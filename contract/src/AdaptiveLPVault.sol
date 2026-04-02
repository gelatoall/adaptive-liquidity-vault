// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./libraries/VaultMath.sol";

contract AdaptiveLPVault {
    using SafeERC20 for IERC20;

    IERC20 public immutable token0;
    IERC20 public immutable token1;

    uint8 public immutable decimals0;
    uint8 public immutable decimals1;

    uint256 public price0;
    uint256 public price1;

    error ZeroAddress();
    error ZeroDecimals();

    constructor(address _token0, address _token1, uint8 _decimals0, uint8 _decimals1) {
        if (_token0 == address(0) || _token1 == address(0)) {
            revert ZeroAddress();
        }

        if (_decimals0 == 0 || _decimals1 == 0) {
            revert ZeroDecimals();
        }

        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
        decimals0 = _decimals0;
        decimals1 = _decimals1;
    }

}