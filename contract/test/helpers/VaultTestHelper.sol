// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../mocks/MockERC20.sol";
import "../../src/AdaptiveLPVault.sol";

abstract contract VaultTestHelper is Test {
    /// @notice Mints mock tokens, approves the vault, and deposits for the same user.
    /// @dev Use this helper for the common path where the token sender also receives the vault shares.
    /// For receiver-specific tests, use `_mintAndDepositToReceiver`.
    /// @param user The address supplying token0/token1 and receiving minted vault shares.
    /// @param amount0 The amount of token0 to deposit.
    /// @param amount1 The amount of token1 to deposit.
    /// @return shares The amount of vault shares minted to `user`.
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
        shares = vault.deposit(amount0, amount1, user);
        vm.stopPrank();
    }

    /// @notice Mints mock tokens to `sender`, approves the vault, and deposits shares to `receiver`.
    /// @dev Use this helper when testing ERC4626-style receiver semantics: sender supplies tokens, receiver receives shares.
    /// @param sender The address supplying token0/token1 and calling deposit.
    /// @param receiver The address receiving minted vault shares.
    /// @param amount0 The amount of token0 to deposit.
    /// @param amount1 The amount of token1 to deposit.
    /// @return shares The amount of vault shares minted to `receiver`.
    function _mintAndDepositToReceiver(
        MockERC20 token0,
        MockERC20 token1,
        AdaptiveLPVault vault,
        address sender, 
        address receiver,
        uint256 amount0, 
        uint256 amount1
    ) internal returns (uint256 shares){
        token0.mint(sender, amount0);
        token1.mint(sender, amount1);

        vm.startPrank(sender);
        token0.approve(address(vault), amount0);
        token1.approve(address(vault), amount1);
        shares = vault.deposit(amount0, amount1, receiver);
        vm.stopPrank();
    }

    /// @notice Returns an empty redeem withdrawal params array for tests that do not exercise adapter slippage.
    function _emptyWithdrawalParams() internal pure returns (
        AdaptiveLPVault.VenueWithdrawalParams[] memory params
    ){
        params = new AdaptiveLPVault.VenueWithdrawalParams[](0);
    }
}
