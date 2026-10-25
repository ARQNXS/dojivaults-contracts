# Round 2, domain LIVE (3.7): liveness of exits

**Internal, AI-assisted review. Not an independent audit; nothing here may be presented as one.**

Scope: can every depositor get out (requestRedeem → settle → claim, with the trades unwound by a platform role) when
everything that can go wrong goes wrong at once, who must act, how long it takes and how many transactions it needs;
and the gas of every exit and settle path at the MAX_POSITIONS ceiling against Arbitrum's 32,000,000 gas limit.
Code: `contracts/src/gains/*` at 4ec6feb (the deployed factory [an earlier factory]).

Tests (all in `contracts/test/audit/gains/r2/`):

| File | What | Runs on |
|---|---|---|
| `LivenessHistoryFork.t.sol` | GR2-LIVE-01 PoC: settle / NAV gas per lifetime Gains index | Arbitrum fork, real gTrade v10 diamond, block 516,389,994 |
| `LivenessGasFork.t.sol` | gas of every exit and settle path at 20 positions, worst mixes, 17 distinct pairs, real feed cost | Arbitrum fork, blocks 516,396,267 / 516,400,392 / 516,402,546 |
| `LivenessStateMachine.t.sol` | one test per scenario row of section 2 (11 rows) | mock diamond (GovBase factory vault) |
| `liveness/LiveForkBase.sol`, `liveness/LiveLifecycleBase.sol` | copies of `GainsForkBase` / `LifecycleForkBase` with the fork block taken from `LIVE_FORK_BLOCK` | |

Run: `LIVE_FORK_BLOCK=<tip - 40> ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc forge test --match-path 'test/audit/gains/r2/Liveness*'`
(`LIVE_N` sets the history size, default 2,000; `LIVE_N_E2E` enables the 32M end-to-end run).

## Assumptions

| # | Assumption | Why |
|---|---|---|
| L-1 | The public RPC serves state only about 10 to 20 minutes back (5,400 blocks back failed with "historical state not available", 2,000 back answered). Each fork run is therefore pinned to the tip minus 40 blocks at run time (always ≥ 516,000,000) and the block is logged; the numbers above are from the runs named. A fixed pinned block cannot be re-run later on this endpoint. | METHOD: pin ≥ 516,000,000; the default block 516,380,000 failed for this reason. |
| L-2 | Plain fork tests are not "fork replays" in METHOD's heavy-lock sense; they ran under the forge lock only. | Conservative about the shared laptop, not about results. |
| L-3 | Chainlink feeds are `vm.mockCall`ed in every fork gas figure (as in rounds 1 and 2). A real read costs 27,675 gas per pair feed (latestRoundData + decimals, cold) and 16,652 for the sequencer feed (`test_GR2_LIVE_gas_realFeedReadCost`); for 20 distinct pairs that adds at most ~0.6M to any NAV path. Stated per row where it matters. | |
| L-4 | Gains v10 keeps no Chainlink feed per pair (`pairs(i).feed` is zero), so the distinct-pair test curates a feed contract per pair at 1 USD and answers Gains' oracle with that price. Gains accepted 17 of 20 pairs (pairs 21-23 refused the open); figures are for 17 and extrapolated to 20 per close. | |
| L-5 | The Gains trigger timeout is a Gains parameter: `marketOrdersTimeoutBlocks` = 200 L2 blocks on the live diamond (≈ 50 s at 4 blocks/s). | read on the fork |
| L-6 | Gains PAUSED / CLOSE_ONLY are emulated on the mock by reverting the diamond's calls (the fork emulation of round 1, `LC_LivenessFork`, is reused as evidence and not re-run). | |
| L-7 | "Realistic" combinations: any one Gains state × any one price fault × any role posture × the order states MAX_POSITIONS allows. A sequencer outage itself stops every transaction (Arbitrum's delayed inbox forces inclusion after ~24 h); the vault-side question is the grace period after it. | |

## 1. Who can do what on an exit (from the code)

| Step | Who | Reads prices / lists | Blocked by |
|---|---|---|---|
| `requestRedeem` | the holder (or an approved spender) | nothing (no price, no Gains list) | a deferred insider deposit of the same controller (`RequestPending`); the auto-claim of an older settled request if USDC refuses the transfer (vault or controller blacklisted) |
| `cancelRedeemRequest`, `claim` | holder / anyone for `claim` | nothing | USDC blacklist (claim transfers USDC) |
| settle, normal | manager or operator; not in a full stop or a loss breach | NAV (both band edges if deposits queued), both Gains lists | holding order, stale price on a pair with an open trade, `NavMoved` / `StaleCheckpoint` (anyone's `checkRisk` refreshes), `EpochTooYoung` (deposits only, 1 h), `InsufficientLiquidity` (no partial fill) |
| settle, redemption-only (daily-loss / drawdown breach) | manager, operator, owner, guardian, sentinel | as normal | as normal; overdue does NOT switch it to exit-only |
| settle, exit-only | any of the five in emergency; owner / guardian / sentinel once the epoch is overdue (not in a loss breach) | NAV (adverse edge), both lists | holding order, stale price on a pair with an open trade; partial fill only in emergency |
| no settle at all | — | — | a full stop (`triggerBreach` by owner / guardian / sentinel) outside emergency: `ReduceOnlyMode` for every role |
| `triggerEmergency` | guardian or owner at any time; **anyone** once the epoch is overdue with redemptions pending | best-effort trade list (try) | nothing |
| close / reduce / flatten | manager, agent, guardian at any time; owner, operator, sentinel in a breach or emergency; operator outside a breach: reduce ≤ shortfall + 2 % + 1 USDC | no price; `flatten` and the operator's `redemptionShortfall` read the Gains lists, `closeTrade` / `reduceTrade` / `flattenIndices` do not | Gains PAUSED; a pending market order on the same trade (one per trade); a pair Gains does not serve |
| `cancelTimedOut` | anyone | nothing | Gains PAUSED; USDC blacklist (refund transfer) |
| `exitEmergency` | guardian only | nothing | a pending redemption, or a last emergency settle that was a partial fill |

## 2. State machine: scenarios, actor, earliest time, transactions, what blocks

Notation: T = the epoch's `maxEpochDuration` from the last settle (1 h to 30 days per policy; 1 day on the live vault,
7 days in the tests). "fill" = Gains' oracle answering a market order (seconds). Depositor transactions count
`requestRedeem` and `claim` (the claim can be sent by anyone). Each row's test is in `LivenessStateMachine.t.sol`
(SM) or the fork files.

| # | Situation | Exit path and actor | Earliest | Txs (depositor / platform) | What blocks it, worst case | Test |
|---|---|---|---|---|---|---|
| N0 | Normal, idle covers | operator / manager settle | next settle (≥ 1 h if deposits queued) | 2 / 1 | — | existing suites |
| N1 | Normal, redemption > idle | operator reduces (≤ shortfall + allowance), fill, settle | minutes | 2 / 2-3 | operator removed and manager refusing → row H2 | `LivenessGasFork::redemptionShortfall…` |
| H1 | **Hostile owner full-stops** (`triggerBreach`), manager refuses | guardian `triggerEmergency` at once, or **the depositor** once overdue; then sentinel / guardian settle (exit-only) | guardian reaction; without it T | 3 (request, triggerEmergency, claim) / 1-2 | every settle mode reverts `ReduceOnlyMode` until emergency; the owner re-triggers right after a guardian `clearBreach` (no cooldown); the owner cannot undo an emergency | SM H1 (GR2-LIVE-02) |
| H2 | Owner `setOperator(0)`, manager refuses | sentinel / guardian / owner exit-only settle once overdue; if idle is short: InsufficientLiquidity outside emergency → depositor `triggerEmergency`, sentinel closes, fill, settle | T | 2-3 / 2-3 | no platform settle before T (`Unauthorized`); no partial fill without emergency | SM H2 |
| H3 | Hostile manager sends decoy closes (expected price Gains refuses) on every trade, in emergency | guardian / sentinel close in a gap after each Gains callback; settle pays idle only meanwhile | idle part: next settle; trade part: when the guardian wins a race | 2 per round / ≥ 1 per trade per attempt | the manager stays an exit caller in emergency and no platform role can remove it (`setManager` is owner-timelocked); flatten skips a trade with a decoy in flight; Timeboost express lane → unbounded. **Known** (GR1-04 residual, XREVIEW LC-02 KEEP Medium, GV-04); since the GR1-04 fix the settle runs, it only cannot pay the trades' part | SM M1 |
| A1 | Agent revoked, operator revoked | unaffected: guardian closes at any time, manager settles | as N0 / N1 | as N0 | — | SM A1 |
| L1 | Daily-loss / drawdown breach, deposits carried | redemption-only settle by any of the five roles (sentinel included); if idle is short, sentinel / owner / operator close (allowed while breached), fill, settle; carried deposits stay cancellable and an emergency settle refunds them | minutes | 2 / 2-3 | `NavMoved` if NAV moved > maxNavMoveBps (≥ 5 %) from the checkpoint: `checkRisk` ratchets it by that bound per hour (a −50 % move at 5 % needs ~14 h), or anyone's `triggerEmergency` at T; overdue alone does not help (the loss-breach branch wins) | SM L1 |
| E1 | Emergency, trades closable | guardian `flatten` per pair (or one `flattenIndices`), fill, sentinel settle | ~1 min (fill) + one Gains timeout (≈ 50 s) if a holding order is pending | 2 / 2-4 (if the settle ran before the fills: +1 depositor request per extra round; measured: a 95 % redeemer, 20 closes in flight at settle 1 → round 1 paid 63 %, round 2 full) | — | `LivenessGasFork::emergencyPartialFill…` |
| E2 | Emergency, a pair Gains no longer serves (close reverts) | settle pays idle pro rata (same USDC per share for every redeemer), unpaid shares returned | next settle | 2 per round | further rounds pay 0 until Gains serves the pair; `exitEmergency` refused (last settle partial) | SM E1 |
| P1 | One feed stale | flatten that pair (no price read), fill, settle (other pairs keep trading) | minutes | 2 / 2 | GR1-09 (known): every settle mode `PriceStale` while that pair has an open trade | SM P2 |
| P2 | Every feed stale, sequencer down or in its grace period (1 h to 1 day) | flatten every pair, fills (Gains' oracle is independent of the Chainlink feeds), the flat vault settles with every feed still dead (no price read without an open trade) | minutes after the sequencer accepts transactions again | 2 / 1 per pair + 1 | the outage itself (no transaction lands while the sequencer is down, except through the delayed inbox after ~24 h) | SM P1 |
| D1 | Gains layout the vault cannot read (GR1-08) | guardian `flattenIndices(all indices)` (one call, ≤ 24M for 20), fill; empty lists decode under any layout; settle | minutes | 2 / 2 | indices must come from events / `getTrade`; while closes are in flight `ordersPending` cannot decode → settle waits for the fills | SM D1 |
| O1 | A holding order (market open sent just before T) | anyone `cancelTimedOut` after 200 L2 blocks (≈ 50 s) or Gains fills it; then settle | +≈ 50 s | 2 / 1 + 1 | no new holding order once overdue or in emergency (`EpochOverdue`, `ReduceOnlyMode`) | SM O1 |
| O2 | **Gains PAUSED** with a holding order pending | none until Gains unpauses | unbounded (Gains governance) | — | `cancelOrderAfterTimeout` is `tradingActivatedOrCloseOnly`; settle `OrdersPending` in every mode including emergency, so not even idle USDC is paid. **Known** (GR1-45 Design, VENUE-LIVENESS.md); quantified here: 100 % of redemptions wait, whatever the idle balance | SM O1 |
| O3 | Gains PAUSED, nothing holding | settle runs (NAV reads still work); normal settle only if idle covers everything, else emergency partial fill from idle | next settle | 2 / 1-2 | trades cannot be closed until Gains resumes | fork `LC_LivenessFork::test_lc_gainsPaused_*` (round 1) |
| O4 | Gains CLOSE_ONLY | as normal: closes, flatten, cancels, `cancelTimedOut`, settle work; opens and SL updates refused | as N / E rows | as N / E | — | round 1 fork |
| U1 | USDC blacklists the vault | settle may run (moves no USDC) unless a holding open is pending (its timed-out cancel refunds USDC and reverts); every claim reverts; a `requestRedeem` whose controller has a settled claim reverts too (auto-claim) | when Circle lifts it | — | Circle; known GR1-45 | round 1 fork |
| X1 | A holder keeps the vault in emergency (1-unit request before each `exitEmergency`) | exits unaffected (the vault stays exit-only) | — | — | only the return to normal is delayed | SM X1 |
| K1 | **Long-lived vault: many Gains indexes ever used** | none once past the threshold | never | — | **GR2-LIVE-01**: every settle mode, NAV, flatten and openTrade walk every index the vault ever used; past ~7,700-13,200 lifetime trade indexes no settle fits 32M, permanently | `LivenessHistoryFork` |
| Z1 | Platform guardian and sentinel unavailable, owner and manager hostile, operator removed | none: a depositor can trigger emergency at T but no depositor can settle | never (until a platform role acts) | — | by design only the five roles settle (a stranger must not pick the moment); trust assumption on platform-key liveness, not a code defect | SM H1/H2 show the boundary |

Combined worst case that still ends: hostile owner + manager (full stop, decoys lost to the guardian on every race but
eventually won), operator removed, agent revoked, one feed stale, overdue epoch, a holding open in flight, Gains
ACTIVATED: T (if the guardian does not act earlier) + ≈ 50 s timeout + one flatten / flattenIndices + fills + one settle.
Depositor transactions: request, `triggerEmergency` (optional), claim, plus one request per partial-fill round.
Platform transactions: `triggerEmergency`, `cancelTimedOut` (anyone, ≤ 20), `flattenIndices` (1) or `flatten` (1 per
pair, ≤ 20), settle (1 per round). The combinations that do not end: Gains PAUSED with a holding order (O2), a USDC
blacklist (U1), a pair Gains will not close (E2, idle part only), an express-lane decoy manager (H3, idle part only),
both platform keys gone (Z1), and **any vault past the GR2-LIVE-01 threshold (K1)**.

## 3. Gas at 20 positions (Arbitrum fork, real diamond)

Execution gas of one top-level call (forge starts each cold); +21,000 + calldata per transaction. Headroom = share of
32,000,000 left. Feeds mocked (L-3). Mixes: "20T" = 20 open trades on BTC / ETH / SOL; "+20P" = 20 pending
UPDATE_LEVERAGE increases (hold nothing, so settle runs beside them, and GainsNav reads the trade for each; increaseTrade
cannot be used at the ceiling, updateLeverage has no ceiling check). These are fresh vaults: add GR2-LIVE-01's walk
(2,387 gas per lifetime trade index, 2,809 per lifetime pending index while any order is in flight) for an old one.

| Call | State | Gas | Headroom |
|---|---|---:|---:|
| totalAssets | 20T + 20P | 8,525,215 | 73 % |
| checkRisk | 20T + 20P | 8,550,492 | 73 % |
| venue() both edges | 20T + 20P | 13,914,956 | 56 % |
| **settle normal, deposits + redemption (favourable edge too)** | 20T + 20P | **14,718,057** | 54 % |
| settle normal, redemption only | 20T + 20P | 9,261,913 | 71 % |
| triggerEmergency | 20T + 20P | 459,255 | 98 % |
| settle exit-only (emergency), deposits refunded | 20T + 20P | 9,282,452 | 70 % |
| settle exit-only (overdue, sentinel, no emergency) | 20T + 20P | 9,328,625 | 70 % |
| settle exit-only, partial fill | 20T, 20 closes in flight | 8,983,336 | 71 % |
| settle exit-only, flat vault (round 2) | 0 | 424,303 | 98 % |
| requestRedeem | 20 positions | 160,341 | 99 % |
| claim (USDC + returned shares) | | 102,744 | 99 % |
| cancelRedeemRequest | | 79,624 | 99 % |
| triggerBreach (sentinel / owner), cancels 20 resting orders | 20 resting | 1,804,486 / 1,804,396 | 94 % |
| triggerEmergency (guardian), cancels 20 resting orders | 20 resting | 1,799,755 | 94 % |
| redemptionShortfall (view) | 20T + 10 pending closes | 522,752 | 98 % |
| redemptionShortfall (view) | 20T + 20 pending (19 closes + 1 partial) | 914,321 | 97 % |
| reduceTrade by the operator (shortfall path) | 20T + 10 pending closes | 1,932,306 | 93 % |
| closeTrade (guardian) | 19T + 1 pending | 1,409,083 | 95 % |
| reduceTrade (manager, collateral / guardian, leverage) | | 1,441,777 / 1,445,312 | 95 % |
| cancelTimedOut (anyone) | 20 positions | 189,019 | 99 % |
| **flatten, 20 ETH trades, one call** (slippage updated on every trade: Gains reports `maxSlippageP` 0 for market trades, so flatten always updates) | 20T one pair | **24,344,926** | **23 %** |
| flattenIndices, 20 ETH trades | | 23,925,570 | 25 % |
| flatten in batches of 7 | | 9,002,376 / 9,283,406 / 8,318,962 | ≥ 70 % |
| 17 distinct pairs: totalAssets | 17T | 7,779,768 | 75 % |
| 17 distinct pairs: flattenIndices (one call) | 17T | 20,517,932 (1.21M per close → ≈ 24.1M for 20) | 35 % (≈ 25 % at 20) |
| 17 distinct pairs: settle normal with deposits | 17T + 17P | 13,684,836 (+ ≤ 0.5M real feeds) | 56 % |
| 17 distinct pairs: settle exit-only (emergency) | 17T + 17P | 9,052,237 | 71 % |
| 17 distinct pairs: triggerEmergency | | 400,800 | 98 % |

Nothing on a fresh vault is above the 26M line (20 % headroom): the tightest is flatten / flattenIndices of 20 trades
at 23.9-24.3M (as in VERIFY-R2), and the heaviest settle is 14.7M (20 trades + 20 non-holding pending + deposits; the
round 2 table had 13.5M without the pending orders). Distinct pairs do not make the NAV paths heavier per trade here
(feeds mocked; real feeds add ≤ 0.6M). The figures change completely with the vault's age: section 4.

## 4. GR2-LIVE-01 (Critical): every NAV path, settle and flatten walk every Gains index the vault has ever used

**Location.** GainsNav.sol:79-80 (`_readTrades` / `_readPendingOrders` → `getTrades` / `getPendingOrders`, used by
`snapshot`), :124-131 (`blockingOrders` → `ordersPending`, settle), :332-340 (`readTrades` / `readPendingOrders`,
flatten), GainsVaultMath.sol:151 (`redemptionShortfall`), GainsVaultLogic.sol:241-245 (settle), :450 (openTrade),
:669-670 (flatten). Gains side: `TradingStorageGetters.getTrades` / `getPendingOrders` (verified facet source).

**Description.** Gains' getters do not index open trades; they scan:

```solidity
// getTrades: no early return when nothing is open
for (uint32 i; i < traderCounter.currentIndex; ++i) {
    if (s.trades[_trader][i].isOpen) { trades[currentIndex++] = ...; if (currentIndex == traderCounter.openCount) break; }
}
// getPendingOrders: returns early only when openCount == 0, else scans up to the newest open order
```

`currentIndex` grows by one for every trade or resting order the vault ever placed (and every market order for the
pending list) and is never reused. `MAX_POSITIONS` bounds open items, not this. Every call above pays one cold SLOAD
per index ever used.

**Evidence** (fork, real diamond, `LivenessHistoryFork.t.sol`, LIVE_N = 1,000; the counter is moved with `vm.store` at
Gains' TradingStorage slot 301 + 8, checked against `getCounters`; empty slots cost the same cold SLOAD as a closed
trade's):

| Measurement | Gas |
|---|---:|
| settle (redemption), flat vault: 0 → 1,000 lifetime trade indexes | 387,064 → 2,774,564 |
| totalAssets, same | 101,342 → 2,488,842 |
| `diamond.getTrades` alone at 1,000 | 2,407,778 |
| **per lifetime trade index (settle)** | **2,387** |
| settle with a close in flight, 1,000 lifetime pending indexes | 956,869 → 3,766,322 (**2,809 per index**) |
| redemptionShortfall / ordersPending, same | 2,509,451 / 2,463,650 |
| settle with 20 open trades placed after 1,000 indexes | 10,485,767 (fresh: ~8.07M) |
| place + cancel one resting limit order (manager): indexes consumed / Gains fee | 1 / 0 (621,579 + 189,259 gas) |
| cancelRedeemRequest at 1,000 | 62,524 (flat in N) |

Thresholds (32M, and the 26M 20 %-headroom line), from the per-index slope and the section 3 bases:

| Path | Base | Lifetime trade indexes at 26M / 32M |
|---|---:|---:|
| settle, flat vault (redemption / exit-only) | 0.39M | 10,730 / 13,243 |
| settle exit-only or redemption-only, 20 open trades | ~9.3M | ~7,000 / ~9,500 |
| settle normal with deposits, 20 open trades (+ pending) | ~14.7M | ~4,700 / ~7,200 |
| flatten (one call), 20 trades on one pair | 24.3M | ~700 / ~3,200 |
| any of the above with an order in flight | + 2,809 per lifetime pending index | lower |

**Impact.** Past the settle threshold no settle mode can run, ever: the emergency exit-only settle reads the same lists,
the clone is not upgradeable and the diamond address is fixed. Every share is locked permanently (requestRedeem is
accepted, nothing pays it; idle USDC included). Exits that read no list keep working (`closeTrade`, `reduceTrade` by
the manager / guardian, `flattenIndices`, `cancelTimedOut`, `cancelOrder`, the full stop through `tryReadTrades`), so
the trades can be closed, but the USDC they return cannot be paid out. Before that: `flatten` (one call) stops fitting
at ~3,200 lifetime indexes (batches and `flattenIndices` remain), `requestDeposit` and `openTrade` stop with settle.

**Likelihood.** Organic: certain for a vault that trades long enough. A strategy using 20 trade indexes a day reaches
the deposit-settle threshold (~7,200) in about a year, the exit-only one (~9,500 with trades open) in ~16 months;
100 a day: 2.5-3 months. Deliberate: the manager or the agent (an online key) can place and cancel resting limit orders at
gas cost only (no Gains fee): reaching ~13,000 costs about Σ(0.8M + 2,387·k) ≈ 2.1e11 gas ≈ 2.1 ETH at 0.01 gwei, and
the vault's own openTrade (it reads the same lists) stops the grind just under the flat-vault 32M line; with trades
open, or with a decoy close in flight at the top of the pending list (`closeTrade` reads no list, so the pending
counter can be grown without that self-limit, ~0.04 USDC gov fee each), settle crosses 32M well before. Impact:
permanent lock of all depositor funds × likelihood: certain on long-lived active vaults (time-bound), feasible for an
insider or a compromised agent → **Critical**. Live: vault [an earlier vault] has no shares and a 101 USDC cap; ALERT.md
lists the platform's interim controls.

**Fix direction.** Never call `getTrades` / `getPendingOrders` on a NAV, settle or flatten path. Keep the vault's own
set of open indexes: a permissionless `syncIndexes(maxSteps)` that walks Gains' counters from a stored cursor with
`getTrade` / `getPendingOrder` and records open items, bounded per call; value, settle and flatten from that set
(`getTrade` per recorded index, O(open items), the `flattenIndices` pattern). Until then: monitor `getCounters(vault, 0|1)`
per vault and wind a vault down well before 4,000 lifetime trade indexes.

PoC: `LivenessHistoryFork.t.sol::test_GR2_LIVE_01_navAndSettleCostGrowWithLifetimeIndexes` (passes: per-index cost
2,387 > 2,000), `test_GR2_LIVE_01_pendingWalkWithACloseInFlight`, `test_GR2_LIVE_01_limitPlaceAndCancelBurnsOneIndexEach_noFee`,
`test_GR2_LIVE_01_twentyOpenTradesAfterNIndexes_settleAndFlatten`; end-to-end `test_GR2_LIVE_01_settleOutOfGasAt32M_e2e`
(LIVE_N_E2E ≥ 13,300; see section 6 for its status).

## 5. GR2-LIVE-02 (Low): an owner's full stop holds every settle until the guardian acts or the epoch is overdue

**Location.** GainsVaultLogic.sol:226 (`hardStop() && !emergency` → `ReduceOnlyMode` for every settle mode),
GainsVaultGovernance.sol:217-222 (`triggerBreach`: owner, guardian, sentinel; no cooldown), :238-249 (`triggerEmergency`).

**Description / scenario.** The vault owner (a creator-side key, possibly hostile, T7) calls `triggerBreach`. From then
on no role can settle, outside emergency: not the operator, not the platform sentinel, not the guardian. The guardian's
`clearBreach` is undone by the owner's next `triggerBreach` (one transaction each). Redemptions wait until the guardian
switches to emergency (the owner cannot undo that, `test_LIVE_SM_H1`) or, without the guardian, until the epoch is
overdue, when the depositor can call `triggerEmergency` and a platform role settles. Numbers: live policy T = 1 day;
the policy allows up to 30 days, and the owner can loosen `maxEpochDuration` through the policy timelock.

**Impact × likelihood.** Temporary hold of every redemption, ≤ T (≤ 30 days), ended at once by the cold guardian;
needs a hostile owner. Low. Note for the runbook: the platform answer to a hostile owner's full stop is
`triggerEmergency` (guardian), never `clearBreach`. PoC: `LivenessStateMachine.t.sol::test_LIVE_SM_H1_hostileOwnerBreach_blocksSettle_depositorTriggersEmergencyAtOverdue`.

## 6. Status of the runs

- `LivenessStateMachine.t.sol`: **11 / 11 pass** (mock).
- `LivenessHistoryFork.t.sol`: **5 / 5 measuring tests pass** (layout, limit place + cancel, NAV / settle per index,
  pending walk at block 516,389,994; 20 open trades after 1,000 indexes at block 516,404,529: settle 10,485,767,
  totalAssets 10,207,962, flattenIndices of the 20 still 23,959,767 because it walks no list).
  **Not proven end to end:** `test_GR2_LIVE_01_settleOutOfGasAt32M_e2e` (LIVE_N_E2E = 13,400) failed at block
  516,404,529 on the public RPC itself ("failed to get storage … historical state not available" after ~25 minutes of
  fetching ~13,400 slots one by one), not on an assertion. The threshold rests on the measured linear cost (2,387 gas
  per index, two sizes: 0 and 1,000) and on Gains' verified source; with an archive RPC the e2e test is expected to
  pass as written. It is skipped by default.
- `LivenessGasFork.t.sol`: **8 / 8 pass** (blocks 516,396,267, 516,400,392, 516,402,546).
