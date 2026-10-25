# Gains round 1: cross-review and self-challenge (brief sections 3 and 6)

Two adversarial reviewers, each attacking the conclusions of the other domains. Their tests:
`test/audit/gains/xreview/XReview.t.sol` (forge, 3 pass) and `test/audit/gains/xreview2/*.test.ts` (vitest, 3 pass:
`cd server && npx vitest run --config ../contracts/test/audit/gains/xreview2/vitest.config.mjs`). Live parameters read
from Arbitrum One (vault: an earlier deployment): policy 3x / daily loss 5% / drawdown 15% / maxSlippage 1% / maxOrderNotional
250,000 / epoch 1 day / maxNavMove 20% / flatten cap 3%; owner = manager = policy owner = fee recipient the launcher's wallet;
cap 21 USDC; NAV 37 wei.

| Finding | Verdict | Severity after challenge | Reason |
|---|---|---|---|
| NAVBIAS + NAV-02 | KEEP, upgraded | High (with XR-1) | Deposit side is the transfer; a passive in-and-out while open is neutral (99,999.999 of 100,000, test_XR_NAVBIAS_passiveInAndOutWhileOpenIsNeutral). settle has no minimum epoch age for non-insider deposits, so a manager cycles every few minutes: 10 cycles in ~1 h on the live policy shape, confederate +4,750 USDC, holder 100k → 94,696, stopped only by the daily-loss breach (clears next UTC day; drawdown clears via resume by the owner, who is the manager on the live vault). Fork fees cut it to ~3.5% of holder NAV per day. |
| XR-1 (new) | CONFIRMED | merged into NAVBIAS | No minimum epoch age for settles that mint non-insider shares (GainsVaultLogic.sol:227). test_XR_NAVBIAS_intradayCyclesBoundedByDailyLoss. |
| NAV-01 | KEEP | Medium | Double count real (C <= L(1+B)/(1−B) ≈ L(1+2B)); 200x reachable (no per-trade leverage cap); multiplies NAVBIAS ~2.1x per notional; harmless alone (understates only). |
| LC-01 / PENDINGLEVNOTIONAL | KEEP, upgraded | High | Nothing on chain undoes the fills (checkRisk only sets reduce-only; the sentinel never flattens). Live params, 100k vault: 20 trades x 5k at 1.5x then 20 concurrent +30x leverage-only increases (150k each, under the 250k order cap) → ~3.15M notional = 31x under a 3x policy; a ~3% adverse move wipes NAV. A manager or one compromised agent key, ~1 s fill window, one tx per trade. |
| LC-02 / PENDINGGRIEF | KEEP | Medium | Guardian's only lever is racing; without Timeboost it ends in seconds-minutes per trade; with an express lane it is unbounded; ~0.0425 USDC gov fee per decoy (~300 USDC/h at 2/s). |
| LC-03 | downgraded | Info | Only SL tightening and resting cancels; ~720 LINK/h to hold, no gain. |
| LC-04 | downgraded | Info | One correct price passes both one-sided checks; a subset of LC-02 decoys. |
| LC-05, LC-06, LC-07 | KEEP | Info, Info/Design, Info | |
| GOV-01 | KEEP | Low | ~1 USDC/s needs a compromised online key; attacker gains nothing. |
| GOV-02, GOV-04, GOV-05, GOV-07, GOV-08 | KEEP | Info | |
| GOV-03 | KEEP | Low | Only after a vault ownership transfer; grief, no theft. |
| GOV-06 | KEEP | Low | Exits work; guardian flattens then settles. |
| NAV-03, NAV-04 | KEEP | Low | Impact high, likelihood near zero / very low. |
| NAV-05 | downgraded, merged | Info | One-off Δband x leverage step behind a public >= 1 day queue; removed by the NAVBIAS fix. |
| NAV-06 | KEEP | Low | Bounded by deviation x leverage (~15 bps at 3x); lets outsiders take the per-settle NAVBIAS. |
| NAV-09 | dropped to a note | Info | ~27k calls/day to erase $0.027/day of fee. |
| ADVERSETRUNC | downgraded | Info | Needs a feed answer >= 1.84e9 USD/unit (uint64 at 1e10), outside T4; the same broken feed overvalues every long more. Fix with SafeCast anyway. |
| DUSTCHECKPOINT | downgraded | Info | No funds locked (deposit cancellable). The freeze ends at maxEpochDuration (1 day live): a platform exit-only overdue settle ignores the bound and resets the checkpoint (test_XR_DUSTCHECKPOINT_overdueExitOnlySettleUnfreezes). On the live vault the owner is the manager, so a platform role must act. |
| SEEDGIFT, CURATIONSWAP | KEEP / downgraded | Info, Info | CURATIONSWAP needs the cold trusted factory owner (T6). |
| RESTINGINSTOP + S-1 | merged | Low | Exposure was policy-checked when placed; guardian flatten / sentinel cancelOrder mitigate; the executor never cancels on a breach. |
| SHORTFALLDEPOSITS | downgraded | Info | Excluding cancellable deposits is conservative; an over-reduce costs only the closing fee. |
| FLATTENSLIP | downgraded | Info | Live maxSlippage 1% < 3%; slippage only cancels. |
| STALESETTLE | KEEP | Low | Guardian closes the pair, a flat vault settles without a price read. |
| D-2 | downgraded | Low | Needs a sub-second read-node lag; only OPEN can duplicate (Gains allows one pending order per trade). |
| D-4 | KEEP | Medium | ~10 min of getLogs blindness; up to 4 copies within policy caps, no alert while blind. |
| D-5 | downgraded | Medium | A normal restart books the ~1 s fill and sends nothing (XR_D5 test 1). Real paths: a crash between broadcast and receipt (XR_D5 test 2), a store error surviving retryReads inside the wait, NEW-1. Worst case on a 100k vault: +150k duplicate exposure within policy; market risk, not theft. |
| NEW-1 (new) | CONFIRMED | Medium | main.ts:2020 releases the leader lease before the queues drain (:2022-2023); in a zero-downtime deploy the standby resumes in-flight signals while the old process executes them → duplicate order (XR_LEASE.test.ts: 2 ETH for a 1 ETH signal). |
| D-11 | downgraded | Low | Deterministic functional bug; loss is minAgentGas 0.001 ETH; no depositor funds. |
