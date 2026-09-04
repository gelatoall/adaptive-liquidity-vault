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

    /// @notice Deployment reverts when it would consume the configured idle buffer.
    function test_DeployToVenue_RevertsWhenIdleBufferWouldBeViolated() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        // The 30e18 total value requires a 6e18 idle buffer at 20%.
        vault.setMinIdleBufferBps(2000);

        // Deploying 27e18 of value would leave only 3e18 idle, below the 6e18 requirement.
        vm.expectRevert(abi.encodeWithSelector(AdaptiveLPVault.IdleBufferViolation.selector, 6 ether, 3 ether));
        vault.deployToVenue(V2_VENUE_ID, 9 ether, 18e6, "");
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

    /// @notice Verifies a router callback cannot reenter the vault during V2 deployment.
    function test_DeployToVenue_RevertsWhenRouterReentersVault() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2e6;

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        router.setReentryVault(vault);
        router.setNextAddLiquidityResult(amount0, amount1, 1 ether);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vault.deployToVenue(V2_VENUE_ID, amount0, amount1, "");

        // The complete outer transaction was rolled back.
        assertEq(vault.venueLiquidity(V2_VENUE_ID), 0);
        assertEq(token0.balanceOf(address(vault)), amount0);
        assertEq(token1.balanceOf(address(vault)), amount1);
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
        assertEq(vault.venueLiquidity(V2_VENUE_ID), liquidityMinted);
        assertTrue(adapter.hasPosition());

        router.setNextRemoveLiquidityResult(amount0, amount1);
        vault.emergencyExit(_emptyWithdrawalParams());

        assertTrue(vault.paused());
        assertEq(vault.venueLiquidity(V2_VENUE_ID), 0);
        assertFalse(adapter.hasPosition());
        assertEq(token0.balanceOf(address(vault)), amount0);
        assertEq(token1.balanceOf(address(vault)), amount1);
    }

    /// @notice Redeem uses idle balances without removing active V2 liquidity.
    function test_Redeem_UsesIdleBufferWithoutRemovingV2Position() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;
        // Alice and Bob deposit a total of 20 token0 and 40 token1.
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);
        _mintAndDeposit(token0, token1, vault, bob, amount0, amount1);
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 bobShares = vault.balanceOf(bob);
        uint256 totalSharesBefore = vault.totalSupply();

        // Deploy only part of the vault assets, leaving enough idle liquidity.
        uint256 deployedAmount0 = 4 ether;
        uint256 deployedAmount1 = 8e6;
        uint256 liquidityMinted = 2 ether;

        router.setNextAddLiquidityResult(deployedAmount0, deployedAmount1, liquidityMinted);
        vault.deployToVenue(V2_VENUE_ID, deployedAmount0, deployedAmount1, "");
        // The trusted V2 valuator needs valid pool reserves.
        pair.setReserves(uint112(deployedAmount0), uint112(deployedAmount1));

        assertEq(vault.venueLiquidity(V2_VENUE_ID), liquidityMinted);
        assertEq(pair.balanceOf(address(adapter)), liquidityMinted);

        // Calculate the idle-only redemption quote before changing balances.
        uint256 idle0Before = token0.balanceOf(address(vault));
        uint256 idle1Before = token1.balanceOf(address(vault));

        // Both oracle prices are 1e18. token1 has 6 decimals, so convert it
        // into the vault's 1e18 base-value precision.
        uint256 idleValue = idle0Before + idle1Before * 1e12;
        uint256 redeemValue = vault.totalAssets() * aliceShares / totalSharesBefore;
        uint256 expectedAmount0Out = idle0Before * redeemValue / idleValue;
        uint256 expectedAmount1Out = idle1Before * redeemValue / idleValue;

        vm.prank(alice);
        (uint256 amount0Out, uint256 amount1Out) = vault.redeem(aliceShares, alice, alice, 0, 0);

        assertEq(amount0Out, expectedAmount0Out);
        assertEq(amount1Out, expectedAmount1Out);
        // Alice's shares were burned.
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), bobShares);
        assertEq(vault.totalSupply(), bobShares + vault.MINIMUM_LOCKED_SHARES());

        // Redeem did not remove any V2 liquidity.
        assertEq(vault.venueLiquidity(V2_VENUE_ID), liquidityMinted);
        assertEq(pair.balanceOf(address(adapter)), liquidityMinted);
        assertTrue(adapter.hasPosition());
    }

    /// @notice Redeem preserves shares when the idle buffer cannot cover the requested value.
    function test_Redeem_RevertsWhenIdleLiquidityIsInsufficient() public {
        uint256 amount0 = 1_000_000 ether;
        uint256 amount1 = 1_000_000e6;
        uint256 liquidityMinted = 1;

        uint256 shares = _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        router.setNextAddLiquidityResult(amount0, amount1, liquidityMinted);
        vault.deployToVenue(V2_VENUE_ID, amount0, amount1, "");
        pair.setReserves(uint112(amount0), uint112(amount1));

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);

        vm.expectRevert(abi.encodeWithSelector(AdaptiveLPVault.InsufficientIdleLiquidity.selector, 1, 0));
        vm.prank(alice);
        vault.redeem(1, alice, alice, 0, 0);

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
