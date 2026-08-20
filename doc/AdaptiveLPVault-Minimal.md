# AdaptiveLPVault Minimal Design

## Goal

Build a minimal two-asset vault that:
- accepts deposits of `token0` and `token1`
- mints vault shares based on deposit value
- allows synchronous share redemption from a valuation-aware idle liquidity buffer
- queues asynchronous redemptions when venue liquidity must return to idle first
- tracks total vault assets across idle balances and registered venue positions
- supports multiple venue adapters through a simple venue registry
- supports owner-supplied rebalance plans across registered venues
- supports strategy-built rebalance plans through a configured strategy

## Scope

This version includes:
- `deposit`
- `redeem`
- asynchronous redemption request, activation, cancellation, and expiration through `RedemptionManager`, with settlement executed by the vault
- `totalAssets`
- share minting and burning
- ERC4626-style receiver/owner semantics for deposit and redeem
- oracle-based idle valuation and adapter-bound venue valuators
- venue registration through `setVenue(...)`
- manual venue deployment and withdrawal through `deployToVenue(...)` and `withdrawFromVenue(...)`
- owner- or keeper-triggered fee harvesting through `harvestVenueFees(...)`
- in-place fee compounding through `compoundVenueFees(...)` for venues that support explicit claims
- capped time-based management-fee accrual through vault-share dilution
- multi-venue asset accounting
- an owner-only delta rebalance executor that withdraws venue excess and deploys target deficits
- optional rebalance value-loss guard using `maxRebalanceValueLossBps`
- strategy-driven rebalance through `IRebalanceStrategy`
- keeper-triggered strategy rebalance through a configured `keeper`
- minimal oracle health circuit breaker for strategy-driven rebalances
- fixed-weight and volatility-bucket total-underlying allocation strategies
- reentrancy protection on user and capital-moving entrypoints
- two-step ownership transfers through OpenZeppelin `Ownable2Step`
- owner-controlled pause and unpause
- emergency exit that withdraws all venue liquidity to idle balances and pauses normal operations
- owner-controlled venue quarantine and accounting write-down for impaired positions

This version does not include:
- automatic dynamic strategy selection
- autonomous keeper resolver integration or keeper rewards
- an on-chain timer or threshold policy that decides when venue fees should be harvested or compounded, or when management fees should be accrued
- threshold-based rebalance conditions
- deposit ratio optimization
- full single-underlying-asset ERC4626 compliance
- a governance timelock, multisig policy, or separate emergency guardian role

Notes:
- the vault depends on `IPriceOracle` for prices
- `MockPriceOracle` is a test helper that exposes `setPrices(...)`
- `IPriceOracle` is read-only and exposes both `getPrices()` and `lastUpdatedAt()`
- a production version should replace the mock oracle with a real oracle implementation
- the vault rejects unset, future-dated, stale, or excessively divergent valuation data before price-dependent accounting
- production primary and reference oracles must be operationally independent and use token0 as the same numeraire
- the vault is a dual-asset share vault; it adopts ERC4626-style receiver/owner/allowance semantics, but does not implement the full ERC4626 standard because ERC4626 assumes a single underlying asset
- V2 price TWAP implementation details are documented in `doc/V2TWAPOracle-Minimal.md`
- V3 spot-vs-TWAP volatility details are documented in `doc/V3TwapVolatilityOracle-Minimal.md`
- rebalance details are documented in `doc/Rebalance-Minimal.md`
- users must approve `RedemptionManager` before it can escrow vault shares for an asynchronous request
- the vault stores only the configured manager address; FIFO queue state and escrowed shares live in `RedemptionManager`

## Ownership And Governance

The vault, fixed-weight strategy, volatility-bucket strategy, and TWAP slippage controller use OpenZeppelin `Ownable2Step`. Calling `transferOwnership(newOwner)` only records `newOwner` as the pending owner. Control changes only after that address calls `acceptOwnership()`, at which point the previous owner loses access to `onlyOwner` functions.

This protects against an accidental ownership transfer to an address that cannot operate the contracts. It does not delay actions initiated by the current owner. Sensitive configuration and capital-management calls remain immediately executable until ownership is transferred to a separately deployed timelock governed by an appropriate multisig. A production deployment should also separate delayed governance from any role that must pause the vault immediately.

## State

The vault stores:
- `token0` address
- `token1` address
- `token0` decimals
- `token1` decimals
- primary and reference valuation-oracle addresses
- separate maximum permitted price ages for both oracles
- maximum permitted primary/reference price deviation in basis points
- venue configs by `venueId`
- trusted venue valuators by `venueId`
- registered venue ids for iteration
- per-venue tracked liquidity
- total tracked liquidity across all venues
- per-venue quarantine state and recognized valuation percentage
- number of venues currently in quarantine
- ERC20 share supply and balances
- configured rebalance strategy
- configured keeper for strategy-driven rebalance execution
- management-fee recipient, annual rate, and last accrual timestamp
- strategy rebalance cooldown and gas price guard config
- paused/unpaused state inherited from OpenZeppelin `Pausable`

Venue state:
- `venues[venueId]` stores the adapter, enabled flag, and optional label
- `venueRegistered[venueId]` tracks whether a venue id has been registered
- `venueIds` is used to iterate all registered venues in `totalAssets()` and withdrawal flows; removal uses swap-and-pop, so ordering is not stable
- `venueLiquidity[venueId]` tracks liquidity reported by each adapter
- `venueValuators[venueId]` stores the trusted accounting valuator bound to the venue's current adapter
- `venueQuarantined[venueId]` marks venues isolated from new deployment after an impairment or operational incident
- `venueValuationBps[venueId]` is the percentage of valuator-reported value recognized by `totalAssets()`; healthy venues default to `10_000`
- `quarantinedVenueCount` prevents normal operations from resuming while any venue remains isolated
- `totalLiquidity` is bookkeeping only; liquidity units can differ across venues and should not be treated as asset value

Current test and example convention:
- `1`: Uniswap V2
- `2`: Uniswap V3 0.05%
- `3`: Uniswap V3 0.30%
- `4`: Uniswap V3 1.00%

These ids are not hardcoded protocol semantics. They become meaningful only after the owner registers adapters through `setVenue(...)`. `IDLE` is not a venue id; rebalance-to-idle is represented by an empty target array.

Each V3 fee tier is represented by its own adapter instance. A full Uniswap venue set therefore uses one V2 adapter plus three separate V3 adapters for the 0.05%, 0.30%, and 1.00% pools.

## Public Functions

- `constructor(name, symbol, token0, token1, decimals0, decimals1)`
  - purpose: initialize share token metadata, underlying tokens, and decimals
  - behavior: rejects zero token addresses, identical token addresses, and zero decimals

- `setPriceOracleConfig(priceOracle, maxPriceAge, referencePriceOracle, maxReferencePriceAge, maxPriceDeviationBps)`
  - purpose: atomically configure primary valuation prices, an independent reference source, freshness windows, and the deviation limit
  - behavior: rejects zero or identical oracle addresses, zero freshness windows, and deviation limits outside `(0, 10_000]`
  - requirement: both oracles return token0-denominated prices with 1e18 precision

- `setVolatilityOracle(volatilityOracle)`
  - purpose: set the volatility oracle used by strategy rebalance guards

- `setVenue(venueId, adapter, label, enabled)`
  - purpose: register or update a venue adapter
  - behavior: updating an existing venue is blocked while that venue has tracked liquidity or adapter-reported position state
  - behavior: replacing an inactive venue's adapter clears its previous adapter-specific valuator

- `removeVenue(venueId)`
  - purpose: remove an obsolete venue from the iterable registry
  - behavior: owner-only; requires the venue to be disabled with no tracked liquidity or adapter-reported position
  - behavior: clears the adapter configuration, registration state, tracked liquidity, and valuator
  - behavior: uses swap-and-pop, so callers must not rely on stable `venueIds` ordering
  - behavior: the same id may be registered again later through `setVenue(...)` without inheriting the old valuator

- `setVenueValuator(venueId, valuator)`
  - purpose: configure the trusted accounting valuator used by `totalAssets()` for an active venue position
  - behavior: owner-only; the valuator must report the venue's current adapter through `getVenueAdapter()`

- `quarantineVenue(venueId, valuationBps)`
  - purpose: isolate an impaired venue and reduce the value recognized in vault NAV
  - behavior: owner-only; disables new deployment to the venue and pauses the vault
  - behavior: accepts a recognition percentage from `0` through `10_000` basis points
  - behavior: does not delete the position or prevent recovery withdrawals

- `setQuarantinedVenueValuationBps(venueId, valuationBps)`
  - purpose: update the recognized value as recovery information changes
  - behavior: owner-only and restricted to quarantined venues

- `restoreVenue(venueId, deploymentEnabled)`
  - purpose: remove a venue from quarantine after recovery or risk review
  - behavior: resets recognized value to `10_000` basis points and optionally re-enables deployment
  - behavior: does not automatically unpause the vault

- `totalAssets()`
  - purpose: return idle value plus trusted valuator output for every active venue position
  - behavior: rejects unset, future-dated, stale, zero, or excessively divergent oracle data before valuation
  - behavior: applies each venue's recognized valuation percentage to its valuator-reported value
  - behavior: skips adapter and valuator calls for a fully written-down venue whose percentage is zero
  - returns: `uint256 assets`

- `getTotalUnderlying()`
  - purpose: return raw `token0` and `token1` amounts across idle balances and adapter-reported venue positions
  - note: intended for strategy planning and reporting; it is not used as trusted share-accounting value
  - returns: `uint256 total0, uint256 total1`

- `getIdleBufferState()`
  - purpose: report current idle value, the configured requirement, deployable excess, and any deficit
  - behavior: values idle and total vault assets with the same validated valuation prices used by share accounting
  - returns: `uint256 idleValue, uint256 requiredIdleValue, uint256 availableToDeployValue, uint256 bufferDeficit`

- `accrueManagementFee()`
  - purpose: mint elapsed management-fee shares to the configured recipient
  - behavior: permissionless and blocked while an asynchronous redemption request is processing
  - behavior: charges at most 365 days since the previous accrual; older elapsed time is waived
  - returns: `uint256 feeShares`

- `setManagementFeeConfig(recipient, annualFeeBps)`
  - purpose: configure the fee recipient and annual management-fee rate
  - behavior: owner-only; accepts at most `1,000` bps and requires a nonzero recipient when the rate is nonzero
  - behavior: accrues the prior configuration before replacing it, so elapsed fees cannot be redirected

- `deposit(amount0, amount1, receiver, minShares)`
  - purpose: transfer tokens from the caller into the vault and mint shares to `receiver`
  - behavior: blocked while the vault is paused
  - behavior: validates primary/reference freshness and deviation before calculating shares
  - behavior: reverts if minted shares are below `minShares`
  - returns: `uint256 shares`

- `redeem(shares, receiver, owner, minAmount0Out, minAmount1Out)`
  - purpose: burn `owner` shares and pay their base-denominated value from idle token balances to `receiver`
  - behavior: if the caller is not `owner`, the caller must have sufficient ERC20 share allowance from `owner`
  - behavior: uses validated valuation prices and the current idle token composition without removing venue liquidity
  - behavior: reverts with `InsufficientIdleLiquidity` when idle value cannot cover the requested redemption
  - behavior: reverts if final token outputs are below `minAmount0Out` or `minAmount1Out`
  - behavior: reverts when valuation prices are stale, invalid, or outside the configured deviation limit
  - behavior: blocked while an asynchronous request is actively processing
  - returns: `uint256 amount0Out, uint256 amount1Out`

- `RedemptionManager.requestRedeem(shares, receiver, deadline)`
  - purpose: escrow shares in a FIFO queue when current idle value cannot cover synchronous redemption
  - behavior: shares remain in total supply and exposed to vault NAV until settlement, cancellation, or expiration
  - behavior: the caller owns the request and must first approve the manager to transfer the requested shares
  - behavior: rejects requests that current idle liquidity can already cover
  - behavior: accepts deadlines no more than `MAX_REDEEM_REQUEST_DURATION` in the future
  - returns: `uint256 requestId`

- `RedemptionManager.activateNextRedeemRequest()`
  - purpose: move the FIFO queue head from `PENDING` to `PROCESSING`
  - behavior: owner or keeper only; one request may be active at a time
  - behavior: snapshots the request's proportional idle balances and venue liquidity, then blocks state-changing vault operations that would invalidate that snapshot

- `RedemptionManager.fundActiveRedeemRequest(venueId, params)`
  - purpose: withdraw the active request's snapshotted liquidity from one venue
  - behavior: owner or keeper only; successful venue funding is accumulated for the active request and failed venues can be retried independently

- `RedemptionManager.deactivateRedeemRequest()`
  - purpose: return an unfunded active request to `PENDING`
  - behavior: owner-only; unavailable after any venue funding succeeds and does not return escrowed shares

- `RedemptionManager.processNextRedeemRequest()`
  - purpose: settle the active queue head from its accumulated idle and venue funding amounts
  - behavior: permissionless after every snapshotted venue has funded; burns escrowed shares and transfers the actual accumulated token amounts
  - behavior: asynchronous requests do not expose user-level final output minimums; venue-specific execution minimums and deadlines are supplied by the owner or keeper through `params`
  - returns: `uint256 amount0Out, uint256 amount1Out`

- `RedemptionManager.cancelRedeemRequest(requestId)`
  - purpose: let the request owner cancel a `PENDING` request and recover its escrowed shares

- `RedemptionManager.expireRedeemRequest(requestId)`
  - purpose: remove an expired request that has not begun venue funding and return its escrowed shares
  - behavior: permissionless after the request deadline; a request with successful venue funding must settle instead

- `deployToVenue(venueId, amount0, amount1, params)`
  - purpose: deploy idle funds into a registered venue adapter
  - behavior: owner-only and blocked while the vault is paused
  - behavior: reverts when the requested deployment would leave less than the configured minimum idle value
  - returns: `uint256 liquidity`

- `withdrawFromVenue(venueId, liquidity, params)`
  - purpose: withdraw deployed liquidity from a specific venue back into idle balances
  - signature: `withdrawFromVenue(venueId, liquidity, params)`
  - behavior: owner-only and available while paused so the owner can reduce venue exposure
  - behavior: forwards venue-specific removal params to the adapter
  - returns: `uint256 amount0Out, uint256 amount1Out`

- `rebalance(targets, withdrawalParams)`
  - purpose: execute an owner-supplied multi-venue target plan
  - behavior: owner-only and blocked while the vault is paused
  - behavior: requires healthy primary/reference valuation oracles before execution
  - behavior: withdraws venue excess and deploys only target deficits while preserving compatible positions
  - behavior: forwards matching per-venue withdrawal params during the withdrawal phase; `targets[i].params` controls deployment into the new venue

- `setStrategy(strategy)`
  - purpose: configure the strategy used by `rebalanceWithStrategy(...)`

- `setKeeper(keeper)`
  - purpose: configure the non-admin address allowed to execute `rebalanceWithStrategy(...)`
  - behavior: owner-only; rejects the zero address
  - behavior: does not grant permission to configure venues, strategies, or manual capital-management functions

- `setRebalanceConfig(minCooldown, minVolatilityDelta, maxGasPrice)`
  - purpose: configure cooldown, volatility delta, and gas price guards for strategy-driven rebalances
  - behavior: enabling or disabling the volatility delta guard clears any previously recorded volatility baseline

- `setMaxRebalanceValueLossBps(maxRebalanceValueLossBps)`
  - purpose: configure the maximum total-value loss allowed during rebalance
  - behavior: `0` disables the guard; non-zero values are interpreted in basis points
  - behavior: only limits downside loss and does not reject value increases

- `setMinIdleBufferBps(minIdleBufferBps)`
  - purpose: configure the minimum share of total vault value that must remain idle
  - behavior: accepts values from `0` through `10_000` basis points
  - behavior: increasing the requirement does not automatically withdraw active positions; it reports a deficit and blocks deployments that would violate the new requirement

- `setOracleHealthCheckEnabled(enabled)`
  - purpose: require a configured volatility oracle before strategy-driven rebalances
  - behavior: when enabled, `rebalanceWithStrategy(...)` reverts if `volatilityOracle` is not set

- `checkSystemHealth()`
  - purpose: expose a simple status for keepers and monitoring
  - returns: `NORMAL`, `ORACLE_STALE`, `ORACLE_DEVIATION`, or `PAUSED`
  - behavior: reports missing, invalid, future-dated, or expired valuation data as `ORACLE_STALE`
  - behavior: reports primary/reference divergence above the configured limit as `ORACLE_DEVIATION`

- `canRebalanceWithStrategy()`
  - purpose: expose whether strategy-driven rebalance currently passes vault-level guards
  - returns: `bool allowed` and a `RebalanceGuardFailure` code; `NONE` means `allowed` is true
  - behavior: checks strategy configuration, pause state, cooldown, gas price, oracle health, and volatility delta guards
  - behavior: returns machine-readable guard codes rather than onchain human-readable strings; keepers and frontends map codes to local text
  - behavior: does not call `strategy.buildTargets(...)` and does not guarantee the strategy plan can be built or executed

- `rebalanceWithStrategy(data, withdrawalParams)`
  - purpose: ask the configured strategy for a target plan and execute it
  - behavior: callable by the owner or configured keeper and blocked while the vault is paused
  - behavior: applies strategy guards, then reuses the same rebalance execution path with matching withdrawal params

- `pause()`
  - purpose: pause deposits, venue deployment, and normal rebalance operations
  - behavior: owner-only; redemptions, direct venue withdrawals, and fee harvesting remain callable
  - behavior: redemptions still require valid valuation prices and sufficient idle liquidity
  - behavior: fee compounding remains blocked because it redeploys idle assets into a venue

- `unpause()`
  - purpose: resume deposits, venue deployment, and normal rebalance operations
  - behavior: owner-only

- `emergencyExit(withdrawalParams)`
  - purpose: pause the vault and attempt to withdraw all tracked venue liquidity
  - behavior: owner-only and processes each active venue through an isolated external self-call
  - behavior: a failed venue remains deployed and emits `EmergencyExitFailed` while healthy venues continue exiting

## Core Flows

### deposit

1. Reject if both deposit amounts are zero.
2. Require an oracle.
3. Accrue elapsed management fees before reading share supply or calculating deposit shares.
4. Read `totalAssets()` before the deposit.
5. Read `totalSupply()` before the deposit.
6. Convert the deposit amounts into a single base-denominated value using `VaultMath`.
7. Calculate gross shares using `VaultMath.calculateShares`.
8. On the initial deposit, require gross shares to exceed `MINIMUM_LOCKED_SHARES`, reserve that amount for the permanent lock, and return the remainder as user shares.
9. Revert if user shares are below `minShares`.
10. Transfer `token0` and `token1` from the caller into the vault.
11. On the initial deposit, mint `MINIMUM_LOCKED_SHARES` to `LOCKED_SHARES_RECEIVER`.
12. Mint the remaining shares to `receiver`.

Deposits are disabled while the vault is paused.

The permanent initial-share lock prevents a first depositor from owning 100% of supply with a tiny deposit and then using a direct token donation to make later deposits round down to zero shares. Once initialized, the vault retains the locked supply and its proportional backing even after all redeemable user shares have exited.

### redeem

1. Reject if `shareToRedeem` is zero.
2. Reject if `receiver` or `owner` is the zero address.
3. Revert if `shareToRedeem` exceeds `owner`'s share balance.
4. If the caller is not `owner`, spend the caller's ERC20 share allowance from `owner`.
5. Accrue elapsed management fees before snapshotting the redeemed share ratio.
6. Read `totalSupply()` before burning.
7. Read validated primary/reference valuation prices and compute total vault value.
8. Convert the redeemed shares into a base-denominated `redeemValue`.
9. Value current idle balances and revert with `InsufficientIdleLiquidity` if they cannot cover `redeemValue`.
10. Preserve the idle token ratio while converting `redeemValue` into `amount0Out` and `amount1Out`.
11. Revert with `RedeemAmountTooSmall` if both token outputs round down to zero.
12. Revert if final token outputs are below `minAmount0Out` or `minAmount1Out`.
13. Burn `owner`'s shares.
14. Transfer `token0` and `token1` to `receiver`.

Synchronous redemption never harvests fees or removes venue liquidity. Large redemptions use `RedemptionManager`, which funds the active request from each snapshotted venue in separate transactions.

Redemptions remain callable while the vault is paused, but still require valid valuation prices and sufficient idle liquidity.

### asynchronous redemption

1. After approving `RedemptionManager`, the user calls `requestRedeem(shares, receiver, deadline)`; when no request is active, the manager first accrues management fees, then verifies that idle value is insufficient, appends the request to its FIFO queue, and escrows the caller's shares.
2. The vault owner or keeper calls `RedemptionManager.activateNextRedeemRequest()`; the manager accrues management fees before marking the queue head as `PROCESSING`.
3. Activation snapshots the request's proportional idle balances and each active venue's proportional liquidity. While active, operations that can change share supply, idle balances, or venue positions are blocked.
4. Owner or keeper calls `fundActiveRedeemRequest(venueId, params)` once per snapshotted venue. A failed venue call does not roll back successful funding from other transactions.
5. After every snapshotted venue has funded, any caller may call `RedemptionManager.processNextRedeemRequest()`.
6. The manager calls `AdaptiveLPVault.settleQueuedRedeem(...)`; the vault burns the manager's escrowed shares and transfers the request's accumulated actual amounts to the receiver. The manager then finalizes and unlinks the request.
7. A request owner may cancel while it is `PENDING`. After its deadline, anyone may expire an unfunded `PENDING` or `PROCESSING` request. A partially funded request must finish funding and settle.

Pending requests do not reserve idle liquidity. Reservation begins only when the queue head is activated. Asynchronous requests intentionally do not use a user-level final output minimum: a multi-transaction, per-venue funding flow cannot safely enforce one without an epoch or batch settlement design. Keepers must apply per-venue execution constraints through the supplied adapter params.

### Management fee

Management fees are charged by minting new vault shares to the configured recipient rather than withdrawing underlying tokens. The annual rate is stored in basis points and capped at `1,000` bps. This dilutes existing shares proportionally while leaving the underlying asset balances unchanged.

`deposit`, synchronous `redeem`, manual `rebalance`, and strategy-driven `rebalanceWithStrategy` accrue fees before share-sensitive accounting. `RedemptionManager` also accrues before queue admission when no request is active and before it activates the queue head. Once a request is `PROCESSING`, accrual and fee-configuration changes are blocked because that funding round relies on a fixed total-share snapshot.

The first accrual only records `lastAccrual`. Each later accrual charges no more than 365 days of elapsed time and advances `lastAccrual` to the current block timestamp. If more than one year elapsed, the older time is intentionally waived rather than accumulated as historical fee debt. Anyone may call `accrueManagementFee()` when no redemption request is processing; off-chain automation may call it periodically, but this version does not include an on-chain scheduler.

### totalAssets

1. Require an oracle.
2. Read prices that share configured token0 as their common numeraire.
3. Value idle token balances directly with those prices.
4. Iterate active venues and require a configured `IVenueValuator` for each position.
5. Add each valuator's base-denominated result to the idle value.

Current valuators:
- `V2FairValueValuator` oracle-values pair reserves and applies a geometric-mean fair LP value before scaling by the adapter's LP share.
- `V3TwapPositionValuator` computes principal at a historical TWAP tick, adds position-manager-tracked owed tokens, and applies the vault's oracle prices.

### getTotalUnderlying

1. Read idle `token0` and `token1` balances held by the vault.
2. Iterate all registered `venueIds`.
3. For each configured adapter, call `adapter.getPositionValue()`.
4. Sum idle balances and deployed venue amounts.

### deployToVenue

1. Require the venue to be registered and configured with an adapter.
2. Require the venue to be enabled.
3. Require a trusted valuator configured for the venue's current adapter.
4. Value the requested deployment conservatively and require the remaining idle value to satisfy `minIdleBufferBps`.
5. Temporarily approve the adapter to pull the requested token amounts.
6. Call `adapter.addLiquidity(amount0, amount1, params)`.
7. Increase `venueLiquidity[venueId]` and `totalLiquidity`.
8. Reset adapter allowances back to zero.

### idle liquidity buffer

The vault expresses its minimum idle reserve in basis points of current total value:

```text
requiredIdleValue = ceil(totalAssets * minIdleBufferBps / 10_000)
availableToDeployValue = max(idleValue - requiredIdleValue, 0)
bufferDeficit = max(requiredIdleValue - idleValue, 0)
```

The deployment guard uses the requested token amounts before calling an adapter. This is intentionally conservative because an adapter may later return unused dust. Manual deployment, manual rebalance, strategy rebalance, and fee compounding all reach the same `_deployToVenue(...)` check.

The buffer reserves liquidity for redemptions; it does not prevent a valid redemption from consuming idle balances. Raising the configured requirement while capital is already deployed does not force an immediate withdrawal. Instead, `getIdleBufferState()` reports the deficit and subsequent deployment attempts remain blocked until the buffer is restored.

### withdrawFromVenue

1. Require the venue to be registered and configured with an adapter.
2. Reject zero liquidity.
3. Require enough tracked liquidity for that venue.
4. Collect claimable venue tokens before removing liquidity.
5. Call `adapter.removeLiquidity(liquidity, params)`.
6. Return the sum of collected tokens and removed liquidity proceeds.
7. Decrease `venueLiquidity[venueId]` and `totalLiquidity`.

Manual rebalances can pass per-venue withdrawal params through `rebalance(targets, withdrawalParams)`. Strategy-driven rebalances can pass caller-supplied per-venue withdrawal params through `rebalanceWithStrategy(data, withdrawalParams)`. Synchronous user redemption does not remove venue liquidity and therefore does not accept withdrawal params. Automatic strategy-side generation of remove-liquidity minimums remains a separate interface design task.

### Fee Harvest and Compounding

`harvestVenueFees(venueId)` lets the owner or keeper collect claimable venue tokens into vault idle balances without removing liquidity. It remains available while paused because it only recovers assets from a venue.

`compoundVenueFees(venueId, params)` collects claimable tokens and redeploys them into the same enabled venue in one transaction. It is paused with other deployment operations. For an active V3 adapter with matching tick params, this uses `increaseLiquidity` on the existing NFT rather than withdrawing and minting a new position. Any unused token dust is returned to vault idle balances by the adapter.

Compounding passes through the same idle-buffer check as every other deployment. If redeploying all collected amounts would violate the configured buffer, the transaction reverts atomically and the venue tokens remain uncollected until a later harvest or compound transaction succeeds.

Uncollected venue fees remain part of trusted venue valuation. `redeem(...)` does not collect them; it pays the redeemed share value from existing idle balances. Harvesting and compounding remain explicit owner/keeper operations.

Harvesting and compounding are permissioned execution operations, not self-executing timers. An owner or configured keeper must submit the transaction after applying its own frequency, gas-cost, and slippage policy.

### harvestVenueFees

1. Require the caller to be the owner or configured keeper.
2. Require a registered venue with a configured adapter.
3. Return zeroes when the venue has no active position or owed tokens.
4. Call `adapter.collectFees()` and leave tracked venue liquidity unchanged.

### compoundVenueFees

1. Require the caller to be the owner or configured keeper and require the vault not to be paused.
2. Collect claimable venue tokens through the same harvest helper.
3. Revert `NoFeesToCompound` when both collected token amounts are zero.
4. Deploy the collected amounts back into the same venue using caller-supplied add-liquidity params.
5. Increase tracked venue liquidity by the adapter-reported amount and emit `FeeCompounded`.

### rebalance

1. Accrue elapsed management fees before rebalance accounting.
2. Reject duplicate venue targets.
3. Validate every non-zero target points to a registered and enabled venue.
4. Collect claimable venue tokens into idle balances.
5. Fully withdraw venues omitted from the plan, assigned a zero target, or incompatible with target structure.
6. Proportionally withdraw only excess liquidity from compatible venues.
7. Deploy only the token deficits needed to approach each non-zero target.
8. Revert `NoRebalanceNeeded` if neither withdrawal nor deployment moved funds.
9. Verify share supply did not change.
10. If `maxRebalanceValueLossBps` is non-zero, verify post-rebalance `totalAssets()` did not fall below the configured loss threshold.

An empty target array means "withdraw all venues to idle". It only succeeds if there is tracked liquidity to withdraw.

The value-loss guard is downside-only. A rebalance that increases `totalAssets()` is allowed, but large positive deviations without fees, donations, or price movement should be investigated in tests or monitoring as a possible accounting issue.

### rebalanceWithStrategy

1. Require the caller to be the owner or configured keeper.
2. Require a configured strategy.
3. Enforce `minCooldown` and `maxGasPrice`; enforce `minVolatilityDelta` only when a valid volatility baseline exists.
4. Call `strategy.buildTargets(address(this), data)`.
5. Execute the returned targets through the same internal rebalance flow, forwarding matching withdrawal params while exiting active venues.
6. Update `lastRebalance` only after successful execution.
7. If the volatility guard is enabled, update `lastRebalanceVolatilityBps` and mark the baseline initialized after successful execution.

The first successful strategy rebalance after the volatility delta guard is enabled establishes the baseline and is not compared against Solidity's default zero value. Replacing the volatility oracle or toggling the delta guard invalidates the old baseline. `lastRebalance` is tracked separately because a rebalance performed while the delta guard was disabled does not create a volatility baseline.

The keeper role is execution-only. It can trigger the already configured strategy path, but it cannot change oracles, strategies, venues, manual target plans, pause state, or emergency-exit behavior.

The current concrete strategies are:
- `FixedWeightStrategy`, which applies one configured set of venue weights
- `VolatilityBucketStrategy`, which selects LOW, MEDIUM, or HIGH venue weights from an `IVolatilityOracle` value and can generate dynamic V3 tick-range params for configured V3 venues

Both strategies operate on total vault underlying amounts reported by `getTotalUnderlying()`, meaning idle balances plus adapter-reported deployed position amounts. A strategy rejects its selected plan when total venue weight exceeds `10_000 - vault.minIdleBufferBps()`. The vault then treats accepted amounts as final per-venue targets, moves only excesses and deficits, and performs the exact value-based idle-buffer check during deployment. `VolatilityBucketStrategy` reads volatility from a configured oracle; `rebalanceWithStrategy(data, withdrawalParams)` still forwards opaque data for other strategy implementations, but the current volatility bucket strategy does not use it.

Delta comparisons currently use exact raw token amounts. Real V3 mint and increase operations may return rounding dust, so repeated identical strategy execution must be checked in mainnet-fork tests before choosing a production dust-tolerance threshold.

`VolatilityBucketStrategy` can optionally map a venue id to a `V3TickCalculations` contract. When a target venue has a configured calculator, the strategy encodes fresh `UniswapV3Adapter.LiquidityParams` with tick bounds calculated from current pool tick, pool `tickSpacing()`, and the current `volatilityBps`.

The strategy can also use a configured `TwapSlippageController` plus per-venue slippage params to generate `amount0Min` and `amount1Min` for dynamic V3 targets. Each controller venue id is bound to a V3 adapter, and the controller derives its validation pool from that adapter rather than from caller-supplied params. Before requesting minimum amounts, the strategy verifies that the controller-bound adapter is the same adapter registered by the vault for that venue id. The controller then checks current V3 spot price against TWAP, rejects excessive spot/TWAP deviation, and applies the configured bps haircut to desired token amounts.

V2 targets do not use the V3 TWAP controller. They retain their venue-specific `UniswapV2Adapter.LiquidityParams`, so V2 execution does not assume that a separate V3 pool remains synchronized with the V2 pair. When no slippage controller is configured, dynamic V3 targets preserve the legacy zero-minimum behavior; when a controller is configured, a dynamic V3 target must also have venue slippage params.

The strategy-driven path is covered for V3 entry and exit. A volatility-bucket target can deploy idle vault balances into a registered V3 venue through `rebalanceWithStrategy(...)`, and existing V3 positions can be exited during a strategy rebalance with caller-supplied withdrawal params.

Current concrete volatility oracle implementations include:
- `PriceChangeVolatilityOracle`, which reads `price0` and `price1` from an `IPriceOracle`, enforces a minimum interval between samples, compares them with the previous sampled prices, and reports the larger absolute price change in basis points
- `V3TwapVolatilityOracle`, which reads a Uniswap V3 pool's spot price from `slot0()`, reads a time-weighted average price through `observe(...)`, and reports the spot-vs-TWAP deviation in basis points

Both implementations expose the same `IVolatilityOracle.getVolatilityBps()` interface. `VolatilityBucketStrategy` does not need to know how the volatility value was produced.

### pause and emergency exit

The vault uses OpenZeppelin `Pausable` as an emergency operations switch.

Paused state blocks normal capital entry and allocation operations:
- `deposit`
- `deployToVenue`
- `rebalance`
- `rebalanceWithStrategy`

Paused state does not block exit-oriented operations:
- `redeem`
- asynchronous redemption request management and settlement
- `withdrawFromVenue`
- `emergencyExit`

For fault-isolated recovery, the owner calls `emergencyExit(withdrawalParams)`. The function pauses the vault before making adapter calls and processes each active venue through an external self-call. `try/catch` keeps a reverting venue deployed, emits `EmergencyExitFailed`, and continues withdrawing healthy venues. An active asynchronous request blocks this operation because emergency withdrawal would invalidate its request-specific funding snapshot. Normal delta rebalances remain atomic, so any failed venue operation reverts the complete rebalance.

## Failure Cases

The vault should revert when:
- constructor token addresses are zero or identical, or either decimals value is zero
- both deposit amounts are zero
- the oracle is not configured
- a non-zero deposit would mint zero shares or fewer shares than `minShares`
- `redeem` is called with zero shares
- `redeem` is called with more shares than the user owns
- `deposit`, `deployToVenue`, `rebalance`, or `rebalanceWithStrategy` is called while paused
- a non-owner calls `pause`, `unpause`, `emergencyExit`, or owner-only capital management functions
- a non-owner calls owner-only functions
- a caller that is neither owner nor keeper calls `rebalanceWithStrategy`
- a venue operation references an unset venue
- a venue operation references a disabled venue
- a venue withdrawal requests zero liquidity
- a venue withdrawal exceeds tracked liquidity
- a venue update is attempted while that venue has active liquidity
- a rebalance plan contains duplicate venue ids
- a rebalance plan requires more token balance than available after withdrawals
- rebalance cannot move any funds
- strategy-driven rebalance is called before a strategy is configured
- strategy-driven rebalance violates cooldown, volatility delta, or max gas price guards
- volatility delta guard is enabled before a volatility oracle is configured
- redeem output is below `minAmount0Out` or `minAmount1Out`
- an asynchronous request is submitted when idle liquidity can already cover it
- an asynchronous request uses an invalid deadline, or an unfunded request is activated or processed after expiry
- queue activation is attempted without a pending head or while another request is active
- asynchronous settlement is attempted before every snapshotted venue has funded

## Invariants

These conditions should always hold:
- the initial deposit creates gross shares equal to deposit value, locks `MINIMUM_LOCKED_SHARES`, and gives the remainder to the receiver
- initialized vault supply never falls below `MINIMUM_LOCKED_SHARES`
- non-zero deposits must not mint zero shares
- `totalAssets()` reflects idle balances plus each active venue's trusted valuator output multiplied by its recognized valuation percentage
- redeeming shares reduces the user's share balance and total share supply
- redeeming shares uses idle balances and leaves active venue liquidity unchanged
- queued shares remain in total supply while held in `RedemptionManager` escrow
- only the FIFO queue head can enter `PROCESSING` and be settled
- failed asynchronous settlement does not burn escrowed shares or unlink the request
- processed, cancelled, and expired requests are unlinked and reduce `totalPendingRedeemShares`
- per-venue liquidity and total tracked liquidity stay in sync with deploy and withdraw flows
- rebalance reuses the same deploy and withdraw helpers as manual venue operations
- strategy-built plans pass through the same validation as manual rebalance plans
- failed strategy-driven rebalances do not update `lastRebalance`

## Test Plan

Vault basics:
- initial deposit locks `MINIMUM_LOCKED_SHARES` while preserving gross share supply
- a first depositor cannot profit from the covered direct-donation attack scenario
- subsequent deposit mints proportional shares
- deposit transfers tokens into the vault
- `totalAssets()` returns the combined vault value
- deposit reverts when both amounts are zero
- deposit reverts when share calculation returns zero shares
- redeem burns shares and returns underlying assets
- redeem reverts when shares is zero
- redeem reverts when the user has insufficient shares

Venue integration:
- `setVenue(...)` registers V2 and V3 adapters
- deployment reverts when venue is unset or disabled
- deployment tracks per-venue liquidity
- withdrawal reduces per-venue liquidity and total liquidity
- `totalAssets()` includes directly valued idle balances and trusted V2/V3 venue valuations
- idle-buffer redemption leaves V2, V3, and multi-venue positions unchanged
- redemption reverts without burning shares when idle value is insufficient
- redemption reverts when both token outputs round down to zero
- asynchronous redemption escrows shares, activates the queue head, and settles permissionlessly after liquidity returns
- cancelling a middle request preserves the surrounding FIFO links
- minimum-output failure preserves an active request until it is processed, deactivated, or expired
- independent V2 and V3 withdrawals can fund one request across separate transactions even when one venue initially fails
- harvesting returns claimable V3 tokens to idle balances without removing the active position
- compounding increases an existing V3 position without changing its `tokenId` or vault share supply
- rebalance and manual withdrawal forward per-venue withdrawal params to V2 and V3 adapters
- venue updates are blocked while the target venue is active

Rebalance coverage:
- rebalance remains owner-only
- rebalance can deploy to V2
- rebalance can deploy to V3
- rebalance can split capital across multiple venues
- rebalance can move only the required delta between existing venues
- rebalance preserves a compatible V3 NFT and rebuilds it only when its tick range changes
- rebalance can withdraw all venues back to idle
- rebalance rejects duplicate venue targets
- rebalance rejects plans that exceed available balances
- rebalance reverts when there is no liquidity to move
- strategy-driven rebalance executes a fixed-weight plan
- strategy-driven rebalance executes a volatility-selected plan
- volatility-selected plans can generate dynamic V3 tick-range params for configured V3 venues
- strategy-driven rebalance can deploy into a V3 venue with dynamic tick and slippage params
- strategy-driven rebalance can exit an active V3 venue and forward V3 withdrawal params
- strategy-driven rebalance can move already-deployed capital from one venue to another
- configured keeper can execute strategy-driven rebalance
- unauthorized callers cannot execute strategy-driven rebalance
- strategy-driven rebalance enforces cooldown and max gas price guards

This list is intentionally high-level. Concrete unit tests may expand each topic into symmetric branches, invalid-input paths, and edge cases.
