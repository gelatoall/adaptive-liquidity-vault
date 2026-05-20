// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IUniswapV3Pool
/// @notice Minimal interface for the V3 pool used by the adapter.
interface IUniswapV3Pool {
    /// @notice Returns the first token in the pool.
    function token0() external view returns (address);

    /// @notice Returns the second token in the pool.
    function token1() external view returns (address);

    /// @notice Returns the pool fee tier.
    function fee() external view returns (uint24);

    // /// @notice Returns the tick spacing for this pool.
    // function tickSpacing() external view returns (int24);

    /// @notice Returns current pool state, including the current square-root price and tick.
    /// @return sqrtPriceX96 Current sqrt price in Q64.96.
    /// @return tick Current tick.
    /// @return observationIndex Current observation index.
    /// @return observationCardinality Current observation cardinality.
    /// @return observationCardinalityNext Next observation cardinality.
    /// @return feeProtocol Protocol fee configuration.
    /// @return unlocked Whether the pool is unlocked.
    function slot0() external view returns (
        uint160 sqrtPriceX96,
        int24 tick,
        uint16 observationIndex,
        uint16 observationCardinality,
        uint16 observationCardinalityNext,
        uint8 feeProtocol,
        bool unlocked
    );
  }