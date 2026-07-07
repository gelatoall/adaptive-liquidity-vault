// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "../interfaces/IPriceOracle.sol";
import "../interfaces/IUniswapV2Pair.sol";

/// @title V2TWAPOracle
/// @notice Minimal Uniswap V2 TWAP oracle that returns token prices in 1e18 precision.
/// @dev Computes a windowed average from cumulative prices and elapsed time.
contract V2TWAPOracle is IPriceOracle {
    // ============================================
    // Constants
    // ============================================
    /// @notice Output precision for returned prices.
    uint256 public constant PRECISION = 1e18;

    /// @notice Uniswap V2 fixed-point denominator for UQ112x112 values.
    uint256 public constant Q112 = 2 ** 112; // 2^112


    // ============================================
    // State Variables
    // ============================================
    /// @notice Uniswap V2 pair used as TWAP source.
    IUniswapV2Pair public immutable pair;

    /// @notice Token considered as price0 in this oracle output.
    address public immutable token0;

    /// @notice Token considered as price1 in this oracle output.
    address public immutable token1;

    /// @notice Minimum number of seconds between valid updates.
    uint32 public immutable minUpdateInterval;

    /// @notice Last recorded cumulative price for pair token0.
    uint256 public price0CumulativeLast;

    /// @notice Last recorded cumulative price for pair token1.
    uint256 public price1CumulativeLast;

    /// @notice Last recorded timestamp from pair reserves.
    uint32 public blockTimestampLast;

    /// @notice Latest TWAP average for pair token0 in UQ112x112 precision.
    uint256 public price0AverageX112;

    /// @notice Latest TWAP average for pair token1 in UQ112x112 precision.
    uint256 public price1AverageX112;

    /// @notice True after the first successful `update`.
    bool public initialized;

    // ============================================
    // Events
    // ============================================
    /// @notice Emitted after a successful TWAP window update.
    /// @param price0 Latest 1e18-scaled price for configured token0.
    /// @param price1 Latest 1e18-scaled price for configured token1.
    /// @param timeElapsed Seconds elapsed in the window used for this update.
    event TwapUpdated(uint256 price0, uint256 price1, uint32 timeElapsed);

    // ============================================
    // Custom Errors
    // ============================================
    /// @notice Thrown when an address argument is zero.
    error ZeroAddress();

    /// @notice Thrown when min update interval is zero.
    error InvalidInterval();

    /// @notice Thrown when pair token set does not match configured token set.
    error InvalidPairTokens();

    /// @notice Thrown when no time elapsed since last snapshot.
    error ZeroTimeElapsed();

    /// @notice Thrown when elapsed time is below `minUpdateInterval`.
    error IntervalTooShort();

    /// @notice Thrown when prices are requested before first valid update.
    error NotInitialized();

    // ============================================
    // Constructor
    // ============================================
    /// @param _pair Uniswap V2 pair address used for cumulative prices.
    /// @param _token0 Token to be returned as `price0` by this oracle.
    /// @param _token1 Token to be returned as `price1` by this oracle.
    /// @param _minUpdateInterval Minimum seconds required between valid updates.
    constructor(address _pair, address _token0, address _token1, uint32 _minUpdateInterval) {
        if (_pair == address(0) || _token0 == address(0) || _token1 == address(0)) {
            revert ZeroAddress();
        }

        if (_minUpdateInterval == 0) {
            revert InvalidInterval();
        }

        pair = IUniswapV2Pair(_pair);
        token0 = _token0;
        token1 = _token1;
        minUpdateInterval = _minUpdateInterval;

        address pairToken0 = pair.token0();
        address pairToken1 = pair.token1();
        bool direct = (pairToken0 == _token0) && (pairToken1 == _token1);
        bool reversed = (pairToken0 == _token1) && (pairToken1 == _token0);
        if (!direct && !reversed) {
            revert InvalidPairTokens();
        }
        
        price0CumulativeLast = pair.price0CumulativeLast();
        price1CumulativeLast = pair.price1CumulativeLast();
        (, , uint32 ts) = pair.getReserves();
        blockTimestampLast = ts;
    }

    // ============================================
    // Functions
    // ============================================
    /// @notice Updates TWAP averages if enough time elapsed since last snapshot.
    /// @dev Uses wrap-around semantics for uint32 timestamps and cumulative deltas.
    function update() external {
        uint256 price0CumNow = pair.price0CumulativeLast();
        uint256 price1CumNow = pair.price1CumulativeLast();
        (, , uint32 tsNow) = pair.getReserves();

        uint32 timeElapsed;
        unchecked { // Relying on wrap-around for TWAP
            timeElapsed = tsNow - blockTimestampLast; 
        } 
        if (timeElapsed == 0) {
            revert ZeroTimeElapsed();
        }
        if (timeElapsed < minUpdateInterval) {
            revert IntervalTooShort();
        }

        uint256 price0Delta;
        uint256 price1Delta;
        unchecked { // Relying on wrap-around for TWAP
            price0Delta = price0CumNow - price0CumulativeLast;
            price1Delta = price1CumNow - price1CumulativeLast;
        }
        price0AverageX112 = price0Delta / timeElapsed;
        price1AverageX112 = price1Delta / timeElapsed;

        price0CumulativeLast = price0CumNow;
        price1CumulativeLast = price1CumNow;
        blockTimestampLast = tsNow;
        initialized = true;

        (uint256 p0, uint256 p1) = _getAlignedPrices();
        emit TwapUpdated(p0, p1, timeElapsed);
    }

    /// @inheritdoc IPriceOracle
    function getPrices() external view override returns (uint256 price0, uint256 price1) {
        if (!initialized) {
            revert NotInitialized();
        }

        return _getAlignedPrices();
    }

    // ============================================
    // Internal Functions
    // ============================================
    /// @notice Converts a UQ112x112 average value to 1e18 precision.
    /// @param avgX112 Average price value in UQ112x112 precision.
    /// @return 1e18-scaled price value.
    function _decodeUQ112x112To1e18(uint256 avgX112) internal pure returns (uint256) {
        return Math.mulDiv(avgX112, PRECISION, Q112);
    }

    /// @notice Returns 1e18-scaled prices aligned to configured `token0` / `token1` order.
    /// @return price0 Latest aligned 1e18-scaled price for configured token0.
    /// @return price1 Latest aligned 1e18-scaled price for configured token1.
    function _getAlignedPrices() internal view returns (uint256, uint256) {
        uint256 price0Avg = _decodeUQ112x112To1e18(price0AverageX112);
        uint256 price1Avg = _decodeUQ112x112To1e18(price1AverageX112);

        // remap pair token order to configured token0/token1 order
        address pairToken0 = pair.token0();
        return pairToken0 == token0 ? (price0Avg, price1Avg) : (price1Avg, price0Avg);
    }
}
