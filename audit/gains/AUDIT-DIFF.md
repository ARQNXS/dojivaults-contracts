# Gains vs round 4: audit diff

Stage 1 of PLAN.md. For each file in `contracts/src/gains/`: what was copied unchanged from round 4, what was removed, what changed and what is new, and why. Diff a pair with `git diff --no-index contracts/src/<round4>.sol contracts/src/gains/<gains>.sol`.

The round 4 sources are untouched: `git diff main -- contracts/src ':!contracts/src/gains'` is empty.

Branch `feat/gains-venue`. Base: round 4 at main `4b01e8e`. Updated for the four post-acceptance fixes (operator reduce bound, feed rotation, branch coverage, `MAX_POSITIONS = 20`); they are marked "(fix)" below.

## Map

| Gains file | Round 4 counterpart | Lines (round 4 → Gains) | `git diff --no-index` |
|---|---|---|---|
| `GainsTypes.sol` | `VaultTypes.sol` | 271 → 215 | +61 −117 |
| `IGainsDiamond.sol` | `hypercore/HyperCore.sol` | 185 → 237 | new venue interface |
| `GainsPrice.sol` | mark price reads in `HyperCore.sol` | → 93 | new |
| `GainsNav.sol` | `VaultMath.coreEquity` | → 212 | new |
| `GainsVaultMath.sol` | `VaultMath.sol` | 261 → 236 | +46 −71 |
| `GainsVaultLogic.sol` | `VaultLogic.sol` | 644 → 747 | +329 −226 |
| `GainsVaultGovernance.sol` | `VaultGovernance.sol` | 415 → 410 | +61 −66 |
| `GainsVault.sol` | `HyperVault.sol` | 628 → 628 | +141 −141 |
| `GainsVaultPolicy.sol` | `VaultPolicy.sol` | 372 → 451 | +154 −75 |
| `GainsVaultFactory.sol` | `HyperVaultFactory.sol` | 449 → 488 | +78 −39 |
| `GainsVaultLens.sol` | `HyperVaultLens.sol` | 242 → 284 | +79 −37 |

Most of the `+/−` count in GainsVaultLogic and GainsVault is code moved, not logic changed: the bridging section is removed and the trading section replaced.

The Gains files import the shared round 4 definitions from `VaultTypes.sol` rather than copying them:
- the constants;
- `BreachReason`, `EpochResult`, `Request`;
- `IVaultFactory`.

What the reviewer needs to check in depth:
- `GainsNav.sol`
- `GainsPrice.sol`
- the trading section of `GainsVaultLogic.sol`
- `GainsVaultPolicy.checkOrder` and the NAV bound
- `GainsVaultGovernance.initialize` and `_check`

Everything else is round 4 with HyperCore removed.

## Exit rule (PLAN.md section 1)

`closeTrade`, `reduceTrade`, `cancelOrder`, `cancelTimedOut` and `flatten` never call GainsNav or GainsPrice. They also never call the policy's `price` / `navPrice`. The only diamond reads they make are `getTrade(s)`, `getPendingOrders` and `getTradeInfo`, which are plain storage views. `flatten` also reads `policy.flattenSlippage`, which is config only.

This is proven by:
- `test/gains/GainsExits.t.sol`: every feed stale, the ETH feed reverting and the sequencer down; `vm.expectCall(..., 0)` on the feeds and on `price` / `navPrice`;
- `invariant_exitsAlwaysCallable` (336 random outages per campaign);
- `test_fork_exitsWithTheSequencerDownAndFeedsBroken`, run against the real diamond.

`setSlTp` (SL tightening) and the depositor exits (`requestRedeem`, `cancelRedeemRequest`, `claim`) read no price either.

(fix) The operator's `reduceTrade` outside a breach is bounded by the redemption shortfall, which is computed without a price: the pending redemptions are valued at the checkpoint NAV (see GainsVaultMath). The exit rule therefore still holds for every caller.

## File by file

### GainsTypes.sol (vs VaultTypes.sol)

- **Reused unchanged (imported from VaultTypes.sol):**
  - every fee, timelock, grace, deposit, cooldown and share constant;
  - `BreachReason`, `EpochResult`, `Request`, `IVaultFactory`.
- **VaultStorage:** round 4's struct with the shared fields in the same order.
  - `coreDepositWallet` becomes `diamond`, and `collateralIndex` (uint8) is added.
  - Removed: the bridge window (`equityAtBridge`, `bridgeAmount`, `lastBridgeBlock`) and the R-02 landing state (`bridgeToCoreDir`, `bridgeLanded`, `coreAtBridge`, `spotAtBridge`, `evmAtBridge`, `evmInSinceBridge`, `evmOutSinceBridge`).
  - Why: Gains has no bridge. Collateral in flight is a pending order on the diamond. It is valued by GainsNav and blocks settle.
- **InitParams:**
  - `coreDepositWallet` becomes `diamond`.
  - `seedUsdc` is removed: the factory transfers the seed into the vault, where it is idle USDC. There is no Core account to open.
- **Events:**
  - Same names and fields for every deposit, settle, fee, risk, role, timelock and hosting event.
  - Removed: `BridgedToCore`, `BridgedToEvm`, `CoreGasFunded`, `UsdMoved`, `AgentSynced`, and HL `OrderSent`.
  - `Flattened` keeps its name with Gains fields: `(pairIndex, index, expectedPrice, caller)`.
  - New: `TradeRequested`, `CloseRequested`, `ReduceRequested`, `IncreaseRequested`, `LeverageUpdateRequested`, `SlTpUpdated`, `OrderCancelled`, `TimeoutCancelled`.
- **Errors:**
  - Same set, minus `BridgeInFlight`, `BridgeTooSmall` and `CoreAccountInactive`.
  - New: `OrdersPending`, `SlNotTighter`, (fix) `TooManyPositions(openPositions, maxPositions)` (was `TooManyOrders()`), `ReduceAboveShortfall(shortfall, collateralDelta)` and `PolicyMismatch()`.
  - Listed for the ABI (raised in GainsPrice): `PriceStale(pairIndex)`, `SequencerDown`, `NoPriceFeed(pairIndex)`.
- **New constants:**
  - (fix) `MAX_POSITIONS = 20` (was `MAX_OPEN_ORDERS = 10`): open trades + resting orders + pending orders. A gas-safety ceiling, not a strategy limit: only `openTrade` (market, limit, stop) and `increaseTrade` are refused at it, never an exit. It bounds the NAV gas (see Gas).
  - `MIN_COLLATERAL_FEE_MULTIPLE = 5`: Gains' hard minimum (STAGE0.md A5).
- **New struct:** `OpenParams`, one argument for `openTrade`.

### IGainsDiamond.sol (replaces HyperCore.sol as the venue layer)

- The interface subset of PLAN.md section 2, taken from the Stage 0 SDK-generated `IGainsDiamondSpike.sol`, with the same structs and field order.
- Added: `ChainlinkRequested` / `ChainlinkFulfilled` (missing from SDK 1.8.10), `updateMaxClosingSlippageP` (used by flatten) and `getTradeFeeParams` (cancel gov fee).
- `library GTrade` holds:
  - the precisions;
  - trade types 0–2 and order types 0–13;
  - the contracts versions;
  - `positionSize`;
  - `l2BlockNumber()`: ArbSys on 42161 / 421614, used only by the lens timeout view.

### GainsPrice.sol (new; replaces the mark price precompile)

- `read(Feed, sequencer, grace, pair)` returns Chainlink in 1e10.
  - The staleness limit is per feed (`maxAge` = heartbeat + margin).
  - The sequencer must be up and past its grace period.
  - Reverts: `PriceStale(pair)` (missing, reverting, malformed, zero or negative, future-dated or stale feed, or an answer that does not fit a uint64 1e10 price), `SequencerDown()` (down, grace period, or not started) and `NoPriceFeed(pair)`.
  - (fix) The uint64 fit is checked before scaling a feed with fewer than 10 decimals, so an absurd answer reverts `PriceStale(pair)` instead of an arithmetic panic (found by the branch coverage tests).
  - Feeds are read with a low-level staticcall, so a broken feed never surfaces as an undecodable revert (the `0xeb8d043a` lesson).
- `adverse(mid, band, long)` returns the valuation price of PLAN.md 4.3 step 4.
- `Feed` packs feed, maxAge, band and decimals into one slot. Decimals are read once, at curation.

### GainsNav.sol (new; replaces VaultMath.coreEquity)

`snapshot(diamond, policy, collateralIndex)` is an external library that runs in the vault. It returns `value`, `notional`, `orders` and `pending`.
- **Resting limit/stop orders:** collateral in full, notional collateral × leverage.
- **Pending orders that hold collateral** (market open, partial open, leverage decrease): collateral minus Gains' minimum gov fee, which is what a callback cancel keeps. This is computed as `getMinGovFeeCollateral` with the no-tier fee and is exact on the fork (`test_fork_callbackCancelledOpenValuedNetOfTheGovFee`).
  - Pending closes leave the trade valued as open.
  - Timed-out orders count until cancelled.
- **Open trades:** Gains' close path at P = the adverse band edge:
  - fixed spread, skew (v10) and two-pass cumulative-volume impact, as `TradingCommonUtils.getTradeClosingPriceImpact`;
  - pnl% floored at −100%;
  - closing fee on max(position, min position) without fee tier;
  - holding fees at P;
  - plus `totalRealizedPnl`;
  - floored at 0;
  - 0 within the band of the liquidation price.
  - This is the Stage 0 `NavCalc` (exact on 7 fork cases, 10 mainnet closes and the Arbitrum One run) with the band, the no-tier fee and the liquidation band applied.
- Prices are cached per pair within one snapshot.

### GainsVaultMath.sol (vs VaultMath.sol)

- **Unchanged:**
  - the OpenZeppelin storage access (`erc20`, `owner`, `totalSupply`, `balanceOf`, `mint`, `burn`, `transfer`, `spendAllowance`);
  - `idleAssets`, `hardStop`, `priceAt`, `toShares`, `toAssets`, `sharePrice`, `epochOverdue`;
  - `claimable`, `claimableWithCarry`, `emergencyFillBps`.
- **Removed:** `coreEquity`, `bridgeInFlight`, `bridgeUnlanded`, `bridgePending`, `bridgeArrived`, `coreSpotUsd`.
- **Changed:** `totalAssets = idleAssets + GainsNav.value`. There is no in-window snapshot.
- **New:**
  - `venue()`: the GainsNav snapshot.
  - `ordersPending()`: a plain `getPendingOrders` length. It reads no price, so it is safe on exit paths.
  - (fix) `redemptionShortfall()`: USDC owed to the redemptions (`pendingRedeemShares` at the checkpoint NAV + `claimableRedeemAssets`) beyond the vault's USDC net of queued deposits and the collateral of closes already in flight (`MARKET_CLOSE`, collateral `MARKET_PARTIAL_CLOSE`). No price read.

### GainsVaultLogic.sol (vs VaultLogic.sol)

- **Unchanged logic:**
  - `requestDeposit`, `requestRedeem`, `cancelDepositRequest`, `cancelRedeemRequest`, `claim`, `_claimIfSettled`, `_rejoinCarry`;
  - insider deferral (R3-02), `_lossBreach`, `_treasury`, `_platform`;
  - the three settle modes (normal, redemption-only, exit-only), with min(NAV, checkpoint) pricing, partial fill + return, carry runs, the insider minimum age and the fee rules;
  - the checkpoint helpers, `leaveHosted`, `lowerProtocolShare`, the factory agent binding check (`_storeAgent`) and the reentrancy guard.
- **Removed:**
  - the `evmInSinceBridge` / `evmOutSinceBridge` bookkeeping in the depositor flow;
  - `bridgeToCore`, `bridgeToEvm`, `_openWindow`, `_arm`, `_syncBridge`, `syncBridge`, `_depositToCore`, `seedCore`, `fundCoreGas`, `moveUsd`;
  - HL `placeOrder` / `cancelOrder` / `flatten`;
  - `initAgent` and `syncAgent`;
  - the HyperCore api-wallet writes in set/revoke agent.
- **Changed:**
  - `settle`:
    - `if (ordersPending) revert OrdersPending()` takes the place of `_syncBridge` / `BridgeInFlight`, for every mode.
    - The venue is valued once per settle (NAV = idle + that value at every step), where round 4 read `totalAssets()` three times. The values are identical; it saves two GainsNav passes (settle at 10 trades: 11.8M → 4.5M gas).
  - `_accrueFees` takes that venue value and uses `priceAt(assets, supply)` where round 4 used `sharePrice()`. The value is identical, because minting moves no assets.
  - `revokeAgent` clears the slot. The agent is a vault caller only, so there is no Core slot to overwrite.
- **New (trading, PLAN.md 4.2):**

  | Function | Callers | Checks |
  |---|---|---|
  | `openTrade(OpenParams)` | manager, agent | not paused, not breached / emergency, fewer than MAX_POSITIONS positions, collateral ≤ idle net of reserves, `policy.checkOrder` (NAV and open notional from GainsNav), exact approval cleared after the call, referrer 0 |
  | `increaseTrade` | manager, agent | same (including the MAX_POSITIONS ceiling); notional delta = (collateralDelta or the existing collateral) × leverageDelta, as Gains computes it |
  | `updateLeverage` | manager, agent | Lower: pulls `collateral × lev / newLev − collateral` from idle (exact approval). Refused in a loss breach or full stop, allowed in a leverage breach (the R3-04 analog). Raise: as a new exposure |
  | `closeTrade`, `reduceTrade` | manager, agent, guardian at any time; owner, operator, sentinel while breached / emergency | no NAV or price read |
  | `reduceTrade` by the operator outside a breach / emergency (fix) | operator | a collateral reduce only (`leverageDelta` 0), and only while `redemptionShortfall() > 0`, of at most that shortfall plus a fee allowance of 2% + 1 USDC (`operatorReduceCap`, Stage 3), computed at the request (`ReduceAboveShortfall(shortfall, collateralDelta)` otherwise). `closeTrade` stays breach / emergency only for the operator |
  | `setSlTp` | manager, agent; the sentinel while breached | while breached / emergency an SL may only tighten (never removed); the sentinel cannot change a TP |
  | `cancelOrder` | manager, agent, sentinel | resting limit / stop |
  | `cancelTimedOut` | anyone | the diamond accepts the cancel only from the trader (STAGE0.md A3) |
  | `flatten(pair, slippageBps, expectedPrice, maxTrades)` (Stage 3: batched) | round 4 flatten roles and custom-slippage rule | Closes the open trades of the pair and cancels its resting orders, at most `maxTrades` per call; returns `(sent, remaining)`. Skips trades with a market order in flight. Sets the closing slippage (`updateMaxClosingSlippageP`) only when it differs. The slippage update and the limit cancel are try/catch: Gains refuses both while a bot's TP / SL / limit trigger is in flight, and the vault cannot see those triggers because Gains files them under the bot. The close itself is never skipped |

### GainsVaultGovernance.sol (vs VaultGovernance.sol)

- **Unchanged:**
  - `setOperator`, `revokeOperator`, `checkRisk`;
  - `_derisk`, `_clear`, `triggerBreach`, `_stop`, `triggerEmergency`, `clearBreach`, `exitEmergency`;
  - the switches, `setDepositCap`, `lowerFees`;
  - `queue` / `execute` / `cancel` with exact calldata lengths;
  - the timelocked setters.
- **New (fix):** `queue` accepts `setPairFeed(uint16,address,uint32,uint16)` (132 bytes exactly); the guardian can cancel it like any queued call.
- **Changed:**
  - `initialize`:
    - checks the diamond instead of the Core deposit wallet;
    - reads `getCollateralIndex(asset)` and requires an active collateral with that address (`UnsupportedAsset` otherwise);
    - drops the seed bridge and Core gas;
    - stores the agent directly;
    - (fix) requires `policy.vault() == address(this)` (`PolicyMismatch`): the policy names its vault, the only caller of its feed rotation.
  - `_check`:
    - equity = idle + GainsNav value;
    - leverage = GainsNav notional / equity (vault leverage, PLAN.md 4.5);
    - the in-flight branches are gone.
- **Removed:** the bridge-window guards in `clearLeverageBreach`, `resume`, `setFees` and `_setFees`.

### GainsVault.sol (vs HyperVault.sol)

- **Unchanged:**
  - initialization of the ERC-20 (12 decimals) and Ownable2Step;
  - roles read from the factory;
  - the ERC-4626 views;
  - the depositor flow, settle, fees and hosting wrappers;
  - `setAgent` (timelocked, refused in a full stop) and `revokeAgent`;
  - the risk, breach, emergency and operator wrappers;
  - the switches, `rescueToken`, `renounceOwnership` disabled;
  - the timelock;
  - every storage getter that still exists.
- **Removed:**
  - `coreEquity`, `bridgePending`, `bridgeInFlight`;
  - the bridging entry points, `fundCoreGas`, `moveUsd`;
  - HL trading, `syncAgent`, `coreDepositWallet`;
  - the bridge getters and constants;
  - `initialize` is no longer `payable`.
- **New:**
  - `venue()`, `ordersPending()`, `diamond()`, `collateralIndex()`;
  - the Gains trading entry points;
  - (fix) `MAX_POSITIONS()` (was `MAX_OPEN_ORDERS()`), `redemptionShortfall()`, and `setPairFeed(pairIndex, feed, maxAge, bandBps)`: timelocked (queue + execute, `onlySelf`), forwards to the policy.
- Runtime size is 18,268 bytes (HyperVault: 17,156). Linked libraries: GainsVaultLogic 20,568, GainsVaultGovernance 10,615, GainsNav 7,831.

### GainsVaultPolicy.sol (vs VaultPolicy.sol)

- **Unchanged:**
  - constants, `RiskConfig` (same fields), `PendingConfig`;
  - every view;
  - `nextCheckpoint`;
  - tighten-now / loosen-after-timelock;
  - the allowlist flow;
  - the timelock delay;
  - `_validate`, `_isTighter`, `_checkEta`.
- **Changed:**
  - `initialize` requires a factory, which is the curation and price source; a standalone vault's policy names one. It also copies the sequencer feed and grace period. (fix) It also takes the vault the policy belongs to (`vault`), the only caller of `setPairFeed`; the factory passes the vault clone it just created.
  - `_allow` copies the pair's feed, maxAge and band from the factory (a snapshot) and enforces the NAV bound.
  - `queueAllowAsset` rejects pair indexes above uint16 (`InvalidPair`) where round 4 rejected spot assets.
  - `checkOrder` takes an `Order` struct and checks, in order:
    - the allowlist;
    - Gains slippage ≤ `maxSlippageBps`;
    - for market orders, the expected price within `maxSlippageBps` of Chainlink (the adverse side, as round 4's band);
    - `maxOrderNotional`;
    - the Gains minimum collateral and, by policy, the minimum position;
    - projected vault leverage.
  - `flattenOrder` becomes `flattenSlippage`: the same cap rule, returned in Gains precision.
- **New:**
  - `price`, `navPrice`, `feedOf`, `navBoundLeverageBps`;
  - the `LeverageAboveNavBound(pair)` check at initialize, at both stages of a config change, at allowlisting and at a feed rotation (PLAN.md 4.3);
  - `FeedSet`;
  - (fix) `setPairFeed(pair, feed, maxAge, bandBps)`, the feed rotation: only from the vault (through its timelock), only for a pair this policy has allowed and the factory still curates, only the exact feed / maxAge / band the factory curates for it at execution (`FeedNotCurated(pair)` otherwise), then the vault-leverage bound again. Errors `NotVault`, `FeedNotCurated`.

### GainsVaultFactory.sol (vs HyperVaultFactory.sol)

- **Unchanged:**
  - the `create` flow: launch allowlist, roles-collide check, seed minimum, registrar signature binding over (agent, predicted vault, deadline) with `block.chainid` (V-04), cap bounds, curation check, permit try/catch, deterministic clones, policy then vault init;
  - the agent registry and unregister-revokes;
  - owner config, role rotation, two-step ownership, `_checkRoles`, `renounceOwnership` disabled.
- **Changed:**
  - immutables: `diamond`, `sequencerFeed` and `sequencerGracePeriod` take the place of `coreDepositWallet`;
  - `minHypeValue` becomes `minAgentGas` (0.001 ETH), forwarded to the bound agent wallet; a launch without an agent sends no ETH;
  - `minSeedUsdc` defaults to 1 USDC (no Core activation fee);
  - the seed stays in the vault as idle USDC;
  - `setAssetCurated(pair, curated, feed, maxAge, bandBps)`. Existing vaults keep the config they copied; a new curated combination is what they may rotate to.
  - (fix) The policy clone is initialized with the vault clone's address.
- **New:** `pairFeed()`, `PairFeedSet`, `InvalidFeed`, `AgentGasTooSmall`, `AgentGasFailed`.

### GainsVaultLens.sol (vs HyperVaultLens.sol)

- **Unchanged:** max*, the previews with pending fees, claimable, pendingRequest, partialFill, emergency previews, epochOverdue.
- **Changed:** `coreActive` becomes `ordersPending`. In `Status`, `coreActive` and `bridgeInFlight` become `ordersPending` and `openPositions`, and `maxPositions`, `venueValue` and `openNotional` are added.
- **New:**
  - `timedOutOrders(vault)`, the keeper's sweep list (PLAN.md 4.3 step 3);
  - (fix) `maxPositions(vault)` and `openPositions(vault)`: the ceiling and the count, read with plain diamond views (no price), so the executor's copy mode can skip with a clear message and the UI can show it while a feed is stale.

## Deviations from PLAN.md

1. **flatten signature:** `flatten(pairIndex, slippageBps, expectedPrice, maxTrades) returns (sent, remaining)` (Stage 3; was `flatten(pairIndex, expectedPrice, slippageBps)`).
   - Gains needs an expected price for a market close and the exit rule forbids a price read, so the listed caller passes it.
   - (Stage 3) `maxTrades` (> 0, `type(uint256).max` = all) bounds the closes plus resting-order cancels of one call, so a full flatten can be split across transactions. A batch skips the trades whose close is already in flight, which is how the next batch continues where the last one stopped; `remaining` counts what is left for it (0 = everything of the pair is closing or cancelled). A refused limit cancel still counts as sent, so a stuck order cannot hold a batch. Still no NAV or price read; roles and the custom-slippage rule unchanged (`GainsFlattenBatch.t.sol`, `test_fork_flattenTwentyTradesInTwoBatches`).
   - The policy bounds the slippage around it.
   - flatten also cancels the pair's resting orders and skips trades with a market order in flight, so one stuck trade never blocks the rest.
   - The slippage update and the limit cancel are best effort (try/catch). A bot's trigger in flight, which the vault cannot see, makes Gains refuse them for a few seconds; the close still goes out.
2. **Operator `reduceTrade` (fix):** PLAN.md 5.3 has the operator free USDC for redemptions with `reduceTrade`, which is round 4's `bridgeToEvm` analog. Outside a breach / emergency it may do so only while the vault is short of USDC for the redemptions, and only up to that shortfall, measured as the collateral the reduce returns, computed at the request. `closeTrade` stays breach / emergency only for the operator, as 4.2 says. In a breach nothing changed.
   - The shortfall prices `pendingRedeemShares` at the **checkpoint NAV**, not at a live NAV: `reduceTrade` is an exit and may not read GainsNav or Chainlink (section 1). A normal settle pays within `maxNavMoveBps` of that checkpoint, which the keeper refreshes hourly with `checkRisk`. If the live NAV is higher, the operator may need a second reduce after the next checkpoint.
   - A leverage-only reduce returns no collateral (Gains sends only positive PnL), so the operator cannot use one outside a breach.
   - Closes already in flight count as returned, so repeated requests cannot exceed the shortfall.
   - (Stage 3) **Fee allowance:** the cap is `operatorReduceCap(shortfall) = shortfall + 2% + 1 USDC` (`OPERATOR_REDUCE_BUFFER_BPS`, `OPERATOR_REDUCE_BUFFER` in GainsTypes), and 0 without a shortfall. Gains keeps its closing fee from the collateral a reduce returns, so a reduce of exactly the shortfall always came back short by that fee. On the fork gate the operator reduced 2,307 → 297 → 0.86 → 0.10 USDC and then 0.10 USDC every run, and never settled without the manager. One reduce now covers the fee up to about 30x leverage; above that, or after a loss, the residual shrinks every round, and the operator stops after 3 rounds and alerts the manager. What a reduce frees beyond the redemptions stays idle on the vault (no loss but the fee). The in-flight rule is unchanged, so the allowance applies once per shortfall, not per request. Tests: `test_OperatorReduce_upToTheShortfallOnly` (cap + 1 refused), `test_OperatorReduce_feeAllowance_coversTheFee`, and the invariant `operatorEscapes` (above the cap is never accepted).
3. **`updateLeverage` lowering:** refused in a daily loss / drawdown breach and in a full stop, allowed in a leverage breach. PLAN.md said "lowering is always allowed"; this follows round 4's R3-04 rule for adding margin.
4. **Price config per vault:** the factory stores feed + maxAge + band per pair, and each policy copies them when it allows the pair. The factory owner can therefore never re-point the prices of existing vaults.
   - (fix) A changed feed reaches a vault through its owner: `setPairFeed` through the vault timelock (or a timelocked re-allowlisting). Only the combination the factory curates at execution is accepted, and the vault-leverage bound is checked again. A deprecated feed blocks settle with `PriceStale(pair)` until the rotation executes (`GainsFeedRotation.t.sol`).
   - The policy records its vault at initialization for this (the vault refuses a policy bound to another vault).
5. **Staleness margins and grace period:**

   | Feed | Heartbeat | Margin | Staleness limit |
   |---|---|---|---|
   | BTC/ETH | 1,755 s | 900 s | 2,655 s |
   | SOL | 86,400 s | 1,800 s | 88,200 s |

   The sequencer grace period is 3,600 s.
6. **`MAX_POSITIONS = 20` (fix, was `MAX_OPEN_ORDERS = 10`):** new. A gas-safety ceiling on open trades + resting orders + pending orders, not a strategy limit. Only `openTrade` (market, limit, stop) and `increaseTrade` are refused at it; `closeTrade`, `reduceTrade`, `cancelOrder`, `cancelTimedOut` and `flatten` never are. On the fork with 20 open trades over BTC / ETH / SOL every NAV-reading action stays under 10M gas (max 9.06M, the 20th `openTrade`), so the GainsNav optimisation was not needed (STAGE1.md).
7. **Deposit requests:** a request with no cap reads no NAV, as in round 4. A stale feed therefore freezes deposits at settle, where they are priced, not at the request. Correction (ROUND1 GR1-42): every factory vault has a cap (create requires 0 < cap <= maxDepositCap), so on factory vaults a deposit request always reads NAV and a stale feed pauses deposit requests too. Exits are never affected.
8. **Market band only:** the Chainlink band applies to market orders' expected price. Limit / stop triggers rest at their own price, which Gains checks against its oracle. `maxSlippageBps` also caps the Gains slippage of every order.
9. **SL / TP while breached:** an SL only tightens; the sentinel may set an SL but not a TP.
10. **Seed and agent gas:** the seed is idle USDC (`seedUsdc` is no longer an InitParams field). `minAgentGas` is forwarded to the agent; a manual-mode launch sends none.

## Stage 3 changes to contracts/src/gains

Stage 3 (the executor's Gains venue) changed `contracts/src/gains` in exactly two places. The details are in the entries above (Deviations 1 and 2); this is the list for the verification pass. `git diff 9575764 HEAD -- contracts/src/gains` shows nothing else.

| # | Change | Files | Why | Tests |
|---|---|---|---|---|
| S3-1 (e3c386b) | `flatten(pairIndex, slippageBps, expectedPrice, maxTrades) returns (sent, remaining)`, was `flatten(pairIndex, expectedPrice, slippageBps)`. At most `maxTrades` closes plus resting-order cancels per call (> 0, `type(uint256).max` = all); `remaining` counts what is left of the pair. | GainsVault, GainsVaultLogic | A full flatten of up to 20 positions is about 24M gas; batching lets the guardian or sentinel split it across transactions. The exit rule is unchanged: no NAV or price read, same roles, same slippage rule, trades with a market order in flight skipped, a refused cancel still counts as sent. | `GainsFlattenBatch.t.sol` (new, 6 tests: in batches, all in one call, `maxTrades` 0 reverts, roles kept, without prices (stale feeds), batches fill and pay), plus `test_fork_flattenTwentyTradesInTwoBatches` (GainsVaultFork.t.sol, real diamond), and existing callers updated (GainsExits, GainsVault, GainsRound4, invariants). |
| S3-2 (c9efc4c) | The operator's `reduceTrade` outside a breach / emergency may reduce up to `operatorReduceCap(shortfall) = shortfall + 2% + 1 USDC` (0 without a shortfall), was `shortfall`. New in GainsTypes: `OPERATOR_REDUCE_BUFFER_BPS = 200`, `OPERATOR_REDUCE_BUFFER = 1e6` and the free function `operatorReduceCap`. The error is unchanged: `ReduceAboveShortfall(shortfall, collateralDelta)`. | GainsTypes, GainsVaultLogic (NatSpec in GainsVault) | Found on the fork gate. Gains keeps its closing fee from the collateral a reduce returns, so a reduce of exactly the shortfall always comes back short by that fee. The operator then reduced 2,307 → 297 → 0.86 → 0.10 USDC and then 0.10 USDC on every run, and redemptions never settled without the manager. Everything else is unchanged: no price read, collateral only (`leverageDelta` 0), only while there is a shortfall, in-flight closes count as returned, no `closeTrade` for the operator outside a breach. What a reduce frees beyond the redemptions stays idle on the vault. | `test_OperatorReduce_upToTheShortfallOnly` (cap + 1 refused, a cap equality check), `test_OperatorReduce_feeAllowance_coversTheFee` (new: one reduce at the cap, no second reduce while it is in flight, the next settle pays the redemptions), the invariant `operatorEscapes` (a reduce above the cap is never accepted). |

**Approvals (PLAN.md 4.2: exact amount per open / increase / leverage decrease, never unlimited): unchanged.**
- Neither change touches `_approve`, `forceApprove` or the allowance reset. A reduce or a flatten pulls no collateral: Gains sends USDC to the vault, so no approval is involved.
- S3-2 bounds how much collateral the operator may take *off* a trade (now the shortfall + 2% + 1 USDC). It grants no allowance and does not affect what the diamond may pull.

Outside `contracts/src/gains`, Stage 3 changed `script/DeployGains.s.sol` (e785ef7). It records the L2 block from `eth_blockNumber` (`_l2Block()`): on Arbitrum, `block.number` is the L1 block, so the indexer start block was wrong. It is a deploy script only; no contract changed.

## Fix round 1 changes to contracts/src/gains

The internal review round 1 ([ROUND1.md](ROUND1.md)) was fixed on branch `fix/gains-r1`. Everything is listed in [FIXES-R1.md](FIXES-R1.md), including the test that fails on the old code for each change. `git diff audit/gains-r1 fix/gains-r1 -- contracts/src` shows exactly these changes: 10 files, +538 −130. The round 4 sources are still untouched.

| # | Change | Files | Why (ROUND1 id) |
|---|---|---|---|
| F1-1 | Pending orders count at the size they add: a leverage-only increase (Gains stores collateral 0) at trade collateral × leverage delta. A second request on a trade with an order pending reverts `PendingOrderExists(index)`. | GainsNav, GainsVaultLogic | GR1-01: several leverage-only increases each passed the vault-leverage check. |
| F1-2 | Two-sided settle: deposits mint at `max(nav, idle + valueHigh)`, with every trade at the favourable band edge; redemptions are paid at the adverse edge as before. `Snapshot` gains `valueHigh` and `blocking`, appended after the four round-4-era fields. `valueHigh` is computed only when a settle prices deposits (`snapshot(..., high)`). Every settle that prices deposits needs `INSIDER_MIN_EPOCH_AGE` (1 h), not only insider ones. | GainsNav, GainsVaultMath, GainsVaultLogic, GainsVault | GR1-02 (and GR1-15): deposits minted at the redemption NAV took about band × vault leverage from holders, repeatable every few minutes. |
| F1-3 | Near-liquidation zero only when the valuation price itself is at or past the liquidation price (the band is in the price once). | GainsNav | GR1-03 |
| F1-4 | Settle, in every mode, waits only for pending orders that hold collateral (market open, partial open with collateral, leverage decrease). `ordersPending()` means the same and is still price-free, and settle checks it before any price read. New risk and leverage decreases revert `EpochOverdue()` once the epoch is overdue. | GainsNav, GainsVaultMath, GainsVaultLogic, GainsVault (NatSpec), GainsVaultLens | GR1-04: decoy closes held the emergency settle. |
| F1-5 | `GainsNav.readTrades` / `readPendingOrders` decode Gains' lists from the returndata stride, decode only the v10 fields the vault uses, and range check each word. Fields Gains appends are tolerated; an unreadable layout reverts `DiamondLayoutChanged()`. `flattenIndices(uint32[], slippageBps, expectedPrice)` closes or cancels by index and decodes nothing (same callers and slippage rules as flatten). | GainsNav, GainsVaultLogic, GainsVaultMath, GainsVaultLens, GainsVault | GR1-08 |
| F1-6 | The factory refuses a zero sequencer feed; `sequencerFeed` / `sequencerGracePeriod` are storage with an owner setter. Each vault adopts the current feed through its timelock (`setSequencerFeed()`, queue selector length 4, policy copies the factory's value). | GainsVaultFactory, GainsVaultPolicy, GainsVault, GainsVaultGovernance | GR1-10 and the Slither item. |
| F1-7 | The policy's `owner()` is the vault's owner; its transferOwnership / acceptOwnership / renounceOwnership revert `OwnershipFollowsVault()`. | GainsVaultPolicy | GR1-12, GR1-30 |
| F1-8 | GainsPrice re-reads `decimals()` on every read (a change is PriceStale), refuses answers whose band edge would not fit a uint64 (`MAX_PRICE`), and gives a feed call at most 200,000 gas. `priceAfterImpact` saturates instead of wrapping. | GainsPrice, GainsNav | GR1-13, GR1-24, GR1-44 |
| F1-9 | A full stop (triggerBreach, triggerEmergency) cancels resting limit / stop opens, as a best effort that never blocks the stop. | GainsVaultGovernance | GR1-16 |
| F1-10 | A dust checkpoint (below MIN_RISK_NAV) accepts any NAV. The NAV bound is checked over every listed pair. `flattenSlippage(0)` = min(maxSlippageBps, maxFlattenSlippageBps). | GainsVaultPolicy | GR1-23, GR1-31, GR1-41 |
| F1-11 | A pending order's gov fee is priced on the trade's own pair. A cancelled next-epoch deposit resets the request to the current epoch. | GainsNav, GainsVaultLogic | GR1-28, GR1-32 |
| F1-12 | checkOrder no longer enforces `pairMinPositionSizeUsd` as a size floor (`Order.minPosition` removed): Gains' own minimum collateral is the only floor. | GainsVaultPolicy, GainsVaultLogic | earlier bug |
| F1-13 | create() writes the registry before the agent ETH call (checks-effects-interactions). | GainsVaultFactory | Slither / Aderyn info |

**Exit rule (PLAN.md section 1): unchanged.**
- closeTrade, reduceTrade, cancelOrder, cancelTimedOut, flatten and the new flattenIndices read no price. The list reads are plain diamond reads.
- `_cancelResting` in a full stop is best effort.
- A settle that only pays exits (exit-only, redemption-only) never values the favourable edge and never waits for the minimum epoch age.

**Approvals: unchanged.** No change touches `_approve`, `forceApprove` or the allowance reset.

**Storage layout:** VaultStorage is unchanged. The factory's two former immutables are now storage, which shifts the factory's own slots. That is a new factory deployment, not an upgrade (the factory, vaults and policies are not upgradeable). The policy appends no storage.

## Gas

The per-action table is in STAGE1.md (not included). Fix round 1 measured on the Arbitrum fork at 20 positions (`GainsVaultFork.test_fork_gasAtMaxPositions`, `LC_LivenessFork`):

| Call | Gas |
|---|---|
| totalAssets | 7,804,704 |
| checkRisk | 7,810,271 |
| settle, no deposits queued | 8,051,831 |
| settle, deposits queued (two valuations per trade, F1-2) | 13,404,159 |
| openTrade (19 → 20) | 8,811,730 |
| increaseTrade | 8,804,085 |
| flatten, 20 ETH trades in one call | 24,335,507 |

Every NAV reader stays under 10M except a settle that prices deposits (13.4M). Every call fits an Arbitrum transaction (32M).
- A vault request costs Gains' own 1.36–1.54M plus the policy check and one GainsNav pass. The pass costs about 400k gas per open trade (prices are read once per pair), so `MAX_POSITIONS = 20` keeps every NAV reader under 10M.
- Exits read no NAV. `flatten` costs about 1.2M per closed trade (Gains' own close request); the worst case, all 20 positions as trades on one pair, is 24.2M, inside an Arbitrum transaction (32M). Split in two batches of 10 (Stage 3) it is 12.4M + 12.7M on the fork.
