// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IUniswapV2Pair {
    /// @notice Return the first token in the pair
    function token0() external view returns (address);

    /// @notice Return the second token in the pair
    function token1() external view returns (address);

    /// @notice Return the LP token balance of an account
    /// @param account Address to query
    function balanceOf(address account) external view returns (uint256);

    /// @notice Return the total LP token supply
    function totalSupply() external view returns (uint256);

    /// @notice Return the current pair reserves and last update timestamp
    /// @return reserve0 Current reserve of token0
    /// @return reserve1 Current reserve of token1
    /// @return blockTimestampLast Timestamp of the last reserve update
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}
