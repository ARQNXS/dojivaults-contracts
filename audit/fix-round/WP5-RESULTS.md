# WP5 results: release verification (round 2 fix round)

Internal, AI-assisted verification of the release candidate on `fix/r2-release`. It is not an independent audit.

## 1. What was verified

The release candidate is `fix/r2-release`, branched from WP4 (`fix/r2-webapp`, 3d75366). Verification was read-only;
each change it made is its own commit with a test, listed here:

| Change | Commit | Why |
|---|---|---|
| Executor fixes P1, B1, B3, G1, G2 and the B2 hysteresis | 9a261cd … a2b5af3 | Uncross review of WP3 (section 3) |
| Foreign-order revoke (BOTH-02) and the launch limits (HL-01) | a398964, 668b621 | Stolen-key review, owner decisions (section 2) |
| HyperEVM big-block deploy (`send_planned.py`) | 3eeade6 | `forge script` cannot deploy past the 3M small-block header (section 6) |
| `revokeAgent` sends nothing to HyperCore (WP5-D14) | 00bc8d5, 6d031cf, f670b90 | HL testnet finding (section 6) |
| The agent's turnover budget reads the visible NAV (HL-INV-01) | 24b8efe | Stolen-agent invariant campaign (section 4) |

The work, by step of the brief:

1. **Fresh internal review.** Reviewers (internal, AI-assisted) who had not worked on WP1–WP4:
   - the stolen-key review (section 2);
   - the uncross review of WP3's executor follow-ups (section 3);
   - a check that every round 2 High and Medium fix is in the release and that its fix test fails without it (HL:
     11 contract and 17 executor reverts; gTrade: batches A, B, C and CFG). Two fix tests were too weak and got
     stronger companions (WP5-HLFIX-E01, WP5-GFIX-CFG01).
2. **Heavy runs:** Medusa, the stolen-agent invariant campaigns at 2,048 × 500, mutation of the WP1–WP3 lines, and
   Halmos (section 4).
3. **Fork tests:** every fork suite on the release, with the GR2-KEY-01 and GR2-LIVE-01 PoCs shown failing (section 5).
4. **HL testnet D14:** run by the owner; passed, one Info finding fixed (section 6).
5. **Compiler guard:** four one-job builds, and the bytecode record (section 7).
6. **Deploy rehearsal:** both venues on anvil forks with the production parameters (7884b20). The HyperEVM deploy was
   rehearsed again with the big-block procedure, end to end on forks of testnet and mainnet (`wp5-logs/bigblock/`).
7. **Runbook:** `docs/fix-round/DEPLOY-R2.md`.

## 2. Stolen agent key: what it can do and what bounds it

Step 1's stolen-key review (fresh reviewers, none of whom worked on WP1–WP4) found two Medium, two Low and two Info
items. A safety filter stopped the attack-style PoCs, so those were never written. Instead, each Medium now has
**defensive tests**: each one asserts that a limit holds at its edge (accepted just inside, refused just outside) on
the live platform policies:

- `contracts/test/audit/fix-round/WP5-KEY-BOUNDS-HL.t.sol`: 6 tests, all pass.
- `contracts/test/audit/fix-round/WP5-KEY-BOUNDS-GAINS.t.sol`: 2 tests, all pass.

**The setting.** The platform agent key is the executor's trading key. If it is stolen, the thief can send the same
orders the executor can, inside the vault's policy, until something stops them. They cannot withdraw, change the
policy, or move USDC out of the vault. The only way to hurt the vault is to trade badly on purpose: pay fees and
spreads again and again ("churn"), or buy high and sell low.

**The policies the numbers use**, both live on 2026-10-23:

| | Max leverage | Daily loss limit | Drawdown limit | Price band per order | Per-order cap |
|---|---|---|---|---|---|
| HL platform vault | 5x | 20 % | 50 % | 1 % | 2.5M |
| gTrade platform vault (Orbis) | 5x | 15 % | 50 % | 3 % | 250k |

Both venues also have:

- **Turnover budget:** 20x NAV of new positions per day. On HL it is a rolling 24 clock hours; on gTrade it is a
  bucket that refills over a day.
- **Off-chain circuit breaker:** it removes the key and pauses trading when more than 5x NAV is opened in an hour.

The two Mediums mean the bound is real but looser than the docs say. Neither lets the key take money out directly;
both let it destroy value faster or for longer than intended.

### WP5-HL-01 (Medium): churn on Hyperliquid can cost more than the "about 2 % a day" the code comment claims

**In plain words.** The thief opens and closes positions over and over. Each round trip pays the taker fee on both
sides (4.5 bps each at the base tier), the spread, and, for large orders, the price impact of walking the order book.
The turnover budget caps how often they can do it: 20x NAV per day. The comment in `VaultPolicy.sol` assumes about
10 bps per round trip, which gives "about 2 % of NAV a day". Orders big enough to walk the book cost more, about
16 bps per side, or roughly 40 bps per round trip with fees, and that gives about 8 % a day. Across a clock-hour
boundary, the rolling window lets up to about 40x NAV fit in a true 24 hours (WP5-HL-05, below), which doubles both
figures for the worst window.

**What it can cost.**

| Vault | Small orders (~10 bps per round trip) | Orders that walk the book (~40 bps) | Hard ceiling for one UTC day |
|---|---|---|---|
| 100k | ~2k a day (~4k in the worst 24 h) | ~8k a day | 20k (daily loss 20 %) |
| 1M | ~20k a day (~40k) | ~80k a day | 200k |

The per-order band caps any single fill at 1 % from mark. Filling at the edge of that band means eating the whole
book up to 1 %, which on BTC/ETH is far deeper than any order the policy allows, so the churn columns are the
realistic ones. The ceiling column is what the contract guarantees even if the realistic estimate is wrong.

**What bounds it** (each one asserted by a test in `WP5-KEY-BOUNDS-HL.t.sol`):

| Limit | Test | What it shows |
|---|---|---|
| Price band, 1 % from mark per order | `test_HL01_agentOrderPriceBoundedByTheOnePercentBand` | Exactly at the band: accepted. 1 tick past it: refused. Reduce-only orders too. |
| Turnover, 20x NAV per rolling 24 h | `test_HL01_agentOpensAtMostTwentyTimesNavPerDay` | 20 orders totalling 1,999,800 on a 100k NAV are accepted; the next 1,010 is refused, a sell as well. |
| Daily loss, 20 % | `test_HL01_dailyLossOverTwentyPercentStopsNewRisk` | -19.99 % still trades. -20.01 % makes the vault reduce only for the rest of the UTC day; closing still works. |
| The key's own order runs the loss check first | `test_HL01_agentOrderRunsTheLossCheckBeforeItIsSent` | With the day at -20.01 % and no keeper run, the key's order is not sent to HyperCore (OrderRefused) and the stop is recorded. The bound does not wait for a keeper. |

The off-chain circuit breaker (`server/test/wp3-breaker.test.ts`) removes the key once more than 5x NAV is opened in
an hour. A thief who stays under that pace still has the whole 20x per day.

**Is the bound too loose?** Yes, for the platform vault. A 20 % daily loss limit is far above what honest trading on
this vault needs, so the realistic churn cost (up to ~8 %) never reaches it.

**Status: decided and addressed (configuration plus a comment fix).** The new platform vaults launch with:

- the trading key's turnover at **10x NAV per 24 h**;
- a **10 % daily loss limit**;
- a **30 % drawdown limit**.

The new HL platform vault gets all three: the turnover is set by the owner right after launch, since a tightening
applies at once. The new Orbis gets the same daily loss and drawdown limits; the gTrade turnover is fixed at 20x in
the contract. Steps and checks are in `docs/fix-round/DEPLOY-R2.md` 7.1 and 7.2.

At 10x, churn costs about 1–4 % a day on the new HL vault (2–8 % in the worst 24 h). The ceiling for one day is the
10 % limit: 10k on a 100k vault, 100k on 1M. The comment on `DEFAULT_AGENT_TURNOVER_BPS` in `VaultPolicy.sol` is
corrected: it now gives 2 % at 10 bps, 8 % at 40 bps, up to twice that across a clock-hour boundary, and the daily
loss limit as the ceiling. It is a comment only, but the metadata hash in the bytecode changes, so
`RELEASE-BYTECODE.md` is regenerated (section 7).

### WP5-BOTH-02 (Medium): the daily stop lifts at midnight with the key still in place, so the loss can repeat day after day

**In plain words.** When the daily loss limit is hit, the vault goes reduce only, but the key is not removed. At the
next 00:00 UTC the stop lifts and the key can trade again. The off-chain breaker removes the key only for fast opening
(more than 5x NAV in an hour). A thief who churns slowly therefore never trips it, and can take up to the daily limit
every day.

**What it can cost.** The ceiling across days is the drawdown limit, 50 % from the peak share price, on both venues.
The stop is measured at a check, and the last day can overshoot it: the test shows a stop at -56.95 % after four days
of -19 %.

| Vault | Ceiling across days (drawdown 50 %, plus at most one day's overshoot) | At the realistic churn rate |
|---|---|---|
| 100k (HL or gTrade) | 50k, at most ~57k | 2–8 % a day on HL and 1.6–5.4 % on gTrade, so 7 to 30 days to reach it |
| 1M | 500k, at most ~570k | same rates |

The guardian is alerted on every loss pause (2 % in an hour, 5 % in 24 h), so in practice someone sees it on day 1.
Nothing on chain forces them to act.

**What bounds it** (asserted):

| Limit | Test | What it shows |
|---|---|---|
| Drawdown, 50 %, holds across days (HL) | `WP5-KEY-BOUNDS-HL`: `test_BOTH02_drawdownCapsLossesAcrossDaysAndDoesNotLiftAtMidnight` | Three days of -19 % (no daily stop) still trade. Day 4 crosses 50 % (DRAWDOWN). On each of the next three UTC days the vault is still stopped and the key's orders are refused. Only the owner's `resume()` lifts it; the key cannot, and neither can anyone else. |
| Drawdown, 50 %, holds across days (gTrade) | `WP5-KEY-BOUNDS-GAINS`: `test_BOTH02_drawdownCapsLossesAcrossDaysAndDoesNotLiftAtMidnight` | Four days of -14 % still trade. Day 5 (-52.96 %) refuses the key's open inline, before any risk check. On each of the next three days it is refused before and after the check. |
| Daily stop restarts from the new day's start (HL) | `test_BOTH02_dailyStopLiftsAtMidnightAndRestartsFromTheNewDayStart` | Records the current behaviour: the stop lifts at the new UTC day with the key kept, and the next stop fires just over 20 % of that day's opening price. |
| Daily loss inline (gTrade) | `test_GAINS_dailyLossOverFifteenPercentRefusesNewRiskInline` | -14.9 % accepted; just over 15 % refused before any `checkRisk`. |

**Is the bound too loose?** Yes. Half the vault over a few weeks is too much to leave to a human reading alerts.

**Status: fixed (the foreign-order revoke), and the drawdown limit lowered.** The on-chain loss stop still does not
revoke the key; D20 stands, by owner decision.

- **The record.** Every transaction the executor signs, with any key, is recorded before it is broadcast, in
  `VaultChain.send` and `sendLean`. The record is `executor_signed_txs` in the database, kept 30 days.
  - A record that cannot be written stops the broadcast.
  - Once the executor starts, nothing is broadcast before the database is attached.
- **The watch.** `server/src/risk/foreignOrders.ts` reads the order logs of every live vault from the shared log
  stream:
  - Hyperliquid: `OrderSent`;
  - gTrade: `TradeRequested`, `CloseRequested`, `ReduceRequested`, `IncreaseRequested`, `LeverageUpdateRequested`.
- **The revoke.** A log sent by the vault's current agent whose transaction is not in the record means the key is
  used elsewhere.
  - Where the vault's sentinel is ours, the sentinel calls `revokeAgent()` at the next stream tick. That is 15 s by
    default plus the receipt, so within about a minute, at any pace and any size. The guardian gets a "FOREIGN ORDER"
    alert.
  - Elsewhere it alerts only.
  - Orders of the manager or any other caller are not acted on.
  - A failed revoke is retried every tick, with one alert.
- **The switch-over.** The first start begins about two minutes past the head, so an order the old executor sent
  during the switch is not mistaken for a foreign one. Later starts resume from the stored cursor.
- **Tests:** `server/test/wp5-foreign-orders.test.ts`, 13 / 13.
  - An agent order outside the executor revokes, on HL and on gTrade.
  - Alert only where the sentinel is not ours.
  - A failed revoke is retried.
  - Our own recorded orders never revoke, nor do the manager's or a vault with no agent.
  - After a restart, a new watch on the persisted record still knows the earlier orders, and a foreign one still
    revokes.
  - VaultChain records the hash before the broadcast, and broadcasts nothing when the record is missing or cannot be
    written.
- **What a slow thief can now take.** At most what fits between their first order and the revoke: one stream tick
  of orders. That is bounded per order by the band and the per-order cap, and in total by the turnover budget.
- **The ceiling.** The ceiling across days is now the 30 % drawdown limit (owner decision, HL-01 above), and it is
  reached only if the watch is down.

### WP5-GAINS-03 (Low): the per-pair cap is per vault, so several vaults on one pair add up

**In plain words.** On gTrade, each vault may hold at most 1 % of a pair's skew depth on BTC/ETH/SOL. That cap keeps
a "double swing" against the vault unprofitable for a thief: it captures at most 1 bp, below the cheapest
round-trip of 2.1 bps. If one stolen key were the agent of k vaults on the same pair, the caps add up to k %, and the
swing pays at k ≥ 3.

**What it can cost.** Today it costs nothing: there is one platform gTrade vault (Orbis), and each vault has its own
agent binding. With k vaults it is about (k − 2) bps of the swung notional per swing, inside each vault's turnover
and daily loss limits.

**What bounds it.** The per-vault cap, each vault's turnover (20x NAV a day) and its daily loss limit.

**Status: known limit in this release** (owner decision). A factory-wide cap per pair is planned for a later version.
It is listed under the gTrade known limits on the security page ("Per market cap is per vault").

### WP5-BOTH-04 (Low / Info): the factories do not cap the risk limits a launcher chooses

**In plain words.** A third-party launcher can create a vault with a 20 % price band or a 100 % daily loss limit. If
that vault's agent key is stolen, only the turnover budget and the off-chain breaker bound it.

**What it can cost.** Up to the turnover-bounded churn of that vault, with no daily ceiling. It does not touch the
platform vaults, whose policies are set by us. Depositors see every vault's policy before depositing.

**Status: known limit in this release** (owner decision). Factory maximums are planned for a later version. It is
listed under both venues' known limits on the security page ("Launcher limits").

### WP5-HL-05 (Info): the rolling 24-hour turnover window can hold about 40x NAV in a true 24 hours

**In plain words.** The HL turnover window counts whole clock hours. 20x opened at 10:59 leaves the window at 11:00
the next day, so another 20x fits one minute later.

**Cost and bound.** At most double the per-day churn of WP5-HL-01 in the worst 24 hours, still under the daily loss
limit, which bounds it.

**Fix.** None needed; it is the gTrade bucket's "full bucket plus a day's refill" shape, documented there.

### Info: raising the leverage of an open trade spends no turnover and has no hold

**In plain words.** `updateLeverage` keeps the size and moves collateral back to the vault. It opens no new notional,
so there is nothing for the turnover budget to count.

**Cost and bound.** None beyond the existing ones: the policy's max leverage still applies, and the loss limits are
unchanged.

**Fix.** None.

## 3. Executor loss pause: hysteresis (WP5 B2, fixed)

The uncross review's B2 (Low) was a loss sitting right at a trigger: it ended and restarted the executor's loss pause
on alternate runs, with an alert each time and new opens allowed on every "recovered" run. The owner chose a
hysteresis. Commit `a2b5af3`:

- **The pause now ends at the first breaker run where every loss trigger is back below half its threshold** (1 h:
  1 %, 24 h: 2.5 %, drawdown: half), or at 00:00 UTC as before.
- **At 00:00 UTC the full thresholds decide**, as before, whether the new day is paused again.

Tests:

- `server/test/wp5-uncross-breaker.test.ts`: the B2 test (ten runs alternating -2.1 % / -1.9 %) changes from
  `it.fails` to a passing `it()`, with one pause alert and the gate never open.
- Three new tests: -1.1 % keeps the pause, -0.9 % ends it with one end alert, and at 00:00 UTC -1.5 % ends it on the
  full thresholds.
- Every server test file that touches the breaker passes: 91 / 91 in 4 files. tsc is clean.

The status text and the depositor, manager and security docs now say "until the loss is back under half the limit
that set it off".

## 4. Heavy runs

### Medusa (commits cd76543 harness, a602f05 logs)

The run is on the release contracts (`contracts/src` unchanged since 3d75366), under the heavy lock, with a 6 h cap per venue. No property failed, so there is no shrunk sequence and nothing to rate.

| Venue | Properties | Calls | Branches / corpus | Line coverage | Wall time |
|---|---|---|---|---|---|
| Hyperliquid (`MedusaConservation`) | 6 / 6 passed (conservation, reserve-backed, owed covered, claims, fairness, fees) | 7,787,401 | 9,473 / 261 | 74.9 % | 4 h 47 min, about 2 h of it fuzzing |
| gTrade (`ConservationMedusa`) | 40 / 40 passed (4 properties plus 36 assertion handlers) | 5,845,246 | 13,814 / 348 | 78.0 % | 3 h 00 min |

Harness changes for the release rules:
- **Hyperliquid:**
  - The agent is no longer a HyperCore API wallet. It trades only through the vault's `placeOrder`, under the turnover and order-rate limits. The simulator refuses the old direct-Core agent action.
  - The guardian's `writeOffBridge` and a rare `revokeAgent` are in the action set.
- **gTrade:** a `passHold` action waits out the 10-minute minimum hold.

Caveats:
- **Hyperliquid fuzzing time:** the machine went into standby twice during the run. Medusa's clock counted the standby time, so only about 2 h of the 3 h timeout was fuzzing. Branch coverage had stopped rising after about 1 h of fuzzing, at 9,473.
- **gTrade coverage:** it was still rising slowly at the end, from 13,767 branches at 2 h 30 min to 13,814 at 3 h.
- **No top-up run:** neither caveat changes the result, so no top-up was run.

### Stolen-agent invariant campaigns (commits 894f366 tests, 3392420 logs)

**The actor.** The conservation campaigns of both venues gained an actor that holds the platform agent key and uses it
as a thief would, with fuzzed arguments:
- **Hyperliquid:** `placeOrder` on any asset (in policy, out of policy, unlisted, spot), at any limit (the band edge,
  inside, outside, far off), with any cloid, reduce-only or not; open/close churn; `cancelOrder`; every
  permissionless call; settle and claims for others; 17 role-gated calls that must revert. The old direct HyperCore
  agent actions stay in the mix and must never be accepted.
- **gTrade:** open (every order type, in-policy pairs, the uncapped pair, out-of-policy pairs, fuzzed leverage,
  price, slippage, TP/SL), close and reduce any trade, increase, leverage update, TP/SL and trigger, cancels; every
  permissionless call; settle and claims for others; 22 role-gated calls that must revert. Gains fills each request at
  the oracle price moved against the vault by up to 300 bps, within the order's own slippage.

**What is asserted.** All earlier conservation invariants, unchanged, plus:
- SA1: the loss of each fill stays inside its bound (band, fees, spread; on gTrade the price push, fees and the
  liquidation and rounding floors);
- SA2: turnover, order rate, pair cap and minimum hold hold;
- SA3: the agent's loss in a UTC day stays under the daily loss limit plus that day's churn bound;
- SA4: no value reaches anyone else: the agent holds no USDC or shares, the vault never pays it, and no transfer,
  Core send, out-of-policy order or role-gated call goes through.

**Results.** 2,048 runs × 500 calls (1,024,000 calls each); the coverage tests show the actor really trades.

| Campaign | Wall time | Result |
|---|---|---|
| HL, platform vault policy | 2,587 s | pass |
| HL, tight policy | 2,454 s | pass |
| gTrade | 2,693 s | pass |

The first runs failed four times. Each failure was shrunk to a short sequence and kept as a replay test:
- **Three were harness bugs**, fixed in the harness: the HL simulator had no margin check; the gTrade mock let a
  leverage update through on a trade past its liquidation price, and left 1 wei of collateral at 779x.
- **One was real: HL-INV-01 (Low), fixed.** While a bridge was pending (up to 300 blocks, about 5 minutes),
  `_spendAgentLimits` sized the agent's turnover budget on the NAV from before the bridge. If HyperCore never
  credits the transfer, that NAV includes money that is gone. In the replay, 300k of a 400k vault was lost in
  transit: the budget read 400k, the agent opened 25x the true NAV in a UTC day against the 20x budget, and lost 52 %
  of it while the daily loss check saw 13 %.
  - It needs a stolen agent key and a lost bridge transfer in the same 5-minute window.
  - **Owner decision: fix now.** Commit 24b8efe: the budget reads the visible NAV (idle + Core equity) only, so a
    pending bridge can only tighten it for its few minutes. The daily loss check is unchanged, so a normal bridge
    cannot trip it.
  - Tests: `test_HLINV01_lostBridgeDoesNotInflateTheBudget`, `test_WP1_bridgeInFlightDoesNotCountInTheBudget` (it
    replaces the cross-review test that asserted the old read) and the campaign replay `test_replay_SA2_heavy`. All
    three fail on the unfixed code (`wp5-logs/hlinv01-unfixed.txt`) and pass on the fix, together with the replay
    campaign, WP5-MUT-HL, WP5-KEY-BOUNDS-HL and every hl-r2 fix suite (`wp5-logs/hlinv01-fixed.txt`).

**What the campaigns ran on.** `contracts/src` at 3d75366: before the WP5-D14 revoke change and the HL-INV-01 fix.
The agent's own `revokeAgent` call always reverts and the agent is never a HyperCore API wallet there, so D14 changes
nothing the campaigns exercise. The campaigns also ran at the default 512 runs in the full forge suite of compiler
guard 4, on the final source (section 7): all six stolen-agent campaign and replay contracts pass.

### Mutation (commit be88667)

**Contracts, every mutant on the WP1 and WP2 lines.** 1,246 generated. 22 on tuple declarations could not be built
into the schema; 2 on the old `_revokeAgent` burn are removed code (WP5-D14). 1,222 ran.

| | Run | Killed by the existing tests | Killed by the new WP5 tests | Equivalent | Boundary | Test gap | Chain id |
|---|---|---|---|---|---|---|---|
| Hyperliquid | 545 | 414 | 15 | 50 | 18 | 48 | 0 |
| gTrade | 677 | 523 | 13 | 52 | 19 | 69 | 1 |
| **Total** | 1,222 | 937 | 28 | 102 | 37 | 117 | 1 |

- **Score:** 83.7 % with the equivalents left out, 86.2 % with the new kill tests.
- Every survivor has a written reason (`wp5-logs/mut/survivors-contracts.txt`). The 117 test gaps are Low or Info; the
  largest group is 46 decode guards in GainsNav against a malformed diamond answer.
- The mutants on the old bridge branch of `_spendAgentLimits` are removed code since HL-INV-01.

**Executor, a sample of the WP3 lines** (no TypeScript mutation tool was installed; a line-filtered mutator wrote
3,148 mutants). The risk paths in full or at a quarter to a half, other files at 10 %: 1,022 sampled, 778 run within
the cap. Not reached: agentUpkeep, weightBudget, operator, parts of processor and executor (244).
- 529 killed, 20 more by the new tests, 23 equivalent, 203 not killed, 3 other.
- **Score:** 73.0 % with the new tests. The 203 are Low or Info (breaker timers, database store, monitor thresholds,
  submitter error returns, Gains min-hold retry timing, alert rate limits).

**New kill tests:** `WP5-MUT-HL.t.sol` (10 tests), `WP5-MUT-GAINS.t.sol` (7), `server/test/wp5-mut-breaker-facts.test.ts`,
`server/test/wp5-mut-proxy-orders.test.ts`. They pass on the release in compiler guard 4.

**Time:** 5 h 41 min of the 6 h cap.

### Halmos (commit be88667)

16 of 16 properties proved again; no timeout, no counterexample (30 minutes per property):
- **Hyperliquid:** P1, P2, P3, V3, V4, V5, H7d6. The control X1 still finds its intended counterexample, so V5 is not
  vacuous.
- **gTrade:** N0, C1–C6, N7, N8. The slowest were N8 (1,543 s) and N7 (1,327 s).

## 5. Fork tests

Commits 658c563 … 5c34a0d and 6c9f967 … d29bbbf; the report is `wp5-logs/forkport-report.md`. Arbitrum One at block
517,076,707.

**The original PoCs fail on the new code.** Each GR2-KEY-01 and GR2-LIVE-01 fork PoC was run unchanged on the fixed
vault, failed, and was then inverted into a passing `_fix_` test:
- **GR2-KEY-01** (KeysSkew ×3, XReviewKeySkew ×4): refused with "pair depth" at the first order past the 1 % cap. The
  largest size the vault takes is BTC 335.09k, ETH 141.93k, SOL 41.82k; the skew term at the cap is 16.75 / 7.10 /
  2.09 USDC, against 233 / 550 / 1,868 at the PoC's 1.25M.
- **GR2-LIVE-01:**
  - `twentyOpenTrades` fails "8327813 <= 12000000";
  - `pendingWalkWithACloseInFlight` fails "1109198 <= 4996432";
  - the lock-band test fails: the exit settle is flat in the counter at 757,893 gas, so there is no lock band;
  - two tests revert after about 1.02 billion gas.
  - `navAndSettleCostGrowWithLifetimeIndexes` still passed, but only through a storage write a real vault cannot
    reach. It is re-scoped: once synced, settle costs 421,006 gas, the same as with no lifetime indexes.

**Every fork suite passes:**
- all `*Fork*` suites except VerifyR2Fork: 177 passed, 0 failed, 1 skipped (`settleOutOfGasAt32M_e2e`, which needs
  `LIVE_N_E2E`);
- `test/gains/fork`: 4 / 4; KeysReferrerFee: 3 / 3;
- VerifyR2Fork, test by test: GV02 third parties, GV02 every trade type, gas of settle (13.74M with deposits, 57 %
  headroom) and of flatten (24.62M, 23 %), GV01 history (12 archive forks), GV01 a month of fees, and the GV01 live
  sample.
- **The live sample, at 300 and then 3,000 trader slots.** Most slots of the trader list read as zero (traders that
  were removed), so the first run (300 slots) held only 12 traders with open trades: 43 trades, size ratios 0.999783
  to 1.000609, no false positive. Compiler guard 4 ran 3,000 slots on the final build (`wp5-logs/guard4.verify-live.txt`,
  Arbitrum block 517,076,707, 1,363 s): 66 traders found, 51 with open trades, 1 skipped (too many lifetime indexes),
  113 v10 market trades with size ratios 0.999783 to 1.001993 (about 4x inside the bound either side), no false
  positive, and all 11 pre-v10 trades refused by the size check. It is still a sample, not every trader.

**What changed in the tests.** About 50 tests now wait out the minimum hold before the manager's exit. Tests that are
not about the pair cap raise it to 10 %. The KEY-01 fix test asserts at the factory's 1 % cap.

**Can a stranger grow the vault's unseen index range before a forced exit? No.** Triggers sent by anyone else (SL,
limit, TP, liquidation) are filed under the sender's own counters; the new LC_GriefFork test shows the vault's
counters do not move. Only the vault's own calls use its indexes, and each catches up first. `syncIndexes` is open to
anyone, and `checkRisk` and every settle catch up fully.

## 6. HL testnet (D14): passed, one Info finding fixed

The owner ran D14 on HyperEVM testnet on 2026-10-23, signing from keystores. The record is
`contracts/deployments/testnet-d14-record.txt` and the runbook is `docs/fix-round/TESTNET-D14.md`.

**Deploy.** The factory was deployed with the new big-block procedure: a plan on an anvil fork, then
`send_planned.py`. `forge script` against the chain itself cannot run the deploy, because its simulation is bounded by
the 3M small-block header. The same procedure is now in DEPLOY-R2 3.2, rehearsed on mainnet forks
(`wp5-logs/bigblock/`).

| Step | What it proves | Result |
|---|---|---|
| pin (no position) | The vault, a contract, sets its own HyperCore account mode with action 16: `userAbstraction` goes from "default" to "disabled". | PASS (7/7 checks) |
| perp 60 | moveUsd through action 7 | done |
| agent order 20 | The agent trades only through `placeOrder`: risk check first, IOC with the agent's cloid, filled under the vault, `agentFlow` counts it. | PASS (11/11) |
| pin-open | Re-pinning with a position open is accepted and leaves the position untouched; the mode stays "disabled". | PASS (8/8) |
| close via flatten | Reduce-only IOC; position 0 on the precompile and on Core. | PASS (4/4) |
| spot, revoke | Funds back to spot; agent 0. | done; see WP5-D14 |

NAV reconciles to the micro-USDC: 100 → 99.981012 USDC. That is fees 0.01755 plus price −0.00144.

**WP5-D14 (Info, fixed).** `revokeAgent()` sent CoreWriter action 9, `addApiWallet(burn, "dojipad")`. It created a
90-day API wallet entry, `0x6f4aa6343b4df8c4d5e03005037ec2e1bcc4f921`, on an account that had none.
- **No API wallet before the revoke.** `extraAgents` was `[]`: the vault's complete CoreWriter history from its launch
  block shows no action 9 before the revoke, and the record lists every action.
- **Where the address comes from.** It is the low 20 bytes of `keccak256(abi.encodePacked(vault, 67708586))`, the
  revoke block. Recomputed with `cast`, it matches. It is a hash output, not an address derived from a public key, so
  nobody holds a key for it; finding one would mean a 2^160 search. The entry can sign nothing.
- **Why it existed.** The burn was a leftover of the older API wallet path (HLR2-A01). Release vaults
  (`orderPath() == 1`, constant) never approve an API wallet, so it protected nothing. The release has no old-path
  vault to keep it for: older vaults run the older implementation, which this release does not change.
- **The fix.** `VaultLogic._revokeAgent` is EVM-only: it clears the agent and emits `AgentRevoked`. A call with no agent
  does nothing. No CoreWriter action is sent.
- **Tests.**
  - `HLR2-A01.fix.t.sol`, rewritten: every revoke path sends nothing (sentinel, guardian stop, emergency, repeated call),
    and the testnet derivation is reproduced.
  - `HlR2Encoding.t.sol`: action 9 never appears, across every entry point.
  - `HLPROXY.fix.t.sol`: the revoke sends no CoreWriter action.
- **Executor.** On a release vault (proxy), the monitor now treats any `extraAgents` row as foreign (test updated;
  older vaults keep the burn-slot rule, with a new test).
- **Bytecode.** Changed for VaultLogic, VaultGovernance, HyperVault, HyperVaultFactory and HyperVaultLens: they import
  `VaultLogic.sol`, so their metadata changes. VaultPolicy and the 7 gTrade contracts are unchanged.
  `RELEASE-BYTECODE.md` is regenerated in compiler guard 3 (section 7).

**What D14 ran on, against the release.** D14 ran on the bytecode from before 00bc8d5: the guard 2 build of 5afadb3.
The testnet deployment matches the guard 2 `RELEASE-BYTECODE.md` for all six HL contracts (`bytecode-check.py`
against testnet: ALL MATCH, `wp5-logs/d14-bytecode-vs-5afadb3.txt`).

The release then differs from it in one source file, `VaultLogic.sol`. `git diff --stat 5afadb3 00bc8d5` over
`contracts/src`, `foundry.toml`, `remappings.txt`, `lib` and `script/Deploy.s.sol` lists only that file, with 6
insertions and 11 deletions (`wp5-logs/d14-src-diff-5afadb3-00bc8d5.txt`):

```diff
 import {
-    AGENT_NAME,
     BPS,
 ...
     function _revokeAgent(VaultStorage storage $) internal {
         address old = $.agent;
-        address burn = address(uint160(uint256(keccak256(abi.encodePacked(address(this), block.number)))));
-        HyperCore.addApiWallet(burn, AGENT_NAME);
-        if (old == address(0)) {
-            emit Ev.AgentRevokeResent();
-            return;
-        }
+        if (old == address(0)) return;
         $.agent = address(0);
         emit Ev.AgentRevoked(old);
     }
```

The rest of the diff is the doc comment above `revokeAgent`.
- **Behaviour change.** `revokeAgent()` no longer sends action 9. With no agent set, it no longer emits
  `AgentRevokeResent` either; it does nothing. A revoke of a live agent still clears it and emits `AgentRevoked`.
  The callers and their role gates are unchanged, and so is the deposit hold that `HyperVault.revokeAgent` sets.
- **The five contracts.** VaultLogic's code changes. VaultGovernance, HyperVault, HyperVaultFactory and
  HyperVaultLens change only in their metadata hash, because each imports `VaultLogic.sol`. HyperVault and
  VaultGovernance also link the library by address, which the checker zeroes. None of their own sources changed.
- **No D14 rerun.** Every D14 step except the revoke ran through code this diff does not touch: pin, perp, the agent
  order, pin with a position, flatten and spot. The revoke's remaining behaviour is the same, minus the action that
  was the finding.
- **Compiler guard 3** shows these five rows move, VaultLogic's size by the removed code (22,678 → 22,366 bytes). It
  also shows GainsNav move by 16 bytes with none of its sources changed. That is the compiler, not this diff (section
  7). GainsNav is not on HyperEVM, so D14 does not involve it.

**The second change after D14: HL-INV-01 (24b8efe).** It also changes only `VaultLogic.sol`: `_spendAgentLimits`
drops the bridge-in-flight term from the NAV it reads (5 lines out, 3 comment lines in, the read unchanged). D14's
agent order went through that function with no bridge pending, where the old and new reads are the same number. No
D14 rerun is needed for it either; the bytecode of the same five contracts moves again (section 7).

## 7. Release bytecode

`RELEASE-BYTECODE.md` holds the hash and size of the 13 deployable contracts, from the one-job forced build of the
final tree (compiler guard 4). DEPLOY-R2 1.2 rebuilds the same tree and compares before anything is sent, and 3.2 /
3.3 compare the deployed code after.

| Guard | Head | What changed in the record |
|---|---|---|
| 1 | 3d75366 | First record |
| 2 | 3820d75 | All 13 hashes (a comment in `VaultPolicy.sol`, imported by all 13, changes their metadata); no size changed |
| 3 | 6d031cf | The five HL contracts that import `VaultLogic.sol` (WP5-D14); VaultLogic 22,678 → 22,366 bytes. **And GainsNav, 20,286 → 20,302 bytes, with no source change** |
| 4 | 24b8efe | The same five HL contracts again (HL-INV-01); VaultLogic 22,366 → 22,278 bytes. GainsNav back to 20,286 bytes, **the same hash as guard 2**. VaultPolicy and the other 6 gTrade contracts unchanged since guard 2 |

**Compiler guard 4, the final tree (head 24b8efe, clean, 308 files in one job).**
- Build: successful, solc 2,914 s. EIP-170 is exceeded only by 11 test harnesses; every release contract is under it.
- Forge suite: **1,226 passed, 0 failed, 41 skipped** (229 suites; `wp5-logs/guard4.suite.txt`). Guard 3's five
  failures (old tests that expected action 9) are fixed in f670b90.
- Server: 1,300 passed, 1 failed, 9 skipped in the parallel run; the 3 cluster files 8 / 8 serially; tsc clean
  (`guard4.server.txt`). The failure is `rpc.test.ts`, "a -32005 storm does not block Go live": it needs a request to
  hit the rate limit before a 700 ms timer lifts the storm, a timing assumption that missed under load. Not a
  regression: the file passes 5 / 5 alone, and the whole parallel run passes 1,301 / 1,301 on three reruns
  (`guard4.server-rerun.txt`). The only WP5 change in `rpc.ts` (9a261cd, `pinned`) is used by the proxy-order nonce
  check only, not by Go live. Noted as a flaky test (Info).
- VerifyR2Fork GV01 live sample, 3,000 slots: pass (section 5).

**GainsNav (Info, no action on the contract).** None of GainsNav's 15 sources changed between guards 2 and 3, and the
compiler settings are the same. Compiled alone from those sources, it is 20,302 bytes at 3d75366, 3820d75 and 6d031cf
alike, and line endings make no difference. What changed between the guards is the set of other files in the one
compiler job: new and edited tests. With via_ir, the output can depend on the rest of the job.
- **Why it matters:** the record holds only for the exact tree it was built from, tests and scripts included. Every
  test (Medusa, forks) ran on whatever build its tree produced; the guard 4 suite runs on the recorded build.
- **What changed:** DEPLOY-R2 1.2 now says to deploy only from the RELEASE commit with a clean tree, and to send
  nothing unless the local build says ALL MATCH. Any later commit to the release must not touch a `.sol` file under
  `contracts/src`, `contracts/test` or `contracts/script`.

## 8. Findings summary

No Critical or High. Every WP5 finding is fixed, or is a known limit by owner decision:

| ID | Severity | What | Status |
|---|---|---|---|
| WP5-HL-01 | Medium | HL churn can cost more than the "about 2 % a day" comment | Comment corrected; platform launch limits 10x / 10 % / 30 % (owner decision) |
| WP5-BOTH-02 | Medium | The daily stop lifts at midnight with the key still in place | Fixed in the executor: foreign-order revoke (a398964) |
| WP5-GAINS-03 | Low | The pair cap is per vault | Known limit (owner decision) |
| WP5-BOTH-04 | Low / Info | The factories do not cap a launcher's risk limits | Known limit (owner decision) |
| HL-INV-01 | Low | A lost bridge transfer inflated the agent's turnover budget for up to 5 minutes | Fixed (24b8efe, owner decision) |
| WP3 P1 | Medium | Proxy-order dead-nonce verdict | Fixed (9a261cd) |
| WP3 B1, B2, B3, G1, G2 | Low | Executor breaker and Gains watch follow-ups | Fixed (c677d8e, a2b5af3, e3c9c8f, af5de84, 98c698a) |
| WP5-HL-05 | Info | The rolling window can hold about 40x NAV in a true 24 hours | Documented, bounded by the daily loss limit |
| WP5-D14 | Info | `revokeAgent` created a keyless 90-day API wallet entry on HyperCore | Fixed (00bc8d5, executor 6d031cf) |
| WP5 GainsNav bytecode | Info | The recorded bytecode depends on the whole compiler job | DEPLOY-R2 1.2: deploy only the exact RELEASE tree, ALL MATCH first |
| Info | Info | A leverage raise spends no turnover and has no hold | None needed |
| Flaky server test | Info | `rpc.test.ts` storm test assumes a request is rate limited within 700 ms | Not a regression (section 7); passes on rerun |
| HLFIX-E01, GFIX-CFG01 | Info | Two round 2 fix tests passed without their fix | Stronger tests added |
| Big-block deploy | (process) | `forge script` cannot deploy on HyperEVM past the 3M header | `send_planned.py`, rehearsed (3eeade6) |

**Coverage limits, said plainly:**
- The executor mutation run reached 778 of 3,148 mutants, chosen by sample.
- The HL Medusa run fuzzed for about 2 hours (machine standby), and its coverage had stopped rising.
- The VerifyR2Fork live check samples traders; it does not walk all 16,121.
- The 2,048 x 500 invariant campaigns ran on the source before WP5-D14 and HL-INV-01. Both changes have their own
  tests, and the campaigns pass again at 512 runs in the guard 4 suite on the final source.

## 9. Go / no-go

Everything the brief asks for has run on the final tree, and nothing open blocks a deploy. Before anything is sent,
DEPLOY-R2 1.2 must say ALL MATCH against this record.

**GO** for the round 2 deploy from this commit, following DEPLOY-R2.md.
