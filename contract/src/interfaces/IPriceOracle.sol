// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IPriceOracle
/// @notice Minimal read-only interface that supplies token0-denominated prices to the vault.
/// @dev Both prices use the same numeraire. The vault treats token0 as the base asset, so price0 is 1e18.
interface IPriceOracle {
	/// @notice Returns the current prices of token0 and token1 in token0.
	/// @return price0 Price of one whole token0 in token0, scaled by 1e18.
	/// @return price1 Price of one whole token1 in token0, scaled by 1e18.
	function getPrices() external view returns (uint256 price0, uint256 price1);
}
