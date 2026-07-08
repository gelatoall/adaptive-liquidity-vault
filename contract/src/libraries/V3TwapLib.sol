// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../interfaces/IUniswapV3Pool.sol";
import "./v3/TickMath.sol";
import "./v3/FullMath.sol";

/// @notice Shared Uniswap V3 spot, TWAP, and deviation helpers.
library V3TwapLib {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant Q192 = 2 ** 192;
    uint256 internal constant PRICE_SCALE = 1e18;

    error InvalidTwapPeriod();
    error InvalidTwapPrice();

    /// @notice Returns the current spot price from pool slot0.
    function getSpotPrice(IUniswapV3Pool pool) internal view returns (uint256 price) {
        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        price = sqrtPriceX96ToPrice(sqrtPriceX96);
    }

    /// @notice Returns the TWAP price over a historical period.
    /// @param period Seconds to look back.
    function getTwapPrice(IUniswapV3Pool pool, uint32 period) internal view returns (uint256 price) {
        if (period == 0) revert InvalidTwapPeriod();

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = period; // Start of window
        secondsAgos[1] = 0;      // Now

        // Get cumulative tick values from the pool's built-in oracle
        (int56[] memory tickCumulatives, ) = pool.observe(secondsAgos);

        // Calculate time-weighted average tick
        int56 tickDiff = tickCumulatives[1] - tickCumulatives[0];
        int24 avgTick = int24(tickDiff / int56(uint56(period)));

        // Convert average tick to price (price = 1.0001^tick).
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(avgTick);
        price = sqrtPriceX96ToPrice(sqrtPriceX96);
    }

    /// @notice Returns absolute deviation between spot and TWAP in basis points.
    function getDeviationBps(uint256 spotPrice, uint256 twapPrice) internal pure returns (uint256) {
        if (twapPrice == 0) revert InvalidTwapPrice();

        // Calculate absolute deviation
        uint256 deviation;
        if (spotPrice > twapPrice) {
            deviation = spotPrice - twapPrice;
        } else {
            deviation = twapPrice - spotPrice;
        }

        // Return deviation in basis points relative to the TWAP anchor.
        return (deviation * BPS) / twapPrice;
    }

    /// @notice Converts a V3 Q64.96 square-root price into a 1e18-scaled price.
    function sqrtPriceX96ToPrice(uint160 sqrtPriceX96) internal pure returns (uint256 price) {
        price = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96) * PRICE_SCALE, Q192);
    }

}
