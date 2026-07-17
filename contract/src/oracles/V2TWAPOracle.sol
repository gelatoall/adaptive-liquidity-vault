// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../interfaces/IPriceOracle.sol";
import "../interfaces/IUniswapV2Pair.sol";

/// @title V2TWAPOracle
/// @notice Uniswap V2 TWAP oracle that returns both configured token prices denominated in token0.
/// @dev Converts pair-relative cumulative prices and raw-token decimals into 1e18-scaled token0 values.
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

    /// @notice Configured base token; its returned price is always 1e18.
    address public immutable token0;

    /// @notice Configured quote token whose returned price is denominated in token0.
    address public immutable token1;

    /// @notice Decimals of configured token0.
    uint8 public immutable token0Decimals;

    /// @notice Decimals of configured token1.
    uint8 public immutable token1Decimals;

    /// @notice Minimum number of seconds between valid updates.
    uint32 public immutable minUpdateInterval;

    /// @notice Last recorded cumulative price of pair token0 in pair token1.
    uint256 public price0CumulativeLast;

    /// @notice Last recorded cumulative price of pair token1 in pair token0.
    uint256 public price1CumulativeLast;

    /// @notice Last recorded timestamp from pair reserves.
    uint32 public blockTimestampLast;

    /// @notice Latest TWAP price of pair token0 in pair token1, in UQ112x112 precision.
    uint256 public price0AverageX112;

    /// @notice Latest TWAP price of pair token1 in pair token0, in UQ112x112 precision.
    uint256 public price1AverageX112;

    /// @notice True after the first successful `update`.
    bool public initialized;

    // ============================================
    // Events
    // ============================================
    /// @notice Emitted after a successful TWAP window update.
    /// @param price0 Price of one configured token0 in token0, scaled by 1e18.
    /// @param price1 Price of one configured token1 in token0, scaled by 1e18.
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

    /// @notice Thrown when token decimals cannot be safely scaled.
    error UnsupportedTokenDecimals();

    // ============================================
    // Constructor
    // ============================================
    /// @param _pair Uniswap V2 pair address used for cumulative prices.
    /// @param _token0 Base token used to denominate both returned prices.
    /// @param _token1 Token priced in `_token0` by this oracle.
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

        uint8 decimals0 = IERC20Metadata(_token0).decimals();
        uint8 decimals1 = IERC20Metadata(_token1).decimals();
        if (decimals0 > 77 || decimals1 > 77) {
            revert UnsupportedTokenDecimals();
        }
        token0Decimals = decimals0;
        token1Decimals = decimals1;

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

        (uint256 p0, uint256 p1) = _getBaseDenominatedPrices();
        emit TwapUpdated(p0, p1, timeElapsed);
    }

    /// @inheritdoc IPriceOracle
    function getPrices() external view override returns (uint256 price0, uint256 price1) {
        if (!initialized) {
            revert NotInitialized();
        }

        return _getBaseDenominatedPrices();
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

    /// @notice Converts the pair-relative TWAP into prices denominated in configured token0.
    /// @return price0 Price of one whole token0 in token0, scaled by 1e18.
    /// @return price1 Price of one whole token1 in token0, scaled by 1e18.
    function _getBaseDenominatedPrices() internal view returns (uint256 price0, uint256 price1) {
        // Select the pair price direction that represents configured token1 in configured token0.
        uint256 token1InToken0AverageX112;
        if (pair.token0() == token0) {
            token1InToken0AverageX112 = price1AverageX112;
        } else {
            token1InToken0AverageX112 = price0AverageX112;
        }

        // Remove Q112 encoding while retaining 1e18 precision; the ratio still uses raw token units.
        uint256 rawToken1Price = _decodeUQ112x112To1e18(token1InToken0AverageX112);

        // Convert the raw-unit ratio into whole-token prices in the token0 numeraire.
        price0 = PRECISION;
        price1 = Math.mulDiv(rawToken1Price, 10 ** token1Decimals, 10 ** token0Decimals);
    }
}
