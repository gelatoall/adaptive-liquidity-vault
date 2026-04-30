// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../src/interfaces/IUniswapV2Pair.sol";

/// @title MockUniswapV2Pair
/// @notice Minimal LP token and reserve container used to emulate a Uniswap V2 pair.
contract MockUniswapV2Pair is ERC20, IUniswapV2Pair {
    address public token0;
    address public token1;

    uint112 public reserve0;
    uint112 public reserve1;
    uint32 public blockTimeStampLast;

    /// @param _token0 Address exposed as pair token0.
    /// @param _token1 Address exposed as pair token1.
    constructor(address _token0, address _token1) ERC20("Mock V2 LP", "MV2LP"){
        token0 = _token0;
        token1 = _token1;
    }

    /// @notice Returns the LP token balance for an account.
    /// @param account Address whose LP balance is queried.
    function balanceOf(address account) public view override(ERC20, IUniswapV2Pair) returns (uint256) {
        return super.balanceOf(account);
    }

    /// @notice Returns the total LP supply.
    function totalSupply() public view override(ERC20, IUniswapV2Pair) returns (uint256) {
        return super.totalSupply();
    }

    /// @notice Sets mocked pair reserves.
    /// @param _reserve0 Mock reserve for pair token0.
    /// @param _reserve1 Mock reserve for pair token1.
    function setReserves(uint112 _reserve0, uint112 _reserve1) external {
        reserve0 = _reserve0;
        reserve1 = _reserve1;
        blockTimeStampLast = uint32(block.timestamp);
    }

    /// @notice Returns the mocked pair reserves and last update timestamp.
    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimeStampLast);
    }

    /// @notice Mints LP tokens to the target account.
    /// @param to Recipient of the LP tokens.
    /// @param amount Raw LP amount to mint.
    function mintLp(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Burns LP tokens from the target account.
    /// @param from Account whose LP balance is reduced.
    /// @param amount Raw LP amount to burn.
    function burnLp(address from, uint256 amount) external {
        _burn(from, amount);
    }
}