# AdaptiveLPVault Minimal Design

## Goal

Build a minimal idle two-asset vault that:
- accepts deposits of `token0` and `token1`
- mints vault shares based on the deposit value
- allows users to redeem shares for the underlying tokens
- tracks total vault assets using internal balances and an external price oracle

## Scope

This version includes:
- `deposit`
- `redeem`
- `totalAssets`
- share minting and burning
- oracle-based price reads for testing

This version does not include:
- Uniswap V2 or V3 adapters
- rebalancing
- fees
- the full ERC4626 interface
- deposit ratio optimization

Notes:
- the vault depends on `IPriceOracle` for prices.
- `MockPriceOracle` is a test helper that exposes `setPrices(...)`.
- `IPriceOracle` itself is read-only and only defines `getPrices()`.
- A production version should replace the mock oracle with a real oracle implementation.

## State

The vault stores:
- `token0` address
- `token1` address
- `token0` decimals
- `token1` decimals
- oracle address, which provides `token0` and `token1` prices
- ERC20 share supply and balances

Notes:
- Shares are represented as an ERC20 token.
- All asset values are normalized into a base-denominated `1e18` value before share calculation.

## Public Functions

- `constructor(token0, token1, decimals0, decimals1)`
  - purpose: initialize token addresses and decimals

- `setOracle(oracle)`
  - purpose: set the oracle used to read `token0` and `token1` prices

- `totalAssets()`
  - purpose: return the combined value of the vault's current token balances
  - returns: `uint256 assets`

- `deposit(amount0, amount1)`
  - purpose: transfer tokens into the vault and mint shares to the depositor
  - returns: `uint256 shares`

- `redeem(shares)`
  - purpose: burn shares and return the proportional underlying token amounts
  - returns: `uint256 amount0Out, uint256 amount1Out`

## Core Flows

### deposit

1. Reject if both deposit amounts are zero.
2. Read `totalAssets()` before the deposit.
3. Read `totalSupply()` before the deposit.
4. Convert the deposit amounts into a single base-denominated value using `VaultMath`.
5. Calculate shares to mint using `VaultMath.calculateShares`.
6. Transfer `token0` and `token1` from the user into the vault.
7. Mint shares to the depositor.

### redeem

1. Reject if `shareToRedeem` is zero.
2. Revert if `shareToRedeem` exceeds the caller's balance.
3. Read `totalSupply()` before burning.
4. Read the current `token0` and `token1` balances held by the vault.
5. Compute the proportional token amounts owed to the user.
6. Burn the user's `shareToRedeem`.
7. Transfer `token0` and `token1` to the user.

### totalAssets

1. Read the current `token0` balance held by the vault.
2. Read the current `token1` balance held by the vault.
3. Read `price0` and `price1` from the configured oracle.
4. Convert both balances into base-denominated values using the oracle prices.
5. Return the combined vault value.

## Failure Cases

The vault should revert when:
- both deposit amounts are zero
- the oracle is not configured
- a non-zero deposit asset has a zero price
- the vault is in an invalid state for share calculation
- a non-zero deposit would mint zero shares
- `redeem` is called with zero shares
- `redeem` is called with more shares than the user owns

## Invariants

These conditions should always hold:
- the initial deposit mints shares equal to the deposit value
- non-zero deposits must not mint zero shares
- `totalAssets()` reflects the vault's current token balances and oracle prices
- redeeming shares reduces the user's share balance and the total share supply

## Test Plan

The first test set should cover:
- initial deposit mints shares equal to deposit value
- subsequent deposit mints proportional shares
- deposit transfers tokens into the vault
- `totalAssets()` returns the combined vault value
- deposit reverts when both amounts are zero
- deposit reverts when share calculation returns zero shares
- redeem burns shares and returns underlying assets
- redeem reverts when shares is zero
- redeem reverts when the user has insufficient shares
- redeem returns `token0` and `token1` in proportion to the redeemed shares

This list is intentionally high-level. Concrete unit tests may expand each topic into symmetric branches, invalid-input paths, and edge cases.
