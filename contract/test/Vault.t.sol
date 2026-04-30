// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/AdaptiveLPVault.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockPriceOracle.sol";

contract VaultTest is Test {
    AdaptiveLPVault public vault;
    MockERC20 public token0;
    MockERC20 public token1;
    uint8 public decimals0 = 18; 
    uint8 public decimals1 = 6;
    MockPriceOracle public oracle;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public {
        token0 = new MockERC20("token0", "T0", 18);
        token1 = new MockERC20("token1", "T1", 6);

        vault = new AdaptiveLPVault(
            "Adaptive LP Vault", "ALPV", 
            address(token0), address(token1), 
            decimals0, decimals1
        );

        oracle = new MockPriceOracle();
        vault.setOracle(address(oracle));
    }

    // constructor
    function test_Constructor_SetsTokensAndDecimalsCorrectly() public {
        assertEq(address(vault.token0()), address(token0));
        assertEq(address(vault.token1()), address(token1));
        assertEq(vault.decimals0(), 18);
        assertEq(vault.decimals1(), 6);
    }
    
    function test_Constructor_RevertsWhenToken0IsZeroAddress() public {
        vm.expectRevert(AdaptiveLPVault.ZeroAddress.selector);
        new AdaptiveLPVault(
            "Adaptive LP Vault", "ALPV", 
            address(0), address(token1), 
            decimals0, decimals1
        );
    }

    function test_Constructor_RevertsWhenToken1IsZeroAddress() public {
        vm.expectRevert(AdaptiveLPVault.ZeroAddress.selector);
        new AdaptiveLPVault(
            "Adaptive LP Vault", "ALPV",
            address(token0), address(0),
            decimals0, decimals1
        );
    }

    function test_Constructor_RevertsWhenDecimals0IsZero() public {
        vm.expectRevert(AdaptiveLPVault.ZeroDecimals.selector);
        new AdaptiveLPVault(
            "Adaptive LP Vault", "ALPV", 
            address(token0), address(token1), 
            0, decimals1
        );
    }

    function test_Constructor_RevertsWhenDecimals1IsZero() public {
        vm.expectRevert(AdaptiveLPVault.ZeroDecimals.selector);
        new AdaptiveLPVault(
            "Adaptive LP Vault", "ALPV",
            address(token0), address(token1),
            decimals0, 0
        );
    }

    // totalAssets
    function test_TotalAssets_ReturnsZeroWhenVaultHasNoBalances() public {
        assertEq(vault.totalAssets(), 0);
    }

    function test_TotalAssets_ReturnsCombinedValueOfTokenBalances() public {
        uint256 price0 = 1e18;
        uint256 price1 = 5e14;
        uint256 amount0 = 1e18;
        uint256 amount1 = 2000e6;
        oracle.setPrices(price0, price1);
        token0.mint(alice, amount0);
        token1.mint(alice, amount1);

        vm.startPrank(alice);
        token0.approve(address(vault), amount0);
        token1.approve(address(vault), amount1);
        vault.deposit(amount0, amount1);
        vm.stopPrank();

        assertEq(vault.totalAssets(), 2e18);
    }

    function test_TotalAssets_RevertsWhenVaultHoldsNonZeroToken0ButPrice0IsZero() public {
        uint256 amount0 = 1e18;
        token0.mint(address(vault), amount0);
        vm.expectRevert(VaultMath.InvalidPrice.selector);
        vault.totalAssets();
    }

    function test_TotalAssets_RevertsWhenVaultHoldsNonZeroToken1ButPrice1IsZero() public {
        uint256 amount1 = 1;
        token1.mint(address(vault), amount1);
        vm.expectRevert(VaultMath.InvalidPrice.selector);
        vault.totalAssets();
    }

    // deposit
    function test_Deposit_RevertsWhenBothAmountsAreZero() public {
        vm.prank(alice);
        vm.expectRevert(AdaptiveLPVault.ZeroAmounts.selector);
        vault.deposit(0, 0);
    }

    function test_Deposit_MintsSharesEqualToAssetValueOnInitialDeposit() public {
        uint256 price0 = 1e18;
        uint256 price1 = 5e14;
        uint256 amount0 = 1e18;
        uint256 amount1 = 2000e6;
        oracle.setPrices(price0, price1);
        token0.mint(alice, amount0);
        token1.mint(alice, amount1);

        vm.startPrank(alice);
        token0.approve(address(vault), amount0);
        token1.approve(address(vault), amount1);
        uint256 shares = vault.deposit(amount0, amount1);
        vm.stopPrank();

        assertEq(shares, 2e18);
        assertEq(vault.balanceOf(alice), 2e18);
    }

    function test_Deposit_MintsProportionalSharesOnSecondDeposit() public {
        uint256 price0 = 1e18;
        uint256 price1 = 5e14;
        uint256 amount0 = 1e18;
        uint256 amount1 = 2000e6;
        oracle.setPrices(price0, price1);
        token0.mint(alice, amount0);
        token1.mint(alice, amount1);

        vm.startPrank(alice);
        token0.approve(address(vault), amount0);
        token1.approve(address(vault), amount1);
        vault.deposit(amount0, amount1);
        vm.stopPrank();
        assertEq(vault.totalAssets(), 2e18);

        price0 = 2e18;
        price1 = 5e14;
        oracle.setPrices(price0, price1);
        
        token0.mint(bob, amount0);
        vm.startPrank(bob);
        token0.approve(address(vault), amount0);
        token1.approve(address(vault), 0);
        uint256 shares = vault.deposit(amount0, 0);
        vm.stopPrank();

        uint256 assetsToDeposit = 2e18;
        uint256 totalSharesBefore = 2e18;
        uint256 totalAssetsBefore = 3e18;
        uint256 expectedShares = assetsToDeposit * totalSharesBefore / totalAssetsBefore;
        assertEq(shares, expectedShares);
        assertEq(vault.balanceOf(bob), expectedShares);
    }

    function test_Deposit_RevertsWhenCalculatedSharesWouldBeZero() public {
        uint256 price0 = 1e18;
        uint256 price1 = 1e18;
        uint256 amount0 = 1e18;
        uint256 amount1 = 0;
        oracle.setPrices(price0, price1);
        token0.mint(alice, amount0);
        token1.mint(alice, amount1);

        vm.startPrank(alice);
        token0.approve(address(vault), amount0);
        token1.approve(address(vault), amount1);
        vault.deposit(amount0, amount1);
        vm.stopPrank();
        assertEq(vault.totalAssets(), 1e18);
        assertEq(vault.totalSupply(), 1e18);

        price0 = 1e36;
        oracle.setPrices(price0, price1);
        assertEq(vault.totalAssets(), 1e36);
        assertEq(vault.totalSupply(), 1e18);

        uint256 smallAmount0 = 0;
        uint256 smallAmount1 = 1;
        token1.mint(bob, smallAmount1);
        vm.startPrank(bob);
        token0.approve(address(vault), smallAmount0);
        token1.approve(address(vault), smallAmount1);
        vm.expectRevert(VaultMath.ZeroShares.selector);
        vault.deposit(smallAmount0, smallAmount1);
        vm.stopPrank();
    }

    // redeem
    function test_Redeem_RevertsWhenUserRedeemsMoreSharesThanOwned() public {
        uint256 price0 = 1e18;
        uint256 price1 = 5e14;
        uint256 amount0 = 1e18;
        uint256 amount1 = 2000e6;
        oracle.setPrices(price0, price1);
        token0.mint(alice, amount0);
        token1.mint(alice, amount1);
        token0.mint(bob, amount0);
        token1.mint(bob, amount1);

        vm.startPrank(alice);
        token0.approve(address(vault), amount0);
        token1.approve(address(vault), amount1);
        vault.deposit(amount0, amount1);
        assertEq(vault.balanceOf(alice), 2e18);
        vm.stopPrank();

        token0.mint(bob, amount0);
        token1.mint(bob, amount1);
        vm.startPrank(bob);
        token0.approve(address(vault), amount0);
        token1.approve(address(vault), amount1);
        vault.deposit(amount0, amount1);
        assertEq(vault.balanceOf(bob), 2e18);
        vm.stopPrank();

        assertEq(vault.totalSupply(), 4e18);

        vm.startPrank(alice);
        uint256 shares = 3e18;
        vm.expectRevert(AdaptiveLPVault.InsufficientShares.selector);
        vault.redeem(shares);
        vm.stopPrank();
    }

    function test_Redeem_RevertsWhenSharesIsZero() public {
        vm.prank(alice);
        vm.expectRevert(AdaptiveLPVault.ZeroShares.selector);
        vault.redeem(0);
    }

    function test_Redeem_BurnsUserShares() public {
        uint256 price0 = 1e18;
        uint256 price1 = 5e14;
        uint256 amount0 = 1e18;
        uint256 amount1 = 2000e6;
        oracle.setPrices(price0, price1);
        token0.mint(alice, amount0);
        token1.mint(alice, amount1);
        
        vm.startPrank(alice);
        token0.approve(address(vault), amount0);
        token1.approve(address(vault), amount1);
        vault.deposit(amount0, amount1);
        assertEq(vault.balanceOf(alice), 2e18);

        uint256 shares = 1e18;
        vault.redeem(shares);
        assertEq(vault.balanceOf(alice), 1e18);
        vm.stopPrank();
    }

    function test_Redeem_ReducesTotalSupply() public {
        uint256 price0 = 1e18;
        uint256 price1 = 5e14;
        uint256 amount0 = 1e18;
        uint256 amount1 = 2000e6;
        oracle.setPrices(price0, price1);
        token0.mint(alice, amount0);
        token1.mint(alice, amount1);
        token0.mint(bob, amount0);
        token1.mint(bob, amount1);

        vm.startPrank(alice);
        token0.approve(address(vault), amount0);
        token1.approve(address(vault), amount1);
        vault.deposit(amount0, amount1);
        assertEq(vault.balanceOf(alice), 2e18);
        vm.stopPrank();

        token0.mint(bob, amount0);
        token1.mint(bob, amount1);
        vm.startPrank(bob);
        token0.approve(address(vault), amount0);
        token1.approve(address(vault), amount1);
        vault.deposit(amount0, amount1);
        assertEq(vault.balanceOf(bob), 2e18);
        vm.stopPrank();

        assertEq(vault.totalSupply(), 4e18);

        vm.startPrank(alice);
        uint256 shares = 1e18;
        vault.redeem(shares);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 1e18);
        assertEq(vault.totalSupply(), 3e18);
    }

    function test_Redeem_ReturnsProportionalUnderlyingAmounts() public {
        uint256 price0 = 1e18;
        uint256 price1 = 5e14;
        uint256 amount0 = 1e18;
        uint256 amount1 = 2000e6;
        oracle.setPrices(price0, price1);
        token0.mint(alice, amount0);
        token1.mint(alice, amount1);
        
        vm.startPrank(alice);
        token0.approve(address(vault), amount0);
        token1.approve(address(vault), amount1);
        vault.deposit(amount0, amount1);
        assertEq(vault.balanceOf(alice), 2e18);

        uint256 shares = 1e18;
        (uint256 amount0Out, uint256 amount1Out) = vault.redeem(shares);
        vm.stopPrank();

        assertEq(amount0Out, 0.5e18);
        assertEq(amount1Out, 1000e6);
    }
}
