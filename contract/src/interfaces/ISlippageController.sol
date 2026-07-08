// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Calculates minimum acceptable token amounts for venue liquidity execution.
interface ISlippageController {
    /// @notice Per-target slippage and TWAP validation inputs.
    struct SlippageParams {
        uint256 maxSlippageBps;      // e.g., 50 = 0.5%
        uint32 twapWindow;          // Time window for oracle price validation
        address pool;                // Pool used for TWAP/spot validation
    }

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
