// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/strategies/FixedWeightStrategy.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockPriceOracle.sol";
import "./helpers/VaultTestHelper.sol";
import "./helpers/VenueTestHelper.sol";

/// @notice Covers fixed-weight target construction and config validation.
contract FixedWeightStrategyTest is Test, VaultTestHelper, VenueTestHelper {
    MockERC20 public token0;
    MockERC20 public token1;
    AdaptiveLPVault public vault;
    MockPriceOracle public oracle;
    FixedWeightStrategy public strategy;

    address public alice = makeAddr("alice");

    uint8 public decimals0 = 18;
    uint8 public decimals1 = 6;

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

        strategy = new FixedWeightStrategy();
    }

    function _buildFourTargetConfigs(
        uint256 weightBps0,
        uint256 weightBps1,
        uint256 weightBps2,
        uint256 weightBps3
    ) internal pure returns (FixedWeightStrategy.TargetConfig[] memory configs) {
        configs = new FixedWeightStrategy.TargetConfig[](4);

        configs[0] = FixedWeightStrategy.TargetConfig({
            venueId: V2_VENUE_ID,
            weightBps: weightBps0,
            params: ""
        });

        configs[1] = FixedWeightStrategy.TargetConfig({
            venueId: V3_LOW_VENUE_ID,
            weightBps: weightBps1,
            params: ""
        });

        configs[2] = FixedWeightStrategy.TargetConfig({
            venueId: V3_MID_VENUE_ID,
            weightBps: weightBps2,
            params: ""
        });

        configs[3] = FixedWeightStrategy.TargetConfig({
            venueId: V3_HIGH_VENUE_ID,
            weightBps: weightBps3,
            params: ""
        });
    }

    /// @notice buildTargets returns four targets using configured bps weights.
    function test_BuildTargets_ReturnsFourWeightedTargets() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        FixedWeightStrategy.TargetConfig[] memory configs = _buildFourTargetConfigs(2500, 2500, 3000, 2000);
        strategy.setTargets(configs);

        RebalanceTypes.RebalanceTarget[] memory targets = strategy.buildTargets(address(vault), "");

        assertEq(targets.length, 4);
        
        assertEq(targets[0].venueId, V2_VENUE_ID);
        assertEq(targets[0].amount0, 2.5 ether);
        assertEq(targets[0].amount1, 5e6);

        assertEq(targets[1].venueId, V3_LOW_VENUE_ID);
        assertEq(targets[1].amount0, 2.5 ether);
        assertEq(targets[1].amount1, 5e6);

        assertEq(targets[2].venueId, V3_MID_VENUE_ID);
        assertEq(targets[2].amount0, 3 ether);
        assertEq(targets[2].amount1, 6e6);

        assertEq(targets[3].venueId, V3_HIGH_VENUE_ID);
        assertEq(targets[3].amount0, 2 ether);
        assertEq(targets[3].amount1, 4e6);
    }

    /// @notice buildTargets assigns integer division dust to the final target.
    function test_BuildTargets_AssignsDustToLastTarget() public {
        uint256 amount0 = 100;
        uint256 amount1 = 100;

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        FixedWeightStrategy.TargetConfig[] memory configs = _buildFourTargetConfigs(3333, 3333, 3333, 1);
        strategy.setTargets(configs);

        RebalanceTypes.RebalanceTarget[] memory targets = strategy.buildTargets(address(vault), "");
        
        assertEq(targets[0].amount0, 33);
        assertEq(targets[1].amount0, 33);
        assertEq(targets[2].amount0, 33);
        assertEq(targets[3].amount0, 1);
        
        assertEq(targets[0].amount1, 33);
        assertEq(targets[1].amount1, 33);
        assertEq(targets[2].amount1, 33);
        assertEq(targets[3].amount1, 1);
    }

    /// @notice setTargets rejects an empty config list.
    function test_SetTargets_RevertsWhenEmpty() public {
        FixedWeightStrategy.TargetConfig[] memory configs = new FixedWeightStrategy.TargetConfig[](0);
        vm.expectRevert(FixedWeightStrategy.EmptyTargets.selector);
        strategy.setTargets(configs);
    }

    /// @notice setTargets rejects zero-weight venues.
    function test_SetTargets_RevertsWhenWeightIsZero() public {
        FixedWeightStrategy.TargetConfig[] memory configs = _buildFourTargetConfigs(2500, 2500, 3000, 0);
        vm.expectRevert(FixedWeightStrategy.ZeroWeight.selector);
        strategy.setTargets(configs);
    }

    /// @notice setTargets rejects duplicate venue ids.
    function test_SetTargets_RevertsWhenDuplicateVenue() public {
        FixedWeightStrategy.TargetConfig[] memory configs = new FixedWeightStrategy.TargetConfig[](2);
        configs[0] = FixedWeightStrategy.TargetConfig({
            venueId: V2_VENUE_ID,
            weightBps: 5000,
            params: ""
        });
        configs[1] = FixedWeightStrategy.TargetConfig({
            venueId: V2_VENUE_ID,
            weightBps: 5000,
            params: ""
        });
        vm.expectRevert(FixedWeightStrategy.DuplicateVenue.selector);
        strategy.setTargets(configs);
    }

    /// @notice setTargets requires weights to sum to 10_000 bps.
    function test_SetTargets_RevertsWhenTotalWeightIsNotBps() public {
        FixedWeightStrategy.TargetConfig[] memory configs = _buildFourTargetConfigs(2500, 2500, 3000, 1000);
        vm.expectRevert(FixedWeightStrategy.InvalidTotalWeight.selector);
        strategy.setTargets(configs);
    }

    /// @notice buildTargets rejects a zero vault address.
    function test_BuildTargets_RevertsWhenVaultIsZeroAddress() public {
        vm.expectRevert(FixedWeightStrategy.ZeroAddress.selector);
        strategy.buildTargets(address(0), "");
    }

    /// @notice buildTargets requires configured targets.
    function test_BuildTargets_RevertsWhenTargetsNotConfigured() public {
        vm.expectRevert(FixedWeightStrategy.EmptyTargets.selector);
        strategy.buildTargets(address(vault), "");
    }
}
