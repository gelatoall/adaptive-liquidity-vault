// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IUniswapV2Router {
    /// @notice Add liquidity for a token pair
    /// @param tokenA First token in the liquidity pair
    /// @param tokenB Second token in the liquidity pair
    /// @param amountADesired Desired tokenA amount to supply
    /// @param amountBDesired Desired tokenB amount to supply
    /// @param amountAMin Minimum tokenA amount accepted by the router
    /// @param amountBMin Minimum tokenB amount accepted by the router
    /// @param to Recipient of the minted LP tokens
    /// @param deadline Latest valid timestamp for the call
    /// @return amountA Actual tokenA amount supplied
    /// @return amountB Actual tokenB amount supplied
    /// @return liquidity LP tokens minted
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    /// @notice Remove liquidity for a token pair
    /// @param tokenA First token in the liquidity pair
    /// @param tokenB Second token in the liquidity pair
    /// @param liquidity LP token amount to burn
    /// @param amountAMin Minimum tokenA amount expected back
    /// @param amountBMin Minimum tokenB amount expected back
    /// @param to Recipient of the withdrawn underlying tokens
    /// @param deadline Latest valid timestamp for the call
    /// @return amountA Actual tokenA amount returned
    /// @return amountB Actual tokenB amount returned
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);
}
