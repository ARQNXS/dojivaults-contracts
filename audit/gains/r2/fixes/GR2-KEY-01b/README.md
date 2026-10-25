# GR2-KEY-01b: per-pair factory cap, turnover budget, minimum hold (on top of GR2-KEY-01)

**Internal, AI-assisted review. Not an independent audit.** This is a proposed patch for the fix round; nothing in
`contracts/src` was changed. The design and the reasoning are in [../../FIX-DESIGN.md](../../FIX-DESIGN.md), sections A
to C. The extraction bounds per vault size and cap are in [../../KEYS.md](../../KEYS.md), "GR2-KEY-01b: extraction
bounds", and the model is bounds/model.py (not included) with its output in
bounds/model-output.txt (not included).

**Revision 2 (2026-10-21, owner decisions):**
- the pair cap is a per-pair factory parameter set by the guardian, no longer the fixed 1 %;
- Gains' own TP / SL closes are explicitly outside the hold;
- **D10:** 1 % on BTC, ETH and SOL at launch, raised only by the guardian, up to the 10 % ceiling;
- the raise delay is **31 days**, the policy's longest epoch + 1 day, derived from that bound (exit before effect).
  It replaces the first draft's 7 days.

`fix.diff` is relative to the **KEY-01 patched tree**. Apply it with `git apply` from the repo root, after
`../GR2-KEY-01/fix.diff`:

```
git apply contracts/audit/gains/r2/fixes/GR2-KEY-01/fix.diff
git apply contracts/audit/gains/r2/fixes/GR2-KEY-01b/fix.diff
```

This order was checked on a clean export of 4ec6feb. Every file it produces is byte-identical, ignoring line endings,
to the tested scratch tree.

On the full five-patch stack ([../COMBINED.md](../COMBINED.md)), every hunk applies except one: the `VaultStorage`
append in `GainsTypes.sol`. KEY-06 also appends there. Resolve it by putting the four KEY-01b fields after KEY-06's
`epochDeadline`.

`test-port.diff` ports `KEY01FixTest` so it takes its depth from `DEFAULT_PAIR_SKEW_CAP_BPS`. It applies to the fix test
once that is copied to `contracts/test/audit/gains/r2/fixes/KEY01FixTest.t.sol`.

## What changes

1. **Per-pair skew cap, set on the factory** (revision 2).
   - **Storage.** `GainsVaultFactory` keeps one slot per pair: `PairCap {uint16 bps; bool set; uint16 queuedBps; uint64 eta}`.
   - **Read.** Every factory vault reads `pairSkewCapBps(pair)` from the factory. It does this in `_checkPairDepth`, at
     every open, increase and limit or stop placement. The vault's notional on the pair (open + resting + pending + new)
     must stay at or below `cap × getPairSkewDepth × Chainlink price`.
   - **Lowering:** `setPairSkewCap(pair, bps)` with `bps ≤ current`.
     - The guardian or the sentinel may call it. A lowering only reduces risk, and the hot sentinel is the executor's
       alarm hand.
     - It applies at once, to the next order of every factory vault.
     - It also drops a queued raise, so a raise cannot outlive an alarm.
   - **Raising (guardian only):** the guardian calls `queuePairSkewCap(pair, bps)`, then `executePairSkewCap(pair)`
     once `PAIR_CAP_RAISE_DELAY` has passed (it reverts `NotReady(eta)` before). The guardian or the sentinel can
     `cancelPairSkewCap(pair)`. The sentinel can never raise: `setPairSkewCap` refuses it a raise and its first
     setting, and `queue` and `execute` are guardian-only.
   - **`PAIR_CAP_RAISE_DELAY = POLICY_MAX_EPOCH_DURATION + 1 days` = 31 days.**
     - The policy's real bound on `maxEpochDuration` was the literal `30 days` in `GainsVaultPolicy._validate`. The
       patch names it, as the file-level `POLICY_MAX_EPOCH_DURATION` and the public `GainsVaultPolicy.MAX_EPOCH_DURATION`,
       and `_validate` and the delay both use it. Changing the epoch bound therefore changes the delay with it.
     - **Exit before effect:** a depositor who asks to redeem when a raise is queued is in an epoch that started
       before the queue. That epoch is overdue (anyone can settle it) no later than 30 days after its start, even if
       `maxEpochDuration` is raised meanwhile, so the depositor is paid at least a day before the raise applies. In an
       exit-only settle with too little idle, the redemption is filled pro rata and the rest returned to ask again.
     - **The first draft's residual (epochs over 6 days) is gone** for every epoch the code accepts. With
       GR2-CFG-01 the longest usable epoch is 29 days, so the margin is two days.
   - **The waiting period is new.** The factory had no timelock or queue of its own (its owner setters are instant), so
     this is the minimal queue-then-execute. It holds one pending raise per pair, and a new queue replaces the old one and
     restarts the wait.
   - **Ceiling:** `MAX_PAIR_SKEW_CAP_BPS = 1,000` (10 %). A queue above it reverts `InvalidPairCap`.
   - **Unset pair = no new exposure.** A pair never set has cap 0, and any order on it reverts `OrderRejected("pair cap")`.
     This is the conservative choice (ROUND2.md assumption A-7). D10's launch state is BTC, ETH and SOL at 100 bps,
     each set with one guardian call (`setPairSkewCap(pair, 100)`) at deployment.
     - The guardian's **first** setting of a pair is immediate up to `DEFAULT_PAIR_SKEW_CAP_BPS = 100` (1 %), because no
       vault could trade the pair yet.
     - Anything above that, and every later raise (including one from 0 after a lowering), waits.
     - The sentinel cannot make a first setting.
   - **Standalone vaults** (no factory) use the constant `DEFAULT_PAIR_SKEW_CAP_BPS` (1 %). The fix round may add a
     setter for them; no standalone vault is deployed.
   - **Events:** `PairSkewCapSet(pair, bps)`, `PairSkewCapQueued(pair, bps, eta)` and `PairSkewCapCancelled(pair)`.
   - **Errors:** `NotGuardian()`, `InvalidPairCap(bps)`, `NotQueued()` and `NotReady(eta)`.
   - **Interface:** `IGainsPairCaps` in `GainsTypes.sol`.
   - **Why 1 % as the default:** at 1 % the thief's best route loses on every curated pair. The break-even is 2.13 %
     (BTC, ETH) and 1.5 % (SOL) against the cheapest possible opposite account (KEYS.md).
2. **Turnover budget** (`TURNOVER_NAV_MULTIPLE = 20`, `GainsNav.spendTurnover`). Unchanged from the first KEY-01b.
   - Opened notional is a token bucket of 20 × NAV that refills linearly over one day. Opens include market opens, limit
     and stop placements, and `increaseTrade`'s added size.
   - A refused order reverts `OrderRejected("turnover")`.
   - Exits never spend it.
3. **Minimum hold** (`MIN_HOLD = 10 minutes`, `MIN_HOLD_L2_BLOCKS = 2,400`). Unchanged in code; its scope is now
   explicit.
   - **Held:** `closeTrade`, `reduceTrade`, `flatten` and `flattenIndices` by the manager or agent, outside a breach or
     emergency.
   - **Not held:** the guardian; any exit in a breach or emergency; the operator; and **Gains' own TP, SL and liquidation
     closes**. Those are executed by Gains' bots, never pass through the vault, and `setSlTp` is not held, so a stop loss
     always fires.
   - The residual this leaves: a TP set past the market is an immediate close by the bots. It is quantified in KEYS.md
     and does not change the extraction tables.
4. **Storage** (vault). Appended to `VaultStorage`: `uint128 turnoverUsed`, `uint64 turnoverAt`, `uint64 lastRiskAt` (one
   slot) and `mapping(uint16 => uint64) pairRiskAt`.
5. **Test harness** (part of the patch).
   - `GainsBase`, `GainsFactoryTest` and `GainsRound4FactoryTest` set BTC, ETH and SOL to 100 bps, using the guardian's
     first setting.
   - Fork bases that create factory vaults (`XReviewKeyForkBase`, `KeysForkBase`, `GainsSideForkBase`,
     `LiveLifecycleBase`, `ConservationWorld`, the `test/gains/fork` and `test/audit/gains/{lifecycle,nav,replay}` bases)
     need the same three calls after curation. This patch does not edit them; they are outside the mock suite run here.

## Sizes

| Contract | 4ec6feb | KEY-01 | KEY-01b (first) | **KEY-01b rev. 2** | Limit |
|---|---|---|---|---|---|
| `GainsVaultLogic` | 21,919 | 23,252 | 23,916 | **24,113** (463 bytes left) | 24,576 |
| `GainsVaultFactory` | 12,203 | 12,203 | 12,203 | **13,523** | 24,576 |
| `GainsNav` | 15,740 | n/a | 17,551 | 17,551 | 24,576 |
| `GainsVaultPolicy` | n/a | n/a | n/a | 12,952 (the 30-day epoch bound is now the named constant) | 24,576 |

`GainsVaultLogic` has 463 bytes of headroom left. If the five-patch stack needs more, move `_checkPairDepth` into
`GainsNav`.

## Fix tests

`FixTest.t.sol` has two contracts, `KEY01bFixTest` (standalone vault) and `KEY01bPairCapFixTest` (factory vault,
GovBase). It imports no KEY-01 or KEY-01b constant and calls the factory's cap functions by signature, so it compiles on
every tree.

| Test | First KEY-01b tree (cap a constant) | **Rev. 2** |
|---|---|---|
| `test_KEY01b_fix_pairCap_factoryVaultReadsThePairCapPerPair`: the vault reads its pair's cap; caps are per pair; a sentinel lowering binds the next order; cap 0 → "pair cap" | FAIL | PASS |
| `test_KEY01b_fix_pairCap_lowerIsImmediateRaiseWaits`: lowering immediate; a direct raise reverts; queue → `NotReady` at once and at 31 days − 1 s → applies at 31 days | FAIL | PASS |
| `test_KEY01b_fix_pairCap_raiseDelayIsLongestEpochPlusOneDay`: the policy's `MAX_EPOCH_DURATION` is 30 days and the delay is that + 1 day; a vault with a 30-day epoch launches and 30 days + 1 s is refused; a raise queued at its epoch start reverts at 31 days − 1 s and applies at 31 days, one day after that epoch ends | FAIL | PASS |
| `test_KEY01b_fix_pairCap_onlyGuardianRaises`: factory owner, vault owner, manager and a stranger may do nothing; the sentinel may lower and cancel, not raise, queue or execute | FAIL | PASS |
| `test_KEY01b_fix_pairCap_ceiling`: 1,001 refused, 1,000 applies; a queue must raise | FAIL | PASS |
| `test_KEY01b_fix_pairCap_lowerDropsQueuedRaise` | FAIL | PASS |
| `test_KEY01b_fix_pairCap_unsetPairDefaultsToNoExposure`: unset = 0; the guardian's first setting is immediate up to 100, not 101; the sentinel cannot set it; after a lowering to 0 a raise waits | FAIL | PASS |
| `test_KEY01b_guard_gainsTpSlClosesAreNotHeld`: inside the hold, `setSlTp` (a TP behind the market) works and the manager's close is refused "min hold"; Gains' trigger closes the trade in the same block and pays the vault | PASS (guard) | PASS |
| `test_KEY01b_fix_pairCapIsOnePercentOfSkewDepth` (standalone default), `minHold_*` (3), `turnoverBudget`, `guard_platformAndBreachExitsNeverHeld` | PASS (FAIL on the KEY-01 tree alone, run-unfixed.txt (not included)) | PASS |
| `test_KEY01b_gas_factoryVaultOpen` (logs only) | PASS | PASS |

Runs:
- run-unfixed-rev2.txt (not included): first KEY-01b tree, 8 pass / 7 fail as expected;
- run-fixed-rev2.txt (not included): rev. 2, 15 / 15 pass;
- run-unfixed.txt (not included) and run-fixed.txt (not included): the first KEY-01b against the KEY-01 tree.

`KEY01bForkFixTest.t.sol` runs on the real diamond (public RPC, tip − 40). The guardian sets BTC, ETH and SOL to 1 %;
`KEY01B_CAP_BPS` sets ETH's cap for the run. A raise above 1 % goes through the real queue and execute, with a warp of
`PAIR_CAP_RAISE_DELAY` and a fresh vault. All three caps ran on block 516,927,412 (ETH depth 14.13M), then 1 % and 10 % again
with the 31-day delay on block 516,936,629: 4 / 4 each time (run-fork-rev2.txt (not included)). The second run gave
−38.63 / −90.10 at 1 % and +765.97 / +239.86 at 10 %. The table shows the first run:

| Test | ETH cap 1 % | 5 % | 10 % |
|---|---|---|---|
| Counter-trade double swing: thief PnL (A) | **−37.47** (A 124.9k) | **+59.95** (A 651k) | **+761.71** (A 1.31M) |
| Plain double swing, no fee tier | −87.40 | −200.31 | **+238.53**: positive even without the counter-trade discount |
| XR_08: 250k ETH opens from a ~1M vault, refused "pair depth" after | 0 (cap 141.3k) | 500k (cap 706.6k) | 1.25M (cap 1.41M) |
| Min hold on the real diamond (manager refused, guardian not, manager after 650 s) | PASS | PASS | PASS |

The first run, on the KEY-01 tree at 5 % (block 516,673,656: +63.35 / −211.33), stays in run-fork.txt (not included).

## Gas (mock diamond)

| Call | KEY-01 | KEY-01b (first) | **Rev. 2** | Added by rev. 2 |
|---|---|---|---|---|
| openTrade, standalone vault, first on the pair | 302,096 | 370,765 | 370,885 | +120 |
| openTrade, standalone vault, second on the pair | 369,113 | 381,010 | 381,130 | +120 |
| **openTrade, factory vault, first on the pair** | n/a | 370,898 | **377,523** | **+6,625** (one external `pairSkewCapBps` call, cold factory account and slot) |
| openTrade, factory vault, second on the pair | n/a | 381,136 | 387,783 | +6,647 |
| increaseTrade | 434,174 | 445,865 | 445,985 | +120 (+≈6.6k on a factory vault) |
| closeTrade / reduceTrade (manager) | 142,738 / 148,274 | 161,021 / 166,577 | 161,021 / 166,577 | 0 |
| closeTrade (guardian, never held) | 149,674 | 149,805 | 149,805 | 0 |
| Factory: `setPairSkewCap` / `queuePairSkewCap` / `executePairSkewCap` | n/a | n/a | one storage slot each (not measured; estimate 25–45k) | `set`: the guardian, or the sentinel to lower only; `queue` / `execute`: the guardian only. Rare |

## Existing tests

Mock suite on the rev. 2 tree: **376 pass, 45 fail, 2 skipped (fork)** of 423 (run-fixed-rev2.txt (not included)).
These are the same 45 as the first KEY-01b, and all are expected; none fails on "pair cap", "turnover" or for any other
reason:
- **39 fail with `OrderRejected("min hold")`.** These tests close, reduce or flatten as the manager or agent right after
  opening. The port is to wait `MIN_HOLD` and roll `MIN_HOLD_L2_BLOCKS` before the exit, or exit as the guardian.
- **6 `AccessMatrix` tests** (`DP`, `FS`, `N`, `OD`, `SD`, `TP`) fail because ACCESS-MATRIX.md still says the manager
  and agent may close, reduce and flatten at any time. Update those rows to "after the minimum hold, or in a breach or
  emergency".

Without the harness change in this patch, 15 more factory-vault tests fail with "pair cap": `GainsFactoryTest` and
`GainsRound4FactoryTest`, whose factories never set a cap. That is the intended fail-closed default.

## Executor

- Treat `OrderRejected("pair cap")` as "pair closed to new exposure by the platform", with an alarm, never a retry.
- Treat `OrderRejected("min hold")` on a close as "retry at `max(pairRiskAt + 10 min, fill block + 2,400 L2 blocks)`".
  A view `holdUntil(pair, index)` in the lens would help.
- Treat `OrderRejected("turnover")` as a strategy limit, with an alarm.
- New alarms:
  - on `PairSkewCapQueued`: a raise is coming, with 31 days to object and exit;
  - on Gains changes to `getPairCounterTradeFeeRateMultiplier`, the fee tiers, `pairTotalPositionSizeFeeP` and the
    spread: re-check each pair's cap against its break-even (KEYS.md), and let the sentinel lower it if needed.
- The circuit breaker: these are the **proposed WP3 defaults**, not yet code (FIX-DESIGN.md). It trips on a loss over
  5 % in a rolling 24 h or 2 % in 1 h, a drawdown over 10 %, or opened notional over 5 × NAV in 1 h; the sentinel
  then calls `revokeAgent()` and `setTradingPaused(true)` within 10 minutes.
- Keep the churn alarm (GR2-EXE-01).

## Residuals (stated, not closed)

- **Epoch length: closed.** The first draft's 7-day delay did not cover epochs over 6 days. The 31-day delay, derived
  from the policy's epoch bound, covers every epoch the code accepts (see above). What remains is only that a
  depositor who asks later than a day after the queue, in a 30-day epoch, may still be in when the raise applies.
- **Crossed TP or SL inside the hold.** An immediate close by Gains' bots. It is bounded by the cap, the turnover budget
  and the loss gate (KEYS.md); the owner's decision is that bots close freely.
- **The guardian sets every cap.** A compromised guardian can raise a pair to 10 % after 31 days. The sentinel can cancel
  the raise and lower the cap, and the factory owner rotates the guardian.
