# hl-r2: adversarial cross-review of the fixes

**Internal, AI-assisted review. Not an independent audit, and it must not be presented as one.**

- **Branch.** `audit/hl-r2-xfix`, from `audit/hl-r2` c88b9e2.
- **Nothing changed outside this review.** Nothing was deployed, sent or pushed. `contracts/src`, `server/src`, the
  webapp and the env files are unchanged.
- **Where the work is.**
  - PoCs and fix tests: `fixes/tests-xfix/`.
  - Proposed patches: `fixes/tests-xfix/patches/`.
  - Reproduce with `fixes/verify-xfix.sh`. Logs: `fixes/results/xfix-contracts.log` and `xfix-server.log`.

## How the fixes were attacked

- **Contracts, stage 1.** A throwaway with `HLR2-H01.patch` + `COMBINED-B.patch` and their tests patches, so the
  attacks run against the fixes the way they will ship together.
  - One VaultTypes hunk conflicts textually: `epochDeadline` is appended after `depositHold`. It is merged by hand,
    with no change in behaviour.
- **Contracts, stage 2.** Stage 1 plus my patches `XF01.patch` and `XF02.patch`.
- **Server, stage 1.** `exec/ALL.patch`.
- **Server, stage 2.** Stage 1 plus `XF-exec.patch`.
- **Pass/fail convention.** A PoC passes while the issue exists; each fix test inverts its PoC.
- **What was re-run after my patches.**
  - Contracts: the fixA/fixB fix tests, `AuditPoC`, `HyperVault.t.sol`, `Round4.t.sol`.
  - Server: the 62 fixC fix tests and 9 touched server test files (91 tests), plus `tsc`.
- **The test/audit/** step of verify-xfix.sh printed nothing.** That step builds the whole audit tree in one job. With
  HLO-07 in the tree, that build hits the known solc 0.8.28 internal compiler error (CONTRACT-MEDIUMS.md section 7);
  this is assumed, not confirmed.
  - The same set was run by hand in a pruned tree: 60 tests, 55 passed, 5 failed.
  - The 5 failures are all expected:
    - XF01 and XF02 PoCs (fixed by my patches);
    - `test_HLR2_H04_fix_managerOwnerOperatorCannotBridgeInEmergency` and `test_AUDIT_H02_*` (now `BridgeInFlight`
      instead of `Unauthorized`), both by design of XF01;
    - `test_HLR2_E01_fix_livenessAtTheNavMoveFloor` (test stacking with H01, see E01 below).
- **Not done.**
  - No heavy tools (mutation run holds the lock).
  - Gains (CFG-01/02) was reviewed by reading only. No Gains forge run: another session runs Gains forge on this
    machine.
- **Assumptions (most conservative reading).**
  - **XF-06.** A precompile account snapshot can mix two blocks:
    - `CoreReader.run` sends aggregate3 chunks in parallel;
    - a failed call is retried on the next URL;
    - a perp's mark is deduped into whichever chunk asked for it first.

    How often this happens on mainnet is **not measured**.
  - **The guardian.** It is treated as a cold EOA that may be slow or absent for days.

## Verdict table

| Fix | Verdict | Evidence | New findings |
|---|---|---|---|
| H01 + XB01 (exit before effect, HL) | **CLOSES WITH RESIDUAL** | Variants checked by reading and by the stage 1 tree (below); XF02 PoC | XF-02 (Low) |
| GR2-CFG-01 / 02 (Gains) | CLOSES WITH RESIDUAL (by reading only, not re-run) | Same `_noticeEta` / ceiling code; an overdue Gains epoch already refuses new risk | none proven |
| E01 (CheckpointBehind) | **CLOSES WITH RESIDUAL**; the executor half is missing | `XFIX.t.sol::test_XF04_*` (a cent above a stale checkpoint reverts the exit settle); `XFIX.xfix.test.ts::xfix_XF04_*` (the operator never walks it) | XF-04 (Medium) |
| E06 (platformHold) | **INCOMPLETE** | `xfix_XF05_owner_stop_is_never_settled`: the planner never settles an owner stop, and the keeper skips checkRisk in a full stop (`contractRisk.ts` hardStop) | XF-05 (Medium); XF-03 |
| H04 contract (emergency bridge = guardian/sentinel only) | **REGRESSION** | `test_XF01_emergencyExitNeedsAPlatformKeyForever`: alice is paid 0 of 100,002 USDC after 365 days. fixC's operator bridges with the keeper key (`main.ts:1442`), which this patch refuses in emergency | XF-01 (Medium) |
| HLO-07 (agent warm-up) | **CLOSES WITH RESIDUAL** | Reading (below) | none new; the residuals are confirmed |
| XA01 contract (depositHold) | **CLOSES** | `test_XF03_control_revokeKeepsExitsOpenAndMintsNothing` | (XF-05 planner) |
| X01 copy mirror fresh read | CLOSES WITH RESIDUAL (reading; the ~1 s block residual stands) | - | - |
| X03 bounded re-reads then stop | **CLOSES WITH RESIDUAL** | `xfix_XF07_close_stopped_position_left_open`, `xfix_XF08_*` | XF-07 (Low), XF-08 (Low) |
| X04 fan-out isolation | CLOSES (reading) | - | - |
| X05 UNEXPLAINED_OUTFLOW | **CLOSES WITH RESIDUAL**; it creates a false-positive path | `xfix_XF06_zero_mean_mismatch_acts_on_an_honest_vault`: ACT at 19.7 h, nothing left the vault | XF-06 (Medium) |
| X07 weight fairness | CLOSES WITH RESIDUAL | `xfix_XF08_thirty_sybil_vaults_refuse_the_hosted_vaults_third_order_read` | XF-08 (Low) |
| XA01 executor (ACT = triggerBreach, settle hold) | **REGRESSION** once the contract fixes ship | `test_XF03_monitorActAsTriggerBreachFreezesEveryExitUntilTheDeadline`: alice waits 6.9 days, then the vault is in a permanent emergency | XF-03 (Medium) |
| H04 executor (tip, emergency exit) | **INCOMPLETE** | Its bridge is sent with the keeper key, which contract H04 refuses (XF-01). It does not handle `CheckpointBehind` (XF-04) | XF-01, XF-04 |
| H06 per-vault budgets | CLOSES WITH RESIDUAL | Reading | Info: counters are in memory, so every restart grants each sybil vault its floor again (0.002 HYPE × N vaults per restart) |
| Governance alerts (owner decision c, XB02) | CLOSES WITH RESIDUAL | Reading of `chain/logStream.ts` and `governanceAlerts.ts` | Info (below) |

## New findings

### XF-01 (Medium, regression of the H04 contract fix): an emergency exit needs a platform key, with no time bound

- **What changed.**
  - Before H04: in emergency the manager, the owner and the operator could all `bridgeToEvm`.
  - After H04: only the guardian (cold EOA) and the sentinel (executor online key) can.
- **When the platform's keys are absent.** Executor down, sentinel key rotated, or the guardian away. Every redeemer's
  money on Core stays there, and the pro-rata emergency settle pays from idle USDC only.
  - PoC (stage 1): platform-vault-like vault, alice redeems everything, she forces the emergency at the deadline.
  - The honest owner/manager and the keeper are refused (`Unauthorized`). The settle pays 0.
  - 365 days later: still 0 of 100,002 USDC.
  - Nothing ends this except a platform key. Only the guardian can end an emergency.
- **It also breaks fixC's own automation.**
  - fixC's `emergencyExit` sends `bridgeToEvm` through `operate(..., keeperKey)` (`main.ts:1442`).
  - In emergency the contract refuses that key, so the automated exit can never bring USDC home. The run throws
    "operator failed".
  - fixB had said the executor must use the sentinel key; fixC did not.
- **Rating.**
  - Impact: a lock with no exit, for as long as the platform is absent (High-class impact).
  - Likelihood: low for "platform absent for long"; **certain** for "the automation cannot bridge".
  - Net: **Medium**.
- **Fix: `tests-xfix/patches/XF01.patch`.** Keep the guardian and sentinel unrestricted, and let the owner-chosen roles
  bridge in emergency again, but only `EMERGENCY_BRIDGE_COOLDOWN = MAX_UNLANDED_BLOCKS + 30 = 330` blocks after the
  previous bridge.
  - Every window (at most 300 blocks, unlanded) is followed by at least 30 free blocks for the exit settle. A chain of
    windows (H04) is impossible.
  - Fix tests (`XFIX.fix.t.sol`):
    - `test_XF01_fix_honestOperatorExitsWithoutThePlatform`: the keeper bridges and settles; alice is paid.
    - `test_XF01_fix_managerCannotChainWindows`: the manager's second bridge reverts `BridgeInFlight`; the
      sentinel's does not; the settle lands in the gap.
  - Superseded by design:
    - `HLR2_H04_Fix::test_HLR2_H04_fix_managerOwnerOperatorCannotBridgeInEmergency`;
    - `AuditPoC::test_AUDIT_H02_*`: its expectation becomes `BridgeInFlight` instead of `Unauthorized`; the bridge is
      still refused.
  - Alternative if the lead keeps H04 strict: wire the operator's emergency `bridgeToEvm` to the sentinel key, and
    accept the platform dependency in writing.

### XF-02 (Low, residual of H01 quantified): after a loosening applies in emergency, the close band is 20%, not 3%

- **The gap.** `flattenOrder(…, 0)` uses `maxSlippageBps`, which may be 2,000 bps. A reduce-only `placeOrder` uses the
  same band in a breach or emergency, with any tif. The 3% `MAX_FLATTEN_SLIPPAGE_BPS` caps only an explicit value.
- **PoC.** `test_XF02_loosenedSlippageWidensTheEmergencyCloseBandTo20pct`.
  - H01 timeline: alice is in emergency before the eta, then the loosening applies (permissionless).
  - The hostile manager's flatten is an IOC sell limit at 80,000 on a 100,000 mark (1% before the apply).
  - A reduce-only `placeOrder` at 80,000 is accepted.
- **Rating.**
  - The fill is the book's best bids, so the loss is bounded by book depth inside the band. On BTC/ETH/SOL that is
    small, and a manager-made gap is costly.
  - The same 20% default also applies to an honest platform flatten in a liquidity crunch.
  - Impact up to 20% × notional on a thin book; likelihood low. Net: **Low**.
- **Fix: `XF02.patch`.**
  - The default band becomes `min(maxSlippageBps, maxFlattenSlippageBps)`.
  - In a breach or emergency, `placeOrder` must stay within `maxFlattenSlippageBps`.
  - Fix tests: `test_XF02_fix_closeBandCappedAtTheFlattenCap` (97,000; 80,000 reverts) and
    `test_XF02_fix_normalOrdersUnchanged`.
  - `HyperVault.t.sol` and `Round4.t.sol` pass with it (86/86).

### XF-03 (Medium, executor XA01 half vs contract E06 / XA01): every monitor ACT freezes every exit

- **The path.**
  - With `MONITOR_ACT_BREACH=true` (the default) an ACT sends the sentinel's `triggerBreach`.
  - With E06 that sets `platformHold`: every settle (keeper, owner, manager) reverts `ReduceOnlyMode` until the cold
    guardian clears.
  - Otherwise a redeemer forces the emergency at the epoch deadline, and the vault stays in emergency for good.
- **PoC.** `test_XF03_monitorActAsTriggerBreachFreezesEveryExitUntilTheDeadline`: alice waits 597,598 s (6.9 days,
  the platform vault's 7-day epoch; up to 30 days on others).
- **The control shows the stop is unnecessary.** `test_XF03_control_revokeKeepsExitsOpenAndMintsNothing`:
  - with contract XA01, a sentinel **revoke** already holds deposits (nothing is minted at a deflated NAV);
  - the keeper's settle still pays alice in the same block.
- **The operator's hold makes it worse.**
  - The hold (`main.ts` `hold`: `agent() == 0` on a platform-run vault) blocks all settles, redemption-only ones
    included. It stays until a new agent arrives, which with H01 takes at least `maxEpochDuration + 1 day`.
  - A NAV_MOVE finding (a 10% price move) holds settles 24 h.
- **Rating.** Impact: exits frozen up to E (7–30 days), then a permanent emergency. Likelihood: every true or false ACT
  (see XF-06). Net: **Medium**.
- **Fix (not patched; it is wiring).**
  - On vaults that expose `depositHold()` (new factory): the ACT sends `revokeAgent`, with `triggerBreach` only as a
    fallback when the revoke fails.
  - The operator holds only settles that would price deposits. Under `depositHold` the contract already makes the
    settle redemption-only, so the hold is skipped there.
  - Keep today's `triggerBreach` behaviour for the round 3/4 vaults (no `depositHold`).

### XF-04 (Medium, E01 vs executor H04): the platform's emergency exit stalls on CheckpointBehind

- **How it stalls.**
  - In emergency the keeper sends no checkRisk: `decideCheckRisk` returns `send:false` on `hardStop`.
  - `emergencyExit` sends `settle` straight away and rethrows anything that is not `BridgeInFlight`.
  - With E01, a NAV even one cent above a checkpoint older than an hour reverts `CheckpointBehind`. Funding, open
    positions, or 0.01 USDC is enough. The checkpoint is never walked.
- **PoCs.**
  - `test_XF04_aCentAboveAStaleCheckpointRevertsTheEmergencySettle`: the keeper and the guardian both revert; one
    stranger `checkRisk` unblocks it.
  - `xfix_XF04_emergency_exit_never_walks_the_checkpoint`: 3 operator runs, 3 reverted settles, no checkRisk, nobody
    paid.
- **Rating.** Impact: the automated exit stops until someone calls checkRisk by hand. Likelihood: about half of the
  emergency settles with open positions. Net: **Medium**.
- **Fix: `XF-exec.patch`.** `emergencyExit` catches `CheckpointBehind`, sends the keeper's checkRisk and settles on
  the next run.
  - Fix test: `xfix_fix_XF04_checkRisk_then_settle`.
  - Also recommended: `decideCheckRisk` should not skip a vault in emergency or in an owner stop while redemptions
    wait.

### XF-05 (Medium, E06 and XA01 vs the planner): the contract's new exit paths are never used by the platform

- **The planner does not know the new modes.** `treasury/epochPlan.ts` (and the webapp's byte-for-byte copy) has no
  `platformHold` / `depositHold` input.
- **Owner stop.** `breachMode` maps reason 4 to "stop", so the operator never settles an owner-imposed stop. That is
  exactly the case E06 opened (`xfix_XF05_owner_stop_is_never_settled`).
  - The keeper also skips checkRisk there. After 1 day the redemption-only settle would revert `StaleCheckpoint`
    unless someone walks it.
- **Deposit hold.** The planner counts queued deposits as cash. The contract settles redemption-only (`depIn = 0`), so
  a settle with idle 5,000, queued 100,000 and redemptions 50,000 is planned and reverts `InsufficientLiquidity`
  (`xfix_XF05_deposit_hold_counts_deposits_as_cash`).
- **Rating.** Impact: the redeemers E06 meant to free still wait for the overdue path, as before the fix. Net:
  **Medium**.
- **Fix (not patched: it touches the shared webapp planner).**
  - Read `platformHold()` and `depositHold()` into `EpochInput`.
  - `breachMode` returns "loss" (redemption-only) for reason 4 without a platform hold, and for `depositHold`.
  - The keeper's checkRisk runs in those modes.

### XF-06 (Medium on the worse reading, X05): UNEXPLAINED_OUTFLOW sums read noise that has no drift

- **The flaw.** Drops are summed over 24 h and rises never net them. A snapshot whose account value and marks come
  from different blocks (assumption above) gives a drop of |szi × Δmark| either at the bad look or at the next one,
  whatever the sign.
- **PoC.** `xfix_XF06_zero_mean_mismatch_acts_on_an_honest_vault`.
  - An honest 100,000 USDC vault, 5 BTC (5x).
  - 10 split reads in 24 h at ±0.05% skew, alternating sign (zero mean).
  - Result: ACT at 19.7 h, and the sentinel's `triggerBreach` is sent (XF-03).
  - Control: without skew, nothing.
- **Rating.**
  - Impact: XF-03 on an honest vault.
  - Likelihood: unmeasured. It needs about 1 in 140 looks mismatched at 5x leverage.
  - Rated **Medium** on the worse reading; open question for the lead: measure the chunk-split and retry rate.
- **Fix: `XF-exec.patch` (`monitor.ts`).**
  - With unchanged positions, no order and no bridge, a rise offsets the window's latest drops, and a drop offsets
    earlier rises. The sum is the net decline. Rises at a funding hour are never credited.
  - Fix test: `xfix_fix_XF06_skewed_reads_do_not_act`.
  - All 13 X05 fix tests still pass (drain, dribble, spot buy, PM switch, masked other-dex), along with the
    monitor-agent, monitor-breach and monitor-falsepositives server suites.
  - Residual: a thief can steal up to the amount a third party credited to the vault inside the window.
  - The better fix is a single-block snapshot: read the account and its marks in one `aggregate3`, or read the block
    number in the batch and discard mixed snapshots.

### XF-07 (Low, X03): a full reduce-only close is stopped too

- **When.**
  - The submit threw before reaching the venue;
  - and `orderStatus` stays unreadable for about 15 s, for example our own weight budget busy (`HlBudgetBusyError`,
    see XF-08).
- **Result.** X03 ends a CLOSE / CLOSE_ALL after one attempt with nothing sent. No automatic redelivery exists
  (`processor.ts`: the signal is FAILED), so the position stays open until a manual action.
  - A second reduce-only IOC for the full size can only close to zero, never open, so it is safe to send.
- **PoC.** `xfix_XF07_close_stopped_position_left_open`.
- **Fix: `XF-exec.patch` (`executor.ts`).** Full reduce-only closes keep retrying; opens and partial trims still stop.
  - Fix tests: `xfix_fix_XF07_close_retried_and_filled` and `xfix_fix_XF07_open_still_stops`.
  - All 6 X03 fix tests still pass.

### XF-08 (Low, X07): fairness per vault id, so 30 sybil vaults refuse a hosted vault's later reads

- **The flaw.** The least-served vault goes first. With N attacker vaults saturating the 600/min budget, a hosted
  vault that has already used more than 600/N weight in the last minute waits behind all of them.
- **PoC.** `xfix_XF08_thirty_sybil_vaults_refuse_the_hosted_vaults_third_order_read`.
  - 30 sybil vaults at 1 order/s each.
  - The hosted vault's CLOSE_ALL (3 orders): reads 3 and 4 are **refused after 30 s** (`HlBudgetBusyError`). That is
    X03's "unreadable", so an open stops, and a close stops too without XF-07.
- **Rating.** It needs 30 executor-served attacker vaults (copy vaults with an attacker-run source). Launch is closed
  today. Net: **Low**.
- **Fix (not patched).**
  - Fairness per tenant owner, not per vault id.
  - A reserved share (for example 30%) for platform-run and outside-deposit vaults.
  - `orderStatus` after a thrown submit (X03) on its own priority.

## Answers to the brief's specific questions

**E01 (can a hostile party keep the checkpoint lagging?).**
- **Who walks it.** `checkRisk` is permissionless, moves at most once an hour, and moves by at most `maxNavMoveBps`
  (≥ 5%).
- **What blocking would take.** Holding the settle back would need the NAV to really rise by more than m every hour,
  each hour: at the 5% floor and 5x leverage, about 1%/h in the underlying.
- **The hostile manager cannot counter-move in emergency.**
  - The agent is revoked and trading is reduce-only.
  - Bridges are platform-only (or on cooldown with XF01).
  - The manager calling checkRisk first only moves the checkpoint toward the NAV.
  - Once a step reaches the NAV, the settle succeeds for the next hour even if the NAV rises again (the fresh,
    uncapped checkpoint is paid).
- **A checkpoint set at a dip** withholds at most an hour of rise.
- **Precompile failure** blocks everything, as before (CONTEXT 7).
- **The real E01 gap is liveness in the executor (XF-04).**
- **A test-stacking note for the integrator.** `HLR2_E01_Fix::test_HLR2_E01_fix_livenessAtTheNavMoveFloor` fails with
  `NotReady` on H01 + COMBINED-B. It warps `timelockDelay` instead of the stored eta. It is not a fix bug.

**XA01 depositHold / E06 platformHold with the guardian absent.**
- **depositHold.** Deposits are closed. Queued deposits are carried and stay cancellable (control test). Redemptions
  keep settling redemption-only at min(NAV, checkpoint). Cost: deposit liveness only.
- **Griefing with depositHold.**
  - The owner cannot set or clear it.
  - The sentinel or the factory key can only close deposits.
  - A guardian `clearBreach` works on a vault that is not breached. The XA01 clear sits before `_clear`, which does
    not revert; `clearBreach` only reverts in emergency.
- **platformHold.** It freezes every exit until the deadline: XF-03, and XF-06 for the false-positive path.

**H04 with both platform keys unavailable.** Exits are stuck for good. That is worse than before (XF-01).

**HLO-07.**
- **What exists.** An alert already fires: `tenants/launch.ts` `onVaultCreated` / `onPlatformAgentRegistered`,
  "PLATFORM AGENT NOT OURS" (error, HLO-E06), for an unreserved agent.
- **What does not.** No automatic sentinel `unregisterPlatformAgent`.
- **When the theft still happens.** If the alert is missed, or the executor (indexer) is down for 24 h, it goes ahead
  exactly as before.
- **The owner() signer path is still a hole.** A leaked factory owner key rotates the guardian and the sentinel
  instantly, so nobody can veto. It closes only with owner = guardian as a Safe, or by dropping the path.
- **A vetoed vault is left on deposit hold** until the guardian reopens it (conservative, by design).

**Exit before effect (eta formula).**
- **Overflow.** None: uint64 timestamps plus at most 30 days.
- **The ceiling.** `epochDeadlineCeiling` only ratchets, but it can only reach "lowering time + old E". Its effect ends
  31 days after the lowering, and it delays only the owner's own changes. Platform actions (guardian clear, emergency,
  disallow, pauses) never go through the notice.
- **Honest maintenance gets slower, not impossible.**
  - An agent rotation or a queued clearBreach waits E + 1 day (31 days on a 30-day vault).
  - Note: the platform vault's agent approval expires after 90 days (HLR2-F01). A rotation must be queued at least E + 1 day before
    it expires.
- **Trap variants checked.**
  - A partial fill that carries a redeemer into a later epoch is impossible outside emergency: normal, loss-breach and
    owner-stop settles pay in full or revert `InsufficientLiquidity`.
  - The guardian's `triggerEmergency` works at any time.
  - The only residual is the documented one: a redeemer who asks more than 1 day after the queue, after an intervening
    settle (which may be the honest keeper's daily settle), is in the new epoch.

**Alerts.**
- **No gaps.** The log stream keeps persistent per-consumer cursors and catches up range by range, so outages do not
  lose events. Spans are halved on range errors. HyperEVM finality is fast and confirmations are applied.
- **Info gaps.**
  - (a) `initialCursor = head`: no backfill of items queued before the consumer's first start. The fix: at start, read
    `pendingConfig()`, `assetAllowEta` and the vault queue for every target.
  - (b) A loosening handled after its eta, following a long outage, is compared against the already-applied config
    and alerts at warn.
  - (c) It still ends at a human. With XF-03 fixed, the alert is the guardian's cue.

## Open questions (not proven)

1. **XF-06 likelihood.** The rate of mixed-block account snapshots on mainnet: chunk splits, retries on another URL.
   Needs a read-only measurement (log the block number per aggregate3 chunk).
2. **Gains CFG-01/02.** Not re-run here.
3. **Combined tree, end to end.** The combined tree (H01 + COMBINED-B + exec ALL + my patches) was not run through
   the whole suite. Only the files listed under "How the fixes were attacked" were. The integrator owns the full run.

## Files

- `fixes/tests-xfix/XFIX.t.sol`: forge PoCs XF01–XF04.
- `fixes/tests-xfix/XFIX.fix.t.sol`: forge fix tests XF01–XF02.
- `fixes/tests-xfix/XFIX.xfix.test.ts`: vitest PoCs XF04–XF08.
- `fixes/tests-xfix/XFIX-fix.xfix.test.ts`: vitest fix tests.
- `fixes/tests-xfix/vitest.config.mjs`.
- `fixes/tests-xfix/patches/XF01.patch`, `XF02.patch` (on top of H01 + COMBINED-B) and `XF-exec.patch` (on top of
  exec/ALL).
- `fixes/verify-xfix.sh`; `fixes/results/xfix-contracts.log`, `xfix-server.log`.
