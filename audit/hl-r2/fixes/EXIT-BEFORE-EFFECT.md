# Exit before effect: one fix for HLR2-H01 (HL) and GR2-CFG-01 / GR2-CFG-02 (Gains)

**Internal, AI-assisted review (hl-r2, fix sub-review A). Not an independent audit.** Branch `audit/hl-r2-fixA`
(from `audit/hl-r2` 154856b). Nothing deployed, no transaction sent, nothing pushed; `contracts/src` unchanged on this
branch (assumption A4: the fixes are patch files, proven in a throwaway worktree by `verify.sh`).

## 1. The pattern in plain words

A depositor cannot leave on her own. Her only forced exit is the epoch deadline: once it passes with her redemption
pending, anyone may trigger the emergency, which freezes new risk for good (reduce only, agent revoked; on Gains an
overdue epoch already refuses new risk). So "you can leave before a change applies" is true only if **every change
that widens what her money is exposed to applies after her deadline, with time to spare**. Two rules make that hold:

1. **The deadline is fixed when the epoch starts.** Every settle (and `initialize`) stores
   `epochDeadline = now + maxEpochDuration in force`. `epochOverdue` reads that. A change to `maxEpochDuration` -
   longer or shorter - applies from the next epoch. A running deadline never moves, and overdue stays overdue.
   (Closes H01 leg C / E06b, HLR2-XB01, GR2-CFG-02.)
2. **Notice at least one epoch plus a margin.** A widening change queued at time `q` gets
   `eta = max(q + timelockDelay, q + E + EXIT_MARGIN, ceiling + EXIT_MARGIN)`, where:
   - `E` is the longest epoch length that can be in force before the eta (the current one, or a longer pending one
     for changes queued beside it);
   - `ceiling` is the latest deadline left by an epoch length that was lowered during a running epoch;
   - `EXIT_MARGIN` is 1 day.

   The timelock stays as a floor. It no longer needs to be compared with anything.
   (Closes H01 legs A and B, H01b, GR2-CFG-01.)

The rejected alternative "apply a loosening only after a settle that ran after the queue" (fix sketch B) is not
used: it protects only redeemers who asked before that settle (HLR2-XB03).

## 2. The guarantee

Take a widening change queued at time `q`. Take a depositor whose redemption request is in by `q + R`, where `R` is
at most `EXIT_MARGIN` (1 day).

- She is paid by a settle first, or she can call `triggerEmergency` herself (permissionless: overdue plus a pending
  redemption).
- She can do that at least `EXIT_MARGIN - R` before the change can be executed.
- If no settle runs between `q` and her request, any request made before her epoch's deadline is covered, with at
  least the full margin.
- Once she has triggered, the change applies to a vault that can only reduce. On Gains the overdue epoch already
  refuses new risk.
- Only the guardian ends an emergency, and only after every redemption is paid in full.

Who is protected:
- the H01 redeemer who reacts in the same block as the queue: a full day of slack;
- a redeemer who reacts up to 12 h later: at least 12 h of slack, even if the owner settles an empty epoch in
  between (the XB03 attack).

**What it does not promise:**
- **How long she waits.** That is still the epoch she accepted (up to 30 days).
- **The exit price.** Exit-only pricing at min(NAV, checkpoint) is HLR2-E01's subject.
- **Who carries out the payout.** It is still manual (HLR2-L01): flatten, bridge and settle by a platform role.

**Why it holds (sketch).**
- **Running deadline.** A redeemer waiting at `q` sits in an epoch that started at `s <= q`, with deadline
  `s + E(s)`. That is either `<= q + E_now`, or `E` was lowered after `s`. In the second case the policy recorded
  `ceiling >= lowering time + E(s) >= s + E(s)`.
- **Settles between `q` and the eta.** A settle after `q` and before her request uses an `E` no longer than the
  current or the pending one:
  - The only other way `E` can grow is a config queued after `q`.
  - That config waits at least `E_now + EXIT_MARGIN` itself, so it cannot apply before `q + EXIT_MARGIN`.
  - Hence `R <= EXIT_MARGIN`.
- **Its own config.** A config change's own eta does not need its new `E`. Until it applies, no settle can use it, and
  a pending config is replaced, never stacked.

## 3. Choice: compute the eta at queue time (not "enforce timelock >= E + margin")

- **Option A: an invariant `timelockDelay >= E + EXIT_MARGIN`.** It would have to hold across two contracts:
  - the vault's own delay against the policy's epoch length;
  - and the HL policy does not know its vault.
  The policy's `E` can grow through the policy queue without the vault re-checking its delay. Option A would also
  reject every launch the webapp sends today (2-day delay, epoch of 2 days or more), and tie `MAX_TIMELOCK` (30 d)
  to `maxEpochDuration` (30 d).
- **Option B, the choice: the eta formula.** It is local to each queue and needs no cross-contract invariant. It
  keeps every existing configuration and ABI valid (only etas get later), and it makes the timelock delay irrelevant
  to exit safety. Lowering a delay therefore needs no extra rule.
- **Gains:** the Gains policy knows its vault, so it could read the vault's deadline instead of keeping a ceiling.
  The same ceiling code is used on both venues so that one pattern is reviewed once.

### Which changes need the notice

| Change | Needs it? | Covered by |
|---|---|---|
| Policy loosening (`proposeConfig`, any field looser) | **yes**: more leverage, notional, slippage, breakers off | policy `_noticeEta(0)` |
| `queueAllowAsset` (HL perp, Gains pair) | **yes**: new market exposure (Gains: also a feed and band copy, CFG-03) | policy `_noticeEta(pending E)` |
| `setAgent` | **yes**: the agent signs off-chain and the contract bounds it only on dex 0 (CONTEXT 4) | vault `queue` |
| `setManager` | **yes**: a new trader and treasury role (normal settles, onchain orders) | vault `queue` |
| `setFees` raise | **yes** for the management fee (applies at execute); the performance raise already waits a normal settle | vault `queue` |
| owner `clearBreach` | **yes**: re-opens trading after a stop (H03) | vault `queue` |
| Gains `setPairFeed` / `setSequencerFeed` | **yes** (valuation step, GR1-35) | vault `queue` |
| `setFeeRecipient` | not for principal (fee shares only, and the recipient is an insider whose deposits are deferred); covered anyway: one rule for the whole queue is simpler to reason about | vault `queue` |
| vault `setTimelockDelay` lowering | **no**: every later change still waits for the notice; covered anyway as a queue item | vault `queue` |
| policy `proposeTimelockDelay` lowering | **no**: same reason; left unchanged (waits the old delay) | - |
| Tightenings, `disallowAsset`, `lowerFees`, pauses, breaches, emergency | no: they reduce exposure; tightening `E` is instant but only for the next epoch (rule 1) | - |
| `setOperator(0)` (instant) | no longer matters for H01: the redeemer triggers the emergency herself | - |

## 4. Exact diffs

Patches (against `contracts/src` = `origin/main` 4ec6feb; LF, `git apply` from the repo root):
- `fixes/patches/HLR2-H01.patch`: HL. Covers H01, H01b, E06b leg C and XB01.
  - Files: `VaultPolicy.sol`, `VaultTypes.sol`, `VaultMath.sol`, `VaultLogic.sol`, `VaultGovernance.sol`,
    `HyperVault.sol`, `HyperVaultLens.sol`.
- `fixes/patches/GAINS-GR2-CFG-01.patch`: Gains. Covers CFG-01 and CFG-02.
  - Files: the same seven files under `src/gains/`, with `GainsTypes.sol` in place of `VaultTypes.sol`.

The two patches touch disjoint files and apply together.

Each source patch has a companion `patches/<ID>.tests.patch` that updates existing tests (see 5.3).

Per codebase, the same seven edits:

| Where | HL | Gains |
|---|---|---|
| margin constant | `VaultPolicy.EXIT_MARGIN = 1 days`, `VaultTypes.EXIT_MARGIN` | `GainsVaultPolicy.EXIT_MARGIN`, `GainsTypes.EXIT_MARGIN` |
| deadline storage | `VaultStorage.epochDeadline` (uint64, appended last) | `GainsTypes.VaultStorage.epochDeadline` (appended last) |
| deadline set | `VaultGovernance.initialize`, `VaultLogic.settle` | `GainsVaultGovernance.initialize`, `GainsVaultLogic.settle` |
| overdue | `VaultMath.epochOverdue: now >= epochDeadline` | `GainsVaultMath.epochOverdue` (also gates new risk, `_newRisk`, `updateLeverage`) |
| policy notice | `_noticeEta`, `noticeEta()`, `_setConfig` (ceiling), `epochDeadlineCeiling` (appended last); used by `proposeConfig` (loosening) and `queueAllowAsset` | same |
| vault queue | `eta = max(now + T_v, policy.noticeEta(), epochDeadline + EXIT_MARGIN)` | same |
| views | `HyperVault.epochDeadline()`, Lens `epochOverdue` / `status` read it | `GainsVault.epochDeadline()`, `GainsVaultLens` |

Core of the policy change (identical on both venues):

```solidity
uint256 public constant EXIT_MARGIN = 1 days;
uint64 public epochDeadlineCeiling; // appended after the last state variable

function noticeEta() external view returns (uint256) {
    return _noticeEta(_pending.exists ? _pending.config.maxEpochDuration : 0);
}

function _noticeEta(uint256 otherEpoch) internal view returns (uint256 eta) {
    uint256 e = _config.maxEpochDuration;
    if (otherEpoch > e) e = otherEpoch;
    eta = block.timestamp + e + EXIT_MARGIN;
    uint256 c = uint256(epochDeadlineCeiling) + EXIT_MARGIN;
    if (c > eta) eta = c;
    uint256 t = block.timestamp + timelockDelay;
    if (t > eta) eta = t;
}

function _setConfig(RiskConfig memory next) internal { // used by the tightening path and applyPendingConfig
    if (next.maxEpochDuration < _config.maxEpochDuration) {
        uint256 c = block.timestamp + _config.maxEpochDuration;
        if (c > epochDeadlineCeiling) epochDeadlineCeiling = uint64(c);
    }
    _config = next;
}
// proposeConfig (loosening): eta = _noticeEta(0); queueAllowAsset: eta = _noticeEta(pending E)
```

Vault side:

```solidity
// settle (after epochStartedAt) and initialize:
$.epochDeadline = uint64(block.timestamp + $.policy.maxEpochDuration());
// VaultMath.epochOverdue:
return block.timestamp >= uint256($.epochDeadline);
// VaultGovernance.queue:
uint256 eta = block.timestamp + $.timelockDelay;
uint256 notice = $.policy.noticeEta();
if (notice > eta) eta = notice;
notice = uint256($.epochDeadline) + EXIT_MARGIN;
if (notice > eta) eta = notice;
```

## 5. Tests and results

Reproduce with `contracts/audit/hl-r2/fixes/verify.sh HLR2-H01 GAINS-GR2-CFG-01`.
- Runtime on this machine: about 1.5 h for HL and 2.5 h for Gains. `SKIP_BASELINE=1` skips the unpatched suite.
- For each id, in a throwaway detached worktree, the script:
  1. applies `patches/<ID>.patch` (contracts/src) and `patches/<ID>.tests.patch` (existing tests, see 5.3);
  2. copies `tests/<ID>.fix.t.sol` to `test/audit/hl-r2/fixes/`;
  3. runs the tests;
  4. removes the worktree. It refuses to if the worktree contains a junction or symlink.
- Logs: `results/<ID>.log` (summary) and `results/<ID>.<step>.txt` (raw forge output).

### 5.1 Fix tests

`tests/HLR2-H01.fix.t.sol` (HL, 10 tests):

| Test | Proves |
|---|---|
| `HLR2_H01_Fix::test_FIX_H01_sameBlockRedeemerForcesTheExitBeforeTheLooseningApplies` | The H01 PoC timeline: the platform vault config, alice 100,002 USDC, request in the same block as the queue.<br>- eta = queue + 8 d (not 2 d).<br>- Alice triggers the emergency herself at the old 7-day deadline, 25 h before the eta.<br>- The 30-day epoch in the loosening does not move her deadline (E06b leg C).<br>- After the apply the 45x order reverts `ReduceOnlyMode`.<br>- The guardian pays her 99,957.94 against 100,001.99 at request (0.04% = a week of the 2% management fee). |
| `..._H01b_keeperOperatorNoLongerMatters` | H01b: keeper as operator, NAV in margin, the keeper's settle still `InsufficientLiquidity`. Alice no longer needs the keeper, and the emergency survives the apply. |
| `..._H01_lateReactorAfterAnInterveningSettleStillGetsOut` | The XB03 attack: the owner settles an empty epoch 1 h after queuing and alice reacts 12 h after the queue. Her new deadline is still 23 h before the eta. |
| `..._H01_vaultQueueWaitsForTheExitWindow` | `setFees` raise, `setManager` and `setTimelockDelay(1 d)` queued on the vault (vault delay 2 d): eta = queue + 8 d. Alice is paid before any of them can execute, and the 5% fee never applies to her. |
| `..._H01_pendingLongerEpochLengthensLaterNotices` | A pending 30-day epoch makes a vault item queued beside it wait 31 d. |
| `..._H01_allowAssetWaitsForTheExitWindow` | A new perp (DOGE, curated) waits 8 d. |
| `..._H01_tightenThenLoosenStillWaitsForTheRunningDeadline` | An instant 1-hour epoch tightening leaves the running 7-day deadline alone, and the ceiling keeps the next loosening's eta at queue + 8 d. Without the ceiling it would be queue + 1 d + 1 h, before alice's exit. |
| `..._H01_control_honestLooseningAppliesAfterTheNotice` | Control: an honest loosening applies at its eta, a 9-day delay dominates the notice, and lowering the delay itself still waits the old delay. |
| `..._H01_control_overdueStaysOverdueAfterAnEpochRaise` | Control (CFG-02 on HL): nobody acts, the 30-day epoch applies, the epoch stays overdue, and a stranger triggers the emergency. |
| `HLR2_XB01_Fix::test_FIX_XB01_instantEpochTighteningDoesNotOpenTheExitOnlyPrice` | XB01 inverted.<br>- The instant 1-hour tightening does not make the epoch overdue, and the owner's exit-only settle reverts `Unauthorized`.<br>- The next normal settle pays alice 129,999.999999 (fair) instead of 100,000.<br>- 1-hour epochs start with the next epoch. |

`tests/GAINS-GR2-CFG-01.fix.t.sol` (Gains, 5 tests, `GainsCfgFix`):

| Test | Proves |
|---|---|
| `test_FIX_GR2_CFG_01_redeemerPaidAtTheOldRiskBeforeTheLooseningApplies` | The CFG-01 PoC: timelock 1 d, epoch 30 d, alice 10,000 USDC, operator removed, a fee raise queued.<br>- eta = queue + 31 d for both changes, and the 12x trade stays refused.<br>- At the deadline new risk is refused (`EpochOverdue`) and alice triggers the emergency.<br>- The guardian pays her 9,984.56 (30 days of the 2% fee she accepted). The 5% fee never applies. |
| `test_FIX_GR2_CFG_02_epochRaiseDoesNotLiftAnOverdueEpoch` | The CFG-02 PoC: 2 d / 1 d, the loosening raises E to 30 d, nobody acts.<br>- After the apply the deadline is unchanged and new risk is still refused.<br>- A stranger triggers the emergency and alice is paid in full. |
| `test_FIX_GR2_CFG_control_emergencyInsideTheWindowSurvivesTheApply` | Control: an emergency triggered in [overdue, eta) survives the apply. |
| `test_FIX_GR2_CFG_control_honestLooseningAppliesAfterTheNotice` | Control: an honest loosening on 1 d / 30 d applies after 31 d, with the manager settling on time. |
| `test_FIX_GR2_CFG_tighteningAppliesFromTheNextEpoch` | The XB01 class on Gains: an instant 1-hour tightening does not make the epoch overdue, and the next loosening waits until ceiling + 1 d. |

### 5.2 Results

HLR2-H01 (`results/HLR2-H01.log`; run 2026-10-20 on `audit/hl-r2-fixA` bd8c42b, forge 1.8.4, HL-only build):

| Step | Result |
|---|---|
| Unpatched: the original PoCs (`test_HLR2_H01_`, `_H01b_`, `_E06b_`, `_XB01_`, `test_XB_H01a_`, `_XB_H01b_`) | **6 passed, 0 failed**: the bug exists |
| Unpatched: the suite (`test/**` without the fix dir, Gains removed) | 350 passed, 0 failed, 3 skipped |
| Patched: the fix tests | **10 passed, 0 failed** |
| Patched: the original PoCs | **0 passed, 6 failed**: all six superseded by the inverted fix tests |
| Patched: the suite | 344 passed, 6 failed, 3 skipped. The 6 failures are exactly the six superseded PoCs; no other test fails |
| Sizes (patched) | HyperVault 17,209 B (was 17,156; 7,367 B under EIP-170); VaultPolicy 10,079 (was 9,927); HyperVaultLens 8,758 (was 9,096). `forge build --sizes` exits 1 only because of pre-existing test handlers (`Reaudit2Handler`, `ReauditHandler`, `VaultHandler`), not because of src |

GAINS-GR2-CFG-01 (`results/GAINS-GR2-CFG-01.log`; run 2026-10-20 on `audit/hl-r2-fixA` be44f0f, full build with Gains). `ConfigTimelock.t.sol` was copied unchanged from `audit/gains-r2` ae6c240.

| Step | Result |
|---|---|
| Unpatched: the original PoCs (`test_GR2_CFG_01_timelockShorterThanEpoch_…`, `test_GR2_CFG_02_epochRaiseInLooseningLiftsAnOverdueEpoch`) | **2 passed, 0 failed**: the bug exists |
| Unpatched: the Gains suites (`test/{gains,audit/gains}/**`, including ConfigTimelock) | 386 passed, 0 failed, 21 skipped (fork tests without an RPC) |
| Patched: the fix tests | **5 passed, 0 failed** |
| Patched: the original PoCs | **0 passed, 2 failed**: both superseded by the inverted fix tests |
| Patched: the Gains suites | 384 passed, 2 failed, 21 skipped. The 2 failures are exactly the two superseded PoCs. The CFG controls (`test_GR2_CFG_01_control_…`, `test_GR2_CFG_02_control_…`) still pass |
| Sizes (patched) | GainsVault 19,037 B (was 18,984; 5,539 B under EIP-170); GainsVaultPolicy 13,068 (was 12,936); GainsVaultLens 10,631 (was 10,938). Exit 1 comes from the pre-existing test handlers only. The HL contracts in the same build are unchanged by this patch |

The HL suite was not re-run with the Gains patch, and the Gains suites were not re-run with the HL patch:
- The Gains patch touches only `src/gains/*`.
- The HL patch touches only non-Gains files that Gains imports for constants (`VaultTypes.sol` gets one new constant).
- Both patches `git apply --check` together.
- Assumption: no cross effect. Not run combined.

### 5.3 Existing tests that had to change (deliberate behaviour change)

- **What they had in common.** Every one of these tests queued a change, waited `timelockDelay` (2 days, or the
  vault's delay), then executed or applied it.
- **What changed.** With the fix the eta is one epoch (7 days in every test fixture) plus a day. The tests now warp to
  the eta the contract stored (`queuedEta(id)`, `pendingConfig().eta`, `assetAllowEta(asset)`) instead of computing
  `now + delay`.
- **No assertion weakened.** No assertion about what a change does was weakened. Two assertions on a management fee
  amount changed, because the fee now accrues for 8 days instead of 2 before the raise executes.

HL (`patches/HLR2-H01.tests.patch`: 7 files, 28 lines):
- **The shared helper `Base._timelocked`** (used by `_setAgent`) now reads the eta. That alone fixes:
  - `test_SetAndRevokeAgent`, `test_SwitchingAgentOverwritesSlot`;
  - `test_DailyLossBreachKeepsAgentAndGoesReduceOnlyForTheDay`, `test_SyncAgentRefusedWithoutAgentOrWhileReduceOnly`;
  - `test_DrawdownBreach_untilTheOwnerResumes_peakReset`, `test_GuardianBreachAndEmergencyAreFullStops`;
  - `test_LeverageBreach_reduceOnly_agentKept_clearedByAnyoneOnceBackUnder`,
    `test_RiskBreachEscalatesToAFullStopOnTriggerBreach`;
  - `test_REAUDIT2_N204_oneAgentPerPredictedVault`,
    `test_REAUDIT3_R306_breachSettleSwitchesAPendingRaiseWithoutChargingTheOldRate`;
  - `test_HLR2_D_newGuardianActsOnEveryExistingVaultAtOnce`,
    `test_HLR2_F01_agentApprovalHasNoExpiryFieldAndOnlySyncAgentRenews`.
- **Warp to the stored eta at the call site:**
  - `test_SetAgentRejectedWhileBreached`, `test_ClearBreachGuardianInstantOwnerQueuedAfterBreach`;
  - `test_TimelockedManagerChange`, `test_QueuedChangeExpiresAfterGrace` (eta + grace + 1);
  - `test_LooseningIsTimelocked`, `test_AssetAllowlist`, `test_LooseningExpiresAfterGrace`;
  - `test_OnlyPlatformAgents`, `test_CuratedAssetsOnly`;
  - `test_AUDIT_C01_navDeflationCannotBeSettled`, `test_AUDIT_H01_ownerCannotResetBreachOrRearmInstantly`;
  - `test_REAUDIT_N04_prequeuedClearBreachRejected`, `test_REAUDIT_N07_agentBoundToOneVault`;
  - `test_REAUDIT2_N202_loweringIsImmediateAndCancelsAPendingRaise`,
    `test_HLR2_H03_ownerTimelockedClearUndoesAGuardianStop`.
- **Warp to the eta and change an amount:**
  - `test_AUDIT_M02_feeRaiseInBridgeWindowReverts`: the expected crystallised management fee goes from 164 to
    657.5 USDC (8 days instead of 2, on 1.5M at 2%).
  - `test_REAUDIT2_N202_perfFeeRaiseStartsNextEpoch`: the tolerance on "20% of the pre-raise gain plus a little
    management fee" goes from 200 to 600 USDC (measured 20,387.70).

**Superseded, not changed.** These document the unpatched behaviour and fail with the patch by design. The fix
tests are their inverted forms.
- `test_HLR2_H01_…`
- `test_HLR2_H01b_…`
- `test_HLR2_E06b_ownerLengthensTheWaitTo30Days`
- `test_HLR2_XB01_…`
- `test_XB_H01b_fixSketchBLeavesLateReactingRedeemersExposed`
- `test_XB_H01a_guardianEmergencyInsideTheTimelockGetsTheRedeemerOutAtTheOldRisk`. Its claim still holds (an
  emergency inside the notice survives the apply). It fails only because it applies the loosening at queue + 2 d,
  which is now `NotReady`.

When the fix ships, delete or invert these six in the audit branch.

Gains (`patches/GAINS-GR2-CFG-01.tests.patch`: 13 files, about 50 lines). The fixture is again a 7-day epoch with a 2-day delay.
- **How the patch was made.**
  - Most sites were rewritten mechanically: the queue, then `_skip(2 days)`, `_skip(v.timelockDelay())` or
    `vm.warp(now + 2 days)`, then an execute or apply. They became `_warp(<stored eta>)`. `_warp` refreshes the price
    feeds as `_skip` did.
  - The rewrite script is in the session scratch, not committed; the patch is the record.
  - Six sites were edited by hand: two loops, `_passDeprecated`, the `PolicyMatrix` eta variable, one 3-day skip and
    one `vm.warp`.
  - One rewrite was reverted on purpose. In `test_GOV_TL_duplicateIdRequeueResetsEta…`, the 1-day skip before the
    re-queue is part of what the test checks: a re-queue moves the eta by exactly 1 day, which still holds.
- **Tests changed (50):**
  - `AccessMatrixTest`: `test_accessMatrix_BD`, `BG`, `BL`, `BW`, `DP`, `EM`, `FS`, `N`, `OP`, `SD`, `TP`. The
    setUp's queued `setFeeRecipient` now warps to its eta, so the matrix cell "execute after eta: anyone" is
    measured after the eta again.
  - Assets and curation: `test_AssetAllowlist`, `test_CuratedAssetsOnly`,
    `test_CURATIONSWAP_allowAssetTakesTheFeedCuratedAtExecution`, `test_NavBoundOnInitConfigAndAllowlist`.
  - Breaches and clears: `test_ClearBreachGuardianInstantOwnerQueuedAfterBreach`,
    `test_DailyLossBreachKeepsAgentAndGoesReduceOnlyForTheDay`, `test_DrawdownBreach_untilTheOwnerResumes_peakReset`,
    `test_GuardianBreachAndEmergencyAreFullStops`, `test_LeverageBreach_reduceOnly_agentKept_clearedByAnyoneOnceBackUnder`,
    `test_RiskBreachEscalatesToAFullStopOnTriggerBreach`.
  - Feeds: `test_DeprecatedFeed_settleBlocked_rotate_settleWorks`, `test_FeedSnapshotIsTheVaults`,
    `test_OnlyTheCuratedCombinationIsAccepted`, `test_NAVROTATION_bandCutStepsNavAtAnExecutorChosenMoment`.
  - Governance (`GOV_*`): `test_GOV_02_manyAgentsPerVault_agentOfVaultDesyncs`, `test_GOV_CB_ownerClearVsResumeOnDrawdown`,
    `test_GOV_CB_queuedClearMustPostdateTheBreach`, `test_GOV_CB_queuedClearNeverInEmergency`,
    `test_GOV_FR_queuedRotationFollowsTheCurationAtExecute`,
    `test_GOV_PL_loosening_boundAtApply_tighteningCancelsPending_guardianCannotCancel`,
    `test_GOV_PM_appliersAreAnyoneInTheWindow` (also asserts that allowAsset's eta equals the config's),
    `test_GOV_TL_dirtyBitsNeverExecute`, `test_GOV_TL_duplicateIdRequeueResetsEta_executeWindow_cancel`,
    `test_GOV_TL_failedExecuteKeepsTheItem`.
  - Round 1 PoCs (`GR1_*`): `test_GR1_10_sequencerFeedRotatesThroughTheTimelock`,
    `test_GR1_31_navBoundCoversDisallowedPairs_rotationStaysOpen`.
  - Retests (`GV03`, `HL_*`): `test_GV03_rotationAdoptsWhatWasQueued_notTheFactoryAtExecution`,
    `test_HL_M03_rotationExpires`, `test_HL_N05_lowerFeesCurrentNeverCrystallisesPerformance`,
    `test_HL_R306_leverageBreachSettleKeepsTheRaiseScheduled`.
  - Expiry, eta + grace: `test_LooseningExpiresAfterGrace`, `test_PolicyPendingAndTimelockPaths`,
    `test_QueuedChangeExpiresAfterGrace`.
  - Other timelocked setters: `test_LooseningIsTimelocked`, `test_OnlyPlatformAgents`, `test_SetAgentRejectedWhileBreached`,
    `test_SetAndRevokeAgent`, `test_SwitchingAgentOverwritesSlot`, `test_TimelockedManagerChange`,
    `test_TimelockedSettersAndTheScheduledFeeRaise`, `test_VaultLeverageBoundCheckedAgain`.
  - Also rewritten although they did not fail, in the same pattern: one site each in `GainsBranches.t.sol`,
    `R2Regression.t.sol` and `NavUnit.t.sol`.
- **No amount assertion changed on Gains.**

**Superseded, not changed:** `ConfigTimelock.t.sol::test_GR2_CFG_01_timelockShorterThanEpoch_redeemerTrappedBehindLoosening`
and `::test_GR2_CFG_02_epochRaiseInLooseningLiftsAnOverdueEpoch`, which live on `audit/gains-r2`.

## 6. Storage layout, upgrade path, follow-ups

- **Storage.** New fields are appended at the end:
  - `VaultStorage.epochDeadline` (HL and Gains);
  - `VaultPolicy.epochDeadlineCeiling`, after `_listed`;
  - `GainsVaultPolicy.epochDeadlineCeiling`, after `_feeds`.

  Vaults and policies are EIP-1167 clones of implementations that are `immutable` in each factory. They are not
  upgradeable, and no `delegatecall` goes to a mutable address (HOSTILE-AND-CONFIG 3.6).
- **No upgrade path.** Existing vaults and policies keep the old code for good:
  - HL round 3 [an earlier factory] and round 4 [an earlier factory] (the platform vault);
  - the Gains factory on Arbitrum.

  The fix ships only through new implementations and a **new factory** per venue, with new libraries linked into a
  new vault implementation. Existing vaults need the operational measures from ALERT.md:
  - the guardian alert (mitigation 0);
  - closed launch;
  - for the platform vault: a policy delay of at least `maxEpochDuration + 1 day` and the same vault delay.
- **ABI.** Additions only:
  - `epochDeadline()` on both vaults;
  - `noticeEta()`, `EXIT_MARGIN()` and `epochDeadlineCeiling()` on both policies.

  Nothing is removed. Readers of the old formula `epochStartedAt + maxEpochDuration` must switch to
  `epochDeadline()` for vaults from the new factory:
  - webapp `src/data/chain.ts:208` (fallback when the lens is absent);
  - webapp `src/data/derive.ts:51` (`epochProgress`);
  - webapp `components/vault/VaultCards.tsx:209` (shows the policy length as "Epoch deadline");
  - the Lens is patched.
- **Etas.**
  - The UI that shows a queued item's eta must read `pendingConfig().eta`, `assetAllowEta` and `queuedEta`. It
    must not compute `queue + timelockDelay`.
  - The executor's history rows (`server/src/history/replay.ts`) already read the eta from the events.
- **Webapp launch (do not edit here).** `GainsLaunch.tsx:225` and `LaunchPage.tsx:394` hard-code
  `timelockDelay = 2 days`. With the patch that stays valid. The effective notice becomes
  `max(2 days, epoch + 1 day)`, so the launch form should show that number.
  - Recommended: send `timelockDelay = max(2 days, epochDays * 1 day + 1 day)`, capped at the 30-day
    `MAX_TIMELOCK`.
  - Then what the vault page shows as "timelock" equals the real notice in the common case.
  - For epochs longer than 29 days the notice exceeds the displayed delay. Show `max(timelock, epoch + 1 d)` as
    "changes wait".
  - The copy "so you can leave first" (`depositors.tsx:319`, `overview.tsx:26`) becomes true for the new factory
    only. Old vaults keep the corrected wording from HOSTILE-AND-CONFIG.
- **Executor.**
  - Nothing breaks: queue and execute stay the same calls, only later.
  - Keeper jobs that decide "overdue" off-chain should read `epochDeadline()`.
  - The guardian alert on `ConfigQueued` / `TimelockQueued` / `OperatorSet(0)` (owner decision c) is still wanted:
    it turns the redeemer's self-help into a platform reaction.
- **Factory.** No change needed. Optional: show `noticeEta()` in the factory's or the lens's `status`.

## 7. Residual risk

- **The exit is forced, not fast or fair.**
  - The redeemer still waits for her epoch's deadline (up to 30 days).
  - The emergency settle pays at min(NAV, checkpoint) (HLR2-E01) and needs a platform role to unwind (HLR2-L01).
  - On HL a precompile outage blocks every settle (CONTEXT 7).
- **Reaction window.** A redeemer who asks more than `EXIT_MARGIN` after the queue, after an intervening settle, may
  be inside the new epoch when the change applies. That is the price of a bounded notice. She had a full day and
  the public `ConfigQueued` event.
- **The emergency flatten under a loosened policy.**
  - After the apply, `flatten(asset, 0)` uses the new `maxSlippageBps` (up to 20%) as its default band.
  - Custom slippage stays capped at `maxFlattenSlippageBps` (3%, hard).
  - Who flattens in emergency (manager, operator, guardian) can pick 0. A hostile manager could flatten at a wide
    band. This is not new risk taken; the loss is bounded by the book's depth.
  - Not tested here. Suggested follow-up: in emergency, use `min(maxSlippageBps, maxFlattenSlippageBps)`.
- **Longer honest notices.** A 7-day-epoch vault now waits 8 days to loosen, and a 30-day vault 31 days. This is
  intended.
- **Instant tightening of `E` is still instant for the next epoch.** An owner can set 1 h epochs from the next
  settle. That is a tightening for depositors, and E01's checkpoint-age issue remains E01's.
- **Not proven:**
  - no fuzz or invariant campaign over the notice formula (heavy-tool lock not taken; plain tests only);
  - the 2-contract argument in section 2 is a written proof sketch backed by the scenario tests, not a formal one.
