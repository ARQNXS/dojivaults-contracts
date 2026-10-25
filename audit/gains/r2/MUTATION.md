# Gains round 2: mutation testing (domain MUT)

**Internal, AI-assisted review. Not an independent audit.**

Source under test: `contracts/src/gains/*` at 4ec6feb (branch `audit/gains-r2`), never edited. Every mutant ran in a
scratch copy under the session scratchpad (`.../scratchpad/mut/`), never in the worktree. Drivers and the line list
are committed in mutation/ (not included) (`lines.py` is the authoritative line list).

STATUS (final for mutation, 2026-10-20 19:30): **every type-valid mutant has run (2,115 of 2,115)**. **Final score:
2,031 killed / (2,031 + 79 survived) = 96.3%** (compile failures excluded and counted separately: 2,636 type check +
5 via-IR; no timeout). 78 of the 79 survivors are equivalent with a written argument; 1 (Logic R140) is open with no
fund effect (section 6). With the equivalents out: 2,031 / 2,032 = 99.95%. No surviving mutant reveals a contract
bug; no finding. Raw data: mutation/data/ (timeline.txt is the heavy-lock timeline; logs/ holds the b2 and b3 logs).

## 1. Fund-moving lines

Only lines that move USDC or shares, value them, charge fees, bound the operator, or gate those moves through a policy
check. Tier 1 = run exhaustively first; tier 2 = run after tier 1 (also exhaustively, time permitting). Line numbers
are those of 4ec6feb. "Unique" = Gambit mutants on the line range after removing byte-identical mutants, plus the
supplementary operators of section 2. "Type-valid" = passes a plain `solc` type check (the rest are compile failures,
counted separately and never in the score).

**GainsVaultLogic.sol**

| lines | tier | why fund-moving | unique mutants | type-valid |
|---|---|---|---|---|
| 54-73 | 1 | requestDeposit: amount/min/cap/closed checks, insider routing to next epoch, transferFrom, queue accounting | 173 | 74 |
| 85-99 | 1 | requestRedeem: allowance spend, share escrow transfer, pending accounting | 60 | 27 |
| 107-125 | 1 | cancelDepositRequest: carried check, queue release, USDC refund | 59 | 28 |
| 130-137 | 1 | cancelRedeemRequest: escrow release | 34 | 12 |
| 142-146 | 1 | claim: settled/carried gate | 28 | 10 |
| 152-166 | 1 | _claimIfSettled: share and USDC delivery, reserve clamp | 93 | 40 |
| 174-177 | 1 | _rejoinCarry | 33 | 12 |
| 181 | 1 | _isInsider (deposit routing) | 35 | 5 |
| 186 | 1 | _lossBreach (redemption-only mode) | 39 | 6 |
| 222-347 | 1 | settle: modes, NAV, prices, mint/burn, partial fill, reserve, carry, HWM refs, epoch record | 721 | 291 |
| 361-395 | 1 | _accrueFees: management + performance fee, protocol split, mints, HWM | 279 | 132 |
| 403-409 | 1 | _checkpoint/_setCheckpoint: NAV bound | 15 | 9 |
| 425 | 2 | leaveHosted: protocol share drop | 17 | 8 |
| 433-435 | 2 | lowerProtocolShare | 34 | 16 |
| 446-453 | 1 | openTrade: new-risk gate, idle bound | 71 | 23 |
| 458-467 | 1 | openTrade: Order fields fed to the policy (notional, min collateral, nav, open notional) | 17 | 11 |
| 482-485 | 1 | openTrade: exact approval, open, clear | 3 | 3 |
| 499-524 | 1 | increaseTrade: checks, approval | 85 | 36 |
| 532-566 | 1 | updateLeverage: collateral delta, idle bound, approval | 83 | 52 |
| 574 | 2 | closeTrade auth | 6 | 3 |
| 592-599 | 1 | reduceTrade: operator bound | 55 | 16 |
| 665-667 | 2 | flatten auth + slippage | 24 | 6 |
| 728-737 | 2 | _flattenAuth | 135 | 30 |
| 755 | 1 | _trader | 35 | 5 |
| 762-765 | 1 | _newRisk | 19 | 10 |
| 771-773 | 1 | _mayExit | 79 | 13 |
| 777-778 | 1 | _checkOrder | 6 | 3 |
| 783-787 | 1 | _approve/_clearApproval | 11 | 5 |
| 824-829 | 2 | reentrancy guard | 15 | 7 |

**GainsNav.sol**

| lines | tier | why fund-moving | unique mutants | type-valid |
|---|---|---|---|---|
| 79-117 | 1 | snapshot: NAV value, valueHigh, notional, blocking count, pending held minus gov fee | 177 | 105 |
| 125-129 | 1 | blockingOrders (settle gate) | 23 | 14 |
| 153-184 | 1 | _pendingEffect: held collateral / added notional / blocks per order type | 206 | 68 |
| 214-218 | 1 | _valueAt | 19 | 16 |
| 247 | 1 | _nearLiquidation zero rule | 18 | 6 |
| 257-269 | 1 | _closingPrice | 35 | 20 |
| 275-276 | 1 | minGovFee | 23 | 22 |
| 281-284 | 1 | totalTradeFeesRaw | 50 | 37 |
| 288-293 | 1 | pnlPercent | 79 | 55 |
| 298 | 1 | fixedSpreadP | 14 | 11 |
| 304-306 | 1 | priceAfterImpact | 42 | 27 |
| 311-313 | 1 | tradeValuePure | 53 | 40 |
| 317-324 | 1 | _price cache | 48 | 22 |
| 470 | 2 | _plausible (layout guard) | 57 | 15 |
| 480-482 | 2 | _checkSize (layout guard) | 77 | 47 |

**GainsVaultPolicy.sol**

| lines | tier | why fund-moving | unique mutants | type-valid |
|---|---|---|---|---|
| 247-249 | 1 | navBoundLeverageBps | 25 | 19 |
| 271-284 | 1 | checkOrder: allowlist, slippage, price band, notional, min collateral, leverage | 167 | 89 |
| 290-293 | 1 | flattenSlippage | 40 | 19 |
| 304-320 | 1 | nextCheckpoint: settle NAV bound | 182 | 104 |
| 330-349 | 1 | proposeConfig/applyPendingConfig: loosening timelock | 43 | 19 |
| 368-380 | 2 | queueAllowAsset/allowAsset | 37 | 21 |
| 388-394 | 2 | setPairFeed | 94 | 23 |
| 437-438 | 1 | _checkEta | 27 | 15 |
| 448-459 | 2 | _allow | 49 | 23 |
| 466-469 | 1 | _checkNavBound | 23 | 11 |
| 473-480 | 1 | _validate | 223 | 47 |
| 484-488 | 1 | _isTighter | 121 | 31 |

**GainsVaultMath.sol** (the helpers the three files rely on for claims, NAV and conversions)

| lines | tier | why fund-moving | unique mutants | type-valid |
|---|---|---|---|---|
| 60-95 | 1 | mint / burn / transfer / spendAllowance | 102 | 57 |
| 103-105 | 1 | idleAssets | 25 | 19 |
| 111 | 1 | hardStop | 23 | 5 |
| 116-117 | 1 | priceAt | 25 | 19 |
| 150-164 | 1 | redemptionShortfall (operator bound input) | 114 | 54 |
| 170-176 | 1 | toShares / toAssets | 73 | 61 |
| 184 | 2 | epochOverdue | 14 | 8 |
| 207-227 | 1 | claimableWithCarry | 159 | 73 |

Not in the list (not fund-moving, or covered elsewhere): NatSpec and events, view getters, the agent slot
(setAgent / revokeAgent: access only), setSlTp / cancelOrder / cancelTimedOut (no USDC moves through the vault),
the trade-list decoders (`_list`, `_trade`, `_readPendingOrders` range checks: layout safety, covered by
R2Regression GV-01 / GV-02), GainsVaultLens, GainsVaultGovernance, GainsVaultFactory, GainsPrice, GainsTypes
(`operatorReduceCap` itself is in GainsTypes; its inputs and use in reduceTrade are mutated here, and it has Halmos
proofs, see HALMOS.md).

Totals: 396 source lines, 4,222 unique Gambit mutants + 529 supplementary = 4,751 unique mutants; 2,115 type-valid.

## 2. How the mutants were made and chosen

- **Gambit** (Certora, tag v1.0.6), all default operators, `--skip_validate`, on the four files; 5,973 mutants in
  total (GainsNav 1,786, GainsVaultPolicy 1,152, GainsVaultLogic 2,474, GainsVaultMath 561). Kept: those whose line is
  in section 1, then byte-identical mutants removed (none were; Gambit does not repeat itself here).
- **Supplementary operators (529).** On this build Gambit's binary-op operator replaces `>`, `<`, `==`, `&&`, `||`
  only by arithmetic operators (`+ - * / % **`), which never type-check in a boolean context, so it generates **no**
  boundary (`>` to `>=`), negation (`>` to `<=`) or logical (`&&` to `||`) mutants: exactly the class that tests caps,
  bounds and access rules. `mutation/supplement.py` adds them on the same lines: ROR (each relational operator to its
  boundary and its negation; `==` / `!=` swapped), LOR (`&&` / `||` swapped), UOD (a unary `!` deleted). They are
  reported separately as well as in the total.
- **Type pre-filter.** Every unique mutant was type-checked with plain solc 0.8.28 (analysis only, ~0.5 s each):
  2,636 fail (Gambit's arithmetic-for-comparison swaps, `true` / `-1` assigned to a uint, ...). These are
  compile failures, counted separately, never run. Mutants that type-check but fail the via-IR build (stack too deep)
  are found by the run and are also counted as compile failures.
- **No sampling.** Round 1 sampled 110 mutants because one compile took 3.5 to 8 minutes (section 3 says why that is
  no longer true). This round runs **every type-valid mutant on every listed line** (2,115), in priority order so that a
  cap would cut the least important ones: P1 = tier-1 lines with the core operators (delete statement, if
  true / false, swap arguments, assignment to 0, the arithmetic inverse `+`/`-`, `*`/`/`, ROR, LOR, UOD, unary),
  P2 = the same operators on tier-2 lines, P3 = the rest (assignment to 1, `%`, `**`, other arithmetic). Round-robin
  over the four files inside each class (`mutation/queue.py`).

## 3. Harness and speed

- Gains-only scratch copy of `contracts/` (`mutation/mk-harness.sh`): src/gains and its imports; test/gains minus
  fork/ and spike/; the non-fork audit suites (R1Base, R1PoC, R1NavBias, AccessMatrix, gov/*, xreview/*, fixes/*
  (R1Regression, R2Regression), static/*, nav/NavUnit, integration/IntegrationMock, verify-r2/VerifyR2Mock,
  invariants/GainsSpecInvariants) and **every non-fork round 2 test** under test/audit/gains/r2 at the time of the
  batch (`mutation/r2copy.py`: no createSelectFork / createFork / rpcUrl / spike import, transitively). Excluded:
  `r2/ConfigLevers.t.sol` (does not compile under the fast profile: "Variable ... is 1 too deep in the stack"; it
  tests config levers, not fund flows) and test_ImplementationFitsEip170 (measures an unoptimised build).
- Profile (`mutation/foundry.toml`): via-IR with the optimizer sequence emptied (forge coverage --ir-minimum
  equivalent; the tree does not compile without via-IR); fuzz 64 runs. The two inline invariant campaigns are shrunk in
  the scratch copy only (`patch-inv.sh`): GainsSpecInvariants 2,048 x 500 -> 24 x 80, GainsRound4Invariants
  64 x 100 -> 12 x 60. Baseline on the unmutated tree: 334 / 334 tests pass in 27 s (before the round 2 tests
  were added; see section 4 for each batch's baseline).
- **Why round 1 never hit Foundry's cache.** `auto_detect_remappings` (on by default) re-derives the nested
  remappings of lib/openzeppelin-contracts(-upgradeable) on every run in a different order, the remappings stored in
  `cache/solidity-files-cache.json` never match, and the whole cache is invalidated ("missing cache entry" for every
  source). With `auto_detect_remappings = false` (the three remappings are listed explicitly anyway) the second build
  is "No files changed, compilation skipped" (1.2 s instead of 2 m 49 s). Same cause in the main repo; worth setting in
  contracts/foundry.toml (not done: outside this review's write scope).
- **Artifact-swap mode** (`mutation/run_mut.py`). Each worker has a src-only copy `s<k>` and a full test harness `w<k>`
  (built once). Per mutant: the mutant goes into `s<k>`, `forge build` there (incremental, a few seconds to 30 s), the
  src/gains artifacts are copied into `w<k>/out`, and `forge test --fail-fast` runs in `w<k>`, whose cache hits ("No
  files changed"; a recompile there is reported as an error). GainsVaultLogic, GainsNav and GainsVaultGovernance are
  external libraries linked from those artifacts at deploy time, and the suites deploy GainsVault / GainsVaultPolicy /
  GainsVaultLens / GainsVaultFactory / MockGainsDiamond through `deployCode` (round 1's fast_tests.py rewrite), so the
  tests run the mutant. The artifacts compiled in `s<k>` are not byte-identical to those of a full build
  (GainsVaultPolicy differs: via-IR codegen depends on AST ids) but are the same source with the same settings.
  Control mutants (the unmutated file through the same path) survive; known-bad mutants are killed (section 4).
  ~30 s per surviving mutant, 10 to 20 s per killed one, instead of 3.5 to 8 min.
- **Inlined functions.** Test contracts that call an internal library function inline it (NavUnit: pnlPercent,
  priceAfterImpact, tradeValuePure, toShares/toAssets; GainsBranches: pnlPercent, priceAfterImpact, tradeValuePure;
  VerifyR2Mock: minGovFee). For mutants on those functions the swap would compare the mutant against the pristine
  inlined copy, so those test files are excluded for those mutants (column `excluded` in results), and every survivor is
  re-run with an honest full compile of the mutated tree (section 5).

- **Batch b2 suite (refresh at 07:01-07:15).** The round 2 test folder had grown since b1; every non-fork file under
  test/audit/gains/r2 that compiles in the fast profile was added (r2copy.py: no createSelectFork / createFork /
  rpcUrl / spike import, transitively), by the v3 driver (mutation/refresh3.py: copy, rewrite deployments, build,
  run the r2 tests on the pristine tree and exclude any failing test by name; none failed). Included (13 files):
  ConfigTimelock, EconBase, EconDiff, EconPoC, FundFlowR2, LivenessStateMachine, MutationKills, MutationKills2,
  MutationKillsImpact, MutationKillsR4, XReviewEconCfg, XReviewKey, XReviewLiveGnsStateMachine. Excluded: every fork
  test and fork base (GainsSideFork*, Keys*Fork*, KeysForkBase, KeysReferrerFee (imports a fork base),
  LivenessGasFork, LivenessHistoryFork, liveness/LiveForkBase, XReviewKey*Fork*, XReviewLiveGns*Fork*), the
  folders executor/, econ/, symbolic/ (Halmos harness and its 100k-run fuzz twins), medusa/; ConfigLevers.t.sol (as
  in b1: stack too deep in the fast profile); **ConservationChecker.sol and its importer ConservationInvariants.t.sol**
  (via-IR "Variable ... is 1 too deep in the stack" in ConservationChecker under the fast profile, no source
  location; the conservation invariant campaign is therefore NOT part of the mutation suite). Baseline on the
  pristine tree with this suite: 451 passed, 0 failed, 2 skipped (52 suites, 19.5 s; test_ImplementationFitsEip170
  excluded by design). fast_tests.py now uses `vm.deployCode` in CommonBase helpers (ConservationWorld), which have
  no StdCheats.deployCode.
- **Orphans.** The first sub-reviewer left two `batch2.sh` waiters looping on the heavy lock (pids 11848, 26960).
  Killing them was refused by the permission system; they were defused instead (the scripts they call exit unless
  MUT_DRIVER=v3, and the worker harnesses were renamed w<k> -> x<k> so their baseline step is a no-op). Each took the
  lock once (05:19:04-05:19:07, 05:20:23-05:20:26) and ran nothing.

## 4. Timeline (heavy lock)

- 2026-10-19 21:59-23:38 setup (harness builds, Gambit, type check, control batch; 1 h 39 min, not counted in the cap).
- 23:38:34-01:28:57 batch b1, 4 workers, 1,018 mutants (1 h 50 min). Lock gap before b1 only 32 s.
- 01:35-06:53 no mutation: lock held by hl-r2 (sessions 1b-1d, async invariant, mutants session 2 + Halmos); the
  first sub-reviewer stopped; this sub-reviewer took over at 03:05 (15 min retry, as METHOD says; two free gaps were
  missed by it, reported to the lead at 06:16).
- 06:53:45 (1 s, SyntaxError in the new driver, nothing ran); 06:54:18-06:55:26 (stopped by me: fast_tests rewrite
  bug); 06:56:02-07:00:27 (stopped by me: ConservationChecker stack too deep, bisect fallback useless);
  07:01:13-07:15:56 (refresh OK, then the baseline gate stopped it: my --no-match-test regex ended in `$`, forge
  matches `name()`, so the excluded-by-design EIP-170 test ran); 07:16:39 (0 s, stale status file). About 21 min of
  lock in these attempts, counted in the cap.
- 07:16:52-08:54:17 batch b2, 4 workers (1 h 37 min): re-run of all 154 b1 non-killed mutants on the b2 suite, then
  the remaining 1,097 type-valid mutants of the queue (all of them; P1, P2, P3).
- 09:09 b3 queued; waited on hl-r2 (Halmos passes A-C) until ~10:45, when Claude Code stopped the waiter for low
  system memory. Not restarted until the owner's go-ahead (the laptop rebooted at ~14:50).
- 15:13 ONE combined runner (mutation/combined/combined.sh: the lead's invariant gate, MUT b3, CI forge, Halmos, CI
  Medusa; one heavy-lock queue, 15 min retry, 10 min release between stages). The MutationKills3 setups were fixed
  first (6 tests failed on the pristine tree: factory deposit cap, fake factory without maxDepositCap, a wrong supply
  estimate in the dust-fee tests; ca9ba81: 37 / 37 pass on the pristine tree in the worktree).
- 18:45:53-19:18:12 **batch b3** (stage 2, 32 min): refresh (MutationKills3 and MutationKillsNavPure added; same
  exclusions as b2; no pristine failure), baseline 494 passed / 0 failed / 2 skipped (60 suites), honest full compiles
  of the 8 inlined GainsNav survivors against MutationKillsNavPure (all KILLED, pristine PASS; data/logs/verify-b3.txt),
  Logic R235 re-run at a 40 min timeout (killed in 19 s by AccessMatrix test_accessMatrix_BD), and the re-run of the
  136 survivors on the full suite (data/results-b3-rerun.csv).
- **Mutation cap used: about 4 h 22 min of 12 h** (b1 1 h 50 min, b2 1 h 37 min, failed b2 starts ~21 min, b3 32 min;
  setup 1 h 39 min on top). Cap not hit.

## 5. Results (status = last run; final)

Statuses: results.csv (b1 + b2 queue) overridden by results-b2-rerun.csv, results-b3-timeout.csv, results-b3-rerun.csv
and results-b3-honest.csv (the 8 inlined GainsNav mutants: in the artifact-swap run the test that inlines the helper is
excluded by design, so their kill is the honest full compile). Tables: mutation/data/report2.py with
data/equivalents.txt.

| scope | unique | compile-fail (type check) | compile-fail (via-IR) | run | killed | survived | of which equivalent | open | timeout | error | type-valid not run | score killed/(killed+survived) | adjusted (equivalents out) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| GainsVaultLogic | 2264 | 1371 | 5 | 893 | 855 | 33 | 32 | 1 | 0 | 0 | 0 | 855/888 = 96.3% | 855/856 = 99.9% |
| GainsNav | 921 | 416 | 0 | 505 | 482 | 23 | 23 | 0 | 0 | 0 | 0 | 482/505 = 95.4% | 482/482 = 100% |
| GainsVaultPolicy | 1031 | 610 | 0 | 421 | 416 | 5 | 5 | 0 | 0 | 0 | 0 | 416/421 = 98.8% | 416/416 = 100% |
| GainsVaultMath | 535 | 239 | 0 | 296 | 278 | 18 | 18 | 0 | 0 | 0 | 0 | 278/296 = 93.9% | 278/278 = 100% |
| **all** | 4751 | 2636 | 5 | 2115 | 2031 | 79 | 78 | 1 | 0 | 0 | 0 | **2031/2110 = 96.3%** | 2031/2032 = 99.95% |
| Gambit operators | 4222 | 2636 | 5 | 1586 | 1548 | 33 | 33 | 0 | 0 | 0 | 0 | 1548/1581 = 97.9% | 1548/1548 = 100% |
| supplement (ROR/LOR/UOD) | 529 | 0 | 0 | 529 | 483 | 46 | 45 | 1 | 0 | 0 | 0 | 483/529 = 91.3% | 483/484 = 99.8% |
| tier 1 lines | 4192 | 2284 | 5 | 1908 | 1826 | 77 | 76 | 1 | 0 | 0 | 0 | 1826/1903 = 96.0% | 1826/1827 = 99.9% |
| tier 2 lines | 559 | 352 | 0 | 207 | 205 | 2 | 2 | 0 | 0 | 0 | 0 | 205/207 = 99.0% | 205/205 = 100% |

- **Final score: 2,031 killed / (2,031 + 79 survived) = 96.3%**; compile failures excluded and reported separately
  (2,636 type check, 5 via-IR); no timeout, no error, no type-valid mutant left unrun. 78 of the 79 survivors are
  equivalent (argued); 1 is open (Logic R140, below). Every kill counted is a run of the suite (or, for 8 inlined
  helpers, an honest full compile) against the mutant, with a pristine baseline that passed.
- Progression: b1 863 / 1,016 = 84.9% (1,018 run) -> b2 1,973 / 2,109 = 93.6% (all run; 88 of the 154 b1 non-killed
  mutants killed by the round 2 tests, 1,022 of the 1,097 new ones killed) -> b3 2,031 / 2,110 = 96.3% (57 of the 60
  targeted survivors killed by MutationKills3 / MutationKillsNavPure: 49 in the swap run, 8 by honest compiles; R235
  killed at the longer timeout).
- None of the 76 survivors argued equivalent before b3 was killed by the b3 suite (consistent with the arguments).

## 6. Surviving mutants and disposition

All 79 survivors are in data/final-survivors.txt.

**Equivalent (78), with a written argument in data/dispositions.md** (data/equivalents.txt). Grouped:
equality-only boundaries (`>` vs `>=` where both arms give the same value: Math R488, R495, R497, R506, R528; Policy
R366, R379 (the ternary `nav > prev`; at equality both arms are 0), R385, R387; Logic R47, R114, R120, R142, R148,
R151, R168, R175, R179; Nav R275, R277, R311, R314, R316, R318, R320); unreachable states argued from invariants of
the code (Math #14, #174, #365, #373, #484, R504 (Gains' DecreasePositionSize rule, verified source), R512, R514,
R519, R520, R523, R525, R526; Logic #185, #268, #383, #391, #392, #394, #405, #425, R50, R51, #1111, #1113, #1364
(the factory's protocol fee recipient can never be 0), R153, R160, R170 (feeShares == 0 leaves the supply, hence the
price, unchanged), R206 (both branches revert on Gains' WrongLeverage), #1749, R203; Policy R371; Nav R299 (Gains'
WrongLeverage rule)); valueHigh only read by settle, which reverts on pending orders first (Nav #37, #58, #112,
#142-#145, #147, #150, #151; Logic R98, R100, R101); gas-only (Nav #698, #800, #813, #841, #843 (navPrice cache),
Logic #568 (reentrancy lock on a path with STATICCALLs only)).

Two of the 60 targeted survivors turned out equivalent in b3, the targeting was wrong, not the test:
Policy R379 mutates the ternary `nav > prev`, not the `> cap` the test pins; Logic R170 is `feeShares > 0` -> `>= 0`
in the rescale guard, which never differs (the test pins #1425 / R172 / R173 instead). Both tests stay (they pin real
boundaries and kill other mutants).

**Open (1): Logic R140** (L325 `supply == 0 && depShares > 0` -> `depShares >= 0`). Not killed by
test_MUT_LogicR140_emptySettleKeepsTheRiskReferences: on an empty settle the mutant writes toAssets(ONE_SHARE, nav,
0) = 1e6 into highWaterMark and peakSharePrice, which ARE their initial values (initialize sets both to 1e6), so the
test's assertions on them cannot fail. The mutant's only other write is dayStartSharePrice = 1e6. That value is not
read while the supply is 0 (_check computes the daily loss only with supply > 0) and is overwritten by the first mint
(the same branch with depShares > 0), so it has no fund or risk effect; it is visible through the getter. An assertion
on dayStartSharePrice was added after b3 (passes on the pristine tree, worktree run) but has NOT been re-run against
the mutant (the heavy lock is with the combined runner's later stages). Classified open, not killed, not equivalent.

**Killed by the round 2 kill tests (proven in b3):** see data/results-b3-rerun.csv (killing test per mutant) and
data/logs/verify-b3.txt (honest compiles). 31 tests of MutationKills3 / MutationKillsNavPure kill at least one
mutant.

**Findings.** None. No survivor reveals a contract bug. Observations (no fund effect, not findings):
cancelRedeemRequest's _claimIfSettled is dead code (b1); _accrueFees silently skips a management fee that would reach
the NAV (50+ years without an accrual at 2%; favourable to depositors); a checkpoint of 0 can be stored (emergency
settle at NAV 0, or a checkRisk at NAV 0 with maxNavMoveBps = 100%), and the pricing code then correctly falls back
to the live NAV (R111 / R117, killed).

**Not in the mutation suite:** the conservation invariant suite (ConservationChecker / ConservationInvariants:
stack too deep in the fast profile), ConfigLevers.t.sol (same), fork tests, symbolic/, econ/, executor/, medusa/.
