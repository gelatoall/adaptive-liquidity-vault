// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../src/interfaces/IVolatilityOracle.sol";

/// @notice Test volatility oracle with manually controlled output.
contract MockVolatilityOracle is IVolatilityOracle {
    uint256 public volatilityBps;

    /// @notice Sets the volatility returned by the mock.
    function setVolatilityBps(uint256 value) external {
        volatilityBps = value;
    }

    /// @notice Returns the configured volatility value.
    function getVolatilityBps() external view returns (uint256) {
        return volatilityBps;
    }
}
