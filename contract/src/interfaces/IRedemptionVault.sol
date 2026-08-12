// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal vault interface consumed by the redemption manager.
interface IRedemptionVault {
    /// @notice Returns the vault owner used for redemption administration.
    function owner() external view returns (address);

    /// @notice Returns the keeper permitted to activate queued redemptions.
    function keeper() external view returns (address);

    /// @notice Returns whether the requested shares require asynchronous settlement.
    function requiresQueuedRedeem(uint256 shares) external view returns (bool);

    /// @notice Burns manager-escrowed shares and pays a queued redemption from idle balances.
    function settleQueuedRedeem(
        uint256 shares,
        address receiver,
        address shareOwner,
        uint256 minAmount0Out,
        uint256 minAmount1Out
    ) external returns (uint256 amount0Out, uint256 amount1Out);
}
