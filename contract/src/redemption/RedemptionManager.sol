// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../interfaces/IRedemptionVault.sol";
import "../interfaces/IRedemptionManager.sol";

/// @title RedemptionManager
/// @notice Escrows vault shares and coordinates FIFO asynchronous redemptions.
/// @dev Activation snapshots the request's proportional idle balances and venue liquidity. Venues fund
///      the request independently, and settlement transfers the accumulated request-specific outputs.
contract RedemptionManager is IRedemptionManager, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Maximum lifetime of an asynchronous redemption request.
    uint256 public constant MAX_REDEEM_REQUEST_DURATION = 7 days;

    /// @notice Vault whose asynchronous redemptions are managed by this contract.
    IRedemptionVault public immutable vault;

    /// @notice ERC20 vault-share token escrowed by queued requests.
    IERC20 public immutable sharesToken;

    /// @notice Vault token0 used to snapshot request-specific idle balances.
    IERC20 public immutable token0;

    /// @notice Vault token1 used to snapshot request-specific idle balances.
    IERC20 public immutable token1;

    /// @notice Funding state for the active queue-head request.
    struct ActiveRedeemFunding {
        uint256 requestId;
        uint256 fundingRoundId;
        uint256 totalSharesSnapshot;
        uint256 reservedAmount0;
        uint256 reservedAmount1;
        uint256 pendingVenueCount;
        uint256 fundedVenueCount;
    }
    /// @notice Id assigned to the next activation funding round.
    uint256 public nextFundingRoundId = 1;

    /// @notice Request-specific funding accumulated for the active queue head.
    ActiveRedeemFunding public activeFunding;

    /// @notice Snapshotted venue liquidity still pending for each funding round.
    mapping(uint256 fundingRoundId => mapping(uint256 venueId => uint256 liquidity)) public fundingLiquidity;

    /// @notice A redemption waiting for sufficient idle vault liquidity.
    struct RedeemRequest {
        address owner;
        address receiver;
        uint256 shares;
        uint256 deadline;
        uint256 previousRequestId;
        uint256 nextRequestId;
        RedeemRequestStatus status;
    }

    /// @notice Lifecycle state of an asynchronous redemption request.
    enum RedeemRequestStatus {
        NONE,
        PENDING,
        PROCESSING,
        PROCESSED,
        CANCELLED,
        EXPIRED
    }

    /// @notice Id assigned to the next redemption request.
    uint256 public nextRedeemRequestId = 1;

    /// @notice Queue-head request currently receiving onchain liquidity priority, or zero when none is active.
    uint256 public activeRedeemRequestId;

    /// @notice Oldest queued asynchronous redemption request.
    uint256 public redeemQueueHead;

    /// @notice Newest queued asynchronous redemption request.
    uint256 public redeemQueueTail;

    /// @notice Total shares escrowed by queued `PENDING` and `PROCESSING` redemption requests.
    uint256 public totalPendingRedeemShares;

    /// @notice Redemption request data indexed by request id.
    mapping(uint256 => RedeemRequest) public redeemRequests;

    /// @notice Emitted when shares are escrowed in a new asynchronous redemption request.
    event RedeemRequested(
        uint256 indexed requestId,
        address indexed owner,
        address indexed receiver,
        uint256 shares,
        uint256 deadline
    );

    /// @notice Emitted when the queue head enters processing mode.
    event RedeemRequestActivated(uint256 indexed requestId, address indexed caller);

    /// @notice Emitted when the owner returns the active request to the pending state.
    event RedeemRequestDeactivated(uint256 indexed requestId, address indexed caller);

    /// @notice Emitted when an active request is paid from idle balances.
    event RedeemRequestProcessed(uint256 indexed requestId, uint256 amount0Out, uint256 amount1Out);

    /// @notice Emitted when a request owner cancels a pending request.
    event RedeemRequestCancelled(uint256 indexed requestId, address indexed owner);

    /// @notice Emitted when an expired request is removed and its escrowed shares are returned.
    event RedeemRequestExpired(uint256 indexed requestId, address indexed owner);

    /// @notice Emitted when one venue funds part of the active redemption request.
    event RedeemRequestFunded(
        uint256 indexed requestId,
        uint256 indexed fundingRoundId,
        uint256 indexed venueId,
        uint256 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    /// @notice Thrown when a caller is neither the current vault owner nor keeper.
    error NotOwnerOrKeeper();
    /// @notice Thrown when a caller is not the current vault owner.
    error NotVaultOwner();
    /// @notice Thrown when an address argument is zero.
    error ZeroAddress();
    /// @notice Thrown when a request attempts to escrow zero shares.
    error ZeroShares();
    /// @notice Thrown when the caller does not own enough vault shares.
    error InsufficientShares();

    /// @notice Thrown when a request deadline is not in the permitted future window.
    error InvalidRedeemRequestDeadline();
    /// @notice Thrown when attempting to activate or process a request after its deadline.
    error RedeemRequestDeadlineExpired();
    /// @notice Thrown when queue activation finds a head request outside the pending state.
    error RedeemRequestNotPending();
    /// @notice Thrown when a caller attempts to cancel another account's request.
    error NotRedeemRequestOwner();
    /// @notice Thrown when attempting to expire a request before its deadline.
    error RedeemRequestNotExpired();
    /// @notice Thrown when a terminal request state cannot transition to expired.
    error RedeemRequestNotExpirable();
    /// @notice Thrown when queue activation is requested while the queue is empty.
    error NoPendingRedeemRequest();
    /// @notice Thrown when an asynchronous request is unnecessary because idle liquidity can cover it immediately.
    error IdleLiquidityAvailable();

    /// @notice Thrown when attempting to activate a second request while one is already active.
    error RedeemRequestAlreadyActive();
    /// @notice Thrown when an operation requires a valid active queue-head request.
    error RedeemRequestNotActive();
    /// @notice Thrown when cancellation is attempted outside the pending state.
    error RedeemRequestNotCancellable();

    /// @notice Thrown when a request's proportional venue liquidity rounds down to zero.
    error RedeemLiquidityTooSmall();

    /// @notice Thrown when the selected venue has no pending liquidity in the active funding round.
    error VenueFundingNotPending();
    /// @notice Thrown when settlement is attempted before all snapshotted venues finish funding.
    error RedeemFundingIncomplete();
    /// @notice Thrown when cancellation or expiration is attempted after venue funding begins.
    error RedeemFundingAlreadyStarted();

    modifier onlyVaultOwnerOrKeeper() {
        if (msg.sender != vault.owner() && msg.sender != vault.keeper()) {
            revert NotOwnerOrKeeper();
        }
        _;
    }

    modifier onlyVaultOwner() {
        if (msg.sender != vault.owner()) {
            revert NotVaultOwner();
        }
        _;
    }

    constructor(address _vault) {
        if (_vault == address(0)) revert ZeroAddress();

        vault = IRedemptionVault(_vault);
        sharesToken = IERC20(_vault);
        token0 = IERC20(vault.token0());
        token1 = IERC20(vault.token1());
    }

    /// @inheritdoc IRedemptionManager
    function isProcessing() external view override returns (bool) {
        return activeRedeemRequestId != 0;
    }

    /// @notice Escrows shares in the redemption queue when current idle liquidity is insufficient.
    /// @dev Shares remain in total supply and exposed to vault NAV until the request is processed.
    ///      The caller must approve this manager to transfer the requested vault shares.
    /// @param shares Amount of vault shares escrowed by the request.
    /// @param receiver Address that receives token0 and token1 when the request is processed.
    /// @param deadline Latest timestamp at which the request may be activated or processed.
    /// @return requestId Identifier assigned to the queued request.
    function requestRedeem(
        uint256 shares,
        address receiver,
        uint256 deadline
    ) external nonReentrant returns (uint256 requestId) {
        address requestOwner = msg.sender;

        if (shares == 0) revert ZeroShares();
        if (receiver == address(0)) revert ZeroAddress();
        if (shares > sharesToken.balanceOf(requestOwner)) revert InsufficientShares();

        if (deadline <= block.timestamp || deadline > block.timestamp + MAX_REDEEM_REQUEST_DURATION) {
            revert InvalidRedeemRequestDeadline();
        }

        if (activeRedeemRequestId == 0) {
            // No active request has frozen supply, so settle fees before checking the queue condition.
            vault.accrueManagementFee();
        }

        if (!vault.requiresQueuedRedeem(shares)) revert IdleLiquidityAvailable();

        requestId = nextRedeemRequestId++;
        redeemRequests[requestId] = RedeemRequest({
            owner: requestOwner,
            receiver: receiver,
            shares: shares,
            deadline: deadline,
            previousRequestId: 0,
            nextRequestId: 0,
            status: RedeemRequestStatus.PENDING
        });
        _appendRedeemRequestToQueue(requestId);

        totalPendingRedeemShares += shares;

        sharesToken.safeTransferFrom(requestOwner, address(this), shares);

        emit RedeemRequested(requestId, requestOwner, receiver, shares, deadline);
    }

    /// @notice Activates the queue head so idle liquidity can be reserved for its settlement.
    /// @dev Processing mode blocks synchronous redemptions and new venue deployments until the request
    ///      is processed, deactivated, or expired.
    function activateNextRedeemRequest() external onlyVaultOwnerOrKeeper nonReentrant {
        if (activeRedeemRequestId != 0) revert RedeemRequestAlreadyActive();

        uint256 requestId = redeemQueueHead;
        if (requestId == 0) revert NoPendingRedeemRequest();

        RedeemRequest storage request = redeemRequests[requestId];
        if (request.status != RedeemRequestStatus.PENDING) revert RedeemRequestNotPending();
        if (block.timestamp > request.deadline) revert RedeemRequestDeadlineExpired();

        // Settle fees before PROCESSING freezes the supply used for this funding round.
        vault.accrueManagementFee();

        request.status = RedeemRequestStatus.PROCESSING;
        activeRedeemRequestId = requestId;

        _initializeActiveFunding(requestId, request.shares);

        emit RedeemRequestActivated(requestId, msg.sender);
    }

    /// @notice Funds the active request from one venue's snapshotted proportional liquidity.
    /// @dev Owner or keeper may retry a failed venue independently. Once any venue succeeds, funding
    ///      may continue after the request deadline so a partially funded request can be completed.
    /// @param venueId Venue whose pending liquidity should fund the active request.
    /// @param params Venue-specific remove-liquidity constraints.
    /// @return amount0 Actual token0 amount reserved for the active request.
    /// @return amount1 Actual token1 amount reserved for the active request.
    function fundActiveRedeemRequest(
        uint256 venueId,
        bytes calldata params
    ) external onlyVaultOwnerOrKeeper nonReentrant returns (uint256 amount0, uint256 amount1) {
        uint256 requestId = activeRedeemRequestId;
        if (requestId == 0 || requestId != redeemQueueHead || requestId != activeFunding.requestId) {
            revert RedeemRequestNotActive();
        }

        RedeemRequest storage request = redeemRequests[requestId];
        if (request.status != RedeemRequestStatus.PROCESSING) revert RedeemRequestNotActive();
        if (block.timestamp > request.deadline && activeFunding.fundedVenueCount == 0) {
            revert RedeemRequestDeadlineExpired();
        }

        uint256 fundingRoundId = activeFunding.fundingRoundId;
        uint256 liquidity = fundingLiquidity[fundingRoundId][venueId];
        if (liquidity == 0) revert VenueFundingNotPending();

        fundingLiquidity[fundingRoundId][venueId] = 0;
        activeFunding.pendingVenueCount--;

        (amount0, amount1) = vault.fundQueuedRedeemFromVenue(venueId, liquidity, request.shares, activeFunding.totalSharesSnapshot, params);
        activeFunding.reservedAmount0 += amount0;
        activeFunding.reservedAmount1 += amount1;
        activeFunding.fundedVenueCount++;

        emit RedeemRequestFunded(requestId, fundingRoundId, venueId, liquidity, amount0, amount1);
    }

    /// @notice Returns an unfunded active queue-head request to the pending state.
    /// @dev This owner-only recovery action is unavailable after any venue funds the request. It does
    ///      not remove the request or return its escrowed shares.
    function deactivateRedeemRequest() external onlyVaultOwner nonReentrant {
        uint256 requestId = activeRedeemRequestId;
        if (requestId == 0) revert RedeemRequestNotActive();

        RedeemRequest storage request = redeemRequests[requestId];
        if (request.status != RedeemRequestStatus.PROCESSING) {
            revert RedeemRequestNotActive();
        }

        if (activeFunding.fundedVenueCount != 0) {
            revert RedeemFundingAlreadyStarted();
        }

        request.status = RedeemRequestStatus.PENDING;
        activeRedeemRequestId = 0;
        _clearActiveFunding();

        emit RedeemRequestDeactivated(requestId, msg.sender);
    }

    /// @notice Settles the active queue-head request using its accumulated funding amounts.
    /// @dev Permissionless after every snapshotted venue has funded. Queue state is finalized only after
    ///      vault settlement succeeds.
    /// @return amount0Out Raw token0 amount transferred to the request receiver.
    /// @return amount1Out Raw token1 amount transferred to the request receiver.
    function processNextRedeemRequest() external nonReentrant returns (uint256 amount0Out, uint256 amount1Out) {
        uint256 requestId = activeRedeemRequestId;
        if (requestId == 0 || requestId != redeemQueueHead) {
            revert RedeemRequestNotActive();
        }

        RedeemRequest storage request = redeemRequests[requestId];
        if (request.status != RedeemRequestStatus.PROCESSING) {
            revert RedeemRequestNotActive();
        }

        if (activeFunding.requestId != requestId) {
            revert RedeemRequestNotActive();
        }

        bool deadlineExpired = block.timestamp > request.deadline;
        if (deadlineExpired && activeFunding.fundedVenueCount == 0) {
            revert RedeemRequestDeadlineExpired();
        }
        // Every snapshotted venue must finish funding before settlement.
        if (activeFunding.pendingVenueCount != 0) {
            revert RedeemFundingIncomplete();
        }

        amount0Out = activeFunding.reservedAmount0;
        amount1Out = activeFunding.reservedAmount1;

        vault.settleQueuedRedeem(
            request.shares,
            activeFunding.totalSharesSnapshot,
            request.receiver,
            request.owner,
            amount0Out,
            amount1Out
        );

        // Effects
        request.status = RedeemRequestStatus.PROCESSED;
        activeRedeemRequestId = 0;
        totalPendingRedeemShares -= request.shares;
        _clearActiveFunding();

        _removeRedeemRequestFromQueue(requestId);

        emit RedeemRequestProcessed(requestId, amount0Out, amount1Out);
    }

    /// @notice Cancels a pending request and returns its escrowed shares to its owner.
    /// @param requestId Pending request to cancel.
    function cancelRedeemRequest(uint256 requestId) external nonReentrant {
        RedeemRequest storage request = redeemRequests[requestId];
        if (request.status != RedeemRequestStatus.PENDING) {
            revert RedeemRequestNotCancellable();
        }

        if (msg.sender != request.owner) {
            revert NotRedeemRequestOwner();
        }

        request.status = RedeemRequestStatus.CANCELLED;
        totalPendingRedeemShares -= request.shares;
        _removeRedeemRequestFromQueue(requestId);

        sharesToken.safeTransfer(request.owner, request.shares);

        emit RedeemRequestCancelled(requestId, request.owner);
    }

    /// @notice Removes an expired request that has not begun venue funding and returns its escrowed shares.
    /// @dev Permissionless after the deadline. A funded processing request is irreversible and must settle.
    /// @param requestId Pending or processing request to expire.
    function expireRedeemRequest(uint256 requestId) external nonReentrant {
        RedeemRequest storage request = redeemRequests[requestId];
        if (request.status != RedeemRequestStatus.PENDING && request.status != RedeemRequestStatus.PROCESSING) {
            revert RedeemRequestNotExpirable();
        }

        if (block.timestamp <= request.deadline) {
            revert RedeemRequestNotExpired();
        }

        if (request.status == RedeemRequestStatus.PROCESSING) {
            if (activeRedeemRequestId != requestId) revert RedeemRequestNotActive();

            // Once venue funding succeeds, the redemption becomes irreversible.
            if (activeFunding.fundedVenueCount != 0) {
                revert RedeemFundingAlreadyStarted();
            }

            activeRedeemRequestId = 0;
            _clearActiveFunding();
        }

        request.status = RedeemRequestStatus.EXPIRED;
        totalPendingRedeemShares -= request.shares;
        _removeRedeemRequestFromQueue(requestId);

        sharesToken.safeTransfer(request.owner, request.shares);

        emit RedeemRequestExpired(requestId, request.owner);
    }

    /// @notice Appends a newly created request to the tail of the redemption queue.
    function _appendRedeemRequestToQueue(uint256 requestId) internal {
        RedeemRequest storage request = redeemRequests[requestId];

        if (redeemQueueTail == 0) {
            redeemQueueHead = requestId;
        } else {
            redeemRequests[redeemQueueTail].nextRequestId = requestId;
            request.previousRequestId = redeemQueueTail;
        }

        redeemQueueTail = requestId;
    }

    /// @notice Unlinks a queued request while preserving its terminal request record.
    function _removeRedeemRequestFromQueue(uint256 requestId) internal {
        RedeemRequest storage request = redeemRequests[requestId];
        uint256 previousRequestId = request.previousRequestId;
        uint256 nextRequestId = request.nextRequestId;

        if (previousRequestId == 0) { // remove first request
            // The next request becomes the new head.
            redeemQueueHead = nextRequestId;
        } else { // remove middle request
            redeemRequests[previousRequestId].nextRequestId = nextRequestId;
        }

        if (nextRequestId == 0) { // remove last request
            // The previous request becomes the new tail.
            redeemQueueTail = previousRequestId;
        } else { // remove middle request
            redeemRequests[nextRequestId].previousRequestId = previousRequestId;
        }

        request.previousRequestId = 0;
        request.nextRequestId = 0;
    }

    /// @notice Snapshots idle balances and proportional venue liquidity for a newly active request.
    function _initializeActiveFunding(uint256 requestId, uint256 shares) internal {
        uint256 totalSharesSnapshot = sharesToken.totalSupply();

        uint256 fundingRoundId = nextFundingRoundId++;

        uint256 reservedAmount0 = Math.mulDiv(token0.balanceOf(address(vault)), shares, totalSharesSnapshot);
        uint256 reservedAmount1 = Math.mulDiv(token1.balanceOf(address(vault)), shares, totalSharesSnapshot);

        uint256 pendingVenueCount;
        uint256 count = vault.venueCount();

        for (uint256 i = 0; i < count; i++) {
            uint256 venueId = vault.venueIds(i);
            uint256 currentLiquidity = vault.venueLiquidity(venueId);
            if (currentLiquidity == 0) continue;

            uint256 liquidityToWithdraw = Math.mulDiv(currentLiquidity, shares, totalSharesSnapshot);
            if (liquidityToWithdraw == 0) revert RedeemLiquidityTooSmall();

            fundingLiquidity[fundingRoundId][venueId] = liquidityToWithdraw;
            pendingVenueCount++;
        }

        activeFunding = ActiveRedeemFunding({
            requestId: requestId,
            fundingRoundId: fundingRoundId,
            totalSharesSnapshot: totalSharesSnapshot,
            reservedAmount0: reservedAmount0,
            reservedAmount1: reservedAmount1,
            pendingVenueCount: pendingVenueCount,
            fundedVenueCount: 0
        });
    }

    /// @notice Clears active funding state and any unprocessed per-venue liquidity records.
    function _clearActiveFunding() internal {
        uint256 fundingRoundId = activeFunding.fundingRoundId;
        if (fundingRoundId != 0) {
            uint256 count = vault.venueCount();
            for (uint256 i = 0; i < count; i++) {
                uint256 venueId = vault.venueIds(i);
                delete fundingLiquidity[fundingRoundId][venueId];
            }
        }
        delete activeFunding;
    }
}
