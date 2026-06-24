# TWAPOracle Minimal Design

## Goal

Build a minimal Uniswap V2 TWAP oracle that:
- reads cumulative prices from a configured V2 pair
- computes time-weighted average prices over a minimum window
- returns prices in `1e18` precision through `IPriceOracle.getPrices()`
- aligns returned `(price0, price1)` to configured token order

## Scope

This version includes:
- constructor-time pair/token validation
- cumulative-price snapshot state
- windowed `update()` with minimum interval guard
- `UQ112x112 -> 1e18` conversion
- token-order remapping for reversed pair ordering
- unit tests using mocked pair cumulative values

This version does not include:
- multi-pair aggregation
- staleness timeout policy beyond update gating
- access control on `update()`
- external keeper automation
- fallback oracle logic

## Interface and Output Contract

`TWAPOracle` implements:
- `IPriceOracle.getPrices() -> (uint256 price0, uint256 price1)`

Output contract:
- `price0` and `price1` are denominated in base value with `1e18` precision
- return order always follows configured oracle `token0/token1`, not pair internal order

## Core Formula

For each token side:
- `avgX112 = (cumNow - cumLast) / timeElapsed`
- `price1e18 = avgX112 * 1e18 / 2^112`

Notes:
- cumulative deltas and timestamp deltas intentionally use wrap-around semantics
- `timeElapsed` must be non-zero and at least `minUpdateInterval`

## State

Immutable config:
- `pair`
- `token0`
- `token1`
- `minUpdateInterval`

Rolling snapshot:
- `price0CumulativeLast`
- `price1CumulativeLast`
- `blockTimestampLast`

Latest computed average:
- `price0AverageX112`
- `price1AverageX112`
- `initialized`

## Constructor Behavior

Constructor validates:
- non-zero pair/token addresses
- non-zero `minUpdateInterval`
- pair token set matches configured token set (direct or reversed)

Constructor snapshots:
- `price0CumulativeLast`
- `price1CumulativeLast`
- `blockTimestampLast` from `pair.getReserves()`

Important:
- constructor snapshot does not make oracle initialized
- at least one successful `update()` is required before `getPrices()`

## Update Behavior

`update()` flow:
1. Read current cumulative prices and reserve timestamp from pair.
2. Compute `timeElapsed` using uint32 wrap-around semantics.
3. Revert if `timeElapsed == 0`.
4. Revert if `timeElapsed < minUpdateInterval`.
5. Compute average price deltas in `UQ112x112`.
6. Advance snapshot state to current cumulative/timestamp.
7. Mark `initialized = true`.
8. Emit `TwapUpdated(price0, price1, timeElapsed)` with aligned 1e18 prices.

## Read Behavior

`getPrices()`:
- reverts before first successful update
- converts latest `UQ112x112` averages to `1e18`
- remaps pair order to configured token order

## Internal Helper Functions

Current implementation uses these internal helpers:

### `_decodeUQ112x112To1e18(uint256 avgX112) -> uint256`

Purpose:
- convert one average value from `UQ112x112` precision into `1e18` precision

Formula:
- `price1e18 = avgX112 * 1e18 / 2^112`

Design considerations:
- uses `Math.mulDiv` instead of plain `a*b/d`
- reason: avoid intermediate multiplication overflow risk while preserving integer division semantics
- keeps conversion logic in one place so update/read paths do not duplicate precision code

### `_getAlignedPrices() -> (uint256 price0, uint256 price1)`

Purpose:
- return prices aligned to configured oracle token order (`token0`, `token1`)

Behavior:
- first decodes stored `price0AverageX112` and `price1AverageX112` into `1e18`
- then checks pair order:
  - if `pair.token0 == configured token0`, return `(pairPrice0, pairPrice1)`
  - else return `(pairPrice1, pairPrice0)`

Design considerations:
- isolates token-order remapping in one helper to avoid repeated branching logic
- ensures public `getPrices()` always respects vault-facing token semantics, even when pair internal order is reversed

## Failure Cases

The oracle should revert when:
- constructor receives zero addresses
- constructor receives zero update interval
- pair token set mismatches configured tokens
- `update()` is called with zero elapsed time
- `update()` is called before minimum interval is reached
- `getPrices()` is called before oracle initialization

## Invariants

These conditions should always hold:
- returned prices are always aligned to configured `token0/token1` order
- successful update advances cumulative and timestamp snapshot
- second update window is computed from first update snapshot, not initial constructor snapshot
- `getPrices()` never returns uninitialized values

## Test Plan

Core tests should cover:
- constructor zero-address and interval checks
- constructor token-set mismatch check
- constructor snapshot correctness
- `getPrices()` revert before first valid update
- `update()` revert when no elapsed time
- `update()` revert when interval too short
- successful update average computation and 1e18 scaling
- rolling-window snapshot advancement across multiple updates
- reversed pair-order price alignment

Current integration validation in this repository also covers:
- vault deposit failure before oracle initialization (`NotInitialized`)
- vault deposit success after TWAP update
- vault `totalAssets()` valuation after TWAP update
- vault + V2 adapter path where `totalAssets()` remains consistent across idle-to-deployed movement under TWAP pricing
