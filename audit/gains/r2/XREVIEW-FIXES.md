# Round 2 cross-review of the proposed fixes and of GR2-CI-01

**Internal, AI-assisted review. Not an independent audit.** Cross-reviewer of `fixes/` (GR2-ECON-03, GR2-CFG-01,
GR2-KEY-06, GR2-KEY-01, GR2-LIVE-01, `COMBINED.md`) and of GR2-CI-01 (`CONSERVATION.md` section 9). Nothing in
`contracts/src` was changed. Tests in xr-fixes/ (not included) with raw runs (`run-*.txt`).

## Verdicts

| Item | Verdict | One line |
|---|---|---|
| GR2-ECON-03 | **CLOSES**; extends a pre-existing Low (XF-01) | The leverage-breach settle now charges the fee before minting; no double charge. But an overdue exit-only settle in a leverage breach now also charges the performance fee on the **uncapped** NAV while redeemers are paid at the cap (276.67 USDC on a 53.35k redemption in the test). Same thing already happened without a breach on 4ec6feb. |
| GR2-CFG-01 | **CLOSES** | Every tightening is still instant on the live shape. A longer epoch can still be reached by raising both timelocks first, so nothing is bricked. The webapp must stop offering epochs over T − 1 day (XF-05). |
| GR2-KEY-06 | **CLOSES**; **INTRODUCES** a bounded C-01 weakening (XF-02, Low) | XR-01..04, ECON-02 and CFG-02 stay closed. But in the hour after a *downward* ratchet, a NAV pushed back up toward the pre-loss level is paid to redeemers. Test: 7,984 USDC more on a 48.6k redemption than 4ec6feb pays. That is 16 % of the redemption, against the README's "≤ one ratchet step" framing. |
| GR2-KEY-01 | **CLOSES** | No exit, settle, checkRisk or NAV read calls the new checks. A stranger cannot trip either gate. A depth of 0, a depth cut, or the selector being removed only refuses new risk (XF-04, Info). |
| GR2-LIVE-01 | **CLOSES** the permanent lock; residual unbounded-between-syncs cost (XF-03, Low) | Matches Gains' own lists over 256 random histories × 60 steps, with real-Gains limit execution at a new index and a stranger syncing at random moments. All 9 broken tests port and pass. But closes and reduces do not sync: about 26k gas per unseen order (mock) in every NAV reader, until a permissionless chunked `syncIndexes`. |
| Combined | **Verified** | The 36 failures in `combined-run.txt` are exactly the listed PoCs and tests-to-port (19 + 6 + 9 + 1 + 1 interaction). The 9 LIVE-01 "tests to port" protect GV-01 / GV-02 / GR1-08 properties. Ported to per-index reads, all hold (`XRLive01Ports`). |
| GR2-CI-01 | **Confirmed, Low** (kept) | The PoC re-runs with identical numbers. It needs a Gains facet change: today Gains files every order type the vault does not create under `msg.sender`, not the vault. **The checkRisk claim is proven**: a 178k phantom (25.5 % of NAV) across UTC midnight gives a DAILY_LOSS breach (2,030 bps) with no loss at all. The lifetime peak stays 25.5 % high, so 20.3 % of the 50 % drawdown budget is used up by nothing. |

## Method and assumptions

- Scratch trees (session scratchpad `XR-FIX/`): `asis` = 4ec6feb Gains sources (copy of `fixes/asis`), `all` = the five
  patches applied in COMBINED.md order (copy of `fixes/all`). Copying invalidated forge's cache. Each tree needed one
  full via_ir build (1,238 s / 1,242 s), plus 128 s for the test files added later.
- No forge lock or heavy lock was needed: scratch copies only, and nothing heavy. No fork test was run (KEY-01's fork
  result is the fix author's `run-fork.txt`).
- Conservative readings:
  - (A1) A "pump" is any NAV reading the vault cannot distinguish from a real move. That covers the Low pump tools
    already on record (GR2-GNS-01, GR2-XR-01, GNS-03 skew) and Chainlink lag. C-01 assumes such a reading exists, so
    any widening of what it lets through counts.
  - (A2) The mock's per-index read cost stands in for the real diamond's order of magnitude. Each `getPendingOrder` /
    `getTrade` on Gains reads several cold slots.

## 1. GR2-ECON-03

**Closes.** COMBINED's run has `EconPoC::test_GR2_ECON_03` failing (the PoC asserts the bug), and the fix test passes.
`XRKey06Econ03::test_XR_ECON03_noDoubleChargeAcrossLeverageBreachSettles` checks that a second leverage-breach settle
at the same NAV mints nothing, so the HWM moves once. It passes on both trees. A fee on a deflated NAV can only be
smaller (it is charged only above the HWM), so it moves no value from depositors.

**XF-01 (Low; pre-existing, extended by the patch).** An exit-only settle runs `_accrueFees(withPerformance, venue)` on
the full NAV. Redemptions, however, are priced at `min(NAV, cap)`. When NAV > cap, redeemers pay the performance fee,
through the dilution of the very supply they are priced against, on a gain they are not paid for. On 4ec6feb this
happens in an overdue exit-only settle by a platform role without a breach. With ECON-03 (`!exitOnly` is not in the
condition) it also happens in a leverage breach.

- `test_XR_ECON03_preExisting_exitOnlyNoBreach_higherNavPaysTheRedeemerLess`: 100k vault, 20 % performance fee, 3x
  ETH, +3 % gain, a fresh checkpoint, then ETH +1 % inside the hour. The redeemer is paid 53,352.81 at NAV = cap and
  **53,076.14** at the higher NAV (−276.67, 0.52 %). Passes on both trees.
- `test_XR_ECON03_exitOnlyInLeverageBreach_...`: the same numbers on the patched tree. On 4ec6feb both payouts are
  54,190.99, the expected FAIL there.

Bound: perf × (NAV − cap) × the redeemers' share. The cap gap is at most one interval's NAV move. Likelihood: a
platform role settles exit-only (overdue, or in emergency without a breach), so it is not attacker-timed beyond that.

**Fix-round change:** in exit-only settles, charge the performance fee on `priceNav` (or not at all, the README's
`!exitOnly` option). Keep the raise switch on the same condition. The management fee has the same base issue, but its
size is negligible.

## 2. GR2-CFG-01

**Closes.** The CFG PoCs fail (refused at queue or launch) and the fix test passes.

- `XRCfg01::test_XR_CFG01_everyTighteningStillInstantOnTheLiveShape`: each of the 8 fields, and all together,
  tightened on T 2 d / E 1 d, applies instantly. The invariant T ≥ E + 1 d holds from initialize, so a tightening
  (E' ≤ E) can never hit `EpochAboveTimelock`.
- `test_XR_CFG01_epochRaiseReachableByRaisingBothTimelocksFirst`: a 7-day epoch is reachable by raising the policy T
  (instant) and the vault T (2-day queue), then queueing E.
- Code read: every check point (policy init, propose, apply, timelock propose and apply, vault init, vault
  `setTimelockDelay`) re-checks the other side's current value. A pending change on one side is re-checked when it
  applies. No ordering leaves T < E + 1 d.

**XF-05 (Info, webapp).**
- `pages/GainsLaunch.tsx` sends a fixed `timelockDelay = 2 days` with a free "Epoch length (days)" field: any value
  above 1 reverts `create`.
- `components/manage/GovernanceCards.tsx` lets the owner propose an epoch above T − 1 d, which reverts.
- With KEY-06 applied, `GainsCards.tsx:487` and `data/gainsChain.ts:146` fall back to `epochStartedAt +
  maxEpochDuration`; that must become `epochDeadline()`.
- GovernanceCards labels an epoch tightening "instant", but under KEY-06 it applies from the next epoch.

## 3. GR2-KEY-06

**Closes** the key routes. XR-01..03, ECON-02 ×2 and XR_ECON02 fail on the patched tree, and the KEY06 fix test
passes. The epoch deadline fixed at start also closes CFG-02. Combined with CFG-01, the KEY-06 CFG-02 test must use a
raise that fits the timelock, as COMBINED.md says.

**XF-02 (Low) — the "value its last ratchet replaced" cap re-opens C-01 for one more interval after a downward
ratchet.**

`test_XR_KEY06_pumpBackToTheReplacedValuePaidAfterADownwardRatchet`:
1. A 100k vault at 4x; ETH −4.5 %, so NAV goes 99,200 → 81,236.
2. A stranger's `checkRisk` ratchets the stale checkpoint down to 81,236 and records DAILY_LOSS.
3. 20 minutes later NAV reads 97,204 (a pump or a rebound; A1).
4. The redemption-only settle pays the 50 % redeemer:
   - patched: **48,602** (the full pushed-up NAV, cap = prior = the pre-loss checkpoint);
   - 4ec6feb: **40,618** (cap = the post-loss checkpoint).

The difference, 7,984 USDC, is 16 % of the redemption and comes out of the stayers. Passes on the patched tree; FAILS
on 4ec6feb, as expected.

Context (`test_XR_KEY06_preExisting_pumpPaidInTheFirstIntervalOnBothTrees`, passes on both trees): if the loss lands
while the checkpoint is fresh, 4ec6feb also pays the pushed-up NAV, because its cap is still the pre-loss checkpoint.
So C-01 already had a window of up to 1 h after a loss. KEY-06 extends it to up to 2 h, and the extra hour starts
exactly when a loss breach has just been recorded. That is when redemption-only settles run, and the manager chooses
the moment.

- Bound: min(pump, one ratchet step ≤ maxNavMove 20 %) × the redeemed share. It never pays above a level the vault had
  at a checkpoint, as the README says.
- Realistic pump tools (GNS-01 / XR-01 ≤ ~5 % of NAV) bring that down to a few % of a redemption.
- Low: it needs a NAV pump and a loss breach.

**Fix-round change (recommended):** use `max(checkpoint, prior)` only for **exit-only** settles, the key-chosen route
KEY-06 targets. Keep `min(NAV, checkpoint)` (fresh) or the stale-ratchet rule for **redemption-only** settles. Their
ECON-02 form is already capped by NavMoved and avoidable by cancelling. Otherwise, write the extra interval into
KNOWN-ISSUES next to REAUDIT3's lag.

**Other checks:**
- The "choose a moment" low-cap variants stay closed:
  - A settle resets prior = checkpoint, but a settle pays at the live NAV of that moment.
  - A dip confirmed twice ≥ 1 h apart is the documented residual.
- A stranger's skew-induced dip followed by `checkRisk` cannot lower the cap: prior keeps the pre-dip value.

## 4. GR2-KEY-01

**Closes.** The mock fix test passes, and the fork result is the author's (`run-fork.txt`; not re-run here, no heavy
lock taken). Per pair, the cap covers open trades, resting limits (collateral × leverage), pending opens and
leverage-only partial opens (pair read from the trade). `updateLeverage` keeps the position size on Gains, so it adds
no notional. Code read: `_checkPairDepth` and `_lossGate` are called only from `openTrade`, `increaseTrade` and the
raise branch of `updateLeverage`.

| Test (`XRKey01`) | Shows |
|---|---|
| `depthZeroOrCut_exitsSettleRedemptionUnaffected` | depth 0 on ETH: ETH opens refused, BTC opens fine; reduce, close, flatten, checkRisk, settle and the redemption claim all work |
| `depthSelectorRemoved_onlyOpensRevert` | `getPairSkewDepth` reverting (a facet cut): every open reverts, every exit / settle / redemption works, NAV does not read it |
| `lossGate_neverOnExitsOrSettle` | NAV −18 % with no checkRisk: cancel, reduce, close and flatten work; the next checkRisk records the breach and the redemption-only settle pays |
| `strangerCannotTripEitherGate` | donation, a 500k deposit request, syncIndexes, checkRisk, accrueFees by a stranger: the cap still admits exactly up to 300k and nothing past it |

The loss gate reads the same NAV as `checkRisk`, which anyone can already call to record a real breach. Any outside
NAV push (GNS-03 skew, ≤ 0.55 %) can make the gate refuse only where `checkRisk` would already breach, so it adds no
grief.

**XF-04 (Info).**
- (a) Fail-closed outages: a depth of 0 refuses new risk on that pair, and a removed selector refuses it on every
  pair. This is trading liveness only.
- (b) The cap assumes `pairSkewDepths` is in tokens (1e18). If Gains changed it to USD, the cap would scale by the
  price (GNS-02 class). Add a sanity bound (for example depth × price within a range) or put the per-pair cap in the
  factory curation.
- (c) The 5 % rests on fee-tier discounts ≤ ~2/3 (the author's assumption), not verified here.

## 5. GR2-LIVE-01

**Closes** the permanent lock: no reader walks lifetime indexes.

| Test | Shows |
|---|---|
| `XRLive01::testFuzz_..._parityWithGainsListsUnderRandomHistory` (256 runs × 60 steps) | After every step, `openItems()` equals Gains' open trades / pending orders as sets, and the snapshot is a sum over them, so NAV, notional and counts equal the old reader's. Steps cover: market and limit opens, fills, **real-Gains limit execution at a new index** (`RealLimitDiamond`, per `executeTriggerOpenOrderCallbackDirect`) and mock same-index execution, vault close / reduce / increase, Gains TP / SL / liquidation closes, callback cancels, limit cancels, timeouts, price moves, and a stranger's `syncIndexes(0..3)` at random moments. After a full sync the cursors equal the counters and the tracked arrays equal the open items (bounded). |
| `realLimitExecutionNewIndex_valuedAndTracked` | the new index is valued before any sync; a stranger's sync tracks it, prunes the old one and changes nothing in NAV |
| `XRLive01Ports` (5 tests) | GV-01 ×3 via `getTrade` on tracked and unseen indexes, GV-02 (types 10 / 11 / 12 / 200 block and count; all 7 known non-holding types do not), and GR1-08 (`getTrade` unreadable, or `getCounters` reverting: NAV and flatten revert DiamondLayoutChanged, `flattenIndices` closes, the full stop still stops). The 9 failing tests are a harness change, not a lost protection. |

A stranger's `syncIndexes` cannot grief: it only staticcalls, it prunes only closed entries, and Gains never reopens
an index (verified in `TradingStorageUtils.storePendingOrder` / `storeTrade`: the counter only grows). Strangers cannot
create indexes for the vault either: MANUAL_* realizations, triggers and PNL withdrawals are filed under
`msg.sender`.

**XF-03 (Low) — unseen pending orders grow between syncs.**
- `closeTrade`, `reduceTrade`, `flatten`, `flattenIndices` and `cancelTimedOut` do not sync. Each close or reduce
  request adds one unseen pending-order index, and every NAV reader walks the unseen range.
- `reduceChurnGrowsUnseenOrders_strangerChunkedSyncRecovers`: 300 partial closes put `totalAssets` at 163,497 →
  7,948,233 gas, ≈ **25,949 gas per unseen order (mock)**.
- `settle` / `checkRisk` / trading call `sync(type(uint256).max)` once, so about 1,200 unseen orders already push a
  settle past 32M (extrapolated, mock cost per A2).
- Not a lock: anyone's chunked `syncIndexes(100)` restored 163,494 gas.
- The full stop is unaffected (`fullStopAndSettleWithUnseenOrders`: `triggerEmergency` 119,389 gas with 200 unseen
  orders; `tryReadTrades` walks only trade indexes, which closes do not create).
- Creating them takes about 1,200 vault-key partial closes, each waiting for a Gains callback.

**Fix-round change:** call a bounded `sync` in `reduceTrade`, `closeTrade` and the flatten paths. The unseen range is
then at most the fills since the last call. Also bound `settle`'s sync, or add a `MAX_UNSEEN` revert that names
`syncIndexes`, and have the keeper call `syncIndexes` routinely.

## 6. Do the five work together

- Order ECON-03, CFG-01, KEY-06, KEY-01, LIVE-01 applies cleanly (`fixes/all`).
- I mapped each of the 36 failures in `fixes/all-tests.log` to COMBINED.md's list:
  - CFG-01 (19): 7 CFG PoCs, 8 tests with a 1-day timelock, `isTighterFieldByField`, 3 tests needing E > 1 d.
  - KEY-06 (6): XR-01/02/03, ECON-02 ×2, XR_ECON02.
  - LIVE-01 (9).
  - ECON-03 PoC (1).
  - The KEY-06 × CFG-01 interaction (1).
- No other test fails. A re-run of the whole patched tree, with my 20 tests added, gives **412 pass / 36 fail with the
  identical failure set** (`run-all-full.txt`).
- All 20 of my tests run on the combined tree, so the patches also work together in the scenarios above:
  - KEY-01's gate with LIVE-01's index set;
  - KEY-06's cap with ECON-03's fee;
  - CFG-01's bounds with KEY-06's fixed deadline.

## 7. GR2-CI-01

- **PoC re-run** (`run-asis-ci.txt`, the worktree's `ConservationScenarios` in the 4ec6feb scratch tree): passes with
  identical numbers. NAV 698,810.80 → 738,810.76 (+39,999.96); fee 5.0608 instead of 4.7868 over 10,801 s.
- **Needs a Gains change: confirmed.**
  - Gains v10 `PendingOrderType` has 14 values. 10 is deprecated.
  - `initiateManualNegativePnlRealization` (12 / 13) is permissionless, but `pendingOrder.user = msg.sender`.
  - `triggerOrder` files under the bot.
  - `withdrawPositivePnl` (11) uses `_msgSender()`. The vault never calls it and has no trading delegate.
  - So no vault order carries an unlisted type today. Only a facet change that reports one of the vault's own orders
    under a new type can produce the phantom.
- **checkRisk claim: PROVEN** (`XRCi01::test_XR_CI01_phantomRaisesDayStartAndPeak_falseDailyLossBreach`, 4ec6feb).
  1. Two partial closes, 79k and 99k (they hold nothing), are reported as type 10, so NAV reads 876,810.72 against a
     true 698,810.80 (+25.5 %).
  2. Across UTC midnight, the first `checkRisk` by anyone sets the day start and the lifetime peak to 1.252586, against
     a true 0.998301.
  3. Types restored, NAV back to true, the next `checkRisk` records a **false DAILY_LOSS breach (2,030 bps)**: reduce
     only, redemption-only settles, deposits carried, until the next UTC day.
  4. The day reset clears it, but **the peak stays** (only `resume()` after a DRAWDOWN breach resets it). The vault
     carries a standing 2,030 bps drawdown, and the 50 % limit now fires at a real loss of ~37 %.
  5. The breach needs a phantom > 17.6 % of NAV present at the first check of a UTC day.
  6. No value moves: a redemption-only settle pays min(NAV, cap) ≤ the true NAV.
- **Severity: Low (kept).**
  - Impact: a fee overcharge of mgmt × phantom × time, plus liveness (a one-day false breach and a permanently tighter
    drawdown limit).
  - Likelihood: very low (a Gains facet change).
  - Fix-round change: make CONSERVATION.md's option 3 (no peak / day-start raise while an unknown-type order is
    pending) part of the fix, not optional, together with option 1 for fees.

## Files

- `xr-fixes/XRLive01.t.sol`, `XRLive01Ports.t.sol`, `XRKey01.t.sol`, `XRCfg01.t.sol` (patched tree only).
- `XRKey06Econ03.t.sol` (both trees; each test states its expected tree).
- `XRCi01.t.sol` (4ec6feb, the conservation world).

To run, copy them to `contracts/test/audit/gains/r2/xrfixes/` in a scratch tree (imports are relative to that
folder).

Raw runs:
- `run-all-xr.txt`: patched, 20 / 20 pass.
- `run-asis-xr.txt`: 4ec6feb. XRCi01 and 3 XRKey06Econ03 tests pass; the 2 tests asserting the patched behaviour fail
  as expected.
- `run-asis-ci.txt`: the CI scenarios and XRCi01.
- `run-all-full.txt`: the patched tree, full suite.
