// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../libraries/RebalanceTypes.sol";

/// @notice Strategy interface for building vault rebalance target plans.
interface IRebalanceStrategy {
    /// @notice Builds a target plan for the calling vault to execute.
    /// @param vault Vault requesting the target plan.
    /// @param data Opaque strategy-specific input.
    /// @return targets Target venue allocations to execute.
    function buildTargets(address vault, bytes calldata data) external view returns (
        RebalanceTypes.RebalanceTarget[] memory targets
    );
}
