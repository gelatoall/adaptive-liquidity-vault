// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../AdaptiveLPVault.sol";
import "../interfaces/IRebalanceStrategy.sol";

/// @notice Builds rebalance targets by splitting vault idle balances by fixed venue weights.
contract FixedWeightStrategy is IRebalanceStrategy, Ownable {
    /// @notice Basis point denominator used for weight configs.
    uint256 public constant BPS = 10_000;

    /// @notice Fixed allocation for one venue.
    struct TargetConfig {
        uint256 venueId;
        uint256 weightBps;  // Venue weight in basis points.
        bytes params;       // Venue-specific adapter params.
    }

    /// @notice Configured fixed-weight venue allocations.
    TargetConfig[] public targetConfigs;

    /// @notice Emitted after the target config set is replaced.
    event SetTargets(uint256 count);

    error EmptyTargets();
    error ZeroAddress();
    error ZeroWeight();
    error DuplicateVenue();
    error InvalidTotalWeight();

    // ============================================
    // Constructor
    // ============================================
    constructor() Ownable(msg.sender) {}

    // ============================================
    // View Functions
    // ============================================
    /// @notice Builds a rebalance plan from the vault's current idle token balances.
    /// @dev The last target receives any rounding dust from integer division.
    function buildTargets(
        address vault, 
        bytes calldata
    ) external view returns (RebalanceTypes.RebalanceTarget[] memory targets) {
        if (vault == address(0)) revert ZeroAddress();

        uint256 length = targetConfigs.length;
        if (length == 0) revert EmptyTargets();

        IERC20 token0 = AdaptiveLPVault(vault).token0();
        IERC20 token1 = AdaptiveLPVault(vault).token1();
        uint256 idle0 = token0.balanceOf(vault);
        uint256 idle1 = token1.balanceOf(vault);

        targets = new RebalanceTypes.RebalanceTarget[](length);

        uint256 used0;
        uint256 used1;
        for (uint256 i = 0; i < length; i++) {
            uint256 amount0;
            uint256 amount1;

            if (i == length - 1) {
                amount0 = idle0 - used0;
                amount1 = idle1 - used1;
            } else {
                amount0 = idle0 * targetConfigs[i].weightBps / BPS;
                amount1 = idle1 * targetConfigs[i].weightBps / BPS;
                used0 += amount0;
                used1 += amount1;
            }

            targets[i] = RebalanceTypes.RebalanceTarget({
                venueId: targetConfigs[i].venueId,
                amount0: amount0,
                amount1: amount1,
                params: targetConfigs[i].params
            });
        }
    }

    /// @notice Returns the number of configured target venues.
    function targetCount() external view returns (uint256) {
        return targetConfigs.length;
    }

    // ============================================
    // Admin Functions
    // ============================================
    /// @notice Replaces fixed venue weights.
    /// @dev Weights must be nonzero, unique by venue id, and sum to 10_000 bps.
    function setTargets(TargetConfig[] calldata configs) external onlyOwner {
        if (configs.length == 0) revert EmptyTargets();

        delete targetConfigs;
        uint256 totalWeight;
        for (uint256 i = 0; i < configs.length; i++) {
            if (configs[i].weightBps == 0) revert ZeroWeight();

            for (uint256 j = i + 1; j < configs.length; j++) {
                if (configs[i].venueId == configs[j].venueId) {
                    revert DuplicateVenue();
                }
            }

            totalWeight += configs[i].weightBps;
            targetConfigs.push(TargetConfig({
                venueId: configs[i].venueId,
                weightBps: configs[i].weightBps,
                params: configs[i].params
            }));
        }

        if (totalWeight != BPS) revert InvalidTotalWeight();

        emit SetTargets(configs.length);
    }
}