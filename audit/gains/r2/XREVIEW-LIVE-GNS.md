# Round 2 cross-review: domains LIVE and GNS

**Internal, AI-assisted review. Not an independent audit; nothing here may be presented as one.**

Cross-reviewer brief: try to refute, downgrade or extend GR2-LIVE-01, GR2-LIVE-02 (and the LIVENESS state machine),
GR2-GNS-01..03 and the GNS "sound" claims. Code: `contracts/src/gains/*` at 4ec6feb. Gains sources: the verified bundles
saved by the GNS reviewer (scratchpad `gns-src/`); the getters live in the **unverified** TradingStorage facet, so
every getter claim below was also checked on the live diamond.

New tests (all in `contracts/test/audit/gains/r2/`):

| File | Tests | Runs on |
|---|---|---|
| `XReviewLiveGnsHistoryFork.t.sol` | `test_GR2_XR_LIVE01_*` (4) | Arbitrum fork, real diamond, block 516,425,211 |
| `XReviewLiveGnsSideFork.t.sol` | `test_GR2_XR_GNS01_*` (2) | Arbitrum fork, real diamond, block 516,425,211 |
| `XReviewLiveGnsStateMachine.t.sol` | `test_GR2_XR_LIVE_*` (1) | mock diamond (GovBase) |

Re-runs of the original PoCs at the fresh block 516,425,211 (`LIVE_FORK_BLOCK` = `GNS_FORK_BLOCK` = tip − 40):
`LivenessHistoryFork::test_GR2_LIVE_01_navAndSettleCostGrowWithLifetimeIndexes` PASS (identical numbers: 387,064 →
2,774,564, 2,387 gas per index, 13,243 flat threshold) and
`GainsSideFork::test_GR2_GNS_01_takeProfitPastTheMarket_navAboveWhatGainsPays_redeemerOverpaid` PASS.

## Assumptions

| # | Assumption |
|---|---|
| X-1 | Arbitrum's per-transaction limit is 32,000,000 gas (as LIVENESS.md). If Arbitrum lowers it, or Gains makes the per-index read dearer, every threshold below moves down with it, and a vault already above the new line is locked. |
| X-2 | "Min gas" = the smallest `call{gas: g}` limit (to 1,000 gas) at which the call succeeds, from a snapshot, so the walked slots are cold every attempt. This includes the 63/64 retention of every nested frame, which a plain "gas used" figure does not. |
| X-3 | Thresholds near 32M are linear extrapolations from two measured sizes (counter 500 and 1,500). The 63/64 effect is proportional, so linear is the right model; the band edges carry about ±10 indexes of error (1,000-gas search granularity). A 32M end-to-end run needs ~12,700 RPC slot fetches and was not attempted (LIVENESS ran into the public node's state window at 13,400). |
| X-4 | Conservative reading where ambiguous: the grinder is the manager or the agent (online key), stops wherever it wants, and nobody reacts. |

## Verdicts

| Finding | Original | Verdict | One-line reason | Evidence |
|---|---|---|---|---|
| GR2-LIVE-01 | Critical | **DOWNGRADED to High** | The permanent lock exists, but only for a counter in a band of about 60 to 80 indexes just under openTrade's own ceiling (about 12,650 to 12,732). Only the manager or agent opens trades, and openTrade walks the same list, so no vault can get far past that band. Above LIVENESS' 4,700 to 13,200 thresholds a vault is degraded, not locked: flatten by index, then the flat exit settle. Reaching the band takes a deliberate insider grind (about 25,000 txs, about 2 ETH) that stops inside a window 0.5 % wide, or an unmonitored vault trading for about 1.7 years. | `XReviewLiveGnsHistoryFork.t.sol` (4 tests), re-run of the LIVE PoC |
| GR2-LIVE-02 | Low | **CONFIRMED Low** | Code matches. The owner cannot clear its own stop or leave emergency; the guardian ends it at once; a depositor can trigger emergency at T. | code review; `LivenessStateMachine::test_LIVE_SM_H1_*` |
| LIVENESS table, rows K1 / E2 / P1 | — | **K1 corrected; E2 × P1 gap → GR2-XR-02 (Low)** | K1 overstates (see LIVE-01). E2 + P1 on the same pair blocks every settle mode, idle included. | `XReviewLiveGnsStateMachine.t.sol` |
| GR2-GNS-01 | Low | **CONFIRMED Low** (likelihood revised up, impact unchanged) | Reproduced: +4,118.66 USDC NAV, +2,059.33 to the redeemer. A watching manager wins the race (settle is 1 tx, the bot needs request + oracle callback). The gain is bounded by vault leverage (≤ 5x) × how far past the TP the price runs, beyond the band, in that latency. The manager cannot cause the overshoot. | re-run at 516,425,211 |
| GNS-01 sibling: resting LIMIT open run through | — | **NEW GR2-XR-01 (Low)** | It is valued at collateral, but Gains opens it exactly at the limit, above the market: NAV is 6,367.97 USDC (3.2 %) above the post-fill NAV, and the redeemer is overpaid by 3,183.98. | `XReviewLiveGnsSideFork::test_GR2_XR_GNS01_crossedLimitOpen_*` |
| GNS-01 siblings: SL, STOP open, liquidation | — | **Conservative (confirmed)** | SL and STOP execute at the trigger, which is better than the market there. A liquidation pays 0 and GainsNav values it at 0. | source; `test_GR2_XR_GNS01_crossedStopOpen_conservative` |
| GR2-GNS-02 | Design / Info | **CONFIRMED** | The emergency timelock 0x893f…e75a holds role 4 and has `getMinDelay()` = 36,000 s (read live). | `cast call` |
| GR2-GNS-03 | Info / Design | **CONFIRMED** (not re-run) | The algebra checks out: 1e12 / (200 · 32.7M) = 153 USDC per 1M × 1M on BTC. | arithmetic |
| GNS sound: no positive PnL cap | sound | **CONFIRMED** | `getPnlPercent` has a floor at −100 % and no cap; `getTradeValueCollateral` adds none. | TradingCommonUtils.sol:34-54, :477-497 |
| GNS sound: gToken refusal delays, does not shortchange | sound | **CONFIRMED (with a caveat)** | `GToken.sendAssets` reverts (`NotEnoughAssets`, `MaxDailyPnl`) before any transfer, so the payout is all or nothing. Caveat: the callbacks facet is unverified, so "the callback reverts rather than catches" rests on the GNS fork test. | GToken.sol:722-747 |
| GNS sound: manual realizations NAV-neutral | sound | **CONFIRMED (structure)** | GainsNav reads collateral, holding fees and realized PnL live and applies Gains' own `getTradeValuePure` with the same `fees + holding − realized` term, so it moves only if Gains' own value moves. | GainsNav.sol:213-220 vs TradingCommonUtils.sol:477-497 |

## 1. GR2-LIVE-01 in detail

### 1.1 The Gains getters (verified bundle, confirmed on the live unverified facet)

Every verified bundle carries the same `TradingStorageGetters.sol` (one md5).

- `getTrades` walks `i < currentIndex` and breaks once `openCount` open trades are found. With **nothing open there is
  no early exit**: it walks every index. With trades open it stops at the newest open one.
  - Live: a vault whose only open trade is old does not pay for 50,000 later indexes. Settle cost was 956,869 at
    counter idx+1 and 961,369 at idx+50,001 (`test_GR2_XR_LIVE01_getTradesStopsAtTheLastOpenTrade`).
  - New indexes are always the highest, so on an active vault the walk is full. No role can create an open trade at a
    low index. LIVENESS' "flat or not, same cost" holds in practice.
- `getPendingOrders` returns at once when `openCount == 0`.
  - Live: the pending counter raised by 1,000,000 with nothing pending moved settle from 387,064 to 391,564
    (`test_GR2_XR_LIVE01_pendingCounterIsFreeOnceNothingIsPending`).
  - The pending history, which closes and reduces grow without any list read, costs nothing once the orders fill or
    time out. It is never a permanent lock: on a flat vault in emergency nobody can create a pending order, and anyone
    can call `cancelTimedOut`.

### 1.2 Who can consume the vault's trade indexes

Only the manager and the agent, and only through `vault.openTrade`.

- Gains files a trade under `msg.sender`. The vault never sets a trading delegate: `getTradingDelegate(vault)` is 0 on
  the fork and on the live vault [an earlier vault].
- Stranger, keeper, sentinel and depositor calls to `openTrade` revert.
- A stranger trading on Gains moves its own counter, not the vault's (`test_GR2_XR_LIVE01_onlyManagerOrAgentConsumeIndexes`).
- Live vault [an earlier vault] today: `getCounters(v, 0)` = `getCounters(v, 1)` = (0, 0).

### 1.3 The point LIVENESS missed: openTrade walks the same list, so the counter has a ceiling

`openTrade` runs `$.venue()`, the full GainsNav snapshot (`getTrades` + `getPendingOrders`) before Gains stores the
trade. Every trade index a vault ever gets therefore came from a call that walked all earlier indexes. Limit and stop
orders get their index at placement. A market open gets it at Gains' fill, which walks nothing, so up to 20 market opens
requested at counter n can land at n+1 … n+20 (MAX_POSITIONS). The vault's counter can never exceed about
**(openTrade ceiling) + 21**.

LIVENESS moved the counter with `vm.store` to any N. The question that matters is whether the cheapest exit (flat
vault, exit-only settle) still fits at the highest counter a vault can actually reach.

Measured (min gas, X-2; `test_GR2_XR_LIVE01_openTradeWalksTheSameList_*`, block 516,425,211):

| Counter n | openTrade (resting limit, flat vault: the cheapest open there is) | exit-only settle, flat, at n + 21 | normal settle, flat, at n + 21 | triggerEmergency |
|---:|---:|---:|---:|---:|
| 500 | 1,906,701 | 1,648,470 | 1,660,332 | 122,206 |
| 1,500 | 4,366,734 | 4,142,265 | 4,146,827 | 122,206 |
| slope per index | **2,460** | **2,493** | 2,486 | 0 (the walk is in a try; it OOGs harmlessly) |

At both sizes the exit settle at n + 21 fits inside the gas of the last open that fitted. This is also shown end to end:
`triggerEmergency` and the guardian's settle each run with the open's gas limit and pay the redemption.

The settle's min-gas slope is steeper by 33 gas per index (the 63/64 reserve over its heavier pre-walk frame), so the
margin shrinks: 258,231 at counter 500, 224,469 at counter 1,500.

Extrapolated to 32M:

- **openTrade (flat, limit) stops fitting at counter ≈ 12,732.**
- **The flat exit settle stops fitting at counter ≈ 12,670** (12,649 for the open counter if 21 market opens overrun it).
- At the open's ceiling the settle needs about 155,000 gas more than 32M.

My refutation hypothesis ("the open always runs out first") **failed** in run 1. The test now asserts what was
measured.

Consequences:

1. **The permanent lock is real but narrow.**
   - A vault is locked for good only if its last successful open left the counter in [≈ 12,650, 12,732], about 60
     to 80 indexes.
   - Below that, the guardian has an exit at any counter: `triggerEmergency`, closes by index (`flattenIndices` or
     `closeTrade`, neither walks), the fills, then the flat exit-only settle. Each step is under 32M.
   - Above it, no open can be sent, so the counter cannot get there.
2. **LIVENESS' thresholds are normal-operation thresholds, not lock thresholds.**
   - ~4,700 / 7,200: a normal settle with deposits and 20 trades.
   - ~7,000 / 9,500: a redemption settle with 20 trades.
   - ~3,200: `flatten` in one call.
   - Past them the vault must unwind to settle: deposits stop pricing, and redemptions need the positions closed
     first. That is a forced wind-down (closing costs, a strategy stopped), not a lock.
   - Row K1 ("none once past the threshold, never") is wrong for 7,700 to 12,650. It is right only inside the band
     (and for the open-trade settle modes, which can be avoided by going flat).
3. **Organic reach.**
   - A vault that opens from flat (one trade at a time) can walk up to 12,732. It would have failed every settle made
     with a trade open from about 12,500 (+0.4M per valued trade) and every deposit settle with 20 trades from about
     7,200 long before.
   - About 1.7 years at 20 indexes a day, with failing settles ignored. With the ALERT's counter monitoring this
     cannot go unnoticed.
4. **Deliberate reach (manager or agent online key).**
   - Place and cancel resting limits: open ≈ 0.62M + 2,387·k gas used, cancel ≈ 0.19M.
   - Σ over k = 0 … 12,700 ≈ 0.81M · 12,700 + 2,387 · 12,700² / 2 ≈ 1.03e10 + 1.93e11 ≈ **2.0e11 gas ≈ 2.0 ETH at
     0.01 gwei, about 25,400 transactions**. The cost is quadratic in the target counter.
   - The grinder must stop inside the 0.5 %-wide band, which it can, since it watches its own counter.
   - It needs hours of visible activity (Gains events, a counter rising past any alarm). A sentinel `triggerBreach`
     at any point before the band ends it (`_newRisk` refuses `breached`).
5. **Possible rescue inside the band (analysis only, NOT proven).**
   - An EIP-2930 access list pre-warms the walked slots at 1,900 gas each in intrinsic gas, outside the nested 63/64
     frames. In-frame each slot then costs 100 instead of 2,100.
   - Net saving ≈ 240 gas per listed slot. About 650 slots (≈ 21 KB of access list) would cover the 155k overshoot.
   - The Arbitrum handling of access lists (and of their calldata against the limit) was not tested. Do not rely on it.
6. **Another unproven way out:** Gains could ship a getter that does not walk. That is out of the vault's control.

**Severity.**

- Impact: permanent lock of every share, idle USDC included, in the band. A forced wind-down elsewhere above ~4,700.
- Likelihood of the lock: needs a malicious or compromised manager or agent key, ~2 ETH, ~25,400 visible
  transactions, no platform reaction for hours, and a stop inside a 60-80-index window. Organically: ~1.7 years of
  unmonitored, failing-settle operation.
- Under ROUND1's scale a lock conditional on an insider grind is **High** (conditional).
- The organic part (normal settles fail past ~4,700-9,500, wind-down still possible) is **Medium** (griefing of core
  flows).
- If the lead reads "permanent lock reachable by an insider" impact-first, Critical stays defensible. The record should
  then still say that the lock zone is ~12,650-12,732 lifetime indexes, not 7,700-13,200.
- The fix direction in LIVENESS (own index set, `syncIndexes`) stays right and removes both parts.

### 1.4 The ALERT's interim mitigations

| Step | Check | Verdict |
|---|---|---|
| 1. `diamond.getCounters(vault, 0 / 1)` | Selector exists on the live diamond. It returns (currentIndex, openCount, placeholder); type 0 = TRADE, 1 = PENDING_ORDER. Confirmed by `_setCounter`'s read-back on the fork and by `cast call` on the live vault ((0, 0, 0) both). | correct |
| 1. Alert 3,000 / act 5,000 | Conservative against the real lock band (~12,650). Right for the normal-settle limits (~4,700 with 20 trades and deposits). | keep |
| 2. `setTradingPaused(true)` + `revokeAgent()` against an **agent** grind | The sentinel may pause and revoke. The agent cannot undo either. | correct |
| 2. `setTradingPaused(true)` against a **manager** grind | **Not sufficient on the live vault.** `_switchAuth` lets the owner unpause, and on [an earlier vault] owner = manager ([platform wallet]). The ALERT does give `triggerBreach()` for that case, which is correct: `_newRisk` refuses `breached`, and the owner can only clear through a timelocked queue item or the guardian. **Wording fix:** for any vault where owner = manager, step 2 should be `triggerBreach()` first, not `setTradingPaused`. | partly wrong (wording) |
| 2. "settle then needs emergency: guardian `triggerEmergency` and sentinel `settle()` while the walk still fits" | Correct. Per 1.3 the walk fits at any reachable counter outside the band, provided the vault is flat first (close by index). | correct, add "flatten first" |
| 3. Wind down before the act level | Correct. | keep |
| "Above that no settle mode can ever run again" (thresholds 7,700 / 10,000 / 13,200) | Overstated: those are normal-mode limits. The permanent zone is ~12,650-12,732, reachable only as in 1.3. | correct the ALERT text |

## 2. GR2-LIVE-02 and the state machine on a young vault

**GR2-LIVE-02 is CONFIRMED Low.**

- `triggerBreach` (GainsVaultGovernance.sol:225) has no cooldown.
- `clearBreach` takes the guardian or a self-call (queued owner).
- `triggerEmergency` is open to anyone once overdue with redemptions pending (:258-260).
- The owner cannot `exitEmergency`.
- The hold is ≤ T (≤ 30 days by policy), ended at once by the guardian.

I searched for a young-vault scenario with no exit that the table misses. Candidates and outcomes:

| Candidate | Outcome |
|---|---|
| Hostile owner rotates the sequencer feed to one reporting "down" (timelocked) | A flat vault reads no price, so flatten then settle works (row P2). Not a gap. |
| Controller blacklisted by USDC, auto-claim in `requestRedeem` reverts | The holder can name another controller. Not a gap (U1 covers the vault). |
| Loss breach + `NavMoved` | At T a depositor triggers emergency, and exit-only has no NAV bound. As L1. |
| Partial-fill dust: `burned` rounds to 0 while `paid > 0` | At most one share-unit's value moves. Not liveness; outside this review (FF/CI). |
| **Row E2 (a pair Gains no longer closes) together with row P1 / GR1-09 (that pair's feed stale or deprecated)** | **Gap.** E2 says "settle pays idle pro rata". P1's way out is "flatten that pair". On the same pair neither works: the trade cannot be closed, so every settle mode values it and reverts `PriceStale`. The idle USDC is not paid either (8,001 USDC idle against a 25 % redemption in the PoC). The only fix is a feed rotation, which is `onlySelf` (owner queue + the vault timelock, ≥ 1 day) and needs the factory to curate a live feed. A hostile or absent owner makes it permanent. → **GR2-XR-02** |

### GR2-XR-02 (Low): a stale feed on a pair Gains will not close blocks every settle mode, idle included

This re-raises GR1-09 × GR1-45 with new evidence that it is worse than recorded.

**Location.** GainsVaultLogic.sol:241-246 (every settle mode runs `$.venue`, which reads the pair's price for each open
trade); GainsVault.sol:406 (`setPairFeed` onlySelf).

**Scenario.** A 10k vault holds one ETH trade with 2k on the venue and 8k idle. Gains stops serving ETH closes and the
ETH feed goes stale (or Chainlink deprecates it). Then:

- the guardian's `closeTrade` reverts;
- `flattenIndices` sends 0;
- the sentinel, guardian and keeper settles all revert `PriceStale(1)`;
- the 25 % redemption stays unpaid although idle covers it three times over;
- the guardian cannot call `setPairFeed`.

**Impact × likelihood.** Every redemption is held, including the idle part, until the owner rotates the feed. A hostile
or absent owner makes it permanent. It needs Gains to stop serving the pair AND its Chainlink feed to stop, which is
correlated (a dying asset) but rare. Low.

**Fix (from GR1-09's own list).** When the venue cannot be valued, an emergency exit-only settle prices redemptions from
idle (min(checkpoint, idle-backed NAV), partial fill), or values an unclosable stale pair at 0. Alternatively, give the
guardian a feed rotation restricted to factory-curated feeds.

**PoC.** `XReviewLiveGnsStateMachine.t.sol::test_GR2_XR_LIVE_staleFeedOnAnUnclosablePair_noSettleModePaysEvenIdle`
(pass, mock).

## 3. GR2-GNS-01 and its siblings

**Reproduction (block 516,425,211).**

- NAV was 208,580.11 USDC in the window and 204,461.45 after the TP fill (+4,118.66).
- Gains paid 9,460.45 at the TP.
- Bob was paid 104,290.06 instead of 102,230.72 (+2,059.33). Alice is short by the same amount.
- The source confirms it: `_validateTriggerCloseOrderCallback` (TradingCallbacksUtils.sol:586-605) executes at
  `triggerPrice` whenever `low ≤ trigger ≤ high` over the lookback, so exactly at the TP however far the market ran.

**Can the manager trigger it deliberately?**

- It sets the TP, and the manager (or its keeper) chooses when to settle.
- It cannot cause the overshoot.
- It does win the race once the price is past the TP. A settle is one transaction. Gains needs a `triggerOrder`
  request and then an oracle callback (`getPrice` → `fulfill`), at least a block or two apart. The bot's pending
  TP_CLOSE is filed under the bot, so the vault's `ordersPending` does not see it (VERIFY-R2 row 4/5/6).
- The redeemer's gain is: vault leverage (≤ 5x live) × (overshoot within that latency − the 20-25 bp band) × their
  share. In normal markets the overshoot in seconds is below the band, so the gain is zero.
- I did not prove that a vault-side pending market close can delay the bot's trigger. That stays an open question; if
  it can, the window becomes manager-controlled. The manager could also close at market before the bot, so letting
  the TP fill is a choice, not a forced loss.

**During a Gains pause** no trigger executes and settle still runs (row O3: normal settle if idle covers it, emergency
partial fill otherwise). The overshoot is then unbounded for the pause's length. Pauses are rare governance events.

Verdict: **Low stands.** Impact is bounded (leverage × overshoot) and likelihood is low (fast markets or a pause).

**Sibling, new: GR2-XR-01 (Low). A resting LIMIT open the market has run through is valued at its collateral, but
Gains opens it at the limit, above the market.**

- Location: GainsNav.sol:89-94 (a resting order counts `collateralAmount`); Gains `_validateTriggerOpenOrderCallback`
  (TradingCallbacksUtils.sol:512-520, exact execution at `openPrice` when inside the range).
- Fork (`test_GR2_XR_GNS01_crossedLimitOpen_valuedAtCollateral_opensBelowIt_redeemerOverpaid`): a 200k vault (alice /
  bob 50 / 50) places a 25,000 USDC LIMIT long at 20x (500k notional) 0.5 % below the market. The market falls to
  −1.5 % before the bot.
  - Gains opened at 23,908.51 (limit 23,905.14) while the market was at 23,664.89.
  - NAV in the window was 200,001.00; after the fill it was 193,633.03 (−6,367.97, 3.2 % of NAV).
  - Bob was paid 100,000.50 instead of 96,816.52 (**+3,183.98**). Alice is short the same.
- It is the same mechanism and likelihood as GNS-01, and natural precisely when limit buys fill in a fast fall. The
  resting value also ignores the opening fee that Gains takes at execution (small).
- Fix: value a resting LIMIT whose trigger the valuation price has crossed as the trade it becomes (opened at the
  limit, marked at P, minus opening fees), capped at its collateral.

**SL, STOP, liquidation (confirmed conservative).**

- SL closes at `sl` when it is in range, which is better than the market beyond it, so NAV understates.
- A STOP long run through opens at the stop, below the market. Fork: NAV was 200,001.00 while resting and 203,613.22
  once filled (`test_GR2_XR_GNS01_crossedStopOpen_conservative`).
- LIQ_CLOSE pays value 0 at `liqPrice` (:586-614, no impact). GainsNav `_nearLiquidation` returns 0 once the valuation
  edge is at or past liq.
  - For redemptions (adverse edge) that is ≤ payout.
  - For deposit pricing (favourable edge) a trade can still count above 0 near liq. That raises the deposit price, so
    existing holders are favoured: conservative.
  - Round 1's replay of 3 real liquidations held the zero rule.

## 4. GNS-02 / -03 and the sound claims

- **GNS-02**: `getMinDelay()` of 0x893fcf48d56ce2e92afb4a085941135243d5e75a = 36,000 s, and `hasRole(0x893f…, 4)` = true
  on the live diamond. Design / Info is right: the vault cannot pin a formula, and the guardian can react
  (deposits paused, emergency) only if someone watches the timelocks.
- **No PnL cap**: verified in the source (above). The only bound is the floor at −100 %.
- **gToken refusal**: `sendAssets` checks both limits and reverts before `safeTransfer`. It cannot pay part. That the
  unverified callbacks facet lets the revert propagate (trade stays open) rests on the GNS fork test, which I did not
  re-run.
- **Manual realizations**: structurally neutral. Both sides read the same live inputs, and GainsNav mirrors
  `getTradeValueCollateral` term by term.

## 5. Runs

Run 1, block 516,425,211 (forge 1.8.4, public RPC, forge lock held 00:27-01:20, of which 44 min was a full rebuild
caused by other reviewers' changes):

- `XReviewLiveGnsStateMachine` 1/1 PASS.
- `XReviewLiveGnsSideFork` 2/2 PASS.
- `GainsSideFork::test_GR2_GNS_01_*` PASS.
- `LivenessHistoryFork::test_GR2_LIVE_01_navAndSettleCostGrowWithLifetimeIndexes` PASS.
- `XReviewLiveGnsHistoryFork` 3/4 PASS. The fourth, the refutation hypothesis, FAILED with −154,745 gas at the
  ceiling. It was rewritten to assert the measured band (run 2, below).

Run 2 (block 516,434,325) did not run a test: a glob error in my runner script. Run 3, block 516,440,714:
`test_GR2_XR_LIVE01_openTradeWalksTheSameList_lockOnlyInANarrowBandBelowTheOpenCeiling` **PASS**. The numbers were
identical to run 1: slopes 2,460 / 2,493 / 2,486, open ceiling 12,732, flat exit settle limit 12,649 with a +21
overrun, band 83 indexes.

Not run: the 32M end-to-end settle at counter ~12,700 (public RPC state window, X-3), the access-list rescue (1.3
item 5), and a re-run of GNS-02/03 or the gToken fork test.
