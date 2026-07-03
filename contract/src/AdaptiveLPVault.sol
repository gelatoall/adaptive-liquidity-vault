// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./libraries/VaultMath.sol";
import "./libraries/RebalanceTypes.sol";
import "./interfaces/IVenueAdapter.sol";
import "./interfaces/IPriceOracle.sol";
import "./interfaces/IVolatilityOracle.sol";
import "./interfaces/IRebalanceStrategy.sol";

/// @title AdaptiveLPVault
/// @notice Minimal two-asset vault that mints ERC20 shares against deposited assets.
/// @dev The vault can keep assets idle or deploy them across registered venue adapters.
contract AdaptiveLPVault is ERC20, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

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

    /// @notice Strategy used to build target plans for strategy-driven rebalances.
    IRebalanceStrategy public strategy;

    /// @notice Guard configuration for strategy-driven rebalances.
    RebalanceConfig public rebalanceConfig;

    /// @notice Timestamp of the last successful strategy-driven rebalance.
    uint256 public lastRebalance;

    /// @notice Volatility oracle used by strategy rebalance guards.
    IVolatilityOracle public volatilityOracle;

    /// @notice Volatility recorded after the last successful strategy-driven rebalance.
    uint256 public lastRebalanceVolatilityBps;

    /// @notice Maximum allowed total-value loss during rebalance, in basis points. Zero disables the check.
    uint256 public maxRebalanceValueLossBps;
    
    /// @notice Venue configuration by caller-defined venue id.
    mapping(uint256 => VenueConfig) public venues;

    /// @notice Tracks whether a venue id has been registered.
    mapping(uint256 => bool) public venueRegistered;

    /// @notice Adapter-reported liquidity currently tracked for each venue.
    mapping(uint256 => uint256) public venueLiquidity;
    
    /// @notice List of registered venue ids used for iteration.
    uint256[] public venueIds;

    /// @notice Sum of adapter-reported liquidity across all venues.
    /// @dev This is bookkeeping only. Liquidity units may differ across venues and should not be treated as asset value.
    uint256 public totalLiquidity;

    // ============================================
    // Events
    // ============================================
    /// @notice Emitted when a user deposits assets into the vault.
    event Deposit(address indexed user, uint256 amount0, uint256 amount1);

    /// @notice Emitted when a user redeems vault shares.
    event Redeem(address indexed user, uint256 shares);

    /// @notice Emitted when the owner updates the valuation price oracle.
    event SetPriceOracle(address indexed priceOracle);

    /// @notice Emitted when the owner updates the volatility oracle.
    event SetVolatilityOracle(address indexed volatilityOracle);

    /// @notice Emitted when the owner updates the rebalance strategy.
    event SetStrategy(address indexed strategy);

    /// @notice Emitted when the owner updates strategy rebalance guards.
    event SetRebalanceConfig(uint256 minCooldown, uint256 minVolatilityDelta, uint256 maxGasPrice);

    /// @notice Emitted when the owner registers or updates a venue.
    event SetVenue(uint256 indexed venueId, address indexed adapter, bytes32 label, bool enabled);

    /// @notice Emitted when the owner updates the rebalance value-loss guard.
    event SetMaxRebalanceValueLossBps(uint256 maxRebalanceValueLossBps);

    /// @notice Emitted when the vault deploys idle funds into a venue.
    event DeployToVenue(uint256 indexed venueId, uint256 amount0, uint256 amount1, uint256 liquidity);

    /// @notice Emitted when the vault withdraws venue liquidity back to idle balances.
    event WithdrawFromVenue(uint256 indexed venueId, uint256 liquidity, uint256 amount0Out, uint256 amount1Out);

    /// @notice Emitted after a rebalance plan executes successfully.
    event Rebalance(address indexed caller);

    /// @notice Emitted after a strategy-driven rebalance executes successfully.
    event RebalanceWithStrategy(address indexed caller, address indexed strategy, bytes data);

    /// @notice Emitted after the owner pulls venue liquidity back to idle and pauses the vault.
    event EmergencyExit(address indexed caller);
    
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

    /// @notice Thrown when a caller tries to withdraw more liquidity than tracked for a venue.
    error InsufficientLiquidity();

    /// @notice Thrown when a caller tries to redeem more shares than they own.
    error InsufficientShares();

    /// @notice Thrown when a deployment or rebalance plan requires more idle token balance than available.
    error InsufficientBalances();

    /// @notice Thrown when a valuation or price-dependent operation is requested before an oracle is configured.
    error PriceOracleNotSet();

    /// @notice Thrown when a requested venue id is not registered or has no adapter configured.
    error VenueNotSet();

    /// @notice Thrown when a requested venue is registered but disabled for new deployments.
    error VenueDisabled();

    /// @notice Thrown when an operation is blocked because at least one venue still has an active position.
    error ActivePositionExists();

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

        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
        decimals0 = _decimals0;
        decimals1 = _decimals1;
    }

    // ============================================
    // User Functions
    // ============================================
    /// @notice Deposits token0 and token1 and mints vault shares to the caller.
    /// @dev Deposit flow is token amounts -> normalized asset value -> shares.
    /// @param amount0 Raw token0 amount in token0's smallest unit.
    /// @param amount1 Raw token1 amount in token1's smallest unit.
    /// @return shares Amount of vault shares minted to the depositor.
    function deposit(uint256 amount0, uint256 amount1) external whenNotPaused nonReentrant returns (uint256 shares) {
        // Reject if both deposit amounts are zero.
        if (amount0 == 0 && amount1 == 0) {
            revert ZeroAmounts();
        }

        // Reject if oracle is not configured.
        if (address(priceOracle) == address(0)) {
            revert PriceOracleNotSet();
        }
        (uint256 price0, uint256 price1) = priceOracle.getPrices();

        // Read totalAssets() before the deposit.
        // Read totalSupply() before the deposit.
        uint256 totalAssetsBefore = totalAssets();
        uint256 totalShares = totalSupply();

        // Convert the deposit amounts into a single base-denominated value using VaultMath.
        uint256 assetsToDeposit = VaultMath.getAssetsTotalValue(
            amount0, price0, decimals0, 
            amount1, price1, decimals1
        );

        // Calculate shares to mint using VaultMath.calculateShares.
        shares = VaultMath.calculateShares(assetsToDeposit, totalAssetsBefore, totalShares);

        // Transfer token0 and token1 from the user into the vault.
        IERC20(token0).safeTransferFrom(msg.sender, address(this), amount0);
        IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1);

        // Mint shares to the depositor.
        _mint(msg.sender, shares);

        emit Deposit(msg.sender, amount0, amount1);
    } 

    /// @notice Redeems vault shares for the proportional underlying token balances.
    /// @dev Withdraws the caller's proportional venue liquidity before transferring underlying tokens.
    /// @param shareToRedeem Amount of vault shares to redeem.
    /// @param withdrawalParams Venue-specific remove-liquidity params used when redeem withdraws active positions.
    /// @return amount0Out Raw token0 amount returned to the caller.
    /// @return amount1Out Raw token1 amount returned to the caller.
    function redeem(
        uint256 shareToRedeem,
        VenueWithdrawalParams[] calldata withdrawalParams
    ) external nonReentrant returns (uint256 amount0Out, uint256 amount1Out) {
        // Reject if shares is zero.
        if (shareToRedeem == 0) {
            revert ZeroShares();
        }

        // Revert if the share to redeem exceeds the caller's balance.
        if (shareToRedeem > balanceOf(msg.sender)) {
            revert InsufficientShares();
        }

        // Read totalSupply() before burning.
        uint256 totalSharesBefore = totalSupply();

        // Read the current token0 and token1 balances held by the vault.
        uint256 idle0Before = IERC20(token0).balanceOf(address(this));
        uint256 idle1Before = IERC20(token1).balanceOf(address(this));

        // Compute the proportional token amounts owed to the user.
        amount0Out = shareToRedeem * idle0Before / totalSharesBefore;
        amount1Out = shareToRedeem * idle1Before / totalSharesBefore;

        (uint256 venue0Out, uint256 venue1Out) = _withdrawProportionalVenueLiquidity(
            shareToRedeem,
            totalSharesBefore,
            withdrawalParams
        );
        amount0Out += venue0Out;
        amount1Out += venue1Out;

        // Burn the user's share-to-redeem.
        _burn(msg.sender, shareToRedeem);

        // Transfer token0 and token1 to the user.
        IERC20(token0).safeTransfer(msg.sender, amount0Out);
        IERC20(token1).safeTransfer(msg.sender, amount1Out);

        emit Redeem(msg.sender, shareToRedeem);
    }

    function _withdrawProportionalVenueLiquidity(
        uint256 shares, 
        uint256 totalSharesBefore,
        VenueWithdrawalParams[] calldata withdrawalParams
    ) internal returns (uint256 amount0Out, uint256 amount1Out) {
        for (uint256 i = 0; i < venueIds.length; i++) {
            uint256 id = venueIds[i];
            uint256 liquidity = venueLiquidity[id];
            if (liquidity == 0) continue;

            uint256 liquidityToWithdraw; 
            if (shares == totalSharesBefore) { // Final withdraw
                liquidityToWithdraw = liquidity;
            } else {
                liquidityToWithdraw = liquidity * shares / totalSharesBefore;
            }

            if (liquidityToWithdraw == 0) continue;

            bytes memory params = _getVenueWithdrawalParams(id, withdrawalParams);
            (uint256 venue0Out, uint256 venue1Out) = _withdrawFromVenue(id, liquidityToWithdraw, params);
            amount0Out += venue0Out;
            amount1Out += venue1Out;
        }
    }

    // ============================================
    // View Functions
    // ============================================
    /// @notice Returns the current total value of the vault's holdings.
    /// @dev Includes idle vault balances and adapter-reported deployed underlying amounts for every registered venue.
    /// The returned value is denominated in the base asset and uses 1e18 precision.
    /// @return Total vault asset value using the currently configured mock prices.
    function totalAssets() public view returns (uint256) {
        if (address(priceOracle) == address(0)) {
            revert PriceOracleNotSet();
        }
        (uint256 price0, uint256 price1) = priceOracle.getPrices();

        (uint256 total0, uint256 total1) = _getTotalUnderlying();

        return VaultMath.getAssetsTotalValue(
            total0, price0, decimals0, 
            total1, price1, decimals1
        );
    }

    /// @notice Returns raw token amounts across idle balances and deployed venue positions.
    /// @return total0 Total token0 amount held directly or reported by venues.
    /// @return total1 Total token1 amount held directly or reported by venues.
    function getTotalUnderlying() external view returns (uint256 total0, uint256 total1) {
        (total0, total1) = _getTotalUnderlying();
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
        _unpause();
    }

    /// @notice Withdraws all venue liquidity back to the vault and pauses normal operations.
    /// @dev Can be called even when the vault is already paused. Redeems remain available after emergency exit.
    /// @param withdrawalParams Venue-specific remove-liquidity params used when exiting active positions.
    function emergencyExit(VenueWithdrawalParams[] calldata withdrawalParams) external onlyOwner nonReentrant {
        _withdrawAllVenues(withdrawalParams);
        _pause();

        emit EmergencyExit(msg.sender);
    }

    /// @notice Sets the price oracle used by the vault for asset valuation.
    /// @dev The input address is stored as an `IPriceOracle` interface reference.
    /// @param _priceOracle Address of the price oracle contract.
    function setPriceOracle(address _priceOracle) external onlyOwner {
        if (_priceOracle == address(0)) {
            revert ZeroAddress();
        }
        priceOracle = IPriceOracle(_priceOracle);
        emit SetPriceOracle(_priceOracle);
    }

    /// @notice Sets the volatility oracle used by strategy rebalance guards.
    /// @param _volatilityOracle Address of the volatility oracle contract.
    function setVolatilityOracle(address _volatilityOracle) external onlyOwner {
        if (_volatilityOracle == address(0)) {
            revert ZeroAddress();
        }
        volatilityOracle = IVolatilityOracle(_volatilityOracle);
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

    /// @notice Sets cooldown, volatility delta, and gas price guards for strategy-driven rebalances.
    /// @param _minCooldown Minimum time between successful strategy-driven rebalances.
    /// @param _minVolatilityDelta Minimum volatility change required, or zero to disable.
    /// @param _maxGasPrice Maximum allowed transaction gas price, or zero to disable.
    function setRebalanceConfig(uint256 _minCooldown, uint256 _minVolatilityDelta, uint256 _maxGasPrice) external onlyOwner {
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
            VenueConfig storage currentVenue = venues[_venueId];
            if (venueLiquidity[_venueId] != 0 || 
                (address(currentVenue.adapter) != address(0) && currentVenue.adapter.hasPosition())
            ) {
                revert ActivePositionExists();
            }
        } else {
            venueRegistered[_venueId] = true;
            venueIds.push(_venueId);
        }

        venues[_venueId] = VenueConfig({
            adapter: IVenueAdapter(_adapter),
            enabled: _enabled,
            label: _label
        });

        emit SetVenue(_venueId, _adapter, _label, _enabled);
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
    ) external onlyOwner nonReentrant returns (
        uint256 amount0Out, 
        uint256 amount1Out
    ) {
        return _withdrawFromVenue(venueId, liquidity, params);
    }

    /// @notice Rebalances vault capital according to an owner-supplied target plan.
    /// @dev The current minimal flow withdraws all tracked venue liquidity first, then deploys into non-zero targets.
    /// An empty target array means withdraw all venues to idle. Reverts if the vault is already idle.
    /// @param targets Desired post-rebalance venue deployments.
    /// @param withdrawalParams Venue-specific remove-liquidity params used when rebalance withdraws active positions.
    function rebalance(
        RebalanceTypes.RebalanceTarget[] calldata targets,
        VenueWithdrawalParams[] calldata withdrawalParams
    ) external onlyOwner whenNotPaused nonReentrant {
        _rebalance(targets, withdrawalParams);
        emit Rebalance(msg.sender);
    }

    /// @notice Builds a target plan from the configured strategy and executes it.
    /// @dev Strategy-built targets control deployment params; withdrawal params are empty in this entrypoint for now.
    /// @param data Opaque strategy-specific data forwarded to `buildTargets`.
    function rebalanceWithStrategy(bytes calldata data) external onlyOwner whenNotPaused nonReentrant {
        if (address(strategy) == address(0)) revert StrategyNotSet();

        uint256 currentVolatilityBps = _checkStrategyRebalanceGuards();

        RebalanceTypes.RebalanceTarget[] memory targets = strategy.buildTargets(address(this), data);

        VenueWithdrawalParams[] memory emptyWithdrawalParams = new VenueWithdrawalParams[](0);

        _rebalance(targets, emptyWithdrawalParams);
        lastRebalance = block.timestamp;

        if (rebalanceConfig.minVolatilityDelta != 0) {
            lastRebalanceVolatilityBps = currentVolatilityBps;
        }

        emit RebalanceWithStrategy(msg.sender, address(strategy), data);
    }

    // ============================================
    // Internal Functions
    // ============================================
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

    /// @notice Sums idle token balances and adapter-reported deployed amounts.
    function _getTotalUnderlying() internal view returns (uint256 total0, uint256 total1) {
        total0 = IERC20(token0).balanceOf(address(this));
        total1 = IERC20(token1).balanceOf(address(this));

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

    /// @notice Shared internal deploy flow for manual deploys and rebalance.
    function _deployToVenue(
        uint256 venueId,
        uint256 amount0, 
        uint256 amount1,
        bytes memory params
    ) internal returns (uint256 liquidity) {
        VenueConfig storage v = venues[venueId];
        if (!venueRegistered[venueId] || address(v.adapter) == address(0)) revert VenueNotSet();
        if (!v.enabled) revert VenueDisabled();

        token0.forceApprove(address(v.adapter), amount0);
        token1.forceApprove(address(v.adapter), amount1);

        liquidity = v.adapter.addLiquidity(amount0, amount1, params);
        venueLiquidity[venueId] += liquidity;
        totalLiquidity += liquidity;

        token0.forceApprove(address(v.adapter), 0);
        token1.forceApprove(address(v.adapter), 0);

        emit DeployToVenue(venueId, amount0, amount1, liquidity);
    }

    /// @notice Shared internal withdraw flow for manual withdraws, rebalances, and redemptions.
    /// @dev `params` is forwarded to the venue adapter so each entrypoint can apply venue-specific exit constraints.
    function _withdrawFromVenue(
        uint256 venueId, 
        uint256 liquidity, 
        bytes memory params
    ) internal returns (
        uint256 amount0Out, 
        uint256 amount1Out
    ) {
        VenueConfig storage v = venues[venueId];
        if (!venueRegistered[venueId] || address(v.adapter) == address(0)) revert VenueNotSet();
        if (liquidity == 0) revert ZeroLiquidity();
        if (venueLiquidity[venueId] < liquidity) revert InsufficientLiquidity();

        (amount0Out, amount1Out) = v.adapter.removeLiquidity(liquidity, params);
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

    /// @notice Withdraws all tracked liquidity from every registered venue.
    /// @dev Forwards matching per-venue withdrawal params to adapters; venues with zero tracked liquidity are skipped.
    function _withdrawAllVenues(VenueWithdrawalParams[] memory withdrawalParams) internal {
        for (uint256 i = 0; i < venueIds.length; i++) {
            uint256 id = venueIds[i];
            uint256 liquidity = venueLiquidity[id];
            if (liquidity > 0) {
                bytes memory params = _getVenueWithdrawalParams(id, withdrawalParams);
                _withdrawFromVenue(id, liquidity, params);
            }
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

        uint256 required0;
        uint256 required1;
        for (uint256 i = 0; i < targets.length; i++) {
            required0 += targets[i].amount0;
            required1 += targets[i].amount1;
        }

        // idle -> idle
        if (totalLiquidity == 0 && required0 == 0 && required1 == 0) {
            revert NoRebalanceNeeded();
        }

        // Phase 1: pull all capital back to idle first.
        _withdrawAllVenues(withdrawalParams);

        // Phase 2: redistribute from idle to venues.
        if (targets.length != 0) {
            uint256 idle0 = token0.balanceOf(address(this));
            uint256 idle1 = token1.balanceOf(address(this));

            if (required0 > idle0 || required1 > idle1) {
                revert InsufficientBalances();
            }

            for (uint256 i = 0; i < targets.length; i++) {
                if (targets[i].amount0 == 0 && targets[i].amount1 == 0) continue;
                _deployToVenue(targets[i].venueId, targets[i].amount0, targets[i].amount1, targets[i].params);
            }
        }

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
        if (lastRebalance != 0 && 
            rebalanceConfig.minCooldown != 0 && 
            block.timestamp < lastRebalance + rebalanceConfig.minCooldown
        ) {
            revert CooldownNotElapsed();
        }

        if (rebalanceConfig.maxGasPrice != 0 && tx.gasprice > rebalanceConfig.maxGasPrice) {
            revert GasPriceTooHigh();
        }

        if (rebalanceConfig.minVolatilityDelta != 0) {
            if (address(volatilityOracle) == address(0)) revert VolatilityOracleNotSet();

            currentVolatilityBps = volatilityOracle.getVolatilityBps();
            uint256 delta = _absDiff(currentVolatilityBps, lastRebalanceVolatilityBps);
            if (delta < rebalanceConfig.minVolatilityDelta) revert VolatilityDeltaTooSmall();
        }
    }

    /// @notice Returns the absolute difference between two values.
    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? (a - b) : (b - a);
    }

}
