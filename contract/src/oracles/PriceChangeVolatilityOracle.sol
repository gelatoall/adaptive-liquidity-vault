// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../interfaces/IPriceOracle.sol";
import "../interfaces/IVolatilityOracle.sol";

/// @notice Converts two-token price changes into a volatility value.
contract PriceChangeVolatilityOracle is IVolatilityOracle {
    // ============================================
    // Constants
    // ============================================
    /// @notice Basis point denominator, where 10_000 equals 100%.
    uint256 internal constant BPS = 10_000;

    // ============================================
    // State Variables
    // ============================================
    /// @notice Price source used for volatility calculation.
    IPriceOracle public immutable priceOracle;

    /// @notice Last sampled token0 price.
    uint256 public lastPrice0;

    /// @notice Last sampled token1 price.
    uint256 public lastPrice1;

    /// @notice Latest volatility value in basis points.
    uint256 public volatilityBps;

    // ============================================
    // Events
    // ============================================
    /// @notice Emitted after volatility is updated from a new price sample.
    event VolatilityUpdated(uint256 price0, uint256 price1, uint256 volatilityBps);

    // ============================================
    // Custom Errors
    // ============================================
    error ZeroAddress();
    error InvalidPrice();

    // ============================================
    // Constructor
    // ============================================
    /// @notice Initializes the oracle with a price source.
    constructor(address _priceOracle) {
        if (_priceOracle == address(0)) revert ZeroAddress();

        priceOracle = IPriceOracle(_priceOracle);
    }

    // ============================================
    // Functions
    // ============================================
    /// @notice Samples current prices and updates volatility.
    function update() external {
        (uint256 price0, uint256 price1) = priceOracle.getPrices();
        if (price0 == 0 || price1 == 0) revert InvalidPrice();

        if (lastPrice0 == 0 || lastPrice1 == 0) {
            lastPrice0 = price0;
            lastPrice1 = price1;
            return;
        }

        uint256 diff0 = _absDiff(price0, lastPrice0);
        uint256 diff1 = _absDiff(price1, lastPrice1);

        uint256 priceChangeBps0 = diff0 * BPS / lastPrice0;
        uint256 priceChangeBps1 = diff1 * BPS / lastPrice1;

        volatilityBps = priceChangeBps0 > priceChangeBps1 ? priceChangeBps0 : priceChangeBps1;
        lastPrice0 = price0;
        lastPrice1 = price1;

        emit VolatilityUpdated(price0, price1, volatilityBps);
    }

    // ============================================
    // View Functions
    // ============================================
    /// @inheritdoc IVolatilityOracle
    function getVolatilityBps() external view returns (uint256) {
        return volatilityBps;
    }

    // ============================================
    // Internal Functions
    // ============================================
    /// @notice Returns the absolute difference between two values.
    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? (a - b) : (b - a);
    }
}
