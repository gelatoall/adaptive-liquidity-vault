// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../src/AdaptiveLPVault.sol";
import "../src/adapters/UniswapV2Adapter.sol";
import "../src/valuators/V2FairValueValuator.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockPriceOracle.sol";
import "./mocks/MockUniswapV2Pair.sol";
import "./mocks/MockUniswapV2Router.sol";
import "./helpers/TwapTestHelper.sol";
import "./helpers/VaultTestHelper.sol";
import "./helpers/VenueTestHelper.sol";

/// @title VaultV2IntegrationTest
/// @notice Integration tests for `AdaptiveLPVault` wired to `UniswapV2Adapter`.
contract VaultV2IntegrationTest is Test, TwapTestHelper, VaultTestHelper, VenueTestHelper {
    MockERC20 public token0;
    MockERC20 public token1;
    uint8 public decimals0 = 18;
    uint8 public decimals1 = 6;
    AdaptiveLPVault public vault;
    MockPriceOracle public oracle;
    V2FairValueValuator public valuator;

    MockUniswapV2Pair public pair;
    MockUniswapV2Router public router;
    UniswapV2Adapter public adapter;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    /// @notice Deploys the mock tokens, vault, pair, router, and venue used by each test.
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
        _configureMirroredPriceOracles(vault, oracle);
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
        vault.setVenue(V2_VENUE_ID, address(adapter), V2_LABEL, true);

        valuator = new V2FairValueValuator(address(adapter));
        vault.setVenueValuator(V2_VENUE_ID, address(valuator));
    }

    // ============================================
    // Integration Tests for User & vault & V2 venue
    // ============================================
    /// @notice Verifies only the vault owner can update the configured adapter.
    function test_SetVenue_RevertsWhenCallerIsNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setVenue(V2_VENUE_ID, address(adapter), V2_LABEL, true);
    }
    
    /// @notice Verifies the vault rejects a zero-address adapter configuration.
    function test_SetVenue_RevertsWhenAdapterIsZeroAddress() public {
        // vm.prank(vault.owner());
        vm.expectRevert(AdaptiveLPVault.ZeroAddress.selector);
        vault.setVenue(V2_VENUE_ID, address(0), V2_LABEL, true);
    }

    /// @notice Verifies a venue rejects a valuator bound to a different adapter.
    function test_SetVenueValuator_RevertsWhenAdapterDoesNotMatch() public {
        MockUniswapV2Pair otherPair = new MockUniswapV2Pair(address(token0), address(token1));
        MockUniswapV2Router otherRouter = new MockUniswapV2Router(otherPair);
        UniswapV2Adapter otherAdapter = new UniswapV2Adapter(
            address(vault),
            address(token0),
            address(token1),
            address(otherRouter),
            address(otherPair)
        );
        V2FairValueValuator otherValuator = new V2FairValueValuator(address(otherAdapter));

        vm.expectRevert(AdaptiveLPVault.ValuatorAdapterMismatch.selector);
        vault.setVenueValuator(V2_VENUE_ID, address(otherValuator));
    }

    /// @notice Verifies replacing an adapter clears its valuator and blocks deployment until reconfigured.
    function test_SetVenue_ReplacingAdapterClearsValuatorAndBlocksDeploy() public {
        MockUniswapV2Pair replacementPair = new MockUniswapV2Pair(address(token0), address(token1));
        MockUniswapV2Router replacementRouter = new MockUniswapV2Router(replacementPair);
        UniswapV2Adapter replacementAdapter = new UniswapV2Adapter(
            address(vault),
            address(token0),
            address(token1),
            address(replacementRouter),
            address(replacementPair)
        );

        vault.setVenue(V2_VENUE_ID, address(replacementAdapter), V2_LABEL, true);

        assertEq(address(vault.venueValuators(V2_VENUE_ID)), address(0));

        vm.expectRevert(abi.encodeWithSelector(AdaptiveLPVault.VenueValuatorNotSet.selector, V2_VENUE_ID));
        vault.deployToVenue(V2_VENUE_ID, 1 ether, 1e6, "");
    }
    
    /// @notice Verifies deployment to a venue fails when no venue has been configured.
    function test_DeployToVenue_RevertsWhenVenueNotSet() public {
        AdaptiveLPVault freshVault = new AdaptiveLPVault(
            "Adaptive LP Vault", "ALPV", 
            address(token0), address(token1), 
            decimals0, decimals1
        );
        vm.expectRevert(AdaptiveLPVault.VenueNotSet.selector);
        freshVault.deployToVenue(1, 1 ether, 1e6, "");
    }

    /// @notice Verifies only the vault owner can trigger venue deployment.
    function test_DeployToVenue_RevertsWhenCallerIsNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.deployToVenue(1, 1 ether, 1e6, "");
    }

    /// @notice Verifies venue deployment is disabled while the vault is paused.
    function test_DeployToVenue_RevertsWhenPaused() public {
        vault.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.deployToVenue(1, 1 ether, 1e6, "");
    }

    /// @notice Verifies deploying idle funds moves balances from the vault into the  LP position.
    function test_DeployToVenue_MovesIdleTokensIntoAdapterPosition() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;
        uint256 amount0Used = 8 ether;
        uint256 amount1Used = 8e6;
        uint256 liquidityMinted = 5 ether;

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        uint256 totalAssetsBefore = vault.totalAssets();
        router.setNextAddLiquidityResult(amount0Used, amount1Used, liquidityMinted);

        uint256 liquidity = vault.deployToVenue(1, amount0, amount1, "");
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
        // Fair-value calculation rounds down through integer square roots.
        assertApproxEqAbs(totalAssetsAfter, totalAssetsBefore, 1e10);
    }
    
    /// @notice Verifies withdrawal from a venue fails when no venue has been configured.
    function test_WithdrawFromVenue_RevertsWhenVenueNotSet() public {
        AdaptiveLPVault freshVault = new AdaptiveLPVault(
            "Adaptive LP Vault", "ALPV", 
            address(token0), address(token1), 
            decimals0, decimals1
        );
        vm.expectRevert(AdaptiveLPVault.VenueNotSet.selector);
        freshVault.withdrawFromVenue(1, 1 ether, "");
    }

    /// @notice Verifies only the vault owner can withdraw deployed liquidity from the adapter.
    function test_WithdrawFromVenue_RevertsWhenCallerIsNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.withdrawFromVenue(1, 1 ether, "");
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

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        router.setNextAddLiquidityResult(amount0Used, amount1Used, liquidityMinted);
        vault.deployToVenue(1, amount0, amount1, "");
        pair.setReserves(uint112(amount0Used), uint112(amount1Used));

        uint256 vaultToken0Before = token0.balanceOf(address(vault));
        uint256 vaultToken1Before = token1.balanceOf(address(vault));
        uint256 adapterLpBefore = pair.balanceOf(address(adapter));

        router.setNextRemoveLiquidityResult(amount0Out, amount1Out);
        (uint256 actual0, uint256 actual1) = vault.withdrawFromVenue(1, liquidityMinted, "");

        assertEq(actual0, amount0Out);
        assertEq(actual1, amount1Out);

        // vault receives underlying token
        assertEq(token0.balanceOf(address(vault)), vaultToken0Before + amount0Out);
        assertEq(token1.balanceOf(address(vault)), vaultToken1Before + amount1Out);
        
        // adapter'LP decreases to 0
        assertEq(pair.balanceOf(address(adapter)), adapterLpBefore - liquidityMinted);
        assertEq(pair.balanceOf(address(adapter)), 0);
    }

    /// @notice Verifies only the vault owner can execute a batch emergency exit.
    function test_EmergencyExit_RevertsWhenCallerIsNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.emergencyExit(_emptyWithdrawalParams());
    }

    /// @notice Verifies emergency exit withdraws an active V2 position and pauses the vault.
    function test_EmergencyExit_WithdrawsV2PositionAndPauses() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;
        uint256 liquidityMinted = 5 ether;

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        router.setNextAddLiquidityResult(amount0, amount1, liquidityMinted);
        vault.deployToVenue(V2_VENUE_ID, amount0, amount1, "");
        pair.setReserves(uint112(amount0), uint112(amount1));

        assertFalse(vault.paused());
        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);
        assertEq(vault.totalLiquidity(), liquidityMinted);
        assertEq(vault.venueLiquidity(V2_VENUE_ID), liquidityMinted);
        assertTrue(adapter.hasPosition());

        router.setNextRemoveLiquidityResult(amount0, amount1);
        vault.emergencyExit(_emptyWithdrawalParams());

        assertTrue(vault.paused());
        assertEq(vault.totalLiquidity(), 0);
        assertEq(vault.venueLiquidity(V2_VENUE_ID), 0);
        assertFalse(adapter.hasPosition());
        assertEq(token0.balanceOf(address(vault)), amount0);
        assertEq(token1.balanceOf(address(vault)), amount1);
    }

    /// @notice Verifies redeeming all user-owned shares preserves locked-share V2 liquidity and forwards params.
    function test_Redeem_AllUserSharesPreservesLockedV2Liquidity() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;
        uint256 amount0Used = 8 ether;
        uint256 amount1Used = 15e6;
        uint256 liquidityMinted = 5 ether;
        
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        router.setNextAddLiquidityResult(amount0Used, amount1Used, liquidityMinted);
        vault.deployToVenue(V2_VENUE_ID, amount0, amount1, "");

        uint256 amount0Min = amount0 / 2;
        uint256 amount1Min = amount1 / 2;
        uint256 deadline = block.timestamp + 1 hours;
        AdaptiveLPVault.VenueWithdrawalParams[] memory withdrawalParams =
                new AdaptiveLPVault.VenueWithdrawalParams[](1);
        withdrawalParams[0] = AdaptiveLPVault.VenueWithdrawalParams({
            venueId: V2_VENUE_ID,
            params: abi.encode(amount0Min, amount1Min, deadline)
        });

        uint256 aliceShares = vault.balanceOf(alice);

        uint256 totalSharesBefore = vault.totalSupply();
        uint256 liquidityToWithdraw = liquidityMinted * aliceShares / totalSharesBefore;
        uint256 expectedRemainingLiquidity = liquidityMinted - liquidityToWithdraw;

        uint256 venueAmount0Out = amount0Used * aliceShares / totalSharesBefore;
        uint256 venueAmount1Out = amount1Used * aliceShares / totalSharesBefore;
        router.setNextRemoveLiquidityResult(venueAmount0Out, venueAmount1Out);

        vm.prank(alice);
        (uint256 redeemAmount0, uint256 redeemAmount1) = vault.redeem(aliceShares, alice, alice, withdrawalParams, 0, 0);
        
        uint256 idleAmount0 = amount0 - amount0Used;
        uint256 idleAmount1 = amount1 - amount1Used;
        uint256 expectedAmount0Out = idleAmount0 * aliceShares / totalSharesBefore + venueAmount0Out;
        uint256 expectedAmount1Out = idleAmount1 * aliceShares / totalSharesBefore + venueAmount1Out;

        assertEq(redeemAmount0, expectedAmount0Out);
        assertEq(redeemAmount1, expectedAmount1Out);

        assertEq(vault.totalSupply(), vault.MINIMUM_LOCKED_SHARES());
        assertEq(vault.venueLiquidity(V2_VENUE_ID), expectedRemainingLiquidity);
        assertEq(vault.totalLiquidity(), expectedRemainingLiquidity);
        assertEq(pair.balanceOf(address(adapter)), expectedRemainingLiquidity);
        assertEq(vault.balanceOf(alice), 0);

        assertEq(router.lastRemoveAmountAMin(), amount0Min);
        assertEq(router.lastRemoveAmountBMin(), amount1Min);
        assertEq(router.lastRemoveDeadline(), deadline);
    }

    /// @notice Verifies partial redeem withdraws only the caller's pro-rata active V2 liquidity.
    function test_Redeem_PartiallyWithdrawsActiveV2Position() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);
        _mintAndDeposit(token0, token1, vault, bob, amount0, amount1);
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 bobShares = vault.balanceOf(bob);
        uint256 totalSharesBefore = vault.totalSupply();
        assertEq(aliceShares + vault.MINIMUM_LOCKED_SHARES(), bobShares);
        assertEq(totalSharesBefore, aliceShares + bobShares + vault.MINIMUM_LOCKED_SHARES());

        uint256 totalAmount0 = 20 ether;
        uint256 totalAmount1 = 40e6;
        uint256 liquidityMinted = 10 ether;
        router.setNextAddLiquidityResult(totalAmount0, totalAmount1, liquidityMinted);
        vault.deployToVenue(V2_VENUE_ID, totalAmount0, totalAmount1, "");

        assertEq(vault.venueLiquidity(V2_VENUE_ID), liquidityMinted);
        assertEq(vault.totalLiquidity(), liquidityMinted);

        uint256 liquidityToWithdraw = liquidityMinted * aliceShares / totalSharesBefore;
        uint256 expectedRemainingLiquidity = liquidityMinted - liquidityToWithdraw;
        uint256 expectedAmount0Out = totalAmount0 * aliceShares / totalSharesBefore;
        uint256 expectedAmount1Out = totalAmount1 * aliceShares / totalSharesBefore;
        router.setNextRemoveLiquidityResult(expectedAmount0Out, expectedAmount1Out);

        vm.prank(alice);
        (uint256 redeem0, uint256 redeem1) = vault.redeem(aliceShares, alice, alice, _emptyWithdrawalParams(), 0, 0);

        assertEq(redeem0, expectedAmount0Out);
        assertEq(redeem1, expectedAmount1Out);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), bobShares);
        assertEq(vault.totalSupply(), bobShares + vault.MINIMUM_LOCKED_SHARES());
        
        assertEq(vault.venueLiquidity(V2_VENUE_ID), expectedRemainingLiquidity);
        assertEq(vault.totalLiquidity(), expectedRemainingLiquidity);
        assertEq(pair.balanceOf(address(adapter)), expectedRemainingLiquidity);
    }

    /// @notice Redeem reverts instead of burning shares when the pro-rata venue liquidity rounds down to zero.
    function test_Redeem_RevertsWhenProRataVenueLiquidityRoundsToZero() public {
        uint256 amount0 = 1_000_000 ether;
        uint256 amount1 = 1_000_000e6;
        uint256 liquidityMinted = 1;

        uint256 shares = _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        router.setNextAddLiquidityResult(amount0, amount1, liquidityMinted);
        vault.deployToVenue(V2_VENUE_ID, amount0, amount1, "");

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);
        assertEq(vault.venueLiquidity(V2_VENUE_ID), liquidityMinted);
        assertTrue(shares > liquidityMinted);

        vm.prank(alice);
        vm.expectRevert(AdaptiveLPVault.RedeemAmountTooSmall.selector);
        vault.redeem(1, alice, alice, _emptyWithdrawalParams(), 0, 0);

        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.venueLiquidity(V2_VENUE_ID), liquidityMinted);
    }

    // ============================================
    // Integration Tests for User & vault & V2 adapter & V2 TWAP Oracle
    // ============================================
    function test_TotalAssets_IncludesDeployedPositionWithTwapOracle() public {
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
        
        uint256 amount0 = reserve0;
        uint256 amount1 = reserve1;
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);
        
        uint256 totalAssetsBeforeDeploy = vault.totalAssets();
        assertEq(totalAssetsBeforeDeploy, 2e18);

        uint256 liquidityMinted = 1e18;
        router.setNextAddLiquidityResult(amount0, amount1, liquidityMinted);
        vault.deployToVenue(1, amount0, amount1, "");
        pair.setReserves(uint112(amount0), uint112(amount1));

        uint256 totalAssetsAfterDeploy = vault.totalAssets();

        assertEq(totalAssetsBeforeDeploy, totalAssetsAfterDeploy);
        assertEq(pair.balanceOf(address(adapter)), liquidityMinted);
        
        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);
        assertEq(token0.balanceOf(address(pair)), amount0);
        assertEq(token1.balanceOf(address(pair)), amount1);
    }
}
