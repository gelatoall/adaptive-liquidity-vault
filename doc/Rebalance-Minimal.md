# Rebalance Minimal Design

## Goal

Build a minimal rebalance executor for the vault that:
- reuses the existing venue deploy and withdraw flows
- supports multiple registered venue adapters
- accepts an owner-supplied target plan
- accepts a configured strategy that can build target plans
- includes a fixed-weight strategy for simple static venue allocation
- includes a volatility-bucket strategy for selecting among configured allocations
- can move capital from idle balances into one or more venues
- can move deployed capital from one venue allocation into another through withdraw-all-then-redeploy
- can withdraw all venue liquidity back to idle balances
- stays as an execution layer, not a venue-selection algorithm

## Scope

This version includes:
- owner-only rebalance entrypoint
- `RebalanceTarget[]` plan input
- `IRebalanceStrategy.buildTargets(...)` strategy hook
- `rebalanceWithStrategy(data, withdrawalParams)` for strategy-driven plan execution
- configured keeper address for executing strategy-driven rebalances
- `FixedWeightStrategy` for bps-based total-underlying allocation
- `VolatilityBucketStrategy` for LOW, MEDIUM, and HIGH allocation profiles
- `minCooldown`, `minVolatilityDelta`, and `maxGasPrice` guards for strategy-driven rebalances
- optional oracle health check for strategy-driven rebalances
- `PriceChangeVolatilityOracle` as a minimal on-chain volatility source
- `TwapSlippageController` for TWAP-validated V3 add-liquidity minimum amounts
- duplicate venue target validation
- unset and disabled venue validation
- full withdrawal of all tracked venue liquidity before redeployment
- deployment into one or more venues after withdrawal
- optional total-value loss guard after rebalance execution
- pause protection on normal rebalance entrypoints
- emergency exit path that withdraws all venues to idle and pauses the vault
- no-op or revert semantics when no funds can be moved

This version does not include:
- automatic venue recommendation
- TWAP-driven target weighting
- statistical or annualized volatility calculation
- keeper resolver integration or keeper rewards
- partial in-place rebalancing
- strategy-generated withdrawal slippage params

Notes:
- rebalance is built on top of `_withdrawFromVenue(...)` and `_deployToVenue(...)`.
- `totalLiquidity` is used only as bookkeeping to know whether any tracked liquidity exists.
- per-venue liquidity is tracked in `venueLiquidity[venueId]`.
- strategy logic should live outside the vault. The vault only asks the configured strategy for a target plan and then validates and executes it.
- manual `rebalance(targets, withdrawalParams)` remains an owner emergency/manual override and is not gated by strategy cooldown or gas price guards.
- `rebalanceWithStrategy(data, withdrawalParams)` can be called by the owner or configured keeper; the keeper cannot configure strategy, venues, or manual target plans.
- normal `rebalance(...)` and `rebalanceWithStrategy(...)` are blocked while the vault is paused.
- `emergencyExit(...)` is the paused-safe emergency path for pulling venue liquidity back to idle balances.

## Data Model

The rebalance entrypoint accepts target deployment plans and per-venue withdrawal params:

```solidity
struct RebalanceTarget {
    uint256 venueId;
    uint256 amount0;
    uint256 amount1;
    bytes params;
}
```

Field meanings:
- `venueId`: registered venue receiving capital
- `amount0`: raw token0 amount to deploy into that venue
- `amount1`: raw token1 amount to deploy into that venue
- `params`: venue-specific adapter params for deployment, for example V3 mint limits and deadline

```solidity
struct VenueWithdrawalParams {
    uint256 venueId;
    bytes params;
}
```

Withdrawal params are matched by `venueId` during the withdraw-all phase. Venues without a matching entry receive empty params.

Zero-amount targets are skipped during deployment. They are still checked for duplicate venue ids.

## Venue Id Convention

The current tests and examples use this convention:
- `1`: Uniswap V2
- `2`: Uniswap V3 0.05%
- `3`: Uniswap V3 0.30%
- `4`: Uniswap V3 1.00%

These ids are caller-defined and are not hardcoded protocol semantics. They become meaningful only after the owner registers adapters through `setVenue(...)`.

Each V3 fee tier is registered as a separate venue with a separate adapter instance. Reusing one V3 adapter for multiple V3 venue ids would mix per-venue vault accounting because the adapter owns one configured pool and one active position id.

`IDLE` is not a venue id. To rebalance back to idle, pass an empty target array.

## Public Functions

- `rebalance(targets, withdrawalParams)`
  - purpose: execute an owner-supplied target allocation
  - behavior: blocked while the vault is paused
  - behavior: withdraw all venues first, then deploy non-zero targets
  - behavior: forwards matching per-venue withdrawal params during the withdrawal phase
  - behavior: applies the configured value-loss guard after execution

- `setStrategy(strategy)`
  - purpose: configure the strategy used by `rebalanceWithStrategy(...)`

- `setKeeper(keeper)`
  - purpose: configure the non-admin address allowed to execute `rebalanceWithStrategy(...)`
  - behavior: owner-only; rejects the zero address
  - behavior: grants execution permission only, not configuration or emergency permissions

- `setVolatilityOracle(volatilityOracle)`
  - purpose: configure the volatility oracle used by volatility delta guards

- `setRebalanceConfig(minCooldown, minVolatilityDelta, maxGasPrice)`
  - purpose: configure strategy-driven rebalance guards

- `setMaxRebalanceValueLossBps(maxRebalanceValueLossBps)`
  - purpose: configure the maximum total-value loss allowed during rebalance
  - behavior: `0` disables the guard; non-zero values are basis points and apply only to downside loss

- `setOracleHealthCheckEnabled(enabled)`
  - purpose: toggle the minimal oracle health circuit breaker for strategy-driven rebalances
  - behavior: when enabled, strategy-driven rebalances require a configured volatility oracle

- `checkSystemHealth()`
  - purpose: expose coarse vault health for keepers and monitoring
  - behavior: returns `PAUSED` when the vault is paused
  - behavior: returns `ORACLE_STALE` when oracle health checks are enabled but no volatility oracle is configured
  - behavior: returns `NORMAL` otherwise

- `canRebalanceWithStrategy()`
  - purpose: expose whether strategy-driven rebalance currently passes vault-level guards
  - behavior: returns a boolean and human-readable reason for keeper and frontend checks
  - behavior: checks only vault-owned preconditions and does not call `strategy.buildTargets(...)`

- `rebalanceWithStrategy(data, withdrawalParams)`
  - purpose: ask the configured strategy to build a target plan, then execute that plan
  - behavior: blocked while the vault is paused
  - behavior: forwards matching per-venue withdrawal params during the withdrawal phase
  - behavior: applies `minCooldown`, `minVolatilityDelta`, `maxGasPrice`, and oracle health checks before calling the strategy

- `setVenue(venueId, adapter, label, enabled)`
  - purpose: register or update a venue adapter
  - behavior: updating an active venue is blocked

- `deployToVenue(venueId, amount0, amount1, params)`
  - purpose: manually deploy idle funds into a specific venue
  - behavior: blocked while the vault is paused

- `withdrawFromVenue(venueId, liquidity, params)`
  - purpose: manually withdraw liquidity from a specific venue
  - behavior: available while paused so the owner can reduce active venue exposure
  - behavior: forwards venue-specific removal params to the adapter

- `emergencyExit(withdrawalParams)`
  - purpose: withdraw all tracked venue liquidity to idle balances and pause the vault
  - behavior: can be called while already paused and does not execute the normal rebalance target flow

## Manual vs Strategy Rebalance

`rebalance(targets, withdrawalParams)` is the manual owner-supplied execution path. The owner provides the target plan directly, so the vault only validates and executes that plan. This path is useful for manual operations, emergency overrides, and tests. It is owner-only, blocked while paused, and still uses withdrawal params plus the value-loss guard.

`rebalanceWithStrategy(data, withdrawalParams)` is the strategy-driven path. The owner or configured keeper calls the vault, the vault asks the configured strategy to build targets, then executes those targets through the same internal rebalance flow. This path additionally applies strategy guards such as cooldown, gas price, volatility delta, and oracle health checks. The keeper is execution-only and cannot alter strategy, venue, oracle, pause, or emergency settings.

Both paths ultimately reuse the same internal withdraw-all-then-deploy execution logic.

## Core Flow

### strategy-driven rebalance

The vault stores one configured strategy:

```solidity
IRebalanceStrategy public strategy;
```

The strategy interface is intentionally small:

```solidity
function buildTargets(address vault, bytes calldata data)
    external
    view
    returns (RebalanceTypes.RebalanceTarget[] memory targets);
```

Flow:
1. Owner or configured keeper calls `rebalanceWithStrategy(data, withdrawalParams)`.
2. Vault checks that a strategy is configured.
3. Vault checks `minCooldown` if it is non-zero.
4. Vault checks `maxGasPrice` if it is non-zero.
5. Vault requires a configured volatility oracle if `minVolatilityDelta` or oracle health checks are enabled.
6. Vault checks `minVolatilityDelta` if it is non-zero.
7. Vault calls `strategy.buildTargets(address(this), data)`.
8. Vault executes the returned plan through the same internal rebalance flow used by manual `rebalance(targets, withdrawalParams)`, forwarding the caller-supplied withdrawal params to active venues.
9. Vault updates `lastRebalance` only after successful execution.
10. If the volatility guard is enabled, vault updates `lastRebalanceVolatilityBps` only after successful execution.

If `maxRebalanceValueLossBps` is non-zero, strategy-driven rebalance also passes through the same post-execution value-loss guard.

`MockRebalanceStrategy` is used in tests for preset plans. The concrete minimal strategies are `FixedWeightStrategy` and `VolatilityBucketStrategy`.

### fixed-weight strategy

`FixedWeightStrategy` stores owner-configured target venues and weights:

```solidity
struct TargetConfig {
    uint256 venueId;
    uint256 weightBps;
    bytes params;
}
```

Rules:
- `weightBps` uses `10_000` as 100%
- every target weight must be non-zero
- venue ids must be unique
- all weights must sum to `10_000`

`buildTargets(vault, data)` reads the vault's current total underlying `token0` and `token1` amounts through `vault.getTotalUnderlying()`, then splits those amounts by the configured weights. Total underlying means idle balances plus adapter-reported deployed position amounts. The final target receives any integer-division rounding dust so the returned target amounts sum back to the original totals.

Current limitation:
- the strategy uses adapter-reported deployed amounts, not an independent market quote
- it does not compute in-place deltas
- execution still withdraws all tracked venue liquidity before redeploying the target plan

### volatility-bucket strategy

`VolatilityBucketStrategy` stores separate venue weights for `LOW`, `MEDIUM`, and `HIGH` volatility buckets.

The owner configures:
- a volatility oracle
- a low-volatility upper threshold
- a medium-volatility upper threshold
- one valid `TargetConfig[]` allocation for each bucket that may be used
- optional `V3TickCalculations` contracts per V3 venue
- optional `TwapSlippageController` and per-venue slippage params for V3 add-liquidity minimum amounts

For the current minimal version, the strategy reads volatility from `IVolatilityOracle`:

```solidity
uint256 volatilityBps = volatilityOracle.getVolatilityBps();
```

`rebalanceWithStrategy(data, withdrawalParams)` still forwards opaque strategy data, but `VolatilityBucketStrategy` currently ignores that parameter.

Bucket selection is:
- `volatilityBps <= lowThreshold`: `LOW`
- `lowThreshold < volatilityBps <= highThreshold`: `MEDIUM`
- `volatilityBps > highThreshold`: `HIGH`

The selected weights are applied to current total underlying amounts from `vault.getTotalUnderlying()`. As with `FixedWeightStrategy`, the last target receives rounding dust.

`getRecommendedTargets()` exposes the current bucket's configured `TargetConfig[]` for keepers, frontends, and monitoring. This is the multi-venue equivalent of a single `getRecommendedVenue()` helper: it reports the selected venue ids and weights, but it does not calculate token amounts or execute a rebalance.

For venues with a configured `V3TickCalculations` contract, `buildTargets(...)` replaces the stored static params with freshly encoded `UniswapV3Adapter.LiquidityParams`. The generated params use:
- `amount0Min` and `amount1Min` from the configured slippage controller when configured, otherwise zero
- `deadline = block.timestamp`
- `tickLower` and `tickUpper` from `V3TickCalculations.calculateTickRange(volatilityBps)`

This wires volatility-based V3 range selection and TWAP-validated add-liquidity minimum amounts into the strategy layer. The controller checks that the target venue id matches the configured V3 pool, compares current spot price against TWAP, rejects excessive spot/TWAP deviation, and then applies the configured bps haircut to desired token amounts.

The strategy-driven V3 entry path is covered end to end: `VolatilityBucketStrategy` can build a V3 target with dynamic params, `rebalanceWithStrategy(...)` executes that target through the shared rebalance flow, and the registered V3 adapter mints or increases its managed position. The V3 exit path is also covered by forwarding owner-supplied withdrawal params during strategy rebalances.

Current limitations:
- volatility is read from an external oracle contract
- the strategy does not calculate TWAP or statistical volatility itself
- the strategy uses adapter-reported deployed amounts, not an independent market quote
- execution still withdraws all tracked venue liquidity before redeploying the target plan
- strategy-driven withdrawal params are owner-supplied through `rebalanceWithStrategy(data, withdrawalParams)`; automatic remove-side min amount generation remains out of scope
- oracle health checks currently detect missing required oracle configuration, not timestamp-based oracle staleness
- calculated V3 tick bounds are rounded outward to legal `tickSpacing()` values, so the executable range covers the raw strategy range instead of narrowing it

### volatility oracle implementations

`VolatilityBucketStrategy` consumes the generic `IVolatilityOracle` interface. The oracle is responsible for producing `volatilityBps`; the strategy only maps that number to LOW, MEDIUM, or HIGH bucket allocations.

#### PriceChangeVolatilityOracle

`PriceChangeVolatilityOracle` is a simple price-change implementation of `IVolatilityOracle`.

It reads prices from `IPriceOracle.getPrices()` and stores the previous sampled prices. Each `update()` compares the latest prices with the previous snapshot:

```text
change0Bps = abs(price0 - lastPrice0) * 10_000 / lastPrice0
change1Bps = abs(price1 - lastPrice1) * 10_000 / lastPrice1
volatilityBps = max(change0Bps, change1Bps)
```

The first `update()` only initializes `lastPrice0` and `lastPrice1`; later updates compute `volatilityBps`.

This is intentionally a minimal price-change proxy. It does not compute statistical volatility, standard deviation, or annualized volatility.

#### V3TwapVolatilityOracle

`V3TwapVolatilityOracle` is a Uniswap V3 TWAP-backed implementation of `IVolatilityOracle`.

It reads:
- spot price from `pool.slot0()`
- TWAP price from `pool.observe([twapWindow, 0])`

It then reports:

```text
volatilityBps = abs(spotPrice - twapPrice) * 10_000 / twapPrice
```

This makes a one-block spot manipulation less useful for strategy selection because the attacker must also move the TWAP window. It still reports a spot-vs-TWAP deviation, not statistical volatility.

### rebalance to idle

Call `rebalance` with an empty target array:

```solidity
RebalanceTypes.RebalanceTarget[] memory targets = new RebalanceTypes.RebalanceTarget[](0);
AdaptiveLPVault.VenueWithdrawalParams[] memory withdrawalParams =
    new AdaptiveLPVault.VenueWithdrawalParams[](0);
vault.rebalance(targets, withdrawalParams);
```

Flow:
1. Validate the empty plan.
2. Revert with `NoRebalanceNeeded` if `totalLiquidity == 0`.
3. Withdraw all tracked liquidity from every registered venue.
4. Check that share supply did not change and, if enabled, that total value did not fall below the configured loss threshold.
5. Leave all returned token balances idle in the vault.

The value-loss guard is downside-only. It should not reject a positive `totalAssets()` deviation because fees, donations, or price movement can legitimately increase vault value during execution. In tests without such sources, large positive deviations should be treated as a valuation/accounting signal rather than a revert condition.

### emergency exit

`emergencyExit(withdrawalParams)` is separate from normal rebalance.

Flow:
1. Owner calls `emergencyExit(withdrawalParams)`.
2. Vault iterates all registered venues.
3. For each venue with tracked liquidity, vault forwards matching withdrawal params to the adapter and removes all tracked liquidity.
4. Vault pauses normal operations.
5. Users can still redeem after the emergency exit because `redeem` is not gated by `whenNotPaused`.

This path intentionally bypasses target validation and redeployment. It is for reducing venue exposure during an incident, not for normal allocation changes.

### rebalance to one venue

Call `rebalance` with one target:

```solidity
targets[0] = RebalanceTypes.RebalanceTarget({
    venueId: 1,
    amount0: amount0,
    amount1: amount1,
    params: bytes("")
});
```

Flow:
1. Validate the venue id.
2. Sum required token amounts.
3. Withdraw all existing venue liquidity first.
4. Check idle balances after withdrawal.
5. Deploy the requested amounts into the target venue.

### rebalance to multiple venues

Call `rebalance` with multiple targets:

```solidity
targets[0] = RebalanceTypes.RebalanceTarget({
    venueId: 1,
    amount0: v2Amount0,
    amount1: v2Amount1,
    params: bytes("")
});

targets[1] = RebalanceTypes.RebalanceTarget({
    venueId: 2,
    amount0: v3Amount0,
    amount1: v3Amount1,
    params: abi.encode(amount0Min, amount1Min, deadline)
});
```

Flow:
1. Reject duplicate venue ids.
2. Validate every non-zero target.
3. Sum total required `amount0` and `amount1`.
4. Withdraw all current venues back to idle balances.
5. Check the idle balances can cover the full plan.
6. Deploy each non-zero target.

## Why Withdraw All First

The current implementation uses a simple two-phase model:
- phase 1: pull all tracked venue liquidity back to idle
- phase 2: deploy the desired target plan

This avoids complex in-place delta accounting between venues. It is less gas efficient, but easier to reason about and test. A later strategy layer can optimize by calculating deltas and only moving the changed capital.

Because strategies build targets from `getTotalUnderlying()`, they can request a new allocation even when capital is already deployed. The vault then realizes that plan by withdrawing all tracked venue liquidity to idle first, checking the resulting idle balances, and deploying the requested target amounts.

## Failure Cases

The rebalance layer should revert when:
- a non-owner calls `rebalance`
- a caller that is neither owner nor keeper calls `rebalanceWithStrategy`
- `rebalanceWithStrategy` is called before a strategy is configured
- `rebalanceWithStrategy` is called during cooldown
- `rebalanceWithStrategy` is called above the configured gas price limit
- the vault is already idle and the target plan requires no funds
- a target venue id is duplicated
- a non-zero target points to an unset venue
- a non-zero target points to a disabled venue
- the target plan requires more `token0` or `token1` than available after withdrawals
- a venue withdrawal fails inside its adapter
- a venue deployment fails inside its adapter

## Invariants

These conditions should always hold:
- rebalance does not implement a separate funds-flow path
- rebalance only wraps existing deploy and withdraw helpers
- per-venue liquidity is updated through the same path as manual venue operations
- total tracked liquidity equals the sum of tracked liquidity changes applied by venue operations
- direct user redemption withdraws the caller's proportional tracked venue liquidity
- venue ids are caller-defined identifiers, not enum states
- strategy-built plans must pass the same validation as manual plans
- failed strategy rebalances must not update `lastRebalance`

## Current Test Coverage

Core tests should cover:
- owner-only rebalance
- keeper execution of strategy-driven rebalance
- unauthorized strategy-driven rebalance rejection
- strategy configuration
- strategy-driven rebalance
- fixed-weight strategy target generation
- fixed-weight strategy execution through `rebalanceWithStrategy`
- fixed-weight strategy moving deployed capital into a new venue allocation
- volatility bucket selection and target generation
- volatility-selected plan execution through `rebalanceWithStrategy`
- strategy-driven deployment into a V3 venue with dynamic tick and slippage params
- strategy-driven withdrawal from an active V3 venue with forwarded withdrawal params
- volatility-selected strategy moving deployed capital into a new venue allocation
- strategy cooldown guard
- strategy max gas price guard
- strategy returning an unset venue
- idle-to-V2 deployment
- idle-to-V3 deployment
- deployment to multiple venues in one plan
- withdrawal of multiple venues back to idle
- duplicate venue target rejection
- unset venue target rejection
- disabled venue target rejection
- insufficient balance rejection
- no-liquidity idle rebalance rejection

This list is intentionally focused on the minimal executor and strategy hook. Future oracle-backed volatility tests should focus on signal production rather than repeat the executor's asset-flow coverage.
