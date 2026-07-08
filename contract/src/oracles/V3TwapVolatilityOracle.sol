// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./V3TWAPOracle.sol";
import "../interfaces/IVolatilityOracle.sol";
import "../libraries/V3TwapLib.sol";

/// @notice Measures market volatility as spot price deviation from a V3 TWAP.
contract V3TwapVolatilityOracle is V3TWAPOracle, IVolatilityOracle {
    uint32 public immutable twapWindow;

    error InvalidTwapWindow();
    
    constructor(address _pool, uint32 _twapWindow) V3TWAPOracle(_pool) {
        if (_twapWindow == 0) revert InvalidTwapWindow();
        twapWindow = _twapWindow;
    }

    /// @notice Returns the current spot price from pool slot0.
    function getSpotPrice() public view returns (uint256 price) {
        price = V3TwapLib.getSpotPrice(pool);
    }

    /// @inheritdoc IVolatilityOracle
    function getVolatilityBps() public view override returns (uint256 volatilityBps) {
        uint256 spotPrice = getSpotPrice();
        uint256 twapPrice = getTWAP(twapWindow);
        volatilityBps = V3TwapLib.getDeviationBps(spotPrice, twapPrice);
    }
}
