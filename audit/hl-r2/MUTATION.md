# hl-r2: mutation testing of the fund-moving code (contracts/src, non-gains)

**Internal, AI-assisted review. Not an independent audit.** Branch `audit/hl-r2-mut`. `contracts/src` was never
modified in the repo: every mutant lives in a throwaway copy outside it (`C:\hlr2\mut`), and `git diff --stat
contracts/src` was empty before every commit.

## Result in one paragraph

1,748 first-order mutants on the fund-moving lines. The existing non-gains suite kills 1,306 of them: **81.2%**
of the non-equivalent mutants (1,306 / 1,608; raw 74.7%). Of the 442 survivors, 140 are equivalent (explained one by
one below), 284 are killed by the 85 new tests in `contracts/test/audit/hl-r2/mut/`, and 18 are documented boundary
mutants (1 wei / 1 share unit, a 1-2 USDC bridge, a read-only estimate) that are not killed. With the new tests the
score is **98.9%** (1,590 / 1,608). No surviving mutant is equivalent to a bug in the CURRENT code: every finding below is a test gap
(the code is right, but nothing would notice if the line regressed). The largest gaps guard lines whose regression
would move money: the Core -> EVM landing trackers, `rescueToken`, the treasury entry points and their CoreWriter
encodings, the min(NAV, checkpoint) pricing of exits, the carry run, the depositor-flow guards and the share
primitives (HLR2-M01..M07). Four past fixes have no test that catches their revert (HLR2-M08, details in
PAST-FIXES.md).

## Tool and why

- Gambit (Certora) has no Windows build and no Rust toolchain is installed; vertigo-rs is unmaintained.
  `slither-mutate` (slither-analyzer 0.11.x) installs, but it mutates whole contracts, cannot be restricted to lines,
  and recompiles the project per mutant: with via-IR a non-gains build takes 14 min optimized / 5 min unoptimized, so
  1,700 mutants would take weeks.
- So: a small deterministic mutator plus **mutant schemata** (`contracts/audit/hl-r2/mut-tool/`). `mutgen.py`
  generates every mutant of the target lines; `schema.py` writes ONE build in which each mutant is guarded by
  `MID() == id`, with `MID() = block.chainid - 1_000_000` (0 = the original program). A mutant then runs with
  `forge test --chain-id <1_000_000 + id>` against the cached build: one compile for all 1,814 mutants (1,748 + 66
  past-fix reverts). The first run of each mutant was checked by hand for a few ids (the guard switches, nothing
  recompiles).
- Lines are joined in the scratch copy (`normalize.py`, semantics preserving) so that every multi-line statement is
  one line; `pure` functions holding a mutant become `view` (they read `block.chainid`), as do the test helpers that
  call them (`fixpure.py`).

## Operators

ROR (relational: boundary shift and negation), AOR (+ - * /), ASOR (+= -=), LOR (&& ||), UOI (delete `!`), RR (delete a
`revert` / `if (...) revert`), SDL (delete a statement: assignments, transfers, mints, burns, calls), RND (Floor <->
Ceil), BLR (true <-> false), ILR (0 <-> 1, also `address(0)` -> `address(1)`), CR (the named constants ->
0 and x2: bridge windows, tolerances, MIN_DEPOSIT, MIN_BRIDGE, MIN_RISK_NAV, fee caps, timelock bounds, grace,
checkpoint ages, ONE_SHARE, DECIMALS_OFFSET, YEAR), ARG (argument swaps of mulDiv / toShares / toAssets /
VaultMath.transfer), ENC (34 hand-written CoreWriter / encoding mutants: action ids, field order, scales,
destinations, dexes, sub-account, reduce-only and TIF flags, approval size, revocation name).

## Targets (file: lines, numbering of the round 4 source)

`mut-tool/targets.json`. VaultLogic: the depositor flow (requestDeposit, requestRedeem, cancels, claim,
_claimIfSettled, _rejoinCarry), settle, _accrueFees, the checkpoint, hosting / protocol share, every bridge function,
_openWindow / _arm / _syncBridge, _depositToCore, seedCore, fundCoreGas, moveUsd, placeOrder, cancelOrder, flatten,
the agent slot, the lock. VaultMath: mint / burn / transfer / spendAllowance, idleAssets, coreEquity, the bridge
window views, hardStop, priceAt, totalAssets, toShares / toAssets, sharePrice, epochOverdue, claimableWithCarry,
emergencyFillBps. VaultPolicy: initialize, checkOrder, flattenOrder, nextCheckpoint, the config / allowlist /
timelock queues, _checkEta, _validate, _isTighter. PxMath (all). HyperCore: every read and every CoreWriter
encoding. VaultGovernance: initialize, operator, checkRisk / _check, clears, breaches, emergency, switches, cap,
fees, queue / execute / cancel, the timelocked setters. HyperVault: guardian / sentinel, onlySelf, settle,
setAgent, revokeAgent, rescueToken, renounceOwnership. HyperVaultFactory: create, the agent registry, the admin
setters, _checkRoles. Not targeted: emits, pure getters, HyperVaultLens (read-only; its two past fixes L-02 / R3-07
are in PAST-FIXES.md), scripts.

## Test set and kill rule

- Phase 1: every non-gains unit and PoC test (`--no-match-contract "Invariants$"`), `--fail-fast`. Phase 2, only for
  phase 1 survivors: the 7 invariant contracts. Killed = any test fails. Survived = all pass. Timeout 1,500 s per
  phase (none hit).
- Build profile (scratch only): via-IR, optimizer off with stack allocation (`optimizer_steps = ":"`), fuzz 64 runs,
  invariants 16 runs x 50 depth (the inline 512 x 200 configs were lowered in the scratch copy), code size limit
  off. Five tests fail on the unmodified program for build reasons and are excluded from every run
  (`test_ImplementationFitsEip170`, `test_REAUDIT2_N201_claimGasIsConstantAcross1000EmergencyEpochs`,
  `invariant_reaudit2` (gas ceilings), two skipped `*Reachable` tests); 270 tests pass on the unmodified program.
- Assumption (conservative): the smaller fuzz / invariant budget can only make the suite weaker; the score is a lower
  bound for the configured 512-run suite. 11 mutants were killed only by the invariants (phase 2).
- The new kill tests (`test/audit/hl-r2/**`) are excluded from the campaign runs and checked separately against each
  survivor (`killcheck.py`, in a second scratch copy `C:\hlr2\kill` with the same build).

## Dispositions of survivors (the codes in the table)

- `killed-by-hl-r2`: a new test fails on the mutant and passes on the original (names in the table).
- `EQ`: equivalent, no state difference reachable (reason given). `EQ-MIN`: the value is 0 or >= MIN_DEPOSIT /
  MIN_BRIDGE, so a 0 -> 1 change cannot be reached. `EQ-STATE`: only an event or a no-op write differs.
  `EQ-UNREACH`: the condition cannot hold in any reachable state (reason given). `EQ-TOL`: inside BRIDGE_LANDING_TOLERANCE. `EQ-MOCK`: differs only for a missing Core account,
  where HyperCore returns zeros. `EQ-DEAD`: dead code.
- `B1U` / `B1W` / `B2W` / `B-EDGE` / `VIEW`: NOT equivalent, not killed, documented: the behaviour differs only at
  exactly 1 share unit (1e-12 share), 1 wei, under 2 USDC, exactly at a risk limit, or in a read-only estimate.
  They are listed under HLR2-M11.

## Findings

All findings are test gaps: the current code is right on every line below, and each finding's "PoC" is the pair
(surviving mutant, new test): the mutant survives the existing suite (`results/mut.jsonl`, status `survived`) and the
new test fails on it and passes on the original. Severity follows CONTEXT.md, rated as impact if the line regressed x
likelihood of an unnoticed regression (low: the code is not changing; it matters for the next edit, and for any
claim that "the suite protects this"). Fix for every finding: keep the new tests in `test/audit/hl-r2/mut/` (they
run in the normal suite, 85 tests, all pass on the current code in the optimized worktree build).

| ID | Sev | Gap (lines whose regression nothing caught) | Impact if regressed | Mutants (ids) | Killed by |
|---|---|---|---|---|---|
| HLR2-M01 | Low | Core -> EVM landing signal: the EVM-side trackers (`evmInSinceBridge` in requestDeposit, `evmOutSinceBridge` in cancelDepositRequest and claim, their reset and the spot / EVM snapshots in `_arm`), the landing tolerance and the spot scale | A deposit made during a Core -> EVM bridge is read as the landing: the window closes with the USDC in transit and NAV reads short by the bridged amount (5,000 of 10,000 in M01), so a settle prices deposits at half NAV; or a landing is hidden and settlement waits up to MAX_UNLANDED_BLOCKS | 42, 86, 136, 486, 487, 491, 694, 695, 698, 703, 704, 706, 711, 1736 | M01-M06, M35, M49 |
| HLR2-M02 | Low | `HyperVault.rescueToken` had no test at all | Deleting or inverting its guard lets the owner sweep the depositors' USDC and the escrowed shares (Critical class if it regressed) | 1565-1569 | M07 |
| HLR2-M03 | Low | Treasury entry points tested on the happy path only: `bridgeToCore` / `moveUsd` authorisation, `amount > idle`, `coreUserExists`, zero amounts, the bridgeToEvm liquidity check and full-amount exception, the perp leg (`usdClassTransfer(amount - spot, false)`), every CoreWriter field of sendAsset / usdClassTransfer / cancelByOid, the exact deposit-wallet approval, reduceOnly forwarding | A stranger moving the idle USDC that pays redemptions to Core, reserved USDC bridged away, a bridge back with the wrong leg / direction / sub-account / amount scale, a standing USDC allowance to the deposit wallet, a reduce-only order sent as opening | 423, 425, 426, 430, 433, 451, 456, 457, 461, 468, 470-472, 515, 517, 518, 524, 550, 1134, 1136-1138, 1720-1727, 1738, 1739, 1741, 1748 | M30-M35, M40, M75 |
| HLR2-M04 | Low | Exit pricing at min(NAV, checkpoint): the exit-only line (deleted / negated / `||`) and the redemption-only line with `&&` -> `||`; the exit-only authorisation of the platform roles before overdue | An emergency settle pays exits at a NAV pushed above the last checkpoint (5,500 instead of 5,000 in M18), or at the higher checkpoint after a loss (M19); a normal settle pays redeemers at the stale checkpoint instead of the live NAV (M20); the owner / guardian / sentinel could run an exit-only settle (refund every queued deposit) at any time (M25) | 195, 223, 225, 226, 228, 235, 236 | M18-M20, M25 |
| HLR2-M05 | Low | The carry run and insider deposits through redemption-only settles (round 4): `carryPricedIn = epoch + 1`, the origin reset, `pendingDepositAssets += deferredDepositAssets`, `insiderInQueue` | A carried deposit priced in the wrong epoch, or claimable while still carried (M22: the mutant tries to deliver shares from an older run); an insider's next-epoch deposit dropped from the reserve (its USDC becomes NAV); the R3-02 one-hour delay skipped after a redemption-only settle | 279-281, 283-285, 288, 293, 294 | M22-M24 |
| HLR2-M06 | Low | Depositor-flow guards: `cancelDepositRequest` on an already priced deposit, `cancelRedeemRequest` not clearing the request, zero controller, cap boundary, zero amounts | Cancelling a priced deposit refunds it out of the next depositors' queue (M14); a cancelled redemption cancelled again takes the shares other redeemers escrowed (M13); deposits to controller 0 locked | 3, 10, 11, 16, 52, 54, 55, 72, 73, 77, 91, 92, 94, 95 | M13-M17 |
| HLR2-M07 | Low | Share primitives in VaultMath: `transfer`'s balance check (the library runs `unchecked`) and `spendAllowance` (decrement, infinite shortcut, boundary) | Without the check a redemption of more shares than held underflows the balance (unbounded shares); an allowance not spent or increased | 631, 637, 638, 641, 642 | M36, M37 |
| HLR2-M08 | Low | Past-fix regressions that nothing catches (PAST-FIXES.md): M-01 day roll in flight, N-11 zero-share refund, N2-04 create-path binding, V-03 transferOwnership role check; and the R-02 latch per entry point (settle, accrueFees, moveUsd, checkRisk) | See PAST-FIXES.md; for the latch: a landed bridge whose USDC moves on reopens the window on the stale snapshot (a 2,000 loss masked in M11 / M26) | 207, 246, 248, 323, 522, 1285, 1593, 1689; past-fix reverts 1759, 1780, 1784, 1799 | M08-M12, M26, M27, M45, M62 |
| HLR2-M09 | Low | Governance and initialisation without negative tests: VaultPolicy.initialize bounds and `_validate` (every bound), the config queue, disallow, the policy timelock delay rules; HyperVault initialize checks and stored values; the timelocked setters' own checks; the vault queue table, grace edge, replay and cancel; clearBreach in emergency and its day reset; the factory admin guards and the registrar rule with a pending owner | Out-of-range fees, timelocks, shares or risk configs accepted; a queued item executable twice or after cancel; a clear queued in the breach block counted (N-04 edge); deposits not pausable; a daily loss after a clear masked (M66) | 832-838, 950-1010 (policy, 27 ids), 1018-1072 (19), 1144-1210 (29), 1389-1415, 1467-1526 (31), 1594, 1623-1712 (14) | M50, M53-M56, M58, M59, M65-M74, M76 |
| HLR2-M10 | Info | Smaller edges: partial-fill burn rounding direction (Ceil burns 1 unit too many, V-01 class), window / unlanded boundaries, emergencyFillBps (view), 1 bps performance fee and protocol share, lowerProtocolShare raising the base share, first-mint and settle peak updates, zero equity with open positions (checkRisk divides by zero: blocks every risk check and the first settle), MIN_RISK_NAV, checkOrder edges and a zero mark, checkpoint age edge, flatten guards and cloid, zero orders, agent slot, the reentrancy lock, fundCoreGas failure, the zero-price floor, clears and resume in a window and at the exact leverage limit | Each is bounded (rounding, liveness, a view, a 1 bps fee) or needs a second error | 129, 650, 656, 754, 882, 883, 1213, 1217, 1251, 1253, 1277, 1318, 1335, 1378, 1399, 255, 311, 315, 346, 371, 420, 513, 536-539, 578-585, 596, 597, 606, 607, 613-615, 662, 666, 679, 685, 812-826, 843-864, 918, 1120-1122, 1241, 1249, 1273, 1275, 1311, 1323, 1401 | M21, M28, M29, M35, M38, M39, M41-M44, M46-M48, M51, M52, M57, M60, M61, M63, M64, M71, M77-M83 |
| HLR2-M11 | Info | 18 boundary mutants not killed (listed in the table with B1U / B1W / B2W / B-EDGE / VIEW): a 1-share-unit redemption or fee mint, a 1 wei fee, a 1-2 USDC full-amount bridge, the fill estimate when NAV is under the checkpoint | At most 1 share unit or 1 wei per occurrence (2 USDC for the bridge); the view under-reports a fill | see table | not killed (documented) |
| HLR2-M12 | Info | Dead or unreachable code found by equivalent mutants: `coreAtBridge` is written in `_arm` and never read (since R3-01); `HyperCore.cancelByCloid` is never called; the claim clamp `if (assets > claimableRedeemAssets)` is unreachable (claims are floors of a pro-rata split; not proved symbolically, see HALMOS.md); `VaultMath.burn`'s balance check is unreachable; the syncAgent hard-stop gate is unreachable (agent is always 0 in a full stop) | None (gas, clarity). Keep the defensive ones; drop the dead store and the unused helper when the code is next touched | 485, 1135, 132, 624, 593 | - |

Notes on the table: ids are mutant ids in `mut-tool/mutants.json` (regenerate with `mutgen.py` on the normalized
scratch copy); "M<nn>" is `test_HLR2_M<nn>_kills_*`.

## Time and caps

Heavy-tool lock sessions for mutation (`$TEMP/dv-heavy.lock`, owner "hl-r2 mut/halmos"): 01:33-01:54 (baseline +
exclusion check, 1,276 s), 01:56-02:01 and 02:02-02:14 (two aborted starts: an exclusion regex bug, results
discarded, 1,044 s), 02:15-05:18 (11,028 s, budget-limited session), 06:07-06:39 (1,916 s: the rest of the mutants
and the whole-suite runs of the past-fix survivors). Total mutation lock time **4.24 h** of the 12 h cap; sum of
per-mutant runs 3.50 h. Schema builds (outside the lock, like any compile): 4 x ~6-7 min. Kill-test checks (own
files, ~3 s per mutant) ran outside the lock.

The machine powered off on 2026-10-20 (reboot 14:51 local) during the Halmos pass, after the mutation campaign had
finished; no mutation run was lost or restarted.

## Numbers

- mutants generated (excluding the 66 past-fix reverts): 1748
- run: 1748; killed by the existing suite: 1306 (phase 1 unit/PoC: 1295, phase 2 invariants only: 11); survived: 442; timeouts: 0; errors: 0
- survivors: killed by the new hl-r2 tests 284, equivalent 140, boundary / near-equivalent (documented, not killed) 18, open 0
- mutation score of the existing suite: 1306/1608 = 81.2% (equivalents excluded); raw 1306/1748 = 74.7%
- with the hl-r2 kill tests: 1590/1608 = 98.9%
- mutation time (sum of per-mutant runs): 3.50 h

### By operator

| Operator | Mutants | Killed (existing) | Survived |
|---|---|---|---|
| AOR | 106 | 97 | 9 |
| ARG | 25 | 25 | 0 |
| ASOR | 21 | 20 | 1 |
| BLR | 39 | 33 | 6 |
| CR | 86 | 63 | 23 |
| ENC | 34 | 20 | 14 |
| ILR | 183 | 73 | 110 |
| LOR | 177 | 137 | 40 |
| RND | 9 | 5 | 4 |
| ROR | 522 | 424 | 98 |
| RR | 158 | 99 | 59 |
| SDL | 319 | 242 | 77 |
| UOI | 69 | 68 | 1 |

### By file

| File | Mutants | Killed (existing) | Survived |
|---|---|---|---|
| src/HyperVault.sol | 25 | 20 | 5 |
| src/HyperVaultFactory.sol | 144 | 112 | 32 |
| src/VaultGovernance.sol | 406 | 307 | 99 |
| src/VaultLogic.sol | 629 | 474 | 155 |
| src/VaultMath.sol | 212 | 152 | 60 |
| src/VaultPolicy.sol | 271 | 198 | 73 |
| src/hypercore/HyperCore.sol | 33 | 20 | 13 |
| src/libraries/PxMath.sol | 28 | 23 | 5 |

## Every surviving mutant

| # | File:line | Op | Mutation | Disposition |
|---|---|---|---|---|
| 3 | VaultLogic.sol:45 | RR | delete `if (assets == 0) revert E.ZeroAmount();` | killed-by-hl-r2: killed by M17_kills_zeroAmountGuards |
| 10 | VaultLogic.sol:47 | ILR | 0 -> 1: `if (controller == address(1)) revert E.ZeroAddress();` | killed-by-hl-r2: killed by M15_kills_zeroController |
| 11 | VaultLogic.sol:47 | RR | delete `if (controller == address(0)) revert E.ZeroAddress();` | killed-by-hl-r2: killed by M15_kills_zeroController |
| 16 | VaultLogic.sol:49 | ROR | > -> >=: `if ($.depositCap != 0 && $.totalAssets() + $.pendingDepositAssets + $.deferredDepositAsset` | killed-by-hl-r2: killed by M16_kills_capBoundary |
| 37 | VaultLogic.sol:58 | ILR | 0 -> 1: `if ((r.depositAssets > 1 \|\| r.redeemShares > 0) && r.epoch != epoch) revert E.RequestPendi` | equivalent: EQ-MIN: r.depositAssets is 0 or >= MIN_DEPOSIT (10e6), so `> 1` == `> 0` |
| 38 | VaultLogic.sol:58 | ILR | 0 -> 1: `if ((r.depositAssets > 0 \|\| r.redeemShares > 1) && r.epoch != epoch) revert E.RequestPendi` | boundary/near-equivalent: B1U: differs only when a pending redemption is exactly 1 share unit (1e-12 share) and the controller mixes epochs; value at stake <= 1 share unit |
| 42 | VaultLogic.sol:60 | SDL | delete `$.evmInSinceBridge += assets;` | killed-by-hl-r2: killed by M01_kills_requestDepositEvmInNotTracked |
| 52 | VaultLogic.sol:77 | RR | delete `if (shares == 0) revert E.ZeroAmount();` | killed-by-hl-r2: killed by M17_kills_zeroAmountGuards |
| 54 | VaultLogic.sol:78 | ILR | 0 -> 1: `if (controller == address(1)) revert E.ZeroAddress();` | killed-by-hl-r2: killed by M15_kills_zeroController |
| 55 | VaultLogic.sol:78 | RR | delete `if (controller == address(0)) revert E.ZeroAddress();` | killed-by-hl-r2: killed by M15_kills_zeroController |
| 59 | VaultLogic.sol:82 | SDL | delete `_rejoinCarry($, controller);` | equivalent: EQ: requestRedeem sets r.epoch = currentEpoch right after (line 89), which subsumes _rejoinCarry's only write |
| 72 | VaultLogic.sol:100 | ILR | 0 -> 1: `if (r.depositAssets == 1) revert E.NothingToCancel();` | killed-by-hl-r2: killed by M17_kills_zeroAmountGuards |
| 73 | VaultLogic.sol:100 | RR | delete `if (r.depositAssets == 0) revert E.NothingToCancel();` | killed-by-hl-r2: killed by M17_kills_zeroAmountGuards |
| 77 | VaultLogic.sol:104 | RR | delete `if (!carried) revert E.NothingToCancel();` | killed-by-hl-r2: killed by M14_kills_cancelOfAPricedDeposit |
| 86 | VaultLogic.sol:110 | SDL | delete `$.evmOutSinceBridge += assets;` | killed-by-hl-r2: killed by M02_kills_cancelDepositEvmOutNotTracked, M06_kills_evmOutNotReset |
| 88 | VaultLogic.sol:117 | SDL | delete `_claimIfSettled($, msg.sender);` | equivalent: EQ: in cancelRedeemRequest the leading _claimIfSettled only acts on a settled request, and then r.epoch != currentEpoch makes the call revert, rolling the claim back (VERIFY2 B2); for a current request it returns at once |
| 91 | VaultLogic.sol:119 | LOR | || -> &&: `if (r.epoch != $.currentEpoch && r.redeemShares == 0) revert E.NothingToCancel();` | killed-by-hl-r2: killed by M13_kills_cancelRedeemTwice, M17_kills_zeroAmountGuards |
| 92 | VaultLogic.sol:119 | ILR | 0 -> 1: `if (r.epoch != $.currentEpoch \|\| r.redeemShares == 1) revert E.NothingToCancel();` | killed-by-hl-r2: killed by M13_kills_cancelRedeemTwice, M17_kills_zeroAmountGuards |
| 94 | VaultLogic.sol:121 | ILR | 0 -> 1: `r.redeemShares = 1;` | killed-by-hl-r2: killed by M13_kills_cancelRedeemTwice |
| 95 | VaultLogic.sol:121 | SDL | delete `r.redeemShares = 0;` | killed-by-hl-r2: killed by M13_kills_cancelRedeemTwice |
| 114 | VaultLogic.sol:141 | ILR | 0 -> 1: `if (r.depositAssets == 1 && r.redeemShares == 0) return;` | equivalent: EQ-MIN: depositAssets is 0 or >= 10e6, so the early return for `== 1` never fires; for a zero request the function continues and writes zeros (state equivalent) |
| 115 | VaultLogic.sol:141 | ILR | 0 -> 1: `if (r.depositAssets == 0 && r.redeemShares == 1) return;` | boundary/near-equivalent: B1U: a redemption of exactly 1 share unit with no deposit is never delivered; worth < 1 wei of USDC unless the share price is >= 1e6x the initial one |
| 116 | VaultLogic.sol:141 | SDL | delete `if (r.depositAssets == 0 && r.redeemShares == 0) return;` | equivalent: EQ-STATE: without the early return a zero request runs through claimableWithCarry (all zero), writes zeros and emits Claimed(0,0) |
| 122 | VaultLogic.sol:147 | ROR | > -> >=: `if (shares >= 0) VaultMath.transfer(address(this), controller, shares);` | equivalent: EQ-STATE: transfer of 0 shares is a no-op (event only) |
| 124 | VaultLogic.sol:147 | ILR | 0 -> 1: `if (shares > 1) VaultMath.transfer(address(this), controller, shares);` | boundary/near-equivalent: B1U: returned shares of exactly 1 unit are not delivered (left in the vault); <= 1 share unit |
| 127 | VaultLogic.sol:148 | ROR | > -> >=: `if (assets >= 0) {` | equivalent: EQ-STATE: assets == 0 path moves 0 USDC and adds 0 to the trackers |
| 129 | VaultLogic.sol:148 | ILR | 0 -> 1: `if (assets > 1) {` | killed-by-hl-r2: killed by M81_kills_oneUnitBoundaries |
| 130 | VaultLogic.sol:150 | ROR | > -> >=: `if (assets >= $.claimableRedeemAssets) assets = $.claimableRedeemAssets;` | equivalent: EQ: assigning assets = reserve when equal does not change assets |
| 132 | VaultLogic.sol:150 | SDL | delete `if (assets > $.claimableRedeemAssets) assets = $.claimableRedeemAssets;` | equivalent: EQ-UNREACH: per epoch the claims are floor(s_i * paid / R) with sum s_i = R, so they sum to at most what the epoch reserved (and refunds are reserved in full); assets <= claimableRedeemAssets always. Halmos could not prove this symbolically (H5 timed out, HALMOS.md); it is checked by the invariant suites (claims <= reserve) and kept as defense in depth |
| 136 | VaultLogic.sol:152 | SDL | delete `$.evmOutSinceBridge += assets;` | killed-by-hl-r2: killed by M03_kills_claimEvmOutNotTracked |
| 139 | VaultLogic.sol:163 | ROR | >= -> >: `if (r.depositAssets == 0 \|\| r.epoch > $.currentEpoch) return;` | equivalent: EQ: for r.epoch == currentEpoch claimableWithCarry returns carried = false, so _rejoinCarry changes nothing |
| 141 | VaultLogic.sol:163 | LOR | || -> &&: `if (r.depositAssets == 0 && r.epoch >= $.currentEpoch) return;` | equivalent: EQ: every branch past the early return re-checks through claimableWithCarry, which returns carried = false for a zero deposit or a current request |
| 142 | VaultLogic.sol:163 | ILR | 0 -> 1: `if (r.depositAssets == 1 \|\| r.epoch >= $.currentEpoch) return;` | equivalent: EQ-MIN: depositAssets is never exactly 1 |
| 143 | VaultLogic.sol:163 | SDL | delete `if (r.depositAssets == 0 \|\| r.epoch >= $.currentEpoch) return;` | equivalent: EQ: as 141, the early return is a gas shortcut |
| 161 | VaultLogic.sol:179 | ILR | 0 -> 1: `return msg.sender == $.manager \|\| (msg.sender == $.operator && $.operator != address(1));` | equivalent: EQ: msg.sender is never address(0), so `operator != address(0)` (or address(1)) adds nothing to `msg.sender == operator` |
| 174 | VaultLogic.sol:207 | ILR | 0 -> 1: `bool treasury = msg.sender == $.manager \|\| (msg.sender == $.operator && $.operator != addr` | equivalent: EQ: as 161 |
| 195 | VaultLogic.sol:216 | RR | delete `if (exitOnly && !$.emergency && !$.epochOverdue()) revert E.Unauthorized();` | killed-by-hl-r2: killed by M25_kills_platformExitOnlySettleBeforeOv |
| 207 | VaultLogic.sol:223 | SDL | delete `_syncBridge($);` | killed-by-hl-r2: killed by M26_kills_settleDoesNotLatch |
| 222 | VaultLogic.sol:243 | ROR | > -> >=: `if ($.checkpointNav >= 0 && $.checkpointNav < nav) priceNav = $.checkpointNav;` | equivalent: EQ-UNREACH: checkpointNav == 0 with a positive NAV and pending redemptions needs a zero-NAV checkpoint while shares exist (drawdown 100% breach); priceNav would be 0 in a case where the vault has nothing to protect |
| 223 | VaultLogic.sol:243 | ROR | > -> <=: `if ($.checkpointNav <= 0 && $.checkpointNav < nav) priceNav = $.checkpointNav;` | killed-by-hl-r2: killed by M18_kills_exitOnlyPaysAboveTheCheckpoint |
| 224 | VaultLogic.sol:243 | ROR | < -> <=: `if ($.checkpointNav > 0 && $.checkpointNav <= nav) priceNav = $.checkpointNav;` | equivalent: EQ: checkpointNav == nav gives priceNav = nav either way |
| 225 | VaultLogic.sol:243 | ROR | < -> >=: `if ($.checkpointNav > 0 && $.checkpointNav >= nav) priceNav = $.checkpointNav;` | killed-by-hl-r2: killed by M18_kills_exitOnlyPaysAboveTheCheckpoint, M19_kills_exitOnlyPaysTheHigherCheckpoin |
| 226 | VaultLogic.sol:243 | LOR | && -> ||: `if ($.checkpointNav > 0 \|\| $.checkpointNav < nav) priceNav = $.checkpointNav;` | killed-by-hl-r2: killed by M19_kills_exitOnlyPaysTheHigherCheckpoin |
| 227 | VaultLogic.sol:243 | ILR | 0 -> 1: `if ($.checkpointNav > 1 && $.checkpointNav < nav) priceNav = $.checkpointNav;` | equivalent: EQ-UNREACH: checkpointNav == 1 wei, as 222 |
| 228 | VaultLogic.sol:243 | SDL | delete `if ($.checkpointNav > 0 && $.checkpointNav < nav) priceNav = $.checkpointNav;` | killed-by-hl-r2: killed by M18_kills_exitOnlyPaysAboveTheCheckpoint |
| 231 | VaultLogic.sol:249 | ROR | > -> >=: `if (redemptionOnly && cp >= 0 && cp < nav) priceNav = cp;` | equivalent: EQ-UNREACH: cp == 0, as 222 |
| 233 | VaultLogic.sol:249 | ROR | < -> <=: `if (redemptionOnly && cp > 0 && cp <= nav) priceNav = cp;` | equivalent: EQ: cp == nav gives the same price |
| 235 | VaultLogic.sol:249 | LOR | && -> ||: `if (redemptionOnly \|\| cp > 0 && cp < nav) priceNav = cp;` | killed-by-hl-r2: killed by M20_kills_normalSettlePaysAtTheOldCheckp |
| 236 | VaultLogic.sol:249 | LOR | && -> ||: `if (redemptionOnly && cp > 0 \|\| cp < nav) priceNav = cp;` | killed-by-hl-r2: killed by M20_kills_normalSettlePaysAtTheOldCheckp |
| 237 | VaultLogic.sol:249 | ILR | 0 -> 1: `if (redemptionOnly && cp > 1 && cp < nav) priceNav = cp;` | equivalent: EQ-UNREACH: cp == 1 wei |
| 246 | VaultLogic.sol:258 | ILR | 0 -> 1: `if (depShares == 1) depIn = 0;` | killed-by-hl-r2: killed by M12_kills_zeroShareDepositSwallowed |
| 248 | VaultLogic.sol:258 | SDL | delete `if (depShares == 0) depIn = 0;` | killed-by-hl-r2: killed by M12_kills_zeroShareDepositSwallowed |
| 255 | VaultLogic.sol:268 | RND | Rounding.Floor -> Rounding.Ceil: `burned = redShares.mulDiv(paid, redAssets, Math.Rounding.Ceil);` | killed-by-hl-r2: killed by M21_kills_partialFillOverBurn |
| 258 | VaultLogic.sol:271 | ROR | > -> >=: `if (burned >= 0) VaultMath.burn(address(this), burned);` | equivalent: EQ-STATE: burn(0) is a no-op |
| 260 | VaultLogic.sol:271 | ILR | 0 -> 1: `if (burned > 1) VaultMath.burn(address(this), burned);` | boundary/near-equivalent: B1U: a partial fill that burns exactly 1 unit burns nothing (the paid USDC still reserved): the incumbents lose <= 1 share unit of value |
| 262 | VaultLogic.sol:272 | ROR | > -> >=: `if (depShares >= 0) VaultMath.mint(address(this), depShares);` | equivalent: EQ-STATE: mint(0) is a no-op |
| 264 | VaultLogic.sol:272 | ILR | 0 -> 1: `if (depShares > 1) VaultMath.mint(address(this), depShares);` | boundary/near-equivalent: B1U: a deposit epoch minting exactly 1 unit mints nothing while the claim pays 1 unit from the vault's own balance (reverts if it has none): <= 1 share unit |
| 270 | VaultLogic.sol:279 | ROR | > -> >=: `if ($.pendingDepositAssets >= 0) {` | equivalent: EQ: with an empty deposit queue the carry origin is set but no request ever points at that epoch with a deposit; the next carried deposits join the same run and resolve with it |
| 272 | VaultLogic.sol:279 | ILR | 0 -> 1: `if ($.pendingDepositAssets > 1) {` | equivalent: EQ-MIN: pendingDepositAssets is 0 or >= 10e6 |
| 276 | VaultLogic.sol:280 | ILR | 1 -> 0: `if ($.carryOrigin == 0) $.carryOrigin = epoch + 0;` | equivalent: EQ-UNREACH: origin = epoch (not epoch + 1) is consistent on both sides (carriedFrom and carryPricedIn use the same value) except for a redemption-only settle of epoch 0, which needs a loss breach before the first mint (impossible: no shares, no loss metric) |
| 279 | VaultLogic.sol:283 | ROR | > -> >=: `if ($.deferredDepositAssets >= 0) $.insiderInQueue = true;` | killed-by-hl-r2: killed by M24_kills_insiderDelayWithoutInsider |
| 280 | VaultLogic.sol:283 | ROR | > -> <=: `if ($.deferredDepositAssets <= 0) $.insiderInQueue = true;` | killed-by-hl-r2: killed by M23_kills_insiderDepositThroughARedempti, M24_kills_insiderDelayWithoutInsider |
| 281 | VaultLogic.sol:283 | BLR | true -> false: `if ($.deferredDepositAssets > 0) $.insiderInQueue = false;` | killed-by-hl-r2: killed by M23_kills_insiderDepositThroughARedempti |
| 282 | VaultLogic.sol:283 | ILR | 0 -> 1: `if ($.deferredDepositAssets > 1) $.insiderInQueue = true;` | equivalent: EQ-MIN: deferredDepositAssets is 0 or >= 10e6 |
| 283 | VaultLogic.sol:283 | SDL | delete `if ($.deferredDepositAssets > 0) $.insiderInQueue = true;` | killed-by-hl-r2: killed by M23_kills_insiderDepositThroughARedempti |
| 284 | VaultLogic.sol:284 | ASOR | += -> -=: `$.pendingDepositAssets -= $.deferredDepositAssets;` | killed-by-hl-r2: killed by M23_kills_insiderDepositThroughARedempti |
| 285 | VaultLogic.sol:284 | SDL | delete `$.pendingDepositAssets += $.deferredDepositAssets;` | killed-by-hl-r2: killed by M23_kills_insiderDepositThroughARedempti |
| 288 | VaultLogic.sol:288 | AOR | + -> -: `$.carryPricedIn[$.carryOrigin - 1] = epoch - 1;` | killed-by-hl-r2: killed by M22_kills_carryRunBookkeeping, M23_kills_insiderDepositThroughARedempti |
| 293 | VaultLogic.sol:289 | ILR | 0 -> 1: `$.carryOrigin = 1;` | killed-by-hl-r2: killed by M22_kills_carryRunBookkeeping |
| 294 | VaultLogic.sol:289 | SDL | delete `$.carryOrigin = 0;` | killed-by-hl-r2: killed by M22_kills_carryRunBookkeeping |
| 298 | VaultLogic.sol:292 | ILR | 0 -> 1: `$.insiderInQueue = $.deferredDepositAssets > 1;` | equivalent: EQ-MIN: as 282 |
| 305 | VaultLogic.sol:301 | ROR | > -> >=: `if (supply == 0 && depShares >= 0) {` | equivalent: EQ: with supply 0 and nothing minted the references are set to the supply-0 price (1e6), the next first mint overwrites them, and no risk metric is measured while supply is 0 |
| 309 | VaultLogic.sol:301 | ILR | 0 -> 1: `if (supply == 0 && depShares > 1) {` | equivalent: EQ-MIN: a first mint mints >= 10e6 * 1e6 units |
| 311 | VaultLogic.sol:303 | SDL | delete `$.peakSharePrice = price;` | killed-by-hl-r2: killed by M28_kills_firstMintKeepsTheOldPeak |
| 313 | VaultLogic.sol:306 | ROR | > -> >=: `if (price >= $.peakSharePrice) $.peakSharePrice = price;` | equivalent: EQ: assigning the same price |
| 315 | VaultLogic.sol:306 | SDL | delete `if (price > $.peakSharePrice) $.peakSharePrice = price;` | killed-by-hl-r2: killed by M29_kills_settleDoesNotRaiseThePeak |
| 323 | VaultLogic.sol:331 | SDL | delete `_syncBridge($);` | killed-by-hl-r2: killed by M27_kills_accrueFeesDoesNotLatch |
| 333 | VaultLogic.sol:341 | ILR | 0 -> 1: `if (supply == 0 \|\| assets == 1) return;` | equivalent: EQ-STATE: with NAV == 0 no fee can be minted (feeAssets == 0), with NAV == 1 wei the fee math mints 0 |
| 340 | VaultLogic.sol:345 | ROR | > -> >=: `if (withPerformance && price >= $.highWaterMark && $.performanceFeeBps > 0) {` | equivalent: EQ: price == HWM gives a zero gain, so a zero performance fee |
| 342 | VaultLogic.sol:345 | ROR | > -> >=: `if (withPerformance && price > $.highWaterMark && $.performanceFeeBps >= 0) {` | equivalent: EQ: a 0 bps performance fee adds 0 |
| 346 | VaultLogic.sol:345 | ILR | 0 -> 1: `if (withPerformance && price > $.highWaterMark && $.performanceFeeBps > 1) {` | killed-by-hl-r2: killed by M44_kills_oneBpsPerformanceFee |
| 354 | VaultLogic.sol:352 | ROR | > -> >=: `if (feeAssets >= 0 && feeAssets < assets) {` | equivalent: EQ-STATE: feeAssets == 0 mints 0 shares |
| 356 | VaultLogic.sol:352 | ROR | < -> <=: `if (feeAssets > 0 && feeAssets <= assets) {` | equivalent: EQ-UNREACH: feeAssets == assets needs fees equal to the whole NAV (management <= 5%/yr, performance <= 30% of the gain) |
| 358 | VaultLogic.sol:352 | LOR | && -> ||: `if (feeAssets > 0 \|\| feeAssets < assets) {` | equivalent: EQ-UNREACH: as 356 for the >= side; feeAssets == 0 computes 0 |
| 359 | VaultLogic.sol:352 | ILR | 0 -> 1: `if (feeAssets > 1 && feeAssets < assets) {` | boundary/near-equivalent: B1W: a fee of exactly 1 wei is not minted |
| 367 | VaultLogic.sol:354 | ROR | > -> >=: `if ($.factory != address(0) && $.protocolShareBps >= 0) {` | equivalent: EQ-STATE: a 0 bps protocol share mints 0 (one extra view call to the factory) |
| 369 | VaultLogic.sol:354 | LOR | && -> ||: `if ($.factory != address(0) \|\| $.protocolShareBps > 0) {` | equivalent: EQ: standalone vaults have protocolShareBps 0 (factory vaults pass the same branch), so the extra branch mints 0 |
| 370 | VaultLogic.sol:354 | ILR | 0 -> 1: `if ($.factory != address(1) && $.protocolShareBps > 0) {` | equivalent: EQ: factory is 0 (standalone) or the factory, never address(1) |
| 371 | VaultLogic.sol:354 | ILR | 0 -> 1: `if ($.factory != address(0) && $.protocolShareBps > 1) {` | killed-by-hl-r2: killed by M47_kills_oneBpsProtocolShare |
| 373 | VaultLogic.sol:356 | ILR | 0 -> 1: `if (protocolRecipient != address(1)) {` | equivalent: EQ-UNREACH: the factory never holds a zero protocol fee recipient (setter and constructor reject it), and never address(1) |
| 376 | VaultLogic.sol:358 | ROR | > -> >=: `if (protocolShares >= 0) VaultMath.mint(protocolRecipient, protocolShares);` | equivalent: EQ-STATE: mint(0) is a no-op |
| 378 | VaultLogic.sol:358 | ILR | 0 -> 1: `if (protocolShares > 1) VaultMath.mint(protocolRecipient, protocolShares);` | boundary/near-equivalent: B1U: a protocol cut of exactly 1 share unit is neither minted to the treasury nor to the fee recipient (1 unit less fee dilution) |
| 380 | VaultLogic.sol:361 | ROR | > -> >=: `if (feeShares >= protocolShares) VaultMath.mint($.feeRecipient, feeShares - protocolShares` | equivalent: EQ-STATE: feeShares == protocolShares mints 0 to the fee recipient |
| 384 | VaultLogic.sol:365 | ROR | > -> >=: `if (withPerformance && newPrice >= $.highWaterMark) $.highWaterMark = newPrice;` | equivalent: EQ: assigning the same HWM |
| 388 | VaultLogic.sol:367 | ROR | > -> >=: `if (feeShares >= 0 && newPrice < price) {` | equivalent: EQ: without fee shares newPrice == price, the rescale branch needs newPrice < price |
| 390 | VaultLogic.sol:367 | ROR | < -> <=: `if (feeShares > 0 && newPrice <= price) {` | equivalent: EQ: newPrice == price rescales by exactly 1 (mulDiv(x, p, p) == x) |
| 392 | VaultLogic.sol:367 | LOR | && -> ||: `if (feeShares > 0 \|\| newPrice < price) {` | equivalent: EQ: with fee shares minted newPrice <= price; at equality the rescale factor is exactly 1; without fee shares see 388 |
| 393 | VaultLogic.sol:367 | ILR | 0 -> 1: `if (feeShares > 1 && newPrice < price) {` | boundary/near-equivalent: B1U: a fee mint of exactly 1 unit does not rescale the risk references (a drift of 1 unit in 1e12 per share) |
| 409 | VaultLogic.sol:400 | ROR | < -> <=: `if ($.baseShareBps <= $.protocolShareBps) $.protocolShareBps = $.baseShareBps;` | equivalent: EQ: equal values, the assignment changes nothing |
| 419 | VaultLogic.sol:410 | ROR | < -> <=: `if (newBps <= $.baseShareBps) $.baseShareBps = newBps;` | equivalent: EQ: equal values |
| 420 | VaultLogic.sol:410 | ROR | < -> >=: `if (newBps >= $.baseShareBps) $.baseShareBps = newBps;` | killed-by-hl-r2: killed by M46_kills_lowerProtocolShareRaisesTheBas |
| 421 | VaultLogic.sol:410 | SDL | delete `if (newBps < $.baseShareBps) $.baseShareBps = newBps;` | equivalent: EQ-STATE: base above the protocol share is never used (leaveHosted only lowers the protocol share to a lower base); only the baseShareBps view differs |
| 423 | VaultLogic.sol:420 | RR | delete `if (!_treasury($)) revert E.Unauthorized();` | killed-by-hl-r2: killed by M30_kills_treasuryAuth |
| 425 | VaultLogic.sol:421 | ILR | 0 -> 1: `if (amount == 1) revert E.ZeroAmount();` | killed-by-hl-r2: killed by M31_kills_bridgeToCoreGuards |
| 426 | VaultLogic.sol:421 | RR | delete `if (amount == 0) revert E.ZeroAmount();` | killed-by-hl-r2: killed by M31_kills_bridgeToCoreGuards |
| 430 | VaultLogic.sol:426 | RR | delete `if (!HyperCore.coreUserExists(address(this))) revert E.CoreAccountInactive();` | killed-by-hl-r2: killed by M31_kills_bridgeToCoreGuards |
| 433 | VaultLogic.sol:428 | RR | delete `if (amount > idle) revert E.InsufficientIdle(idle, amount);` | killed-by-hl-r2: killed by M31_kills_bridgeToCoreGuards |
| 451 | VaultLogic.sol:440 | RR | delete `if (amount == 0) revert E.ZeroAmount();` | killed-by-hl-r2: killed by M32_kills_bridgeToEvmLegs |
| 456 | VaultLogic.sol:443 | AOR | + -> -: `if (amount > spotUsd + perpFree) revert E.InsufficientLiquidity(spotUsd - perpFree, amount` | killed-by-hl-r2: killed by M32_kills_bridgeToEvmLegs |
| 457 | VaultLogic.sol:443 | RR | delete `if (amount > spotUsd + perpFree) revert E.InsufficientLiquidity(spotUsd + perpFree, amount` | killed-by-hl-r2: killed by M32_kills_bridgeToEvmLegs |
| 461 | VaultLogic.sol:444 | AOR | + -> -: `if (amount < MIN_BRIDGE && amount != spotUsd - perpFree) revert E.BridgeTooSmall();` | killed-by-hl-r2: killed by M32_kills_bridgeToEvmLegs |
| 468 | VaultLogic.sol:446 | ROR | > -> >=: `if (amount >= spotUsd) HyperCore.usdClassTransfer(SafeCast.toUint64(amount - spotUsd), fal` | killed-by-hl-r2: killed by M33_kills_bridgeToEvmNoZeroPerpLeg |
| 470 | VaultLogic.sol:446 | AOR | - -> +: `if (amount > spotUsd) HyperCore.usdClassTransfer(SafeCast.toUint64(amount + spotUsd), fals` | killed-by-hl-r2: killed by M32_kills_bridgeToEvmLegs |
| 471 | VaultLogic.sol:446 | BLR | false -> true: `if (amount > spotUsd) HyperCore.usdClassTransfer(SafeCast.toUint64(amount - spotUsd), true` | killed-by-hl-r2: killed by M32_kills_bridgeToEvmLegs |
| 472 | VaultLogic.sol:446 | SDL | delete `if (amount > spotUsd) HyperCore.usdClassTransfer(SafeCast.toUint64(amount - spotUsd), fals` | killed-by-hl-r2: killed by M32_kills_bridgeToEvmLegs |
| 475 | VaultLogic.sol:456 | SDL | delete `_syncBridge($);` | equivalent: EQ: _openWindow re-arms the latch (bridgeLanded = false) right after; bridgePending reads the landing live |
| 485 | VaultLogic.sol:468 | SDL | delete `$.coreAtBridge = core;` | equivalent: EQ: coreAtBridge is written and never read since the R3-01 fix (dead storage write) |
| 486 | VaultLogic.sol:469 | SDL | delete `$.spotAtBridge = VaultMath.coreSpotUsd();` | killed-by-hl-r2: killed by M04_kills_spotSnapshotNotRefreshed |
| 487 | VaultLogic.sol:470 | SDL | delete `$.evmAtBridge = $.asset.balanceOf(address(this));` | killed-by-hl-r2: killed by M06_kills_evmOutNotReset, M35_kills_windowBoundaries |
| 488 | VaultLogic.sol:471 | ILR | 0 -> 1: `$.evmInSinceBridge = 1;` | equivalent: EQ-TOL: evmIn = 1 wei only matters for an arrival of exactly bridgeAmount - 1 USDC (BRIDGE_LANDING_TOLERANCE) |
| 490 | VaultLogic.sol:472 | ILR | 0 -> 1: `$.evmOutSinceBridge = 1;` | equivalent: EQ-TOL: as 488 |
| 491 | VaultLogic.sol:472 | SDL | delete `$.evmOutSinceBridge = 0;` | killed-by-hl-r2: killed by M06_kills_evmOutNotReset |
| 506 | VaultLogic.sol:499 | BLR | false -> true: `$.bridgeLanded = true;` | equivalent: EQ: the seed lands before any share exists; the first mint ignores NAV (1 USDC = 1e6 units), so an early latch prices nothing |
| 507 | VaultLogic.sol:499 | SDL | delete `$.bridgeLanded = false;` | equivalent: EQ: bridgeLanded is false in fresh storage at initialization |
| 513 | VaultLogic.sol:508 | RR | delete `if (!ok) revert E.CallFailed(ret);` | killed-by-hl-r2: killed by M43_kills_fundCoreGasFailure |
| 515 | VaultLogic.sol:514 | RR | delete `if (!_treasury($)) revert E.Unauthorized();` | killed-by-hl-r2: killed by M30_kills_treasuryAuth |
| 517 | VaultLogic.sol:515 | ILR | 0 -> 1: `if (amount == 1) revert E.ZeroAmount();` | killed-by-hl-r2: killed by M34_kills_moveUsdAction |
| 518 | VaultLogic.sol:515 | RR | delete `if (amount == 0) revert E.ZeroAmount();` | killed-by-hl-r2: killed by M34_kills_moveUsdAction |
| 522 | VaultLogic.sol:517 | SDL | delete `_syncBridge($);` | killed-by-hl-r2: killed by M45_kills_moveUsdDoesNotLatch |
| 524 | VaultLogic.sol:519 | SDL | delete `HyperCore.usdClassTransfer(SafeCast.toUint64(amount), toPerp);` | killed-by-hl-r2: killed by M34_kills_moveUsdAction |
| 536 | VaultLogic.sol:540 | LOR | || -> &&: `if (sz == 0 && limitPx == 0) revert E.ZeroAmount();` | killed-by-hl-r2: killed by M38_kills_zeroOrder |
| 537 | VaultLogic.sol:540 | ILR | 0 -> 1: `if (sz == 1 \|\| limitPx == 0) revert E.ZeroAmount();` | killed-by-hl-r2: killed by M38_kills_zeroOrder |
| 538 | VaultLogic.sol:540 | ILR | 0 -> 1: `if (sz == 0 \|\| limitPx == 1) revert E.ZeroAmount();` | killed-by-hl-r2: killed by M38_kills_zeroOrder |
| 539 | VaultLogic.sol:540 | RR | delete `if (sz == 0 \|\| limitPx == 0) revert E.ZeroAmount();` | killed-by-hl-r2: killed by M38_kills_zeroOrder |
| 540 | VaultLogic.sol:541 | ROR | >= -> >: `if (asset_ > HyperCore.SPOT_ASSET_OFFSET) revert E.OrderRejected("spot not supported");` | equivalent: EQ: asset 10000 is rejected by VaultPolicy.checkOrder with the same OrderRejected("spot not supported") |
| 550 | VaultLogic.sol:553 | SDL | delete `HyperCore.cancelByOid(asset_, oid);` | killed-by-hl-r2: killed by M40_kills_cancelOrderAction |
| 561 | VaultLogic.sol:565 | ILR | 0 -> 1: `if (!isManager && !_platform($, guardian, sentinel) && !(msg.sender == $.operator && $.ope` | equivalent: EQ: as 161 (msg.sender is never address(0)) |
| 578 | VaultLogic.sol:573 | ROR | >= -> >: `if (asset_ > HyperCore.SPOT_ASSET_OFFSET) revert E.UnsupportedAsset();` | killed-by-hl-r2: killed by M39_kills_flattenGuards |
| 580 | VaultLogic.sol:573 | RR | delete `if (asset_ >= HyperCore.SPOT_ASSET_OFFSET) revert E.UnsupportedAsset();` | killed-by-hl-r2: killed by M39_kills_flattenGuards |
| 582 | VaultLogic.sol:575 | ILR | 0 -> 1: `if (p.szi == 1) return;` | killed-by-hl-r2: killed by M39_kills_flattenGuards |
| 583 | VaultLogic.sol:575 | SDL | delete `if (p.szi == 0) return;` | killed-by-hl-r2: killed by M39_kills_flattenGuards |
| 585 | VaultLogic.sol:578 | ILR | 0 -> 1: `HyperCore.limitOrder(asset_, isBuy, px, sz, true, HyperCore.TIF_IOC, 1);` | killed-by-hl-r2: killed by M39_kills_flattenGuards |
| 593 | VaultLogic.sol:604 | RR | delete `if ($.hardStop()) revert E.ReduceOnlyMode();` | equivalent: EQ-UNREACH: in a full stop the stored agent is always 0 (triggerBreach / triggerEmergency revoke it; setAgent refuses in a full stop), so syncAgent reverts ZeroAddress first |
| 596 | VaultLogic.sol:610 | ILR | 0 -> 1: `if (newAgent == address(1)) revert E.ZeroAddress();` | killed-by-hl-r2: killed by M41_kills_agentSlotGuards |
| 597 | VaultLogic.sol:610 | RR | delete `if (newAgent == address(0)) revert E.ZeroAddress();` | killed-by-hl-r2: killed by M41_kills_agentSlotGuards |
| 606 | VaultLogic.sol:625 | ILR | 0 -> 1: `if (old == address(1)) return;` | killed-by-hl-r2: killed by M41_kills_agentSlotGuards |
| 607 | VaultLogic.sol:625 | SDL | delete `if (old == address(0)) return;` | killed-by-hl-r2: killed by M41_kills_agentSlotGuards |
| 613 | VaultLogic.sol:637 | RR | delete `if ($.lock == 1) revert E.Reentrancy();` | killed-by-hl-r2: killed by M42_kills_reentrancyLock |
| 614 | VaultLogic.sol:638 | ILR | 1 -> 0: `$.lock = 0;` | killed-by-hl-r2: killed by M42_kills_reentrancyLock |
| 615 | VaultLogic.sol:638 | SDL | delete `$.lock = 1;` | killed-by-hl-r2: killed by M42_kills_reentrancyLock |
| 624 | VaultMath.sol:79 | RR | delete `if (bal < amount) revert IERC20Errors.ERC20InsufficientBalance(from, bal, amount);` | equivalent: EQ-UNREACH: VaultMath.burn is only called on the vault's own balance for burned <= the shares it escrows for the epoch |
| 631 | VaultMath.sol:90 | RR | delete `if (bal < amount) revert IERC20Errors.ERC20InsufficientBalance(from, bal, amount);` | killed-by-hl-r2: killed by M36_kills_shareBalanceChecks |
| 637 | VaultMath.sol:101 | SDL | delete `if (current == type(uint256).max) return;` | killed-by-hl-r2: killed by M37_kills_allowance |
| 638 | VaultMath.sol:102 | ROR | < -> <=: `if (current <= amount) revert IERC20Errors.ERC20InsufficientAllowance(spender, current, am` | killed-by-hl-r2: killed by M37_kills_allowance |
| 641 | VaultMath.sol:104 | AOR | - -> +: `e._allowances[holder][spender] = current + amount;` | killed-by-hl-r2: killed by M37_kills_allowance |
| 642 | VaultMath.sol:104 | SDL | delete `e._allowances[holder][spender] = current - amount;` | killed-by-hl-r2: killed by M37_kills_allowance |
| 645 | VaultMath.sol:115 | ROR | > -> >=: `return bal >= reserved ? bal - reserved : 0;` | equivalent: EQ: bal == reserved gives 0 either way |
| 650 | VaultMath.sol:120 | ILR | 0 -> 1: `if (!HyperCore.coreUserExists(address(this))) return 1;` | killed-by-hl-r2: killed by M81_kills_oneUnitBoundaries |
| 651 | VaultMath.sol:120 | SDL | delete `if (!HyperCore.coreUserExists(address(this))) return 0;` | equivalent: EQ-MOCK: without the guard the precompiles are read for an account that does not exist; HyperCore returns zeros (the mock returns its stored zeros), NAV unchanged |
| 654 | VaultMath.sol:123 | ROR | > -> >=: `return e >= 0 ? uint256(e) : 0;` | equivalent: EQ: e == 0 returns 0 either way |
| 656 | VaultMath.sol:123 | ILR | 0 -> 1: `return e > 1 ? uint256(e) : 0;` | killed-by-hl-r2: killed by M81_kills_oneUnitBoundaries |
| 662 | VaultMath.sol:133 | ROR | <= -> <: `if (block.number < last + BRIDGE_SETTLE_BLOCKS) return true;` | killed-by-hl-r2: killed by M35_kills_windowBoundaries |
| 666 | VaultMath.sol:133 | CR | BRIDGE_SETTLE_BLOCKS -> 0: `if (block.number <= last + 0) return true;` | killed-by-hl-r2: killed by M35_kills_windowBoundaries |
| 679 | VaultMath.sol:141 | ROR | > -> >=: `if (last == 0 \|\| $.bridgeLanded \|\| block.number >= last + MAX_UNLANDED_BLOCKS) return fals` | killed-by-hl-r2: killed by M35_kills_windowBoundaries |
| 685 | VaultMath.sol:141 | ILR | 0 -> 1: `if (last == 1 \|\| $.bridgeLanded \|\| block.number > last + MAX_UNLANDED_BLOCKS) return false` | killed-by-hl-r2: killed by M29_kills_settleDoesNotRaiseThePeak |
| 691 | VaultMath.sol:152 | ROR | > -> >=: `uint256 want = $.bridgeAmount >= BRIDGE_LANDING_TOLERANCE ? $.bridgeAmount - BRIDGE_LANDIN` | equivalent: EQ: bridgeAmount == 1 USDC gives want 0 either way |
| 694 | VaultMath.sol:152 | ILR | 0 -> 1: `uint256 want = $.bridgeAmount > BRIDGE_LANDING_TOLERANCE ? $.bridgeAmount - BRIDGE_LANDING` | killed-by-hl-r2: killed by M49_kills_landingTolerance |
| 695 | VaultMath.sol:152 | CR | BRIDGE_LANDING_TOLERANCE -> 0: `uint256 want = $.bridgeAmount > 0 ? $.bridgeAmount - BRIDGE_LANDING_TOLERANCE : 0;` | killed-by-hl-r2: killed by M49_kills_landingTolerance |
| 696 | VaultMath.sol:152 | CR | BRIDGE_LANDING_TOLERANCE -> 2*BRIDGE_LANDING_TOLERANCE: `uint256 want = $.bridgeAmount > (BRIDGE_LANDING_TOLERANCE * 2) ? $.bridgeAmount - BRIDGE_L` | boundary/near-equivalent: B2W: a full-amount bridge between 1 and 2 USDC counts as landed with nothing arrived (at most 2 USDC carried as in transit) |
| 698 | VaultMath.sol:152 | CR | BRIDGE_LANDING_TOLERANCE -> 2*BRIDGE_LANDING_TOLERANCE: `uint256 want = $.bridgeAmount > BRIDGE_LANDING_TOLERANCE ? $.bridgeAmount - (BRIDGE_LANDIN` | killed-by-hl-r2: killed by M49_kills_landingTolerance |
| 703 | VaultMath.sol:157 | AOR | + -> -: `uint256 bal = $.asset.balanceOf(address(this)) - $.evmOutSinceBridge;` | killed-by-hl-r2: killed by M02_kills_cancelDepositEvmOutNotTracked, M03_kills_claimEvmOutNotTracked |
| 704 | VaultMath.sol:158 | ROR | >= -> >: `return bal > $.evmAtBridge + $.evmInSinceBridge + want;` | killed-by-hl-r2: killed by M49_kills_landingTolerance |
| 706 | VaultMath.sol:158 | AOR | + -> -: `return bal >= $.evmAtBridge - $.evmInSinceBridge + want;` | killed-by-hl-r2: killed by M01_kills_requestDepositEvmInNotTracked, M05_kills_evmInNotReset |
| 709 | VaultMath.sol:163 | ILR | 0 -> 1: `if (!HyperCore.coreUserExists(address(this))) return 1;` | boundary/near-equivalent: B1W: as 650 |
| 710 | VaultMath.sol:163 | SDL | delete `if (!HyperCore.coreUserExists(address(this))) return 0;` | equivalent: EQ-MOCK: as 651 |
| 711 | VaultMath.sol:164 | AOR | / -> *: `return uint256(HyperCore.spotBalance(address(this), HyperCore.USDC_TOKEN).total) * 100;` | killed-by-hl-r2: killed by M49_kills_landingTolerance |
| 718 | VaultMath.sol:175 | ILR | 0 -> 1: `if (supply == 0) return 1;` | equivalent: EQ: the price of a supply-0 vault only seeds the risk references, which the first mint resets |
| 754 | VaultMath.sol:199 | RND | Rounding.Floor -> Rounding.Ceil: `return toAssets(ONE_SHARE, totalAssets($), totalSupply(), Math.Rounding.Ceil);` | killed-by-hl-r2: killed by M80_kills_sharePriceRoundsDown |
| 761 | VaultMath.sol:227 | ROR | >= -> >: `if (r.epoch > $.currentEpoch) return (0, 0, false);` | equivalent: EQ: epochs[currentEpoch] is empty, so a current request also returns zeros |
| 763 | VaultMath.sol:227 | BLR | false -> true: `if (r.epoch >= $.currentEpoch) return (0, 0, true);` | equivalent: EQ-UNREACH: every caller only asks for r.epoch < currentEpoch (claim, cancelDepositRequest, _rejoinCarry, _claimIfSettled return before) |
| 764 | VaultMath.sol:227 | ILR | 0 -> 1: `if (r.epoch >= $.currentEpoch) return (1, 0, false);` | equivalent: EQ-UNREACH: as 763 |
| 765 | VaultMath.sol:227 | ILR | 0 -> 1: `if (r.epoch >= $.currentEpoch) return (0, 1, false);` | equivalent: EQ-UNREACH: as 763 |
| 766 | VaultMath.sol:227 | SDL | delete `if (r.epoch >= $.currentEpoch) return (0, 0, false);` | equivalent: EQ: as 761 (falls through on an empty epoch record, all zero) |
| 767 | VaultMath.sol:229 | ROR | > -> >=: `if (r.depositAssets >= 0) {` | equivalent: EQ: a request without a deposit computes 0 shares; a carried flag on a pure redemption changes no caller (claim needs redeemShares > 0 to proceed only when carried, which it has) |
| 769 | VaultMath.sol:229 | ILR | 0 -> 1: `if (r.depositAssets > 1) {` | equivalent: EQ-MIN |
| 780 | VaultMath.sol:236 | ROR | > -> >=: `if (!carried && pe.depositAssets >= 0) {` | equivalent: EQ-UNREACH: the pricing epoch's depositAssets always includes the request's own deposit |
| 782 | VaultMath.sol:236 | LOR | && -> ||: `if (!carried \|\| pe.depositAssets > 0) {` | equivalent: EQ: a carried deposit points at a redemption-only epoch whose depositAssets is 0 |
| 784 | VaultMath.sol:236 | ILR | 0 -> 1: `if (!carried && pe.depositAssets > 1) {` | equivalent: EQ-MIN |
| 790 | VaultMath.sol:242 | ROR | > -> >=: `if (s >= 0 && e.redeemShares > 0) {` | equivalent: EQ: s == 0 adds 0 |
| 792 | VaultMath.sol:242 | ROR | > -> >=: `if (s > 0 && e.redeemShares >= 0) {` | equivalent: EQ-UNREACH: s > 0 implies e.redeemShares >= s > 0 |
| 794 | VaultMath.sol:242 | LOR | && -> ||: `if (s > 0 \|\| e.redeemShares > 0) {` | equivalent: EQ: as 790/792 |
| 795 | VaultMath.sol:242 | ILR | 0 -> 1: `if (s > 1 && e.redeemShares > 0) {` | boundary/near-equivalent: B1U: a redemption of exactly 1 unit is neither paid nor returned |
| 796 | VaultMath.sol:242 | ILR | 0 -> 1: `if (s > 0 && e.redeemShares > 1) {` | boundary/near-equivalent: B1U: an epoch whose only redemption is 1 unit pays nothing |
| 803 | VaultMath.sol:245 | ROR | < -> <=: `if (burnedForMe <= s) shares += s - burnedForMe;` | equivalent: EQ: burnedForMe == s adds 0 |
| 809 | VaultMath.sol:253 | ILR | 0 -> 1: `if (pending == 1) return BPS;` | equivalent: EQ: pending 0 gives owed 0, which returns BPS |
| 810 | VaultMath.sol:253 | SDL | delete `if (pending == 0) return BPS;` | equivalent: EQ: as 809 |
| 811 | VaultMath.sol:255 | ROR | > -> >=: `if ($.checkpointNav >= 0 && $.checkpointNav < nav) nav = $.checkpointNav;` | equivalent: EQ-UNREACH: checkpoint 0 with pending redemptions (as 222) |
| 812 | VaultMath.sol:255 | ROR | > -> <=: `if ($.checkpointNav <= 0 && $.checkpointNav < nav) nav = $.checkpointNav;` | killed-by-hl-r2: killed by M48_kills_emergencyFillBps |
| 813 | VaultMath.sol:255 | ROR | < -> <=: `if ($.checkpointNav > 0 && $.checkpointNav <= nav) nav = $.checkpointNav;` | equivalent: EQ: checkpoint == NAV |
| 814 | VaultMath.sol:255 | ROR | < -> >=: `if ($.checkpointNav > 0 && $.checkpointNav >= nav) nav = $.checkpointNav;` | killed-by-hl-r2: killed by M48_kills_emergencyFillBps |
| 815 | VaultMath.sol:255 | LOR | && -> ||: `if ($.checkpointNav > 0 \|\| $.checkpointNav < nav) nav = $.checkpointNav;` | boundary/near-equivalent: VIEW: with NAV below the checkpoint the estimate would price at the checkpoint (under-reports the fill, conservative); emergencyFillBps is a read-only UI / monitor estimate. Not killed |
| 816 | VaultMath.sol:255 | ILR | 0 -> 1: `if ($.checkpointNav > 1 && $.checkpointNav < nav) nav = $.checkpointNav;` | equivalent: EQ-UNREACH: checkpoint of 1 wei |
| 817 | VaultMath.sol:255 | SDL | delete `if ($.checkpointNav > 0 && $.checkpointNav < nav) nav = $.checkpointNav;` | killed-by-hl-r2: killed by M48_kills_emergencyFillBps |
| 818 | VaultMath.sol:256 | RND | Rounding.Floor -> Rounding.Ceil: `uint256 owed = toAssets(pending, nav, totalSupply(), Math.Rounding.Ceil);` | boundary/near-equivalent: VIEW-B1W: owed rounded up by 1 wei in the read-only estimate |
| 821 | VaultMath.sol:258 | ROR | >= -> >: `if (owed == 0 \|\| available > owed) return BPS;` | equivalent: EQ: available == owed gives exactly BPS |
| 823 | VaultMath.sol:258 | LOR | || -> &&: `if (owed == 0 && available >= owed) return BPS;` | killed-by-hl-r2: killed by M48_kills_emergencyFillBps |
| 824 | VaultMath.sol:258 | ILR | 0 -> 1: `if (owed == 1 \|\| available >= owed) return BPS;` | boundary/near-equivalent: VIEW-B1W: an owed of exactly 1 wei reads as fully covered |
| 825 | VaultMath.sol:258 | SDL | delete `if (owed == 0 \|\| available >= owed) return BPS;` | killed-by-hl-r2: killed by M48_kills_emergencyFillBps |
| 826 | VaultMath.sol:259 | RND | Rounding.Floor -> Rounding.Ceil: `return available.mulDiv(BPS, owed, Math.Rounding.Ceil);` | killed-by-hl-r2: killed by M48_kills_emergencyFillBps |
| 832 | VaultPolicy.sol:94 | LOR | || -> &&: `if (timelockDelay_ < MIN_TIMELOCK && timelockDelay_ > MAX_TIMELOCK) revert InvalidTimelock` | killed-by-hl-r2: killed by M50_kills_policyInitBounds |
| 833 | VaultPolicy.sol:94 | CR | MIN_TIMELOCK -> 0: `if (timelockDelay_ < 0 \|\| timelockDelay_ > MAX_TIMELOCK) revert InvalidTimelock();` | killed-by-hl-r2: killed by M50_kills_policyInitBounds |
| 836 | VaultPolicy.sol:94 | CR | MAX_TIMELOCK -> 2*MAX_TIMELOCK: `if (timelockDelay_ < MIN_TIMELOCK \|\| timelockDelay_ > (MAX_TIMELOCK * 2)) revert InvalidTi` | killed-by-hl-r2: killed by M50_kills_policyInitBounds |
| 837 | VaultPolicy.sol:94 | RR | delete `if (timelockDelay_ < MIN_TIMELOCK \|\| timelockDelay_ > MAX_TIMELOCK) revert InvalidTimelock` | killed-by-hl-r2: killed by M50_kills_policyInitBounds |
| 838 | VaultPolicy.sol:95 | SDL | delete `_validate(config_);` | killed-by-hl-r2: killed by M50_kills_policyInitBounds |
| 843 | VaultPolicy.sol:183 | ROR | >= -> >: `if (asset > HyperCore.SPOT_ASSET_OFFSET) return (false, "spot not supported");` | killed-by-hl-r2: killed by M51_kills_checkOrderEdges |
| 845 | VaultPolicy.sol:183 | BLR | false -> true: `if (asset >= HyperCore.SPOT_ASSET_OFFSET) return (true, "spot not supported");` | killed-by-hl-r2: killed by M51_kills_checkOrderEdges |
| 846 | VaultPolicy.sol:183 | SDL | delete `if (asset >= HyperCore.SPOT_ASSET_OFFSET) return (false, "spot not supported");` | killed-by-hl-r2: killed by M51_kills_checkOrderEdges |
| 853 | VaultPolicy.sol:185 | BLR | false -> true: `if (markPx1e8 == 0) return (true, "no mark");` | killed-by-hl-r2: killed by M51_kills_checkOrderEdges |
| 854 | VaultPolicy.sol:185 | ILR | 0 -> 1: `if (markPx1e8 == 1) return (false, "no mark");` | killed-by-hl-r2: killed by M51_kills_checkOrderEdges |
| 855 | VaultPolicy.sol:185 | SDL | delete `if (markPx1e8 == 0) return (false, "no mark");` | killed-by-hl-r2: killed by M51_kills_checkOrderEdges |
| 858 | VaultPolicy.sol:187 | ROR | > -> >=: `if (isBuy && limitPx >= markPx1e8 + band) return (false, "price above band");` | killed-by-hl-r2: killed by M51_kills_checkOrderEdges |
| 864 | VaultPolicy.sol:188 | ROR | < -> <=: `if (!isBuy && uint256(limitPx) + band <= markPx1e8) return (false, "price below band");` | killed-by-hl-r2: killed by M51_kills_checkOrderEdges |
| 872 | VaultPolicy.sol:191 | ROR | > -> >=: `uint256 px = limitPx >= markPx1e8 ? limitPx : markPx1e8;` | equivalent: EQ: equal values |
| 880 | VaultPolicy.sol:194 | ROR | > -> >=: `uint256 equity = accountValue >= 0 ? uint256(uint64(accountValue)) : 0;` | equivalent: EQ: accountValue 0 gives equity 0 either way |
| 882 | VaultPolicy.sol:194 | ILR | 0 -> 1: `uint256 equity = accountValue > 1 ? uint256(uint64(accountValue)) : 0;` | killed-by-hl-r2: killed by M82_kills_checkOrderEquityEdge |
| 883 | VaultPolicy.sol:194 | ILR | 0 -> 1: `uint256 equity = accountValue > 0 ? uint256(uint64(accountValue)) : 1;` | killed-by-hl-r2: killed by M82_kills_checkOrderEquityEdge |
| 897 | VaultPolicy.sol:209 | ROR | < -> <=: `isBuy = szi <= 0;` | equivalent: EQ-UNREACH: flattenOrder is only reached with szi != 0 (flatten returns on 0) |
| 899 | VaultPolicy.sol:209 | ILR | 0 -> 1: `isBuy = szi < 1;` | equivalent: EQ-UNREACH: as 897 |
| 901 | VaultPolicy.sol:210 | ROR | < -> <=: `uint256 absSzi = szi <= 0 ? uint256(-int256(szi)) : uint256(int256(szi));` | equivalent: EQ-UNREACH: as 897 |
| 903 | VaultPolicy.sol:210 | ILR | 0 -> 1: `uint256 absSzi = szi < 1 ? uint256(-int256(szi)) : uint256(int256(szi));` | equivalent: EQ-UNREACH: as 897 |
| 918 | VaultPolicy.sol:240 | ROR | > -> >=: `if (block.timestamp >= at + CHECKPOINT_MAX_AGE) revert StaleCheckpoint();` | killed-by-hl-r2: killed by M52_kills_checkpointAgeEdge |
| 924 | VaultPolicy.sol:241 | ROR | > -> >=: `if ((nav >= prev ? nav - prev : prev - nav) > cap) revert NavMoved(nav, prev);` | equivalent: EQ: nav == prev gives a zero move either way |
| 938 | VaultPolicy.sol:244 | ROR | > -> >=: `if (nav >= prev + cap) nav = prev + cap; else if (nav + cap < prev) nav = prev - cap;` | equivalent: EQ: equal values |
| 940 | VaultPolicy.sol:244 | ROR | < -> <=: `if (nav > prev + cap) nav = prev + cap; else if (nav + cap <= prev) nav = prev - cap;` | equivalent: EQ: equal values |
| 950 | VaultPolicy.sol:259 | SDL | delete `delete _pending;` | killed-by-hl-r2: killed by M53_kills_configQueue |
| 955 | VaultPolicy.sol:269 | RR | delete `if (!_pending.exists) revert NothingPending();` | killed-by-hl-r2: killed by M53_kills_configQueue |
| 958 | VaultPolicy.sol:273 | SDL | delete `delete _pending;` | equivalent: EQ: re-applying the same pending config is idempotent; a new queue overwrites it and a tightening deletes it (only pendingConfig().exists reads differently) |
| 959 | VaultPolicy.sol:277 | UOI | delete !: `if (_pending.exists) revert NothingPending();` | killed-by-hl-r2: killed by M53_kills_configQueue |
| 960 | VaultPolicy.sol:277 | RR | delete `if (!_pending.exists) revert NothingPending();` | equivalent: EQ-STATE: cancelling with nothing queued deletes nothing |
| 961 | VaultPolicy.sol:278 | SDL | delete `delete _pending;` | killed-by-hl-r2: killed by M53_kills_configQueue |
| 964 | VaultPolicy.sol:287 | ILR | 0 -> 1: `assetAllowEta[asset] = 1;` | killed-by-hl-r2: killed by M54_kills_disallowDropsTheQueuedAllow |
| 965 | VaultPolicy.sol:287 | SDL | delete `assetAllowEta[asset] = 0;` | killed-by-hl-r2: killed by M54_kills_disallowDropsTheQueuedAllow |
| 966 | VaultPolicy.sol:292 | ROR | >= -> >: `if (asset > HyperCore.SPOT_ASSET_OFFSET) revert SpotNotSupported();` | equivalent: EQ: a queued allow of asset 10000 can never be applied (_allow reverts SpotNotSupported) |
| 973 | VaultPolicy.sol:301 | ILR | 0 -> 1: `if (eta == 1) revert NothingPending();` | killed-by-hl-r2: killed by M54_kills_disallowDropsTheQueuedAllow |
| 974 | VaultPolicy.sol:301 | RR | delete `if (eta == 0) revert NothingPending();` | killed-by-hl-r2: killed by M54_kills_disallowDropsTheQueuedAllow |
| 976 | VaultPolicy.sol:303 | ILR | 0 -> 1: `assetAllowEta[asset] = 1;` | equivalent: EQ: re-applying an allow is idempotent; disallowAsset clears the eta |
| 977 | VaultPolicy.sol:303 | SDL | delete `assetAllowEta[asset] = 0;` | equivalent: EQ: as 976 |
| 981 | VaultPolicy.sol:311 | ROR | > -> >=: `if (delay < MIN_TIMELOCK \|\| delay >= MAX_TIMELOCK) revert InvalidTimelock();` | killed-by-hl-r2: killed by M55_kills_timelockDelayRules |
| 983 | VaultPolicy.sol:311 | LOR | || -> &&: `if (delay < MIN_TIMELOCK && delay > MAX_TIMELOCK) revert InvalidTimelock();` | killed-by-hl-r2: killed by M55_kills_timelockDelayRules |
| 984 | VaultPolicy.sol:311 | CR | MIN_TIMELOCK -> 0: `if (delay < 0 \|\| delay > MAX_TIMELOCK) revert InvalidTimelock();` | killed-by-hl-r2: killed by M55_kills_timelockDelayRules |
| 987 | VaultPolicy.sol:311 | CR | MAX_TIMELOCK -> 2*MAX_TIMELOCK: `if (delay < MIN_TIMELOCK \|\| delay > (MAX_TIMELOCK * 2)) revert InvalidTimelock();` | killed-by-hl-r2: killed by M55_kills_timelockDelayRules |
| 988 | VaultPolicy.sol:311 | RR | delete `if (delay < MIN_TIMELOCK \|\| delay > MAX_TIMELOCK) revert InvalidTimelock();` | killed-by-hl-r2: killed by M55_kills_timelockDelayRules |
| 989 | VaultPolicy.sol:312 | ROR | >= -> >: `if (delay > timelockDelay) {` | killed-by-hl-r2: killed by M55_kills_timelockDelayRules |
| 991 | VaultPolicy.sol:313 | SDL | delete `timelockDelay = delay;` | killed-by-hl-r2: killed by M55_kills_timelockDelayRules |
| 992 | VaultPolicy.sol:314 | ILR | 0 -> 1: `pendingTimelockEta = 1;` | killed-by-hl-r2: killed by M55_kills_timelockDelayRules |
| 993 | VaultPolicy.sol:314 | SDL | delete `pendingTimelockEta = 0;` | killed-by-hl-r2: killed by M55_kills_timelockDelayRules |
| 998 | VaultPolicy.sol:324 | ILR | 0 -> 1: `if (pendingTimelockEta == 1) revert NothingPending();` | killed-by-hl-r2: killed by M55_kills_timelockDelayRules |
| 999 | VaultPolicy.sol:324 | RR | delete `if (pendingTimelockEta == 0) revert NothingPending();` | killed-by-hl-r2: killed by M55_kills_timelockDelayRules |
| 1000 | VaultPolicy.sol:325 | SDL | delete `_checkEta(pendingTimelockEta);` | killed-by-hl-r2: killed by M55_kills_timelockDelayRules |
| 1002 | VaultPolicy.sol:327 | ILR | 0 -> 1: `pendingTimelockEta = 1;` | equivalent: EQ: re-applying the same delay is idempotent; a raise clears the eta |
| 1003 | VaultPolicy.sol:327 | SDL | delete `pendingTimelockEta = 0;` | equivalent: EQ: as 1002 |
| 1007 | VaultPolicy.sol:336 | ROR | > -> >=: `if (block.timestamp >= eta + GRACE_PERIOD) revert Expired();` | killed-by-hl-r2: killed by M55_kills_timelockDelayRules |
| 1010 | VaultPolicy.sol:336 | CR | GRACE_PERIOD -> 0: `if (block.timestamp > eta + 0) revert Expired();` | killed-by-hl-r2: killed by M55_kills_timelockDelayRules |
| 1018 | VaultPolicy.sol:344 | ROR | >= -> >: `if (asset > HyperCore.SPOT_ASSET_OFFSET) revert SpotNotSupported();` | killed-by-hl-r2: killed by M56_kills_validateBounds |
| 1020 | VaultPolicy.sol:344 | RR | delete `if (asset >= HyperCore.SPOT_ASSET_OFFSET) revert SpotNotSupported();` | killed-by-hl-r2: killed by M56_kills_validateBounds |
| 1041 | VaultPolicy.sol:355 | ROR | < -> <=: `if (c.maxLeverageBps == 0 \|\| c.maxLeverageBps > 500_000 \|\| c.maxDailyLossBps == 0 \|\| c.max` | killed-by-hl-r2: killed by M56_kills_validateBounds |
| 1052 | VaultPolicy.sol:355 | LOR | || -> &&: `if (c.maxLeverageBps == 0 && c.maxLeverageBps > 500_000 \|\| c.maxDailyLossBps == 0 \|\| c.max` | killed-by-hl-r2: killed by M56_kills_validateBounds |
| 1053 | VaultPolicy.sol:355 | LOR | || -> &&: `if (c.maxLeverageBps == 0 \|\| c.maxLeverageBps > 500_000 && c.maxDailyLossBps == 0 \|\| c.max` | killed-by-hl-r2: killed by M56_kills_validateBounds |
| 1054 | VaultPolicy.sol:355 | LOR | || -> &&: `if (c.maxLeverageBps == 0 \|\| c.maxLeverageBps > 500_000 \|\| c.maxDailyLossBps == 0 && c.max` | killed-by-hl-r2: killed by M56_kills_validateBounds |
| 1055 | VaultPolicy.sol:355 | LOR | || -> &&: `if (c.maxLeverageBps == 0 \|\| c.maxLeverageBps > 500_000 \|\| c.maxDailyLossBps == 0 \|\| c.max` | killed-by-hl-r2: killed by M56_kills_validateBounds |
| 1056 | VaultPolicy.sol:355 | LOR | || -> &&: `if (c.maxLeverageBps == 0 \|\| c.maxLeverageBps > 500_000 \|\| c.maxDailyLossBps == 0 \|\| c.max` | killed-by-hl-r2: killed by M56_kills_validateBounds |
| 1057 | VaultPolicy.sol:355 | LOR | || -> &&: `if (c.maxLeverageBps == 0 \|\| c.maxLeverageBps > 500_000 \|\| c.maxDailyLossBps == 0 \|\| c.max` | killed-by-hl-r2: killed by M56_kills_validateBounds |
| 1060 | VaultPolicy.sol:355 | LOR | || -> &&: `if (c.maxLeverageBps == 0 \|\| c.maxLeverageBps > 500_000 \|\| c.maxDailyLossBps == 0 \|\| c.max` | killed-by-hl-r2: killed by M56_kills_validateBounds |
| 1061 | VaultPolicy.sol:355 | LOR | || -> &&: `if (c.maxLeverageBps == 0 \|\| c.maxLeverageBps > 500_000 \|\| c.maxDailyLossBps == 0 \|\| c.max` | killed-by-hl-r2: killed by M56_kills_validateBounds |
| 1064 | VaultPolicy.sol:355 | LOR | || -> &&: `if (c.maxLeverageBps == 0 \|\| c.maxLeverageBps > 500_000 \|\| c.maxDailyLossBps == 0 \|\| c.max` | killed-by-hl-r2: killed by M56_kills_validateBounds |
| 1066 | VaultPolicy.sol:355 | ILR | 0 -> 1: `if (c.maxLeverageBps == 1 \|\| c.maxLeverageBps > 500_000 \|\| c.maxDailyLossBps == 0 \|\| c.max` | killed-by-hl-r2: killed by M56_kills_validateBounds |
| 1067 | VaultPolicy.sol:355 | ILR | 0 -> 1: `if (c.maxLeverageBps == 0 \|\| c.maxLeverageBps > 500_000 \|\| c.maxDailyLossBps == 1 \|\| c.max` | killed-by-hl-r2: killed by M56_kills_validateBounds |
| 1068 | VaultPolicy.sol:355 | ILR | 0 -> 1: `if (c.maxLeverageBps == 0 \|\| c.maxLeverageBps > 500_000 \|\| c.maxDailyLossBps == 0 \|\| c.max` | killed-by-hl-r2: killed by M56_kills_validateBounds |
| 1069 | VaultPolicy.sol:355 | ILR | 0 -> 1: `if (c.maxLeverageBps == 0 \|\| c.maxLeverageBps > 500_000 \|\| c.maxDailyLossBps == 0 \|\| c.max` | killed-by-hl-r2: killed by M56_kills_validateBounds |
| 1070 | VaultPolicy.sol:355 | ILR | 0 -> 1: `if (c.maxLeverageBps == 0 \|\| c.maxLeverageBps > 500_000 \|\| c.maxDailyLossBps == 0 \|\| c.max` | killed-by-hl-r2: killed by M56_kills_validateBounds |
| 1071 | VaultPolicy.sol:355 | ILR | 1 -> 0: `if (c.maxLeverageBps == 0 \|\| c.maxLeverageBps > 500_000 \|\| c.maxDailyLossBps == 0 \|\| c.max` | killed-by-hl-r2: killed by M56_kills_validateBounds |
| 1072 | VaultPolicy.sol:355 | ILR | 0 -> 1: `if (c.maxLeverageBps == 0 \|\| c.maxLeverageBps > 500_000 \|\| c.maxDailyLossBps == 0 \|\| c.max` | killed-by-hl-r2: killed by M56_kills_validateBounds |
| 1099 | libraries/PxMath.sol:17 | ROR | < -> <=: `if (raw <= 100_000) return raw;` | equivalent: EQ: 100000 has 5 significant figures, returned unchanged either way |
| 1101 | libraries/PxMath.sol:17 | SDL | delete `if (raw < 100_000) return raw;` | equivalent: EQ: below 100000 the loop does not run and floored == raw |
| 1120 | libraries/PxMath.sol:42 | ILR | 0 -> 1: `if (rounded == 1) rounded = 1;` | killed-by-hl-r2: killed by M57_kills_zeroPriceFloor |
| 1121 | libraries/PxMath.sol:42 | ILR | 1 -> 0: `if (rounded == 0) rounded = 0;` | killed-by-hl-r2: killed by M57_kills_zeroPriceFloor |
| 1122 | libraries/PxMath.sol:42 | SDL | delete `if (rounded == 0) rounded = 1;` | killed-by-hl-r2: killed by M57_kills_zeroPriceFloor |
| 1134 | hypercore/HyperCore.sol:163 | SDL | delete `_send(ACTION_CANCEL_BY_OID, abi.encode(asset, oid));` | killed-by-hl-r2: killed by M40_kills_cancelOrderAction |
| 1135 | hypercore/HyperCore.sol:167 | SDL | delete `_send(ACTION_CANCEL_BY_CLOID, abi.encode(asset, cloid));` | equivalent: EQ-DEAD: HyperCore.cancelByCloid is never called by the vault (dead code in the library) |
| 1136 | hypercore/HyperCore.sol:172 | SDL | delete `_send(ACTION_USD_CLASS_TRANSFER, abi.encode(ntl, toPerp));` | killed-by-hl-r2: killed by M32_kills_bridgeToEvmLegs, M34_kills_moveUsdAction |
| 1137 | hypercore/HyperCore.sol:178 | ILR | 0 -> 1: `_send(ACTION_SEND_ASSET, abi.encode(destination, address(1), sourceDex, destinationDex, to` | killed-by-hl-r2: killed by M32_kills_bridgeToEvmLegs |
| 1138 | hypercore/HyperCore.sol:178 | SDL | delete `_send(ACTION_SEND_ASSET, abi.encode(destination, address(0), sourceDex, destinationDex, to` | killed-by-hl-r2: killed by M32_kills_bridgeToEvmLegs, M33_kills_bridgeToEvmNoZeroPerpLeg |
| 1144 | VaultGovernance.sol:58 | LOR | || -> &&: `if (p.manager == address(0) && p.feeRecipient == address(0) \|\| address(p.policy) == addres` | killed-by-hl-r2: killed by M58_kills_initializeChecks |
| 1145 | VaultGovernance.sol:58 | LOR | || -> &&: `if (p.manager == address(0) \|\| p.feeRecipient == address(0) && address(p.policy) == addres` | killed-by-hl-r2: killed by M58_kills_initializeChecks |
| 1146 | VaultGovernance.sol:58 | LOR | || -> &&: `if (p.manager == address(0) \|\| p.feeRecipient == address(0) \|\| address(p.policy) == addres` | killed-by-hl-r2: killed by M58_kills_initializeChecks |
| 1147 | VaultGovernance.sol:58 | ILR | 0 -> 1: `if (p.manager == address(1) \|\| p.feeRecipient == address(0) \|\| address(p.policy) == addres` | killed-by-hl-r2: killed by M58_kills_initializeChecks |
| 1148 | VaultGovernance.sol:58 | ILR | 0 -> 1: `if (p.manager == address(0) \|\| p.feeRecipient == address(1) \|\| address(p.policy) == addres` | killed-by-hl-r2: killed by M58_kills_initializeChecks |
| 1149 | VaultGovernance.sol:58 | ILR | 0 -> 1: `if (p.manager == address(0) \|\| p.feeRecipient == address(0) \|\| address(p.policy) == addres` | killed-by-hl-r2: killed by M58_kills_initializeChecks |
| 1150 | VaultGovernance.sol:58 | ILR | 0 -> 1: `if (p.manager == address(0) \|\| p.feeRecipient == address(0) \|\| address(p.policy) == addres` | killed-by-hl-r2: killed by M58_kills_initializeChecks |
| 1151 | VaultGovernance.sol:59 | RR | delete `revert E.ZeroAddress();` | killed-by-hl-r2: killed by M58_kills_initializeChecks |
| 1155 | VaultGovernance.sol:61 | ILR | 0 -> 1: `if (p.factory == address(1) && p.guardian == address(0)) revert E.ZeroAddress();` | killed-by-hl-r2: killed by M58_kills_initializeChecks |
| 1156 | VaultGovernance.sol:61 | ILR | 0 -> 1: `if (p.factory == address(0) && p.guardian == address(1)) revert E.ZeroAddress();` | killed-by-hl-r2: killed by M58_kills_initializeChecks |
| 1157 | VaultGovernance.sol:61 | RR | delete `if (p.factory == address(0) && p.guardian == address(0)) revert E.ZeroAddress();` | killed-by-hl-r2: killed by M58_kills_initializeChecks |
| 1159 | VaultGovernance.sol:62 | RR | delete `if (IERC20Metadata(address(p.asset)).decimals() != 6) revert E.UnsupportedAsset();` | killed-by-hl-r2: killed by M58_kills_initializeChecks |
| 1164 | VaultGovernance.sol:63 | LOR | || -> &&: `if (p.managementFeeBps > MAX_MANAGEMENT_FEE_BPS && p.performanceFeeBps > MAX_PERFORMANCE_F` | killed-by-hl-r2: killed by M58_kills_initializeChecks |
| 1166 | VaultGovernance.sol:63 | CR | MAX_MANAGEMENT_FEE_BPS -> 2*MAX_MANAGEMENT_FEE_BPS: `if (p.managementFeeBps > (MAX_MANAGEMENT_FEE_BPS * 2) \|\| p.performanceFeeBps > MAX_PERFORM` | killed-by-hl-r2: killed by M58_kills_initializeChecks |
| 1168 | VaultGovernance.sol:63 | CR | MAX_PERFORMANCE_FEE_BPS -> 2*MAX_PERFORMANCE_FEE_BPS: `if (p.managementFeeBps > MAX_MANAGEMENT_FEE_BPS \|\| p.performanceFeeBps > (MAX_PERFORMANCE_` | killed-by-hl-r2: killed by M58_kills_initializeChecks |
| 1169 | VaultGovernance.sol:63 | RR | delete `if (p.managementFeeBps > MAX_MANAGEMENT_FEE_BPS \|\| p.performanceFeeBps > MAX_PERFORMANCE_F` | killed-by-hl-r2: killed by M58_kills_initializeChecks |
| 1174 | VaultGovernance.sol:64 | LOR | || -> &&: `if (p.timelockDelay < MIN_TIMELOCK && p.timelockDelay > MAX_TIMELOCK) revert E.InvalidTime` | killed-by-hl-r2: killed by M58_kills_initializeChecks |
| 1175 | VaultGovernance.sol:64 | CR | MIN_TIMELOCK -> 0: `if (p.timelockDelay < 0 \|\| p.timelockDelay > MAX_TIMELOCK) revert E.InvalidTimelock();` | killed-by-hl-r2: killed by M58_kills_initializeChecks |
| 1178 | VaultGovernance.sol:64 | CR | MAX_TIMELOCK -> 2*MAX_TIMELOCK: `if (p.timelockDelay < MIN_TIMELOCK \|\| p.timelockDelay > (MAX_TIMELOCK * 2)) revert E.Inval` | killed-by-hl-r2: killed by M58_kills_initializeChecks |
| 1179 | VaultGovernance.sol:64 | RR | delete `if (p.timelockDelay < MIN_TIMELOCK \|\| p.timelockDelay > MAX_TIMELOCK) revert E.InvalidTime` | killed-by-hl-r2: killed by M58_kills_initializeChecks |
| 1182 | VaultGovernance.sol:65 | ROR | > -> >=: `if (p.protocolShareBps > MAX_PROTOCOL_SHARE_BPS \|\| p.baseShareBps >= MAX_PROTOCOL_SHARE_BP` | killed-by-hl-r2: killed by M58_kills_initializeChecks |
| 1184 | VaultGovernance.sol:65 | LOR | || -> &&: `if (p.protocolShareBps > MAX_PROTOCOL_SHARE_BPS && p.baseShareBps > MAX_PROTOCOL_SHARE_BPS` | killed-by-hl-r2: killed by M58_kills_initializeChecks |
| 1186 | VaultGovernance.sol:65 | CR | MAX_PROTOCOL_SHARE_BPS -> 2*MAX_PROTOCOL_SHARE_BPS: `if (p.protocolShareBps > (MAX_PROTOCOL_SHARE_BPS * 2) \|\| p.baseShareBps > MAX_PROTOCOL_SHA` | killed-by-hl-r2: killed by M58_kills_initializeChecks |
| 1188 | VaultGovernance.sol:65 | CR | MAX_PROTOCOL_SHARE_BPS -> 2*MAX_PROTOCOL_SHARE_BPS: `if (p.protocolShareBps > MAX_PROTOCOL_SHARE_BPS \|\| p.baseShareBps > (MAX_PROTOCOL_SHARE_BP` | killed-by-hl-r2: killed by M58_kills_initializeChecks |
| 1189 | VaultGovernance.sol:65 | RR | delete `if (p.protocolShareBps > MAX_PROTOCOL_SHARE_BPS \|\| p.baseShareBps > MAX_PROTOCOL_SHARE_BPS` | killed-by-hl-r2: killed by M58_kills_initializeChecks |
| 1204 | VaultGovernance.sol:82 | SDL | delete `$.highWaterMark = 10 ** 6;` | killed-by-hl-r2: killed by M59_kills_initializeStores |
| 1206 | VaultGovernance.sol:84 | SDL | delete `$.epochStartedAt = uint64(block.timestamp);` | killed-by-hl-r2: killed by M59_kills_initializeStores |
| 1207 | VaultGovernance.sol:85 | SDL | delete `$.lastFeeAccrual = uint64(block.timestamp);` | killed-by-hl-r2: killed by M59_kills_initializeStores |
| 1210 | VaultGovernance.sol:86 | SDL | delete `$.riskDay = block.timestamp / 1 days;` | killed-by-hl-r2: killed by M59_kills_initializeStores |
| 1213 | VaultGovernance.sol:90 | ILR | 0 -> 1: `if (p.seedUsdc > 1) VaultLogic.seedCore($, p.seedUsdc);` | killed-by-hl-r2: killed by M83_kills_initSeedAndGasOfOneWei |
| 1217 | VaultGovernance.sol:91 | ILR | 0 -> 1: `if (value > 1) VaultLogic.fundCoreGas($, value);` | killed-by-hl-r2: killed by M83_kills_initSeedAndGasOfOneWei |
| 1223 | VaultGovernance.sol:93 | ILR | 0 -> 1: `if (p.operator != address(1)) {` | equivalent: EQ-STATE: an operator of address(0) is stored as address(0) (event only) |
| 1237 | VaultGovernance.sol:137 | LOR | || -> &&: `if (!$.breached && $.breachReason != BreachReason.LEVERAGE) revert E.NotClearable();` | equivalent: EQ: a non-leverage breach is refused two lines later (breachReason != LEVERAGE, NotClearable) |
| 1239 | VaultGovernance.sol:137 | RR | delete `if (!$.breached \|\| $.breachReason != BreachReason.LEVERAGE) revert E.NotClearable();` | equivalent: EQ: as 1237 |
| 1240 | VaultGovernance.sol:138 | RR | delete `if ($.emergency) revert E.InEmergency();` | equivalent: EQ: in emergency breachReason is EMERGENCY, refused by the same later check (NotClearable instead of InEmergency) |
| 1241 | VaultGovernance.sol:139 | RR | delete `if ($.bridgePending()) revert E.BridgeInFlight();` | killed-by-hl-r2: killed by M60_kills_clearInsideABridgeWindow |
| 1249 | VaultGovernance.sol:144 | ROR | > -> >=: `if ($.breachReason != BreachReason.LEVERAGE \|\| lev >= maxLev \|\| daily > maxDaily \|\| dd > m` | killed-by-hl-r2: killed by M61_kills_leverageAtTheLimitClears |
| 1251 | VaultGovernance.sol:144 | ROR | > -> >=: `if ($.breachReason != BreachReason.LEVERAGE \|\| lev > maxLev \|\| daily >= maxDaily \|\| dd > m` | killed-by-hl-r2: killed by M77_kills_lossLimitsAtTheirValue |
| 1253 | VaultGovernance.sol:144 | ROR | > -> >=: `if ($.breachReason != BreachReason.LEVERAGE \|\| lev > maxLev \|\| daily > maxDaily \|\| dd >= m` | killed-by-hl-r2: killed by M77_kills_lossLimitsAtTheirValue |
| 1257 | VaultGovernance.sol:144 | LOR | || -> &&: `if ($.breachReason != BreachReason.LEVERAGE \|\| lev > maxLev \|\| daily > maxDaily && dd > ma` | equivalent: EQ: a daily loss or drawdown over its limit escalates the breach inside _check, refused by breachReason != LEVERAGE |
| 1263 | VaultGovernance.sol:153 | LOR | || -> &&: `if (!$.breached && $.breachReason != BreachReason.DRAWDOWN) revert E.NotClearable();` | equivalent: EQ: refused by breachReason != DRAWDOWN two lines later |
| 1265 | VaultGovernance.sol:153 | RR | delete `if (!$.breached \|\| $.breachReason != BreachReason.DRAWDOWN) revert E.NotClearable();` | equivalent: EQ: as 1263 |
| 1266 | VaultGovernance.sol:154 | RR | delete `if ($.emergency) revert E.InEmergency();` | equivalent: EQ: as 1240 (EMERGENCY reason) |
| 1273 | VaultGovernance.sol:156 | RR | delete `if ($.bridgePending()) revert E.BridgeInFlight();` | killed-by-hl-r2: killed by M60b_kills_resumeInsideABridgeWindow |
| 1275 | VaultGovernance.sol:159 | ROR | > -> >=: `if ($.breachReason != BreachReason.DRAWDOWN \|\| lev >= maxLev \|\| daily > maxDaily) revert E` | killed-by-hl-r2: killed by M61b_kills_leverageAtTheLimitResumes |
| 1277 | VaultGovernance.sol:159 | ROR | > -> >=: `if ($.breachReason != BreachReason.DRAWDOWN \|\| lev > maxLev \|\| daily >= maxDaily) revert E` | killed-by-hl-r2: killed by M78_kills_resumeAtTheDailyLimit |
| 1285 | VaultGovernance.sol:169 | SDL | delete `VaultLogic.syncBridge($);` | killed-by-hl-r2: killed by M62_kills_checkRiskDoesNotLatch |
| 1288 | VaultGovernance.sol:175 | ROR | < -> <=: `equity = visible <= $.equityAtBridge ? visible : $.equityAtBridge;` | equivalent: EQ: equal values |
| 1303 | VaultGovernance.sol:187 | ROR | > -> >=: `if (!inFlight && price >= $.peakSharePrice) $.peakSharePrice = price;` | equivalent: EQ: equal values |
| 1310 | VaultGovernance.sol:191 | ILR | 0 -> 1: `if (m.ntlPos > 1) {` | boundary/near-equivalent: B1W: a notional of exactly 1 wei reads as no leverage |
| 1311 | VaultGovernance.sol:192 | ROR | > -> >=: `leverageBps = m.accountValue >= 0 ? uint256(m.ntlPos).mulDiv(BPS, uint256(uint64(m.account` | killed-by-hl-r2: killed by M63_kills_zeroEquityWithPositions |
| 1313 | VaultGovernance.sol:192 | ILR | 0 -> 1: `leverageBps = m.accountValue > 1 ? uint256(m.ntlPos).mulDiv(BPS, uint256(uint64(m.accountV` | boundary/near-equivalent: B1W: an account value of exactly 1 wei reads as unbounded leverage |
| 1318 | VaultGovernance.sol:195 | ROR | >= -> >: `if (supply > 0 && equity > MIN_RISK_NAV) {` | killed-by-hl-r2: killed by M79_kills_minRiskNavEdge |
| 1321 | VaultGovernance.sol:195 | ILR | 0 -> 1: `if (supply > 1 && equity >= MIN_RISK_NAV) {` | boundary/near-equivalent: B1U: a supply of exactly 1 share unit reads no loss metrics |
| 1323 | VaultGovernance.sol:195 | CR | MIN_RISK_NAV -> 2*MIN_RISK_NAV: `if (supply > 0 && equity >= (MIN_RISK_NAV * 2)) {` | killed-by-hl-r2: killed by M64_kills_minRiskNav |
| 1324 | VaultGovernance.sol:197 | ROR | > -> >=: `if (start >= price) dailyLossBps = (start - price).mulDiv(BPS, start);` | equivalent: EQ: start == price gives a zero loss |
| 1329 | VaultGovernance.sol:198 | ROR | > -> >=: `if ($.peakSharePrice >= price) drawdownBps = ($.peakSharePrice - price).mulDiv(BPS, $.peak` | equivalent: EQ: peak == price gives a zero drawdown |
| 1335 | VaultGovernance.sol:205 | ROR | > -> >=: `BreachReason r = drawdownBps >= maxDd ? BreachReason.DRAWDOWN : dailyLossBps > maxDaily ? ` | killed-by-hl-r2: killed by M77_kills_lossLimitsAtTheirValue |
| 1361 | VaultGovernance.sol:231 | ROR | > -> >=: `_stop($, $.breachReason >= BreachReason.GUARDIAN ? $.breachReason : BreachReason.GUARDIAN,` | equivalent: EQ: breachReason == GUARDIAN maps to GUARDIAN either way |
| 1378 | VaultGovernance.sol:246 | ILR | 0 -> 1: `if (!privileged && !($.epochOverdue() && $.pendingRedeemShares > 1)) revert E.NotOverdue()` | killed-by-hl-r2: killed by M81_kills_oneUnitBoundaries |
| 1389 | VaultGovernance.sol:261 | RR | delete `if ($.emergency) revert E.InEmergency();` | killed-by-hl-r2: killed by M65_kills_clearBreachInEmergency |
| 1391 | VaultGovernance.sol:263 | AOR | / -> *: `$.riskDay = block.timestamp * 1 days;` | killed-by-hl-r2: killed by M66_kills_clearRestartsTheDay |
| 1393 | VaultGovernance.sol:263 | SDL | delete `$.riskDay = block.timestamp / 1 days;` | killed-by-hl-r2: killed by M66_kills_clearRestartsTheDay |
| 1399 | VaultGovernance.sol:273 | ILR | 0 -> 1: `if ($.pendingRedeemShares > 1) revert E.RedemptionsPending();` | killed-by-hl-r2: killed by M81_kills_oneUnitBoundaries |
| 1401 | VaultGovernance.sol:275 | ROR | > -> >=: `if (epoch >= 0) {` | killed-by-hl-r2: killed by M71_kills_exitEmergencyAtEpochZero |
| 1403 | VaultGovernance.sol:275 | ILR | 0 -> 1: `if (epoch > 1) {` | equivalent: EQ-UNREACH: epochs[0] is the first settle, which cannot be a partial fill (no share existed to redeem before it) |
| 1415 | VaultGovernance.sol:289 | SDL | delete `$.depositsPaused = paused;` | killed-by-hl-r2: killed by M67_kills_depositPauseStored |
| 1459 | VaultGovernance.sol:334 | RR | delete `if (data.length < 4) revert E.NotQueued();` | equivalent: EQ: calldata shorter than 4 bytes reverts on the data[:4] slice (another error) |
| 1467 | VaultGovernance.sol:337 | LOR | || -> &&: `if (sel == SEL_SET_MANAGER \|\| sel == SEL_SET_FEE_RECIPIENT && sel == SEL_SET_TIMELOCK \|\| s` | killed-by-hl-r2: killed by M68_kills_queueTableGraceAndReplay |
| 1482 | VaultGovernance.sol:354 | ROR | > -> >=: `if (block.timestamp >= eta + GRACE_PERIOD) revert E.Expired();` | killed-by-hl-r2: killed by M68_kills_queueTableGraceAndReplay |
| 1489 | VaultGovernance.sol:356 | ROR | <= -> <: `if (bytes4(data[:4]) == SEL_CLEAR_BREACH && $.queuedAt[id] < $.breachedAt) revert E.NotRea` | killed-by-hl-r2: killed by M69_kills_clearQueuedInTheBreachBlock |
| 1493 | VaultGovernance.sol:357 | SDL | delete `delete $.queuedEta[id];` | killed-by-hl-r2: killed by M68_kills_queueTableGraceAndReplay |
| 1494 | VaultGovernance.sol:358 | SDL | delete `delete $.queuedAt[id];` | equivalent: EQ: queuedAt is only read together with queuedEta, which execute deletes; a new queue overwrites both |
| 1502 | VaultGovernance.sol:367 | ILR | 0 -> 1: `if ($.queuedEta[id] == 1) revert E.NotQueued();` | equivalent: EQ-STATE: cancelling an unqueued id deletes nothing (event only) |
| 1503 | VaultGovernance.sol:367 | RR | delete `if ($.queuedEta[id] == 0) revert E.NotQueued();` | equivalent: EQ-STATE: as 1502 |
| 1504 | VaultGovernance.sol:368 | SDL | delete `delete $.queuedEta[id];` | killed-by-hl-r2: killed by M70_kills_cancelIsFinal |
| 1505 | VaultGovernance.sol:369 | SDL | delete `delete $.queuedAt[id];` | equivalent: EQ: as 1494 |
| 1507 | VaultGovernance.sol:374 | ILR | 0 -> 1: `if (newManager == address(1)) revert E.ZeroAddress();` | killed-by-hl-r2: killed by M72_kills_timelockedSetterBounds |
| 1508 | VaultGovernance.sol:374 | RR | delete `if (newManager == address(0)) revert E.ZeroAddress();` | killed-by-hl-r2: killed by M72_kills_timelockedSetterBounds |
| 1512 | VaultGovernance.sol:386 | ROR | == -> !=: `if (recipient != address(0)) revert E.ZeroAddress();` | killed-by-hl-r2: killed by M68_kills_queueTableGraceAndReplay, M72_kills_timelockedSetterBounds |
| 1513 | VaultGovernance.sol:386 | ILR | 0 -> 1: `if (recipient == address(1)) revert E.ZeroAddress();` | killed-by-hl-r2: killed by M72_kills_timelockedSetterBounds |
| 1514 | VaultGovernance.sol:386 | RR | delete `if (recipient == address(0)) revert E.ZeroAddress();` | killed-by-hl-r2: killed by M72_kills_timelockedSetterBounds |
| 1515 | VaultGovernance.sol:387 | SDL | delete `$.feeRecipient = recipient;` | killed-by-hl-r2: killed by M68_kills_queueTableGraceAndReplay, M72_kills_timelockedSetterBounds |
| 1516 | VaultGovernance.sol:392 | ROR | < -> <=: `if (delay <= MIN_TIMELOCK \|\| delay > MAX_TIMELOCK) revert E.InvalidTimelock();` | killed-by-hl-r2: killed by M72_kills_timelockedSetterBounds |
| 1517 | VaultGovernance.sol:392 | ROR | < -> >=: `if (delay >= MIN_TIMELOCK \|\| delay > MAX_TIMELOCK) revert E.InvalidTimelock();` | killed-by-hl-r2: killed by M68_kills_queueTableGraceAndReplay, M72_kills_timelockedSetterBounds |
| 1518 | VaultGovernance.sol:392 | ROR | > -> >=: `if (delay < MIN_TIMELOCK \|\| delay >= MAX_TIMELOCK) revert E.InvalidTimelock();` | killed-by-hl-r2: killed by M72_kills_timelockedSetterBounds |
| 1519 | VaultGovernance.sol:392 | ROR | > -> <=: `if (delay < MIN_TIMELOCK \|\| delay <= MAX_TIMELOCK) revert E.InvalidTimelock();` | killed-by-hl-r2: killed by M68_kills_queueTableGraceAndReplay, M72_kills_timelockedSetterBounds |
| 1520 | VaultGovernance.sol:392 | LOR | || -> &&: `if (delay < MIN_TIMELOCK && delay > MAX_TIMELOCK) revert E.InvalidTimelock();` | killed-by-hl-r2: killed by M72_kills_timelockedSetterBounds |
| 1521 | VaultGovernance.sol:392 | CR | MIN_TIMELOCK -> 0: `if (delay < 0 \|\| delay > MAX_TIMELOCK) revert E.InvalidTimelock();` | killed-by-hl-r2: killed by M72_kills_timelockedSetterBounds |
| 1522 | VaultGovernance.sol:392 | CR | MIN_TIMELOCK -> 2*MIN_TIMELOCK: `if (delay < (MIN_TIMELOCK * 2) \|\| delay > MAX_TIMELOCK) revert E.InvalidTimelock();` | killed-by-hl-r2: killed by M72_kills_timelockedSetterBounds |
| 1523 | VaultGovernance.sol:392 | CR | MAX_TIMELOCK -> 0: `if (delay < MIN_TIMELOCK \|\| delay > 0) revert E.InvalidTimelock();` | killed-by-hl-r2: killed by M68_kills_queueTableGraceAndReplay, M72_kills_timelockedSetterBounds |
| 1524 | VaultGovernance.sol:392 | CR | MAX_TIMELOCK -> 2*MAX_TIMELOCK: `if (delay < MIN_TIMELOCK \|\| delay > (MAX_TIMELOCK * 2)) revert E.InvalidTimelock();` | killed-by-hl-r2: killed by M72_kills_timelockedSetterBounds |
| 1525 | VaultGovernance.sol:392 | RR | delete `if (delay < MIN_TIMELOCK \|\| delay > MAX_TIMELOCK) revert E.InvalidTimelock();` | killed-by-hl-r2: killed by M72_kills_timelockedSetterBounds |
| 1526 | VaultGovernance.sol:393 | SDL | delete `$.timelockDelay = delay;` | killed-by-hl-r2: killed by M68_kills_queueTableGraceAndReplay, M72_kills_timelockedSetterBounds |
| 1527 | VaultGovernance.sol:402 | ROR | > -> >=: `if (mgmtBps >= MAX_MANAGEMENT_FEE_BPS \|\| perfBps > MAX_PERFORMANCE_FEE_BPS) revert E.Inval` | killed-by-hl-r2: killed by M72_kills_timelockedSetterBounds |
| 1531 | VaultGovernance.sol:402 | LOR | || -> &&: `if (mgmtBps > MAX_MANAGEMENT_FEE_BPS && perfBps > MAX_PERFORMANCE_FEE_BPS) revert E.Invali` | killed-by-hl-r2: killed by M72_kills_timelockedSetterBounds |
| 1533 | VaultGovernance.sol:402 | CR | MAX_MANAGEMENT_FEE_BPS -> 2*MAX_MANAGEMENT_FEE_BPS: `if (mgmtBps > (MAX_MANAGEMENT_FEE_BPS * 2) \|\| perfBps > MAX_PERFORMANCE_FEE_BPS) revert E.` | killed-by-hl-r2: killed by M72_kills_timelockedSetterBounds |
| 1535 | VaultGovernance.sol:402 | CR | MAX_PERFORMANCE_FEE_BPS -> 2*MAX_PERFORMANCE_FEE_BPS: `if (mgmtBps > MAX_MANAGEMENT_FEE_BPS \|\| perfBps > (MAX_PERFORMANCE_FEE_BPS * 2)) revert E.` | killed-by-hl-r2: killed by M72_kills_timelockedSetterBounds |
| 1536 | VaultGovernance.sol:402 | RR | delete `if (mgmtBps > MAX_MANAGEMENT_FEE_BPS \|\| perfBps > MAX_PERFORMANCE_FEE_BPS) revert E.Invali` | killed-by-hl-r2: killed by M72_kills_timelockedSetterBounds |
| 1565 | HyperVault.sol:339 | ROR | == -> !=: `if (address(token) != address($.asset) \|\| address(token) == address(this)) revert Unsuppor` | killed-by-hl-r2: killed by M07_kills_rescueTokenGuard |
| 1566 | HyperVault.sol:339 | ROR | == -> !=: `if (address(token) == address($.asset) \|\| address(token) != address(this)) revert Unsuppor` | killed-by-hl-r2: killed by M07_kills_rescueTokenGuard |
| 1567 | HyperVault.sol:339 | LOR | || -> &&: `if (address(token) == address($.asset) && address(token) == address(this)) revert Unsuppor` | killed-by-hl-r2: killed by M07_kills_rescueTokenGuard |
| 1568 | HyperVault.sol:339 | RR | delete `if (address(token) == address($.asset) \|\| address(token) == address(this)) revert Unsuppor` | killed-by-hl-r2: killed by M07_kills_rescueTokenGuard |
| 1569 | HyperVault.sol:340 | SDL | delete `token.safeTransfer(to, token.balanceOf(address(this)));` | killed-by-hl-r2: killed by M07_kills_rescueTokenGuard |
| 1574 | HyperVaultFactory.sol:229 | RR | delete `if (guardian == sentinel) revert RolesCollide();` | equivalent: EQ-UNREACH: the factory never holds guardian == sentinel (the constructor and both setters run _checkRoles) |
| 1593 | HyperVaultFactory.sol:237 | RR | delete `if (agentOfVault[predicted] != address(0)) revert VaultAlreadyHasAgent(predicted, agentOfV` | killed-by-hl-r2: killed by M08_kills_createBindsASecondAgentToAPreB |
| 1594 | HyperVaultFactory.sol:238 | ROR | > -> >=: `if (block.timestamp >= p.agentDeadline) revert BadAgentSignature();` | killed-by-hl-r2: killed by M73_kills_agentDeadlineEdge |
| 1602 | HyperVaultFactory.sol:240 | ILR | 0 -> 1: `if (signer == address(1) \|\| (signer != agentRegistrar && signer != owner())) revert BadAge` | equivalent: EQ-UNREACH: OpenZeppelin ECDSA.recover reverts on an invalid signature and never returns address(0) or address(1) for a valid one in practice |
| 1613 | HyperVaultFactory.sol:247 | RR | delete `if (!isAssetCurated[p.assets[i]]) revert AssetNotCurated(p.assets[i]);` | equivalent: EQ: VaultPolicy.initialize checks every asset against the same factory's curation (_checkCurated), reverting AssetNotCurated as well |
| 1615 | HyperVaultFactory.sol:250 | ILR | 0 -> 1: `if (permit.deadline != 1) {` | equivalent: EQ: a permit with deadline 0 or 1 is expired and swallowed by the try/catch; transferFrom is the real check |
| 1623 | HyperVaultFactory.sol:305 | LOR | || -> &&: `if (agent == address(0) && vault == address(0)) revert ZeroAddress();` | killed-by-hl-r2: killed by M74_kills_factoryAdminGuards |
| 1624 | HyperVaultFactory.sol:305 | ILR | 0 -> 1: `if (agent == address(1) \|\| vault == address(0)) revert ZeroAddress();` | killed-by-hl-r2: killed by M74_kills_factoryAdminGuards |
| 1625 | HyperVaultFactory.sol:305 | ILR | 0 -> 1: `if (agent == address(0) \|\| vault == address(1)) revert ZeroAddress();` | killed-by-hl-r2: killed by M74_kills_factoryAdminGuards |
| 1626 | HyperVaultFactory.sol:305 | RR | delete `if (agent == address(0) \|\| vault == address(0)) revert ZeroAddress();` | killed-by-hl-r2: killed by M74_kills_factoryAdminGuards |
| 1651 | HyperVaultFactory.sol:320 | ILR | 0 -> 1: `if (vault == address(1)) return;` | equivalent: EQ-STATE: unregistering an unbound agent deletes nothing (event only) |
| 1652 | HyperVaultFactory.sol:320 | SDL | delete `if (vault == address(0)) return;` | equivalent: EQ-STATE: as 1651 |
| 1662 | HyperVaultFactory.sol:334 | ILR | 0 -> 1: `if (recipient == address(1)) revert ZeroAddress();` | killed-by-hl-r2: killed by M74_kills_factoryAdminGuards |
| 1663 | HyperVaultFactory.sol:334 | RR | delete `if (recipient == address(0)) revert ZeroAddress();` | killed-by-hl-r2: killed by M74_kills_factoryAdminGuards |
| 1664 | HyperVaultFactory.sol:340 | ROR | > -> >=: `if (baseShareBps_ >= MAX_PROTOCOL_SHARE_BPS \|\| hostedShareBps_ > MAX_PROTOCOL_SHARE_BPS) r` | killed-by-hl-r2: killed by M74_kills_factoryAdminGuards |
| 1670 | HyperVaultFactory.sol:340 | CR | MAX_PROTOCOL_SHARE_BPS -> 2*MAX_PROTOCOL_SHARE_BPS: `if (baseShareBps_ > (MAX_PROTOCOL_SHARE_BPS * 2) \|\| hostedShareBps_ > MAX_PROTOCOL_SHARE_B` | killed-by-hl-r2: killed by M74_kills_factoryAdminGuards |
| 1678 | HyperVaultFactory.sol:375 | ILR | 0 -> 1: `if (guardian_ == address(1)) revert ZeroAddress();` | killed-by-hl-r2: killed by M74_kills_factoryAdminGuards |
| 1679 | HyperVaultFactory.sol:375 | RR | delete `if (guardian_ == address(0)) revert ZeroAddress();` | killed-by-hl-r2: killed by M74_kills_factoryAdminGuards |
| 1680 | HyperVaultFactory.sol:376 | SDL | delete `_checkRoles(owner(), guardian_, sentinel, agentRegistrar);` | equivalent: EQ: with no pending owner, the second _checkRoles(pendingOwner = 0, ...) applies every rule that involves the guardian (guardian != sentinel, registrar != guardian) |
| 1681 | HyperVaultFactory.sol:377 | SDL | delete `_checkRoles(pendingOwner(), guardian_, sentinel, agentRegistrar);` | equivalent: EQ: the pending-owner rules not involving the guardian were enforced when the pending owner was set (transferOwnership runs _checkRoles) |
| 1684 | HyperVaultFactory.sol:384 | ILR | 0 -> 1: `if (sentinel_ == address(1)) revert ZeroAddress();` | killed-by-hl-r2: killed by M74_kills_factoryAdminGuards |
| 1685 | HyperVaultFactory.sol:384 | RR | delete `if (sentinel_ == address(0)) revert ZeroAddress();` | killed-by-hl-r2: killed by M74_kills_factoryAdminGuards |
| 1686 | HyperVaultFactory.sol:385 | SDL | delete `_checkRoles(owner(), guardian, sentinel_, agentRegistrar);` | killed-by-hl-r2: killed by M74_kills_factoryAdminGuards |
| 1689 | HyperVaultFactory.sol:401 | SDL | delete `_checkRoles(newOwner, guardian, sentinel, agentRegistrar);` | killed-by-hl-r2: killed by M09_kills_ownershipToAHotRole |
| 1692 | HyperVaultFactory.sol:439 | ILR | 0 -> 1: `if (owner_ == address(1)) {` | equivalent: EQ: owner_ == 0 takes the owner-less branch only for a zero pending owner; with the mutant it takes the full branch, whose extra rules are false for owner_ == 0 |
| 1694 | HyperVaultFactory.sol:440 | RR | delete `if (guardian_ == sentinel_) revert RolesCollide();` | equivalent: EQ: setters run _checkRoles(owner(), ...) first, which enforces guardian != sentinel |
| 1695 | HyperVaultFactory.sol:441 | ROR | != -> ==: `if (registrar_ == address(0) && (registrar_ == guardian_ \|\| registrar_ == sentinel_)) reve` | equivalent: EQ: as 1694 (registrar rules enforced by the owner check) |
| 1699 | HyperVaultFactory.sol:441 | LOR | || -> &&: `if (registrar_ != address(0) && (registrar_ == guardian_ && registrar_ == sentinel_)) reve` | equivalent: EQ: as 1695 |
| 1700 | HyperVaultFactory.sol:441 | ILR | 0 -> 1: `if (registrar_ != address(1) && (registrar_ == guardian_ \|\| registrar_ == sentinel_)) reve` | equivalent: EQ: as 1695 |
| 1701 | HyperVaultFactory.sol:441 | RR | delete `if (registrar_ != address(0) && (registrar_ == guardian_ \|\| registrar_ == sentinel_)) reve` | equivalent: EQ: as 1695 |
| 1712 | HyperVaultFactory.sol:445 | LOR | || -> &&: `if (registrar_ != address(0) && (registrar_ == owner_ \|\| registrar_ == guardian_ && regist` | killed-by-hl-r2: killed by M76_kills_registrarRuleWithAPendingOwner |
| 1713 | HyperVaultFactory.sol:445 | ILR | 0 -> 1: `if (registrar_ != address(1) && (registrar_ == owner_ \|\| registrar_ == guardian_ \|\| regist` | equivalent: EQ: a zero registrar collides with no role in the full branch either (owner, guardian and sentinel are nonzero) |
| 1720 | hypercore/HyperCore.sol:163 | ENC | cancel action id 10 -> 11: `_send(ACTION_CANCEL_BY_CLOID, abi.encode(asset, oid));` | killed-by-hl-r2: killed by M40_kills_cancelOrderAction |
| 1721 | hypercore/HyperCore.sol:163 | ENC | cancel: swap asset and oid: `_send(ACTION_CANCEL_BY_OID, abi.encode(oid, asset));` | killed-by-hl-r2: killed by M40_kills_cancelOrderAction |
| 1722 | hypercore/HyperCore.sol:172 | ENC | usdClassTransfer: direction flipped: `_send(ACTION_USD_CLASS_TRANSFER, abi.encode(ntl, !toPerp));` | killed-by-hl-r2: killed by M32_kills_bridgeToEvmLegs, M34_kills_moveUsdAction |
| 1723 | hypercore/HyperCore.sol:172 | ENC | usdClassTransfer action id 7 -> 6: `_send(ACTION_SPOT_SEND, abi.encode(ntl, toPerp));` | killed-by-hl-r2: killed by M32_kills_bridgeToEvmLegs, M34_kills_moveUsdAction |
| 1724 | hypercore/HyperCore.sol:178 | ENC | sendAsset action id 13 -> 6: `_send(ACTION_SPOT_SEND, abi.encode(destination, address(0), sourceDex, destinationDex, tok` | killed-by-hl-r2: killed by M32_kills_bridgeToEvmLegs, M33_kills_bridgeToEvmNoZeroPerpLeg |
| 1725 | hypercore/HyperCore.sol:178 | ENC | sendAsset: subAccount = destination: `_send(ACTION_SEND_ASSET, abi.encode(destination, destination, sourceDex, destinationDex, t` | killed-by-hl-r2: killed by M32_kills_bridgeToEvmLegs |
| 1726 | hypercore/HyperCore.sol:178 | ENC | sendAsset: amount scale /100: `_send(ACTION_SEND_ASSET, abi.encode(destination, address(0), sourceDex, destinationDex, to` | killed-by-hl-r2: killed by M32_kills_bridgeToEvmLegs |
| 1727 | hypercore/HyperCore.sol:178 | ENC | sendAsset: swap token and amount: `_send(ACTION_SEND_ASSET, abi.encode(destination, address(0), sourceDex, destinationDex, am` | killed-by-hl-r2: killed by M32_kills_bridgeToEvmLegs |
| 1736 | VaultMath.sol:164 | ENC | coreSpotUsd scale dropped: `return uint256(HyperCore.spotBalance(address(this), HyperCore.USDC_TOKEN).total) / 1;` | killed-by-hl-r2: killed by M49_kills_landingTolerance |
| 1738 | VaultLogic.sol:447 | ENC | bridgeToEvm destination = self: `HyperCore.sendAsset(address(this), HyperCore.SPOT_DEX, HyperCore.SPOT_DEX, HyperCore.USDC_` | killed-by-hl-r2: killed by M32_kills_bridgeToEvmLegs |
| 1739 | VaultLogic.sol:447 | ENC | bridgeToEvm source dex = perp: `HyperCore.sendAsset(HyperCore.USDC_SYSTEM_ADDRESS, HyperCore.DEFAULT_PERP_DEX, HyperCore.S` | killed-by-hl-r2: killed by M32_kills_bridgeToEvmLegs |
| 1741 | VaultLogic.sol:488 | ENC | unlimited approval to the deposit wallet: `$.asset.approve(address($.coreDepositWallet), type(uint256).max);` | killed-by-hl-r2: killed by M75_kills_exactApprovalAndReduceOnlyFlag |
| 1742 | VaultLogic.sol:626 | ENC | burn address constant per vault: `address burn = address(uint160(uint256(keccak256(abi.encodePacked(address(this), uint256(0` | equivalent: EQ-SEC: the revocation address is a hash nobody holds the key to either way; a constant one per vault still overwrites the agent slot (only the address differs between revocations) |
| 1748 | VaultLogic.sol:546 | ENC | placeOrder drops reduceOnly: `HyperCore.limitOrder(asset_, isBuy, limitPx, sz, false, tif, cloid);` | killed-by-hl-r2: killed by M75_kills_exactApprovalAndReduceOnlyFlag |
