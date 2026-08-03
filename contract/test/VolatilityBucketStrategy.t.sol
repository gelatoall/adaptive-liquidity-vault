// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/adapters/UniswapV3Adapter.sol";
import "../src/strategies/VolatilityBucketStrategy.sol";
import "../src/strategies/V3TickCalculations.sol";
import "../src/oracles/V3TwapVolatilityOracle.sol";
import "../src/interfaces/ISlippageController.sol";
import "../src/slippage/TwapSlippageController.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockPriceOracle.sol";
import "./mocks/MockVolatilityOracle.sol";
import "./mocks/MockUniswapV3Pool.sol";
import "./mocks/MockNonfungiblePositionManager.sol";
import "./helpers/VaultTestHelper.sol";
import "./helpers/VenueTestHelper.sol";

/// @notice Covers volatility bucket selection and strategy-built rebalance targets.
contract VolatilityBucketStrategyTest is Test, VaultTestHelper, VenueTestHelper {
    MockERC20 public token0;
    MockERC20 public token1;
    AdaptiveLPVault public vault;
    MockPriceOracle public priceOracle;
    MockVolatilityOracle public volatilityOracle;
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

        priceOracle = new MockPriceOracle();
        _configureMirroredPriceOracles(vault, priceOracle);
        priceOracle.setPrices(1e18, 1e18);

        volatilityOracle = new MockVolatilityOracle();

        strategy = new VolatilityBucketStrategy(address(volatilityOracle), lowThresholdBps, highThresholdBps);
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
                2000  // V3 1.00%: 20%
            )
        );
    }

    /// @notice Low volatility selects the configured low-bucket allocation.
    function test_BuildTargets_UsesLowBucket() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1); // user -> vault

        _setLowBucketTargets(); // prepare low strategy

        volatilityOracle.setVolatilityBps(50);
        RebalanceTypes.RebalanceTarget[] memory targets = strategy.buildTargets(address(vault), "");

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

    /// @notice Configured V3 venues receive dynamic tick params instead of their static target params.
    function test_BuildTargets_BuildsDynamicV3TickParams() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;
        uint24 fee = 3000; // fee tier: 3000 = 0.30%, tickSpacing = 60

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        _setLowBucketTargets();

        MockUniswapV3Pool pool = new MockUniswapV3Pool(address(token0), address(token1), fee);
        pool.setSlot0FromTick(199);
        pool.setTwapTick(199);
        vm.warp(1800);

        MockNonfungiblePositionManager positionManager = new MockNonfungiblePositionManager();
        UniswapV3Adapter adapterV3 = new UniswapV3Adapter(
            address(vault),
            address(token0),
            address(token1),
            address(positionManager),
            address(pool),
            -600,
            600
        );
        vault.setVenue(V3_LOW_VENUE_ID, address(adapterV3), V3_LOW_LABEL, true);

        V3TickCalculations calculations = new V3TickCalculations(address(pool));
        strategy.setV3TickCalculations(V3_LOW_VENUE_ID, address(calculations));

        volatilityOracle.setVolatilityBps(49); // low volatility => tickRange = 200

        TwapSlippageController slippageController = new TwapSlippageController();
        slippageController.setVenueAdapter(V3_LOW_VENUE_ID, address(adapterV3));

        strategy.setSlippageController(address(slippageController));
        strategy.setVenueSlippageParams(
            V3_LOW_VENUE_ID, 
            ISlippageController.SlippageParams({
                maxSlippageBps: 50,
                twapWindow: 1800
            })
        );

        RebalanceTypes.RebalanceTarget[] memory targets = strategy.buildTargets(address(vault), "");

        // _buildFourTargetConfigs orders V3_LOW at index 1; assert it before decoding V3 params.
        assertEq(targets[1].venueId, V3_LOW_VENUE_ID);
        UniswapV3Adapter.LiquidityParams memory params = abi.decode(targets[1].params, (UniswapV3Adapter.LiquidityParams));

        // V3_LOW receives 60% of the LOW bucket allocation, then applies a 50 bps haircut.
        assertEq(params.amount0Min, 6 ether * 9_950 / 10_000);
        assertEq(params.amount1Min, 12e6 * 9_950 / 10_000);
        assertEq(params.deadline, block.timestamp);
        // currentTick = 199 and low-volatility tickRange = 200 gives raw bounds [-1, 399].
        // With spacing 60, outward rounding produces [-60, 420].
        assertEq(params.tickLower, -60);
        assertEq(params.tickUpper, 420);
    }

    /// @notice Target construction rejects a controller bound to a different adapter than the vault venue.
    function test_BuildTargets_RevertsWhenControllerAdapterDoesNotMatchVaultVenue() public {
        uint24 fee = 3000;

        _mintAndDeposit(token0, token1, vault, alice, 10 ether, 20e6);

        _setLowBucketTargets();
        volatilityOracle.setVolatilityBps(49);

        // poolA belongs to the adapter actually registered by the vault.
        MockUniswapV3Pool poolA = new MockUniswapV3Pool(address(token0), address(token1), fee);
        // poolB represents an unrelated V3 venue.
        MockUniswapV3Pool poolB = new MockUniswapV3Pool(address(token0), address(token1), fee);
        MockNonfungiblePositionManager positionManager = new MockNonfungiblePositionManager();
        UniswapV3Adapter adapterA = new UniswapV3Adapter(
            address(vault),
            address(token0),
            address(token1),
            address(positionManager),
            address(poolA),
            -600,
            600
        );
        UniswapV3Adapter adapterB = new UniswapV3Adapter(
            address(vault),
            address(token0),
            address(token1),
            address(positionManager),
            address(poolB),
            -600,
            600
        );

        // The vault records adapterA as the actual V3_LOW venue.
        vault.setVenue(V3_LOW_VENUE_ID, address(adapterA), V3_LOW_LABEL, true);

        V3TickCalculations calculations = new V3TickCalculations(address(poolA));
        strategy.setV3TickCalculations(V3_LOW_VENUE_ID, address(calculations));

        TwapSlippageController controller = new TwapSlippageController();
        // Deliberate configuration error: controller points to adapterB.
        controller.setVenueAdapter(V3_LOW_VENUE_ID, address(adapterB));
        strategy.setSlippageController(address(controller));

        strategy.setVenueSlippageParams(
            V3_LOW_VENUE_ID,
            ISlippageController.SlippageParams({
                maxSlippageBps: 50,
                twapWindow: 1800
            })
        );

        vm.expectRevert(VolatilityBucketStrategy.SlippageControllerAdapterMismatch.selector);

        strategy.buildTargets(address(vault), "");
    }

    /// @notice Medium volatility selects the configured medium-bucket allocation.
    function test_BuildTargets_UsesMediumBucket() public {
        _mintAndDeposit(token0, token1, vault, alice, 10 ether, 20e6);

        _setMediumBucketTargets();

        volatilityOracle.setVolatilityBps(200);
        RebalanceTypes.RebalanceTarget[] memory targets = strategy.buildTargets(address(vault), "");

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
    function test_BuildTargets_LeavesUnallocatedHighBucketWeightIdle() public {
        _mintAndDeposit(token0, token1, vault, alice, 10 ether, 20e6);

        _setHighBucketTargets();

        volatilityOracle.setVolatilityBps(400);
        RebalanceTypes.RebalanceTarget[] memory targets = strategy.buildTargets(address(vault), "");

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
        assertEq(targets[3].amount0, 2 ether);
        assertEq(targets[3].amount1, 4e6);
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

        volatilityOracle.setVolatilityBps(60);
        RebalanceTypes.RebalanceTarget[] memory targets = strategy.buildTargets(address(vault), "");

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

    /// @notice A V3 TWAP volatility oracle can drive low-bucket target selection.
    function test_BuildTargets_UsesV3TwapVolatilityOracle() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;

        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        uint32 twapWindow = 1800;
        vm.warp(twapWindow);
        
        MockUniswapV3Pool pool = new MockUniswapV3Pool(address(token0), address(token1), 3000);
        pool.setTwapTick(0);
        pool.setSlot0FromTick(0);
        
        V3TwapVolatilityOracle v3Oracle = new V3TwapVolatilityOracle(address(pool), twapWindow);
        
        VolatilityBucketStrategy v3OracleStrategy = new VolatilityBucketStrategy(address(v3Oracle), lowThresholdBps, highThresholdBps);
        v3OracleStrategy.setBucketTargets(
            VolatilityBucketStrategy.Bucket.LOW, 
            _buildFourTargetConfigs(
                1000, // V2: 10%
                6000, // V3 0.05%: 60%
                2500, // V3 0.30%: 25%
                500   // V3 1.00%: 5%
            )
        );
        assertEq(v3Oracle.getVolatilityBps(), 0);
        
        RebalanceTypes.RebalanceTarget[] memory targets = v3OracleStrategy.buildTargets(address(vault), "");

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

    /// @notice Recommended targets come from the currently selected volatility bucket.
    function test_GetRecommendedTargets_ReturnsCurrentBucketWeights() public {
        _setLowBucketTargets();

        volatilityOracle.setVolatilityBps(50);
        RebalanceTypes.TargetConfig[] memory targets = strategy.getRecommendedTargets();
        assertEq(targets.length, 4);

        assertEq(targets[0].venueId, V2_VENUE_ID);
        assertEq(targets[0].weightBps, 1000);

        assertEq(targets[1].venueId, V3_LOW_VENUE_ID);
        assertEq(targets[1].weightBps, 6000);

        assertEq(targets[2].venueId, V3_MID_VENUE_ID);
        assertEq(targets[2].weightBps, 2500);

        assertEq(targets[3].venueId, V3_HIGH_VENUE_ID);
        assertEq(targets[3].weightBps, 500);
    }
}
