// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../src/interfaces/IPriceOracle.sol";

/// @title MockPriceOracle
/// @notice Test-only price oracle with manually configurable token prices.
contract MockPriceOracle is IPriceOracle {
	uint256 public price0;
	uint256 public price1; 

    /// @notice Sets the mock prices returned by {getPrices}.
    /// @param _price0 Price of one whole token0.
    /// @param _price1 Price of one whole token1.
    function setPrices(uint256 _price0, uint256 _price1) external {
        price0 = _price0;
        price1 = _price1;
    }

    /// @inheritdoc IPriceOracle
    function getPrices() external view returns (uint256, uint256) {
        return (price0, price1);
    }
}