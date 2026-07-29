// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../AdaptiveLPVault.sol";
import "../interfaces/IRebalanceStrategy.sol";
import "../interfaces/IVolatilityOracle.sol";
import "../interfaces/ISlippageController.sol";
import "../interfaces/IVenueAdapter.sol";
import "../adapters/UniswapV3Adapter.sol";
import "./V3TickCalculations.sol";

/// @notice Builds total-underlying allocations from configured volatility buckets.
contract VolatilityBucketStrategy is IRebalanceStrategy, Ownable {
    /// @notice Supported volatility ranges.
    enum Bucket {
        LOW,
        MEDIUM,
        HIGH
    }

    /// @notice Volatility source used for bucket selection.
    IVolatilityOracle public immutable volatilityOracle;

    /// @notice Optional controller used to compute V3 add-liquidity minimum amounts.
    ISlippageController public slippageController;

    /// @notice Upper bound of the low-volatility bucket.
    uint256 public lowVolatilityThresholdBps;

    /// @notice Upper bound of the medium-volatility bucket.
    uint256 public highVolatilityThresholdBps;

    /// @notice Venue allocations configured for each bucket.
    mapping(Bucket => RebalanceTypes.TargetConfig[]) public bucketTargets;
    
    /// @notice Optional dynamic V3 tick calculator per venue.
    mapping(uint256 => V3TickCalculations) public v3TickCalculations;

    /// @notice Optional slippage inputs used by the controller for each venue id.
    mapping(uint256 => ISlippageController.SlippageParams) public venueSlippageParams;

    /// @notice Emitted when volatility thresholds are updated.
    event SetThresholds(uint256 lowVolatilityThresholdBps, uint256 highVolatilityThresholdBps);

    /// @notice Emitted when a bucket's venue allocations are replaced.
    event SetBucketTargets(Bucket indexed bucket, uint256 count);

    /// @notice Emitted when a venue's dynamic V3 tick calculator is configured.
    event SetV3TickCalculations(uint256 indexed venueId, address indexed calculator);

    /// @notice Emitted when the slippage controller is configured.
    event SetSlippageController(address indexed controller);

    /// @notice Emitted when a venue's slippage inputs are configured.
    event SetVenueSlippageParams(uint256 indexed venueId, uint256 maxSlippageBps, uint32 twapWindow);
    
    error ZeroAddress();
    error ZeroWeight();
    error InvalidThresholds();
    error InvalidTotalWeight();
    error EmptyTargets();
    error DuplicateVenue();
    error InvalidBps();
    error InvalidTwapWindow();
    error SlippageParamsNotSet();
    error SlippageControllerAdapterMismatch();

    // ============================================
    // Constructor
    // ============================================
    /// @notice Initializes the volatility oracle and bucket thresholds.
    constructor(
        address _volatilityOracle, 
        uint256 lowThresholdBps, 
        uint256 highThresholdBps
    ) Ownable(msg.sender) {
        if (_volatilityOracle == address(0)) revert ZeroAddress();
        volatilityOracle = IVolatilityOracle(_volatilityOracle);

        _setThresholds(lowThresholdBps, highThresholdBps);
    }

    // ============================================
    // View Functions
    // ============================================
    /// @notice Builds a rebalance plan from total vault underlying and the selected volatility bucket.
    /// @dev Extra strategy data is currently unused; the last target receives rounding dust.
    function buildTargets(
        address vault, 
        bytes calldata
    ) external view returns (RebalanceTypes.RebalanceTarget[] memory targets) {
        if (vault == address(0)) revert ZeroAddress();

        AdaptiveLPVault targetVault = AdaptiveLPVault(vault);

        uint256 volatilityBps = volatilityOracle.getVolatilityBps();
        Bucket bucket = getBucket(volatilityBps);
        RebalanceTypes.TargetConfig[] storage configs = bucketTargets[bucket];

        uint256 length = configs.length;
        if (length == 0) revert EmptyTargets();
        targets = new RebalanceTypes.RebalanceTarget[](length);
        
        (uint256 total0, uint256 total1) = targetVault.getTotalUnderlying();

        uint256 used0;
        uint256 used1;
        for(uint256 i = 0; i < length; i++) {
            uint256 amount0;
            uint256 amount1;

            if (i == length - 1) {
                amount0 = total0 - used0;
                amount1 = total1 - used1;
            } else {
                amount0 = total0 * configs[i].weightBps / RebalanceTypes.BPS;
                amount1 = total1 * configs[i].weightBps / RebalanceTypes.BPS;

                used0 += amount0;
                used1 += amount1;
            }
            
            targets[i] = RebalanceTypes.RebalanceTarget({
                venueId: configs[i].venueId,
                amount0: amount0,
                amount1: amount1,
                params: _buildTargetParams(targetVault, configs[i], volatilityBps, amount0, amount1)
            });
        }
    }

    /// @notice Returns the bucket selected for a volatility value.
    function getBucket(uint256 volatilityBps) public view returns (Bucket) {
        if (volatilityBps <= lowVolatilityThresholdBps) return Bucket.LOW;
        if (volatilityBps <= highVolatilityThresholdBps) return Bucket.MEDIUM;
        return Bucket.HIGH;
    }

    /// @notice Returns target configs configured for the current volatility bucket.
    function getRecommendedTargets() external view returns (RebalanceTypes.TargetConfig[] memory targets) {
        uint256 volatilityBps = volatilityOracle.getVolatilityBps();
        Bucket bucket = getBucket(volatilityBps);

        RebalanceTypes.TargetConfig[] storage configs = bucketTargets[bucket];
        uint256 length = configs.length;
        if (length == 0) revert EmptyTargets();

        targets = new RebalanceTypes.TargetConfig[](length);
        for (uint256 i = 0; i < length; i++) {
            targets[i] = configs[i];
        }
    }

    /// @notice Returns the number of configured targets for a bucket.
    function bucketTargetCount(Bucket bucket) external view returns (uint256) {
        return bucketTargets[bucket].length;
    }

    // ============================================
    // Admin Functions
    // ============================================
    /// @notice Updates the volatility bucket thresholds.
    function setThresholds(uint256 lowThresholdBps, uint256 highThresholdBps) external onlyOwner {
        _setThresholds(lowThresholdBps, highThresholdBps);
        emit SetThresholds(lowThresholdBps, highThresholdBps);
    }

    /// @notice Replaces the venue allocations for a bucket.
    function setBucketTargets(Bucket bucket, RebalanceTypes.TargetConfig[] calldata configs) external onlyOwner {
        uint256 length = configs.length;
        if (length == 0) revert EmptyTargets();

        uint256 totalWeight;
        for(uint256 i = 0; i < length; i++) {
            if (configs[i].weightBps == 0) revert ZeroWeight();

            for(uint256 j = i + 1; j < length; j++) {
                if (configs[i].venueId == configs[j].venueId) {
                    revert DuplicateVenue();
                }
            }

            totalWeight += configs[i].weightBps;
        }

        if (totalWeight != RebalanceTypes.BPS) revert InvalidTotalWeight();

        delete bucketTargets[bucket];
        for(uint256 i = 0; i < length; i++) {
            bucketTargets[bucket].push(configs[i]);
        }
        
        emit SetBucketTargets(bucket, length);
    }

    /// @notice Sets the dynamic V3 tick calculator for a venue.
    function setV3TickCalculations(uint256 venueId, address calculator) external onlyOwner {
        if (calculator == address(0)) revert ZeroAddress();
        v3TickCalculations[venueId] = V3TickCalculations(calculator);

        emit SetV3TickCalculations(venueId, calculator);
    }

    /// @notice Sets the optional controller used to compute V3 target minimum amounts.
    function setSlippageController(address controller) external onlyOwner {
        if (controller == address(0)) revert ZeroAddress();
        slippageController = ISlippageController(controller);

        emit SetSlippageController(controller);
    }

    /// @notice Sets slippage inputs for a venue used when the slippage controller is enabled.
    function setVenueSlippageParams(
        uint256 venueId, 
        ISlippageController.SlippageParams calldata params
    ) external onlyOwner {
        if (params.maxSlippageBps > RebalanceTypes.BPS) revert InvalidBps();
        if (params.twapWindow == 0) revert InvalidTwapWindow();
        venueSlippageParams[venueId] = params;
        
        emit SetVenueSlippageParams(venueId, params.maxSlippageBps, params.twapWindow);
    }

    // ============================================
    // Internal Functions
    // ============================================
    /// @notice Validates and stores volatility thresholds.
    function _setThresholds(uint256 lowThresholdBps, uint256 highThresholdBps) internal {
        if (lowThresholdBps >= highThresholdBps) revert InvalidThresholds();

        lowVolatilityThresholdBps = lowThresholdBps;
        highVolatilityThresholdBps = highThresholdBps;
    }

    /// @notice Returns static params or generated dynamic V3 tick and slippage params for a target config.
    function _buildTargetParams(
        AdaptiveLPVault targetVault,
        RebalanceTypes.TargetConfig memory config, 
        uint256 volatilityBps,
        uint256 amount0,
        uint256 amount1
    ) internal view returns (bytes memory) {
        V3TickCalculations calculator = v3TickCalculations[config.venueId];
        if (address(calculator) == address(0)) {
            return config.params;
        }

        (uint256 amount0Min, uint256 amount1Min) = _calculateMinAmounts(targetVault, config.venueId, amount0, amount1);
        (int24 tickLower, int24 tickUpper) = calculator.calculateTickRange(volatilityBps);
        return abi.encode(UniswapV3Adapter.LiquidityParams({
            amount0Min: amount0Min,
            amount1Min: amount1Min,
            deadline: block.timestamp,
            tickLower: tickLower,
            tickUpper: tickUpper
        }));
    }

    /// @notice Returns V3 controller-computed minimum amounts after verifying the vault and controller adapter match.
    /// @dev Returns zero minimums when no slippage controller is configured.
    function _calculateMinAmounts(
        AdaptiveLPVault targetVault,
        uint256 venueId, 
        uint256 amount0, 
        uint256 amount1
    ) internal view returns (uint256, uint256) {
        if (address(slippageController) == address(0)) {
            return (0, 0);
        }

        ISlippageController.SlippageParams memory params = venueSlippageParams[venueId];
        if (params.twapWindow == 0) {
            revert SlippageParamsNotSet();
        }

        (IVenueAdapter vaultAdapter,,) = targetVault.venues(venueId);
        address controllerAdapter = slippageController.venueAdapters(venueId);
        if (address(vaultAdapter) != controllerAdapter) revert SlippageControllerAdapterMismatch();

        return slippageController.calculateMinAmounts(venueId, amount0, amount1, params);
    }
}
