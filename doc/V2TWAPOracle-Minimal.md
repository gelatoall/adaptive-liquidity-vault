# V2TWAPOracle Minimal Design

## Goal

Build a minimal Uniswap V2 TWAP oracle that:
- reads cumulative prices from a configured V2 pair
- computes time-weighted average prices over a minimum window
- returns prices in `1e18` precision through `IPriceOracle.getPrices()`
- denominates both returned prices in configured `token0`

## Scope

This version includes:
- constructor-time pair/token validation
- cumulative-price snapshot state
- windowed `update()` with minimum interval guard
- `UQ112x112 -> 1e18` conversion
- raw-unit decimal normalization
- direct and reversed pair-order handling
- unit tests using mocked pair cumulative values

This version does not include:
- multi-pair aggregation
- staleness timeout policy beyond update gating
- access control on `update()`
- external keeper automation
- fallback oracle logic

## Interface and Output Contract

`V2TWAPOracle` implements:
- `IPriceOracle.getPrices() -> (uint256 price0, uint256 price1)`

Output contract:
- configured `token0` is the base asset
- `price0` is always `1e18`
- `price1` is the value of one whole configured `token1` in configured `token0`, scaled by `1e18`
- both outputs therefore share one numeraire and can be used by vault valuation

## Core Formula

For each pair-native price side:
- `avgX112 = (cumNow - cumLast) / timeElapsed`
- `rawPrice1e18 = avgX112 * 1e18 / 2^112`

After selecting the pair direction that represents configured `token1` in configured `token0`:
- `price0 = 1e18`
- `price1 = rawPrice1e18 * 10^token1Decimals / 10^token0Decimals`

Notes:
- cumulative deltas and timestamp deltas intentionally use wrap-around semantics
- `timeElapsed` must be non-zero and at least `minUpdateInterval`

## State

Immutable config:
- `pair`
- `token0`
- `token1`
- `token0Decimals`
- `token1Decimals`
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
- token decimals can be safely scaled

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
8. Emit `TwapUpdated(price0, price1, timeElapsed)` with token0-denominated 1e18 prices.

## Read Behavior

`getPrices()`:
- reverts before first successful update
- selects the pair-native average representing configured token1 in configured token0
- converts the selected `UQ112x112` raw-unit ratio to `1e18`
- normalizes token decimals and returns `(1e18, token1PriceInToken0)`

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

### `_getBaseDenominatedPrices() -> (uint256 price0, uint256 price1)`

Purpose:
- return both configured token prices in the configured token0 numeraire

Behavior:
- if `pair.token0 == configured token0`, select pair `price1AverageX112`
- otherwise select pair `price0AverageX112`
- decode the selected UQ112x112 value
- normalize the raw-unit ratio with configured token decimals
- return `price0 = 1e18` and the normalized `price1`

Design considerations:
- V2 pair `price0` and `price1` are reciprocal, pair-relative values with different numeraires
- returning both pair-native values would violate the vault's common-base valuation contract
- selecting one direction and fixing token0 at `1e18` keeps `totalAssets()` dimensionally consistent

## Failure Cases

The oracle should revert when:
- constructor receives zero addresses
- constructor receives zero update interval
- pair token set mismatches configured tokens
- either token reports decimals too large for safe power-of-ten scaling
- `update()` is called with zero elapsed time
- `update()` is called before minimum interval is reached
- `getPrices()` is called before oracle initialization

## Invariants

These conditions should always hold:
- `price0 == 1e18` after initialization
- both returned prices are denominated in configured token0
- direct and reversed pair ordering produce the same output for the same economic price
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
- token-decimal normalization
- reversed pair-order base-denominated output

Current integration validation in this repository also covers:
- vault deposit failure before oracle initialization (`NotInitialized`)
- vault deposit success after TWAP update
- vault `totalAssets()` valuation after TWAP update
- vault + V2 adapter path where `totalAssets()` remains consistent across idle-to-deployed movement under TWAP pricing
