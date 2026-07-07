// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import "../src/oracles/V3TwapVolatilityOracle.sol";
import "../src/libraries/v3/TickMath.sol";
import "../src/libraries/v3/FullMath.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockUniswapV3Pool.sol";

contract V3TwapVolatilityOracleTest is Test {
    uint256 internal constant Q192 = 2 ** 192;
    uint256 internal constant PRICE_SCALE = 1e18;
    uint32 internal constant TWAP_WINDOW = 1800; // 30 min

    MockERC20 public token0;
    MockERC20 public token1;
    MockUniswapV3Pool public pool;
    V3TwapVolatilityOracle public oracle;

    function setUp() public {
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("token1", "TK1", 6);
        uint24 feeTier = 3000;  // 0.30% fee
        pool = new MockUniswapV3Pool(address(token0), address(token1), feeTier);
        oracle = new V3TwapVolatilityOracle(address(pool), TWAP_WINDOW);
        vm.warp(TWAP_WINDOW);
    }

    function _priceFromTick(int24 tick) internal pure returns (uint256) {
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(tick);
        return FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96) * PRICE_SCALE, Q192);
    }

    function test_GetTWAP_ReturnsPriceFromAverageTick() public {
        int24 twapTick = 100;
        pool.setTwapTick(twapTick);
        uint256 price = oracle.getTWAP(TWAP_WINDOW);
        assertEq(price, _priceFromTick(twapTick));
    }

    function test_GetSpotPrice_ReturnsPriceFromCurrentTick() public {
        int24 currentTick = 200;
        pool.setSlot0FromTick(currentTick);
        uint256 price = oracle.getSpotPrice();
        assertEq(price, _priceFromTick(currentTick));
    }
    
    function test_GetVolatilityBps_ReturnsDeviationBetweenSpotAndTwap() public {
        int24 twapTick = 0;
        int24 currentTick = 100;
        pool.setTwapTick(twapTick);
        pool.setSlot0FromTick(currentTick);

        uint256 volatilityBps = oracle.getVolatilityBps();
        assertGt(volatilityBps, 0); // volatilityBps > 0
    }

    function test_GetVolatilityBps_ReturnsZeroWhenSpotEqualsTwap() public {
        int24 tick = 100;
        pool.setTwapTick(tick);
        pool.setSlot0FromTick(tick);

        uint256 volatilityBps = oracle.getVolatilityBps();
        assertEq(volatilityBps, 0);
    }

    function test_Constructor_RevertsWhenTwapWindowIsZero() public {
        vm.expectRevert(V3TwapVolatilityOracle.InvalidTwapWindow.selector);
        new V3TwapVolatilityOracle(address(pool), 0);
    }

    function test_GetTWAP_RevertsWhenPeriodIsZero() public {
        vm.expectRevert(V3TWAPOracle.InvalidTwapPeriod.selector);
        oracle.getTWAP(0);
    }
}
