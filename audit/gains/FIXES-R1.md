# Gains contracts: fix round 1

**This is an internal fix round for the internal review [ROUND1.md](ROUND1.md). It is not an independent audit.**

## Scope

- **Branch:** `fix/gains-r1`, in the worktree `dv-fix-gains`. Created from `audit/gains-r1` (ddff808), with `origin/main` 849c0fb merged in (e850c3d).
- **Changed:**
  - `contracts/src/gains`
  - tests
  - the executor (`server/`)
  - docs (`docs/gains`, `docs/audit-pack/KNOWN-ISSUES.md`)
- **Not changed:**
  - no webapp file;
  - nothing deployed, no transaction sent, nothing pushed;
  - nothing merged into main.
- **Baseline before any fix** (e850c3d, full `forge test` with the Arbitrum RPC): 93 suites, 743 passed, 0 failed, 2 skipped.
- **Executor baseline:** 879 passed, 1 failed, 7 skipped. The failure was the worktree's `.git` file in `exec-context`, fixed as housekeeping.
- **Round 2** (section 5, "Round 2"): the findings of the verification pass [VERIFY-R1.md](VERIFY-R1.md) (GV-01 to GV-06), on the same branch after merging `origin/main` 544808a (62045de). Same rules: each fix has a regression test that fails on the old code.
- **R2-01** (section 5, "R2-01"): the one finding of the second verification pass [VERIFY-R2.md](VERIFY-R2.md) (verify/gains-r2 14a2ee3, cherry-picked as 9d8e706 with its tests and data).

## Method

Rule applied to every fixed finding: its ROUND1 PoC is now a regression test that asserts the fixed behaviour (`test_GR1_xx_...`).

Every contract fix was then undone ONCE, on its own, to show that its test fails on the old code:

1. Copy `contracts/` to a scratch directory. The worktree was never edited.
2. Replace the fixed lines with the round-1 lines in that copy (`fixes/revert-check/unfix.py`, one entry per fix).
3. Run the fix's regression tests there with `fixes/revert-check/runcheck.py`.

The raw forge output is in `fixes/revert-check/` (`results-lane1.txt`, `results-lane2.txt`).

**Control:** the same 50 regression tests, with nothing undone, all pass on the fixed code: `Ran 11 test suites: 50 tests passed, 0 failed` (`control.txt`).

The executor fixes were checked the same way, by reverting files; see [fixes/EXECUTOR.md](fixes/EXECUTOR.md). Every converted or adapted test is listed in [fixes/TESTS-A1.md](fixes/TESTS-A1.md) and [fixes/TESTS-A2.md](fixes/TESTS-A2.md).

## 1. Fix table

### High

| Finding | Fix | Regression tests | Reverted check (fix undone, tests run) |
|---|---|---|---|
| **GR1-01** Pending leverage-only increases add no notional | GainsNav `_pendingEffect`: a pending MARKET_PARTIAL_OPEN with collateral 0 adds the trade's collateral × leverage delta; with collateral, the order's collateral × leverage. The policy checks open + pending exposure. GainsVaultLogic `_onePending`: a request on a trade that has an order pending reverts `PendingOrderExists(index)` (increaseTrade, updateLeverage). | `R1PoC.test_GR1_01_secondLeverageOnlyIncreaseRefused`, `test_GR1_01_tenConcurrentLeverageIncreasesRefusedAtThePolicy` (the "31x" scenario, see §7), fork `LC_PendingFork.test_GR1_01_leverageOnlyIncreases_cannotBypassVaultLeverage`, `test_GR1_01_leverageOnlyIncrease_countedWhilePending` | **4 / 4 FAIL.** `the pending +197.5k counts: 99999999999 !~= 297500000000`; `only the first fits the 3x policy: 10 != 1` (old code: all ten accepted); fork `the pending increase is counted: 0 != 23713000000`; `pending +10,000 USDC of size counted: 0 != 10000000000` |
| **GR1-02** Deposits mint at the adverse-edge NAV, repeatable intraday | (a) Two-sided settle: deposits mint at `max(nav, idle + valueHigh)`, with every trade at the favourable band edge. Redemptions are paid at the adverse edge. With no open trades both are equal. `valueHigh` is computed only when a settle prices deposits. (b) ROUND1's stronger recommendation, also done: every settle that prices deposits runs at least `INSIDER_MIN_EPOCH_AGE` (1 h) into the epoch, not only insider ones. Why both: (a) removes the transfer itself. (b) stops cycling settles every few minutes around Chainlink's lag (GR1-15) or the vault's open trades, so no residual within rounding can be farmed at high frequency. | `R1NavBias.test_GR1_02_depositWhileOpenRedeemWhenFlat_3x`, `_atTheNavBound`, `test_GR1_02_repeatedCyclesUnprofitable`, `test_GR1_02_settleThatMintsWaitsAnHour`; `XReview.test_GR1_02_intradayCyclesNoLongerTakeFromTheHolder` (the 100k-holder scenario); fork `NavEconFork.test_GR1_02_fork_realFees_3x_depositInWhileOpenGainsNothing`, `_10x_...`, `test_GR1_02_fork_controlSameNotionalAt6x_gainsNothing` | **(a) 8 / 8 FAIL**, GR1-15 included. `the holder loses at most rounding: 99698869670 < 100000000000` (3x); `98733951797 < 100000000000` (12.5x); `every cycle costs the depositor: 1005997330980 >= 1000000000000` (bob +5,997); intraday `1004750655485 >= ...` (bob +4,750, as in ROUND1); fork `bob gains nothing with no price move: 100270766603 > ...` (3x), `100911188730 > ...` (10x); the 6x control underflows on bob's "loss". **(b) FAIL:** `next call did not revert as expected` (a minting settle within the hour) |

Measured with the fix (tests above):
- The 100k holder of the intraday scenario keeps 100,000 USDC (minus at most 10 wei). Bob loses on every cycle.
- 3x mock: bob pays 299 USDC, alice gains it.
- Fork with real fees: bob pays 279.85 USDC at 3x and 927.97 USDC at 10x. Alice ends at 100,040.97 with bob versus 99,781.78 without him, compared from one state snapshot.

### Medium

| Finding | Fix | Regression tests | Reverted check |
|---|---|---|---|
| **GR1-03** Near-liquidation rule counts the band twice | GainsNav `_nearLiquidation`: zero only when the valuation price (already at the band edge) is at or past L: long `P <= L`, short `P >= L`. | `R1Regression.test_GR1_03_tradeAboveItsLiquidationPriceIsValued`, `test_GR1_03_tradeWithinTheBandOfLiquidationIsZero`; fork `NavEconFork.test_GR1_03_fork_highLeverageTradeValuedAtWhatGainsPays` (200x at open: 594 of 1,350 USDC collateral, equal to the wei to what Gains pays at the adverse edge), `test_GR1_03_fork_confederateCannotExtractAtTheCliff` | **2 / 4 FAIL**: `valued: P is above L: 0 <= 0`, fork `valued at the open, not 0: 0 <= 135000000`. The two others pass on the old rule too, by design. "Within the band of liquidation is still 0" is the half of the fix that must not change. The confederate extraction is also stopped by GR1-02 on its own (both edges priced), so undoing GR1-03 alone does not bring it back. The un-fix hard-codes the old rule with B = 20 bps, the curated BTC / ETH band the tests use. |
| **GR1-04** Decoy orders block the emergency settle | (a) Settle, in every mode, is blocked only by pending orders that hold collateral: market open, partial open with collateral, leverage decrease. `ordersPending()` has that meaning, is still price-free, and settle checks it before any price read. Closes, partial closes and leverage increases hold nothing, and their trade is valued as open. (b) Once the epoch is overdue (or in emergency), no new open, increase or leverage change (`EpochOverdue()`). An order that holds collateral therefore delays an exit-only settle for at most one Gains timeout, after which ANYONE may `cancelTimedOut`; that was already permissionless and is now tested. | `R1PoC.test_GR1_04_decoyClosesNoLongerBlockTheEmergencySettle`, `test_GR1_04_holdingOrderBlocksAtMostOneTimeout`; fork `LC_GriefFork.test_GR1_04_decoyClosesDoNotHoldEmergencySettle`, `test_GR1_04_exitRoleClosesAndReducesDoNotHoldSettle`, `test_GR1_04_overdueEmergencyNotBlockedByPendingClose`, `test_GR1_04_openInFlightHoldsSettleAtMostOneTimeout` | **(a) 4 / 4 FAIL:** `but it holds no collateral`; fork `closes do not count as orders that hold settle`, `OrdersPending()`. **(b) 2 / 2 FAIL:** `next call did not revert as expected` (an open accepted while overdue); fork `assertion failed` |
| **GR1-05 / 06 / 07** Executor resubmits, lease before drain, "no answer" retried | One design for all three, written up in [fixes/EXECUTOR.md](fixes/EXECUTOR.md): an intent key per order, stored before broadcast; on-chain netting (getTrades + getPendingOrders) and receipt-by-hash before any new attempt; "no answer" means reconcile, never retry; drain before the lease is released; only QUEUED signals are processed. | server `gains-r1-idempotency.test.ts` (GR1-05: 5, GR1-06: 3, GR1-07: 4); PoCs `tools/executor/D-4`, `D-5`, `xreview2/XR_D5`, `XR_LEASE` converted | **All FAIL on the reverted files** and pass after restore. The restart sends a second open; the in-process run sends `['openTrade','increaseTrade']` instead of `['openTrade']`; the standby is leader during the drain; no answer stays retryable (4 pending opens). Every scenario ends with exactly one order on the (fake) chain with the fix. |
| **GR1-08** A Gains Trade / PendingOrder ABI change freezes NAV, settle, flatten | GainsNav `readTrades` / `readPendingOrders` (and a non-reverting `tryReadTrades`) decode the lists by the returndata stride. Only the v10 fields the vault uses are decoded, and every word is range checked. Trailing fields are tolerated; a layout the vault cannot read reverts `DiamondLayoutChanged()`, never a silent misread. Exits keep working even if the read fails: `flattenIndices(uint32[], slippageBps, expectedPrice)` closes or cancels by index and decodes nothing, with the same callers and slippage rules as flatten. A full stop uses `tryReadTrades`, so it never fails on the list. | `IntegrationMock.test_GR1_08_tradeLayoutChange_navSettleAndFlattenWorkUnchanged`, `test_GR1_08_pendingOrderLayoutChange_navFlattenAndOperatorReduceWork` (mock diamond with an extra Trade field: values identical to v10), `test_GR1_08_unreadableLayout_revertsDiamondLayoutChanged_flattenIndicesCloses`; `R1Regression.test_GR1_08_flattenIndicesWorksWhenTheTradeListIsUnreadable`, `test_GR1_08_flattenIndicesSameCallersAsFlatten` | **4 / 4 layout tests FAIL** with the round-1 high-level decode: `EvmError: Revert` (both extra-field layouts), `next call did not revert as expected` (no DiamondLayoutChanged). `flattenIndices` is new, so a test of it cannot compile on the old code; the runtime check above undoes the reader and keeps the entry point. |

### Low

| Finding | Fix | Regression tests | Reverted check |
|---|---|---|---|
| **GR1-10** Sequencer uptime feed cannot be rotated (and Slither: a zero feed is accepted) | The factory constructor refuses `sequencerFeed_ == 0`. `sequencerFeed` / `sequencerGracePeriod` are now storage, with `setSequencerFeed(address, uint256)` (owner, non-zero). The vault's `setSequencerFeed()` is onlySelf and queued through the vault timelock (selector length 4); the policy then copies the factory's current feed and grace. *Round 2 (GV-03) replaced this with `setSequencerFeed(address, uint256)`, snapshotted at queue time; see section 5.* | `R1Regression.test_GR1_10_factoryRefusesAZeroSequencerFeed`, `test_GR1_10_sequencerFeedRotatesThroughTheTimelock` (a dead feed is SequencerDown, then rotated, then priced again); `Governance.test_GR1_10_sequencerFeedRotatesThroughTheTimelock_zeroRefused` | **3 / 3 FAIL:** `next call did not revert as expected` (zero accepted, twice); `0x1d14… != 0x92a6…` (the policy keeps the dead feed) |
| **GR1-12** The policy's owner survives a vault transfer | GainsVaultPolicy `owner()` returns the vault's owner. The policy's `transferOwnership`, `acceptOwnership` and `renounceOwnership` revert `OwnershipFollowsVault()`. | `Governance.test_GR1_12_policyOwnershipFollowsAVaultTransfer` | **FAIL:** `the policy follows the vault: 0xC37d… != 0x3D0e…` |
| **GR1-13** Feed decimals cached at curation | GainsPrice.read re-reads `decimals()` on every read. A change, or a failing call, is `PriceStale(pair)`. | `NavUnit.test_GR1_13_decimalsChangeRevertsPriceStale` | **FAIL:** `next call did not revert as expected` |
| **GR1-15** Requests and cancels free until the settle | Fixed by GR1-02. Two-sided pricing costs the requester about 2 × B × his share of the notional, more than Chainlink's lag can pay (the deviation threshold, 5 to 10 bps, is below the band). No settle that prices deposits runs within an hour of the last one. | `NavUnit.test_GR1_15_cancelOptionNoLongerProfitable` (bob ends at 99,476.42 of 100,000 after Chainlink catches up; old code +75.1 USDC) | **FAIL** with GR1-02(a) undone: `bob is still below his deposit ...: 100075075225 >= 100000000000` |
| **GR1-16** Resting orders survive a full stop and emergency | `_stop` (triggerBreach, triggerEmergency) cancels the vault's resting limit / stop opens. It is best effort: an unreadable list or a refused cancel never blocks the stop. Executor half: the sentinel cancels resting opens on every risk breach (EXECUTOR.md). | `R1PoC.test_GR1_16_fullStopCancelsRestingOrders`; server "GR1-16" (2) | **FAIL:** `the resting order is cancelled`. Executor: `expected [] to deeply equal [ 1, 2 ]` |
| **GR1-17..22** Executor Lows | Re-sign only by waiting for the stored hash (17); a landed request stays `sent` and is reconciled by receipt (18); one bounded deadline per order (19); the free-margin plan counts idle once and ignores queued deposits (20); the watcher uses `account.totalNtlPos` (21); 15 min bind grace, and the predicted vault proves the creator (22). Details in EXECUTOR.md. | server `gains-r1-lows.test.ts` and the converted PoCs D-2, D-3, D-6, D-8, D-9, D-10-D-11 | **All FAIL on the reverted files** (EXECUTOR.md lists each failure message) |

## 2. Executor

See [fixes/EXECUTOR.md](fixes/EXECUTOR.md) for the design, the per-finding table with the failure messages, and the counts. Changes outside the findings:
- **Minimum trade:** the executor minimum-trade setting only; no max() with pairMinPositionSizeUsd (§5).
- **ABI:** the round-1 vault interface (flattenIndices, EpochOverdue, DiamondLayoutChanged, PendingOrderExists, OwnershipFollowsVault).
- **venue():** decoded on its first four fields only, so deployed (old) vaults still read.
- **Housekeeping:** `executorSha` resolves a git worktree's `.git` file.
- **Two decisions to revisit:**
  - A create at the predicted vault now binds even when `tx.from` is not the owner. This is needed for Safes; the scoped CREATE2 salt proves the creator.
  - An order left unresolved that fills later is not booked on its ticket automatically: the processor alerts and the manager reconciles. That is the price of never sending twice.

## 3. Low findings not fixed

| Finding | Why not | Mitigation |
|---|---|---|
| GR1-09 Exit-only settle prices the venue: a stale feed holds redemptions | Both remedies in ROUND1 move value to or from redeemers at a moment nobody chose: paying from idle at a capped NAV, or valuing a stale pair's trades at 0 in an exit-only settle. Valuing at 0 underpays every redeemer of that epoch. This is not small and not safe without a design decision. | The guardian flattens the stale pair (exits read no price), then the flat vault settles. Covered in docs/gains/VENUE-LIVENESS.md. The PoC `R1PoC.test_STALESETTLE_*` still passes as a demonstration. |
| GR1-11 reduceTrade has no minimum size | A floor based on `pairMinPositionSizeUsd` is the size rule this round removes (§5). Any other floor would block legitimate small reduces. The harm needs a compromised online key and gives the attacker nothing. | Executor alarm: more than 10 ReduceRequested from one caller on one vault in 10 minutes raises an error alert (EXECUTOR.md, GR1-11). The PoCs `OperatorBound.test_GOV_01_*` still pass. |
| GR1-14 SOL staleness limit of 24.5 h | A 1 to 2 h freshness requirement on settles and deposits would block SOL vaults in calm markets: the Chainlink SOL/USD heartbeat is 24 h. That is a liveness change, not a small one. | Two-sided pricing (GR1-02) and the 1 h minimum age shrink what a frozen price can be used for. The NAV bound and the checkpoint stay. The PoC `NavUnit.test_HALTEDFEED_*` still passes. |

## 4. Informational and design triage

| ID | Item | Status |
|---|---|---|
| GR1-23 | DUSTCHECKPOINT | **Fixed:** nextCheckpoint accepts any NAV below MIN_RISK_NAV. Tests: `test_GR1_23_dustCheckpointDoesNotFreezeSettle`, `XReview.test_GR1_23_dustCheckpointNormalSettleRuns`. Reverted check: 2 / 2 FAIL with `NavMoved(1002283, 2739)`. The live vault keeps the old code until a redeploy (`R1LiveFork` still shows 55 h). |
| GR1-24 | ADVERSETRUNC | **Fixed:** read refuses answers above `MAX_PRICE = uint64.max × 1e4 / 1.1e4`, and priceAfterImpact saturates. Tests: `R1PoC.test_GR1_24_*` (2), `NavUnit.test_GR1_24_*`. Reverted check: 3 / 3 FAIL (`saturates, no wrap: 844574407370954 != 18446744073709551615`, and two `next call did not revert`). |
| GR1-25 | setSlTp / cancelOrder blockable for about 20 blocks per 1 LINK trigger | **Accepted:** Gains-side behaviour; closes and settle are unaffected. The PoC files its triggers before triggerBreach now (TESTS-A1.md). |
| GR1-26 | flatten takes one expectedPrice for longs and shorts | **Accepted:** no bad fill is possible (slippage only cancels). The cost is gov fees. The guardian can flatten per side with flattenIndices. |
| GR1-27 | flatten reports remaining = 0 behind a timed-out close or decoy | **Documented:** a decoy no longer holds settle (GR1-04), and the timed-out order is cancellable by anyone. |
| GR1-28 | Pending partial-open / leverage-update gov fee priced on pair 0 | **Fixed:** the fee is on the trade's own pair. Tests: `LC_PendingFork.test_GR1_28_updateLeverageDecrease_solFeeOnTradesOwnPair`, `NavEconFork.test_GR1_28_fork_pendingSolIncreaseUsesTradesOwnPairFee`. Reverted check: 2 / 2 FAIL (`499574946 != 499957495`, `19965537064 != 19965919613`). |
| GR1-29 | registerPlatformAgent binds many agents to one vault | **Accepted:** the hot registrar's trust boundary. `GainsVault.agent()` is the source of truth; the PoC is kept. |
| GR1-30 | The policy keeps renounceOwnership | **Fixed** with GR1-12. Test: `Governance.test_GR1_30_policyRenounceRevertsOwnerKeepsTheVeto`. Reverted check: FAIL, `next call did not revert as expected`. |
| GR1-31 | _checkNavBound skips listed-but-disallowed pairs | **Fixed:** every listed pair is checked. Test: `Governance.test_GR1_31_navBoundCoversDisallowedPairs_rotationStaysOpen`. Reverted check: FAIL. |
| GR1-32 | KNOWN-ISSUES I3-02 recovery wrong | **Fixed:** a cancelled next-epoch deposit resets the request to the current epoch. KNOWN-ISSUES.md is corrected. Test: `HLRetest.test_GR1_32_cancelledDeferredDepositLiftsTheRedeemBlock`. Reverted check: FAIL, `reset to the current epoch: 2 != 1`. |
| GR1-33 | redemptionShortfall prices at a possibly stale checkpoint | **Accepted:** conservative (the surplus stays idle). |
| GR1-34 | redemptionShortfall ignores deposits a settle nets | **Accepted:** conservative. The executor's free-margin plan no longer double counts (GR1-20). PoC kept. |
| GR1-35 | Anyone executes setPairFeed and picks the moment of the band step | **Accepted:** bounded by Δband × notional behind a public, at least 1 day queue. With two-sided pricing a depositor no longer takes it for free (the PoC now measures across the execution, TESTS-A1.md). |
| GR1-36 | Opening cost plus band booked as a daily loss at once | **Documented:** a property of the conservative NAV. |
| GR1-37 | Management fee rounds to 0 under per-second accrual on vaults under about 1,577 USDC | **Accepted:** dust. |
| GR1-38 | tradeValuePure panics on absurd inputs | **Accepted:** a revert, never a wrong value. |
| GR1-39 | The launch seed goes to the first depositors | **Documented:** the own-capital runbook step 8 now says so (docs/gains/MAINNET-OWN-CAPITAL.md). PoC kept. |
| GR1-40 | allowAsset copies the factory's curation at execution | **Accepted:** needs the cold factory owner (trust T6). PoC kept. |
| GR1-41 | flatten(0) uses maxSlippageBps uncapped | **Fixed:** `min(maxSlippageBps, maxFlattenSlippageBps)`. Test: `R1PoC.test_GR1_41_defaultFlattenCappedLikeACustomOne`. Reverted check: FAIL, `20000 != 3000`. |
| GR1-42 | requestDeposit reads NAV on every factory vault | **Documented:** AUDIT-DIFF.md deviation 7 now carries the correction (every factory vault has a cap, so a deposit request reads NAV and a stale feed pauses deposit requests; exits never). |
| GR1-43 | Executor nonce manager unused | **Fixed** (removed). Server test "GR1-43"; reverted check FAIL (EXECUTOR.md). |
| GR1-44 | A feed that halts exceptionally burns 63/64 of the read's gas | **Fixed:** feed calls get at most 200,000 gas. Test: `IntegrationMock.test_GR1_44_writingFeedRevertsPriceStaleWithBoundedGas` (311,158 gas of 50M). Reverted check: FAIL, `46222084 >= 2000000`. |
| GR1-45 | Venue liveness (Design) | **Documented** in docs/gains/VENUE-LIVENESS.md (CLOSE_ONLY, PAUSED, a pair no longer served, a USDC blacklist, a layout change), with what each role can do. No webapp change. |
| Slither / Aderyn | Zero sequencer feed; create() writes after the ETH call; minGovFee divides first | **Fixed:** the zero feed (GR1-10) and create() CEI (F1-13 in AUDIT-DIFF; no behaviour change, so no test). **Accepted:** minGovFee, under 1e-6 USDC. |

## 5. Earlier bugs fixed on this branch

| Bug | Fix | Test | Reverted check |
|---|---|---|---|
| GainsVaultPolicy enforced pairMinPositionSizeUsd as a size floor | `checkOrder` no longer has the check; `Order.minPosition` is removed. Gains' own minimum (5 × pairMinFeeUsd of collateral) is the only floor, and the vault still checks it. | `R1Regression.test_policyDoesNotEnforcePairMinPositionSize` (a 200 USD position below the 285.7 USD fee basis opens; 0.4 USDC below Gains' minimum is refused); `GainsBranches` / `GainsVault` updated | **FAIL** with the floor put back: `OrderRejected("position below min")` |
| Executor minimum = max(the executor minimum-trade setting, pairMin) | the executor minimum-trade setting only (`core/minimums.ts`) | `gains-min-trade.test.ts` | **FAIL** on the reverted file: `expected 'SKIPPED' not to be 'SKIPPED'` |
| MAINNET-OWN-CAPITAL.md step 8: "the seed stays in the vault" | The seed goes to the first depositors, not back to the owner. The check now expects dust in the vault and about D + 1 USDC on DEPOSITOR. | (docs) | |

**Mutation-gap tests** (tools/MUTATION.md survivors), re-checked by re-applying each mutant:

| Mutant | Test | Result |
|---|---|---|
| GainsVaultLogic#952 | `R1Regression.test_MUT952_twoSeparateCarryRunsEachPricedInItsOwnEpoch` | FAIL, `run 2 starts at its own epoch: 1 != 4` |
| GainsVaultPolicy#207 | `R1Regression.test_MUT207_checkOrderBandEdgesBothSides` | FAIL, `long at mark + band` |
| GainsVaultPolicy#753 | `R1Regression.test_MUT753_applyTimelockDelayClearsThePending` | FAIL, `nothing pending after the apply: 1700172800 != 0` |

The three mutants are now killed.

### Round 2: the verification pass's findings (VERIFY-R1 GV-01 to GV-06)

Rules as in round 1: every code fix has a regression test asserting the fixed behaviour, and the fix was undone to show the test fails. **How the reverted check was done this time:** the three contract fixes were undone together in the worktree, after they were committed (2e80b50), with the old lines put back by hand; the build ran, `R2Regression` ran, and the files were restored with `git checkout` (round 1 used a scratch copy). Raw output: [fixes/revert-check/results-round2.txt](fixes/revert-check/results-round2.txt). The executor fix (GV-04) was checked by stashing its source file.

| Finding | Fix | Regression tests | Reverted check |
|---|---|---|---|
| **GV-02** (Low) An unknown pending-order type neither holds settle nor counts in NAV | GainsNav `_pendingEffect` lists every type. Hold nothing: MARKET_CLOSE, MARKET_PARTIAL_CLOSE, UPDATE_LEVERAGE increase, MARKET_PARTIAL_OPEN with collateral 0, and Gains' own trigger executions (LIMIT_OPEN, STOP_OPEN, TP_CLOSE, SL_CLOSE, LIQ_CLOSE). Hold collateral: MARKET_OPEN, MARKET_PARTIAL_OPEN with collateral, UPDATE_LEVERAGE decrease. **Any other type** (10, PNL_WITHDRAWAL 11 which the vault never creates, 12, 13, a future value) blocks settle and its collateral counts in NAV: fail closed, as round 1's settle did for every order. GR1-04's fix is kept for the known types. | `R2Regression.test_GV02_unknownOrderType_blocksSettleAndCountsInNav` (VERIFY-R1's PoC: the 15k open reported as type 10, 11, 12, 200: settle reverts `OrdersPending`, NAV equals the known type's), `test_GV02_knownNonHoldingTypes_stillDoNotBlock` | **FAIL:** `unknown type: settle waits`. The "known non-holding" test passes on the old code too, by design: it guards the GR1-04 half that must not change. |
| **GV-01** (Info) A field inserted before positionSizeToken is misread silently | GainsNav: every **open** element of the trade list must be one Gains can hold: leverage > 0, openPrice > 0, collateralAmount > 0, tradeType ≤ STOP, else `DiamondLayoutChanged()`. In the NAV snapshot an open market trade's `positionSizeToken` must be within a factor of 4 of collateral × precisionDelta × leverage / openPrice (zero included), else `DiamondLayoutChanged()`. Gains keeps the two consistent through partial opens (size-weighted open price), partial closes and leverage updates (constant size), so a real trade is far inside the bound (the test's 10% drift values normally). Closed elements may hold zeros and are still read past. The NatSpec now says what holds: appended fields are read past, an insertion is caught by these checks. | `R2Regression.test_GV01_fieldInsertedBeforePositionSize_revertsLayoutChanged` (VERIFY-R1's PoC layout: venue() and the 10k × 20x open now revert instead of passing a 3x policy at 4.7x), `test_GV01_openTradeWithImpossibleSize_revertsLayoutChanged` (size 0, ÷5, ×5 revert; +10% values), `test_GV01_implausibleOpenTrade_revertsLayoutChanged` | **3 / 3 FAIL:** `next call did not revert as expected` (the PoC layout is read and the open accepted; size 0 / ÷5 / ×5 are read); `panic: division or modulo by zero (0x12) != DiamondLayoutChanged()` (an open trade with openPrice 0 panics deeper in the old code instead of naming the layout) |
| **GV-03** (Info) The sequencer rotation adopts the factory's feed at execution, with any grace | The vault's timelocked call is now `setSequencerFeed(address feed, uint256 gracePeriod)` (queued length 68). **At queue time** the governance checks that both equal the factory's current values (`SequencerFeedNotCurrent()` otherwise): what the owner reviews is what executes. **At execution** the policy sets the queued values; a factory change after the queue is not adopted (the owner queues again). The grace period is bounded to **1 h ≤ grace ≤ 1 day** (`SequencerGraceOutOfRange(grace)`) in the factory constructor, the factory setter and the policy setter. Deployed factory: unchanged (immutable); the bound applies to the next deployment, whose script already uses 3,600 s. | `R2Regression.test_GV03_rotationAdoptsWhatWasQueued_notTheFactoryAtExecution` (queue (seq2, 2 h); the factory moves to (seq3, 1 day); execution adopts seq2 / 2 h; values other than the factory's cannot be queued), `test_GV03_graceBounded_factoryConstructorAndSetter` (365 days, 1 h − 1 s, 1 day + 1 s, 0 refused; 1 h and 1 day accepted), `test_GV03_policySetterBoundsGrace`; GR1-10 tests adapted (`R1Regression`, `Governance`, `PolicyMatrix`, `FactoryMatrix`, `AccessMatrix`) | **3 / 3 FAIL** with the round-1 behaviour (adopt the factory's values at execution, no queue check, no bound): `next call did not revert as expected` (a mismatched queue, a 365-day grace and an out-of-range policy grace are all accepted) |
| **GV-04** (Low) Decoy closes still cost the gov fee; the rate alarm counts reduces only | Small and safe, so fixed: the executor's alarm consumes `CloseRequested` as well as `ReduceRequested` (one consumer, two topics), counted together per caller and vault (more than 10 in 10 minutes alerts). The text names both. Nothing changes on chain. | server `gains-r1-lows.test.ts` "GV-04: decoy closes count too" (6 closes + 4 reduces: quiet; the 11th, a close: one alert) | **FAIL** with `reduceRate.ts` stashed: `expected [] to have a length of 1 but got +0` |
| **GV-05** (Info) Anyone can make a redemption settle wait up to an hour | **No code change** (as VERIFY-R1 recommends). Queuing MIN_DEPOSIT turns the manager's next normal settle into one that prices deposits, which waits until the epoch is an hour old (GR1-02 (b)). The age counts from the epoch start, so a later deposit does not extend it; emergency and redemption-only settles do not wait. It matters only for a vault that settles more often than hourly; the keeper settles daily. Documented in section 6. | VERIFY-R1 V20e (on `verify/gains-r1`) | n/a |
| **GV-06** (Info) A non-holding order's fill steps NAV after a settle that ran beside it | **No code change.** A leverage-only increase holds nothing, so settle runs while it is pending (GR1-04); its fill then books Gains' fees on the added size and puts the band on it. A redemption settled in between is paid at the NAV before the step. The same as sending the order one block after the settle: bounded by one order's fees, the band part comes back to the holders at the close, and nobody can repeat it for profit. Documented in section 6. | VERIFY-R1 V24a, VF leverage fill | n/a |

**Control:** with nothing undone, `R2Regression` 8 / 8 pass, and the adapted GR1-10 / governance / matrix suites pass (section 8, Round 2).

### R2-01: the second verification pass's finding (VERIFY-R2)

| Finding | Fix | Regression tests | Reverted check |
|---|---|---|---|
| **R2-01** (Low) A degraded-mode flatten raises the "revoke the caller" alarm | Executor only (526a08f). The reduce-rate alarm counts **one transaction once** per caller and vault, so `flattenIndices` with many indices is one event, whoever sends it. The consumer **skips the vault's guardian and owner** as callers (read through the chain's 5 min cached `guardian()` / `owner()`; if that read fails, nobody is skipped). Repeated transactions from any other caller still count, so a grind by an online key still alerts at the 11th transaction in 10 minutes. Nothing changes on chain. | VERIFY-R2's PoC `test/audit/gains/verify-r2/executor/verify-r2.test.ts`: the two FINDING cases became "guardian's 20-index flattenIndices: quiet", "one transaction counts once (agent): quiet", "guardian and owner over 11 transactions each: quiet", with "11 agent transactions in a minute still alert" and "a failed guardian / owner read skips nobody" kept as guards (9 / 9 pass). In the executor suite: `gains-r1-lows.test.ts` "R2-01". | **FAIL** with `reduceRate.ts` restored to the old code: PoC 3 / 3 (`expected ... length of +0 but got 1`, `... got 1`, `... got 2`), the two guards pass by design; `gains-r1-lows` R2-01 (`... got 3`). |

## 6. Behaviour changes depositors and operators should know

- **Bid / ask while trades are open (GR1-02).** A deposit settled while trades are open buys at the favourable edge, and a redemption is paid at the adverse edge.
  - A round trip while trades stay open costs about 2 × B × the depositor's share of the open notional. Example: 0.58% for 100k into a 100k vault holding 290k of notional at B = 20 bps (`XReview.test_XR_NAVBIAS_passiveInAndOutWhileOpenPaysTheSpread`).
  - That cost goes to the holders who stay.
  - Depositing while the vault is flat costs nothing extra.
- **Deposits lift the share price while trades are open.** Because of the premium above, a settled deposit raises the holders' share price by about 2 × B × the vault's leverage × deposit / NAV. Daily loss and drawdown can therefore improve on a deposit flow; they never worsen.
  - A large deposit can pull a vault back from a drawdown edge, but only by paying the band to the holders.
  - The R-01 tests and the flow invariants are now one-directional.
- **A settle that prices deposits waits an hour into the epoch.** Exits never wait: redemption-only and exit-only settles are unaffected.
- **Closes in flight no longer hold settle.** Only an open, an increase with collateral or a leverage decrease does.
- **Once an epoch is overdue, the vault takes no new risk** until it is settled. The keeper settles daily, and the live policy's maxEpochDuration is 1 day.
- **A full stop cancels resting limit / stop orders.**
- **The policy has no owner of its own.** Changes to it are signed by the vault's owner and follow a vault transfer.
- **flatten(0) slippage is capped** at maxFlattenSlippageBps (3% at most).
- **Round 2 (VERIFY-R1):**
  - **A redemption settle can wait up to an hour (GV-05).** Anyone who queues a deposit (MIN_DEPOSIT is enough) makes the next normal settle one that prices deposits, which runs at least an hour into the epoch. Emergency and redemption-only settles never wait, and a later deposit does not extend the wait.
  - **A leverage-only increase does not hold settle, and its fill steps NAV (GV-06).** A redemption settled while it is pending is paid at the NAV before the fill books the fees on the added size. Bounded by one order's fees.
  - **An unknown pending-order type holds settle (GV-02).** If Gains ever reports a type the vault does not list, settles wait (OrdersPending) until it fills, is cancelled or times out; anyone may `cancelTimedOut` after Gains' timeout. Exits are unaffected.
  - **A trade list Gains could not produce stops the priced paths (GV-01).** An open trade with zero leverage, open price or collateral, an unknown trade type, or a size more than 4x off its collateral × leverage / open price reverts `DiamondLayoutChanged()`: NAV, deposits, settle and new risk stop, exits (`flattenIndices`, a full stop) keep working, as for any unreadable layout (GR1-08, VENUE-LIVENESS.md).
  - **Rotating the sequencer feed (GV-03):** the owner queues `setSequencerFeed(feed, grace)` with the factory's current values (read them from the factory first); a change in the factory after the queue needs a new queue. The grace period is 1 h to 1 day.
- **R2-01 (VERIFY-R2):** the reduce / close rate alarm no longer counts the vault's guardian and owner, and counts a transaction once; a `flattenIndices` during an incident stays quiet. A close-all by the agent in 11 or more separate transactions within 10 minutes still alerts, by design.
- **Gas at 20 positions** (fork): totalAssets 7.80M, checkRisk 7.81M, settle 8.05M without and 13.40M with queued deposits, openTrade 8.81M, increaseTrade 8.80M, flatten of 20 trades 24.3M. Every call fits Arbitrum's 32M.

## 7. Corrections to ROUND1

- **GR1-01's "about 31x"** assumed 20 open trades and 20 concurrent increases. `MAX_POSITIONS = 20` counts trades plus pending orders, so at most 10 trades + 10 increases fit.
  - Under a 3x policy with each increase passing alone, the old code reached about 16.5x (`test_GR1_01_tenConcurrentLeverageIncreasesRefusedAtThePolicy`: all ten accepted on the old code).
  - Up to about 25x was possible with tiny, high-leverage starting trades.
  - The severity (High) is unchanged.
- **GR1-03 alone does not transfer value** once GR1-02 is fixed: the confederate cycle needs both. The 200x valuation error itself is fixed.

## 8. Gate

All gates were run on the final commit of this branch, the heavy ones one at a time with nothing else running.

| Gate | Result |
|---|---|
| `forge test`, full, Arbitrum RPC | **94 suites, 759 passed, 0 failed, 2 skipped** (1,417 s). The 2 skips are the same as in the baseline. |
| Invariants at 2,048 × 500 | `invariant_spec`: **pass**, runs 2,048, calls 1,024,000, reverts 1,165. The other invariant suites (Round4, GainsRound4, Reaudit) also pass at their own configured runs. |
| Medusa, 1 h cap | **19 / 19 passed** (12 assertion tests, 7 properties), 7,470,737 calls, 0 failures, 4,799 branches. Round 1 ran 1,439,150 calls. |
| Executor (`server/`) | `npm test`: **910 passed, 0 failed, 6 skipped**, 77 files. `tsc --noEmit` clean. |
| Gas at 20 positions | totalAssets 7,804,704; checkRisk 7,810,271; settle 8,051,831 with no deposits queued, 13,404,159 with deposits queued; flatten (20 trades) 24,335,507. Table in docs/gains/AUDIT-DIFF.md. |
| Fork replay | `VaultReplayFork` **20 / 20 pass**; `NavReplayFork.test_diff_replayRealCloses` and `GainsForkReplay` (2) pass. |
| AUDIT-DIFF.md | Updated with the section "Fix round 1 changes to contracts/src/gains" (F1-1 to F1-13) and the gas table. |
| Reverted checks | Every fix's regression test fails with the fix undone (section 1). Control: 50 / 50 pass. |

### Round 2 gate

Run on the round 2 commits of this branch (merge of `origin/main` 544808a included), the heavy runs one at a time.

| Gate | Result |
|---|---|
| `forge test`, full, Arbitrum RPC | **95 suites, 767 passed, 0 failed, 2 skipped (1,901 s); round 1's 759 plus the 8 R2Regression tests, the same 2 skips** |
| Invariants at 2,048 × 500 | `invariant_spec`: **pass, runs 2,048, calls 1,024,000, reverts 1,138 (1,550 s run alone); the other invariant suites pass at their own configured runs in the full run** |
| Executor (`server/`) | `npm test`: **923 passed, 0 failed, 6 skipped, 81 files**. `tsc --noEmit` clean. `contractErrors.ts` regenerated (+ SequencerFeedNotCurrent, SequencerGraceOutOfRange). |
| Reverted checks | GV-01 3 / 3, GV-02 1 / 1 (+1 guard by design), GV-03 3 / 3, GV-04 1 / 1 FAIL with the fix undone (table above). |
| Not re-run | Medusa, Halmos, the fork replays and gas at 20 positions: the round 2 changes add a few comparisons per open trade to the NAV read and none to the exit paths. |

### R2-01 gate

Run on 526a08f plus this document (VERIFY-R2 cherry-picked, its Solidity tests included in the full run).

| Gate | Result |
|---|---|
| `forge test`, full, Arbitrum RPC | **97 suites, 775 passed, 0 failed, 2 skipped (1,775 s); round 2's 767 plus VERIFY-R2's 8 (VerifyR2Fork 7, VerifyR2Mock 1), the same 2 skips** |
| Executor (`server/`, fresh clone) | `npm test`: **921 passed, 0 failed, 7 skipped (80 files) plus startup 2 / 2; the 7th skip is contract-errors, which needs forge artifacts and passes 5 / 5 in the worktree**. `tsc --noEmit` clean. VERIFY-R2 executor PoC: 9 / 9 pass. |

The NAV-diff data lives only in `contracts/audit/gains/nav/data/`. Its dumps are written only with `NAV_DIFF_DUMP=true`, so a test run leaves `deployments/` untouched.
