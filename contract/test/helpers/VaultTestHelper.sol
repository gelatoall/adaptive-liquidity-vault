// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../mocks/MockERC20.sol";
import "../../src/AdaptiveLPVault.sol";

abstract contract VaultTestHelper is Test {
    /// @notice Mints mock tokens, approves, and deposits into the vault for a user.
    /// @param user The address performing the deposit.
    /// @param amount0 The amount of token0 to deposit.
    /// @param amount1 The amount of token1 to deposit.
    /// @return shares The amount of vault shares minted.
    function _mintAndDeposit(
        MockERC20 token0,
        MockERC20 token1,
        AdaptiveLPVault vault,
        address user, 
        uint256 amount0, 
        uint256 amount1
    ) internal returns (uint256 shares){
        token0.mint(user, amount0);
        token1.mint(user, amount1);

        vm.startPrank(user);
        token0.approve(address(vault), amount0);
        token1.approve(address(vault), amount1);
        shares = vault.deposit(amount0, amount1);
        vm.stopPrank();
    }
}