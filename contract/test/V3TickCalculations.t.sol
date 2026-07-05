// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/strategies/V3TickCalculations.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockUniswapV3Pool.sol";

contract V3TickCalculationsTest is Test {
    MockERC20 public token0;
    MockERC20 public token1;
    MockUniswapV3Pool public pool;
    V3TickCalculations public calculations;

    function setUp() public {
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("token1", "TK1", 6);
        uint24 feeTier = 3000;  // 0.30% fee
        pool = new MockUniswapV3Pool(address(token0), address(token1), feeTier);
        pool.setSlot0FromTick(0);
        calculations = new V3TickCalculations(address(pool));
    }

    function test_CalculateTickRange_LowBucketBoundary() public {
        uint256 volatilityBps = 49; // low bucket: raw width 200 ticks
        (int24 tickLower, int24 tickUpper) = calculations.calculateTickRange(volatilityBps);

        // currentTick = 0, raw range = [-200, 200], spacing = 60
        assertEq(tickLower, -240);
        assertEq(tickUpper, 240);
    }

    function test_CalculateTickRange_MediumBucketLowerBoundary() public {
        uint256 volatilityBps = 50; // medium bucket: raw width 500 ticks
        (int24 tickLower, int24 tickUpper) = calculations.calculateTickRange(volatilityBps);

        // currentTick = 0, raw range = [-500, 500], spacing = 60
        assertEq(tickLower, -540);
        assertEq(tickUpper, 540);
    }

    function test_CalculateTickRange_HighBucketLowerBoundary() public {
        uint256 volatilityBps = 150; // high bucket: raw width 1500 ticks
        (int24 tickLower, int24 tickUpper) = calculations.calculateTickRange(volatilityBps);

        assertEq(tickLower, -1500); // already aligned to spacing 60
        assertEq(tickUpper, 1500);
    }

    function test_CalculateTickRange_RoundsOutwardWhenLowerCrossesZero() public {
        pool.setSlot0FromTick(199);
        uint256 volatilityBps = 49; // low bucket: raw width 200 ticks
        (int24 tickLower, int24 tickUpper) = calculations.calculateTickRange(volatilityBps);

        // currentTick = 199, raw range = [-1, 399], spacing = 60
        assertEq(tickLower, -60); // key check: -1 must round down to -60, not truncate to 0
        assertEq(tickUpper, 420); // 399 rounds up to 420
    }

    function test_CalculateTickRange_RoundsOutwardWhenUpperCrossesZero() public {
        pool.setSlot0FromTick(-199);
        uint256 volatilityBps = 49; // low bucket: raw width 200 ticks
        (int24 tickLower, int24 tickUpper) = calculations.calculateTickRange(volatilityBps);

        // currentTick = -199, raw range = [-399, 1], spacing = 60
        assertEq(tickLower, -420); // -399 rounds down to -420
        assertEq(tickUpper, 60); // key check: 1 must round up to 60, not truncate to 0
    }
}
