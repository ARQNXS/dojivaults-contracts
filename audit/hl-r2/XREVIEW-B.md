# hl-r2 cross-review B (challenger): timelock / config, economics, fund flow

**Internal, AI-assisted review. It is not an independent audit and must not be presented as one.**

Branch `audit/hl-r2-xb` (from `audit/hl-r2` at 2b826cd), 2026-10-20. Targets: HOSTILE-AND-CONFIG.md (H01-H09),
HLO-DEFERRED.md (HLO-02/03/06/07/08), ECONOMICS.md + LIVENESS.md (E01-E09, L01, L02), FUND-FLOW.md /
COREWRITER-ENCODING.md / STATIC.md (F01-F08), ALERT.md. Nothing deployed, no transaction sent, nothing pushed;
`contracts/src` and `server/src` unchanged. Chain reads are read-only `cast call` and one HL `info` request.

Counter-PoCs: `contracts/test/audit/hl-r2/xreview/XReviewB.t.sol` (5 tests, all pass, see section 6):

```
cd contracts && forge test --match-path "test/audit/hl-r2/xreview/*" -vv
```

## Assumptions (conservative readings)

- XA1. Under `openLaunch = true` the vault owner is untrusted. This matches REPORT.md (REPORT.md:16, :86 "On factory
  vaults the owner is the creator (an untrusted manager)", D-3 :205). The lower ratings in REAUDIT2 N2-02 ("the owner
  is a trusted role", REAUDIT2.md:230) and VERIFY W-01 ("needs a malicious owner, which during the allowlisted phase
  is a vetted launcher", VERIFY.md:164) relied on the allowlist. That premise is gone on the round 4 factory.
- XA2. The factory guardian is a person holding one cold EOA (0x1A7a…D7ff). It acts only when something alerts it.
  I credit a guardian defence only if the executor raises an alert that would start it.
- XA3. Each original PoC was re-run on this branch (section 6). Where I disagree with a number, I cite the code line.

## 1. Verdict table

| ID | Original | Verdict | Final | Reason |
|---|---|---|---|---|
| **HLR2-H01** | High | **STANDS (with corrections)** | **High** | Mechanism confirmed: `epochOverdue` reads `maxEpochDuration` live (VaultMath.sol:202-204); `cancelPendingConfig` is owner-only (VaultPolicy.sol:276); `applyPendingConfig` is anyone's (:268). The write-up misses one defence: the guardian's instant `triggerEmergency` inside the timelock freezes new risk and pays the redeemer (`test_XB_H01a_…`). Nothing alerts the guardian today, though (XB02). With an alert and a runbook it drops to Medium. |
| HLR2-H02 | Info | MERGE with N-13 (KNOWN-ISSUES.md:15) | Info | Accepted, restated; keep the incident-response note |
| HLR2-H03 | Low | STANDS | Low | N-04 / I2-01 restated (KNOWN-ISSUES.md:16); the new point is the one-person guardian |
| HLR2-H04 | Medium | STANDS | Medium | X-01 was accepted as Low on a "priority-fee settler" premise (VERIFY.md:223, :236), and the executor does not meet it. Bounded by Core USDC / MIN_BRIDGE windows; the unbounded reading (failed sends) is unverified |
| HLR2-H05 | Medium (premise unverified) | **DOWNGRADE** | Open question (Medium if confirmed) | Both halves rest on undocumented HL behaviour (S3). The CONTEXT evidence standard says "Unprovable = open question". Keep the cheap `syncAgent` hardening |
| HLR2-H06 | Medium | STANDS, **numbers corrected** | Medium | S4 is wrong in the attacker's favour. The keeper settles on **any** pending request, not per epoch (epochPlan.ts:167-170), and "outside depositor" status is permanent ("any epoch, not cancelled", tenants/outside.ts). So one sybil vault that alternates 10 USDC requests drives a keeper settle every operator loop, with about 12 USDC of capital. The attacker's gas per round is about a quarter of the keeper's. Impact unchanged |
| HLR2-H07 | Low | MERGE into HLO-08 (and KEYS K06) | Low (process) | Same key, same powers; H07 is HLO-08's consequence list |
| HLR2-H08 | Info | STANDS | Info | |
| HLR2-H09 | Info | STANDS | Info | |
| HLO-02 | Low | STANDS | Low | |
| HLO-03 | Low | STANDS | Low | Multiplier; its "worse with H01" sentence belongs to H01 |
| HLO-06 | Low (Design) | STANDS | Low (Design) | Its "stall while a loosening matures" point merges into H01 |
| HLO-07 | Medium | STANDS | Medium | = I3-04 (KNOWN-ISSUES.md:20) = KEYS K06 leg; the co-signature analysis is right |
| HLO-08 | Low (process) | STANDS, absorbs H07 | Low (process) | Live read 2026-10-20: owner still the EOA, no pending owner |
| **HLR2-E01** | Medium | STANDS | Medium | Confirmed. In an honest emergency anyone's hourly `checkRisk` closes the gap (`test_XB_E01c_…`), so the honest-case loss comes from the keeper sending no `checkRisk` in a full stop. The hostile case stands. E01's proposed fix ("remove the owner's instant triggerEmergency") is incomplete: see XB01 |
| HLR2-E02 | Low | MERGE as an amplifier of KEYS K03 (not the same root cause) | Low | K03's root is C-01 (deflation within `maxNavMoveBps` priced by a non-insider settle). E02's root is the stale breach flag. E02 is why K03's bound is `maxNavMoveBps` and not `maxDailyLossBps` on vaults where daily loss < NAV band. The attacker can make the keeper skip its own `checkRisk` with a permissionless `checkRisk` just before the deflation (keeper refreshes only when the checkpoint is > 1 day old, epochPlan.ts:218). Moot on the platform vault (20%/20%) |
| HLR2-E03 | Low | STANDS | Low | M-05 residual; a 19% one-block mark spike on a curated perp is unlikely, but a genuine transient move works too |
| HLR2-E04 | Info | MERGE with N-09 (KNOWN-ISSUES.md:14) | Info | Accepted, quantified |
| HLR2-E05 | Info | STANDS | Info | |
| HLR2-E06 | Medium | STANDS; **E06b MERGE into H01** (leg C) | Medium | Consistent with VERIFY W-01 (owner freeze of exits, Medium, VERIFY.md:152). The sentinel half is KEYS K04. E06b (a loosened epoch moves the running deadline) has the same root cause as H01's third leg |
| HLR2-E07 | Low | MERGE with async HLR2-A02 (branch `audit/hl-r2-async`, AsyncPoC.t.sol:58-137) | Low | Same mechanism: the R3-08 write-off after 300 blocks (accepted, KNOWN-ISSUES.md:24). E07 = redemption-only in a breach; A02 = normal settle + performance fee |
| HLR2-E08 | Info | STANDS | Info | |
| HLR2-E09 | Info | STANDS | Info | |
| HLR2-L01 | Low (Design) | STANDS | Low (Design) | It is also what makes every H01 / E06 recovery manual |
| HLR2-L02 | Low | STANDS | Low | |
| HLR2-F01 | Low | STANDS | Low | Arithmetic confirmed (section 4) |
| HLR2-F02 | Low | STANDS | Low | Only the manager or the sentinel can cancel the spot order (VaultLogic.sol:552), not the guardian |
| HLR2-F03 | Info | STANDS | Info | |
| HLR2-F04 | Info | STANDS | Info | Variant of REPORT L-02 (previews differ from settle) |
| HLR2-F05 | Info | STANDS | Info | |
| HLR2-F06 | Design | STANDS | Design | Accepted issuer risk class |
| HLR2-F07 | Info | STANDS | Info | |
| HLR2-F08 | Info | MERGE note with I3-02 (KNOWN-ISSUES.md:17) | Info | Same "deposit for another controller" semantics |
| **ALERT** | — | **STANDS as a precaution; both commands verified** | — | Section 3 |

New: **HLR2-XB01** (Medium, E01 variant: merge into E01), **HLR2-XB02** (Low, detection gap that leaves H01's
guardian backstop latent), **HLR2-XB03** (Info, H01 fix sketch B is insufficient), **HLR2-XB04** (Info, vault and
policy ownership diverge on transfer).

## 2. HLR2-H01, attacked

**Paths I tried for a redeemer to get out before the loosening applies:**

| Path | Result | Evidence |
|---|---|---|
| Keeper settles once the money is idle | Closed: the owner calls `setOperator(0)` at once (HyperVault.sol:304). Even with the keeper kept, a normal settle needs the full payout idle (VaultLogic.sol:263-264). The H01b caveat: at 4x with `withdrawable` set to 0 the model is slightly off (HL keeps margin at the position's leverage; 4x at 5x leverage leaves ~20k free). At exactly 5x it is 0, and a manager can always be at the policy maximum. In a many-depositor vault a small redeemer could be paid out of `withdrawable` by the keeper, unless the operator was removed | code |
| Redeemer settles or forces it herself | Closed: `settle` is roles only (VaultLogic.sol:207-209); `triggerEmergency` needs overdue (VaultGovernance.sol:245) | H01 PoC |
| Guardian `cancelPendingConfig` | Closed: owner only (VaultPolicy.sol:276) | code |
| `applyPendingConfig` needs a call | Not a defence: anyone may call it in [eta, eta + 14 d] (VaultPolicy.sol:268, 334-337) | code |
| A loosened `maxEpochDuration` moves a running epoch's deadline | **Confirmed**: read live (VaultMath.sol:202-204); a tightening also moves it, at once (XB01) | H01 PoC, XB01 |
| **Guardian `triggerEmergency` inside the timelock** | **Open, and the write-up omits it.** The guardian may trigger at any time (`privileged`, VaultGovernance.sol:245). Emergency makes `placeOrder` reduce only (VaultLogic.sol:538), revokes the agent, refuses `bridgeToCore` (:425), and only the guardian ends it (VaultGovernance.sol:272). The loosening still applies, but to a vault that can only reduce; the guardian flattens, bridges and settles | `test_XB_H01a_guardianEmergencyInsideTheTimelockGetsTheRedeemerOutAtTheOldRisk`: alice is paid her full value at t0 + 2 d, and the 45x order reverts `ReduceOnlyMode` |
| Sentinel (hot, automated) | Partial: `triggerBreach` (a full stop) also freezes new risk, and each re-trigger invalidates an owner-queued clear. It freezes exits as well (E06), so it is a holding move until the guardian acts | code |

**Is the guardian defence real today?** No. Nothing tells the guardian: `ConfigQueued`, `TimelockQueued` and
`OperatorSet` are only history rows (`server/src/history/replay.ts:344, 362, 401`); no monitor or alert path reads them
(`grep -rn ConfigQueued server/src`). Under XA2 the defence is latent, so H01 stands. This is also why I do not give
H01 the same Low as H03: H03 has the same guardian dependency, but the damage is only the manager trading again inside
the existing policy.

**Severity.** High per the scale (conditional loss up to ~100% plus a lock of up to 29 days) and per precedent: REPORT
H-01 ("owner instantly disarms risk controls", REPORT.md:78-97, untrusted factory owner) was High for the same
guarantee ("depositors get time to exit before risk increases"). Likelihood is low and should be written down:
- open launch;
- outside depositors who reached a stranger vault by direct link (Explore is curated);
- an owner who gains only option value (performance fee on a gamble). Curated BTC/ETH/SOL books make a direct value
  transfer to the owner impractical;
- no guardian reaction within the timelock.

Today: zero outside money (live read below).

**Corrections to the write-up:**
1. "The only forced exit is triggerEmergency once overdue" is wrong: the guardian has an instant one. The accurate
   statement is that **the redeemer** has no forced exit, and **the platform's** forced exit depends on a person
   noticing.
2. "Her first forced exit comes 29 days after the request" assumes guardian inaction for 29 days.
3. The fix list should lead with the cheapest compensating control: an executor alert on any `ConfigQueued` that
   loosens a field, any `TimelockQueued` lowering, and `OperatorSet(0)`, on vaults with outside deposits, routed to
   the guardian. Add a runbook step: `triggerEmergency` before the eta when redeemers are waiting (XB02).
4. Fix sketch B is weaker than claimed (XB03, `test_XB_H01b_…`). Fix A (delay ≥ `maxEpochDuration` + margin) plus C
   (snapshot the deadline at settle) is the sound pair. "Make the overdue exit-only settle callable by anyone" undoes
   I2-02 (KNOWN-ISSUES.md:28, superseded rule); if proposed, it must refund deposits safely.

## 3. ALERT verdict and its commands

**Live reads (2026-10-20, block time 1792448844):**
- Round 4 factory `owner()` = `0x1A7acB7966e6E3632694484dE261B70230eCD7ff` (no code: EOA), `pendingOwner()` = 0,
  `openLaunch()` = true.
- The platform vault `policy()` = [an earlier policy].
- Policy `owner()` = [platform wallet] (= vault owner), `timelockDelay()` = 172800,
  `pendingTimelockEta()` = 0, no pending config, `maxEpochDuration()` = 604800, `factory()` = the round 4 factory.
- Vault `timelockDelay()` = 172800, operator = keeper `0x3FeaC534…bf89`.

| Command | Verdict |
|---|---|
| `cast send [an earlier factory] "setOpenLaunch(bool)" false` from the factory owner | **Correct.** `setOpenLaunch` is `onlyOwner` (HyperVaultFactory.sol:368) and the owner is that EOA. It affects future launches only. The platform vault is unaffected. It closes H01 only for vaults not yet launched |
| `policy.proposeTimelockDelay(777600)` on [an earlier policy] from [platform wallet] | **Correct and instant**: 777,600 ≥ 172,800 (raise path, VaultPolicy.sol:312-315), ≤ MAX_TIMELOCK 2,592,000 (:22), no pending lowering to interfere. **It closes the loss leg of H01 for the platform vault** (`test_XB_ALERT_…`): a redeemer who reacts to a queue triggers the emergency herself at the old deadline (epoch start + 7 d < queue + 9 d, whatever the queue time in the epoch, because a settle in between must pay her). That freezes new risk before the eta. A later lowering of the delay itself waits the 9 days and is public. **What it does not close:** (a) the payout still needs a platform role to unwind and settle (manual, L01); (b) the vault's own 2-day timelock still gates `setManager` / `setAgent` (a policy-unbounded trader, D-1, though only a factory-bound agent) and a **management** fee raise, which applies at execute, not "from the next epoch" as the ALERT says (VaultLogic `_setFees`; HOSTILE table). Add: queue the vault's `setTimelockDelay(777600)` (it waits 2 days) |

**ALERT text corrections:**
- "fee raises (which apply from the next epoch)": only the performance fee waits; the management raise is
  immediate at execute (bounded at 5%/yr).
- The vault timelock also gates `setTimelockDelay` and `clearBreach`.
- Add the guardian alert / runbook as mitigation 0: it is the only one that protects vaults launched before
  `setOpenLaunch(false)` (none exist today).
- An alternative for the platform vault: tighten `maxEpochDuration` to below the 2-day timelock (instant). It is fragile: a missed
  keeper day makes the epoch overdue and lets anyone trigger an emergency. The 9-day delay is better.

**Verdict:** the ALERT is justified under rule 0 (a High reachable on a live factory configuration), with no money at
risk today. Its commands are correct as written. The mitigation is sufficient for the platform vault's policy leg, and launch
closure covers new strangers.

## 4. Other targeted checks

- **F01 (90-day expiry), from a fresh live read.** HL `extraAgents([an earlier vault])` =
  `[{"name":"dojipad","address":"[an earlier agent]","validUntil":1799292344459}]`. Block 48047401 timestamp = 1791516344.
  1,799,292,344.459 − 1,791,516,344 = 7,776,000.459 s = 90.000005 days. Expiry is **2027-01-07 03:25:44 UTC**
  (CONTEXT.md says 2027-01-06: off by a day). The executor reads `validUntil` (`venues/hl/info.ts:246`, `monitor.ts:83`)
  and never compares it. Low stands.
- **E01: who can refresh the checkpoint in emergency.** `checkRisk` is permissionless and has no emergency guard
  (HyperVault.sol:274, VaultGovernance.sol:168-210). It moves the checkpoint by ≤ `maxNavMoveBps` once per hour. In
  E01a the hostile owner settles in the same block (or within the ~11-block bridge window), so a redeemer gets at most
  one +20% step (E01c). In an honest emergency, two calls an hour apart remove a +30% gap (`test_XB_E01c_…`). The
  executor does not do it (risk/contractRisk.ts:253-254). The cheapest fix: keep the keeper's hourly `checkRisk` in a
  full stop.
- **E06 vs H01.** E06 (full stop freezes exits) is distinct. E06b is H01's third leg (C) and should be merged there.
- **E02 vs K03:** see table.
- **E07 vs async:** no ASYNC.md exists on `audit/hl-r2-async` yet. Its A02 PoCs cover the same mechanism; merge E07
  there.

## 5. New items

### HLR2-XB01 (Medium, E01 variant: merge into E01): instant epoch tightening opens exit-only pricing without an emergency

A `maxEpochDuration` **tightening** is instant (`_isTighter`, VaultPolicy.sol:365-371), and `epochOverdue` reads it live
(VaultMath.sol:202-204). An owner who is not the manager:
1. proposes `maxEpochDuration = 1 hours`;
2. the running epoch is overdue in the same block;
3. the owner (a platform role, not treasury) settles exit-only at min(NAV, stale checkpoint) (VaultLogic.sol:212-214,
   242-244).

This is E01b without the 7-day wait and E01a without an emergency: no agent revoke, no full stop, only a
`ConfigApplied` event. PoC `test_HLR2_XB01_instantEpochTighteningOpensTheExitOnlyPriceWithoutAnEmergency`: +30% real
gain over 20 h, alice is paid 100,000 for a fair 130,000, and the owner's sybil holds 160,000 for 100,000.

Scope: owner ≠ manager. With owner = manager (the wizard default) the settle is a treasury settle, so the NAV bound
applies; that owner uses E01a. Consequence for E01's fix: removing the owner's instant `triggerEmergency` is not enough.
Price exit-only at the walked checkpoint (E01's first fix), and apply an epoch tightening only from the next epoch
(snapshot the deadline at settle, H01 fix C), which closes both.

### HLR2-XB02 (Low, detection gap): nothing alerts the guardian to a loosening, a delay lowering or an operator removal

The one live defence against H01 (and the fastest against E06 / HLO-06 stalls) is the guardian's `triggerEmergency`.
The executor turns `ConfigQueued`, `TimelockQueued` and `OperatorSet` into history rows only
(`server/src/history/replay.ts:344-364, 401`); `monitor.ts` has no such finding kind.

Fix: a monitor finding `POLICY_LOOSENING_QUEUED` (any field looser than current, any `TimelockQueued`, any
`AssetAllowQueued`) and `OPERATOR_REMOVED`, on vaults with outside deposits. Error level, with the eta and the pending
redemptions. Runbook: guardian `triggerEmergency` before the eta when redemptions are pending; otherwise publish the
eta to depositors. Evidence: grep (no PoC possible for an absent alert).

### HLR2-XB03 (Info, fix review): H01 fix sketch B protects only redeemers queued before the next settle

The owner settles an empty epoch an hour after queuing; B's condition (`epochStartedAt > queuedAt`) is then met, and a
depositor who reacts later inside the timelock is in the H01 position at the eta (`test_XB_H01b_…`). Use A (+C).

### HLR2-XB04 (Info): vault and policy ownership diverge after a transfer

The factory sets the policy owner = `p.owner` (HyperVaultFactory.sol:260). Vault and policy are separate
`Ownable2Step` contracts. A vault `transferOwnership` (instant, two step) leaves the policy, including every
loosening and the instant `maxEpochDuration` tightening, with the old owner unless it is transferred too. Depositors
and the indexer that look at `vault.owner()` see the wrong party. Fix: make the policy's owner `vault.owner()`
(read through), or have the UI show both owners. No PoC: two standard OZ transfers.

## 6. PoC runs (this branch)

Re-run on `audit/hl-r2-xb` after a full build (`forge build --skip "src/gains/**" ...`, 2026-10-20):

| Path | Result |
|---|---|
| `test/audit/hl-r2/hostile/*` | 16 passed (HostileConfig 10, HloDeferred 6) |
| `test/audit/hl-r2/flow/*` | 27 passed, 1 skipped (the opt-in fork test, `HLR2_FORK=true`) |
| `test/audit/hl-r2/econ/*` (`--no-match-test test_differential`, the 650-scenario campaign is not re-run) | 23 passed |
| `test/audit/hl-r2/xreview/*` (this review) | 5 passed |

Counter-PoC numbers:
- `test_XB_H01a_…`: alice's value at the request is 100,001.999999 and the guardian's emergency settle pays her
  99,990.812498 at t0 + 2 d; the 45x order after the loosening reverts `ReduceOnlyMode`.
- `test_XB_ALERT_…`: with the 9-day delay, alice triggers the emergency at epoch start + 7 d (before the eta), is
  paid in full, and a lowering of the delay is queued 9 days out.
- `test_XB_H01b_…`: settle after the queue, alice requests at t0 + 1 d, the loosening applies at t0 + 2 d with her
  redemption pending.
- `test_XB_E01c_…`: two stranger `checkRisk` calls in an honest emergency, and alice is paid 130,000 (fair).
- `test_HLR2_XB01_…`: alice is paid 100,000 for a fair 129,999.999999; the sybil holds 159,999.999999; no emergency, no
  breach.
