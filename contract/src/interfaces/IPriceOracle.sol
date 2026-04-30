// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IPriceOracle
/// @notice Minimal read-only interface that supplies token0 and token1 prices to the vault.
/// @dev Mutable price-setting belongs to concrete oracle implementations, such as a test mock.
interface IPriceOracle {
	/// @notice Returns the current prices of token0 and token1.
	/// @dev Prices are denominated in the vault's base asset and use 1e18 precision.
	/// @return price0 Price of one whole token0.
	/// @return price1 Price of one whole token1.
	function getPrices() external view returns (uint256 price0, uint256 price1);
}
