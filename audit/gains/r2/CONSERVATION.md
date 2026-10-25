# Round 2, domain CI: the conservation invariant

**Internal, AI-assisted review by a sub-reviewer. Not an independent audit.**

Source under test: `contracts/src/gains/*` at `origin/main` 4ec6feb (branch `audit/gains-r2`), unchanged.

## 1. The question, as an invariant

> Every unit of USDC that enters the vault leaves it only (a) as collateral for the vault's own trades and orders on
> the diamond (and comes back only to the vault), (b) to a redeemer pro rata to their shares at the price the settle
> published, or (c) as fees within the configured caps.

The suite books every unit, including collateral in flight at the diamond, and checks fairness at every settle,
claim and fee mint.

## 2. Files

| File | What |
|---|---|
| `test/audit/gains/r2/ConservationMocks.sol` | `LedgerUSDC`: a 6-decimal USDC that books every transfer touching the vault: in from depositors and donors, collateral to the diamond, payouts from it, deliveries to the one address the handler names before each call (claimant or canceller), and anything else (`strayOut`). `CIDiamond`: a copy of `MockGainsDiamond` (same ABI and value math), extended. The original cannot be extended because its functions are not virtual. |
| `test/audit/gains/r2/ConservationWorld.sol` | `CIWorld`: a factory vault made by `GainsVaultFactory.create`, set up like the live one. Owner = manager = fee recipient; agent bound; keeper as operator; hosted (protocol share 33%); fees 2% / 20%; timelock 2 days. Live policy: 5x, daily loss 15%, drawdown 50%, slippage 3%, maxOrderNotional 250k, maxEpochDuration 1 day, maxNavMove 20%, flatten 3%. Pairs BTC / ETH with a 20 bps band; 1 USDC seed. Differences from live: no deposit cap, the mock diamond, the ledger token. |
| `test/audit/gains/r2/ConservationHandler.sol` | `CIValuer`: an independent valuation of the venue from the mock's close math, at the adverse edge, the mid and the favourable edge, with orders counted by their real type. `CIHandler`: the actions, the ghost ledger and the per-operation checks. |
| `test/audit/gains/r2/ConservationChecker.sol` | `CIChecker`: the global checks, shared by forge and Medusa |
| `test/audit/gains/r2/ConservationInvariants.t.sol` | `ConservationInvariants.invariant_conservation`, `ConservationHandlerSanity`, `ConservationScenarios` (the two sensitivity scenarios and the PoC of GR2-CI-01) |
| `test/audit/gains/r2/medusa/ConservationMedusa.sol`, `audit/gains/r2/medusa-ci.json` | Medusa harness (every handler action 1:1, the checks as `property_`) and its config |
| `audit/gains/r2/ci/unfix_gv02.py`, `audit/gains/r2/ci/sensitivity.txt` | GV-02 un-fix script; raw output of the sensitivity runs |

### What the mock diamond can do (all driven by the handler)

- Fill a market open, partial open, partial close, close or leverage update at the Chainlink price ± 0.5%.
- Leave orders pending across any number of calls (delay).
- Cancel in the callback, keeping the gov fee.
- Time out: `cancelOrderAfterTimeout`, through the vault's permissionless `cancelTimedOut`, after 201 blocks.
- Execute limit and stop orders.
- Hit TP / SL.
- Liquidate, only when the trade is at or past the -90% liquidation price.
- File Gains' own trigger executions as pending orders that hold nothing (types 2 to 6), and resolve or drop them.
- Report a collateral-holding order under an unknown type (10, 11, 12, 13, 200) and restore it: GV-02.
- Change pair fees, spread and gov fee; move holding fees (funding) by ±5% of collateral per step.
- Move prices by ±4% per step, crash by 18% or 35%, or a "stress" move: ETH -35% and BTC +35% together, against both seed trades.

Two changes from the original mock:
- A fill or close on a trade that is no longer open is now cancelled, with its held collateral refunded. The original mock would pay a close twice if a trigger had closed the trade first.
- `cancelOpenOrder` refuses while a trigger order on the same trade is pending. This matches Gains' "PendingTrigger" refusal.

### Actors

| Actor | Role in the handler |
|---|---|
| Depositors D0, D1, D2 | Ordinary depositors |
| Confederate C | Not an insider, controlled by the manager. Priced in the current epoch; the GR1-02 attacker. |
| Manager M (also owner and fee recipient) | Insider deposits go to the next epoch. Trades; settles; raises fees through the timelock; lowers fees; triggers stops; resumes. |
| Agent A | Trades; re-bound through the timelock after a full stop |
| Keeper K (operator) | Settles; reduces trades to fund redemptions (within its cap); checkRisk |
| Sentinel S | Settles exit-only when overdue; triggers breaches; flattens and cancels while breached |
| Guardian G | Emergency; clears; exits the emergency after a fully paid settle; flattens |
| Stranger X | Donations; `cancelTimedOut`; `checkRisk`; `clearLeverageBreach`; `accrueFees`; executes timelocked items; claims for others; `triggerEmergency` when overdue; exits it tries and is refused |

Payers may deposit for other controllers (insider payer, so deferred). Actions include a bank run: three holders redeem everything, then an emergency and an exit-only settle on the USDC at hand.

## 3. Properties

All properties are exact unless a bound is stated. Each bound is derived in section 4.

**Ledger (USDC), checked after every call:**
- **C1.** USDC into the vault equals deposits plus donations (the seed came before the ledger started). USDC to users equals claims plus refunds. `strayOut == 0`: nobody but the diamond, or the claimant or canceller of that very call, ever received USDC from the vault.
- **C2.** The venue's escrow ledger equals the escrow recomputed from its open trades and orders. Collateral sent equals collateral pulled, which equals what the vault's own trader calls asked for (open, increase, leverage decrease); nothing was pulled outside one. Every venue payout for the vault reached the vault.
- **C3.** `vault USDC + escrow at the diamond == seed + deposits + donations − refunds − claims + (venue payouts − collateral released)`. The last term is the P&L the mock decided, net of Gains' fees and the gov fees callback cancels kept.
- **T4.** The vault's allowance to the diamond is 0.

**Fairness, checked in the handler at the operation:**
- **F1.** A settle never lowers the continuing holders' fair value per share, after the fee dilution. Fair value = idle + the venue valued at the Chainlink mid, independently. The check is `(V1+1)(S0+F+1e6) >= (V0+1)(S1+1e6)`. Exact, except an emergency partial fill, which may favour redeemers by under one share unit.
- **F1d.** Deposit shares = `toShares(depIn, max(advNAV, idle + favNAV), supply after fees)`, with the NAVs independent. Zero shares means a refund. Nothing is minted in an exit-only or redemption-only settle.
- **F1r.** Redemption payout = `toAssets(shares, priceNav, supply after fees)`. priceNav = advNAV, or min(advNAV, checkpoint) in a redemption-only or exit-only settle. A partial fill (emergency only) pays exactly the USDC on hand and burns `floor(shares × paid / owed)`.
- **S1.** No settle runs while an order that holds collateral (by its real type) is pending.
- **F2.** Every delivery (claim, or the implicit claim in requestDeposit / requestRedeem) equals the entitlement computed from the epoch records. Per epoch: claimed USDC ≤ redeemAssets; returned shares ≤ redeemShares − burned; claimed deposit shares ≤ depositShares; refunds ≤ depositAssets. A stranger's claim pays the controller, never the stranger.
- **F3.** At every fee mint (settle, accrueFees, the accrual inside setFees / lowerFees):
  - fee shares × (NAV+1) ≤ (cap+1) × (supply+fee+1e6), where cap = NAV × mgmt × Δt / (BPS × YEAR) + (performance only in a normal settle) perf × max(0, price − HWM) × supply / ONE_SHARE / BPS;
  - mgmt ≤ 500, perf ≤ 3,000, protocol ≤ 5,000;
  - protocol shares × BPS ≤ fee shares × protocolShareBps;
  - the fee recipient gets exactly fee − protocol, nobody else gets any.

**Reserves and flows:**
- USDC ≥ pending + deferred deposits + claimable.
- pending + deferred == the sum of unpriced requests (carried ones included).
- claimable ≥ every outstanding entitlement, and claimable − entitlements ≤ the dust bound (one wei per redeemer per settle, plus one).
- The share escrow covers queued and unclaimed shares. Every share is held by a known holder.
- A depositor flow (request, cancel, claim) never changes idle USDC, the share supply or the venue: reserves never cross-subsidise the holders.
- A cancel returns exactly the request. requestRedeem escrows exactly the shares.

**NAV:**
- **N1.** `totalAssets() == idle + independent adverse valuation` while prices are fresh. `CI_SKIP_NAV=true` switches N1 off; this is used to show that the fairness properties alone catch GV-02.

## 4. Rounding bounds (why each one is the bound)

- **F1, exact outside a partial fill.**
  - Deposits: shares d ≤ depIn(S+1e6)/(Vh+1) with Vh ≥ Vmid, so d(Vmid+1) ≤ depIn(S+1e6).
  - Redemptions: paid ≤ r(Vp+1)/(S+1e6) with Vp ≤ Vmid.
  - Adding both: `(V+depIn−paid+1)(S+1e6) − (V+1)(S+d−r+1e6) ≥ 0`, with no rounding slack, because both floors favour the holders.
  - Vmid ≤ Vfav because the mock's close value is monotone in price, and liquidation at the favourable edge implies liquidation at the mid.
- **F1, partial fill.** burned = floor(r × paid / owed) can be one share unit (1e-12 share) too few. Tolerance: one share unit at the pre-settle price, `(V0+1)` in cross-multiplied units, which is far below one wei of USDC.
- **F1 is skipped when the supply is 0.** The first mint gives 1e6 units per USDC whatever the NAV. The seed, donations or leftover dust go to the first depositors. This is GR1-39, already documented, and no holder exists to lose.
- **F3.** The vault mints `floor(c(S+1e6)/(A−c))` shares for a fee c. Their value `F(A+1)/(S+F+1e6) ≤ c(A+1)/A < c+1`.
- **Claimable dust.** Each redeemer's claim is floored, so a settle can leave at most (number of redeemers) wei unclaimable in `claimableRedeemAssets`, forever. It belongs to nobody. The bound is checked cumulatively.

## 5. Runs

All runs used forge 1.8.4 with via_ir, in scratch copies of `contracts/` (own `out/`) under the session scratchpad. The worktree run used the forge lock; heavy runs used the heavy lock.

| # | Where | Campaign | Runs × depth | Calls | Handler reverts | Time | Result |
|---|---|---|---|---|---|---|---|
| 1 | scratch dev | debug | 16 × 200 | 3,200 | 0 | 6 s | pass (low coverage: opens 0) |
| 2 | scratch dev | debug after sizing fixes | 64 × 300 | 19,200 | 0 | 77 s | pass |
| 3 | scratch dev | 256-run check | 256 × 500 | 128,000 | 0 | 385 s | pass (an emergency dominated the last run; the handler was retuned) |
| 4 | scratch dev | coverage tuning (5 runs, stats below) | 64 × 500 each | 32,000 each | 0 | 150–270 s each | pass |
| 5 | scratch u102 (GR1-02 undone) | sensitivity | 64 × 300 | 642 at failure | 0 | 40 s | **FAIL F1** at run 3 |
| 6 | scratch ugv02 (GV-02 undone) | sensitivity | 64 × 300 | 13 at failure | 0 | 28 s | **FAIL N1** at run 1 |
| 7 | scratch ugv02 | sensitivity, N1 off | 64 × 300 | 19,200 | 0 | — | pass (the 3 calls needed did not occur; the settle action was given a second selector, see 8) |
| 8 | scratch ugv02 | sensitivity, N1 off | 256 × 300 | 15,609 at failure | 0 | 70 s | **FAIL** (shrunk: leverage update, retype, settle; S1 / F1r) |
| 9 | scratch u102, final handler | sensitivity | 256 × 500 | 1,512 at failure | 0 | 58 s | **FAIL F1** (shrunk: deposit, settleKeeper) |
| 10 | scratch ugv02, final handler | sensitivity, N1 off | 256 × 500 | — | 0 | 114 s | **FAIL F1r** (shrunk: openTrade left pending, retype to unknown, bankRun) |
| 11 | worktree (forge lock), 2026-10-20 03:07 | `--match-path ConservationInvariants.t.sol --no-match-test invariant_conservation`: sanity, the two sensitivity scenarios, GR2-CI-01 | — | — | — | 192 s (188 s compile) | **4 / 4 pass** (section 6) |
| 12 | scratch `heavy` (heavy lock) | **campaign** | **2,048 × 500** | — | — | — | **NOT RUN** (section 7) |
| 13 | scratch `med` (heavy lock) | **Medusa**, cap 12 h | — | — | — | — | **NOT RUN** (section 7) |

Cross-run coverage of the final handler (64 × 500, `CI_STATS_FILE`, totals over 65 runs):

| settles | normal | redemption-only | exit-only | partial fills | minting deposits | with open trades | deposits | redeems | cancels | claims | fee mints | opens | fills | callback cancels | timeouts | liquidations | triggers | retypes | emergency triggers |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1,189 | 487 | 18 | 684 | 15 | 171 | 244 | 214 | 575 | 83 | 679 | 2,640 | 153 | 459 | 76 | 48 | 5 | 111 | 21 | 290 |

"Exit-only" includes the platform roles' settles of an overdue epoch, which refund deposits. With maxEpochDuration = 1 day and the 2-day fee timelock, that path is common.

## 6. Results on the real code (worktree, run 11)

`forge test --match-path test/audit/gains/r2/ConservationInvariants.t.sol --no-match-test invariant_conservation -vv`,
forge lock, 2026-10-20 03:04-03:07 (compile 188 s, tests 58 ms):

| Test | Result | What it shows |
|---|---|---|
| `ConservationHandlerSanity.test_CI_handlerDrivesEveryAction` | pass | Every handler action runs on the real code without breaking a check |
| `ConservationScenarios.test_CI_sensitivity_GR102_depositWhileTradesOpen` | pass | Holders' mid value per share 999,558 before, 999,932 after (rises): the deposit is priced at max(adv, idle + fav) |
| `ConservationScenarios.test_CI_sensitivity_GV02_unknownTypeHoldsSettle` | pass | Settle waits; 0 shares minted, 0 redemption paid, value per share unchanged |
| `ConservationScenarios.test_GR2_CI_01_unknownTypeOnNonHoldingOrderOverstatesNav` | pass (asserts the bad behaviour) | Section 9 |

Invariant campaigns on the real code that passed (scratch copies whose `src/` and Conservation*.sol are byte for byte
the worktree's, checked with `cmp` / `diff -r` on 2026-10-20): runs 1-4 above, the largest 256 × 500 (128,000 calls,
0 reverts, 385 s), and five 64 × 500 coverage runs (32,000 calls each). No invariant break on the real code in any run.
The required 2,048 × 500 campaign was not run (section 7), so the real-code evidence stops at 256 × 500.

## 7. Heavy runs: not run in this session (superseded: both ran later, see §12 and §13)

- **State on take-over (2026-10-20 03:04).** The heavy lock was held by the Hyperliquid round 2 review
  (`hl-r2 mut/halmos: pastfix+mutants session 1d`, since 02:15), with another hl-r2 waiter queued (async conservation,
  2,048 × 500). The previous CI sub-reviewer had left its own waiter (`scratchpad/CI/heavy.sh`, forge 2,048 × 500 only)
  polling every 15 min since 00:52 (`heavy-wait.log`); it never held the lock. No stale CI lock, no CI forge lock, no
  uncommitted CI files in the two r2 folders (`mutation/batch2.sh` and `mutation/honest.py` are the MUT domain's and
  were not touched).
- I stopped that waiter to replace it with `scratchpad/CI/heavy2.sh` (one lock hold: forge 2,048 × 500 in
  `scratchpad/CI/heavy`, then Medusa in `scratchpad/CI/med` with `timeout: 43200`, i.e. 12 h, the brief's full cap as
  the owner asked, hard-killed at 44,400 s). **Starting the new background waiter was refused by the session's
  permission classifier** ("Interfere With Workloads"). I did not try to get around it. Result: **no CI heavy waiter is
  queued now**, and neither the 2,048 × 500 campaign nor Medusa ran.
- To run them (owner): `bash <scratchpad>/CI/heavy2.sh`. It waits for the heavy lock (15-min polls, `heavy-wait.log`)
  and writes `heavy.log`, `heavy-time.txt`, `stats-heavy.csv`, `med.log`, `med-time.txt` next to it. The scratch copies
  are current; `med/` is prebuilt (`out-medusa`, `--ignore-compile`, 54 files, 164 s). Expected time: forge about
  50 min (256 × 500 took 385 s), Medusa 12 h. `audit/gains/r2/medusa-ci.json` now carries the 12 h timeout.
- Caps: none hit (nothing heavy ran). The Medusa cap for this domain is 12 h (owner's change of plan; was 4 h).

## 8. Sensitivity checks (the suite must fail with each fix undone)

Raw output: `ci/sensitivity.txt`. Scratch copies `u102` (GR1-02a + GR1-02b undone with round 1's
`audit/gains/fixes/revert-check/unfix.py`) and `ugv02` (GV-02 undone with `ci/unfix_gv02.py`: unknown types neither
block nor count, as round 1's GR1-04 fix had it).

| Fix undone | Invariant campaign | Scenario | Verdict |
|---|---|---|---|
| GR1-02 | run 5: FAIL F1 at run 3 (642 calls); run 9 (final handler, 256 × 500): **FAIL F1** at run 4, 1,512 calls, shrunk to 2 calls, `deposit` then `settleKeeper` (seed `0x1c19…0c14`) | `test_CI_sensitivity_GR102_depositWhileTradesOpen` **FAIL** ("holders diluted": 999,558 → 999,178 per share) | caught |
| GV-02 | run 6: **FAIL N1** at run 1 (13 calls). With N1 off (`CI_SKIP_NAV=true`, to show the fairness checks catch it alone): run 8 FAIL S1 / F1r at 15,609 calls; run 10 (`ugv02-final-skipnav`): **FAIL F1r** at run 69, 34,009 calls, shrunk to 3, `openTrade` left pending, `gRetype` to an unknown type, `bankRun` (seed `0xba77…1eee`) | `test_CI_sensitivity_GV02_unknownTypeHoldsSettle` **FAIL** (999,558 → 973,005 per share; the settle ran beside the unknown order, minted 0.338e18 shares for 300k and paid 106,081 USDC of redemptions) | caught |

Check of the record: the `ugv02-final.log` invariant line ("runs: 1, calls: 3") is forge **replaying the
counterexample persisted** by the skip-NAV run (the log says "Run `forge clean` or remove file"), not a fresh find; the
fresh GV-02 finds are runs 6, 8 and 10. The GR1-02 finds (runs 5 and 9) are fresh. Both undone fixes are therefore
caught by the invariant and by the scenario, and the same scenarios pass on the real code (section 6). The GR2-CI-01
PoC also flips under `ugv02` (overstatement 0), confirming the overstatement comes from GV-02's fail-closed valuation.

## 9. Findings

### GR2-CI-01 (Low): an unknown order type on a non-holding order overstates NAV, and the permissionless fee accrual charges on it

**PoC:** `test/audit/gains/r2/ConservationInvariants.t.sol::ConservationScenarios.test_GR2_CI_01_unknownTypeOnNonHoldingOrderOverstatesNav`
(passes on the real code, run 11).

**Mechanism.** `GainsNav._pendingEffect` (GV-02's fix) returns `(o.trade.collateralAmount, 0, pair, blocks = true)` for
any order type it does not list (10, 11 PNL_WITHDRAWAL, 12, 13, any future value). That is right for settle (it waits:
fail closed), and right for NAV if the unknown order really holds collateral. But if Gains reports an order that holds
nothing (a partial close, whose `collateralAmount` field is the amount to close) under an unknown type, the field is
added to NAV as collateral held at the diamond while the trade it refers to is still valued as open: the amount is
counted twice. Settle is blocked (`OrdersPending`), so no deposit or redemption is priced on it, but the other NAV
consumers are not:
- `accrueFees()` is permissionless and charges `NAV × mgmt × Δt` on the inflated NAV; so do the accruals inside
  `setFees` / `lowerFees`.
- `checkRisk()` (permissionless) raises `peakSharePrice` (lifetime, reset only by `resume`), on the first check of a
  UTC day sets `dayStartSharePrice`, and writes the keeper checkpoint, all from the inflated NAV. (Code reading, not in
  the PoC: when the phantom disappears the price falls by phantom / NAV; a phantom above 15% of NAV within the day gives
  a daily-loss breach, above 50% a drawdown breach. A breach is reduce-only and the owner can resume, so this is a
  liveness side effect, not a loss. maxNavMove may refuse the next settle until a fresh `checkRisk`.)

**Numbers (PoC).** Vault NAV 698,810.80 USDC; the manager requests a 40,000 USDC partial close (holds 0); the order is
reported as type 10: NAV 738,810.76, overstated by 39,999.96 (40,000 minus the minimum gov fee). Settle reverts
`OrdersPending`. After 10,801 s, `accrueFees()` mints exactly the fee on the inflated NAV: 5.0608 USDC instead of
4.7868, +0.2740 USDC (= 40,000 × 2% × 10,801 / 31,536,000).

**Impact on a 100k vault with a 40k phantom.** Management fee 2%: 7.67 USDC/day charged instead of 5.48, i.e.
**+2.19 USDC/day** (40,000 × 0.02 / 365), 800 USDC/year (0.8% of the vault) if it lasted a year. At the 5% management
cap: +5.48 USDC/day. The phantom is bounded by the order's collateral field, which for a vault-created close is at
most the trade's collateral, so the overcharge is at most mgmt × (collateral of the trades with such an order) × time.
The holders lose it by dilution; the fee recipient (manager) and the protocol (33% hosted share) receive it. No
performance fee: that is charged only in a normal settle, which is blocked. Duration: until the order fills, is
cancelled or times out (`cancelTimedOut`, if Gains' timeout applies to that type); under a Gains that never resolves
it, until the guardian acts.

**Likelihood: very low.** It needs Gains (a diamond upgrade the vault cannot control) to report one of the vault's
non-holding orders (close, partial close, leverage increase, trigger execution) under a type outside the list the vault
knows, while such an order is pending. No vault role and no outsider can cause it with today's Gains (the PoC uses the
mock's `retype`). The manager can collect it by calling `accrueFees` but cannot make it happen.

**Severity: Low** (theft of yield in principle, bounded to mgmt × phantom × time, small per day, conditional on a Gains
change). Not Critical or High: no ALERT.

**Relation to GV-02 (FIXES-R1).** GV-02 deliberately chose "unknown type: block settle and count its collateral",
because the opposite (round 1: neither block nor count) let a settle run beside an unknown order that holds collateral
and price deposits and redemptions on an understated NAV (shown again in section 8: 999,558 → 973,005 per share). That
choice is kept and is correct for settle. The trade-off FIXES-R1 did not record: while settle waits, the counted
collateral still feeds the fee accrual and the risk references, and for fees an overstatement is the harmful direction.

**Fix direction (no change made; src is out of scope).** In order of preference:
1. In `_accrueFees`, when the snapshot has a pending order of an **unknown** type, charge nothing and **do not advance**
   `lastFeeAccrual`: the first accrual after it resolves charges the true NAV over the whole period, which is fair.
   Needs `GainsNav.Snapshot` to count unknown-type orders separately from the known holding ones (e.g.
   `unknownBlocking`). `setFees` / `lowerFees` keep working (they accrue nothing then).
2. Or value unknown-type collateral at 0 for fees only (fee NAV = the lower reading), keeping the fail-closed
   valuation for everything else.
3. Optionally skip the `peakSharePrice` / `dayStartSharePrice` raise in `checkRisk` while an unknown type is pending,
   so the phantom cannot leave a lasting false peak.

Regression test: the PoC with the assertion inverted (fee minted equals the fee on the true NAV, or nothing).

## 10. Open questions

- The 2,048 × 500 campaign and Medusa did not run (section 7). The real code is shown conserving up to 256 × 500 and in
  the 64 × 500 coverage runs. The sensitivity checks show the suite catches both undone fixes within 4-69 runs, which is
  some evidence that a break of that kind would surface, not proof.
- The `checkRisk` side effect of GR2-CI-01 (inflated lifetime peak, false breach when the phantom disappears) is from
  code reading; no PoC.
- The mock diamond models Gains' value math (copied from `MockGainsDiamond`), not the real facets; real Gains behaviour
  (fee sequencing, borrowing fees, timeouts per type) is the GNS domain's.

## 11. Assumptions (conservative readings)

- "Fair price" = the settle's published price (adverse NAV for normal settles, min(adverse, checkpoint) for
  redemption-only / exit-only), checked against an independent valuation; the vault's adverse-edge pricing is the
  specification, not a finding.
- The first mint into an empty vault (GR1-39, documented) is excluded from F1.
- A phantom created only by an external Gains change counts as a finding (Low), not as out of scope.

## 12. Full campaign (added by the lead, 2026-10-20)

Run by the owner-approved combined runner (stage 3) under the heavy lock, in the scratch copy `scratchpad/CI/heavy`
(src identical to the worktree): `FOUNDRY_INVARIANT_RUNS=2048 FOUNDRY_INVARIANT_DEPTH=500 forge test --match-test
invariant_conservation`.

**Result: `invariant_conservation` PASS — 2,048 runs × 500 depth, 1,024,000 calls, 0 reverts** (19:28–20:04, 2,195 s).
Raw output: ci/heavy-2048x500.txt (not included), per-run handler statistics:
ci/stats-heavy-2048x500.csv (not included). The invariant gate (ROUND2.md section 7) also ran it at
512 × 500 (256,000 calls, 0 reverts). Medusa is stage 5 of the same runner (12 h cap).

## 13. Medusa, 12 h (added by the lead, 2026-10-21)

- Run: Medusa 1.5.1 on `ConservationMedusa` (scratch copy `scratchpad/CI/med`, same src tree as the audit branch),
  8 workers, call sequence length 100, `timeout: 43200`, combined runner stage 5 under the heavy lock,
  2026-10-21 04:27:08 to 16:27:19 (43,212 s). **The 12 h cap was hit** (Medusa stopped on its own timeout, exit 0).
- Volume: **23,311,723 calls in 233,114 sequences**, 12,855 branches, corpus 304.
- Result: **39 / 39 passed, 0 failures**: the 4 properties (`property_fairness`, `property_ledger`, `property_nav`,
  `property_reserves`) and the 35 assertion handlers (every vault entry point the harness drives, the Gains callbacks,
  fee governance, crash/stress/bank-run, donations and time).
- Excerpt with hourly progress and the result block: ci/medusa-12h.txt (not included) (the full 2.0 MB log
  stays in the scratchpad).
- Not done: a Medusa sensitivity run with GR1-02 / GV-02 undone. The cap was spent on the real code; the forge
  sensitivity checks (§8, §12) show the same properties fail with those fixes undone.

