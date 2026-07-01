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
import "../test/helpers/RebalanceTestHelper.sol";
import "../src/libraries/RebalanceTypes.sol";

contract RebalanceMultiVenue is Test, VaultTestHelper, VenueTestHelper, RebalanceTestHelper {
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
        vault.setPriceOracle(address(oracle));
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
        vault.setVenue(V3_LOW_VENUE_ID, address(adapterV3), V3_LOW_LABEL, true);
    }

    function test_Rebalance_DeploysToMultipleVenues() public {
        _mintAndDeposit(token0, token1, vault, alice, 10 ether, 20e6);

        uint256 v2Amount0 = 6 ether;
        uint256 v2Amount1 = 12e6;
        uint256 v2Liquidity = 3 ether;

        uint256 v3Amount0 = 4 ether;
        uint256 v3Amount1 = 8e6;

        routerV2.setNextAddLiquidityResult(v2Amount0, v2Amount1, v2Liquidity);

        uint128 v3Liquidity = _primeV3Mint(token0, token1, poolV3, positionManagerV3, 
                                tickLower, tickUpper, v3Amount0, v3Amount1);

        RebalanceTypes.RebalanceTarget[] memory targets = _buildTwoTargets(
            V2_VENUE_ID, v2Amount0, v2Amount1, "", 
            V3_LOW_VENUE_ID, v3Amount0, v3Amount1, _defaultV3Params()
        );

        vault.rebalance(targets, _emptyWithdrawalParams());

        assertEq(token0.balanceOf(address(vault)), 0);
        assertEq(token1.balanceOf(address(vault)), 0);

        assertEq(token0.balanceOf(address(pairV2)), v2Amount0);
        assertEq(token1.balanceOf(address(pairV2)), v2Amount1);
        assertEq(pairV2.balanceOf(address(adapterV2)), v2Liquidity);

        assertEq(token0.balanceOf(address(positionManagerV3)), v3Amount0);
        assertEq(token1.balanceOf(address(positionManagerV3)), v3Amount1);
        assertTrue(adapterV3.hasPosition());
        assertEq(adapterV3.tokenId(), 1);

        assertEq(vault.venueLiquidity(V2_VENUE_ID), v2Liquidity);
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), uint256(v3Liquidity));
        assertEq(vault.totalLiquidity(), v2Liquidity + uint256(v3Liquidity));
    }

    
    function test_Rebalance_WithdrawsMultipleVenuesToIdle() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 20e6;
        _mintAndDeposit(token0, token1, vault, alice, amount0, amount1);

        uint256 v2Amount0 = 6 ether;
        uint256 v2Amount1 = 12e6;
        uint256 v2Liquidity = 3 ether;

        uint256 v3Amount0 = 4 ether;
        uint256 v3Amount1 = 8e6;

        routerV2.setNextAddLiquidityResult(v2Amount0, v2Amount1, v2Liquidity);

        uint128 v3Liquidity = _primeV3Mint(token0, token1, poolV3, positionManagerV3, 
                                tickLower, tickUpper, v3Amount0, v3Amount1);

        RebalanceTypes.RebalanceTarget[] memory deployTargets = _buildTwoTargets(
            V2_VENUE_ID, v2Amount0, v2Amount1, "", 
            V3_LOW_VENUE_ID, v3Amount0, v3Amount1, _defaultV3Params()
        );

        vault.rebalance(deployTargets, _emptyWithdrawalParams());

        assertTrue(adapterV2.hasPosition());
        assertTrue(adapterV3.hasPosition());
        assertEq(vault.venueLiquidity(V2_VENUE_ID), v2Liquidity);
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), uint256(v3Liquidity));
        assertEq(vault.totalLiquidity(), v2Liquidity + uint256(v3Liquidity));

        // set V2 Venue
        routerV2.setNextRemoveLiquidityResult(v2Amount0, v2Amount1);
        // set V3 venue
        (uint256 v3PoolAmount0Out, uint256 v3PoolAmount1Out) = _mapPoolAmounts(token0, token1, v3Amount0, v3Amount1);
        positionManagerV3.setNextDecreaseResult(v3PoolAmount0Out, v3PoolAmount1Out);

        _rebalanceToIdle(vault);

        assertEq(vault.venueLiquidity(V2_VENUE_ID), 0);
        assertEq(vault.venueLiquidity(V3_LOW_VENUE_ID), 0);
        assertEq(vault.totalLiquidity(), 0);

        assertEq(token0.balanceOf(address(vault)), amount0);
        assertEq(token1.balanceOf(address(vault)), amount1);

        assertEq(pairV2.balanceOf(address(adapterV2)), 0);
        assertFalse(adapterV2.hasPosition());

        assertFalse(adapterV3.hasPosition());
        assertEq(adapterV3.tokenId(), 0);
    }

    function test_Rebalance_RevertsOnDuplicateVenueTargets() public {
        _mintAndDeposit(token0, token1, vault, alice, 10 ether, 20e6);

        RebalanceTypes.RebalanceTarget[] memory targets = _buildTwoTargets(
            V2_VENUE_ID, 6 ether, 12e6, "", 
            V2_VENUE_ID, 4 ether, 8e6, ""
        );

        vm.expectRevert(AdaptiveLPVault.DuplicateVenueTarget.selector);
        vault.rebalance(targets, _emptyWithdrawalParams());
    }

    function test_Rebalance_RevertsWhenTargetVenueNotSet() public {
        _mintAndDeposit(token0, token1, vault, alice, 10 ether, 20e6);

        RebalanceTypes.RebalanceTarget[] memory targets = _buildSingleTarget(999, 6 ether, 12e6, "");

        vm.expectRevert(AdaptiveLPVault.VenueNotSet.selector);
        vault.rebalance(targets, _emptyWithdrawalParams());
    }

    function test_Rebalance_RevertsWhenTargetVenueDisabled() public {
        _mintAndDeposit(token0, token1, vault, alice, 10 ether, 20e6);

        vault.setVenue(V2_VENUE_ID, address(adapterV2), V2_LABEL, false);
        RebalanceTypes.RebalanceTarget[] memory targets = _buildSingleTarget(V2_VENUE_ID, 6 ether, 12e6, "");

        vm.expectRevert(AdaptiveLPVault.VenueDisabled.selector);
        vault.rebalance(targets, _emptyWithdrawalParams());
    }

    function test_Rebalance_RevertsWhenPlanExceedsIdleBalances() public {
        _mintAndDeposit(token0, token1, vault, alice, 1 ether, 2e6);
        
        RebalanceTypes.RebalanceTarget[] memory targets = _buildSingleTarget(V2_VENUE_ID, 6 ether, 12e6, "");

        vm.expectRevert(AdaptiveLPVault.InsufficientBalances.selector);
        vault.rebalance(targets, _emptyWithdrawalParams());
    }

    function test_Rebalance_RevertsWhenNoRebalanceNeeded() public {
        _mintAndDeposit(token0, token1, vault, alice, 10 ether, 20e6);
        assertEq(vault.totalLiquidity(), 0);

        RebalanceTypes.RebalanceTarget[] memory targets = new RebalanceTypes.RebalanceTarget[](0);
        vm.expectRevert(AdaptiveLPVault.NoRebalanceNeeded.selector);
        vault.rebalance(targets, _emptyWithdrawalParams());
    }
}