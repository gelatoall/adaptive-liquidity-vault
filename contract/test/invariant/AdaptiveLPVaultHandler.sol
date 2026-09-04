// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "../helpers/VenueTestHelper.sol";
import "../../src/AdaptiveLPVault.sol";
import "../../src/adapters/UniswapV2Adapter.sol";
import "../../src/adapters/UniswapV3Adapter.sol";
import "../../src/libraries/RebalanceTypes.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockUniswapV2Pair.sol";
import "../mocks/MockUniswapV2Router.sol";
import "../mocks/MockUniswapV3Pool.sol";
import "../mocks/MockNonfungiblePositionManager.sol";

contract AdaptiveLPVaultHandler is VenueTestHelper {
    struct V3Venue {
        uint256 venueId;
        MockUniswapV3Pool pool;
        MockNonfungiblePositionManager positionManager;
        UniswapV3Adapter adapter;
    }

    struct VenueAmounts {
        uint256 amount0;
        uint256 amount1;
    }

    AdaptiveLPVault internal immutable vault;
    MockERC20 internal immutable token0;
    MockERC20 internal immutable token1;
    
    MockUniswapV2Pair internal immutable pairV2;
    MockUniswapV2Router internal immutable routerV2;
    UniswapV2Adapter internal immutable adapterV2;
    
    V3Venue internal v3Low;
    V3Venue internal v3Mid;
    V3Venue internal v3High;
    
    address internal immutable vaultOwner;
    address[] internal actors;
    
    int24 internal immutable tickLower;
    int24 internal immutable tickUpper;
    
    uint256 public lastRebalanceSupplyBefore;
    uint256 public lastRebalanceSupplyAfter;
    uint256 public successfulRebalanceCount;

    mapping(uint256 => VenueAmounts) internal deployedAmounts;

    constructor(
        AdaptiveLPVault _vault,
        MockERC20 _token0,
        MockERC20 _token1,
        MockUniswapV2Pair _pairV2,
        MockUniswapV2Router _routerV2,
        UniswapV2Adapter _adapterV2,
        V3Venue memory _v3Low,
        V3Venue memory _v3Mid,
        V3Venue memory _v3High,
        address _vaultOwner,
        address[] memory _actors,
        int24 _tickLower,
        int24 _tickUpper
    ) {
        vault = _vault;
        token0 = _token0;
        token1 = _token1;
        pairV2 = _pairV2;
        routerV2 = _routerV2;
        adapterV2 = _adapterV2;
        v3Low = _v3Low;
        v3Mid = _v3Mid;
        v3High = _v3High;
        vaultOwner = _vaultOwner;
        actors = _actors;
        tickLower = _tickLower;
        tickUpper = _tickUpper;
    }

    function deposit(uint256 actorSeed, uint256 amount0Seed, uint256 amount1Seed) external {
        // Keep deposits idle-only while a venue position is active in this handler.
        if (_hasActiveVenuePosition()) return;

        address actor = _actor(actorSeed);

        uint256 amount0 = bound(amount0Seed, 1e18, 10000e18);
        uint256 amount1 = bound(amount1Seed, 1e6, 10000e6);

        token0.mint(actor, amount0);
        token1.mint(actor, amount1);

        vm.startPrank(actor);
        token0.approve(address(vault), amount0);
        token1.approve(address(vault), amount1);
        vault.deposit(amount0, amount1, actor, 0);
        vm.stopPrank();
    }

    function redeem(uint256 actorSeed, uint256 sharesSeed) external {
        // Synchronous redeem only uses idle balances in the current vault design.
        if (_hasActiveVenuePosition()) return;
        
        address actor = _actor(actorSeed);
        uint256 actorShares = vault.balanceOf(actor);
        if (actorShares == 0) return;

        uint256 shares = bound(sharesSeed, 1, actorShares);
        uint256 totalShares = vault.totalSupply();
        uint256 idleValue = vault.totalAssets();
        if (idleValue == 0) return;

        uint256 redeemValue = Math.mulDiv(idleValue, shares, totalShares);
        if (redeemValue == 0) return;

        uint256 idle0 = token0.balanceOf(address(vault));
        uint256 idle1 = token1.balanceOf(address(vault));

        uint256 amount0Out = Math.mulDiv(idle0, redeemValue, idleValue);
        uint256 amount1Out = Math.mulDiv(idle1, redeemValue, idleValue);
        if (amount0Out == 0 && amount1Out == 0) return;

        vm.prank(actor);
        vault.redeem(shares, actor, actor, 0, 0);
    }

    /// @notice Rebalances all idle assets into equal targets across the four configured venues.
    function rebalanceToFourVenueSplit() external {
        // This initial handler version only opens positions from a fully idle vault.
        if (_hasActiveVenuePosition()) return;

        uint256 idle0 = token0.balanceOf(address(vault));
        uint256 idle1 = token1.balanceOf(address(vault));

        // Every configured V3 test position uses both assets in its active range.
        if (idle0 == 0 || idle1 == 0) return;

        uint256 v2Amount0 = idle0 / 4;
        uint256 v2Amount1 = idle1 / 4;
        uint256 v3LowAmount0 = idle0 / 4;
        uint256 v3LowAmount1 = idle1 / 4;
        uint256 v3MidAmount0 = idle0 / 4;
        uint256 v3MidAmount1 = idle1 / 4;
        uint256 v3HighAmount0 = idle0 - v2Amount0 - v3LowAmount0 - v3MidAmount0;
        uint256 v3HighAmount1 = idle1 - v2Amount1 - v3LowAmount1 - v3MidAmount1;

        // Configure the V2 router and its valuation reserves.
        uint256 v2Liquidity = 1 ether;
        routerV2.setNextAddLiquidityResult(v2Amount0, v2Amount1, v2Liquidity);
        pairV2.setReserves(uint112(v2Amount0), uint112(v2Amount1));

        // Configure one deterministic mint result for each independent V3 position manager.
        _primeV3Mint(token0, token1, v3Low.pool, v3Low.positionManager, tickLower, tickUpper, v3LowAmount0, v3LowAmount1);
        _primeV3Mint(token0, token1, v3Mid.pool, v3Mid.positionManager, tickLower, tickUpper, v3MidAmount0, v3MidAmount1);
        _primeV3Mint(token0, token1, v3High.pool, v3High.positionManager, tickLower, tickUpper, v3HighAmount0, v3HighAmount1);

        RebalanceTypes.RebalanceTarget[] memory targets = new RebalanceTypes.RebalanceTarget[](4);
        targets[0] = RebalanceTypes.RebalanceTarget({
            venueId: V2_VENUE_ID,
            amount0: v2Amount0,
            amount1: v2Amount1,
            params: ""
        });

        bytes memory v3Params = _defaultV3Params(tickLower, tickUpper);
        targets[1] = RebalanceTypes.RebalanceTarget({
            venueId: V3_LOW_VENUE_ID,
            amount0: v3LowAmount0,
            amount1: v3LowAmount1,
            params: v3Params
        });
        targets[2] = RebalanceTypes.RebalanceTarget({
            venueId: V3_MID_VENUE_ID,
            amount0: v3MidAmount0,
            amount1: v3MidAmount1,
            params: v3Params
        });
        targets[3] = RebalanceTypes.RebalanceTarget({
            venueId: V3_HIGH_VENUE_ID,
            amount0: v3HighAmount0,
            amount1: v3HighAmount1,
            params: v3Params
        });

        uint256 supplyBefore = vault.totalSupply();

        vm.prank(vaultOwner);
        vault.rebalance(targets, _emptyWithdrawalParams());

        lastRebalanceSupplyBefore = supplyBefore;
        lastRebalanceSupplyAfter = vault.totalSupply();
        successfulRebalanceCount++;

        deployedAmounts[V2_VENUE_ID] = VenueAmounts(v2Amount0, v2Amount1);
        deployedAmounts[V3_LOW_VENUE_ID] = VenueAmounts(v3LowAmount0, v3LowAmount1);
        deployedAmounts[V3_MID_VENUE_ID] = VenueAmounts(v3MidAmount0, v3MidAmount1);
        deployedAmounts[V3_HIGH_VENUE_ID] = VenueAmounts(v3HighAmount0, v3HighAmount1);
    }

    /// @notice Withdraws all active venue positions back to idle vault balances.
    function rebalanceToIdle() external {
        if (!_hasActiveVenuePosition()) return;

        VenueAmounts memory v2Amounts = deployedAmounts[V2_VENUE_ID];
        VenueAmounts memory v3LowAmounts = deployedAmounts[V3_LOW_VENUE_ID];
        VenueAmounts memory v3MidAmounts = deployedAmounts[V3_MID_VENUE_ID];
        VenueAmounts memory v3HighAmounts = deployedAmounts[V3_HIGH_VENUE_ID];

        // The V2 router returns vault-ordered token amounts directly.
        routerV2.setNextRemoveLiquidityResult(v2Amounts.amount0, v2Amounts.amount1);

        // V3 mocks expect amounts in each pool's token order.
        (uint256 lowPoolAmount0, uint256 lowPoolAmount1) = _mapPoolAmounts(token0, token1,
                v3LowAmounts.amount0, v3LowAmounts.amount1);
        v3Low.positionManager.setNextDecreaseResult(lowPoolAmount0, lowPoolAmount1);

        (uint256 midPoolAmount0, uint256 midPoolAmount1) = _mapPoolAmounts(token0, token1,
                v3MidAmounts.amount0, v3MidAmounts.amount1);
        v3Mid.positionManager.setNextDecreaseResult(midPoolAmount0, midPoolAmount1);

        (uint256 highPoolAmount0, uint256 highPoolAmount1) = _mapPoolAmounts(token0, token1,
                v3HighAmounts.amount0, v3HighAmounts.amount1);
        v3High.positionManager.setNextDecreaseResult(highPoolAmount0, highPoolAmount1);

        AdaptiveLPVault.VenueWithdrawalParams[] memory withdrawalParams = new AdaptiveLPVault.VenueWithdrawalParams[](3);
        bytes memory v3Params = _defaultV3Params(tickLower, tickUpper);
        withdrawalParams[0] = AdaptiveLPVault.VenueWithdrawalParams({
            venueId: V3_LOW_VENUE_ID,
            params: v3Params
        });
        withdrawalParams[1] = AdaptiveLPVault.VenueWithdrawalParams({
            venueId: V3_MID_VENUE_ID,
            params: v3Params
        });
        withdrawalParams[2] = AdaptiveLPVault.VenueWithdrawalParams({
            venueId: V3_HIGH_VENUE_ID,
            params: v3Params
        });

        uint256 supplyBefore = vault.totalSupply();

        RebalanceTypes.RebalanceTarget[] memory targets = new RebalanceTypes.RebalanceTarget[](0);

        vm.prank(vaultOwner);
        vault.rebalance(targets, withdrawalParams);

        lastRebalanceSupplyBefore = supplyBefore;
        lastRebalanceSupplyAfter = vault.totalSupply();
        successfulRebalanceCount++;

        delete deployedAmounts[V2_VENUE_ID];
        delete deployedAmounts[V3_LOW_VENUE_ID];
        delete deployedAmounts[V3_MID_VENUE_ID];
        delete deployedAmounts[V3_HIGH_VENUE_ID];
    }
    
    function _actor(uint256 actorSeed) internal view returns (address) {
        return actors[actorSeed % actors.length];
    }

    function _hasActiveVenuePosition() internal view returns (bool) {
        return (adapterV2.hasPosition() || v3Low.adapter.hasPosition() 
            || v3Mid.adapter.hasPosition() || v3High.adapter.hasPosition());
    }

    function _emptyWithdrawalParams() internal pure returns (AdaptiveLPVault.VenueWithdrawalParams[] memory params) {
        params = new AdaptiveLPVault.VenueWithdrawalParams[](0);
    }
}