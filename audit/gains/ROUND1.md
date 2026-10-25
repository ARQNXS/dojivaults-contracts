# Gains contracts: internal security review, round 1

**This is an internal review. It is not an independent audit and must not be presented as one.**

Scope: `contracts/src/gains/*` and `contracts/script/DeployGains.s.sol` at `origin/main` 5dd1344 (unchanged in this
review), plus the executor paths that sign or decide for Gains vaults (`server/src/venues/gains/*` and the Gains
branches of keeper, treasury operator, risk watcher, monitor, launch, registrar, `hotKeys.ts`). Branch
`audit/gains-r1`. Nothing deployed, no transaction sent, nothing pushed.

Model documents: [SPEC.md](SPEC.md), [THREAT-MODEL.md](THREAT-MODEL.md), [ACCESS-MATRIX.md](ACCESS-MATRIX.md).
Domain reports: [nav/FINDINGS.md](nav/FINDINGS.md) (3.1), [lifecycle/FINDINGS.md](lifecycle/FINDINGS.md) (3.2, 3.3),
[gov/FINDINGS.md](gov/FINDINGS.md) + [gov/HL-RETEST.md](gov/HL-RETEST.md) (3.4, 3.6),
[tools/executor/RESULTS.md](tools/executor/RESULTS.md) (3.7), cross-review [XREVIEW.md](XREVIEW.md) (3, 6),
tooling in [tools/](tools/) (4).

## 1. Executive summary

The Gains contracts are a careful port of round 4: the access matrix (4,428 cells) matches the specification exactly,
the trade valuation is exact against Gains' own close path (independent TypeScript implementation: max divergence
0.005 bp over 79 valuations including 30 real mainnet closes), every exit works with every price source down, and
none of the 96 HL finding classes regressed. No issue lets an outsider take depositor funds, and nothing is
exploitable on the live vault now: it holds 37 wei of USDC (the 21 USDC were redeemed in epoch 1), its cap is 21 USDC
and its only holders are the owner (also manager and fee recipient) and the protocol.

The problems are in three places:

1. **The NAV is the same number for buying and selling shares** (GR1-02, GR1-03). Trades are valued at the adverse
   edge of Chainlink ± band, which is a fair redemption price but a discount for depositors. A deposit made while
   trades are open and redeemed when they are closed takes about band × vault leverage of the deposit from the
   holders who were already in, with no price move. Settle has no minimum epoch age for non-insider deposits, so a
   manager with a confederate can repeat it every few minutes: 4,750 USDC from a 100k holder in about an hour on the
   live policy shape, stopped only by the daily-loss breaker. The near-liquidation rule counts the band twice and
   doubles the effect at Gains' maximum leverage.
2. **Pending leverage-only increases carry no notional** (GR1-01). Several of them in one block each pass the
   policy's vault-leverage check: 7.9x under a 3x policy on the real diamond, about 31x with the live parameters and
   20 trades. The policy limit is the guarantee depositors are shown, and a manager or one compromised agent key
   can bypass it.
3. **Pending orders gate every settle** (GR1-04), including the emergency exit-only settle. Anyone who may exit
   (the manager, the owner, the operator, the sentinel) can keep a decoy close in flight and hold redemptions for as
   long as they win the race against the guardian. On the executor side, three paths send one order twice (GR1-05,
   GR1-06, GR1-07).

A fourth, external one: **the vault decodes Gains' trade lists with a fixed ABI** (GR1-08). A Gains facet upgrade
that adds a field to `Trade`, as v10 did, makes NAV, every settle mode and flatten revert in every Gains vault at
once, until trades are closed one by one.

Severity counts after the cross-review (section 2): **0 Critical, 2 High, 6 Medium, 14 Low, 22 Informational,
1 Design.** Open questions: section 4. Mutation score on the limited security sample: **92.3%** (48 / 52, section 6).

## 2. Summary table

Severity scale: brief section 5 (HL scale calibrated with Immunefi). Impact × likelihood is stated per finding.

| ID | Title | Severity | Location | PoC |
|---|---|---|---|---|
| GR1-01 | Pending leverage-only increases add no notional: several bypass maxLeverageBps | High | GainsNav.sol:68-70 | `R1PoCTest.test_PENDINGLEVNOTIONAL_twoLeverageIncreasesInOneBlockReach5xUnder3xPolicy`; fork `LC_PendingFork.test_lc_LC01_leverageOnlyIncreasesBypassVaultLeverage` |
| GR1-02 | Deposits mint at the adverse-edge NAV, repeatable intraday: value transfer from holders | High | GainsNav.sol:59, GainsVaultLogic.sol:227, :249-266 | `R1NavBiasTest.*`, `XReviewTest.test_XR_NAVBIAS_intradayCyclesBoundedByDailyLoss`, fork `NavEconForkTest.test_NAVBIAS_fork_realFees_3x/_10x` |
| GR1-03 | Near-liquidation zero rule counts the band twice: 200x trades are zeroed at the open | Medium | GainsNav.sol:120 | fork `NavEconForkTest.test_NAVCLIFF_fork_highLeverageTradeValuedZeroButPays`, `test_NAVCLIFF_fork_confederateExtractsFromHolders` |
| GR1-04 | Decoy market orders keep the emergency settle blocked | Medium | GainsVaultLogic.sol:230, :666, :707-711 | `R1PoCTest.test_PENDINGGRIEF_managerBlocksEmergencySettleAndFlatten`; fork `LC_GriefFork.test_lc_LC02_*` |
| GR1-05 | Executor resubmits an in-flight Gains order (crash after broadcast, store error) | Medium | server engine/executor.ts:119-126, venues/gains/info.ts:120-127 | `tools/executor/D-5.test.ts`, `xreview2/XR_D5.test.ts` |
| GR1-06 | Executor releases the leader lease before draining its queues: duplicate order on a deploy | Medium | server main.ts:2020-2023 | `xreview2/XR_LEASE.test.ts` |
| GR1-07 | Executor retries "no answer from Gains" with a fresh order: up to 4x the size | Medium | server venues/gains/submitter.ts:257-258, venues/gains/index.ts:18 | `tools/executor/D-4.test.ts` |
| GR1-08 | A Gains facet upgrade that changes the Trade / PendingOrder ABI freezes NAV, every settle mode and flatten of every vault | Medium | IGainsDiamond.sol:12-28, :53-61; GainsNav.sol:43-44, GainsVaultMath.sol:134, :151, GainsVaultLogic.sol:662-663 | `integration/IntegrationMock.t.sol::test_INT01_tradeLayoutChange_freezesNavSettleAndFlatten`, `test_INT01_pendingOrderLayoutChange_blocksNavFlattenAndOperatorReduce`; fork `IntegrationForkTest.test_INT_fork_returnLayoutsMatchIGainsDiamond` |
| GR1-09 | Exit-only settle prices the venue: a stale feed holds every redemption until the pair is flattened | Low | GainsVaultLogic.sol:233 | `R1PoCTest.test_STALESETTLE_emergencyRedemptionsWaitForAFlattenWhenAFeedIsStale` |
| GR1-10 | The sequencer uptime feed cannot be rotated | Low | GainsVaultFactory.sol:50-51, GainsVaultPolicy.sol:148 | `gov/Governance.t.sol::test_GOV_06_sequencerFeedCannotBeRotated` |
| GR1-11 | reduceTrade has no minimum size: collateral can be ground into minimum fees | Low | GainsVaultLogic.sol:568-586 | `gov/OperatorBound.t.sol::test_GOV_01_*` |
| GR1-12 | The policy's owner is separate from the vault's and survives a vault transfer | Low | GainsVaultPolicy.sol:25, GainsVaultFactory.sol:284 | `gov/Governance.t.sol::test_GOV_03_vaultTransferLeavesPolicyWithOldOwner` |
| GR1-13 | Feed decimals cached at curation: a decimals change misprices without a revert | Low | GainsVaultFactory.sol:447, GainsPrice.sol:57-63 | `nav/NavUnit.t.sol::test_NAVDEC_decimalsChangeMispricesWithoutRevert` |
| GR1-14 | SOL staleness limit 24.5 h: a halted feed is trusted for a day by pricing settles | Low | DeployGains.s.sol:31, GainsPrice.sol:53 | `nav/NavUnit.t.sol::test_HALTEDFEED_solFrozenForADayStillSettles` |
| GR1-15 | Requests and cancels are free until the settle transaction: an option on Chainlink lag | Low | GainsVaultLogic.sol:52, :106, :123 | `nav/NavUnit.t.sol::test_CANCELOPTION_freeCancelUntilSettle` |
| GR1-16 | Resting limit / stop orders survive a full stop and emergency and still open exposure | Low | GainsVaultGovernance.sol:229-235 | `R1PoCTest.test_RESTINGINSTOP_limitOrderOpensAfterTriggerBreach` |
| GR1-17 | Executor re-signs on "already known" / "nonce too low": a duplicate open | Low | server chain/vault.ts:919-944, :1130 | `tools/executor/D-2.test.ts` |
| GR1-18 | Executor marks a landed request failed after a 60 s receipt timeout | Low | server venues/gains/chain.ts:264, submitter.ts:219-224 | `tools/executor/D-3.test.ts` |
| GR1-19 | Executor holds a vault's queue up to 20 minutes per order | Low | server venues/gains/submitter.ts:111, :257-265 | `tools/executor/D-6.test.ts` |
| GR1-20 | Executor free-margin plan double counts idle USDC | Low | server treasury/reduce.ts:59, venues/gains/info.ts:113 | `tools/executor/D-8.test.ts` |
| GR1-21 | Executor risk watcher measures leverage differently from the contract | Low | server risk/watcher.ts:212-216 | `tools/executor/D-9.test.ts` |
| GR1-22 | Launch binding: indexer lag at the deadline, and Safe owners can never bind | Low | server tenants/launch.ts:277, :382-388 | `tools/executor/D-10-D-11.test.ts` |
| GR1-23..44 | Informational items | Info | section 3.3 | section 3.3 |
| GR1-45 | Venue liveness: Gains PAUSED / CLOSE_ONLY, a pair no longer served, a USDC blacklist | Design | trust T2 / T5 | `lifecycle/LC_LivenessFork.t.sol` |

## 3. Findings

### GR1-01 Pending leverage-only increases add no notional: several bypass maxLeverageBps (High)

**Location.** GainsNav.sol:68-70 (pending MARKET_PARTIAL_OPEN adds `positionSize(o.trade.collateralAmount,
o.trade.leverage)`), consumed as `openNotional` by GainsVaultLogic.sol:454 (openTrade), :506 (increaseTrade), :548
(leverage raise).

**Description.** Gains stores a leverage-only `increasePositionSize` (collateralDelta 0) as a pending order with
`collateralAmount = 0, leverage = leverageDelta` (verified on the real diamond,
`test_lc_increaseLeverageOnly_pendingNotionalIsZero`). GainsNav therefore counts 0 notional for it while it is
pending, although the fill adds `trade.collateral × leverageDelta`. `increaseTrade` computes the new request's own
notional correctly (line 502), but every check made before the fill uses the stale open notional. Gains allows one
pending market order per trade, so the attacker uses one increase per trade, all in the ~1 s before the first fill.

**Impact.** Fork, 3x policy, NAV 9,984 USDC, 3 trades of 1,000 at 2x (6,000 notional): three +23.7x leverage-only
increases all pass `checkOrder`; after the fills vault leverage is 78,834 bps against 30,000. With the live parameters
(maxOrderNotional 250,000) on a 100k vault with 20 trades: about 3.15M notional, 31x under a 3x policy, so a ~3% adverse
move wipes NAV, and the opening and closing fees alone cost ~3.6% of NAV. Nothing on chain unwinds it: `checkRisk`
only sets a reduce-only leverage breach after the fact and the executor's sentinel never flattens. The NAV error bound
of SPEC N5 (2 × B × leverage ≤ maxNavMoveBps / 4) is exceeded by the same factor.

**Likelihood.** Needs the manager (semi-trusted only within the policy, T7) or one compromised agent key (hot, T6):
one transaction per trade, no timing beyond the fill latency. Impact high × likelihood low-medium.

**Fix.** For a pending MARKET_PARTIAL_OPEN with `collateralAmount == 0`, add
`positionSize(getTrade(this, o.trade.index).collateralAmount, o.trade.leverage)` (the formula increaseTrade already
uses at :502).

### GR1-02 Deposits mint at the adverse-edge NAV, repeatable intraday (High)

**Location.** GainsNav.sol:59 (open trades valued at `GainsPrice.adverse`), GainsVaultLogic.sol:249-266 (the same `nav`
mints deposits and burns redemptions), :227 (the minimum epoch age applies only to insider deposits).

**Description.** PLAN.md 4.3 values every open trade at C × (1 − B) for a long and C × (1 + B) for a short, so NAV
sits about B × open notional below what the vault realizes at the Chainlink price. That is the right price for a
redemption (conservative for the remaining holders) but a discount for a deposit: shares are minted cheap, and the
difference is released to all holders, the new depositor included, when the trades close. Closing fees, spread and
impact are real costs and not the issue; the band is. A passive depositor who enters and leaves while trades are open
is neutral (test_XR_NAVBIAS_passiveInAndOutWhileOpenIsNeutral: 99,999.999 of 100,000); one who enters while they are
open and leaves when they are flat takes the gap. The positions are public (getTrades of the vault), and the manager
decides when they are open. The insider deferral (R3-02) covers only the manager, owner and fee recipient addresses,
and a settle that prices non-insider deposits has no minimum epoch age, so the manager can cycle every few minutes.

**Impact.** Mock, no fees, one cycle: bob deposits 100k while alice's 100k is in a 3x ETH long, the trade closes at the
same price, bob redeems: bob +300 USDC, alice −301 (3x); +1,265 / −1,266 at 12.5x, the highest leverage the factory
bound allows at the default maxNavMoveBps. Five daily cycles at 12x: alice's 100k → 94,002. Intraday on the live policy
shape (3x, 5% daily loss, 15% drawdown, checkRisk before each settle): 10 cycles at 5-minute spacing in about an hour,
bob +4,750 USDC, alice 100k → 94,696, then the daily-loss breach stops it until the next UTC day; drawdown stops it
until `resume`, which on the live vault the manager calls as owner. Fork with real Gains fees: +270.8 / −489.4 USDC per
100k at 2.7x, +911.2 / −1,641.1 at 9x; fees cut the intraday rate to about 3.5% of holder NAV per day.

**Likelihood.** A manager with any non-insider address, or any outsider who times deposits around the vault's public
positions (with GR1-15, without the manager's cooperation, per settle). Impact: theft of holder value, bounded at about
the daily-loss limit per day. Likelihood medium.

**Fix.** Price the two flows separately: mint deposits at a NAV that values open trades at the favourable band edge
(or at C), pay redemptions at the adverse edge (a bid / ask NAV). Add a minimum epoch age (e.g. 1 hour or more) to
every settle that mints shares.

### GR1-03 Near-liquidation zero rule counts the band twice (Medium)

**Location.** GainsNav.sol:120 (`P × 1e4 ≤ L × (1e4 + B)` for a long, P already C × (1 − B)).

**Description.** The rule zeroes a trade when C ≤ L(1 + B)/(1 − B) ≈ L(1 + 2B), not when the realizable price could
reach L (C(1 − B) ≤ L). The policy has no per-trade leverage cap, so at Gains' maximum leverage (200x BTC/ETH, 150x
SOL) a trade is zeroed the moment it opens.

**Impact.** Fork: an ETH 200x long with 1,350 USDC collateral (270k notional, 2.7x vault leverage) has
`venue().value == 0` right after the fill; closing it at C pays 1,134.0 USDC (84% of collateral): an understatement
of 42 bps of notional against the 40 bps of SPEC N5. Used with GR1-02: bob +1,027.4, alice −1,248.1 per cycle (the
same notional at 6x: +488.9 / −709.6). Alone it only understates NAV.

**Likelihood.** As GR1-02 (a manager choosing 200x).

**Fix.** Value at 0 only when P itself is at or past L; optionally cap per-trade leverage (e.g. 0.9 / (4B) = 112x at
B = 20 bps).

### GR1-04 Decoy market orders keep the emergency settle blocked (Medium)

**Location.** GainsVaultLogic.sol:230 (`OrdersPending` in every settle mode), :666 (flatten skips trades with an order
in flight), :707-711 (`_mayExit`: manager and agent at any time; owner, operator, sentinel in a breach or emergency).

**Description.** In an emergency the exit-only settle is how redeemers are paid. It reverts while any order is pending.
The manager (and in an emergency the owner, operator and sentinel) may still send closes and reduces. A close at a
price far off the market is accepted by Gains and cancelled by its callback a few blocks later; the sender re-sends.
Flatten skips a trade with an order in flight and reports `remaining = 0`; a direct close reverts at Gains
(`ConflictingPendingOrder`). No platform role can remove the manager quickly (`setManager` is owner-queued with a
timelock of at least 1 day; on the live vault the owner is the manager).

**Impact.** Redemptions are held for as long as the attacker wins the race after each callback. Fork: a decoy close
costs 1,406,722 gas (~2.8e-5 ETH at 0.02 gwei) plus a 0.042505 USDC gov fee booked on the vault's trade; two decoys
staggered by 2 blocks held an order in flight through 6 consecutive answers. Without Timeboost the guardian can land a
close in a gap and, once every trade is closed, no decoy is possible (test_lc_LC02_guardianWinsTheRace_thenSettle);
an express-lane holder wins every race. Depositors pay ~0.0425 USDC per decoy (~300 USDC/h at 2 per second).

**Likelihood.** A hostile manager or owner (T7) or a compromised online key. Impact medium (temporary lock with a racing
exit) × likelihood low.

**Fix.** Block settle only on pending orders that hold collateral: MARKET_OPEN, MARKET_PARTIAL_OPEN with collateral,
UPDATE_LEVERAGE decrease (GainsNav's "held" cases). Closes, partial closes and leverage increases hold nothing, and
GainsNav values the trade as open (continuous to 1 wei at the valuation price). None of the holding types can be
created in an emergency, so no actor could then hold an emergency settle beyond one fill or timeout. At minimum,
apply this to exit-only settles.

### GR1-05 Executor resubmits an in-flight Gains order (Medium)

**Location.** server/src/engine/executor.ts:119-126 and 161-169 (`if (known)` is true for an empty fills array),
venues/gains/info.ts:120-127 (`orderState` returns open for a sent / pending row), main.ts:1084-1096 (boot re-queues
QUEUED and PROCESSING signals), venues/gains/submitter.ts:122-123 (pending opens are not netted).

**Description.** When the executor cannot tell whether an order was sent (a crash between broadcast and receipt, a
store error inside the wait), recovery finds no fills and the loop moves to the next attempt with a fresh order. A
normal restart is not affected: Gains fills in ~1 s and recovery books the fill (XR_D5 test 1).

**Impact.** A full-size duplicate (2x) not on any ticket, within policy (maxOrderNotional, maxLeverageBps, idle). On a
100k vault up to +150k unintended exposure: a 5% adverse move before the manager reacts costs 7.5k (7.5% of NAV). Market
risk, not theft.

**Likelihood.** Low to medium (a crash in the broadcast-to-receipt window; a database error that survives retryReads).

**Fix.** Treat `known && status === "open"` as in flight: wait on the stored row, never start a new attempt. At boot,
resume every `sent` / `pending` row (receipt by hash, then wait) before re-running its signal.

### GR1-06 Executor releases the leader lease before draining its queues (Medium)

**Location.** server/src/main.ts:2020 (`lease.stop()`) before :2022-2023 (`queue.onIdle()`, `registry.onIdle()`).

**Description.** In a zero-downtime deploy the old instance releases the lease first; the standby takes it within one
renew tick (20 s) and re-queues every QUEUED / PROCESSING signal while the old process is still executing them.
`Processor.processInner` never re-checks the status (processor.ts:305-312), and GR1-05's `if (known)` then starts a
second attempt. This contradicts lease.ts:4-6 ("the two never both send").

**Impact.** As GR1-05 (a duplicate Gains order), plus overwritten database rows and double-booked tickets.

**Likelihood.** A Gains signal in flight or queued at a deploy (deploys are manual). Low-medium.

**Fix.** Stop intake and drain the queues before `lease.stop()`; re-check a signal is still QUEUED before processing;
the GR1-05 fix.

### GR1-07 Executor retries "no answer from Gains" with a fresh order (Medium)

**Location.** server/src/venues/gains/submitter.ts:257-258 (after 600 s `wait()` returns "no answer from Gains"),
venues/gains/index.ts:18 (`GAINS_RETRYABLE` matches it), engine/executor.ts:174-178, submitter.ts:122-123, 144-147.

**Description.** If the fill tracker is blind for 10 minutes (getLogs errors are swallowed, fills.ts:218-221) or the
oracle is slow while ArbSys is unreadable, the order is retried under a new cloid; `plan()` ignores pending opens and
turns the unseen trade into an increase.

**Impact.** Up to 4x the order (1 open + 3 increases, D-4 variant A: 4 ETH long for a 1 ETH signal, 0 booked), capped
by policy; the extra exposure is orphaned and not alerted while the tracker is blind.

**Likelihood.** Low (a 10-minute getLogs or ArbSys outage during an order). Impact high × likelihood low.

**Fix.** "No answer" is not retryable; before any retry re-read `getPendingOrders` / `getTrades` and net both; one
idempotency key per order across attempts.

### GR1-08 A Gains Trade / PendingOrder ABI change freezes NAV, settle and flatten (Medium)

**Location.** IGainsDiamond.sol:12-28 (`Trade`, 15 ABI words), :53-61 (`PendingOrder`, Trade nested first); fixed
decoders at GainsNav.sol:43-44, GainsVaultMath.sol:134 (ordersPending), :151 (redemptionShortfall),
GainsVaultLogic.sol:662-663 (flatten), GainsVaultLens.sol:205, :228. The diamond address is set once
(GainsVaultGovernance.sol:78), the vaults are non-upgradeable clones and the factory's diamond is immutable.

**Description.** Gains grows `Trade` by carving fields out of a trailing storage placeholder. Storage stays
compatible, the ABI does not (every field is one word): v9 → v10 already grew it from 13 to 15 words (inferred from the
public source; the v10 word counts are verified on the live diamond). With one more field, the vault's 15-word decoder
reverts on `getTrades` with ≥ 2 trades (element 1's `index` reads an address) and on `getPendingOrders` with ≥ 1 order;
with exactly 1 trade it decodes silently.

**Impact.** No loss by itself; a fleet-wide liveness failure. With ≥ 2 open trades, `totalAssets`, `checkRisk`,
`accrueFees`, the normal settle, the guardian's exit-only emergency settle, `openTrade`, `requestDeposit` (every factory
vault has a cap) and `flatten` all revert in every Gains vault at once. `requestRedeem`, `claim`, `closeTrade` /
`reduceTrade` by index, `cancelOrder`, `cancelTimedOut` and `setSlTp` still work. Redemptions are paid only after the
manager or the cold guardian closes trades one by one down to ≤ 1 (20 positions: up to 19 closes of ~1.4M gas each, each
crystallised at that moment's price). Off chain, the executor's event topics change and it silently stops seeing fills.

**Likelihood.** A Gains governance upgrade behind Gains' own public timelock, with precedent (v9 → v10). Impact 3/5 ×
likelihood 2/5 → Medium; not High because an exit path exists and no attacker can trigger it.

**Fix.** Read the lists with a low-level staticcall and check `ret.length == 64 + n × stride`, else revert a named
`DiamondLayoutChanged()` (also catches the silent n = 1 case); put list decoding behind a reader the factory curates
and each vault adopts through its timelock (the setPairFeed pattern); give the guardian an index-based
`flattenIndices(uint32[])` that decodes nothing; monitor Gains' timelock for diamondCuts touching the 34 selectors
(IntegrationForkTest pins the word counts).

### GR1-09 Exit-only settle prices the venue: a stale feed holds redemptions (Low)

**Location.** GainsVaultLogic.sol:233 (`$.venue()` in every settle mode).

**Description.** With an ETH trade open and the ETH feed stale (or deprecated), the guardian's emergency settle reverts
`PriceStale(1)` although idle USDC covers the redemption in full. The way out is to flatten the pair (exits read no
price), after which the flat vault settles; a feed rotation needs the vault timelock (≥ 1 day) and the factory's
curation.

**Impact.** Redemptions wait for a forced unwind of the stale pair (crystallised at market). Likelihood low (a Chainlink
feed outage beyond maxAge or a deprecation).

**Fix.** In an exit-only settle, price the redemptions from idle only when the venue cannot be valued (min(checkpoint,
idle-backed NAV) with a partial fill), or value a stale pair's trades at 0 for exit-only settles.

### GR1-10 The sequencer uptime feed cannot be rotated (Low)

**Location.** GainsVaultFactory.sol:50-51 (immutable), GainsVaultPolicy.sol:148-149 (copied at initialize, no setter),
GainsPrice.sol:72-78.

**Description.** If the Arbitrum uptime feed 0xFdB6…697D reverts or is retired, every vault with open trades can never
again settle (any mode), run checkRisk, take deposits or open trades. Exits work; the guardian must close every trade;
a flat vault settles. Impact: forced unwind and relaunch of every vault; likelihood very low.

**Fix.** A timelocked `setSequencerFeed` through the vault queue that accepts only the factory's current value, and a
factory setter for the cold owner. Related (Slither triage): the factory constructor accepts `sequencerFeed_ = 0`
(GainsVaultFactory.sol:183), which silently disables the sequencer-down check for every vault of that factory and
cannot be undone; assert it non-zero in the constructor or in DeployGains.s.sol.

### GR1-11 reduceTrade has no minimum size (Low)

**Location.** GainsVaultLogic.sol:568-586.

**Description.** Gains charges every partial close at least 0.10 USD (closing fee on max(delta size,
pairMinPositionSizeUsd)), and a reduce that would pay out a negative amount is cancelled with the 0.0425 USDC gov fee.
reduceTrade accepts any `collateralDelta > 0`. The operator's cap limits each request, not their number: 40 reduces
burned 3.979 USDC and freed 0.397. The agent / manager may reduce at any time, also in a loss breach.

**Impact.** ~1 USDC/s of NAV across 20 trades (a fill every ~2 s), bounded by the collateral; the attacker pays ~0.5 USD/s
of gas and gains nothing. Likelihood: a compromised online key and hours without reaction.

**Fix.** Require `collateralDelta × leverage ≥ pairMinPositionSizeUsd` unless it closes the remainder; one operator
reduce in flight per trade; alert on ReduceRequested frequency.

### GR1-12 The policy's owner survives a vault transfer (Low)

**Location.** GainsVaultPolicy.sol:25 (own Ownable2Step), GainsVaultFactory.sol:284 (initialized with `p.owner`).

**Description.** After the vault's ownership moves, the old owner still owns the policy and can instantly tighten it
into a permanent leverage breach (maxLeverageBps 1), make emergency triggerable by anyone (maxEpochDuration 1 h) and
disallow every pair; the new owner gets OwnableUnauthorizedAccount on every policy call. Grief, no theft; only after a
transfer that does not move the policy (no code, UI or runbook does).

**Fix.** Make the policy's `onlyOwner` check `GainsVault(vault).owner()`, or move it with the vault's ownership.

### GR1-13 Feed decimals cached at curation (Low)

**Location.** GainsVaultFactory.sol:447, GainsPrice.sol:57-63.

**Description.** A Chainlink proxy's `decimals()` follows its current aggregator. If a phase change moves a feed from 8
to 6 decimals, prices read 100x low with no revert: a 3x short vault's NAV 99,940 → 129,699; NavMoved blocks the first
settle, but the permissionless checkRisk walks the checkpoint up in 3 hours; a 10% redemption then paid 12,375.9 USDC
against ~9,994 fair (+24%). An increase of decimals fails closed. Likelihood near zero (live proxies are phase 2,
8 decimals; no USD feed has changed decimals).

**Fix.** Read `decimals()` on every read and revert `PriceStale` when it differs from the cached value.

### GR1-14 SOL staleness limit of 24.5 h (Low)

**Location.** DeployGains.s.sol:31 (88,200 s), GainsPrice.sol:53.

**Description.** A halted feed keeps NAV at the checkpoint, so `NavMoved` never fires: a settle 23 h later paid a
redeemer of half the shares 49,684.9 USDC against 37,500 fair after a −10% move on a 5x SOL trade (trust T4; BTC/ETH
have the same exposure for 44 minutes). Likelihood very low.

**Fix.** Settles and deposits require a round no older than 1-2 h; exits unaffected.

### GR1-15 Requests and cancels are free until the settle transaction (Low)

**Location.** GainsVaultLogic.sol:52, :106, :123.

**Description.** No request cutoff and no cancel fee: a requester keeps a request only while Chainlink's lag favours it
(5 bps of lag at 3x: +75.1 USDC on 100k; otherwise the cancel returns every wei). Bounded by the deviation threshold
(5 bps BTC/ETH, 10 bps SOL) × vault leverage; it also lets outsiders take GR1-02 per settle.

**Fix.** A request / cancel cutoff before settle (e.g. the epoch's last hour), or a cancel fee; with the GR1-02 fix.

### GR1-16 Resting orders survive a full stop and emergency (Low)

**Location.** GainsVaultGovernance.sol:229-235 (`_stop` revokes the agent, cancels nothing); executor sentinel never
sends `cancelOrder` for Gains (venues/gains/monitor.ts:106-121).

**Description.** A limit or stop open placed before a breach still opens when Gains' bot triggers it, in a full stop or
emergency (test: 60k notional long opened during an emergency). It was policy-checked when placed and is cancellable by
the sentinel or flatten. Anyone can also block the cancel for ~20 blocks with a 1 LINK Gains trigger (GR1-25).

**Fix.** The keeper / sentinel cancels every resting open on a breach; or `_stop` cancels them (try / catch).

### GR1-17..22 Executor (Low)

| ID | Defect | Location | Impact × likelihood | Fix |
|---|---|---|---|---|
| GR1-17 | "already known" / "nonce too low" after a broadcast re-signs the open with nonce n+1 (two accepted requests, same calldata) | chain/vault.ts:919-944, :1130 | one duplicate open within policy × a sub-second read-node lag; only opens (Gains allows one pending order per trade) | wait for the stored hash; never re-sign a Gains request |
| GR1-18 | a 60 s receipt timeout marks a landed request failed with no orderIndex; its fill is booked "outside the executor" and the strategy's close never closes it | venues/gains/chain.ts:264, submitter.ts:219-224, fills.ts:438-461 | intended size held unmanaged × a 60 s receipt delay | keep `sent` and fetch the receipt by hash; link fills by tx hash |
| GR1-19 | the vault queue waits 600 s per step and again in `finish()`: trims and reduces delayed up to 20 minutes | submitter.ts:111, :257-265 | delayed derisking × slow fills | one bounded wait per order; trims ahead of waiting orders |
| GR1-20 | free-margin plan counts idle twice (`withdrawable = idle` added again) and queued deposits as cash: the manager's signed reduction is too small or 0 | treasury/reduce.ts:59, venues/gains/info.ts:113 | redemptions wait for the operator's automatic reduce | `have = idle + spot`, or read `redemptionShortfall()` |
| GR1-21 | watcher leverage from net positions at the stream mark, ignoring resting and pending notional: no trim before a contract leverage breach (3.25x vs 1.5x) | risk/watcher.ts:212-216 | breach without pre-emptive trim, no loss | use `account.totalNtlPos`; cancel resting opens |
| GR1-22 | a create mined just before the 1 h deadline but indexed after it becomes MANUAL and its agent key is purged; Safe owners never bind (`txFrom == owner`) | tenants/launch.ts:277, :382-388 | lost automation and 0.001 ETH agent gas; 100% of Safe launches with an agent | look up by agent regardless of expiry and compare block time; accept when the predicted vault matches |

### 3.3 Informational (GR1-23..44)

| ID | Item | Location | Test |
|---|---|---|---|
| GR1-23 | DUSTCHECKPOINT: after every depositor redeems, NAV and checkpoint are dust (live: 37 wei); a 1 USDC donation makes normal settles revert NavMoved for ~55 h on the live vault (x1.2 per hour ratchet). No funds locked (deposits cancellable); a platform exit-only overdue settle ends it after maxEpochDuration (1 day live). Fix: skip the bound when the checkpoint is below MIN_RISK_NAV | GainsVaultPolicy.sol:276-295 | `R1LiveForkTest.test_DUSTCHECKPOINT_live_oneUsdcFreezesTheLiveVault`, `R1PoCTest.test_DUSTCHECKPOINT_*`, `XReviewTest.test_XR_DUSTCHECKPOINT_overdueExitOnlySettleUnfreezes` |
| GR1-24 | ADVERSETRUNC: `adverse()` casts mid × (1 + B) to uint64 silently; a short's valuation price wraps to ~0 for a feed answer ≥ 1.84e9 USD/unit (still accepted by `read`), NAV +10% on a 5k short. Outside T4. Fix: SafeCast or cap in `read`. Same family: priceAfterImpact :192 (not exploitable) | GainsPrice.sol:82 | `R1PoCTest.test_ADVERSETRUNC_*`, `NavUnitTest.test_priceAfterImpactTruncation_unreachableForInflation` |
| GR1-25 | Anyone can block setSlTp and cancelOrder (no try / catch) for ~20 blocks per 1 LINK Gains trigger; closes and settle unaffected | GainsVaultLogic.sol:591-612 | `LC_GriefFork.test_lc_LC03_*` |
| GR1-26 | flatten takes one expectedPrice for longs and shorts: a hot role in a breach can make one side always cancel (a gov fee each); no bad fill possible | GainsVaultLogic.sol:681 | `LC_LivenessFork.test_lc_flattenExpectedPrice_guaranteedFailureCostsGovFees` |
| GR1-27 | flatten returns remaining = 0 while trades sit behind a timed-out close or a decoy | GainsVaultLogic.sol:666-670 | `LC_LifecycleFork.test_lc_timedOutClose_blocksNewCloseAndFlattenReportsZeroRemaining` |
| GR1-28 | Pending partial-open / leverage gov fees priced on pair 0 (Gains leaves pairIndex 0); equal fees today | GainsNav.sol:76 | `LC_PendingFork.test_lc_updateLeverageDecrease_solFeeOnPairZero`, `NavEconForkTest.test_GOVFEEPAIR_fork_pendingSolIncreaseUsesPair0Fee` |
| GR1-29 | registerPlatformAgent binds any number of agents to an existing vault and overwrites / deletes agentOfVault | GainsVaultFactory.sol:331-340 | `HLRetest.test_GOV_02_manyAgentsPerVault_agentOfVaultDesyncs` |
| GR1-30 | The policy keeps renounceOwnership (config frozen, a queued loosening cannot be cancelled) | GainsVaultPolicy.sol:25 | `Governance.test_GOV_04_*` |
| GR1-31 | _checkNavBound skips listed-but-disallowed pairs with exposure; their feed rotation can then revert | GainsVaultPolicy.sol:426-431 | `Governance.test_GOV_05_*` |
| GR1-32 | KNOWN-ISSUES I3-02 recovery is wrong: a cancel keeps r.epoch = current + 1 (HL identical) | GainsVaultLogic.sol:106-120 | `HLRetest.test_HL_I302_*` |
| GR1-33 | redemptionShortfall prices at the checkpoint: a stale one overstates the need (> 400 of ~5,000 after −9% NAV); surplus stays idle | GainsVaultMath.sol:146 | `OperatorBound.test_GOV_OB_staleCheckpointOverstatesTheNeed` |
| GR1-34 | redemptionShortfall ignores queued deposits that a normal settle nets: the operator may reduce although no reduce is needed (40k on a 100k vault) | GainsVaultMath.sol:147-149 | `R1PoCTest.test_SHORTFALLDEPOSITS_operatorReducesWhenDepositsAlreadyCover` |
| GR1-35 | setPairFeed is executable by anyone after the delay: who executes picks the moment of a Δband × notional NAV step (450 USDC on 300k at 15 bps) | GainsVaultGovernance.sol:345 | `NavUnitTest.test_NAVROTATION_bandCutStepsNavAtAnExecutorChosenMoment` |
| GR1-36 | Opening cost plus band is booked as a daily loss at once (27-35 bps of notional; 91 bps at 3x) | GainsNav.sol:59 | `NavEconForkTest.test_DAILYLOSS_fork_navDropAtOpenPerNotional` |
| GR1-37 | Management fee rounds to 0 under per-second accrueFees calls on vaults under ~1,577 USDC | GainsVaultLogic.sol:353 | `NavUnitTest.test_fees_managementFeeDustUnderPerSecondAccrual` |
| GR1-38 | tradeValuePure panics (reverts) on absurd inputs; never a wrong value | GainsNav.sol:196-200 | `NavUnitTest.test_valueMath_absurdInputsPanicNotMisvalue` |
| GR1-39 | The launch seed is gifted to the first depositors (live epoch 0: 20 USDC in, 20.999963 out) | GainsVaultLogic.sol:266 | `R1PoCTest.test_SEEDGIFT_firstDepositorReceivesTheSeed` |
| GR1-40 | allowAsset copies the factory's curation at execution, not what the owner queued (needs the cold factory owner) | GainsVaultPolicy.sol:349-355, :414 | `R1PoCTest.test_CURATIONSWAP_allowAssetTakesTheFeedCuratedAtExecution` |
| GR1-41 | flatten(slippage 0) uses maxSlippageBps (up to 20%) while a custom flatten is capped at 3% (live: 1%) | GainsVaultPolicy.sol:267-271 | `R1PoCTest.test_FLATTENSLIP_defaultFlattenWiderThanTheCustomCap` |
| GR1-42 | requestDeposit reads NAV on every factory vault (cap is always > 0): a stale feed freezes deposit requests, not only settles (AUDIT-DIFF deviation 7 says otherwise) | GainsVaultLogic.sol:58 | `AccessMatrixTest.test_accessMatrix_FS` / `_SD` |
| GR1-43 | Executor nonce manager is unused at viem 2.57.3 (D-1 refuted; a viem change would wedge hot wallets on "nonce too high") | server chain/vault.ts:243, :934, :1125-1133 | `tools/executor/D-1.test.ts` |
| GR1-44 | A feed that halts exceptionally (invalid opcode, or a state write under the staticcall) consumes 63/64 of the NAV read's gas instead of reverting `PriceStale` (trust T4: curated Chainlink proxies revert normally). Fix (optional): `feed.staticcall{gas: 100_000}` | GainsPrice.sol:325 | `integration/IntegrationMock.t.sol::test_INT_feedsAreStaticcalled` |

### GR1-45 Venue liveness (Design, trust T2 / T5)

Fork (`lifecycle/LC_LivenessFork.t.sol`): in Gains CLOSE_ONLY, closes, reduces, flatten, cancels and redemptions work,
openTrade, setSlTp (the sentinel's breach SL) and the margin-adding leverage decrease are refused, and a pending open
waits for cancelTimedOut. In PAUSED every exit reverts including cancelTimedOut (flatten reverts as a whole) and settle
runs only if nothing is pending. A pair Gains stops serving locks its trades' value; the emergency settle pays pro rata
from idle (5,001 of ~10,000 USDC). A USDC blacklist of the vault makes close fills fail and a pending open's
cancelTimedOut revert, so settle stays OrdersPending. The GR1-04 fix also lets settle run through a Gains pause when
only closes are in flight.

## 4. Open questions

1. **Oracle gap in fast markets (T3).** B rests on 19 calm fills (−12 to +15 bps). If Gains' oracle diverges from
   Chainlink by more than B in volatile markets, SPEC N4 (NAV never above the payout) fails. Measure
   `MarketExecuted.oraclePrice` against the Chainlink round at the block over volatile windows.
2. **Fee tier.** Does a contract trader earn Gains fee-tier points? If so GainsNav's untiered fee is conservative.
3. **Feed decimals vs rotation latency** (GOV-Q1): a decimals change needs re-curation plus a ≥ 1 day setPairFeed.
4. **The registrar signature does not bind creation parameters** (`hosted`, policy): a creator with a hosted-launch
   signature can create `hosted = false` (10% instead of 33% protocol share) and keep the platform agent. Does the
   executor refuse such a vault?
5. **Racing the guardian** (GR1-04): is the sentinel expected to win flatten races against a Timeboost express-lane
   holder?
6. **Pair delisting**: can Gains governance make closeTradeMarket revert per pair (exit-less trades)?
7. **D-7**: does gTrade refuse an operator reduce that leaves 1 USDC of collateral (gainsOperator.ts:225-245)?
8. Gains' `triggerTimeoutBlocks` (20) is a Gains parameter; GR1-25's window scales with it.

## 5. Checked and sound

Each line names the test that shows it.

**Access control (3.4).** Every cell of ACCESS-MATRIX.md: vault 4,428 cells (`AccessMatrixTest.test_accessMatrix_<state>`,
12 states), policy and factory (`gov/PolicyMatrix.t.sol`, `gov/FactoryMatrix.t.sol`). Timelock: selector whitelist,
exact lengths, dirty bits fail at execute, window and expiry, cancel rights (`gov/Governance.t.sol`). Clear-breach rules
incl. N-04 / I2-01 (`gov/Governance.t.sol`). Registrar signature: replay across salts / creators / factories / chains,
expiry, high-s and compact signatures, wrong signer, CREATE2 front-running all refused (`gov/FactoryMatrix.t.sol`).
Clones initialize once; a third party's clone cannot adopt another vault's policy. Role collisions incl. the pending
owner. The operator's concurrent reduces total exactly shortfall + 2% of the last residual + 1 USDC
(`gov/OperatorBound.t.sol`).

**NAV (3.1).** Per-trade value equals an independent TypeScript implementation within 0.005 bp and Gains' payout within
0.0024 bp on every market close (`nav/NavDiffFork.t.sol`, `nav/NavReplayFork.t.sol`, `nav/diff/diff.ts`,
DIFF-RESULTS.md). GainsNav never above the payout on any exact row. Every GainsPrice failure mode is a named error
(`NavUnitTest.test_feed_*`, `test_sequencer_*`). Donation / first-depositor inflation unprofitable
(`test_inflation_donationAttackUnprofitable`). Rounding favours the vault (`testFuzz_roundTripNeverProfits`,
`testFuzz_conversionRoundingFavoursTheVault`). Breach settles charge no performance fee and keep the HWM
(`test_fees_breachSettleChargesNoPerformanceAndKeepsHwm`).

**Lifecycle (3.2).** Pending-order fields on the real diamond (partial close, leverage reduce, leverage update, partial
open with collateral) match what GainsNav and redemptionShortfall rely on, except the leverage-only increase (GR1-01)
(`lifecycle/LC_PendingFork.t.sol`, `nav/NavPendingFork.t.sol`). NAV continuity across every request and fill (exact or
± 1 wei; −0.042505 USDC gov fee on opens). Fill after timeout, double cancel, cancel of a filled order, late answers:
revert or no-op (`LC_LifecycleFork.t.sol`). Gains SL / liquidation while a vault order is pending: full refunds, no
double payout. Trade indexes never reused. Approvals back to 0 after every request. No payout can arrive inside settle.
Far-from-market limit / stop / TP / SL cannot transfer value to Gains LPs (`LC_LimitStopFork.t.sol`, 7 tests).

**Exits and liveness (3.3).** Static call graph and dynamic `vm.expectCall(..., 0)` on feeds, `price`, `navPrice`,
`checkOrder` for closeTrade, reduceTrade (every caller incl. the operator), cancelOrder, cancelTimedOut, flatten,
setSlTp, requestRedeem, cancelRedeemRequest, claim (`LC_LivenessFork.test_lc_exitsNeverCallPolicyPrices`,
`test_lc_exitsWorkWithEveryPriceSourceDown`, existing `GainsExits.t.sol`). MAX_POSITIONS never blocks an exit (22
items). Gas at 20 positions within limits: totalAssets 8.06M / checkRisk 8.06M / settle 8.30M, worst NAV reader 9.15M
(20 trades + 20 pending leverage decreases), flatten of 20 trades 24.2M of Arbitrum's 32M (lifecycle/GAS.md).

**Round 4 diff and HL history (3.6).** 96 HL contract finding ids retested: 54 hold, 0 regressed, 29 N/A
(HyperCore-only), 13 covered by the domain tests above (gov/HL-RETEST.md). The depositor flow, settle modes, insider
deferral, carry, checkpoint rule, emergency exit rule and fee logic are textually identical to round 4 apart from
reading the venue once.

**Executor and keys (3.7).** No online key is shared across chains (boot check `distinctHotKeys`); the operator applies the
exact `operatorReduceCap` and never over-reduces; cancel races between the submitter's own cancel, the timeout sweep and
a late fill cannot double-fill; the keeper's risk mirror matches `_check` integer for integer (tools/executor/RESULTS.md).

**Tooling (4).** See section 6.

## 6. Tooling

Run limits. Following the lead's instruction during the review, mutation testing was capped at about 3 hours of runtime
and each Halmos or Medusa run at about 2 hours. Every cap below is stated where it applied; nothing below the caps
is claimed as proven.

**Static analysis** ([tools/SLITHER-TRIAGE.md](tools/SLITHER-TRIAGE.md), [tools/ADERYN-TRIAGE.md](tools/ADERYN-TRIAGE.md)).
Slither 0.11.6, all detectors, src/gains: 176 results, 0 findings, 125 informational, 51 false positives. Aderyn 0.6.8:
166 instances, 0 findings, 88 informational, 78 false positives (its two "High" types are calls to the factory's own
clones, USDC or the diamond, and a storage-array false positive). Informational items carried into this report: the
factory accepts `sequencerFeed_ = 0` (GR1-10); `create()` writes the vault registry (GainsVaultFactory.sol:319-321)
after the ETH call to the agent (:315), harmless because every reader is role-gated, free to reorder; `minGovFee`
divides before multiplying (GainsNav.sol:157-158), < 1e-6 USDC per pending order.

**Mutation testing** ([tools/MUTATION.md](tools/MUTATION.md), [tools/mutation-results.csv](tools/mutation-results.csv)).
Gambit generated 8,493 mutants over all 11 files. A full run was out of reach: via_ir cannot be turned off (the tree
does not compile without it, stack too deep at GainsNav.sol:96), Foundry's cache never hits on this machine, and one
compiling mutant took 3.5 to 8 minutes. **The run is limited** to a seeded sample of **110 mutants** from the
security-relevant functions of GainsNav, GainsPrice, GainsVaultPolicy, GainsVaultLogic (requestRedeem, cancel, claim,
settle, fees, reduceTrade, flatten, _mayExit) and GainsVaultFactory (create, agent registration, role setters,
ownership, curation); line ranges in MUTATION.md. GainsVaultMath, GainsVaultGovernance, GainsVault, GainsVaultLens,
GainsTypes and IGainsDiamond are not in the score. The suite ran with a test-only `deployCode` patch
(tools/mutation/deploycode.patch, applied only in scratch copies, never committed; 295 / 295 green before mutation).

| File | Generated | Sampled | Compile-fail | Killed | Survived | Score |
|---|---|---|---|---|---|---|
| GainsNav | 571 | 25 | 11 | 14 | 0 | 100% |
| GainsPrice | 299 | 20 | 11 | 9 | 0 | 100% |
| GainsVaultPolicy | 1,134 | 20 | 13 | 5 | 2 | 71.4% |
| GainsVaultLogic | 2,379 | 30 | 15 | 14 | 1 | 93.3% |
| GainsVaultFactory | 944 | 15 | 8 | 6 | 1 | 85.7% |
| **Sample** | | **110** | **58** | **48** | **4** | **92.3%** (killed / (killed + survived)) |

Mutation testing found a bug in this review's own test: `AccessMatrix.t.sol` counted mismatches in storage and
`vm.revertToState` reset the counter every cell, so it could never fail (mutant GainsVaultLogic#2009 logged 6
mismatches and passed). Fixed in 4cdda5c; re-run on the unmutated contracts: 4,428 cells, 0 mismatches; the mutant is
now killed. Score before the fix 90.2% (46 / 51). Regression PoC: `static/RevertToStateCounter.t.sol`. No other audit
test accumulates results in storage across `revertToState`. Survivors, none a contract bug: GainsVaultLogic#952
(settle `carryOrigin = 0` → 1; gap: two separate carry runs then claims), GainsVaultPolicy#207 (checkOrder slippage band
shrinks to ~0; liveness only; gap: tests at both band edges), GainsVaultPolicy#753 (applyTimelockDelay leaves the eta;
no security effect), GainsVaultFactory#684 (setGuardian role check deleted; equivalent, covered by the other setters'
invariants).

**Halmos** ([tools/HALMOS.md](tools/HALMOS.md)). Proven (9): operator cap OB1 (cap(0) = 0), OB2 (shortfall ≤ cap ≤
shortfall + 2% + 1 USDC), OB4c (no revert below 2^64); SM1 (floor ≤ ceil ≤ floor + 1), SM6 (priceAt = toAssets(one
share)); NV4, NV4c, NV5 (impact and spread never favour the trader), NV8 (notional cannot overflow). Counterexamples (4):
NV6b and NV4b rediscover GR1-24 (ADVERSETRUNC) and its priceAfterImpact sibling; OB4b is the expected overflow at a
shortfall of 2^256 − 1; NV7 was a tolerance error in the property (adverse floors by one 1e-10 unit toward the vault;
NV7b holds on fuzzing). **Not proven (timeouts):** everything through `mulDiv` or signed 256-bit division:
SM2-SM5, SM7-SM9, CL1-CL3, FE1-FE6, NV1-NV3, NV4d, NV6, NV6c, NV7b, OB3, OB3b, OB4, on bitwuzla and yices, including
narrow-domain twins. Caps: the NAV run finished at 2.03 h; the first share / fee runs were stopped at ~2 h 05 min and
re-run per function with a 120 s query timeout; the fee re-run was stopped at 55 min on FE3, so FE3-FE6 have no symbolic
result. Every unproven property has a fuzz twin: 42 / 42 pass at 100,000 runs each (`symbolic/SymbolicFuzzTwins.t.sol`).

**Invariant fuzzing** ([tools/FUZZING.md](tools/FUZZING.md)). New Foundry suite `invariants/GainsSpecInvariants.t.sol`,
one `invariant_spec` over SPEC D1, D4-D7, S1, S3, S8, N1 (NAV against an independent sum), T4, K1, F2-F4, G1, R5, X1, X2
plus share and escrow accounting: **2,048 runs × 500 depth, 1,024,000 calls, no invariant broken** (62.5 min); a calm
campaign (emergencies 33x rarer) 512 × 500, pass. Coverage limit: about 10 settles per 500-call run and few accepted
operator reduces, so R5 is tested mostly on its refusal side. Medusa (`invariants/medusa/GainsMedusa.sol`), **capped at
1 h**: 1,439,150 calls, 14,454 sequences, 19 / 19 properties and assertions pass; line coverage GainsNav 82%, GainsPrice
88%, GainsVaultLogic 60%, GainsVaultMath 54%. Echidna not run (Medusa covers it).

**Differential NAV** ([nav/DIFF-RESULTS.md](nav/DIFF-RESULTS.md)). Max 0.005 bp over 79 valuations (section 5).

**Fork replay** ([tools/FORK-REPLAY.md](tools/FORK-REPLAY.md), `replay/VaultReplayFork.t.sol`, 20 tests). 19 real gTrade
exits (7 market closes, 4 partial closes, 3 TP, 3 SL, 3 liquidations; BTC, ETH, SOL; 5x-111x) replayed through a factory
vault, each forked at its own transaction: vault USDC equals Gains' payout to the wei in 19 / 19; max error against the
real trader 0.031 bp of notional after removing the trade's own fee history (0.086 bp gross); GainsNav never above the
payout (4.5-25.9 bp below with the band, exact at band 0 on market closes); the liquidation zero rule held. TP / SL fill
up to 0.086 bp away from the market-close path (an open question for Gains, inside the band).

**External integrations** ([tools/INTEGRATION.md](tools/INTEGRATION.md), `integration/`, 17 tests). GR1-08, GR1-44.
Sound: all 34 selectors exist on the live diamond with the layouts of IGainsDiamond; units and collateral index 3;
exact approvals back to 0; every read and feed is a staticcall; a malicious diamond reaches only permissionless entry
points; a hooked token cannot double pay; no receive / fallback, the factory keeps no ETH.

## 7. How to reproduce

```bash
cd contracts
export ARBITRUM_RPC_URL=<archive RPC>             # fork suites skip without it
forge test --match-path "test/audit/gains/**"     # every PoC and verification test of this review
forge test                                         # whole project: existing suites green, PoCs pass as demonstrations
cd ../server && npm ci && npx vitest run --config ../contracts/audit/gains/tools/executor/vitest.config.mjs
npx vitest run --config ../contracts/test/audit/gains/xreview2/vitest.config.mjs
```

**Final run** (2026-10-17, tree 12b1e32, forge 1.8.4, ARBITRUM_RPC_URL set): `forge test` → 93 suites, **743 passed,
0 failed, 2 skipped** (the same 2 skips as the baseline of 65 suites / 519 passed before this review), 1,888 s; every
existing suite green and every PoC of this review passing while its issue exists. The 2,048 × 500 invariant campaign
is part of this run. Vitest: executor 18 / 18, cross-review 3 / 3.
