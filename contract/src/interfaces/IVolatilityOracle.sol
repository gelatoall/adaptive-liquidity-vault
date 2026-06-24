// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Provides a volatility value in basis points.
interface IVolatilityOracle {
    /// @notice Returns the current volatility estimate in basis points.
    function getVolatilityBps() external view returns (uint256 volatilityBps);
}
