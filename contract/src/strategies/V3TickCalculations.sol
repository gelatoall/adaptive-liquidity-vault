// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../interfaces/IUniswapV3Pool.sol";

/// @notice Calculates Uniswap V3 position tick ranges from pool state and volatility signals.
contract V3TickCalculations {
    /// @notice V3 pool whose current tick and tick spacing are used for range calculation.
    IUniswapV3Pool public immutable v3Pool;

    error ZeroAddress();
    error InvalidTickSpacing();

    /// @notice Initializes the calculator for one V3 pool.
    constructor(address _v3Pool) {
        if (_v3Pool == address(0)) revert ZeroAddress();
        v3Pool = IUniswapV3Pool(_v3Pool);
    }

    /// @notice Calculate optimal tick range for V3 position
    /// @param volatilityBps Current volatility in basis points (100 = 1%)
    /// @return tickLower Lower tick bound adjusted to pool spacing
    /// @return tickUpper Upper tick bound adjusted to pool spacing
    function calculateTickRange(uint256 volatilityBps) public view returns (int24 tickLower, int24 tickUpper) {
        // 1. Get current active tick from pool
        (, int24 currentTick,,,,,) = v3Pool.slot0();

        // 2. Map volatility signal to a raw tick range width
        // Wider range for higher volatility to avoid falling out of bounds (IL protection)
        int24 tickRange;
        if (volatilityBps < 50) {
            tickRange = 200; // ~2% price range width
        } else if (volatilityBps < 150) {
            tickRange = 500; // ~5% price range width
        } else {
            tickRange = 1500; // ~15% price range width
        }

        // 3. Round bounds to nearest valid tick spacing (essential V3 invariant).
        int24 tickSpacing = v3Pool.tickSpacing();
        if (tickSpacing <= 0) revert InvalidTickSpacing();

        // Round outward so the final range fully covers the raw target range.
        tickLower = _roundDownToSpacing(currentTick - tickRange, tickSpacing);
        tickUpper = _roundUpToSpacing(currentTick + tickRange, tickSpacing);
    }

    /// @notice Rounds a tick down to the nearest spacing-aligned tick.
    function _roundDownToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        // Solidity division truncates toward zero, so negative unaligned ticks need one extra step down.
        if (tick < 0 && (tick % spacing != 0)) {
            compressed--;
        }
        return compressed * spacing;
    }

    /// @notice Rounds a tick up to the nearest spacing-aligned tick.
    function _roundUpToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        // Positive unaligned ticks need one extra step up to keep the range covering the raw bound.
        if (tick > 0 && (tick % spacing != 0)) {
            compressed++;
        }
        return compressed * spacing;
    }
}
