# Gains contracts round 2: domain KEY (3.3 compromised key, worst case)

**Internal, AI-assisted review. Not an independent audit.**

Branch `audit/gains-r2`, worktree `dv-audit-gains-r2`, from `origin/main` 4ec6feb. This file answers: for each role, assuming
ONLY that key is stolen, the maximum USDC a thief can TAKE (to an address they control) and the maximum they can DESTROY
(value that leaves depositors without reaching the thief), how fast, what alerts fire, and what the owner / guardian /
sentinel can do to stop it. Magnitudes are for a 10k / 100k / 1M USDC vault under the LIVE policy shape (5x max vault
leverage, 15% daily loss, 50% drawdown, 3% slippage, 250k maxOrderNotional, 1 day epoch, 20% maxNavMove, 3% flatten).

## Bottom line

No single stolen key TAKES depositor USDC to a thief's address *through the vault contracts*: idle USDC only ever leaves as
trade collateral to the gTrade diamond (owed to `trade.user == vault`), to a redeemer pro-rata, or as fees within the
configured caps. The theft question that is real for the agent / manager is **indirect**: a hostile trader can route part
of the vault's trading loss to his OWN Gains account through skew price impact (GR2-KEY-01). TP/SL mis-set by the agent do
NOT hand the in-the-money PnL to the pool (GR2-KEY-02): Gains executes a far trigger as a market close, not at the trigger.
Every online key can DESTROY value (market risk, fees, griefing) bounded by the daily-loss breaker's *latency*, since
`openTrade` does not call `checkRisk` and the keeper calls it only every 5 min. The factory-owner / guardian key (the SAME
address on the live deployment, 0x1A7a…D7ff) is the one key that both rotates every vault's roles instantly and can redirect
the protocol fee recipient; it is a cold key by assumption T6.

## Live facts (block 516,381,860)

Factory [an earlier factory], vault [an earlier vault]: owner = manager = feeRecipient [platform wallet], agent [an earlier agent], operator
0xC111…B5F1, hosted, cap 101 USDC, ~22 USDC in (21.5 queued + 1 seed), 0 shares, no trades. Guardian = factory owner
0x1A7a…D7ff, sentinel 0xCB7c…9c9a, registrar 0xf3eE…5a2d. So nothing here is exploitable at any material size today; the
table is the shape of the risk once a vault holds real deposits.

## Per-key table

| Key | TAKE (to thief) | DESTROY @10k / 100k / 1M | Speed / binding limit | Alerts (executor) | Stop (exact call) |
|---|---|---|---|---|---|
| **Agent** (hot) | None via the vault. Indirect: GR2-KEY-01 skew capture to the thief's own Gains account — bounded by the skew term V·A/(200·depthUsd), see GR2-KEY-01; at the live caps the opposite account was net negative on all three pairs | Market risk up to 5x NAV + round-trip fees per cycle. Round trip measured 8.0 bps of notional (BTC/ETH), 13.6 bps (SOL): one full churn of 5×NAV = 0.40% / 0.68% of NAV. Per 10k/100k/1M: bounded by 15% daily-loss once checkRisk runs | Per tx: one order ≤ 250k notional, ≤ 5x. No on-chain throttle. `openTrade` never calls `checkRisk`; the 15% daily-loss breach bites only when the keeper's checkRisk runs (every 5 min) or at the 1-day settle; 50% drawdown then needs owner `resume()` (24h cooldown) | Sentinel/owner/guardian `triggerBreach` (revokes agent, cancels resting opens), `revokeAgent`, `setTradingPaused(true)`. Automatic: only if a Gains trading *delegate* is set (not a trade pattern) |
| **Manager** | As agent + indirect skew | As agent + flatten at ≤3% slippage + settle timing | Replaced by owner `setManager` behind a ≥1-day timelock (live 2d); on the live vault owner==manager | reduceRate alarm counts the manager's reduces/closes | Guardian `triggerBreach` / `triggerEmergency`; owner queues `setManager` |
| **Operator / keeper** (hot) | None | Fee grind via tiny reduces (GR1-11), only while `redemptionShortfall()>0`; reduce capped at shortfall+2%+1 USDC | ~1 USDC/s of NAV across 20 trades (GR1-11), gains the thief nothing | reduceRate alarm fires on the 11th `ReduceRequested`/`CloseRequested` from one caller in 10 min (notification) | Owner/guardian/sentinel `revokeOperator` |
| **Sentinel** (hot) | None | `triggerBreach` then `flatten` at the worst moment crystallises a temporary loss; expectedPrice/slippage griefing (gov fees) | Instant | A guardian/owner `flatten` is not alarmed as the sentinel's; breach itself is alerted by the registry indexer | Factory owner `setSentinel` (instant, every vault); guardian `clearBreach` |
| **Registrar** (hot) | None — cannot bind an agent without the owner's timelocked `setAgent` (`_storeAgent` checks `platformAgentFor(agent)==vault`) | Launch griefing (GR1-22) | Instant for new reservations only | — | Factory owner `setAgentRegistrar` |
| **Owner** (vault) | Fee raise within hard caps, only after the timelock (running epoch charged at the old rate); `setOperator` to a thief is instant (then reduces capped) | Policy tightening into a breach, pauses, `leaveHosted`, deposit-cap | Loosening timelocked; tightening instant | Registry indexer warns on `Queued` governance calls | Guardian `cancel(id)`, `revokeOperator`. Owner cannot exitEmergency/clearBreach/remove guardian/sentinel |
| **Factory owner == Guardian** (cold, 0x1A7a…D7ff live) | `setProtocolFeeRecipient` → future protocol fee shares to the thief; pending-`allowAsset` feed swap (GR1-40) | `setGuardian`/`setSentinel` rotation instant on EVERY vault; `triggerEmergency` + flatten anytime; `exitEmergency`/`clearBreach` | Instant, fleet-wide | **No alert** on GuardianSet/SentinelSet/OperatorSet/ProtocolFeeRecipient | None on-chain. Cold-key trust boundary (T6). Note: on live these are ONE key |
| **Launcher** | None | None beyond its own vault | — | — | Factory owner `setLauncherAllowed(false)` |

All numbers come from the PoC run in §Measured (fork, block 516,388,500).

## Findings

### GR2-KEY-01 (Low, design) — Skew impact can route vault loss to an opposite Gains trader
A thief with the agent or manager key opens vault trades on a pair while holding an opposite position on his own Gains
account. Gains v10 skew price impact (`PriceImpactUtils.getTradeSkewPriceImpactP`: marginal `≈ sizeToken/(4·depth)`) marks
the pair as the vault's size enters and leaves; the thief's opposite trade is filled on the better side of that mark. The
value the vault loses ABOVE its own round-trip cost (fees + spread + its own impact) is what the thief's account can
receive — the rest goes to Gains LPs. No policy field limits per-trade leverage or ties the vault's size to pair depth, and
`openTrade` never calls `checkRisk`, so the move is not interrupted within the cycle. PoC
`KeysSkewForkTest.test_GR2_KEY_01_*` asserts, per pair on the real diamond, that the extra vault loss is bounded by the
skew term (96.7% to 99.98% of it) and that the opposite account was net negative at the live caps (§Measured).
Mitigations (owner's choice): a per-trade leverage/notional cap scaled to the pair's skew depth; an executor alarm on
vault-notional vs pair `getPairSkewDepth`; the guardian flattens on an anomalous impact.

### GR2-KEY-02 (checked, not a finding) — Mis-set TP/SL do NOT hand ITM PnL to the pool
Gains executes a TP/SL EXACTLY at the trigger only when the oracle range since the trigger's last update actually reached
it (`TradingCallbacksUtils._validateTriggerCloseOrderCallback`: `low<=trigger<=high`, lookback from
`tp/slLastUpdatedBlock`). A TP set just past the open on a deep ITM long, or an SL set just inside the market, is therefore
NOT_HIT or executes at the current oracle price (a market close), never at the far trigger. ROUND1's `LC_LimitStopFork`
tested the wrong-side cases; this round `KeysTpSlForkTest.test_GR2_KEY_02_*` adds the in-the-money TP/SL case the brief
asked for and asserts the vault's payout equals a market close. So the agent cannot gift the ITM PnL to the pool through a
chosen trigger.

### GR2-KEY-03 (checked, not a finding) — No referrer is ever attached to the vault
`openTrade` passes `referrer = address(0)` (GainsVaultLogic.sol:484). No other vault path sets one, and Gains'
`registerPotentialReferrer` is `onlySelf` so a third party cannot attach his address as the vault's referrer. PoC
`KeysReferrerFeeForkTest.test_GR2_KEY_03_*` asserts `getTraderActiveReferrer(vault)==0` after open and increase and that a
third-party call cannot change it. So a thief cannot skim referral rebates on the vault's fees.

### GR2-KEY-04 (measurement) — Fee churn per cycle vs keeper interval
The "DESTROY per hour" ceiling for the agent/manager/operator is set by how many open+close (or reduce) cycles fit before
`checkRisk` trips the 15% daily-loss breaker. `KeysReferrerFeeForkTest.test_GR2_KEY_04_*` measures the Gains round-trip cost
per 250k cycle. Keeper `checkRisk` cadence: `KEEPER_INTERVAL_MS=300000` (5 min), and it only sends when a metric is near a
limit, so the breaker can lag a burst of churn.

## Measured (fork, real gTrade v10 diamond, block 516,388,500; 9 / 9 tests pass)

Run in a scratch copy (`contracts/` at HEAD plus the Keys files) because an untracked file of another domain
(`test/audit/gains/r2/GainsSideForkBase.sol`, address checksum error) broke compilation of the shared worktree at the time.
The public RPC prunes state after roughly 9,000 blocks: block 516,380,000 was already unavailable and the tests are
pinned to 516,388,500, so they must be re-pinned to a recent block when re-run.

**GR2-KEY-04: round-trip cost (vault open + close at one oracle price, 25x)**

| Pair | Notional | Vault loss | bps of notional |
|---|---|---|---|
| ETH | 250k (one order) | 199.995 USDC | 8.0 |
| ETH | 5 × 250k | 999.92 USDC | 8.0 |
| BTC | 5 × 250k | 999.97 USDC | 8.0 |
| SOL | 5 × 250k | 1,699.88 USDC | 13.6 |

DESTROY by churn, per full turnover of the 5x limit: 0.40% of NAV (BTC/ETH), 0.68% (SOL). The breakers do not limit
this per transaction. They act only when `checkRisk` runs (the keeper evaluates every 5 min and sends near a limit, or
after a fill / NAV-move trigger). So the bound is the daily loss (15%) plus whatever churn fits in the gap before the
next checkRisk, then the drawdown (50%) until the owner's `resume()`:

| Vault NAV | 15% daily-loss breaker | 50% drawdown ceiling | Orders per full 5x turnover (250k max each) |
|---|---|---|---|
| 10k | 1,500 USDC | 5,000 USDC | 1 |
| 100k | 15,000 USDC | 50,000 USDC | 2 |
| 1M | 150,000 USDC | 500,000 USDC | 20 (= MAX_POSITIONS) |

On top of this sits market risk: up to all collateral posted, a 5x-NAV directional bet. That is a loss to depositors,
not a gain for the thief.

**GR2-KEY-01: skew-impact bound (vault 5 × 250k long, one opposite 1.25M trade held across the vault's round trip, all
fills at one oracle price)**

| Pair | Skew depth (USD, live) | Extra vault loss vs. no opposite trade | Skew term V·A/(200·depthUsd) | Extra / term | Opposite account net |
|---|---|---|---|---|---|
| BTC | 32.60M | 239.62 USDC (1.9 bps of V) | 239.67 | 99.98% | −760.38 USDC |
| ETH | 13.76M | 567.72 USDC (4.5 bps of V) | 567.91 | 99.97% | −432.25 USDC |
| SOL | 4.07M | 1,855.95 USDC (14.8 bps of V) | 1,919.18 | 96.7% | −329.50 USDC |

Reading: the extra loss the vault suffers because someone trades the other side while the vault's size is in the pair
is bounded by the skew term. At the live caps the opposite account's own Gains costs exceeded what it captured on every
pair. The vault-side term, however, grows with the vault's notional in one pair relative to that pair's skew depth,
and the policy only bounds the notional by 5×NAV and 250k per order. That relationship is what the owner should cap.
This review did not search for parameters where the opposite side comes out ahead.

**GR2-KEY-02: in-the-money TP / SL (ETH long 250k at 25x, price +8%)**

| Case | Result | Vault received |
|---|---|---|
| Control: market close at C | executed | 29,798.004 USDC (collateral 10,000) |
| TP set 0.1% past the open (far below market), triggered, oracle range around C | executed, not exact, at oracle C | 29,798.003 USDC: equal to the market close |
| SL set 0.5% above the open (far below market), triggered | cancelled by Gains (reason 11); trade stays open | n/a, nothing lost |

**GR2-KEY-03:** `getTraderActiveReferrer(vault) == 0` after open and increase. A third party's
`registerPotentialReferrer(vault, thief)` reverts (`onlySelf` on the facet) and leaves it at zero.

## Findings table

| Id | Title | Severity | Impact × likelihood | PoC | Run |
|---|---|---|---|---|---|
| GR2-KEY-01 | Vault notional per pair is not bounded against Gains skew depth: an opposite trader adds an extra vault loss up to V·A/(200·depthUsd) | Low (design) | Measured 1.9 to 14.8 bps of the vault's notional per round trip with an equal opposite trade; opposite account net negative at the live caps × needs the agent or manager key plus outside capital | `KeysSkewFork.t.sol::test_GR2_KEY_01_skewTermBoundsExtraVaultLoss_{BTC,ETH,SOL}` | passed |
| GR2-KEY-04 | The daily-loss breaker trips only on `checkRisk`, not on `openTrade`: churn by a hostile trader key is bounded by the keeper's cadence, not per transaction | Low | 0.40% (BTC/ETH) / 0.68% (SOL) of NAV per 5x turnover; 15% per day plus the keeper-gap overshoot, then 50% drawdown × online key compromised and no human reaction | `KeysReferrerFee.t.sol::test_GR2_KEY_04_feeCostPerChurnCycle_ETH` | passed |
| GR2-KEY-05 | No automatic on-chain response to a hostile trader key; no caller-attributed alert on TradeRequested / LeverageUpdateRequested / SlTpUpdated / OrderCancelled; no alert on OperatorSet / GuardianSet / SentinelSet / protocol fee recipient | Low (executor) | Detection depends on a human reading the alert channel × any online-key compromise | design; cites server/src/venues/gains/monitor.ts, reduceRate.ts, risk/watcher.ts, tenants/registry.ts | n/a |
| GR2-KEY-02 | (checked, sound) A mis-set TP/SL cannot hand in-the-money PnL to the pool | — | — | `KeysTpSlFork.t.sol::test_GR2_KEY_02_*` | passed |
| GR2-KEY-03 | (checked, sound) No referrer can be attached to the vault | — | — | `KeysReferrerFee.t.sol::test_GR2_KEY_03_*` | passed |

## Mitigations per row (owner's choice)

- Agent / manager (KEY-01, KEY-04): a policy cap on vault notional per pair as a fraction of `getPairSkewDepth`; call
  `checkRisk` (or a cheap daily-loss check) inside `openTrade` / `increaseTrade`; executor alarm on order rate per
  caller and on vault notional vs skew depth; the sentinel's `revokeAgent` wired to that alarm. Stop calls:
  sentinel/owner/guardian `triggerBreach()`, `revokeAgent()`, `setTradingPaused(true)`.
- Operator: unchanged (GR1-11 alarm); `revokeOperator()`.
- Sentinel / registrar: factory owner `setSentinel` / `setAgentRegistrar`; alert on their use.
- Factory owner == guardian (live): split the two roles onto separate cold keys (ideally a Safe, see the Safe runbook);
  alert on GuardianSet / SentinelSet / ProtocolFeeRecipient changes.

## GR2-KEY-01b: extraction bounds

This section is fix-round input for the GR2-KEY-01 fix (ROUND2.md, High). Since round 2 rated it High, the "Low (design)"
in the findings above is the first measurement, kept as history. The section answers one question: with the KEY-01b
patch in place, how much can a thief who holds the agent or manager key take per day, and per vault?

The patch it assumes: the per-pair factory cap, the turnover budget of 20 × NAV per day, the 10-minute minimum hold, and
the loss gate inside openTrade. On top of that it assumes a circuit breaker that is not yet in code (defined below).

The model is fixes/GR2-KEY-01b/bounds/model.py (not included) and its output is
model-output.txt (not included). It is calibrated on the fork runs in
run-fork.txt (not included).

### The route and the formula

The thief's best route is the double swing (FIX-DESIGN.md A1):
1. The vault holds +V on a pair.
2. He opens A against it on his own Gains account.
3. The vault closes and reopens −V.
4. He closes.

Gains' skew impact (`PriceImpactUtils`, divider 2; D is the pair's 1 % skew depth in USD) gives these amounts per swing:

| Quantity | Formula |
|---|---|
| Capture | 2·V·A / (200·D). Per unit of A: r = V/(100·D), so r in bps = 100·V/D. At V = f·D that is **f/100 of A**: 1 bp at a 1 % cap, 5 bps at 5 %, 10 bps at 10 % |
| Thief profit | A·(r − c), where c is his round-trip cost per unit of A |
| Vault loss | V·c_v + capture. Only the capture reaches the thief; V·c_v goes to Gains |
| Vault size on the pair | V = min(f·D, 5·NAV). The cap and the policy's 5x leverage both bind; the 5x bound is why small vaults are safe at any cap |
| Turnover | Each swing opens one V, which spends the turnover budget |

The model is checked against the fork (ETH, counter-trade flag, no fee tier):

| Cap | V = A | Model | Fork | Source |
|---|---|---|---|---|
| 5 % | 687k | +64 USDC | **+63.35 USDC** | KEY-01 tree |
| 1 % | 137k | −41 USDC | **−41.00 USDC** | KEY-01b tree |
| 1 % | V 138k, A 125k | −37 USDC | **−37.47 USDC** | Revision 2 tree, block 516,927,412 (run-fork-rev2.txt (not included)) |
| 5 % | V 692k, A 651k | +60 USDC | **+59.95 USDC** | Same block |
| 10 % | V 1.385M, A 1.309M | +763 USDC | **+761.71 USDC** | Same block. Plain, no tier: **+238.53** (model +236) |

### Thief cost c per unit of A (bps)

These are the FIX-DESIGN.md A1 numbers. The counter-trade costs are measured on the fork: 3.97 bps, from capture minus
PnL.

| Thief account | BTC / ETH | SOL |
|---|---|---|
| Counter trade + top fee tiers (worst case) | **2.13** | **1.5** (cumulative-volume impact excluded) |
| Plain trade + top tiers | 3.6 | 3.75 (excluded as above) |
| Counter trade, no tiers | 3.97 (measured) | 4.0 |
| Plain, no tiers | 8.0 (measured) | 13.6 (measured) |

Margin per swing, r − c, at V = f·D (worst-case account; best pair in bold):

| Cap f | Capture r | BTC / ETH counter + tiers | SOL counter + tiers | Plain + tiers (any pair) | Verdict |
|---|---|---|---|---|---|
| 1 % | 1 bp | −1.13 | −0.5 | −2.6 / −2.75 | **Negative for every account and pair** |
| 1.5 % | 1.5 bps | −0.63 | 0 | −2.1 | Break-even on SOL |
| 2 % | 2 bps | −0.13 | **+0.5** | −1.6 | Positive on SOL |
| 5 % | 5 bps | **+2.87** | +3.5 | +1.4 / +1.25 | Positive. The plain leg is unbounded by the skew |
| 10 % | 10 bps | +7.87 | **+8.5** | +6.4 / +6.25 | Positive. Even plain without tiers is +2 on BTC / ETH |

**Break-even cap per pair** = the cheapest opposite round trip in bps, read as a percentage of depth:
- **BTC and ETH: 2.13 %.**
- **SOL: 1.5 %.**

### Limits on swings per day

- **Turnover budget:** at most 20·NAV/V swings per day. The first 24 hours can reach 40·NAV/V, because the bucket starts
  full and also refills.
- **Daily loss (15 %, KEY-01 `_lossGate`, checked before each new risk):** at most 0.15·NAV / (vault loss per swing).
- **The 10-minute hold does not bound swings.** A take profit or stop loss set past the market is closed by Gains' bots
  at the next trigger (next subsection).
- **Positions:** MAX_POSITIONS (20) × 250k per order, so V ≤ 5M. This never binds before 5·NAV does.

Assumed **circuit breaker**. These are the **proposed executor defaults for fix round WP3** (FIX-DESIGN.md), not yet
code. It would use existing powers: the executor alarms and the sentinel calls `revokeAgent()` and
`setTradingPaused(true)`. It trips on any of:
- vault loss over 5 % of NAV in a rolling 24 h;
- vault loss over 2 % in a rolling 1 h;
- drawdown from the peak share price over 10 %;
- opened notional over 5 × NAV in a rolling 1 h.

It detects within two keeper intervals (10 min). A thief who stays under it costs the vault at most 5 % per day. A burst
inside the 10 minutes is bounded only by the code limits. Per vault, the breaker allows a slow drip up to 10 % drawdown
plus one burst of at most the 15 % daily loss, so **25 % of NAV** in vault loss. Without the breaker the limit is the
50 % drawdown (reduce-only until the owner resumes).

### Maximum thief extraction (worst-case account: counter trade + top tiers on every pair)

Background skew assumed at 1 % of D in the vault's direction. Plain thief trades are assumed up to 5M (an **estimate**:
Gains' open-interest limits were not read, and SOL's cumulative-volume impact on a 5M plain trade is left out, so the SOL
cells overstate). Depths are live at block 516,920,630.

| NAV | Cap | Best route (per swing) | Swings / day | Binds | **Per day** (code limits) | Per day (with breaker) | **Per vault** (no breaker → 50 % DD) | Per vault (with breaker) |
|---|---|---|---|---|---|---|---|---|
| 10k | 1 % | none: V ≤ 50k, r ≤ 1.19 bp on SOL, below c = 1.5 | – | – | **0** | 0 | **0** | 0 |
| 10k | 5 % | none (same: 5x NAV binds before the cap) | – | – | **0** | 0 | **0** | 0 |
| 10k | 10 % | none (same) | – | – | **0** | 0 | **0** | 0 |
| 100k | 1 % | none: r = 1 bp | – | – | **0** | 0 | **0** | 0 |
| 100k | 5 % | SOL V 209k: +713, vault −2,910 | 5.2 | daily loss | **3,675** | 1,225 | **12,248** | 6,124 |
| 100k | 10 % | SOL V 418k: +3,516, vault −6,029 | 2.5 | daily loss | **8,748** | 2,916 | **29,159** | 14,580 |
| 1M | 1 % | none: r = 1 bp | – | – | **0** | 0 | **0** | 0 |
| 1M | 5 % | ETH V 712k: +945; SOL V 209k: +713 | 20.0 + 27.5 | turnover and daily loss | **38,517** | 13,515 | **135,152** | 67,576 |
| 1M | 10 % | SOL V 418k: +3,516 | 24.9 | daily loss | **87,478** | 29,159 | **291,594** | 145,797 |

With an account that has **no fee tiers** (counter trade only; the fork case), the same table reads:
- **0 at 1 %** for every vault size;
- 5 %: 100k → 240 per day (turnover binds), 1M → 2,472 per day;
- 10 %: 100k → 1,320 per day, 1M → 27,303 per day;
- per vault (no breaker): 3.1k and 44k at 5 %, 13.4k and 142k at 10 %.

**Reading.**
- **At 1 % no vault size and no account extracts anything.** The route loses on every swing, so the turnover budget,
  the loss gate and the breaker are left bounding pure destruction (below).
- **At 5 % and 10 % extraction is positive from about 100k NAV upwards.** It is the larger the deeper the vault: up to
  about 39k per day (5 %) and 87k per day (10 %) on a 1M vault, and 135k / 292k over the vault's life without a breaker.
  The breaker cuts that by half to two thirds, but not to zero.
- **10k vaults extract nothing at any cap.** Their 5x leverage (50k) is below 1.2 % of SOL's depth.

**Destruction** (not extraction; the thief loses money doing it) is bounded the same way at any cap: at most 20 × NAV ×
the vault's round trip, so 1.6 % (BTC / ETH) or 2.7 % (SOL) of NAV per day from churn. A thief willing to pay for it
can add the routed capture to that, up to the 15 % daily loss.

### Capacity per pair at each cap (live depths, block 516,920,630)

"Max open notional" is the vault's total on the pair, f × D. "Fully deployed NAV" is the largest vault that can put its
whole 5x leverage on that pair alone, f × D / 5.

| Pair | 1 % skew depth (USD) | 1 %: notional / NAV | 5 %: notional / NAV | 10 %: notional / NAV |
|---|---|---|---|---|
| BTC (pair 0) | 33.30M (398 BTC) | 333k / 66.6k | 1.66M / 333k | 3.33M / 666k |
| ETH (pair 1) | 14.25M (5,738 ETH) | 142k / 28.5k | 712k / 142k | 1.42M / 285k |
| SOL (pair 33) | 4.18M (38,980 SOL) | 41.8k / 8.4k | 209k / 41.8k | 418k / 83.7k |
| All three | 51.7M | 517k / **103k** | 2.59M / 517k | 5.17M / 1.03M |

At 1 %, a vault above about 103k NAV cannot use its full 5x on the three curated pairs. It is capped at 517k of
notional: a 1M vault runs at about 0.52x at most. That is the price of the bound. Deeper pairs, or more of them, raise it.

### Recommended defaults

| Pair | Recommended cap | Break-even (worst-case thief) | Margin |
|---|---|---|---|
| BTC (0) | **100 bps (1 %)** | 213 bps | 2.1x |
| ETH (1) | **100 bps (1 %)** | 213 bps | 2.1x |
| SOL (33) | **100 bps (1 %)** | 150 bps | 1.5x before its cumulative-volume impact, which only adds to the thief's cost |

**A new pair** needs a cap of at most its cheapest opposite round trip in bps ÷ 1.5, read as a percentage of depth. A pair
whose counter-trade, top-tier round trip is below 1.5 bps must start below 1 %. The guardian can set a new pair's first
cap immediately only up to 1 %. Anything higher waits 31 days (the longest epoch + 1 day), and only the guardian
raises.

**Decision D10 (owner, 2026-10-21):**
- **At launch** the cap is 1 % on BTC, ETH and SOL.
- **Only the guardian may raise it,** to at most the 10 % ceiling in code.
- **Break-even** is about 2.13 % for BTC / ETH and about 1.5 % for SOL.
- **Docs note for the fix round** (the fix round edits the docs site):
  > On gTrade vaults, the platform limits how large a position a vault can hold on each market to 1 % of that market's price-impact depth (BTC, ETH and SOL at launch); only the platform guardian can raise this limit, to at most 10 %, and a raise takes effect 31 days after it is announced, so you can always withdraw before it applies, while a lowering takes effect at once.

**Re-check the caps** when Gains changes the counter-trade multiplier, the fee tiers, the pair fees or the spread. The
guardian lowers at once. GR2-EXE alarm: watch `getPairCounterTradeFeeRateMultiplier`, `pairTotalPositionSizeFeeP` and
the fee tiers.

### Take profit / stop loss inside the hold (the residual)

**Design.** The hold restricts only `closeTrade`, `reduceTrade`, `flatten` and `flattenIndices` by the manager or the
agent. Gains' own closes are never held:
- TP / SL / liquidation executed by Gains' bots, via `triggerOrder` and the callbacks, do not pass through the vault;
- `setSlTp` is not held, so a depositor's stop loss always fires.

Fix test: `KEY01bFixTest::test_KEY01b_guard_gainsTpSlClosesAreNotHeld`. Inside the hold, the manager sets a TP behind the
market, and his own close is refused "min hold". Gains' trigger closes the trade in the same block, and the USDC comes
back to the vault.

**What that leaves open.** An agent can turn any trade into an immediate close inside the hold by setting the TP (or
SL) past the market.
- Gains has no minimum trigger distance. `updateTradeTp` only checks open and TRADE type
  (`TradingStorageUtils.sol:315-327`). `updateTradeSl` only caps the distance on the loss side (`_limitTradeSlDistance`).
- A crossed trigger executes at the next bot trigger as a market close at the candle's open price
  (`TradingCallbacksUtils._validateTriggerCloseOrderCallback:627-633`; measured in GR2-KEY-02 above).
- The policy's slippage band applies to opens only.

So the hold bounds neither the swing count (144 per pair per day) nor the reaction time between an open and the close.

**What bounds it instead.**
- The per-pair cap: per-swing capture of f/100 of A, which is negative at 1 %.
- The turnover budget: at most 20·NAV/V swings per day.
- The 15 % daily-loss gate before every new risk.
- The breaker (assumed).

The hold still does two jobs: the 20x protection close factor (the vault's own closes never pay it) and keeping
rotation and late fills from escaping it.

**Effect on the tables: none.** They are computed without any hold limit, and in every cell turnover or daily loss binds
at 30 swings per pair per day or fewer, below the hold's 144. If the fix round wants the hold to bind again, the least
intrusive rule is "inside the hold, `setSlTp` may not set a TP or SL that the Chainlink mark has already crossed". A
crossed trigger is a market close, not a protection, so the rule removes nothing from a stop loss. A tight but uncrossed
TP would still close on the next tick of noise. This is not proposed as a fix: the owner's decision is that bots close
on TP / SL freely.

### Assumptions of this section

| # | Assumption |
|---|---|
| X-1 | Depths and prices at block 516,920,630 (`getPairSkewDepth(3, p)` and Chainlink, read only). Gains' multipliers and tiers as FIX-DESIGN.md A1 read them (2026-10-20) |
| X-2 | Background skew of 1 % of D in the vault's direction gives counter-trade room beyond V. Live it is 0.05–0.75 % |
| X-3 | Plain thief trades up to 5M: an estimate, with Gains' OI limits and SOL's cumulative-volume impact not modelled (an overstatement) |
| X-4 | Vault round trip per swing: 8.0 bps (BTC, ETH) and 13.6 bps (SOL), measured in GR2-KEY-04 |
| X-5 | Daily loss 15 % and drawdown 50 % (live policy), enforced before new risk by the KEY-01 loss gate. Compounding is ignored |
| X-6 | The circuit breaker's thresholds above are the proposed WP3 executor defaults, not code |
| X-7 | One thief and one vault. Several vaults under one compromised agent each have their own budget, so the per-vault figures add up |

## Open questions
- GR2-KEY-01 was measured at one size (V = A = 1.25M) and one oracle price; Gains OI caps, funding over longer holds
  and protection-close factors were not varied.
- Whether batching logical reduces into one tx (e.g. EIP-7702) stays under the reduceRate alarm's one-tx-counts-once rule.

## PoC files
- `contracts/test/audit/gains/r2/KeysForkBase.sol` — fork harness (block 516,380,000, live policy shape).
- `contracts/test/audit/gains/r2/KeysSkewFork.t.sol` — GR2-KEY-01.
- `contracts/test/audit/gains/r2/KeysTpSlFork.t.sol` — GR2-KEY-02.
- `contracts/test/audit/gains/r2/KeysReferrerFee.t.sol` — GR2-KEY-03, GR2-KEY-04.
