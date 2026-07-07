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
    int24 public twapTick;
    uint160 public sqrtPriceX96;
    int24 public tickSpacing;

    error InvalidFee();
    error ObservationTooOld();

    /// @notice Creates a mock pool for the given token pair and fee tier.
    /// @dev The token addresses are sorted to match Uniswap V3 pool token ordering.
    constructor(address _token0, address _token1, uint24 _fee) {
        (token0, token1) = _token0 < _token1 ? (_token0, _token1) : (_token1, _token0);
        fee = _fee;
        tickSpacing = _tickSpacingForFee(_fee);
        currentTick = 0;
        twapTick = currentTick;
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

    /// @notice Sets the average tick returned by observe for TWAP tests.
    function setTwapTick(int24 _twapTick) external {
        twapTick = _twapTick;
    }

    /// @inheritdoc IUniswapV3Pool
    function slot0() external view returns (
        uint160, int24, uint16, uint16, uint16, uint8, bool
    ) {
        return (sqrtPriceX96, currentTick, 0, 0, 0, 0, true);
    }

    /// @inheritdoc IUniswapV3Pool
    function observe(uint32[] calldata secondsAgos) external view returns (
        int56[] memory tickCumulatives,
        uint160[] memory secondsPerLiquidityCumulativeX128s
    ) {
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);

        for (uint256 i = 0; i < secondsAgos.length; i++) {
            if (secondsAgos[i] > block.timestamp) revert ObservationTooOld();

            uint56 observationTime = uint56(block.timestamp - secondsAgos[i]);
            tickCumulatives[i] = int56(twapTick) * int56(observationTime);
        }
    }

    function _tickSpacingForFee(uint24 _fee) internal pure returns (int24) {
        if (_fee == 500) return 10;     // 0.05% fee = 500   -> tickSpacing = 10
        if (_fee == 3000) return 60;    // 0.30% fee = 3000  -> tickSpacing = 60
        if (_fee == 10000) return 200;  // 1.00% fee = 10000 -> tickSpacing = 200
        revert InvalidFee();
    }
}
