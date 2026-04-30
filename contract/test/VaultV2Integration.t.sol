// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/AdaptiveLPVault.sol";
import "../src/adapters/UniswapV2Adapter.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockPriceOracle.sol";
import "./mocks/MockUniswapV2Pair.sol";
import "./mocks/MockUniswapV2Router.sol";

/// @title VaultV2IntegrationTest
/// @notice Integration tests for `AdaptiveLPVault` wired to `UniswapV2Adapter`.
contract VaultV2IntegrationTest is Test {
    MockERC20 public token0;
    MockERC20 public token1;
    uint8 public decimals0 = 18;
    uint8 public decimals1 = 6;
    AdaptiveLPVault public vault;
    
    MockPriceOracle public oracle;
    MockUniswapV2Pair public pair;
    MockUniswapV2Router public router;
    UniswapV2Adapter public adapter;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    /// @notice Deploys the mock tokens, vault, pair, router, and adapter used by each test.
    function setUp() public {
        // deploy token0/token1
        token0 = new MockERC20("token0", "T0", decimals0);
        token1 = new MockERC20("token1", "T1", decimals1);

        // deploy vault
        vault = new AdaptiveLPVault(
            "Adaptive LP Vault", "ALPV", 
            address(token0), address(token1), 
            decimals0, decimals1
        );

        oracle = new MockPriceOracle();
        vault.setOracle(address(oracle));
        oracle.setPrices(1e18, 1e18);

        // deploy pair/router/adapter
        pair = new MockUniswapV2Pair(address(token0), address(token1));
        router = new MockUniswapV2Router(pair);
        adapter = new UniswapV2Adapter(
            address(vault),
            address(token0),
            address(token1),
            address(router),
            address(pair)
        );

        // set adapter into vault
        vault.setAdapter(address(adapter));
    }
    
    /// @notice Verifies the default fixture wires the vault to the configured adapter.
    function test_SetAdapter_SetsAdapterCorrectly() public {
        assertEq(address(vault.adapter()), address(adapter));
    }

    /// @notice Verifies only the vault owner can update the configured adapter.
    function test_SetAdapter_RevertsWhenCallerIsNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setAdapter(address(adapter));
    }
    
    /// @notice Verifies the vault rejects a zero-address adapter configuration.
    function test_SetAdapter_RevertsWhenAdapterIsZeroAddress() public {
        // vm.prank(vault.owner());
        vm.expectRevert(AdaptiveLPVault.ZeroAddress.selector);
        vault.setAdapter(address(0));
    }
    
    /// @notice Verifies deployment to a venue fails when no adapter has been configured.
    function test_DeployToVenue_RevertsWhenAdapterNotSet() public {
        AdaptiveLPVault freshVault = new AdaptiveLPVault(
            "Adaptive LP Vault", "ALPV", 
            address(token0), address(token1), 
            decimals0, decimals1
        );
        vm.expectRevert(AdaptiveLPVault.AdapterNotSet.selector);
        freshVault.deployToVenue(1 ether, 1e6, "");
    }

    /// @notice Verifies only the vault owner can trigger venue deployment.
    function test_DeployToVenue_RevertsWhenCallerIsNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.deployToVenue(1 ether, 1e6, "");
    }

    /// @notice Verifies deploying idle funds moves balances from the vault into the adapter LP position.
    function test_DeployToVenue_MovesIdleTokensIntoAdapterPosition() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;
        uint256 amount0Used = 8 ether;
        uint256 amount1Used = 15e6;
        uint256 liquidityMinted = 5 ether;
        token0.mint(alice, amount0);
        token1.mint(alice, amount1);

        vm.startPrank(alice);
        token0.approve(address(vault), amount0);
        token1.approve(address(vault), amount1);
        vault.deposit(amount0, amount1);
        vm.stopPrank();

        uint256 totalAssetsBefore = vault.totalAssets();
        router.setNextAddLiquidityResult(amount0Used, amount1Used, liquidityMinted);

        uint256 liquidity = vault.deployToVenue(amount0, amount1, "");
        pair.setReserves(uint112(amount0Used), uint112(amount1Used));
        uint256 totalAssetsAfter = vault.totalAssets();

        assertEq(liquidity, liquidityMinted);
        // adapter gets LP token
        assertEq(pair.balanceOf(address(adapter)), liquidityMinted);
        // correct amount of dust is left in vault
        assertEq(token0.balanceOf(address(vault)), amount0 - amount0Used);
        assertEq(token1.balanceOf(address(vault)), amount1 - amount1Used);
        // adapter didn't have token, but pair does.
        assertEq(token0.balanceOf(address(pair)), amount0Used);
        assertEq(token0.balanceOf(address(adapter)), 0);
        assertEq(token1.balanceOf(address(adapter)), 0);
        // totalAsset stays the same
        assertEq(totalAssetsBefore, totalAssetsAfter);
    }
    
    /// @notice Verifies withdrawal from a venue fails when no adapter has been configured.
    function test_WithdrawFromVenue_RevertsWhenAdapterNotSet() public {
        AdaptiveLPVault freshVault = new AdaptiveLPVault(
            "Adaptive LP Vault", "ALPV", 
            address(token0), address(token1), 
            decimals0, decimals1
        );
        vm.expectRevert(AdaptiveLPVault.AdapterNotSet.selector);
        freshVault.withdrawFromVenue(1 ether);
    }

    /// @notice Verifies only the vault owner can withdraw deployed liquidity from the adapter.
    function test_WithdrawFromVenue_RevertsWhenCallerIsNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.withdrawFromVenue(1 ether);
    }

    /// @notice Verifies withdrawing from the venue returns the underlying tokens back to the vault.
    function test_WithdrawFromVenue_ReturnsUnderlyingBackToVault() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;
        uint256 amount0Used = 8 ether;
        uint256 amount1Used = 15e6;
        uint256 liquidityMinted = 5 ether;

        uint256 amount0Out = 3 ether;
        uint256 amount1Out = 7e6;

        token0.mint(alice, amount0);
        token1.mint(alice, amount1);

        vm.startPrank(alice);
        token0.approve(address(vault), amount0);
        token1.approve(address(vault), amount1);
        vault.deposit(amount0, amount1);
        vm.stopPrank();

        router.setNextAddLiquidityResult(amount0Used, amount1Used, liquidityMinted);
        vault.deployToVenue(amount0, amount1, "");
        pair.setReserves(uint112(amount0Used), uint112(amount1Used));

        uint256 vaultToken0Before = token0.balanceOf(address(vault));
        uint256 vaultToken1Before = token1.balanceOf(address(vault));
        uint256 adapterLpBefore = pair.balanceOf(address(adapter));

        router.setNextRemoveLiquidityResult(amount0Out, amount1Out);
        (uint256 actual0, uint256 actual1) = vault.withdrawFromVenue(liquidityMinted);

        assertEq(actual0, amount0Out);
        assertEq(actual1, amount1Out);

        // vault receives underlying token
        assertEq(token0.balanceOf(address(vault)), vaultToken0Before + amount0Out);
        assertEq(token1.balanceOf(address(vault)), vaultToken1Before + amount1Out);
        
        // adapter'LP decreases to 0
        assertEq(pair.balanceOf(address(adapter)), adapterLpBefore - liquidityMinted);
        assertEq(pair.balanceOf(address(adapter)), 0);
    }

    /// @notice Verifies users cannot redeem while the vault still has an active deployed position.
    function test_Redeem_RevertsWhenAdapterHasActivePosition() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;
        uint256 amount0Used = 8 ether;
        uint256 amount1Used = 15e6;
        uint256 liquidityMinted = 5 ether;
        token0.mint(alice, amount0);
        token1.mint(alice, amount1);

        vm.startPrank(alice);
        token0.approve(address(vault), amount0);
        token1.approve(address(vault), amount1);
        vault.deposit(amount0, amount1);
        vm.stopPrank();

        router.setNextAddLiquidityResult(amount0Used, amount1Used, liquidityMinted);
        vault.deployToVenue(amount0, amount1, "");

        uint256 aliceShares = vault.balanceOf(alice);

        vm.expectRevert(AdaptiveLPVault.ActivePositionExists.selector);
        vm.prank(alice);
        vault.redeem(aliceShares);
    }

    /// @notice Verifies redemption succeeds again after the owner withdraws the deployed position back to the vault.
    function test_Redeem_WorksAfterWithdrawFromVenue() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;
        uint256 amount0Used = 8 ether;
        uint256 amount1Used = 15e6;
        uint256 liquidityMinted = 5 ether;

        uint256 amount0OutFromWithdraw = 3 ether;
        uint256 amount1OutFromWithdraw = 7e6;

        token0.mint(alice, amount0);
        token1.mint(alice, amount1);

        vm.startPrank(alice);
        token0.approve(address(vault), amount0);
        token1.approve(address(vault), amount1);
        vault.deposit(amount0, amount1);
        vm.stopPrank();

        uint256 aliceShares = vault.balanceOf(alice);
        assertEq(aliceShares, 30 ether);

        router.setNextAddLiquidityResult(amount0Used, amount1Used, liquidityMinted);
        vault.deployToVenue(amount0, amount1, "");

        vm.expectRevert(AdaptiveLPVault.ActivePositionExists.selector);
        vm.prank(alice);
        vault.redeem(aliceShares);

        router.setNextRemoveLiquidityResult(amount0OutFromWithdraw, amount1OutFromWithdraw);
        vault.withdrawFromVenue(liquidityMinted);
        assertEq(pair.balanceOf(address(adapter)), 0);  // adapter doesn't have LP tokens

        vm.prank(alice);
        (uint256 redeemAmount0, uint256 redeemAmount1) = vault.redeem(aliceShares);
        assertEq(redeemAmount0, amount0 - amount0Used + amount0OutFromWithdraw);
        assertEq(redeemAmount1, amount1 - amount1Used + amount1OutFromWithdraw);
        assertEq(vault.balanceOf(alice), 0);    // Alice doesn't have shares in the vault
        assertEq(vault.totalSupply(), 0);       // No shares in the vault
    }
}
