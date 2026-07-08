// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../interfaces/IUniswapV3Pool.sol";
import "../libraries/V3TwapLib.sol";

/// @notice Reads Uniswap V3's built-in oracle and returns TWAP prices.
contract V3TWAPOracle {
    IUniswapV3Pool public immutable pool;

    error ZeroAddress();

    constructor(address _pool) {
        if (_pool == address(0)) revert ZeroAddress();
        pool = IUniswapV3Pool(_pool);
    }

    /// @notice Returns the TWAP price over a historical period.
    /// @param period Seconds to look back.
    function getTWAP(uint32 period) public view returns (uint256 price) {
        price = V3TwapLib.getTwapPrice(pool, period);
    }
}
