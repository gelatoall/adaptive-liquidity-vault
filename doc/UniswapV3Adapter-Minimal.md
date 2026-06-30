# UniswapV3Adapter Minimal Design

## Goal

Build a minimal Uniswap V3 adapter that:
- receives `token0` and `token1` from the vault
- adds liquidity to one configured Uniswap V3 pool
- holds one V3 position NFT inside the adapter
- removes liquidity back into `token0` and `token1`
- collects explicit V3 fees and returns them to the vault
- reports the underlying token balances represented by the current V3 position

## Scope

This version includes:
- one configured V3 pool
- one fixed fee tier, implied by the configured pool
- one fixed tick range
- one active position NFT managed by the adapter
- minting a new V3 position when no position exists
- increasing liquidity on the existing position
- decreasing liquidity from the existing position
- explicit fee collection
- position state reporting through the shared `IVenueAdapter` interface

This version does not include:
- multiple V3 fee tiers in one adapter
- multiple V3 position NFTs in one adapter
- automatic tick range selection
- single-sided deposit optimization
- swap-to-ratio logic
- autonomous rebalancing
- production-grade slippage policy
- V3 TWAP oracle integration
- exact real-time uncollected fee accounting beyond the position manager state

Notes:
- This adapter is an execution module, not a strategy module.
- The vault decides when assets remain idle or are deployed.
- The adapter only manages one configured V3 venue.
- Multi-fee-tier selection belongs in a later strategy or venue manager layer.
- The target `pool` is treated as known configuration, so this minimal version does not depend on a V3 factory.
- The current `IVenueAdapter` can be reused because the adapter hides the V3 NFT details internally.

## Responsibilities

### Vault Responsibilities

- accept user deposits
- mint and burn shares
- track total vault assets
- decide when assets remain idle or are deployed
- call the adapter with explicit token amounts
- pass venue-specific `params` through `deployToVenue(...)`

### Adapter Responsibilities

- receive `token0` and `token1` from the vault
- conform to the shared `IVenueAdapter` interface
- map vault token order to pool token order
- approve the V3 position manager using pool-ordered token addresses and amounts when needed
- mint a V3 position NFT when no active position exists
- increase liquidity on the existing V3 position
- decrease liquidity from the existing V3 position
- collect fees and withdrawn principal from the position manager
- return unused dust, withdrawn assets, and collected fees to the vault
- expose current deployed position balances

## State

The adapter stores:
- `vault` address
- `token0` ERC20 reference, using vault token order
- `token1` ERC20 reference, using vault token order
- `positionManager` reference
- `pool` reference
- `tickLower`
- `tickUpper`
- `tokenId`

Notes:
- `tokenId == 0` means the adapter currently has no remembered V3 position NFT.
- V3 pool token order is determined by address sorting, so the adapter must map vault token order to pool token order before calling the position manager.
- V3 position manager calls use pool token order.
- Vault-facing return values use vault token order.
- Only the vault should be allowed to trigger state-changing adapter functions.

## Design Choice

The minimal version should use this ownership model:
- the adapter receives vault tokens
- the adapter mints or increases one V3 position NFT
- the adapter holds the NFT
- the adapter collects fees and withdrawn assets
- the adapter returns all collected tokens to the vault

Reason:
- V3 position identity is NFT-based, so `tokenId` should stay inside the adapter.
- The vault should not know or pass `tokenId` in normal operation.
- Keeping one active position makes the current `IVenueAdapter` sufficient.
- Multiple fee tiers can be modeled later as multiple adapter instances or a strategy manager.

## Public Functions

- `constructor(vault, token0, token1, positionManager, pool, tickLower, tickUpper)`
  - purpose: initialize immutable V3 venue configuration
  - validation:
    - revert on zero addresses
    - revert if `tickLower >= tickUpper`
    - revert if `pool.token0/token1` do not match the configured token set in either order
  - records:
    - the configured vault token pair
    - no active position by leaving `tokenId` as zero

- `addLiquidity(amount0, amount1, params)`
  - purpose: deploy vault tokens into the configured V3 position
  - returns: `uint256 liquidity`
  - behavior:
    - only callable by `vault`
    - reverts when both amounts are zero
    - decodes V3-specific add-liquidity execution params
    - pulls tokens from the vault
    - approves the position manager using pool-ordered token addresses and amounts
    - builds internal execution context that maps vault order into pool order
    - mints a new position if `tokenId == 0`
    - otherwise increases liquidity on the existing position
    - returns unused dust to the vault
    - resets approvals back to zero

- `removeLiquidity(liquidity, params)`
  - purpose: remove liquidity from the current V3 position
  - returns: `uint256 amount0, uint256 amount1` in vault token order
  - behavior:
    - only callable by `vault`
    - reverts on non-empty `params` in the current refactor step
    - reverts when liquidity is zero
    - reverts when no position exists
    - reverts when requested liquidity exceeds current position liquidity
    - calls `decreaseLiquidity(...)`
    - calls `collect(...)` to receive withdrawn principal and any collectable amounts tracked by the position manager
    - transfers collected tokens back to the vault
    - burns the NFT and clears `tokenId` when the position is fully empty

- `collectFees()`
  - purpose: collect explicit V3 fees from the current position
  - returns: `uint256 fees0, uint256 fees1` in vault token order
  - behavior:
    - only callable by `vault`
    - reverts when no position exists
    - calls `collect(...)`
    - transfers collected tokens back to the vault
  - note:
    - V3 `collect()` may return any collectable token amounts tracked by the position manager, not only swap fees in a narrow accounting sense.

- `getPositionValue()`
  - purpose: report the underlying token amounts represented by the current V3 position
  - returns: `uint256 amount0, uint256 amount1` in vault token order
  - expected behavior:
    - returns zeroes when no position exists
    - returns non-zero values when the position has only owed amounts and zero liquidity
    - reads `positions(tokenId)` for liquidity and `tokensOwed0/1`
    - reads `pool.slot0()` for current sqrt price
    - uses V3 math to convert liquidity into principal token amounts
    - adds `tokensOwed0/1`
    - maps pool token order back to vault token order
  - dependency:
    - a correct implementation requires V3 math libraries such as `TickMath` and `LiquidityAmounts`
  - precision note:
    - this minimal implementation reports `principal + position-manager-tracked owed amounts`
    - it does not reconstruct the latest uncollected fee growth that has not yet been written into `tokensOwed0/1`

- `hasPosition()`
  - purpose: report whether the adapter currently has an active V3 position
  - returns: `bool`
  - behavior:
    - returns false when `tokenId == 0`
    - otherwise returns true if position liquidity or tokens owed are non-zero

## Params Encoding

Minimal `addLiquidity` params:

```solidity
abi.encode(
    uint256 amount0Min,
    uint256 amount1Min,
    uint256 deadline
)
```

Where:
- `amount0Min` is expressed in vault token0 order
- `amount1Min` is expressed in vault token1 order
- `deadline` is forwarded to the position manager

Adapter behavior:
- desired amounts come from `addLiquidity(amount0, amount1, params)`
- minimum amounts come from `params`
- both desired and minimum amounts are mapped into pool token order before calling the position manager

## Core Flows

### addLiquidity

1. Reject if both token amounts are zero.
2. Decode `amount0Min`, `amount1Min`, and `deadline` from `params`.
3. Pull `token0` and `token1` from the vault.
4. Build an internal execution context that maps vault amounts into pool amounts.
5. Approve the position manager for the desired token amounts.
6. If no active `tokenId` exists, call `mint(...)`.
7. Otherwise call `increaseLiquidity(...)`.
8. Store the new `tokenId` after minting.
9. Map used amounts back into vault token order.
10. Return unused dust to the vault.
11. Reset approvals back to zero.
12. Emit an event summarizing the operation.

### removeLiquidity

1. Reject if requested liquidity is zero.
2. Reject if no position exists.
3. Read current position liquidity.
4. Reject if requested liquidity exceeds current position liquidity.
5. Call `decreaseLiquidity(...)`.
6. Call `collect(...)` to receive collectable token amounts.
7. Map collected amounts back into vault token order.
8. Transfer collected tokens to the vault.
9. Read the remaining position state.
10. If liquidity and owed tokens are zero, burn the NFT and clear `tokenId`.
11. Emit an event summarizing the operation.

### collectFees

1. Reject if no position exists.
2. Call `collect(...)` with max uint128 amounts.
3. Map collected amounts back into vault token order.
4. Transfer collected tokens to the vault.
5. Emit an event summarizing the operation.

### getPositionValue

1. Return zeroes if no position exists.
2. Read current position liquidity and owed tokens.
3. Start with `tokensOwed0/1` as the owed component.
4. If liquidity is non-zero, read current pool sqrt price from `slot0()`.
5. Convert the configured ticks into sqrt ratios.
6. Use V3 liquidity math to compute principal token amounts.
7. Add principal and owed amounts.
8. Map pool token order back into vault token order.

### hasPosition

1. Return false if `tokenId == 0`.
2. Read current position liquidity and owed tokens.
3. Return true if any of them are non-zero.
4. Return false otherwise.

## Internal Helpers

The adapter can keep the public surface small by pushing V3-specific details into internal helpers:

- `_mapVaultToPool(...)`
  - maps vault token order and vault amounts into pool token order
- `_mapTokenAmounts(...)`
  - generic token-order mapping helper used in both directions
- `_getPositionMetadata(...)`
  - reads the subset of `positions(tokenId)` needed by the adapter
- `_collectAndTransfer(...)`
  - collects from the position manager into the adapter, then transfers to the vault
- `_cleanupEmptyPosition()`
  - burns the NFT and clears `tokenId` when the position is fully empty
- `_buildAddLiquidityContext(...)`
  - builds the execution context used by `addLiquidity()`
- `_executeAddLiquidity(...)`
  - dispatches to mint or increase and returns used amounts
- `_mintPosition(...)`
  - performs the actual `positionManager.mint(...)` call
- `_increasePosition(...)`
  - performs the actual `positionManager.increaseLiquidity(...)` call
- `_refundDust(...)`
  - returns unused vault tokens back to the vault

## Failure Cases

The adapter should revert when:
- constructor receives a zero address
- constructor receives invalid tick bounds
- constructor pool token set does not match configured vault tokens
- both add-liquidity amounts are zero
- a non-vault caller attempts a state-changing operation
- remove liquidity is called with zero liquidity
- remove liquidity is called without a position
- remove liquidity exceeds current position liquidity
- fee collection is requested without a position
- token transfers fail
- position manager calls fail

## Invariants

These conditions should always hold:
- only the vault can move funds through the adapter
- the adapter owns the active V3 position NFT
- the vault does not need to know the V3 `tokenId`
- the adapter has at most one active position
- position manager calls use pool token order
- vault-facing return values use vault token order
- unused token dust returns to the vault
- collected fees and withdrawn principal return to the vault
- if the adapter still has liquidity or owed tokens, `hasPosition()` should return true
- if the position is fully empty after collect/remove, `tokenId` should be burned and cleared back to zero

## Test Plan

The first test set should cover:
- constructor stores the expected addresses and ticks
- constructor rejects zero addresses
- constructor rejects invalid tick bounds
- constructor rejects pools with mismatched token sets
- `addLiquidity()` reverts when both amounts are zero
- `addLiquidity()` mints a new V3 position when no position exists
- `addLiquidity()` stores the returned `tokenId`
- `addLiquidity()` increases liquidity when a position already exists
- `addLiquidity()` maps amounts correctly for both token address orderings
- `addLiquidity()` returns unused dust to the vault
- `removeLiquidity()` reverts when liquidity is zero
- `removeLiquidity()` reverts when no position exists
- `removeLiquidity()` reverts when requested liquidity exceeds position liquidity
- `removeLiquidity()` returns collected token amounts to the vault
- `removeLiquidity()` burns and clears `tokenId` when the position is empty
- `collectFees()` reverts when no position exists
- `collectFees()` transfers collected fees to the vault
- `hasPosition()` returns false before minting
- `hasPosition()` returns true when liquidity is non-zero
- `hasPosition()` returns true when only owed tokens remain
- `hasPosition()` returns false after the position is fully cleared
- `getPositionValue()` returns zeroes without a position
- `getPositionValue()` includes principal and position-manager-tracked owed tokens
- non-vault callers cannot execute state-changing functions

Notes on testing priorities:
- Mock the position manager first; do not start with a full V3 integration test.
- Keep first tests focused on permissions, token flow, NFT ownership, token-order mapping, and position accounting.
- Exact V3 math tests should be added once `TickMath` and `LiquidityAmounts` are included.
- Fork tests against real V3 pools should come after local unit tests are stable.

### Vault-Level Integration

After the adapter unit tests are stable, add a separate vault integration file for the V3 path, for example:
- `VaultV3Integration.t.sol`

That integration layer should verify:
- `setVenue()` wires the vault to the V3 adapter
- `deposit -> deployToVenue(venueId, ...) -> redeem` works as a closed loop by withdrawing proportional active V3 liquidity during redemption
- `totalAssets()` includes `adapter.getPositionValue()`
- redemption can clear the active V3 position when the user redeems all shares

Keep `collectFees()` coverage in the adapter unit tests for now, since the vault does not yet expose a dedicated public fee-harvest entrypoint for V3.

## Current Vault Integration

The current vault can integrate this adapter without changing `IVenueAdapter`:
- the vault stores registered venue adapters as `IVenueAdapter`
- the owner can register one V3 fee tier as one venue through `setVenue(venueId, adapter, label, enabled)`
- the owner can call `deployToVenue(venueId, amount0, amount1, params)`
- the owner can call `withdrawFromVenue(venueId, liquidity, params)`
- `totalAssets()` can include V3 deployed balances through `adapter.getPositionValue()`
- direct user redemption withdraws the caller's proportional tracked V3 liquidity before transferring underlying tokens

This means each V3 fee tier can be represented by a separate adapter instance and registered as a separate venue while preserving the current vault abstraction.

## Future Extensions

Later versions may add:
- decoding withdraw params for slippage-protected `decreaseLiquidity`
- V3 TWAP oracle integration
- tick range updates
- multiple adapter instances for multiple fee tiers
- a venue registry or strategy manager
- automated rebalance between V2, V3 0.05%, V3 0.30%, and V3 1.00%
- exact uncollected fee valuation using V3 fee-growth accounting
