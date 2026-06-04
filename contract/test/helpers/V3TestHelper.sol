// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../mocks/MockERC20.sol";

abstract contract V3TestHelper is Test {
    /// @notice Maps vault-ordered amounts to pool-ordered amounts.
    function _mapPoolAmounts(
        MockERC20 token0,
        MockERC20 token1,
        uint256 vaultAmount0, 
        uint256 vaultAmount1
    ) internal view returns (uint256 poolAmount0, uint256 poolAmount1) {
        if (address(token0) < address(token1)) {
            return (vaultAmount0, vaultAmount1);
        } else {
            return (vaultAmount1, vaultAmount0);
        }
    }
}