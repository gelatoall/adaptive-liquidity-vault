// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal vault interface consumed by the redemption manager.
interface IRedemptionVault {
    /// @notice Returns the vault owner used for redemption administration.
    function owner() external view returns (address);

    /// @notice Returns the keeper permitted to activate queued redemptions.
    function keeper() external view returns (address);

    /// @notice Returns the first underlying token.
    function token0() external view returns (address);

    /// @notice Returns the second underlying token.
    function token1() external view returns (address);

    /// @notice Returns the number of registered venues.
    function venueCount() external view returns (uint256);

    /// @notice Returns the venue id stored at `index`.
    function venueIds(uint256 index) external view returns (uint256);

    /// @notice Returns the vault's tracked liquidity for `venueId`.
    function venueLiquidity(uint256 venueId) external view returns (uint256);

    /// @notice Returns whether the requested shares require asynchronous settlement.
    function requiresQueuedRedeem(uint256 shares) external view returns (bool);

    /// @notice Withdraws request-specific liquidity from one venue into the vault.
    function fundQueuedRedeemFromVenue(
        uint256 venueId,
        uint256 liquidity,
        uint256 requestShares,
        uint256 totalSharesSnapshot,
        bytes calldata params
    ) external returns (uint256 requestAmount0, uint256 requestAmount1);

    /// @notice Burns escrowed shares and transfers request-specific funded amounts to the receiver.
    function settleQueuedRedeem(
        uint256 shares,
        uint256 totalSharesSnapshot,
        address receiver,
        address shareOwner,
        uint256 amount0Out,
        uint256 amount1Out
    ) external;
}
