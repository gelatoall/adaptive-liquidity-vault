// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IUniswapV2Pair {
    /// @notice Returns the first token in the pair.
    /// @return token Address of pair token0.
    function token0() external view returns (address);

    /// @notice Returns the second token in the pair.
    /// @return token Address of pair token1.
    function token1() external view returns (address);

    /// @notice Returns LP token balance of an account.
    /// @param account Address to query.
    /// @return balance LP token balance for the account.
    function balanceOf(address account) external view returns (uint256);

    /// @notice Returns total LP token supply.
    /// @return supply Current LP token total supply.
    function totalSupply() external view returns (uint256);

    /// @notice Returns current pair reserves and last reserve update timestamp.
    /// @return reserve0 Current reserve of pair token0.
    /// @return reserve1 Current reserve of pair token1.
    /// @return blockTimestampLast Timestamp of the last reserve update.
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    /// @notice Returns cumulative price for pair token0.
    /// @dev Uses Uniswap V2 cumulative price semantics (`UQ112x112 * time`).
    /// @return cumulativePrice0 Current cumulative price value for pair token0.
    function price0CumulativeLast() external view returns (uint256);

    /// @notice Returns cumulative price for pair token1.
    /// @dev Uses Uniswap V2 cumulative price semantics (`UQ112x112 * time`).
    /// @return cumulativePrice1 Current cumulative price value for pair token1.
    function price1CumulativeLast() external view returns (uint256);
}
