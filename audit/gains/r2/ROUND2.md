# Gains contracts: internal review, round 2 (fund-flow and adversarial depth)

**This is an internal, AI-assisted review. It is not an independent audit and must not be presented as one.**

Status: **final** (2026-10-21). Every campaign in the brief ran: conservation invariant 2,048 × 500, Medusa 12 h,
mutation (96.3%), Halmos (30 min per property, the owner's cap), static analysis, the final gates (section 7). Fixes
with fix tests for every High and Medium are in section 3 and [fixes/](fixes/).

Branch `audit/gains-r2`, worktree `dv-audit-gains-r2`, from `origin/main` 4ec6feb, the commit that deployed the current
Gains factory [an earlier factory]. Nothing in `contracts/src` or `server/src` was changed; nothing deployed, sent, pushed or
merged. Method and rules: METHOD.md (not included).

## 1. Executive summary (plain language)

**Is money safe today?** Yes, in practice. The live vault ([an earlier vault]) holds about 22 USDC under a 101 USDC cap, has
minted no shares and opened no trades, and the code behind it is exactly the reviewed code and cannot be changed.
Nobody outside the vault's own roles can take money from it, and no path sends USDC anywhere except into the vault's
own trades, to redeemers, or to capped fees.

**What must be fixed before outside deposits?** Four things, all in the contracts, so they need a new vault
implementation and a migration:
1. **GR2-LIVE-01 (High):** settling gets more expensive with every trade the vault has ever made, because Gains' list
   reads walk the whole history. A busy vault eventually cannot settle normally, and an insider or stolen trading key
   can push a vault into a narrow band where it can never settle again. Monitor the counters now (ALERT.md); fix by
   tracking the vault's own open indexes.
2. **GR2-KEY-01 (High):** a stolen agent or manager key can deliberately lose the vault's money to its own opposite
   trade on Gains through price impact: about 5k USDC per round trip on a 1M vault, ~55–60k per day before the
   daily-loss breaker. Fix (GR2-KEY-01b, owner decision D10): cap each pair's notional at 1% of Gains' skew depth (BTC, ETH, SOL at launch;
a per-pair factory setting the guardian lowers at once and raises only after 31 days, at most 10%), a turnover budget,
a 10-minute minimum hold on agent and manager closes, and the risk check inside `openTrade`. At 1% the attack loses
money for the thief at every vault size (fork-measured); break-even is about 2.13% for BTC / ETH and 1.5% for SOL.
3. **GR2-ECON-03 (Medium):** a settle during a leverage breach lets new depositors in without first charging the
   performance fee, so they pay it on gains they did not share (1.44% of a 100k deposit in the test). One-line fix,
   tested.
4. **GR2-KEY-06 (Medium):** a stolen guardian, owner or sentinel key held together with shares can trigger an
   emergency at a price dip and pay redeemers the dip price, keeping the rebound (10% of a redemption in the test).

Also before outside deposits: GR2-CFG-01 (Medium, enforce timelock ≥ epoch), alerts on queued policy changes and on
emergency triggers, and the corrected first steps in ALERT.md (on the live vault the owner is the manager, so
`triggerBreach`, not a pause).

## 2. Summary table

Severity scale: ROUND1 (brief section 5). Every finding was challenged by a second sub-reviewer (XREVIEW-*.md); the
"Cross-review" column says what changed.

| ID | Title | Severity | Cross-review | Location | PoC |
|---|---|---|---|---|---|
| GR2-LIVE-01 | Settle / NAV / openTrade walk every Gains index ever used: normal settles stop fitting, a narrow band locks for good | **High** (organic part Medium) | Critical → High | GainsNav.sol:79-80, :124-139; Gains TradingStorageGetters.getTrades / getPendingOrders | `LivenessHistoryFork.t.sol::test_GR2_LIVE_01_*` (4), `XReviewLiveGnsHistoryFork.t.sol::test_GR2_XR_LIVE01_openTradeWalksTheSameList_lockOnlyInANarrowBandBelowTheOpenCeiling` |
| GR2-KEY-01 | Vault notional per pair is unbounded against Gains' skew depth: a stolen trading key routes vault loss to an opposite trader | **High** | Low → High (fork at live caps) | GainsVaultPolicy.sol:270-285; GainsVaultLogic.sol:445-487 | `XReviewKeySkewFork.t.sol::test_GR2_XR_08_skewOppositeProfits_ETH_V5M_A5M` (+ XR_05..07), `KeysSkewFork.t.sol::test_GR2_KEY_01_*` |
| GR2-ECON-03 | A leverage-breach settle mints deposits without crystallising the performance fee | **Medium** | Confirmed, new | GainsVaultLogic.sol:250, :256 | `EconPoC.t.sol::test_GR2_ECON_03_leverageBreachSettleChargesNewDepositorForOldGains`, `XReviewEconCfg.t.sol::test_GR2_XR_ECON03_managerForcesLeverageBreachAtWill_noPriceMove` |
| GR2-KEY-06 | Guardian / owner / sentinel keys choose when redemptions are priced at min(NAV, checkpoint) | **Medium** | New in cross-review | GainsVaultLogic.sol:231-232, :264-265; GainsVaultGovernance.sol:258-268 | `XReviewKey.t.sol::test_GR2_XR_01..04_*` |
| GR2-CFG-01 | Factory accepts policy timelock < maxEpochDuration: a redeemer can be trapped behind a loosening up to 29 days | **Medium** | Confirmed; High rejected (guardian rescue) | GainsVaultFactory.sol:251-327; GainsVaultPolicy.sol:329-341, :472-481 | `ConfigTimelock.t.sol::test_GR2_CFG_01_*`, `XReviewEconCfg.t.sol::test_GR2_XR_CFG01_*` |
| GR2-GNS-01 | A trade past its TP is valued at the market; Gains pays the TP | Low | Confirmed | GainsNav.sol:213-220 | `GainsSideFork.t.sol::test_GR2_GNS_01_takeProfitPastTheMarket_navAboveWhatGainsPays_redeemerOverpaid` |
| GR2-XR-01 | A crossed resting limit open is valued at its collateral; Gains opens it at the (worse) limit | Low | New in cross-review | GainsNav.sol:89-94 | `XReviewLiveGnsSideFork.t.sol::test_GR2_XR_GNS01_crossedLimitOpen_valuedAtCollateral_opensBelowIt_redeemerOverpaid` |
| GR2-XR-02 | Unclosable pair + stale feed: no settle mode pays, not even idle; only the owner's timelocked feed change helps | Low | New (re-raises GR1-09 + GR1-45 as worse) | GainsVaultLogic.sol:245; GainsNav.sol:96 | `XReviewLiveGnsStateMachine.t.sol::test_GR2_XR_LIVE_staleFeedOnAnUnclosablePair_noSettleModePaysEvenIdle` |
| GR2-ECON-02 | Loss-breach / exit-only settles pay min(NAV, checkpoint) at a settler-chosen moment | Low (design) | Medium → Low; key route split out as KEY-06 | GainsVaultLogic.sol:264-272 | `EconPoC.t.sol::test_GR2_ECON_02_*` |
| GR2-ECON-01 | A hedged book around a settle manufactures the bid / ask band | Low (design) | Confirmed | GainsVaultLogic.sol:280 | `EconPoC.t.sol::test_GR2_ECON_01_*` |
| GR2-CFG-02 | Raising maxEpochDuration un-overdues an epoch (new risk back on, stranger's emergency refused) | Low | Confirmed | GainsVaultMath.sol:183-185 | `ConfigTimelock.t.sol::test_GR2_CFG_02_*` |
| GR2-LIVE-02 | An owner's full stop holds every settle until the guardian acts or the epoch is overdue | Low | Confirmed | GainsVaultLogic.sol:226 | `LivenessStateMachine.t.sol::test_LIVE_SM_H1_*` |
| GR2-EXE-01 | Reduce-rate alarm counts a transaction once: EIP-7702 batching hides up to 20 reduces per tx | Low | Confirmed (7702 live on Arbitrum) | server venues/gains/reduceRate.ts | `executor/EXE_Alarm.test.ts` "GR2-EXE-01" |
| GR2-EXE-02 | A strategy close fails unretried while another actor's order is pending on the trade | Low | — | server venues/gains/submitter.ts | `executor/EXE_WrongAction.test.ts` "GR2-EXE-02" |
| GR2-EXE-07 | A fenced old owner's requeue resets the new owner's claim: one late open | Low | Confirmed | server db/mongo.ts:339-343, processor.ts:350-354 | `executor/EXE_SignalRace.test.ts` |
| GR2-CI-01 | An unknown-type order that holds nothing is valued at its collateral field (GV-02 fail-closed): fees accrue on the inflated NAV, and checkRisk raises the day start / peak from it (a false daily-loss breach when the phantom goes) | Low | Confirmed (XREVIEW-FIXES) | GainsNav.sol:180-183; GainsVaultGovernance.sol:184-190 | `ConservationInvariants.t.sol::test_GR2_CI_01_unknownTypeOnNonHoldingOrderOverstatesNav`, `xr-fixes/XRCi01.t.sol` |
| GR2-KEY-04 | Fee churn per full 5x turnover: 0.40% of NAV (BTC/ETH), 0.68% (SOL) | Info (measurement) | Confirmed | — | `KeysReferrerFee.t.sol::test_GR2_KEY_04_*` |
| GR2-GNS-02 | NAV re-implements Gains' close formula; a facet change makes it silently wrong (10 h emergency timelock) | Design | Confirmed | GainsNav.sol | design scenario |
| GR2-GNS-03 | Outsiders can move NAV through Gains skew; unprofitable below ~0.25–1.05M of vault value per pair | Info | Confirmed | GainsNav.sol:204-206 | `GainsSideFork.t.sol::test_GNS_skew_*` |
| GR2-CFG-03 | No platform veto on policy-side queues; re-allowing an allowed pair re-copies the feed | Info | — | GainsVaultPolicy.sol:367-381 | `ConfigLevers.t.sol::test_GR2_CFG_03_*` |
| GR2-FF-01 | Anyone can block an insider's redeem with a 10 USDC deposit on its controller until it cancels | Info | Confirmed | GainsVaultLogic.sol:64-67, :94 | `FundFlowR2.t.sol::test_GR2_FF_01_*` |
| GR2-FF-02 | `requestDeposit` pulls the asset before booking the request and `checkRisk` is outside the lock: with a callback-on-transfer asset, a reentrant `checkRisk` reads the queued deposit as NAV (false peak, then a false drawdown breach); not reachable with native USDC (no hooks, immutable factory asset) | Info | New (KNOWN-EXPLOITS KX-N1) | GainsVaultLogic.sol:68-73 | `KnownExploits.t.sol::test_GR2_KX_03_postSendHookAsset_queuedDepositReadAsNav_falseDrawdown_notReachableWithUsdc` |
| GR2-EXE-03..06 | Operator receipt timeout; repeated shortfall ask; 600 s wait for an unsent request; fence checked before simulate only | Info | — | server (EXECUTOR.md) | `executor/EXE_*.test.ts` |
| GR2-MUT-* / GR2-STAT-* | none: mutation 96.3% with no fund-relevant survivor; static analysis 0 findings; Halmos 9 / 17 proven, 0 counterexamples | — | — | — | MUTATION.md, STATIC-TRIAGE.md, HALMOS.md |

Counts: 0 Critical, 2 High, 3 Medium, 11 Low, 8 Info / Design.

## 3. Findings

For each High and Medium: **Fix** is the change proposed for the fix round, and **Fix test** names the test that
fails on the current code and passes with the fix, run in a scratch copy with the patch applied (patches, fix tests
and raw runs in [fixes/](fixes/); start with [fixes/COMBINED.md](fixes/COMBINED.md)). All five patches pass
`git apply --check` on 4ec6feb and apply cleanly one after another; built together they give 392 passing and 36
failing tests, every failure one listed under the findings below (PoCs of the fixed bugs, and tests to port). With
all five, GainsVaultLogic is 23,611 bytes of the 24,576 limit. The revised KEY-01 fix (KEY-01b, applied after the
five) needs one mechanical merge with KEY-06 at the end of `VaultStorage`; the resolved six-patch stack is fixes/STACK6.diff. Built together, GainsVaultLogic is 24,474 bytes (102 under the
limit: any further growth in the fix round first moves `_checkPairDepth` or `_lossGate` into GainsNav); 363 pass and
80 fail, 77 of them the expected per-patch failures and 3 test-setup ports (two "min hold" exits in other fix tests, one
30-day-epoch vault that CFG-01 now refuses), no contract bug (fixes/stack6-run.txt). To run a fix test, apply its `fix.diff` in a scratch
copy and copy `FixTest.t.sol` to `contracts/test/audit/gains/r2/fixes/`.

### GR2-LIVE-01 Settle / NAV / openTrade walk every Gains index ever used (High)

**Location.** GainsNav.snapshot (`_readTrades`, `_readPendingOrders`), `blockingOrders`, `hasPendingOrder`; reached from
`totalAssets`, `checkRisk`, every settle mode, `flatten`, `openTrade`, `increaseTrade`, `requestDeposit`. Gains:
`TradingStorageGetters.getTrades` loops `i < counter.currentIndex` and exits early only after the last OPEN trade;
`getPendingOrders` likewise up to the newest pending order. Indexes are never reused.

**Description.** Each lifetime trade index costs about 2,387–2,493 gas in every NAV read (fork, real diamond). A flat
vault pays for its whole history; one open trade at a high index forces nearly the whole walk. Only the manager or the
agent can consume the vault's indexes (no trading delegate; Gains files every order under its caller); a limit open
placed and cancelled consumes one index at gas cost only.

**Impact.** Normal settles stop fitting Arbitrum's 32M at about 4,700 (20 trades + deposits) to 13,200 (flat) lifetime
indexes; from there the vault must be wound down (guardian `triggerEmergency`, close by index with `flattenIndices` /
`closeTrade`, which do not walk the list, then the flat exit-only settle). Because `openTrade` walks the same list,
the counter can only grow while an open fits (~12,732); the flat exit-only settle stops fitting at ~12,650–12,670. A
vault whose last open lands in that ~60–80 index band can never settle again: every share is locked for good (clone,
fixed diamond). Both band edges are extrapolated from measured slopes; the 32M end-to-end run was impossible on the
public RPC.

**Likelihood.** Deliberate: the manager or a stolen agent key, ~2e11 gas (~2 ETH at 0.01 gwei), ~25,400 transactions,
stopping inside the band. Organic: ~1.7 years at 20 indexes/day, unmonitored, with normal settles already failing.
Impact critical × likelihood low → High (organic wind-down part Medium).

**Fix.** [fixes/GR2-LIVE-01/](fixes/GR2-LIVE-01/) (`fix.diff`, README with the design). The vault keeps its own index
set (a cursor over Gains' `getCounters` plus the tracked open trade and pending-order indexes, in an ERC-7201 slot) and
reads `getTrade` / `getPendingOrder` per tracked index, never the full lists. A permissionless `syncIndexes(maxSteps)`,
also run at the start of settle, checkRisk and the trading calls, prunes closed entries and picks up new ones; the
full-stop path never reverts on it. Until it ships: monitor `getCounters(vault, 0/1)` (alert 3,000, act 5,000), never
launch long-lived high-frequency strategies on this implementation; see ALERT.md (with the cross-review correction).

**Fix test.** `fixes/GR2-LIVE-01/FixTest.t.sol` (`LIVE01FixTest`, 4 tests): NAV equals the old reader's on a mixed state;
settle gas is flat in the lifetime index count. Unfixed: checkRisk 221k → 1.09M (300 indexes) → 293M (50,000), settle
356k → 1.23M → 340M. Fixed: settle 372,330 at 0, 300 and 50,000. Existing tests to port: the 9 that inject malformed
`getTrades` / `getPendingOrders` output (GV-01 ×3, GV-02 ×2, GR1-08 ×3, `NavSkipsClosed`) move to per-index mocks.
Still for the fix round: decoding of `getCounters` / `getPendingOrder` and limit executions creating new indexes on the
real diamond; gas at 20 positions on a fork.

### GR2-KEY-01 Vault notional per pair is unbounded against Gains' skew depth (High)

**Location.** GainsVaultPolicy.checkOrder bounds an order by maxOrderNotional and the vault by maxLeverageBps only;
`openTrade` does not run `checkRisk`.

**Description.** Gains v10 skew impact moves a pair's execution price with net open interest. A thief holding the agent
or manager key opens and closes large vault positions on one pair while holding an opposite position on his own Gains
account; the opposite account is filled on the favourable side of the impact the vault creates.

**Impact.** Fork, ETH (depth 13.76M), 1M vault at the live 5x (5M notional): the vault loses ~13.0k per round trip, ~9.0k
of it routed; the thief nets **+5,036 / +5,043 / +5,048 USDC** per round trip on three blocks, on ~100k collateral.
About 55–60k/day before the 15% daily-loss breaker trips (the keeper's checkRisk runs every 5 min), ~190k to the 50%
drawdown. Break-even notional: ETH ~2.2M, SOL ~1.47M (SOL above break-even extrapolated: Gains did not execute the
vault's 5M SOL opens on the fork). At the live caps on a 100k vault the opposite account is net negative (KEYS.md).

**Likelihood.** A stolen online key plus outside capital; not exploitable on the live vault (101 USDC cap).

**Fix (revised, [FIX-DESIGN.md](FIX-DESIGN.md) §A–B, [fixes/GR2-KEY-01b/](fixes/GR2-KEY-01b/)).** The 5% cap below does
**not** close the finding: a thief who flags his opposite trade `isCounterTrade` (Gains charges it 0.43× the BTC/ETH
fee, 0.4× SOL, with fee tiers on top) and holds through a vault double swing still nets **+63.35 USDC** per round trip
at the 5% cap (fork, block 516,673,656). KEY-01b on top of KEY-01: per-pair cap **1%** of skew depth (capture ≤ 1 bp,
below every cheapest thief cost: margin 2.1× BTC/ETH, 1.5× SOL); a **turnover budget** of 20 × NAV per day (token
bucket; churn destroys at most 1.6% / 2.7% of NAV per day); a **minimum hold** of 10 min / 2,400 L2 blocks from the
fill (`TradeInfo.lastPosIncreaseBlock`) for manager / agent exits only (the guardian, breach / emergency exits and the
operator are never held), longer than Gains' protection-close window at any value it may set. Fork on KEY-01b
(block 516,682,710): the same counter-trade thief **−41.00 USDC**; XR_08's 250k ETH order refused `pair depth`. Cost:
per-pair capacity BTC 329k / ETH 140k / SOL 41.6k notional. Gains' protection close factor (20×, 750 blocks) only
multiplies the depth-band impact on a profitable close (BTC / ETH have none), so it does not change the route's sign.
Open for the fix round: the capacity cost, k as a constant or config, 39 tests and 6 ACCESS-MATRIX rows to port, fork
gas at 20 positions.

**Fix, revision 2 (owner decisions, 2026-10-21).** Two decisions change the fix.

1. **The cap is a per-pair factory parameter**, `GainsVaultFactory.pairSkewCapBps(pair)`, which every factory vault reads
   at each open, increase and limit or stop placement.
   - Lowering: the guardian or the sentinel, at once; it also drops a queued raise.
   - Raising: **only the guardian** queues it and executes it after **31 days**: the longest epoch any policy accepts
     (`GainsVaultPolicy.MAX_EPOCH_DURATION`, 30 days) plus one day, derived from that constant (exit before effect).
     The sentinel may lower and cancel, never raise.
   - Ceiling: **10 %**.
   - A pair never set takes **no new exposure** (A-7). The guardian's first setting is immediate up to 1 %.
   - Standalone vaults keep the 1 % constant.
   - Defaults: BTC, ETH and SOL at 1 %.
   - Cost: `GainsVaultLogic` grows to 24,113 bytes (463 left), and a factory vault's open costs +6.6k gas.
2. **Gains' own TP / SL closes are never held.** The hold restricts only the agent's and manager's close, reduce and
   flatten.

**Decision D10 (owner, 2026-10-21).**
- **At launch** the cap is 1 % of skew depth on BTC, ETH and SOL.
- **Only the guardian may raise it,** to at most the 10 % ceiling in code, and every raise waits 31 days.
- **Break-even** is about 2.13 % for BTC / ETH and about 1.5 % for SOL against the cheapest possible opposite account.
  A cap above a pair's break-even lets a thief with the agent or manager key profit (KEYS.md).
- **Docs note for the fix round.** The fix round edits the docs site; this review only writes in the audit folders. The
  sentence for the depositor and manager docs is:
  > On gTrade vaults, the platform limits how large a position a vault can hold on each market to 1 % of that market's price-impact depth (BTC, ETH and SOL at launch); only the platform guardian can raise this limit, to at most 10 %, and a raise takes effect 31 days after it is announced, so you can always withdraw before it applies, while a lowering takes effect at once.

**Circuit-breaker defaults for the executor (fix round WP3). These are proposed defaults, not yet code:** loss over 5 % of NAV in a rolling 24 h, or over 2 % in a rolling 1 h; drawdown from the peak share price over 10 %; opened notional over 5 × NAV in a rolling 1 h; on any of them the sentinel calls `revokeAgent()` and `setTradingPaused(true)` within 10 minutes (two keeper intervals).
The KEYS.md tables use them for the "with breaker" columns. The "code limits" columns do not depend on them.

Extraction bounds, from [KEYS.md](KEYS.md) "GR2-KEY-01b: extraction bounds": a model calibrated on the fork, worst-case
thief (counter trade + top fee tiers), with the turnover budget, the loss gate and an assumed circuit breaker; the TP / SL
residual is included.
- **At 1 %: 0** for 10k, 100k and 1M vaults. The route loses on every pair.
- **At 5 %:**
  - 100k: 3.7k per day, 12k per vault;
  - 1M: 38.5k per day, 135k per vault (without a breaker; about half with it).
- **At 10 %:**
  - 100k: 8.7k per day, 29k per vault;
  - 1M: 87k per day, 292k per vault.
- 10k vaults: 0 at every cap, because 5x leverage binds before the cap.

Fork, one block (516,927,412), counter-trade thief with no tier: **−37.47** at 1 %, **+59.95** at 5 %, **+761.71** at
10 %. A plain thief with no tier also wins at 10 % (+238.53). Break-even: 2.13 % (BTC, ETH) and 1.5 % (SOL).

**Fix (first version, superseded on the cap).** [fixes/GR2-KEY-01/](fixes/GR2-KEY-01/). Per pair, open + resting + pending + new notional ≤ 5% of Gains'
`getPairSkewDepth(collateralIndex, pair)` (selector 0xf0f045a7, verified against the Gains source; a depth of 0
refuses), and the daily-loss and drawdown limits are checked inside `openTrade`, `increaseTrade` and leverage raises
from the NAV already read. 5% is a third of the measured break-even ratio (ETH 0.16 of depth, SOL 0.36); it assumes
no Gains fee-tier discount above about two thirds. Also add an executor alarm on trade churn per caller.

**Fix test.** KEY-01b revision 2: `fixes/GR2-KEY-01b/FixTest.t.sol`, `KEY01bPairCapFixTest`. Its 7 per-pair cap tests
fail on the first KEY-01b tree and pass on rev. 2. They cover: the vault reads its pair's cap; caps are per pair; the
sentinel lowers at once; zero refuses with "pair cap"; a raise reverts `NotReady` at 31 days − 1 s and applies at 31 days; the delay equals the policy's
longest epoch + 1 day; only the guardian
raises; the 10 % ceiling; a lowering drops a queued raise; an unset pair takes no exposure.
`test_KEY01b_guard_gainsTpSlClosesAreNotHeld` passes on both trees: Gains' TP close goes through inside the hold, while
the manager's close is refused. Results: run-fixed-rev2.txt (not included) (15 / 15; mock
suite 376 pass / 45 fail, the same 45; first KEY-01b tree 8 pass / 7 fail) and run-fork-rev2.txt (not included) (4 / 4 at each of
1 %, 5 % and 10 %). First KEY-01b: `fixes/GR2-KEY-01b/FixTest.t.sol` (5 fail on the KEY-01 tree, pass on KEY-01b; guard test passes on both), `KEY01bForkFixTest.t.sol` (4 fork tests pass), `GasTest.t.sol` (openTrade +11.9k, manager close / reduce +18.3k, guardian close +0.1k on the mock); regression 367 pass / 45 fail, all of them tests that exit right after opening ("min hold") or ACCESS-MATRIX rows to update. KEY-01 (first version): `fixes/GR2-KEY-01/FixTest.t.sol` (`KEY01FixTest`, 5 mock tests): 4 fail + 1 guard pass unfixed → 5 pass
fixed; `KEY01ForkFixTest` on the real diamond (public RPC, tip − 40): patched PASS, the first ETH order past the cap
(~688k at depth 13.76M) refused with `OrderRejected("pair depth")`; 4ec6feb FAIL, all 20 × 250k opens accepted
(run-fork.txt (not included)). Gas added per open not yet measured at 20 positions. Existing
tests: 405 / 405 after adding `getPairSkewDepth` to `EvilDiamond`; fork PoCs above the cap must shrink their sizes.

### GR2-ECON-03 A leverage-breach settle mints deposits without crystallising the performance fee (Medium)

**Location.** GainsVaultLogic.sol:250 (`_accrueFees($, !$.breached && !$.emergency, venue)`) and :256 (the scheduled
raise switch), with a leverage breach still a normal (minting) settle (:230-231).

**Description.** Since REAUDIT3 (Change 7) no breach settle charges a performance fee. KNOWN-ISSUES I3-08 analysed only
redeemers ("never a depositor loss"). A leverage breach does not stop deposits from being minted, so new depositors buy
in at a price that still contains the uncrystallised gain and later pay the performance fee on it.

**Impact.** PoC: bob deposits 100k in a leverage-breach settle after a gain; he loses 1,438 USDC (1.44%) and the fee
recipient gains 1,419. The manager can force the breach with no price move: one open at exactly 5x reads 50,505 bps
after the fill, and the next `checkRisk` sets LEVERAGE. On the live vault the fee recipient is the owner / manager.

**Likelihood.** Manager discretion, any time gains are uncrystallised. Theft of yield → Medium.

**Fix.** [fixes/GR2-ECON-03/](fixes/GR2-ECON-03/): `withPerformance = !$.emergency && !redemptionOnly` for both the
fee charge (:250) and the scheduled-raise switch (:256); the lens uses the same rule. The patch inverts
`test_HL_R306_leverageBreachSettleKeepsTheRaiseScheduled` (renamed `..SwitchesTheRaiseLikeANormalSettle`). Also update
the docs, KNOWN-ISSUES I3-08 and the NatSpec at :248. (The HyperEVM `VaultLogic.sol:226` has the identical rule; out of
scope, not tested.)

**Fix test.** `fixes/GR2-ECON-03/FixTest.t.sol` (`ECON03FixTest`, 5 tests: no performance fee on pre-entry gains in a
leverage-breach settle; loss-breach and emergency settles still charge none; the raise switch follows the same rule;
lens parity): 3 fail + 2 guards pass unfixed → 5 pass fixed (the transfer is gone to the wei: bob 99,193.455362 and
the fee recipient 2,212.594996 with and without the breach). Existing suites 404 / 405; only the PoC
`EconPoC::test_GR2_ECON_03` fails.

### GR2-KEY-06 Guardian / owner / sentinel keys choose when redemptions are priced at min(NAV, checkpoint) (Medium)

**Location.** Exit-only pricing GainsVaultLogic.sol:264-265; `triggerEmergency` (guardian / owner at any time)
GainsVaultGovernance.sol:258-268; owner's instant `maxEpochDuration` tightening (makes the epoch overdue).

**Description.** Exit-only settles pay redemptions at min(NAV, checkpoint). After a sharp dip the checkpoint sits at the
dip and cannot be raised for an hour; whoever chooses the moment of the exit-only settle chooses whether redeemers get
the dip or the rebound. The difference stays with the remaining holders.

**Impact.** 100k vault at 4x, ETH −2.5% then full rebound: a 50k redemption is paid 44,610 instead of 49,600; a thief
holding the remaining shares gains 4,990. At 5x a common 1% dip-and-rebound is 5% of every queued redemption.
Routes: guardian key (emergency + settle at any time); owner key (emergency, or `maxEpochDuration` 1 h instantly then
an exit-only settle); sentinel key (slow route via repeated `triggerBreach`).

**Likelihood.** A stolen platform or owner key plus shares bought in advance; loud (emergency revokes the agent).
Medium. The non-key form (honest settler, checkpoint lag) is GR2-ECON-02 (Low).

**Fix.** [fixes/GR2-KEY-06/](fixes/GR2-KEY-06/) (also closes GR2-ECON-02's route and GR2-CFG-02). Exit-only and
redemption-only settles pay `min(NAV, cap)`: while the checkpoint is fresh, cap = max(checkpoint, the value its last
ratchet replaced); once stale, cap = what `checkRisk` would ratchet it to. The epoch deadline is fixed when the epoch
starts (closes the owner's instant-epoch route XR-03 and CFG-02 with one change). Also alert on EmergencyTriggered and
on epoch-shortening config. Trade-off kept from C-01: a NAV pushed up inside the bound is never paid; the only
weakening is one ratchet step inside the hour after a downward ratchet, never above a level the vault had at a
checkpoint (README).

**Fix test.** `fixes/GR2-KEY-06/FixTest.t.sol` (`KEY06FixTest`, 9 tests: XR-01..04 move nothing; the C-01 pump is
still capped; a stale low checkpoint is not a cap; lens parity with `previewEmergencyRedeem`; CFG-02 closed): 8 fail +
1 pass unfixed → 9 pass fixed. Existing suites 402 / 409; the 7 failures are all round 2 PoCs (XR-01..03, ECON-02 ×2,
XR_ECON02, CFG-02); the C-01 / D1 / D4 tests pass.

### GR2-CFG-01 Policy timelock < maxEpochDuration traps redeemers behind a loosening (Medium)

**Location.** The factory and `GainsVaultPolicy._validate` allow timelockDelay ≥ 1 day and maxEpochDuration up to 30
days independently; loosenings apply after the policy timelock; normal settles are the manager's or operator's, and
the owner can remove the operator instantly.

**Impact.** A hostile owner queues a loosening and does not settle: a redeemer who asked to leave right after the
queue is exposed to the loosened policy for up to E − T (29 days). PoC (12x after a leverage loosening, ETH −5%):
10,000 USDC paid as 3,984.89, plus the raised management fee (≤ 0.24% of NAV). The live vault (T = 2 d, E = 1 d) reaches
T < E after one harmless-looking queue that raises E to 30 days. GR2-CFG-02 makes it worse.

**Likelihood.** Hostile owner, nobody watching: the cold guardian's `triggerEmergency` (no overdue condition) frees the
redeemer at any time, before or after the loosening applies (XR tests). No alert fires on `ConfigQueued` today.

**Fix.** [fixes/GR2-CFG-01/](fixes/GR2-CFG-01/): every loosening timelock (policy and vault) must be ≥
maxEpochDuration + 1 day, checked at initialize, propose and apply (new error `EpochAboveTimelock`). Consequence: the
shortest usable timelock is E + 1 day and the longest epoch 29 days; the webapp's fixed 2-day timelock allows epochs of
at most 1 day. Also alert on policy `ConfigQueued` / `AssetAllowQueued` / `TimelockQueued` and show maxEpochDuration
and queued items on the vault page.

**Fix test.** `fixes/GR2-CFG-01/FixTest.t.sol` (`CFG01FixTest`, 5 tests: the PoC launch is refused; raising the
live-shape epoch to 30 days with T = 2 days is refused): 5 fail unfixed → 5 pass fixed. Existing suites 386 / 405 with
the test harness `_defaultRisk` epoch changed from 7 days to 1 day; the 19 failures (7 CFG PoCs, 8 tests using a 1-day
timelock, `isTighterFieldByField`, 3 tests needing epochs longer than a day) are listed in the README.

### Cross-review of the fixes: what the fix round must change ([XREVIEW-FIXES.md](XREVIEW-FIXES.md))

All five patches close their findings (21 new tests in xr-fixes/ (not included), 20 on the combined patched tree, all
pass; the combined tree's 36 failures are exactly the listed ones). Before merging, the fix round must change:

| # | Patch | Issue found | Change |
|---|---|---|---|
| XF-02 (Low) | GR2-KEY-06 | Using `max(checkpoint, prior)` also in **redemption-only** settles stretches C-01's pump window from up to 1 h to up to 2 h right after a loss breach is recorded: 4x vault, ETH −4.5%, a 50% redeemer paid 48,602 patched vs 40,618 on 4ec6feb (+7,984, 16%) | Apply the fresh/prior cap only to **exit-only** settles (the key-chosen route); redemption-only keeps `min(NAV, checkpoint)` or the stale-ratchet rule |
| XF-01 (Low, pre-existing, extended) | GR2-ECON-03 | An overdue exit-only settle in a leverage breach now charges the performance fee on the uncapped NAV while redeemers are paid at min(NAV, cap) (−0.52% to the redeemer at +1% ETH); on 4ec6feb this already happens without a breach | In exit-only settles charge the performance fee on `priceNav`, or not at all (`!exitOnly`); same condition for the raise switch |
| XF-03 (Low) | GR2-LIVE-01 | close, reduce, flatten and cancelTimedOut do not sync: ~25.9k gas per unseen order in every NAV reader (mock); ~1,200 unseen orders push settle past 32M (anyone's `syncIndexes(100)` restores it; `triggerEmergency` 119k at 200 unseen) — no lock | Bounded sync in `reduceTrade`, `closeTrade`, `flatten`, `flattenIndices`; bound settle's sync or revert `MAX_UNSEEN` pointing to `syncIndexes`; keeper syncs routinely; port the 9 tests as in `xr-fixes/XRLive01Ports.t.sol` |
| XF-04 (Info) | GR2-KEY-01 | The cap assumes `getPairSkewDepth` is in tokens; the fee-tier assumption behind 5% is unverified | Sanity-bound the returned depth; verify the fee tier |
| XF-05 | CFG-01 / KEY-06 (webapp) | `GainsLaunch.tsx` sends a fixed 2-day timelock with a free epoch field (epochs > 1 day revert the launch with CFG-01); `GovernanceCards.tsx` likewise; `GainsCards.tsx:487`, `gainsChain.ts:146` compute overdue as `epochStartedAt + maxEpochDuration`; the "instant" label on epoch tightening is wrong under KEY-06 | Cap the epoch or derive the timelock from it; read `epochDeadline()`; relabel |
| — | KEY-06 × CFG-01 | One interaction test | Keep the KEY-06 CFG-02 test with an epoch raise that fits the timelock (COMBINED.md) |
| — | GR2-CI-01 | — | Both: accrue no fees and raise no day start / peak while an unknown-type order is pending |
| XF-06 (from FIX-DESIGN) | GR2-KEY-01 | The 5% pair cap leaves a counter-trade thief +63.35 USDC per round trip (re-measured with rev. 2 on block 516,927,412: +59.95 at 5 %, +761.71 at 10 %) | Use KEY-01b. Rev. 2: a per-pair factory cap defaulting to 1 % on BTC, ETH and SOL. Keep every pair below its break-even (2.13 % BTC / ETH, 1.5 % SOL); 5 % and 10 % make extraction positive from about 100k NAV (KEYS.md) |

**Fix-round work package WP3 (executor), proposed defaults, not yet code:** a circuit breaker that trips on loss over 5 % of NAV in a rolling 24 h, or over 2 % in a rolling 1 h; drawdown from the peak share price over 10 %; opened notional over 5 × NAV in a rolling 1 h; on any of them the sentinel calls `revokeAgent()` and `setTradingPaused(true)` within 10 minutes (two keeper intervals).
It goes with the KEY-01b alarms on `PairSkewCapQueued` and on Gains fee or multiplier changes, and with retries on
"min hold" (FIX-DESIGN.md, "WP3: executor defaults").

CFG-01 bricks no configuration: every tightening still applies instantly on the live shape, and a 7-day epoch stays
reachable by raising both timelocks first. KEY-01's new checks run on opens only; no exit, settle, checkRisk or NAV
read calls them, and a stranger cannot move either gate. LIVE-01's index set matched Gains' open items after every
step of 256 random histories × 60 steps, including Gains' own limit executions and strangers' syncs.

### Low findings

| ID | Finding | Impact × likelihood | Fix |
|---|---|---|---|
| GR2-GNS-01 | Gains executes a crossed TP exactly at the TP; NAV values the trade at the market until the bot triggers | 200k vault, 500k ETH at 100x, TP +1%, market +2%: NAV +4,123 (2.0%), a 50% redeemer overpaid 2,061.51 at the stayer's cost; ≤ ~5% of NAV at 5x × a settle inside the trigger latency (seconds; longer in a Gains pause). A watching manager can win the race but cannot cause the overshoot | value a trade whose TP lies between the open and the valuation price at the TP (`min(P, TP)` long / `max` short) |
| GR2-XR-01 | A resting limit open whose trigger the market has passed is valued at its collateral; Gains opens it exactly at the limit | 500k at 20x, market 1% past the limit: NAV 200,001 before vs 193,633 after the fill (3.2%), a redeemer overpaid 3,183.98 × same window as GNS-01 | value a crossed resting open as a trade opened at its limit |
| GR2-XR-02 | Pair Gains will not close + that pair's feed stale: every settle mode reverts PriceStale, idle is not paid | 8,001 idle vs a 25% redemption unpaid; permanent with a hostile / absent owner (feed rotation is owner-queued) × two Gains-side failures at once | exit-only settle values an unpriceable pair at 0 (or pays from idle at a capped NAV) — GR1-09's design decision, now with a worse case |
| GR2-ECON-02 | Redemption-only and exit-only settles pay min(NAV, checkpoint); the checkpoint lags a rebound by up to an hour | −15.2% on a rebound within 30 min (redemption-only, capped by NavMoved and avoidable by cancelling); exit-only on owner == manager is a normal settle — the key route is GR2-KEY-06 | as KEY-06 (fresh checkpoint only) |
| GR2-ECON-01 | A delta-neutral long + short opened only around a settle charges every flow B × leverage | ≤ maxNavMove / 8 per flow (1% live); with real fees it pays only on flows ≥ ~56% of NAV | accept (documented band) |
| GR2-CFG-02 | A loosening that raises maxEpochDuration makes an overdue epoch current again | Re-enables new risk and refuses a stranger's triggerEmergency for 30 − T days unless someone triggers within T − E_old | per-epoch deadline fixed at epoch start |
| GR2-LIVE-02 | An owner's `triggerBreach` blocks every settle outside emergency and can be re-triggered after the guardian's clear | Redemptions held ≤ maxEpochDuration; ended at once by the guardian's emergency, or by any depositor at overdue | allow redemption-only settles in a guardian-reason breach |
| GR2-EXE-01 | Reduce-rate alarm counts one transaction once (R2-01) | EIP-7702 (live on Arbitrum, ArbOS 61) batches up to 20 reduces per tx: ~2,866 USDC/day (2.9% of a 100k vault) unseen vs ~143/day without batching; the agent's open/close churn is not alarmed at all; the owner (= manager live) is exempt | count events per caller (keep only the guardian exemption); alarm on open/close churn |
| GR2-EXE-02 | Strategy close reverts "no position to reduce" while another actor's order is pending, not retried | full position held for the ticket's life × a few-second overlap | retry after the pending order resolves; correct the alert text |
| GR2-EXE-07 | `requeueSignals` on a fenced owner resets any PROCESSING row incl. the new owner's | one stale open of the intended size, within policy; a late open after the strategy's close is refused by `ticketSignalSeen` | requeue only rows claimed by the fenced owner's token |
| GR2-CI-01 | GV-02 values an unknown-type order at its collateral field even when it holds nothing; settle is blocked (correct) but `accrueFees` / `setFees` charge on the phantom, and `checkRisk` raises the day start and peak from it | 100k vault, 40k phantom: +2.19 USDC/day at 2% (5.48 at 5%). A phantom > 17.6% of NAV at the day's first check gives a false daily-loss breach when it goes (2,030 bps with no loss in the test) and keeps 20% of the drawdown budget used until `resume()`. No value moves to anyone × needs a Gains upgrade reporting a type outside 0..13 (very low) | accrue no fees and raise no day start / peak while an unknown-type order is pending |

### Informational and design

| ID | Item |
|---|---|
| GR2-GNS-02 | GainsNav re-implements Gains' close formula; a facet cut that changes it (PnL cap, fee basis, impact term) makes NAV silently wrong. Gains cuts ~monthly (28 cuts since 2024-05; the 2026-09 cuts replaced 29 of the vault's 34 selectors), via a 3-day or a 10-hour emergency timelock. Watch the timelocks and replay the NAV-diff suites against scheduled cuts. |
| GR2-GNS-03 | Outside skew moves NAV by 153 / 362 / 1,224 USDC per 1M skew per 1M vault notional (BTC / ETH / SOL); the outsider's round trip costs 8.0 / 8.0 / 15.3 bp; break-even 1.05M / 0.44M / 0.25M of vault value on one pair at 5x; max-skew caps the move at 0.15–0.55%. |
| GR2-KEY-04 | Round-trip cost measured 8.0 bp (BTC/ETH), 13.6 bp (SOL) of notional. |
| GR2-CFG-03 | No guardian veto on policy-side queues; `queueAllowAsset` on an allowed pair re-copies the factory feed outside the guardian-cancellable vault queue (cold factory owner, GR1-40 trust). |
| GR2-FF-02 | Book the deposit request before `safeTransferFrom`, or run `checkRisk` under the lock (hardening; native USDC has no transfer hooks). |
| GR2-FF-01 | A stranger's 10 USDC deposit on an insider controller blocks its `requestRedeem` until it cancels (refund goes to the insider). Non-insiders unaffected. |
| GR2-EXE-03..06 | `single()` marks a landed operator reduce failed after a receipt timeout; the operator re-asks the full shortfall while a reduce is pending (≤ 1,533 for 500); a never-broadcast request is waited on for 600 s; agent sends check the fence before simulate only. |
| Lead notes | `cancelRedeemRequest`'s `_claimIfSettled` is dead code (rolled back by the revert at :132), NatSpec :128 misleading (MUT). The virtual-offset shares hold what a full exit leaves behind; nobody can capture it (XR-ECON). |

## 3b. Known exploit classes ([KNOWN-EXPLOITS.md](KNOWN-EXPLOITS.md))

16 classes, each with 1–2 public incidents verified at the source (39 sources, accessed 2026-10-20) and a test or a
precise reason: **exposed 2, partly 5, not exposed 8, not applicable 1.**

- **Exposed:** 6b skew / thin-pair self-dealing (GR2-KEY-01), 11 key / signer compromise (GR2-KEY-01, -06,
  GR2-ECON-03).
- **Partly:** 5 NAV / oracle manipulation (GNS-01, GNS-03, XR-01, ECON-01, Chainlink lag), 12 fee / HWM (ECON-03,
  XF-01), 13 sequencer / stale feeds (XR-02), 14 governance / queued-change traps (CFG-01, CFG-02, XR-03, CFG-03),
  15 perp-venue oracle and maths (trust T2, GNS-02).
- **Not exposed:** 1 share inflation, 2 donation, 3 reentrancy (with USDC; GR2-FF-02 for hooked assets), 4 rounding,
  7 access control, 8 arbitrary call / approvals, 9 clone init / delegatecall, 10 signatures.
- **Not applicable:** 6 Hyperliquid-specific (no HyperCore path in `src/gains`).

Six new tests `KnownExploits.t.sol::test_GR2_KX_01..06`; one run of 24 cited suites: 324 passed, 0 failed. No class
is exploitable on the live vault. The seed list was corrected where the sources differ (Wormhole 2022 and Enzyme
2023 were bounties, not exploits; Curve 2023 was a Vyper compiler bug; JELLY's HLP loss was unrealised; amounts
and dates per the sources).

## 4. Open questions

1. **Chainlink lag above the band (ROUND1 T3, unchanged).** No full in/out cycle profits in the model, but a holder
   timing a one-way exit gains (lag − B) × leverage when the lag exceeds B (up to 145 bp per settle at 50 bp of lag).
   Needs fast-market measurements of Gains' oracle against the Chainlink round.
2. **Five unverified Gains facets** (TradingStorage, TradingCallbacks — which pays every close — PairsStorage,
   PriceAggregator, one unidentified): behaviour is inferred from bundled libraries and fork tests.
3. **Who can call PairsStorage setters and pause, with what delay**, and the proposer/executor sets of Gains' three
   timelocks.
4. **GR2-LIVE-01 end to end at 32M** (needs an archive RPC: `LIVE_N_E2E=13400`), and whether an EIP-2930 access list
   can rescue a vault inside the band.
5. **GR2-KEY-01 on SOL above break-even** (Gains refused the fork's 5M SOL opens) and whether the keeper's checkRisk
   fires inside a churn burst.
6. **Whether a vault-side pending market close delays Gains' TP trigger** (would make GNS-01's window manager-controlled).
7. **CFG-01 residual depends on guardian reaction time** (operations).
8. **HyperEVM vaults** share ECON-03's rule (`VaultLogic.sol:226`); out of scope.

## 5. Checked and sound

| Claim | Test / evidence |
|---|---|
| No arbitrary call, no delegatecall to a mutable target, no caller-supplied recipient except the caller's own entitlement; one approve site, exact, cleared on every path (revert, try/catch, short pull) | FUND-FLOW.md; `FundFlowR2.t.sol` 31 tests |
| `execute()` reaches only the 8 whitelisted onlySelf setters; none moves USDC; 44 other calldatas refused | `test_FF_execute_*` |
| Gains third-party entry points cannot pull or redirect vault funds (delegated trading, referrer registration, triggers) | live `eth_call` reads; `KeysReferrerFee.t.sol::test_GR2_KEY_03_*` |
| Live code = reviewed code: vault and policy are EIP-1167 clones; all 7 deployed contracts byte-equal to the 4ec6feb build (metadata included); no SELFDESTRUCT / CALLCODE; initializers locked | CONFIG.md §1, `cfg/verify-onchain.sh` |
| Factory changes cannot move depositor value or lock exits (only guardian / sentinel rotation, fee recipient, lower share reach a vault) | `ConfigLevers.t.sol`, `GovFactoryMatrixTest` |
| Mis-set TP / SL do not hand in-the-money PnL to the pool (a far trigger fills at the market or is cancelled) | `KeysTpSlFork.t.sol::test_GR2_KEY_02_*` |
| No positive PnL cap in Gains v10; NAV ≤ payout on a +1,188% winner | `GainsSideFork.t.sol::test_GNS_noPositivePnlCap_*` |
| Gains manager parameter changes and manual realizations move NAV and payout together / not at all | `test_GNS_managerSkewDepthChange_*`, `test_GNS_managerManualRealizations_navNeutral` |
| gToken payout refusal delays, never shortchanges; USDC blacklist / pause fail closed without misvaluing | `test_GNS_gTokenRefusesPayout_*`, `test_GNS_usdcBlacklistDiamondAndPause_*` |
| SL, STOP and liquidation valuations are conservative | `XReviewLiveGnsSideFork.t.sol::test_GR2_XR_GNS01_crossedStopOpen_conservative` |
| Independent model of fair share price vs the real vault over 22 strategies × 3 sizes × 8 seeds × 60 epochs + 256 fuzz runs: 0 wei divergence; round 1's timing games (GR1-02 residual, lag options, split requests, carry options, fee timing, insider deferral, dust, partial-fill order) lose or are neutral | ECONOMICS.md, `EconDiff.t.sol` (ffi, `ECON_FFI=true`), `econ/table.json` |
| Every depositor exits a young vault (except the listed Gains-side and both-platform-keys-gone cases); worst case maxEpochDuration + one Gains timeout + flatten + one settle per partial-fill round | LIVENESS.md §2, `LivenessStateMachine.t.sol` 11 tests |
| Gas at 20 positions on a fresh vault, all under 26M (flatten 24.34M, settle with deposits 14.72M) | `LivenessGasFork.t.sol` 8 tests |
| Executor: at most one request per order under every crash point, handover, late fill, lagging node and nonce reply tested; online keys distinct across chains and roles | EXECUTOR.md, `executor/EXE_*.test.ts` 44 tests |
| Static analysis: Slither 199 / Aderyn 184 results, every new one triaged, 0 findings | STATIC-TRIAGE.md |
| Conservation invariant (every USDC unit, incl. collateral in flight, only to the vault's own trades, a fair redeemer or capped fees): holds at **2,048 × 500** (1,024,000 calls, 0 reverts) on the real code; fails with the GR1-02 fix undone and with the GV-02 fix undone | CONSERVATION.md, `ConservationInvariants.t.sol` (4 / 4 in the worktree), `ci/sensitivity.txt` |
| Mutation on 396 fund-moving lines (GainsVaultLogic, GainsNav, GainsVaultPolicy, GainsVaultMath): every one of 2,115 type-valid mutants run; final **96.3%** (2,031 / 2,110), **99.95%** without the 78 argued-equivalent survivors (one open, Logic R140, no fund effect); no survivor shows a contract bug | MUTATION.md; kill tests `MutationKills*.t.sol`, `MutationKillsNavPure.t.sol` |
| Single-operation conservation (deposit / redeem request, both cancels, claim, settle in all four modes) proven symbolically for all inputs; operator reduce cap monotone; protocol split | Halmos 0.3.3: C1 to C6, N0, N7, N8 proven (HALMOS.md, halmos-results.txt); the other 8 timed out at 30 min and rest on their 100,000-run fuzz twins |

## 6. Tooling and caps

| Tool | Result | Cap / status |
|---|---|---|
| Slither 0.11.6 / Aderyn 0.6.8 | 199 / 184 results, every new one triaged, 0 findings (STATIC-TRIAGE.md). Slither needed a scratch copy with the round 4 duplicate struct names renamed (crash on duplicate `InitParams` / `VaultStorage`). | — |
| Mutation (Gambit v1.0.6 + 529 own ROR/LOR/UOD mutants) | 4,751 mutants; 2,641 compile failures excluded (2,636 type check, 5 via-IR); all 2,115 type-valid run; **2,031 killed, 79 survived: 96.3%** (b1 84.9% → b2 93.6% → b3 96.3%); 78 survivors equivalent with written arguments, 1 open (Logic R140: an empty settle rewrites already-initial values; only the `dayStartSharePrice` getter differs; an assertion was added but not yet run against the mutant); 99.95% with the equivalents removed (MUTATION.md) | ~4 h 22 min of the 12 h cap; not hit |
| Halmos 0.3.3 | **9 of 17 proven, 0 counterexamples, 8 timeouts** (C1 to C6 incl. settle in all four modes, N0, N7, N8 proven; N1 to N6 and C7, the nonlinear mulDiv / fee ones, timed out; all 17 fuzz twins pass at 100,000 runs). HALMOS.md, halmos-results.txt | **30 min cap per property hit 8 times** (owner's cap; 292 min total) |
| Conservation invariant (forge) | **PASS at 2,048 × 500** (1,024,000 calls, 0 reverts, 2,195 s; CONSERVATION.md §12) and at 512 × 500 in the invariant gate; fails as required with the GR1-02 fix undone (run 4 of 256) and with the GV-02 fix undone (run 1) | brief's campaign done |
| Medusa | **PASS, 39 / 39, 0 failures** over 12 h: 23,311,723 calls in 233,114 sequences, 12,855 branches (ConservationMedusa: 4 properties + 35 assertion handlers; CONSERVATION.md §13, ci/medusa-12h.txt) | **12 h cap hit** |

Notes: the first conservation and mutation sub-reviewers were stopped by accident and
restarted from their committed work; mutation batch 1 used 1 h 50 min of the 12 h cap; Medusa (12 h) runs at the brief's full cap; Halmos (30 min
per property, the owner's cap of 2026-10-21, lowered from the brief's 2 h). Fork tests ran on the public RPC, which keeps only 10–20 minutes of
state: every fork test must be re-pinned to a recent block (`*_FORK_BLOCK` env vars) to re-run.

## 7. Final gate

| Gate | Result |
|---|---|
| **Gate of record:** `forge test --no-match-test invariant_` at 755ba0b (the final audit commit before this write-up; includes KnownExploits.t.sol), gate/forge-test3.txt (not included) | **129 suites: 824 passed, 0 failed, 34 skipped** (1,719 s; skipped = fork suites without `ARBITRUM_RPC_URL` and the ffi EconDiff, as before) |
| `forge test --no-match-test invariant_` re-run at ca9ba81 (after the mutation kill tests landed), gate/forge-test2.txt (not included) | **128 suites: 818 passed, 0 failed, 34 skipped** (2,549 s); the same 34 skips (fork suites, ffi `EconDiff`). This is the gate of record. |
| `forge test --no-match-test invariant_` in the worktree at 264e4e6 (forge 1.8.4, no `ARBITRUM_RPC_URL`), gate/forge-test.txt (not included) | **121 suites: 781 passed, 0 failed, 34 skipped** (2,852 s incl. the 24 min build). The 34 skips are every fork suite (no archive RPC; the public RPC cannot serve their pinned blocks) and the ffi-gated `EconDiff`. Every non-fork PoC of this review passes as a demonstration, and every existing suite is green. The round 2 fork PoCs were run by their reviewers at recent blocks (raw outputs in the domain reports and fixes/). |
| Invariant suites at their configured runs (`GainsSpecInvariants` 2,048 × 500, `VaultInvariants` / `ReauditInvariants` 512, round 2 `invariant_conservation`) | **16 / 16 invariant tests pass** at ca9ba81 (11 suites, 2,991 s, gate/inv-gate.txt (not included)): `GainsSpecInvariants.invariant_spec` **2,048 × 500 (1,024,000 calls, 1,115 reverts)**; round 2 `invariant_conservation` 512 × 500 (256,000 calls, 0 reverts); the Reaudit / Vault / Verify suites at 512 runs |
| Executor `npm test` (server/, nothing edited), gate/server-test.txt (not included) | First half **983 passed, 1 failed, 9 skipped**: the failure is `dojipad-ec.test.ts` (backfill at activation), a timing test that also failed under load for the EXE reviewer; re-run alone **52 / 52 pass**. Because `npm test` chains with `&&`, the second half was then run separately: startup, cluster-roles, cluster-multiprocess **8 / 8 pass**. Not green in one run; every test green at least once; no failure is in the Gains executor code. |
| Round 2 executor tests (`test/audit/gains/r2/executor/`, 4 files) | **44 / 44 pass** |

## Assumptions (written down because nobody can be asked during the run)

| # | Assumption | Why |
|---|---|---|
| A-1 | VERIFY-R1.md is not on main; it is read from branch `verify/gains-r1` (bc0cdd0). | The brief lists it under "read first". |
| A-2 | No private archive RPC is configured in this session (`ARBITRUM_RPC_URL` unset; env files are off limits). Fork work uses the public endpoint `https://arb1.arbitrum.io/rpc`, which keeps only recent state (10–20 minutes in practice). Fork tests pinned to older blocks are reported as skipped, not as passing. | Brief: never touch env files. |
| A-3 | Live system at the start of the run (block 516,381,860, 2026-10-19): factory [an earlier factory] has one vault, [an earlier vault] (epoch 0, 21.5 USDC queued deposit, 1 USDC seed idle, 0 shares, no trades). The first factory [an earlier factory] has one vault [an earlier vault] holding 37 wei. "Live" in this report means these two. | On-chain reads. |
| A-4 | Severity follows ROUND1's scale; impact is stated for a 10k, 100k and 1M vault where the brief asks for it. | Brief section 5. |
| A-5 | "Theft" in the severity scale includes value routed to a key holder's own Gains account or own shares (GR2-KEY-01, -06), not only direct transfers from the vault. | Conservative reading. |
| A-6 | Proposed fixes are written and tested only as patches applied to scratch copies; `contracts/src` is never edited. Fix tests that assert the fixed behaviour live under `audit/gains/r2/fixes/` (not under `test/`), so the worktree's full `forge test` stays green on the unfixed code. | Brief: never edit `contracts/src`; final gate must be green. |
| A-7 | GR2-KEY-01b rev. 2: a pair whose factory cap was never set takes **no new exposure** (cap 0, `OrderRejected("pair cap")`), rather than defaulting to 1 %. The guardian's first setting of a pair up to 1 % is immediate. | Owner: "unset pair: conservative default (1 %, or refuse new exposure); pick the conservative one". Refusing is the more conservative of the two, because a pair with cheaper fees than BTC / ETH / SOL can be profitable for a thief at 1 % (KEYS.md). |
| A-8 | GR2-KEY-01b rev. 2: the factory had no waiting period of its own, so a minimal queue-then-execute was added. `PAIR_CAP_RAISE_DELAY` = `GainsVaultPolicy.MAX_EPOCH_DURATION` (30 days, the policy's real bound on `maxEpochDuration`, now a named constant) + 1 day = **31 days**. The earlier 7-day residual for epochs over 6 days is gone: every epoch any policy accepts is overdue (anyone can settle it) at least a day before a raise queued during it applies. Only the guardian raises; the sentinel may lower a cap and cancel a raise. | Owner (second message): "at least the maximum epoch length + 1 day … derive it from that constant"; "only the guardian raises". |
| A-9 | The circuit-breaker trigger levels (loss over 5 % in 24 h or 2 % in 1 h, drawdown over 10 %, opened notional over 5 × NAV in 1 h; revokeAgent + setTradingPaused within 10 minutes) are the **proposed executor defaults for fix round WP3**, not yet code. The KEYS.md "with breaker" columns use them; the "code limits" columns do not depend on them. | Owner: record them as the proposed WP3 defaults. |
| D10 | **Owner decision D10:** the pair cap is 1 % of skew depth on BTC, ETH and SOL at launch. Only the guardian may raise it, to at most the 10 % ceiling in code, after 31 days. Break-even is about 2.13 % (BTC / ETH) and about 1.5 % (SOL). The docs note for the fix round is in the GR2-KEY-01 fix section. | Owner, 2026-10-21. |
