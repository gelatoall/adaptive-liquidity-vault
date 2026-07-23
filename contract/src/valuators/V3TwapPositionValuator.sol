// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../interfaces/IVenueValuator.sol";
import "../interfaces/INonfungiblePositionManager.sol";
import "../interfaces/IUniswapV3Pool.sol";
import "../adapters/UniswapV3Adapter.sol";
import "../libraries/V3TwapLib.sol";
import "../libraries/VaultMath.sol";
import "../libraries/v3/TickMath.sol";
import "../libraries/v3/LiquidityAmounts.sol";

/// @title V3TwapPositionValuator
/// @notice Values one V3 adapter position using the pool's TWAP tick.
/// @dev Computes principal at the TWAP tick, adds position-manager-tracked owed tokens,
///      maps pool token order into vault order, and applies vault-supplied oracle prices.
contract V3TwapPositionValuator is IVenueValuator {
    /// @notice Adapter whose NFT position is valued.
    UniswapV3Adapter public immutable adapter;

    /// @notice Position manager that stores the NFT position state.
    INonfungiblePositionManager public immutable positionManager;

    /// @notice V3 pool used to obtain the TWAP tick.
    IUniswapV3Pool public immutable pool;

    /// @notice Vault-order token0.
    address public immutable token0;

    /// @notice Vault-order token1.
    address public immutable token1;

    /// @notice Decimal precision of token0.
    uint8 public immutable decimals0;

    /// @notice Decimal precision of token1.
    uint8 public immutable decimals1;

    /// @notice Historical lookback used to calculate the valuation tick.
    uint32 public immutable twapWindow;

    error ZeroAddress();
    error InvalidTwapWindow();
    error InvalidPositionTokens();

    /// @param _adapter V3 adapter whose position this contract values.
    /// @param _twapWindow Number of seconds used for the valuation TWAP.
    constructor(address _adapter, uint32 _twapWindow) {
        if (_adapter == address(0)) revert ZeroAddress();
        if (_twapWindow == 0) revert InvalidTwapWindow();

        adapter = UniswapV3Adapter(_adapter);
        positionManager = adapter.positionManager();
        pool = adapter.pool();

        token0 = address(adapter.token0());
        token1 = address(adapter.token1());
        decimals0 = IERC20Metadata(token0).decimals();
        decimals1 = IERC20Metadata(token1).decimals();

        twapWindow = _twapWindow;
    }

    /// @inheritdoc IVenueValuator
    function getVenueAdapter() external view override returns (address) {
        return address(adapter);
    }

    /// @inheritdoc IVenueValuator
    function getValueInBase(uint256 price0, uint256 price1) external view override returns (uint256 value) {
        uint256 positionId = adapter.tokenId();
        if (positionId == 0) {
            return 0;
        }

        (
            ,,
            address positionToken0,
            address positionToken1,,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,,,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = positionManager.positions(positionId);

        bool directOrder = positionToken0 == token0 && positionToken1 == token1;
        bool reversedOrder = positionToken0 == token1 && positionToken1 == token0;
        if (!directOrder && !reversedOrder) {
            revert InvalidPositionTokens();
        }

        uint256 poolAmount0 = uint256(tokensOwed0);
        uint256 poolAmount1 = uint256(tokensOwed1);
        if (liquidity > 0) {
            int24 avgTick = V3TwapLib.getTwapTick(pool, twapWindow);
            uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(avgTick);
            uint160 sqrtRatioLowerX96 = TickMath.getSqrtRatioAtTick(tickLower);
            uint160 sqrtRatioUpperX96 = TickMath.getSqrtRatioAtTick(tickUpper);
            (uint256 principal0, uint256 principal1) =
                LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtRatioLowerX96, sqrtRatioUpperX96, liquidity);
            poolAmount0 += principal0;
            poolAmount1 += principal1;
        }

        uint256 amount0;
        uint256 amount1;
        if (directOrder) {
            amount0 = poolAmount0;
            amount1 = poolAmount1;
        } else {
            amount0 = poolAmount1;
            amount1 = poolAmount0;
        }

        value = VaultMath.getAssetsTotalValue(amount0, price0, decimals0, amount1, price1, decimals1);
    }
}
