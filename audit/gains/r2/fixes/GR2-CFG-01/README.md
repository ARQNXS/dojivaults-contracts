# GR2-CFG-01 fix: every loosening timelock outlasts an epoch by a day

**Internal, AI-assisted review. Not an independent audit.** Proposed patch for the fix round; nothing in
`contracts/src` was changed. Patch against 4ec6feb, applies with `git apply` from the repo root (checked with
`git apply --check` on the worktree).

## Rule

`timelockDelay >= maxEpochDuration + EPOCH_TIMELOCK_MARGIN` (1 day) for **both** timelocks that delay a loosening: the
policy's (config, allowAsset, timelock lowering) and the vault's (setManager, setFees, setAgent, setFeeRecipient,
feed rotations). Enforced at every point where either side changes:

| Where | Check |
|---|---|
| `GainsVaultPolicy.initialize` | config's epoch vs the policy timelock (the vault is initialized after the policy and checks its own) |
| `GainsVaultPolicy.proposeConfig` (tightening and queued alike) | new epoch vs the policy timelock and the vault timelock (`IGainsVaultTimelock(vault).timelockDelay()`) |
| `GainsVaultPolicy.applyPendingConfig` | again, both: either timelock may have been lowered since the queue |
| `GainsVaultPolicy.proposeTimelockDelay` (instant raise and queued lowering) | new delay vs the current epoch |
| `GainsVaultPolicy.applyTimelockDelay` | again: a queued epoch raise may have applied first |
| `GainsVaultGovernance.initialize` (vault) | vault timelock vs the policy's epoch |
| `GainsVaultGovernance.setTimelockDelay` (vault, timelocked) | new vault timelock vs the policy's epoch (the execute reverts `CallFailed(InvalidTimelock)`) |

New error on the policy: `EpochAboveTimelock(maxEpochDuration, timelockDelay)`; the vault reuses `InvalidTimelock()`.
The factory needs no change: `create` initializes both and inherits the checks.

## Why these choices

- **Margin of 1 day.** With `T >= E` alone, a redeemer who asks right after a queue made at an epoch start reaches
  "overdue" in the same second the loosening becomes executable: the owner can put `applyPendingConfig` first in the
  block (CONFIG.md "race"). The margin is the redeemer's (or the guardian's) reaction time between overdue
  (anyone's `triggerEmergency`, the platform's exit-only settle) and the loosening's eta. One day is the minimum notice
  the timelock itself guarantees (`MIN_TIMELOCK`), and the live vault (T = 2 days, E = 1 day) meets it exactly, so the
  live shape is unchanged.
- **Consequences of the bounds:** `MIN_TIMELOCK` (1 day) is reachable only with no epoch at all, so the smallest
  usable timelock is E + 1 day ≥ 25 h; the longest epoch is 29 days (T ≤ 30 days). The webapp's fixed 2-day timelock
  allows epochs of at most 1 day: the launch form must either cap the epoch at T − 1 day or raise T.
- **The vault's own timelock needs the same rule.** `setFees` (management fee raise applies at execution) and
  `setManager` / `setAgent` are loosenings behind the vault timelock; with vault T < E a pre-queue redeemer is exposed to
  them exactly as to a policy loosening. Since the vault timelock is set by the vault and the epoch by the policy, the
  policy reads the vault's timelock on every epoch change, and the vault reads the policy's epoch on every timelock
  change.
- **GR2-CFG-02 is closed by this rule for every epoch that was running at the queue:** a loosening can raise E only to
  E_new ≤ T − 1 day, so at its eta (queue + T) any epoch that started before the queue is past start + E_new: it stays
  overdue. The only remaining edge is an epoch started after the queue (a settle inside the window) that the raise
  extends, which is not an overdue epoch. The KEY-06 patch (epoch deadline fixed at the epoch's start) closes CFG-02
  completely; its fix test `test_KEY06_fix_CFG02_epochRaiseDoesNotLiftAnOverdueEpoch` covers it. The two patches share
  one file (`GainsVaultGovernance.sol`, different hunks) and apply together (see `../COMBINED.md`).

## Side effects

- Harness: `test/gains/GainsBase.t.sol::_defaultRisk` used `maxEpochDuration: 7 days` with 2-day timelocks, which the
  rule refuses (every setUp would revert). The patch sets it to **1 day** (the live shape). An alternative harness
  (timelocks 8 days, epoch 7 days) was run and rejected: 88 failures instead of 19 (literal 2-day skips everywhere).
- Executor / webapp: the launch form and any config UI must respect T ≥ E + 1 day; alert on policy `ConfigQueued`,
  `AssetAllowQueued`, `TimelockQueued` (unchanged recommendation).

## Fix test

`FixTest.t.sol` (`CFG01FixTest`, runs from `contracts/test/audit/gains/r2/fixes/`). Reverts are checked with
selector-free `vm.expectRevert()` so the file compiles on 4ec6feb.

| Test | Asserts | Unfixed | Fixed |
|---|---|---|---|
| `test_CFG01_fix_factoryRefusesTimelockBelowEpochPlusMargin` | `create` refuses the ConfigTimelock PoC launch (T 1 d, E 30 d) and T/E = 2d/7d, 2d/2d, 1d/1h, 30d/30d; accepts 2d/1d (live) and 30d/29d | FAIL | PASS |
| `test_CFG01_fix_liveShapeCannotRaiseTheEpochAboveTheTimelock` | live shape: `proposeConfig` with E = 30 d (the XR live-reachability step, also CFG-02's loosening) and E = 1 d + 1 s refused; a loosening without an epoch raise still queues | FAIL | PASS |
| `test_CFG01_fix_policyTimelockChangesKeepTheMargin` | `proposeTimelockDelay` below E + 1 d refused; a lowering queued before an epoch raise applied is refused at `applyTimelockDelay` | FAIL | PASS |
| `test_CFG01_fix_queuedEpochRaiseRecheckedAtApply` | an epoch raise queued before a timelock lowering applied is refused at `applyPendingConfig` | FAIL | PASS |
| `test_CFG01_fix_vaultTimelockKeepsTheMargin` | vault `initialize` with vault T < E + 1 d refused; `setTimelockDelay` below it fails at execute; a policy epoch raise above vault T − 1 d refused even with policy T = 30 d | FAIL | PASS |

## Existing tests (harness E = 1 day)

Regression run in the patched scratch tree (40 suites, 405 tests): **386 pass, 19 fail**.

| Group | Tests | What the fix round does |
|---|---|---|
| Round 2 CFG PoCs (assert the bug; their launches/raises are now refused) | `r2/ConfigTimelock.t.sol::test_GR2_CFG_01_timelockShorterThanEpoch_redeemerTrappedBehindLoosening`, `test_GR2_CFG_02_epochRaiseInLooseningLiftsAnOverdueEpoch`, `test_GR2_CFG_02_control_emergencyInsideTheWindowSurvivesTheApply`; `r2/XReviewEconCfg.t.sol::test_GR2_XR_CFG01_liveShapeReachesTimelockBelowEpochInOneQueue`, `_guardianEmergencyAnyTimeFreesRedeemerBeforeEta`, `_guardianRescueAfterApplyBeforeTheMove`, `_sentinelFullStopRemovesTheRiskButNotTheLock` | retire (replaced by this fix test) |
| Tests using a 1-day timelock with the 1-day default epoch | `gov/FactoryMatrix.t.sol::test_GOV_FM_clonesInitializeOnce_policyBoundToItsVault`, `gov/PolicyMatrix.t.sol::test_GOV_PM_appliersAreAnyoneInTheWindow`, `r2/ConfigLevers.t.sol::test_GR2_CFG_cancelRights`, `test_GR2_CFG_graceWindowsAllFourQueues`, `test_GR2_CFG_vaultAndPolicyTimelocksAreIndependent`, `fixes/R1Regression.t.sol::test_MUT753_applyTimelockDelayClearsThePending`, `gains/GainsBranches.t.sol::test_PolicyPendingAndTimelockPaths`, `gains/GainsPolicyAndFactory.t.sol::test_TimelockDelayLoweringIsTimelocked` | use E = 1 h with a 1-day + 1 h timelock, or T = 2 days |
| `r2/ConfigLevers.t.sol::test_GR2_CFG_isTighterFieldByField` | loosens E by 1 s past T − 1 d | loosen E inside the bound |
| Tests that need an epoch longer than 1 day | `xreview/XReview.t.sol::test_GR1_02_intradayCyclesNoLongerTakeFromTheHolder`, `R1PoC.t.sol::test_GR1_04_holdingOrderBlocksAtMostOneTimeout`, `r2/LivenessStateMachine.t.sol::test_LIVE_SM_O1_holdingOrder_oneTimeout_thenPausedUnbounded` (`EpochOverdue`) | give these vaults E = 7 days with T = 8 days (local `_vaultWith`) or settle inside the day |

Raw output: `run-unfixed.txt`, `run-fixed.txt` (fix test, the regression run, and the rejected harness's summary).
