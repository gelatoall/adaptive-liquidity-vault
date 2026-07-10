// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../src/AdaptiveLPVault.sol";
import "../src/adapters/UniswapV2Adapter.sol";
import "../src/strategies/FixedWeightStrategy.sol";
import "../src/strategies/VolatilityBucketStrategy.sol";
import "../src/oracles/PriceChangeVolatilityOracle.sol";
import "../src/oracles/V3TwapVolatilityOracle.sol";
import "./mocks/MockUniswapV3Pool.sol";
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

    /// @notice System health is normal when pause and oracle health checks are disabled.
    function test_CheckSystemHealth_ReturnsNormalByDefault() public {
        assertEq(uint256(vault.checkSystemHealth()), uint256(AdaptiveLPVault.SystemStatus.NORMAL));
    }

    /// @notice System health reports PAUSED when the vault is paused.
    function test_CheckSystemHealth_ReturnsPausedWhenVaultIsPaused() public {
        vault.pause();
        assertEq(uint256(vault.checkSystemHealth()), uint256(AdaptiveLPVault.SystemStatus.PAUSED));
    }

    /// @notice Enabled oracle health check reports ORACLE_STALE when no volatility oracle is configured.
    function test_CheckSystemHealth_ReturnsOracleStaleWhenEnabledWithoutOracle() public {
        vault.setOracleHealthCheckEnabled(true);
        assertEq(uint256(vault.checkSystemHealth()), uint256(AdaptiveLPVault.SystemStatus.ORACLE_STALE));
    }

    /// @notice rebalanceWithStrategy reverts when oracle health check requires a missing volatility oracle.
    function test_RebalanceWithStrategy_RevertsWhenOracleHealthCheckEnabledWithoutOracle() public {
        vault.setStrategy(address(strategy));
        vault.setOracleHealthCheckEnabled(true);

        vm.expectRevert(AdaptiveLPVault.VolatilityOracleNotSet.selector);
        vault.rebalanceWithStrategy("", _emptyWithdrawalParams());
    }

    /// @notice Configuring the volatility oracle restores NORMAL health when oracle health check is enabled.
    function test_CheckSystemHealth_ReturnsNormalWhenOracleHealthCheckHasOracle() public {
        vault.setOracleHealthCheckEnabled(true);
        vault.setVolatilityOracle(address(volatilityOracle));

        assertEq(uint256(vault.checkSystemHealth()), uint256(AdaptiveLPVault.SystemStatus.NORMAL));
    }

    /// @notice canRebalanceWithStrategy reports a missing strategy before execution.
    function test_CanRebalanceWithStrategy_ReturnsFalseWhenStrategyNotSet() public {
        (bool allowed, string memory reason) = vault.canRebalanceWithStrategy();

        assertFalse(allowed);
        assertEq(reason, "Rebalance strategy not set");
    }

    /// @notice canRebalanceWithStrategy reports true when vault-level guards pass.
    function test_CanRebalanceWithStrategy_ReturnsTrueWhenGuardsPass() public {
        vault.setStrategy(address(strategy));

        (bool allowed, string memory reason) = vault.canRebalanceWithStrategy();

        assertTrue(allowed);
        assertEq(reason, "");
    }

    /// @notice canRebalanceWithStrategy mirrors the oracle health requirement.
    function test_CanRebalanceWithStrategy_ReturnsFalseWhenVolatilityOracleNotSet() public {
        vault.setStrategy(address(strategy));
        vault.setOracleHealthCheckEnabled(true);

        (bool allowed, string memory reason) = vault.canRebalanceWithStrategy();

        assertFalse(allowed);
        assertEq(reason, "Volatility oracle not set");
    }

    /// @notice canRebalanceWithStrategy reports when volatility movement is below the configured threshold.
    function test_CanRebalanceWithStrategy_ReturnsFalseWhenVolatilityDeltaTooSmall() public {
        vault.setStrategy(address(strategy));
        vault.setRebalanceConfig(0, 100, 0);
        vault.setVolatilityOracle(address(volatilityOracle));
        volatilityOracle.setVolatilityBps(50);

        (bool allowed, string memory reason) = vault.canRebalanceWithStrategy();

        assertFalse(allowed);
        assertEq(reason, "Volatility delta too small");
    }

    /// @notice rebalanceWithStrategy reverts before a strategy is configured.
    function test_RebalanceWithStrategy_RevertsWhenStrategyNotSet() public {
        vm.expectRevert(AdaptiveLPVault.StrategyNotSet.selector);
        vault.rebalanceWithStrategy("", _emptyWithdrawalParams());
    }

    /// @notice Verifies strategy-driven rebalance is disabled while the vault is paused.
    function test_RebalanceWithStrategy_RevertsWhenPaused() public {
        vault.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.rebalanceWithStrategy("", _emptyWithdrawalParams());
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

        vault.rebalanceWithStrategy("", _emptyWithdrawalParams());

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
        vault.rebalanceWithStrategy("", _emptyWithdrawalParams());

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
        vault.rebalanceWithStrategy("", _emptyWithdrawalParams());

        vm.expectRevert(AdaptiveLPVault.CooldownNotElapsed.selector);
        vault.rebalanceWithStrategy("", _emptyWithdrawalParams());
    }

    /// @notice rebalanceWithStrategy enforces the configured max gas price.
    function test_RebalanceWithStrategy_RevertsWhenGasPriceTooHigh() public {
        vault.setStrategy(address(strategy));
        vault.setRebalanceConfig(0, 0, 50 gwei);
        
        vm.txGasPrice(51 gwei);
        vm.expectRevert(AdaptiveLPVault.GasPriceTooHigh.selector);
        vault.rebalanceWithStrategy("", _emptyWithdrawalParams());
    }

    /// @notice strategy-built plans still go through venue validation.
    function test_RebalanceWithStrategy_RevertsWhenStrategyReturnsUnsetVenue() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 2e6;

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        vault.setStrategy(address(strategy));
        strategy.setSingleTarget(999, amount0, amount1, "");
        
        vm.expectRevert(AdaptiveLPVault.VenueNotSet.selector);
        vault.rebalanceWithStrategy("", _emptyWithdrawalParams());
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

        vault.rebalanceWithStrategy("", _emptyWithdrawalParams());

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
        vault.rebalanceWithStrategy("", _emptyWithdrawalParams());

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

        vault.rebalanceWithStrategy("", _emptyWithdrawalParams());

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);
        assertEq(token0.balanceOf(address(pairV2)), amount0);
        assertEq(token1.balanceOf(address(pairV2)), amount1);
        assertEq(vault.venueLiquidity(V2_VENUE_ID), liquidity);
    }

    /// @notice rebalanceWithStrategy can use V3 TWAP volatility to build and execute a bucket plan.
    function test_RebalanceWithStrategy_ExecutesPlanFromV3TwapVolatilityOracle() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;
        uint256 liquidity = 10 ether;

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        uint32 twapWindow = 1800;
        vm.warp(twapWindow);

        MockUniswapV3Pool pool = new MockUniswapV3Pool(address(token0), address(token1), 3000);
        pool.setTwapTick(0);
        pool.setSlot0FromTick(0);

        V3TwapVolatilityOracle v3Oracle = new V3TwapVolatilityOracle(address(pool), twapWindow);
        assertEq(v3Oracle.getVolatilityBps(), 0);

        VolatilityBucketStrategy v3OracleStrategy =
            new VolatilityBucketStrategy(address(v3Oracle), lowThresholdBps, highThresholdBps);

        RebalanceTypes.TargetConfig[] memory configs = new RebalanceTypes.TargetConfig[](1);
        configs[0] = RebalanceTypes.TargetConfig({
            venueId: V2_VENUE_ID,
            weightBps: 10_000,
            params: ""
        });

        v3OracleStrategy.setBucketTargets(VolatilityBucketStrategy.Bucket.LOW, configs);
        vault.setStrategy(address(v3OracleStrategy));

        routerV2.setNextAddLiquidityResult(amount0, amount1, liquidity);

        vault.rebalanceWithStrategy("", _emptyWithdrawalParams());

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);
        assertEq(token0.balanceOf(address(pairV2)), amount0);
        assertEq(token1.balanceOf(address(pairV2)), amount1);

        assertEq(vault.venueLiquidity(V2_VENUE_ID), liquidity);
        assertEq(vault.totalLiquidity(), liquidity);
    }

    /// @notice rebalanceWithStrategy reverts when volatility guard is enabled without an oracle.
    function test_RebalanceWithStrategy_RevertsWhenVolatilityOracleNotSet() public {
        vault.setStrategy(address(strategy));
        vault.setRebalanceConfig(0, 100, 0);

        vm.expectRevert(AdaptiveLPVault.VolatilityOracleNotSet.selector);
        vault.rebalanceWithStrategy("", _emptyWithdrawalParams());
    }

    /// @notice rebalanceWithStrategy reverts when volatility change is below the configured minimum.
    function test_RebalanceWithStrategy_RevertsWhenVolatilityDeltaTooSmall() public {
        vault.setStrategy(address(strategy));
        vault.setRebalanceConfig(0, 100, 0);
        vault.setVolatilityOracle(address(volatilityOracle));

        volatilityOracle.setVolatilityBps(50);

        vm.expectRevert(AdaptiveLPVault.VolatilityDeltaTooSmall.selector);
        vault.rebalanceWithStrategy("", _emptyWithdrawalParams());
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

        vault.rebalanceWithStrategy("", _emptyWithdrawalParams());

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

        vault.rebalanceWithStrategy("", _emptyWithdrawalParams());

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

        vault.rebalanceWithStrategy("", _emptyWithdrawalParams());

        assertEq(vault.venueLiquidity(V2_VENUE_ID), 0);
        assertEq(vault.venueLiquidity(SECOND_V2_VENUE_ID), secondLiquidity);
        assertEq(vault.totalLiquidity(), secondLiquidity);

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);

        assertEq(token0.balanceOf(address(pairV2B)), amount0);
        assertEq(token1.balanceOf(address(pairV2B)), amount1);
    }

    /// @notice rebalanceWithStrategy forwards owner-supplied withdrawal params when exiting a V3 position.
    function test_RebalanceWithStrategy_ForwardsWithdrawalParamsToV3Remove() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;
        uint256 v2Liquidity = 20 ether;
        int24 tickLower = -600;
        int24 tickUpper = 600;

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        MockUniswapV3Pool pool = new MockUniswapV3Pool(address(token0), address(token1), 3000);
        MockNonfungiblePositionManager positionManager = new MockNonfungiblePositionManager();

        UniswapV3Adapter adapterV3 = new UniswapV3Adapter(
            address(vault),
            address(token0),
            address(token1),
            address(positionManager),
            address(pool),
            tickLower,
            tickUpper
        );

        vault.setVenue(V3_LOW_VENUE_ID, address(adapterV3), V3_LOW_LABEL, true);

        uint256 v3Liquidity = _deployVaultToV3(
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

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), v3Liquidity);
        assertEq(vault.venueLiquidity(V2_VENUE_ID), 0);
        
        uint256 amount0Min = 9 ether;
        uint256 amount1Min = 18e6;
        uint256 deadline = block.timestamp + 300;
        AdaptiveLPVault.VenueWithdrawalParams[] memory withdrawalParams = new AdaptiveLPVault.VenueWithdrawalParams[](1);
        withdrawalParams[0] = AdaptiveLPVault.VenueWithdrawalParams({
            venueId: V3_LOW_VENUE_ID,
            params: _v3Params(amount0Min, amount1Min, deadline, tickLower, tickUpper)
        });

        strategy.setSingleTarget(V2_VENUE_ID, amount0, amount1, "");
        vault.setStrategy(address(strategy));

        (uint256 poolAmount0, uint256 poolAmount1) = _mapPoolAmounts(token0, token1, amount0, amount1);
        positionManager.setNextDecreaseResult(poolAmount0, poolAmount1);
        routerV2.setNextAddLiquidityResult(amount0, amount1, v2Liquidity);

        vault.rebalanceWithStrategy("", withdrawalParams);

        (uint256 poolAmount0Min, uint256 poolAmount1Min) = _mapPoolAmounts(token0, token1, amount0Min, amount1Min);
        assertEq(positionManager.lastDecreaseAmount0Min(), poolAmount0Min);
        assertEq(positionManager.lastDecreaseAmount1Min(), poolAmount1Min);
        assertEq(positionManager.lastDecreaseDeadline(), deadline);

        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), 0);
        assertEq(vault.venueLiquidity(V2_VENUE_ID), v2Liquidity);
        assertEq(vault.totalLiquidity(), v2Liquidity);
    }

}
