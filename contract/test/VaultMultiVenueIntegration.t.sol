// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/AdaptiveLPVault.sol";
import "../src/adapters/UniswapV2Adapter.sol";
import "../src/adapters/UniswapV3Adapter.sol";
import "../src/valuators/V2FairValueValuator.sol";
import "../src/valuators/V3TwapPositionValuator.sol";
import "../src/redemption/RedemptionManager.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockPriceOracle.sol";
import "./mocks/MockUniswapV2Pair.sol";
import "./mocks/MockUniswapV2Router.sol";
import "./mocks/MockUniswapV3Pool.sol";
import "./mocks/MockNonfungiblePositionManager.sol";
import "../test/helpers/VaultTestHelper.sol";
import "../test/helpers/VenueTestHelper.sol";

contract VaultMultiVenueIntegrationTest is Test, VaultTestHelper, VenueTestHelper {
    MockERC20 public token0;
    MockERC20 public token1;
    AdaptiveLPVault public vault;
    MockPriceOracle public oracle;
    V2FairValueValuator public valuatorV2;
    V3TwapPositionValuator public valuatorV3;
    
    MockUniswapV2Pair public pairV2;
    MockUniswapV2Router public routerV2;
    UniswapV2Adapter public adapterV2;

    MockUniswapV3Pool public poolV3Low;
    MockNonfungiblePositionManager public positionManagerV3Low;
    UniswapV3Adapter public adapterV3Low;

    RedemptionManager public redemptionManager;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint8 public decimals0 = 18;
    uint8 public decimals1 = 6;
    uint24 public fee = 500;
    int24 public tickLower = -600;
    int24 public tickUpper = 600;
    uint32 public twapWindow = 1800;

    function setUp() public {
        token0 = new MockERC20("token0", "T0", decimals0);
        token1 = new MockERC20("token1", "T1", decimals1);

        vault = new AdaptiveLPVault(
            "Adaptive LP Vault", "ALPV", 
            address(token0), address(token1), 
            decimals0, decimals1
        );

        oracle = new MockPriceOracle();
        _configureMirroredPriceOracles(vault, oracle);
        oracle.setPrices(1e18, 1e18);

        // deploy V2 venue
        pairV2 = new MockUniswapV2Pair(address(token0), address(token1));
        routerV2 = new MockUniswapV2Router(pairV2);
        adapterV2 = new UniswapV2Adapter(
            address(vault),
            address(token0),
            address(token1),
            address(routerV2),
            address(pairV2)
        );

        // deploy V3 low venue
        poolV3Low = new MockUniswapV3Pool(address(token0), address(token1), fee);
        poolV3Low.setSlot0FromTick(0);
        positionManagerV3Low = new MockNonfungiblePositionManager();
        adapterV3Low = new UniswapV3Adapter(
            address(vault), 
            address(token0),
            address(token1),
            address(positionManagerV3Low),
            address(poolV3Low),
            tickLower,
            tickUpper
        );

        vault.setVenue(V2_VENUE_ID, address(adapterV2), V2_LABEL, true);
        vault.setVenue(V3_LOW_VENUE_ID, address(adapterV3Low), V3_LOW_LABEL, true);

        poolV3Low.setTwapTick(0);
        vm.warp(block.timestamp + twapWindow);
        valuatorV2 = new V2FairValueValuator(address(adapterV2));
        valuatorV3 = new V3TwapPositionValuator(address(adapterV3Low), twapWindow);
        vault.setVenueValuator(V2_VENUE_ID, address(valuatorV2));
        vault.setVenueValuator(V3_LOW_VENUE_ID, address(valuatorV3));

        redemptionManager = new RedemptionManager(address(vault));
        vault.setRedemptionManager(address(redemptionManager));
    }

    /// @notice Returns only the lifecycle status from the public request getter.
    function _getRedeemRequestStatus(uint256 requestId) internal view returns (RedemptionManager.RedeemRequestStatus status) {
        (,,,,,, status) = redemptionManager.redeemRequests(requestId);
    }

    /// @notice Verifies the full Uniswap venue set uses one V2 adapter plus one V3 adapter per fee tier.
    function test_SetVenue_RegistersFullUniswapVenueSet() public {
        // deploy V3 mid venue
        MockUniswapV3Pool poolV3Mid = new MockUniswapV3Pool(address(token0), address(token1), 3000);
        MockNonfungiblePositionManager positionManagerV3Mid = new MockNonfungiblePositionManager();
        UniswapV3Adapter adapterV3Mid = new UniswapV3Adapter(
            address(vault), 
            address(token0),
            address(token1),
            address(positionManagerV3Mid),
            address(poolV3Mid),
            tickLower,
            tickUpper
        );
        // deploy V3 high venue
        MockUniswapV3Pool poolV3High = new MockUniswapV3Pool(address(token0), address(token1), 10000);
        MockNonfungiblePositionManager positionManagerV3High = new MockNonfungiblePositionManager();
        UniswapV3Adapter adapterV3High = new UniswapV3Adapter(
            address(vault), 
            address(token0),
            address(token1),
            address(positionManagerV3High),
            address(poolV3High),
            tickLower,
            tickUpper
        );
        vault.setVenue(V3_MID_VENUE_ID, address(adapterV3Mid), V3_MID_LABEL, true);
        vault.setVenue(V3_HIGH_VENUE_ID, address(adapterV3High), V3_HIGH_LABEL, true);

        assertTrue(vault.venueRegistered(V2_VENUE_ID));
        assertTrue(vault.venueRegistered(V3_LOW_VENUE_ID));
        assertTrue(vault.venueRegistered(V3_MID_VENUE_ID));
        assertTrue(vault.venueRegistered(V3_HIGH_VENUE_ID));

        assertEq(vault.venueIds(0), V2_VENUE_ID);
        assertEq(vault.venueIds(1), V3_LOW_VENUE_ID);
        assertEq(vault.venueIds(2), V3_MID_VENUE_ID);
        assertEq(vault.venueIds(3), V3_HIGH_VENUE_ID);

        (IVenueAdapter v2Adapter, bool v2Enabled, bytes32 v2Label) = vault.venues(V2_VENUE_ID);
        assertEq(address(v2Adapter), address(adapterV2));
        assertTrue(v2Enabled);
        assertEq(v2Label, V2_LABEL);

        (IVenueAdapter v3AdapterLow, bool v3EnabledLow, bytes32 v3LabelLow) = vault.venues(V3_LOW_VENUE_ID);
        assertEq(address(v3AdapterLow), address(adapterV3Low));
        assertTrue(v3EnabledLow);
        assertEq(v3LabelLow, V3_LOW_LABEL);

        (IVenueAdapter v3AdapterMid, bool v3EnabledMid, bytes32 v3LabelMid) = vault.venues(V3_MID_VENUE_ID);
        assertEq(address(v3AdapterMid), address(adapterV3Mid));
        assertTrue(v3EnabledMid);
        assertEq(v3LabelMid, V3_MID_LABEL);

        (IVenueAdapter v3AdapterHigh, bool v3EnabledHigh, bytes32 v3LabelHigh) = vault.venues(V3_HIGH_VENUE_ID);
        assertEq(address(v3AdapterHigh), address(adapterV3High));
        assertTrue(v3EnabledHigh);
        assertEq(v3LabelHigh, V3_HIGH_LABEL);

        assertTrue(address(adapterV3Low) != address(adapterV3Mid));
        assertTrue(address(adapterV3Low) != address(adapterV3High));
        assertTrue(address(adapterV3Mid) != address(adapterV3High));

        assertEq(poolV3Low.fee(), 500);
        assertEq(poolV3Mid.fee(), 3000);
        assertEq(poolV3High.fee(), 10000);

        assertEq(poolV3Low.tickSpacing(), 10);
        assertEq(poolV3Mid.tickSpacing(), 60);
        assertEq(poolV3High.tickSpacing(), 200);
    }

    function test_SetVenue_RevertsWhenVenueHasActiveLiquidity() public {
        _mintAndDeposit(token0, token1, vault, alice, 10 ether, 20e6);

        uint256 v2Amount0 = 6 ether;
        uint256 v2Amount1 = 12e6;
        uint256 v2Liquidity = 3 ether;
        _deployVaultToV2(vault, routerV2, V2_VENUE_ID, v2Amount0, v2Amount1, v2Amount0, v2Amount1, v2Liquidity);
        assertTrue(adapterV2.hasPosition());

        MockUniswapV2Pair newPair = new MockUniswapV2Pair(address(token0), address(token1));
        MockUniswapV2Router newRouter = new MockUniswapV2Router(newPair);
        UniswapV2Adapter newAdapter = new UniswapV2Adapter(
            address(vault),
            address(token0),
            address(token1),
            address(newRouter),
            address(newPair)
        );
        vm.expectRevert(AdaptiveLPVault.ActivePositionExists.selector);
        vault.setVenue(V2_VENUE_ID, address(newAdapter), bytes32("V2_NEW"), true);
    }

    /// @notice Verifies a disabled inactive venue and its configuration can be removed.
    function test_RemoveVenue_RemovesDisabledInactiveVenue() public {
        // setUp registers [V2, V3_LOW].
        assertEq(vault.venueCount(), 2);
        assertEq(vault.venueIds(0), V2_VENUE_ID);
        assertEq(vault.venueIds(1), V3_LOW_VENUE_ID);

        // A venue must be disabled before removal.
        vault.setVenue(V2_VENUE_ID, address(adapterV2), V2_LABEL, false);
        vault.removeVenue(V2_VENUE_ID);

        // V2 registry and associated configuration are cleared.
        assertFalse(vault.venueRegistered(V2_VENUE_ID));
        assertEq(vault.venueLiquidity(V2_VENUE_ID), 0);
        assertEq(address(vault.venueValuators(V2_VENUE_ID)), address(0));
        (IVenueAdapter removedAdapter,bool removedEnabled, bytes32 removedLabel) = vault.venues(V2_VENUE_ID);
        assertEq(address(removedAdapter), address(0));
        assertFalse(removedEnabled);
        assertEq(removedLabel, bytes32(0));

        // Swap-and-pop moves V3_LOW into the removed V2 slot.
        assertEq(vault.venueCount(), 1);
        assertEq(vault.venueIds(0), V3_LOW_VENUE_ID);
        // The remaining venue is unaffected.
        assertTrue(vault.venueRegistered(V3_LOW_VENUE_ID));
        assertEq(address(vault.venueValuators(V3_LOW_VENUE_ID)), address(valuatorV3));
    }

    function test_DeployToVenue_TracksPerVenueLiquidity() public {
        _mintAndDeposit(token0, token1, vault, alice, 10 ether, 20e6);

        uint256 v2Amount0 = 6 ether;
        uint256 v2Amount1 = 12e6;
        uint256 v2Liquidity = 3 ether;

        uint256 v3Amount0 = 4 ether;
        uint256 v3Amount1 = 8e6;

        _deployVaultToV2(vault, routerV2, V2_VENUE_ID, v2Amount0, v2Amount1, v2Amount0, v2Amount1, v2Liquidity);
        uint256 v3Liquidity = _deployVaultToV3(vault, token0, token1, poolV3Low, positionManagerV3Low, 
                                    V3_LOW_VENUE_ID, tickLower, tickUpper, v3Amount0, v3Amount1);

        assertEq(vault.venueLiquidity(V2_VENUE_ID), v2Liquidity);
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), v3Liquidity);
        assertEq(vault.totalLiquidity(), v2Liquidity + v3Liquidity);

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);
        assertEq(token0.balanceOf(address(pairV2)), v2Amount0);
        assertEq(token1.balanceOf(address(pairV2)), v2Amount1);
        assertEq(token0.balanceOf(address(positionManagerV3Low)), v3Amount0);
        assertEq(token1.balanceOf(address(positionManagerV3Low)), v3Amount1);
    }

    function test_DeployToVenue_RevertsWhenVenueDisabled() public {
        vault.setVenue(V2_VENUE_ID, address(adapterV2), V2_LABEL, false);

        _mintAndDeposit(token0, token1, vault, alice, 10 ether, 20e6);

        vm.expectRevert(AdaptiveLPVault.VenueDisabled.selector);
        vault.deployToVenue(V2_VENUE_ID, 1 ether, 2e6, "");
    }

    function test_DeployToVenue_RevertsWhenVenueNotSet() public {
        uint256 unknownVenueId = 999;
        _mintAndDeposit(token0, token1, vault, alice, 10 ether, 20e6);

        vm.expectRevert(AdaptiveLPVault.VenueNotSet.selector);
        vault.deployToVenue(unknownVenueId, 1 ether, 2e6, "");
    }
    
    function test_WithdrawFromVenue_TracksPerVenueLiquidity() public {
        _mintAndDeposit(token0, token1, vault, alice, 10 ether, 20e6);

        uint256 v2Amount0 = 6 ether;
        uint256 v2Amount1 = 12e6;
        uint256 v2Liquidity = 3 ether;

        uint256 v3Amount0 = 4 ether;
        uint256 v3Amount1 = 8e6;

        _deployVaultToV2(vault, routerV2, V2_VENUE_ID, v2Amount0, v2Amount1, v2Amount0, v2Amount1, v2Liquidity);
        uint256 v3Liquidity = _deployVaultToV3(vault, token0, token1, poolV3Low, positionManagerV3Low, 
                                    V3_LOW_VENUE_ID, tickLower, tickUpper, v3Amount0, v3Amount1);

        uint256 v2Amount0Out = v2Amount0;
        uint256 v2Amount1Out = v2Amount1;
        routerV2.setNextRemoveLiquidityResult(v2Amount0Out, v2Amount1Out);
        (uint256 actual0, uint256 actual1) = vault.withdrawFromVenue(V2_VENUE_ID, v2Liquidity, "");

        assertEq(actual0, v2Amount0Out);
        assertEq(actual1, v2Amount1Out);

        assertEq(vault.venueLiquidity(V2_VENUE_ID), 0);
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), v3Liquidity);
        assertEq(vault.totalLiquidity(), v3Liquidity);

        assertEq(token0.balanceOf(address(vault)), v2Amount0);
        assertEq(token1.balanceOf(address(vault)), v2Amount1);

        assertTrue(adapterV3Low.hasPosition());
        assertEq(adapterV3Low.tokenId(), 1);
    }

    /// @notice Verifies a queued redemption survives one venue failure and settles after both venues return funds.
    function test_AsyncRedeem_SettlesAfterMultiVenueLiquidityReturnsSeparately() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;

        uint256 v2Amount0 = 6 ether;
        uint256 v2Amount1 = 12e6;
        uint256 v2Liquidity = 3 ether;

        uint256 v3Amount0 = 4 ether;
        uint256 v3Amount1 = 8e6;

        // Deploy Alice's entire deposit across V2 and V3, leaving no idle funds for a synchronous redemption.
        uint256 aliceShares = _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        _deployVaultToV2(vault, routerV2, V2_VENUE_ID, v2Amount0, v2Amount1, v2Amount0, v2Amount1, v2Liquidity);
        uint256 v3Liquidity = _deployVaultToV3(vault, token0, token1, poolV3Low, positionManagerV3Low, V3_LOW_VENUE_ID, tickLower, tickUpper, v3Amount0, v3Amount1);

        // V2 valuation requires initialized reserves.
        pairV2.setReserves(uint112(v2Amount0), uint112(v2Amount1));

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);

        // Alice queues her shares, and the owner activates the request so future idle funds are reserved for it.
        uint256 deadline = block.timestamp + 1 hours;

        vm.startPrank(alice);
        vault.approve(address(redemptionManager), aliceShares);
        uint256 requestId = redemptionManager.requestRedeem(aliceShares, alice, deadline);
        vm.stopPrank();
        redemptionManager.activateNextRedeemRequest();
        assertEq(redemptionManager.activeRedeemRequestId(), requestId);

        (uint256 fundingRequestId, uint256 fundingRoundId, uint256 totalSharesSnapshot, uint256 reservedAmount0,
            uint256 reservedAmount1, uint256 pendingVenueCount, uint256 fundedVenueCount) = redemptionManager.activeFunding();

        assertEq(fundingRequestId, requestId);
        assertEq(totalSharesSnapshot, vault.totalSupply());
        assertEq(reservedAmount0, 0);
        assertEq(reservedAmount1, 0);
        assertEq(pendingVenueCount, 2);
        assertEq(fundedVenueCount, 0);

        // Activation snapshots the proportional liquidity required from each venue.
        uint256 v2LiquidityToWithdraw = redemptionManager.fundingLiquidity(fundingRoundId, V2_VENUE_ID);
        uint256 v3LiquidityToWithdraw = redemptionManager.fundingLiquidity(fundingRoundId, V3_LOW_VENUE_ID);

        // Simulate a temporary V2 failure: attempting to withdraw V2 must revert without changing its position.
        routerV2.setRevertOnRemoveLiquidity(true);

        vm.expectRevert(MockUniswapV2Router.MockRemoveLiquidityFailed.selector);
        redemptionManager.fundActiveRedeemRequest(V2_VENUE_ID, "");

        // V2 remains deployed after its isolated withdrawal call fails.
        assertEq(vault.venueLiquidity(V2_VENUE_ID), v2Liquidity);
        assertTrue(adapterV2.hasPosition());

        // V3 can still fund its part of the request in a separate transaction.
        uint256 expectedV3Amount0 = v3Amount0 * v3LiquidityToWithdraw / v3Liquidity;
        uint256 expectedV3Amount1 = v3Amount1 * v3LiquidityToWithdraw / v3Liquidity;

        (uint256 poolAmount0, uint256 poolAmount1) = _mapPoolAmounts(token0, token1, expectedV3Amount0, expectedV3Amount1);
        positionManagerV3Low.setNextDecreaseResult(poolAmount0, poolAmount1);
        redemptionManager.fundActiveRedeemRequest(V3_LOW_VENUE_ID, _v3Params(0, 0, deadline, tickLower, tickUpper));

        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), v3Liquidity - v3LiquidityToWithdraw);
        assertEq(vault.venueLiquidity(V2_VENUE_ID), v2Liquidity);
        assertEq(token0.balanceOf(address(vault)), expectedV3Amount0);
        assertEq(token1.balanceOf(address(vault)), expectedV3Amount1);

        vm.expectRevert(RedemptionManager.RedeemFundingIncomplete.selector);
        redemptionManager.processNextRedeemRequest();

        // Failed settlement does not burn Alice's escrowed shares or remove her request from the queue.
        assertEq(redemptionManager.activeRedeemRequestId(), requestId);
        assertEq(redemptionManager.redeemQueueHead(), requestId);
        assertEq(vault.balanceOf(address(redemptionManager)), aliceShares);

        routerV2.setRevertOnRemoveLiquidity(false);
        uint256 expectedV2Amount0 = v2Amount0 * v2LiquidityToWithdraw / v2Liquidity;
        uint256 expectedV2Amount1 = v2Amount1 * v2LiquidityToWithdraw / v2Liquidity;

        routerV2.setNextRemoveLiquidityResult(expectedV2Amount0, expectedV2Amount1);
        redemptionManager.fundActiveRedeemRequest(V2_VENUE_ID, "");

        assertEq(vault.venueLiquidity(V2_VENUE_ID), v2Liquidity - v2LiquidityToWithdraw);
        assertEq(token0.balanceOf(address(vault)), expectedV2Amount0 + expectedV3Amount0);
        assertEq(token1.balanceOf(address(vault)), expectedV2Amount1 + expectedV3Amount1);

        // With both venue positions returned to idle, any caller can now complete Alice's active request.
        vm.prank(bob);
        (uint256 amount0Out, uint256 amount1Out) = redemptionManager.processNextRedeemRequest();

        assertEq(amount0Out, expectedV2Amount0 + expectedV3Amount0);
        assertEq(amount1Out, expectedV2Amount1 + expectedV3Amount1);

        assertEq(token0.balanceOf(alice), amount0Out);
        assertEq(token1.balanceOf(alice), amount1Out);
        assertGt(amount0Out, 0);
        assertGt(amount1Out, 0);

        // Successful settlement burns the escrowed shares and clears the active one-item queue.
        assertEq(vault.balanceOf(address(redemptionManager)), 0);
        assertEq(redemptionManager.activeRedeemRequestId(), 0);
        assertEq(redemptionManager.redeemQueueHead(), 0);
        assertEq(redemptionManager.redeemQueueTail(), 0);
        assertEq(redemptionManager.totalPendingRedeemShares(), 0);
    }

    /// @notice Verifies a partial queued redemption sums independently rounded funding from V2 and V3 venues.
    function test_AsyncRedeem_AccumulatesMultiVenueFundingWithRoundingDust() public {
        uint256 userAmount0 = 10 ether;
        uint256 userAmount1 = 20e6;

        uint256 v2Amount0 = 12 ether;
        uint256 v2Amount1 = 24e6;
        uint256 v2Liquidity = 7;

        uint256 v3Amount0 = 8 ether;
        uint256 v3Amount1 = 16e6;

        // Alice and Bob own nearly equal portions; locked initial shares make Alice's ratio slightly below 50%.
        uint256 aliceShares = _mintAndDeposit(token0, token1, vault, alice, userAmount0, userAmount1);
        _mintAndDeposit(token0, token1, vault, bob, userAmount0, userAmount1);

        _deployVaultToV2(vault, routerV2, V2_VENUE_ID, v2Amount0, v2Amount1, v2Amount0, v2Amount1, v2Liquidity);
        uint256 v3Liquidity = _deployVaultToV3(vault, token0, token1, poolV3Low, positionManagerV3Low,
                            V3_LOW_VENUE_ID, tickLower, tickUpper, v3Amount0, v3Amount1);
        pairV2.setReserves(uint112(v2Amount0), uint112(v2Amount1));
        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);

        uint256 deadline = block.timestamp + 1 hours;

        vm.startPrank(alice);
        vault.approve(address(redemptionManager), aliceShares);
        uint256 requestId = redemptionManager.requestRedeem(aliceShares, alice, deadline);
        vm.stopPrank();

        redemptionManager.activateNextRedeemRequest();

        (, uint256 fundingRoundId,,,,,) = redemptionManager.activeFunding();

        uint256 v2LiquidityToWithdraw = redemptionManager.fundingLiquidity(fundingRoundId, V2_VENUE_ID);
        uint256 v3LiquidityToWithdraw = redemptionManager.fundingLiquidity(fundingRoundId, V3_LOW_VENUE_ID);

        // 7 multiplied by Alice's slightly-less-than-half share ratio rounds down to 3.
        assertEq(v2LiquidityToWithdraw, 3);
        assertEq(v2Liquidity - v2LiquidityToWithdraw, 4);
        assertGt(v3LiquidityToWithdraw, 0);

        uint256 expectedV2Amount0 = v2Amount0 * v2LiquidityToWithdraw / v2Liquidity;
        uint256 expectedV2Amount1 = v2Amount1 * v2LiquidityToWithdraw / v2Liquidity;
        uint256 expectedV3Amount0 = v3Amount0 * v3LiquidityToWithdraw / v3Liquidity;
        uint256 expectedV3Amount1 = v3Amount1 * v3LiquidityToWithdraw / v3Liquidity;

        routerV2.setNextRemoveLiquidityResult(expectedV2Amount0, expectedV2Amount1);
        redemptionManager.fundActiveRedeemRequest(V2_VENUE_ID, "");

        (uint256 poolAmount0, uint256 poolAmount1) = _mapPoolAmounts(token0, token1, expectedV3Amount0, expectedV3Amount1);
        positionManagerV3Low.setNextDecreaseResult(poolAmount0, poolAmount1);
        redemptionManager.fundActiveRedeemRequest(
            V3_LOW_VENUE_ID,
            _v3Params(0, 0, deadline, tickLower, tickUpper)
        );

        (uint256 amount0Out, uint256 amount1Out) = redemptionManager.processNextRedeemRequest();

        // Settlement uses the sum of each venue's actual rounded funding amount.
        assertEq(amount0Out, expectedV2Amount0 + expectedV3Amount0);
        assertEq(amount1Out, expectedV2Amount1 + expectedV3Amount1);

        assertEq(token0.balanceOf(alice), amount0Out);
        assertEq(token1.balanceOf(alice), amount1Out);
        assertEq(vault.balanceOf(alice), 0);

        // The V2 dust stays in the active V2 position rather than being overpaid.
        assertEq(vault.venueLiquidity(V2_VENUE_ID), v2Liquidity - v2LiquidityToWithdraw);
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), v3Liquidity - v3LiquidityToWithdraw);
        assertTrue(adapterV2.hasPosition());
        assertTrue(adapterV3Low.hasPosition());

        assertEq(redemptionManager.activeRedeemRequestId(), 0);
        assertEq(uint256(_getRedeemRequestStatus(requestId)), uint256(RedemptionManager.RedeemRequestStatus.PROCESSED));
    }

    /// @notice Verifies a partial queued redemption settles funding from two active V3 venues.
    function test_AsyncRedeem_SettlesAcrossMultipleV3Venues() public {
        uint256 userAmount0 = 10 ether;
        uint256 userAmount1 = 20e6;

        uint256 v3LowAmount0 = 8 ether;
        uint256 v3LowAmount1 = 16e6;
        uint256 v3MidAmount0 = 12 ether;
        uint256 v3MidAmount1 = 24e6;

        // Add an independent V3 0.30% venue for this test only.
        MockUniswapV3Pool poolV3Mid = new MockUniswapV3Pool(address(token0), address(token1), 3000);
        MockNonfungiblePositionManager positionManagerV3Mid = new MockNonfungiblePositionManager();
        UniswapV3Adapter adapterV3Mid = new UniswapV3Adapter(
            address(vault),
            address(token0),
            address(token1),
            address(positionManagerV3Mid),
            address(poolV3Mid),
            tickLower,
            tickUpper
        );
        poolV3Mid.setSlot0FromTick(0);
        poolV3Mid.setTwapTick(0);

        V3TwapPositionValuator valuatorV3Mid = new V3TwapPositionValuator(address(adapterV3Mid), twapWindow);
        vault.setVenue(V3_MID_VENUE_ID, address(adapterV3Mid), V3_MID_LABEL, true);
        vault.setVenueValuator(V3_MID_VENUE_ID, address(valuatorV3Mid));

        // Alice owns a partial vault share after Bob makes an equal deposit.
        uint256 aliceShares = _mintAndDeposit(token0, token1, vault, alice, userAmount0, userAmount1);
        _mintAndDeposit(token0, token1, vault, bob, userAmount0, userAmount1);

        uint256 lowLiquidity = _deployVaultToV3(vault, token0, token1, poolV3Low, positionManagerV3Low,
                            V3_LOW_VENUE_ID, tickLower, tickUpper, v3LowAmount0, v3LowAmount1);
        uint256 midLiquidity = _deployVaultToV3(vault, token0, token1, poolV3Mid, positionManagerV3Mid,
                            V3_MID_VENUE_ID, tickLower, tickUpper, v3MidAmount0, v3MidAmount1);

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);

        uint256 deadline = block.timestamp + 1 hours;

        vm.startPrank(alice);
        vault.approve(address(redemptionManager), aliceShares);
        uint256 requestId = redemptionManager.requestRedeem(aliceShares, alice, deadline);
        vm.stopPrank();

        redemptionManager.activateNextRedeemRequest();

        (, uint256 fundingRoundId,,,,,) = redemptionManager.activeFunding();

        uint256 lowLiquidityToWithdraw = redemptionManager.fundingLiquidity(fundingRoundId, V3_LOW_VENUE_ID);
        uint256 midLiquidityToWithdraw = redemptionManager.fundingLiquidity(fundingRoundId, V3_MID_VENUE_ID);

        // Both V3 positions must supply a nonzero proportional amount.
        assertGt(lowLiquidityToWithdraw, 0);
        assertGt(midLiquidityToWithdraw, 0);

        uint256 expectedLowAmount0 = v3LowAmount0 * lowLiquidityToWithdraw / lowLiquidity;
        uint256 expectedLowAmount1 = v3LowAmount1 * lowLiquidityToWithdraw / lowLiquidity;

        uint256 expectedMidAmount0 = v3MidAmount0 * midLiquidityToWithdraw / midLiquidity;
        uint256 expectedMidAmount1 = v3MidAmount1 * midLiquidityToWithdraw / midLiquidity;

        (uint256 lowPoolAmount0, uint256 lowPoolAmount1) = _mapPoolAmounts(token0, token1, expectedLowAmount0, expectedLowAmount1);
        positionManagerV3Low.setNextDecreaseResult(lowPoolAmount0, lowPoolAmount1);
        redemptionManager.fundActiveRedeemRequest(
            V3_LOW_VENUE_ID,
            _v3Params(0, 0, deadline, tickLower, tickUpper)
        );

        (uint256 midPoolAmount0, uint256 midPoolAmount1) = _mapPoolAmounts(token0, token1, expectedMidAmount0, expectedMidAmount1);
        positionManagerV3Mid.setNextDecreaseResult(midPoolAmount0, midPoolAmount1);
        redemptionManager.fundActiveRedeemRequest(
            V3_MID_VENUE_ID,
            _v3Params(0, 0, deadline, tickLower, tickUpper)
        );

        (uint256 amount0Out, uint256 amount1Out) = redemptionManager.processNextRedeemRequest();

        // Settlement combines the actual funding from both V3 positions.
        assertEq(amount0Out, expectedLowAmount0 + expectedMidAmount0);
        assertEq(amount1Out, expectedLowAmount1 + expectedMidAmount1);

        assertEq(token0.balanceOf(alice), amount0Out);
        assertEq(token1.balanceOf(alice), amount1Out);
        assertEq(vault.balanceOf(alice), 0);

        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), lowLiquidity - lowLiquidityToWithdraw);
        assertEq(vault.venueLiquidity(V3_MID_VENUE_ID), midLiquidity - midLiquidityToWithdraw);
        assertTrue(adapterV3Low.hasPosition());
        assertTrue(adapterV3Mid.hasPosition());

        assertEq(uint256(_getRedeemRequestStatus(requestId)), uint256(RedemptionManager.RedeemRequestStatus.PROCESSED));
    }

    /// @notice Verifies a batch emergency exit skips a failing venue and withdraws a healthy venue.
    function test_EmergencyExit_SkipsFailingVenue() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;

        uint256 v2Amount0 = 6 ether;
        uint256 v2Amount1 = 12e6;
        uint256 v2Liquidity = 3 ether;

        uint256 v3Amount0 = 4 ether;
        uint256 v3Amount1 = 8e6;

        // Deposit funds and deploy them across V2 and V3.
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);
        _deployVaultToV2(vault, routerV2, V2_VENUE_ID, v2Amount0, v2Amount1, v2Amount0, v2Amount1, v2Liquidity);
        uint256 v3Liquidity = _deployVaultToV3(vault, token0, token1, poolV3Low, positionManagerV3Low, V3_LOW_VENUE_ID, tickLower, tickUpper, v3Amount0, v3Amount1);
        assertEq(vault.venueLiquidity(V2_VENUE_ID), v2Liquidity);
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), v3Liquidity);
        assertTrue(adapterV2.hasPosition());
        assertTrue(adapterV3Low.hasPosition());
        assertFalse(vault.paused());

        // Simulate a broken V2 venue and verify its isolated exit fails.
        routerV2.setRevertOnRemoveLiquidity(true);
        // Configure the healthy V3 venue to return its underlying tokens.
        (uint256 poolAmount0Out, uint256 poolAmount1Out) = _mapPoolAmounts(token0, token1, v3Amount0, v3Amount1);
        positionManagerV3Low.setNextDecreaseResult(poolAmount0Out, poolAmount1Out);
        vault.emergencyExit(_emptyWithdrawalParams());

        // Failed V2 remains deployed while healthy V3 returns to idle.
        assertEq(vault.venueLiquidity(V2_VENUE_ID), v2Liquidity);
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), 0);
        assertEq(vault.totalLiquidity(), v2Liquidity);

        assertTrue(adapterV2.hasPosition());
        assertFalse(adapterV3Low.hasPosition());

        assertEq(token0.balanceOf(address(vault)), v3Amount0);
        assertEq(token1.balanceOf(address(vault)), v3Amount1);
        assertTrue(vault.paused());
    }

    function test_TotalAssets_SumsIdleAndAllVenues() public {
        _mintAndDeposit(token0, token1, vault, alice, 10 ether, 20e6);

        uint256 v2Amount0 = 6 ether;
        uint256 v2Amount1 = 12e6;
        uint256 v2Liquidity = 3 ether;

        uint256 v3Amount0 = 4 ether;
        uint256 v3Amount1 = 8e6;

        _deployVaultToV2(vault, routerV2, V2_VENUE_ID, v2Amount0, v2Amount1, v2Amount0, v2Amount1, v2Liquidity);
        _deployVaultToV3(vault, token0, token1, poolV3Low, positionManagerV3Low, 
                                    V3_LOW_VENUE_ID, tickLower, tickUpper, v3Amount0, v3Amount1);
        
        pairV2.setReserves(uint112(v2Amount0), uint112(v2Amount1));
        
        (uint256 price0, uint256 price1) = oracle.getPrices();
        uint256 idleValue = VaultMath.getAssetsTotalValue(
            token0.balanceOf(address(vault)),
            price0,
            decimals0,
            token1.balanceOf(address(vault)),
            price1,
            decimals1
        );
        uint256 expected = idleValue + valuatorV2.getValueInBase(price0, price1) + valuatorV3.getValueInBase(price0, price1);

        assertEq(vault.totalAssets(), expected);
    }

    /// @notice Redeem uses idle balances without changing active V2 or V3 positions.
    function test_Redeem_UsesIdleBufferWithoutChangingMultiVenuePositions() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;
        // Total vault deposits: 20 token0 and 40 token1.
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);
        _mintAndDeposit(token0, token1, vault, bob, amount0, amount1);
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 bobShares = vault.balanceOf(bob);
        uint256 totalSharesBefore = vault.totalSupply();

        // Deploy only part of the assets to V2.
        uint256 v2Amount0 = 2 ether;
        uint256 v2Amount1 = 4e6;
        uint256 v2Liquidity = 1 ether;
        _deployVaultToV2(vault, routerV2, V2_VENUE_ID, v2Amount0, v2Amount1, v2Amount0, v2Amount1, v2Liquidity);
        // The V2 trusted valuator requires valid reserves.
        pairV2.setReserves(uint112(v2Amount0), uint112(v2Amount1));

        // Deploy another part to V3.
        uint256 v3Amount0 = 2 ether;
        uint256 v3Amount1 = 4e6;
        uint256 v3Liquidity = _deployVaultToV3(vault, token0, token1, poolV3Low, positionManagerV3Low,
                                    V3_LOW_VENUE_ID, tickLower, tickUpper, v3Amount0, v3Amount1);

        uint256 v3TokenIdBefore = adapterV3Low.tokenId();

        assertEq(vault.venueLiquidity(V2_VENUE_ID), v2Liquidity);
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), v3Liquidity);

        // Calculate Alice's claim against the remaining idle buffer.
        uint256 idle0Before = token0.balanceOf(address(vault));
        uint256 idle1Before = token1.balanceOf(address(vault));
        (uint256 price0, uint256 price1) = oracle.getPrices();

        uint256 idleValue = VaultMath.getAssetsTotalValue(idle0Before, price0, decimals0, idle1Before, price1, decimals1);

        uint256 redeemValue = vault.totalAssets() * aliceShares / totalSharesBefore;

        assertGe(idleValue, redeemValue);

        uint256 expectedAmount0Out = idle0Before * redeemValue / idleValue;
        uint256 expectedAmount1Out = idle1Before * redeemValue / idleValue;

        vm.prank(alice);
        (uint256 amount0Out, uint256 amount1Out) = vault.redeem(aliceShares, alice, alice, 0, 0);
        
        assertEq(amount0Out, expectedAmount0Out);
        assertEq(amount1Out, expectedAmount1Out);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), bobShares);
        assertEq(vault.totalSupply(), bobShares + vault.MINIMUM_LOCKED_SHARES());

        // Neither venue position was withdrawn.
        assertEq(vault.venueLiquidity(V2_VENUE_ID), v2Liquidity);
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), v3Liquidity);
        assertEq(vault.totalLiquidity(), v2Liquidity + v3Liquidity);

        assertTrue(adapterV2.hasPosition());
        assertEq(pairV2.balanceOf(address(adapterV2)), v2Liquidity);

        assertTrue(adapterV3Low.hasPosition());
        assertEq(adapterV3Low.tokenId(), v3TokenIdBefore);

        (,,,,,,, uint128 positionLiquidity,,,,) = positionManagerV3Low.positions(v3TokenIdBefore);

        assertEq(uint256(positionLiquidity), v3Liquidity);
    }
}
