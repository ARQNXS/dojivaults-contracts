# HL finding classes retested on Gains (sub-reviewer 3.4 / 3.6, round 1)

One row per HL id from hl-history.md section 3 (contracts) and 3.7 (server). Verdict: **holds** (the HL fix or the
accepted behaviour carries over and is shown by the test), **regressed** (the class reappears on Gains), **N/A** (the
HyperCore mechanism does not exist on Gains; the Gains analog, if any, is named), **open** (not proven either way here,
handed to the named domain). Tests: `gov/` = `contracts/test/audit/gains/gov/`, `gains/` = `contracts/test/gains/`.

Counts: see the summary at the end.

## Round 1 (REPORT.md)

| Id | Verdict | Evidence / one line |
|---|---|---|
| C-01 | holds (residual) | Insider deferral + checkpoint bound + redemption-only loss-breach settle copied 1:1. `gains/GainsRound4.t.sol::test_D4_C01_noMintAtADeflatedNav`. Residual: maxNavMoveBps can be raised to 100% instantly by the owner (N-03 direction), `gov/Governance.t.sol::test_GOV_PL_instantLevers`. NAV-side candidates (cliff, band) are 3.1 / lead NAVBIAS. |
| H-01 | holds | The owner's instant levers are exactly: setOperator, unpause, cap, lowerFees, policy tightening (incl. maxNavMoveBps up, maxEpochDuration down), disallowAsset, policy timelock raise, triggerBreach / triggerEmergency. clearBreach / setAgent / exitEmergency / setManager / setFees / setPairFeed are not instant. `gov/HLRetest.t.sol::test_HL_H01_ownerInstantPowersAreTheListedOnes`, `gov/Governance.t.sol::test_GOV_PL_instantLevers`. The instant tightenings become a griefing lever in the hands of a previous owner: GOV-03. |
| H-02 | open (3.2 / lead) | Analog = keeping `ordersPending()` true. Lead PoC PENDINGGRIEF (manager in emergency). Not re-proven here. |
| M-01 | open (3.1) | Analog: pending UPDATE_LEVERAGE / partial close valuation, day roll timing. For the operator bound only: a pending partial close counts as returned collateral, `gov/OperatorBound.t.sol::test_GOV_OB_concurrentReducesInOneBlockStayWithinOneCap`. |
| M-02 | holds | Timelocked setFees crystallises the old management rate first; a stale feed reverts the execute (never skips accrual) and the item stays queued. `gov/Governance.t.sol::test_GOV_TL_failedExecuteKeepsTheItem`. |
| M-03 | holds | 14 day grace on vault execute (incl. setPairFeed), policy config, allowAsset, timelock delay. `gov/Governance.t.sol::test_GOV_TL_duplicateIdRequeueResetsEta_executeWindow_cancel`, `gov/PolicyMatrix.t.sol::test_GOV_PM_appliersAreAnyoneInTheWindow`, `gov/HLRetest.t.sol::test_HL_M03_rotationExpires`. |
| M-04 | open (3.3 / lead) | Lead FLATTENSLIP (flatten slippage 0 = maxSlippageBps <= 20%). Note from 3.4: Gains' close slippage check is one-sided vs the caller's expectedPrice, so the slippage value cannot force a bad fill, only a cancel (GOV-01 cost per cancel). |
| M-05 | holds | Perf fee only in settle; `gains/GainsVault.t.sol::test_PerformanceFeeAboveHighWaterMark`; HWM unchanged by lowerFees in `gov/HLRetest.t.sol::test_HL_N05_*`. |
| L-01 | N/A | Notional = collateral x leverage, price independent. Analog (open notional at mid vs order notional) belongs to 3.1. |
| L-02 | open (3.1) | Lens previews vs overdue exit-only settle (hl-history hypothesis), not retested here. |
| L-03 | holds | `gains/GainsRound4.t.sol::test_R01_feeMintsDoNotMoveTheMetrics`, `testFuzz_R01_flowsNeverMoveTheMetrics`. |
| L-04 | N/A | No bridge window / snapshot. |
| L-05 | open (3.1) | Per-trade floor at 0; NAV domain. |
| L-06 | N/A | No Core account; the agent is a vault caller. Analog: `gov/HLRetest.t.sol::test_HL_I08_noVenueSideAuthoritySurvivesARevoke`. |
| I-01 | holds | `ProtocolShareLowered` emitted by vault and factory; exercised in `gov/FactoryMatrix.t.sol::test_GOV_FM_ownerOnlySetters`. |
| I-02 | holds | `gains/GainsPolicyAndFactory.t.sol::test_ImplementationFitsEip170`. |
| I-03 | holds (vault, factory) / see GOV-04 (policy) | `gov/HLRetest.t.sol::test_HL_I03_V03_renounce`. The policy keeps OZ renounceOwnership: GOV-04 (`gov/Governance.t.sol::test_GOV_04_*`). Same on HL VaultPolicy. |
| I-04 | open (3.1) | Lead SEEDGIFT. |
| I-05 | holds (accepted) | Rounding directions unchanged (diffed). Backing invariant `gains/GainsRound4Invariants.t.sol::invariant_sharesAndAssetsAccounting`. |
| I-06 | holds (accepted) | Creator still picks operator, fee recipient and vault owner, unchecked against platform roles. `gov/HLRetest.t.sol::test_HL_I06_creatorMayNameThePlatformSentinelOperator`. |
| I-07 | holds (by design) | Stranger triggerEmergency only when overdue with redemptions: `gov/HLRetest.t.sol::test_HL_R303_*` (NotOverdue), `gov/Governance.t.sol::test_GOV_03_*` (overdue => stranger triggers). |
| I-08 | N/A | Revoke is a storage write; no Gains delegate is ever set. `gov/HLRetest.t.sol::test_HL_I08_*`. |
| D-1 | holds, sharper | Agent bounded by checkOrder for new risk, but exits are unbounded in count: GOV-01 (agent grinds collateral into min fees in any state, `gov/OperatorBound.t.sol::test_GOV_01_agentGrindsEvenInADailyLossBreach`). |
| D-2 | open (3.1) | Chainlink + band replaces marks. |
| D-3 | holds | Guardian / sentinel read live from the factory. `gov/HLRetest.t.sol::test_HL_N06_guardianRotatedMidEmergency`. |
| D-4 | open (3.2) | Bot-triggered orders invisible to getPendingOrders (gains-diamond-research Q9). |
| D-5 | N/A here (3.7) | Executor key custody. |

## HyperCore assumptions (A-01 .. A-14)

| Id | Verdict | One line |
|---|---|---|
| A-01 | N/A (3.5) | Analog: IGainsDiamond layouts vs facets (fork decode). |
| A-02 | N/A (3.5) | Analog: 1e10 prices / 1e3 leverage / collateral precision. |
| A-03 | N/A (3.5) | Same. |
| A-04 | N/A (3.1 / 3.5) | Analog: feed failure modes; GainsPrice returns named errors (`gains/GainsBranches.t.sol::test_PriceRejectsEveryMalformedAnswer`). New governance gap: the sequencer feed cannot be rotated, GOV-06. |
| A-05 | N/A (3.5) | Analog: Gains fee formulas; min closing fee 0.10 USD is what GOV-01 exploits. |
| A-06 | N/A (3.5) | Encoding of diamond calls. |
| A-07 | N/A | No bridge; payouts go to trade.user (research Q10). |
| A-08 | N/A (3.2) | Market-order latency. |
| A-09 | N/A (3.2) | Timeout 200 blocks. |
| A-10 | N/A | No agent names. |
| A-11 | N/A | No account abstraction. |
| A-12 | N/A (3.5) | Only the trader acts on its trades; `test_HL_I08_*` shows no delegate. |
| A-13 | N/A | No Core account. |
| A-14 | N/A (3.3) | Diamond calls revert synchronously (flatten try/catch). |

## Round 2 (REAUDIT.md)

| Id | Verdict | One line |
|---|---|---|
| N-01 | N/A | No snapshot / window; settle refuses on any pending order. |
| N-02 | open (3.3 / lead) | Emergency settle reads prices: a stale pair feed or a dead sequencer feed blocks every settle mode until the exposed trades are closed. The sequencer half is GOV-06 (no rotation at all); exits stay open, so not a permanent lock. |
| N-03 | holds | Direction (raising maxNavMoveBps is the tightening), floor 500. `gov/HLRetest.t.sol::test_HL_N03_navMoveDirectionAndFloor`. NAV bound on leverage re-checked at both stages: `gov/Governance.t.sol::test_GOV_PL_loosening_boundAtApply_*`; gap for disallowed pairs: GOV-05. |
| N-04 | holds | Exact lengths, dirty bits never execute, queuedAt > breachedAt strictly, daily auto-clear then new breach, emergency. `gov/Governance.t.sol::test_GOV_TL_queue_*`, `test_GOV_TL_dirtyBitsNeverExecute`, `test_GOV_CB_*`. Owner clear vs resume on drawdown: no bypass (`test_GOV_CB_ownerClearVsResumeOnDrawdown`). |
| N-05 | holds | `gov/HLRetest.t.sol::test_HL_N05_lowerFeesCurrentNeverCrystallisesPerformance`. |
| N-06 | holds | `gov/HLRetest.t.sol::test_HL_N06_guardianRotatedMidEmergency`. |
| N-07 | holds for binding / see GOV-02 | Binding per vault holds (an agent bound elsewhere is refused, `gains/GainsPolicyAndFactory.t.sol::test_OnlyPlatformAgents`). "One agent per vault" does not hold for existing vaults and agentOfVault desyncs: GOV-02 (`gov/HLRetest.t.sol::test_GOV_02_*`). Same code on HL. |
| N-08 | holds | HWM only with perf; `test_HL_N05_*` asserts the HWM does not move. |
| N-09 | holds (accepted) | Same insider rule (manager, owner, fee recipient); sybil bypass accepted. |
| N-10 | holds (superseded) | Guardian stop: settle ReduceOnlyMode. `gov/HLRetest.t.sol::test_HL_N10_I202_settleGates`. |
| N-11 | holds | Code identical (`depShares == 0 => depIn = 0`); NAV domain retest by 3.1. |
| N-12 | holds | Self checkpoint on the first settle (`GainsVault.settle`), identical nextCheckpoint (`gains/GainsPolicyAndFactory.t.sol::test_CheckpointRule`). |
| N-13 | holds (accepted) | Lowering maxDepositCap / de-curating reaches no existing vault. `gov/FactoryMatrix.t.sol::test_GOV_FM_maxDepositCap_lowerLaterAndZero`, `gains/GainsPolicyAndFactory.t.sol::test_FeedSnapshotIsTheVaults`. |
| N-14 | holds | EIP-170, as I-02. |
| N-15 | open (3.1) | Lens preview in overdue exit-only settle. |
| R-1 | holds (residual) | Bounded NAV deflation by a trusted trader; on Gains the manager trades too (D1). 3.1 quantifies. |

## Round 3 (REAUDIT2.md)

| Id | Verdict | One line |
|---|---|---|
| N2-01 | holds | Claims O(1), one epoch per request (code identical, diffed). |
| N2-02 | holds | `gains/GainsAdmin.t.sol::test_TimelockedSettersAndTheScheduledFeeRaise`. |
| N2-03 | holds / changed | Custom flatten capped at 300 bps; no colluding counterparty on Gains. Slippage only gates cancels (one-sided vs caller's expectedPrice). |
| N2-04 | holds | Nonce-free but single-use by state: replay across vaults, creators, factories, chains and after unregister all fail. `gov/FactoryMatrix.t.sol::test_GOV_FM_sig_replayAcrossVaultsFactoriesChains`, `test_GOV_FM_sig_expiryMalleabilitySigner`. |
| I2-01 | holds (documented) | `gov/Governance.t.sol::test_GOV_CB_I201_rebreachInvalidatesOwnerClear`. |
| I2-02 | holds (superseded) | Stranger / depositor cannot settle: `gov/HLRetest.t.sol::test_HL_N10_I202_settleGates`. |
| I2-03 | holds | Registrar cannot revoke a live agent: `gov/FactoryMatrix.t.sol::test_GOV_FM_unregisterPlatformAgent_cells`. |
| I2-04 | holds | Self checkpoint in GainsVault.settle; `gov/OperatorBound.t.sol` settles a fresh factory vault without a prior keeper checkpoint in `_fundFv` (checkRisk then settle). |
| I2-05 | holds | `gov/FactoryMatrix.t.sol::test_GOV_FM_ownershipAndRoleCollisions_pendingOwnerIncluded`. Operator / agent / vault owner not part of the check (I-06). |
| I2-06 | holds (operational) | DeployGains.s.sol `_setup` ends with `transferOwnership(guardian)` (two step). |

## Verification (VERIFY.md)

| Id | Verdict | One line |
|---|---|---|
| V-01 | holds | Partial fill + return identical (diffed); `gains/GainsVault.t.sol::test_EmergencySettlePaysProRataAndRefundsDeposits`. |
| V-02 | N/A here (3.7) | Server nonce store. |
| V-03 | holds | Pending-owner collision checks and factory renounce: `test_GOV_FM_ownershipAndRoleCollisions_pendingOwnerIncluded`, `test_HL_I03_V03_renounce`. Policy renounce open: GOV-04. |
| V-04 | holds (residual I3-04) | Registrar cannot pre-bind a predicted address: `gov/FactoryMatrix.t.sol::test_GOV_FM_create2SaltScopedNoFrontRun`, `test_GOV_FM_registerPlatformAgent_cells`. |
| W-01 | holds | Owner has no exit path (direct, queued): `gov/HLRetest.t.sol::test_HL_W01_ownerHasNoExitPath`. |
| W-01b | holds (guardian-only exit) | Same test; the last-epoch gate is VG-1. |
| X-01 | N/A | No bridges; analog H-02 (open, lead). |
| VG-1 | holds (operational) | exitEmergency checks the last epoch only (code identical). |
| VG-2 | N/A | No Core HYPE; cancelTimedOut spends nothing of the vault (Gains timeout cancels are free, research Q4). |
| VG-3 | open (lead) | Harness review of GainsRound4Invariants. |
| VG-4 | holds (cosmetic) | Lens partialFill identical. |

## Round 4 (REAUDIT3.md, VERIFY-ROUND3.md)

| Id | Verdict | One line |
|---|---|---|
| R3-01 | N/A | No landing signal; analog = getPendingOrders exactness (3.2). |
| R3-02 | holds | `gains/GainsRound4.t.sol::test_R302_insiderAgeNeverDelaysExits`, `gains/GainsVault.t.sol::test_InsiderDepositsArePricedInTheNextEpoch`. |
| R3-03 | holds | `gov/HLRetest.t.sol::test_HL_R303_secondEmergencyInvalidatesClearQueuedAfterTheFirst`, `gains/GainsRound4.t.sol::test_R303_retriggerRestartsBreachedAt`. |
| R3-04 | holds | Margin add refused in a loss breach (`gains/GainsRound4.t.sol::test_R304_marginStillAllowedInALeverageBreach`); outside a breach the manager can still spend idle that pending redemptions need, recoverable by the operator without the manager: `gov/HLRetest.t.sol::test_HL_R304_idleOfPendingRedemptionsIntoMarginRecoverableByOperator`. |
| R3-05 | N/A | Analog: an unfilled order blocks settle until cancelTimedOut (anyone), 3.2. |
| R3-06 | holds | `gov/HLRetest.t.sol::test_HL_R306_leverageBreachSettleKeepsTheRaiseScheduled`. |
| R3-07 | open (3.1) | Lens perf gate in breach / overdue. |
| R3-08 | N/A | Analog slow fill valued at collateral - gov fee (3.1). |
| I3-01 | holds (documented) | Same day roll and resume peak reset (code identical). |
| I3-02 | holds, doc wrong | Insider 10 USDC deposit for `controller = victim` blocks the victim's requestRedeem; KNOWN-ISSUES says "until cancel or settle" but cancel does NOT lift it (the request keeps epoch = current + 1): GOV-07, `gov/HLRetest.t.sol::test_HL_I302_insiderDepositForVictimBlocksItsRedeemUntilSettle`. Same code on HL. |
| I3-03 | N/A | No landing signal; donations only raise idle. |
| I3-04 | holds (residual) | Registrar still signs launches; signature not bound to creation params (`hosted`, policy). |
| I3-05 | holds (changed by decision) | `setMaxDepositCap` unbounded; DeployGains defaults MAX_DEPOSIT_CAP to type(uint256).max (no-platform-limit decision of 2026-10-13); KNOWN-ISSUES' "script refuses above 50,000" no longer true for Gains. maxDepositCap = 0 freezes every vault's setDepositCap (`test_GOV_FM_maxDepositCap_lowerLaterAndZero`). |
| I3-06 | open (lead) | Gains insider invariant should compare timestamps. |
| I3-07 | holds | `gains/GainsRound4.t.sol::test_D2_insiderDelayGriefingCostsTenUsdc`. |
| I3-08 | holds (accepted) | No perf fee in breach settles (code identical). |
| R3-01 res.1 | N/A | Analog: trader makes closes fail (expectedPrice) to keep settle blocked, 3.2 / lead. |
| OPS-1 | N/A here (3.7) | Executor retry idempotency. |

## Server / executor (out of contract scope; sub-reviewer 3.7)

| Id | Verdict |
|---|---|
| S-01 .. S-17 | N/A here (3.7) |
| SN-01 .. SN-09 | N/A here (3.7) |

(26 ids.)

## Summary

Contract ids (96): holds 54 (incl. "holds, sharper", "holds, doc wrong", residual / accepted / documented / operational),
regressed 0, N/A 29 (D-5, V-02, OPS-1 are executor items for 3.7), open (handed to another domain) 13. Server ids (26): N/A here (3.7).
