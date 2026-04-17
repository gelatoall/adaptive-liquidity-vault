# UniswapV2Adapter Minimal Design

## Goal

Build a minimal Uniswap V2 adapter that:
- receives `token0` and `token1` from the vault
- adds liquidity to a Uniswap V2 pair
- removes liquidity back into `token0` and `token1`
- reports the underlying token balances represented by the current LP position

## Scope

This version includes:
- add liquidity
- remove liquidity
- LP token accounting
- position balance reporting
- local unit tests with mocks or simplified setup

This version does not include:
- automatic rebalancing
- multi-venue routing
- fee collection logic beyond normal V2 LP behavior
- production-grade access control beyond vault-only execution
- slippage optimization
- oracle-based strategy decisions

Notes:
- This adapter is an execution module, not a strategy module.
- The vault decides when assets remain idle or are deployed.
- The adapter only interacts with the venue.
- The target `pair` is treated as known configuration, so this minimal version does not depend on a V2 factory.

## Responsibilities

### Vault Responsibilities

- accept user deposits
- mint and burn shares
- track total vault assets
- decide when assets remain idle or are deployed
- call the adapter with explicit amounts

### Adapter Responsibilities

- receive `token0` and `token1` from the vault
- approve router usage when needed
- add liquidity into the target V2 pair
- remove liquidity from the pair
- collect fees if the venue exposes a separate fee-collection step
- return unused tokens and withdrawn tokens back to the vault
- expose current deployed position balances

## State

The adapter stores:
- `vault` address
- `token0` address
- `token1` address
- `router` address
- `pair` address

Notes:
- Only the vault should be allowed to trigger state-changing adapter functions.
- LP tokens should be held in one place consistently.
- `router` is used for add/remove liquidity execution.
- `pair` is used to read reserves, LP supply, and current position state.

## Design Choice

The minimal version should use this ownership model:
- the adapter holds the LP tokens
- the vault sends `token0` and `token1` to the adapter
- the adapter adds liquidity and keeps the LP position
- when withdrawing, the adapter removes liquidity and returns `token0` and `token1` to the vault

Reason:
- this keeps venue-specific accounting inside the adapter
- the vault only needs to ask the adapter for deployed balances

## Public Functions

- `constructor(vault, token0, token1, router, pair)`
  - purpose: initialize immutable venue configuration

- `addLiquidity(amount0, amount1, params)`
  - purpose: add `token0` and `token1` as V2 liquidity
  - returns: `uint256 liquidity`

- `removeLiquidity(liquidity)`
  - purpose: remove liquidity from the pair
  - returns: `uint256 amount0Out, uint256 amount1Out`

- `collectFees()`
  - purpose: collect fees for venues that support explicit fee collection
  - returns: `uint256 fees0, uint256 fees1`

- `getPositionValue()`
  - purpose: report the underlying token amounts represented by the adapter's LP position
  - note: despite the function name, the minimal V2 implementation returns underlying amounts, not normalized oracle-priced value
  - returns: `uint256 amount0, uint256 amount1`

- `hasPosition()`
  - purpose: report whether the adapter currently has an active venue position
  - returns: `bool`

## Core Flows

### addLiquidity

1. Reject if both token amounts are zero.
2. Pull `token0` and `token1` from the vault or use tokens already transferred in.
3. Approve the router for token usage.
4. Call the V2 router to add liquidity.
5. Record or infer the minted LP tokens.
6. Keep LP tokens in the adapter.
7. Return any unused token dust to the vault.

### removeLiquidity

1. Reject if liquidity is zero.
2. Reject if liquidity exceeds the adapter's LP balance.
3. Approve the router to spend LP tokens.
4. Call the V2 router to remove liquidity.
5. Receive `token0` and `token1` back from the pair.
6. Transfer withdrawn `token0` and `token1` back to the vault.

### collectFees

1. If the venue supports explicit fee collection, claim the pending fees.
2. Return the collected token amounts.
3. For V2, this function should normally revert with an unsupported-operation style error because fee collection is realized through LP position value rather than a separate claim step.

### getPositionValue

1. Read the adapter's LP token balance.
2. Read the pair reserves and total LP supply.
3. Compute the adapter's proportional share of reserve0 and reserve1.
4. Return the underlying token amounts.

## Failure Cases

The adapter should revert when:
- both deposit amounts are zero
- liquidity to withdraw is zero
- liquidity exceeds the adapter's LP balance
- a state-changing function is called by a non-vault address
- `collectFees()` is called on a venue that does not support explicit fee collection
- token transfer or router interaction fails

## Invariants

These conditions should always hold:
- only the vault can trigger liquidity deployment or withdrawal
- LP token ownership is tracked consistently
- `getPositionValue()` reflects the adapter's proportional share of pair reserves
- withdrawn assets return to the vault, not to arbitrary callers

## Test Plan

The first test set should cover:
- constructor stores the expected addresses
- `addLiquidity()` reverts when both amounts are zero
- `addLiquidity()` can mint LP tokens
- `collectFees()` reverts for the minimal V2 implementation
- `removeLiquidity()` reverts when liquidity is zero
- `removeLiquidity()` reverts when liquidity exceeds position size
- `removeLiquidity()` returns `token0` and `token1` to the vault
- `hasPosition()` reflects whether the adapter has active liquidity deployed
- `getPositionValue()` returns the proportional underlying reserves
- non-vault callers cannot execute state-changing functions

This test plan is intentionally high-level. Concrete tests may expand each topic into symmetric branches, invalid-input paths, and edge cases.
