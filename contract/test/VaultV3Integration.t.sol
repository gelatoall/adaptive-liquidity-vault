// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/AdaptiveLPVault.sol";
import "../src/adapters/UniswapV3Adapter.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockPriceOracle.sol";
import "./mocks/MockUniswapV3Pool.sol";
import "./mocks/MockNonfungiblePositionManager.sol";
import "../src/libraries/v3/TickMath.sol";
import "../src/libraries/v3/LiquidityAmounts.sol";
import "../test/helpers/VaultTestHelper.sol";
import "../test/helpers/VenueTestHelper.sol";
import "../src/valuators/V3TwapPositionValuator.sol";
import "../src/redemption/RedemptionManager.sol";

/// @title VaultV3IntegrationTest
/// @notice Integration tests for `AdaptiveLPVault` wired to `UniswapV3Adapter`.
contract VaultV3IntegrationTest is Test, VaultTestHelper, VenueTestHelper {
    MockERC20 public token0;
    MockERC20 public token1;
    AdaptiveLPVault public vault;

    MockPriceOracle public oracle;
    V3TwapPositionValuator public valuator;
    
    MockUniswapV3Pool public pool;
    MockNonfungiblePositionManager public positionManager;
    UniswapV3Adapter public adapter;

    RedemptionManager public redemptionManager;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    uint8 public decimals0 = 18;
    uint8 public decimals1 = 6;
    uint24 public fee = 3000;
    int24 public tickLower = -600;
    int24 public tickUpper = 600;
    uint32 public twapWindow = 1800;

    /// @notice Deploys the vault, oracle, pool, position manager, and V3 adapter fixture.
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

        // deploy oracle
        oracle = new MockPriceOracle();
        _configureMirroredPriceOracles(vault, oracle);
        oracle.setPrices(1e18, 1e18);

        // deploy pool/positionManager/V3adapter
        pool = new MockUniswapV3Pool(address(token0), address(token1), fee);
        pool.setSlot0FromTick(0);

        positionManager = new MockNonfungiblePositionManager();

        adapter = new UniswapV3Adapter(
            address(vault), 
            address(token0),
            address(token1),
            address(positionManager),
            address(pool),
            tickLower,
            tickUpper
        );

        // set V3 adapter into vault
        vault.setVenue(V3_LOW_VENUE_ID, address(adapter), V3_LOW_LABEL, true);

        pool.setTwapTick(0);
        vm.warp(block.timestamp + twapWindow);

        valuator = new V3TwapPositionValuator(address(adapter), twapWindow);
        vault.setVenueValuator(V3_LOW_VENUE_ID, address(valuator));

        redemptionManager = new RedemptionManager(address(vault));
        vault.setRedemptionManager(address(redemptionManager));
    }

    /// @notice Returns only the lifecycle status from the public request getter.
    function _getRedeemRequestStatus(uint256 requestId) internal view returns (RedemptionManager.RedeemRequestStatus status) {
        (,,,,,, status) = redemptionManager.redeemRequests(requestId);
    }

    /// @notice Returns the previous and next queue links for a redemption request.
    function _getRedeemRequestLinks(uint256 requestId) internal view returns (uint256 previousRequestId, uint256 nextRequestId) {
        (,,,, previousRequestId, nextRequestId,) = redemptionManager.redeemRequests(requestId);
    }

    /// @notice Verifies idle vault funds can be deployed into V3.
    function test_DeployToVenue_DeploysIdleFundsIntoV3() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;

        // user -> vault
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);
        assertEq(token0.balanceOf(address(vault)), amount0);
        assertEq(token1.balanceOf(address(vault)), amount1);

        // vault -> pool
        _deployVaultToV3(
            vault, token0, token1, pool, positionManager, V3_LOW_VENUE_ID, tickLower, tickUpper, amount0, amount1
        );

        assertTrue(adapter.hasPosition());
        assertEq(adapter.tokenId(), 1);

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);
        // Note：真实情况token是在pool里面，这里只是简化了Mock
        assertEq(token0.balanceOf(address(positionManager)), amount0);
    }

    /// @notice Verifies a position-manager callback cannot reenter the vault during V3 deployment.
    function test_DeployToVenue_RevertsWhenPositionManagerReentersVault() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;
        uint128 liquidity = 1234;

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        positionManager.setReentryVault(vault);
        positionManager.setNextMintResult(liquidity, amount0, amount1);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vault.deployToVenue(
            V3_LOW_VENUE_ID,
            amount0,
            amount1,
            _defaultV3Params(tickLower, tickUpper)
        );

        // The callback reverted the complete outer deployment.
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), 0);
        assertFalse(adapter.hasPosition());
        assertEq(adapter.tokenId(), 0);
        assertEq(positionManager.nextTokenId(), 1);
        assertEq(token0.balanceOf(address(vault)), amount0);
        assertEq(token1.balanceOf(address(vault)), amount1);
    }
    
    /// @notice Verifies deployed V3 funds and explicit fees can be withdrawn back to the vault.
    function test_WithdrawFromVenue_ReturnsFundsAndCollectsFeesFromV3() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;
        uint256 fee0 = 0.1 ether;
        uint256 fee1 = 200e6;

        // user -> vault
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        // vault -> pool
        uint256 deployedLiquidity = _deployVaultToV3(vault, token0, token1, pool, positionManager, 
                                V3_LOW_VENUE_ID, tickLower, tickUpper, amount0, amount1);

        assertTrue(adapter.hasPosition());
        assertEq(adapter.tokenId(), 1);

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);

        (uint256 poolAmount0Desired, uint256 poolAmount1Desired) = _mapPoolAmounts(token0, token1, amount0, amount1);
        positionManager.setNextDecreaseResult(poolAmount0Desired, poolAmount1Desired);

        (uint256 feePool0, uint256 feePool1) = _mapPoolAmounts(token0, token1, fee0, fee1);
        positionManager.addFees(adapter.tokenId(), uint128(feePool0), uint128(feePool1));

        (uint256 amount0Out, uint256 amount1Out) = vault.withdrawFromVenue(V3_LOW_VENUE_ID, deployedLiquidity, "");

        assertEq(amount0Out, amount0 + fee0);
        assertEq(amount1Out, amount1 + fee1);
        assertFalse(adapter.hasPosition());
        assertEq(adapter.tokenId(), 0);

        assertEq(token0.balanceOf(address(vault)), amount0 + fee0);
        assertEq(token1.balanceOf(address(vault)), amount1 + fee1);
    }

    /// @notice Redeem uses idle balances without removing active V3 liquidity.
    function test_Redeem_UsesIdleBufferWithoutRemovingV3Position() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;
        
        // Two users provide enough assets to create an idle liquidity buffer.
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);
        _mintAndDeposit(token0, token1, vault, bob, amount0, amount1);

        uint256 aliceShares = vault.balanceOf(alice);
        uint256 bobShares = vault.balanceOf(bob);
        uint256 totalSharesBefore = vault.totalSupply();

        // Deploy only part of the assets, leaving most assets idle.
        uint256 deployedAmount0 = 0.4 ether;
        uint256 deployedAmount1 = 800e6;

        // vault -> pool
        uint256 deployedLiquidity = _deployVaultToV3(vault, token0, token1, pool, positionManager, 
                        V3_LOW_VENUE_ID, tickLower, tickUpper, deployedAmount0, deployedAmount1);
        uint256 tokenIdBefore = adapter.tokenId();

        assertTrue(adapter.hasPosition());
        assertEq(tokenIdBefore, 1);
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), deployedLiquidity);

        // Calculate the expected idle-only redemption amounts.
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

        // Synchronous redeem must leave the V3 NFT and liquidity unchanged.
        assertTrue(adapter.hasPosition());
        assertEq(adapter.tokenId(), tokenIdBefore);
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), deployedLiquidity);

        (,,,,,,, uint128 positionLiquidity,,,,) = positionManager.positions(tokenIdBefore);
        assertEq(uint256(positionLiquidity), deployedLiquidity);
    }

    /// @notice Verifies vault totalAssets includes the deployed V3 position value.
    function test_TotalAssets_IncludesV3PositionValue() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;
        
        // user -> vault
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        // vault -> pool
        _deployVaultToV3(vault, token0, token1, pool, positionManager, 
                        V3_LOW_VENUE_ID, tickLower, tickUpper, amount0, amount1);

        (uint256 price0, uint256 price1) = oracle.getPrices();
        
        uint256 idleValue = VaultMath.getAssetsTotalValue(
            token0.balanceOf(address(vault)),
            price0, 
            decimals0, 
            token1.balanceOf(address(vault)),
            price1, 
            decimals1
        );
        uint256 expectedTotalAssets = idleValue + valuator.getValueInBase(price0, price1);

        assertEq(vault.totalAssets(), expectedTotalAssets);
    }

    function test_QuarantineVenue_WritesDownAndRestoresV3Position() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;

        // user -> vault
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        // vault -> pool
        uint256 liquidity = _deployVaultToV3(vault, token0, token1, pool, positionManager,
                        V3_LOW_VENUE_ID, tickLower, tickUpper, amount0, amount1);

        (uint256 price0, uint256 price1) = oracle.getPrices();
        uint256 venueValue = valuator.getValueInBase(price0, price1);
        assertEq(vault.totalAssets(), venueValue);
        assertEq(vault.venueValuationBps(V3_LOW_VENUE_ID), 10000);

        // Recognize only 50% of the impaired venue's reported value.
        vault.quarantineVenue(V3_LOW_VENUE_ID, 5000);

        assertTrue(vault.paused());
        assertTrue(vault.venueQuarantined(V3_LOW_VENUE_ID));
        assertEq(vault.quarantinedVenueCount(), 1);
        assertEq(vault.venueValuationBps(V3_LOW_VENUE_ID), 5000);
        (, bool enabled,) = vault.venues(V3_LOW_VENUE_ID);
        assertFalse(enabled);
        // The position still exists, but only half its reported value is recognized.
        assertTrue(adapter.hasPosition());
        assertEq(vault.totalAssets(), venueValue * 5000 / 10000);

        // A complete write-down excludes the venue from vault NAV.
        vault.setQuarantinedVenueValuationBps(V3_LOW_VENUE_ID, 0);
        assertEq(vault.venueValuationBps(V3_LOW_VENUE_ID), 0);
        assertEq(vault.totalAssets(), 0);

        // Quarantine blocks new deployment, but withdrawal remains available.
        (uint256 poolAmount0, uint256 poolAmount1) = _mapPoolAmounts(token0, token1, amount0, amount1);
        positionManager.setNextDecreaseResult(poolAmount0, poolAmount1);
        vault.withdrawFromVenue(V3_LOW_VENUE_ID, liquidity, _v3Params(0, 0, block.timestamp + 1 hours, tickLower, tickUpper));
        // Recovered tokens are idle and therefore return to NAV at full value.
        uint256 recoveredIdleValue = VaultMath.getAssetsTotalValue(
            token0.balanceOf(address(vault)), price0, decimals0,
            token1.balanceOf(address(vault)), price1, decimals1
        );
        assertEq(vault.totalAssets(), recoveredIdleValue);
        assertFalse(adapter.hasPosition());

        // Restore registry accounting, but keep deployments disabled initially.
        vault.restoreVenue(V3_LOW_VENUE_ID, false);

        assertFalse(vault.venueQuarantined(V3_LOW_VENUE_ID));
        assertEq(vault.quarantinedVenueCount(), 0);
        assertEq(vault.venueValuationBps(V3_LOW_VENUE_ID), 10000);

        (, enabled,) = vault.venues(V3_LOW_VENUE_ID);
        assertFalse(enabled);

        // With no quarantined venues remaining, normal operation can resume.
        vault.unpause();
        assertFalse(vault.paused());
    }

    /// @notice Verifies harvesting transfers V3 fees to vault idle balances without removing the active position.
    function test_HarvestVenueFees_CollectsFeesWithoutRemovingPosition() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;
        uint256 fee0 = 0.1 ether;
        uint256 fee1 = 200e6;

        // user -> vault
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        // vault -> pool
        _deployVaultToV3(
            vault, token0, token1, pool, positionManager, V3_LOW_VENUE_ID, tickLower, tickUpper, amount0, amount1
        );

        (uint256 feePool0, uint256 feePool1) = _mapPoolAmounts(token0, token1, fee0, fee1);
        positionManager.addFees(adapter.tokenId(), uint128(feePool0), uint128(feePool1));

        uint256 vault0Before = token0.balanceOf(address(vault));
        uint256 vault1Before = token1.balanceOf(address(vault));

        (uint256 collected0, uint256 collected1) = vault.harvestVenueFees(V3_LOW_VENUE_ID);
        assertEq(collected0, fee0);
        assertEq(collected1, fee1);

        assertEq(token0.balanceOf(address(vault)), vault0Before + fee0);
        assertEq(token1.balanceOf(address(vault)), vault1Before + fee1);
        
        assertTrue(adapter.hasPosition());
    }

    /// @notice Verifies compounding V3 fees increases the existing position without changing share supply.
    function test_CompoundVenueFees_IncreasesExistingV3Position() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;
        uint256 fee0 = 0.1 ether;
        uint256 fee1 = 200e6;
        uint128 liquidityAdded = 1234;

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        _deployVaultToV3(vault, token0, token1, pool, positionManager, V3_LOW_VENUE_ID, tickLower, tickUpper, amount0, amount1);

        uint256 tokenIdBefore = adapter.tokenId();
        uint256 venueLiquidityBefore = vault.venueLiquidity(V3_LOW_VENUE_ID);
        uint256 totalSupplyBefore = vault.totalSupply();

        (uint256 feePool0, uint256 feePool1) = _mapPoolAmounts(token0, token1, fee0, fee1);
        positionManager.addFees(adapter.tokenId(), uint128(feePool0), uint128(feePool1));
        positionManager.setNextIncreaseResult(liquidityAdded, feePool0, feePool1);

        uint256 amount0Min = fee0 / 2;
        uint256 amount1Min = fee1 / 2;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory params = _v3Params(amount0Min, amount1Min, deadline, tickLower, tickUpper);
        (uint256 poolAmount0Min, uint256 poolAmount1Min) = _mapPoolAmounts(token0, token1, amount0Min, amount1Min);

        (uint256 collected0, uint256 collected1, uint256 actualLiquidityAdded) = vault.compoundVenueFees(V3_LOW_VENUE_ID, params);

        assertEq(collected0, fee0);
        assertEq(collected1, fee1);
        assertEq(actualLiquidityAdded, liquidityAdded);

        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), venueLiquidityBefore + liquidityAdded);
        assertEq(vault.totalSupply(), totalSupplyBefore);

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);

        assertEq(positionManager.lastIncreaseAmount0Min(), poolAmount0Min);
        assertEq(positionManager.lastIncreaseAmount1Min(), poolAmount1Min);
        assertEq(positionManager.lastIncreaseDeadline(), deadline);

        (,,,,,,, uint128 positionLiquidity,,,,) = positionManager.positions(tokenIdBefore);
        assertEq(uint256(positionLiquidity), venueLiquidityBefore + liquidityAdded);
    }

    /// @notice Verifies a temporary V3 spot move cannot alter totalAssets or deposit share issuance.
    function test_DepositShares_IgnoreV3SpotManipulation() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        _deployVaultToV3(vault, token0, token1, pool, positionManager,
                V3_LOW_VENUE_ID, tickLower, tickUpper, amount0, amount1);

        pool.setSlot0FromTick(0);
        uint256 assetsBefore = vault.totalAssets();
        uint256 totalSharesBefore = vault.totalSupply();

        (uint256 price0, uint256 price1) = oracle.getPrices();
        uint256 bobDepositValue = VaultMath.getAssetsTotalValue(amount0, price0, decimals0, amount1, price1, decimals1);
        uint256 expectedBobShares = VaultMath.calculateShares(bobDepositValue, assetsBefore, totalSharesBefore);

        // Simulate a flash swap changing spot while TWAP remains unchanged.
        pool.setSlot0FromTick(500);
        assertEq(vault.totalAssets(), assetsBefore);

        uint256 bobShares = _mintAndDeposit(token0, token1, vault, bob, amount0, amount1);

        assertEq(bobShares, expectedBobShares);
    }

    /// @notice Verifies a queued partial redemption receives its pro-rata share of V3 owed tokens.
    function test_AsyncRedeem_PartiallyDistributesV3FeesProRata() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;

        // Alice and Bob deposit equal amounts into the vault.
        uint256 aliceShares = _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);
        uint256 bobShares = _mintAndDeposit(token0, token1, vault, bob, amount0, amount1);

        // Deploy every idle token into V3 so Alice cannot use synchronous redeem.
        uint256 totalAmount0 = amount0 * 2;
        uint256 totalAmount1 = amount1 * 2;

        uint256 liquidity = _deployVaultToV3(vault, token0, token1, pool, positionManager, V3_LOW_VENUE_ID, tickLower, tickUpper, totalAmount0, totalAmount1);
        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);

        uint256 fee0 = 0.1 ether;
        uint256 fee1 = 200e6;

        (uint256 feePool0, uint256 feePool1) = _mapPoolAmounts(token0, token1, fee0, fee1);
        positionManager.addFees(adapter.tokenId(), uint128(feePool0), uint128(feePool1));

        uint256 annualFeeBps = 200;
        vault.setManagementFeeConfig(bob, annualFeeBps);
        // Let one day of management fees accrue before Alice queues her request.
        vm.warp(block.timestamp + 1 days);
        // Keep the valuation oracle fresh for requestRedeem's liquidity check.
        oracle.setPrices(1e18, 1e18);

        uint256 deadline = block.timestamp + 7 days;

        // With no idle liquidity available, the frontend selects the asynchronous redemption path.
        vm.startPrank(alice);
        vault.approve(address(redemptionManager), aliceShares);
        uint256 requestId = redemptionManager.requestRedeem(aliceShares, alice, deadline);
        vm.stopPrank();

        uint256 bobSharesAfterRequest = vault.balanceOf(bob);
        assertGt(bobSharesAfterRequest, bobShares);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(address(redemptionManager)), aliceShares);
        assertEq(redemptionManager.redeemQueueHead(), requestId);
        assertEq(redemptionManager.redeemQueueTail(), requestId);
        assertEq(redemptionManager.totalPendingRedeemShares(), aliceShares);
        assertEq(uint256(_getRedeemRequestStatus(requestId)), uint256(RedemptionManager.RedeemRequestStatus.PENDING));

        // Let additional fees accrue before activation takes the funding-round supply snapshot.
        vm.warp(block.timestamp + 2 days);
        uint256 bobSharesBeforeActivation = vault.balanceOf(bob);
        // Activating the queue head reserves future idle liquidity for this request.
        redemptionManager.activateNextRedeemRequest();
        assertGt(vault.balanceOf(bob), bobSharesBeforeActivation);
        assertEq(redemptionManager.activeRedeemRequestId(), requestId);
        assertEq(uint256(_getRedeemRequestStatus(requestId)), uint256(RedemptionManager.RedeemRequestStatus.PROCESSING));

        // Synchronous redemption is blocked while a request is processing.
        vm.prank(bob);
        vm.expectRevert(AdaptiveLPVault.RedeemProcessingActive.selector);
        vault.redeem(bobShares, bob, bob, 0, 0);

        // New venue deployment is also blocked while processing.
        vm.expectRevert(AdaptiveLPVault.RedeemProcessingActive.selector);
        vault.deployToVenue(V3_LOW_VENUE_ID, 0, 0, "");

        // The owner can recover from a premature activation.
        redemptionManager.deactivateRedeemRequest();
        assertEq(redemptionManager.activeRedeemRequestId(), 0);
        assertEq(redemptionManager.redeemQueueHead(), requestId);
        assertEq(uint256(_getRedeemRequestStatus(requestId)), uint256(RedemptionManager.RedeemRequestStatus.PENDING));

        // Reactivate the same queue-head request.
        redemptionManager.activateNextRedeemRequest();

        (uint256 fundingRequestId, uint256 fundingRoundId, uint256 totalSharesSnapshot, uint256 reservedAmount0,
            uint256 reservedAmount1, uint256 pendingVenueCount, uint256 fundedVenueCount) = redemptionManager.activeFunding();
        assertEq(fundingRequestId, requestId);
        assertEq(totalSharesSnapshot, vault.totalSupply());
        assertEq(reservedAmount0, 0);
        assertEq(reservedAmount1, 0);
        assertEq(pendingVenueCount, 1);
        assertEq(fundedVenueCount, 0);

        // Manager has snapshotted the proportional V3 liquidity owed to Alice.
        uint256 liquidityToWithdraw = redemptionManager.fundingLiquidity(fundingRoundId, V3_LOW_VENUE_ID);

        uint256 expectedPrincipal0Out = totalAmount0 * liquidityToWithdraw / liquidity;
        uint256 expectedPrincipal1Out = totalAmount1 * liquidityToWithdraw / liquidity;
        uint256 expectedFee0Out = fee0 * aliceShares / totalSharesSnapshot;
        uint256 expectedFee1Out = fee1 * aliceShares / totalSharesSnapshot;
        uint256 expectedRequestAmount0Out = expectedPrincipal0Out + expectedFee0Out;
        uint256 expectedRequestAmount1Out = expectedPrincipal1Out + expectedFee1Out;

        (uint256 poolAmount0, uint256 poolAmount1) = _mapPoolAmounts(token0, token1, expectedPrincipal0Out, expectedPrincipal1Out);
        positionManager.setNextDecreaseResult(poolAmount0, poolAmount1);

        redemptionManager.fundActiveRedeemRequest(V3_LOW_VENUE_ID, _v3Params(0, 0, deadline, tickLower, tickUpper));
        assertEq(token0.balanceOf(address(vault)), expectedPrincipal0Out + fee0);
        assertEq(token1.balanceOf(address(vault)), expectedPrincipal1Out + fee1);
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), liquidity - liquidityToWithdraw);

        // Processing is permissionless after activation, so Bob can settle it.
        vm.prank(bob);
        (uint256 amount0Out, uint256 amount1Out) = redemptionManager.processNextRedeemRequest();

        // Settlement uses exactly the amounts reserved during request funding.
        assertEq(amount0Out, expectedRequestAmount0Out);
        assertEq(amount1Out, expectedRequestAmount1Out);

        // Alice receives the exact amounts accumulated for her request.
        assertEq(token0.balanceOf(alice), amount0Out);
        assertEq(token1.balanceOf(alice), amount1Out);

        assertEq(token0.balanceOf(address(vault)), fee0 - expectedFee0Out);
        assertEq(token1.balanceOf(address(vault)), fee1 - expectedFee1Out);

        // Escrowed shares were burned and the request was removed from the queue.
        assertEq(vault.balanceOf(address(redemptionManager)), 0);
        assertEq(redemptionManager.activeRedeemRequestId(), 0);
        assertEq(redemptionManager.redeemQueueHead(), 0);
        assertEq(redemptionManager.redeemQueueTail(), 0);
        assertEq(redemptionManager.totalPendingRedeemShares(), 0);

        assertEq(uint256(_getRedeemRequestStatus(requestId)), uint256(RedemptionManager.RedeemRequestStatus.PROCESSED));
    }

    /// @notice Verifies redeeming all user-held shares distributes V3 owed tokens pro rata.
    function test_AsyncRedeem_AllUserSharesReceivesProRataV3Fees() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;

        // Alice is the only user; initial locked shares remain in the vault share supply.
        uint256 aliceShares = _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        uint256 liquidity = _deployVaultToV3(vault, token0, token1, pool, positionManager,
                                V3_LOW_VENUE_ID, tickLower, tickUpper, amount0, amount1);
        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);

        uint256 fee0 = 0.1 ether;
        uint256 fee1 = 200e6;
        (uint256 feePool0, uint256 feePool1) = _mapPoolAmounts(token0, token1, fee0, fee1);
        positionManager.addFees(adapter.tokenId(), uint128(feePool0), uint128(feePool1));

        uint256 deadline = block.timestamp + 7 days;

        // With no idle liquidity available, the frontend selects the asynchronous redemption path.
        vm.startPrank(alice);
        vault.approve(address(redemptionManager), aliceShares);
        uint256 requestId = redemptionManager.requestRedeem(aliceShares, alice, deadline);
        vm.stopPrank();

        redemptionManager.activateNextRedeemRequest();

        (, uint256 fundingRoundId, uint256 totalSharesSnapshot,,,,) = redemptionManager.activeFunding();
        uint256 liquidityToWithdraw = redemptionManager.fundingLiquidity(fundingRoundId, V3_LOW_VENUE_ID);
        assertLt(liquidityToWithdraw, liquidity);

        uint256 expectedPrincipal0Out = amount0 * liquidityToWithdraw / liquidity;
        uint256 expectedPrincipal1Out = amount1 * liquidityToWithdraw / liquidity;

        // Locked shares retain their small proportional share of the owed fees.
        uint256 expectedFee0Out = fee0 * aliceShares / totalSharesSnapshot;
        uint256 expectedFee1Out = fee1 * aliceShares / totalSharesSnapshot;
        (uint256 poolAmount0, uint256 poolAmount1) = _mapPoolAmounts(token0, token1, expectedPrincipal0Out, expectedPrincipal1Out);
        positionManager.setNextDecreaseResult(poolAmount0, poolAmount1);

        redemptionManager.fundActiveRedeemRequest(V3_LOW_VENUE_ID, _v3Params(0, 0, deadline, tickLower, tickUpper));

        (uint256 amount0Out, uint256 amount1Out) = redemptionManager.processNextRedeemRequest();

        assertEq(amount0Out, expectedPrincipal0Out + expectedFee0Out);
        assertEq(amount1Out, expectedPrincipal1Out + expectedFee1Out);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalSupply(), vault.MINIMUM_LOCKED_SHARES());
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), liquidity - liquidityToWithdraw);
        assertTrue(adapter.hasPosition());

        // Locked shares retain their proportional fee share, plus any rounding remainder.
        assertEq(token0.balanceOf(address(vault)), fee0 - expectedFee0Out);
        assertEq(token1.balanceOf(address(vault)), fee1 - expectedFee1Out);
        assertEq(uint256(_getRedeemRequestStatus(requestId)), uint256(RedemptionManager.RedeemRequestStatus.PROCESSED));
    }

    /// @notice Verifies a small redemption settles through the queue when all assets are deployed to V3.
    function test_AsyncRedeem_SettlesSmallV3RedemptionFromFullyDeployedVault() public {
        uint256 aliceAmount0 = 1 ether;
        uint256 aliceAmount1 = 2000e6;
        uint256 bobAmount0 = 999 ether;
        uint256 bobAmount1 = 1_998_000e6;

        // Alice owns a small share of the vault after Bob's much larger deposit.
        uint256 aliceShares = _mintAndDeposit(token0, token1, vault, alice, aliceAmount0, aliceAmount1);
        _mintAndDeposit(token0, token1, vault, bob, bobAmount0, bobAmount1);

        uint256 totalAmount0 = aliceAmount0 + bobAmount0;
        uint256 totalAmount1 = aliceAmount1 + bobAmount1;

        uint256 liquidity = _deployVaultToV3(vault, token0, token1, pool, positionManager,
                                V3_LOW_VENUE_ID, tickLower, tickUpper, totalAmount0, totalAmount1);
        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);

        uint256 deadline = block.timestamp + 7 days;

        // No idle balance exists, so Alice must use the asynchronous redemption path.
        vm.startPrank(alice);
        vault.approve(address(redemptionManager), aliceShares);
        uint256 requestId = redemptionManager.requestRedeem(aliceShares, alice, deadline);
        vm.stopPrank();

        redemptionManager.activateNextRedeemRequest();

        (, uint256 fundingRoundId, uint256 totalSharesSnapshot,,,,) = redemptionManager.activeFunding();
        // Alice owns less than 1% of the active supply, but her venue liquidity is nonzero.
        assertLt(aliceShares * 100, totalSharesSnapshot);

        uint256 liquidityToWithdraw = redemptionManager.fundingLiquidity(fundingRoundId, V3_LOW_VENUE_ID);
        assertGt(liquidityToWithdraw, 0);
        assertLt(liquidityToWithdraw, liquidity);

        uint256 expectedAmount0Out = totalAmount0 * liquidityToWithdraw / liquidity;
        uint256 expectedAmount1Out = totalAmount1 * liquidityToWithdraw / liquidity;

        (uint256 poolAmount0, uint256 poolAmount1) = _mapPoolAmounts(token0, token1, expectedAmount0Out, expectedAmount1Out);
        positionManager.setNextDecreaseResult(poolAmount0, poolAmount1);
        redemptionManager.fundActiveRedeemRequest(V3_LOW_VENUE_ID, _v3Params(0, 0, deadline, tickLower, tickUpper));

        // Anyone may settle once funding is complete.
        vm.prank(bob);
        (uint256 amount0Out, uint256 amount1Out) = redemptionManager.processNextRedeemRequest();

        assertEq(amount0Out, expectedAmount0Out);
        assertEq(amount1Out, expectedAmount1Out);
        assertEq(token0.balanceOf(alice), amount0Out);
        assertEq(token1.balanceOf(alice), amount1Out);

        assertEq(vault.balanceOf(alice), 0);
        assertTrue(adapter.hasPosition());
        assertEq(uint256(_getRedeemRequestStatus(requestId)), uint256(RedemptionManager.RedeemRequestStatus.PROCESSED));
    }

    /// @notice Verifies cancelling a middle request preserves the redemption queue links.
    function test_AsyncRedeem_CancelsMiddleRequestWithoutBreakingQueue() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;

        // Three users deposit equal token amounts.
        uint256 aliceShares = _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);
        uint256 bobShares = _mintAndDeposit(token0, token1, vault, bob, amount0, amount1);
        uint256 charlieShares = _mintAndDeposit(token0, token1, vault, charlie, amount0, amount1);

        // Deploy all underlying tokens so every user must use asynchronous redemption.
        _deployVaultToV3(vault, token0, token1, pool, positionManager, V3_LOW_VENUE_ID, tickLower, tickUpper, amount0*3, amount1*3);
        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);

        uint256 deadline = block.timestamp + 1 hours;

        vm.startPrank(alice);
        vault.approve(address(redemptionManager), aliceShares);
        uint256 requestId1 = redemptionManager.requestRedeem(aliceShares, alice, deadline);
        vm.stopPrank();

        vm.startPrank(bob);
        vault.approve(address(redemptionManager), bobShares);
        uint256 requestId2 = redemptionManager.requestRedeem(bobShares, bob, deadline);
        vm.stopPrank();

        vm.startPrank(charlie);
        vault.approve(address(redemptionManager), charlieShares);
        uint256 requestId3 = redemptionManager.requestRedeem(charlieShares, charlie, deadline);
        vm.stopPrank();

        // All three users' shares are now held in escrow by the redemption manager.
        assertEq(vault.balanceOf(address(redemptionManager)), aliceShares + bobShares + charlieShares);
        assertEq(redemptionManager.totalPendingRedeemShares(), aliceShares + bobShares + charlieShares);

        assertEq(redemptionManager.redeemQueueHead(), requestId1);
        assertEq(redemptionManager.redeemQueueTail(), requestId3);

        // Bob cancels the middle request.
        vm.prank(bob);
        redemptionManager.cancelRedeemRequest(requestId2);

        // Bob receives his escrowed shares back.
        assertEq(vault.balanceOf(bob), bobShares);
        // Only Alice and Charlie's shares remain in escrow.
        assertEq(vault.balanceOf(address(redemptionManager)), aliceShares + charlieShares);
        assertEq(redemptionManager.totalPendingRedeemShares(), aliceShares + charlieShares);

        // The queue remains Alice -> Charlie.
        (uint256 previous1, uint256 next1) = _getRedeemRequestLinks(requestId1);
        (uint256 previous3, uint256 next3) = _getRedeemRequestLinks(requestId3);

        assertEq(previous1, 0);
        assertEq(next1, requestId3);

        assertEq(previous3, requestId1);
        assertEq(next3, 0);

        assertEq(redemptionManager.redeemQueueHead(), requestId1);
        assertEq(redemptionManager.redeemQueueTail(), requestId3);

        // Bob's request remains as history but is no longer queued.
        assertEq(uint256(_getRedeemRequestStatus(requestId2)), uint256(RedemptionManager.RedeemRequestStatus.CANCELLED));
    }

}
