// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Calculates minimum acceptable token amounts for V3 liquidity execution.
interface ISlippageController {
    /// @notice Per-target slippage and TWAP validation inputs.
    struct SlippageParams {
        /// @notice Maximum allowed slippage and spot-to-TWAP deviation in basis points.
        uint256 maxSlippageBps;
        /// @notice Historical window used to read the V3 TWAP.
        uint32 twapWindow;
    }

    /// @notice Returns the V3 adapter bound to a venue id for pool validation.
    function venueAdapters(uint256 venueId) external view returns (address);

    /// @notice Returns minimum acceptable amounts for a target venue and desired token amounts.
    /// @param targetVenueId Venue id receiving liquidity.
    /// @param amount0 Desired vault token0 amount.
    /// @param amount1 Desired vault token1 amount.
    /// @param params Slippage and TWAP validation inputs.
    function calculateMinAmounts(
        uint256 targetVenueId, 
        uint256 amount0, 
        uint256 amount1,
        SlippageParams calldata params
    ) external view returns (uint256 minAmount0, uint256 minAmount1);
}
