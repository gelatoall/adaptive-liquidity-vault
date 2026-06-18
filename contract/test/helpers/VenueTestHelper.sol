// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../src/AdaptiveLPVault.sol";
import "../../src/libraries/v3/LiquidityAmounts.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockUniswapV2Router.sol";
import "../mocks/MockUniswapV3Pool.sol";
import "../mocks/MockNonfungiblePositionManager.sol";

abstract contract VenueTestHelper is Test {
    uint256 internal constant V2_VENUE_ID = 1;
    uint256 internal constant V3_LOW_VENUE_ID = 2;
    uint256 internal constant V3_MID_VENUE_ID = 3;
    uint256 internal constant V3_HIGH_VENUE_ID = 4;

    bytes32 internal constant V2_LABEL = bytes32("V2");
    bytes32 internal constant V3_LOW_LABEL = bytes32("V3_005");
    bytes32 internal constant V3_MID_LABEL = bytes32("V3_030");
    bytes32 internal constant V3_HIGH_LABEL = bytes32("V3_100");

    /// @notice Returns permissive V3 add-liquidity params for tests.
    function _defaultV3Params() internal view returns (bytes memory) {
        return abi.encode(0, 0, block.timestamp + 1);
    }

    /// @notice Maps vault-ordered amounts to pool-ordered amounts.
    function _mapPoolAmounts(
        MockERC20 token0,
        MockERC20 token1,
        uint256 vaultAmount0, 
        uint256 vaultAmount1
    ) internal view returns (uint256 poolAmount0, uint256 poolAmount1) {
        if (address(token0) < address(token1)) {
            return (vaultAmount0, vaultAmount1);
        } else {
            return (vaultAmount1, vaultAmount0);
        }
    }

    /// @notice Quotes V3 liquidity and pool-ordered token amounts.
    function _quoteV3Liquidity(
        MockERC20 token0,
        MockERC20 token1,
        MockUniswapV3Pool pool,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal view returns (
        uint128 liquidity,
        uint256 poolAmount0,
        uint256 poolAmount1
    ) {
        (poolAmount0, poolAmount1) = _mapPoolAmounts(token0, token1, amount0, amount1);

        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint160 sqrtRatioLowerX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioUpperX96 = TickMath.getSqrtRatioAtTick(tickUpper);

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtRatioLowerX96,
            sqrtRatioUpperX96,
            poolAmount0,
            poolAmount1
        );
    }

    /// @notice Configures the position manager's next V3 mint result.
    function _primeV3Mint(
        MockERC20 token0,
        MockERC20 token1,
        MockUniswapV3Pool pool,
        MockNonfungiblePositionManager positionManager,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal returns (uint128 liquidity) {
        uint256 poolAmount0;
        uint256 poolAmount1;
        (liquidity, poolAmount0, poolAmount1) = _quoteV3Liquidity(
            token0,
            token1,
            pool,
            tickLower,
            tickUpper,
            amount0,
            amount1
        );

        positionManager.setNextMintResult(liquidity, poolAmount0, poolAmount1);
    }

    /// @notice Configures and executes a vault deployment to a V2 venue.
    function _deployVaultToV2(
        AdaptiveLPVault vault,
        MockUniswapV2Router router,
        uint256 venueId,
        uint256 amount0,
        uint256 amount1,
        uint256 amount0Used,
        uint256 amount1Used,
        uint256 liquidityMinted
    ) internal returns (uint256 liquidity) {
        router.setNextAddLiquidityResult(amount0Used, amount1Used, liquidityMinted);
        liquidity = vault.deployToVenue(venueId, amount0, amount1, "");
    }

    /// @notice Configures and executes a vault deployment to a V3 venue.
    function _deployVaultToV3(
        AdaptiveLPVault vault,
        MockERC20 token0,
        MockERC20 token1,
        MockUniswapV3Pool pool,
        MockNonfungiblePositionManager positionManager,
        uint256 venueId,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal returns (uint256 liquidity) {
        _primeV3Mint(
            token0,
            token1,
            pool,
            positionManager,
            tickLower,
            tickUpper,
            amount0,
            amount1
        );

        liquidity = vault.deployToVenue(
            venueId,
            amount0,
            amount1,
            _defaultV3Params()
        );
    }

    /// @notice Builds weight configs for the standard four test venues.
    function _buildFourTargetConfigs(
        uint256 weightBps0,
        uint256 weightBps1,
        uint256 weightBps2,
        uint256 weightBps3
    ) internal pure returns (RebalanceTypes.TargetConfig[] memory configs) {
        configs = new RebalanceTypes.TargetConfig[](4);

        configs[0] = RebalanceTypes.TargetConfig({
            venueId: V2_VENUE_ID,
            weightBps: weightBps0,
            params: ""
        });

        configs[1] = RebalanceTypes.TargetConfig({
            venueId: V3_LOW_VENUE_ID,
            weightBps: weightBps1,
            params: ""
        });

        configs[2] = RebalanceTypes.TargetConfig({
            venueId: V3_MID_VENUE_ID,
            weightBps: weightBps2,
            params: ""
        });

        configs[3] = RebalanceTypes.TargetConfig({
            venueId: V3_HIGH_VENUE_ID,
            weightBps: weightBps3,
            params: ""
        });
    }
}
