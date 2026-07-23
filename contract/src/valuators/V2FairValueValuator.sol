// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../interfaces/IVenueValuator.sol";
import "../interfaces/IUniswapV2Pair.sol";
import "../adapters/UniswapV2Adapter.sol";
import "../libraries/VaultMath.sol";

/// @title V2FairValueValuator
/// @notice Values a V2 LP position without trusting the pool's current reserve ratio.
/// @dev Oracle-values both reserves, derives fair pool value as twice their geometric mean,
///      then applies the adapter's share of LP supply. Integer operations round conservatively.
contract V2FairValueValuator is IVenueValuator {
    /// @notice Adapter whose LP position is valued.
    UniswapV2Adapter public immutable adapter;

    /// @notice V2 pair that issued the adapter's LP tokens.
    IUniswapV2Pair public immutable pair;

    /// @notice Vault-order token0.
    address public immutable token0;

    /// @notice Vault-order token1.
    address public immutable token1;

    /// @notice Decimal precision of token0.
    uint8 public immutable decimals0;

    /// @notice Decimal precision of token1.
    uint8 public immutable decimals1;

    error ZeroAddress();
    error InvalidPairTokens();
    error InvalidTotalSupply();
    error InvalidReserves();

    /// @param _adapter V2 adapter whose LP position this contract values.
    constructor(address _adapter) {
        if (_adapter == address(0)) revert ZeroAddress();
        adapter = UniswapV2Adapter(_adapter);
        pair = adapter.pair();

        token0 = address(adapter.token0());
        token1 = address(adapter.token1());
        decimals0 = IERC20Metadata(token0).decimals();
        decimals1 = IERC20Metadata(token1).decimals();

        bool directOrder = pair.token0() == token0 && pair.token1() == token1;
        bool reversedOrder = pair.token0() == token1 && pair.token1() == token0;
        if (!directOrder && !reversedOrder) {
            revert InvalidPairTokens();
        }
    }

    /// @inheritdoc IVenueValuator
    function getVenueAdapter() external view override returns (address) {
        return address(adapter);
    }

    /// @inheritdoc IVenueValuator
    function getValueInBase(uint256 price0, uint256 price1) external view override returns (uint256 value) {
        // Read the adapter's LP token balance.
        uint256 lpBalance = pair.balanceOf(address(adapter));
        if (lpBalance == 0) {
            return 0;
        }

        // Read the total LP supply.
        uint256 totalLpBalance = pair.totalSupply();
        if (totalLpBalance == 0) {
            revert InvalidTotalSupply();
        }

        (uint112 pairReserve0, uint112 pairReserve1,) = pair.getReserves();
        uint256 reserve0;
        uint256 reserve1;
        // Convert pair token order into vault token order.
        if (pair.token0() == token0) {
            reserve0 = uint256(pairReserve0);
            reserve1 = uint256(pairReserve1);
        } else {
            reserve0 = uint256(pairReserve1);
            reserve1 = uint256(pairReserve0);
        }

        uint256 reserveValue0 = VaultMath.valueInBase(reserve0, price0, decimals0);
        uint256 reserveValue1 = VaultMath.valueInBase(reserve1, price1, decimals1);
        if (reserveValue0 == 0 || reserveValue1 == 0) {
            revert InvalidReserves();
        }

        // Avoid multiplying both full reserve values; each integer square root rounds down.
        uint256 geometricMean = Math.sqrt(reserveValue0) * Math.sqrt(reserveValue1);
        uint256 fairPoolValue = geometricMean * 2;

        value = Math.mulDiv(fairPoolValue, lpBalance, totalLpBalance);
    }
}
