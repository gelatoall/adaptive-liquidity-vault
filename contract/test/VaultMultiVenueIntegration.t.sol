// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/AdaptiveLPVault.sol";
import "../src/adapters/UniswapV2Adapter.sol";
import "../src/adapters/UniswapV3Adapter.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockPriceOracle.sol";
import "./mocks/MockUniswapV2Pair.sol";
import "./mocks/MockUniswapV2Router.sol";
import "./mocks/MockUniswapV3Pool.sol";
import "./mocks/MockNonfungiblePositionManager.sol";
import "../test/helpers/VaultTestHelper.sol";
import "../test/helpers/VenueTestHelper.sol";

contract VaultMultiVenueIntegrationTest is Test, VaultTestHelper, VenueTestHelper {
    MockERC20 public token0;
    MockERC20 public token1;
    AdaptiveLPVault public vault;
    MockPriceOracle public oracle;
    
    MockUniswapV2Pair public pairV2;
    MockUniswapV2Router public routerV2;
    UniswapV2Adapter public adapterV2;

    MockUniswapV3Pool public poolV3;
    MockNonfungiblePositionManager public positionManagerV3;
    UniswapV3Adapter public adapterV3;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint8 public decimals0 = 18;
    uint8 public decimals1 = 6;
    uint24 public fee = 3000;
    int24 public tickLower = -600;
    int24 public tickUpper = 600;

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

        // deploy V3 venue
        poolV3 = new MockUniswapV3Pool(address(token0), address(token1), fee);
        poolV3.setSlot0FromTick(0);
        positionManagerV3 = new MockNonfungiblePositionManager();
        adapterV3 = new UniswapV3Adapter(
            address(vault), 
            address(token0),
            address(token1),
            address(positionManagerV3),
            address(poolV3),
            tickLower,
            tickUpper
        );

        vault.setVenue(V2_VENUE_ID, address(adapterV2), V2_LABEL, true);
        vault.setVenue(V3_VENUE_ID, address(adapterV3), V3_LABEL, true);
    }

    function test_SetVenue_RegistersMultipleVenuesCorrectly() public {
        assertTrue(vault.venueRegistered(V2_VENUE_ID));
        assertTrue(vault.venueRegistered(V3_VENUE_ID));

        assertEq(vault.venueIds(0), V2_VENUE_ID);
        assertEq(vault.venueIds(1), V3_VENUE_ID);

        (IVenueAdapter v2Adapter, bool v2Enabled, bytes32 v2Label) = vault.venues(V2_VENUE_ID);
        assertEq(address(v2Adapter), address(adapterV2));
        assertTrue(v2Enabled);
        assertEq(v2Label, bytes32("V2"));

        (IVenueAdapter v3Adapter, bool v3Enabled, bytes32 v3Label) = vault.venues(V3_VENUE_ID);
        assertEq(address(v3Adapter), address(adapterV3));
        assertTrue(v3Enabled);
        assertEq(v3Label, bytes32("V3_005"));
    }

    function test_SetVenue_RevertsWhenVenueHasActiveLiquidity() public {
        _mintAndDeposit(token0, token1, vault, alice, 10 ether, 20e6);

        uint256 v2Amount0 = 6 ether;
        uint256 v2Amount1 = 12e6;
        uint256 v2Liquidity = 3 ether;
        _deployVaultToV2(vault, routerV2, V2_VENUE_ID, v2Amount0, v2Amount1, v2Amount0, v2Amount1, v2Liquidity);
        assertTrue(adapterV2.hasPosition());

        MockUniswapV2Pair newPair = new MockUniswapV2Pair(address(token0), address(token1));
        MockUniswapV2Router newRouter = new MockUniswapV2Router(newPair);
        UniswapV2Adapter newAdapter = new UniswapV2Adapter(
            address(vault),
            address(token0),
            address(token1),
            address(newRouter),
            address(newPair)
        );
        vm.expectRevert(AdaptiveLPVault.ActivePositionExists.selector);
        vault.setVenue(V2_VENUE_ID, address(newAdapter), bytes32("V2_NEW"), true);
    }

    function test_DeployToVenue_TracksPerVenueLiquidity() public {
        _mintAndDeposit(token0, token1, vault, alice, 10 ether, 20e6);

        uint256 v2Amount0 = 6 ether;
        uint256 v2Amount1 = 12e6;
        uint256 v2Liquidity = 3 ether;

        uint256 v3Amount0 = 4 ether;
        uint256 v3Amount1 = 8e6;

        _deployVaultToV2(vault, routerV2, V2_VENUE_ID, v2Amount0, v2Amount1, v2Amount0, v2Amount1, v2Liquidity);
        uint256 v3Liquidity = _deployVaultToV3(vault, token0, token1, poolV3, positionManagerV3, 
                                    V3_VENUE_ID, tickLower, tickUpper, v3Amount0, v3Amount1);

        assertEq(vault.venueLiquidity(V2_VENUE_ID), v2Liquidity);
        assertEq(vault.venueLiquidity(V3_VENUE_ID), v3Liquidity);
        assertEq(vault.totalLiquidity(), v2Liquidity + v3Liquidity);

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);
        assertEq(token0.balanceOf(address(pairV2)), v2Amount0);
        assertEq(token1.balanceOf(address(pairV2)), v2Amount1);
        assertEq(token0.balanceOf(address(positionManagerV3)), v3Amount0);
        assertEq(token1.balanceOf(address(positionManagerV3)), v3Amount1);
    }

    function test_DeployToVenue_RevertsWhenVenueDisabled() public {
        vault.setVenue(V2_VENUE_ID, address(adapterV2), V2_LABEL, false);

        _mintAndDeposit(token0, token1, vault, alice, 10 ether, 20e6);

        vm.expectRevert(AdaptiveLPVault.VenueDisabled.selector);
        vault.deployToVenue(V2_VENUE_ID, 1 ether, 2e6, "");
    }

    function test_DeployToVenue_RevertsWhenVenueNotSet() public {
        uint256 unknownVenueId = 999;
        _mintAndDeposit(token0, token1, vault, alice, 10 ether, 20e6);

        vm.expectRevert(AdaptiveLPVault.VenueNotSet.selector);
        vault.deployToVenue(unknownVenueId, 1 ether, 2e6, "");
    }
    
    function test_WithdrawFromVenue_TracksPerVenueLiquidity() public {
        _mintAndDeposit(token0, token1, vault, alice, 10 ether, 20e6);

        uint256 v2Amount0 = 6 ether;
        uint256 v2Amount1 = 12e6;
        uint256 v2Liquidity = 3 ether;

        uint256 v3Amount0 = 4 ether;
        uint256 v3Amount1 = 8e6;

        _deployVaultToV2(vault, routerV2, V2_VENUE_ID, v2Amount0, v2Amount1, v2Amount0, v2Amount1, v2Liquidity);
        uint256 v3Liquidity = _deployVaultToV3(vault, token0, token1, poolV3, positionManagerV3, 
                                    V3_VENUE_ID, tickLower, tickUpper, v3Amount0, v3Amount1);

        uint256 v2Amount0Out = v2Amount0;
        uint256 v2Amount1Out = v2Amount1;
        routerV2.setNextRemoveLiquidityResult(v2Amount0Out, v2Amount1Out);
        (uint256 actual0, uint256 actual1) = vault.withdrawFromVenue(V2_VENUE_ID, v2Liquidity);

        assertEq(actual0, v2Amount0Out);
        assertEq(actual1, v2Amount1Out);

        assertEq(vault.venueLiquidity(V2_VENUE_ID), 0);
        assertEq(vault.venueLiquidity(V3_VENUE_ID), v3Liquidity);
        assertEq(vault.totalLiquidity(), v3Liquidity);

        assertEq(token0.balanceOf(address(vault)), v2Amount0);
        assertEq(token1.balanceOf(address(vault)), v2Amount1);

        assertTrue(adapterV3.hasPosition());
        assertEq(adapterV3.tokenId(), 1);
    }

    function test_TotalAssets_SumsIdleAndAllVenues() public {
        _mintAndDeposit(token0, token1, vault, alice, 10 ether, 20e6);

        uint256 v2Amount0 = 6 ether;
        uint256 v2Amount1 = 12e6;
        uint256 v2Liquidity = 3 ether;

        uint256 v3Amount0 = 4 ether;
        uint256 v3Amount1 = 8e6;

        _deployVaultToV2(vault, routerV2, V2_VENUE_ID, v2Amount0, v2Amount1, v2Amount0, v2Amount1, v2Liquidity);
        uint256 v3Liquidity = _deployVaultToV3(vault, token0, token1, poolV3, positionManagerV3, 
                                    V3_VENUE_ID, tickLower, tickUpper, v3Amount0, v3Amount1);
        
        pairV2.setReserves(uint112(v2Amount0), uint112(v2Amount1));
        
        (uint256 price0, uint256 price1) = oracle.getPrices();
        (uint256 v2Value0, uint256 v2Value1) = adapterV2.getPositionValue();
        (uint256 v3Value0, uint256 v3Value1) = adapterV3.getPositionValue();
        uint256 expected = VaultMath.getAssetsTotalValue(
            token0.balanceOf(address(vault)) + v2Value0 + v3Value0, 
            price0, 
            decimals0, 
            token1.balanceOf(address(vault)) + v2Value1 + v3Value1, 
            price1, 
            decimals1
        );

        assertEq(vault.totalAssets(), expected);
    }

    function test_Redeem_RevertsWhenAnyVenueHasPosition() public {
        _mintAndDeposit(token0, token1, vault, alice, 10 ether, 20e6);

        uint256 v2Amount0 = 6 ether;
        uint256 v2Amount1 = 12e6;
        uint256 v2Liquidity = 3 ether;

        uint256 v3Amount0 = 4 ether;
        uint256 v3Amount1 = 8e6;

        _deployVaultToV2(vault, routerV2, V2_VENUE_ID, v2Amount0, v2Amount1, v2Amount0, v2Amount1, v2Liquidity);
        uint256 v3Liquidity = _deployVaultToV3(vault, token0, token1, poolV3, positionManagerV3, 
                                    V3_VENUE_ID, tickLower, tickUpper, v3Amount0, v3Amount1);

        uint256 aliceShares = vault.balanceOf(alice);
        vm.expectRevert(AdaptiveLPVault.ActivePositionExists.selector);
        vm.prank(alice);
        vault.redeem(aliceShares);
    }
}