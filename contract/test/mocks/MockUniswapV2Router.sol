// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../src/interfaces/IUniswapV2Router.sol";
import "./MockERC20.sol";
import "./MockUniswapV2Pair.sol";

/// @title MockUniswapV2Router
/// @notice Configurable router mock used to script add/remove liquidity results.
contract MockUniswapV2Router is IUniswapV2Router {
    MockUniswapV2Pair private immutable pair;

    uint256 public nextAmountAUsed;
    uint256 public nextAmountBUsed;
    uint256 public nextLiquidityMinted;

    uint256 public nextAmountAOut;
    uint256 public nextAmountBOut;

    /// @param _pair LP token contract minted and burned by the router mock.
    constructor(MockUniswapV2Pair _pair) {
        pair = _pair;
    }

    /// @notice Configures the next `addLiquidity` return values.
    /// @param amountAUsed Amount of tokenA reported as used.
    /// @param amountBUsed Amount of tokenB reported as used.
    /// @param liquidityMinted LP tokens reported as minted.
    function setNextAddLiquidityResult(
        uint256 amountAUsed,
        uint256 amountBUsed,
        uint256 liquidityMinted
    ) external {
        nextAmountAUsed = amountAUsed;
        nextAmountBUsed = amountBUsed;
        nextLiquidityMinted = liquidityMinted;
    }

    /// @notice Configures the next `removeLiquidity` return values.
    /// @param amountAOut Amount of tokenA reported as returned.
    /// @param amountBOut Amount of tokenB reported as returned.
    function setNextRemoveLiquidityResult(
        uint256 amountAOut,
        uint256 amountBOut
    ) external {
        nextAmountAOut = amountAOut;
        nextAmountBOut = amountBOut;
    }

    /// @inheritdoc IUniswapV2Router
    function addLiquidity(
        address token0,
        address token1,
        uint256,
        uint256,
        uint256,
        uint256,
        address to,
        uint256
    ) external override returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        amountA = nextAmountAUsed;
        amountB = nextAmountBUsed;
        liquidity = nextLiquidityMinted;
        if (amountA > 0) {
            MockERC20(token0).transferFrom(msg.sender, address(pair), amountA);
        }
        if (amountB > 0) {
            MockERC20(token1).transferFrom(msg.sender, address(pair), amountB);
        }
        if (liquidity > 0) {
            pair.mintLp(to, liquidity);
        }
    }

    /// @inheritdoc IUniswapV2Router
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256,
        uint256,
        address to,
        uint256
    ) external override returns (uint256 amountA, uint256 amountB) {
        if (liquidity > 0) {
            pair.burnLp(msg.sender, liquidity);
        }

        amountA = nextAmountAOut;
        amountB = nextAmountBOut;

        if (amountA > 0) {
            MockERC20(tokenA).mint(to, amountA);
        }

        if (amountB > 0) {
            MockERC20(tokenB).mint(to, amountB);
        }
    }
}
