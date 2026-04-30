// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockERC20
/// @dev Minimal ERC20 mock with configurable decimals and unrestricted minting for tests.
contract MockERC20 is ERC20 {
    uint8 private immutable _customDecimals;

    /// @param name Token name used by the ERC20 metadata extension.
    /// @param symbol Token symbol used by the ERC20 metadata extension.
    /// @param _decimals Token decimals returned by {decimals}.
    constructor(
        string memory name, 
        string memory symbol,
        uint8 _decimals
    ) ERC20(name, symbol) {
        _customDecimals = _decimals;
    }

    /// @notice Returns the configured token decimals for this mock.
    function decimals() public view override returns (uint8) {
        return _customDecimals;
    }

    /// @notice Mints tokens to the target account.
    /// @param to Recipient of the minted tokens.
    /// @param amount Raw token amount to mint.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Burns tokens from the target account.
    /// @param from Account whose balance is reduced.
    /// @param amount Raw token amount to burn.
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
