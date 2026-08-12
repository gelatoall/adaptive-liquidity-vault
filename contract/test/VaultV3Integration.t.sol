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
        (,,,,,,,, status) = redemptionManager.redeemRequests(requestId);
    }

    /// @notice Returns the previous and next queue links for a redemption request.
    function _getRedeemRequestLinks(uint256 requestId) internal view returns (uint256 previousRequestId, uint256 nextRequestId) {
        (,,,,,, previousRequestId, nextRequestId,) = redemptionManager.redeemRequests(requestId);
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
        uint256 liquidity = _deployVaultToV3(vault, token0, token1, pool, positionManager, 
                                V3_LOW_VENUE_ID, tickLower, tickUpper, amount0, amount1);
        
        assertEq(vault.totalLiquidity(), liquidity);

        assertTrue(adapter.hasPosition());
        assertEq(adapter.tokenId(), 1);

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);
        // Note：真实情况token是在pool里面，这里只是简化了Mock
        assertEq(token0.balanceOf(address(positionManager)), amount0);
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

        assertEq(vault.totalLiquidity(), deployedLiquidity);
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
        assertEq(vault.totalLiquidity(), deployedLiquidity);

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

    /// @notice Verifies harvesting transfers V3 fees to vault idle balances without removing the active position.
    function test_HarvestVenueFees_CollectsFeesWithoutRemovingPosition() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;
        uint256 fee0 = 0.1 ether;
        uint256 fee1 = 200e6;

        // user -> vault
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        // vault -> pool
        uint256 liquidity = _deployVaultToV3(vault, token0, token1, pool, positionManager, 
                                V3_LOW_VENUE_ID, tickLower, tickUpper, amount0, amount1);

        (uint256 feePool0, uint256 feePool1) = _mapPoolAmounts(token0, token1, fee0, fee1);
        positionManager.addFees(adapter.tokenId(), uint128(feePool0), uint128(feePool1));

        uint256 vault0Before = token0.balanceOf(address(vault));
        uint256 vault1Before = token1.balanceOf(address(vault));

        (uint256 collected0, uint256 collected1) = vault.harvestVenueFees(V3_LOW_VENUE_ID);
        assertEq(collected0, fee0);
        assertEq(collected1, fee1);

        assertEq(token0.balanceOf(address(vault)), vault0Before + fee0);
        assertEq(token1.balanceOf(address(vault)), vault1Before + fee1);
        
        assertEq(vault.totalLiquidity(), liquidity);
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
        assertEq(vault.totalLiquidity(), venueLiquidityBefore + liquidityAdded);
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

        _deployVaultToV3(
            vault,
            token0,
            token1,
            pool,
            positionManager,
            V3_LOW_VENUE_ID,
            tickLower,
            tickUpper,
            amount0,
            amount1
        );

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

    /// @notice Verifies a queued redemption can be activated, funded from V3, and settled.
    function test_AsyncRedeem_ProcessesQueuedRequest() public {
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

        uint256 minAmount0Out = amount0 * 99 / 100;
        uint256 minAmount1Out = amount1 * 99 / 100;
        uint256 deadline = block.timestamp + 1 hours;

        // With no idle liquidity available, the frontend selects the asynchronous redemption path.
        vm.startPrank(alice);
        vault.approve(address(redemptionManager), aliceShares);
        uint256 requestId = redemptionManager.requestRedeem(aliceShares, alice, minAmount0Out, minAmount1Out, deadline);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(address(redemptionManager)), aliceShares);
        assertEq(redemptionManager.redeemQueueHead(), requestId);
        assertEq(redemptionManager.redeemQueueTail(), requestId);
        assertEq(redemptionManager.totalPendingRedeemShares(), aliceShares);
        assertEq(uint256(_getRedeemRequestStatus(requestId)), uint256(RedemptionManager.RedeemRequestStatus.PENDING));

        // Activating the queue head reserves future idle liquidity for this request.
        redemptionManager.activateNextRedeemRequest();
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
        // Configure the mock to return all deployed tokens during withdrawal.
        (uint256 poolAmount0, uint256 poolAmount1) = _mapPoolAmounts(token0, token1, totalAmount0, totalAmount1);

        positionManager.setNextDecreaseResult(poolAmount0, poolAmount1);

        // Withdraw V3 liquidity in a separate transaction to refill idle balances.
        vault.withdrawFromVenue(V3_LOW_VENUE_ID, liquidity, _v3Params(0, 0, deadline, tickLower, tickUpper));
        assertEq(token0.balanceOf(address(vault)), totalAmount0);
        assertEq(token1.balanceOf(address(vault)), totalAmount1);

        // Processing is permissionless after activation, so Bob can settle it.
        vm.prank(bob);
        (uint256 amount0Out, uint256 amount1Out) = redemptionManager.processNextRedeemRequest();

        // Alice's requested output limits are respected.
        assertGe(amount0Out, minAmount0Out);
        assertGe(amount1Out, minAmount1Out);
        assertEq(token0.balanceOf(alice), amount0Out);
        assertEq(token1.balanceOf(alice), amount1Out);

        // Escrowed shares were burned and the request was removed from the queue.
        assertEq(vault.balanceOf(address(redemptionManager)), 0);
        assertEq(redemptionManager.activeRedeemRequestId(), 0);
        assertEq(redemptionManager.redeemQueueHead(), 0);
        assertEq(redemptionManager.redeemQueueTail(), 0);
        assertEq(redemptionManager.totalPendingRedeemShares(), 0);

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
        uint256 requestId1 = redemptionManager.requestRedeem(aliceShares, alice, 0, 0, deadline);
        vm.stopPrank();

        vm.startPrank(bob);
        vault.approve(address(redemptionManager), bobShares);
        uint256 requestId2 = redemptionManager.requestRedeem(bobShares, bob, 0, 0, deadline);
        vm.stopPrank();

        vm.startPrank(charlie);
        vault.approve(address(redemptionManager), charlieShares);
        uint256 requestId3 = redemptionManager.requestRedeem(charlieShares, charlie, 0, 0, deadline);
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

    /// @notice Verifies output minimums protect queued shares and an expired active request can be cleared.
    function test_AsyncRedeem_EnforcesMinimumAndExpiresActiveRequest() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;

        // Alice and Bob deposit equal amounts.
        uint256 aliceShares = _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);
        _mintAndDeposit(token0, token1, vault, bob, amount0, amount1);

        uint256 totalSupplyBefore = vault.totalSupply();
        uint256 totalAmount0 = amount0 * 2;
        uint256 totalAmount1 = amount1 * 2;

        // Deploy all underlying tokens so Alice must use asynchronous redemption.
        uint256 liquidity = _deployVaultToV3(vault, token0, token1, pool, positionManager, V3_LOW_VENUE_ID, tickLower, tickUpper, totalAmount0, totalAmount1);
        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);

        uint256 deadline = block.timestamp + 1 hours;

        // Set an impossible token0 minimum so final settlement must revert.
        vm.startPrank(alice);
        vault.approve(address(redemptionManager), aliceShares);
        uint256 requestId = redemptionManager.requestRedeem(aliceShares, alice, type(uint256).max, 0, deadline);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(address(redemptionManager)), aliceShares);

        // Activate the queue-head request.
        redemptionManager.activateNextRedeemRequest();

        assertEq(redemptionManager.activeRedeemRequestId(), requestId);
        assertEq(uint256(_getRedeemRequestStatus(requestId)), uint256(RedemptionManager.RedeemRequestStatus.PROCESSING));

        // Configure the V3 mock to return all deployed tokens.
        (uint256 poolAmount0, uint256 poolAmount1) = _mapPoolAmounts(token0, token1, totalAmount0, totalAmount1);
        positionManager.setNextDecreaseResult(poolAmount0, poolAmount1);

        // Withdraw the V3 position into vault idle balances.
        vault.withdrawFromVenue(V3_LOW_VENUE_ID, liquidity, _v3Params(0, 0, deadline, tickLower, tickUpper));

        assertEq(token0.balanceOf(address(vault)), totalAmount0);
        assertEq(token1.balanceOf(address(vault)), totalAmount1);

        // Settlement must revert because amount0Out cannot reach type(uint256).max.
        vm.expectRevert(AdaptiveLPVault.InsufficientRedeemOutput.selector);
        redemptionManager.processNextRedeemRequest();

        // The failed settlement must not burn shares or remove the request.
        assertEq(vault.balanceOf(address(redemptionManager)), aliceShares);
        assertEq(vault.totalSupply(), totalSupplyBefore);
        assertEq(redemptionManager.activeRedeemRequestId(), requestId);
        assertEq(redemptionManager.redeemQueueHead(), requestId);
        assertEq(redemptionManager.redeemQueueTail(), requestId);
        assertEq(redemptionManager.totalPendingRedeemShares(), aliceShares);
        assertEq(uint256(_getRedeemRequestStatus(requestId)), uint256(RedemptionManager.RedeemRequestStatus.PROCESSING));

        // Move beyond the user-selected deadline.
        vm.warp(deadline + 1);

        // Expiration is permissionless, so Charlie can clear Alice's request.
        vm.prank(charlie);
        redemptionManager.expireRedeemRequest(requestId);

        // Alice receives her escrowed shares back instead of receiving underlying tokens.
        assertEq(vault.balanceOf(alice), aliceShares);
        assertEq(vault.balanceOf(address(redemptionManager)), 0);
        assertEq(vault.totalSupply(), totalSupplyBefore);

        // Expiring the active request exits processing mode and clears the queue.
        assertEq(redemptionManager.activeRedeemRequestId(), 0);
        assertEq(redemptionManager.redeemQueueHead(), 0);
        assertEq(redemptionManager.redeemQueueTail(), 0);
        assertEq(redemptionManager.totalPendingRedeemShares(), 0);
        assertEq(uint256(_getRedeemRequestStatus(requestId)), uint256(RedemptionManager.RedeemRequestStatus.EXPIRED));

        // Settlement never happened, so Alice received no underlying tokens.
        assertEq(token0.balanceOf(alice), 0);
        assertEq(token1.balanceOf(alice), 0);
    }
}
