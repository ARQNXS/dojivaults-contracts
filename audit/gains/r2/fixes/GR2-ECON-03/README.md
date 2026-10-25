# GR2-ECON-03 fix: charge the performance fee in a leverage-breach settle

**Internal, AI-assisted review. Not an independent audit.** Proposed patch for the fix round; nothing in
`contracts/src` was changed. Patch against 4ec6feb, applies with `git apply` from the repo root (checked with
`git apply --check` on the worktree).

## What changes

`fix.diff` (built from the cross-reviewer's `../../xr-econ-cfg/econ03-fix.diff`, cleaned up):

| File | Change |
|---|---|
| `GainsVaultLogic.sol` settle | `withPerformance = !$.emergency && !redemptionOnly` (redemptionOnly = `_lossBreach($)`). The fee charge (`_accrueFees`) and the scheduled-raise switch both use it. Before: `!$.breached && !$.emergency`. NatSpec rewritten. |
| `GainsVaultLens.sol` `pendingFeeShares` | Same condition: no performance fee only in a daily-loss / drawdown breach or in emergency. |
| `test/audit/gains/gov/HLRetest.t.sol` | `test_HL_R306_leverageBreachSettleKeepsTheRaiseScheduled` inverted and renamed `test_HL_R306_leverageBreachSettleSwitchesTheRaiseLikeANormalSettle` (the raise switches, perf fee 3,000). |

Which settles charge the performance fee after the patch:

| Settle | Mints deposits | Performance fee | Raise switch |
|---|---|---|---|
| Normal | yes | yes | yes |
| Leverage breach (normal mode) | yes | **yes (was no)** | **yes (was no)** |
| Daily loss / drawdown breach (redemption-only) | no | no | no |
| Emergency (exit-only) | no (refunds) | no | no |
| Overdue exit-only by a platform role, no breach | no (refunds) | yes (unchanged) | yes (unchanged) |
| Overdue exit-only in a leverage breach | no (refunds) | yes (was no) | yes (was no) |

## Why

A leverage breach is a normal (minting) settle: before the patch new depositors bought in at a price that still
contained the uncrystallised gain and paid the fee on it at the next normal settle (EconPoC: bob 100k, −1,438 USDC). The
manager can cause the breach at will (one open at exactly 5x). The fee must be charged whenever deposits are minted.
The C-01 reason for skipping it (a possibly deflated NAV) applies only to loss breaches, which stay fee-free, and
R3-06 (no raise switch without a charge) is kept by using the same condition for both.

## Side effects

- A leverage-breach settle now moves the high water mark and rescales the risk references (fee dilution), like a
  normal settle. Leverage itself is unchanged by the fee mint.
- The last row of the table above: an exit-only settle in a leverage breach after the epoch is overdue now charges the
  fee, exactly as the same settle without the breach always did. Nobody is minted in it, so it is neutral for ECON-03;
  the fix round may prefer `!exitOnly` in the condition as well (one more term), which would also stop the overdue
  no-breach exit-only settle from charging. Not done here: it changes behaviour outside the finding.
- HyperEVM `VaultLogic.sol:226` has the identical rule; out of scope, not patched or tested.
- Docs to update in the fix round: KNOWN-ISSUES I3-08, the NatSpec at GainsVaultLogic.sol:248 (done in the patch),
  REAUDIT3 / HL-RETEST references to R3-06's leverage case.

## Fix test

`FixTest.t.sol` (`ECON03FixTest`, runs from `contracts/test/audit/gains/r2/fixes/`):

| Test | Asserts | Unfixed (4ec6feb) | Fixed |
|---|---|---|---|
| `test_ECON03_fix_leverageBreachSettleChargesThePerformanceFeeBeforeMinting` | EconPoC scenario: HWM moves and fee shares are minted in the breach settle; bob's and the fee recipient's USDC equal the no-breach control (±1 USDC) | FAIL (HWM 1,000,000) | PASS |
| `test_ECON03_fix_leverageBreachSettleSwitchesTheScheduledRaise` | a scheduled 3,000 bps raise switches in a leverage-breach settle | FAIL (3000 != 0) | PASS |
| `test_ECON03_fix_lensPreviewsThePerformanceFeeInALeverageBreach` | lens `pendingFeeShares` > 0 and equals the fee shares settle mints | FAIL (0) | PASS |
| `test_ECON03_fix_lossBreachSettleStillChargesNoPerformanceFee` | daily-loss breach settle: no fee shares, HWM kept, raise kept, lens 0 | PASS (regression guard) | PASS |
| `test_ECON03_fix_emergencySettleStillChargesNoPerformanceFee` | emergency settle: same | PASS (regression guard) | PASS |

Raw output: `run-unfixed.txt` (4ec6feb) and `run-fixed.txt` (patched, plus the regression run).

## Existing tests

Regression run in the patched scratch tree: 40 suites, 405 tests (every Gains mock suite: GainsVault, GainsRound4,
GainsExits, GainsPolicyAndFactory, GainsAdmin, GainsPositions, GainsBranches, GainsFlattenBatch, GainsFeedRotation,
gov/HLRetest, Governance, PolicyMatrix, FactoryMatrix, OperatorBound, fixes/R1Regression, R2Regression, R1PoC,
AccessMatrix, NavUnit, VerifyR2Mock, XReview, IntegrationMock, r2/EconPoC, ConfigTimelock, XReviewEconCfg, XReviewKey,
LivenessStateMachine, XReviewLiveGnsStateMachine, FundFlowR2, ConfigLevers and the five fix tests): **404 pass, 1 fail**.

| Test | With the patch | What the fix round does |
|---|---|---|
| `gov/HLRetest.t.sol::test_HL_R306_leverageBreachSettleKeepsTheRaiseScheduled` | would fail | inverted in the patch (passes) |
| `r2/EconPoC.t.sol::test_GR2_ECON_03_leverageBreachSettleChargesNewDepositorForOldGains` | FAIL (expected: the PoC asserts the bug) | retire, or invert to `ECON03FixTest`'s first test |

`r2/XReviewEconCfg.t.sol::test_GR2_XR_ECON03_managerForcesLeverageBreachAtWill_noPriceMove` still passes (its vault
has no gain above the HWM, so "HWM unchanged" holds either way); its comment "no performance fee in this settle"
becomes stale.
