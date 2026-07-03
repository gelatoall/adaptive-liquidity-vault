// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../src/interfaces/IUniswapV3Pool.sol";
import "../../src/libraries/v3/TickMath.sol";

/// @title MockUniswapV3Pool
/// @notice Minimal Uniswap V3 pool mock used by adapter tests.
/// @dev Keeps token order canonical and exposes only the pool fields currently used by the adapter.
contract MockUniswapV3Pool is IUniswapV3Pool {
    address public token0;
    address public token1;
    uint24 public fee;
    int24 public currentTick;
    uint160 public sqrtPriceX96;
    int24 public tickSpacing;

    /// @notice Creates a mock pool for the given token pair and fee tier.
    /// @dev The token addresses are sorted to match Uniswap V3 pool token ordering.
    constructor(address _token0, address _token1, uint24 _fee) {
        (token0, token1) = _token0 < _token1 ? (_token0, _token1) : (_token1, _token0);
        fee = _fee;
        tickSpacing = 60;
        currentTick = 0;
        sqrtPriceX96 = TickMath.getSqrtRatioAtTick(currentTick); // 2^96
    }

    /// @notice Sets slot0 using a tick-derived sqrt price.
    /// @dev Use this in most tests to keep tick and sqrtPriceX96 consistent.
    function setSlot0FromTick(int24 _tick) external {
        currentTick = _tick;
        sqrtPriceX96 = TickMath.getSqrtRatioAtTick(_tick);
    }

    /// @notice Sets slot0 directly.
    /// @dev Use this for tests that intentionally need a custom price/tick combination.
    function setSlot0(uint160 _sqrtPriceX96, int24 _tick) external {
        sqrtPriceX96 = _sqrtPriceX96;
        currentTick = _tick;
    }

    /// @inheritdoc IUniswapV3Pool
    function slot0() external view returns (
        uint160, int24, uint16, uint16, uint16, uint8, bool
    ) {
        return (sqrtPriceX96, currentTick, 0, 0, 0, 0, true);
    }
}
