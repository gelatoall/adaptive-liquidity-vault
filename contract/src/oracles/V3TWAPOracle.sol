// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../interfaces/IUniswapV3Pool.sol";
import "../libraries/v3/TickMath.sol";
import "../libraries/v3/FullMath.sol";

/// @notice Reads Uniswap V3's built-in oracle and returns TWAP prices.
contract V3TWAPOracle {
    uint256 internal constant Q192 = 2 ** 192;
    uint256 internal constant PRICE_SCALE = 1e18;

    IUniswapV3Pool public immutable pool;

    error ZeroAddress();
    error InvalidTwapPeriod();

    constructor(address _pool) {
        if (_pool == address(0)) revert ZeroAddress();
        pool = IUniswapV3Pool(_pool);
    }

    /// @notice Returns the TWAP price over a historical period.
    /// @param period Seconds to look back.
    function getTWAP(uint32 period) public view returns (uint256 price) {
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
        price = _sqrtPriceX96ToPrice(sqrtPriceX96);
    }

    /// @notice Converts a V3 Q64.96 square-root price into a 1e18-scaled price.
    function _sqrtPriceX96ToPrice(uint160 sqrtPriceX96) internal pure returns (uint256 price) {
        price = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96) * PRICE_SCALE, Q192);
    }
}
