# hl-r2: Halmos (symbolic) properties of the fund math and single vault operations

**Internal, AI-assisted review. Not an independent audit.** Halmos 0.3.3 (pip, yices 2 default solver), Windows.
Tests: `contracts/test/audit/hl-r2/halmos/` (`check_` prefix; `forge test` does not run them). Logs:
`C:\hlr2\results\halmos\` (scratch, summarised here).

## Setup and the limits met

- Halmos runs in a scratch project (`C:\hlr2\hal`: `contracts/src` non-gains, the mocks, the halmos tests) with
  via-IR, optimizer off + stack allocation, `ast = true`.
- **Unsupported, worked around:** (1) forge's `dynamic_test_linking` (default on in forge 1.8) compiles `new X()` into
  `vm.deployCode`, which Halmos does not support -> `dynamic_test_linking = false`. (2) HyperVault calls the external
  libraries VaultLogic / VaultGovernance; Halmos cannot link library placeholders (`contract hexcode contains library
  placeholder`, then `non-hexadecimal number found in fromhex()` in setUp) -> the scratch project links them at fixed
  addresses (`libraries = [...:0x...A1001, ...:0x...A1002]`) and `HalmosVault.setUp` deploys each library from its
  creation code and `vm.etch`es it there. (3) Inline assembly must be `memory-safe` or via-IR stack allocation fails
  (`StackTooDeep` in check_V2). (4) Halmos' default assertion timeout is 60 s; runs pass
  `--solver-timeout-assertion <cap - 60>s`.
- **Not handled by the solver within the cap:** non-linear bit-vector arithmetic (OpenZeppelin `mulDiv` on 128 / 64
  bit symbolic inputs) and the PxMath rounding loop with symbolic division. Reductions tried, in order: 64-bit inputs
  (`*r`), 32-bit inputs (`*s`), one digit count at a time (`H7d*`), bitwuzla instead of yices.
- **Interruption:** pass C (lock taken 10:45 local) hung after yices ran out of memory on `check_V1` at 10:55; the
  machine powered off and rebooted at 14:51 local (lead released the stale lock). About 4.1 h of lock time lost,
  ~10 min useful. Pass C was restarted with `--solver-max-memory 4096 --solver-threads 2` and a watchdog that kills
  halmos and every solver at the cap.

## Results

| Property | What it states | Inputs | Result | Time / cap |
|---|---|---|---|---|
| P1 `check_P1_ratchetBounded` | checkRisk ratchet: move <= maxNavMoveBps of prev, none inside the interval, = NAV inside the band | prev, nav uint128; bps, at, now symbolic | **PROVED** (17 paths) | 5 s |
| P2 `check_P2_settleBound` | settle bound: returns only with a fresh checkpoint and NAV in band; never without a checkpoint (N-12) | same | **PROVED** (16 paths) | 0.3 s |
| P3 `check_P3_honestMoveSettles` | an honest in-band move always settles (liveness) | same | **PROVED** (10 paths) | 0.3 s |
| V3 `check_V3_cancelDepositConserves` | cancelDepositRequest: USDC out == request, queue -dep, idle and supply unchanged | dep uint128 | **PROVED** | 1 s |
| V4 `check_V4_cancelRedeemConserves` | cancelRedeemRequest: shares back in full, escrow and queue -red, no USDC moves | red | **PROVED** | 1 s |
| V5 `check_V5_requestsConserve` | requestDeposit / requestRedeem: USDC in == request, queue +dep, idle unchanged; shares into escrow, supply unchanged | dep, red | **PROVED** | 1 s |
| X1 (control) | V5's paths are reachable (assert(false)-style) | dep, red | FAIL as expected (counterexample dep = red = 2^49): V5 is not vacuous | 1 s |
| V1 `check_V1_settleNormalConserves` | normal settle with symbolic NAV, deposit, redemption: USDC unchanged, reserve += payout, idle' = idle + dep - paid, minted == claimable, payout == claim, price not lowered | av int64, spot uint64, dep, red | **UNSUPPORTED in practice**: yices out of memory (10:55, before the power-off); not re-run (same path as V2) | - |
| V2 `check_V2_settleEmergencyConserves` | exit-only settle: deposits refunded, payout <= idle and <= value at min(NAV, checkpoint), burn never above the payout (< 1 unit), unpaid shares returned | same | **STOPPED** at 17 min: two yices processes at 13.8 GB each (`--solver-max-memory` is not enforced on Windows); stopped to protect the machine | 17 min / 40 min |
| X2 (control for V1) | settle reachable | | not run (as V1) | - |
| H1 / H1r / H1s deposit leg never dilutes | (nav+d+1)(s+1e6) >= (nav+1)(s+sh+1e6) | 128 / 64 / 32 bit | TIMEOUT (first 128-bit attempt stopped at 14 min, 7 GB); H1s with bitwuzla TIMEOUT at 15 min | - |
| H2 / H2r / H2s redeem leg never dilutes | | | not run after H1 / H5 / H6 timed out at every width (same mulDiv core); not proved | - |
| H3 / H3r / H3s deposit then redeem returns <= deposit | | | not run (as H2); not proved | - |
| H4 / H4r / H4s partial-fill burn bounds | | | not run (as H2); not proved. The same claim is checked numerically by the kill test `test_HLR2_M21_kills_partialFillOverBurn` and by `testFuzz_VERIFY2_B1` | - |
| H5r / H5s redemption claims <= reserve, returned <= unburned | | 64 / 32 bit | H5r: solver out of memory; H5s: TIMEOUT 15 min | - |
| H6r / H6s deposit claims <= minted | | 64 / 32 bit | TIMEOUT (H6r 19 min yices; H6s 15 min yices and 15 min bitwuzla) | - |
| H7 `toSigFigs5` (all uint64) | <= 5 significant figures, on the right side of raw, within one unit | uint64 | TIMEOUT 20 min | 20 min |
| H7d6 (6-digit raw) | same, closed-form unit | raw in [1e5, 1e6) | **PROVED** with yices (225 paths, 63 s) and bitwuzla (84 s), loop bound 20 (one iteration needed) | 1-2 min |
| H7d12 / H7d19 | same for 12 / 19 digits | | TIMEOUT 15 min | |
| H7d9 | 9 digits | | build failed in that slot (the memory-safe fix came after); not re-run | |
| H8 `boundedLimitPx1e8` within slippage | buy <= mark(1+s), sell >= mark(1-s) | uint64 mark, szDecimals, slip | **COUNTEREXAMPLE** (sells, 3 found, validated concretely): HLR2-HAL01 | 9 min |
| H8d (6-7 digit marks, szDecimals 5) | same + the price crosses the mark | | TIMEOUT 20 min with the same sell counterexamples printed (0x4e1e00 / 0x3b9 bps, ...) | 20 min |
| H9 crosses the mark | buy >= mark, sell <= mark (an IOC can fill) | | TIMEOUT (60 s default solver timeout in pass A, then not re-run) | |


## What the proved properties mean

- P1-P3 (VaultPolicy.nextCheckpoint, symbolic maxNavMoveBps in [500, 10000], NAVs up to 2^128, symbolic time): the
  checkpoint ratchet never moves by more than maxNavMoveBps of the previous value and never inside
  CHECKPOINT_INTERVAL, and equals the live NAV inside the band; a settle returns only for a checkpoint younger than a
  day and a NAV inside the band, never without a checkpoint (N-12), and always for an honest move inside the band.
  This is the C-01 / N-03 / N-12 rule proved for all inputs, not sampled.
- V3-V5 (single vault operations on the real HyperVault + linked libraries with mocked precompiles, symbolic
  amounts): requestDeposit / requestRedeem / cancelDepositRequest / cancelRedeemRequest move exactly the requested
  USDC or shares, change the queue by the same amount and leave idle USDC and the share supply unchanged.
- H7d6: PxMath.toSigFigs5 is correct for every 6-digit raw price (the size of today's BTC / ETH / SOL raw marks).
- Not proved (time-outs / solver memory): the share-math and claim properties H1-H6 and the full settle properties
  V1 / V2. Their claims stay covered by tests only: the invariant suites (settle price moves only by rounding,
  reserved USDC backed, claims within the reserve), the fuzz test VERIFY2_B1, and the new kill tests M18-M21.
  Conservative reading: no symbolic guarantee for mulDiv-based conservation from this sub-review.
- HAL01 (from check_H8's counterexample): see the finding below.

## Time

Heavy-lock time for Halmos (`$TEMP/dv-heavy.lock`, owner "hl-r2 mut/halmos"): 06:39-06:53 (first H1 attempt), 08:55-09:31
(pass A), 09:32-10:45 (pass B), 10:45-14:51 (pass C: ~10 min useful, then the solver OOM hang and the power-off,
**~4.1 h lost**), 17:13-17:45, 17:45-18:08, 18:08-18:38 (pass C restarted). About 3.5 h of useful Halmos time, 7.6 h
of lock time in all. No property ran longer than 40 min (cap 2 h per property).

## Finding

**HLR2-HAL01 (Info)**: `PxMath.boundedLimitPx1e8` floors `rawMark * (BPS - slippageBps) / BPS` before rounding a SELL
up to 5 significant figures. When the floored value already has 5 significant figures the round-up does nothing,
so the flatten sell limit sits below `mark * (1 - slippage)` by less than one raw tick (counterexample rawMark
1,090,708, slippage 1,682 bps, szDecimals 0: limit 907,250 vs exact 907,250.91). The comment "the price never exceeds
the slippage bound" is off by < 1 tick (< 1e-5 of the price at 6 significant digits). Impact: negligible (a reduce
only IOC may fill up to a fraction of a tick worse than the stated band); likelihood: every sell flatten whose bound
is not an integer. PoC: `test_HLR2_HAL01_sellLimitBelowTheBandByLessThanOneTick` (passes on the current code). Fix:
round the sell bound up before the significant-figure step (`(rawMark * (BPS - slip) + BPS - 1) / BPS`), or document
"within one tick". Buys are not affected (floor is the conservative side).

## Reproduce

`C:\hlr2\hal` = `contracts/src` (non-gains) + `test/mocks/Mocks.sol` + `test/audit/hl-r2/halmos/`, foundry.toml as
above plus `libraries`; then `halmos --root . --contract <C> --function <check_x> --loop 20
--solver-timeout-assertion <s>s --solver-max-memory 4096 --solver-threads 2` (`mut-tool/halmos-run.sh`).
