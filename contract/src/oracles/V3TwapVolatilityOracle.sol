// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./V3TWAPOracle.sol";
import "../interfaces/IVolatilityOracle.sol";

/// @notice Measures market volatility as spot price deviation from a V3 TWAP.
contract V3TwapVolatilityOracle is V3TWAPOracle, IVolatilityOracle {
    uint256 internal constant BPS = 10_000;
    uint32 public immutable twapWindow;

    error InvalidTwapWindow();
    error InvalidTwapPrice();
    
    constructor(address _pool, uint32 _twapWindow) V3TWAPOracle(_pool) {
        if (_twapWindow == 0) revert InvalidTwapWindow();
        twapWindow = _twapWindow;
    }
    
    /// @notice Returns the current spot price from pool slot0.
    function getSpotPrice() public view returns (uint256 price) {
        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        price = _sqrtPriceX96ToPrice(sqrtPriceX96);
    }

    /// @inheritdoc IVolatilityOracle
    function getVolatilityBps() public view override returns (uint256 volatilityBps) {
        uint256 spotPrice = getSpotPrice();
        uint256 twapPrice = getTWAP(twapWindow);
        if (twapPrice == 0) revert InvalidTwapPrice();

        // Calculate absolute deviation
        uint256 deviation;
        if (spotPrice > twapPrice) {
            deviation = spotPrice - twapPrice;
        } else {
            deviation = twapPrice - spotPrice;
        }

        // Return deviation in basis points relative to the TWAP anchor.
        volatilityBps = (deviation * BPS) / twapPrice;
    }
}
