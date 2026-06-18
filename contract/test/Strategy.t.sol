// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/AdaptiveLPVault.sol";
import "../src/adapters/UniswapV2Adapter.sol";
import "../src/strategies/FixedWeightStrategy.sol";
import "../src/strategies/VolatilityBucketStrategy.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockPriceOracle.sol";
import "./mocks/MockRebalanceStrategy.sol";
import "./mocks/MockUniswapV2Pair.sol";
import "./mocks/MockUniswapV2Router.sol";
import "../test/helpers/VaultTestHelper.sol";
import "../test/helpers/VenueTestHelper.sol";

/// @notice Covers the minimal strategy-driven rebalance entrypoint.
contract StrategyTest is Test, VaultTestHelper, VenueTestHelper {
    MockERC20 public token0;
    MockERC20 public token1;
    AdaptiveLPVault public vault;
    MockPriceOracle public oracle;
    MockRebalanceStrategy public strategy;
    FixedWeightStrategy public fixedStrategy;
    VolatilityBucketStrategy public volatilityStrategy;
    
    MockUniswapV2Pair public pairV2;
    MockUniswapV2Router public routerV2;
    UniswapV2Adapter public adapterV2;

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

        oracle = new MockPriceOracle();
        vault.setOracle(address(oracle));
        oracle.setPrices(1e18, 1e18);

        strategy = new MockRebalanceStrategy();
        fixedStrategy = new FixedWeightStrategy();
        volatilityStrategy = new VolatilityBucketStrategy(lowThresholdBps, highThresholdBps);

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
    }

    /// @notice setStrategy stores the configured strategy address.
    function test_SetStrategy_SetsStrategy() public {
        vault.setStrategy(address(strategy));
        assertEq(address(vault.strategy()), address(strategy));
    }

    /// @notice setRebalanceConfig stores cooldown and gas price guards.
    function test_SetRebalanceConfig_SetsConfig() public {
        uint256 _minCooldown = 1 hours;
        uint256 _maxGasPrice = 50 gwei;
        vault.setRebalanceConfig(_minCooldown, _maxGasPrice);
        (uint256 minCooldown, uint256 maxGasPrice) = vault.rebalanceConfig();
        assertEq(minCooldown, _minCooldown);
        assertEq(maxGasPrice, _maxGasPrice);
    }

    /// @notice rebalanceWithStrategy reverts before a strategy is configured.
    function test_RebalanceWithStrategy_RevertsWhenStrategyNotSet() public {
        vm.expectRevert(AdaptiveLPVault.StrategyNotSet.selector);
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
        vault.setRebalanceConfig(1 hours, 0);

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
        vault.setRebalanceConfig(0, 50 gwei);
        
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

        vault.rebalanceWithStrategy(abi.encode(uint256(50)));

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);
        assertEq(token0.balanceOf(address(pairV2)), amount0);
        assertEq(token1.balanceOf(address(pairV2)), amount1);
        assertEq(vault.venueLiquidity(V2_VENUE_ID), liquidity);
    }
}
