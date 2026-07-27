// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../src/interfaces/IPriceOracle.sol";

/// @notice Test-only reference oracle that mirrors another price oracle.
contract MockForwardingPriceOracle is IPriceOracle {
    IPriceOracle public immutable source;

    error ZeroAddress();

    constructor(address _source) {
        if (_source == address(0)) revert ZeroAddress();
        source = IPriceOracle(_source);
    }

    function getPrices() external view returns (uint256 price0, uint256 price1){
          return source.getPrices();
    }

    function lastUpdatedAt() external view returns (uint256) {
        return source.lastUpdatedAt();
    }
}