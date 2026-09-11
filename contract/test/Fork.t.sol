// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "./helpers/VenueTestHelper.sol";
import "../src/libraries/RebalanceTypes.sol";

import "../src/AdaptiveLPVault.sol";
import "../src/adapters/UniswapV2Adapter.sol";
import "../src/valuators/V2FairValueValuator.sol";
import "../src/oracles/V2TWAPOracle.sol";
import "../src/adapters/UniswapV3Adapter.sol";
import "../src/valuators/V3TwapPositionValuator.sol";
import "../src/strategies/V3TickCalculations.sol";
import "../src/redemption/RedemptionManager.sol";

interface IUniswapV2PairFork {
    function sync() external;
}

interface IUniswapV3FactoryFork {
    function getPool( address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

contract ForkTest is Test, VenueTestHelper {
    uint256 constant FORK_BLOCK = 20_000_000;
    uint32 constant TWAP_WINDOW = 1800;     // 30 min
    uint24 constant V3_LOW_FEE = 500;
    uint24 constant V3_MID_FEE = 3000;

    // Mainnet addresses
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant UNISWAP_V2_WETH_USDC_PAIR = 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc;
    address constant UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant NONFUNGIBLE_POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;

    AdaptiveLPVault public vault;
    RedemptionManager public redemptionManager;

    UniswapV2Adapter public v2Adapter;
    V2TWAPOracle public primaryV2Oracle;
    V2TWAPOracle public referenceV2Oracle;
    V2FairValueValuator public v2Valuator;

    UniswapV3Adapter public v3LowAdapter;
    V3TwapPositionValuator public v3LowValuator;
    IUniswapV3Pool public v3LowPool;
    int24 public v3LowTickLower;
    int24 public v3LowTickUpper;

    UniswapV3Adapter public v3MidAdapter;
    V3TwapPositionValuator public v3MidValuator;
    IUniswapV3Pool public v3MidPool;
    int24 public v3MidTickLower;
    int24 public v3MidTickUpper;

    address public alice = makeAddr("alice");

    function setUp() public {
        // 1. Load real Ethereum mainnet state.
        vm.createSelectFork(vm.rpcUrl("mainnet"), FORK_BLOCK);

        // 2. Deploy vault.
        vault = new AdaptiveLPVault("Fork Adaptive LP Vault", "fALPV", WETH, USDC, 18, 6);
        redemptionManager = new RedemptionManager(address(vault));
        vault.setRedemptionManager(address(redemptionManager));
        
        // 3. Deploy two distinct oracle contracts.
        primaryV2Oracle = new V2TWAPOracle(UNISWAP_V2_WETH_USDC_PAIR, WETH, USDC, TWAP_WINDOW);
        referenceV2Oracle = new V2TWAPOracle(UNISWAP_V2_WETH_USDC_PAIR, WETH, USDC, TWAP_WINDOW);
        // Produce the first valid 30-minute TWAP observation.
        vm.warp(block.timestamp + TWAP_WINDOW);
        IUniswapV2PairFork(UNISWAP_V2_WETH_USDC_PAIR).sync();
        primaryV2Oracle.update();
        referenceV2Oracle.update();
        // Connect the initialized oracles to the vault.
        vault.setPriceOracleConfig(address(primaryV2Oracle), 1 days, address(referenceV2Oracle), 1 days, 500);

        // 4. Deploy v2.
        v2Adapter = new UniswapV2Adapter(address(vault), WETH, USDC, UNISWAP_V2_ROUTER, UNISWAP_V2_WETH_USDC_PAIR);
        // Register v2 venue.
        vault.setVenue(V2_VENUE_ID, address(v2Adapter), V2_LABEL, true);
        // Configure valuation for the registered adapter.
        v2Valuator = new V2FairValueValuator(address(v2Adapter));
        vault.setVenueValuator(V2_VENUE_ID, address(v2Valuator));

        // 5. Deploy V3 low. 
        // Configure the real WETH/USDC 0.05% V3 pool.
        address v3LowPoolAddress = IUniswapV3FactoryFork(UNISWAP_V3_FACTORY).getPool(WETH, USDC, V3_LOW_FEE);
        v3LowPool = IUniswapV3Pool(v3LowPoolAddress);
        // Build a spacing-aligned range around the current mainnet tick.
        V3TickCalculations lowTickCalculations = new V3TickCalculations(v3LowPoolAddress);
        (v3LowTickLower, v3LowTickUpper) = lowTickCalculations.calculateTickRange(0);
        v3LowAdapter = new UniswapV3Adapter(address(vault), WETH, USDC, NONFUNGIBLE_POSITION_MANAGER, address(v3LowPool), v3LowTickLower, v3LowTickUpper);
        vault.setVenue(V3_LOW_VENUE_ID, address(v3LowAdapter), V3_LOW_LABEL, true);
        v3LowValuator = new V3TwapPositionValuator(address(v3LowAdapter), TWAP_WINDOW);
        vault.setVenueValuator(V3_LOW_VENUE_ID, address(v3LowValuator));

        // 6. Deploy V3 mid. 
        address v3MidPoolAddress = IUniswapV3FactoryFork(UNISWAP_V3_FACTORY).getPool(WETH, USDC, V3_MID_FEE);
        // assertGt(v3)
        v3MidPool = IUniswapV3Pool(v3MidPoolAddress);
        V3TickCalculations midTickCalculations = new V3TickCalculations(v3MidPoolAddress);
        (v3MidTickLower, v3MidTickUpper) = midTickCalculations.calculateTickRange(0);
        v3MidAdapter = new UniswapV3Adapter(address(vault), WETH, USDC, NONFUNGIBLE_POSITION_MANAGER, address(v3MidPool), v3MidTickLower, v3MidTickUpper);
        vault.setVenue(V3_MID_VENUE_ID, address(v3MidAdapter), V3_MID_LABEL, true);
        v3MidValuator = new V3TwapPositionValuator(address(v3MidAdapter), TWAP_WINDOW);
        vault.setVenueValuator(V3_MID_VENUE_ID, address(v3MidValuator));
    }

    function test_Fork_V2_DepositDeployWithdrawAndRedeem() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;

        deal(WETH, alice, amount0);
        deal(USDC, alice, amount1);

        // alice -> vault
        vm.startPrank(alice);
        IERC20(WETH).approve(address(vault), amount0);
        IERC20(USDC).approve(address(vault), amount1);
        uint256 aliceShares = vault.deposit(amount0, amount1, alice, 0);
        vm.stopPrank();

        uint256 lockedShares = vault.MINIMUM_LOCKED_SHARES();
        uint256 supplyAfterDeposit = vault.totalSupply();
        assertGt(aliceShares, 0); // > 0
        assertEq(vault.balanceOf(alice), aliceShares);
        assertEq(vault.balanceOf(vault.LOCKED_SHARES_RECEIVER()), lockedShares);
        assertEq(supplyAfterDeposit, aliceShares + lockedShares);

        // vault -> V2 venue
        uint256 liquidity = vault.deployToVenue(V2_VENUE_ID, amount0, amount1, "");
        assertGt(liquidity, 0);
        assertEq(v2Adapter.pair().balanceOf(address(v2Adapter)), liquidity);

        uint256 assetsWhileDeployed = vault.totalAssets();
        assertGt(assetsWhileDeployed, 0);

        // V2 venue -> vault
        (uint256 withdrawn0, uint256 withdrawn1) = vault.withdrawFromVenue(V2_VENUE_ID, liquidity, "");
        assertGt(withdrawn0, 0);
        assertGt(withdrawn1, 0);
        assertEq(v2Adapter.pair().balanceOf(address(v2Adapter)), 0);

        // vault -> alice
        uint256 alice0Before = IERC20(WETH).balanceOf(alice);
        uint256 alice1Before = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        (uint256 redeemed0, uint256 redeemed1) = vault.redeem(aliceShares, alice, alice, 0, 0);
        
        assertGt(redeemed0, 0);
        assertGt(redeemed1, 0);
        assertEq(IERC20(WETH).balanceOf(alice), alice0Before + redeemed0);
        assertEq(IERC20(USDC).balanceOf(alice), alice1Before + redeemed1);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalSupply(), lockedShares);
    }

    function test_Fork_V3_DepositDeployWithdrawAndRedeem() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;

        deal(WETH, alice, amount0);
        deal(USDC, alice, amount1);

        // alice -> vault
        vm.startPrank(alice);
        IERC20(WETH).approve(address(vault), amount0);
        IERC20(USDC).approve(address(vault), amount1);
        uint256 aliceShares = vault.deposit(amount0, amount1, alice, 0);
        vm.stopPrank();

        // vault -> V3 low venue
        bytes memory v3Params = _v3Params(0, 0, block.timestamp + 1 hours, v3LowTickLower, v3LowTickUpper);
        uint256 liquidity = vault.deployToVenue(V3_LOW_VENUE_ID, amount0, amount1, v3Params);
        assertGt(liquidity, 0);
        assertGt(v3LowAdapter.tokenId(), 0); // has position
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), liquidity);

        uint256 assetsWhileDeployed = vault.totalAssets();
        assertGt(assetsWhileDeployed, 0);

        // v3 low venue -> vault
        (uint256 withdrawn0, uint256 withdrawn1) = vault.withdrawFromVenue(V3_LOW_VENUE_ID, liquidity, v3Params);
        assertGt(withdrawn0, 0);
        assertGt(withdrawn1, 0);
        assertEq(v3LowAdapter.tokenId(), 0); // no position
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), 0);

        // vault -> alice
        uint256 aliceBefore0 = IERC20(WETH).balanceOf(alice);
        uint256 aliceBefore1 = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        (uint256 redeemed0, uint256 redeemed1) = vault.redeem(aliceShares, alice, alice, 0, 0);

        assertGt(redeemed0, 0);
        assertGt(redeemed1, 0);
        assertEq(IERC20(WETH).balanceOf(alice), aliceBefore0 + redeemed0);
        assertEq(IERC20(USDC).balanceOf(alice), aliceBefore1 + redeemed1);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalSupply(), vault.MINIMUM_LOCKED_SHARES());
    }

    function test_Fork_Rebalance_MigratesV2ToV3() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;

        deal(WETH, alice, amount0);
        deal(USDC, alice, amount1);

        // alice -> vault
        vm.startPrank(alice);
        IERC20(WETH).approve(address(vault), amount0);
        IERC20(USDC).approve(address(vault), amount1);
        vault.deposit(amount0, amount1, alice, 0);
        vm.stopPrank();

        // vault -> V2 venue
        uint256 v2Liquidity = vault.deployToVenue(V2_VENUE_ID, amount0, amount1, "");
        assertGt(v2Liquidity, 0);
        assertEq(v2Adapter.pair().balanceOf(address(v2Adapter)), v2Liquidity);

        (uint256 v2Amount0, uint256 v2Amount1) = v2Adapter.getPositionValue();
        uint256 available0 = IERC20(WETH).balanceOf(address(vault)) + v2Amount0;
        uint256 available1 = IERC20(USDC).balanceOf(address(vault)) + v2Amount1;
        uint256 target0 = available0 * 99 / 100;
        uint256 target1 = available1 * 99 / 100;
        bytes memory v3Params = _v3Params(0, 0, block.timestamp + 1 hours, v3LowTickLower, v3LowTickUpper);
        RebalanceTypes.RebalanceTarget[] memory targets = new RebalanceTypes.RebalanceTarget[](1);
        targets[0] = RebalanceTypes.RebalanceTarget({
            venueId: V3_LOW_VENUE_ID,
            amount0: target0,
            amount1: target1,
            params: v3Params
        }); 

        AdaptiveLPVault.VenueWithdrawalParams[] memory withdrawalParams = new AdaptiveLPVault.VenueWithdrawalParams[](0);
        uint256 supplyBefore = vault.totalSupply(); // total vault shares
        uint256 assetsBefore = vault.totalAssets(); // value in base asset

        vault.setMaxRebalanceValueLossBps(500);
        vault.rebalance(targets, withdrawalParams);

        assertEq(v2Adapter.pair().balanceOf(address(v2Adapter)), 0);
        assertEq(vault.venueLiquidity(V2_VENUE_ID), 0);

        assertGt(v3LowAdapter.tokenId(), 0);
        assertGt(vault.venueLiquidity(V3_LOW_VENUE_ID), 0);

        assertEq(vault.totalSupply(), supplyBefore);
        uint256 assetsAfter = vault.totalAssets();
        assertGe(assetsAfter, assetsBefore * 9500 / 10000); // >=
    }

    function test_Fork_Rebalance_MigratesV3LowToV3Mid() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;

        deal(WETH, alice, amount0);
        deal(USDC, alice, amount1);

        // alice -> vault
        vm.startPrank(alice);
        IERC20(WETH).approve(address(vault), amount0);
        IERC20(USDC).approve(address(vault), amount1);
        vault.deposit(amount0, amount1, alice, 0);
        vm.stopPrank();

        // vault -> V3 low venue
        bytes memory v3LowParams = _v3Params(0, 0, block.timestamp + 1 hours, v3LowTickLower, v3LowTickUpper);
        uint256 liquidity = vault.deployToVenue(V3_LOW_VENUE_ID, amount0, amount1, v3LowParams);
        assertGt(liquidity, 0);
        assertGt(v3LowAdapter.tokenId(), 0); // has position
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), liquidity);

        (uint256 v3LowAmount0, uint256 v3LowAmount1) = v3LowAdapter.getPositionValue();
        uint256 available0 = IERC20(WETH).balanceOf(address(vault)) + v3LowAmount0;
        uint256 available1 = IERC20(USDC).balanceOf(address(vault)) + v3LowAmount1;
        uint256 target0 = available0 * 99 / 100;
        uint256 target1 = available1 * 99 / 100;
        bytes memory v3MidParams = _v3Params(0, 0, block.timestamp + 1 hours, v3MidTickLower, v3MidTickUpper);
        RebalanceTypes.RebalanceTarget[] memory targets = new RebalanceTypes.RebalanceTarget[](1);
        targets[0] = RebalanceTypes.RebalanceTarget({
            venueId: V3_MID_VENUE_ID,
            amount0: target0,
            amount1: target1,
            params: v3MidParams
        }); 

        AdaptiveLPVault.VenueWithdrawalParams[] memory withdrawalParams = new AdaptiveLPVault.VenueWithdrawalParams[](0);
        uint256 supplyBefore = vault.totalSupply(); // total vault shares
        uint256 assetsBefore = vault.totalAssets(); // value in base asset

        vault.setMaxRebalanceValueLossBps(500);
        vault.rebalance(targets, withdrawalParams);

        assertEq(v3LowAdapter.tokenId(), 0);
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), 0);

        assertGt(v3MidAdapter.tokenId(), 0);
        assertGt(vault.venueLiquidity(V3_MID_VENUE_ID), 0);

        assertEq(vault.totalSupply(), supplyBefore);
        uint256 assetsAfter = vault.totalAssets();
        assertGe(assetsAfter, assetsBefore * 9500 / 10000); // >=
    }

    function test_Fork_EmergencyExit_WithdrawsV2AndV3Positions() public {
        uint256 amount0PerVenue = 1 ether;
        uint256 amount1PerVenue = 2000e6;

        uint256 totalAmount0 = amount0PerVenue * 2;
        uint256 totalAmount1 = amount1PerVenue * 2;

        // 1. Alice deposits enough assets for both V2 and V3 positions.
        deal(WETH, alice, totalAmount0);
        deal(USDC, alice, totalAmount1);

        vm.startPrank(alice);
        IERC20(WETH).approve(address(vault), totalAmount0);
        IERC20(USDC).approve(address(vault), totalAmount1);
        vault.deposit(totalAmount0, totalAmount1, alice, 0);
        vm.stopPrank();

        uint256 supplyBefore = vault.totalSupply();

        // Vault -> V2 venue
        uint256 v2Liquidity = vault.deployToVenue(V2_VENUE_ID, amount0PerVenue, amount1PerVenue, "");
        assertGt(v2Liquidity, 0);
        assertEq(v2Adapter.pair().balanceOf(address(v2Adapter)), v2Liquidity);

        // Vault -> V3_LOW venue
        bytes memory v3Params = _v3Params(0, 0, block.timestamp + 1 hours, v3LowTickLower, v3LowTickUpper);
        uint256 v3Liquidity = vault.deployToVenue(V3_LOW_VENUE_ID, amount0PerVenue, amount1PerVenue, v3Params);
        assertGt(v3Liquidity, 0);
        assertGt(v3LowAdapter.tokenId(), 0);

        AdaptiveLPVault.VenueWithdrawalParams[] memory withdrawalParams = new AdaptiveLPVault.VenueWithdrawalParams[](1);
        withdrawalParams[0] = AdaptiveLPVault.VenueWithdrawalParams({
            venueId: V3_LOW_VENUE_ID,
            params: v3Params
        });
        vault.emergencyExit(withdrawalParams);

        assertTrue(vault.paused());

        assertEq(v2Adapter.pair().balanceOf(address(v2Adapter)), 0);
        assertEq(vault.venueLiquidity(V2_VENUE_ID), 0);
        assertEq(v3LowAdapter.tokenId(), 0);
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), 0);

        assertEq(vault.totalSupply(), supplyBefore);
        assertGt(IERC20(WETH).balanceOf(address(vault)), 0);
        assertGt(IERC20(USDC).balanceOf(address(vault)), 0);
    }

    function test_Fork_AsyncRedeem_SettlesFromV3Position() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2000e6;
        uint256 deadline = block.timestamp + 1 days;

        deal(WETH, alice, amount0);
        deal(USDC, alice, amount1);

        // alice -> vault
        vm.startPrank(alice);
        IERC20(WETH).approve(address(vault), amount0);
        IERC20(USDC).approve(address(vault), amount1);
        uint256 aliceShares = vault.deposit(amount0, amount1, alice, 0);
        vm.stopPrank();

        // vault -> V3 low venue
        bytes memory v3LowParams = _v3Params(0, 0, deadline, v3LowTickLower, v3LowTickUpper);
        uint256 liquidity = vault.deployToVenue(V3_LOW_VENUE_ID, amount0, amount1, v3LowParams);
        assertGt(v3LowAdapter.tokenId(), 0); // has position
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), liquidity);

        // Alice's vault shares -> RedemptionManager escrow
        vm.startPrank(alice);
        vault.approve(address(redemptionManager), aliceShares);
        uint256 requestId = redemptionManager.requestRedeem(aliceShares, alice, deadline);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(address(redemptionManager)), aliceShares);
        assertEq(redemptionManager.redeemQueueHead(), requestId);

        redemptionManager.activateNextRedeemRequest();
        assertEq(redemptionManager.activeRedeemRequestId(), requestId);

        // V3_LOW position -> Vault idle balances reserved for the request
        uint256 venueLiquidityBefore = vault.venueLiquidity(V3_LOW_VENUE_ID);
        redemptionManager.fundActiveRedeemRequest(V3_LOW_VENUE_ID, v3LowParams);
        assertLt(vault.venueLiquidity(V3_LOW_VENUE_ID), venueLiquidityBefore);

        // Vault -> Alice; escrowed vault shares are burned
        uint256 alice0Before = IERC20(WETH).balanceOf(alice);
        uint256 alice1Before = IERC20(USDC).balanceOf(alice);
        (uint256 amount0Out, uint256 amount1Out) = redemptionManager.processNextRedeemRequest();
        assertGt(amount0Out, 0);
        assertGt(amount1Out, 0);
        assertEq(IERC20(WETH).balanceOf(alice), alice0Before + amount0Out);
        assertEq(IERC20(USDC).balanceOf(alice), alice1Before + amount1Out);

        assertEq(vault.balanceOf(address(redemptionManager)), 0);
        assertEq(redemptionManager.activeRedeemRequestId(), 0);
        assertEq(redemptionManager.redeemQueueHead(), 0);
        assertEq(redemptionManager.redeemQueueTail(), 0);

        assertEq(vault.totalSupply(), vault.MINIMUM_LOCKED_SHARES());
    }
}
