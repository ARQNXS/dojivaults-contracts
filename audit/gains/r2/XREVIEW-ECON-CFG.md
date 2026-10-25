# Round 2 cross-review: ECON and CFG

**Internal, AI-assisted review. Not an independent audit.** I was asked to attack the ECON (ECONOMICS.md) and CFG
(CONFIG.md) conclusions: refute them, downgrade them, or find cases they missed. Worktree `dv-audit-gains-r2`, branch
`audit/gains-r2`. Where a point was ambiguous I took the most conservative reading and wrote the assumption down.

New tests: `contracts/test/audit/gains/r2/XReviewEconCfg.t.sol`, with contracts `XReviewEconTest` (R1Base, the ECON
live-like policy) and `XReviewCfgTest` (GovBase, factory launch). There are 9 tests, all named `test_GR2_XR_*`, and
all pass on the current code.

## Verdicts

| Id | Their severity | Verdict | My severity | One line |
|---|---|---|---|---|
| GR2-ECON-03 | Medium | **CONFIRMED, new** | Medium | Real. It contradicts the accepted I3-08 claim "never a depositor loss". The manager can force the breach with one open, without needing any price move. The proposed fix removes the transfer exactly (to the wei) and does not touch the loss-breach rule the earlier decision was made for. |
| GR2-ECON-02 | Medium (design) | **DOWNGRADED** | Low (design) | The redemption-only half is the lag REAUDIT3 section 10 accepted, and NavMoved bounds it to maxNavMoveBps. The exit-only half is mis-scoped in two ways. The "owner (also the manager on the live vault)" overdue route does not exist when owner == manager. The owner's real route is `triggerEmergency` at any time, which is loud and one-shot. |
| GR2-ECON-01 | Low (design) | **CONFIRMED** (known class, new method) | Low (design) | It is a consequence of the GR1-02 bid/ask documented in FIXES-R1 section 6: per flow, the charge is at most B × maxLeverage. What is new is the delta-neutral way to impose it. With real Gains fees it only pays on flows larger than about 56 % of NAV. |
| GR2-CFG-01 | Medium (maybe High) | **CONFIRMED Medium; High rejected; reachability widened** | Medium | The platform guardian can free the redeemer at any moment (`triggerEmergency` has no overdue condition for it), even after the loosening has applied. The residual risk is that nobody watches. New point: the live vault's shape (T 2 d, E 1 d) reaches T < E after one innocuous-looking queue, so "does not apply to the live vault" holds only today. |
| GR2-CFG-02 | Low | **CONFIRMED** | Low | Reproduced. The same guardian rescue applies. |
| ECON "checked and sound": first depositor after a full exit | sound | **CONFIRMED, with a correction** | Info | A 10M round trip captures 0 of a 522 USDC residual. The residual is never "released pro rata to later holders" as ECONOMICS.md says: it stays with the virtual offset shares. |
| ECON "checked and sound": Chainlink lag | sound | **NARROWED** (open question, known T3) | — | "Negative in total" holds only for round-trip strategies. A holder who times a one-way exit gains (lag − B) × L per flow whenever lag > B. That is ROUND1 open question T3 / GR1-15, not new. |

## Runs

| Where | Command | Result |
|---|---|---|
| Scratch `scratchpad/XR-ECON/asis` (copy of the worktree `src/gains`, `VaultTypes`, `VaultPolicy`, `hypercore`, `libraries` plus the harness files; no forge lock needed) | `forge test --match-path "test/audit/gains/r2/*.t.sol" -vv` | EconPoC 6/6, ConfigTimelock 5/5, XReviewEconCfg 9/9 (7 on the first run, the 2 owner-route tests added and run after): **all pass** |
| Scratch `scratchpad/XR-ECON/fix` (the same, plus the ECON-03 fix in `GainsVaultLogic.settle` and `GainsVaultLens.pendingFeeShares`) | `forge test -vv` over GainsRound4, NavUnit, HLRetest, EconPoC, ConfigTimelock, XReviewEconCfg (13 suites, 90 tests) | 88 pass, 2 fail, both expected (see ECON-03); raw: `audit/gains/r2/xr-econ-cfg/fix-tree-run.txt`, patch: `xr-econ-cfg/econ03-fix.diff` |
| Worktree (forge lock) | `forge test --skip XReviewKey XReviewLive --match-path "test/audit/gains/r2/{EconPoC,ConfigTimelock,XReviewEconCfg}.t.sol" -vv` | **20 / 20 pass** (EconPoC 6, ConfigTimelock 5, XReviewEconCfg 9), 2026-10-20 00:21-00:27, lock held only for that run. Output: `audit/gains/r2/xr-econ-cfg/worktree-run.txt` |

## GR2-ECON-03: CONFIRMED Medium, new

**Was "no performance fee in any breach settle" a deliberate earlier decision?** Yes.
- It was round 4 "Change 7". REAUDIT3 section 9 marks it "Correct", and section 11 verifies it: "No performance fee in a leverage breach: Correct, HWM unchanged" (`test_REAUDIT3_QB_leverageBreachSettle_managementOnly_hwmKept_metricsUnmoved`).
- The Gains port keeps it, with the comment "(any reason, leverage included)" at `GainsVaultLogic.sol:248`. The round 1 test `test_fees_breachSettleChargesNoPerformanceAndKeepsHwm` (NavUnit) also covers it.
- The only stated reason is in that test: "no fee on a NAV that may be deflated". It concerns loss breaches.
- The known consequence was recorded as **I3-08** (KNOWN-ISSUES): "Redeemers who exit in a breach epoch keep gains above the HWM without the performance fee ... **A fee recipient loss, never a depositor loss.**"

**Is the cross-subsidy new?** Yes.
- I3-08 analysed the redemption side only.
- The deposit side was never analysed. A leverage breach is the one breach mode that still **mints** deposits (`settle` lines 227-230).
- ECON-03 shows a depositor loss, so I3-08's "never a depositor loss" is wrong for leverage-breach settles. This is new evidence against an accepted item, not a re-raise.

**Can the manager force the breach at will?** Yes, with no price move and no gain needed.
- `test_GR2_XR_ECON03_managerForcesLeverageBreachAtWill_noPriceMove`: a flat 100k vault opens one ETH long at exactly the 5x limit. `checkOrder` accepts it against the pre-open NAV.
- Leverage is then 50,505 bps, because the new trade is valued at the adverse band edge. Anyone's `checkRisk` sets LEVERAGE.
- At 4.9x it is 49,484 bps and there is no breach. So the manager chooses, settle by settle.
- The manager's own normal-mode settle then mints the queued deposit with the HWM untouched.
- `requestDeposit` is closed during the breach, so only deposits queued before the open are caught. The manager decides when to open, so this is no protection.
- Even an honest manager at the limit causes this by accident: the keeper's `checkRisk` before its settle sets the breach.

**Conservative reading.** A depositor could cancel after seeing `Breached`. But `checkRisk` and `settle` can be sent back to back (Arbitrum FCFS ordering), so I assume no defence.

**Magnitude.**
- ECON's PoC, re-run: bob loses 1,438.18 USDC (97,755.27 against 99,193.46) and the fee recipient gains 1,419.39. The numbers are identical in the worktree and the scratch copy.
- The overcharge is perf × (entry price − HWM) / entry price on the deposit.
- It is not limited to one epoch's gain. The manager can keep normal settles from happening by breaching before each one: clear after the cooldown, let deposits queue, re-open to the limit, settle. The HWM then stays frozen for many epochs, and late depositors pay on all of the accumulated gain.
- Bounded by the 30 % performance cap times the gain since the last normal settle. This is ECON's own formula, which already covers several epochs.
- Medium stands: a fee above the cap for that depositor, at the manager's discretion.

**Is the proposed fix safe?** Yes, checked by mutation in the scratch `fix` tree.
- `_accrueFees($, !$.emergency && !_lossBreach($), venue)`.
- The scheduled-raise switch uses the same condition.
- `GainsVaultLens.pendingFeeShares` skips the performance fee only for emergency or a DAILY_LOSS / DRAWDOWN breach. Without this the lens is off by the fee in a leverage breach, which is R3-07 again.

Results:
- ECON-03 PoC: with the breach and without it, bob 99,193.455362 / 99,193.455362, fee recipient 2,212.594996 / 2,212.594996, alice 107,593.949639 / 107,593.949639. The breach no longer changes anything, to the wei (`scratchpad/XR-ECON/fix-econ03.txt`).
- The only other failure is `HLRetest.test_HL_R306_leverageBreachSettleKeepsTheRaiseScheduled`. This is expected and correct: the leverage-breach settle now charges the running epoch at the old rate, then switches the raise. That is exactly N2-02's rule, so R3-06's concern (a switch without the old-rate charge) does not come back. The test must be inverted.
- Unchanged and passing:
  - the daily-loss tests `NavUnit.test_fees_breachSettleChargesNoPerformanceAndKeepsHwm` and `GainsRound4BreachFeesTest` (lens parity included);
  - every emergency test in the 13 suites.
- So the reason for the earlier rule (no fee on a possibly deflated NAV, which is a loss-breach concern) is kept.
- A leverage breach says nothing about NAV integrity. A deflated NAV pushes leverage up but sits below the HWM, so no fee is charged anyway. An inflated NAV pulls leverage down, so it does not breach.

Also update:
- the NatSpec at `GainsVaultLogic.sol:248`;
- `docs/copy` "No performance fee is charged in any breach or emergency settlement" (security.tsx:97, depositors.tsx:208);
- KNOWN-ISSUES I3-08.

**Out of scope, noted.** HL `VaultLogic.sol:226` has the same line, so HL vaults have the same leverage-breach mint path. I did not test it.

## GR2-ECON-02: DOWNGRADED to Low (design)

**Redemption-only half: a known, accepted rule.**
- REAUDIT3 section 10 ("question a") recommended `min(nav, checkpointBefore)` for redemption-only settles and stated the consequence: "an upward reading is paid at the lagging checkpoint (**at most one hour and at most m behind**), which favours the holders who stay". It also noted that "any listed role chooses the settle moment".
- ECON-02's 15.2 % loss is that lag, measured during a real rebound.
- The NavMoved bound caps it. `test_GR2_XR_ECON02_redemptionOnlyGapBoundedByNavMove_andCancelDefence`: same scenario, with a full rebound to 198,040 over a 163,808 checkpoint (+20.9 %). The redemption-only settle reverts `NavMoved`, so the settler cannot pay the dip beyond m.
- `cancelRedeemRequest` works during the breach.

What ECON adds:
- real numbers;
- the observation that an honest keeper that settles right after its own `checkRisk` produces the same effect;
- a documentation gap. That gap is worth a line for depositors: "a redemption queued in a loss breach may be paid at the hour-old checkpoint; cancel and re-request after the next ratchet".

**Exit-only half: mis-scoped.**
- ECONOMICS.md says the exit-only settle "can be sent by the owner (also the manager on the live vault) once the epoch is overdue". On the live shape this is false. If owner == manager, the caller is `treasury`, so `exitOnly = emergency || (!treasury && !redemptionOnly)` is false and the overdue settle is a **normal** settle at the live NAV.
- `test_GR2_XR_ECON02_ownerIsManager_overdueSettleIsNormalNotExitOnly`: bob's quarter is paid live/4, not the dip. ECON's overdue PoC works only because the harness has owner ≠ manager.
- The insider's real route is wider in time but loud. `triggerEmergency` is "Owner or guardian at any time", and then the owner or manager settles exit-only at min(NAV, checkpoint).
- `test_GR2_XR_ECON02_ownerEmergencyGivesTheExitOnlyDipAnyTime`: the epoch is 2 h old, not overdue. Bob is paid 44,610 against 50,000 from a normal settle at the same moment (−10.8 %).
- The cost to the insider: emergency revokes the agent, refunds deposits, only the guardian ends it, and the event is public. It is a one-shot grab, not a quiet harvest.
- The overdue exit-only path also has a practical cap. A dip deeper than the daily-loss limit sets a loss breach, and that turns the platform's settle into the bounded redemption-only mode.

**Can an insider harvest it systematically?**
- That needs real crashes (≥ maxDailyLoss of NAV) that rebound within the hour, while others have redemptions queued.
- The insider gains only its pro-rata share of the gap as a stayer, and bears the crash itself.
- It cannot manufacture the dip cheaply. A delta-neutral book (ECON-01) lowers the adverse NAV by only B × L (≤ 1 % at live parameters), far from a 15 % daily-loss breach.
- ECON's model row "overdue_owner" (+306 bp over 60 epochs at most) uses the owner ≠ manager harness.

**Verdict.** A bounded (≤ m per settle) transfer to stayers under an accepted conservative rule, with a discretionary timing element that was already recorded. **Low (design)**, plus a documentation item.

## GR2-ECON-01: CONFIRMED Low (design)

- FIXES-R1 section 6 documents the cost of a flow while trades are open ("about 2 × B × the depositor's share of the open notional ... goes to the holders who stay").
- ROUND1 GR1-02 already says the manager "decides when they are open".
- So the per-flow transfer is a known, bounded consequence: ≤ B × maxLeverage ≤ maxNavMove / 8 by the policy constraint, which is 1 % at live parameters.
- No earlier document mentions a **delta-neutral** book, and that is the new lever. It needs no market risk, so a hostile manager can impose the band deliberately and route it to a confederate.
- With 3.6 bp Gains fees per side it pays only on flows larger than about 56 % of NAV (ECON's numbers; the PoC `..._hedgedBookPaysAfterGainsFeesOnALargeFlow` passes, with alice +299 net).
- Low is right. The cheapest fix is the netting rule ECON proposes (net longs against shorts per pair for `valueHigh`). Otherwise document "the manager can impose up to B × maxLeverage on any flow".

## GR2-CFG-01: CONFIRMED Medium (High rejected); reachability widened

**Re-run.** `test_GR2_CFG_01_*` and the control pass: alice is paid 3,984.89 of 10,000 after 29 days.

**Is there really no exit?** For the redeemer's own self-help: confirmed. The other routes:

| Route | Works before the eta? | Works after the apply? | Test |
|---|---|---|---|
| alice / stranger `triggerEmergency` | no (NotOverdue) until epochStart + E | same | CFG PoC |
| operator (keeper) normal settle | no: the owner's `setOperator(0)` is instant | no | CFG PoC |
| sentinel / guardian exit-only settle | no: needs overdue or emergency | no | CFG PoC |
| **guardian `triggerEmergency`** (no overdue condition for the guardian or owner) then the sentinel's exit-only settle | **yes: alice paid 10,000 less 1 h of management fee** | **yes**: even with the 12x trade open, guardian close + settle pays alice 10,000.45 | `test_GR2_XR_CFG01_guardianEmergencyAnyTimeFreesRedeemerBeforeEta`, `test_GR2_XR_CFG01_guardianRescueAfterApplyBeforeTheMove` |
| sentinel `triggerBreach` (online key) | removes the risk: the full stop survives the apply and the manager's 12x open reverts ReduceOnlyMode | but **not the lock**: a full stop also blocks every non-emergency settle (ReduceOnlyMode for sentinel and manager alike), so alice waits for the guardian or for t0 + 30 d | `test_GR2_XR_CFG01_sentinelFullStopRemovesTheRiskButNotTheLock` |

**Residual.**
- The trap and the loss need the platform's cold guardian not to react between the public `ConfigQueued` (t0) and the adverse move. The sentinel can prevent the loss, but not the lock.
- Today nothing alerts on `ConfigQueued` (CFG open question 2), and the guardian is one cold key. So "if nobody watches" is the realistic case, not a corner case.
- It is still not "temporary lock with **no exit**" (High): a platform exit exists at all times.
- Medium stands: a conditional loss to a redeemer who tried to leave, which depends on the platform not responding.
- The fix CFG proposes (T ≥ E in create, proposeConfig and the timelock setters) is still right. An executor alert on `ConfigQueued` with a pending redemption would turn the residual into an operational SLA.

**Reachability (new).**
- CFG says "No ALERT: the live vault has timelock 2 days and epoch 1 day, so CFG-01 does not apply to it". That is true only until the owner queues one config whose only change is `maxEpochDuration` 1 d → 30 d. That is a loosening, so it waits 2 days, and it looks harmless.
- After it applies, T (2 d) < E (30 d), and every later loosening is CFG-01's trap.
- `test_GR2_XR_CFG01_liveShapeReachesTimelockBelowEpochInOneQueue`: after the second queue, alice has no self-help from the eta to t1 + 30 d − 1 s, and the 12x open goes through.
- The first queue does open its own 24 h self-help window (CFG-02's arithmetic), so this widens likelihood, not impact.
- No ALERT is needed: the live vault's holders are the owner and the protocol.

## GR2-CFG-02: CONFIRMED Low

- Reproduced (`test_GR2_CFG_02_*` pass).
- The guardian rescue above applies as well.
- Raising E is itself a timelocked loosening, which is the reachability step above. Storing the deadline per epoch, as CFG proposes, also closes that step.

## ECON "checked and sound": the two claims I attacked

1. **"First depositor after a full exit ... nobody can capture the residual quickly."**
   - I tried to capture it: 7 dust share units plus a 522 USDC residual (ECON's seed-7 / 1M state), then a 10,000,000 USDC deposit and full redemption while flat.
   - carol ends 1 wei short (`test_GR2_XR_ECON_residualAfterFullExitNotCapturableByLargeDepositor`). The claim holds.
   - Correction: the residual is **never** "released pro rata to later holders as the supply grows". At fair prices a depositor's round trip returns exactly its deposit, and the residual's value stays with the 1e6 virtual shares, so it follows the share price. That is why ECON saw 522 shrink to 313 over a run of trading: it was exposed to the strategy, not released. Info.
2. **"Chainlink lag ... no in total (single settles can win when lag > band)."**
   - ECON's strategies do round trips. A holder who only times a one-way exit gains (lag − B) × L of the flow whenever Chainlink lags by more than the band (the mirror case for deposits). It needs no round trip.
   - So "negative in total" does not mean "no extraction".
   - This is ROUND1 open question T3 / GR1-15 (the band assumed ≥ the oracle gap), so it is not a new finding. I would list it as **open (T3)**, not "checked and sound".
   - Not tested here: there is no fork data for fast-market gaps.

## Open questions

- ECON-03 on HL vaults (`src/VaultLogic.sol:226`, same rule): not tested; out of scope.
- CFG-01: how fast the guardian really reacts (cold key, no `ConfigQueued` alert) decides the residual. This is an executor and operations question.

## Caps, skipped

- No heavy tools.
- The ECON differential (ffi) was not re-run. I relied on the deterministic PoCs.
- Both scratch trees are under `scratchpad/XR-ECON/` (`asis`, `fix`). The fix was applied only there, never to `contracts/src`.
