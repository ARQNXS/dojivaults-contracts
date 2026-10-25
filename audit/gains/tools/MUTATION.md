# Mutation testing, Gains round 1 (limited sample)

Tool: Gambit (Certora, tag v1.0.6), all default operators (binary-op, assignment, if-statement, delete-expression,
swap-arguments, unary-op). Tree: audit/gains-r1 (9f39013). Raw per-mutant results for the sample: `mutation-results.csv`
(next to this file; `status` is final, `status_before_accessmatrix_fix` is the first run). Harness scripts:
`mutation/` (fast_tests.py, run_mutants.py, select3.py, index_mutants.py, gen-mutants.sh, mk-harness.sh,
foundry.mutation.toml) and the test patch `mutation/deploycode.patch`.

**The run is limited** (lead's rule: cap at ~3 h; only security-relevant lines of GainsNav, GainsPrice,
GainsVaultPolicy, GainsVaultLogic (settle, fees, reduce, exits) and GainsVaultFactory (roles, curation)).
Gambit generated **8,493 mutants** over all 11 src/gains files (GainsNav 571, GainsPrice 299, GainsVaultLogic 2,379,
GainsVaultMath 561, GainsVaultGovernance 1,514, GainsVaultPolicy 1,134, GainsVaultFactory 944, GainsVault 163,
GainsVaultLens 870, GainsTypes 27, IGainsDiamond 31); **110 were sampled** and run. GainsVaultMath,
GainsVaultGovernance, GainsVault, GainsVaultLens, GainsTypes and IGainsDiamond are NOT in the scored sample.

## Result

Final score on the sample: **48 killed, 4 survived, 58 compile-fail ->
48/52 = 92.3%**
(score = killed / (killed + survived), compile-fails excluded). No surviving mutant shows a bug in the contracts.
Mutation testing found one bug **in a test**: test/audit/gains/AccessMatrix.t.sol could never fail (below). It was
fixed by the lead during this run; the score before and after the fix is shown separately.

### Final (with the fixed AccessMatrix.t.sol)

| file | generated | sampled | compile-fail | killed | survived | timeout | score killed / (killed + survived) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| GainsNav | 571 | 25 | 11 | 14 | 0 | 0 | 14/14 = 100.0% |
| GainsPrice | 299 | 20 | 11 | 9 | 0 | 0 | 9/9 = 100.0% |
| GainsVaultPolicy | 1134 | 20 | 13 | 5 | 2 | 0 | 5/7 = 71.4% |
| GainsVaultLogic | 2379 | 30 | 15 | 14 | 1 | 0 | 14/15 = 93.3% |
| GainsVaultFactory | 944 | 15 | 8 | 6 | 1 | 0 | 6/7 = 85.7% |
| **total** | **5327** | **110** | **58** | **48** | **4** | **0** | **48/52 = 92.3%** |

### Before the AccessMatrix fix (first run)

| file | generated | sampled | compile-fail | killed | survived | timeout | score killed / (killed + survived) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| GainsNav | 571 | 25 | 11 | 14 | 0 | 0 | 14/14 = 100.0% |
| GainsPrice | 299 | 20 | 11 | 9 | 0 | 0 | 9/9 = 100.0% |
| GainsVaultPolicy | 1134 | 20 | 13 | 5 | 2 | 0 | 5/7 = 71.4% |
| GainsVaultLogic | 2379 | 30 | 15 | 12 | 2 | 1 | 12/14 = 85.7% |
| GainsVaultFactory | 944 | 15 | 8 | 6 | 1 | 0 | 6/7 = 85.7% |
| **total** | **5327** | **110** | **58** | **46** | **5** | **1** | **46/51 = 90.2%** |

Differences: GainsVaultLogic#2009 survived -> killed (AccessMatrix fix); GainsVaultLogic#779 was a timeout (> 1,200 s
under the heavily loaded first run, original test harness) and was re-run: killed in 92 s
(test_DUSTCHECKPOINT_oneUsdcDonationFreezesNormalSettle). Before the fix, counting the timeout as killed:
47/52 = 90.4%;
excluding it: 46/51 = 90.2%.

The high compile-fail share is expected: Gambit ran with `--skip_validate` (its plain-solc validation hits the
stack-too-deep below on every file importing GainsNav), so type-invalid mutants (e.g. `<` -> `%` on a bool context)
reach forge, which rejects them in a few seconds.

## Test bug found: AccessMatrix.t.sol assertion was vacuous

`_runState` counted mismatches in a storage variable and every cell calls `_enter`, which runs
`vm.revertToState(base)` and rolled the counter back to 0, so `assertEq(mismatches, 0)` only saw the last cell.
Mutant GainsVaultLogic#2009 logged `MISMATCH state/fn/actor <s> 16 7` in 6 states and all 12 test_accessMatrix_*
passed. On the unmutated tree the suite logs 0 mismatches, so ACCESS-MATRIX.md's conclusions held, but nothing
enforced them. Fix (lead, in dv-audit-gains, not yet committed): `mismatches` is a local in `_runState`. With it the
mutant fails all 12 states (1 to 4 mismatches each). Regression PoC: `test/audit/gains/static/RevertToStateCounter.t.sol`
(reproduces the storage-counter-vs-revertToState pattern; passes, i.e. shows the counter is lost).
Other audit tests using vm.revertToState were checked (gov/FactoryMatrix, gov/Governance, gov/PolicyMatrix, R1PoC,
xreview/XReview, and test/gains/fork/GainsRiskParity): all assert inside the snapshot window before reverting, none
accumulates a result in storage across a revert. No other instance of the pattern.

## Sample definition

Only mutants whose line lies inside the listed functions (line ranges of the 9f39013 sources, LF-normalised) were
eligible; from those, a seeded (seed 7) round-robin over distinct source lines (one mutant per line per round) up to
the per-file budget, so the sample spreads over as many security lines as possible. Mutants of these functions run
in an earlier, aborted wider run are counted toward the budget (same semantics).

| file | generated | eligible (in listed functions) | sampled | functions (line range) |
| --- | --- | --- | --- | --- |
| GainsNav | 571 | 571 | 25 | snapshot (42-82), tradeValue (83-100), _nearLiquidation (101-124), _closingPrice (125-155), minGovFee (156-162), totalTradeFeesRaw (169-175), pnlPercent (176-185), fixedSpreadP (186-189), priceAfterImpact (190-195), tradeValuePure (196-201), _price (202-213) |
| GainsPrice | 299 | 299 | 20 | read (45-71), checkSequencer (72-80), adverse (81-86), _latest (87-94) |
| GainsVaultPolicy | 1134 | 979 | 20 | navBoundLeverageBps (223-232), checkOrder (247-266), flattenSlippage (267-275), nextCheckpoint (276-302), proposeConfig (303-316), applyPendingConfig (317-325), queueAllowAsset (341-348), allowAsset (349-360), setPairFeed (361-373), proposeTimelockDelay (374-386), applyTimelockDelay (387-397), _checkEta (398-402), _allow (409-425), _checkNavBound (426-432), _validate (433-443), _isTighter (444-452) |
| GainsVaultLogic | 2379 | 1352 | 30 | requestRedeem (80-105), cancelRedeemRequest (123-134), claim (135-144), _claimIfSettled (145-166), settle (212-340), _accrueFees (346-387), reduceTrade (568-590), flatten (640-685), _mayExit (707-712) |
| GainsVaultFactory | 944 | 670 | 15 | create (247-330), registerPlatformAgent (331-343), unregisterPlatformAgent (344-360), setGuardian (402-410), setSentinel (411-418), setAgentRegistrar (419-427), transferOwnership (428-433), setAssetCurated (442-460), _checkRoles (477-489) |

## Harness

- Gains-only scratch project outside the repo (copy of src/gains, the round 4 type files it imports: VaultTypes,
  VaultPolicy, hypercore/HyperCore, libraries/PxMath; test/mocks; test/gains minus fork/ and spike/; the non-fork audit
  suites R1Base, R1PoC, R1NavBias, AccessMatrix, gov/*, xreview/*, nav/NavUnit), as script/gains-coverage.sh does it.
  29 suites, 295 tests, test_ImplementationFitsEip170 excluded (it measures an unoptimised build, as in
  gains-coverage.sh). contracts/src in the repo was never edited; mutants were only copied over the scratch copy.
- **via_ir was kept** because the tree does not compile without it (stack too deep at GainsNav.sol:96 with the legacy
  pipeline, unmutated tree). Settings: via_ir with the optimizer sequence emptied (`optimizerSteps = ""`, stack
  allocation on), the foundry.toml form of `forge coverage --ir-minimum`. Fuzz runs 64, invariant 16 x 32 (project
  default 512 fuzz runs; speed trade-off).
- **deploycode.patch** (`mutation/deploycode.patch`, applied ONLY in the scratch copies while running the mutants,
  never committed): the 8 `new C(...)` sites for GainsVault / GainsVaultPolicy / GainsVaultLens / GainsVaultFactory /
  MockGainsDiamond in test/gains/GainsBase.t.sol, GainsPolicyAndFactory.t.sol, GainsRound4.t.sol and
  test/audit/gains/gov/FactoryMatrix.t.sol become `C(deployCode("C.sol:C", abi.encode(args)))`. Same artifact, same
  CREATE from the same test contract, same address and arguments; under via-IR it stops every test contract from
  re-generating those contracts, ~43% faster builds. **The reported score is from the patched suite**, which was 295/295
  green on the unmutated tree before mutation (and again with the fixed AccessMatrix: every surviving mutant run
  passes all tests).
- foundry 1.8.4 never reused its compile cache here (`missing cache entry` for every source), so each mutant is a full
  compile; 5 workers; per valid mutant 2.5 to 8 min depending on machine load (shared with four halmos runs).
- Per mutant: copy over scratch `src/gains/<File>.sol`, `forge test --fail-fast`, restore. compile-fail / killed /
  survived / timeout (> 1,200 s).

## Surviving mutants (all on security-relevant lines)

| location | mutant | operator | original | mutant | final status | verdict | explanation |
| --- | --- | --- | --- | --- | --- | --- | --- |
| GainsVaultPolicy.sol:254 `checkOrder` | GainsVaultPolicy#207 | BinaryOpMutation | `uint256 band = (mark * _config.maxSlippageBps) / BPS;` | `uint256 band = (mark/_config.maxSlippageBps) / BPS;` | survived | test gap | price check. The mutant shrinks the market-order band around the Chainlink mark to ~0 (stricter, so only a liveness change). Tests only check orders far outside the band; none checks that an expectedPrice inside the band but off the mark (e.g. mark x (1 + maxSlippageBps/2)) is accepted, nor the exact band edge. Add a boundary test for both sides. |
| GainsVaultPolicy.sol:391 `applyTimelockDelay` | GainsVaultPolicy#753 | DeleteExpressionMutation | `pendingTimelockEta = 0;` | `assert(true);` | survived | test gap (no security effect) | timelock check. Without `pendingTimelockEta = 0` the applied proposal stays applicable inside its grace window. A re-apply always writes the same value: the only other writer of timelockDelay (proposeTimelockDelay, raise path) clears pendingTimelockEta, and the lower path replaces the pending pair, so timelockDelay cannot be changed by it. Observable only through the public pendingTimelockEta getter and a second apply not reverting NothingPending, which no test checks. |
| GainsVaultLogic.sol:298 `settle` | GainsVaultLogic#952 | AssignmentMutation | `$.carryOrigin = 0;` | `$.carryOrigin = 1;` | survived | test gap | settle math (carry run). After a priced settle closes a carry run, carryOrigin must reset to 0. With 1, the next redemption-only settle does not open a new run (`if (carryOrigin == 0)` is skipped), carried requests get carriedFrom = 1, and every later priced settle rewrites carryPricedIn[0]: deposits carried in a SECOND carry run are priced in the wrong epoch at claim. No test runs two separate carry runs (loss breach -> priced settle -> loss breach again -> priced settle) and then claims both. The code is correct; add that test. |
| GainsVaultLogic.sol:654 `flatten` | GainsVaultLogic#2009 | IfStatementMutation | `if (slippageBps != 0) {` | `if (false) {` | killed | test gap, closed (killed after the AccessMatrix fix) | access check in flatten. With `if (false)` a non-zero slippageBps is no longer restricted to the manager / the guardian in emergency (the guardian outside emergency and, in a breach, the owner / sentinel / operator could flatten with a custom slippage up to maxFlattenSlippageBps). AccessMatrix.t.sol has exactly this cell (f == 16) and logged the MISMATCH in every state, but its storage `mismatches` counter was reset by vm.revertToState in _enter, so the test passed. With the fixed AccessMatrix (counter is a local) the mutant is KILLED: all 12 test_accessMatrix_* fail (1 to 4 mismatches each). Regression PoC: test/audit/gains/static/RevertToStateCounter.t.sol. |
| GainsVaultFactory.sol:404 `setGuardian` | GainsVaultFactory#684 | DeleteExpressionMutation | `_checkRoles(owner(), guardian_, sentinel, agentRegistrar);` | `assert(true);` | survived | equivalent | roles. In setGuardian the deleted `_checkRoles(owner(), ...)` checks guardian != sentinel, sentinel != owner and registrar vs owner/guardian/sentinel. The kept `_checkRoles(pendingOwner(), ...)` checks guardian != sentinel and registrar vs guardian/sentinel in both of its branches; sentinel != owner and registrar != owner do not depend on the new guardian and are invariants kept by setSentinel / setAgentRegistrar / transferOwnership (each checks owner and pending owner) and the constructor. No reachable state distinguishes the mutant. |

Test gaps to close (no contract change needed): a two-carry-run settle/claim test (Logic#952), market-order band
boundary tests on both sides (Policy#207), `pendingTimelockEta == 0` after applyTimelockDelay plus a second apply
reverting NothingPending (Policy#753). Logic#2009 is closed by the AccessMatrix fix. Factory#684 is equivalent.
