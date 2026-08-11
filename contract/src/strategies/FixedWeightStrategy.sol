// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "../AdaptiveLPVault.sol";
import "../interfaces/IRebalanceStrategy.sol";
import "../libraries/RebalanceTypes.sol";

/// @notice Builds rebalance targets by splitting total vault underlying by fixed venue weights.
contract FixedWeightStrategy is IRebalanceStrategy, Ownable2Step {
    /// @notice Configured fixed-weight venue allocations.
    RebalanceTypes.TargetConfig[] public targetConfigs;

    /// @notice Total venue allocation weight; unallocated weight remains idle.
    uint256 public totalTargetWeightBps;

    /// @notice Emitted after the target config set is replaced.
    event SetTargets(uint256 count);

    error EmptyTargets();
    error ZeroAddress();
    error ZeroWeight();
    error DuplicateVenue();
    error InvalidTotalWeight();
    /// @notice Thrown when configured venue weights would consume the vault's required idle buffer.
    error IdleBufferWeightExceeded(uint256 targetWeightBps, uint256 maxDeployableWeightBps);

    // ============================================
    // Constructor
    // ============================================
    constructor() Ownable(msg.sender) {}

    // ============================================
    // View Functions
    // ============================================
    /// @notice Builds a rebalance plan from the vault's total underlying token balances.
    /// @dev Target weights cannot exceed the vault's deployable weight after its idle buffer.
    ///      When weights total 10_000 bps, the final target receives rounding dust; otherwise
    ///      unallocated underlying remains idle.
    function buildTargets(
        address vault, 
        bytes calldata
    ) external view returns (RebalanceTypes.RebalanceTarget[] memory targets) {
        if (vault == address(0)) revert ZeroAddress();

        AdaptiveLPVault targetVault = AdaptiveLPVault(vault);
        uint256 length = targetConfigs.length;
        if (length == 0) revert EmptyTargets();

        uint256 maxDeployableWeightBps = RebalanceTypes.BPS - targetVault.minIdleBufferBps();
        if (totalTargetWeightBps > maxDeployableWeightBps) {
            revert IdleBufferWeightExceeded(totalTargetWeightBps, maxDeployableWeightBps);
        }

        (uint256 total0, uint256 total1) = targetVault.getTotalUnderlying();

        targets = new RebalanceTypes.RebalanceTarget[](length);

        uint256 used0;
        uint256 used1;
        bool fullyAllocated = totalTargetWeightBps == RebalanceTypes.BPS;
        for (uint256 i = 0; i < length; i++) {
            uint256 amount0;
            uint256 amount1;

            if (fullyAllocated && (i == length - 1)) {
                amount0 = total0 - used0;
                amount1 = total1 - used1;
            } else {
                amount0 = total0 * targetConfigs[i].weightBps / RebalanceTypes.BPS;
                amount1 = total1 * targetConfigs[i].weightBps / RebalanceTypes.BPS;
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
    /// @dev Weights must be nonzero and unique, and their sum must not exceed 10_000 bps.
    ///      Unallocated weight remains in the vault as idle liquidity.
    function setTargets(RebalanceTypes.TargetConfig[] calldata configs) external onlyOwner {
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
            targetConfigs.push(RebalanceTypes.TargetConfig({
                venueId: configs[i].venueId,
                weightBps: configs[i].weightBps,
                params: configs[i].params
            }));
        }

        if (totalWeight > RebalanceTypes.BPS) revert InvalidTotalWeight();
        totalTargetWeightBps = totalWeight;

        emit SetTargets(configs.length);
    }
}
