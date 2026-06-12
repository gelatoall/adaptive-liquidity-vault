# Rebalance Minimal Design

## Goal

Build a minimal rebalance executor for the vault that:
- reuses the existing venue deploy and withdraw flows
- supports multiple registered venue adapters
- accepts an owner-supplied target plan
- can move capital from idle balances into one or more venues
- can withdraw all venue liquidity back to idle balances
- stays as an execution layer, not an autonomous strategy engine

## Scope

This version includes:
- owner-only rebalance entrypoint
- `RebalanceTarget[]` plan input
- duplicate venue target validation
- unset and disabled venue validation
- full withdrawal of all tracked venue liquidity before redeployment
- deployment into one or more venues after withdrawal
- no-op or revert semantics when no funds can be moved

This version does not include:
- automatic venue recommendation
- TWAP-driven target weighting
- volatility thresholds
- cooldown checks
- max gas price checks
- keeper automation
- partial in-place rebalancing
- slippage optimization beyond adapter-level params

Notes:
- rebalance is built on top of `_withdrawFromVenue(...)` and `_deployToVenue(...)`.
- `totalLiquidity` is used only as bookkeeping to know whether any tracked liquidity exists.
- per-venue liquidity is tracked in `venueLiquidity[venueId]`.
- strategy and quote logic should live outside this minimal executor.

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

- `setVenue(venueId, adapter, label, enabled)`
  - purpose: register or update a venue adapter
  - behavior: updating an active venue is blocked

- `deployToVenue(venueId, amount0, amount1, params)`
  - purpose: manually deploy idle funds into a specific venue

- `withdrawFromVenue(venueId, liquidity)`
  - purpose: manually withdraw liquidity from a specific venue

## Core Flow

### rebalance to idle

Call `rebalance` with an empty target array:

```solidity
AdaptiveLPVault.RebalanceTarget[] memory targets = new AdaptiveLPVault.RebalanceTarget[](0);
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
targets[0] = AdaptiveLPVault.RebalanceTarget({
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
targets[0] = AdaptiveLPVault.RebalanceTarget({
    venueId: 1,
    amount0: v2Amount0,
    amount1: v2Amount1,
    params: bytes("")
});

targets[1] = AdaptiveLPVault.RebalanceTarget({
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

## Current Test Coverage

Core tests should cover:
- owner-only rebalance
- idle-to-V2 deployment
- idle-to-V3 deployment
- deployment to multiple venues in one plan
- withdrawal of multiple venues back to idle
- duplicate venue target rejection
- unset venue target rejection
- disabled venue target rejection
- insufficient balance rejection
- no-liquidity idle rebalance rejection

This list is intentionally focused on the minimal executor. Future strategy-layer tests should cover how target plans are produced, not repeat the executor's asset-flow coverage.
