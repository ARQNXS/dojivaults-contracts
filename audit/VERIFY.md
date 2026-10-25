# DojiPad Vaults: verification pass, round 3 fixes

| | |
|---|---|
| Diff | `1bd2153..875c1c4` (round 3: O(1) pro-rata claims, deferred performance fee raise, 3% flatten cap, one agent per predicted vault, launch nonce, factory role checks, deploy script ownership hand-off) |
| Rules | Same as before: no src edits, PoC for Medium+, no broadcasts, no keys. Local and uncommitted |
| Sizes | HyperVault 15,126 B (9,450 B headroom), Factory 9,710 B, VaultPolicy 9,927 B, Lens 6,556 B |
| Contract tests | `forge test`: **156/156 pass**, all invariant suites included (table 2) |
| Server tests | `npx vitest run`: **153/153 pass** (14 files) |
| New PoC | `test/audit/verify/VerifyPoC.t.sol`: **1/1 pass = issue present** (V-01) |

## 1. REAUDIT2 items: pass/fail

"Inverted PoC" = the REAUDIT2 PoC now asserts the fixed behaviour and passes. "Bypass" = my attempts against the new code.

| Item | Fix | Inverted PoC | Bypass attempts | Result |
|---|---|---|---|---|
| N2-01 (Medium) claim gas O(epochs) | Survival / cumPaid accumulators (`VaultLogic.settle:194-214`, `VaultMath.claimable:170-178`, lens mirror) | `test_REAUDIT2_N201_claimGasIsConstantAcross1000EmergencyEpochs` PASS; `OK_proRataPayoutsNeverExceedLiquidity`, `OK_dustLeftoversCloseTheEra` PASS | Rounding direction: every term floors, so Σ payouts ≤ `paid` and Σ leftovers ≤ remaining (checked by hand and by the emergency invariant). **Bypassed by the era-closing floor: V-01** | **FAIL (regression, Critical)** |
| N2-02 (Low) perf fee raise retroactive in the epoch | Raise is scheduled in `_setFees`; applied in `settle` after the old-rate accrual (`VaultLogic:160-167`); lowering is immediate and clears the pending raise | `test_REAUDIT2_N202_perfFeeRaiseStartsNextEpoch`, `..._loweringIsImmediateAndCancelsAPendingRaise` PASS | `lowerFees(current, current)` with a pending raise: accepted, management accrual only, perf rate unchanged, pending cleared (no crystallisation, N-05 still fixed). Re-queue a smaller raise: overwrites pending. Raise then emergency/exit-only settle: old rate charged first. Management raise: crystallised first, `setFees` reverts in flight. No bypass | **PASS** |
| N2-03 (Low) flatten lever | `MAX_FLATTEN_SLIPPAGE_BPS = 300` in `_validate`; guardian custom slippage only in emergency (`VaultLogic.flatten`) | `test_REAUDIT2_N203_flattenSlippageIsCappedAt3Percent` PASS | Guardian custom flatten outside emergency: `Unauthorized`. Config above 300 via the timelock: `InvalidConfig`. Stranger custom: `Unauthorized`. The manager keeps ≤3% (documented) | **PASS** |
| N2-04 (Low) no nonce; several agents per vault | Server single-use nonce bound to the owner and consumed only by a valid signature; one pending reservation per (owner, salt); factory `agentOfVault` one per predicted vault | `test_REAUDIT2_N204_oneAgentPerPredictedVault` PASS; server `REAUDIT2_N204_*` PASS | Replay: nonce deleted on first valid use. Nonce of another owner: rejected. Residual V-02 (nonce eviction, Low) and V-04 (registrar pre-binding DoS, Low) | **PASS** (residual Low) |
| I2-01 sentinel re-breach loop | Accepted: factory owner rotates the sentinel | `test_REAUDIT2_INFO_sentinelRebreachBlocksOwnerClears` (documents) | - | **Accepted** |
| I2-02 overdue stranger settle refunds deposits | Accepted, documented | `test_REAUDIT2_INFO_overdueStrangerSettleRefundsDeposits` | - | **Accepted** |
| I2-03 registrar revokes live agents | `unregisterPlatformAgent`: a live agent can only be revoked by owner / guardian / sentinel | `test_REAUDIT2_I203_registrarCannotRevokeALiveAgent` PASS | Registrar unregisters a not-yet-live binding of a predicted vault: allowed (launch DoS only, V-04) | **PASS** |
| I2-04 first settle needs a keeper | `HyperVault.settle` runs `checkRisk` when `checkpointAt == 0` | `test_REAUDIT2_I204_firstSettleCheckpointsItself` PASS | A breach found by that inner check reverts the whole settle (no state persisted, retried after recovery) | **PASS** |
| I2-05 roles may collide | `_checkRoles` in constructor, `setGuardian`, `setSentinel`, `setAgentRegistrar`, `transferOwnership`; `create` rejects guardian == sentinel | `test_REAUDIT2_I205_factoryRolesMustNotCollide` PASS | The check compares against the **current** owner, not `pendingOwner`: `setSentinel(pendingOwner)` before acceptance lets owner == sentinel after acceptance (V-03, Info). `renounceOwnership` not disabled on the factory (V-03) | **PASS** (Info residual) |
| I2-06 EOA factory owner | `DeployFactory._setup` ends with `transferOwnership(PLATFORM_GUARDIAN)` (two step) and prints the `acceptOwnership()` call (`0x79ba5097`, correct selector) | script review | Setup runs as the deployer before the hand-off, so config cannot be left half-applied. The deployer stays owner until the guardian accepts: **acceptance is a deploy step, before any launcher is allowlisted**. Role collisions abort the script (registrar == deployer reverts). Launch stays closed by default; `maxDepositCap` 50k default | **PASS** (operational step) |

Earlier findings (round 1 C/H/M/L, round 2 N-01..N-08): all regression PoCs and the dedicated invariants still pass on `875c1c4` (`invariant_N01/N05/N07/N08` 512 x 500, `invariant_core`, `invariant_suite`). No regression found in those paths.

## 2. Invariant suites on 875c1c4

| Suite | Runs x depth | Calls | Result |
|---|---|---|---|
| `audit/invariants` `invariant_suite` | 512 x 200 | 102,400 | PASS |
| `audit/reaudit` `invariant_core` | 512 x 200 | 102,400 | PASS |
| `audit/reaudit` `invariant_N01/N05/N07/N08` | 512 x 500 | 256,000 each | PASS |
| `audit/reaudit2` `invariant_reaudit2` (fresh) | 512 x 200 | 102,400 | PASS |
| `audit/reaudit2` `invariant_reaudit2` (emergency-seeded) | 512 x 500 | 256,000 | PASS |

**Why the suites miss V-01:** the emergency handler's mini epochs bring home 100 USDC against ~150k pending, so each epoch multiplies the survival factor by ~0.999 and it never approaches 1e12. V-01 needs a few *near-complete* pro-rata epochs (exact bridge amounts), which random fuzzing does not produce. Add a handler action that bridges `redAssets - k` (k small) before a stranger settle. It will then find V-01 within a few calls.

## 3. New findings in the round 3 code

### V-01 (Critical): the survival floor burns honest redemptions

**Location.** `VaultLogic.settle:199-209` (`if (survival < SURVIVAL_FLOOR) { burned = redShares; ... new era }`), together with `VaultMath.claimable:172-178`.

**Description.**
- `SURVIVAL_FLOOR` is compared with the **era-wide** cumulative survival factor. Every request that joins during an era inherits that era's current `survivalBefore` as its base.
- When the factor after an epoch falls below 1e12, the settle burns **every** pending share. It reserves only the epoch's `paid`, and the era closes, so all leftovers are 0.
- That is harmless only for requests that really are down to 1e-24 of their size. A request that joined in the last epoch has lost nothing yet but still gets burned.
- The factor is driven by how completely each epoch pays. In emergency, anyone can bridge an exact amount home and anyone can settle, so an unprivileged actor can steer it.

**Exploit (PoC `test_VERIFY_V01_survivalFloorWipesFreshRedemptions`).**
1. Emergency, reachable by anyone once an epoch is overdue with a pending redemption.
2. The attacker's sybil redeems its own shares in three epochs. Each time it bridges home exactly `redAssets - keep`, so the epoch pays its redemption almost in full at fair value. This sets the survival factor to 1e25, then 1e14, then 1.00005e12.
3. Honest alice requests her whole 1M.
4. A 100 USDC bridge (`MIN_BRIDGE`) and a settle push the factor below 1e12. The era closes, alice's entire request is burned, and she can claim **98.99 USDC for shares worth 999,616 USDC**.
5. The burned value accrues to the remaining holders: the sybil's ~1.05M of remaining shares is now worth **2,049,616**.

The attacker's cost is gas: its own redemptions are paid at fair value. Without an attacker, a long emergency with near-full payouts can drift the factor down organically and hit any late redeemer the same way.

**Severity.** Critical: direct theft from depositors by an unprivileged actor, in the one mode (emergency) that exists to protect exits.

**Fix (describe).**
- Never force-burn on the floor. When the factor would drop below the floor, *rescale* instead of closing the era: multiply `redeemSurvival` and `redeemCumPaid` by a constant (e.g. 1e24) and record the rescale count in `era`.
- `claimable` then scales a request's `base` and `cumPaidBefore` by 1e24 per rescale since the request. A request more than one rescale old really is below 1e-24 of its size and can be treated as fully burned *for that request only*.
- `burned` must stay `redShares.mulDiv(paid, redAssets)`, so only paid shares are ever burned.
- Alternative: close the era only when `remaining == 0`, and keep the floor as a per-request check in `claimable`: leftover = 0 only if `survival_now / base < 1e-24`.

**Tests.** Invert `test_VERIFY_V01_*` (alice keeps her unpaid shares pending and can cancel to get them back). Add the near-full bridge action to `Reaudit2Handler` with ghost "a pending share was burned without being paid" and re-run 512 x 500 emergency-seeded. `OK_dustLeftoversCloseTheEra` must still pass, or be adjusted to the rescale semantics.

### V-02 (Low, server): nonce store eviction and single-process state
`LaunchService.issueNonce` keeps up to 10,000 nonces in process memory and evicts the oldest. The endpoint is unauthenticated, limited to 60 requests per 10 min per IP. An attacker spread over ~170 IPs, or one IP if the trusted proxy hop count is misconfigured (earlier S-08 caveat), can evict legitimate nonces. Launches then fail until retried. Nonces also don't survive restarts and don't work across more than one server instance. **Fix:** cap the number of unexpired nonces per owner and refuse new ones (not evict) when full, or derive the nonce statelessly (an HMAC of owner and time window with a used-set in the database). Keep the trusted proxy hop count exact.

### V-03 (Info): factory role checks
`_checkRoles` checks against `owner()`, not `pendingOwner()`, and `renounceOwnership` is inherited unchanged. That means `setSentinel(pendingOwner)` before acceptance allows owner == sentinel, and a renounce freezes role rotation for every vault. **Fix:** include `pendingOwner()` in `_checkRoles`, and override `renounceOwnership` to revert.

### V-04 (Low): registrar pre-binding
A compromised registrar online key can bind an agent to any predicted vault address. That blocks a creator's launch with that salt (`VaultAlreadyHasAgent`; the creator retries with a new salt). Together with an attacker who is an allowlisted launcher, it also hands that attacker a self-held agent at `create`, which reopens the C-01 lever for their own vault, bounded by the checkpoint and the risk limits. Mitigated by the launcher allowlist during the capped phase. **Fix (post-launch):** have the creator co-sign the binding (the factory verifies a creator signature over `(agent, salt)`), or let the creator register through `create` with a registrar signature.

### Reviewed and found sound
- **Accumulators:** ordering (read before burn); per-epoch base recorded in `EpochResult`; leftover re-queue at `currentEpoch` keeps the cohort base consistent; `pendingRedeemShares` is never double counted; Σ claims ≤ reserve (and `_claimIfSettled` caps at `claimableRedeemAssets`); era transitions on full payment (`remaining == 0`); lens mirrors the vault exactly.
- **Deferred perf rate:** see N2-02.
- **Role checks:** the guardian/sentinel/registrar separation holds on every setter.
- **flatten:** authorisation matrix.
- **Self-checkpoint on the first settle.**
- **Deploy script:** two-step ownership hand-off, role-collision abort, closed launch, cap default, `fs_permissions` limited to `./deployments`.

## 4. Go / no-go for the capped mainnet deploy

**NO-GO on 875c1c4.** V-01 is a Critical theft path in emergency mode, reachable by an unprivileged actor once any epoch is overdue with a pending redemption. The 50k cap bounds the loss per vault but does not change the class. Everything else in round 3 verifies.

**GO once all of these hold:**
1. V-01 fixed as described (rescale, never force-burn unpaid shares), the inverted `test_VERIFY_V01_*` passes, and the emergency-seeded suite with the near-full-bridge action passes 512 x 500.
2. Deploy steps: the guardian accepts factory ownership before any `setLauncherAllowed`; launch stays allowlisted; `maxDepositCap` ≤ 50k.
3. V-02, V-03 and V-04 may follow after launch (Low/Info), but V-03's `renounceOwnership` override costs a few bytes and is worth taking now.

The V-01 fix touches only `VaultLogic.settle` (the floor branch), `VaultMath.claimable` and the lens mirror, with ample bytecode headroom. A focused re-verification of those three functions plus the emergency suite is enough.

---

# Verification pass 2: V-01 / V-03 fixes (`e5334a9..7933fbf`)

| | |
|---|---|
| Diff | Emergency settle = **partial fill + return** (survival/cumPaid accumulators removed: a request belongs to one epoch, only the shares paid for are burned, the rest come back on claim); `emergencyFillBps` + lens `partialFill` / `previewEmergencyRedeem`; factory `renounceOwnership` reverts and the setters check the pending owner (V-03); webapp partial-fill banner and "re-request remainder" |
| Rules | Same as before; no src edits; files local and uncommitted |
| Contracts | `forge test`: **168 passed, 0 failed, 2 skipped** (the 2 skips are the reachability tests deliberately skipped in the emergency-seeded subclass; they pass in the fresh suite) |
| Server | `npx vitest run`: **153/153** |
| Webapp | `npm run build`: **builds** (vite, 44 s) |
| New files | `test/audit/verify/Verify2PoC.t.sol` (W-01 PoC + 3 bypass attempts), `test/audit/verify/VerifyMixedInvariants.t.sol` (mixed-request fairness, fresh 512x200 and emergency-seeded 512x500, plus 2 reachability tests) |

## 1. Pass/fail

| Item | What was checked | Result |
|---|---|---|
| **V-01** inverted PoC | `test_VERIFY_V01_lateRedeemersArePaidOrReturned`: the old attack shape (three near-complete steered epochs, then alice + a 100 USDC epoch). Alice gets 100 USDC and her unpaid shares back at fair value; the sybil gains nothing | **PASS** |
| V-01: steered near-complete fills | Inverted PoC, plus the implementer's `steerEpoch` action (90-99.99% fills) in the emergency-seeded suite, 512 x 500 | **PASS**: no cross-epoch state is left to steer |
| V-01: re-request timing | `B3`: anyone may settle with zero liquidity and flush the queue (all shares returned whole). Griefing only. Requests made during a rescue bridge window cannot be flushed (settle reverts in flight) | **PASS** (Info) |
| V-01: mixing deposits and redemptions in one epoch | New `invariant_mixedRequestsFair` / `...Emergency`: a mixed claim is split into the deposit leg (minted shares or refund at the epoch's deposit ratio) and the redemption leg, each held to the unmixed rule. Reachability tests cover a normal mixed epoch and refund + partial fill + returned shares | **PASS** (102,400 and 256,000 calls) |
| V-01: cancel after a partial fill | `B2`: cancel reverts `NothingToCancel` (the inner claim is rolled back); `claim` delivers the payout and the shares; nothing is lost or locked | **PASS** (UX: the banner should say "claim", not "cancel") |
| V-01: claim ordering, odd sizes, many tiny vs one large | `testFuzz_VERIFY2_B1` (512 runs): six odd-sized redeemers plus one large, random fill, claims in reverse order. Each is paid at the epoch ratio or gets shares back (within 2 wei + 1 share unit). Σ paid ≤ epoch paid; Σ returned ≤ not burned; reserve backed | **PASS** |
| V-01: emergency entered and exited around a partial fill | `test_VERIFY2_W01_*` | **FAIL**: new finding W-01 (Medium), below |
| Harness change 1 (round 1 `_checkClaimable`) | `lens.claimable` now returns minted deposit shares **plus** returned redemption shares. The ghost subtracts the returned part using the vault's own Ceil rounding before valuing the deposit. Without the subtraction the old check would flag every partial fill falsely | **Ghost correction, not a weakening** |
| Harness change 2 (fairness clause skips `dep > 0`) | The skipped case was not covered anywhere for the redemption leg. Added `invariant_mixedRequestsFair` (+ emergency variant) that decomposes mixed claims; passes. Note: the clause's final line `assertEq(pending == 0 \|\| pending > 0, true)` is a tautology; remove it | **Skip was a coverage gap, now covered**; tautology Info |
| **V-03** | `test_VERIFY_V03_*`: `renounceOwnership` reverts; `setSentinel` / `setAgentRegistrar` to the pending owner revert; `setGuardian(pendingOwner)` allowed (owner == guardian is the intended cold setup). By hand: `_checkRoles(0, …)` skips owner-equality checks correctly; a second `transferOwnership` re-checks the new pending owner; non-owner `renounceOwnership` reverts with the Ownable error | **PASS** |
| Regression scan: lens | `_redemption` mirrors `VaultMath.claimable` rounding exactly (Floor paid, Ceil burned); `previewEmergencyRedeem` prices at min(NAV, checkpoint) like settle. `partialFill` returns 0 once claimed (despite its comment), so the banner disappears after a claim; cosmetic | **PASS** (Info) |
| Regression scan: webapp | "Re-request remainder" sends `requestRedeem(sharesReturned, user, user)`; the vault claims first, so one transaction works. The fallback `address ?? vault.manager` only applies without a connected wallet (cannot send) | **PASS** |
| Invariant suites | Round 1 `invariant_suite` 512x200; reaudit `invariant_core` 512x200 and N01/N05/N07/N08 512x500; reaudit2 fresh 512x200 and emergency-seeded 512x500 (with `steerEpoch`); verify mixed fresh 512x200 and emergency 512x500 | **all PASS**, 0 reverts |

## 2. New finding

### W-01 (Medium): the owner exits emergency right after each partial fill

**Location.** `VaultGovernance.exitEmergency:170-175` (checks only `pendingRedeemShares > 0`); `VaultGovernance.execute:250` (the queued-after rule covers `clearBreach` only).

**Description.** With partial fill + return, every emergency settle leaves `pendingRedeemShares == 0`: the unpaid shares go back to the redeemers instead of staying pending. That is exactly the condition `exitEmergency` checks. A queued `exitEmergency` is also not tied to the emergency, so the owner can queue it long before.

After the first partial fill, the owner executes it in the same block. The redeemers then have shares back but no exit path until the epoch is overdue again:
- `bridgeToEvm` needs the manager or emergency;
- `settle` needs the manager or an overdue epoch;
- `triggerEmergency` needs an overdue epoch.

The owner re-queues right away; the timelock (≥ 1 day) is shorter than the epoch (up to 30 days). Exit throughput drops from one fill per bridge window (~11 blocks) to one fill per `maxEpochDuration`.

**PoC.** `test_VERIFY2_W01_ownerExitsEmergencyAfterEachPartialFill`: a 10% fill, then emergency is exited in the same block. A week later alice has received 10%, and bridge, settle and trigger all revert.

**Mitigation in place.** The cold platform guardian can `triggerEmergency` at any time, after which the owner needs a fresh timelock per exit. So the worst case with an attentive guardian is one partial fill per owner timelock period. No value is lost (fills are at fair value, shares come back).

**Severity.** Medium: temporary freeze of exits by a malicious owner, the same guarantee H-01b protected.

**Fix (≈3 lines).**
1. Stamp `emergencyAt` in `triggerEmergency`, and in `execute` reject an `exitEmergency` item with `queuedAt <= emergencyAt` (same rule as `clearBreach`).
2. In `exitEmergency`, also require that the last exit-only settle filled in full (store `lastFillBps` at settle, or require `emergencyFillBps() == 10_000` with the last epoch's `redeemBurned == redeemShares`).

Tests: invert `test_VERIFY2_W01_*` (the execute reverts `NotReady` / `RedemptionsPending`). Add a handler action "owner pre-queues and executes exitEmergency right after a partial fill" with ghost "emergency exited with an unpaid partial fill".

## 3. Go / no-go for the capped mainnet deploy

**GO** for the capped deploy (allowlisted launchers, `maxDepositCap` ≤ 50k, the guardian accepts factory ownership before any `setLauncherAllowed`), with these conditions:

1. **W-01:** fix it before the first launcher is allowlisted (≈3 lines, no layout risk) and re-run `Verify2PoC` + the emergency suites. If the deploy goes first, the guardian runbook must re-trigger `triggerEmergency` immediately whenever an owner exits emergency while a partial fill is outstanding (the monitor can flag `EmergencyExited` after an `EpochSettled` with `redeemBurned < redeemShares`). W-01 needs a malicious owner, which during the allowlisted phase is a vetted launcher, and it delays exits without moving value.
2. **Deploy steps:** `DeployFactory` as reviewed; the guardian (cold multisig) sends `acceptOwnership()` (`0x79ba5097`) before any `setLauncherAllowed`; `openLaunch` stays false; `MAX_DEPOSIT_CAP` ≤ 50,000e6.
3. **Before lifting the allowlist** (not required for the capped deploy): W-01 fixed; V-02 (nonce store) and V-04 (registrar pre-binding) addressed; the tautological assertion removed from `Reaudit2Invariants`.

No Critical or High issue is open. Every earlier finding (rounds 1-3, V-01, V-03) verifies as fixed, with its regression test and invariant passing.

---

# Verification pass 3: W-01 fix (`101fb70..5dd5a91`)

The fix has two rules:
- `triggerEmergency` stamps `emergencyAt` (only when entering) and resets `lastFillComplete`.
- `execute` rejects an `exitEmergency` item with `queuedAt <= emergencyAt`, and `exitEmergency` needs `pendingRedeemShares == 0 && lastFillComplete`, where every emergency settle sets `lastFillComplete = (burned == redShares)`.

| Item | Check | Result |
|---|---|---|
| Inverted W-01 PoC | `test_VERIFY2_W01_ownerCannotExitAfterAPartialFill`, `test_VERIFY2_W01_prequeuedExitRevertsEvenAfterAFullFill` | **PASS** |
| Bypass: pre-queued exit | An item queued before the emergency, or in the same second (`<=`), reverts `NotReady` even after a full fill | **Holds** |
| Bypass: emergency re-entry | Re-triggering during an emergency does not move `emergencyAt` (a valid item can't be griefed); a new emergency after an exit stamps a new `emergencyAt` and resets the flag, so items from the previous one are dead | **Holds** |
| Bypass: exit after a partial fill | `lastFillComplete` is recomputed on **every** emergency settle, so after the partial fill an **empty settle** (`0 == 0`), or a sybil **dust redemption** that is filled in full, sets it back to true, and the matured exit executes in the same block. PoCs: `test_VERIFY3_W01b_emptySettleFlipsLastFillComplete`, `test_VERIFY3_W01b_dustRedemptionFlipsLastFillComplete` (pass = issue present). Alice holds her 90% returned shares with no exit path until the epoch is overdue | **BYPASSED → W-01b** |
| Emergency-seeded suites, 512 x 500 | `Reaudit2EmergencyInvariants` (256,000 calls; 3 owner exits) and `VerifyMixedEmergencyInvariants` (256,000 calls; mixed invariants included) | **PASS**. The handler's `ownerExitsAfterFill` executes straight after the latest settle and never inserts a settle in between, so it cannot reach W-01b |
| Other Verify PoCs | V-01 inverted, V-03, B1 fuzz (512), B2, B3 | **PASS** |

## W-01b (Medium): the "last fill complete" condition can be spoofed

**Location.** `VaultLogic.settle` (`if ($.emergency) $.lastFillComplete = burned == redShares;`), `VaultGovernance.exitEmergency`.

**What remains of W-01.** The owner can no longer pre-queue: one fresh timelock (≥ 1 day) is needed per emergency. After that, they can still end the emergency right after any partial fill by settling an empty or dust epoch first, which anyone may do in emergency, in the same block. The returned-share holders then wait `maxEpochDuration` unless the cold guardian re-triggers, after which the owner needs another timelock. No value moves.

**Fix.**
1. Make a partial fill sticky for the emergency. Replace the flag with `partialFillThisEmergency`, set on any emergency settle with `burned < redShares` and cleared only in `triggerEmergency` when entering. Settles with `redShares == 0` never touch it.
2. Once a partial fill has happened, the **owner** path to `exitEmergency` is closed for that emergency; only the cold **guardian** may end it (or the vault winds down).

A counter of outstanding returned shares is *not* sufficient: an attacker can clear it by fully redeeming its own large stake.

**Tests:**
- invert both `test_VERIFY3_W01b_*` (the execute reverts after the empty settle and after the dust redemption);
- add a handler action "settle an empty or dust epoch, then execute the owner's exit" with ghost `vExitAfterPartialFill`;
- add a test that the guardian can still end such an emergency.

## Go / no-go

**GO to deploy the contracts** (factory with `openLaunch = false`, `maxDepositCap` ≤ 50k, the guardian accepts factory ownership before anything else).

**NO-GO to allowlist the first launcher until W-01b is fixed.** This keeps the condition from section 2 ("fix W-01 before the first launcher is allowlisted"): the fix is incomplete, so the condition is not yet met. The change is small (one flag, one branch), and re-verifying it is `Verify3PoC` inverted plus the emergency-seeded suite with the new handler action.

If the platform chooses to allowlist before the fix, the only acceptable mitigation is operational. The guardian runbook must call `triggerEmergency` immediately on any `EmergencyExited` that follows an `EpochSettled` with `redeemBurned < redeemShares` in the same emergency. That bounds the owner to one exit per timelock period. Nothing else is open: no Critical or High, and every other item verifies as fixed.

---

# Verification pass 4: W-01b fix (`6d74c1c..eeb723c`)

The fix: `exitEmergency` is **guardian only**; the owner's queued path is gone (`exitEmergency` is no longer a queueable selector; `lastFillComplete` was removed). The guardian may exit only with nothing pending and when the last settle of this emergency was not a partial fill.

| Item | Check | Result |
|---|---|---|
| Inverted Verify3 PoCs | `test_VERIFY3_W01b_emptySettleDoesNotHelpTheOwner`, `..._dustRedemptionDoesNotHelpTheOwner`: after the empty or dust settle the owner's direct `exitEmergency` and `queue(exitEmergency)` both revert `Unauthorized`; the vault stays in emergency until alice is paid, then the guardian exits. `test_VERIFY3_W01b_guardianGate`: pending and partial-last-fill both block the guardian | **PASS** |
| Non-guardian path out of emergency | `emergency = false` is written in exactly one place (`VaultGovernance.exitEmergency:186`), behind `msg.sender == guardian`. On factory vaults `guardian()` is read live from the factory (only the factory owner rotates it; the vault owner cannot set it, and `setGuardian` is not queueable). No `execute` path reaches it (selector not whitelisted; `queue` reverts). `triggerEmergency` only sets it | **None found** |
| Trap: owner / manager | The owner can't exit; `bridgeToCore` reverts in emergency; deposits are closed; the manager's `bridgeToEvm` only brings USDC home; settle is open to anyone in emergency; exit-only settles never hit the NAV band; requests, claims and cancels are always open | **No trap** |
| Trap: bridge window re-arm (X-01, Low, residual of H-02) | `test_VERIFY4_X01_dustBridgeReopensWindowEachRound`: once Core is drained, a griefer tops it up with 1e-6 USDC on Core and bridges the "full available" amount, re-opening the 10 block window. To block settlement they must be first in the block after every window, paying a Core send plus an EVM tx each round; the first settle that lands pays everyone. Liveness griefing only, no value moved | **Low, accepted** (monitor + priority-fee settler) |
| Guardian gate after an empty settle | The guardian's check looks at the last epoch only, so an empty settle after a partial fill re-opens the gate *for the guardian*. The guardian is the trusted cold key and the rule is documented ("exit only after every redeemer is fully paid or has declined") | **Info** (operational) |
| Emergency-seeded suites, 512 x 500 | `Reaudit2EmergencyInvariants` (256,000 calls; 3 guardian exits) and `VerifyMixedEmergencyInvariants` (256,000 calls; mixed invariants), with the new `guardianExits` action that tries the W-01b trick, owner direct and queued exits, and guardian exits; ghosts `vOwnerExit` and `vExitAfterPartialFill` stay 0 | **PASS** |
| All verify PoCs | V-01 inverted, V-03, B1 fuzz (512), B2, B3, W-01 inverted (2), W-01b inverted (3), X-01 | **PASS** |

## Go / no-go

**Deploy: GO.**
- `DeployFactory` as reviewed; `openLaunch = false`; `MAX_DEPOSIT_CAP` ≤ 50,000e6.
- The guardian (cold multisig) sends `acceptOwnership()` (`0x79ba5097`) before anything else.

**Allowlisting launchers: GO**, once the guardian has accepted factory ownership and with these operating conditions:
1. **Launch:** launchers are vetted and allowlisted individually (`setLauncherAllowed`); `openLaunch` stays false; the cap stays ≤ 50k per vault.
2. **Monitor:** the sentinel monitor is live before the first launch, with the SN-01 HYPE/dust fix confirmed. It watches `EmergencyTriggered`, partial-fill `EpochSettled` (`redeemBurned < redeemShares`) and bridge-window re-arms (X-01). A settler with a priority fee settles emergency epochs as soon as the window closes.
3. **Guardian runbook:** `exitEmergency` only after every redeemer of the emergency is fully paid or has declined. The contract checks the last epoch; the runbook covers the rest.

**Open items, none blocking the capped allowlisted phase:**
- X-01 (Low);
- V-02 (Low, server nonce store);
- V-04 (Low, registrar pre-binding);
- the guardian-gate Info above.

Fix V-02 and V-04 before `openLaunch`. No Critical, High or Medium is open; every earlier finding verifies as fixed.

---

# Verification pass 5: A-13 agent sync (`a07d2fd..f11359d`)

The change: `initialize` only records the agent (`VaultLogic.initAgent`, same factory-binding checks as `setAgent`, no HyperCore action). The new permissionless `syncAgent()` re-sends `addApiWallet($.agent, "dojipad")` and reverts with `ZeroAddress` (no agent) or `ReduceOnlyMode` (breached / emergency). The timelocked `setAgent` still stores and approves in one call.

This confirms assumption A-13 from REPORT.md section 6 (an action sent before the Core account exists is dropped). It was observed on mainnet: vault (an earlier deployment) has `agent()` set, but read-only `extraAgents` is empty and its ledger shows only activation and the seed transfers.

| Item | Check | Result |
|---|---|---|
| Only the stored agent can be approved | `$.agent` is written in exactly two places: `_storeAgent` (non-zero and `platformAgentFor(agent) == address(this)`, reached only from `initAgent` in `initialize` and the timelocked `setAgent`) and the revoke (`= 0`). `syncAgent` takes no parameters and sends `$.agent` only. `test_VERIFY5_syncSendsOnlyTheStoredAgent`: the creating tx sends no `addApiWallet`; the sync sends `(platformAgent, "dojipad")` | **Holds** |
| Breach / emergency gate | A breach always revokes first (`_breach` → `revokeAgent`), so a breached vault has `agent == 0` and sync reverts `ZeroAddress`. A guardian `clearBreach` does not restore the agent, so sync stays impossible until a timelocked `setAgent` (`test_VERIFY5_breachAndEmergencyGate`). The explicit `ReduceOnlyMode` gate is defence in depth: no reachable state has a stored agent while breached | **Holds** |
| Revoke / sentinel / unregister / leaveHosted | Sentinel `revokeAgent`, factory `unregisterPlatformAgent` of the live agent, and `leaveHosted` each set `agent = 0` and write the burn address into the "dojipad" slot; sync then reverts (`test_VERIFY5_noSyncAfterAnyRevoke`) | **Holds** |
| Same-name replacement | All approvals and revocations use the single name "dojipad". HL docs: an approval with a matching name replaces the existing named agent (A-10, verified). A sync can only ever write the stored agent, never an old key. Same block, sync then revoke: CoreWriter actions keep EVM order and the burn lands last (`test_VERIFY5_syncThenRevokeSameBlock`). Cross-block ordering on HyperCore follows EVM order (assumption, consistent with A-08) | **Holds** |
| Re-sync of an approved agent | Same address and same name: a replacement by itself, no state change (HL semantics as above) | **Holds** |
| Griefing bound | Each call is one CoreWriter action costing the caller ~47k gas (HL docs) and changing no vault state (`test_VERIFY5_repeatedSyncCost`: 20 calls, agent unchanged). The HL docs mention no HyperCore-side fee per CoreWriter action, and the mainnet ledgers show none; that is **unverified** without a broadcast. If one exists, spamming could drain the vault's 0.01 HYPE on Core. The consequence would be a later revoke's `addApiWallet(burn)` silently failing: `agent() == 0` on chain while the key stays live on Hyperliquid. Bounded by detection and recovery: the monitor's `FOREIGN_AGENT` check sees an agent on Hyperliquid that is not `agent()`, and anyone can `fundCoreGas` and re-revoke | **Low / Info (conditional)**. Defence in depth: a per-vault cooldown (e.g. one sync per 100 blocks) costs a few bytes |
| Executor: never sync a vault whose stored agent differs | `AgentSync.run` checks `vault.agent() == expected` right before sending (`agentSync.ts:61-66`) and skips otherwise. The monitor only raises `AGENT_NOT_ON_HL` when `onchainAgent == expected` and the agent is absent from `extraAgents`, and reacts once per appearance through the same `ensure` (in-flight dedupe per vault). Revoked vaults (`agent() == 0`) never match. Even a race (revoke between check and tx) is safe: the tx reverts or sends the stored, factory-bound agent | **Holds** |
| Tests | Contracts: `forge test` **184 passed, 0 failed, 2 skipped** (intentional). All invariant suites pass: round 1 512x200; reaudit core 512x200 and N01/N05/N07/N08 512x500; reaudit2 fresh 512x200 and emergency-seeded 512x500 (with the new `syncAgent` action, ghost "sync changed the agent" = 0); verify mixed fresh 512x200 and emergency 512x500. Server: **165/165** (incl. `agentSync.test.ts`, `monitor-agent.test.ts`). New: `test/audit/verify/Verify5PoC.t.sol`, 5/5 | **PASS** |

## Go / no-go

**Redeploy (implementation + factory): GO.**
- Same deploy conditions as section 4: `openLaunch = false`, `MAX_DEPOSIT_CAP` ≤ 50,000e6, and the guardian accepts factory ownership before anything else.
- After each launch, approval is reached by the executor's `syncAgent` (or anyone's). Treat the vault as live only once `extraAgents` lists the stored agent; the wizard and `/api/launch/status` already gate on this.

**Allowlisting:** unchanged from section 4: GO under the stated operating conditions. Add one check: the monitor's `FOREIGN_AGENT` alert must stay enabled after revocations, since it is the detection path if a revoke is ever dropped on HyperCore.

**Existing vaults on the previous mainnet factory** (e.g. an earlier deployment) have no `syncAgent` and no agent on Hyperliquid. Their agent can only be approved through the timelocked `setAgent` (which sends the action after activation), or they can be retired. They are not affected by anything above.

**Open items (unchanged, non-blocking):** X-01, V-02, V-04 (Low); the guardian-gate Info; the `syncAgent` HYPE assumption above (Info). No Critical, High or Medium is open.
