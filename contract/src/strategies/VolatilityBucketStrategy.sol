// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../AdaptiveLPVault.sol";
import "../interfaces/IRebalanceStrategy.sol";

/// @notice Builds idle-only allocations from configured volatility buckets.
contract VolatilityBucketStrategy is IRebalanceStrategy, Ownable {
    /// @notice Supported volatility ranges.
    enum Bucket {
        LOW,
        MEDIUM,
        HIGH
    }

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
    error InvalidData();
    error InvalidThresholds();
    error InvalidTotalWeight();
    error EmptyTargets();
    error DuplicateVenue();
    error VaultNotIdle();

    // ============================================
    // Constructor
    // ============================================
    /// @notice Initializes the low and high volatility thresholds.
    constructor(uint256 lowThresholdBps, uint256 highThresholdBps) Ownable(msg.sender) {
        _setThresholds(lowThresholdBps, highThresholdBps);
    }

    // ============================================
    // View Functions
    // ============================================
    /// @notice Builds an idle-balance allocation plan for the supplied volatility.
    /// @dev `data` must encode one uint256 volatility value in basis points.
    function buildTargets(
        address vault, 
        bytes calldata data
    ) external view returns (RebalanceTypes.RebalanceTarget[] memory targets) {
        if (vault == address(0)) revert ZeroAddress();

        AdaptiveLPVault targetVault = AdaptiveLPVault(vault);
        if (targetVault.totalLiquidity() != 0) {
            revert VaultNotIdle();
        }

        if (data.length != 32) revert InvalidData();
        uint256 volatilityBps = abi.decode(data, (uint256));
        Bucket bucket = getBucket(volatilityBps);
        RebalanceTypes.TargetConfig[] storage configs = bucketTargets[bucket];

        uint256 length = configs.length;
        if (length == 0) revert EmptyTargets();
        targets = new RebalanceTypes.RebalanceTarget[](length);
        
        IERC20 token0 = targetVault.token0();
        IERC20 token1 = targetVault.token1();
        uint256 idle0 = token0.balanceOf(vault);
        uint256 idle1 = token1.balanceOf(vault);

        uint256 used0;
        uint256 used1;
        for(uint256 i = 0; i < length; i++) {
            uint256 amount0;
            uint256 amount1;

            if (i == length - 1) {
                amount0 = idle0 - used0;
                amount1 = idle1 - used1;
            } else {
                amount0 = idle0 * configs[i].weightBps / RebalanceTypes.BPS;
                amount1 = idle1 * configs[i].weightBps / RebalanceTypes.BPS;

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
