// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IVenueValuator
/// @notice Returns a trusted base-denominated value for one venue position.
interface IVenueValuator {
    /// @notice Returns the adapter whose position this valuator values.
    /// @return adapter Address of the adapter bound to this valuator.
    function getVenueAdapter() external view returns (address adapter);

    /// @notice Returns the venue position value using vault-supplied oracle prices.
    /// @param price0 Price of one whole token0 in the base asset, scaled by 1e18.
    /// @param price1 Price of one whole token1 in the base asset, scaled by 1e18.
    /// @return value Position value denominated in the base asset, scaled by 1e18.
    function getValueInBase(uint256 price0, uint256 price1) external view returns (uint256 value);
}
