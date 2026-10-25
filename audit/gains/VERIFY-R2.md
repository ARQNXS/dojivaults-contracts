# Gains fix round 2: verification pass

**This is an internal verification of round 2 of [FIXES-R1.md](FIXES-R1.md) (the fixes for [VERIFY-R1.md](VERIFY-R1.md)'s GV-01 to GV-06). It is not an independent audit and must not be presented as one.**

**Independence.** This pass was run by an agent that did not write the round 2 fixes or VERIFY-R1. FIXES-R1's claims were not taken as evidence: every verdict rests on a test or a scan written for this pass, or on a named re-run.

## Scope

- **Branch:** `verify/gains-r2` in the worktree `dv-verify-gains-r2`, created from `fix/gains-r1` at 5aa1178. Nothing merged in.
- **Read:**
  - FIXES-R1.md (section 5 "Round 2", section 6 "Round 2", section 8 "Round 2 gate"), VERIFY-R1.md (from `verify/gains-r1`);
  - the diff `56cc78c..5aa1178`. Its round 2 commits are 956bf19, f496dc7, 4c5c894, 2e80b50 and 5aa1178. The rest of the diff is the merge of `main` 544808a (62045de), whose server changes (fix/settle-rpc: lane clients, gas headroom, revert reasons) were read for item 6 only.
- **Written:** only in `contracts/audit/gains/` (this file, `verify-r2/`) and `contracts/test/audit/gains/verify-r2/`.
- **Not done:** no edit to `contracts/src` or `server/src`; nothing deployed, no transaction sent, nothing pushed, nothing merged.
- **Sources for Gains' own code:** the verified facet sources on Sourcify (GNSTradingInteractions 0x66B2…D327, GNSPriceImpact 0xDCAD…4e55, GNSFundingFees 0xe197…798B, GNSBorrowingFees 0x5D27…E5f9; the libraries TradingInteractionsUtils, UpdateLeverageLifecycles, Increase/DecreasePositionSizeUtils, TradeManagementCallbacksUtils, TradingCallbacksUtils, TradingCommonUtils, TradingStorageUtils and TradingStorageGetters ship in those bundles), @gainsnetwork/sdk 1.8.10, and the gTrade v10 changelog. Arbiscan answered 403 to automated fetches. Five facets (most likely TradingStorage, TradingCallbacks, PriceAggregator, PairsStorage and the diamond loupe) are not on Sourcify. Where that matters, the fork tests below stand in for the source.

## Tests and scans written for this pass

| File | What | Count |
|---|---|---|
| `audit/gains/verify-r2/scan-size-ratio.mjs` | Item 1: every open trade on the diamond (getTraders / getTrades / getTradeInfo, one block) against the GV-01 bound | read only |
| `audit/gains/verify-r2/scan-history.mjs` | Item 1: every executed partial close, partial open and leverage update over 60 days, the trade read in the block of the event | read only |
| `audit/gains/verify-r2/data/*.json` | Their output (block 516,057,788; blocks 495,321,788 to 516,057,788) | |
| `test/audit/gains/verify-r2/VerifyR2Fork.t.sol` | Items 1, 2, 5 on the Arbitrum fork | 7 |
| `test/audit/gains/verify-r2/VerifyR2Mock.t.sol` | Item 2: every PendingOrderType value on the mock | 1 |
| `test/audit/gains/verify-r2/executor/verify-r2.test.ts` | Item 4 (vitest) | 6 |

```bash
cd contracts
ARBITRUM_RPC_URL=... node audit/gains/verify-r2/scan-size-ratio.mjs 516057788
ARBITRUM_RPC_URL=... STEP=250000 node audit/gains/verify-r2/scan-history.mjs 495321788 516057788
forge test --match-path "test/audit/gains/verify-r2/*"   # the fork file needs ARBITRUM_RPC_URL
cd ../server && npx vitest run --config ../contracts/test/audit/gains/verify-r2/executor/vitest.config.mjs
# without node_modules in this worktree: SERVER_MODULES_ROOT=<a checkout with the same server/package-lock.json>/server
```

## Verdicts

| Item | Verdict | Finding |
|---|---|---|
| 1. GV-01 plausibility bounds | **Holds.** No legitimate v10 trade comes near the bound; tightest ratio 0.98567, margin ×3.94 | none |
| 2. GV-02 order types | **Holds.** Every real `PendingOrderType` (0 to 13) is classified correctly; only 14 and up hit the fail-closed path | none (two info notes) |
| 3. GV-03 sequencer feed and grace | **Holds.** Queued, bounded 1 h to 1 day at every entry; the deploy value 3,600 s is inside the bounds (at the low edge) | none |
| 4. GV-04 executor alarm | **Holds for closes and reduces; one false alarm** | **R2-01 (Low)** |
| 5. Gas at 20 positions | **Holds.** The worst case is flatten at 24.34M, 23 % headroom to 32M; round 2 adds at most 24k | none |
| 6. Rest of the diff | **Nothing that breaks an exit, a settle or NAV** | none (notes) |

## 1. GV-01: the plausibility bounds

**What round 2 adds.** `GainsNav._plausible` refuses (`DiamondLayoutChanged`) any open element with collateral 0, leverage 0, open price 0 or trade type > STOP. It runs in `_readTrades`, which serves `readTrades`, `flatten`, the Lens and `snapshot`; `tryReadTrades` (the full stop) does not use it. `GainsNav._checkSize` runs in `snapshot` on each open market trade. It refuses `size == 0 || size·4 < expected || size > expected·4`, where `expected = collateral·precisionDelta·leverage·1e10 / (1e3·openPrice)`. The ratio below is `size / expected`.

**Why the ratio is not exactly 1 (from the Gains source).**
- Fees and PnL never change `collateralAmount`; they sit in `tradeFeesData`.
- `positionSizeToken` is computed without the skew price impact, while `openPrice` includes it.
- A partial close keeps `openPrice` and cuts size in proportion.
- A leverage update keeps the size and moves collateral inversely to leverage.
- A partial open re-averages `openPrice` by size.

So the drift is bounded by the skew impact (a few percent at most), and holding time cannot move it.

**Evidence.**

| Check | Sample | Ratio range (1 = exact) | Fails |
|---|---|---|---|
| Existing replays on round 2: VaultReplayFork / NavReplayFork / GainsForkReplay | 20 / 1 / 2 tests | | 0 (all pass) |
| Live scan, every open trade (`scan-size-ratio.mjs`, block 516,057,788) | 419 traders, 978 open elements, 905 market trades | | 0 implausible elements |
| … v10 market trades | 870 | 0.998678 – 1.002002 | 0 |
| … of them BTC / ETH / SOL on USDC (the vault's pairs) | 210 | 0.999631 – 1.000619 | 0 |
| … of them untouched for 30 days (funding and borrowing only) | 234 | 0.998798 – 1.000143 | 0 |
| … pre-v10 (contractsVersion 0/1, size 0) | 35 | size 0 | all would trip (see note) |
| History, 60 days of executed operations (`scan-history.mjs`, blocks 495,321,788 – 516,057,788, trade read in the event's block, 0 unread) | 49,543 (49,529 on v10 trades) | | 0 |
| … partial close | 24,251 | **0.98567** – 1.004424 | 0 |
| … leverage-only size decrease | 1,968 | 0.998053 – 1.001692 | 0 |
| … partial open with collateral | 12,633 | 0.991036 – 1.00592 | 0 |
| … leverage-only partial open | 1,951 | 0.997278 – 1.001705 | 0 |
| … leverage increase | 2,799 | 0.993594 – 1.00277 | 0 |
| … leverage decrease | 5,927 | 0.995956 – **1.005977** | 0 |
| … BTC / ETH / SOL on USDC subset | 6,041 | 0.992071 – 1.002894 | 0 |
| Fork: the extreme of each kind above, forked at its block and run through the real `GainsNav.snapshot` (`test_R2_GV01_realTradesAfterPartialClosesOpensAndLeverageUpdates`) | 12 real trades | 0.98567 – 1.005977 | 0 (pass) |
| Fork: every live trade at FORK_BLOCK through `GainsNav.readTrades` and, alone, through `snapshot` (`test_R2_GV01_everyLiveTradeThroughTheVaultChecks`) | 423 traders, 958 elements; 851 v10 and 35 pre-v10 market trades | v10 0.998440 – 1.002002 | 0 v10 false positives, 0 other reverts; 35 / 35 pre-v10 refused (pass) |
| Fork: a vault trade through open, partial open, leverage-only increase, `updateLeverage` up and down, partial close, leverage-only decrease, 30 daily settles and a deposit settle, then flatten (`test_R2_GV01_vaultTradeThroughEveryOperationAndAMonthOfFees`) | 9 states, `totalAssets` at each | 0.999925 – 0.999926 | 0 (pass) |

**Tightest legitimate ratio: 0.98567.** It comes from a partial close on an alt pair (user 0x0D78…9900, index 815, block 509,773,537). The bound refuses below 0.25 and above 4.

**Margin: ×3.94 on the low side (0.98567 / 0.25) and ×3.98 on the high side (4 / 1.005977).** A legitimate trade would need about 75 % skew impact to trip the bound, and Gains caps impact far below that.

**Notes.**
- **Pre-v10 trades** have `positionSizeToken == 0` and can never get a non-zero one, so `_checkSize` would refuse them. A vault never holds one, because every vault trade is opened through the v10 interface. The 35 live ones belong to old EOAs. Not a finding.
- **A precompile address is listed as a Gains trader.** 0x…01 appears in `getTraders` with no open element. `readTrades` reads it fine. The fork test skips its `snapshot` step because forge cannot etch a precompile, and with no elements that step has nothing to check. It has no bearing on a vault. The test pauses gas metering, because about 420 traders in one test exceed forge's 2^30 test gas limit; none of its numbers are gas figures.

## 2. GV-02: order types

**The real enum (Gains v10, verified facet sources):**

| Value | Type | Value | Type |
|---|---|---|---|
| 0 | MARKET_OPEN | 7 | UPDATE_LEVERAGE |
| 1 | MARKET_CLOSE | 8 | MARKET_PARTIAL_OPEN |
| 2 | LIMIT_OPEN | 9 | MARKET_PARTIAL_CLOSE |
| 3 | STOP_OPEN | 10 | PARAM_UPDATE (deprecated) |
| 4 | TP_CLOSE | 11 | PNL_WITHDRAWAL |
| 5 | SL_CLOSE | 12 | MANUAL_HOLDING_FEES_REALIZATION |
| 6 | LIQ_CLOSE | 13 | MANUAL_NEGATIVE_PNL_REALIZATION |

@gainsnetwork/sdk 1.8.10 lists only 0 to 6, so the on-chain source is the authority here, not the SDK.

**The vault's list (`GainsNav._pendingEffect`)** names every value from 0 to 13. An unknown value returns `(o.trade.collateralAmount, 0, feePair, blocks = true)`.

| Type | Field shapes (Gains) | Holds collateral | Vault | Test |
|---|---|---|---|---|
| 0 MARKET_OPEN | full trade | yes, the collateral | ✓ held, blocks | mock + fork |
| 1 MARKET_CLOSE | | no | ✓ blocks | mock + fork |
| 2 / 3 LIMIT / STOP_OPEN | filed under the caller (a bot or the trader) | yes, if the vault's | ✓ | mock |
| 4 / 5 / 6 TP / SL / LIQ_CLOSE | filed under the bot | no | ✓ | mock. Fork: a bot's TP trigger on the vault's trade is not in `getPendingOrders(vault)`; `ordersPending()` is false |
| 7 UPDATE_LEVERAGE | collateral = delta, leverage = new absolute | yes, when the leverage decrease adds collateral | ✓ held = delta | mock + fork (up and down) |
| 8 MARKET_PARTIAL_OPEN | collateral delta, leverage delta | yes (the delta); 0 on leverage-only | ✓ | mock + fork (both) |
| 9 MARKET_PARTIAL_CLOSE | | no | ✓ blocks | mock + fork |
| 10 PARAM_UPDATE | deprecated | no | ✓ | mock |
| 11 PNL_WITHDRAWAL | collateral = the PnL amount asked | no | see note | mock |
| 12 / 13 manual realizations | filed under the caller | no | ✓ | mock. Fork: refused (see note) |
| 14, 255 | unknown | | fail closed: valued at the collateral field, blocks settle | mock |

- `test_R2_GV02_everyRealOrderType_classified` (mock, 19 cases) asserts `ordersPending`, `blocking`, the value (base + held − min gov fee), and that `settle` reverts `OrdersPending` when the order blocks.
- `test_R2_GV02_everyTypeTheVaultCreates_onTheRealDiamond` checks the same on the fork for type 0, type 8 with collateral and leverage-only, type 7 up and down, type 9 and type 1.

Both pass.

**Info notes.**
- **Type 11** would be valued at `trade.collateralAmount`. For this type that field is the PnL amount asked, not collateral in flight. The vault has no entry point that creates it, and Gains files it under its caller, so it cannot reach `getPendingOrders(vault)`. Not reachable.
- **Types 12 / 13.** The source read suggested anyone may call `initiateManualNegativePnlRealization(trader, index, …)`. On the live diamond at FORK_BLOCK, a stranger's call is refused with `WrongAccess()` (0x6c5ffd54). The fork test logs the refusal and moves on. Even if access were opened, these orders are filed under the caller, not the vault (mock case). The test then closes and settles the vault normally.

## 3. GV-03: sequencer feed and grace

- **Every entry is queued and bounded.**
  - The vault's `setSequencerFeed(address, uint256)` is `onlySelf`, so only a queued governance call reaches it.
  - `GainsVaultGovernance.queue` checks the call length (68), that the feed and grace equal the factory's, and the grace bound.
  - `GainsVaultPolicy.setSequencerFeed` is vault-only and bounded.
  - The factory checks the bound in its constructor and its setter, through `GainsPrice.checkSequencerGrace`: `MIN_SEQUENCER_GRACE = 1 hours`, `MAX_SEQUENCER_GRACE = 1 days` (`GainsPrice.sol:52-56`).
- **Deploy value.** `script/DeployGains.s.sol:20` sets `SEQUENCER_GRACE = 3_600` (1 h). That is inside the bounds, exactly at the minimum. The factory constructor would revert on any value outside them, so a wrong value cannot ship silently.
- No server or webapp code calls `setSequencerFeed`; it is a governance-only path.

## 4. GV-04: the executor alarm

`server/src/venues/gains/reduceRate.ts` subscribes to `ReduceRequested` and `CloseRequested`, not `Flattened`. It alerts when one caller on one vault emits more than 10 of them within 10 minutes, at most once an hour. Reduces and closes are both counted, and a normal `flatten` (`Flattened`, `GainsVaultLogic.sol:689`) never counts. That part holds (vitest, 6/6 pass). The one false alarm is below.

### R2-01 (Low): a degraded-mode flatten raises the "revoke the caller" alarm

- **Location:** `server/src/venues/gains/reduceRate.ts:41-51` (threshold 10 in 10 minutes; topics `REDUCE_REQUESTED_TOPIC` and `CLOSE_REQUESTED_TOPIC`). Emitters: `GainsVaultLogic.sol:715` (`flattenIndices`, one `CloseRequested` per index) and `GainsVaultLogic.sol:576` (`closeTrade`).
- **Description:** `flattenIndices` is the guardian's fallback when `flatten` cannot run. It emits one `CloseRequested` per index in a single transaction, so with 11 or more open trades (MAX_POSITIONS is 20) that one call crosses the threshold.
  - The alert then says the caller is grinding collateral into fees and tells the operator to `revokeAgent` / `revokeOperator` it, but the caller is the guardian.
  - The same happens when the agent legitimately closes 11 or more trades within 10 minutes, for example a close-all.
  - A normal `flatten` does not alert.
- **Impact:** No on-chain effect. During an incident, which is when `flattenIndices` is used, the operator is told to revoke the actor doing the exit. If the operator does that to the agent, a legitimate close-all stops half-way. Low.
- **Fix:** Skip the guardian (and the vault's owner) as a caller, or count the `CloseRequested` events of one transaction as a single event. Either way, keep alerting on repeated transactions.
- **PoC:** `test/audit/gains/verify-r2/executor/verify-r2.test.ts`, the two `FINDING:` cases:
  - 20 indices in one transaction from the guardian: the alarm fires on the 11th log;
  - 11 agent closes in one minute: the alarm fires.

  The controls in the same file pass: 20 `Flattened` events stay quiet, 10 closes stay quiet, and 6 + 6 closes from two callers stay quiet.

## 5. Gas at 20 positions (Arbitrum fork, block 515,219,884)

Measured on round 2 by `test_R2_gas_settleTotalAssetsCheckRisk_20Trades` and `test_R2_gas_flattenAndFlattenIndices_20Trades`, with 20 open trades (BTC / ETH / SOL mixed; ETH only for flatten). The "Before" column is the figure from FIXES-R1 / VERIFY-R1.

| Call | Round 2 gas | Before | Δ | Headroom to 32M |
|---|---|---|---|---|
| settle with deposits + a redemption | 13,486,215 | 13,462,609 | +23,606 | 18,513,785 (57 %) |
| settle, redemption only | 8,070,679 | | | 23,929,321 (74 %) |
| flatten (20 trades, one call) | **24,344,915** | 24,335,510 | +9,405 | **7,655,085 (23 %)** |
| flattenIndices (20 indices) | 23,925,558 | 23,925,536 | +22 | 8,074,442 (25 %) |
| totalAssets | 7,821,996 | 7.80M | ≈ +20k | 24,178,004 (75 %) |
| checkRisk | 7,829,163 | 7.81M | ≈ +20k | 24,170,837 (75 %) |
| venue() view, both edges | 13,148,965 | | | 18,851,035 (58 %) |

The plausibility and size checks cost about 1k gas per trade. `flatten` is still the tightest call and has 7.6M gas spare.

## 6. The rest of the diff

- **`_plausible` reaches more paths.** It now guards `flatten` and the Lens as well as NAV and settle, and item 1 shows no legitimate trade trips it. If Gains ever changes its layout, `flatten` reverts too, but two exits still work:
  - `flattenIndices`, which works by index without `_readTrades`;
  - the full stop, through the unguarded `tryReadTrades`.
- **Exit-only settle** goes through `snapshot`, so `_checkSize` guards it too. Same conclusion as item 1.
- **Blocking on unknown types** stops `settle` (`OrdersPending`) until the order clears. That is the intended fail-closed behaviour. A vault cannot create such an order (item 2), and the exits do not wait on `ordersPending`.
- **Merge of main 544808a.**
  - `server/src/chain/vault.ts` adds `withGasHeadroom` (1.3×) for HyperEVM.
  - `GainsVaultChain.prepare` (`server/src/venues/gains/chain.ts`) keeps its own 1.2× headroom and is unchanged.
  - The executor never calls `flatten` / `flattenIndices`.

  No effect on Gains exits or settle.
- No change in the diff touches `withdraw`, the redemption queue or the share math.

## Not covered

- **Unverified Gains facets.** Arbiscan refused automated fetches, and five facets (most likely TradingStorage, TradingCallbacks, PriceAggregator, PairsStorage and the loupe) are not on Sourcify. Where their behaviour matters (the field shapes per order type, who files which order), the fork tests on the live diamond stand in.
- **The history scan covers 60 days.** Pairs with very high skew impact set the extremes, and they did here: the tightest ratio was on an alt pair, not one of the vault's, and it still had ×3.9 margin.
- **Gas was measured at 20 positions on three pairs.** A vault on more pairs reads more feeds.
