// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/libraries/VaultMath.sol";

/// @dev Exposes internal library functions through external wrappers for testing.
contract VaultMathHarness {
    function valueInBase(
        uint256 amount,
        uint256 price,
        uint8 decimals
    ) external pure returns (uint256) {
        return VaultMath.valueInBase(amount, price, decimals);
    }

    function getAssetsTotalValue(
        uint256 amount0,
        uint256 price0,
        uint8 decimals0,
        uint256 amount1,
        uint256 price1,
        uint8 decimals1
    ) external pure returns (uint256) {
        return VaultMath.getAssetsTotalValue(amount0, price0, decimals0, amount1, price1, decimals1);
    }


    function calculateShares(
        uint256 assetsToDeposit,
        uint256 totalAssets,
        uint256 totalShares
    ) external pure returns (uint256) {
        return VaultMath.calculateShares(assetsToDeposit, totalAssets, totalShares);
    }
}

contract VaultMathTest is Test {
    VaultMathHarness harness;

    function setUp() public {
        harness = new VaultMathHarness();
    }

    // valueInBase()
    function test_ValueInBase_ReturnsZeroWhenAmountIsZero() public {
        uint256 amount = 0;
        uint256 price = 1e18;
        uint8 decimals = 18;
        assertEq(harness.valueInBase(amount, price, decimals), 0);
    }

    function test_ValueInBase_RevertsWhenPriceIsZero() public {
        uint256 amount = 2e18;
        uint256 price = 0;
        uint8 decimals = 18;
        vm.expectRevert(VaultMath.InvalidPrice.selector);
        harness.valueInBase(amount, price, decimals);
    }

    function test_ValueInBase_ComputesValueCorrectly_For18DecimalsToken() public {
        uint256 amount = 2e18;
        uint256 price = 5e17;
        uint8 decimals = 18;
        assertEq(harness.valueInBase(amount, price, decimals), 1e18);
    }

    function test_ValueInBase_ComputesValueCorrectly_For6DecimalsToken() public {
        uint256 amount = 2000e6;
        uint256 price = 5e14;
        uint8 decimals = 6;
        assertEq(harness.valueInBase(amount, price, decimals), 1e18);
    }

    function test_ValueInBase_ReturnsCorrectValue_WhenAmountIsOneWholeToken() public {
        uint256 amount = 1e18;
        uint256 price = 2e18;
        uint8 decimals = 18;
        assertEq(harness.valueInBase(amount, price, decimals), 2e18);
    }

    // getAssetsTotalValue()
    function test_GetAssetsTotalValue_ReturnsSumOfTwoAssetValues() public {
        uint256 amount0 = 1e18;
        uint256 price0 = 1e18;
        uint8 decimals0 = 18;
        uint256 amount1 = 2000e6;
        uint256 price1 = 5e14;
        uint8 decimals1 = 6;

        assertEq(harness.getAssetsTotalValue(amount0, price0, decimals0, amount1, price1, decimals1), 2e18);
    }

    function test_GetAssetsTotalValue_ReturnsSingleAssetValue_WhenOtherAmountIsZero() public {
        uint256 amount0 = 1e18;
        uint256 price0 = 1e18;
        uint8 decimals0 = 18;
        uint256 amount1 = 0;
        uint256 price1 = 5e14;
        uint8 decimals1 = 6;
        assertEq(harness.getAssetsTotalValue(amount0, price0, decimals0, amount1, price1, decimals1), 1e18);
    }

    function test_GetAssetsTotalValue_RevertsWhenFirstPriceIsZero() public {
        uint256 amount0 = 1e18;
        uint256 price0 = 0;
        uint8 decimals0 = 18;
        uint256 amount1 = 2000e6;
        uint256 price1 = 5e14;
        uint8 decimals1 = 6;

        vm.expectRevert(VaultMath.InvalidPrice.selector);
        harness.getAssetsTotalValue(amount0, price0, decimals0, amount1, price1, decimals1);
    }

    function test_GetAssetsTotalValue_RevertsWhenSecondPriceIsZero() public {
        uint256 amount0 = 1e18;
        uint256 price0 = 1e18;
        uint8 decimals0 = 18;
        uint256 amount1 = 2000e6;
        uint256 price1 = 0;
        uint8 decimals1 = 6;

        vm.expectRevert(VaultMath.InvalidPrice.selector);
        harness.getAssetsTotalValue(amount0, price0, decimals0, amount1, price1, decimals1);
    }

    // calculateShares()
    function test_CalculateShares_ReturnsAssetsToDeposit_OnInitialDeposit() public {
        uint256 assetsToDeposit = 100e18;
        uint256 totalAssets = 0;
        uint256 totalShares = 0;
        assertEq(harness.calculateShares(assetsToDeposit, totalAssets, totalShares), 100e18);
    }

    function test_CalculateShares_ComputesProportionalShares_WhenVaultIsInitialized() public {
        uint256 assetsToDeposit = 100e18;
        uint256 totalAssets = 2000e18;
        uint256 totalShares = 1000e18;
        assertEq(harness.calculateShares(assetsToDeposit, totalAssets, totalShares), 50e18);
    }

    function test_CalculateShares_ReturnsZero_WhenAssetsToDepositIsZero() public {
        uint256 assetsToDeposit = 0;
        uint256 totalAssets = 2000e18;
        uint256 totalShares = 1000e18;
        assertEq(harness.calculateShares(assetsToDeposit, totalAssets, totalShares), 0);
    }

    function test_CalculateShares_RoundsDown_WhenDivisionIsNotExact() public {
        uint256 assetsToDeposit = 1;
        uint256 totalAssets = 3;
        uint256 totalShares = 10;
        assertEq(harness.calculateShares(assetsToDeposit, totalAssets, totalShares), 3);
    }

    function test_CalculateShares_RevertsWhenNonZeroDepositRoundsDownToZero() public {
        uint256 assetsToDeposit = 1;
        uint256 totalAssets = 2;
        uint256 totalShares = 1;
        vm.expectRevert(VaultMath.ZeroShares.selector);
        harness.calculateShares(assetsToDeposit, totalAssets, totalShares);
    }

    function test_CalculateShares_RevertsWhenTotalAssetsIsZeroButTotalSharesIsNotZero() public {
        uint256 assetsToDeposit = 100e18;
        uint256 totalAssets = 0;
        uint256 totalShares = 1000e18;
        vm.expectRevert(VaultMath.InvalidVaultState.selector);
        harness.calculateShares(assetsToDeposit, totalAssets, totalShares);
    }

    function test_CalculateShares_RevertsWhenTotalSharesIsZeroButTotalAssetsIsNotZero() public {
        uint256 assetsToDeposit = 100e18;
        uint256 totalAssets = 1000e18;
        uint256 totalShares = 0;
        vm.expectRevert(VaultMath.InvalidVaultState.selector);
        harness.calculateShares(assetsToDeposit, totalAssets, totalShares);
    }
}