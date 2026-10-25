# Gains round 2: Halmos (domain STAT, Halmos part)

**Internal, AI-assisted review. Not an independent audit.**

STATUS: **run 2026-10-21 under the 30-minute cap: 9 of 17 proven, 0 counterexamples, 8 timeouts** (results section
below). Before that it had not run (heavy-lock contention with the Hyperliquid round 2 review, then memory pressure).

**Cap: 30 minutes wall time per property** (owner's instruction of 2026-10-21; it replaces the brief's 2 h). Nothing had
run under the earlier caps, so every result below is under the 30-minute cap. Runner: scratchpad `combined/halmos-full.sh`
(waits for the combined runner to exit, then takes the heavy lock with a 15 min retry and holds it for the batch, overall
`timeout 32400`), which calls `combined/halmos-nolock.sh`: each check_ in turn under `timeout 1800`, halmos 0.3.3,
`--solver bitwuzla --solver-timeout-assertion 0 --solver-threads 4`. There is no per-query timeout, so the 30-minute wall
cap governs; the branching timeout is the default. Each outcome is recorded exactly as Halmos reports it: proven,
counterexample, or timeout (30 min). A timeout means "not proven", never "holds".

Harness: test/audit/gains/r2/symbolic/ConservationProps.sol (properties), HalmosConservation.t.sol (check_*),
HalmosConservationFuzz.t.sol (test_fuzz_* twins, 100,000 runs each). Runner: mutation/halmos-run-one.sh (30 min wall cap
per property, scratch project).

## Results (2026-10-21, 16:32 to 21:25, 292 min, heavy lock held for the batch)

**9 proven, 0 counterexamples, 8 timeouts at the 30-minute cap.** No property was refuted. A timeout means "not proven
by Halmos", never "holds"; for those 8 the evidence is the fuzz twin at 100,000 runs, plus the forge invariant
(2,048 x 500) and Medusa (12 h). Raw lines: halmos-results.txt (not included).

| id | property (single operation) | Halmos (30 min cap) | paths / time | fuzz twin 100k |
|---|---|---|---|---|
| C1 | deposit request: idle unchanged, USDC conserved, joins exactly the right queue (insider -> deferred) | **proven** | 59 / 577 s | pass |
| C2 | redeem request: shares owner -> escrow 1:1, supply unchanged, allowance spent exactly | **proven** | 33 / 1 s | pass |
| C3 | cancel deposit: idle unchanged, still backed | **proven** | 49 / 140 s | pass |
| C4 | cancel redeem: escrow >= pending kept | **proven** | 11 / 2 s | pass |
| C5 | settle (normal / redemption-only / exit-only / emergency partial): backed after, idle' = idle - paid + priced deposits, every queued dollar priced / refunded / still queued, burn <= queued, no mint outside normal, partial fill empties idle | **proven** | 256 / 661 s | pass |
| C6 | claim: pays only from the reserve (clamped), idle and queues untouched | **proven** | 88 / 15 s | pass |
| C7 | fee mint: no USDC moves, supply grows by exactly feeShares, protocol <= fee | timeout (30 min; Halmos prints "[ERROR] ... 1 failed" because the solver was killed, returncode 143; no counterexample) | 46 / 1,798 s | pass |
| N0 | toShares / toAssets(0) = 0 | **proven** | 6 / 0.06 s | pass |
| N1 | 2 redeemers: sum paid <= redemption assets (mulDiv) | timeout (30 min) | - | pass |
| N1p | same, plain arithmetic | timeout (30 min) | - | pass |
| N2 | partial fill burn bound | timeout (30 min) | - | pass |
| N3 | 2 depositors: sum minted <= minted for the sum | timeout (30 min) | - | pass |
| N4 | redemption assets <= NAV | timeout (30 min) | - | pass |
| N5 | mint never dilutes existing holders | timeout (30 min) | - | pass |
| N6 | redeem never dilutes remaining holders | timeout (30 min) | - | pass |
| N7 | operator reduce cap monotone (uint32 domain) | **proven** | 11 / 802 s | pass |
| N8 | protocol fee split | **proven** | 7 / 934 s | pass |

The timeouts are the nonlinear ones (mulDiv over two or three 128-bit symbolic amounts, plus C7's fee formula), which
bitwuzla does not close in 30 minutes. The single-operation conservation properties C1 to C6, including the full settle
in all four modes, are proven for all inputs in their (uint128 / uint64) domains.

Sensitivity: 5 deliberate breaks of the COPY lines; C2, C5, C6 failed as expected; C1 did not catch a wrong-queue
deposit, so C1 was strengthened (4cc9fd9) and then failed on it. C6's break shows as an underflow revert, which
Halmos would discard (only Panic 0x01 counts).
