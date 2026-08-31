// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test ERC20 that deducts a configurable fee from ordinary transfers.
contract MockFeeOnTransferERC20 is ERC20 {
    uint256 public immutable feeBps;
    address public immutable feeRecipient;
    uint8 private immutable _customDecimals;

    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals_,
        uint256 feeBps_,
        address feeRecipient_
    ) ERC20(name, symbol) {
        _customDecimals = decimals_;
        feeBps = feeBps_;
        feeRecipient = feeRecipient_;
    }

    function decimals() public view override returns (uint8) {
        return _customDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        // Mint and burn remain fee-free; ordinary transfers pay the configured fee.
        if (from == address(0) || to == address(0) || feeBps == 0) {
            super._update(from, to, amount);
            return;
        }

        uint256 fee = amount * feeBps / 10000;
        super._update(from, to, amount - fee);
        super._update(from, feeRecipient, fee);
    }
}
