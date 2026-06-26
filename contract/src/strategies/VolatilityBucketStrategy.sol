// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../AdaptiveLPVault.sol";
import "../interfaces/IRebalanceStrategy.sol";
import "../interfaces/IVolatilityOracle.sol";

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

    /// @notice Upper bound of the low-volatility bucket.
    uint256 public lowVolatilityThresholdBps;

    /// @notice Upper bound of the medium-volatility bucket.
    uint256 public highVolatilityThresholdBps;

    /// @notice Venue allocations configured for each bucket.
    mapping(Bucket => RebalanceTypes.TargetConfig[]) public bucketTargets;

    /// @notice Emitted when volatility thresholds are updated.
    event SetThresholds(uint256 lowVolatilityThresholdBps, uint256 highVolatilityThresholdBps);

    /// @notice Emitted when a bucket's venue allocations are replaced.
    event SetBucketTargets(Bucket indexed bucket, uint256 count);
    
    error ZeroAddress();
    error ZeroWeight();
    error InvalidThresholds();
    error InvalidTotalWeight();
    error EmptyTargets();
    error DuplicateVenue();

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
                params: configs[i].params
            });
        }
    }

    /// @notice Returns the bucket selected for a volatility value.
    function getBucket(uint256 volatilityBps) public view returns (Bucket) {
        if (volatilityBps <= lowVolatilityThresholdBps) return Bucket.LOW;
        if (volatilityBps <= highVolatilityThresholdBps) return Bucket.MEDIUM;
        return Bucket.HIGH;
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

    // ============================================
    // Internal Functions
    // ============================================
    /// @notice Validates and stores volatility thresholds.
    function _setThresholds(uint256 lowThresholdBps, uint256 highThresholdBps) internal {
        if (lowThresholdBps >= highThresholdBps) revert InvalidThresholds();

        lowVolatilityThresholdBps = lowThresholdBps;
        highVolatilityThresholdBps = highThresholdBps;
    }
}
