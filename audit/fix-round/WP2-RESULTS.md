# WP2: gTrade contract fixes in `contracts/src` (round 2 fix round)

Internal, AI-assisted work. It is not an independent audit and must not be presented as one.

Branch `fix/r2-gains-contracts` from `fix/r2-hl-contracts` (WP1, 6e52700), worktree `dv-fix-r2-gains`. origin/main
(0529f1a) was merged in first (739f47f); it adds only audit and test folders and touches nothing in `contracts/src`.
Nothing was pushed, merged, deployed or sent. No env file or hosting setting was touched, and there is
no `server/` or `webapp/` change. No HL contract changed: no shared file forced one.

Plan: `docs/fix-round/ROUND2-FIXES.md` (section 2 decisions, WP2). Sources:
- `contracts/audit/gains/r2/ROUND2.md` section 3, FIX-DESIGN.md;
- `fixes/COMBINED.md`, `fixes/STACK6.diff`, `fixes/<id>/`;
- `contracts/audit/fix-round/WP1-RESULTS.md`.

## In plain words

- **Room first.** GainsVaultLogic was at 22,014 bytes. The depositor request code moved unchanged to
  GainsVaultGovernance, and the whole suite gave the same result before and after.
- **The Gains review's fix stack is in** (COMBINED.md order), without its own CFG-01 part, which WP1's shared
  exit-before-effect rule already covers:
  - **LIVE-01 (High).** Settle, NAV and openTrade read only the vault's own trades and orders, one index at a time,
    instead of every trade the vault has ever had.
  - **KEY-01 / KEY-01b (High).** Limits on what a stolen manager or agent key can do with trades:
    - a per-pair cap kept in the factory (1 % of Gains' skew depth at launch);
    - a turnover budget (20× NAV of opened notional a day);
    - a 10-minute minimum hold on the manager's and the agent's exits (Gains' own TP/SL and liquidations are never
      held);
    - a loss gate inside openTrade.
  - **ECON-03, KEY-06 (Medium).** A leverage-breach settle now charges the performance fee before it mints. An
    exit-only settle no longer pays redeemers at a dip a key holder picked.
- **The cross-review's follow-ups are in.** XF-01, XF-02, XF-03 and XF-04 (section 1).
- **FF-02.** A deposit request is booked before the USDC moves.
- **From the HL review's GAINS-OPENTRADE patch, one part was added**: Gains' own per-pair OI ceiling also bounds the
  cap (section 3). The patch's 5 % cap was not applied.
- **Tests.**
  - Every original PoC that runs without an RPC was first shown failing against the new code (section 6).
  - Those PoCs were then removed or turned into fix assertions.
  - About 50 tests had to wait out the new minimum hold before a manager exit.
  - The suite has no expected failures.
- **One finding to flag (section 5).** The Gains review's CFG-01 fix tests check its own refusal mechanism, not the
  property. They fail on WP1's shared rule. The property holds, and the tests now assert it.

## 1. What went in (commits on `fix/r2-gains-contracts`)

| Commit | What | Source |
|---|---|---|
| 739f47f | Merge origin/main (audit and test folders only) | |
| 5681f1d | Size refactor: depositor requests GainsVaultLogic → GainsVaultGovernance (section 2) | new |
| 1a00f26 | GR2-ECON-03: a leverage-breach settle charges the performance fee before it mints | `fixes/GR2-ECON-03/fix.diff` (clean 3-way) |
| 31df7ec | GR2-KEY-06: exit-only / redemption-only settles pay at a cap no key holder can time; also closes ECON-02's key route and CFG-02 | `fixes/GR2-KEY-06/fix.diff` (**conflict**, section 4) |
| af1f81d | GR2-KEY-01 (first version, the base KEY-01b builds on) | `fixes/GR2-KEY-01/fix.diff` (**conflict**, section 4) |
| 881e7af | GR2-LIVE-01: per-index reads, own index set, permissionless `syncIndexes(maxSteps)` | `fixes/GR2-LIVE-01/fix.diff` (clean) |
| 39d4a47 | GR2-KEY-01b rev. 2: factory pair cap, turnover budget, minimum hold, loss gate | `STACK6.diff` minus the five patches (clean on this tree) |
| 1f3a2df | XF-01: no performance fee in an exit-only settle | ROUND2.md section 3, XREVIEW-FIXES.md 1 |
| 4b74f4c | XF-02: the prior-checkpoint cap applies to exit-only settles only | XREVIEW-FIXES.md 3 |
| d5ed772 | GR2-FF-02: book the deposit request before the transfer; no risk check inside the lock | `fixes/GR2-FF-02/` |
| 26dce56 | XF-03: closes, reduces and flattens sync the index set first (bounded, never reverts) | XREVIEW-FIXES.md 5 |
| b718e0c | XF-04: Gains' pair OI ceiling bounds the pair cap | GAINS-OPENTRADE comparison (section 3) |
| a29f998 | Turnover comment: the bucket's worst 24 h window is about 2× the steady rate | |
| 34c529b | The gains-r2 fix tests and cross-review tests under `contracts/test`, as written, plus `WP2FixTest` | `fixes/*/`, `xr-fixes/` |
| 5650c0a | Fork tests re-pinned to `GAINS_FORK_BLOCK` (section 8) | |
| d90fbe5 | CFG01FixTest on the shared rule (section 5); KX-03 and the XF-01/XF-02 PoCs inverted; AccessMatrix waits the hold | section 6 |
| 796a5f0 | Ports of the existing suite to the new rules; superseded PoCs removed or inverted; proof and gate logs (`wp2-logs/`) | section 6 |

**KEY-01b settings as built** (ROUND2-FIXES section 2 decisions):

| Setting | Value |
|---|---|
| Per-pair cap | Stored in the factory, `pairSkewCapBps[pair]`, as bps of Gains' skew depth. BTC, ETH and SOL are set to 1 % (100 bps) by the guardian at launch; the guardian's first setting is immediate. Standalone vaults use `DEFAULT_PAIR_SKEW_CAP_BPS` = 100. |
| Raise | Guardian only, up to 10 % (1,000 bps), after `PAIR_CAP_RAISE_DELAY` = max epoch (30 d) + `EXIT_MARGIN` (1 d) = 31 days. |
| Lower | Guardian or sentinel, at once; it also cancels a queued raise. |
| Unset pair | No new exposure (cap 0). |
| Turnover | Token bucket of `TURNOVER_NAV_MULTIPLE` = 20 × NAV of opened notional, refilling linearly over a day. Closes and reduces never spend it. |
| Minimum hold | `MIN_HOLD` = 10 minutes and `MIN_HOLD_L2_BLOCKS` = 2,400 (Arbitrum L2 blocks at the 250 ms floor, so always at least 10 minutes) since the pair's last new risk and the trade's last increase. It applies to the manager's and the agent's closes, reduces and flattens. It never applies to the guardian, the operator, any exit in a breach or emergency, or Gains' TP/SL/liquidation bots, which act on the diamond, not through the vault. |
| Loss gate | openTrade, increases and leverage raises refuse new risk (`ReduceOnlyMode`) once the live daily loss or drawdown reaches the policy limit, before `checkRisk` records the breach. Exits, cancels, settles and NAV never read it. |

**Deploying:**
- The deploy script still links the same three libraries (GainsVaultLogic, GainsVaultGovernance, GainsNav).
- The guardian must call `setPairSkewCap(pair, 100)` for BTC, ETH and SOL before a factory vault can open on them.

## 2. The size refactor (5681f1d)

- **What moved.** `requestDeposit`, `requestRedeem`, the two cancels, `claim` and their helpers moved unchanged from
  GainsVaultLogic to GainsVaultGovernance.
- **Vault side.** GainsVault now calls the same functions on GainsVaultGovernance.
- **What stayed the same.**
  - The reentrancy lock is the same `$.lock` slot (`GainsVaultLogic._enter/_exit`, internal, inlined).
  - Storage, events and the deploy script's three linked libraries are unchanged.

| | Before (WP1) | After the refactor | Final (all of WP2) |
|---|---|---|---|
| GainsVaultLogic | 22,014 | 19,115 | 21,855 (margin **2,721**) |
| GainsVaultGovernance | 13,119 | 16,276 | 16,907 |

**Proof that behaviour did not change.** A one-job full build and suite ran on 5681f1d (`wp2-logs/refactor.*`):
191 suites, **1,103 passed, 0 failed, 39 skipped** (1,142). This is identical to WP1's final gate.

## 3. GAINS-OPENTRADE (HL review, 5 % cap) against KEY-01b

The patch was not applied. KEY-01b already covers its core: a per-pair cap against skew depth, the loss gate and a
hold. What the patch has that KEY-01b lacks:

| Patch part | Decision | Why |
|---|---|---|
| Cap also bounded by Gains' `getPairMaxOiCollateral` | **Added** (XF-04, b718e0c) | A skew-depth read in the wrong units (a Gains facet change) could lift KEY-01b's cap. Gains' own OI ceiling is a second, independent bound. When set it bounds the cap; a revert fails closed on new risk only. |
| Refuse a TP inside the entry band at open | Not added | KEY-01b's turnover budget and loss gate bound the churn this targets, and crossed TP/SL closes by Gains' bot are a documented, accepted residual (KEY-01b README, ROUND2-FIXES item 5). |
| Hold on `setTp` | Not added | Changing TP/SL is never held: the stop loss must always be movable (KEY-01b design). |
| Profit-aware hold | Not added | Needs a live PnL read on every exit. The 10-minute flat hold and the turnover budget bound the same loop. |

**Turnover comment fix (a29f998).** The comment now states that the bucket's worst 24-hour window is about 2× the
steady rate: a full bucket, then a day of refill.

## 4. Conflicts and how they were resolved

Every patch went in with `git apply --3way`. No two fixes contradicted each other.

1. **KEY-06 against WP1's shared pattern (31df7ec).** Both store the epoch deadline at epoch start, with the same
   rule and the same policy read. Resolved as a union:
   - one `epochDeadline` field, placed after KEY-06's `priorCheckpointNav` (the order KEY-01b's storage expects);
   - KEY-06's `startEpoch()` in `initialize` and `settle`;
   - WP1's `epochOverdue` and lens reads;
   - one `epochDeadline()` getter (KEY-06's duplicate dropped).
2. **KEY-01's import list in GainsVaultLogic (af1f81d).** `MIN_DEPOSIT` had moved to GainsVaultGovernance with the
   refactor, and KEY-01's `MIN_RISK_NAV` was kept. Resolved as a union of both import lists.
3. **KEY-01b's raise delay (39d4a47).** STACK6 writes `+ 1 days`. Here `PAIR_CAP_RAISE_DELAY` reads WP1's
   `EXIT_MARGIN` (also 1 day), so it is still 31 days. One constant instead of two.

The cross-review changes (XF-01 to XF-04) are written on top of the stack, so they have no 3-way conflicts. Each is
the cross-review's own resolution of a gap between two fixes (ROUND2.md section 3).

## 5. CFG-01: the review's fix tests on WP1's shared pattern (flagged)

The brief asked to check that the Gains review's CFG-01 fix tests pass on the shared pattern, and to stop and write
down why if one does not. **All five failed** in the proof run (`wp2-logs/proof.failures.txt`, "next call did not
revert as expected").

- **Why.** The review's fix refused the configuration: the factory, policy and vault reject a timelock below the epoch
  plus the margin. WP1's shared pattern (decision D1, binding) allows the configuration and instead delays the change:
  queue eta = max(timelock, noticeEta, epochDeadline + EXIT_MARGIN). The tests assert the refusal, so they fail.
- **The property.** "A change that adds risk cannot take effect before a depositor who sees it can exit" holds on the
  shared pattern. In every scenario the eta is ≥ the epoch deadline + 1 day.
- **What was done (d90fbe5).** Same five scenarios. Each now asserts the shared rule's eta and that the change cannot
  execute before it.
- **What this is.** A test that encodes the mechanism, not the property. It is not a defect in either fix, and it
  needs no source change. WP1's own gains-r2 config tests had the same adaptation (WP1-RESULTS section 5).

## 6. The original PoCs: shown failing, then removed or inverted

**Proof run.** 34c529b: all fixes in, every test as written, nothing ported. Logs are in `wp2-logs/proof.*`.
- One-job build and suite: 208 suites, **1,084 passed, 87 failed, 41 skipped** (1,212).
- Every failure was put in one of the classes below. None is a defect in the new code.

**Original PoCs that fail on the new code** (the proof):

| PoC | Failure on the new code | Now |
|---|---|---|
| EconPoC `ECON_03_leverageBreachSettleChargesNewDepositorForOldGains` | "no performance fee charged, HWM kept": the fee is now charged | Inverted: `..._fix_leverageBreachSettleChargesTheFeeBeforeMinting` |
| EconPoC `ECON_02_overdueExitOnlySettleByOwnerPaysTheDip` | the holders no longer keep > 8 % of the redemption | Inverted: `..._fix_overdueExitOnlySettleByOwnerPaysTheRebound` |
| XReviewKey `XR_01` (guardian key) and `XR_02` (owner = manager key) | "the victim is paid > 4,000 USDC less: 0" | Inverted: `..._fix_..._emergencyExitOnlyPaysTheRebound` (victim and thief ≈ control within 1 USDC) |
| XReviewEconCfg `XR_ECON02_ownerEmergencyGivesTheExitOnlyDipAnyTime` | min hold, then the dip is no longer paid | Inverted: `..._fix_ownerEmergencyNoLongerPaysTheDip` |
| KnownExploits `KX_03` post-send hook | `Reentrancy()`: the booking comes first and checkRisk inside the lock reverts | Inverted (d90fbe5) |
| XRKey06Econ03, 3 PoCs (XF-01 ×2, XF-02) | the higher NAV no longer pays less; the pump is no longer paid in full | Inverted (d90fbe5) |
| R2Regression `GV01` ×3, `GV02_knownNonHoldingTypes` (LIVE-01's list layout guard) | the vault no longer reads `getTrades`/`getPendingOrders` | Removed. XRLive01Ports covers the per-index reads. `test_GV02_unknownOrderType` is kept and passes. |
| IntegrationMock `hookTokenReentryFromDeposit` | the reentrant cancel now refunds the booked request | Rewritten for FF-02: with other assets, the cancel refunds exactly the booked 800; in an empty vault it fails and nothing moves |
| XRLive01 `reduceChurnGrowsUnseenOrders` | XF-03 syncs on every reduce | Inverted: `..._fix_reduceChurnKeepsUnseenOrdersBounded` (unseen ≤ 1, gas bounded) |

**Fork PoCs.** The LIVE-01 and KEY-01 originals are fork PoCs:
- `LivenessHistoryFork` (6), `XReviewLiveGnsHistoryFork` (4) and `KeysSkewFork` (3);
- the GR2-KEY-01 fork PoC.

No Arbitrum RPC is set in this environment, so they skip and could not be shown failing here (section 8, open item
O2). The mock-side counterparts did fail on the new code:
- the LIVE-01 list-injection tests above;
- `LIVE01FixTest` and `KEY01bFixTest` / `KEY01bPairCapFixTest`, which assert the fixes on the mock diamond.

**Kept as documented residuals** (they still pass and describe accepted behaviour):
- EconPoC `ECON_01` ×3: the hedged book at settle (ECON-01, accepted design).
- `ECON_02_redemptionOnly`. XF-02 deliberately keeps min(NAV, checkpoint) in a loss breach. That is capped by
  `maxNavMoveBps` and avoidable by cancelling (open item O6).

**Other failure classes in the proof run, and what was done:**

| Class | Count | Done |
|---|---|---|
| Minimum hold: a manager or agent exit right after an open | about 50 | `_passHold()` (new in GainsBase: `MIN_HOLD` + `MIN_HOLD_L2_BLOCKS`, feeds kept fresh) before the first held exit. Tests that need stale feeds roll blocks only. Invariant handlers (GainsSpec, GainsRound4) wait the hold before their outage exits. |
| CFG01FixTest | 5 | Section 5 |
| Mock list reads (LIVE-01) | 9 | Removed (R2Regression ×4) or ported to per-index mocks: R1Regression GR1_08, IntegrationMock ×2, LivenessStateMachine D1, VerifyR2Mock, GainsBranches NavSkipsClosed |
| AccessMatrix | 7 | The base snapshot waits the hold (d90fbe5). `ACCESS-MATRIX.md` itself is unchanged. |
| Conservation suite (CIDiamond mock, world) | 4 | The mock gains `getTrade`/`getPendingOrder`/`getCounters`/skew-depth/OI reads; the world sets the BTC and ETH caps to 1 %. The handler's F1r model now mirrors KEY-06's `redemptionCap` (and XF-02), and its fee model ECON-03 / XF-01. |
| GainsSpec F2/F4 model | 1 (found in the port run) | "HWM and the fee rate move only in a normal settle" became "only in a settle that charges the fee": a treasury settle with no emergency and no loss breach (ECON-03 + XF-01). |
| R1NavBias 3x | 1 | ECON-03 charges 20 % of Bob's entry spread (about 120 USDC) in the leverage-breach settle. The assert now checks that nothing is created and that what is left is at most that fee. |
| XRKey01 stranger | 1 | Pair depth from `DEFAULT_PAIR_SKEW_CAP_BPS` (1 %) instead of KEY-01's 5 % |
| XReview intraday cycles | 1 (port run) | The turnover budget (20× NAV a day) now refuses an open partway through the 10 cycles. The test stops on `OrderRejected("turnover")` (asserting it is the only refusal) and keeps its asserts: Bob loses, Alice loses at most rounding. |
| GainsRound4 R02 | 1 (port run) | The hold's 10 minutes of management fee make the shortfall just under 5,000. The test matches the error selector. |

## 7. Cross-review

Before the gate, a fresh sub-agent that did none of the work reviewed:
- every conflict resolution;
- the size refactor;
- XF-01 to XF-04;
- FF-02;
- the never-held rule.

It worked read-only (`git show`, diffs against `fixes/<id>/fix.diff`). **It found no defects.**

- **Refactor OK.** Bodies are identical apart from the header, imports, `using SafeERC20` and the lock calls. Vault
  entry points changed only their call target, and lock coverage is unchanged. There is no storage change, and the
  deploy script links the same three libraries.
- **KEY-06 against WP1 OK.**
  - `epochDeadline` is written only by `startEpoch` (initialize, settle).
  - WP1's readers are kept: `epochOverdue`, the lens and the queue eta.
  - The layout matches KEY-01b's.
- **KEY-01 and KEY-01b OK.** 30 d + `EXIT_MARGIN` = 31 d = STACK6.
- **XF-01 OK.**
- **XF-02 OK.** Outside emergency, a loss breach can only settle redemption-only.
- **FF-02 OK.** The request is booked before `safeTransferFrom`. The cap check runs on the pre-booking totals.
  `_check`'s lock guard is reached only from `checkRisk` / `clearLeverageBreach` / `resume`, none of which runs under
  the lock.
- **XF-03 OK.** `GainsNav.sync` only staticcalls and never reverts; at most 20 index reads.
- **XF-04 OK.** Units are USDC 1e6. The selector is live on the diamond's facet (hl-r2 evidence `diamond-reads.txt`).
- **Never-held OK.** `_held` = not the guardian, not breached, not in emergency, and the caller is the manager or the
  agent. TP/SL/liquidation bots act on the diamond.

Notes (not defects):
1. XF-04 adds a live diamond call to every openTrade. The fork suites (GainsForkTrading and others) exercise it on
   the real diamond once an RPC is set (O2).
2. XF-02 depends on the breach state at settle time. A daily-loss breach cleared by the new day's first `checkRisk`
   turns a pending redemption-only settle back into a normal one. This is consistent with the design.

## 8. Fork tests

5650c0a re-pins every Gains fork base to `GAINS_FORK_BLOCK`:
- The default is 517,076,707 (2026-10-22), after Gains' 2026-09 facet cuts, so the forks run the patched vault on
  the current diamond. The public RPC keeps recent state only.
- The base-specific variables (`GNS_`, `LIVE_`, `XR_FORK_BLOCK`) still win when set.
- Two tests that assert chain data at 515,219,884 keep that block and need an archive RPC: GainsForkReads A6 and the
  GainsRiskParity fixtures.

**No `ARBITRUM_RPC_URL` is set here, so no fork test ran.** With one set, these would run at `GAINS_FORK_BLOCK`:

| Group | Tests |
|---|---|
| `test/gains/fork/` | 39 |
| `test/audit/gains/` (fork suites outside r2) | 79 |
| `test/audit/gains/r2/` fork suites, including `KEY01bForkFixTest` (4) and `KEY01ForkFixTest` (1) | 45 |
| **Total** | **163** |

Another 29 are historical (fixture or old-block replays). KeysSkewFork, XReviewKeySkewFork and KEY01bForkFix measure
the pre-fix attack: with an RPC they should show the new caps refusing it (O2).

## 9. Gate: one-job build and whole suite

All runs:
- forge 1.8.4, solc 0.8.28 via_ir;
- one compiler job for the whole tree (`src`, Gains, scripts, every test), as the README builds it;
- `forge build --force --sizes`, then `forge test`;
- under the shared heavy-tool lock (`$TEMP/dv-heavy.lock`).

| Run | Head | Build | Suite |
|---|---|---|---|
| refactor (`wp2-logs/refactor.*`) | 5681f1d | compiler run successful | 191 suites: 1,103 passed, 0 failed, 39 skipped |
| proof (`wp2-logs/proof.*`) | 34c529b | compiler run successful | 208 suites: 1,084 passed, **87 failed** (section 6), 41 skipped |
| port 1 (`wp2-logs/port1.*`) | d90fbe5 + ports | compiler run successful | 208 suites: 1,162 passed, **7 failed**, 41 skipped. The 7 are listed in section 6 (port run). |
| **gate, final (`wp2-logs/gate.*`)** | **796a5f0** | 1,721 s, compiler run successful | 208 suites: **1,169 passed, 0 failed, 41 skipped** (1,210 tests) |

- **Fix tests: 75 / 75 pass**, plus 2 fork suites skipped without an RPC:
  - `test/audit/gains/r2/fixes/*`: 49 passed, 2 skipped (`KEY01bForkFixTest`, `KEY01ForkFixTest`);
  - `xrfixes/*`: 21 passed;
  - `WP2FixTest`: 5 passed.
- **The gate header shows `dirty=1`.** That one file is this report, which is not a source.
- **No expected failures are left.** The suite has no superseded PoC and no failing test.
- **WP1's tests.** `test/audit/hl-r2/fixes/*` and `hl-r2/proxy/*`: 91 / 91 pass (75 + 16), as in WP1's gate.
- **The 41 skips are all gated.** They are WP1's 39 plus the two new r2 fork fix suites (`KEY01bForkFixTest`,
  `KEY01ForkFixTest`), which skip in `setUp` without an RPC.
- **Build exit code.** `forge build --sizes` exits 1 only because of EIP-170 messages for test harnesses, as in WP1.
  Every deployable contract is under the limit.

**Sizes.** Runtime bytes from the gate build. EIP-170 = 24,576. Libraries are read from `out/`, since `--sizes` does
not list linked libraries.

| Contract | Runtime | Margin | WP1 |
|---|---|---|---|
| **GainsVaultLogic** (library) | **21,855** | **2,721** | 22,014 |
| GainsVault | 22,422 | 2,154 | 19,037 |
| GainsNav (library) | 20,302 | 4,274 | 12,340 |
| GainsVaultGovernance (library) | 16,907 | 7,669 | 13,119 |
| GainsVaultFactory | 13,523 | 11,053 | 12,203 |
| GainsVaultPolicy | 13,084 | 11,492 | 13,068 |
| GainsVaultLens | 10,356 | 14,220 | 10,631 |
| VaultLogic (HL library) | 22,678 | 1,898 | 22,678 |
| HyperVault | 19,821 | 4,755 | 19,821 |
| VaultGovernance (HL library) | 13,840 | 10,736 | 13,840 |
| VaultPolicy | 12,218 | 12,358 | 12,218 |
| HyperVaultFactory | 10,955 | 13,621 | 10,955 |
| HyperVaultLens | 9,118 | 15,458 | 9,118 |

- **HL is unchanged.** Initcode is under 49,152 for every deployable contract.
- **Over the limit: test harnesses only**, never deployed: Reaudit2Handler, CIHandler, ReauditHandler,
  ConservationHandler, SpecHandler, VaultHandler, GainsHandler (25,019, over by 443).
- **GainsVault now has the tightest Gains margin (2,154).** It grew with LIVE-01's index set and `syncIndexes`, and
  with KEY-01b's entry points.

## 10. Open items

- **O1. Turnover default and worst window.** 20× NAV a day, as decided. The bucket's worst 24-hour window is about
  2× the steady rate (a29f998). Whether that is acceptable, or the bucket should refill over two days, is the
  owner's call.
- **O2. Fork runs.** With an Arbitrum RPC:
  - run the 163 fork tests at `GAINS_FORK_BLOCK`;
  - show the LIVE-01 and KEY-01 fork PoCs failing on the new code;
  - check XF-04's `getPairMaxOiCollateral` read on the live diamond (cross-review note 1).
- **O3. GR2-CI-01 (Low), not included.** There is no ready patch. It needs a Snapshot field and an ABI change, and it
  only occurs after a Gains facet change.
- **O4. Lows left out.**
  - GNS-01, XR-01, XR-02 and LIVE-02: no ready, tested fix.
  - ECON-01: accepted design.
  - EXE-01, EXE-02 and EXE-07: server side, out of scope (WP3).

  Included Lows: ECON-02 (exit-only form, through KEY-06), CFG-02 (through KEY-06), XF-01 to XF-04.
- **O5. Optional hardening, not done.**
  - Wrap the hold reads in try/catch.
  - A per-index hold in `flattenIndices`, which currently uses the vault-wide `lastRiskAt`.
- **O6. ECON-02, redemption-only form.** XF-02 keeps min(NAV, checkpoint) in a loss breach, to close C-01's pump
  window. The PoC `ECON_02_redemptionOnly` still passes by design: the effect is capped by `maxNavMoveBps` and the
  redeemer can avoid it by cancelling. The KEY-06 README had expected that PoC to fail too, so that README is now
  out of date on this point.
- **O7. Executor (WP3).**
  - Map `OrderRejected("pair cap" | "pair depth" | "no skew depth" | "turnover" | "min hold")` and the loss
    gate's `ReduceOnlyMode` on an open.
  - Hold the agent's exits for 10 minutes and 2,400 L2 blocks after new risk.
  - Call `syncIndexes` when unseen indexes build up.
- **O8. Lens / webapp (WP4).**
  - The lens fee preview when an epoch is overdue: the exit-only settle now charges no performance fee (XF-01), and
    the lens should show that.
  - New factory read `pairSkewCapBps(pair)` and vault call `syncIndexes(maxSteps)`; regenerate the ABIs.
- **O9. HL minimum hold (D4).** Still not built on HL (WP1 O2).
- **O10. Audit docs.** `ACCESS-MATRIX.md` and the gains-r2 write-ups still name the removed or renamed PoCs and lack
  rows for the new entry points (`setPairSkewCap`, `syncIndexes`). They were not edited, because audit directories
  are changed only under an explicit audit instruction. This file is the map.
- **O11. Test ports.** The ports keep each test's intent by waiting out the hold before the first held exit. Three
  were judgement calls worth a second look:
  - XReview's intraday cycles (now bounded by turnover);
  - OperatorBound's baseline day;
  - GainsPositions' timed-out pending open.
