// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/oracles/V2TWAPOracle.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockUniswapV2Pair.sol";

/// @title OracleTest
/// @notice Unit tests for V2TWAPOracle constructor validation, update windows, scaling, and token-order mapping.
contract OracleTest is Test {
    MockERC20 public token0;
    MockERC20 public token1;
    MockUniswapV2Pair public pair;
    V2TWAPOracle public oracle;
    uint32 public minUpdateInterval = 300; // 5 minutes
    
    /// @notice Deploys token mocks, pair mock, and oracle fixture for each test.
    function setUp() public {
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 6);

        pair = new MockUniswapV2Pair(address(token0), address(token1));
        pair.setReserves(1_000_000, 2_000_000);
        pair.setCumulativePrices(1_000_000e18, 2_000_000e18);

        oracle = new V2TWAPOracle(
            address(pair), 
            address(token0), 
            address(token1),
            minUpdateInterval
        );
    }

    /// @notice Reverts when the pair address is zero.
    function test_Constructor_RevertsWhenPairIsZeroAddress() public {
        vm.expectRevert(V2TWAPOracle.ZeroAddress.selector);
        new V2TWAPOracle(
            address(0),
            address(token0), 
            address(token1),
            minUpdateInterval
        );
    }

    /// @notice Reverts when token0 address is zero.
    function test_Constructor_RevertsWhenToken0IsZeroAddress() public {
        vm.expectRevert(V2TWAPOracle.ZeroAddress.selector);
        new V2TWAPOracle(
            address(pair),
            address(0), 
            address(token1),
            minUpdateInterval
        );
    }

    /// @notice Reverts when token1 address is zero.
    function test_Constructor_RevertsWhenToken1IsZeroAddress() public {
        vm.expectRevert(V2TWAPOracle.ZeroAddress.selector);
        new V2TWAPOracle(
            address(pair),
            address(token0), 
            address(0),
            minUpdateInterval
        );
    }

    /// @notice Reverts when the minimum update interval is zero.
    function test_Constructor_RevertsWhenIntervalIsZero() public {
        vm.expectRevert(V2TWAPOracle.InvalidInterval.selector);
        new V2TWAPOracle(
            address(pair),
            address(token0), 
            address(token1),
            0
        );
    }

    /// @notice Reverts when pair token set does not match configured token set.
    function test_Constructor_RevertsWhenPairTokenSetMismatch() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        MockUniswapV2Pair badPair = new MockUniswapV2Pair(address(token0), address(other));

        vm.expectRevert(V2TWAPOracle.InvalidPairTokens.selector);
        new V2TWAPOracle(
            address(badPair),
            address(token0), 
            address(token1),
            minUpdateInterval
        );
    }
    
    /// @notice Snapshots pair cumulative values and timestamp during constructor.
    function test_Constructor_SnapshotsInitialCumulativesAndTimestamp() public {
        (, , uint32 ts) = pair.getReserves();
        assertEq(oracle.price0CumulativeLast(), pair.price0CumulativeLast());
        assertEq(oracle.price1CumulativeLast(), pair.price1CumulativeLast());
        assertEq(oracle.blockTimestampLast(), ts);
        assertFalse(oracle.initialized());
    }

    /// @notice Reverts before the first valid update initializes an average.
    function test_GetPrices_RevertsBeforeFirstValidUpdate() public {
        vm.expectRevert(V2TWAPOracle.NotInitialized.selector);
        oracle.getPrices();
    }

    /// @notice Reverts when no time has elapsed since last snapshot.
    function test_Update_RevertsWhenNoTimeElapsed() public {
        vm.expectRevert(V2TWAPOracle.ZeroTimeElapsed.selector);
        oracle.update();
    }

    /// @notice Reverts when elapsed time is below minimum update interval.
    function test_Update_RevertsWhenIntervalTooShort() public {
        vm.warp(block.timestamp + minUpdateInterval - 1);
        pair.setReserves(1_000_001, 2_000_001);
        vm.expectRevert(V2TWAPOracle.IntervalTooShort.selector);
        oracle.update();
    }

    /// @notice Computes TWAP averages and returns 1e18-scaled prices after update.
    function test_Update_ComputesBaseDenominatedPrices() public {
        uint256 q112 = 2 ** 112;
        uint32 dt = minUpdateInterval;
        uint256 reserve0 = 1 ether;
        uint256 reserve1 = 2000e6;
        uint256 avg0X112 = reserve1 * q112 / reserve0;
        uint256 avg1X112 = reserve0 * q112 / reserve1;

        uint256 cum0Last = oracle.price0CumulativeLast();
        uint256 cum1Last = oracle.price1CumulativeLast();
        uint256 cum0Now = cum0Last + avg0X112 * dt;
        uint256 cum1Now = cum1Last + avg1X112 * dt;

        vm.warp(block.timestamp + dt);
        pair.setReserves(uint112(reserve0), uint112(reserve1)); // push pair timestamp forward
        pair.setCumulativePrices(cum0Now, cum1Now);

        oracle.update();
        
        assertEq(oracle.price0AverageX112(), avg0X112);
        assertEq(oracle.price1AverageX112(), avg1X112);
        assertEq(oracle.price0CumulativeLast(), cum0Now);
        assertEq(oracle.price1CumulativeLast(), cum1Now);
        assertTrue(oracle.initialized());

        (, , uint32 tsNow) = pair.getReserves();
        assertEq(oracle.blockTimestampLast(), tsNow);

        (uint256 price0, uint256 price1) = oracle.getPrices();
        assertEq(price0, 1e18);
        assertEq(price1, 0.0005 ether);
    }

    /// @notice Uses advanced snapshot state for the second update window.
    function test_Update_AdvancesSnapshotForNextWindow() public {
        uint256 q112 = 2 ** 112;
        uint32 dt = minUpdateInterval;

        uint256 reserve0 = 1 ether;
        uint256 reserve1W1 = 2000e6;
        uint256 avg0W1 = reserve1W1 * q112 / reserve0;
        uint256 avg1W1 = reserve0 * q112 / reserve1W1;

        uint256 cum0Last = oracle.price0CumulativeLast();
        uint256 cum1Last = oracle.price1CumulativeLast();
        uint256 cum0Now1 = cum0Last + avg0W1 * dt;
        uint256 cum1Now1 = cum1Last + avg1W1 * dt;

        vm.warp(block.timestamp + dt);
        pair.setReserves(uint112(reserve0), uint112(reserve1W1)); // push pair timestamp forward
        pair.setCumulativePrices(cum0Now1, cum1Now1);

        oracle.update();
        (uint256 p0W1, uint256 p1W1) = oracle.getPrices();
        assertEq(p0W1, 1e18);
        assertEq(p1W1, 0.0005 ether);

        // window #2 target avg
        uint256 reserve1W2 = 2_500e6;
        uint256 avg0W2 = reserve1W2 * q112 / reserve0;
        uint256 avg1W2 = reserve0 * q112 / reserve1W2;
        uint256 cum0Now2 = cum0Now1 + avg0W2 * dt;
        uint256 cum1Now2 = cum1Now1 + avg1W2 * dt;

        vm.warp(block.timestamp + dt);
        pair.setReserves(uint112(reserve0), uint112(reserve1W2));
        pair.setCumulativePrices(cum0Now2, cum1Now2);

        oracle.update();
        (uint256 p0W2, uint256 p1W2) = oracle.getPrices();
        assertEq(p0W2, 1e18);
        assertEq(p1W2, 0.0004 ether);
    }

    /// @notice Keeps token0-denominated output unchanged when the pair token order is reversed.
    function test_GetPrices_MapsReversedPairOrderCorrectly() public {
        MockUniswapV2Pair reversedPair = new MockUniswapV2Pair(address(token1), address(token0));

        uint256 q112 = 2 ** 112;
        uint256 pairReserve0 = 2000e6; // pair token0 = configured token1 (USDC)
        uint256 pairReserve1 = 1 ether; // pair token1 = configured token0 (WETH)

        // Establish the initial reserve timestamp before the oracle snapshots it.
        reversedPair.setReserves(uint112(pairReserve0), uint112(pairReserve1));
        reversedPair.setCumulativePrices(1_000_000e18, 2_000_000e18);

        V2TWAPOracle reversedOracle = new V2TWAPOracle(
            address(reversedPair),
            address(token0),
            address(token1),
            minUpdateInterval
        );

        uint32 dt = minUpdateInterval;
        uint256 avg0X112 = pairReserve1 * q112 / pairReserve0;
        uint256 avg1X112 = pairReserve0 * q112 / pairReserve1;

        uint256 cum0Last = reversedOracle.price0CumulativeLast();
        uint256 cum1Last = reversedOracle.price1CumulativeLast();
        uint256 cum0Now = cum0Last + dt * avg0X112;
        uint256 cum1Now = cum1Last + dt * avg1X112;

        vm.warp(block.timestamp + dt);
        // Persist the advanced timestamp while keeping the same economic reserves.
        reversedPair.setReserves(uint112(pairReserve0), uint112(pairReserve1));
        reversedPair.setCumulativePrices(cum0Now, cum1Now);

        reversedOracle.update();
        (uint256 price0, uint256 price1) = reversedOracle.getPrices();
        assertEq(price0, 1e18);
        assertApproxEqAbs(price1, 0.0005 ether, 1);
    }

}
