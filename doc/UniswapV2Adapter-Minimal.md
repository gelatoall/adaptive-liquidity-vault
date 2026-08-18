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
- explicit implementation of the shared `IVenueAdapter` interface

This version does not include:
- automatic rebalancing
- venue routing inside the adapter
- fee collection logic beyond normal V2 LP behavior
- production-grade policy controls beyond vault-only capital movement
- slippage optimization
- oracle-based strategy decisions

Notes:
- This adapter is an execution module, not a strategy module.
- The vault decides when assets remain idle or are deployed.
- The adapter only interacts with the venue.
- Price formation is handled by the oracle layer (`doc/V2TWAPOracle-Minimal.md`), not by this adapter.
- The target `pair` is treated as known configuration, so this minimal version does not depend on a V2 factory.
- The current implementation validates that `pair` contains exactly `token0` and `token1`, allowing either pair ordering.

## Responsibilities

### Vault Responsibilities

- accept user deposits
- mint and burn shares
- track total vault assets
- decide when assets remain idle or are deployed
- call the adapter with explicit amounts

### Adapter Responsibilities

- receive `token0` and `token1` from the vault
- conform to the shared `IVenueAdapter` interface used by higher-level vault logic
- approve router usage when needed
- add liquidity into the target V2 pair
- remove liquidity from the pair
- return zero for explicit fee collection because plain Uniswap V2 LPs do not expose a separate fee-claim step
- return unused tokens and withdrawn tokens back to the vault
- expose current deployed position balances

## State

The adapter stores:
- `vault` address
- `token0` ERC20 reference
- `token1` ERC20 reference
- `router` address
- `pair` address

Notes:
- Only the vault should be allowed to trigger state-changing adapter functions.
- LP tokens should be held in one place consistently.
- `router` is used for add/remove liquidity execution.
- `pair` is used to read reserves, LP supply, and current position state.
- In the current implementation, `vault` is stored as a plain `address`, not as an `AdaptiveLPVault` type.
- This keeps the adapter coupled only to the caller address it trusts, not to a specific vault implementation contract.

## Design Choice

The minimal version should use this ownership model:
- the adapter holds the LP tokens
- the vault sends `token0` and `token1` to the adapter
- the adapter adds liquidity and keeps the LP position
- when withdrawing, the adapter removes liquidity and returns `token0` and `token1` to the vault

Reason:
- this keeps venue-specific accounting inside the adapter
- the vault only needs to ask the adapter for deployed balances

Current code status:
- `UniswapV2Adapter` explicitly implements `IVenueAdapter`
- `onlyVault` currently protects `addLiquidity()` and `removeLiquidity()`
- `getPositionValue()` is intentionally public `view`
- `hasPosition()` remains publicly readable
- `collectFees()` is implemented as `pure` and returns `(0, 0)` because V2 fees accrue inside LP value
- add/remove events exist for observability, but current tests treat them as secondary to state and asset-flow verification
- `AdaptiveLPVault` is now minimally integrated with the adapter through:
  - `setVenue(venueId, adapter, label, enabled)`
  - `deployToVenue(venueId, amount0, amount1, params)`
  - `withdrawFromVenue(venueId, liquidity, params)`
  - `V2FairValueValuator` for trusted `totalAssets()` accounting of the deployed LP position

## Public Functions

- `constructor(vault, token0, token1, router, pair)`
  - purpose: initialize immutable venue configuration
  - current validation:
    - revert on zero addresses
    - revert if `pair.token0/token1` do not match the configured tokens in either order

- `addLiquidity(amount0, amount1, params)`
  - purpose: add `token0` and `token1` as V2 liquidity
  - returns: `uint256 liquidity`
  - current behavior:
    - only callable by `vault`
    - decodes optional `amount0Min`, `amount1Min`, and `deadline` from `params`
    - empty `params` use `amount0Min = 0`, `amount1Min = 0`, and `deadline = block.timestamp`
    - pulls funds from the vault with `safeTransferFrom`
    - resets token approvals back to zero after router execution

- `removeLiquidity(liquidity, params)`
  - purpose: remove liquidity from the pair
  - returns: `uint256 amount0Out, uint256 amount1Out`
  - current behavior:
    - only callable by `vault`
    - decodes optional `amount0Min`, `amount1Min`, and `deadline` from `params`
    - empty `params` use `amount0Min = 0`, `amount1Min = 0`, and `deadline = block.timestamp`
    - reverts if requested liquidity exceeds adapter LP balance

- `collectFees()`
  - purpose: collect fees for venues that support explicit fee collection
  - returns: `uint256 fees0, uint256 fees1`
  - current V2 implementation: returns `(0, 0)` because there is no separate fee-claim step

- `getPositionValue()`
  - purpose: report the underlying token amounts represented by the adapter's LP position
  - note: despite the function name, the minimal V2 implementation returns underlying amounts, not normalized oracle-priced value
  - returns: `uint256 amount0, uint256 amount1`
  - current behavior:
    - callable by any address
    - reverts with `InvalidTotalSupply` if LP balance is non-zero while pair total supply is zero
  - rationale:
    - the result is computed entirely from public on-chain data: adapter LP balance, pair reserves, pair total supply, and token ordering
    - restricting this function to `vault` would not hide meaningful information because any observer can derive the same result off-chain
    - keeping it public makes integration easier for frontends, monitoring, scripts, and keepers
  - accounting note:
    - this reserve-ratio-based amount view is informational and is not used directly by vault share accounting
    - `AdaptiveLPVault.totalAssets()` uses `V2FairValueValuator`, which oracle-values both reserves and applies a geometric-mean fair LP value before scaling by LP ownership

- `hasPosition()`
  - purpose: report whether the adapter currently has an active venue position
  - returns: `bool`

## Core Flows

### addLiquidity

1. Reject if both token amounts are zero.
2. Pull `token0` and `token1` from the vault with `safeTransferFrom`.
3. Approve the router for token usage.
4. Call the V2 router to add liquidity.
5. Record or infer the minted LP tokens.
6. Keep LP tokens in the adapter.
7. Return any unused token dust to the vault.
8. Reset router approvals back to zero.
9. Emit an event summarizing the execution result for off-chain observability.

### removeLiquidity

1. Reject if liquidity is zero.
2. Reject if liquidity exceeds the adapter's LP balance.
3. Approve the router to spend LP tokens.
4. Call the V2 router to remove liquidity.
5. Receive `token0` and `token1` back from the pair.
6. Transfer withdrawn `token0` and `token1` back to the vault.
7. Reset LP approval back to zero.
8. Emit an event summarizing the execution result for off-chain observability.

### collectFees

1. Return `(0, 0)`.
2. V2 swap fees are realized through LP position value, so removing liquidity naturally realizes them with the withdrawn underlying assets.
3. Returning zero keeps the shared vault withdrawal flow compatible with venues that do not expose explicit fee claims.

### getPositionValue

1. Read the adapter's LP token balance.
2. Read the pair reserves and total LP supply.
3. Revert if LP balance is non-zero while total LP supply is zero.
4. Compute the adapter's proportional share of reserve0 and reserve1.
5. Return the underlying token amounts, remapping reserves if the pair token ordering is reversed relative to the adapter config.

## Failure Cases

The adapter should revert when:
- both deposit amounts are zero
- liquidity to withdraw is zero
- liquidity exceeds the adapter's LP balance
- a state-changing function is called by a non-vault address
- LP balance is non-zero while the pair reports zero total supply
- token transfer or router interaction fails
- constructor configuration does not match the pair's token set

## Invariants

These conditions should always hold:
- only the vault can trigger liquidity deployment or withdrawal
- LP token ownership is tracked consistently
- `getPositionValue()` reflects the adapter's proportional share of pair reserves
- withdrawn assets return to the vault, not to arbitrary callers
- public read methods do not grant any additional ability to move funds
- synchronous redemption uses the vault's idle buffer and never calls this adapter's removal path

## Test Plan

The first test set should cover:
- constructor stores the expected addresses
- `addLiquidity()` reverts when both amounts are zero
- `addLiquidity()` can mint LP tokens
- `collectFees()` returns zero for V2
- `removeLiquidity()` reverts when liquidity is zero
- `removeLiquidity()` reverts when liquidity exceeds position size
- `removeLiquidity()` returns `token0` and `token1` to the vault
- `hasPosition()` reflects whether the adapter has active liquidity deployed
- `getPositionValue()` returns the proportional underlying reserves
- `getPositionValue()` is readable by non-vault callers
- `getPositionValue()` reverts on invalid zero-total-supply pair state
- constructor rejects pairs whose token set does not match the configured tokens
- non-vault callers cannot execute state-changing functions

Notes on testing priorities:
- In the current stage, event-specific assertions are optional rather than core.
- The more important tests are the ones that verify balances, LP ownership, permissions, and position valuation.
- Event tests become more valuable only when downstream systems rely on exact event schemas.

## Current Vault Integration

The current repository now goes beyond an isolated standalone adapter unit.

`AdaptiveLPVault` is minimally wired to the adapter as follows:
- the vault stores registered venue adapters as `IVenueAdapter`
- the owner can register the V2 adapter with `setVenue(venueId, adapter, label, enabled)`
- the owner can call `deployToVenue(venueId, amount0, amount1, params)`
- the owner can call `withdrawFromVenue(venueId, liquidity, params)`
- `totalAssets()` adds:
  - idle token balances held by the vault
  - trusted base-denominated values returned by the configured venue valuators
- synchronous user redemption uses idle balances and leaves V2 LP liquidity unchanged

This means the current implementation already validates:
- vault-to-adapter capital movement
- adapter-to-vault withdrawal flow
- total asset accounting across idle balances and one or more deployed venues
- idle-buffer redemption while active V2 liquidity remains unchanged
- manager-escrowed asynchronous redemption funded from snapshotted V2 and V3 liquidity in separate transactions
- preservation of a queued request when one venue funding call fails while healthy venues fund independently

It does not yet implement:
- oracle-driven deployment decisions
- autonomous strategy selection

## Current Integration Test Coverage

The current integration tests for `AdaptiveLPVault + UniswapV2Adapter` cover:
- adapter wiring via `setVenue(...)`
- owner-only deployment and withdrawal
- revert when deployment or withdrawal is attempted before the venue is configured
- revert when deployment is attempted for a disabled venue
- successful deployment moving idle vault funds into an adapter-held LP position
- unused dust remaining in the vault after deployment
- successful withdrawal returning underlying token balances back to the vault
- redemption succeeding from a sufficient idle buffer without removing the active V2 position
- redemption reverting without burning shares when idle value is insufficient
- queued redemption surviving an isolated V2 withdrawal failure and settling after V2 recovers
- per-venue liquidity tracking in the multi-venue vault

These tests are intentionally focused on:
- permissions
- asset flow correctness
- adapter position ownership
- accounting continuity

They are not yet focused on:
- oracle price quality
- real AMM execution outcomes
- strategy policy

This test plan is intentionally high-level. Concrete tests may expand each topic into symmetric branches, invalid-input paths, and edge cases.
