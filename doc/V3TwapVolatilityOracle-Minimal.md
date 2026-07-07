# V3TwapVolatilityOracle Minimal Design

## Goal

Build a minimal Uniswap V3 volatility oracle that:
- reads the current spot price from a V3 pool
- reads a TWAP price from the same pool's built-in oracle
- reports spot-vs-TWAP deviation through `IVolatilityOracle.getVolatilityBps()`
- returns volatility in basis points, where `10_000 bps = 100%`

## Concepts

### Spot Price

Spot price is the current pool price. In Uniswap V3 it is exposed through `slot0()` as `sqrtPriceX96`.

Spot price can move within one block, so it should not be the only signal used for strategy selection.

### TWAP Price

TWAP means time-weighted average price.

For Uniswap V3, the pool stores cumulative tick observations. Reading:

```solidity
pool.observe([period, 0])
```

returns cumulative values at the start and end of the lookback window. The average tick is:

```text
avgTick = (tickCumulativeNow - tickCumulativePast) / period
```

That average tick is converted back to a price through `TickMath.getSqrtRatioAtTick(avgTick)`.

### Volatility Bps

This oracle defines volatility as spot-vs-TWAP deviation:

```text
volatilityBps = abs(spotPrice - twapPrice) * 10_000 / twapPrice
```

This is not statistical volatility. It does not compute standard deviation, variance, or annualized volatility. It is a practical manipulation-resistance signal for bucket selection.

## Contracts

### V3TWAPOracle

`V3TWAPOracle` is the base reader.

It owns:
- `pool`
- `getTWAP(period)`
- `_sqrtPriceX96ToPrice(sqrtPriceX96)`

Prices are returned with `1e18` scaling so small tick movements do not round down to the same integer price.

### V3TwapVolatilityOracle

`V3TwapVolatilityOracle` extends `V3TWAPOracle` and implements `IVolatilityOracle`.

It owns:
- `twapWindow`
- `getSpotPrice()`
- `getVolatilityBps()`

`getVolatilityBps()` compares current spot price against the TWAP price over `twapWindow`.

## Strategy Integration

`VolatilityBucketStrategy` only depends on:

```solidity
IVolatilityOracle.getVolatilityBps()
```

This means it can use either:
- `MockVolatilityOracle` in unit tests
- `PriceChangeVolatilityOracle` for simple price-change driven tests
- `V3TwapVolatilityOracle` for V3 spot-vs-TWAP driven bucket selection

The strategy does not know whether volatility came from a mock, a price-change oracle, or a V3 TWAP oracle.

## Current Test Coverage

The current tests cover:
- TWAP price from average tick
- spot price from current tick
- non-zero volatility when spot differs from TWAP
- zero volatility when spot equals TWAP
- revert on zero TWAP window
- revert on zero TWAP period
- `VolatilityBucketStrategy` using `V3TwapVolatilityOracle` to select the LOW bucket
- `rebalanceWithStrategy(...)` executing a bucket plan driven by `V3TwapVolatilityOracle`

## Limitations

This version does not include:
- multi-pool aggregation
- stale observation handling beyond the pool/mock behavior
- decimal normalization between arbitrary token pairs
- statistical volatility calculations
- automatic slippage minimum generation

The output is best understood as a V3 spot-vs-TWAP deviation signal.
