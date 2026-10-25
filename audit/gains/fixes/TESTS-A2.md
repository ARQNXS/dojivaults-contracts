# Gains round 1 fix: tests, sub-fixer A2

Scope: `test/audit/gains/gov/`, `test/audit/gains/AccessMatrix.t.sol`, `audit/gains/ACCESS-MATRIX.md`, `test/gains/`
(including `fork/`). Branch `fix/gains-r1`. No file under `src/` was changed.

## 1. Round 1 PoCs turned into regression tests

Each one asserts the fixed behaviour, so it fails on `audit/gains-r1`. GR1-10 does not even compile there:
`setSequencerFeed` does not exist yet.

| Original test | New name | Finding | What it asserts now |
|---|---|---|---|
| `gov/Governance.t.sol::test_GOV_06_sequencerFeedCannotBeRotated` | `test_GR1_10_sequencerFeedRotatesThroughTheTimelock_zeroRefused` | GR1-10 | The factory constructor refuses a zero sequencer feed. `factory.setSequencerFeed` is owner only and refuses zero. An existing vault keeps its feed until the timelock runs: direct `vault.setSequencerFeed()` is `Unauthorized` and `policy.setSequencerFeed()` is `NotVault`. The queue takes exactly 4 bytes. After queue, delay and execute, the policy holds the new feed and grace, and a vault that was frozen by a dead feed (`SequencerDown`) checkRisks and settles its redemption again. |
| `gov/Governance.t.sol::test_GOV_03_vaultTransferLeavesPolicyWithOldOwner` | `test_GR1_12_policyOwnershipFollowsAVaultTransfer` | GR1-12 | `policy.owner()` follows the vault's two-step transfer: unchanged before accept, the new owner after. The previous owner gets `OwnableUnauthorizedAccount` on proposeConfig / disallowAsset / proposeTimelockDelay, and no leverage breach can be forced. The new owner tightens and disallows. Policy transfer / accept revert `OwnershipFollowsVault`. |
| `gov/Governance.t.sol::test_GOV_04_policyRenounceFreezesConfigAndPendingLooseningStillApplies` | `test_GR1_30_policyRenounceRevertsOwnerKeepsTheVeto` | GR1-30 | `renounceOwnership` reverts `OwnershipFollowsVault` for the owner and for a stranger. The owner keeps the policy and cancels the pending loosening. A stranger then has nothing to apply (`NothingPending`), and the config is unchanged. |
| `gov/Governance.t.sol::test_GOV_05_disallowedPairRotationBlockedByLaterLeverageRaise` | `test_GR1_31_navBoundCoversDisallowedPairs_rotationStaysOpen` | GR1-31 | With SOL listed but disallowed (and still holding a trade), raising maxLeverageBps above SOL's NAV bound reverts `LeverageAboveNavBound(SOL)` at proposeConfig. The SOL feed rotation then executes. |
| `gov/HLRetest.t.sol::test_HL_I302_insiderDepositForVictimBlocksItsRedeemUntilSettle` | `test_GR1_32_cancelledDeferredDepositLiftsTheRedeemBlock` | GR1-32 | Cancelling the manager-sent deferred deposit refunds alice and zeroes `deferredDepositAssets`. `requests(alice).epoch` is back to `currentEpoch`. Her `requestRedeem` goes in at once (no settle needed) and then settles normally. |

Kept as they were. These findings are not fixed or are accepted; only the shared setup changed:
`OperatorBound.test_GOV_01_*` (GR1-11), `OperatorBound.test_GOV_OB_*` (GR1-33 accepted),
`HLRetest.test_GOV_02_*` (GR1-29 accepted), and the other HL retests.

## 2. Other tests changed, and why

The shared base first.

**`GainsBase.t.sol` (inherited by every suite).** I made no change of my own. I use the lead's `_ageEpoch(v)` and
`_settle()`.

**`gov/GovBase.t.sol::_fundFv`.** I added `_ageEpoch(fv)` before the keeper's settle. A deposit-pricing settle needs
INSIDER_MIN_EPOCH_AGE (GR1-02). This fixed 11 gov tests that failed with `EpochTooYoung`.

### Gov tests

| Test | Change | Why |
|---|---|---|
| `Governance.test_GOV_TL_queue_ownerOnly_exactSelectorsAndLengths` | Added `setSequencerFeed()` (length 4) to the accepted queue items. | GR1-10: a new timelocked selector. |
| `HLRetest.test_HL_I03_V03_renounce` | The policy's renounce now expects `OwnershipFollowsVault`, and the owner is unchanged. | GR1-30 |
| `PolicyMatrix.test_GOV_PM_ownerOnlyFunctions` | transferOwnership / renounceOwnership by non-owners now expect `OwnershipFollowsVault`, not `OwnableUnauthorizedAccount`. | GR1-12 / GR1-30 |
| `PolicyMatrix.test_GOV_PM_ownershipTwoStepAndRenounceAllowed` | Replaced by `test_GOV_PM_ownershipFollowsTheVault_noTransferNoRenounce`. Transfer, accept and renounce revert for every actor. A vault transfer moves the policy; the old owner is refused and the new one is accepted. | GR1-12 / GR1-30 |
| `PolicyMatrix` (new) | `test_GOV_PM_setSequencerFeed_vaultOnly`: every actor except the policy's own vault gets `NotVault`. The vault copies the factory's current feed and grace. | GR1-10 |
| `FactoryMatrix.test_GOV_FM_ownerOnlySetters` | Added `setSequencerFeed`: non-owners are refused, the owner works, and zero reverts `ZeroAddress`. | GR1-10 |

### `test/gains/` (mock suites)

| Test | Change | Why |
|---|---|---|
| `GainsPolicyAndFactory` (7 settle sites in 10 tests and `_earnFees`) | `_ageEpoch(v)` before the deposit-pricing settle. | GR1-02 `EpochTooYoung` |
| `GainsRound4.GainsRound4FactoryTest.setUp` | `_ageEpoch(v)` after alice's deposit. | GR1-02 |
| `GainsRound4.test_R01_depositDoublingTheVaultNeverResetsThePeak` | Ages the epoch. The drawdown assert is now one-way: `dd1 <= dd0 + 1`, and within 50 bps. | GR1-02: bob mints at the favourable edge, so the holders gain it and the drawdown shrinks (measured 1000 to 980 bps). |
| `GainsRound4.testFuzz_R01_flowsNeverMoveTheMetrics` | Ages the epoch. The metrics are one-way (never worse). They must stay unchanged within 1 bps only when no deposit is in the flow. | GR1-02 (the fuzz found daily loss going from 51 to 0 bps on a 2x deposit) |
| `GainsRound4.test_R01_dustVaultNeverBreachesOnRounding` | Ages the epoch. | GR1-02 |
| `GainsRound4.test_D4_C01_noMintAtADeflatedNav` | Tolerance 0.1% to 0.3%. Sybil's value `<= 100k`; alice's `>= 100k`. | GR1-02: sybil mints at the favourable edge of a 1x trade (−0.2%), and alice gains it. |
| `GainsRound4.test_R02_aPendingCloseIsNeitherANavDropNorSettledAround` | A pending partial close no longer gives `OrdersPending`: `ordersPending()` is false and settle reverts `InsufficientLiquidity(0, 5000e6)`. The trade is still valued as open and the USDC is not home yet. | GR1-04 |
| `GainsRound4.test_EmergencyUnwind_listedRolesOnly` | The flatten close in flight no longer holds the owner's exit-only settle. It settles at once and alice is paid pro rata from idle. | GR1-04 |
| `GainsRound4Invariants` handler `settle` | "In flight" now means `vault.ordersPending()` (an order that holds collateral). The flow metric invariant counts only worsening moves; improvements are counted in `settlesImprovedMetrics`. | GR1-04, GR1-02 |
| `GainsRound4Invariants` handler `seed` | `_skip(1 hours)` before the first settle. | GR1-02 |
| `GainsFeedRotation.test_DeprecatedFeed_settleBlocked_rotate_settleWorks` | `_skip(1 hours)` first, so the stale-feed settle fails on `PriceStale` and not `EpochTooYoung`. | GR1-02 |
| `GainsAdmin.test_LensEmergencyPreviewsAndOrderViews` | `lens.ordersPending` is false while a partial close is pending; `openPositions == 2`. | GR1-04 |
| `GainsExits.test_PricedPathsStopWithNamedErrors` | openTrade after the 7-day warp gives `EpochOverdue`, which comes before the price read. The settle expectation stays `OrdersPending`: the lead moved the price-free check back in front of the valuation. | GR1-04 |
| `GainsExits.test_BreachUnwindWorksWithoutPrices` | triggerEmergency already cancels the resting BTC limit (asserted), so the separate `cancelOrder` was removed. | GR1-16 |
| `GainsFlattenBatch.test_FlattenBatchesKeepTheRoles` | After triggerBreach the resting ETH limit is already cancelled (asserted). The owner's batch of 4 leaves 0, not 1. | GR1-16 |
| `GainsVault.test_DepositsFundRedemptionsInSameEpoch` | Tolerance 1 to 1e3 (0.001 USDC), and `<=`. | The settle now runs 1 h into the epoch: one hour of the 2% management fee. |

### `test/gains/fork/`

| Test | Change | Why |
|---|---|---|
| `GainsVaultFork.test_fork_timedOutOpenBlocksSettleUntilAnyoneCancels` | `_rollFresh(4 * 3_600)` after bob's deposit. | GR1-02 |
| `GainsVaultFork.test_fork_gasAtMaxPositions` | New reading for a settle that prices deposits (bob deposits 1,000), with a 14M budget. Every other reading keeps 10M. | GR1-02: two valuations per trade, only when deposits are priced. |

Gas at 20 positions (fork, after the lead's one-edge change):

| Call | Gas |
|---|---|
| increaseTrade (19 trades) | 8,804,085 |
| openTrade (19 to 20) | 8,811,730 |
| totalAssets (20) | 7,804,704 |
| checkRisk (20) | 7,810,271 |
| settle, no deposits (20) | 8,051,831 |
| settle with deposits (20) | 13,404,159 |
| flatten, 7 BTC trades at the ceiling | 8,986,120 |
| flatten, 20 ETH trades | 24,335,507 |

`fork/DeployGains.t.sol` fails `inconsistent link for GainsVaultGovernance` in setUp when run with `--out out-a2`.
`script/DeployGains.s.sol` reads hard-coded `out/...` artifacts, which are stale in this worktree. This is an
environment problem, not a contract one. Run it with the default `out` after a build.

## 3. Access matrix cells that changed

Vault matrix: 44 functions (41 + `flattenIndices` with slippage 0, `flattenIndices` with custom slippage,
`setSequencerFeed`) x 9 actors x 12 states = 4,752 cells, all matching. The mismatch counter stays a local.

| Function (index) | State | Actors | Round 1 | Now | Finding |
|---|---|---|---|---|---|
| settle (3) | OP | Mgr, Opr | OrdersPending | ✓ | GR1-04 |
| openTrade (5) | OD | Mgr, Agt | ✓ | EpochOverdue | GR1-04 |
| increaseTrade (6) | OD | Mgr, Agt | ✓ | EpochOverdue | GR1-04 |
| updateLeverage up (7) | OD | Mgr, Agt | ✓ | EpochOverdue | GR1-04 |
| updateLeverage down (8) | OD | Mgr, Agt | ✓ | EpochOverdue | GR1-04 |
| increaseTrade (6), updateLeverage up / down (7, 8) | OP | Mgr, Agt | `Error(string)` from the diamond | PendingOrderExists | GR1-01 |
| cancelOrder of the resting limit (14) | BG, EM | Mgr, Sen | ✓ | `Error(string)`: already cancelled by the full stop | GR1-16 |
| flattenIndices(0) (41) | all | as flatten(0) | n/a | new | GR1-08 |
| flattenIndices(custom) (42) | all | as flatten(custom) | n/a | new | GR1-08 |
| setSequencerFeed (43) | all | everyone | n/a | Unauthorized (self only) | GR1-10 |

`flatten(slippage 0)` now uses min(maxSlippageBps, maxFlattenSlippageBps) (GR1-41). With the matrix's 1% / 3% config
the value is unchanged, so no cell moves.

The ACCESS-MATRIX.md section 2 row "settle (guardian / sentinel / owner)" at OP said `OrdersPending`. The test had
always expected `Unauthorized` there (platform roles are refused outside em / loss breach / overdue). The row now
says ✗.

Policy (section 3): `setSequencerFeed` is vault only. Transfer / accept / renounce revert `OwnershipFollowsVault`, and
the owner is read live from the vault. Factory (section 4): `setSequencerFeed` is owner only and never zero.

## 4. Reported to the lead

1. Gas: every NAV reader went to about 13-14M at 20 positions (two valuations per trade). The lead changed src so
   that only a deposit-pricing settle values both edges. The numbers above are measured after that change.
2. settle ran the valuation before the OrdersPending check, so a stale feed plus a pending open gave `PriceStale`.
   The lead restored the price-free check first, and the test was reverted to `OrdersPending`.
3. GR1-02 side effect: a deposit settled while trades are open lifts the holders' share price by about 2 x band x
   leverage x deposit / NAV. Daily loss and drawdown can therefore improve on a flow, never worsen. The R-01 tests and
   the invariant are now one-way. The lead notes it for FIXES-R1.md.
