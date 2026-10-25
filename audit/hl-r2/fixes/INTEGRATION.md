# hl-r2 fixes, integrated: one contract patch, one executor patch, one planner patch

**Internal, AI-assisted review (hl-r2, integration sub-review). It is not an independent audit and must not be presented
as one.** Branch `audit/hl-r2-integ` (from `audit/hl-r2` c88b9e2, with the cross-review merge 01afe7c). Nothing was
deployed, sent, pushed or changed in hosting. No env file or hosting configuration was edited. `contracts/src`, `server/src` and
`webapp/` on this branch are unchanged: every change is a patch file, proven in throwaway worktrees under `$TEMP`
(assumption A4).

## In plain words

- **All the contract fixes now ship as one patch** (`integrated/CONTRACTS.patch`):
  - the exit-before-effect rule (fixA H01, plus its Gains twin GR2-CFG-01);
  - the five contract Mediums (fixB: E01, E06, H04, HLO-07, XA01);
  - the two cross-review fixes (XF01, XF02).

  They fit together. The only real text clash is the list of new storage fields at the end of `VaultStorage`, merged
  as a union. Two of the fixes changed each other's meaning, and both are resolved:
  - XF01 replaces fixB's strict H04 rule: owner-chosen roles may bridge home in an emergency again, after a cooldown.
  - The executor must keep the exit price checkpoint moving, now that a stale one blocks the exit settle (E01).
- **The whole contract tree builds in one compiler job, the way the README and the deploy runbook build it.** That
  covers Gains, the scripts and every fix test.
  - fixB's compiler crash ("Tag too large for reserved space") comes from one large **test** contract,
    `Reaudit2PoC`. It was found by replaying forge's exact compiler job and bisecting it. No deployable contract is
    involved.
  - The crash depends on which files share the job. The integrated tree happens not to trip it, so it is fixed anyway
    with a test-only split, proven on fixB's failing tree.
- **The full test suite** fails only on the PoCs that the fixes supersede, each listed by name. Every fix test passes.
- **The executor is aligned with the fixed contracts** (`integrated/EXECUTOR.patch`). That patch is fixC's nine
  patches, plus the cross-review's executor fixes, plus the reconciliation. In short:
  - in an emergency the bridge home goes out from the sentinel;
  - the keeper walks the price checkpoint so exits can settle;
  - an owner-only stop and a deposit hold settle withdrawals;
  - a monitor ACT on a new vault revokes the key instead of freezing every exit;
  - Hyperliquid read weight is shared fairly per owner.
- **The webapp needs one code change now**: the shared planner, `integrated/WEBAPP-epochPlan.patch`. It is a
  byte-for-byte copy of the server's, and a server test enforces that. The other webapp and docs changes are listed
  under "Webapp and docs".

## 1. Contracts: `integrated/CONTRACTS.patch` (+ `CONTRACTS.tests.patch`)

Stack, in order, against `contracts/src` = origin/main 4ec6feb:
1. `patches/HLR2-H01.patch` (fixA);
2. `patches/COMBINED-B.patch` (fixB: E01, E06, H04, HLO-07, XA01);
3. `patches/GAINS-GR2-CFG-01.patch` (fixA, Gains: disjoint files);
4. `tests-xfix/patches/XF01.patch`;
5. `tests-xfix/patches/XF02.patch`.

Files: HyperVault, HyperVaultLens, VaultGovernance, VaultLogic, VaultMath, VaultPolicy, VaultTypes, and seven
`src/gains` files.

### 1.1 Textual conflicts and how they were resolved

| Where | Patches | Resolution |
|---|---|---|
| `VaultStorage` tail (`VaultTypes.sol`) | H01 `epochDeadline`; B `depositHold`, `agentActiveAt`, `platformHold`, `checkpointLagging` | Union, H01's field first. New deployments only (clones, never upgraded), so the order is free. Packing: the five fields share one slot with `insiderInQueue`. |
| `settle` (`VaultLogic.sol`) | H01 (deadline stored at the end), E06 (hard-stop guard, `redemptionOnly`), XA01 (`redemptionOnly`), E01 (exit-only pricing) | Disjoint hunks, applied cleanly. The combined line is `redemptionOnly = _lossBreach || ownerStop || (depositHold && !emergency)`. |
| `triggerBreach` / `_clear` / `clearBreach` (`VaultGovernance.sol`) | E06 `platformHold`, XA01 `depositHold` | H01 touches only `initialize` and `queue` in this file. No overlap. |
| `HyperVaultLens._postFeeRedeem`, previews, `epochOverdue` / `status` | E06 + XA01 (combined in COMBINED-B); H01 (`epochDeadline`) | Disjoint lines. |
| `bridgeToEvm` (`VaultLogic.sol`) | B-H04 then XF01 | XF01 replaces H04's rule (lead's decision). Guardian and sentinel may bridge at any time. Manager, owner and operator may bridge in emergency only `EMERGENCY_BRIDGE_COOLDOWN` = 330 blocks after the previous bridge. |
| `placeOrder` / `flattenOrder` | XF02 | No overlap. |

### 1.2 Semantic interactions checked

- **E01 `CheckpointBehind` × H01 stored deadline and eta.**
  - Overdue is now `now >= epochDeadline`, which a policy change cannot move. So an exit-only settle by a non-treasury
    role happens either at the stored deadline or in emergency. E01's rule then applies the same way in both cases.
  - The XB01 fix test was written to pass either way. On the integrated tree it passes: the owner's settle reverts
    `Unauthorized`, because the instant tightening does not make the epoch overdue.
  - Liveness. The redeemer's forced exit (overdue, then `triggerEmergency`) needs no checkpoint. The settle needs the
    walk: one `checkRisk` per hour, permissionless. The executor now sends it (section 3). The H01 fix tests pay alice
    with E01 in force (`test_FIX_H01_*` pass).
  - **Test-stacking issue.** `HLR2_E01_Fix::test_HLR2_E01_fix_livenessAtTheNavMoveFloor` applied its loosening after
    `timelockDelay`. Under H01 that is `NotReady`. The integrated copy, `integrated/tests/HLR2-E01.fix.t.sol`, warps to
    `pendingConfig().eta`. Nothing else in the test changed.
- **XA01 `depositHold` / E06 `platformHold` × H01's eta for the owner's `clearBreach`.**
  - The owner's queued clear waits `max(now + delay, noticeEta, epochDeadline + 1 d)`.
  - It clears a breach and `platformHold` (`_clear`), never `depositHold`; only the guardian lifts that.
  - So a sentinel stop lasts until the guardian clears it, or past the redeemer's deadline (she can force the
    emergency first). This is by design: the platform hold is the platform's call.
  - Under an owner-only stop, E06 lets redemptions settle redemption-only meanwhile. The long eta therefore freezes
    nothing.
- **HLO-07 warm-up × H01 eta.**
  - `agentActiveAt` = launch + 1 day.
  - A replacement `setAgent` waits at least `max(delay, E + 1 d)`, which is more than 1 day, so it cannot land inside
    the warm-up.
  - A veto (`unregisterPlatformAgent`) also sets `depositHold`, so the vetoed vault stays closed until the guardian
    reopens it (conservative, noted by fixB).
- **H04 / XF01 × the emergency path that fixA's tests use.**
  - The fixA tests pay alice through the guardian's `bridgeToEvm` and settle. The guardian is unrestricted under both
    H04 and XF01, so they pass.
  - Round4's `_home` helpers (COMBINED-B tests patch) bridge as the guardian in emergency, which is still valid.
  - `AuditPoC::test_AUDIT_H02_*`: COMBINED-B had changed its expectation to `Unauthorized`. Under XF01 the manager's
    bridge inside the cooldown reverts `BridgeInFlight`, the original expectation, so that hunk is reverted.
  - `HLR2_H04_Fix::test_HLR2_H04_fix_managerOwnerOperatorCannotBridgeInEmergency` asserted the strict rule. It is
    replaced in `integrated/tests/HLR2-H04.fix.t.sol` by
    `test_HLR2_H04_fix_managerOwnerOperatorCannotChainBridgesInEmergency`:
    - after the sentinel's window, the manager and the operator revert `BridgeInFlight`;
    - the guardian's exit settle lands in the gap;
    - 330 blocks later the operator bridges with no platform key.
- **XF02 × E06 / XA01.** The close band is capped at `maxFlattenSlippageBps` in any breach or emergency. That includes
  an owner stop and a deposit hold: a deposit hold is not a breach, so trading there is bounded only by the revoked
  agent (none) and the manager's on-chain orders at the normal band.
- **GR2-CFG-01 (Gains).** Disjoint from every other patch except one shared constant, `VaultTypes.EXIT_MARGIN`, which
  Gains imports. Built and run in the same one-job tree (section 2), together with its fix tests.

## 2. Compiler error ("Tag too large for reserved space") and how the tree is built

**How CI and Deploy build.**
- The repo has no CI workflow file.
- The README (`forge build`, `forge test`) and the deploy runbooks build the whole project in one solc job: README
  "Mainnet deploy runbook", `docs/gains/REDEPLOY-R2.md` 1.2, `script/anvil-deploy-check.sh` via `forge script`.
- One `foundry.toml` profile: via_ir, optimizer 200, cancun, solc 0.8.28.

**Results.**

| Tree | Files in the job | Result |
|---|---|---|
| Unpatched `audit/hl-r2` (baseline), whole tree incl. Gains | 184 | builds (forge) |
| **Integrated** (CONTRACTS.patch + tests patch + every fix test + XFIX tests), whole tree incl. Gains | 193 | **builds** (forge, 2,058 s, solc peak 7.1 GB private) |
| Integrated, first attempt, while two other solc jobs ran | 193 | `std::bad_alloc` after 538 s: memory pressure (three 5–7 GB solc processes; not reproduced alone) |
| Integrated, solc direct with `solcjob.py` (all contracts, smaller output selection) | 193 | 0 errors, 289 contracts |
| Integrated minus Gains (fixB's shape), solc direct | 116 | 0 errors, 157 contracts |
| fixB's own tree (COMBINED-B, Gains deleted), forge through the `solc_tee` wrapper | 113 (114 sources) | **ICE reproduced**: "Internal compiler error (CompilerStack.cpp:1417): Assembly exception for bytecode: Tag too large for reserved space" after 987 s |
| Same captured job replayed in solc directly | 114 sources | the same ICE |
| Bisect of that job by output selection (13 compiles) | | minimal failing selection: **`test/audit/reaudit2/Reaudit2PoC.t.sol:Reaudit2PoC`** alone |
| Same job with the fix below (only that file changed), both contracts selected | 114 sources | no error (29 s) |
| fixB's tree with the fix, forge one job | 113 | **builds** (664 s) |
| Integrated tree with the fix, `Reaudit2PoC.t.sol` | | 17 / 17 tests pass (16 + 1 moved) |

**Root cause.**
- It is a solc 0.8.28 via_ir internal error while assembling **one test contract, `Reaudit2PoC`**. That contract has
  111,548 B of runtime and 116,545 B of initcode in the integrated build. It inherits the audit base and embeds the
  vault, policy and factory creation code.
- It is not a source error, and not in any deployable contract.
- Whether it trips depends on the whole job:
  - solc numbers AST nodes across every source in the job;
  - via_ir derives Yul identifiers from those ids, so the optimizer's choices and the code layout change with them;
  - the assembler then reserves too few bytes for a jump tag of this very large contract.
- That explains fixB's observations: every file compiles alone; the three halves compile; the full non-Gains tree with
  HLO-07 fails. On the integrated tree, with Gains and the XF tests in the job, the same contract assembles without
  error. That is luck, not a fix.

**Fix (test-only, in `CONTRACTS.tests.patch`).**
- `integrated/split_r2poc.py` moves `test_REAUDIT2_I205_factoryRolesMustNotCollide` out of `Reaudit2PoC` into a new
  `contract Reaudit2PoCFactoryRoles is AuditBase` in the same file. The test body is unchanged.
- `Reaudit2PoC` drops to 107,414 B. With the split, fixB's failing tree builds in one forge job.
- No `contracts/src` change and no foundry profile change were needed.
- **Considered and not used:**
  - building the deploy with `--skip test`: it would hide the problem from the deploy, but CI-style `forge build` /
    `forge test` (README, runbooks) would still stop;
  - a separate profile with `via_ir` only for `src`: it would change the test setup the whole audit history was run
    with.

**Bisect pitfall, for whoever reruns it.** An `outputSelection` with `"*": {"": [...]}` makes solc treat *every*
contract as requested: `requestedContractNames` maps a source-level `""` key under `"*"` to "all". So the selection must
name only the selected contracts. `solcjob.py` does that.

**What the deployable contracts depend on.**
- Each deployable contract's bytecode is produced in the integrated one-job build without error, with the sizes in
  section 4. That covers HyperVault, VaultLogic, VaultGovernance, VaultPolicy, HyperVaultFactory, HyperVaultLens and
  their Gains equivalents.
- The Deploy flow compiles exactly that tree. It is not affected as integrated.
- The crash is a function of the whole job (solc numbers AST nodes across the job, and via_ir's Yul names carry those
  ids). So any later change to any file can make it reappear or vanish. **Guard:** before every deploy, run
  `forge build` of the release commit as one job and check the bytecode against `deployments/*.json`, which the
  runbook already requires.

**Tools** (in `integrated/`):
- `solcjob.py` rebuilds forge's one job (same sorted source set, same settings) with an optional `--select`.
- `solcbisect.sh` halves the selection until one contract remains.
- `solc_tee.py` is a pass-through `solc` for `forge build --use` that keeps forge's exact standard-JSON input.

## 3. Executor: `integrated/EXECUTOR.patch`

What it contains:
- `patches/exec/ALL.patch` (fixC: X01, X03, X04, X05, X07, XA01, H04, H06, ALERT);
- `tests-xfix/patches/XF-exec.patch` for XF-06 (`monitor.ts`) and XF-07 (`engine/executor.ts`). Its XF-04 operator
  hunk is superseded by `exitSettle` (below), which is the same fix plus an immediate retry;
- the reconciliation, also kept on its own as `integrated/EXECUTOR.reconcile.patch`;
- `integrated/WEBAPP-epochPlan.patch`: the webapp's `lib/epoch.ts`, which must stay identical to
  `server/src/treasury/epochPlan.ts`. `server/test/operator.test.ts` "byte for byte copy" fails if they differ, so
  apply both or neither.

| Item | Change | Files |
|---|---|---|
| fixB H04 + XF01: emergency bridges | `OperatorDeps.emergencyBridge`. The emergency exit's `bridgeToEvm` goes out from the **sentinel** key through `chain.operate(…, <sentinel key>, {tipWei})`: the sentinel's online-key sender, charged to the operator job's gas budget by its `bridgeToEvm:` label. No cooldown applies to the sentinel. Without a sentinel key, it uses the operator key; XF01 allows that after the cooldown, and older vaults allow it anyway. | `treasury/operator.ts`, `main.ts` |
| fixB E01 (+ XF-04): checkpoint walk | **Keeper.** `decideCheckRisk` gets reason `exit-walk`. In emergency, a full stop or an overdue epoch, when the checkpoint trails the NAV and is an hour old, it sends `checkRisk`: for any gap when redemptions wait, otherwise only past the usual drift. In a full stop it also keeps the ordinary drift ratchet (`checkpoint`, either direction), so an owner-stop redemption-only settle stays inside the NAV bound. It used to send nothing in a full stop (`contractRisk.ts:253-254`). `riskInputs` reads `pendingRedeemShares`, `epochStartedAt` and `epochDeadline()` in a second batch at the same block. **Operator.** `exitSettle`: on `CheckpointBehind` it sends one `checkRisk` and retries at once. An uncapped step reaches the NAV, so the settle lands in the same run. If the checkpoint is still behind (a capped step), the next try is an hour later (`walkRetryMs`), with one alert a day. | `risk/contractRisk.ts`, `keeper.ts`, `chain/vault.ts`, `treasury/operator.ts` |
| fixA H01: deadline | `epochDeadlineOf()`: `epochDeadline()` on the fixed factory; `epochStartedAt + maxEpochDuration` on older vaults, whose own formula that is. Etas: the executor already takes them from the events (governance alerts, history). | `chain/vault.ts` |
| fixB XA01 + XF-03: deposit hold | `operatorFacts` reads `depositHold()` / `platformHold()` (null on older vaults) and passes them to the planner. The operator never holds a settle under `depositHold`: the contract settles redemption-only. On fixed-factory vaults, a revoked agent alone no longer holds a settle; older vaults keep fixC's `agent() == 0` rule. A held vault with only queued deposits gets no settle, and is reported as "deposit hold: queued deposits carried", not as an error. New guardian alert on `DepositHold(true)` (error, with a review runbook) and `DepositHold(false)` (info). | `treasury/operator.ts`, `main.ts`, `chain/governanceAlerts.ts` |
| fixC XA01 ACT × E06 (XF-03) | **Fixed-factory vaults** (`depositHold()` readable): the ACT sends **`revokeAgent`**. The contract then holds deposits and exits keep settling; `triggerBreach` is only the fallback if the revoke fails. **Older vaults:** `triggerBreach` first (fixC). The alert text says which applies. On the new contract, a sentinel `triggerBreach` sets `platformHold` and freezes every settle until the guardian clears. The ACT therefore never uses it when a revoke suffices. | `monitor.ts`, `main.ts` |
| E06 / XA01 planner (XF-05) | `EpochInput.platformHold` / `depositHold`. `breachMode` maps an owner-only stop (reason 4 with no platform hold) and a deposit hold to `"loss"` (redemption-only, deposits not cash, nothing to Hyperliquid). A platform hold, an unknown hold (older vault), reason 5 and emergency stay `"stop"`. Round 3 vaults are unchanged. | `treasury/epochPlan.ts` + webapp `lib/epoch.ts` |
| XF-06, XF-07 | As in the cross-review: netting in UNEXPLAINED_OUTFLOW, and retries of full reduce-only closes. | `monitor.ts`, `engine/executor.ts` |
| XF-08 (Low) | `setHlWeightFairness`. Inside a priority, waiters of **reserved** vaults go first while reserved spend in the rolling minute is under 30% of the budget. "Least served" counts per **owner group** (`registry.tenantFor(v).owner`), not per vault id. Wired: groups = tenant owner; reserved = `platformRun(v)`. Outside-deposit vaults are not wired: that needs a synchronous outside-deposit cache (follow-up). | `venues/hl/weightBudget.ts`, `main.ts` |

**Proof** (throwaway `$TEMP/integ-exec`, real `npm ci` in `server/` and `webapp/`, no junction):

| Run | Result |
|---|---|
| `tests-exec` (fixC's 62 fix + PoC tests, and `INTEG.fix.test.ts`, 27 tests) | **89 / 89 pass** |
| `INTEG.fix.test.ts` on ALL.patch alone (before the reconciliation, first 16 tests) | 12 fail, 4 pass. The 4 are the controls: no-sentinel fallback, outside emergency, another revert, platform hold runs nothing. |
| `tests-xfix` fix tests (with the integrated XF-04 expectation: walk and settle in one run) | 4 / 4 pass |
| `tests-xfix` PoCs (7) | **3 fail (fixed):** XF04, XF06, XF07. **4 pass:** the two XF05 PoCs build planner inputs *without* the new fields, which is the older-vault path and is unchanged by design (inverted in `integ_XF05_owner_stop_settles` / `_deposit_hold_deposits_not_cash`); the XF06 control; and the XF08 PoC, which runs with no fairness configured (inverted in `integ_XF08_*`). |
| touched server test files (44 files: operator, treasury, keeper-*, risk-*, monitor-*, settle-revert, precompile-fallback, log-stream, gas-budget, hl-weight-budget, executor, …) | **461 passed, 3 skipped, 0 failed** |
| `npx tsc --noEmit` | clean |
| webapp `src/lib/epoch.test.ts` (with the planner patch) | 22 / 22 pass |

One existing test needed a code change, not a test change. `precompile-fallback.test.ts` has a strict RPC fake that
rejects the whole multicall on an unknown view. The new reads were therefore moved to a second batch at the same block;
a failed read is `null` and never fails the batch. No server test file was edited.

`INTEG.fix.test.ts` tests (27):
- `integ_H04_emergency_bridge_from_sentinel`, `_no_sentinel_key_falls_back_to_the_operator`,
  `_outside_emergency_unchanged`;
- `integ_E01_checkpoint_behind_walks_then_settles`, `_capped_step_waits_an_hour`, `_other_revert_still_throws`,
  `integ_E01_keeper_walks_in_emergency`, `_in_a_platform_full_stop`, `_when_overdue`, `_no_walk_when_pointless`;
- `integ_E06_owner_stop_pays_redemptions`, `integ_E06_platform_hold_runs_nothing`;
- `integ_XA01_deposit_hold_no_settle_loop`, `_pays_redemptions_once`, `integ_XA01_deposit_hold_alert`;
- `integ_H01_deadline_source`;
- `integ_XF03_new_vault_act_revokes_not_breaches`, `_revoke_fails_falls_back_to_breach`,
  `_old_vault_keeps_trigger_breach`, `_no_settle_hold_under_deposit_hold`;
- `integ_XF05_breach_modes`, `_owner_stop_settles`, `_deposit_hold_deposits_not_cash`,
  `_keeper_ratchets_in_an_owner_stop`;
- `integ_XF08_reserved_share_serves_the_platform_vault`, `_owner_groups_count_a_swarm_once`,
  `_control_per_vault_is_still_refused`.

## 4. Full suite, built as the README / deploy flow builds (one job, Gains included)

forge 1.8.4, solc 0.8.28 via_ir. Logs: `results/integrated-baseline.log`, `results/integrated-contracts.log`.

| Run | Files in the job | Tests | Passed | Failed | Skipped |
|---|---|---|---|---|---|
| Baseline: unpatched `audit/hl-r2` c88b9e2 (src = origin/main) | 184 | 755 (113 suites) | 731 | 0 | 24 |
| **Integrated**: CONTRACTS.patch + CONTRACTS.tests.patch + all fix tests + XFIX tests (before the Reaudit2PoC split) | 193 | 801 (124 suites) | 760 | 17 | 24 |
| **Integrated, final**: `verify-integrated.sh contracts` from the committed patches (split included), fresh throwaway | 195 | 801 (125 suites) | **760** | **17** | 24 |

- **The 24 skips are the same in both runs**: 21 fork `setUp()` skips without an RPC, `test_HLR2_FLOW_fork_…`, and the
  two `test_mixed…Reachable` smoke tests.
- **The 46 extra tests** are the 41 fix tests and the 5 XFIX PoCs. The final run has one more suite because the split
  moved one test into `Reaudit2PoCFactoryRoles`; the test count is unchanged.
- **The final run's failures** are the same 17 names, and "failing tests that are NOT a superseded PoC" is empty
  (`results/integrated-contracts.log`).
- **Every failure is a superseded PoC. None is unexpected.**

| Superseded PoC (fails by design) | Superseded by | Fix report |
|---|---|---|
| `test_HLR2_H01_loosenedPolicyAppliesBeforeASameBlockRedeemerCanForceAnExit` | H01 | fixA |
| `test_HLR2_H01b_keeperOperatorCannotGetTheRedeemerOutEither` | H01 | fixA |
| `test_HLR2_E06b_ownerLengthensTheWaitTo30Days` | H01 (leg C: the deadline snapshot) | fixA |
| `test_HLR2_XB01_instantEpochTighteningOpensTheExitOnlyPriceWithoutAnEmergency` | H01 / E01 | fixA, fixB |
| `test_XB_H01a_guardianEmergencyInsideTheTimelockGetsTheRedeemerOutAtTheOldRisk` | H01: its claim still holds, but it applies the loosening at queue + 2 d, which is now `NotReady` | fixA |
| `test_XB_H01b_fixSketchBLeavesLateReactingRedeemersExposed` | H01 | fixA |
| `test_HLR2_E01a_…`, `_E01b_…`, `_E01c_…`, `_E01d_…`, `_E01e_…` (5) | E01 (`CheckpointBehind`) | fixB |
| `test_HLR2_E06_fullStopBlocksAllExitsUntilOverdue` | E06 | fixB |
| `test_HLR2_H04_managerBridgeChainKeepsTheEmergencySettleOut` | H04 / XF01 (`BridgeInFlight`: the cooldown) | fixB, XF |
| `test_HLO07_leakedRegistrarKeyGivesAnyLauncherASelfHeldAgent` | HLO-07 (`AgentWarmingUp`) | fixB |
| `test_HLR2_XA01_revokeOnlyActStillLetsTheKeeperSettleAtTheDeflatedNav` | XA01 (`RequestNotSettled`: carried, not minted) | fixB |
| `test_XF01_emergencyExitNeedsAPlatformKeyForever` | XF01 | cross-review |
| `test_XF02_loosenedSlippageWidensTheEmergencyCloseBandTo20pct` | XF02 | cross-review |

**These keep passing by design:**
- `test_XB_E01c_…` (the walk);
- `test_HLR2_XA01_control_…`;
- the three `test_HLO07_r2_*` tests;
- `XFIX_PoC::test_XF03_*` (both) and `test_XF04_*`. Their contract behaviour is intended; the fixes are in the
  executor.

**Fix tests: all 41 pass.**

| Suite | Tests | Result |
|---|---|---|
| fixA (`HLR2_H01_Fix`, `HLR2_XB01_Fix`, `GainsCfgFix`) | 9 + 1 + 5 = **15** | 15 pass |
| fixB (`HLR2_E01_Fix`, `HLR2_E06_Fix`, `HLR2_E06_FixFactory`, `HLR2_H04_Fix`, `HLO07_Fix`, `HLR2_XA01_Fix`) | 7 + 4 + 1 + 3 + 4 + 3 = **22** | 22 pass |
| Cross-review (`XFIX_Fix`) | **4** | 4 pass |

Two of these run from the integrated copies:
- the E01 liveness test now waits for the stored eta;
- the H04 test is inverted for the XF01 cooldown.

**Sizes** (runtime bytes, from this build; EIP-170 = 24,576):

| Contract | Bytes | Margin |
|---|---|---|
| HyperVault | 17,532 | 7,044 |
| VaultLogic | 18,210 | 6,366 |
| VaultGovernance | 12,020 | 12,556 |
| VaultPolicy | 10,107 | 14,469 |
| HyperVaultFactory | 10,955 | 13,621 |
| HyperVaultLens | 9,118 | 15,458 |
| GainsVault | 19,037 | 5,539 |
| **GainsVaultLogic** | **22,014** | **2,562** (the tightest) |
| GainsVaultGovernance | 13,119 | 11,457 |
| GainsVaultPolicy | 13,068 | 11,508 |
| GainsVaultFactory | 12,203 | 12,373 |
| GainsVaultLens | 10,631 | 13,945 |
| GainsNav | 12,340 | 12,236 |

Init code is below 49,152 everywhere. The test handlers above the limit are pre-existing and are not deployed.

## 5. Webapp and docs changes the fixes require (not patched here, except the planner)

Code:
- `webapp/src/lib/epoch.ts`: **patched** (`integrated/WEBAPP-epochPlan.patch`), identical to the server's
  `epochPlan.ts`.
- `webapp/src/components/manage/TodoCard.tsx:51`: also pass `platformHold` and `depositHold` from the vault into the
  planner input. Without them, the To do card keeps the old behaviour, which is safe: "stop" / normal.
- `webapp/src/data/chain.ts:104-129`: read `epochDeadline`, `depositHold`, `platformHold`, `agentActiveAt` and
  `checkpointLagging`. Each is optional: older vaults revert, so read them as null.
- `webapp/src/data/chain.ts:208`: the overdue fallback becomes `now >= epochDeadline`. Use
  `epochStartedAt + maxEpochDuration` only when `epochDeadline` is null.
- `webapp/src/data/derive.ts:51` (`epochProgress`): max = `epochDeadline - epochStartedAt`.
- `webapp/src/components/vault/VaultCards.tsx:209`: "Epoch deadline" shows this epoch's stored deadline as a date.
  Show the policy length as "Next epochs: N days".
- `webapp/src/components/gains/GainsCards.tsx:487`: the same formula on Gains, so read `epochDeadline()`.
- `webapp/src/components/manage/GovernanceCards.tsx:78`: "Sensitive changes wait {delay} so depositors can exit
  first" becomes "Changes that add risk wait at least one epoch plus a day (max(delay, epoch + 1 day)); each queued
  item shows its own date". `:243`: the epoch field hint says that a new epoch length applies from the next epoch.
- `webapp/src/components/manage/FeeRecipientCard.tsx:51` and `VaultCards.tsx:462` ("Change delay"): show the stored
  eta (`queuedEta`, `pendingConfig().eta`, `assetAllowEta`). Never compute `queue + timelockDelay`.
- `webapp/src/pages/LaunchPage.tsx:394` and `GainsLaunch.tsx:225`: the fixed `timelockDelay = 2 days` stays valid.
  Recommended: `max(2 days, epochDays + 1 day)`, capped at 30 days, so the shown delay equals the real notice.
- `webapp/src/components/manage/OpsCards.tsx:83-84`: "a full stop does not [settle]" becomes "an owner-only stop and a
  deposit hold settle withdrawals only; a DojiPad stop or an emergency does not". The flag follows `vaultBreachMode`
  once it reads the holds.
- Vault page and DepositPanel: show a "Deposits on hold: DojiPad is reviewing; withdrawals keep settling" badge
  (`depositHold`), and "Opens for deposits at {agentActiveAt}" during the warm-up.
- `webapp/src/abi/*.ts`: regenerate (`npm run abi`) for the new views, events (`DepositHold`) and errors
  (`CheckpointBehind`, `AgentWarmingUp`).

Docs (new wording; for vaults from the fixed factory, while the old factories keep their current, corrected text):
- `docs/depositors.tsx:249` and `security.tsx:199` (exit pricing): "An exit-only settlement waits until the checkpoint
  has caught up with the vault's value. Anyone can move it, one step an hour, and DojiPad's keeper does. It then pays
  at the lower of the live value and a checkpoint at most an hour old."
- `docs/depositors.tsx:231` and `security.tsx:201` (full stop): "A stop by the owner keeps withdrawals settling;
  deposits wait. A stop by DojiPad's guardian or sentinel, or an emergency, freezes settlement until the guardian acts
  or the epoch passes its deadline."
- `docs/depositors.tsx:319` and `overview.tsx:26` ("so you can leave first"): "Changes that add risk wait at least one
  full epoch plus a day, whatever the timelock, so a withdrawal you request in time is forced through before they
  apply. The epoch's deadline is fixed when it starts."
- `docs/depositors.tsx:339-344` and `security.tsx:198` (sentinel revokes the key): "When DojiPad revokes a key, the
  vault goes on deposit hold. Deposits close and queued deposits wait (you can cancel them) until DojiPad's guardian
  reviews. Withdrawals keep settling."
- `docs/depositors.tsx:426-427` and `managers.tsx:486` (bridge home in an emergency): "In an emergency DojiPad's
  guardian and sentinel can bring USDC home at any time. The manager, the owner and the operator can do so only after
  a pause of about 330 blocks since the previous transfer."
- `docs/managers.tsx:140-142` (launch steps): "A vault launched with a DojiPad strategy opens for deposits 24 hours
  after launch. During that time DojiPad can veto the key, and the key cannot trade."
- Flatten / close band, managers' docs on breach and emergency closes: "In a breach or an emergency, closing orders
  and flattens stay within the flatten cap (at most 3%), whatever the policy's slippage."

## 6. Follow-ups (not done here)

1. **Executor HLO-07 warm-up.** The post-launch `syncAgent` (A-13, `agentSync.ts`) and the monitor's
   AGENT_NOT_ON_HL reaction revert `AgentWarmingUp` for 24 h on a new vault, giving error alerts and no harm. They
   should skip while `now < agentActiveAt()`. The automatic sentinel `unregisterPlatformAgent` of an unreserved agent
   (fixB) is also not built.
2. **XF-08 outside-deposit reservation.** `reserved` is wired to platform-run vaults only. Outside-deposit vaults need
   a synchronous cache of `outsideDeposits`.
3. **Emergency exit when our keeper is not the operator.** The H01 scenario includes `setOperator(0)`. The operator
   skips such vaults, so the redeemer's forced emergency is settled by the guardian by hand. A sentinel-driven
   emergency settle for every vault with redemptions waiting in emergency would close that gap.
4. **Lens.** `status()` could expose `epochDeadline`, `depositHold`, `platformHold`, `agentActiveAt` and `noticeEta`,
   giving the webapp one read.
5. **Governance alert backfill** (cross-review info (a)): at start, read the pending config, the asset etas and the
   vault queue.
6. **Compiler guard** (section 2): one-job `forge build` and a bytecode check at every release commit.
7. When the fixes ship, delete or invert the superseded PoCs (section 4) in the audit branch. The Gains CFG PoCs live
   on `audit/gains-r2` (`ConfigTimelock.t.sol`) and are not in this tree.

## 7. Assumptions

- **XF-03.** "A revoke suffices" holds only on vaults with contract XA01 (`depositHold()` readable). Older vaults keep
  `triggerBreach` first.
- **XA01 hold.** fixC held settles on a revoked platform-run vault. On fixed-factory vaults it no longer does: the
  contract makes them redemption-only, and the monitor finding still holds the first 24 h. Redemptions under a deposit
  hold are paid at min(NAV, checkpoint), possibly the deflated value; a redeemer can cancel. This is fixB's stated
  residual, accepted.
- **Sentinel for emergency bridges** even though XF01 lets the operator bridge after the cooldown. The sentinel has no
  cooldown, and the emergency is already a platform incident.
- **XF-04.** One immediate retry after a `checkRisk` step. The settle is simulated first, so a revert costs no gas.
- **Planner mapping.** An owner-only stop and a deposit hold are presented to the planner as `"loss"`, the existing
  redemption-only mode, rather than a new mode, so the webapp copy changes by about 10 lines.
- **Superseded tests.** A superseded PoC is listed, not edited. The two adapted fix tests (E01 liveness, H04 under
  XF01) and the XF-04 fix test expectation are copies in `integrated/tests/`; the originals are untouched.

## 8. Files

- `fixes/INTEGRATION.md` (this file)
- `fixes/integrated/CONTRACTS.patch`, `CONTRACTS.tests.patch`
- `fixes/integrated/EXECUTOR.patch` (= exec/ALL + XF-exec without its operator hunk + reconcile),
  `EXECUTOR.reconcile.patch`, `WEBAPP-epochPlan.patch`
- `fixes/integrated/tests/HLR2-E01.fix.t.sol`, `HLR2-H04.fix.t.sol`, `XFIX-fix.xfix.test.ts`: the adapted copies
- `fixes/tests-exec/INTEG.fix.test.ts`
- `fixes/integrated/solcjob.py`, `solcbisect.sh`, `solc_tee.py`, `split_r2poc.py`; `results/integrated-solc-bisect.log`
- `fixes/verify-integrated.sh`; `fixes/results/integrated-*.log`

## Addendum (lead, 2026-10-21; the sub-reviewer stopped on an API usage limit before writing this)

- **Final one-job suite on the integrated stack** (d6e457b, committed patches, Gains included; the mutation kill
  tests are in the tree):
  - 897 tests: 856 passed, 17 failed, 24 skipped.
  - The 17 failures are exactly the superseded PoCs.
  - No other failure, against the expected none.
  - Fix tests: 41/41.
  - Log: `results/integrated-verify-contracts-final.out`.
- **Mutation kill tests M41, M69 and M72:** they waited `timelockDelay` and failed only because the fix moved the
  eta. They were adapted in CONTRACTS.tests.patch to wait for the stored eta. With the adaptation they still kill
  their mutants (setAgent-zero, setManager-zero, the clear-in-breach-block guard), and they pass on the clean
  integrated tree (`results/integrated-mutcheck.out`).
- **Halmos re-run on the integrated source,** under the shared lock (03:26–03:52 local):
  - P1, P2, P3, V3, V4, V5 and H7d6 proved.
  - The negative control X1 fails, as it must.
  - H8 (the HAL01 property) timed out at this run's own 20-minute limit. Earlier, on the unpatched source, it gave
    the HAL01 counterexample. The integrated patch does not change `PxMath`, so HAL01 still applies.
  - Logs: `results/integrated-halmos/`.
- The one-job build exits 1 only on EIP-170 for test handler contracts. Every deployable contract is below 24,576 B
  (the table is in the log).
