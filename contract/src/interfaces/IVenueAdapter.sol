// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IVenueAdapter {
    /// @notice Add liquidity to the venue
    /// @param amount0 Raw token0 amount to deploy
    /// @param amount1 Raw token1 amount to deploy
    /// @param params Venue-specific encoded parameters for future extensibility
    /// @return liquidity Amount of liquidity added (LP tokens or position size)
    function addLiquidity(
        uint256 amount0,
        uint256 amount1,
        bytes calldata params
    ) external returns (uint256 liquidity);

    /// @notice Remove liquidity from the venue
    /// @param liquidity Amount of LP tokens or position liquidity to remove
    /// @param params Venue-specific encoded parameters for removal execution
    /// @return amount0 Token0 received
    /// @return amount1 Token1 received
    function removeLiquidity(
        uint256 liquidity, 
        bytes calldata params
    ) external returns (uint256 amount0, uint256 amount1);

    /// @notice Collect claimable venue tokens; venues without an explicit claim step should return zero.
    /// @dev For V3 this uses position-manager owed-token accounting, which may include tokens made owed by
    ///      a previous liquidity decrease in addition to swap fees.
    function collectFees() external returns (uint256 collected0, uint256 collected1);

    /// @notice Get the underlying token balances represented by the current position
    function getPositionValue() external view returns (uint256 amount0, uint256 amount1);

    /// @notice Check if venue has active position
    function hasPosition() external view returns (bool);

    /// @notice Checks whether an existing position can be reused for the target parameters.
    /// @param params Venue-specific target parameters.
    /// @return compatible True when the existing position supports an in-place delta update.
    function isPositionCompatible(bytes calldata params) external view returns (bool compatible);
}
