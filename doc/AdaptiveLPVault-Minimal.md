# AdaptiveLPVault Minimal Design

## Goal

Build a minimal two-asset vault that:
- accepts deposits of `token0` and `token1`
- mints vault shares based on deposit value
- allows users to redeem shares for proportional idle balances and deployed venue liquidity
- tracks total vault assets across idle balances and registered venue positions
- supports multiple venue adapters through a simple venue registry
- supports owner-supplied rebalance plans across registered venues
- supports strategy-built rebalance plans through a configured strategy

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
- optional rebalance value-loss guard using `maxRebalanceValueLossBps`
- strategy-driven rebalance through `IRebalanceStrategy`
- fixed-weight and volatility-bucket total-underlying allocation strategies
- reentrancy protection on user and capital-moving entrypoints
- owner-controlled pause and unpause
- emergency exit that withdraws all venue liquidity to idle balances and pauses normal operations

This version does not include:
- automatic dynamic strategy selection
- autonomous keepers
- threshold-based rebalance conditions
- automatic TWAP-based slippage calculation
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
- configured rebalance strategy
- strategy rebalance cooldown and gas price guard config
- paused/unpaused state inherited from OpenZeppelin `Pausable`

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

- `setPriceOracle(priceOracle)`
  - purpose: set the price oracle used to read `token0` and `token1` prices

- `setVolatilityOracle(volatilityOracle)`
  - purpose: set the volatility oracle used by strategy rebalance guards

- `setVenue(venueId, adapter, label, enabled)`
  - purpose: register or update a venue adapter
  - behavior: updating an existing venue is blocked while that venue has tracked liquidity or adapter-reported position state

- `totalAssets()`
  - purpose: return the combined value of idle balances and all adapter-reported venue positions
  - returns: `uint256 assets`

- `getTotalUnderlying()`
  - purpose: return raw `token0` and `token1` amounts across idle balances and adapter-reported venue positions
  - returns: `uint256 total0, uint256 total1`

- `deposit(amount0, amount1)`
  - purpose: transfer tokens into the vault and mint shares to the depositor
  - behavior: blocked while the vault is paused
  - returns: `uint256 shares`

- `redeem(shares, withdrawalParams)`
  - purpose: burn shares and return proportional token balances across idle assets and active venue positions
  - behavior: withdraws the caller's proportional tracked liquidity from each active venue before transferring tokens
  - behavior: forwards matching per-venue withdrawal params to adapters; venues without a matching entry receive empty params
  - returns: `uint256 amount0Out, uint256 amount1Out`

- `deployToVenue(venueId, amount0, amount1, params)`
  - purpose: deploy idle funds into a registered venue adapter
  - behavior: owner-only and blocked while the vault is paused
  - returns: `uint256 liquidity`

- `withdrawFromVenue(venueId, liquidity, params)`
  - purpose: withdraw deployed liquidity from a specific venue back into idle balances
  - signature: `withdrawFromVenue(venueId, liquidity, params)`
  - behavior: owner-only and available while paused so the owner can reduce venue exposure
  - behavior: forwards venue-specific removal params to the adapter
  - returns: `uint256 amount0Out, uint256 amount1Out`

- `rebalance(targets, withdrawalParams)`
  - purpose: execute an owner-supplied multi-venue target plan
  - behavior: owner-only and blocked while the vault is paused
  - behavior: withdraws all tracked venue liquidity first, then deploys non-zero targets
  - behavior: forwards matching per-venue withdrawal params during the withdrawal phase; `targets[i].params` controls deployment into the new venue

- `setStrategy(strategy)`
  - purpose: configure the strategy used by `rebalanceWithStrategy(...)`

- `setRebalanceConfig(minCooldown, minVolatilityDelta, maxGasPrice)`
  - purpose: configure cooldown, volatility delta, and gas price guards for strategy-driven rebalances

- `setMaxRebalanceValueLossBps(maxRebalanceValueLossBps)`
  - purpose: configure the maximum total-value loss allowed during rebalance
  - behavior: `0` disables the guard; non-zero values are interpreted in basis points
  - behavior: only limits downside loss and does not reject value increases

- `rebalanceWithStrategy(data)`
  - purpose: ask the configured strategy for a target plan and execute it
  - behavior: owner-only and blocked while the vault is paused
  - behavior: applies strategy guards, then reuses the same rebalance execution path

- `pause()`
  - purpose: pause deposits, venue deployment, and normal rebalance operations
  - behavior: owner-only; redemptions and direct venue withdrawals remain available

- `unpause()`
  - purpose: resume deposits, venue deployment, and normal rebalance operations
  - behavior: owner-only

- `emergencyExit(withdrawalParams)`
  - purpose: withdraw all tracked venue liquidity back to idle balances and pause the vault
  - behavior: owner-only; can be called while already paused; forwards matching per-venue withdrawal params

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

Deposits are disabled while the vault is paused.

### redeem

1. Reject if `shareToRedeem` is zero.
2. Revert if `shareToRedeem` exceeds the caller's balance.
3. Read `totalSupply()` before burning.
4. Read idle `token0` and `token1` balances held by the vault.
5. Compute the proportional idle token amounts owed to the user.
6. Iterate registered venues and withdraw `shareToRedeem / totalSupplyBefore` of each tracked venue liquidity amount.
7. For each venue withdrawal, forward the matching `VenueWithdrawalParams.params` entry to the adapter; if no entry matches the venue id, forward empty params.
8. Add the tokens returned from venue withdrawals to the user's output amounts.
9. Burn the user's shares.
10. Transfer `token0` and `token1` to the user.

When `shareToRedeem == totalSupplyBefore`, redemption withdraws all tracked liquidity from each active venue to avoid leaving rounding dust.

Redemptions remain available while the vault is paused so users can exit.

### totalAssets

1. Require an oracle.
2. Read total underlying token amounts through `_getTotalUnderlying()`.
3. Convert the combined token amounts into base-denominated value using oracle prices.

### getTotalUnderlying

1. Read idle `token0` and `token1` balances held by the vault.
2. Iterate all registered `venueIds`.
3. For each configured adapter, call `adapter.getPositionValue()`.
4. Sum idle balances and deployed venue amounts.

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
4. Call `adapter.removeLiquidity(liquidity, params)`.
5. Decrease `venueLiquidity[venueId]` and `totalLiquidity`.

User redemptions can pass per-venue withdrawal params through `redeem(shares, withdrawalParams)`. Manual rebalances can pass per-venue withdrawal params through `rebalance(targets, withdrawalParams)`. Strategy-driven rebalances still use empty withdrawal params in this entrypoint; strategy-side withdrawal params are a separate interface design task.

### rebalance

1. Reject duplicate venue targets.
2. Validate every non-zero target points to a registered and enabled venue.
3. Sum required `amount0` and `amount1` across the target plan.
4. If the vault is already idle and the plan requires no funds, revert `NoRebalanceNeeded`.
5. Withdraw all tracked venue liquidity back to idle balances.
6. Require idle balances to cover the target plan.
7. Deploy each non-zero target into its requested venue.
8. Verify share supply did not change.
9. If `maxRebalanceValueLossBps` is non-zero, verify post-rebalance `totalAssets()` did not fall below the configured loss threshold.

An empty target array means "withdraw all venues to idle". It only succeeds if there is tracked liquidity to withdraw.

The value-loss guard is downside-only. A rebalance that increases `totalAssets()` is allowed, but large positive deviations without fees, donations, or price movement should be investigated in tests or monitoring as a possible accounting issue.

### rebalanceWithStrategy

1. Require a configured strategy.
2. Enforce `minCooldown`, `minVolatilityDelta`, and `maxGasPrice` when configured.
3. Call `strategy.buildTargets(address(this), data)`.
4. Execute the returned targets through the same internal rebalance flow.
5. Update `lastRebalance` only after successful execution.
6. If the volatility guard is enabled, update `lastRebalanceVolatilityBps` after successful execution.

The current concrete strategies are:
- `FixedWeightStrategy`, which applies one configured set of venue weights
- `VolatilityBucketStrategy`, which selects LOW, MEDIUM, or HIGH venue weights from an `IVolatilityOracle` value

Both strategies operate on total vault underlying amounts reported by `getTotalUnderlying()`, meaning idle balances plus adapter-reported deployed position amounts. The vault execution path still withdraws all tracked venue liquidity before redeploying the returned plan. `VolatilityBucketStrategy` reads volatility from a configured oracle; `rebalanceWithStrategy(data)` still forwards opaque data for other strategy implementations, but the current volatility bucket strategy does not use it.

The current concrete volatility oracle is `PriceChangeVolatilityOracle`. It reads `price0` and `price1` from an `IPriceOracle`, compares them with the previous sampled prices, and reports the larger absolute price change in basis points. This is a simple price-change proxy, not a statistical volatility model.

### pause and emergency exit

The vault uses OpenZeppelin `Pausable` as an emergency operations switch.

Paused state blocks normal capital entry and allocation operations:
- `deposit`
- `deployToVenue`
- `rebalance`
- `rebalanceWithStrategy`

Paused state does not block exit-oriented operations:
- `redeem`
- `withdrawFromVenue`
- `emergencyExit`

`emergencyExit(withdrawalParams)` is an owner-only safety path. It iterates all registered venues, withdraws every venue with tracked liquidity, forwards matching withdrawal params to each adapter, and then pauses the vault. It intentionally does not call the normal `_rebalance(...)` path because emergency exit should not be blocked by normal rebalance semantics such as target validation or `NoRebalanceNeeded`.

## Failure Cases

The vault should revert when:
- both deposit amounts are zero
- the oracle is not configured
- a non-zero deposit would mint zero shares
- `redeem` is called with zero shares
- `redeem` is called with more shares than the user owns
- `deposit`, `deployToVenue`, `rebalance`, or `rebalanceWithStrategy` is called while paused
- a non-owner calls `pause`, `unpause`, `emergencyExit`, or owner-only capital management functions
- a non-owner calls owner-only functions
- a venue operation references an unset venue
- a venue operation references a disabled venue
- a venue withdrawal requests zero liquidity
- a venue withdrawal exceeds tracked liquidity
- a venue update is attempted while that venue has active liquidity
- a rebalance plan contains duplicate venue ids
- a rebalance plan requires more token balance than available after withdrawals
- rebalance cannot move any funds
- strategy-driven rebalance is called before a strategy is configured
- strategy-driven rebalance violates cooldown, volatility delta, or max gas price guards
- volatility delta guard is enabled before a volatility oracle is configured

## Invariants

These conditions should always hold:
- the initial deposit mints shares equal to deposit value
- non-zero deposits must not mint zero shares
- `totalAssets()` reflects idle balances plus adapter-reported position values across all registered venues
- redeeming shares reduces the user's share balance and total share supply
- redeeming shares withdraws the caller's proportional tracked liquidity from active venues
- per-venue liquidity and total tracked liquidity stay in sync with deploy and withdraw flows
- rebalance reuses the same deploy and withdraw helpers as manual venue operations
- strategy-built plans pass through the same validation as manual rebalance plans
- failed strategy-driven rebalances do not update `lastRebalance`

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
- full redeem withdraws all active V2, V3, and multi-venue liquidity
- partial redeem withdraws only the caller's pro-rata active V2, V3, and multi-venue liquidity
- redeem forwards per-venue withdrawal params to V2 and V3 adapters
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
- strategy-driven rebalance executes a fixed-weight plan
- strategy-driven rebalance executes a volatility-selected plan
- strategy-driven rebalance can move already-deployed capital from one venue to another
- strategy-driven rebalance enforces cooldown and max gas price guards

This list is intentionally high-level. Concrete unit tests may expand each topic into symmetric branches, invalid-input paths, and edge cases.
