// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../src/AdaptiveLPVault.sol";
import "../src/adapters/UniswapV2Adapter.sol";
import "../src/strategies/FixedWeightStrategy.sol";
import "../src/strategies/VolatilityBucketStrategy.sol";
import "../src/oracles/PriceChangeVolatilityOracle.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockPriceOracle.sol";
import "./mocks/MockRebalanceStrategy.sol";
import "./mocks/MockUniswapV2Pair.sol";
import "./mocks/MockUniswapV2Router.sol";
import "./mocks/MockVolatilityOracle.sol";
import "../test/helpers/VaultTestHelper.sol";
import "../test/helpers/VenueTestHelper.sol";

/// @notice Covers the minimal strategy-driven rebalance entrypoint.
contract StrategyTest is Test, VaultTestHelper, VenueTestHelper {
    MockERC20 public token0;
    MockERC20 public token1;
    AdaptiveLPVault public vault;
    MockPriceOracle public priceOracle;
    MockVolatilityOracle public volatilityOracle;
    MockRebalanceStrategy public strategy;
    FixedWeightStrategy public fixedStrategy;
    VolatilityBucketStrategy public volatilityStrategy;
    
    MockUniswapV2Pair public pairV2;
    MockUniswapV2Router public routerV2;
    UniswapV2Adapter public adapterV2;
    
    uint256 internal constant SECOND_V2_VENUE_ID = 99;
    MockUniswapV2Pair public pairV2B;
    MockUniswapV2Router public routerV2B;
    UniswapV2Adapter public adapterV2B;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint8 public decimals0 = 18;
    uint8 public decimals1 = 6;

    uint256 public lowThresholdBps = 100;
    uint256 public highThresholdBps = 300;

    function setUp() public {
        token0 = new MockERC20("token0", "T0", decimals0);
        token1 = new MockERC20("token1", "T1", decimals1);

        vault = new AdaptiveLPVault(
            "Adaptive LP Vault", "ALPV", 
            address(token0), address(token1), 
            decimals0, decimals1
        );

        priceOracle = new MockPriceOracle();
        vault.setPriceOracle(address(priceOracle));
        priceOracle.setPrices(1e18, 1e18);

        volatilityOracle = new MockVolatilityOracle();

        strategy = new MockRebalanceStrategy();
        fixedStrategy = new FixedWeightStrategy();
        volatilityStrategy = new VolatilityBucketStrategy(address(volatilityOracle), lowThresholdBps, highThresholdBps);

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

        vault.setVenue(V2_VENUE_ID, address(adapterV2), V2_LABEL, true);

        // deploy another V2 venue for test_RebalanceWithStrategy_MovesDeployedPositionToNewVenueWithFixedWeightStrategy
        pairV2B = new MockUniswapV2Pair(address(token0), address(token1));
        routerV2B = new MockUniswapV2Router(pairV2B);
        adapterV2B = new UniswapV2Adapter(
            address(vault),
            address(token0),
            address(token1),
            address(routerV2B),
            address(pairV2B)
        );
        vault.setVenue(SECOND_V2_VENUE_ID, address(adapterV2B), bytes32("V2_B"), true);
    }

    /// @notice setStrategy stores the configured strategy address.
    function test_SetStrategy_SetsStrategy() public {
        vault.setStrategy(address(strategy));
        assertEq(address(vault.strategy()), address(strategy));
    }

    /// @notice setRebalanceConfig stores cooldown and gas price guards.
    function test_SetRebalanceConfig_SetsConfig() public {
        uint256 _minCooldown = 1 hours;
        uint256 _minVolatilityDelta = 100;
        uint256 _maxGasPrice = 50 gwei;
        vault.setRebalanceConfig(_minCooldown, _minVolatilityDelta, _maxGasPrice);
        (uint256 minCooldown, uint256 minVolatilityDelta, uint256 maxGasPrice) = vault.rebalanceConfig();
        assertEq(minCooldown, _minCooldown);
        assertEq(minVolatilityDelta, _minVolatilityDelta);
        assertEq(maxGasPrice, _maxGasPrice);
    }

    /// @notice rebalanceWithStrategy reverts before a strategy is configured.
    function test_RebalanceWithStrategy_RevertsWhenStrategyNotSet() public {
        vm.expectRevert(AdaptiveLPVault.StrategyNotSet.selector);
        vault.rebalanceWithStrategy("");
    }

    /// @notice Verifies strategy-driven rebalance is disabled while the vault is paused.
    function test_RebalanceWithStrategy_RevertsWhenPaused() public {
        vault.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.rebalanceWithStrategy("");
    }

    /// @notice rebalanceWithStrategy executes a single-venue strategy plan.
    function test_RebalanceWithStrategy_ExecutesSingleVenuePlan() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2e6;
        uint256 liquidity = 1 ether;

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        vault.setStrategy(address(strategy));
        strategy.setSingleTarget(V2_VENUE_ID, amount0, amount1, "");

        routerV2.setNextAddLiquidityResult(amount0, amount1, liquidity);

        vault.rebalanceWithStrategy("");

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);
        assertEq(token0.balanceOf(address(pairV2)), amount0);
        assertEq(token1.balanceOf(address(pairV2)), amount1);

        assertEq(vault.venueLiquidity(V2_VENUE_ID), liquidity);
        assertEq(vault.totalLiquidity(), liquidity);
    }

    /// @notice rebalanceWithStrategy records the timestamp after success.
    function test_RebalanceWithStrategy_UpdatesLastRebalance() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2e6;
        uint256 liquidity = 1 ether;

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        vault.setStrategy(address(strategy));
        strategy.setSingleTarget(V2_VENUE_ID, amount0, amount1, "");

        routerV2.setNextAddLiquidityResult(amount0, amount1, liquidity);

        vm.warp(1234);
        vault.rebalanceWithStrategy("");

        assertEq(vault.lastRebalance(), 1234);
    }

    /// @notice rebalanceWithStrategy enforces the configured cooldown.
    function test_RebalanceWithStrategy_RevertsDuringCooldown() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2e6;
        uint256 liquidity = 1 ether;

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        vault.setStrategy(address(strategy));
        vault.setRebalanceConfig(1 hours, 0, 0);

        strategy.setSingleTarget(V2_VENUE_ID, amount0, amount1, "");

        routerV2.setNextAddLiquidityResult(amount0, amount1, liquidity);

        vm.warp(1000);
        vault.rebalanceWithStrategy("");

        vm.expectRevert(AdaptiveLPVault.CooldownNotElapsed.selector);
        vault.rebalanceWithStrategy("");
    }

    /// @notice rebalanceWithStrategy enforces the configured max gas price.
    function test_RebalanceWithStrategy_RevertsWhenGasPriceTooHigh() public {
        vault.setStrategy(address(strategy));
        vault.setRebalanceConfig(0, 0, 50 gwei);
        
        vm.txGasPrice(51 gwei);
        vm.expectRevert(AdaptiveLPVault.GasPriceTooHigh.selector);
        vault.rebalanceWithStrategy("");
    }

    /// @notice strategy-built plans still go through venue validation.
    function test_RebalanceWithStrategy_RevertsWhenStrategyReturnsUnsetVenue() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2e6;

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        vault.setStrategy(address(strategy));
        strategy.setSingleTarget(999, amount0, amount1, "");
        
        vm.expectRevert(AdaptiveLPVault.VenueNotSet.selector);
        vault.rebalanceWithStrategy("");
    }

    /// @notice rebalanceWithStrategy can execute a real fixed-weight strategy plan.
    function test_RebalanceWithStrategy_ExecutesFixedWeightPlan() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;
        uint256 liquidity = 10 ether;

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);
        assertEq(token0.balanceOf(address(vault)), amount0);
        assertEq(token1.balanceOf(address(vault)), amount1);

        RebalanceTypes.TargetConfig[] memory configs = new RebalanceTypes.TargetConfig[](1);
        configs[0] = RebalanceTypes.TargetConfig({
            venueId: V2_VENUE_ID,
            weightBps: 10_000,
            params: ""
        });
        fixedStrategy.setTargets(configs);
        vault.setStrategy(address(fixedStrategy));

        routerV2.setNextAddLiquidityResult(amount0, amount1, liquidity);

        vault.rebalanceWithStrategy("");

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);
        assertEq(token0.balanceOf(address(pairV2)), amount0);
        assertEq(token1.balanceOf(address(pairV2)), amount1);
        assertEq(vault.venueLiquidity(V2_VENUE_ID), liquidity);
    }

    /// @notice rebalanceWithStrategy executes a volatility-selected allocation.
    function test_RebalanceWithStrategy_ExecutesVolatilityBucketPlan() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;
        uint256 liquidity = 10 ether;

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);
        assertEq(token0.balanceOf(address(vault)), amount0);
        assertEq(token1.balanceOf(address(vault)), amount1);

        RebalanceTypes.TargetConfig[] memory configs = new RebalanceTypes.TargetConfig[](1);
        configs[0] = RebalanceTypes.TargetConfig({
            venueId: V2_VENUE_ID,
            weightBps: 10_000,
            params: ""
        }); 
        volatilityStrategy.setBucketTargets(VolatilityBucketStrategy.Bucket.LOW, configs);
        vault.setStrategy(address(volatilityStrategy));

        routerV2.setNextAddLiquidityResult(amount0, amount1, liquidity);

        volatilityOracle.setVolatilityBps(50);
        vault.rebalanceWithStrategy("");

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);
        assertEq(token0.balanceOf(address(pairV2)), amount0);
        assertEq(token1.balanceOf(address(pairV2)), amount1);
        assertEq(vault.venueLiquidity(V2_VENUE_ID), liquidity);
    }

    /// @notice rebalanceWithStrategy can execute a plan selected by price-change volatility.
    function test_RebalanceWithStrategy_ExecutesPriceChangeVolatilityPlan() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;
        uint256 liquidity = 10 ether;

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        // Change price volatility
        PriceChangeVolatilityOracle priceChangeVolatilityOracle = new PriceChangeVolatilityOracle(address(priceOracle));
            // First update initializes the price snapshot.
        priceOracle.setPrices(100e18, 100e18);
        priceChangeVolatilityOracle.update();
            // Second update computes 50% volatility, which selects HIGH.
        priceOracle.setPrices(150e18, 110e18);
        priceChangeVolatilityOracle.update();
        assertEq(priceChangeVolatilityOracle.getVolatilityBps(), 5000);

        // Build target configs
        RebalanceTypes.TargetConfig[] memory configs = new RebalanceTypes.TargetConfig[](1);
        configs[0] = RebalanceTypes.TargetConfig({
            venueId: V2_VENUE_ID,
            weightBps: 10_000,
            params: ""
        });

        // Match bucket volatility level with target configs
        VolatilityBucketStrategy oracleBackedStrategy = new VolatilityBucketStrategy(
            address(priceChangeVolatilityOracle), 
            lowThresholdBps, 
            highThresholdBps
        );
        oracleBackedStrategy.setBucketTargets(VolatilityBucketStrategy.Bucket.HIGH, configs);

        // vault <-> strategy
        vault.setStrategy(address(oracleBackedStrategy));
        
        routerV2.setNextAddLiquidityResult(amount0, amount1, liquidity);

        vault.rebalanceWithStrategy("");

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);
        assertEq(token0.balanceOf(address(pairV2)), amount0);
        assertEq(token1.balanceOf(address(pairV2)), amount1);
        assertEq(vault.venueLiquidity(V2_VENUE_ID), liquidity);
    }

    /// @notice rebalanceWithStrategy reverts when volatility guard is enabled without an oracle.
    function test_RebalanceWithStrategy_RevertsWhenVolatilityOracleNotSet() public {
        vault.setStrategy(address(strategy));
        vault.setRebalanceConfig(0, 100, 0);

        vm.expectRevert(AdaptiveLPVault.VolatilityOracleNotSet.selector);
        vault.rebalanceWithStrategy("");
    }

    /// @notice rebalanceWithStrategy reverts when volatility change is below the configured minimum.
    function test_RebalanceWithStrategy_RevertsWhenVolatilityDeltaTooSmall() public {
        vault.setStrategy(address(strategy));
        vault.setRebalanceConfig(0, 100, 0);
        vault.setVolatilityOracle(address(volatilityOracle));

        volatilityOracle.setVolatilityBps(50);

        vm.expectRevert(AdaptiveLPVault.VolatilityDeltaTooSmall.selector);
        vault.rebalanceWithStrategy("");
    }

    /// @notice successful strategy rebalance records the current volatility.
    function test_RebalanceWithStrategy_UpdatesLastRebalanceVolatility() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;
        uint256 liquidity = 10 ether;

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        vault.setStrategy(address(strategy));
        vault.setRebalanceConfig(0, 100, 0);
        vault.setVolatilityOracle(address(volatilityOracle));

        volatilityOracle.setVolatilityBps(150);

        strategy.setSingleTarget(V2_VENUE_ID, amount0, amount1, "");
        routerV2.setNextAddLiquidityResult(amount0, amount1, liquidity);

        vault.rebalanceWithStrategy("");

        assertEq(vault.lastRebalanceVolatilityBps(), 150);
    }

    /// @notice fixed-weight strategy can move deployed capital from one venue to another.
    function test_RebalanceWithStrategy_MovesDeployedPositionToNewVenueWithFixedWeightStrategy() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;
        uint256 firstLiquidity = 10 ether;
        uint256 secondLiquidity = 20 ether;

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        routerV2.setNextAddLiquidityResult(amount0, amount1, firstLiquidity);
        vault.deployToVenue(V2_VENUE_ID, amount0, amount1, "");
        // V2 adapter getPositionValue() reads reserves, not raw token balances.
        pairV2.setReserves(uint112(amount0), uint112(amount1));

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token0.balanceOf(address(pairV2)), amount0);
        assertEq(vault.venueLiquidity(V2_VENUE_ID), firstLiquidity);
        assertEq(vault.venueLiquidity(SECOND_V2_VENUE_ID), 0);

        RebalanceTypes.TargetConfig[] memory configs = new RebalanceTypes.TargetConfig[](1);
        configs[0] = RebalanceTypes.TargetConfig({
            venueId: SECOND_V2_VENUE_ID,
            weightBps: 10_000,
            params: ""
        });
        fixedStrategy.setTargets(configs);
        vault.setStrategy(address(fixedStrategy));

        routerV2.setNextRemoveLiquidityResult(amount0, amount1);
        routerV2B.setNextAddLiquidityResult(amount0, amount1, secondLiquidity);

        vault.rebalanceWithStrategy("");

        assertEq(vault.venueLiquidity(V2_VENUE_ID), 0);
        assertEq(vault.venueLiquidity(SECOND_V2_VENUE_ID), secondLiquidity);
        assertEq(vault.totalLiquidity(), secondLiquidity);

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);

        assertEq(token0.balanceOf(address(pairV2B)), amount0);
        assertEq(token1.balanceOf(address(pairV2B)), amount1);
    }

    /// @notice volatility bucket strategy can move deployed capital from one venue to another.
    function test_RebalanceWithStrategy_MovesDeployedPositionToNewVenueWithVolatilityBucketStrategy() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;
        uint256 firstLiquidity = 10 ether;
        uint256 secondLiquidity = 20 ether;

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        routerV2.setNextAddLiquidityResult(amount0, amount1, firstLiquidity);
        vault.deployToVenue(V2_VENUE_ID, amount0, amount1, "");
        // V2 adapter getPositionValue() reads reserves, not raw token balances.
        pairV2.setReserves(uint112(amount0), uint112(amount1));

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token0.balanceOf(address(pairV2)), amount0);
        assertEq(vault.venueLiquidity(V2_VENUE_ID), firstLiquidity);
        assertEq(vault.venueLiquidity(SECOND_V2_VENUE_ID), 0);

        RebalanceTypes.TargetConfig[] memory configs = new RebalanceTypes.TargetConfig[](1);
        configs[0] = RebalanceTypes.TargetConfig({
            venueId: SECOND_V2_VENUE_ID,
            weightBps: 10_000,
            params: ""
        });
        volatilityOracle.setVolatilityBps(50);
        volatilityStrategy.setBucketTargets(VolatilityBucketStrategy.Bucket.LOW, configs);
        vault.setStrategy(address(volatilityStrategy));

        routerV2.setNextRemoveLiquidityResult(amount0, amount1);
        routerV2B.setNextAddLiquidityResult(amount0, amount1, secondLiquidity);

        vault.rebalanceWithStrategy("");

        assertEq(vault.venueLiquidity(V2_VENUE_ID), 0);
        assertEq(vault.venueLiquidity(SECOND_V2_VENUE_ID), secondLiquidity);
        assertEq(vault.totalLiquidity(), secondLiquidity);

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);

        assertEq(token0.balanceOf(address(pairV2B)), amount0);
        assertEq(token1.balanceOf(address(pairV2B)), amount1);
    }

}
