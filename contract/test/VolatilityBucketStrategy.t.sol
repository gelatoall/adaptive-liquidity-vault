// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/strategies/VolatilityBucketStrategy.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockPriceOracle.sol";
import "./helpers/VaultTestHelper.sol";
import "./helpers/VenueTestHelper.sol";

/// @notice Covers volatility bucket selection and idle-only target construction.
contract VolatilityBucketStrategyTest is Test, VaultTestHelper, VenueTestHelper {
    MockERC20 public token0;
    MockERC20 public token1;
    AdaptiveLPVault public vault;
    MockPriceOracle public oracle;
    VolatilityBucketStrategy public strategy;

    address public alice = makeAddr("alice");

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

        strategy = new VolatilityBucketStrategy(lowThresholdBps, highThresholdBps);
    }

    function _setLowBucketTargets() internal {
        strategy.setBucketTargets(
            VolatilityBucketStrategy.Bucket.LOW, 
            _buildFourTargetConfigs(
                1000, // V2: 10%
                6000, // V3 0.05%: 60%
                2500, // V3 0.30%: 25%
                500   // V3 1.00%: 5%
            )
        );
    }

    function _setMediumBucketTargets() internal {
        strategy.setBucketTargets(
            VolatilityBucketStrategy.Bucket.MEDIUM, 
            _buildFourTargetConfigs(
                2000, // V2: 20%
                2500, // V3 0.05%: 25%
                4500, // V3 0.30%: 45%
                1000  // V3 1.00%: 10%
            )
        );
    }

    function _setHighBucketTargets() internal {
        strategy.setBucketTargets(
            VolatilityBucketStrategy.Bucket.HIGH, 
            _buildFourTargetConfigs(
                5000, // V2: 50%
                500,  // V3 0.05%: 5%
                1500, // V3 0.30%: 15%
                3000  // V3 1.00%: 30%
            )
        );
    }

    /// @notice Low volatility selects the configured low-bucket allocation.
    function test_BuildTargets_UsesLowBucket() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1); // user -> vault

        _setLowBucketTargets(); // prepare low strategy

        RebalanceTypes.RebalanceTarget[] memory targets = strategy.buildTargets(address(vault), abi.encode(uint256(50)));

        assertEq(targets.length, 4);

        assertEq(targets[0].venueId, V2_VENUE_ID);
        assertEq(targets[0].amount0, 1 ether);
        assertEq(targets[0].amount1, 2e6);

        assertEq(targets[1].venueId, V3_LOW_VENUE_ID);
        assertEq(targets[1].amount0, 6 ether);
        assertEq(targets[1].amount1, 12e6);

        assertEq(targets[2].venueId, V3_MID_VENUE_ID);
        assertEq(targets[2].amount0, 2.5 ether);
        assertEq(targets[2].amount1, 5e6);

        assertEq(targets[3].venueId, V3_HIGH_VENUE_ID);
        assertEq(targets[3].amount0, 0.5 ether);
        assertEq(targets[3].amount1, 1e6);
    }

    /// @notice Medium volatility selects the configured medium-bucket allocation.
    function test_BuildTargets_UsesMediumBucket() public {
        _mintAndDeposit(token0, token1, vault, alice, 10 ether, 20e6);

        _setMediumBucketTargets();

        RebalanceTypes.RebalanceTarget[] memory targets =
            strategy.buildTargets(
                address(vault),
                abi.encode(uint256(200))
            );

        assertEq(targets.length, 4);

        assertEq(targets[0].venueId, V2_VENUE_ID);
        assertEq(targets[0].amount0, 2 ether);
        assertEq(targets[0].amount1, 4e6);

        assertEq(targets[1].venueId, V3_LOW_VENUE_ID);
        assertEq(targets[1].amount0, 2.5 ether);
        assertEq(targets[1].amount1, 5e6);

        assertEq(targets[2].venueId, V3_MID_VENUE_ID);
        assertEq(targets[2].amount0, 4.5 ether);
        assertEq(targets[2].amount1, 9e6);

        assertEq(targets[3].venueId, V3_HIGH_VENUE_ID);
        assertEq(targets[3].amount0, 1 ether);
        assertEq(targets[3].amount1, 2e6);
    }

    /// @notice High volatility selects the configured high-bucket allocation.
    function test_BuildTargets_UsesHighBucket() public {
        _mintAndDeposit(token0, token1, vault, alice, 10 ether, 20e6);

        _setHighBucketTargets();

        RebalanceTypes.RebalanceTarget[] memory targets =
            strategy.buildTargets(
                address(vault),
                abi.encode(uint256(400))
            );

        assertEq(targets.length, 4);

        assertEq(targets[0].venueId, V2_VENUE_ID);
        assertEq(targets[0].amount0, 5 ether);
        assertEq(targets[0].amount1, 10e6);

        assertEq(targets[1].venueId, V3_LOW_VENUE_ID);
        assertEq(targets[1].amount0, 0.5 ether);
        assertEq(targets[1].amount1, 1e6);

        assertEq(targets[2].venueId, V3_MID_VENUE_ID);
        assertEq(targets[2].amount0, 1.5 ether);
        assertEq(targets[2].amount1, 3e6);

        assertEq(targets[3].venueId, V3_HIGH_VENUE_ID);
        assertEq(targets[3].amount0, 3 ether);
        assertEq(targets[3].amount1, 6e6);
    }

    /// @notice Integer division dust is assigned to the final target.
    function test_BuildTargets_AssignsDustToLastTarget() public {
        uint256 amount0 = 100;
        uint256 amount1 = 100;

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1); // user -> vault

        strategy.setBucketTargets(
            VolatilityBucketStrategy.Bucket.LOW, 
            _buildFourTargetConfigs(3333, 3333, 3333, 1)
        );

        RebalanceTypes.RebalanceTarget[] memory targets = strategy.buildTargets(address(vault), abi.encode(uint256(60)));

        assertEq(targets[0].venueId, V2_VENUE_ID);
        assertEq(targets[0].amount0, 33);
        assertEq(targets[0].amount1, 33);

        assertEq(targets[1].venueId, V3_LOW_VENUE_ID);
        assertEq(targets[1].amount0, 33);
        assertEq(targets[1].amount1, 33);

        assertEq(targets[2].venueId, V3_MID_VENUE_ID);
        assertEq(targets[2].amount0, 33);
        assertEq(targets[2].amount1, 33);

        assertEq(targets[3].venueId, V3_HIGH_VENUE_ID);
        assertEq(targets[3].amount0, 1);
        assertEq(targets[3].amount1, 1);
    }
}
