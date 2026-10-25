# Round 2: fix design for GR2-KEY-01 (cap size, turnover, minimum hold) and Hyperliquid design input

**Internal, AI-assisted review. Not an independent audit; nothing here may be presented as one.** This document turns
the owner's design decisions into a fix design and checks each one against the code. The patch is in
[fixes/GR2-KEY-01b/](fixes/GR2-KEY-01b/), on top of [fixes/GR2-KEY-01/](fixes/GR2-KEY-01/). Nothing in `contracts/src`
or `server/src` was changed. No transaction was sent, and nothing was deployed or pushed.

Sources:
- the worktree `dv-audit-gains-r2` at 4ec6feb, plus the KEY-01 patch in a scratch tree;
- the verified Gains facet sources from Sourcify: GNSPriceImpact `0xDCAD…4e55`, GNSFeeTiers `0x846e…F2Fb`,
  GNSTradingInteractions `0x66B2…D327`;
- live values read with `cast call` on `https://arb1.arbitrum.io/rpc` (read only), blocks 516,668,542 to 516,673,656,
  2026-10-20.

## Summary

| # | Owner decision | Verdict | One line |
|---|---|---|---|
| A0 | openTrade already runs `policy.checkOrder` (D1) | **CONFIRMED** | Allowlist, Chainlink band (market orders only), max notional, projected leverage |
| A1 | Per-pair depth cap at 5 % of skew depth | **The cap exists (CONFIRMED). 5 % is not enough (WRONG)** | A counter-trade double swing makes a profit at 5 % on the real diamond. The cap must be **1 %**. **Revision 2 (owner):** the cap is a per-pair factory parameter set by the guardian (lowered at once, raised by the guardian only after 31 days = longest epoch + 1 day, ceiling 10 %, unset = no new exposure). **D10:** 1 % on BTC, ETH and SOL at launch (A1b) |
| A2 | Turnover budget | Designed and patched | A token bucket of **20 × NAV per rolling day** of opened notional |
| A3 | Minimum holding time | Designed and patched | **10 minutes** from the last new risk on the pair, plus **2,400 L2 blocks** from Gains' fill block. Applies to manager and agent exits outside a breach only. **Revision 2 (owner):** Gains' own TP / SL closes are never held |
| A4 | Loss gate inside openTrade | **CONFIRMED** (KEY-01 patch) | Unchanged |
| B | Gains' protection close factor is about 20x within about 750 blocks | **Parameters CONFIRMED, scope WRONG** | It is 20x of the cumulative-volume impact only, on a profitable close only, and zero on BTC and ETH (no depth bands). A patient thief never pays it. No hold time can make the route unprofitable |
| C | Patch, fix tests, gas | Done | [fixes/GR2-KEY-01b/](fixes/GR2-KEY-01b/) |
| D | HyperVault (read only) | See section D | Design input for the Hyperliquid fix round |

## A. Gains: what openTrade checks, and what KEY-01b adds

### A0. Decision D1: openTrade already runs `policy.checkOrder` (CONFIRMED)

`GainsVaultLogic.openTrade` (4ec6feb, `GainsVaultLogic.sol:445-487`) runs two checks:

1. `_newRisk` (`:761-768`): the caller is the manager or the agent, the vault is not in a breach or emergency, trading
   is not paused, and the epoch is not overdue.
2. `_checkOrder` (`:455`, `:776-779`), which calls `GainsVaultPolicy.checkOrder` (`GainsVaultPolicy.sol:270-285`):
   - the allowlist `isAssetAllowed[o.pair]` (`:272`);
   - a Chainlink mark band of ±maxSlippageBps (`:275-280`). This applies to **market orders only**; a limit or stop
     trigger is not banded;
   - the maximum order notional (`:281`) and the minimum collateral (`:282`);
   - projected leverage: `(openNotional + notional) / nav ≤ maxLeverageBps` (`:283`).

`increaseTrade` (`:491-529`, check at `:507`) and a leverage raise (`updateLeverage`, `:549-551`) run the same check.

checkOrder does not check three things, and that gap is GR2-KEY-01:
- anything per pair beyond the allowlist;
- the daily loss or drawdown;
- a rate limit.

The KEY-01 patch adds the per-pair depth cap and the loss gate. KEY-01b adds the rest.

### A1. Per-pair depth cap: it exists (CONFIRMED), but 5 % is not enough (WRONG); use 1 %

The cap is in fixes/GR2-KEY-01/fix.diff (not included) as `_checkPairDepth`: open + resting + pending +
new notional on the pair must be at most 5 % of `getPairSkewDepth × Chainlink price`.

Its README rests on two assumptions:
- the opposite trader pays the full 8 bps round trip, with a fee-tier discount of at most about 2/3;
- the route captures V·A/(200·depth).

Both are too optimistic, for three reasons.

1. **Counter-trade fee.** The thief's opposite trade lowers the skew the vault built, so he can flag it
   `isCounterTrade`. Gains v10 checks this in `TradingCallbacksUtils._openTradePrep:832-843` and
   `TradingCommonUtils.validateCounterTrade:953-980`; the size is capped at the pair's current skew and any excess
   collateral is returned.
   - The fee is `pairTotalPositionSizeFeeP × counterTradeFeeRateMultiplier`
     (`TradingCommonUtils.getTotalTradeFeesCollateral:665-690`). Both the open and the close use `trade.isCounterTrade`.
   - Live: the multiplier is **0.429** for BTC and ETH and **0.400** for SOL. The counter-trade maximum leverage is 15x,
     10x and 8x.
2. **Fee tiers stack on top.** `FeeTiersUtils.calculateFeeAmount:235-253` multiplies the volume tier by the GNS staking
   tier. Live, volume tiers go down to **0.75** and staking tiers down to **0.50**.
3. **The double swing.** The thief opens while the vault holds +V on the pair. He closes after the vault has closed
   and reopened at −V.
   - His skew capture per unit is (S_open − S_close)/(200·depth), where S is the pair's skew.
     `PriceImpactUtils._getTradePriceImpactP:1081-1094` computes `(start + trade/2) / depth`, and
     `getTradeSkewPriceImpactP` divides by 2. His own impact cancels out.
   - The vault's position swings from +V to −V. The capture is therefore **2·V·A/(200·depth) = f/100 of A** at
     V = f·depth. A single swing gives f/200.
   - No time rule changes this. Only the vault's position at the thief's open and at his close matters, and the
     per-pair cap bounds that position at ±f·depth.

**Thief round-trip cost per unit of A.** Live inputs:
- fee 0.035 % per side on BTC and ETH, 0.05 % on SOL;
- fixed spread 0.01 % on BTC and ETH, charged half per side (`getFixedSpreadP:71-77` halves it); 0 on SOL;
- no cumulative-volume impact on BTC and ETH, because they have no depth bands (section B).

| Thief account | BTC / ETH | SOL (lower bound: cumulative-volume impact excluded) |
|---|---|---|
| Plain | 7 + 1 = **8.0 bps** (KEYS.md measured 8.0) | 10 bps (KEYS.md measured 13.6 including cumulative volume) |
| Counter trade | 7 × 0.429 + 1 = **4.0 bps** | 10 × 0.4 = **4.0 bps** |
| Fee tiers only (0.75 × 0.5) | 7 × 0.375 + 1 = 3.6 bps | 3.75 bps |
| Counter trade + tiers | 7 × 0.429 × 0.375 + 1 = **2.13 bps** | 10 × 0.4 × 0.375 = **1.5 bps** |

**Capture against cost:**

| Cap f | Single swing (f/200) | Double swing (f/100) | Who profits |
|---|---|---|---|
| 5 % (KEY-01) | 2.5 bps | **5 bps** | A counter trade alone (5 > 4.0). Tiers alone (5 > 3.6). Counter trade + tiers even on a single swing (2.5 > 2.13 / 1.5) |
| 2 % | 1 bp | 2 bps | SOL with counter trade + tiers (2 > 1.5). ETH at 2 against 2.13 has no margin |
| **1 % (KEY-01b)** | 0.5 bp | **1 bp** | Nobody. Margin 2.1x (BTC / ETH) and 1.5x (SOL) against the top discounts; 4x against a counter trade without tiers |

**Fork proof.** Real diamond at block 516,673,656, `KEY01bForkFixTest`, run on the KEY-01 tree with the cap at 5 %
(run-fork.txt (not included)). Setup:
- ETH depth 14.02M, so the cap is 701k;
- the vault opens V = 687k long (3 × 229k);
- the thief opens a short of A = 687k (the pair skew was 795k);
- the vault closes and reopens short, with every step 650 s apart (longer than the KEY-01b hold), all at one oracle
  price.

| Thief account | Capture term 2VA/(200·depth) | Thief PnL | Per unit of A |
|---|---|---|---|
| Counter trade (no fee tier) | 336.7 USDC (4.9 bps) | **+63.35 USDC** | +0.92 bp (model: 4.9 − 4.0) |
| Plain | 336.7 USDC | −211.33 USDC | −3.1 bps (model: 4.9 − 8.0) |

**So the KEY-01 patch at 5 % does not close GR2-KEY-01.** A thief with the agent or manager key and an outside Gains
account still makes a profit on every swing:
- with the counter-trade discount alone;
- about 3x more with the top tiers;
- with the top tiers and a plain trade he is not limited by the skew, so A can be 5M: 1.4 bps, about 700 USDC per swing.

The first KEY-01b set a constant `MAX_PAIR_SKEW_DEPTH_BPS = 100`. Revision 2 replaces it with a per-pair factory
parameter (A1b). Vault capacity per pair at 1 %, at the depths of 2026-10-20 (KEYS.md has 1 %, 5 % and 10 % at block
516,920,630):

| Pair | Skew depth (tokens) | Price (USD) | Notional cap |
|---|---|---|---|
| BTC | 398 | 82,706 | **329k** |
| ETH | 5,738 | 2,447 | **140k** |
| SOL | 38,980 | 106.6 | **41.6k** |

A 100k vault at 5x needs at least two pairs. A 1M vault can use about 0.5M of its 5M leverage on the three curated
pairs. That is the cost of the bound. The fix round may add deeper pairs or accept a lower leverage cap.

Assumptions (conservative):
- The thief can reach both top fee tiers.
- Gains does not change the counter-trade multiplier, the tiers or the depths without the vault noticing. The cap
  reads the depth live, but the multipliers are not read. The fix round chooses between two remedies: an executor alarm
  on changes to `getPairCounterTradeFeeRateMultiplier`, the fee tiers and `pairTotalPositionSizeFeeP`, or a cap per
  pair curated in the policy.
- XF-04 (b) still applies: the depth read needs a sanity bound.

### A1b. Revision 2: the cap per pair, on the factory (owner decision, 2026-10-21)

**Rule.** `GainsVaultFactory` holds `pairSkewCapBps(pair)`, which every factory vault reads in `_checkPairDepth` at each
open, increase and limit or stop placement.

| Who | What | When |
|---|---|---|
| Guardian or sentinel | `setPairSkewCap(pair, bps)` with `bps ≤ current`. A lowering, which also drops a queued raise | At once |
| Guardian | The first setting of a never-set pair, up to `DEFAULT_PAIR_SKEW_CAP_BPS` = 100 | At once: no vault could trade the pair yet |
| Guardian only | `queuePairSkewCap(pair, bps)`, then `executePairSkewCap(pair)` | After `PAIR_CAP_RAISE_DELAY` = `GainsVaultPolicy.MAX_EPOCH_DURATION` + 1 day = 31 days |
| Guardian or sentinel | `cancelPairSkewCap(pair)` | At once |
| Anyone else | Nothing | |

- Ceiling: `MAX_PAIR_SKEW_CAP_BPS` = 1,000 (10 %).
- A pair never set, or set to 0, refuses new exposure with `OrderRejected("pair cap")`. This is fail-closed, like a
  pair without skew depth (ROUND2.md A-7).
- Standalone vaults keep the 1 % constant.

**Why these choices.**
- **Queue-then-execute.** The factory has no waiting period of its own (its owner setters are instant), so this is the
  minimal queue-then-execute.
- **31 days, derived (exit before effect).** The policy's real bound on `maxEpochDuration` is 30 days. It was a
  literal in `GainsVaultPolicy._validate`; the patch names it `MAX_EPOCH_DURATION` and derives `PAIR_CAP_RAISE_DELAY`
  from it as that bound + 1 day.
  - A depositor of any vault who asks to redeem when a raise is queued is in an epoch that started before the queue.
    That epoch is overdue no later than 30 days after its start, even if the owner raises `maxEpochDuration`
    meanwhile: the bound caps that too. Once it is overdue, anyone can settle it.
  - So the depositor is paid at least one day before the raise applies. In an exit-only settle with too little idle,
    they are filled pro rata and the rest is returned to ask again.
  - **The earlier residual (epochs over 6 days) is gone** for every epoch length the code accepts. With GR2-CFG-01
    applied, the longest usable epoch is 29 days, so the margin is two days.
  - Fix test: `test_KEY01b_fix_pairCap_raiseDelayIsLongestEpochPlusOneDay`. A vault with a 30-day epoch launches,
    30 days + 1 s is refused, a raise queued at its start reverts at 31 days − 1 s and applies at 31 days, one day
    after that epoch ends.
- **The sentinel may lower.** It is the executor's hand for the alarm on Gains fee or multiplier changes (A1
  assumptions). Lowering only reduces risk.
- **A lowering drops a queued raise,** so a raise cannot survive an alarm.
- **Unset = 0, with an immediate first setting up to 1 %.** A cheaper-fee pair curated later is not open at 1 % by
  default: someone has to set it. Its cap must stay below its break-even, the cheapest opposite round trip in bps read as
  a percentage of depth (KEYS.md).

**Decision D10 (owner, 2026-10-21):**
- **At launch** the cap is 1 % (100 bps) of skew depth on BTC, ETH and SOL.
- **Only the guardian may raise it,** to at most the 10 % ceiling in code, after 31 days.
- **Break-even** is about 2.13 % for BTC and ETH and about 1.5 % for SOL (A1).
- **Docs note for the fix round** (the fix round edits the docs site; this review only writes in the audit folders):
  > On gTrade vaults, the platform limits how large a position a vault can hold on each market to 1 % of that market's price-impact depth (BTC, ETH and SOL at launch); only the platform guardian can raise this limit, to at most 10 %, and a raise takes effect 31 days after it is announced, so you can always withdraw before it applies, while a lowering takes effect at once.

**Defaults:** BTC, ETH and SOL at 100 bps.
- Break-even against the worst-case thief is 213 bps for BTC and ETH and 150 bps for SOL.
- Extraction at each cap and vault size is in KEYS.md, "GR2-KEY-01b: extraction bounds". It is 0 at 1 % for every
  size; at 5 % and 10 % it is positive from about 100k NAV.

### A2. Turnover budget (new)

**Rule.**
- Notional that the manager or agent opens is drawn from a token bucket of `TURNOVER_NAV_MULTIPLE × NAV`. Opens are
  market opens, resting limit or stop placements, and size increases.
- The bucket refills linearly over one day. That makes it a rolling window, so there is no double burst at UTC midnight.
- NAV is the order's own read (`idle + venue value`), already computed for checkOrder.
- A refused order reverts `OrderRejected("turnover")`.
- Closes, reduces, flattens and leverage changes (Gains keeps the size constant) never spend the budget, nor do the
  platform roles. So the budget can never block an exit.

**Storage.** One slot holds `uint128 turnoverUsed`, `uint64 turnoverAt` and `uint64 lastRiskAt` (the vault-wide hold
stamp). It is appended at the end of `VaultStorage`; this needs a fresh deployment, since no live vault is upgraded in
place.

**Why k = 20.** It allows four full turnovers of the 5x leverage cap per rolling day. It bounds three things:
- **Destruction by pure churn** (fees go to Gains, nothing to the thief): at most 20 × 8.0 bps = **1.6 % of NAV per
  day** on BTC and ETH, and 20 × 13.6 bps = **2.7 %** on SOL (KEYS.md round-trip costs). This holds whatever the
  keeper's latency. Before, GR2-KEY-04 had no on-chain bound until the 15 % daily-loss breach was recorded.
- **Thief swings per day, if the cap were ever mis-set (A1):** at most 20 × NAV / V. At the old 5 % on a 1M vault
  (V = 701k) that is 28 swings × 63–200 USDC (counter trade, with or without tiers), so 1.8k–5.6k USDC per day. The XR_08
  route had no such limit: 55–60k per day.
- **A routed loss the opposite trader pays for** (at the 1 % cap): the vault's extra loss per swing is at most 1 bp of
  A, while the attacker pays at least 2.13 bps of A. The budget limits how often he can repeat it before a human acts.

**Strategies.** The executor's signal followers (the platform vault) hold one trade per pair per vault
(`server/src/venues/gains/submitter.ts:66`). They open at most the 5x exposure per signal, so 20 × NAV allows four full
reversals at full leverage per day. A vault that needs more turnover is not a swing strategy. For it, k should become a
policy choice: move it into `RiskConfig`, tightening instantly and loosening behind the timelock, like the other
fields.

**Edge cases.** A cancelled limit order keeps its draw (conservative). A leverage raise draws nothing, because Gains
keeps the size.

### A3. Minimum holding time (new)

**Rule.** The manager or agent may not close, reduce or flatten exposure in two cases:

1. **Pair hold.** Within `MIN_HOLD = 10 minutes` of the vault's last new-risk request on that pair. The stamp
   `pairRiskAt[pair]` is set at request time by every open, increase or limit placement.
2. **Trade hold.** On a trade within `MIN_HOLD_L2_BLOCKS = 2,400` Arbitrum blocks of its **fill**, as Gains records it
   in `TradeInfo.lastPosIncreaseBlock`. Verified in the Gains source:
   - it is set at an open, including a limit or stop execution (`TradingStorageUtils.storeTrade:153-158`), and at a
     market partial open (`updateTradePosition:232`);
   - it is not updated by a leverage update or a partial close;
   - `createdBlock` is **not** the open block: every position update resets it (`:249`).

**Block clock.** Gains' unit is `ChainUtils.getBlockNumber()`, which on Arbitrum is `ArbSys.arbBlockNumber()`, not
`block.number` (on Arbitrum that is the L1 estimate). The vault reads ArbSys (precompile 0x64) on chain ids 42161 and
421614, and `block.number` elsewhere. At Arbitrum's 250 ms floor, 2,400 blocks are at least 10 minutes. Measured: 264 ms
per block over the last 100,000 blocks, so about 10.6 minutes.

**Why both stamps.**
- The fill-time check covers what the request stamp cannot see: a limit or stop placed long ago that Gains fills now.
- The pair stamp covers what the fill check cannot see: rotation (open trade #2, then close the old #1 at once) and
  requests that are not yet filled.
- `flattenIndices` decodes nothing (GR1-08), so there the manager's hold is the vault-wide `lastRiskAt` only. Residual:
  a late limit fill on a pair the manager closes through `flattenIndices`. A2 bounds it.

**Who is never held.** This follows the "close / reduce / flatten" row of the LIVENESS.md exit table:
- the guardian, at any time;
- any exit in a breach or emergency, whether by the owner, sentinel, operator, manager or agent;
- the operator's redemption reduce outside a breach (row N1: `reduceTrade`'s operator branch is untouched).

In code: `_held = msg.sender != guardian && !breached && !emergency && (manager or agent)`.

Liveness rows N1, H2, H3, E1 and D1 are unchanged, because none of them depends on the manager's or agent's exit
outside a breach. An owner who is also the manager (the live setup) can still stop at once with `triggerBreach()`, which
also ends new risk.

**Enforced at request.** Gains is asynchronous and the vault never sees the fill, so the check runs when the close or
reduce is requested. That is the conservative side: the close still fills seconds later.

**Why 10 minutes** (numbers in section B):
- **(a)** It is longer than Gains' protection-close window at any value Gains may set.
  `PriceImpactUtils.setProtectionCloseFactorBlocks` caps the window at `MAX_PROTECTION_CLOSE_FACTOR_DURATION = 10
  minutes`; live it is 750 blocks, about 200 s. So no profitable vault close ever pays Gains' 20x factor. That saves
  depositors money, on SOL today.
- **(b)** It is two keeper intervals (`KEEPER_INTERVAL_MS = 5 min`), so one checkRisk and a churn alarm (GR2-EXE-01)
  can run between a thief's open and his close.
- **(c)** It allows at most one swing per pair every 10 minutes.
- It does **not** make the skew route unprofitable. Only the cap does (B3).

**Gains' TP / SL closes are not held (revision 2, owner decision).** The hold restricts only the agent's and manager's
`closeTrade`, `reduceTrade`, `flatten` and `flattenIndices`. Gains' bots may close on TP, SL or liquidation at any time:
- those closes never pass through the vault;
- `setSlTp` is not held, so a depositor's stop loss always fires.

The fix test is `KEY01bFixTest::test_KEY01b_guard_gainsTpSlClosesAreNotHeld`.

The residual is that a TP or SL set past the market is an immediate close by the bots, so the hold does not bound the
swing count. KEYS.md quantifies it. The cap (negative per swing at 1 %), the turnover budget and the loss gate bound it,
and the extraction tables are unchanged because turnover or daily loss binds at 30 swings per pair per day or fewer,
below the hold's 144. A rule forbidding crossed triggers inside the hold would restore the bound without weakening a
stop loss, but the owner's decision is that bots close freely, so it is not proposed.

**Cost to strategies.** A signal that closes within 10 minutes of its open has to wait. The executor retries on
`OrderRejected("min hold")` once both holds have passed: `pairRiskAt + 10 min`, and the fill block + 2,400. The trade's
own stop loss still fires. The price risk of the wait: ETH at about 48 % annualised moves 0.25 % in 10 minutes, so 1.2 %
of NAV at 5x for the rare early close. None of that is a transfer to anyone.

### A4. Loss gate inside openTrade (CONFIRMED, KEY-01 patch)

`_lossGate` in fixes/GR2-KEY-01/fix.diff (not included):
- runs in openTrade, increaseTrade and the leverage raise, at the order's own NAV, with checkRisk's formulas (R-01);
- reverts `ReduceOnlyMode` when the daily loss or drawdown is over its limit.

On the KEY-01b tree, `KEY01FixTest::test_KEY01_fix_dailyLossOverLimitRefusesNewRiskBeforeCheckRisk` still refuses
openTrade and increaseTrade with `ReduceOnlyMode`. Its last line, the manager's "exits stay open" close made right after
the open, is now held by A3, so the test needs the hold port (run-fixed.txt (not included)).
`lossWithinLimitStillTrades` passes. The gate itself is unchanged.

## B. Gains' protection close factor

### B1. The mechanism (verified in the source)

In `PriceImpactUtils.getTradeCumulVolPriceImpactP` (GNSPriceImpact facet `0xDCAD…4e55`, `PriceImpactUtils.sol:551-617`):
- `protectionCloseFactorActive` (`:571-576`) is `isPnlPositive && !open && protectionCloseFactor != 0 &&
  ChainUtils.getBlockNumber() <= lastPosIncreaseBlock + protectionCloseFactorBlocks && !whitelisted`.
- When it is active, it multiplies the **cumulative-volume (depth-band) impact** by `protectionCloseFactor` (1e10
  precision) (`:606`).
- It does **not** touch the skew impact (`getTradeSkewPriceImpactP`, `:619-645`) or the spread.

Other details:
- `isPnlPositive` is decided in two passes (`TradingCommonUtils.getTradeClosingPriceImpact:555-640`): the trade's value
  after fees, priced with the factor-free impact, must exceed the collateral.
- If a pair has no depth bands, the cumulative-volume impact returns 0 (`:585-588`), and 20 × 0 = 0.
- The block clock is `ArbSys.arbBlockNumber()` on Arbitrum (`ChainUtils.getBlockNumber:34-46`). Gains' own conversion
  assumes 300 ms per block (`convertBlocksToSeconds:101-105`), and the setter caps the window at 10 minutes (`:27`,
  `:343-348`).

### B2. Live values (cast, read only, around block 516,668,600)

| Pair | protectionCloseFactor | Blocks | cumulativeFactor | exemptAfterProtection | Depth bands (total above / below) | 1 % skew depth |
|---|---|---|---|---|---|---|
| BTC (0) | 2e11 = **20x** | **750** | 1x | false | **none** | 398 BTC (32.9M) |
| ETH (1) | 20x | 750 | 0, read as 1x | false | **none** | 5,738 ETH (14.0M) |
| SOL (33) | 20x | 750 | 0.3x | false | 31.6M / 44.4M | 38,980 SOL (4.16M) |

Other live values:
- `negPnlCumulVolMultiplier` is 0.2;
- the OI windows are 4 × 90 s;
- 750 blocks are **198 s** at the measured 264 ms per block (225 s at Gains' 300 ms).

`getTradeCumulVolPriceImpactP` on SOL at the live windows, in bps. Each cell is the close of a long / the close of a
short:

| Size | Outside the window (or a losing close) | Profitable close inside 750 blocks |
|---|---|---|
| 50k | 0.08 / 0.12 | 1.6 / 2.4 |
| 203k | 0.32 / 0.47 | 6.5 / 9.4 |
| 1M | 1.8 / 2.7 | 36.6 / 54.2 |

On ETH and BTC it is 0 in every case.

**Verdict.** The parameters are CONFIRMED: 20x and 750 blocks. "A profitable close within about 750 blocks pays about
20x price impact" is WRONG in scope:
- it is 20x of the cumulative-volume component only;
- that component is zero on BTC and ETH today;
- so XR_08's ETH route is untouched by it.

### B3. Who pays it in the skew route, and does a hold time help?

- **The vault's closes in the route lose money.** The vault pays its own impact plus the routed part, so
  `isPnlPositive` is false and the vault never pays the factor in the attack.
- **The thief's close is the profitable one.** He pays 20x only if he closes within 750 blocks of **his own**
  `lastPosIncreaseBlock`, and only on a pair with depth bands. On SOL at the old 5 % cap (V = A ≈ 203k), with a capture
  of 5 bps and a counter-trade cost of 4.0 bps:
  - inside the window his close costs +9.4 bps more, so the double swing nets −8.4 bps;
  - outside the window it costs +0.47 bps, so it nets **+0.5 bp profit**.
  - A thief who waits 200 s escapes the factor, and waiting costs him nothing in expectation: one price, or a hedge
    elsewhere. As the minority side he even receives funding.
- **The vault's minimum hold N cannot make the route unprofitable.**
  - The thief holds at least as long as the vault, because he opens after the vault's open and closes after the
    vault's close. Any N of 750 blocks or more only pushes him out of a window he would leave anyway.
  - The capture depends only on the vault's position at his open and at his close (at most 2·f·depth), not on time.
  - The fork run confirms it: with every step 650 s apart, the 5 % route still nets +63 USDC (A1).
  - Unprofitability comes from the cap f (A1). N bounds frequency and buys reaction time.
- **Where the factor does matter for depositors:** a legitimate profitable SOL close inside 750 blocks pays it. On 1M
  that is 36–54 bps instead of 2–3. N = 10 minutes is longer than the 10-minute maximum Gains may set, so a manager or
  agent close never pays it.

### B4. NAV consistency

`GainsNav._closingPrice` (4ec6feb, `GainsNav.sol:252-270`) runs Gains' two passes with the trade's
`lastPosIncreaseBlock` (`_ctx`, `:197`) and the diamond's own clock. So NAV values a profitable trade inside the window
exactly as a close now would be paid.

With the hold, the manager cannot close inside the window, but the guardian can, at that value: consistent.

The NAV steps up when the window expires (SOL only):
- at the 1 % cap (41.6k): at most about 2.4 bps × 41.6k ≈ 10 USDC;
- at the old 5 % cap: about 9.4 bps × 203k ≈ 190 USDC, or 0.02 % of a 1M NAV.

That is immaterial for settle pricing. GainsNav uses the vault's own fee tier and `isCounterTrade = false`, as Gains
does for the vault. No change is needed.

## C. Patch, fix tests, gas

[fixes/GR2-KEY-01b/](fixes/GR2-KEY-01b/) has the same layout as the other fixes:
- `fix.diff`, relative to the KEY-01 patched tree. Both diffs were applied in order to a copy of 4ec6feb, and the result
  is byte-identical to the tested tree.
- `test-port.diff` (KEY01FixTest takes its depth from the constant).
- `README.md`.
- `FixTest.t.sol` (`KEY01bFixTest`, mock), `GasTest.t.sol`, `KEY01bForkFixTest.t.sol`.
- `run-unfixed.txt`, `run-fixed.txt`, `run-fork.txt`.

The patch itself:

| Change | Where | Details |
|---|---|---|
| Cap 5 % → per pair (rev. 2) | `GainsTypes.sol`, `GainsVaultFactory.sol`, `_checkPairDepth` | `DEFAULT_PAIR_SKEW_CAP_BPS = 100` (standalone vaults, and the bound on a first setting), `MAX_PAIR_SKEW_CAP_BPS = 1,000`, `PAIR_CAP_RAISE_DELAY = GainsVaultPolicy.MAX_EPOCH_DURATION + 1 days` (31 days; `GainsVaultPolicy.sol` names its 30-day bound), `IGainsPairCaps`; factory `PairCap` per pair with set / queue / execute / cancel and three events (A1b) |
| Turnover budget | `GainsTypes.sol`, `GainsNav.spendTurnover`, called from `openTrade` / `increaseTrade` after `_checkPairDepth` | `TURNOVER_NAV_MULTIPLE = 20`; the same call stamps `lastRiskAt` and `pairRiskAt[pair]` |
| Minimum hold | `GainsNav.checkHold / holdTrade / holdPair`; `_held` in `GainsVaultLogic`; checks in `closeTrade`, `reduceTrade` (trader branch only), `flatten`, `flattenIndices` | `MIN_HOLD = 10 minutes`, `MIN_HOLD_L2_BLOCKS = 2,400`; ArbSys clock on Arbitrum |
| Storage | end of `VaultStorage` | `turnoverUsed`, `turnoverAt`, `lastRiskAt` (one slot) and `pairRiskAt` |

**Size.** With the helpers inside `GainsVaultLogic`, the library built at **24,885 bytes, over the 24,576 limit**. They
were moved into `GainsNav`, an external library delegatecalled on the vault's storage. Results:
- `GainsVaultLogic` 23,916 bytes (KEY-01: 23,252; 4ec6feb: 21,919), so **660 bytes of headroom** remain;
- `GainsNav` 17,551.

A second build hit "stack too deep" in `flatten`. The per-trade check therefore runs in `GainsNav.holdPair` before the
loop, which re-reads the list on the manager's path only.

**Fix tests** (mock; run-unfixed.txt (not included) / run-fixed.txt (not included)):

| Test | KEY-01 alone | KEY-01b |
|---|---|---|
| `test_KEY01b_fix_pairCapIsOnePercentOfSkewDepth` | FAIL | PASS |
| `test_KEY01b_fix_minHold_traderExitsHeld` (close, reduce, flatten, flattenIndices × manager and agent) | FAIL | PASS |
| `test_KEY01b_fix_minHold_newRiskOnThePairReArmsIt` (rotation) | FAIL | PASS |
| `test_KEY01b_fix_minHold_lateLimitFillHeldByGainsBlock` | FAIL | PASS |
| `test_KEY01b_fix_turnoverBudget` | FAIL (4.0M opened on a 100k vault in 10 cycles) | PASS (refused at exactly 2.0M; closes always go through; refills) |
| `test_KEY01b_guard_platformAndBreachExitsNeverHeld` | PASS | PASS |

**Fork** (run-fork.txt (not included), public RPC, tip − 40; this re-runs the GR2-KEY-01 XR_08
scenario):

| Run | KEY-01 (5 %), block 516,673,656 | KEY-01b (1 %), block 516,682,710 |
|---|---|---|
| XR_08: 250k ETH opens from a 1M vault | (KEY-01 run: refused past 701k) | **the first order is refused "pair depth"** (cap 139.8k) |
| Counter-trade double swing at the cap | thief **+63.35 USDC** on A = 687k | thief **−41.00 USDC** on A = 137k (−3.0 bps; model 0.98 − 4.0) |
| Plain double swing | −211.33 | −95.78 |
| Manager close inside the hold | n/a | refused "min hold". The guardian's close goes through; the manager's goes through after 650 s |

So the thief's round trip is unprofitable at KEY-01b's cap, and the vault refuses the XR_08 sizes outright.

**Gas** (mock, `GasTest.t.sol`):

| Call | Added |
|---|---|
| openTrade | **+11.9k** per open (+68.7k on the first open of a vault and pair, for two zero→non-zero slots) |
| increaseTrade | **+11.7k** |
| closeTrade by manager or agent | **+18.3k** |
| reduceTrade by manager or agent | **+18.3k** |
| guardian close | +0.1k |

On the real diamond, add about 5–10k for the two cold reads on a close (estimate, not measured on a fork).

**Existing tests:** 367 pass, 45 fail of 414 (2 fork suites skipped):
- 39 fail with `OrderRejected("min hold")`: the manager or agent exits right after opening. Port: wait the hold, or exit
  as the guardian. `KEY01FixTest::dailyLossOverLimit…` is among them; its loss-gate assertions still pass, and only its
  final manager close is held.
- 6 `AccessMatrix` rows: ACCESS-MATRIX.md must say "manager / agent exits after the minimum hold, or in a breach or
  emergency".
- Nothing fails on the turnover budget or for any other reason. The 45 are listed in run-fixed.txt.

**Revision 2** ([fixes/GR2-KEY-01b/README.md](fixes/GR2-KEY-01b/README.md); run-fixed-rev2.txt (not included),
run-unfixed-rev2.txt (not included), run-fork-rev2.txt (not included)):
- **Fix tests.** 8 new: 7 per-pair cap tests, including the 31-day = longest epoch + 1 day test (fail on the first KEY-01b tree, pass on rev. 2) and the TP / SL guard
  (passes on both).
- **Mock suite.** 376 pass, 45 fail (the same 45), 2 skipped, of 423.
- **Sizes.** `GainsVaultLogic` 24,113 bytes, 463 left. `GainsVaultFactory` 13,523.
- **Gas.** A factory vault's openTrade or increaseTrade costs +6.6k, for the factory read.
- **Harness.** `GainsBase`, `GainsFactoryTest` and `GainsRound4FactoryTest` set BTC, ETH and SOL to 1 %. Without that,
  15 factory-vault tests fail "pair cap", which is the intended fail-closed default.

## D. HyperVault (Hyperliquid vaults): design input for the Hyperliquid fix round, verified read only here

Everything in this section was **checked read-only** in this worktree's `contracts/src` (round 4 HyperVault,
VaultLogic, VaultPolicy, HyperCore) and `server/src`, plus the Hyperliquid docs and public read-only endpoints. Nothing
was written to the Hyperliquid review's folders. It is input for the Hyperliquid fix round, not a finding of this
review.

### D1. Contract order path, checked by VaultPolicy: CONFIRMED, with gaps

**Entry points.** `HyperVault.placeOrder / cancelOrder / flatten` (`HyperVault.sol:236-246`) delegate to `VaultLogic`.

**Wire format.** `HyperCore._send` (`hypercore/HyperCore.sol:150-152`) writes `abi.encodePacked(uint8(1), actionId,
payload)` to CoreWriter `0x3333…3333` (`:25`).
- Action ids (`:50-56`): 1 limit order, 6 spot send, 7 USD class transfer, 9 add API wallet, 10 cancel by oid, 11 cancel
  by cloid, 13 send asset.
- Time-in-force constants (`:59-61`): ALO 1, GTC 2, IOC 3.
- These match the HL table:
  https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interacting-with-hypercore

**`placeOrder`** (`VaultLogic.sol:527-548`):
- Manager only. Reduce-only in a breach, an emergency, or when paused. Spot is refused.
- Reads the mark price (precompiles 0x806 / 0x80a) and the account margin summary (0x80F), then calls
  `VaultPolicy.checkOrder` (`VaultPolicy.sol:173-198`), which checks:
  - spot refused;
  - allowlist (skipped for reduce-only orders);
  - mark band ±maxSlippageBps, on every order;
  - notional ≤ maxOrderNotional, at the worse of limit and mark;
  - projected gross leverage (ntlPos + notional) / accountValue.
- Then sends `HyperCore.limitOrder`.

**`cancelOrder`** (`:551-554`): manager or sentinel, no policy check.

**`flatten`** (`:562-580`): uses `policy.flattenOrder`, a bounded reduce-only IOC.

**Gaps a proxy must close:**
- The **time-in-force is not validated**: GTC and ALO orders can rest and fill far from the checked mark.
- The band is checked against the mark when the EVM block is built, but the order executes seconds later (D3).
- The policy's "leverage" is gross notional over equity, **not Core's per-asset leverage**. CoreWriter has no
  update-leverage action, so contract-path orders use whatever leverage the agent last set
  (`server/src/venues/hl/exchange.ts:66-68`).
- There is no cancel by cloid.

Live policy on all three mainnet vaults: maxSlippageBps 100, maxLeverageBps 30,000 (3x), maxOrderNotional 250,000 USDC.

### D2. The API-wallet agent bypasses VaultPolicy: CONFIRMED

**How the agent is approved on Core.** CoreWriter action 9 "add API wallet" (`HyperCore.addApiWallet`,
`HyperCore.sol:182-184`), on the named slot `AGENT_NAME = "dojipad"` (`VaultTypes.sol:50`). It is sent from:
- `setAgent`: timelocked (`HyperVault.sol:252-255`, then `VaultLogic.sol:586-589`); `_storeAgent` requires
  `factory.platformAgentFor(agent) == vault` (`:609-616`);
- `syncAgent`: anyone, outside a hard stop (`HyperVault.sol:259-261`, `VaultLogic.sol:601-607`). The keeper calls it
  (`server/src/agentSync.ts`).

`revokeAgent` (owner, guardian, sentinel or factory) overwrites the slot with a burn address
(`VaultLogic.sol:619-630`).

**What an API wallet can do on Core.** It signs any L1 trading action for the vault account:
- orders and cancels on any market, at any size or price HL accepts;
- `updateLeverage`;
- `agentSendAsset` between the account's own dexes or spot and perp. This is REPORT C-01 and D-1 ("agents are
  unbounded onchain", `contracts/audit/REPORT.md:203`);
- **also `agentSetAbstraction`**, which switches the account mode (see D4).

It cannot sign withdrawals or transfers to others (usdSend, spotSend, withdraw3, sendAsset are user-signed; REPORT A-12,
"Verified (docs)", `REPORT.md:266`). Source: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/exchange-endpoint

**What the executor does.** It signs with the agent key directly to the HL API and never calls the contract:
- `LiveSubmitter` (`server/src/venues/hl/exchange.ts:35-69`), `@nktkas/hyperliquid` `ExchangeClient`, every order IOC
  (`:30`);
- `server/src/dojipad/ec/contractOrders.ts:18` says so: "Executor orders never come through here".

The policy is enforced only off chain, in `core/guard.ts:32-60` and the IOC band (`venues/hl/rounding.ts:38-41`).
`contracts/audit/hl-open/REVIEW.md:189` already records that this guard is the only per-order bound on the platform
agent.

### D3. Latency: contract path against API wallet

**Documented:**
- Small blocks: "Fast block duration is set to 1 seconds with a 3M gas limit". Big blocks: 1 minute, 30M gas.
  https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/dual-block-architecture
- CoreWriter delay: "order actions and vault transfers sent from CoreWriter are delayed onchain for a few seconds"
  (interacting-with-hypercore). **No exact value is published.** Delayed actions show twice on the L1 explorer, as the
  enqueue and the execution.
- HyperCore: "end-to-end latency has a median 0.2 seconds and 99th percentile 0.9 seconds" for co-located clients.
  https://hyperliquid.gitbook.io/hyperliquid-docs/hypercore/overview

**Measured** (read-only RPC, 2026-10-20):
- HyperEVM blocks 49,066,248 to 49,066,827: 520 blocks fetched, of which 512 small (3M gas) and 8 big (30M gas, every
  61 blocks, on minute boundaries).
- Small-to-small interval over 508 pairs: mean 1.000 s, median, p90 and p99 all 1 s. Timestamps have 1 s resolution.
- HyperCore block interval, from precompile 0x809 over two 36–37 s spans: 0.052–0.074 s, about 0.06 s.

**Model:**

| Path | Steps | Total |
|---|---|---|
| API wallet | One HTTPS request, then the next Core block | ≈ 0.2 s median, 0.9 s p99 |
| Contract | Wait for the next small block (mean 0.5 s) + propagation (0.1–0.3 s) + the CoreWriter delay (assumed 2–5 s, central 3 s) | ≈ 2.6–5.8 s |

So the contract path adds **about 3 s (central) to 5 s (pessimistic)**.

**What the strategies lose.** the platform vault and the copy mirror trade BTC, ETH and SOL, all IOC at mark ±100 bps, sized by
slots of 33 / 50 / 100 % of equity times the leverage cap (`server/src/core/sizing.ts:37-67`). Realised volatility from
1-minute HL candles over about 3.5 days:

| Asset | Annualised | Per √s |
|---|---|---|
| BTC | 30.6 % | 0.54 bps |
| ETH | 48.0 % | 0.85 bps |
| SOL | 56.3 % | 1.00 bps |

One sigma over the extra delay, in bps and USD per trade:

| Asset | Δ = 3 s | Δ = 5 s | USD at the 250k max order |
|---|---|---|---|
| BTC | 0.94 | 1.21 | $24–30 |
| ETH | 1.47 | 1.90 | $37–48 |
| SOL | 1.73 | 2.24 | $43–56 |
| Stress (70 % annualised) | 2.16 | 2.79 | $54–70 |

At $10k notional the range is $0.9–2.8.

How to read this:
- For an order that knows nothing about the next 3–5 s, this is variance, not expected loss.
- It becomes a real cost for signal followers and copy orders that trade after a move: about 1–3 bps per trade.
- That is immaterial for a swing strategy, and below the copy mirror's 20–30 bps slippage alerts.
- The 100 bps band almost never refuses a fill: a 100 bps move in 5 s is beyond 35 sigma.

### D4. "Default account mode": stated but not enforced (CONFIRMED)

**Where it is stated:**
- `README.md:464`: "Keep the vault on the default mode".
- `docs/audit-pack/KNOWN-ISSUES.md:41-42`.
- `contracts/audit/REPORT.md:239`, `:265`, A-11: "Verified for current mode only … under a unified/portfolio mode the
  precompile may include spot, so NAV double counts. Who may set it (agent?) is unverified".
- `contracts/audit/notes.md:32-37`: CoreWriter action 16 "Set abstraction" is not used by the vault.

**Not enforced:**
- There is no "abstraction" anywhere in `contracts/src`. HyperCore defines no action 16 and reads no mode.
- The executor reads no `userAbstraction`.
- Live, the info API returns `userAbstraction = "default"` for all three mainnet vaults.

**Not found:** a separate "round 2 margin-mode finding" in this worktree's audit folders. It is probably in the
Hyperliquid review's own worktree, which was not opened (UNVERIFIED here). The gap itself is confirmed by the code above.

**Is there an on-chain read of the mode? None documented.** The precompiles 0x800–0x813 (positions, spot balances,
vault equity, marks, oracle, L1 block, asset and token info, BBO, account margin summary, core-user-exists,
borrow/lend, position2) carry no mode. Abstraction exists only as write action 16 (values 1 disabled, 2 unified account,
3 portfolio margin; hyper-evm-lib `HLConstants.sol`). 0x814 answers with `PrecompileError` and is undocumented
(UNVERIFIED).

**How an HL proxy that reuses the contract path enforces it:**
1. **No API wallet on the vault account.** The named slot stays empty or burned. That closes `agentSetAbstraction`, and
   `userSetAbstraction` needs the account's own key, which a contract does not have. Action 16 becomes the only route.
2. **The vault never sends action 16 with any value but 1 (disabled).** An idempotent, permissionless
   `assertStandardMode()` that sends `16(1)` once the Core account exists makes this structural. It is fire-and-forget:
   it asserts the mode but proves nothing.
3. **"Refuse orders unless the mode reads default" cannot be done on chain today.** Until HL ships a mode read:
   - the keeper reads `userAbstraction` on the info API on every tick and before every settle;
   - on any value other than "default" or "disabled", the sentinel calls `triggerBreach` / `setTradingPaused`, and the
     executor refuses to settle.
   - If a precompile appears, gate placeOrder, settle and coreEquity on it, and fail closed (revert) when the read is
     unavailable.
4. **If the agent path is kept, the guarantee is weaker:** the vault cannot stop the agent from switching modes. The
   executor must never send `agentSetAbstraction` (an assert next to `assertPerpOrder` in `exchange.ts`), and monitoring
   must react to a change.

## WP3: executor defaults (fix round; proposed, not yet code)

The executor's circuit breaker for a hostile agent or manager key. The KEYS.md "with breaker" columns are computed with
these values. Every action uses an existing sentinel power, so no contract change is needed.

| Trigger (any one) | Proposed default |
|---|---|
| Vault loss over a rolling 24 h | **> 5 % of NAV** |
| Vault loss over a rolling 1 h | **> 2 % of NAV** |
| Drawdown from the peak share price | **> 10 %** |
| Notional opened over a rolling 1 h | **> 5 × NAV** |
| Action | The sentinel calls `revokeAgent()` and `setTradingPaused(true)` **within 10 minutes** (two keeper intervals) of the trigger |

Other WP3 items from KEY-01b:
- alarms on `PairSkewCapQueued` (31 days to object) and on Gains changes to `getPairCounterTradeFeeRateMultiplier`, the
  fee tiers, `pairTotalPositionSizeFeeP` and the spread (re-check the break-even, and let the sentinel lower);
- `OrderRejected("pair cap")`: alarm, no retry;
- `OrderRejected("min hold")`: retry after the hold;
- `OrderRejected("turnover")`: strategy limit, with an alarm;
- the churn alarm (GR2-EXE-01).

Status: proposed defaults. Nothing here is in `server/src`.

## What the fix round must still decide

**Gains (KEY-01b):**
1. **The cap.** Decided (D10): a per-pair factory cap, 1 % on BTC, ETH and SOL at launch, raised only by the
   guardian after 31 days. Still open: Whichever is chosen, add an alarm or bound on the
   Gains parameters the bound depends on but does not read: the counter-trade fee multiplier, the fee tiers,
   `pairTotalPositionSizeFeeP` and the spread. Also apply XF-04 (b), a sanity bound on the depth read.
2. **Capacity.** Accept the capacity cost: 140k ETH, 329k BTC and 41.6k SOL of notional per pair today. Or add deeper
   pairs, or lower the leverage cap.
3. **Where k lives.** Whether k = 20 stays a constant or becomes a `RiskConfig` field (tighten instantly, loosen
   behind the timelock).
4. **The TP / SL bypass of the hold.** Decided (owner, revision 2): Gains' bots close on TP / SL freely, and the hold
   restricts only agent and manager closes. The residual is bounded in KEYS.md.
5. **Where the helpers live.** `GainsNav` (as patched) or a dedicated library. `GainsVaultLogic` has 660 bytes left.
6. **Tests and docs.** Port the 39 "min hold" tests and the ACCESS-MATRIX rows. Add executor retries for "min hold",
   a "turnover" alarm, and a lens `holdUntil` view.
7. **Fork gas.** Measure the close and reduce cost on a fork at 20 positions, together with KEY-01's open cost, which
   was not measured either.

**Hyperliquid (input for its fix round):**
1. **Drop the API wallet or keep it.** Dropping it moves every order onto the policy-checked contract path, at a cost of
   about 3–5 s of latency, which is about 1–3 bps per trade.
2. **Leverage on Core.** Without an agent, Core leverage cannot be set (no CoreWriter action), so the proxy must design
   for it.
3. **Contract-path checks.** Validate the time-in-force (IOC only, or bound resting orders), and add cancel by cloid.
4. **The mode rule.** Implement items 1–3 of D4. Find out whether "default" equals "disabled" and whether HL may migrate
   accounts. Measure the exact CoreWriter delay from an enqueue / execute pair.
