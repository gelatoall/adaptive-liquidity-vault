// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/oracles/PriceChangeVolatilityOracle.sol";
import "./mocks/MockPriceOracle.sol";

/// @notice Tests price-change based volatility calculation.
contract PriceChangeVolatilityOracleTest is Test {
    MockPriceOracle public priceOracle;
    PriceChangeVolatilityOracle public volatilityOracle;

    function setUp() public {
        priceOracle = new MockPriceOracle();
        volatilityOracle = new PriceChangeVolatilityOracle(address(priceOracle));
    }

    /// @notice Constructor rejects a zero price oracle address.
    function test_Constructor_RevertsWhenPriceOracleIsZero() public {
        vm.expectRevert(PriceChangeVolatilityOracle.ZeroAddress.selector);
        new PriceChangeVolatilityOracle(address(0));
    }

    /// @notice First update initializes snapshots without volatility.
    function test_Update_InitializesSnapshotOnFirstUpdate() public {
        priceOracle.setPrices(100e18, 200e18);
        volatilityOracle.update();

        assertEq(volatilityOracle.lastPrice0(), 100e18);
        assertEq(volatilityOracle.lastPrice1(), 200e18);
        assertEq(volatilityOracle.volatilityBps(), 0);
    }

    /// @notice Price increases produce the larger two-token change.
    function test_Update_ComputesVolatilityWhenPricesIncrease() public {
        priceOracle.setPrices(100e18, 200e18);
        volatilityOracle.update();

        priceOracle.setPrices(110e18, 210e18);
        volatilityOracle.update();

        assertEq(volatilityOracle.lastPrice0(), 110e18);
        assertEq(volatilityOracle.lastPrice1(), 210e18);
        assertEq(volatilityOracle.volatilityBps(), 1000);
    }

    /// @notice Price decreases use absolute price changes.
    function test_Update_ComputesVolatilityWhenPricesDecrease() public {
        priceOracle.setPrices(100e18, 200e18);
        volatilityOracle.update();

        priceOracle.setPrices(90e18, 190e18);
        volatilityOracle.update();

        assertEq(volatilityOracle.lastPrice0(), 90e18);
        assertEq(volatilityOracle.lastPrice1(), 190e18);
        assertEq(volatilityOracle.volatilityBps(), 1000);
    }

    /// @notice Opposite-direction moves still use absolute changes.
    function test_Update_ComputesVolatilityWhenPricesMoveInOppositeDirections() public {
        priceOracle.setPrices(100e18, 200e18);
        volatilityOracle.update();

        priceOracle.setPrices(105e18, 170e18);
        volatilityOracle.update();

        assertEq(volatilityOracle.lastPrice0(), 105e18);
        assertEq(volatilityOracle.lastPrice1(), 170e18);
        assertEq(volatilityOracle.volatilityBps(), 1500);
    }

    /// @notice update reverts when token0 price is zero.
    function test_Update_RevertsWhenPrice0IsZero() public {
        priceOracle.setPrices(0, 1e18);
        vm.expectRevert(PriceChangeVolatilityOracle.InvalidPrice.selector);
        volatilityOracle.update();
    }

    /// @notice update reverts when token1 price is zero.
    function test_Update_RevertsWhenPrice1IsZero() public {
        priceOracle.setPrices(1e18, 0);
        vm.expectRevert(PriceChangeVolatilityOracle.InvalidPrice.selector);
        volatilityOracle.update();
    }
}
