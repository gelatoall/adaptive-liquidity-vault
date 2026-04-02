// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library VaultMath {

    error InvalidPrice();
    error InvalidVaultState();
    error ZeroShares();

    /// @dev Converts a raw token amount into a base-asset-denominated value.
    /// @param amount Raw token amount in the token's smallest unit.
    /// @param price Price of one whole token denominated in the base asset, scaled by 1e18.
    /// @param decimals Decimals used by the token amount.
    /// @return Value denominated in the base asset, scaled by 1e18.
    function valueInBase(
        uint256 amount,
        uint256 price,
        uint8 decimals
    ) internal pure returns (uint256) {
        if (amount == 0) {
            return 0;
        }

        if (price == 0) {
            revert InvalidPrice();
        }

        return (amount * price) / (10 ** decimals);
    }

    /// @dev Sums the base-asset-denominated value of two token balances.
    /// @param amount0 Raw amount of token0 in its smallest unit.
    /// @param price0 Price of one whole token0 denominated in the base asset, scaled by 1e18.
    /// @param decimals0 Decimals used by token0.
    /// @param amount1 Raw amount of token1 in its smallest unit.
    /// @param price1 Price of one whole token1 denominated in the base asset, scaled by 1e18.
    /// @param decimals1 Decimals used by token1.
    /// @return Total value denominated in the base asset, scaled by 1e18.
    function getAssetsTotalValue(
        uint256 amount0,
        uint256 price0,
        uint8 decimals0,
        uint256 amount1,
        uint256 price1,
        uint8 decimals1
    ) internal pure returns (uint256) {
        uint256 value0 = valueInBase(amount0, price0, decimals0);
        uint256 value1 = valueInBase(amount1, price1, decimals1);
        return (value0 + value1);
    }


    /// @dev Calculates shares to mint for a deposit based on the current vault exchange rate.
    /// @param assetsToDeposit Deposit value denominated in the base asset, scaled by 1e18.
    /// @param totalAssets Total vault assets denominated in the base asset, scaled by 1e18.
    /// @param totalShares Total existing vault shares.
    /// @return shares Amount of shares to mint for the deposit.
    function calculateShares(
        uint256 assetsToDeposit,
        uint256 totalAssets,
        uint256 totalShares
    ) internal pure returns (uint256) {
        if (totalAssets == 0 && totalShares == 0) {
            return assetsToDeposit;
        }

        if (totalAssets == 0 || totalShares == 0) {
            revert InvalidVaultState();
        }

        uint256 share = (assetsToDeposit * totalShares) / totalAssets;
        if (share == 0 && assetsToDeposit > 0) {
            revert ZeroShares();
        }

        return share;
    }
}