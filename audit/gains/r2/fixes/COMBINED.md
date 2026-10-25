# Round 2 proposed fixes: index and combined check

**Internal, AI-assisted review. Not an independent audit.** Patches only; nothing in `contracts/src` was changed.

| Finding | Folder | Files the patch touches | Fix test | Unfixed (4ec6feb) | Patched |
|---|---|---|---|---|---|
| GR2-ECON-03 (Medium) | [GR2-ECON-03](GR2-ECON-03/) | Logic, Lens, test HLRetest | `ECON03FixTest` (5) | 3 fail, 2 pass (regression guards) | 5 pass |
| GR2-CFG-01 (Medium) | [GR2-CFG-01](GR2-CFG-01/) | Policy, Governance, test GainsBase | `CFG01FixTest` (5) | 5 fail | 5 pass |
| GR2-KEY-06 (Medium) + ECON-02 + CFG-02 | [GR2-KEY-06](GR2-KEY-06/) | Types, Math, Logic, Governance, Vault, Lens | `KEY06FixTest` (9) | 8 fail, 1 pass (lens parity) | 9 pass |
| GR2-KEY-01 (High) | [GR2-KEY-01](GR2-KEY-01/) | IGainsDiamond, Types, Nav, Math, Logic, mocks | `KEY01FixTest` (5) + `KEY01ForkFixTest` (fork) | 4 fail, 1 pass (guard) | 5 pass; fork: see `GR2-KEY-01/run-fork.txt` |
| GR2-LIVE-01 (High) | [GR2-LIVE-01](GR2-LIVE-01/) | IGainsDiamond, Nav, Vault, Lens, mocks | `LIVE01FixTest` (4) | 2 fail (gas), 2 pass (parity = old reader's numbers) | 4 pass |
| GR2-KEY-01 revised: **KEY-01b rev. 2** (High) | [GR2-KEY-01b](GR2-KEY-01b/) | Types, Nav, Logic, **Factory**, Policy (named epoch bound), test GainsBase / GainsPolicyAndFactory / GainsRound4 (relative to the KEY-01 tree) | `KEY01bFixTest` (7) + `KEY01bPairCapFixTest` (8) + `KEY01bForkFixTest` (fork, caps 1 / 5 / 10 %) | KEY-01 tree: 5 fail; first KEY-01b tree: 7 per-pair tests fail | 15 / 15 pass; fork 4 / 4 at each cap; mock suite 376 / 45 expected fails (GR2-KEY-01b/README.md) |

Each `fix.diff` is against 4ec6feb and applies alone with `git apply` from the repo root. Fix tests live in the
folders (not under `contracts/test`, so the worktree's full `forge test` stays green on unfixed code); to run one, copy
`FixTest.t.sol` to `contracts/test/audit/gains/r2/fixes/` (imports are relative to that folder).

## All five together

Applied in the order ECON-03, CFG-01, KEY-06, KEY-01, LIVE-01 on a clean export of 4ec6feb: **all apply** (no
conflicts; 13 files, +498 / −107). Built and run in a scratch tree with the same 40 Gains mock suites plus the five fix
tests (combined-run.txt (not included)): **392 pass, 36 fail**, every failure one of the per-patch expected ones:

- 19 from CFG-01 (7 round 2 CFG PoCs, 8 tests using a 1-day timelock with the 1-day harness epoch, `isTighterFieldByField`,
  3 tests needing an epoch longer than a day): see GR2-CFG-01/README.md;
- 6 more round 2 PoCs from KEY-06 (XR-01..03, ECON-02 ×2, XR_ECON02; the CFG-02 PoC is already in the CFG list);
- 9 from LIVE-01 (layout-injection tests on the old list calls): see GR2-LIVE-01/README.md;
- 1 from ECON-03 (its PoC);
- 1 interaction: `KEY06FixTest::test_KEY06_fix_CFG02_epochRaiseDoesNotLiftAnOverdueEpoch` raises the epoch to 30 days
  with a 2-day timelock, which CFG-01 now refuses at the queue (`EpochAboveTimelock`). With both patches CFG-02 is
  closed twice; the fix round keeps the KEY-06 test with an epoch raise that fits the timelock (e.g. T = 8 d, E 1 d → 7 d).

Runtime sizes with all five: GainsVaultLogic 23,611 bytes (limit 24,576: 965 bytes left), GainsVault 21,689,
GainsNav 18,834, Governance 13,794, Policy 13,228, Lens 10,356.

## KEY-01b on top of the five

KEY-01b (rev. 2) is written against the KEY-01 tree. On the five-patch stack (order ECON-03, CFG-01, KEY-06, KEY-01,
LIVE-01, then KEY-01b), checked on 2026-10-21 on a clean export of 4ec6feb:
- **Every hunk applies except one.** `GainsTypes.sol`'s `VaultStorage` append is rejected, because KEY-06 appends
  `priorCheckpointNav` and `epochDeadline` at the same place.
- **The resolution is mechanical:** put KEY-01b's four fields (`turnoverUsed`, `turnoverAt`, `lastRiskAt`,
  `pairRiskAt`) after `epochDeadline`.
- **The 31-day raise delay** comes from `GainsVaultPolicy.sol` (one named constant, used by `_validate`). That hunk
  sits away from CFG-01's policy hunks and applied cleanly in the check. With CFG-01 the longest usable epoch is 29
  days (timelock ≤ 30 days, epoch ≤ timelock − 1 day), so the delay keeps a two-day margin.
- **Six together: built and run (2026-10-21).** The resolved stack is STACK6.diff (not included) (relative to
  4ec6feb, 16 files, +739 / −110; checked to apply with `git apply` on a fresh export). Scratch tree as F-1 plus
  `KEY01bFixTest.t.sol`, with KEY-01b's `test-port.diff` applied to the copied `KEY01FixTest`. Raw output:
  stack6-run.txt (not included).
  - **Sizes** (runtime, bytes; limit 24,576): `GainsVaultLogic` **24,474 (102 bytes left)**, `GainsNav` 20,286,
    `GainsVault` 21,689, `GainsVaultFactory` 13,523, `GainsVaultPolicy` 13,244, `GainsVaultGovernance` 13,794,
    `GainsVaultLens` 10,356. This is under the limit, so no function was moved. With 102 bytes left, any further growth
    in the fix round first needs `_checkPairDepth` or `_lossGate` moved into `GainsNav` (4,290 bytes left).
  - **Tests:** 46 suites, **363 pass, 80 fail**, 0 skipped (443). Fix tests: 38 / 43 pass (ECON03 4/5, CFG01 5/5,
    KEY06 8/9, KEY01 4/5, LIVE01 3/4, KEY01b 7/7, pair cap 7/8).
  - **77 of the 80 are expected:**
    - 32 are on the five-stack list only;
    - 41 are on KEY-01b's list only (`min hold` ports and the AccessMatrix rows);
    - 4 are on both lists. They now stop at `min hold` before the five-stack assertion, or keep the five-stack reason.

    Every expected failure on either list still fails; none passes by accident.
  - **3 are new.** All are test-side interactions; none is a code defect.
    - `ECON03FixTest::test_ECON03_fix_leverageBreachSettleChargesThePerformanceFeeBeforeMinting` and
      `LIVE01FixTest::test_LIVE01_fix_navParityWithTheListReaderOnAMixedState` fail with `OrderRejected("min hold")`.
      In each, the manager closes an ETH trade in the same second as a new ETH request:
      - ECON-03: the control branch settles and calls `_flat` right after `_scenario`'s second ETH open. The breach
        branch passes, because breach exits are not held.
      - LIVE-01: `_closeFilled` closes the trade the test just opened.

      These are the same class as KEY-01b's `min hold` ports; the two files were not in KEY-01b's run. Port: skip
      `MIN_HOLD` and roll `MIN_HOLD_L2_BLOCKS` before the exit.
    - `KEY01bPairCapFixTest::test_KEY01b_fix_pairCap_raiseDelayIsLongestEpochPlusOneDay` fails with
      `EpochAboveTimelock(30 d, 30 d)`. It creates a vault with a 30-day epoch and a 30-day timelock, which CFG-01
      refuses (epoch ≤ timelock − 1 day). This is the 29-day ceiling stated above: the delay is unchanged and the
      margin is two days. Port:
      - create the vault with a 29-day epoch;
      - keep the assertions that `MAX_EPOCH_DURATION` = 30 d and the delay = 31 d, and the refusal at 30 d + 1 s;
      - check the eta against that epoch's end + 2 days.

## Assumptions

| # | Assumption |
|---|---|
| F-1 | Scratch trees hold `src` (Gains subset + deps) and 30 Gains mock test files with their imports (no HyperEVM, no fork suites); "regression run" means those 40 suites. Fork suites were not run on the patched code. |
| F-2 | The harness change needed by CFG-01 is part of its patch (GainsBase `_defaultRisk().maxEpochDuration` 7 d → 1 d, the live shape); the alternative (8-day timelocks) was measured and rejected (88 failures vs 19). |
| F-3 | Constants instead of policy fields where a policy field would change `RiskConfig` (KEY-01's 5 %, CFG-01's 1-day margin), to keep the patches small; the fix round may make them configurable. |
| F-4 | KEY-01's fork test needs the machine-wide heavy lock (METHOD.md: fork work); its status is in `GR2-KEY-01/run-fork.txt`. |
