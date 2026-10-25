# Gains round 1: Halmos (brief section 4, "Symbolic")

This is an internal review by a sub-reviewer. It is not an independent audit.

- Tools: Halmos 0.3.3, with solvers bitwuzla 0.8.1 and yices 2.6.4 (both downloaded by Halmos into `~/.halmos/solvers`).
- Source: contracts/src/gains/* at 9f39013.

Harnesses (all under `contracts/test/audit/gains/symbolic/`):
- `GainsSymbolic.t.sol` has four contracts: `GainsShareMathSymbolic`, `GainsFeeMathSymbolic`, `GainsNavSymbolic` and `GainsOperatorBoundSymbolic`.
  - They import the production libraries. GainsVaultMath, GainsNav, GainsPrice and `operatorReduceCap` are internal pure, so they are inlined into the harness.
  - The fee and claim shapes are the exception. Their production code reads VaultStorage and makes external calls, so the harness copies the exact expressions:
    - `GainsVaultLogic._accrueFees`, lines 347-381;
    - `claimableWithCarry`, lines 216-221;
    - the settle partial fill, lines 272-278.
  - Copied blocks are marked COPY in the source.
- `GainsPlainSymbolic.t.sol` (`GainsPlainMathSymbolic`) holds narrow-domain twins of the share, claim and fee inequalities. It writes `mulDiv(a, b, c)` as `a * b / c`, which is exact inside the 64/80-bit domains.
- `SymbolicFuzzTwins.t.sol` is a forge fuzz twin of every check expected to hold: 42 tests at 100,000 runs each.
  - Semantics match Halmos: a Panic 0x01 fails; any other revert discards the input.
  - It is evidence for the checks Halmos could not close within its time cap.

Driver: `audit/gains/tools/halmos-run.sh <Contract> <tag> <solver> [halmos args]`, run from contracts/.
- It compiles only the symbolic folder and its imports (via_ir, about 20-45 s) into `out-halmos-<tag>`, so several runs can go in parallel.
- It sets `PYTHONUNBUFFERED=1`. Without it, Halmos's per-test lines only reach the log when the run ends, which is what happened to the first share and fee runs below.

```
bash audit/gains/tools/halmos-run.sh GainsNavSymbolic nav bitwuzla --solver-timeout-assertion 900s
bash audit/gains/tools/halmos-run.sh GainsShareMathSymbolic shareA bitwuzla --function 'check_SM[1-4]_' --solver-timeout-assertion 120s
FOUNDRY_SRC=test/audit/gains/symbolic FOUNDRY_SCRIPT=test/audit/gains/symbolic FOUNDRY_OUT=out-twins FOUNDRY_CACHE_PATH=cache-twins \
  FOUNDRY_FUZZ_RUNS=100000 FOUNDRY_FUZZ_MAX_TEST_REJECTS=100000000 forge test --match-path test/audit/gains/symbolic/SymbolicFuzzTwins.t.sol
```

Semantics note: Halmos only reports assertion failures (Panic 0x01). A path that reverts, for example on a checked-arithmetic overflow, is discarded rather than reported. So:
- a "proven" check means no non-reverting path violates the assertion;
- the "no revert" properties (OB4*) wrap the call in try/catch and assert false in the catch.

## Results

| Id | Property | Function under test | Result | Solver / per-query timeout | Notes |
|---|---|---|---|---|---|
| OB1 | `operatorReduceCap(0) == 0` | GainsTypes.operatorReduceCap | **PROVEN** | yices, bitwuzla | |
| OB2 | cap >= shortfall; cap <= s + 2%·s + 1 USDC; cap - s >= 1 USDC (s < 2^200) | operatorReduceCap | **PROVEN** | bitwuzla 900 s (6.8 s) | |
| OB3 | cap monotone (uint200) | operatorReduceCap | TIMEOUT | yices 300 s, bitwuzla 900 s | fuzz twin 100k pass |
| OB3b | cap monotone (uint64 = any USDC amount) | operatorReduceCap | TIMEOUT (1,801 s) | yices 1,800 s | fuzz twin 100k pass |
| OB4 | cap never reverts for s < 2^200 | operatorReduceCap | TIMEOUT (904 s bitwuzla, 1,800 s yices) | bitwuzla 900 s, yices 1,800 s | fuzz twin 100k pass |
| OB4c | cap never reverts for s < 2^64 (every USDC amount) | operatorReduceCap | **PROVEN** (1,587 s) | yices 1,800 s | |
| OB4b | cap never reverts for any uint256 | operatorReduceCap | **COUNTEREXAMPLE (expected)**: s = 2^256 − 1 | bitwuzla (178 s) | `s * 200` overflows above 2^256 / 200; unreachable (USDC supply < 2^64) |
| SM1 | Floor <= Ceil, Ceil − Floor <= 1 (toShares, toAssets) | GainsVaultMath | **PROVEN** | bitwuzla 120 s (12 s) | |
| SM2 | deposit → immediate redeem never returns more | toShares / toAssets | TIMEOUT | bitwuzla 120 s | plain twin P_SM2 TIMEOUT 300 s; fuzz twins 100k pass |
| SM3 | a Floor mint never dilutes holders | toShares | TIMEOUT | bitwuzla 120 s | plain P_SM3 TIMEOUT 300 s; fuzz 100k pass |
| SM4 | a Floor redemption never dilutes the rest; paid <= NAV | toAssets | TIMEOUT | bitwuzla 120 s | plain P_SM4 TIMEOUT 300 s; fuzz 100k pass |
| SM5 | conversions monotone in the amount | toShares / toAssets | TIMEOUT | bitwuzla 120 s | fuzz 100k pass |
| SM6 | `priceAt(nav, s) == toAssets(ONE_SHARE, nav, s, Floor)` (checkRisk path = settle path) | priceAt / toAssets | **PROVEN** | bitwuzla 120 s (4 s) | |
| SM7 | first mint 1 USDC = 1e6 units, round trip <= deposit | toShares / toAssets | TIMEOUT | bitwuzla 120 s | fuzz 100k pass |
| SM8 | redAssets <= priceNav for shares <= supply | toAssets | TIMEOUT | bitwuzla 120 s | fuzz 100k pass |
| SM9 | emergency partial fill: burned <= queued, burned·redAssets <= paid·redShares | settle 272-278 (COPY) | TIMEOUT | bitwuzla 120 s | plain P_SM9 TIMEOUT 300 s; fuzz 100k pass |
| CL1 | 2 redeemers: Σ payouts <= epoch paid; Σ returned shares <= escrow − burned | claimableWithCarry 216-221 (COPY) | TIMEOUT (652 s, 311 paths) | bitwuzla 120 s | plain P_CL1 TIMEOUT 300 s; fuzz 100k pass |
| CL2 | 3 redeemers: Σ payouts <= paid | same | TIMEOUT | bitwuzla 120 s | fuzz 100k pass |
| CL3 | Σ deposit shares delivered <= depositShares | claimableWithCarry 213 (COPY) | TIMEOUT | bitwuzla 120 s | fuzz 100k pass |
| FE1 | fee shares worth <= feeAssets at the post-mint state; newPrice <= price | _accrueFees (COPY) | TIMEOUT (515 s, 221 paths) | bitwuzla 120 s | plain P_FE1 TIMEOUT 300 s; fuzz 100k pass |
| FE2 | protocolShares <= feeShares·bps/BPS <= feeShares | _accrueFees 368 (COPY) | TIMEOUT | bitwuzla 120 s | fuzz 100k pass |
| FE3 | newPrice <= price with the performance fee | _accrueFees (COPY) | CAPPED (run stopped at 55 min while on FE3) | bitwuzla 120 s | fuzz 100k pass |
| FE4 | rescaled peak / dayStart never rise; price >= ref ⇒ newPrice >= rescaled ref (no false loss) | _accrueFees 378-381 (COPY) | CAPPED (not reached) | bitwuzla 120 s | plain P_FE4 TIMEOUT 300 s; fuzz 100k pass |
| FE5 | feeAssets < assets (mgmt <= 5%, <= 10 y, perf <= 30%, hwm > 0) | _accrueFees (COPY) | CAPPED (not reached) | bitwuzla 120 s | fuzz 100k pass |
| FE6 | HWM only rises, and only to newPrice | _accrueFees (COPY) | CAPPED (not reached) | bitwuzla 120 s | fuzz 100k pass |
| NV1 | pnlPercent floored at −100%; sign follows the move; 0 at the open price | GainsNav.pnlPercent | TIMEOUT | bitwuzla 900 s, yices 300 s | plain P_NV1 TIMEOUT 300 s; fuzz 100k pass |
| NV2 | pnlPercent monotone in the price | GainsNav.pnlPercent | TIMEOUT | bitwuzla 900 s, yices 300 s | fuzz 100k pass |
| NV3 | tradeValuePure >= 0, nondecreasing in pnl, nonincreasing in fees, <= collateral when pnl <= 0 and fees >= 0 | GainsNav.tradeValuePure | TIMEOUT | bitwuzla 900 s, yices 300 s | fuzz 100k pass |
| NV4 | priceAfterImpact(px, 0) == px | GainsNav.priceAfterImpact | **PROVEN** | bitwuzla (0.6 s) | |
| NV4b | priceAfterImpact monotone in the impact (whole int64) | GainsNav.priceAfterImpact | **COUNTEREXAMPLE** | bitwuzla | see below; NAV-10 rediscovered |
| NV4c | a negative impact never raises the price | GainsNav.priceAfterImpact | **PROVEN** | bitwuzla (2.8 s) | |
| NV4d | monotone for \|impact\| <= 100% and px <= 2^63 | GainsNav.priceAfterImpact | TIMEOUT | bitwuzla 900 s, yices 300 s | fuzz 100k pass (bounded inputs) |
| NV5 | fixedSpreadP: long <= 0, short >= 0, \|x\| = spread / 2 | GainsNav.fixedSpreadP | **PROVEN** | bitwuzla (0.16 s) | |
| NV6 | adverse(long) <= mid (band <= 10%) | GainsPrice.adverse | TIMEOUT | bitwuzla 900 s, yices 300 s | fuzz 100k pass |
| NV6b | adverse(short) >= mid for every uint64 mid | GainsPrice.adverse | **COUNTEREXAMPLE (expected)** | bitwuzla (0.7 s) | mid = 2^64 − 1, band = 1,000: uint64 wrap; ADVERSETRUNC rediscovered |
| NV6c | adverse(short) >= mid below the wrap threshold | GainsPrice.adverse | TIMEOUT | bitwuzla 900 s, yices 300 s | fuzz 100k pass |
| NV7 | \|adverse − mid\|·1e4 <= mid·band (band applied once) | GainsPrice.adverse | COUNTEREXAMPLE (harness spec) | bitwuzla | rounding of 1 unit, see below |
| NV7b | NV7 with the 1-unit floor allowed: mid·band − 1e4 < d·1e4 <= mid·band + 1e4 | GainsPrice.adverse | TIMEOUT | yices 300 s | fuzz 100k pass |
| NV8 | notional term positionSizeToken·mid / 1e22 never overflows (uint160 × uint64) | GainsNav.snapshot line 61 | **PROVEN** | bitwuzla (0.18 s) | |

Totals:
- Proven: 9 (OB1, OB2, OB4c, SM1, SM6, NV4, NV4c, NV5, NV8).
- Counterexamples: 4. Three are expected or known (OB4b, NV6b, NV4b); one is a harness tolerance (NV7).
- Timeouts or caps: the rest. Every timed-out property holds on 100,000 fuzz runs (SymbolicFuzzTwins: 42/42 pass).

The pattern behind the timeouts:
- Everything that runs through OZ `Math.mulDiv` (512-bit `mul` / `mulmod` assembly) or through signed 256-bit division (`pnlPercent`, `tradeValuePure`, `priceAfterImpact`, the `/ 10_000` in `adverse` and in the cap) times out, on both bitwuzla and yices.
- This is true even with 32- and 64-bit input domains (GainsPlainMathSymbolic), because the EVM words stay 256-bit.
- What closed are the properties whose arithmetic is linear or has no division on the critical path.

### Counterexamples

- **NV4b (NAV-10, rediscovered).** px = 16,111,950,846,090,316,791 (1.6e9 USD at 1e10), i1 = 1,701, i2 = 6,917,529,027,641,082,107 (6.9e6 % impact).
  - `priceAfterImpact(px, i2)` wraps at the uint64 cast (GainsNav.sol:192) to a value below `priceAfterImpact(px, i1)`.
  - It needs an impact above about 100% and a price near 2^64. Neither is reachable from Gains, which caps impact. The nav domain already refuted it as an exploit (NAV-10).
  - The bounded version (NV4d) times out symbolically and passes 100k fuzz runs.
- **NV6b (ADVERSETRUNC, rediscovered).** mid = 2^64 − 1, band = 1,000.
  - `adverse(mid, band, false) = uint64(mid · 1.1)` wraps to about 0.1 · 2^64, below mid (GainsPrice.sol:318).
  - It needs a feed answer of at least 2^64 / 1.1 at 1e10, about 1.68e9 USD per unit. GainsPrice.read accepts answers up to 2^64 − 1 (1.84e9 USD).
  - Already filed as ADVERSETRUNC (Info).
- **NV7 (harness tolerance, not a code defect).** mid = 9,602,279,994,571,776,871, band = 768, long.
  - `adverse` floors: a = floor(mid · 9,232 / 10,000), so d = mid − a = ceil(mid · 768 / 10,000). That is one 1e-10 unit more than mid · band / 1e4.
  - The rounding favours the vault: a long is valued lower. My assertion omitted that unit. NV7b, with the unit, holds on 100k fuzz runs.
- **OB4b (expected).** s = 2^256 − 1 overflows `shortfall * OPERATOR_REDUCE_BUFFER_BPS` (GainsTypes.sol:30) and reverts.
  - `redemptionShortfall` is bounded by the claimable plus pending redemptions, which are below the USDC supply.
  - OB4 / OB4c and the fuzz twins show no revert for s < 2^200.

No new finding.

## Caps (user rule: no single run longer than about 2 h)

| Run | Configuration | Ran | Outcome |
|---|---|---|---|
| GainsNavSymbolic (13 checks) | bitwuzla, 900 s per assertion query | 7,304 s (2.03 h, finished on its own) | results above |
| GainsShareMathSymbolic (12 checks), first run | bitwuzla, 900 s per query | **killed at about 2 h 05 min** | no per-test output (stdout buffered); re-run below |
| GainsFeeMathSymbolic (6 checks), first run | bitwuzla, 900 s per query | **killed at about 2 h 05 min** | no output (buffered); re-run below |
| Share re-run in 3 parallel groups (SM1-4, SM5-9, CL) | bitwuzla, 120 s per query | 10-25 min each | results above |
| Fee re-run | bitwuzla, 120 s per query | **stopped at 55 min** (22:23) while on FE3 | FE1, FE2 timeouts; FE3-FE6 not reached / capped |
| GainsOperatorBoundSymbolic | yices 300 s; bitwuzla 900 s | 5 min; 33 min | results above |
| OB3 / OB3b / OB4 / OB4c re-run | yices, 1,800 s per query | 1 h 58 min, finished | OB4c PROVEN; OB3, OB3b, OB4 TIMEOUT |
| GainsPlainMathSymbolic (8 checks) | bitwuzla, 300 s per query | about 40 min | timeouts listed above |
| SymbolicFuzzTwins (forge fuzz, 42 tests) | 100,000 runs each, max rejects 1e8 | 97 s | 42/42 pass |

Halmos has no per-test wall-clock limit, only a per-query solver timeout. A check with many paths can therefore exceed it: CL1 ran 652 s on 311 paths at 120 s per query.

## Final status of the capped runs

Nothing is still running.
- Total Halmos wall time was about 6.5 h across parallel runs. No single run went past 2 h 05 min: the first share and fee runs were stopped there.
- The operator bound is proven for every USDC-sized shortfall: OB1, OB2 and OB4c (no revert, cap >= shortfall).
- Its monotonicity (OB3/OB3b) only reached a timeout, and holds on 100k fuzz runs.
- The fee math (FE1-FE6) has no symbolic proof. Its evidence is the 100k-run fuzz twins plus the invariant F2/F3/F4 properties in FUZZING.md.
