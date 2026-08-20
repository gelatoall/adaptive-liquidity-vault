// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./libraries/VaultMath.sol";
import "./libraries/RebalanceTypes.sol";
import "./interfaces/IVenueAdapter.sol";
import "./interfaces/IPriceOracle.sol";
import "./interfaces/IVolatilityOracle.sol";
import "./interfaces/IRebalanceStrategy.sol";
import "./interfaces/IVenueValuator.sol";
import "./interfaces/IRedemptionManager.sol";

/// @title AdaptiveLPVault
/// @notice Minimal two-asset vault that mints ERC20 shares against deposited assets.
/// @dev The vault can keep assets idle or deploy them across registered venue adapters.
contract AdaptiveLPVault is ERC20, Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ============================================
    // Constants
    // ============================================
    /// @notice Shares permanently locked on the first deposit to mitigate donation attacks.
    uint256 public constant MINIMUM_LOCKED_SHARES = 1000;

    /// @notice Address holding permanently locked initial shares.
    address public constant LOCKED_SHARES_RECEIVER = address(0xdead);

    /// @dev Maximum annual management fee rate accepted by the vault.
    uint16 internal constant MAX_MANAGEMENT_FEE_BPS = 1000;

    /// @dev Seconds used to convert an annual fee rate into an elapsed-period fee.
    uint256 internal constant MANAGEMENT_FEE_YEAR = 365 days;

    /// @dev Fixed-point precision used for fractional fee calculations.
    uint256 internal constant WAD = 1e18;

    // ============================================
    // Types
    // ============================================
    /// @notice Configuration for one registered liquidity venue.
    struct VenueConfig {
        IVenueAdapter adapter;
        bool enabled;
        bytes32 label;      // optional, eg: "V2", "V3_005", "V3_030", "V3_100"
    }

    /// @notice Venue-specific withdrawal execution params used during user redemptions.
    struct VenueWithdrawalParams {
        uint256 venueId;
        bytes params;
    }

    /// @notice Execution guards for strategy-driven rebalances.
    struct RebalanceConfig {
        /// @notice Minimum time between successful strategy-driven rebalances. Zero disables the guard.
        uint256 minCooldown;
        /// @notice Minimum volatility change since the last successful strategy rebalance. Zero disables the guard.
        uint256 minVolatilityDelta;
        /// @notice Maximum allowed transaction gas price for strategy-driven rebalances. Zero disables the guard.
        uint256 maxGasPrice;
    }

    /// @notice Configuration for capped annual management fees charged through vault-share dilution.
    struct ManagementFeeConfig {
        /// @notice Address receiving newly minted management-fee shares.
        address recipient;
        /// @notice Annual fee rate in basis points, capped by `MAX_MANAGEMENT_FEE_BPS`.
        uint16 annualFeeBps;
        /// @notice Timestamp through which management fees were last accounted.
        uint64 lastAccrual;
    }

    /// @notice Coarse operational health status exposed for keepers and monitoring.
    enum SystemStatus {
        NORMAL,
        ORACLE_STALE,
        ORACLE_DEVIATION,
        PAUSED
    }

    /// @notice Internal strategy rebalance guard status used by execution and view helpers.
    enum RebalanceGuardFailure {
        NONE,
        COOLDOWN_NOT_ELAPSED,
        GAS_PRICE_TOO_HIGH,
        VALUATION_ORACLE_STALE,
        VALUATION_ORACLE_DEVIATION,
        VOLATILITY_ORACLE_NOT_SET,
        VOLATILITY_DELTA_TOO_SMALL
    }

    // ============================================
    // State
    // ============================================
    /// @notice First underlying token accepted by the vault.
    IERC20 public immutable token0;
    /// @notice Second underlying token accepted by the vault.
    IERC20 public immutable token1;

    /// @notice Decimals used to interpret raw token0 amounts.
    uint8 public immutable decimals0;
    /// @notice Decimals used to interpret raw token1 amounts.
    uint8 public immutable decimals1;

    /// @notice Price oracle used to calculate the value of underlying holdings.
    /// @dev The vault depends on the IPriceOracle interface for price discovery.
    IPriceOracle public priceOracle;

    /// @notice Maximum permitted age of prices used for vault accounting.
    uint256 public maxPriceAge;

    /// @notice Independent oracle used to validate valuation prices.
    IPriceOracle public referencePriceOracle;

    /// @notice Maximum permitted age of reference prices.
    uint256 public maxReferencePriceAge;

    /// @notice Maximum permitted primary/reference price deviation in basis points.
    uint256 public maxPriceDeviationBps;

    /// @notice Strategy used to build target plans for strategy-driven rebalances.
    IRebalanceStrategy public strategy;

    /// @notice Address allowed to execute strategy-driven rebalances without admin permissions.
    address public keeper;

    /// @notice Guard configuration for strategy-driven rebalances.
    RebalanceConfig public rebalanceConfig;

    /// @notice Timestamp of the last successful strategy-driven rebalance.
    uint256 public lastRebalance;

    /// @notice Volatility oracle used by strategy rebalance guards.
    IVolatilityOracle public volatilityOracle;

    /// @notice Volatility recorded after the last successful strategy rebalance executed with the delta guard enabled.
    /// @dev This value is meaningful only while `volatilityBaselineInitialized` is true.
    uint256 public lastRebalanceVolatilityBps;

    /// @notice Whether `lastRebalanceVolatilityBps` contains a valid baseline for the current oracle and guard lifecycle.
    bool public volatilityBaselineInitialized;

    /// @notice Maximum allowed total-value loss during rebalance, in basis points. Zero disables the check.
    uint256 public maxRebalanceValueLossBps;

    /// @notice Minimum vault value that must remain idle, in basis points.
    uint256 public minIdleBufferBps;

    /// @notice Whether strategy rebalances require a configured volatility oracle.
    bool public oracleHealthCheckEnabled;

    /// @notice Current configuration for capped annual management-fee accrual.
    ManagementFeeConfig public managementFeeConfig;

    /// @notice Venue configuration by caller-defined venue id.
    mapping(uint256 => VenueConfig) public venues;

    /// @notice Tracks whether a venue id has been registered.
    mapping(uint256 => bool) public venueRegistered;

    /// @notice Adapter-reported liquidity currently tracked for each venue.
    mapping(uint256 => uint256) public venueLiquidity;

    /// @notice Trusted accounting valuator configured for each venue.
    mapping(uint256 => IVenueValuator) public venueValuators;

    /// @notice Whether a registered venue is isolated because its assets may be impaired.
    mapping(uint256 => bool) public venueQuarantined;

    /// @notice Percentage of the valuator-reported venue value recognized in vault NAV.
    mapping(uint256 => uint256) public venueValuationBps;

    /// @notice Number of currently quarantined venues.
    uint256 public quarantinedVenueCount;

    /// @notice List of registered venue ids used for iteration.
    /// @dev Venue removal uses swap-and-pop, so list ordering is not stable.
    uint256[] public venueIds;

    /// @notice Sum of adapter-reported liquidity across all venues.
    /// @dev This is bookkeeping only. Liquidity units may differ across venues and should not be treated as asset value.
    uint256 public totalLiquidity;

    /// @notice One-time configured manager responsible for asynchronous redemption requests.
    address public redemptionManager;

    // ============================================
    // Events
    // ============================================
    /// @notice Emitted when a sender deposits underlying tokens and shares are minted to a receiver.
    event Deposit(address indexed sender, address indexed receiver, uint256 amount0, uint256 amount1, uint256 shares);

    /// @notice Emitted when shares are burned from an owner and underlying tokens are sent to a receiver.
    event Redeem(address indexed sender, address indexed receiver, address indexed owner, uint256 shares, uint256 amount0Out, uint256 amount1Out);

    /// @notice Emitted when the owner updates the valuation price oracle.
    event SetPriceOracleConfig(
        address indexed priceOracle,
        address indexed referencePriceOracle,
        uint256 maxPriceAge,
        uint256 maxReferencePriceAge,
        uint256 maxPriceDeviationBps
    );

    /// @notice Emitted when the owner updates the volatility oracle.
    event SetVolatilityOracle(address indexed volatilityOracle);

    /// @notice Emitted when the owner updates the rebalance strategy.
    event SetStrategy(address indexed strategy);

    /// @notice Emitted when the owner updates the keeper address.
    event SetKeeper(address indexed keeper);

    /// @notice Emitted when the owner updates strategy rebalance guards.
    event SetRebalanceConfig(uint256 minCooldown, uint256 minVolatilityDelta, uint256 maxGasPrice);

    /// @notice Emitted when the owner registers or updates a venue.
    event SetVenue(uint256 indexed venueId, address indexed adapter, bytes32 label, bool enabled);

    /// @notice Emitted when the asynchronous redemption manager is configured.
    event SetRedemptionManager(address indexed redemptionManager);

    /// @notice Emitted when an inactive venue is removed from the registry.
    event RemoveVenue(uint256 indexed venueId, address indexed adapter);

    /// @notice Emitted when the trusted valuator for a venue is updated or cleared.
    /// @dev A zero valuator means the previous adapter-specific valuator was cleared.
    event SetVenueValuator(uint256 indexed venueId, address indexed valuator);

    /// @notice Emitted when the owner updates the rebalance value-loss guard.
    event SetMaxRebalanceValueLossBps(uint256 maxRebalanceValueLossBps);

    /// @notice Emitted when the minimum idle liquidity buffer is updated.
    event SetMinIdleBufferBps(uint256 minIdleBufferBps);

    /// @notice Emitted when strategy rebalance oracle health checks are toggled.
    event SetOracleHealthCheckEnabled(bool enabled);

    /// @notice Emitted when the management-fee recipient or annual rate is updated.
    event SetManagementFeeConfig(address indexed recipient, uint256 annualFeeBps);

    /// @notice Emitted when elapsed management fees are minted as vault shares.
    event ManagementFeeAccrued(address indexed recipient, uint256 sharesMinted, uint256 accrualPeriod);

    /// @notice Emitted when the vault deploys idle funds into a venue.
    event DeployToVenue(uint256 indexed venueId, uint256 amount0, uint256 amount1, uint256 liquidity);

    /// @notice Emitted when the vault withdraws venue liquidity back to idle balances.
    /// @dev Output amounts include any fees collected before removing the requested liquidity.
    event WithdrawFromVenue(uint256 indexed venueId, uint256 liquidity, uint256 amount0Out, uint256 amount1Out);

    /// @notice Emitted when claimable venue tokens are transferred into vault idle balances.
    event FeeHarvested(uint256 indexed venueId, uint256 amount0, uint256 amount1);

    /// @notice Emitted when harvested venue tokens are redeployed into the same venue.
    event FeeCompounded(uint256 indexed venueId, uint256 amount0, uint256 amount1, uint256 liquidityAdded);

    /// @notice Emitted after a rebalance plan executes successfully.
    event Rebalance(address indexed caller);

    /// @notice Emitted after a strategy-driven rebalance executes successfully.
    event RebalanceWithStrategy(address indexed caller, address indexed strategy, bytes data);

    /// @notice Emitted after a best-effort emergency exit has attempted every active venue.
    event EmergencyExit(address indexed caller);

    /// @notice Emitted when one venue cannot be withdrawn during a best-effort emergency exit.
    event EmergencyExitFailed(uint256 indexed venueId);

    /// @notice Emitted when a venue is isolated and its recognized accounting value is updated.
    event VenueQuarantined(uint256 indexed venueId, uint256 valuationBps);

    /// @notice Emitted when a quarantined venue's recognized value changes.
    event VenueValuationBpsUpdated(uint256 indexed venueId, uint256 oldValuationBps, uint256 newValuationBps);

    /// @notice Emitted when a venue exits quarantine.
    event VenueRestored(uint256 indexed venueId, bool deploymentEnabled);

    // ============================================
    // Custom Errors
    // ============================================
    /// @notice Thrown when an address argument is the zero address.
    error ZeroAddress();

    /// @notice Thrown when either configured token decimals value is zero.
    error ZeroDecimals();

    /// @notice Thrown when both token deposit amounts are zero.
    error ZeroAmounts();

    /// @notice Thrown when a caller tries to redeem zero shares.
    error ZeroShares();

    /// @notice Thrown when a caller tries to withdraw zero venue liquidity.
    error ZeroLiquidity();

    /// @notice Thrown when an initial deposit cannot cover the permanently locked shares.
    error InitialDepositTooSmall();

    /// @notice Thrown when both configured underlying token addresses are the same.
    error IdenticalTokens();

    /// @notice Thrown when a caller is neither the owner nor the keeper.
    error NotOwnerOrKeeper();

    /// @notice Thrown when a venue has no claimable tokens to compound.
    error NoFeesToCompound();

    /// @notice Thrown when a caller tries to withdraw more liquidity than tracked for a venue.
    error InsufficientLiquidity();

    /// @notice Thrown when a caller tries to redeem more shares than they own.
    error InsufficientShares();

    /// @notice Thrown when a deployment or rebalance plan requires more idle token balance than available.
    error InsufficientBalances();

    /// @notice Thrown when minted shares are below the caller's minimum.
    error InsufficientSharesOut();

    /// @notice Thrown when redeemed token amounts are below the caller's minimums.
    error InsufficientRedeemOutput();

    /// @notice Thrown when idle balances cannot cover a synchronous redemption.
    error InsufficientIdleLiquidity(uint256 requiredValue, uint256 idleValue);

    /// @notice Thrown when the primary valuation oracle is not configured.
    error PriceOracleNotSet();

    /// @notice Thrown when the independent reference oracle is not configured.
    error ReferencePriceOracleNotSet();

    /// @notice Thrown when primary and reference oracle configuration is invalid.
    error InvalidOracleConfiguration();

    /// @notice Thrown when either configured price freshness window is zero.
    error InvalidMaxPriceAge();

    /// @notice Thrown when the maximum permitted price deviation is invalid.
    error InvalidMaxPriceDeviationBps();

    /// @notice Thrown when an oracle reports a zero price.
    error InvalidOraclePrice(address oracle, uint8 tokenIndex);

    /// @notice Thrown when an oracle reports an unset or future update timestamp.
    error InvalidOracleTimestamp(address oracle, uint256 updatedTimestamp, uint256 currentTimestamp);

    /// @notice Thrown when an oracle price is older than its configured maximum age.
    error StalePrice(address oracle, uint256 updatedTimestamp, uint256 currentTimestamp);

    /// @notice Thrown when primary and reference prices differ beyond the configured limit.
    error ExcessivePriceDeviation(uint8 tokenIndex, uint256 deviationBps, uint256 maxDeviationBps);

    /// @notice Thrown when a requested venue id is not registered or has no adapter configured.
    error VenueNotSet();

    /// @notice Thrown when attempting to remove a venue that is still enabled.
    error VenueMustBeDisabled();

    /// @notice Thrown when venue registration state and the iterable venue list disagree.
    error VenueRegistryInconsistent(uint256 venueId);

    /// @notice Thrown when an active venue has no trusted accounting valuator.
    error VenueValuatorNotSet(uint256 venueId);

    /// @notice Thrown when a valuator is bound to a different venue adapter.
    error ValuatorAdapterMismatch();

    /// @notice Thrown when a requested venue is registered but disabled for new deployments.
    error VenueDisabled();

    /// @notice Thrown when attempting to quarantine an already isolated venue.
    error VenueAlreadyQuarantined();

    /// @notice Thrown when an operation requires a quarantined venue.
    error VenueNotQuarantined();

    /// @notice Thrown when unpausing while isolated venues remain.
    error QuarantinedVenuesRemain();

    /// @notice Thrown when an operation is blocked because at least one venue still has an active position.
    error ActivePositionExists();

    /// @notice Thrown when a positive redemption value produces zero output for both underlying tokens.
    error RedeemAmountTooSmall();

    /// @notice Thrown when a rebalance request would not move any funds.
    error NoRebalanceNeeded();

    /// @notice Thrown when a rebalance plan contains the same venue id more than once.
    error DuplicateVenueTarget();

    /// @notice Thrown when strategy-driven rebalance is called before a strategy is configured.
    error StrategyNotSet();

    /// @notice Thrown when strategy-driven rebalance is called before cooldown elapses.
    error CooldownNotElapsed();

    /// @notice Thrown when strategy-driven rebalance is called above the configured gas price limit.
    error GasPriceTooHigh();

    /// @notice Thrown when a strategy rebalance requires fresh valuation prices.
    error ValuationOracleStale();

    /// @notice Thrown when valuation oracles exceed the configured deviation limit.
    error ValuationOracleDeviation();

    /// @notice Thrown when volatility guard is enabled before configuring a volatility oracle.
    error VolatilityOracleNotSet();

    /// @notice Thrown when volatility change is below the configured minimum.
    error VolatilityDeltaTooSmall();

    /// @notice Thrown when a basis-points value exceeds 100%.
    error InvalidBps();

    /// @notice Thrown when rebalance unexpectedly changes total share supply.
    error RebalanceShareSupplyChanged();

    /// @notice Thrown when rebalance reduces total vault value beyond the configured guard.
    error ExcessiveRebalanceValueLoss();

    /// @notice Thrown when an external caller invokes a function reserved for vault self-calls.
    error OnlySelf();

    /// @notice Thrown when attempting to replace the one-time redemption-manager configuration.
    error RedemptionManagerAlreadySet();
    /// @notice Thrown when the configured redemption manager has no deployed contract code.
    error InvalidRedemptionManager();
    /// @notice Thrown when a caller is not the configured redemption manager.
    error OnlyRedemptionManager();
    /// @notice Thrown when queued settlement is attempted without an active manager request.
    error RedemptionNotProcessing();
    /// @notice Thrown when synchronous redemption or venue deployment is attempted during request processing.
    error RedeemProcessingActive();
    /// @notice Thrown when a deployment would leave insufficient idle value.
    error IdleBufferViolation(uint256 requiredIdleValue, uint256 idleValueAfter);
    /// @notice Thrown when vault share supply changes during an active funding round.
    error RedeemShareSupplyChanged();

    // ============================================
    // Modifiers
    // ============================================
    modifier onlyOwnerOrKeeper() {
        if (msg.sender != owner() && msg.sender != keeper) {
            revert NotOwnerOrKeeper();
        }
        _;
    }

    modifier onlyRedemptionManager() {
        if (msg.sender != redemptionManager) {
            revert OnlyRedemptionManager();
        }
        _;
    }

    /// @dev Prevents operations that could change supply, idle balances, or venue positions during request funding.
    modifier whenNoRedemptionProcessing() {
        if (_isRedemptionProcessing()) {
            revert RedeemProcessingActive();
        }
        _;
    }

    // ============================================
    // Constructor
    // ============================================
    /// @param _name Share token name.
    /// @param _symbol Share token symbol.
    /// @param _token0 Address of the first underlying token.
    /// @param _token1 Address of the second underlying token.
    /// @param _decimals0 Decimals used by token0 amounts.
    /// @param _decimals1 Decimals used by token1 amounts.
    constructor(
        string memory _name,
        string memory _symbol,
        address _token0, 
        address _token1, 
        uint8 _decimals0, 
        uint8 _decimals1
    ) ERC20(_name, _symbol) Ownable(msg.sender) {
        if (_token0 == address(0) || _token1 == address(0)) {
            revert ZeroAddress();
        }

        if (_decimals0 == 0 || _decimals1 == 0) {
            revert ZeroDecimals();
        }

        if (_token0 == _token1) revert IdenticalTokens();

        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
        decimals0 = _decimals0;
        decimals1 = _decimals1;
    }

    // ============================================
    // User Functions
    // ============================================
    /// @notice Deposits token0 and token1 and mints vault shares to `receiver`.
    /// @dev The caller supplies the underlying tokens; `receiver` receives the newly minted shares. On
    ///      the initial deposit, `MINIMUM_LOCKED_SHARES` is reserved from gross shares and locked permanently.
    /// @param amount0 Raw token0 amount in token0's smallest unit.
    /// @param amount1 Raw token1 amount in token1's smallest unit.
    /// @param receiver Address that receives the minted vault shares.
    /// @param minShares Minimum acceptable shares minted to `receiver`.
    /// @return shares Amount of vault shares minted to `receiver`.
    function deposit(
        uint256 amount0, 
        uint256 amount1, 
        address receiver, 
        uint256 minShares
    ) external whenNotPaused nonReentrant whenNoRedemptionProcessing returns (uint256 shares) {
        // Reject if both deposit amounts are zero.
        if (amount0 == 0 && amount1 == 0) {
            revert ZeroAmounts();
        }

        // Reject if receiver is zero.
        if (receiver == address(0)) revert ZeroAddress();

        // Settle elapsed fee dilution before using total supply for share pricing.
        _accrueManagementFee();

        (uint256 price0, uint256 price1) = _getValidatedPrices();

        // Read totalAssets() before the deposit.
        // Read totalSupply() before the deposit.
        uint256 totalAssetsBefore = _totalAssetsAtPrices(price0, price1);
        uint256 totalShares = totalSupply();

        // Convert the deposit amounts into a single base-denominated value using VaultMath.
        uint256 assetsToDeposit = VaultMath.getAssetsTotalValue(
            amount0, price0, decimals0, 
            amount1, price1, decimals1
        );

        // Calculate gross shares, then reserve the permanent lock on initial deposit.
        uint256 grossShares = VaultMath.calculateShares(assetsToDeposit, totalAssetsBefore, totalShares);
        bool isInitialDeposit = totalShares == 0;
        if (isInitialDeposit) {
            if (grossShares <= MINIMUM_LOCKED_SHARES) revert InitialDepositTooSmall();
            shares = grossShares - MINIMUM_LOCKED_SHARES;
        } else {
            shares = grossShares;
        }

        if (shares < minShares) revert InsufficientSharesOut();

        // Transfer token0 and token1 from the sender into the vault.
        token0.safeTransferFrom(msg.sender, address(this), amount0);
        token1.safeTransferFrom(msg.sender, address(this), amount1);

        // Permanently lock part of the shares minted by the initial deposit.
        if (isInitialDeposit) {
            _mint(LOCKED_SHARES_RECEIVER, MINIMUM_LOCKED_SHARES);
        }

        // Mint the remaining shares to the receiver.
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, amount0, amount1, shares);
    } 

    /// @notice Redeems vault shares using available idle token balances.
    /// @dev Values the redeemed shares using validated prices and pays them using the current idle token composition
    ///      without removing venue liquidity. Burns shares from `owner`; delegated callers need share allowance.
    /// @param shareToRedeem Amount of vault shares to burn.
    /// @param receiver Address that receives the withdrawn token0 and token1 amounts.
    /// @param owner Address whose vault shares are burned.
    /// @param minAmount0Out Minimum acceptable token0 amount sent to `receiver`.
    /// @param minAmount1Out Minimum acceptable token1 amount sent to `receiver`.
    /// @return amount0Out Raw token0 amount sent to `receiver`.
    /// @return amount1Out Raw token1 amount sent to `receiver`.
    function redeem(
        uint256 shareToRedeem,
        address receiver,
        address owner,
        uint256 minAmount0Out,
        uint256 minAmount1Out
    ) external nonReentrant returns (uint256 amount0Out, uint256 amount1Out) {
        if (_isRedemptionProcessing()) {
            revert RedeemProcessingActive();
        }

        // Reject if shares is zero.
        if (shareToRedeem == 0) {
            revert ZeroShares();
        }

        if (receiver == address(0) || owner == address(0)) revert ZeroAddress();

        // Revert if the share amount exceeds the owner's balance.
        if (shareToRedeem > balanceOf(owner)) {
            revert InsufficientShares();
        }

        // Allow approved operators to redeem shares on behalf of the owner.
        if (owner != msg.sender) {
            _spendAllowance(owner, msg.sender, shareToRedeem);
        }

        // Settle elapsed fee dilution before snapshotting the redeemed share ratio.
        _accrueManagementFee();

        // Snapshot total supply before quoting and burning the redeemed shares.
        uint256 totalSharesBefore = totalSupply();

        (amount0Out, amount1Out) = _quoteIdleRedeem(shareToRedeem, totalSharesBefore);
        if (amount0Out < minAmount0Out || amount1Out < minAmount1Out) {
            revert InsufficientRedeemOutput();
        }

        // Burn the owner's redeemed shares.
        _burn(owner, shareToRedeem);

        // Transfer token0 and token1 to the receiver.
        token0.safeTransfer(receiver, amount0Out);
        token1.safeTransfer(receiver, amount1Out);

        emit Redeem(msg.sender, receiver, owner, shareToRedeem, amount0Out, amount1Out);
    }

    /// @notice Accrues elapsed management fees by minting vault shares to the configured recipient.
    /// @dev Permissionless. A call charges at most one year since the prior accrual and waives any
    ///      older elapsed time. It is blocked while queued redemption funding has frozen share supply.
    /// @return feeShares Vault shares minted to the configured fee recipient.
    function accrueManagementFee() external nonReentrant whenNoRedemptionProcessing returns (uint256 feeShares) {
        return _accrueManagementFee();
    }

    /// @notice Returns whether current idle value is insufficient to redeem `shares` synchronously.
    function requiresQueuedRedeem(uint256 shares) external view returns (bool) {
        (uint256 redeemValue, uint256 idleValue,,) = _getRedeemLiquidityState(shares, totalSupply());
        return redeemValue > idleValue;
    }

    /// @notice Withdraws one venue's snapshotted liquidity for the active queued redemption.
    /// @dev Collects claimable venue tokens first and attributes only the request's proportional fee share.
    /// @param venueId Venue funding the active request.
    /// @param liquidity Snapshotted venue liquidity allocated to the request.
    /// @param requestShares Shares escrowed by the active request.
    /// @param totalSharesSnapshot Total share supply captured when request funding began.
    /// @param params Venue-specific remove-liquidity constraints.
    /// @return requestAmount0 Actual token0 amount attributed to the request.
    /// @return requestAmount1 Actual token1 amount attributed to the request.
    function fundQueuedRedeemFromVenue(
        uint256 venueId,
        uint256 liquidity,
        uint256 requestShares,
        uint256 totalSharesSnapshot,
        bytes calldata params
    ) external onlyRedemptionManager nonReentrant returns (uint256 requestAmount0, uint256 requestAmount1) {
        if (!_isRedemptionProcessing()) revert RedemptionNotProcessing();
        if (totalSupply() != totalSharesSnapshot) revert RedeemShareSupplyChanged();

        (uint256 fees0, uint256 fees1) = _collectVenueFees(venueId);
        uint256 requestFees0 = Math.mulDiv(fees0, requestShares, totalSharesSnapshot);
        uint256 requestFees1 = Math.mulDiv(fees1, requestShares, totalSharesSnapshot);

        (uint256 removed0, uint256 removed1) = _withdrawFromVenue(venueId, liquidity, params, false);
        requestAmount0 = requestFees0 + removed0;
        requestAmount1 = requestFees1 + removed1;
    }

    /// @notice Settles an active asynchronous redemption using its request-specific funded amounts.
    /// @dev Verifies the activation-time supply snapshot, burns manager-escrowed shares, and transfers
    ///      the exact amounts supplied by the redemption manager to `receiver`.
    function settleQueuedRedeem(
        uint256 shares,
        uint256 totalSharesSnapshot,
        address receiver,
        address shareOwner,
        uint256 amount0Out,
        uint256 amount1Out
    ) external onlyRedemptionManager nonReentrant {
        if (!_isRedemptionProcessing()) {
            revert RedemptionNotProcessing();
        }

        if (totalSupply() != totalSharesSnapshot) {
            revert RedeemShareSupplyChanged();
        }

        if (amount0Out > token0.balanceOf(address(this)) || amount1Out > token1.balanceOf(address(this))) {
            revert InsufficientBalances();
        }

        // RedemptionManager holds the shares while the request is queued.
        _burn(msg.sender, shares);

        token0.safeTransfer(receiver, amount0Out);
        token1.safeTransfer(receiver, amount1Out);

        emit Redeem(msg.sender, receiver, shareOwner, shares, amount0Out, amount1Out);
    }

    // ============================================
    // View Functions
    // ============================================
    /// @notice Returns the current total value of the vault's holdings.
    /// @dev Values idle balances directly and active positions through their configured trusted valuators.
    ///      Primary prices must be fresh and within the configured deviation from the reference oracle.
    ///      Oracle prices and the returned value are denominated in configured token0 with 1e18 precision.
    /// @return Total vault value denominated in token0, scaled by 1e18.
    function totalAssets() public view returns (uint256) {
        (uint256 price0, uint256 price1) = _getValidatedPrices();

        return _totalAssetsAtPrices(price0, price1);
    }

    /// @notice Returns raw token amounts across idle balances and deployed venue positions.
    /// @dev Venue amounts may depend on current pool state and are informational; share accounting uses `totalAssets()`.
    /// @return total0 Total token0 amount held directly or reported by venues.
    /// @return total1 Total token1 amount held directly or reported by venues.
    function getTotalUnderlying() external view returns (uint256 total0, uint256 total1) {
        (total0, total1) = _getTotalUnderlying();
    }

    /// @notice Returns the vault's current idle-buffer state in the base denomination.
    /// @return idleValue Current value held directly by the vault.
    /// @return requiredIdleValue Minimum idle value required by `minIdleBufferBps`.
    /// @return availableToDeployValue Idle value available above the required buffer.
    /// @return bufferDeficit Value required to restore the buffer, or zero when satisfied.
    function getIdleBufferState() external view returns (
        uint256 idleValue,
        uint256 requiredIdleValue,
        uint256 availableToDeployValue,
        uint256 bufferDeficit
    ) {
        return _getIdleBufferState();
    }

    /// @notice Returns the number of currently registered venues.
    function venueCount() external view returns (uint256) {
        return venueIds.length;
    }

    /// @notice Returns the current vault health status used by offchain keepers and monitoring.
    /// @dev Reports stale or invalid valuation data as `ORACLE_STALE`, excessive primary/reference
    ///      price divergence as `ORACLE_DEVIATION`, and gives pause state the highest priority.
    function checkSystemHealth() external view returns (SystemStatus) {
        if (paused()) return SystemStatus.PAUSED;

        SystemStatus valuationStatus = _getValuationOracleStatus();
        if (valuationStatus != SystemStatus.NORMAL) {
            return valuationStatus;
        }

        if (oracleHealthCheckEnabled && address(volatilityOracle) == address(0)) {
            return SystemStatus.ORACLE_STALE;
        }

        return SystemStatus.NORMAL;
    }

    /// @notice Returns whether strategy-driven rebalance currently passes vault-level guards.
    /// @dev This does not call `strategy.buildTargets(...)`; it only checks vault-owned preconditions.
    function canRebalanceWithStrategy() external view returns (bool allowed, string memory reason) {
        if (address(strategy) == address(0)) {
            return (false, "Rebalance strategy not set");
        }

        if (paused()) {
            return (false, "Paused");
        }

        (RebalanceGuardFailure failure, ) = _getStrategyRebalanceGuardStatus();

        if (failure == RebalanceGuardFailure.COOLDOWN_NOT_ELAPSED) return (false, "Cooldown not elapsed");
        if (failure == RebalanceGuardFailure.GAS_PRICE_TOO_HIGH) return (false, "Gas price too high");
        if (failure == RebalanceGuardFailure.VALUATION_ORACLE_STALE) return (false, "Valuation oracle stale");
        if (failure == RebalanceGuardFailure.VALUATION_ORACLE_DEVIATION) return (false, "Valuation oracle deviation");
        if (failure == RebalanceGuardFailure.VOLATILITY_ORACLE_NOT_SET) return (false, "Volatility oracle not set");
        if (failure == RebalanceGuardFailure.VOLATILITY_DELTA_TOO_SMALL) return (false, "Volatility delta too small");
        return (true, "");
    }

    // ============================================
    // Admin Functions
    // ============================================
    /// @notice Pauses deposits and normal rebalance operations.
    /// @dev Redeems and direct venue withdrawals remain available so users and the owner can exit positions.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resumes deposits and normal rebalance operations.
    /// @dev Only the owner can unpause after validating that the vault is safe to operate again.
    function unpause() external onlyOwner {
        if (quarantinedVenueCount != 0) revert QuarantinedVenuesRemain();

        _unpause();
    }

    /// @notice Withdraws all tracked liquidity from one venue through an isolated external call.
    /// @dev Only callable by the vault itself to provide the call boundary required by `try/catch`.
    ///      Successful withdrawals emit `WithdrawFromVenue`; failures revert only this subcall.
    /// @param venueId Registered venue to withdraw from.
    /// @param params Venue-specific remove-liquidity constraints.
    function executeEmergencyExitVenue(uint256 venueId, bytes calldata params) external {
        if (msg.sender != address(this)) revert OnlySelf();

        _withdrawFromVenue(venueId, venueLiquidity[venueId], params, true);
    }

    /// @notice Pauses the vault and attempts to withdraw every active venue.
    /// @dev Each venue executes through an isolated self-call. A failed venue remains deployed and
    ///      emits `EmergencyExitFailed`, while the loop continues withdrawing healthy venues.
    /// @param withdrawalParams Optional venue-specific remove-liquidity constraints.
    function emergencyExit(VenueWithdrawalParams[] calldata withdrawalParams) external onlyOwner nonReentrant whenNoRedemptionProcessing {
        if (!paused()) {
            _pause();
        }

        for (uint256 i = 0; i < venueIds.length; i++) {
            uint256 id = venueIds[i];
            if (venueLiquidity[id] == 0) continue;

            bytes memory params = _getVenueWithdrawalParams(id, withdrawalParams);
            try this.executeEmergencyExitVenue(id, params) {
                // Successful withdrawals emit WithdrawFromVenue.
            } catch {
                emit EmergencyExitFailed(id);
            }
        }

        emit EmergencyExit(msg.sender);
    }

    /// @notice Atomically configures primary and reference valuation-oracle safeguards.
    /// @dev The two oracle addresses must differ. Both must use token0 as their common numeraire.
    /// @param _priceOracle Primary oracle used for vault accounting.
    /// @param _maxPriceAge Maximum permitted age of the primary price, in seconds.
    /// @param _referencePriceOracle Independent oracle used to validate primary prices.
    /// @param _maxReferencePriceAge Maximum permitted age of reference prices, in seconds.
    /// @param _maxPriceDeviationBps Maximum primary/reference deviation allowed, in basis points.
    function setPriceOracleConfig(
        address _priceOracle,
        uint256 _maxPriceAge,
        address _referencePriceOracle,
        uint256 _maxReferencePriceAge,
        uint256 _maxPriceDeviationBps
    ) external onlyOwner {
        if (_priceOracle == address(0) || _referencePriceOracle == address(0)) revert ZeroAddress();
        if (_priceOracle == _referencePriceOracle) revert InvalidOracleConfiguration();
        if (_maxPriceAge == 0 || _maxReferencePriceAge == 0) revert InvalidMaxPriceAge();
        if (_maxPriceDeviationBps == 0 || _maxPriceDeviationBps > RebalanceTypes.BPS) revert InvalidMaxPriceDeviationBps();

        priceOracle = IPriceOracle(_priceOracle);
        maxPriceAge = _maxPriceAge;
        referencePriceOracle = IPriceOracle(_referencePriceOracle);
        maxReferencePriceAge = _maxReferencePriceAge;
        maxPriceDeviationBps = _maxPriceDeviationBps;
        emit SetPriceOracleConfig(
            _priceOracle,
            _referencePriceOracle,
            _maxPriceAge,
            _maxReferencePriceAge,
            _maxPriceDeviationBps
        );
    }

    /// @notice Sets the volatility oracle used by strategy rebalance guards.
    /// @dev Replacing the oracle invalidates the previous volatility baseline because oracle methodologies may differ.
    /// @param _volatilityOracle Address of the volatility oracle contract.
    function setVolatilityOracle(address _volatilityOracle) external onlyOwner {
        if (_volatilityOracle == address(0)) {
            revert ZeroAddress();
        }
        volatilityOracle = IVolatilityOracle(_volatilityOracle);

        // Values reported by the previous oracle are not valid baselines for the newly configured oracle.
        volatilityBaselineInitialized = false;
        lastRebalanceVolatilityBps = 0;

        emit SetVolatilityOracle(_volatilityOracle);
    }

    /// @notice Sets the strategy used to build rebalance targets.
    /// @param _strategy Strategy contract address.
    function setStrategy(address _strategy) external onlyOwner {
        if (_strategy == address(0)) {
            revert ZeroAddress();
        }
        strategy = IRebalanceStrategy(_strategy);
        emit SetStrategy(_strategy);
    }

    /// @notice Sets the keeper allowed to execute strategy-driven rebalances.
    /// @param _keeper Keeper address.
    function setKeeper(address _keeper) external onlyOwner {
        if (_keeper == address(0)) {
            revert ZeroAddress();
        }

        keeper = _keeper;
        emit SetKeeper(_keeper);
    }

    /// @notice Sets cooldown, volatility delta, and gas price guards for strategy-driven rebalances.
    /// @dev Enabling or disabling the volatility delta guard invalidates the previous baseline.
    /// @param _minCooldown Minimum time between successful strategy-driven rebalances.
    /// @param _minVolatilityDelta Minimum volatility change required, or zero to disable.
    /// @param _maxGasPrice Maximum allowed transaction gas price, or zero to disable.
    function setRebalanceConfig(uint256 _minCooldown, uint256 _minVolatilityDelta, uint256 _maxGasPrice) external onlyOwner {
        bool volatilityGuardToggled = (rebalanceConfig.minVolatilityDelta == 0) != (_minVolatilityDelta == 0);
        if (volatilityGuardToggled) {
            volatilityBaselineInitialized = false;
            lastRebalanceVolatilityBps = 0;
        }

        rebalanceConfig = RebalanceConfig({
            minCooldown: _minCooldown,
            minVolatilityDelta: _minVolatilityDelta,
            maxGasPrice: _maxGasPrice
        });
        emit SetRebalanceConfig(_minCooldown, _minVolatilityDelta, _maxGasPrice);
    }

    /// @notice Sets the maximum total-value loss allowed during rebalance.
    /// @dev A value of zero disables the value-loss guard. Values are expressed in basis points.
    /// @param _maxRebalanceValueLossBps Maximum allowed rebalance value loss in basis points.
    function setMaxRebalanceValueLossBps(uint256 _maxRebalanceValueLossBps) external onlyOwner {
        if (_maxRebalanceValueLossBps > RebalanceTypes.BPS) revert InvalidBps();
        maxRebalanceValueLossBps = _maxRebalanceValueLossBps;
        emit SetMaxRebalanceValueLossBps(_maxRebalanceValueLossBps);
    }

    /// @notice Sets the minimum vault value that must remain idle.
    /// @dev Increasing the requirement does not withdraw active positions; it reports any resulting
    ///      deficit through `getIdleBufferState()` and blocks deployments that would violate the buffer.
    /// @param newBufferBps Minimum idle allocation in basis points.
    function setMinIdleBufferBps(uint256 newBufferBps) external onlyOwner {
        if (newBufferBps > RebalanceTypes.BPS) revert InvalidBps();
        minIdleBufferBps = newBufferBps;
        emit SetMinIdleBufferBps(newBufferBps);
    }

    /// @notice Toggles the volatility-oracle health requirement for strategy-driven rebalances.
    /// @dev When enabled, `rebalanceWithStrategy` requires a configured volatility oracle even if delta guards are disabled.
    /// @param enabled Whether the oracle health check is enabled.
    function setOracleHealthCheckEnabled(bool enabled) external onlyOwner {
        oracleHealthCheckEnabled = enabled;
        emit SetOracleHealthCheckEnabled(enabled);
    }

    /// @notice Updates the recipient and annual rate used for future management-fee accrual.
    /// @dev Accrues the prior configuration first, so elapsed fees cannot be redirected to a new recipient.
    /// @param recipient Address receiving newly minted fee shares; required when the rate is nonzero.
    /// @param annualFeeBps Annual fee rate in basis points, capped by `MAX_MANAGEMENT_FEE_BPS`.
    function setManagementFeeConfig(address recipient, uint256 annualFeeBps) external onlyOwner whenNoRedemptionProcessing {
        if (annualFeeBps > MAX_MANAGEMENT_FEE_BPS) revert InvalidBps();
        if (annualFeeBps != 0 && recipient == address(0)) revert ZeroAddress();

        // Settle the prior recipient and rate before replacing this configuration.
        _accrueManagementFee();
        managementFeeConfig.recipient = recipient;
        managementFeeConfig.annualFeeBps = uint16(annualFeeBps);
        emit SetManagementFeeConfig(recipient, annualFeeBps);
    }

    /// @notice Isolates an impaired venue, disables new deployment, and applies an accounting write-down.
    /// @dev Pauses normal vault operations. A zero valuation excludes the venue from `totalAssets()` without
    ///      querying its adapter or valuator, while recovery withdrawals remain available.
    /// @param _venueId Registered venue to quarantine.
    /// @param _valuationBps Percentage of the venue-reported value recognized in NAV.
    function quarantineVenue(uint256 _venueId, uint256 _valuationBps) external onlyOwner {
        if (!venueRegistered[_venueId]) revert VenueNotSet();
        if (venueQuarantined[_venueId]) revert VenueAlreadyQuarantined();
        if (_valuationBps > RebalanceTypes.BPS) revert InvalidBps();

        venueQuarantined[_venueId] = true;
        venueValuationBps[_venueId] = _valuationBps;
        venues[_venueId].enabled = false;
        quarantinedVenueCount++;

        if (!paused()) {
            _pause();
        }

        emit VenueQuarantined(_venueId, _valuationBps);
    }

    /// @notice Removes a venue from quarantine and restores its recognized value to 100%.
    /// @dev Does not unpause the vault; the owner must separately resume operations after all venues are restored.
    /// @param _venueId Quarantined venue to restore.
    /// @param deploymentEnabled Whether new deployment to the restored venue should be enabled.
    function restoreVenue(uint256 _venueId, bool deploymentEnabled) external onlyOwner {
        if (!venueRegistered[_venueId]) revert VenueNotSet();
        if (!venueQuarantined[_venueId]) revert VenueNotQuarantined();

        venueQuarantined[_venueId] = false;
        venueValuationBps[_venueId] = RebalanceTypes.BPS;
        venues[_venueId].enabled = deploymentEnabled;
        quarantinedVenueCount--;

        emit VenueRestored(_venueId, deploymentEnabled);
    }

    /// @notice Updates the accounting value recognized for a quarantined venue.
    /// @param _venueId Quarantined venue whose write-down is being updated.
    /// @param newValuationBps New recognized percentage of the venue-reported value.
    function setQuarantinedVenueValuationBps(uint256 _venueId, uint256 newValuationBps) external onlyOwner {
        if (!venueRegistered[_venueId]) revert VenueNotSet();
        if (!venueQuarantined[_venueId]) revert VenueNotQuarantined();
        if (newValuationBps > RebalanceTypes.BPS) revert InvalidBps();

        uint256 oldValuationBps = venueValuationBps[_venueId];
        venueValuationBps[_venueId] = newValuationBps;

        emit VenueValuationBpsUpdated(_venueId, oldValuationBps, newValuationBps);
    }

    /// @notice Registers or updates a venue adapter.
    /// @dev Existing venues can only be updated when the venue has no tracked liquidity and no adapter-reported position.
    /// @param _venueId Caller-defined venue id.
    /// @param _adapter Adapter contract for the venue.
    /// @param _label Optional bytes32 venue label.
    /// @param _enabled Whether deployments to the venue are enabled.
    function setVenue(uint256 _venueId, address _adapter, bytes32 _label, bool _enabled) external onlyOwner {
        if (_adapter == address(0)) {
            revert ZeroAddress();
        }

        if (venueRegistered[_venueId]) {
            if (venueQuarantined[_venueId]) {
                revert VenueAlreadyQuarantined();
            }

            VenueConfig storage currentVenue = venues[_venueId];
            if (venueLiquidity[_venueId] != 0 || 
                (address(currentVenue.adapter) != address(0) && currentVenue.adapter.hasPosition())
            ) {
                revert ActivePositionExists();
            }

            if (address(currentVenue.adapter) != _adapter) {
                delete venueValuators[_venueId];
                emit SetVenueValuator(_venueId, address(0));
            }
        } else {
            venueRegistered[_venueId] = true;
            venueIds.push(_venueId);
            venueValuationBps[_venueId] = RebalanceTypes.BPS;
        }

        venues[_venueId] = VenueConfig({
            adapter: IVenueAdapter(_adapter),
            enabled: _enabled,
            label: _label
        });

        emit SetVenue(_venueId, _adapter, _label, _enabled);
    }

    /// @notice Removes a disabled venue with no tracked or adapter-reported position.
    /// @dev Clears the venue configuration, registration state, tracked liquidity, and valuator.
    ///      Removing a venue may change the ordering of `venueIds`.
    /// @param _venueId Registered venue id to remove.
    function removeVenue(uint256 _venueId) external onlyOwner {
        if (!venueRegistered[_venueId]) revert VenueNotSet();

        VenueConfig storage currentVenue = venues[_venueId];
        address adapter = address(currentVenue.adapter);

        if (venueLiquidity[_venueId] != 0 || (adapter != address(0) && currentVenue.adapter.hasPosition())) {
            revert ActivePositionExists();
        }

        if (currentVenue.enabled) revert VenueMustBeDisabled();

        if (venueQuarantined[_venueId]) {
            quarantinedVenueCount--;
        }

        _removeVenueId(_venueId);
        delete venues[_venueId];
        delete venueRegistered[_venueId];
        delete venueLiquidity[_venueId];
        delete venueValuators[_venueId];
        delete venueQuarantined[_venueId];
        delete venueValuationBps[_venueId];

        emit RemoveVenue(_venueId, adapter);
    }

    /// @notice Configures the trusted accounting valuator for a registered venue.
    /// @dev The valuator must declare the venue's current adapter, preventing stale or cross-venue configuration.
    /// @param _venueId Registered venue whose active position will be valued.
    /// @param _valuator Valuator contract bound to the venue's current adapter.
    function setVenueValuator(uint256 _venueId, address _valuator) external onlyOwner {
        if (!venueRegistered[_venueId]) revert VenueNotSet();
        if (_valuator == address(0)) revert ZeroAddress();

        IVenueValuator configuredValuator = IVenueValuator(_valuator);
        if (configuredValuator.getVenueAdapter() != address(venues[_venueId].adapter)) {
            revert ValuatorAdapterMismatch();
        }
        venueValuators[_venueId] = configuredValuator;

        emit SetVenueValuator(_venueId, _valuator);
    }

    /// @notice Deploys idle vault funds into a registered venue adapter.
    /// @dev This is the public owner-only venue entrypoint and delegates to the shared internal helper.
    /// @param venueId Registered venue id to deploy into.
    /// @param amount0 Raw token0 amount the vault attempts to deploy.
    /// @param amount1 Raw token1 amount the vault attempts to deploy.
    /// @param params Venue-specific encoded parameters forwarded to the adapter.
    /// @return liquidity Venue liquidity amount reported by the adapter.
    function deployToVenue(
        uint256 venueId,
        uint256 amount0, 
        uint256 amount1,
        bytes calldata params
    ) external onlyOwner whenNotPaused nonReentrant returns (uint256 liquidity) {
        return _deployToVenue(venueId, amount0, amount1, params);
    }

    /// @notice Withdraws deployed liquidity from a registered venue adapter back into the vault.
    /// @dev This is the public owner-only venue entrypoint and delegates to the shared internal helper.
    /// @param venueId Registered venue id to withdraw from.
    /// @param liquidity Raw venue liquidity amount to remove.
    /// @param params Venue-specific encoded parameters forwarded to the adapter.
    /// @return amount0Out Raw token0 amount returned to the vault.
    /// @return amount1Out Raw token1 amount returned to the vault.
    function withdrawFromVenue(
        uint256 venueId,
        uint256 liquidity, 
        bytes calldata params
    ) external onlyOwner nonReentrant whenNoRedemptionProcessing returns (
        uint256 amount0Out,
        uint256 amount1Out
    ) {
        return _withdrawFromVenue(venueId, liquidity, params, true);
    }

    /// @notice Collects claimable tokens from one venue into vault idle balances.
    /// @dev Does not remove venue liquidity and remains callable while the vault is paused.
    /// @param venueId Registered venue whose claimable tokens are collected.
    /// @return collected0 Raw token0 amount collected into the vault.
    /// @return collected1 Raw token1 amount collected into the vault.
    function harvestVenueFees(uint256 venueId) external onlyOwnerOrKeeper nonReentrant whenNoRedemptionProcessing returns (uint256 collected0, uint256 collected1) {
        return _collectVenueFees(venueId);
    }

    /// @notice Collects claimable venue tokens and redeploys them into the same venue.
    /// @dev Uses the adapter's existing-position path when available, so a V3 adapter increases its current NFT.
    ///      The caller supplies venue-specific add-liquidity constraints. This operation is disabled while paused.
    /// @param venueId Registered and enabled venue whose claimable tokens are compounded.
    /// @param params Venue-specific encoded add-liquidity parameters.
    /// @return collected0 Raw token0 amount collected before redeployment.
    /// @return collected1 Raw token1 amount collected before redeployment.
    /// @return liquidityAdded Additional liquidity reported by the venue adapter.
    function compoundVenueFees(uint256 venueId, bytes calldata params) external onlyOwnerOrKeeper whenNotPaused nonReentrant whenNoRedemptionProcessing returns (
        uint256 collected0,
        uint256 collected1,
        uint256 liquidityAdded
    ) {
        (collected0, collected1) = _collectVenueFees(venueId);

        if (collected0 == 0 && collected1 == 0) {
            revert NoFeesToCompound();
        }

        liquidityAdded = _deployToVenue(venueId, collected0, collected1, params);

        emit FeeCompounded(venueId, collected0, collected1, liquidityAdded);
    }

    /// @notice Rebalances vault capital according to an owner-supplied target plan.
    /// @dev Requires healthy valuation oracles, then withdraws venue excess and deploys only target deficits.
    ///      Removed, zero-target, and structurally incompatible venues are fully withdrawn.
    ///      An empty target array means withdraw all venues to idle.
    /// @param targets Desired post-rebalance venue deployments.
    /// @param withdrawalParams Venue-specific remove-liquidity params used when rebalance withdraws active positions.
    function rebalance(
        RebalanceTypes.RebalanceTarget[] calldata targets,
        VenueWithdrawalParams[] calldata withdrawalParams
    ) external onlyOwner whenNotPaused nonReentrant whenNoRedemptionProcessing {
        _checkValuationOracleGuards();
        // Settle elapsed fees before the rebalance snapshots share-supply-sensitive accounting.
        _accrueManagementFee();
        _rebalance(targets, withdrawalParams);
        emit Rebalance(msg.sender);
    }

    /// @notice Builds a target plan from the configured strategy and executes it.
    /// @dev Strategy-built targets control deployment params; withdrawalParams control venue exits.
    /// @param data Opaque strategy-specific data forwarded to `buildTargets`.
    /// @param withdrawalParams Venue-specific remove-liquidity params used when strategy rebalance withdraws active positions.
    function rebalanceWithStrategy(
        bytes calldata data,
        VenueWithdrawalParams[] calldata withdrawalParams
    ) external onlyOwnerOrKeeper whenNotPaused nonReentrant whenNoRedemptionProcessing {
        if (address(strategy) == address(0)) revert StrategyNotSet();

        uint256 currentVolatilityBps = _checkStrategyRebalanceGuards();

        // Settle elapsed fees before strategy planning and rebalance execution.
        _accrueManagementFee();

        RebalanceTypes.RebalanceTarget[] memory targets = strategy.buildTargets(address(this), data);

        _rebalance(targets, withdrawalParams);
        lastRebalance = block.timestamp;

        if (rebalanceConfig.minVolatilityDelta != 0) {
            // A baseline becomes valid only after the guarded rebalance completes successfully.
            lastRebalanceVolatilityBps = currentVolatilityBps;
            volatilityBaselineInitialized = true;
        }

        emit RebalanceWithStrategy(msg.sender, address(strategy), data);
    }

    /// @notice Configures the redemption manager used for asynchronous redemption.
    /// @dev This one-time setting prevents replacing the contract that can settle escrowed shares.
    function setRedemptionManager(address manager) external onlyOwner {
        if (manager == address(0)) revert ZeroAddress();
        if (manager.code.length == 0) revert InvalidRedemptionManager();
        if (redemptionManager != address(0)) revert RedemptionManagerAlreadySet();

        redemptionManager = manager;
        emit SetRedemptionManager(manager);
    }

    // ============================================
    // Internal Functions
    // ============================================
    /// @notice Removes a venue id from the iterable registry using swap-and-pop.
    /// @dev Reverts if registration state and the iterable venue list are inconsistent.
    /// @param _venueId Registered venue id to remove.
    function _removeVenueId(uint256 _venueId) internal {
        uint256 length = venueIds.length;

        for (uint256 i = 0; i < length; i++) {
            if (venueIds[i] != _venueId) continue;

            uint256 lastIndex = length - 1;
            if (i != lastIndex) {
                venueIds[i] = venueIds[lastIndex];
            }
            venueIds.pop();
            return;
        }
        revert VenueRegistryInconsistent(_venueId);
    }

    /// @notice Returns matching withdrawal params for a venue, or empty bytes when none are supplied.
    function _getVenueWithdrawalParams(
        uint256 venueId,
        VenueWithdrawalParams[] memory withdrawalParams
    ) internal pure returns (bytes memory) {
        for (uint256 i = 0; i < withdrawalParams.length; i++) {
            if (withdrawalParams[i].venueId == venueId) {
                return withdrawalParams[i].params;
            }
        }

        return "";
    }

    /// @notice Returns whether the valuation oracle timestamp is configured and fresh.
    function _isOracleFresh(IPriceOracle oracle, uint256 allowedAge) internal view returns (bool) {
        if (address(oracle) == address(0) || allowedAge == 0) return false;

        uint256 updatedTimestamp;
        try oracle.lastUpdatedAt() returns (uint256 timestamp) {
            updatedTimestamp = timestamp;
        } catch {
            return false;
        }

        uint256 currentTimestamp = block.timestamp;
        if (updatedTimestamp == 0 || updatedTimestamp > currentTimestamp) {
            return false;
        }

        return (currentTimestamp - updatedTimestamp <= allowedAge);
    }

    /// @notice Reads non-zero oracle prices and enforces the configured freshness window.
    /// @param oracle Oracle whose prices and timestamp are validated.
    /// @param allowedAge Maximum permitted age of the current price snapshot, in seconds.
    /// @return price0 Price of one whole token0 in token0, scaled by 1e18.
    /// @return price1 Price of one whole token1 in token0, scaled by 1e18.
    function _readFreshPrices(
        IPriceOracle oracle,
        uint256 allowedAge
    ) internal view returns (uint256 price0, uint256 price1) {
        (price0, price1) = oracle.getPrices();
        if (price0 == 0) revert InvalidOraclePrice(address(oracle), 0);
        if (price1 == 0) revert InvalidOraclePrice(address(oracle), 1);

        uint256 updatedTimestamp = oracle.lastUpdatedAt();
        uint256 currentTimestamp = block.timestamp;

        if (updatedTimestamp == 0 || updatedTimestamp > currentTimestamp) {
            revert InvalidOracleTimestamp(address(oracle), updatedTimestamp, currentTimestamp);
        }

        if (currentTimestamp - updatedTimestamp > allowedAge) {
            revert StalePrice(address(oracle), updatedTimestamp, currentTimestamp);
        }
    }

    /// @notice Calculates absolute primary/reference price deviation relative to the reference price.
    function _calculatePriceDeviationBps(uint256 primaryPrice, uint256 referencePrice) internal pure returns (uint256) {
        uint256 delta = _absDiff(primaryPrice, referencePrice);
        return Math.mulDiv(delta, RebalanceTypes.BPS, referencePrice);
    }

    /// @notice Returns whether both oracle price pairs are valid and within the configured deviation.
    /// @dev Converts oracle call failures and zero prices into status values instead of reverting.
    function _getPriceDeviationStatus() internal view returns (bool pricesValid, bool withinLimit) {
        uint256 primaryPrice0;
        uint256 primaryPrice1;
        uint256 referencePrice0;
        uint256 referencePrice1;

        try priceOracle.getPrices() returns (uint256 price0, uint256 price1) {
            primaryPrice0 = price0;
            primaryPrice1 = price1;
        } catch {
            return (false, false);
        }

        try referencePriceOracle.getPrices() returns (uint256 price0, uint256 price1) {
            referencePrice0 = price0;
            referencePrice1 = price1;
        } catch {
            return (false, false);
        }

        if (primaryPrice0 == 0 || primaryPrice1 == 0 || referencePrice0 == 0 || referencePrice1 == 0) {
            return (false, false);
        }

        withinLimit = _calculatePriceDeviationBps(primaryPrice0, referencePrice0) <= maxPriceDeviationBps &&
            _calculatePriceDeviationBps(primaryPrice1, referencePrice1) <= maxPriceDeviationBps;

        return (true, withinLimit);
    }

    /// @notice Maps valuation-oracle freshness and deviation checks to the public health status.
    function _getValuationOracleStatus() internal view returns (SystemStatus) {
        if (!_isOracleFresh(priceOracle, maxPriceAge) || !_isOracleFresh(referencePriceOracle, maxReferencePriceAge)) {
            return SystemStatus.ORACLE_STALE;
        }

        (bool pricesValid, bool withinDeviationLimit) = _getPriceDeviationStatus();

        if (!pricesValid) {
            return SystemStatus.ORACLE_STALE;
        }

        if (!withinDeviationLimit) {
            return SystemStatus.ORACLE_DEVIATION;
        }

        return SystemStatus.NORMAL;
    }

    /// @notice Reverts when valuation oracles are stale, invalid, or outside the deviation limit.
    function _checkValuationOracleGuards() internal view {
        SystemStatus status = _getValuationOracleStatus();

        if (status == SystemStatus.ORACLE_STALE) {
            revert ValuationOracleStale();
        }

        if (status == SystemStatus.ORACLE_DEVIATION) {
            revert ValuationOracleDeviation();
        }
    }

    /// @notice Returns primary valuation prices after freshness and reference-deviation validation.
    /// @return price0 Price of one whole token0 in token0, scaled by 1e18.
    /// @return price1 Price of one whole token1 in token0, scaled by 1e18.
    function _getValidatedPrices() internal view returns (uint256 price0, uint256 price1) {
        if (address(priceOracle) == address(0)) revert PriceOracleNotSet();
        if (address(referencePriceOracle) == address(0)) revert ReferencePriceOracleNotSet();

        (price0, price1) = _readFreshPrices(priceOracle, maxPriceAge);
        (uint256 referencePrice0, uint256 referencePrice1) = _readFreshPrices(referencePriceOracle, maxReferencePriceAge);

        uint256 deviation0 = _calculatePriceDeviationBps(price0, referencePrice0);
        if (deviation0 > maxPriceDeviationBps){
            revert ExcessivePriceDeviation(0, deviation0, maxPriceDeviationBps);
        }

        uint256 deviation1 = _calculatePriceDeviationBps(price1, referencePrice1);
        if (deviation1 > maxPriceDeviationBps){
            revert ExcessivePriceDeviation(1, deviation1, maxPriceDeviationBps);
        }
    }

    /// @notice Values idle balances and active venue positions using trusted accounting valuators.
    /// @dev Every active position with a non-zero recognized value must have a valuator bound to its current adapter.
    ///      Quarantined venue values are multiplied by their configured recognition percentage.
    function _totalAssetsAtPrices(uint256 price0, uint256 price1) internal view returns (uint256 totalValue) {
        // Idle tokens do not depend on AMM pool state and can be valued directly.
        totalValue = VaultMath.getAssetsTotalValue(
            token0.balanceOf(address(this)),
            price0,
            decimals0,
            token1.balanceOf(address(this)),
            price1,
            decimals1
        );

        for (uint256 i = 0; i < venueIds.length; i++) {
            uint256 venueId = venueIds[i];
            uint256 valuationBps = venueValuationBps[venueId];
            if (valuationBps == 0) continue;

            IVenueAdapter adapter = venues[venueId].adapter;
            if (address(adapter) == address(0)) continue;
            if (!adapter.hasPosition()) continue;

            IVenueValuator valuator = venueValuators[venueId];
            if (address(valuator) == address(0)) {
                revert VenueValuatorNotSet(venueId);
            }

            uint256 venueValue = valuator.getValueInBase(price0, price1);
            totalValue += Math.mulDiv(venueValue, valuationBps, RebalanceTypes.BPS);
        }
    }

    /// @notice Values a share claim and the vault's current idle balances using the same validated prices.
    function _getRedeemLiquidityState(uint256 shares, uint256 totalShares) internal view returns (
        uint256 redeemValue,
        uint256 idleValue,
        uint256 idle0,
        uint256 idle1
    ) {
        (uint256 price0, uint256 price1) = _getValidatedPrices();
        uint256 totalValue = _totalAssetsAtPrices(price0, price1);

        redeemValue = Math.mulDiv(totalValue, shares, totalShares);
        if (redeemValue == 0) revert RedeemAmountTooSmall();

        idle0 = token0.balanceOf(address(this));
        idle1 = token1.balanceOf(address(this));
        idleValue = VaultMath.getAssetsTotalValue(idle0, price0, decimals0, idle1, price1, decimals1);
    }

    /// @notice Quotes an idle-only redemption using validated valuation prices.
    /// @dev Pays the claim using the current idle token composition without removing venue liquidity.
    function _quoteIdleRedeem(uint256 shares, uint256 totalShares) internal view returns (
        uint256 amount0Out,
        uint256 amount1Out
    ) {
        (uint256 redeemValue, uint256 idleValue, uint256 idle0, uint256 idle1) = _getRedeemLiquidityState(shares, totalShares);

        if (redeemValue > idleValue) revert InsufficientIdleLiquidity(redeemValue, idleValue);

        amount0Out = Math.mulDiv(idle0, redeemValue, idleValue);
        amount1Out = Math.mulDiv(idle1, redeemValue, idleValue);
        if (amount0Out == 0 && amount1Out == 0) {
            revert RedeemAmountTooSmall();
        }
    }

    /// @dev Reads the manager-owned processing state without duplicating it in vault storage.
    function _isRedemptionProcessing() internal view returns (bool) {
        return redemptionManager != address(0) && IRedemptionManager(redemptionManager).isProcessing();
    }

    /// @dev Values the idle balances that would remain after a proposed deployment.
    ///      Requested deployment amounts are used conservatively before the adapter returns any dust.
    function _getIdleBufferValuesAfterDeployment(
        uint256 amount0ToDeploy,
        uint256 amount1ToDeploy
    ) internal view returns (
        uint256 idleValueAfter,
        uint256 requiredIdleValue
    ) {
        uint256 idle0 = token0.balanceOf(address(this));
        uint256 idle1 = token1.balanceOf(address(this));
        if (amount0ToDeploy > idle0 || amount1ToDeploy > idle1) {
            revert InsufficientBalances();
        }

        (uint256 price0, uint256 price1) = _getValidatedPrices();
        uint256 totalValue = _totalAssetsAtPrices(price0, price1);
        requiredIdleValue = Math.mulDiv(totalValue, minIdleBufferBps, RebalanceTypes.BPS, Math.Rounding.Ceil);

        idleValueAfter = VaultMath.getAssetsTotalValue(
            idle0 - amount0ToDeploy, price0, decimals0,
            idle1 - amount1ToDeploy, price1, decimals1
        );
    }

    /// @dev Splits current idle value into deployable excess or a buffer deficit.
    function _getIdleBufferState() internal view returns (
        uint256 idleValue,
        uint256 requiredIdleValue,
        uint256 availableToDeployValue,
        uint256 bufferDeficit
    ) {
        (idleValue, requiredIdleValue) = _getIdleBufferValuesAfterDeployment(0, 0);

        if (idleValue >= requiredIdleValue) {
            availableToDeployValue = idleValue - requiredIdleValue;
        } else {
            bufferDeficit = requiredIdleValue - idleValue;
        }
    }

    /// @dev Reverts when a proposed deployment would consume the required idle buffer.
    function _validateIdleBufferForDeployment(
        uint256 amount0ToDeploy,
        uint256 amount1ToDeploy
    ) internal view {
        if (minIdleBufferBps == 0) return;

        (uint256 idleValueAfter, uint256 requiredIdleValue) =
            _getIdleBufferValuesAfterDeployment(amount0ToDeploy, amount1ToDeploy);

        if (idleValueAfter < requiredIdleValue) {
            revert IdleBufferViolation(requiredIdleValue, idleValueAfter);
        }
    }

    /// @notice Sums idle token balances and adapter-reported deployed amounts.
    /// @dev This amount view is intended for strategy planning and reporting, not vault share pricing.
    function _getTotalUnderlying() internal view returns (uint256 total0, uint256 total1) {
        total0 = token0.balanceOf(address(this));
        total1 = token1.balanceOf(address(this));

        for (uint256 i = 0; i < venueIds.length; i++) {
            uint256 venueId = venueIds[i];
            VenueConfig storage v = venues[venueId];
            if (address(v.adapter) == address(0)) continue;
            (uint256 amount0, uint256 amount1) = v.adapter.getPositionValue();
            total0 += amount0;
            total1 += amount1;
        }
    }

    /// @notice Returns whether any registered venue adapter reports an active position.
    function _anyVenueHasPosition() internal view returns (bool) {
        for (uint256 i = 0; i < venueIds.length; i++) {
            uint256 venueId = venueIds[i];
            VenueConfig storage v = venues[venueId];
            if (address(v.adapter) != address(0) && v.adapter.hasPosition()) {
                return true;
            }
        }
        return false;
    }

    /// @notice Accrues a capped interval of management fees through share dilution.
    /// @dev The first call only establishes a timestamp. Later calls charge at most
    ///      `MANAGEMENT_FEE_YEAR`; elapsed time older than that cap is waived.
    /// @return feeShares Vault shares minted to the configured recipient.
    function _accrueManagementFee() internal returns (uint256 feeShares) {
        uint256 lastAccrual = managementFeeConfig.lastAccrual;
        if (lastAccrual == 0) {
            managementFeeConfig.lastAccrual = uint64(block.timestamp);
            return 0;
        }

        uint256 elapsed = block.timestamp - lastAccrual;
        if (elapsed == 0) return 0;

        uint256 accrualPeriod = Math.min(elapsed, MANAGEMENT_FEE_YEAR);
        // A single accrual charges no more than one year; any older elapsed time is waived.
        managementFeeConfig.lastAccrual = uint64(block.timestamp);

        uint256 supply = totalSupply();
        if (supply == 0 || managementFeeConfig.annualFeeBps == 0 || managementFeeConfig.recipient == address(0)) {
            return 0;
        }

        uint256 feeFractionWad = Math.mulDiv(
            uint256(managementFeeConfig.annualFeeBps),
            accrualPeriod * WAD,
            RebalanceTypes.BPS * MANAGEMENT_FEE_YEAR
        );

        feeShares = Math.mulDiv(supply, feeFractionWad, WAD - feeFractionWad);
        if (feeShares == 0) return 0;

        _mint(managementFeeConfig.recipient, feeShares);

        emit ManagementFeeAccrued(managementFeeConfig.recipient, feeShares, accrualPeriod);
    }

    /// @notice Shared internal deploy flow for manual deploys and rebalance.
    function _deployToVenue(
        uint256 venueId,
        uint256 amount0, 
        uint256 amount1,
        bytes memory params
    ) internal returns (uint256 liquidity) {
        if (_isRedemptionProcessing()) {
            revert RedeemProcessingActive();
        }

        VenueConfig storage v = venues[venueId];
        if (!venueRegistered[venueId] || address(v.adapter) == address(0)) revert VenueNotSet();
        if (!v.enabled) revert VenueDisabled();
        if (address(venueValuators[venueId]) == address(0)) revert VenueValuatorNotSet(venueId);
        _validateIdleBufferForDeployment(amount0, amount1);

        token0.forceApprove(address(v.adapter), amount0);
        token1.forceApprove(address(v.adapter), amount1);

        liquidity = v.adapter.addLiquidity(amount0, amount1, params);
        venueLiquidity[venueId] += liquidity;
        totalLiquidity += liquidity;

        token0.forceApprove(address(v.adapter), 0);
        token1.forceApprove(address(v.adapter), 0);

        emit DeployToVenue(venueId, amount0, amount1, liquidity);
    }

    /// @notice Collects claimable tokens from a registered venue into vault idle balances.
    /// @dev A venue with no active position returns zero without calling its adapter. Disabled venues remain
    ///      harvestable so existing assets can still be recovered.
    function _collectVenueFees(uint256 venueId) internal returns(uint256 collected0, uint256 collected1) {
        VenueConfig storage v = venues[venueId];
        if (!venueRegistered[venueId] || address(v.adapter) == address(0)) revert VenueNotSet();

        // Avoid calling adapters such as V3 when no active liquidity or owed tokens exist.
        if (!v.adapter.hasPosition()) {
            return (0, 0);
        }

        (collected0, collected1) = v.adapter.collectFees();

        emit FeeHarvested(venueId, collected0, collected1);
    }

    /// @notice Collects claimable tokens from every registered venue.
    /// @dev Used before delta rebalance so claimable tokens participate in the same target-allocation flow.
    function _collectAllVenueFees() internal returns (uint256 totalCollected0, uint256 totalCollected1) {
        for (uint256 i = 0; i < venueIds.length; i++) {
            (uint256 collected0, uint256 collected1) = _collectVenueFees(venueIds[i]);
            totalCollected0 += collected0;
            totalCollected1 += collected1;
        }
    }

    /// @notice Shared internal withdraw flow for manual withdrawals, rebalances, and emergency exits.
    /// @dev When `collectFeesBeforeRemove` is true, returns collected tokens plus removed liquidity proceeds.
    ///      Delta rebalance harvests all venues first and passes false to avoid collecting the same owed tokens twice.
    ///      `params` is forwarded to the adapter as venue-specific exit constraints.
    function _withdrawFromVenue(
        uint256 venueId, 
        uint256 liquidity, 
        bytes memory params,
        bool collectFeesBeforeRemove
    ) internal returns (
        uint256 amount0Out, 
        uint256 amount1Out
    ) {
        VenueConfig storage v = venues[venueId];
        if (!venueRegistered[venueId] || address(v.adapter) == address(0)) revert VenueNotSet();
        if (liquidity == 0) revert ZeroLiquidity();
        if (venueLiquidity[venueId] < liquidity) revert InsufficientLiquidity();

        uint256 fee0;
        uint256 fee1;
        if (collectFeesBeforeRemove) {
            (fee0, fee1) = _collectVenueFees(venueId);
        }

        (uint256 removed0, uint256 removed1) = v.adapter.removeLiquidity(liquidity, params);
        amount0Out = fee0 + removed0;
        amount1Out = fee1 + removed1;

        venueLiquidity[venueId] -= liquidity;
        totalLiquidity -= liquidity;

        emit WithdrawFromVenue(venueId, liquidity, amount0Out, amount1Out);
    }

    /// @notice Reverts if a rebalance plan contains duplicate venue ids.
    function _checkUniqueVenueIds(RebalanceTypes.RebalanceTarget[] memory targets) internal pure {
        uint256 length = targets.length;
    
        if (length < 2) return;
        for (uint256 i = 0; i < length; i++) {
            uint256 preId = targets[i].venueId;
            for (uint256 j = i + 1; j < length; j++) {
                if (preId == targets[j].venueId) {
                    revert DuplicateVenueTarget();
                }
            }
        }
    }

    /// @notice Finds a venue target by id.
    function _findTarget(
        RebalanceTypes.RebalanceTarget[] memory targets,
        uint256 venueId
    ) internal pure returns (bool found, uint256 index) {
        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i].venueId == venueId) {
                return (true, i);
            }
        }

        return (false, 0);
    }

    /// @notice Calculates the proportional liquidity that exceeds a venue's final token targets.
    function _calculateLiquidityToWithdraw(
        uint256 currentLiquidity,
        uint256 current0,
        uint256 current1,
        uint256 target0,
        uint256 target1
    ) internal pure returns (uint256 liquidityToWithdraw) {
        uint256 keepBps = RebalanceTypes.BPS;

        if (current0 > target0) {
            keepBps = Math.min(keepBps, Math.mulDiv(target0, RebalanceTypes.BPS, current0));
        }

        if (current1 > target1) {
            keepBps = Math.min(keepBps, Math.mulDiv(target1, RebalanceTypes.BPS, current1));
        }

        uint256 liquidityToKeep = Math.mulDiv(currentLiquidity, keepBps, RebalanceTypes.BPS);
        liquidityToWithdraw = currentLiquidity - liquidityToKeep;
    }

    /// @notice Reverts if a non-zero rebalance target points to an unset or disabled venue.
    function _validateRebalanceTargets(RebalanceTypes.RebalanceTarget[] memory targets) internal view {
        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i].amount0 == 0 && targets[i].amount1 == 0) {
                continue;
            }

            uint256 venueId = targets[i].venueId;
            VenueConfig storage v = venues[venueId];

            if (!venueRegistered[venueId] || address(v.adapter) == address(0)) {
                revert VenueNotSet();
            }

            if (!v.enabled) {
                revert VenueDisabled();
            }
        }
    }

    // 遍历当前 venue
    //     |
    //     |-- liquidity == 0
    //     |      -> 跳过
    //     |
    //     |-- 不在新 targets
    //     |      -> 全撤
    //     |
    //     |-- 在 targets，但目标为 (0, 0)
    //     |      -> 全撤
    //     |
    //     |-- 在 targets，但 V3 range 不兼容
    //     |      -> 这个 venue 全撤，稍后重建
    //     |
    //     |-- 在 targets，且兼容
    //            |
    //            |-- 当前没有超额
    //            |      -> 不撤
    //            |
    //            |-- 当前存在超额
    //                   -> 只撤超额比例
    /// @notice Withdraws only liquidity that exceeds or conflicts with final venue targets.
    function _withdrawVenueDeltas(
        RebalanceTypes.RebalanceTarget[] memory targets,
        VenueWithdrawalParams[] memory withdrawalParams
    ) internal returns (bool moved) {
        for (uint256 i = 0; i < venueIds.length; i++) {
            uint256 id = venueIds[i];
            uint256 liquidity = venueLiquidity[id];

            if (liquidity == 0) continue;

            (bool found, uint256 index) = _findTarget(targets, id);
            bytes memory removeParams = _getVenueWithdrawalParams(id, withdrawalParams);

            if (!found) {
                _withdrawFromVenue(id, liquidity, removeParams, false);
                moved = true;
                continue;
            }

            RebalanceTypes.RebalanceTarget memory target = targets[index];
            if (target.amount0 == 0 && target.amount1 == 0) {
                _withdrawFromVenue(id, liquidity, removeParams, false);
                moved = true;
                continue;
            }

            IVenueAdapter adapter = venues[id].adapter;
            if (!adapter.isPositionCompatible(target.params)) {
                _withdrawFromVenue(id, liquidity, removeParams, false);
                moved = true;
                continue;
            }

            (uint256 current0, uint256 current1) = adapter.getPositionValue();
            uint256 liquidityToWithdraw = _calculateLiquidityToWithdraw(liquidity, current0, current1, target.amount0, target.amount1);

            if (liquidityToWithdraw == 0) continue;

            _withdrawFromVenue(id, liquidityToWithdraw, removeParams, false);
            moved = true;
        }
    }

    /// @notice Adds only the token deficits required to approach each venue's final target.
    function _deployVenueDeltas(RebalanceTypes.RebalanceTarget[] memory targets) internal returns (bool moved) {
        for (uint256 i = 0; i < targets.length; i++) {
            RebalanceTypes.RebalanceTarget memory target = targets[i];
            if (target.amount0 == 0 && target.amount1 == 0) continue;

            IVenueAdapter adapter = venues[target.venueId].adapter;

            uint256 current0;
            uint256 current1;
            if (adapter.hasPosition()) {
                (current0, current1) = adapter.getPositionValue();
            }

            uint256 add0 = (target.amount0 > current0) ? (target.amount0 - current0) : 0;
            uint256 add1 = (target.amount1 > current1) ? (target.amount1 - current1) : 0;
            if (add0 == 0 && add1 == 0) continue;

            if (add0 > token0.balanceOf(address(this)) || add1 > token1.balanceOf(address(this))) {
                revert InsufficientBalances();
            }

            _deployToVenue(target.venueId, add0, add1, target.params);
            moved = true;
        }
    }

    /// @notice Shared rebalance executor used by manual and strategy-driven entrypoints.
    function _rebalance(
        RebalanceTypes.RebalanceTarget[] memory targets,
        VenueWithdrawalParams[] memory withdrawalParams
    ) internal {
        _checkUniqueVenueIds(targets);
        _validateRebalanceTargets(targets);

        uint256 totalSharesBefore = totalSupply();
        uint256 totalValueBefore;
        if (maxRebalanceValueLossBps != 0) {
            totalValueBefore = totalAssets();
        }

        // Collect claimable venue tokens into idle balances so delta rebalance can redeploy them.
        _collectAllVenueFees();

        bool withdrew = _withdrawVenueDeltas(targets, withdrawalParams);

        bool deployed = _deployVenueDeltas(targets);

        if (!withdrew && !deployed) revert NoRebalanceNeeded();

        _checkRebalanceValueInvariant(totalSharesBefore, totalValueBefore);
    }

    /// @notice Checks that rebalance preserved share supply and did not exceed the configured value-loss guard.
    function _checkRebalanceValueInvariant(uint256 totalSharesBefore, uint256 totalValueBefore) internal view {
        if (totalSupply() != totalSharesBefore) revert RebalanceShareSupplyChanged();

        if (maxRebalanceValueLossBps == 0) return;

        uint256 minRemainValueBps = RebalanceTypes.BPS - maxRebalanceValueLossBps;
        uint256 minValueAfter = totalValueBefore * minRemainValueBps / RebalanceTypes.BPS;
        if (totalAssets() < minValueAfter) revert ExcessiveRebalanceValueLoss();
    }

    /// @notice Checks strategy rebalance guards and returns the current volatility if needed.
    function _checkStrategyRebalanceGuards() internal view returns (uint256 currentVolatilityBps) {
        RebalanceGuardFailure failure;
        (failure, currentVolatilityBps) = _getStrategyRebalanceGuardStatus();
        if (failure == RebalanceGuardFailure.COOLDOWN_NOT_ELAPSED) revert CooldownNotElapsed();
        if (failure == RebalanceGuardFailure.GAS_PRICE_TOO_HIGH) revert GasPriceTooHigh();
        if (failure == RebalanceGuardFailure.VALUATION_ORACLE_STALE) revert ValuationOracleStale();
        if (failure == RebalanceGuardFailure.VALUATION_ORACLE_DEVIATION) revert ValuationOracleDeviation();
        if (failure == RebalanceGuardFailure.VOLATILITY_ORACLE_NOT_SET) revert VolatilityOracleNotSet();
        if (failure == RebalanceGuardFailure.VOLATILITY_DELTA_TOO_SMALL) revert VolatilityDeltaTooSmall();
    }

    /// @notice Returns the current strategy rebalance guard status without reverting.
    function _getStrategyRebalanceGuardStatus() internal view returns (
        RebalanceGuardFailure failure,
        uint256 currentVolatilityBps
    ){
        SystemStatus valuationStatus = _getValuationOracleStatus();
        if (valuationStatus == SystemStatus.ORACLE_STALE) {
            return (RebalanceGuardFailure.VALUATION_ORACLE_STALE, 0);
        }
        if (valuationStatus == SystemStatus.ORACLE_DEVIATION) {
            return (RebalanceGuardFailure.VALUATION_ORACLE_DEVIATION, 0);
        }

        if (lastRebalance != 0 && 
            rebalanceConfig.minCooldown != 0 && 
            block.timestamp < lastRebalance + rebalanceConfig.minCooldown
        ) {
            return (RebalanceGuardFailure.COOLDOWN_NOT_ELAPSED, 0);
        }

        if (rebalanceConfig.maxGasPrice != 0 && tx.gasprice > rebalanceConfig.maxGasPrice) {
            return (RebalanceGuardFailure.GAS_PRICE_TOO_HIGH, 0);
        }

        bool needsVolatilityOracle = rebalanceConfig.minVolatilityDelta != 0 || oracleHealthCheckEnabled;
        if (needsVolatilityOracle) {
            if (address(volatilityOracle) == address(0)) {
                return (RebalanceGuardFailure.VOLATILITY_ORACLE_NOT_SET, 0);
            }

            if (rebalanceConfig.minVolatilityDelta != 0) {
                currentVolatilityBps = volatilityOracle.getVolatilityBps();

                // The first guarded rebalance establishes the baseline instead of comparing against a default zero value.
                if (volatilityBaselineInitialized) {
                    uint256 delta = _absDiff(currentVolatilityBps, lastRebalanceVolatilityBps);
                    if (delta < rebalanceConfig.minVolatilityDelta) {
                        return (RebalanceGuardFailure.VOLATILITY_DELTA_TOO_SMALL, currentVolatilityBps);
                    }
                }
            }
        }

        return (RebalanceGuardFailure.NONE, currentVolatilityBps);
    }

    /// @notice Returns the absolute difference between two values.
    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? (a - b) : (b - a);
    }

}
