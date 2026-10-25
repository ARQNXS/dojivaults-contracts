# hl-r2: past fixes and their regression tests (sub-review: mutation / past fixes / Halmos)

**Internal, AI-assisted review. Not an independent audit.** Branch `audit/hl-r2-mut`, code under review `contracts/src`
(non-gains) unchanged since the round 4 deploy. Nothing deployed, no transaction sent.

## Question

For every past finding whose fix is in the contracts: does its regression test still exist, does it pass on the
current code, and does it FAIL when the fix is reverted? A fix whose test does not catch its own revert is a finding.

## Method

- Inventory: every finding in `contracts/audit/REPORT.md`, `REAUDIT.md`, `REAUDIT2.md`, `REAUDIT3.md`, `VERIFY.md`,
  `VERIFY-ROUND3.md`, `FIXES.md`, `A13-SYNC-AGENT.md`, `hl-open/` and `docs/audit-pack/`, `docs/security/REVIEW-SUMMARY.md`
  (51 fixes with a contract change: every Critical, High and Medium, every fix that touches fund flow, and the Low /
  Info fixes that change behaviour). The machine-readable inventory is `mut-tool/inventory.json`.
- One revert mutant per fix element (66 in total, `mut-tool/pastfix.json`): the fixed line put back the way the
  finding describes the bug (a guard deleted, a bound removed, the old formula). Each revert is compiled into the same
  mutant-schema build as the mutation campaign (MUTATION.md: one build, every mutant guarded by `block.chainid`), so
  each revert runs with `forge test --chain-id 1_000_000 + id` against an otherwise unchanged program.
- Step 1: run the finding's own closing test(s) on the revert (`--match-test`). Step 2: if they pass, run the whole
  non-gains suite (unit + PoC, then the invariant suites) on it. Step 3: if nothing catches it, write a kill test in
  `contracts/test/audit/hl-r2/mut/` and check it against the revert.
- Build profile for all of this (assumption, written down): via-IR with the optimizer off (`optimizer_steps = ":"`,
  stack allocation on), fuzz 64 runs, invariants 16 runs x 50 depth (the inline 512 x 200 configs were lowered in the
  scratch copy only). This changes no test logic; it makes the suite fast enough to run once per mutant. It does make
  five tests fail on the unmodified program for build reasons only (`test_ImplementationFitsEip170`: unoptimized
  bytecode is 59,603 B; `test_REAUDIT2_N201_claimGasIsConstantAcross1000EmergencyEpochs` and `invariant_reaudit2`:
  gas ceilings tuned to optimized code; two `*Reachable` tests are skipped in the emergency suite and share a name).
  Those five are excluded from every mutant run; everything else (270 tests) passes on the unmodified program. The
  full optimized suite is the lead's run.
- "Exists": the test is in the tree today. "Passes": it passes on the unmodified program in the run above.

## Summary

| | Count |
|---|---|
| Fixes inventoried (with a contract change) | 51 |
| Revert mutants | 66 |
| Closing tests that exist and pass on the current code | all 51 (N-11 has no named test; N2-01's gas test needs the optimized build) |
| Reverts caught by the finding's own closing test | 58 |
| Reverts NOT caught by their own test | 8: M-01b, L-04, N-11, N2-04 (create half), R-02 (latch), V-03 (transferOwnership half), W-01 (as written), A-13 (sync gate) |
| ... caught by another test of the suite | 2: L-04 (by `test_SeedBridgedToCoreSpotThenHypeForwarded`; its own test is stale), R-02 latch (by `test_lateLandingIsNotALoss`) |
| ... equivalent (no reachable behaviour change) | 2: W-01 as written (the faithful revert, owner may exit directly, IS caught), A-13 sync gate |
| ... a real regression gap: nothing in the suite catches the revert (finding HLR2-M08) | **4: M-01b, N-11, N2-04 (create half), V-03 (transferOwnership half)**; each is now killed by a new test |


## Table (every revert mutant)

| Finding | Sev | Class | Closing test(s) | Revert mutant (#id, where) | Closing tests on the revert | Whole suite on the revert | Verdict |
|---|---|---|---|---|---|---|---|
| C-01 | Critical | NAV manipulation / pricing at a deflated NAV | test_AUDIT_C01_navDeflationCannotBeSettled, test_AUDIT_C01b_legitimateMovesSettleThroughTheRatchet, test_D4_C01_noMintAtADeflatedNav, test_InsiderDepositsArePricedInTheNextEpoch | C-01a (#1749) `VaultPolicy.sol:241`: settle NAV bound removed | killed: test_AUDIT_C01_navDeflationCannotBeSettled | n/a (caught) | caught by its own test |
| C-01 | Critical | NAV manipulation / pricing at a deflated NAV | test_AUDIT_C01_navDeflationCannotBeSettled, test_AUDIT_C01b_legitimateMovesSettleThroughTheRatchet, test_D4_C01_noMintAtADeflatedNav, test_InsiderDepositsArePricedInTheNextEpoch | C-01b (#1750) `VaultPolicy.sol:240`: checkpoint max age removed | killed: test_CheckpointRule | n/a (caught) | caught by its own test |
| C-01 | Critical | NAV manipulation / pricing at a deflated NAV | test_AUDIT_C01_navDeflationCannotBeSettled, test_AUDIT_C01b_legitimateMovesSettleThroughTheRatchet, test_D4_C01_noMintAtADeflatedNav, test_InsiderDepositsArePricedInTheNextEpoch | C-01c (#1751) `VaultLogic.sol:55`: insider deposits priced in the current epoch | killed: test_D2_insiderDelayGriefingCostsTenUsdc, test_HLO_N09_confederatePricedNowManagerSettlesAtWill, test_InsiderDepositsArePricedInTheNextEpoch | n/a (caught) | caught by its own test |
| C-01 | Critical | NAV manipulation / pricing at a deflated NAV | test_AUDIT_C01_navDeflationCannotBeSettled, test_AUDIT_C01b_legitimateMovesSettleThroughTheRatchet, test_D4_C01_noMintAtADeflatedNav, test_InsiderDepositsArePricedInTheNextEpoch | C-01d (#1752) `VaultLogic.sol:214`: loss-breach settle mints (no redemption-only mode) | killed: test_D4_C01_noMintAtADeflatedNav | n/a (caught) | caught by its own test |
| H-01 | High | access control / timelock bypass | test_AUDIT_H01_ownerCannotResetBreachOrRearmInstantly, test_AUDIT_H01b_ownerCannotExitEmergencyWithRedeemersWaiting | H-01a (#1753) `VaultGovernance.sol:260`: owner clears a breach directly | killed: test_AUDIT_H01_ownerCannotResetBreachOrRearmInstantly | n/a (caught) | caught by its own test |
| H-01 | High | access control / timelock bypass | test_AUDIT_H01_ownerCannotResetBreachOrRearmInstantly, test_AUDIT_H01b_ownerCannotExitEmergencyWithRedeemersWaiting | H-01b (#1754) `HyperVault.sol:92`: owner calls onlySelf (setAgent, setFees, setManager...) directly | killed: test_AUDIT_H01_ownerCannotResetBreachOrRearmInstantly | n/a (caught) | caught by its own test |
| H-01 | High | access control / timelock bypass | test_AUDIT_H01_ownerCannotResetBreachOrRearmInstantly, test_AUDIT_H01b_ownerCannotExitEmergencyWithRedeemersWaiting | H-01c (#1755) `VaultGovernance.sol:273`: emergency exit with redemptions pending | killed: test_AUDIT_H01b_ownerCannotExitEmergencyWithRedeemersWaiting | n/a (caught) | caught by its own test |
| H-02 | High | liveness / griefing of settlement (bridge window) | test_AUDIT_H02_bridgeWindowCannotBlockEmergencySettle | H-02a (#1756) `VaultLogic.sol:444`: dust bridgeToEvm allowed | killed: test_AUDIT_H02_bridgeWindowCannotBlockEmergencySettle | n/a (caught) | caught by its own test |
| H-02 | High | liveness / griefing of settlement (bridge window) | test_AUDIT_H02_bridgeWindowCannotBlockEmergencySettle | H-02b (#1757) `VaultLogic.sol:429`: dust bridgeToCore allowed | killed: test_MinBridgeUnlessFullAmount | n/a (caught) | caught by its own test |
| M-01 | Medium | risk metric (in-flight double count) | test_AUDIT_M01a_bridgePingPongDoesNotMaskBreach, test_AUDIT_M01b_dayRollInsideBridgeWindowIsDeferred | M-01a (#1758) `VaultGovernance.sol:175`: in-flight equity = live + bridged (upper bound) | killed: test_AUDIT_M01a_bridgePingPongDoesNotMaskBreach | n/a (caught) | caught by its own test |
| M-01 | Medium | risk metric (in-flight double count) | test_AUDIT_M01a_bridgePingPongDoesNotMaskBreach, test_AUDIT_M01b_dayRollInsideBridgeWindowIsDeferred | M-01b (#1759) `VaultGovernance.sol:181`: day rolls inside a bridge window | survived | survived | NOT caught by its own test (equivalent for the test since N-01b caps the in-window equity); a real gap remains (an in-window gain understates the day start and masks a later loss): HLR2-M08, killed by test_HLR2_M10_kills_dayRollInsideTheWindow |
| M-02 | Medium | fees (retroactive raise) | test_AUDIT_M02_feeRaiseInBridgeWindowReverts | M-02 (#1760) `VaultGovernance.sol:381`: fee change inside a bridge window | killed: test_AUDIT_M02_feeRaiseInBridgeWindowReverts | n/a (caught) | caught by its own test |
| M-03 | Medium | timelock (no expiry) | test_AUDIT_M03_queuedChangesExpire | M-03a (#1761) `VaultGovernance.sol:354`: vault queue never expires | killed: test_AUDIT_M03_queuedChangesExpire | n/a (caught) | caught by its own test |
| M-03 | Medium | timelock (no expiry) | test_AUDIT_M03_queuedChangesExpire | M-03b (#1762) `VaultPolicy.sol:336`: policy queue never expires | killed: test_AUDIT_M03_queuedChangesExpire | n/a (caught) | caught by its own test |
| M-04 | Medium | trading limits (contract path) | test_AUDIT_M04a_flattenSlippageCappedByPolicy, test_AUDIT_M04b_placeOrderChecksProjectedLeverage | M-04a (#1763) `VaultPolicy.sol:207`: custom flatten slippage uncapped | killed: test_AUDIT_M04a_flattenSlippageCappedByPolicy | n/a (caught) | caught by its own test |
| M-04 | Medium | trading limits (contract path) | test_AUDIT_M04a_flattenSlippageCappedByPolicy, test_AUDIT_M04b_placeOrderChecksProjectedLeverage | M-04b (#1764) `VaultPolicy.sol:195`: no projected leverage check per order | killed: test_AUDIT_M04b_placeOrderChecksProjectedLeverage | n/a (caught) | caught by its own test |
| M-05 | Medium | fees (performance fee on transient highs) | test_AUDIT_M05_noPerfFeeOnTransientSpike | M-05 (#1765) `VaultLogic.sol:333`: permissionless accrueFees charges the performance fee | killed: test_AUDIT_M05_noPerfFeeOnTransientSpike | n/a (caught) | caught by its own test |
| L-01 | Low | trading limits | test_AUDIT_L01_notionalCapUsesMark | L-01 (#1766) `VaultPolicy.sol:191`: notional at limit price | killed: test_AUDIT_L01_notionalCapUsesMark | n/a (caught) | caught by its own test |
| L-02 | Low | previews | test_AUDIT_L02_lensPreviewMatchesSettle | L-02 (#1814) `HyperVaultLens.sol:98`: lens previews ignore pending fees | killed: test_AUDIT_L02_lensPreviewMatchesSettle | n/a (caught) | caught by its own test |
| L-03 | Low | risk metric (fee dilution) | test_AUDIT_L03_feeAccrualDoesNotTriggerDrawdownBreach, test_R01_feeMintsDoNotMoveTheMetrics | L-03 (#1767) `VaultLogic.sol:367`: fee dilution not rescaled out of the risk references | killed: test_AUDIT_L03_feeAccrualDoesNotTriggerDrawdownBreach | n/a (caught) | caught by its own test |
| L-04 | Low | NAV (double count in window) | test_AUDIT_L04_viewsDoNotDoubleCountInWindow | L-04 (#1768) `VaultMath.sol:182`: views double count inside the window | survived | killed: test_SeedBridgedToCoreSpotThenHypeForwarded | own test stale (it credits Core in the same block, so idle + core is already right without the snapshot); the whole suite catches the revert (test_SeedBridgedToCoreSpotThenHypeForwarded); also killed by test_HLR2_M01 |
| L-05 | Low | NAV (negative perp equity) | test_AUDIT_L05_negativePerpEquityNetted | L-05 (#1769) `VaultMath.sol:121`: negative perp clamped separately from spot | killed: test_AUDIT_L05_negativePerpEquityNetted | n/a (caught) | caught by its own test |
| L-06 | Low | agent approval ordering (HyperCore) | test_AUDIT_L06_agentApprovedAfterCoreAccountExists, test_AUDIT_A13_managerKeyIsNeverAnAgent | L-06 (#1770) `VaultGovernance.sol:92`: agent approved in the account-creating transaction | killed: test_AUDIT_L06_agentApprovedAfterCoreAccountExists, test_VERIFY5_syncSendsOnlyTheStoredAgent | n/a (caught) | caught by its own test |
| I-03 | Info | ownership | test_RenounceOwnershipDisabled | I-03 (#1805) `HyperVault.sol:345`: vault renounceOwnership no longer reverts | killed: test_RenounceOwnershipDisabled | n/a (caught) | caught by its own test |
| N-01 | Critical | bridge window held open / settle inside it | test_REAUDIT_N01_windowCannotBeHeldOrSettledInside | N-01 (#1771) `VaultLogic.sol:457`: bridge window can be re-armed while open | killed: test_REAUDIT_N01_windowCannotBeHeldOrSettledInside | n/a (caught) | caught by its own test |
| N-01b | Critical (part of N-01) | risk metric masked in window | test_REAUDIT_N01b_windowCannotMaskBreach | N-01b (#1811) `VaultGovernance.sol:175`: in-window equity = frozen snapshot (masks a loss) | killed: test_REAUDIT_N01b_windowCannotMaskBreach | n/a (caught) | caught by its own test |
| N-02 | Critical | emergency deadlock (all-or-nothing) | test_REAUDIT_N02_emergencyExitCannotDeadlock | N-02 (#1772) `VaultLogic.sol:264`: emergency settle all-or-nothing | killed: test_REAUDIT_N02_emergencyExitCannotDeadlock | n/a (caught) | caught by its own test |
| N-03 | High | policy tighten/loosen classification | test_REAUDIT_N03_navBoundNeverBlocksExits | N-03 (#1773) `VaultPolicy.sol:366`: lowering maxNavMoveBps counts as tighter | killed: test_REAUDIT_N03_navBoundNeverBlocksExits | n/a (caught) | caught by its own test |
| N-04 | Medium | timelock bypass (pre-queued / padded clearBreach) | test_REAUDIT_N04_prequeuedClearBreachRejected | N-04a (#1774) `VaultGovernance.sol:356`: pre-queued clearBreach accepted | killed: test_REAUDIT3_R303_ownerClearQueuedBetweenTwoEmergenciesStillCounts, test_REAUDIT_N04_prequeuedClearBreachRejected | n/a (caught) | caught by its own test |
| N-04 | Medium | timelock bypass (pre-queued / padded clearBreach) | test_REAUDIT_N04_prequeuedClearBreachRejected | N-04b (#1775) `VaultGovernance.sol:341`: padded calldata creates duplicate queue ids | killed: test_REAUDIT_N04_prequeuedClearBreachRejected | n/a (caught) | caught by its own test |
| N-05 | Medium | fees (M-05 bypass via lowerFees) | test_REAUDIT_N05_lowerFeesCannotCrystalliseASpike | N-05 (#1776) `VaultGovernance.sol:322`: lowerFees(current, current) allowed | killed: test_REAUDIT_N05_lowerFeesCannotCrystalliseASpike | n/a (caught) | caught by its own test |
| N-06 | Medium | role rotation | test_REAUDIT_N06_rolesRotateForExistingVaults | N-06 (#1777) `HyperVault.sol:84`: guardian fixed per vault (not read from the factory) | killed: test_REAUDIT_N06_rolesRotateForExistingVaults | n/a (caught) | caught by its own test |
| N-07 | Low | agent binding | test_REAUDIT_N07_agentBoundToOneVault | N-07 (#1778) `VaultLogic.sol:611`: any agent accepted on any vault | killed: test_REAUDIT_N07_agentBoundToOneVault | n/a (caught) | caught by its own test |
| N-08 | Medium | fees (HWM ratchet without fee) | test_REAUDIT_N08_hwmOnlyMovesWithTheFee | N-08 (#1779) `VaultLogic.sol:365`: HWM ratchets on management-only accrual | killed: test_REAUDIT_N08_hwmOnlyMovesWithTheFee | n/a (caught) | caught by its own test |
| N-11 | Info | refund accounting (zero-share deposit) | none named | N-11 (#1780) `VaultLogic.sol:258`: zero-share deposit swallowed | survived | survived | NO regression test exists; the revert survives the whole suite: HLR2-M08, killed by test_HLR2_M12_kills_zeroShareDepositSwallowed |
| N-12 | Info | checkpoint bootstrap | test_CheckpointRule, test_REAUDIT2_I204_firstSettleCheckpointsItself | N-12 (#1781) `VaultPolicy.sol:235`: first settle without a checkpoint | killed: test_CheckpointRule | n/a (caught) | caught by its own test |
| N2-01 | Medium | claim gas O(epochs) | test_REAUDIT2_N201_claimGasIsConstantAcross1000EmergencyEpochs | none (structural (the O(n) loop was removed with V-01); no single-line revert reproduces it. The gas test is the guard; it is run on the optimized build only (see baseline)) | - | - | structural |
| N2-02 | Low | fees (raise applies to the running epoch) | test_REAUDIT2_N202_perfFeeRaiseStartsNextEpoch, test_REAUDIT2_N202_loweringIsImmediateAndCancelsAPendingRaise | N2-02 (#1782) `VaultGovernance.sol:405`: performance fee raise applies to the running epoch | killed: test_REAUDIT2_N202_loweringIsImmediateAndCancelsAPendingRaise, test_REAUDIT2_N202_perfFeeRaiseStartsNextEpoch | n/a (caught) | caught by its own test |
| N2-03 | Low | trading limits (flatten slippage lever) | test_REAUDIT2_N203_flattenSlippageIsCappedAt3Percent | N2-03 (#1783) `VaultPolicy.sol:355`: flatten slippage cap 20% instead of 3% | killed: test_REAUDIT2_N203_flattenSlippageIsCappedAt3Percent | n/a (caught) | caught by its own test |
| N2-04 | Low | agent binding (several agents per predicted vault) | test_REAUDIT2_N204_oneAgentPerPredictedVault | N2-04 (#1784) `HyperVaultFactory.sol:237`: several agents bound to one predicted vault | survived | survived | NOT caught: test_REAUDIT2_N204 only covers registerPlatformAgent, not the create() half of the fix: HLR2-M08, killed by test_HLR2_M08_kills_createBindsASecondAgentToAPreBoundVault |
| I2-03 | Info | role power (registrar revokes live agent) | test_REAUDIT2_I203_registrarCannotRevokeALiveAgent | I2-03 (#1806) `HyperVaultFactory.sol:322`: registrar revokes a live agent | killed: test_REAUDIT2_I203_registrarCannotRevokeALiveAgent | n/a (caught) | caught by its own test |
| I2-04 | Info | checkpoint bootstrap | test_REAUDIT2_I204_firstSettleCheckpointsItself | I2-04 (#1807) `HyperVault.sol:193`: first settle needs an external checkRisk | killed: test_REAUDIT2_I204_firstSettleCheckpointsItself | n/a (caught) | caught by its own test |
| I2-05 | Info | role separation | test_REAUDIT2_I205_factoryRolesMustNotCollide | I2-05 (#1808) `HyperVaultFactory.sol:444`: factory roles may collide | killed: test_REAUDIT2_I205_factoryRolesMustNotCollide | n/a (caught) | caught by its own test |
| V-01 | Critical | emergency partial fill burns honest redemptions | test_VERIFY_V01_lateRedeemersArePaidOrReturned, testFuzz_VERIFY2_B1_partialFillRounding | V-01 (#1797) `VaultMath.sol:245`: unpaid shares of a partial fill not returned | killed: test_VERIFY2_B2_cancelAfterPartialFill, test_VERIFY2_B3_zeroLiquiditySettleReturnsEverything, test_VERIFY2_W01_ownerCannotExitAfterAPartialFill | n/a (caught) | caught by its own test |
| V-01 | Critical | emergency partial fill burns honest redemptions | test_VERIFY_V01_lateRedeemersArePaidOrReturned, testFuzz_VERIFY2_B1_partialFillRounding | V-01r (#1812) `VaultMath.sol:244`: returned shares rounded up (over-return) | killed: test_VERIFY2_B2_cancelAfterPartialFill, test_VERIFY2_B3_zeroLiquiditySettleReturnsEverything, test_VERIFY2_W01_ownerCannotExitAfterAPartialFill | n/a (caught) | caught by its own test |
| V-03 | Info | factory ownership | test_VERIFY_V03_factoryOwnershipCannotBeRenouncedAndPendingOwnerIsChecked | V-03a (#1798) `HyperVaultFactory.sol:407`: factory renounceOwnership no longer reverts | killed: test_VERIFY_V03_factoryOwnershipCannotBeRenouncedAndPendingOwnerIsChecked | n/a (caught) | caught by its own test |
| V-03 | Info | factory ownership | test_VERIFY_V03_factoryOwnershipCannotBeRenouncedAndPendingOwnerIsChecked | V-03b (#1799) `HyperVaultFactory.sol:401`: ownership to a hot role | survived | survived | NOT caught: the V-03 test covers renounce and the setters, not transferOwnership to a hot role: HLR2-M08, killed by test_HLR2_M09_kills_ownershipToAHotRole |
| V-04 | Low | registrar pre-binding DoS | test_V04_registrarCannotPreBindAndSignaturesAreScoped | V-04 (#1800) `HyperVaultFactory.sol:306`: registrar pre-binds a predicted vault | killed: test_V04_registrarCannotPreBindAndSignaturesAreScoped | n/a (caught) | caught by its own test |
| W-01 | Medium | emergency exit by the owner after a partial fill | test_VERIFY2_W01_ownerCannotExitAfterAPartialFill, test_VERIFY2_W01_reTriggerKeepsTheEmergencyStamp | W-01 (#1801) `VaultGovernance.sol:272`: owner exits emergency through its own timelock | survived | survived | EQUIVALENT as written (exitEmergency is not queueable, so address(this) can never call it); the faithful revert (owner may exit directly, scratch-only mutant #9001) IS caught by test_AUDIT_H01b, test_VERIFY2_W01_ownerCannotExitAfterAPartialFill, test_VERIFY3_W01b_* and test_ExitEmergencyIsTheGuardiansAndNotWithRedemptionsPending |
| W-01b | Medium | emergency exit gate spoofed | test_VERIFY3_W01b_emptySettleDoesNotHelpTheOwner, test_VERIFY3_W01b_dustRedemptionDoesNotHelpTheOwner, test_VERIFY3_W01b_guardianGate | W-01b (#1802) `VaultGovernance.sol:277`: exit right after a partial fill | killed: test_VERIFY2_W01_ownerCannotExitAfterAPartialFill, test_VERIFY3_W01b_dustRedemptionDoesNotHelpTheOwner, test_VERIFY3_W01b_emptySettleDoesNotHelpTheOwner | n/a (caught) | caught by its own test |
| X-01 | Low | bridge window re-arm by a stranger | test_VERIFY4_X01_strangerCannotReopenTheWindow | X-01 (#1803) `VaultLogic.sol:439`: anyone bridges back in emergency | killed: test_VERIFY4_X01_strangerCannotReopenTheWindow | n/a (caught) | caught by its own test |
| A-13 | (change) | agent approval dropped by HyperCore | test_VERIFY5_* | A-13a (#1809) `VaultLogic.sol:604`: syncAgent re-approves during a full stop | survived | survived | EQUIVALENT: in a full stop the stored agent is always 0 (triggerBreach / triggerEmergency revoke it, setAgent refuses in a full stop), so syncAgent reverts ZeroAddress before the hardStop gate; the gate is defense in depth |
| A-13 | (change) | agent approval dropped by HyperCore | test_VERIFY5_* | A-13b (#1810) `VaultLogic.sol:628`: revoke keeps the stored agent (sync re-approves it) | killed: test_VERIFY5_breachAndEmergencyGate, test_VERIFY5_noSyncAfterAnyRevoke, test_VERIFY5_syncThenRevokeSameBlock | n/a (caught) | caught by its own test |
| R-01 | (round 4 design) | risk metrics measured on the share price, flows neutral | test_R01_* | R-01 (#1785) `VaultLogic.sol:301`: deposits reset the risk references | killed: test_R01_depositDoublingTheVaultNeverResetsThePeak | n/a (caught) | caught by its own test |
| R-02 | (round 4 design) | late bridge landing | test_R02_* | R-02a (#1786) `VaultMath.sol:134`: window closes after 10 blocks landed or not | killed: test_R02_boundedByTheMaximumWait, test_R02_lateLandingIsNeitherANavDropNorSettledAround | n/a (caught) | caught by its own test |
| R-02 | (round 4 design) | late bridge landing | test_R02_* | R-02b (#1787) `VaultLogic.sol:477`: landing never latched | survived | killed: test_lateLandingIsNotALoss | the R-02 tests do not catch it; the whole suite does (test_lateLandingIsNotALoss); the latching by each entry point is now pinned by test_HLR2_M11/M26/M27/M45/M62 |
| R-02 | (round 4 design) | late bridge landing | test_R02_* | R-02c (#1788) `VaultLogic.sol:518`: moveUsd inside a bridge window | killed: test_R02_moveUsdWaitsForTheWindow | n/a (caught) | caught by its own test |
| R3-01 | Medium | bridge landing signal | test_REAUDIT3_R301_* | R3-01 (#1789) `VaultMath.sol:156`: EVM->Core landing read from Core equity | killed: test_REAUDIT3_R301_pnlLatchesAnUnlandedBridge_falseDailyLossBreach, test_REAUDIT3_R301_settleRunsWithUsdcUnaccounted | n/a (caught) | caught by its own test |
| R3-02 | Low | insider pricing (back-to-back settles) | test_REAUDIT3_R302_*, test_R302_insiderAgeNeverDelaysExits | R3-02 (#1790) `VaultLogic.sol:220`: no minimum epoch age before pricing insiders | killed: test_R302_insiderAgeNeverDelaysExits, test_REAUDIT3_R302_insiderDeferralBypassedByBackToBackSettles | n/a (caught) | caught by its own test |
| R3-03 | Low | timelock bypass (N-04 variant) | test_REAUDIT3_R303_*, test_R303_retriggerRestartsBreachedAt | R3-03 (#1791) `VaultGovernance.sol:252`: re-trigger keeps the old breachedAt | killed: test_R303_retriggerRestartsBreachedAt, test_REAUDIT3_R303_ownerClearQueuedBetweenTwoEmergenciesStillCounts | n/a (caught) | caught by its own test |
| R3-04 | Low | treasury actions in a loss breach | test_REAUDIT3_R304_*, test_R304_marginStillAllowedInALeverageBreach | R3-04a (#1792) `VaultLogic.sol:425`: bridgeToCore in a loss breach | killed: test_REAUDIT3_R304_bridgeToCoreInDrawdownBreachStarvesRedemptions | n/a (caught) | caught by its own test |
| R3-04 | Low | treasury actions in a loss breach | test_REAUDIT3_R304_*, test_R304_marginStillAllowedInALeverageBreach | R3-04b (#1793) `VaultLogic.sol:516`: moveUsd(toPerp) in a loss breach | killed: test_REAUDIT3_R304_bridgeToCoreInDrawdownBreachStarvesRedemptions | n/a (caught) | caught by its own test |
| R3-05 | Low | unlanded bridge masks a loss | test_REAUDIT3_R305_unlandedBridgeMasksALossFor300Blocks (rewritten) | R3-05 (#1794) `VaultMath.sol:134`: window held 300 blocks | killed: test_R02_boundedByTheMaximumWait, test_REAUDIT3_R305_unlandedBridgeMasksALossFor300Blocks | n/a (caught) | caught by its own test |
| R3-06 | Low | fees (N2-02 regression) | test_REAUDIT3_R306_* | R3-06 (#1795) `VaultLogic.sol:234`: breach settle switches a pending raise on | killed: test_REAUDIT3_R306_breachSettleSwitchesAPendingRaiseWithoutChargingTheOldRate | n/a (caught) | caught by its own test |
| R3-07 | Low | previews (lens perf fee in breach) | test_breachSettleChargesManagementFeeOnlyNeverPerformance | R3-07 (#1813) `HyperVaultLens.sol:87`: lens previews charge a performance fee in a breach | killed: test_breachSettleChargesManagementFeeOnlyNeverPerformance | n/a (caught) | caught by its own test |
| R3-08 | Low | late landing past the window read as a loss | test_lateLandingIsNotALoss, test_D4b/c/d | R3-08 (#1796) `VaultMath.sol:147`: late bridge past the window read as a loss / settled around | killed: test_D4b_aTradingLossWhileUnlandedStillBreaches, test_D4c_aTransferThatNeverLandsCountsAsLostAfterTheCap, test_D4d_noNewBridgeWhileTheLastOneIsLate | n/a (caught) | caught by its own test |
| I3-07 | Info | insider delay griefing with dust | test_D2_minimumDeposit, test_D2_insiderDelayGriefingCostsTenUsdc | I3-07 (#1804) `VaultLogic.sol:46`: dust deposit requests | killed: test_D2_insiderDelayGriefingCostsTenUsdc, test_D2_minimumDeposit, test_REAUDIT3_INFO_strangerArmsInsiderDelay | n/a (caught) | caught by its own test |


## The four gaps (finding HLR2-M08, Low)

| Fix | Revert that nothing caught | Why the old test misses it | Impact if the line regressed | New test |
|---|---|---|---|---|
| M-01 (second half) | `_check` rolls the day inside a bridge window | Since N-01b the in-window equity is min(snapshot, live + in flight), so the old double-count scenario no longer differs | An in-window gain is understated in the new day's start price, so a loss of up to that gain on the same day is masked from the daily-loss limit (scenario in the test: +10% in the window, then -9.1%, limit 5%: no breach) | `test_HLR2_M10_kills_dayRollInsideTheWindow` |
| N-11 | `if (depShares == 0) depIn = 0` deleted | No test ever reached a deposit that mints zero shares | The deposit is absorbed by the incumbents and its claim is clamped to the reserve (10 USDC lost in the test; with other users' payouts in the reserve the refund is paid out of their money) | `test_HLR2_M12_kills_zeroShareDepositSwallowed` |
| N2-04 (create half) | `agentOfVault[predicted] != 0` check in `create()` deleted | `test_REAUDIT2_N204` only exercises `registerPlatformAgent` | A registrar-signed launch binds a second agent to a vault the owner pre-bound (two platform agents for one vault: the N2-04 class) | `test_HLR2_M08_kills_createBindsASecondAgentToAPreBoundVault` |
| V-03 (second half) | `_checkRoles(newOwner, ...)` deleted from `transferOwnership` | The V-03 test covers renounce and the setters against the pending owner, not the transfer itself | The factory could be handed to the hot sentinel or registrar key (cold and hot roles merged) | `test_HLR2_M09_kills_ownershipToAHotRole` |

Severity: Low (impact x likelihood): the current code is correct; the gap only matters if one of these lines regresses,
and nothing in the suite would notice. Fix: keep the four new tests (contracts/test/audit/hl-r2/mut/) in the suite;
update `test_AUDIT_L04_*` and the R-02 tests so they test what they are named after (L-04: assert the snapshot while
Core has NOT been credited yet; R-02: assert that a landing, once moved on, does not reopen the window).

## Findings and fixes without a revertable line

- N2-01 (claim gas O(epochs)): the O(n) structure was replaced with V-01's one-epoch-per-request design; no single line
  reverts it. Its guard is `test_REAUDIT2_N201_claimGasIsConstantAcross1000EmergencyEpochs`, which needs the optimized
  build (it is one of the five tests excluded from the unoptimized runs).
- Accepted, documented or design items carry no fix to revert: I-04, I-05, I-07, I-08, D-1..D-5, N-09, N-10, N-13,
  N-14, N-15, I2-01, I2-02, I2-06, I3-01..I3-06, I3-08, R3-05 residuals, V5 syncAgent HYPE, V4 guardian gate, and the
  open hl-open contract items HLO-01..HLO-13 (no fix in `contracts/src` since round 4).
- Executor / server findings (S-01..S-17, SN-01..SN-09, V-02, OPS-1, HLO-E01..E10) are TypeScript; outside this
  Solidity mutation sub-review. Their regression tests live in `server/test/audit/` and were not run here.

## Reproduce

`contracts/audit/hl-r2/mut-tool/` (generator, schema writer, runner, `pastfix.json`, `inventory.json`). In a scratch
copy of `contracts/` (never in the repo): `python normalize.py .`, commit, `python mutgen.py . targets.json
mutants.json`, `python schema.py . mutants.json`, `FOUNDRY_PROFILE=mut forge build ...` (profile in MUTATION.md), then
`python run.py . mutants.json pf.jsonl --pf --no-fail-fast` and `--ids <survivors> --tag full`.
