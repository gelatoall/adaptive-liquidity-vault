// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal redemption-manager interface consumed by the vault.
interface IRedemptionManager {
    /// @notice Returns whether a queued redemption is currently active.
    function isProcessing() external view returns (bool);
}
