// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../src/AdaptiveLPVault.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockPriceOracle.sol";
import "./helpers/TwapTestHelper.sol";
import "./helpers/VaultTestHelper.sol";

contract VaultTest is Test, TwapTestHelper, VaultTestHelper {
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
        vault.setPriceOracle(address(oracle));
    }

    // ============================================
    // Unit Tests
    // ============================================
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

    // pause
    /// @notice Verifies the owner can pause and unpause the vault.
    function test_PauseAndUnpause_UpdatesPausedState() public {
        assertFalse(vault.paused());

        vault.pause();
        assertTrue(vault.paused());

        vault.unpause();
        assertFalse(vault.paused());
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
        
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

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
        vault.deposit(0, 0, alice, 0);
    }

    function test_Deposit_MintsSharesEqualToAssetValueOnInitialDeposit() public {
        uint256 price0 = 1e18;
        uint256 price1 = 5e14;
        uint256 amount0 = 1e18;
        uint256 amount1 = 2000e6;
        oracle.setPrices(price0, price1);

        uint256 shares = _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        assertEq(shares, 2e18);
        assertEq(vault.balanceOf(alice), 2e18);
    }

    function test_Deposit_MintsProportionalSharesOnSecondDeposit() public {
        uint256 price0 = 1e18;
        uint256 price1 = 5e14;
        uint256 amount0 = 1e18;
        uint256 amount1 = 2000e6;
        oracle.setPrices(price0, price1);
        
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);
        assertEq(vault.totalAssets(), 2e18);

        price0 = 2e18;
        price1 = 5e14;
        oracle.setPrices(price0, price1);
        
        token0.mint(bob, amount0);
        vm.startPrank(bob);
        token0.approve(address(vault), amount0);
        token1.approve(address(vault), 0);
        uint256 shares = vault.deposit(amount0, 0, bob, 0);
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
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);
        
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
        vault.deposit(smallAmount0, smallAmount1, bob, 0);
        vm.stopPrank();
    }

    /// @notice Verifies deposit reverts when minted shares are below the caller's minimum.
    function test_Deposit_RevertsWhenSharesBelowMinimum() public {
        uint256 amount0 = 1e18;
        uint256 amount1 = 2000e6;
        oracle.setPrices(1e18, 5e14);

        token0.mint(alice, amount0);
        token1.mint(alice, amount1);

        vm.startPrank(alice);
        token0.approve(address(vault), amount0);
        token1.approve(address(vault), amount1);

        vm.expectRevert(AdaptiveLPVault.InsufficientSharesOut.selector);
        vault.deposit(amount0, amount1, alice, type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Verifies deposits are blocked while the vault is paused.
    function test_Deposit_RevertsWhenPaused() public {
        vault.pause();

        uint256 amount0 = 1e18;
        uint256 amount1 = 2000e6;
        token0.mint(alice, amount0);
        token1.mint(alice, amount1);

        vm.startPrank(alice);
        token0.approve(address(vault), amount0);
        token1.approve(address(vault), amount1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.deposit(amount0, amount1, alice, 0);
        vm.stopPrank();
    }

    /// @notice Verifies deposit pulls tokens from the caller while minting shares to a separate receiver.
    function test_Deposit_MintsSharesToReceiver() public {
        uint256 price0 = 1e18;
        uint256 price1 = 5e14;
        uint256 amount0 = 1e18;
        uint256 amount1 = 2000e6;
        oracle.setPrices(price0, price1);

        uint256 shares = _mintAndDepositToReceiver(token0, token1, vault, alice, bob, amount0, amount1);

        assertEq(shares, 2e18);
        
        // Alice supplies the underlying tokens to the vault.
        assertEq(token0.balanceOf(alice), 0);
        assertEq(token1.balanceOf(alice), 0);
        assertEq(token0.balanceOf(address(vault)), amount0);
        assertEq(token1.balanceOf(address(vault)), amount1);

        // Bob receives the minted shares.
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), shares);
    }

    // redeem
    /// @notice Verifies users can still redeem idle balances while the vault is paused.
    function test_Redeem_WorksWhenPaused() public {
        uint256 price0 = 1e18;
        uint256 price1 = 5e14;
        uint256 amount0 = 1e18;
        uint256 amount1 = 2000e6;
        oracle.setPrices(price0, price1);

        uint256 shares = _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        vault.pause();

        vm.prank(alice);
        (uint256 amount0Out, uint256 amount1Out) = vault.redeem(shares, alice, alice, _emptyWithdrawalParams(), 0, 0);

        assertEq(amount0Out, amount0);
        assertEq(amount1Out, amount1);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_Redeem_RevertsWhenUserRedeemsMoreSharesThanOwned() public {
        uint256 price0 = 1e18;
        uint256 price1 = 5e14;
        uint256 amount0 = 1e18;
        uint256 amount1 = 2000e6;
        oracle.setPrices(price0, price1);
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);
        assertEq(vault.balanceOf(alice), 2e18);

        _mintAndDeposit(token0, token1, vault, bob, amount0, amount1);
        assertEq(vault.balanceOf(bob), 2e18);

        assertEq(vault.totalSupply(), 4e18);

        vm.startPrank(alice);
        uint256 shares = 3e18;
        vm.expectRevert(AdaptiveLPVault.InsufficientShares.selector);
        vault.redeem(shares, alice, alice, _emptyWithdrawalParams(), 0, 0);
        vm.stopPrank();
    }

    function test_Redeem_RevertsWhenSharesIsZero() public {
        vm.prank(alice);
        vm.expectRevert(AdaptiveLPVault.ZeroShares.selector);
        vault.redeem(0, alice, alice, _emptyWithdrawalParams(), 0, 0);
    }

    function test_Redeem_BurnsUserShares() public {
        uint256 price0 = 1e18;
        uint256 price1 = 5e14;
        uint256 amount0 = 1e18;
        uint256 amount1 = 2000e6;
        oracle.setPrices(price0, price1);
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);
        assertEq(vault.balanceOf(alice), 2e18);

        uint256 shares = 1e18;
        vm.prank(alice);
        vault.redeem(shares, alice, alice, _emptyWithdrawalParams(), 0, 0);
        assertEq(vault.balanceOf(alice), 1e18);
    }

    function test_Redeem_ReducesTotalSupply() public {
        uint256 price0 = 1e18;
        uint256 price1 = 5e14;
        uint256 amount0 = 1e18;
        uint256 amount1 = 2000e6;
        oracle.setPrices(price0, price1);

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);
        assertEq(vault.balanceOf(alice), 2e18);

        _mintAndDeposit(token0, token1, vault, bob, amount0, amount1);
        assertEq(vault.balanceOf(bob), 2e18);
    
        assertEq(vault.totalSupply(), 4e18);

        uint256 shares = 1e18;
        vm.prank(alice);
        vault.redeem(shares, alice, alice, _emptyWithdrawalParams(), 0, 0);

        assertEq(vault.balanceOf(alice), 1e18);
        assertEq(vault.totalSupply(), 3e18);
    }

    function test_Redeem_ReturnsProportionalUnderlyingAmounts() public {
        uint256 price0 = 1e18;
        uint256 price1 = 5e14;
        uint256 amount0 = 1e18;
        uint256 amount1 = 2000e6;
        oracle.setPrices(price0, price1);
        
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);
        assertEq(vault.balanceOf(alice), 2e18);
        
        uint256 shares = 1e18;
        vm.prank(alice);
        (uint256 amount0Out, uint256 amount1Out) = vault.redeem(shares, alice, alice, _emptyWithdrawalParams(), 0, 0);

        assertEq(amount0Out, 0.5e18);
        assertEq(amount1Out, 1000e6);
    }

    /// @notice Verifies redeem reverts when token output is below the owner's minimum.
    function test_Redeem_RevertsWhenOutputBelowMinimum() public {
        uint256 price0 = 1e18;
        uint256 price1 = 5e14;
        uint256 amount0 = 1e18;
        uint256 amount1 = 2000e6;
        oracle.setPrices(price0, price1);

        uint256 shares = _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        vm.prank(alice);
        vm.expectRevert(AdaptiveLPVault.InsufficientRedeemOutput.selector);
        vault.redeem(shares, alice, alice, _emptyWithdrawalParams(), amount0 + 1, amount1);
    }

    /// @notice Verifies an approved operator can burn owner shares and send underlying tokens to a separate receiver.
    function test_Redeem_AllowsApprovedOperatorToRedeemOwnerSharesToReceiver() public {
        uint256 price0 = 1e18;
        uint256 price1 = 5e14;
        uint256 amount0 = 1e18;
        uint256 amount1 = 2000e6;
        oracle.setPrices(price0, price1);

        uint256 shares = _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        address operator = makeAddr("operator");

        vm.prank(alice);
        vault.approve(operator, shares);
        assertEq(vault.allowance(alice, operator), shares);

        vm.prank(operator);
        (uint256 amount0Out, uint256 amount1Out) =
            vault.redeem(shares, bob, alice, _emptyWithdrawalParams(), 0, 0);

        assertEq(amount0Out, amount0);
        assertEq(amount1Out, amount1);

        // Alice's shares are burned.
        assertEq(vault.balanceOf(alice), 0);

        // Operator only initiated the redeem; it receives neither shares nor tokens.
        assertEq(vault.balanceOf(operator), 0);
        assertEq(token0.balanceOf(operator), 0);
        assertEq(token1.balanceOf(operator), 0);

        // Bob receives the underlying tokens.
        assertEq(token0.balanceOf(bob), amount0);
        assertEq(token1.balanceOf(bob), amount1);

        // Allowance was consumed.
        assertEq(vault.allowance(alice, operator), 0);
    }


    // ============================================
    // Integration Tests
    // ============================================
    function test_Integration_Deposit_RevertsBeforeTwapIsInitialized() public {
        uint32 interval = 300;
        (, V2TWAPOracle twap) = _deployTwapOracleButNotUpdate(
            token0,
            token1,
            vault,
            interval
        );
        
        uint256 amount0 = 1e18;
        uint256 amount1 = 2000e6;
        token0.mint(alice, amount0);
        token1.mint(alice, amount1);

        vm.startPrank(alice);
        token0.approve(address(vault), amount0);
        token1.approve(address(vault), amount1);

        vm.expectRevert(V2TWAPOracle.NotInitialized.selector);
        vault.deposit(amount0, amount1, alice, 0);
        vm.stopPrank();
    }

    function test_Integration_Deposit_WorksAfterTwapUpdate() public {
        uint32 interval = 300;
        uint256 q112 = 2 ** 112;
        uint256 reserve0 = 1 ether;
        uint256 reserve1 = 2000e6;
        uint256 avg0X112 = reserve1 * q112 / reserve0;
        uint256 avg1X112 = reserve0 * q112 / reserve1;

        (MockUniswapV2Pair twapPair, V2TWAPOracle twap) = _deployTwapOracleButNotUpdate(
            token0,
            token1,
            vault,
            interval
        );
        _primeTwap(twapPair, twap, interval, avg0X112, avg1X112);
        assertTrue(twap.initialized());
        
        (uint256 price0, uint256 price1) = twap.getPrices();
        assertEq(price0, 1e18, "twap price0");
        assertApproxEqAbs(price1, 0.0005 ether, 1, "twap price1");

        uint256 amount0 = 1e18;
        uint256 amount1 = 1e6;
        uint256 mintShares = _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        uint256 expectedAssets = 1e18 + 5e14;
        assertEq(mintShares, expectedAssets);
        assertEq(vault.balanceOf(alice), expectedAssets, "shares minted from twap-priced assets");
    }

    function test_Integration_TotalAssets_WorksWithTwapOracleAfterUpdate() public {
        uint32 interval = 300;
        uint256 q112 = 2 ** 112;
        uint256 reserve0 = 1 ether;
        uint256 reserve1 = 2000e6;
        uint256 avg0X112 = reserve1 * q112 / reserve0;
        uint256 avg1X112 = reserve0 * q112 / reserve1;

        (MockUniswapV2Pair twapPair, V2TWAPOracle twap) = _deployTwapOracleButNotUpdate(
            token0,
            token1,
            vault,
            interval
        );
        _primeTwap(twapPair, twap, interval, avg0X112, avg1X112);
        
        uint256 amount0 = 1e18;
        uint256 amount1 = 1e6;

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);
        
        assertEq(vault.totalAssets(), 1e18 + 5e14);
    }
}
