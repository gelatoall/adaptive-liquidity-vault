# Rebalance Minimal Design

## Goal

Build a minimal rebalance executor for the vault that:
- reuses the existing venue deploy and withdraw flows
- supports multiple registered venue adapters
- accepts an owner-supplied target plan
- accepts a configured strategy that can build target plans
- can move capital from idle balances into one or more venues
- can withdraw all venue liquidity back to idle balances
- stays as an execution layer, not a venue-selection algorithm

## Scope

This version includes:
- owner-only rebalance entrypoint
- `RebalanceTarget[]` plan input
- `IRebalanceStrategy.buildTargets(...)` strategy hook
- `rebalanceWithStrategy(data)` for strategy-driven plan execution
- `minCooldown` and `maxGasPrice` guards for strategy-driven rebalances
- duplicate venue target validation
- unset and disabled venue validation
- full withdrawal of all tracked venue liquidity before redeployment
- deployment into one or more venues after withdrawal
- no-op or revert semantics when no funds can be moved

This version does not include:
- automatic venue recommendation
- TWAP-driven target weighting
- volatility thresholds
- keeper automation
- partial in-place rebalancing
- slippage optimization beyond adapter-level params

Notes:
- rebalance is built on top of `_withdrawFromVenue(...)` and `_deployToVenue(...)`.
- `totalLiquidity` is used only as bookkeeping to know whether any tracked liquidity exists.
- per-venue liquidity is tracked in `venueLiquidity[venueId]`.
- strategy logic should live outside the vault. The vault only asks the configured strategy for a target plan and then validates and executes it.
- manual `rebalance(targets)` remains an owner emergency/manual override and is not gated by strategy cooldown or gas price guards.

## Data Model

The rebalance entrypoint accepts:

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
- `params`: venue-specific adapter params, for example V3 mint limits and deadline

Zero-amount targets are skipped during deployment. They are still checked for duplicate venue ids.

## Venue Id Convention

The current tests and examples use this convention:
- `1`: Uniswap V2
- `2`: Uniswap V3 0.05%
- `3`: Uniswap V3 0.30%
- `4`: Uniswap V3 1.00%

These ids are caller-defined and are not hardcoded protocol semantics. They become meaningful only after the owner registers adapters through `setVenue(...)`.

`IDLE` is not a venue id. To rebalance back to idle, pass an empty target array.

## Public Functions

- `rebalance(targets)`
  - purpose: execute an owner-supplied target allocation
  - behavior: withdraw all venues first, then deploy non-zero targets

- `setStrategy(strategy)`
  - purpose: configure the strategy used by `rebalanceWithStrategy(...)`

- `setRebalanceConfig(minCooldown, maxGasPrice)`
  - purpose: configure strategy-driven rebalance guards

- `rebalanceWithStrategy(data)`
  - purpose: ask the configured strategy to build a target plan, then execute that plan
  - behavior: applies `minCooldown` and `maxGasPrice` before calling the strategy

- `setVenue(venueId, adapter, label, enabled)`
  - purpose: register or update a venue adapter
  - behavior: updating an active venue is blocked

- `deployToVenue(venueId, amount0, amount1, params)`
  - purpose: manually deploy idle funds into a specific venue

- `withdrawFromVenue(venueId, liquidity)`
  - purpose: manually withdraw liquidity from a specific venue

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
1. Owner calls `rebalanceWithStrategy(data)`.
2. Vault checks that a strategy is configured.
3. Vault checks `minCooldown` if it is non-zero.
4. Vault checks `maxGasPrice` if it is non-zero.
5. Vault calls `strategy.buildTargets(address(this), data)`.
6. Vault executes the returned plan through the same internal rebalance flow used by manual `rebalance(targets)`.
7. Vault updates `lastRebalance` only after successful execution.

This stage does not implement venue recommendation. The current mock strategy only returns preset targets for testing.

### rebalance to idle

Call `rebalance` with an empty target array:

```solidity
RebalanceTypes.RebalanceTarget[] memory targets = new RebalanceTypes.RebalanceTarget[](0);
vault.rebalance(targets);
```

Flow:
1. Validate the empty plan.
2. Revert with `NoRebalanceNeeded` if `totalLiquidity == 0`.
3. Withdraw all tracked liquidity from every registered venue.
4. Leave all returned token balances idle in the vault.

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

## Failure Cases

The rebalance layer should revert when:
- a non-owner calls `rebalance`
- a non-owner calls `rebalanceWithStrategy`
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
- direct user redemption remains blocked while any venue has active liquidity
- venue ids are caller-defined identifiers, not enum states
- strategy-built plans must pass the same validation as manual plans
- failed strategy rebalances must not update `lastRebalance`

## Current Test Coverage

Core tests should cover:
- owner-only rebalance
- strategy configuration
- strategy-driven rebalance
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

This list is intentionally focused on the minimal executor and strategy hook. Future TWAP or volatility strategy tests should cover how target plans are produced, not repeat the executor's asset-flow coverage.
