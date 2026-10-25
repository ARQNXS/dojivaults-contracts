# Gains round 1 fix round: test sub-fixer A1

Scope: `test/audit/gains/{nav,lifecycle,integration,replay,symbolic,invariants}/` and `test/audit/gains/R1LiveFork.t.sol`.
Every test in these directories passes on branch `fix/gains-r1` (src including the `GainsNav.snapshot(..., bool high)` change).

## 1. Round 1 PoCs converted to regression tests

Each regression test asserts the fixed behaviour, so it fails on the round 1 code. Its doc comment names the PoC it was.

| Original test | New name | Finding | What it asserts now |
|---|---|---|---|
| `lifecycle/LC_PendingFork.test_lc_LC01_leverageOnlyIncreasesBypassVaultLeverage` | `test_GR1_01_leverageOnlyIncreases_cannotBypassVaultLeverage` | GR1-01 | A pending leverage-only increase is counted in the notional at collateral x delta. A second increase on another trade is refused `OrderRejected("leverage")`. A second request on the same trade is refused `PendingOrderExists(index)`. After the fill, vault leverage is within maxLeverageBps (29,957 vs 30,000 bps) and there is no breach. |
| `lifecycle/LC_PendingFork.test_lc_increaseLeverageOnly_pendingNotionalIsZero` | `test_GR1_01_leverageOnlyIncrease_countedWhilePending` | GR1-01 | The pending increase adds exactly +10,000 USDC of notional (1,000 x 10). It does not hold settle. The fill adds nothing a second time. |
| `lifecycle/LC_PendingFork.test_lc_updateLeverageDecrease_solFeeOnPairZero` | `test_GR1_28_updateLeverageDecrease_solFeeOnTradesOwnPair` | GR1-28 | Gains still stores pairIndex 0 on the pending order. Mocking pair 0's govFeeP x10 leaves the NAV unchanged, so the fee comes from pair 33. The reserved fee (42,505) equals the fee Gains realizes. |
| `nav/NavEconFork.test_GOVFEEPAIR_fork_pendingSolIncreaseUsesPair0Fee` | `test_GR1_28_fork_pendingSolIncreaseUsesTradesOwnPairFee` | GR1-28 | Pair 0's fee is mocked x10 (425,054 vs SOL 42,505). The pending SOL partial open is valued at 500e6 - minGovFee(SOL). |
| `nav/NavEconFork.test_NAVBIAS_fork_realFees_3x` | `test_GR1_02_fork_realFees_3x_depositInWhileOpenGainsNothing` | GR1-02 | bob deposits while the trade is open and leaves once it is flat: bobOut <= bobIn (he pays 279.85 USDC). From the same snapshot, alice ends with at least what she gets without bob (1 USDC tolerance): 100,040.97 with bob vs 99,781.78 without. |
| `nav/NavEconFork.test_NAVBIAS_fork_realFees_10x` | `test_GR1_02_fork_realFees_10x_depositInWhileOpenGainsNothing` | GR1-02 | The same at 10x: bob pays 927.97 USDC, and alice gets 100,132.46 with bob vs 99,270.56 without. |
| `nav/NavEconFork.test_NAVCLIFF_fork_controlSameNotionalAt6x` | `test_GR1_02_fork_controlSameNotionalAt6x_gainsNothing` | GR1-02 | A 1M depositor at 6x gains nothing (he pays 1,034.85 USDC). |
| `nav/NavEconFork.test_NAVCLIFF_fork_highLeverageTradeValuedZeroButPays` | `test_GR1_03_fork_highLeverageTradeValuedAtWhatGainsPays` | GR1-03 | A 200x trade is valued at the open (594 of 1,350 USDC collateral, not 0). The zero point is 10 bps of Chainlink move away, not at the open. Its NAV value equals to the wei what Gains pays for a close at the adverse edge. |
| `nav/NavEconFork.test_NAVCLIFF_fork_confederateExtractsFromHolders` | `test_GR1_03_fork_confederateCannotExtractAtTheCliff` | GR1-03 | The 1M confederate who enters at the cliff and leaves after the close at C gets bobOut <= bobIn (999,504.58 out). |
| `lifecycle/LC_GriefFork.test_lc_LC02_staggeredDecoyClosesBlockEmergencySettle` | `test_GR1_04_decoyClosesDoNotHoldEmergencySettle` | GR1-04 | With two decoy closes in flight, `ordersPending()` is false and the guardian's emergency settle runs (epoch +1, alice is paid). flatten still skips the trades and reports 0 remaining (GR1-27, unchanged). |
| `lifecycle/LC_GriefFork.test_lc_LC02_everyExitRoleCanHoldSettle` | `test_GR1_04_exitRoleClosesAndReducesDoNotHoldSettle` | GR1-04 | The owner's close and the operator's collateral reduce do not hold the exit-only settle. The operator can still be revoked at once. |
| `lifecycle/LC_GriefFork.test_lc_overdueEmergencyStillBlockedByPendingClose` | `test_GR1_04_overdueEmergencyNotBlockedByPendingClose` | GR1-04 | The overdue emergency settle runs with the close in flight. |
| (new) | `lifecycle/LC_GriefFork.test_GR1_04_openInFlightHoldsSettleAtMostOneTimeout` | GR1-04 | Once the epoch is overdue, openTrade, increaseTrade and updateLeverage (raise and decrease) revert `EpochOverdue()`. A market open sent before that holds settle (`OrdersPending`) until anyone calls `cancelTimedOut`; then the settle runs. |
| `integration/IntegrationMock.test_INT01_tradeLayoutChange_freezesNavSettleAndFlatten` | `test_GR1_08_tradeLayoutChange_navSettleAndFlattenWorkUnchanged` | GR1-08 | Both lists are in the 16-word Trade layout (PendingOrder grows with it). NAV, checkRisk (leverage and daily loss), accrueFees, a deposit plus normal settle, openTrade, flatten (2 closes) and the emergency settle all work. The full snapshot (value, valueHigh, notional, orders, pending, blocking), redemptionShortfall and ordersPending equal the v10-layout values at every step. |
| `integration/IntegrationMock.test_INT01_pendingOrderLayoutChange_blocksNavFlattenAndOperatorReduce` | `test_GR1_08_pendingOrderLayoutChange_navFlattenAndOperatorReduceWork` | GR1-08 | With a close in flight in the new layout, NAV and the shortfall are unchanged, the operator's shortfall reduce goes out, and flatten closes the BTC trade. The values match the v10 layout. |
| (new) | `integration/IntegrationMock.test_GR1_08_unreadableLayout_revertsDiamondLayoutChanged_flattenIndicesCloses` | GR1-08 | A garbage getTrades (element count does not divide the returndata) makes totalAssets, checkRisk, settle and flatten revert `DiamondLayoutChanged()`. triggerEmergency still stops the vault (its resting-order cancel is best effort). `flattenIndices` closes both trades by index, and skips an index that is no longer open (returns 0). Once the list is readable again, the exit-only settle runs. |
| `integration/IntegrationMock.test_INT_feedsAreStaticcalled` | `test_GR1_44_writingFeedRevertsPriceStaleWithBoundedGas` | GR1-44 | A feed that writes state under the staticcall: the NAV read reverts `PriceStale(ETH)` using 311,158 gas of the 50M given (asserted < 2M). Before, it used 63/64 of the 50M. |
| `nav/NavUnit.test_NAVDEC_decimalsChangeMispricesWithoutRevert` | `test_GR1_13_decimalsChangeRevertsPriceStale` | GR1-13 | The feed's decimals() is mocked to 6. policy.price, totalAssets, checkRisk and the settle with a queued redemption all revert `PriceStale(ETH)`. A decimals() that reverts is also stale. Back at 8 decimals the pair is priced again. |
| `nav/NavUnit.test_CANCELOPTION_freeCancelUntilSettle` | `test_GR1_15_cancelOptionNoLongerProfitable` | GR1-15 | Cancels are still free and the lag still moves bob's value (+74.6 USDC). But bob is below his deposit even after Chainlink catches up (99,476.42 of 100,000): two-sided pricing (2 x 20 bps x 3x) costs more than the 5 bps lag returns. With the test's numbers this holds, so nothing was forced. |
| `nav/NavUnit.test_priceAfterImpactTruncation_unreachableForInflation` | `test_GR1_24_priceAfterImpactSaturatesAndReadCapsAtMaxPrice` | GR1-24 | priceAfterImpact saturates at uint64.max (no wrap) and floors at 0. read accepts MAX_PRICE. At that price, with the widest 10% band, the short's adverse edge fits and the short is valued 0 (past liquidation). One unit above MAX_PRICE is `PriceStale`. |

## 2. Other tests changed, and why

All of these follow from intended behaviour changes. None weakens a check beyond what the fix requires.

- **`nav/NavUnit.test_feed_hugeAnswersBoundedAtUint64` -> `test_feed_hugeAnswersBoundedAtMaxPrice`** (GR1-24). The read bound is MAX_PRICE now, not uint64.max. The test asserts that the old maximum is PriceStale.
- **`nav/NavUnit.test_HALTEDFEED_solFrozenForADayStillSettles`** (GR1-14, not fixed). Adds `_ageEpoch(v2)` before the first deposit settle: the 1 h minimum epoch age. The PoC's point is unchanged and it passes.
- **`nav/NavUnit.test_NAVROTATION_bandCutStepsNavAtAnExecutorChosenMoment`** (GR1-35, not fixed). bob now mints at the favourable edge, so his value right after the settle is below 100k. The "bob took ~half of the step" assertion now measures his value across the rotation's execution (> 200 USDC) instead of against his deposit. The NAV step (450 USDC) is asserted as before.
- **`nav/NavUnit.test_inflation_donationAttackUnprofitable`** (GR1-23). The dust checkpoint no longer bounds the settle, so the attack's settle now goes through instead of reverting. The test runs the real settle and asserts the victim loses < 1 USDC and the attacker's 1 share unit is worth < 2 USDC.
- **`nav/NavDiffFork.t.sol`, `nav/NavReplayFork.t.sol`** (coordinator request). The JSON dumps to `./deployments/audit-nav-diff-*.json` are written only with `NAV_DIFF_DUMP=1` (`vm.envOr("NAV_DIFF_DUMP", false)`), and the doc comments say so; the files are then copied to `audit/gains/nav/data/`. The generated `contracts/deployments/audit-nav-diff-*.json` files were deleted.
- **`nav/NavEconFork._biasCycle`**. `bobIn = 0` runs the same timeline without bob. The new `_biasPair` runs both from one `vm.snapshotState()` for the alice comparison.
- **`lifecycle/LC_GriefFork.test_lc_LC03_strangerTriggerBlocksSlTighteningAndLimitCancel`** (GR1-25, not fixed). triggerBreach now cancels resting opens (GR1-16), which removed the limit order the PoC triggers on (Gains error 0xa3b36525). The stranger's triggers are now filed before the breach. The breach's cancel of the limit is then refused (PendingTrigger, best effort) and the limit survives; the test asserts this. The rest of the PoC (sentinel setSlTp / cancelOrder blocked, flatten still sends) is unchanged.
- **`lifecycle/LC_LifecycleFork.test_lc_stopLossWhileReducePending`** (GR1-04). The dead reduce is still pending (asserted on the diamond's list), but `ordersPending()` is now false: a partial close holds nothing.
- **`lifecycle/LC_LivenessFork.test_lc_gainsPaused_exitsRevert_settleBlockedOnlyByPending` -> `test_lc_gainsPaused_exitsRevert_stuckCloseNoLongerHoldsSettle`** (GR1-04, GR1-45 design). The settle now runs while Gains is PAUSED with the close stuck (it used to revert OrdersPending until Gains resumed).
- **`integration/IntegrationMock` reentrancy tests** (`test_INT_diamondReadsCannotReenter`, `test_INT_diamondRequestReentryReachesOnlyPermissionless`, `test_INT_hookTokenReentryFromClaim`). Add `_skip(1 hours)` before each settle that prices deposits (1 h minimum age). New helpers `_upgradeAll` and `_assertSameAsV10`.
- **`replay/VaultReplayFork._deploy`** (1 h minimum age). The vault is created and the deposit requested 1 h before the fork block's timestamp, and settled back at it. The replayed trades keep their recorded blocks and times; nothing touches the diamond before that settle.
- **`invariants/GainsSpecInvariants.t.sol` (SpecHandler)**:
  - `seed()` waits 1 h before its deposit settle.
  - S1 now counts only pending orders that hold collateral (`_holdingOrders`, computed from the diamond independently of the vault: market open, partial open with collateral, leverage decrease).
  - F3: at a settle, daily loss and drawdown may fall: deposits minted at the favourable edge raise the share price at the adverse-edge NAV, which is intended by GR1-02. They still may not rise > 1 bp. F3 is unchanged for every other flow. The first short campaign failed F3 on deposit -> settle with trades open.
  - The N1 NAV model follows GR1-03 (zero only at or past liquidation), GR1-01 / GR1-04 (a collateral-0 partial open holds nothing) and GR1-28 (fee on the trade's pair). The first short campaign failed N1 on the old band-twice rule.
  - Short campaign: inline config pins 2,048 x 500, so it was run with `FOUNDRY_PROFILE=a1short` (unknown profile, falls back to default, inline `default.` config does not apply) and `FOUNDRY_INVARIANT_RUNS=8 FOUNDRY_INVARIANT_DEPTH=300`. Results are in section 4.
- **`invariants/medusa/GainsMedusa.sol`**. Not changed; it compiles with the rest of the directory.
- **`R1LiveFork.t.sol`**. Not changed (it runs against the live, old bytecode). Its result is in section 4.

## 3. Reported to the lead

- No suspected src regression. Every failure was traced to an intended change listed above.

## 4. Results (fix/gains-r1 with the `snapshot(..., bool high)` change)

```
nav          Ran 5 test suites: 32 tests passed, 0 failed, 0 skipped (32 total tests)
lifecycle    Ran 5 test suites: 53 tests passed, 0 failed, 0 skipped (53 total tests)
integration  Ran 2 test suites: 18 tests passed, 0 failed, 0 skipped (18 total tests)
replay       Ran 1 test suite: 20 tests passed, 0 failed, 0 skipped (20 total tests)
symbolic     Ran 5 test suites: 42 tests passed, 0 failed, 0 skipped (42 total tests)
invariants   Ran 1 test suite: 1 tests passed (GainsSpecHandlerSanity), Medusa harness compiles
all six      Ran 19 test suites: 166 tests passed, 0 failed, 0 skipped (166 total tests)
R1LiveFork   Ran 1 test suite: 1 tests passed (live vault: 55 hours blocked, still > 48)
```

Short invariant campaign: the inline runs / depth were lowered to 12 / 300 for one local run, then the file was restored
byte for byte. `GainsSpecInvariants` passed with runs 12, calls 3,600. `GainsSpecInvariantsCalm` (its own inline config)
passed with runs 512, calls 256,000. The 2,048-run campaign was not run.

Gas, `LC_LivenessFork` on the new code:

| Call | Gas |
|---|---|
| totalAssets (18 trades + 1 limit + 1 pending open) | 7,186,685 |
| checkRisk (same) | 7,215,517 |
| totalAssets / checkRisk (20 open trades) | 7,800,773 / 7,807,896 |
| totalAssets (20 trades + pending closes) | 8,020,103 |
| totalAssets / checkRisk (20 trades + 20 pending leverage decreases) | 8,990,394 / 8,997,517 |
| settle (20 open trades, a redemption, no deposits queued) | 8,049,456 |
| flatten (20 ETH trades, one call) | 24,335,509 |
| flatten (3 batches 7 / 7 / 6) | 8,992,828 + 9,273,857 + 8,309,413 = 26,576,098 |
| flatten (all SOL trades, mixed 20) | 6,767,891 |
| openTrade (19th / 20th) | 8,464,064 / 8,810,411 |

The suite has no settle with queued deposits at 20 positions, so that number is not measured.
