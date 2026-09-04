// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";

import "../../src/AdaptiveLPVault.sol";
import "../../src/adapters/UniswapV2Adapter.sol";
import "../../src/adapters/UniswapV3Adapter.sol";
import "../../src/valuators/V2FairValueValuator.sol";
import "../../src/valuators/V3TwapPositionValuator.sol";

import "../mocks/MockERC20.sol";
import "../mocks/MockPriceOracle.sol";
import "../mocks/MockUniswapV2Pair.sol";
import "../mocks/MockUniswapV2Router.sol";
import "../mocks/MockUniswapV3Pool.sol";
import "../mocks/MockNonfungiblePositionManager.sol";
import "../helpers/VaultTestHelper.sol";
import "../helpers/VenueTestHelper.sol";

import "./AdaptiveLPVaultHandler.sol";

contract AdaptiveLPVaultInvariantTest is StdInvariant, Test, VaultTestHelper, VenueTestHelper{
    uint8 internal constant DECIMALS0 = 18;
    uint8 internal constant DECIMALS1 = 6;

    uint32 internal constant TWAP_WINDOW = 1800;
    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;
    
    AdaptiveLPVault internal vault;
    MockERC20 internal token0;
    MockERC20 internal token1;
    MockPriceOracle internal oracle;

    MockUniswapV2Pair internal pairV2;
    MockUniswapV2Router internal routerV2;
    UniswapV2Adapter internal adapterV2;
    V2FairValueValuator internal valuatorV2;

    MockUniswapV3Pool internal poolV3Low;
    MockNonfungiblePositionManager internal positionManagerV3Low;
    UniswapV3Adapter internal adapterV3Low;
    V3TwapPositionValuator internal valuatorV3Low;

    MockUniswapV3Pool internal poolV3Mid;
    MockNonfungiblePositionManager internal positionManagerV3Mid;
    UniswapV3Adapter internal adapterV3Mid;
    V3TwapPositionValuator internal valuatorV3Mid;

    MockUniswapV3Pool internal poolV3High;
    MockNonfungiblePositionManager internal positionManagerV3High;
    UniswapV3Adapter internal adapterV3High;
    V3TwapPositionValuator internal valuatorV3High;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    AdaptiveLPVaultHandler internal handler;

    function setUp() public {
        token0 = new MockERC20("Token0", "TK0", DECIMALS0);
        token1 = new MockERC20("Token1", "TK1", DECIMALS1);

        vault = new AdaptiveLPVault(
            "Adaptive LP Vault", "ALPV", 
            address(token0), address(token1), 
            DECIMALS0, DECIMALS1
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
        poolV3Low = new MockUniswapV3Pool(address(token0), address(token1), 500);
        poolV3Low.setSlot0FromTick(0);
        poolV3Low.setTwapTick(0);
        positionManagerV3Low = new MockNonfungiblePositionManager();
        adapterV3Low = new UniswapV3Adapter(
            address(vault), 
            address(token0),
            address(token1),
            address(positionManagerV3Low),
            address(poolV3Low),
            TICK_LOWER,
            TICK_UPPER
        );

        // deploy V3 mid venue
        poolV3Mid = new MockUniswapV3Pool(address(token0), address(token1), 3000);
        poolV3Mid.setSlot0FromTick(0);
        poolV3Mid.setTwapTick(0);
        positionManagerV3Mid = new MockNonfungiblePositionManager();
        adapterV3Mid = new UniswapV3Adapter(
            address(vault), 
            address(token0),
            address(token1),
            address(positionManagerV3Mid),
            address(poolV3Mid),
            TICK_LOWER,
            TICK_UPPER
        );

        // deploy V3 high venue
        poolV3High = new MockUniswapV3Pool(address(token0), address(token1), 10000);
        poolV3High.setSlot0FromTick(0);
        poolV3High.setTwapTick(0);
        positionManagerV3High = new MockNonfungiblePositionManager();
        adapterV3High = new UniswapV3Adapter(
            address(vault), 
            address(token0),
            address(token1),
            address(positionManagerV3High),
            address(poolV3High),
            TICK_LOWER,
            TICK_UPPER
        );

        vm.warp(block.timestamp + TWAP_WINDOW);

        vault.setVenue(V2_VENUE_ID, address(adapterV2), V2_LABEL, true);
        valuatorV2 = new V2FairValueValuator(address(adapterV2));
        vault.setVenueValuator(V2_VENUE_ID, address(valuatorV2));

        vault.setVenue(V3_LOW_VENUE_ID, address(adapterV3Low), V3_LOW_LABEL, true);
        valuatorV3Low = new V3TwapPositionValuator(address(adapterV3Low), TWAP_WINDOW);
        vault.setVenueValuator(V3_LOW_VENUE_ID, address(valuatorV3Low));

        vault.setVenue(V3_MID_VENUE_ID, address(adapterV3Mid), V3_MID_LABEL, true);
        valuatorV3Mid = new V3TwapPositionValuator(address(adapterV3Mid), TWAP_WINDOW);
        vault.setVenueValuator(V3_MID_VENUE_ID, address(valuatorV3Mid));

        vault.setVenue(V3_HIGH_VENUE_ID, address(adapterV3High), V3_HIGH_LABEL, true);
        valuatorV3High = new V3TwapPositionValuator(address(adapterV3High), TWAP_WINDOW);
        vault.setVenueValuator(V3_HIGH_VENUE_ID, address(valuatorV3High));

        AdaptiveLPVaultHandler.V3Venue memory v3Low = AdaptiveLPVaultHandler.V3Venue({
            venueId: V3_LOW_VENUE_ID,
            pool: poolV3Low,
            positionManager: positionManagerV3Low,
            adapter: adapterV3Low
        });

        AdaptiveLPVaultHandler.V3Venue memory v3Mid =
            AdaptiveLPVaultHandler.V3Venue({
                venueId: V3_MID_VENUE_ID,
                pool: poolV3Mid,
                positionManager: positionManagerV3Mid,
                adapter: adapterV3Mid
            });

        AdaptiveLPVaultHandler.V3Venue memory v3High =
            AdaptiveLPVaultHandler.V3Venue({
                venueId: V3_HIGH_VENUE_ID,
                pool: poolV3High,
                positionManager: positionManagerV3High,
                adapter: adapterV3High
            });
        
        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;

        handler = new AdaptiveLPVaultHandler(
            vault, token0, token1,
            pairV2, routerV2, adapterV2,
            v3Low, v3Mid, v3High,
            address(this), actors,
            TICK_LOWER, TICK_UPPER
        );
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.redeem.selector;
        selectors[2] = handler.rebalanceToFourVenueSplit.selector;
        selectors[3] = handler.rebalanceToIdle.selector;
        targetSelector(
            FuzzSelector({
                addr: address(handler),
                selectors: selectors
            })
        );
    }

    function test_SetUp_RegistersAllFourVenues() public view {
        assertTrue(vault.venueRegistered(V2_VENUE_ID));
        assertTrue(vault.venueRegistered(V3_LOW_VENUE_ID));
        assertTrue(vault.venueRegistered(V3_MID_VENUE_ID));
        assertTrue(vault.venueRegistered(V3_HIGH_VENUE_ID));

        assertEq(vault.venueCount(), 4);
    }

    function invariant_TrackedSharesEqualTotalSupply() public view {
        uint256 trackedShares = vault.balanceOf(alice) + vault.balanceOf(bob)
                + vault.balanceOf(carol) + vault.balanceOf(vault.LOCKED_SHARES_RECEIVER());

        assertEq(trackedShares, vault.totalSupply());
    }

    /// @notice A successful rebalance must not mint or burn vault shares.
    function invariant_RebalanceDoesNotChangeTotalSupply() public view {
        if (handler.successfulRebalanceCount() == 0) return;

        assertEq(handler.lastRebalanceSupplyAfter(), handler.lastRebalanceSupplyBefore());
    }

    /// @notice A zero-supply vault must not retain either underlying token.
    function invariant_ZeroSupplyHasNoIdleUnderlying() public view {
        if (vault.totalSupply() != 0) return;

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);
    }
}