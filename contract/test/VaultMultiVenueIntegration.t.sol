// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/AdaptiveLPVault.sol";
import "../src/adapters/UniswapV2Adapter.sol";
import "../src/adapters/UniswapV3Adapter.sol";
import "../src/valuators/V2FairValueValuator.sol";
import "../src/valuators/V3TwapPositionValuator.sol";
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
    V2FairValueValuator public valuatorV2;
    V3TwapPositionValuator public valuatorV3;
    
    MockUniswapV2Pair public pairV2;
    MockUniswapV2Router public routerV2;
    UniswapV2Adapter public adapterV2;

    MockUniswapV3Pool public poolV3Low;
    MockNonfungiblePositionManager public positionManagerV3Low;
    UniswapV3Adapter public adapterV3Low;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint8 public decimals0 = 18;
    uint8 public decimals1 = 6;
    uint24 public fee = 500;
    int24 public tickLower = -600;
    int24 public tickUpper = 600;
    uint32 public twapWindow = 1800;

    function setUp() public {
        token0 = new MockERC20("token0", "T0", decimals0);
        token1 = new MockERC20("token1", "T1", decimals1);

        vault = new AdaptiveLPVault(
            "Adaptive LP Vault", "ALPV", 
            address(token0), address(token1), 
            decimals0, decimals1
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
        poolV3Low = new MockUniswapV3Pool(address(token0), address(token1), fee);
        poolV3Low.setSlot0FromTick(0);
        positionManagerV3Low = new MockNonfungiblePositionManager();
        adapterV3Low = new UniswapV3Adapter(
            address(vault), 
            address(token0),
            address(token1),
            address(positionManagerV3Low),
            address(poolV3Low),
            tickLower,
            tickUpper
        );

        vault.setVenue(V2_VENUE_ID, address(adapterV2), V2_LABEL, true);
        vault.setVenue(V3_LOW_VENUE_ID, address(adapterV3Low), V3_LOW_LABEL, true);

        poolV3Low.setTwapTick(0);
        vm.warp(block.timestamp + twapWindow);
        valuatorV2 = new V2FairValueValuator(address(adapterV2));
        valuatorV3 = new V3TwapPositionValuator(address(adapterV3Low), twapWindow);
        vault.setVenueValuator(V2_VENUE_ID, address(valuatorV2));
        vault.setVenueValuator(V3_LOW_VENUE_ID, address(valuatorV3));
    }

    /// @notice Verifies the full Uniswap venue set uses one V2 adapter plus one V3 adapter per fee tier.
    function test_SetVenue_RegistersFullUniswapVenueSet() public {
        // deploy V3 mid venue
        MockUniswapV3Pool poolV3Mid = new MockUniswapV3Pool(address(token0), address(token1), 3000);
        MockNonfungiblePositionManager positionManagerV3Mid = new MockNonfungiblePositionManager();
        UniswapV3Adapter adapterV3Mid = new UniswapV3Adapter(
            address(vault), 
            address(token0),
            address(token1),
            address(positionManagerV3Mid),
            address(poolV3Mid),
            tickLower,
            tickUpper
        );
        // deploy V3 high venue
        MockUniswapV3Pool poolV3High = new MockUniswapV3Pool(address(token0), address(token1), 10000);
        MockNonfungiblePositionManager positionManagerV3High = new MockNonfungiblePositionManager();
        UniswapV3Adapter adapterV3High = new UniswapV3Adapter(
            address(vault), 
            address(token0),
            address(token1),
            address(positionManagerV3High),
            address(poolV3High),
            tickLower,
            tickUpper
        );
        vault.setVenue(V3_MID_VENUE_ID, address(adapterV3Mid), V3_MID_LABEL, true);
        vault.setVenue(V3_HIGH_VENUE_ID, address(adapterV3High), V3_HIGH_LABEL, true);

        assertTrue(vault.venueRegistered(V2_VENUE_ID));
        assertTrue(vault.venueRegistered(V3_LOW_VENUE_ID));
        assertTrue(vault.venueRegistered(V3_MID_VENUE_ID));
        assertTrue(vault.venueRegistered(V3_HIGH_VENUE_ID));

        assertEq(vault.venueIds(0), V2_VENUE_ID);
        assertEq(vault.venueIds(1), V3_LOW_VENUE_ID);
        assertEq(vault.venueIds(2), V3_MID_VENUE_ID);
        assertEq(vault.venueIds(3), V3_HIGH_VENUE_ID);

        (IVenueAdapter v2Adapter, bool v2Enabled, bytes32 v2Label) = vault.venues(V2_VENUE_ID);
        assertEq(address(v2Adapter), address(adapterV2));
        assertTrue(v2Enabled);
        assertEq(v2Label, V2_LABEL);

        (IVenueAdapter v3AdapterLow, bool v3EnabledLow, bytes32 v3LabelLow) = vault.venues(V3_LOW_VENUE_ID);
        assertEq(address(v3AdapterLow), address(adapterV3Low));
        assertTrue(v3EnabledLow);
        assertEq(v3LabelLow, V3_LOW_LABEL);

        (IVenueAdapter v3AdapterMid, bool v3EnabledMid, bytes32 v3LabelMid) = vault.venues(V3_MID_VENUE_ID);
        assertEq(address(v3AdapterMid), address(adapterV3Mid));
        assertTrue(v3EnabledMid);
        assertEq(v3LabelMid, V3_MID_LABEL);

        (IVenueAdapter v3AdapterHigh, bool v3EnabledHigh, bytes32 v3LabelHigh) = vault.venues(V3_HIGH_VENUE_ID);
        assertEq(address(v3AdapterHigh), address(adapterV3High));
        assertTrue(v3EnabledHigh);
        assertEq(v3LabelHigh, V3_HIGH_LABEL);

        assertTrue(address(adapterV3Low) != address(adapterV3Mid));
        assertTrue(address(adapterV3Low) != address(adapterV3High));
        assertTrue(address(adapterV3Mid) != address(adapterV3High));

        assertEq(poolV3Low.fee(), 500);
        assertEq(poolV3Mid.fee(), 3000);
        assertEq(poolV3High.fee(), 10000);

        assertEq(poolV3Low.tickSpacing(), 10);
        assertEq(poolV3Mid.tickSpacing(), 60);
        assertEq(poolV3High.tickSpacing(), 200);
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
        uint256 v3Liquidity = _deployVaultToV3(vault, token0, token1, poolV3Low, positionManagerV3Low, 
                                    V3_LOW_VENUE_ID, tickLower, tickUpper, v3Amount0, v3Amount1);

        assertEq(vault.venueLiquidity(V2_VENUE_ID), v2Liquidity);
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), v3Liquidity);
        assertEq(vault.totalLiquidity(), v2Liquidity + v3Liquidity);

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);
        assertEq(token0.balanceOf(address(pairV2)), v2Amount0);
        assertEq(token1.balanceOf(address(pairV2)), v2Amount1);
        assertEq(token0.balanceOf(address(positionManagerV3Low)), v3Amount0);
        assertEq(token1.balanceOf(address(positionManagerV3Low)), v3Amount1);
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
        uint256 v3Liquidity = _deployVaultToV3(vault, token0, token1, poolV3Low, positionManagerV3Low, 
                                    V3_LOW_VENUE_ID, tickLower, tickUpper, v3Amount0, v3Amount1);

        uint256 v2Amount0Out = v2Amount0;
        uint256 v2Amount1Out = v2Amount1;
        routerV2.setNextRemoveLiquidityResult(v2Amount0Out, v2Amount1Out);
        (uint256 actual0, uint256 actual1) = vault.withdrawFromVenue(V2_VENUE_ID, v2Liquidity, "");

        assertEq(actual0, v2Amount0Out);
        assertEq(actual1, v2Amount1Out);

        assertEq(vault.venueLiquidity(V2_VENUE_ID), 0);
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), v3Liquidity);
        assertEq(vault.totalLiquidity(), v3Liquidity);

        assertEq(token0.balanceOf(address(vault)), v2Amount0);
        assertEq(token1.balanceOf(address(vault)), v2Amount1);

        assertTrue(adapterV3Low.hasPosition());
        assertEq(adapterV3Low.tokenId(), 1);
    }

    function test_TotalAssets_SumsIdleAndAllVenues() public {
        _mintAndDeposit(token0, token1, vault, alice, 10 ether, 20e6);

        uint256 v2Amount0 = 6 ether;
        uint256 v2Amount1 = 12e6;
        uint256 v2Liquidity = 3 ether;

        uint256 v3Amount0 = 4 ether;
        uint256 v3Amount1 = 8e6;

        _deployVaultToV2(vault, routerV2, V2_VENUE_ID, v2Amount0, v2Amount1, v2Amount0, v2Amount1, v2Liquidity);
        _deployVaultToV3(vault, token0, token1, poolV3Low, positionManagerV3Low, 
                                    V3_LOW_VENUE_ID, tickLower, tickUpper, v3Amount0, v3Amount1);
        
        pairV2.setReserves(uint112(v2Amount0), uint112(v2Amount1));
        
        (uint256 price0, uint256 price1) = oracle.getPrices();
        uint256 idleValue = VaultMath.getAssetsTotalValue(
            token0.balanceOf(address(vault)),
            price0,
            decimals0,
            token1.balanceOf(address(vault)),
            price1,
            decimals1
        );
        uint256 expected = idleValue + valuatorV2.getValueInBase(price0, price1) + valuatorV3.getValueInBase(price0, price1);

        assertEq(vault.totalAssets(), expected);
    }

    /// @notice Verifies redeeming all user-owned shares preserves locked-share liquidity across V2 and V3.
    function test_Redeem_AllUserSharesPreservesLockedMultiVenueLiquidity() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        uint256 v2Amount0 = 6 ether;
        uint256 v2Amount1 = 12e6;
        uint256 v2Liquidity = 3 ether;

        uint256 v3Amount0 = 4 ether;
        uint256 v3Amount1 = 8e6;

        _deployVaultToV2(vault, routerV2, V2_VENUE_ID, v2Amount0, v2Amount1, v2Amount0, v2Amount1, v2Liquidity);
        uint256 v3Liquidity = _deployVaultToV3(vault, token0, token1, poolV3Low, positionManagerV3Low, 
                                    V3_LOW_VENUE_ID, tickLower, tickUpper, v3Amount0, v3Amount1);
        assertEq(vault.venueLiquidity(V2_VENUE_ID), v2Liquidity);
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), v3Liquidity);
        assertEq(vault.totalLiquidity(), v2Liquidity + v3Liquidity);

        uint256 aliceShares = vault.balanceOf(alice);
        uint256 totalSharesBefore = vault.totalSupply();
        uint256 v2Amount0Out = v2Amount0 * aliceShares / totalSharesBefore;
        uint256 v2Amount1Out = v2Amount1 * aliceShares / totalSharesBefore;
        uint256 v3Amount0Out = v3Amount0 * aliceShares / totalSharesBefore;
        uint256 v3Amount1Out = v3Amount1 * aliceShares / totalSharesBefore;
        uint256 remainingV2Liquidity = v2Liquidity - v2Liquidity * aliceShares / totalSharesBefore;
        uint256 remainingV3Liquidity = v3Liquidity - v3Liquidity * aliceShares / totalSharesBefore;

        routerV2.setNextRemoveLiquidityResult(v2Amount0Out, v2Amount1Out);
        (uint256 poolAmount0, uint256 poolAmount1) = _mapPoolAmounts(token0, token1, v3Amount0Out, v3Amount1Out);
        positionManagerV3Low.setNextDecreaseResult(poolAmount0, poolAmount1);

        vm.prank(alice);
        (uint256 redeem0, uint256 redeem1) = vault.redeem(aliceShares, alice, alice, _emptyWithdrawalParams(), 0, 0);
        
        assertEq(redeem0, v2Amount0Out + v3Amount0Out);
        assertEq(redeem1, v2Amount1Out + v3Amount1Out);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalSupply(), vault.MINIMUM_LOCKED_SHARES());

        assertEq(vault.venueLiquidity(V2_VENUE_ID), remainingV2Liquidity);
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), remainingV3Liquidity);
        assertEq(vault.totalLiquidity(), remainingV2Liquidity + remainingV3Liquidity);

        assertEq(pairV2.balanceOf(address(adapterV2)), remainingV2Liquidity);
        assertTrue(adapterV3Low.hasPosition());
        assertEq(adapterV3Low.tokenId(), 1);
    }

    /// @notice Verifies partial redeem withdraws only the caller's pro-rata active V2 and V3 liquidity.
    function test_Redeem_PartiallyWithdrawsActiveMultiVenuePositions() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);
        _mintAndDeposit(token0, token1, vault, bob, amount0, amount1);
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 bobShares = vault.balanceOf(bob);
        uint256 totalSharesBefore = vault.totalSupply();
        assertEq(aliceShares + vault.MINIMUM_LOCKED_SHARES(), bobShares);
        assertEq(totalSharesBefore, aliceShares + bobShares + vault.MINIMUM_LOCKED_SHARES());

        uint256 v2Amount0 = 12 ether;
        uint256 v2Amount1 = 24e6;
        uint256 v2Liquidity = 6 ether;

        uint256 v3Amount0 = 8 ether;
        uint256 v3Amount1 = 16e6;

        _deployVaultToV2(vault, routerV2, V2_VENUE_ID, v2Amount0, v2Amount1, v2Amount0, v2Amount1, v2Liquidity);
        uint256 v3Liquidity = _deployVaultToV3(vault, token0, token1, poolV3Low, positionManagerV3Low, 
                                    V3_LOW_VENUE_ID, tickLower, tickUpper, v3Amount0, v3Amount1);
        assertEq(vault.venueLiquidity(V2_VENUE_ID), v2Liquidity);
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), v3Liquidity);
        assertEq(vault.totalLiquidity(), v2Liquidity + v3Liquidity);

        uint256 v2Amount0Out = v2Amount0 * aliceShares / totalSharesBefore;
        uint256 v2Amount1Out = v2Amount1 * aliceShares / totalSharesBefore;
        uint256 v3Amount0Out = v3Amount0 * aliceShares / totalSharesBefore;
        uint256 v3Amount1Out = v3Amount1 * aliceShares / totalSharesBefore;
        uint256 remainingV2Liquidity = v2Liquidity - v2Liquidity * aliceShares / totalSharesBefore;
        uint256 remainingV3Liquidity = v3Liquidity - v3Liquidity * aliceShares / totalSharesBefore;

        routerV2.setNextRemoveLiquidityResult(v2Amount0Out, v2Amount1Out);
        (uint256 poolAmount0, uint256 poolAmount1) = _mapPoolAmounts(token0, token1, v3Amount0Out, v3Amount1Out);
        positionManagerV3Low.setNextDecreaseResult(poolAmount0, poolAmount1);

        vm.prank(alice);
        (uint256 redeem0, uint256 redeem1) = vault.redeem(aliceShares, alice, alice, _emptyWithdrawalParams(), 0, 0);
        
        assertEq(redeem0, v2Amount0Out + v3Amount0Out);
        assertEq(redeem1, v2Amount1Out + v3Amount1Out);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), bobShares);
        assertEq(vault.totalSupply(), bobShares + vault.MINIMUM_LOCKED_SHARES());

        assertEq(vault.venueLiquidity(V2_VENUE_ID), remainingV2Liquidity);
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), remainingV3Liquidity);
        assertEq(vault.totalLiquidity(), remainingV2Liquidity + remainingV3Liquidity);

        assertEq(pairV2.balanceOf(address(adapterV2)), remainingV2Liquidity);
        assertTrue(adapterV3Low.hasPosition());
        assertEq(adapterV3Low.tokenId(), 1);

        (,,,,,,, uint128 positionLiquidity,,,,) = positionManagerV3Low.positions(adapterV3Low.tokenId());
        assertEq(uint256(positionLiquidity),  remainingV3Liquidity);
    }
}
