# Rebalance Minimal Design

## Goal

Build a minimal rebalance layer for the vault that:
- reuses the existing deploy and withdraw flows
- supports a single active venue label set: `IDLE`, `DEPLOYED_V2`, or `DEPLOYED_V3`
- moves from idle balances into the configured V2 or V3 adapter when requested
- withdraws all deployed liquidity back to idle balances when requested
- keeps rebalance as a thin owner-only strategy wrapper, not a new funds-flow implementation

## Scope

This version includes:
- a single venue state machine with V2 and V3 deployed labels
- owner-only rebalance entrypoint
- idle-to-V2 or idle-to-V3 deployment using the vault's current token balances
- deployed-to-idle withdrawal using the tracked deployed liquidity
- no-op or revert semantics when no funds can be moved
- adapter switch protection while deployed liquidity is active

This version does not include:
- multi-venue routing
- partial rebalance
- threshold-based autonomous triggering
- keeper automation
- slippage optimization
- price-driven target weighting

Notes:
- rebalance is built on top of the existing `deployToVenue(...)` and `withdrawFromVenue(...)` flows.
- the minimal implementation treats `totalLiquidity == 0` as idle and `totalLiquidity > 0` as deployed.
- V3 is handled as a second deployed label in the same minimal state machine; multi-venue routing is still out of scope.

## State

The rebalance layer relies on:
- vault idle `token0` balance
- vault idle `token1` balance
- tracked deployed LP liquidity
- configured adapter

State interpretation:
- `totalLiquidity == 0` means the vault is effectively idle
- `totalLiquidity > 0` means the vault has an active deployed position
- the rebalance target label distinguishes whether the deploy path should use V2-style empty params or V3-style encoded params

## Public Functions

- `rebalance(targetVenue)`
  - purpose: move the vault between idle and deployed V2/V3 states

- `setAdapter(adapter)`
  - purpose: configure the single active venue adapter
  - behavior: revert if deployed liquidity already exists

- `deployToVenue(amount0, amount1, params)`
  - purpose: manually deploy idle funds into the configured adapter

- `withdrawFromVenue(liquidity)`
  - purpose: manually withdraw deployed liquidity back into idle balances

## Core Flows

### rebalance to V2

1. Read the vault's current idle `token0` balance.
2. Read the vault's current idle `token1` balance.
3. Revert if both balances are zero.
4. Call the existing internal deploy flow with the full idle balances and empty params.
5. Update tracked deployed liquidity through the shared deploy path.

### rebalance to V3

1. Read the vault's current idle `token0` balance.
2. Read the vault's current idle `token1` balance.
3. Revert if both balances are zero.
4. Call the existing internal deploy flow with the full idle balances and V3-encoded params.
5. Update tracked deployed liquidity through the shared deploy path.

### rebalance to IDLE

1. Read tracked deployed liquidity.
2. Revert if tracked liquidity is zero.
3. Call the existing internal withdraw flow with the full deployed liquidity.
4. Idle balances increase by the withdrawn token amounts.
5. Tracked deployed liquidity returns to zero.

### adapter switch protection

1. Read tracked deployed liquidity.
2. Revert if liquidity is non-zero.
3. Allow the adapter to be changed only when the vault is truly idle.

## Failure Cases

The rebalance layer should revert when:
- a non-owner calls `rebalance`
- a rebalance request would not move any funds
- the vault tries to change adapters while deployed liquidity is active
- the vault tries to deploy without a configured adapter
- the vault tries to withdraw without a configured adapter

## Invariants

These conditions should always hold:
- rebalance does not implement a separate funds-flow path
- rebalance only wraps the existing deploy and withdraw helpers
- tracked deployed liquidity stays in sync with the adapter position
- the vault can only have one active venue label in this minimal version
- `IDLE` is represented by zero tracked deployed liquidity

## Test Plan

Core tests should cover:
- rebalance remains owner-only
- idle-to-V2 rebalance deploys all idle balances
- idle-to-V3 rebalance deploys all idle balances
- idle-to-V2 rebalance reverts when there is nothing to deploy
- idle-to-V3 rebalance reverts when there is nothing to deploy
- V2-to-idle rebalance withdraws all deployed liquidity
- V3-to-idle rebalance withdraws all deployed liquidity
- V2-to-idle rebalance reverts when there is nothing to withdraw
- V3-to-idle rebalance reverts when there is nothing to withdraw
- adapter switching is blocked while liquidity is deployed

This list is intentionally minimal and should remain focused on the single-venue rebalance state machine. Future multi-venue or strategy-layer work should add a separate extension of these tests rather than widening the first pass.
