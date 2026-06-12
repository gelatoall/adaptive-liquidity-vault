# AdaptiveLPVault Minimal Design

## Goal

Build a minimal two-asset vault that:
- accepts deposits of `token0` and `token1`
- mints vault shares based on deposit value
- allows users to redeem shares for idle underlying balances
- tracks total vault assets across idle balances and registered venue positions
- supports multiple venue adapters through a simple venue registry
- supports owner-supplied rebalance plans across registered venues

## Scope

This version includes:
- `deposit`
- `redeem`
- `totalAssets`
- share minting and burning
- oracle-based asset valuation
- venue registration through `setVenue(...)`
- manual venue deployment and withdrawal through `deployToVenue(...)` and `withdrawFromVenue(...)`
- multi-venue asset accounting
- a minimal owner-only rebalance executor that withdraws all venues first, then deploys according to a target plan

This version does not include:
- automatic strategy selection
- autonomous keepers
- threshold-based rebalance conditions
- automatic withdrawal during user redemption
- deposit ratio optimization
- the full ERC4626 interface

Notes:
- the vault depends on `IPriceOracle` for prices
- `MockPriceOracle` is a test helper that exposes `setPrices(...)`
- `IPriceOracle` itself is read-only and only defines `getPrices()`
- a production version should replace the mock oracle with a real oracle implementation
- TWAP implementation details are documented in `doc/TWAPOracle-Minimal.md`
- rebalance details are documented in `doc/Rebalance-Minimal.md`

## State

The vault stores:
- `token0` address
- `token1` address
- `token0` decimals
- `token1` decimals
- oracle address
- venue configs by `venueId`
- registered venue ids for iteration
- per-venue tracked liquidity
- total tracked liquidity across all venues
- ERC20 share supply and balances

Venue state:
- `venues[venueId]` stores the adapter, enabled flag, and optional label
- `venueRegistered[venueId]` tracks whether a venue id has been registered
- `venueIds` is used to iterate all registered venues in `totalAssets()` and withdrawal flows
- `venueLiquidity[venueId]` tracks liquidity reported by each adapter
- `totalLiquidity` is bookkeeping only; liquidity units can differ across venues and should not be treated as asset value

Current test and example convention:
- `1`: Uniswap V2
- `2`: Uniswap V3 0.05%
- `3`: Uniswap V3 0.30%
- `4`: Uniswap V3 1.00%

These ids are not hardcoded protocol semantics. They become meaningful only after the owner registers adapters through `setVenue(...)`. `IDLE` is not a venue id; rebalance-to-idle is represented by an empty target array.

## Public Functions

- `constructor(name, symbol, token0, token1, decimals0, decimals1)`
  - purpose: initialize share token metadata, underlying tokens, and decimals

- `setOracle(oracle)`
  - purpose: set the oracle used to read `token0` and `token1` prices

- `setVenue(venueId, adapter, label, enabled)`
  - purpose: register or update a venue adapter
  - behavior: updating an existing venue is blocked while that venue has tracked liquidity or adapter-reported position state

- `totalAssets()`
  - purpose: return the combined value of idle balances and all adapter-reported venue positions
  - returns: `uint256 assets`

- `deposit(amount0, amount1)`
  - purpose: transfer tokens into the vault and mint shares to the depositor
  - returns: `uint256 shares`

- `redeem(shares)`
  - purpose: burn shares and return proportional idle token balances
  - behavior: reverts while any registered venue still has tracked or adapter-reported active position state
  - returns: `uint256 amount0Out, uint256 amount1Out`

- `deployToVenue(venueId, amount0, amount1, params)`
  - purpose: deploy idle funds into a registered venue adapter
  - returns: `uint256 liquidity`

- `withdrawFromVenue(venueId, liquidity)`
  - purpose: withdraw deployed liquidity from a specific venue back into idle balances
  - returns: `uint256 amount0Out, uint256 amount1Out`

- `rebalance(targets)`
  - purpose: execute an owner-supplied multi-venue target plan
  - behavior: withdraws all tracked venue liquidity first, then deploys non-zero targets

## Core Flows

### deposit

1. Reject if both deposit amounts are zero.
2. Require an oracle.
3. Read `totalAssets()` before the deposit.
4. Read `totalSupply()` before the deposit.
5. Convert the deposit amounts into a single base-denominated value using `VaultMath`.
6. Calculate shares to mint using `VaultMath.calculateShares`.
7. Transfer `token0` and `token1` from the user into the vault.
8. Mint shares to the depositor.

### redeem

1. Reject if `shareToRedeem` is zero.
2. Revert if `shareToRedeem` exceeds the caller's balance.
3. Revert if any venue still has tracked liquidity or adapter-reported position state.
4. Read `totalSupply()` before burning.
5. Read idle `token0` and `token1` balances held by the vault.
6. Compute the proportional idle token amounts owed to the user.
7. Burn the user's shares.
8. Transfer `token0` and `token1` to the user.

### totalAssets

1. Require an oracle.
2. Read idle `token0` and `token1` balances held by the vault.
3. Iterate all registered `venueIds`.
4. For each configured adapter, call `adapter.getPositionValue()`.
5. Sum idle balances and deployed venue amounts.
6. Convert the combined token amounts into base-denominated value using oracle prices.

### deployToVenue

1. Require the venue to be registered and configured with an adapter.
2. Require the venue to be enabled.
3. Temporarily approve the adapter to pull the requested token amounts.
4. Call `adapter.addLiquidity(amount0, amount1, params)`.
5. Increase `venueLiquidity[venueId]` and `totalLiquidity`.
6. Reset adapter allowances back to zero.

### withdrawFromVenue

1. Require the venue to be registered and configured with an adapter.
2. Reject zero liquidity.
3. Require enough tracked liquidity for that venue.
4. Call `adapter.removeLiquidity(liquidity)`.
5. Decrease `venueLiquidity[venueId]` and `totalLiquidity`.

### rebalance

1. Reject duplicate venue targets.
2. Validate every non-zero target points to a registered and enabled venue.
3. Sum required `amount0` and `amount1` across the target plan.
4. If the vault is already idle and the plan requires no funds, revert `NoRebalanceNeeded`.
5. Withdraw all tracked venue liquidity back to idle balances.
6. Require idle balances to cover the target plan.
7. Deploy each non-zero target into its requested venue.

An empty target array means "withdraw all venues to idle". It only succeeds if there is tracked liquidity to withdraw.

## Failure Cases

The vault should revert when:
- both deposit amounts are zero
- the oracle is not configured
- a non-zero deposit would mint zero shares
- `redeem` is called with zero shares
- `redeem` is called with more shares than the user owns
- `redeem` is called while any venue is active
- a non-owner calls owner-only functions
- a venue operation references an unset venue
- a venue operation references a disabled venue
- a venue withdrawal requests zero liquidity
- a venue withdrawal exceeds tracked liquidity
- a venue update is attempted while that venue has active liquidity
- a rebalance plan contains duplicate venue ids
- a rebalance plan requires more token balance than available after withdrawals
- rebalance cannot move any funds

## Invariants

These conditions should always hold:
- the initial deposit mints shares equal to deposit value
- non-zero deposits must not mint zero shares
- `totalAssets()` reflects idle balances plus adapter-reported position values across all registered venues
- redeeming shares reduces the user's share balance and total share supply
- users can only redeem idle balances
- per-venue liquidity and total tracked liquidity stay in sync with deploy and withdraw flows
- rebalance reuses the same deploy and withdraw helpers as manual venue operations

## Test Plan

Vault basics:
- initial deposit mints shares equal to deposit value
- subsequent deposit mints proportional shares
- deposit transfers tokens into the vault
- `totalAssets()` returns the combined vault value
- deposit reverts when both amounts are zero
- deposit reverts when share calculation returns zero shares
- redeem burns shares and returns underlying assets
- redeem reverts when shares is zero
- redeem reverts when the user has insufficient shares

Venue integration:
- `setVenue(...)` registers V2 and V3 adapters
- deployment reverts when venue is unset or disabled
- deployment tracks per-venue liquidity
- withdrawal reduces per-venue liquidity and total liquidity
- `totalAssets()` includes idle balances and all venue positions
- redeem reverts while any venue has active liquidity
- venue updates are blocked while the target venue is active

Rebalance coverage:
- rebalance remains owner-only
- rebalance can deploy to V2
- rebalance can deploy to V3
- rebalance can split capital across multiple venues
- rebalance can withdraw all venues back to idle
- rebalance rejects duplicate venue targets
- rebalance rejects plans that exceed available balances
- rebalance reverts when there is no liquidity to move

This list is intentionally high-level. Concrete unit tests may expand each topic into symmetric branches, invalid-input paths, and edge cases.
