# Gains openTrade additions: depth cap, turnover budget, minimum holding time, loss gate (GR2-KEY-01)

**Internal, AI-assisted review (hl-r2, Gains fix sub-review). Not an independent audit.** Branch `audit/hl-r2-gtrade`
(from `audit/hl-r2` 131f6ee). Nothing deployed, no transaction sent, nothing pushed. `contracts/src`, `server/src` and
`webapp` are unchanged on this branch. The fix is a patch file proven in throwaway worktrees (assumption A4); the only
chain access was read-only `eth_call` on Arbitrum One through the public RPC.

## 1. In plain words

A Gains vault already checks every new trade against its policy: the pair must be allowed, a market order's price must be
near Chainlink, one order may not be too large, and the vault's total exposure may not exceed its leverage limit. Four
things were missing. This patch adds them.

1. **Depth cap.** The vault may not hold more than 5 % of a pair's Gains skew depth on that pair. Bigger positions move
   Gains' price enough that someone trading the other side on his own account can profit from the vault's loss. This is
   the stolen-key attack in GR2-KEY-01.
2. **Turnover budget.** Over any 24 hours, the vault may open at most 20 times its NAV in new positions. This puts a
   ceiling on how much a stolen or broken trading key can burn in fees by opening and closing all day.
3. **Minimum holding time.** Gains charges extra (20 times its cumulative price impact) when a trade is closed in profit
   within 750 Arbitrum blocks of being opened, about 3 to 3.5 minutes. On a pair where that extra actually costs
   something, the vault now refuses the manager's and the agent's own profitable close in that window plus 40 blocks.
   On those pairs it also refuses a take profit placed with the open, and take-profit or profit-side stop changes in
   the window. Today it costs something on SOL. On BTC and ETH, Gains' cumulative impact is zero, so nothing is held
   there; the vault reads this live from Gains. Losing closes are always allowed. So are closes by the guardian and
   the platform, and every exit during a breach or an emergency.
4. **Loss gate.** If the vault is already past its daily loss limit or its drawdown limit, it refuses new risk at once.
   It no longer waits for the next `checkRisk` call (the keeper's, every 5 minutes) to notice.

The depth share, the turnover multiple and an optional longer holding time are policy settings. Tightening them applies
at once. Loosening them waits for the same exit notice as every other loosening under the exit-before-effect fix
(GAINS-GR2-CFG-01): at least one full epoch plus a day. No check ever blocks an exit, and a failed read never holds a
close.

## 2. Owner's design input, checked in code

Line numbers are `origin/main` (= `audit/hl-r2` `contracts/src`, 4ec6feb), unpatched.

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| C1 | `openTrade` already runs `policy.checkOrder` per decision D1 | **True** | D1: docs/gains/PLAN.md:72. `GainsVaultLogic.openTrade` calls `_newRisk` (:446) and `_checkOrder` (:455-469) → `GainsVaultPolicy.checkOrder` (:270-285) |
| C2 | checkOrder checks the allowlist | **True** | GainsVaultPolicy.sol:271-272 (pair ≤ uint16, `isAssetAllowed`) |
| C3 | checkOrder checks the Chainlink mark band | **Partly** | Only for **market** orders: `if (o.market)` at :275-280. Limit / stop opens (`market = tradeType == TRADE`, Logic :460) and leverage raises (`market: false`, Logic :556) skip it; Gains checks a limit trigger against its own oracle. `increaseTrade` passes `market: true` (Logic :512) and is banded |
| C4 | checkOrder checks the max notional | **True, per order only** | :281 `o.notional > maxOrderNotional`. A leverage raise passes `notional: 0` (Logic :560), so it never meets this bound. Nothing limits the notional per pair (GR2-KEY-01) or per day |
| C5 | checkOrder checks projected leverage | **True for vault leverage, not per trade** | :283 `(openNotional + notional) × BPS ≤ maxLeverageBps × nav`. This is the **vault's** open notional over NAV. The per-trade leverage (up to Gains' `pairMaxLeverage`) is not bounded by the policy (KEYS.md, "no policy field limits per-trade leverage"). A leverage raise at constant size adds 0 to the projection |
| C6 | Missing: depth cap, turnover budget, minimum holding time, loss / drawdown check inside openTrade | **True** | No pair-level read in Logic :445-487 or Policy :270-285. No counter of opened notional. Close / reduce (:573-601) read nothing. The loss check runs only in `checkRisk` → `Governance._check` (:177-208). `openTrade` reaches loss limits only through `_newRisk`'s `$.breached` (:763), which is set by a `checkRisk` call. KEEPER_INTERVAL_MS = 300,000 (server venues/gains/wire.ts:347) |
| C7 | GR2-KEY-01 asks for the daily loss / drawdown check inside openTrade | **True, and more** | audit/gains-r2 ROUND2.md:121-147 (High). The fix asks for (a) a per-pair notional cap against `getPairSkewDepth` and (b) the loss gate in `openTrade`, `increaseTrade` and leverage raises. KEYS.md lists GR2-KEY-01 as Low; ROUND2.md raised it to High after the fork run at the live caps |
| C8 | Protection close factor: "~750 blocks, 20x" | **True on the live diamond, with corrections** | §3. 750 is in **Arbitrum L2 blocks** (ArbSys), not L1. 750 blocks ≈ 191-209 s measured, not a fixed time. 20x multiplies only the **cumulative-volume** part of the close impact (not spread, skew or fees). It applies to market closes, partial closes, **and TP / SL executions** |

Paths the checks run on today (unpatched):

| Path | checkOrder | Mark band | Max notional | Vault leverage | Loss limits |
|---|---|---|---|---|---|
| `openTrade` market | yes | yes | yes | yes | only once `checkRisk` has set `breached` |
| `openTrade` limit / stop (placement) | yes | **no** | yes | yes | same |
| limit / stop **fill** (Gains bot) | **no** (Gains executes) | - | - | - | - |
| `increaseTrade` | yes | yes | yes (added size) | yes | same |
| `updateLeverage` raise | yes | **no** | **0** | unchanged projection | same |
| `updateLeverage` lower (adds margin) | no | - | - | - | refused in a loss breach (:537) |
| `setSlTp`, `cancelOrder` | no | - | - | - | - |
| `closeTrade`, `reduceTrade`, flatten | no (by design: exits read no price) | - | - | - | - |

## 3. Gains' protection close factor: evidence

Sources (fetched 2026-10-20, 18:00-18:10 UTC):

- **Verified source** of facet GNSPriceImpact `0xDCAD09f7682e045d235FCf4Aa9f1B47AB2054e55`, Sourcify:
  `https://sourcify.dev/server/v2/contract/42161/0xDCAD09f7682e045d235FCf4Aa9f1B47AB2054e55?fields=sources`.
  Excerpts with line numbers and the hash are in evidence/gains/gtrade-source-excerpts.txt (not included).
  The diamond's loupe maps `getPairFactors` and `getTradeCumulVolPriceImpactP` to this facet.
- **Live reads**: read-only `eth_call` on the diamond `0xFF16…f169`, block 516,675,158. See
  evidence/gains/diamond-reads.txt (not included).
- gTrade developer docs (`docs.gains.trade/developer/technical-reference/contracts/libraries/priceimpactutils`) list the
  setters and the 1e10 precision but not the rule. The rule below is taken from the source.

**The rule (PriceImpactUtils.getTradeCumulVolPriceImpactP, source lines 552-615):**

```
protectionCloseFactorActive = _isPnlPositive && !_open && protectionCloseFactor != 0
    && ChainUtils.getBlockNumber() <= _lastPosIncreaseBlock + protectionCloseFactorBlocks
    && !protectionCloseFactorWhitelist[trader];
... priceImpactFactor = (active ? protectionCloseFactor : 1e10) * userMultiplier / 1e3   // depth-band impact only
```

- **Block clock.** `ChainUtils.getBlockNumber()` returns `ArbSys.arbBlockNumber()` on Arbitrum One (ChainUtils.sol:34-46),
  so the window is counted in **L2 blocks**. `lastPosIncreaseBlock` is set to the fill block when the trade is stored
  (TradingStorageUtils.sol:158) and again on every partial open (:232). A leverage update does not reset it.
- **What is multiplied.** Only the cumulative-volume (depth band) impact. The fixed spread, the v10 skew impact and the
  fees are not multiplied (TradingCommonUtils.getTradeClosingPriceImpact, :555-652). The cumulative impact is 0 when the
  pair has no depth bands. With `exemptAfterProtectionCloseFactor` it is also 0 once the window has passed.
- **"In profit".** Gains computes the trade value without the factor at the oracle price, net of closing fees, spread,
  skew and cumulative impact. The factor applies when that value is above the collateral (:599-641).
- **Where it applies.** Market close (TradingCallbacksUtils.sol:154-159, `useCumulativeVolPriceImpact = true`), TP / SL
  executions (:616) and partial closes (DecreasePositionSizeUtils.sol:83-91). Liquidations are excluded.
- **Bound.** `setProtectionCloseFactorBlocks` refuses windows longer than `MAX_PROTECTION_CLOSE_FACTOR_DURATION = 10
  minutes`. That is 2,000 blocks at Gains' own 0.3 s per block (PriceImpactUtils.sol:27, :343-348).

**Live values (getPairFactors([0, 1, 33]), block 516,675,158):**

| Pair | protectionCloseFactor | protectionCloseFactorBlocks | cumulativeFactor | exemptAfter |
|---|---|---|---|---|
| BTC (0) | 2e11 = **20x** | **750** | 1e10 (1x) | false |
| ETH (1) | 2e11 = **20x** | **750** | 0 (→ 1x) | false |
| SOL (33) | 2e11 = **20x** | **750** | 3e9 (0.3x) | false |

**Blocks to seconds** (L2 block timestamps, same block):

| Last N blocks | Seconds | s / block | 750 blocks = |
|---|---|---|---|
| 750 | 191 | 0.255 | 191 s |
| 7,500 | 1,925 | 0.257 | 193 s |
| 100,000 | 26,321 | 0.263 | 197 s |
| 1,000,000 | 278,631 | 0.279 | 209 s |

Gains converts blocks at 0.3 s (ChainUtils.convertBlocksToSeconds), which gives 225 s. Arbitrum's minimum block time is
0.25 s, so 750 blocks is never less than 187.5 s. When the chain is quiet, blocks come more slowly and the window lasts
longer in seconds. A hold expressed in seconds could therefore end before Gains' window does. **For that reason the
patch measures the hold in L2 blocks, read from the trade itself.** Correction to the design input: "~750 blocks / 20x"
is right, but the unit is Arbitrum L2 blocks (about 3.2-3.5 minutes at today's rate, never under 3.1 minutes). The 20x
applies to the cumulative-volume impact only, not to the whole close cost. Measured on the fork (§6): on a 100k close
in profit it costs **30.52 USDC on SOL** (3.05 bps of notional). On **ETH it costs nothing**, because ETH's cumulative
impact is 0 today. So the "20x" is a multiplier on a term that may be zero.

## 4. Design

### 4.1 Where things live

| Piece | Contract | Why there |
|---|---|---|
| `OrderLimits` config, propose / apply / cancel | GainsVaultPolicy | Next to `RiskConfig`, with the same tighten-instant / loosen-timelocked rule. A separate struct keeps `RiskConfig`'s ABI (the executor, the webapp and ~40 tests build it) |
| Depth cap + turnover (`checkExposure`, vault-only, records the order) | GainsVaultPolicy | Has the Chainlink price and its own storage. Keeps GainsVaultLogic under the size limit |
| Hold check (`holdBlocked`, view) | GainsVaultPolicy | A separate contract, so the vault can call it under try / catch (fail open on exits) |
| Loss gate (`_lossGate`) | GainsVaultLogic | Needs vault storage (riskDay, dayStartSharePrice, peakSharePrice). No external read |
| Pair notional in the NAV pass | GainsNav (`snapshot(..., pairOf)`), GainsVaultMath (`venueFor`) | The same pass that already computes `notional`. No second NAV read |

### 4.2 The checks

**Depth cap** (closes GR2-KEY-01's skew route; XF-04 sanity ceiling)

```
pairNotional(after) = Σ on `pair`: open trades (positionSizeToken × Chainlink) + resting limit/stop (collateral ×
                      leverage) + pending market opens / increases (added size) + this order
cap = min( getPairSkewDepth(collateralIndex, pair) × Chainlink(pair) / 1e22 × maxPairDepthBps / 10,000 ,
           getPairMaxOiCollateral(collateralIndex, pair)  [when ≠ 0] )
refuse "pair depth" if pairNotional(after) > cap;  refuse "no skew depth" if the depth is 0
```

- **Source.** `getPairSkewDepth` = the 1 % skew depth in tokens, 1e18 (IPriceImpact.pairSkewDepths, "depth (tokens,
  1e18)"). Gains' skew impact moves the price by size / (2 × depth) per 1 % (`priceImpactDivider = 2`). An opposite trader
  of size A who holds across a vault round trip of size V captures at most V·A / (200·depthUsd) (GR2-KEY-01, measured at
  96.7-99.98 % of that term). At V ≤ f·depthUsd that is f / 200 of A per round trip. At the default f = 5 % it is
  **2.5 bps of A**, against an opposite round-trip cost of 8.0 bps (BTC, ETH) and 13.6-17.5 bps (SOL). The measured
  break-even ratios are ETH 0.16 and SOL 0.36, so 5 % is under a third of the lowest.
- **Live caps** (depth × Chainlink at block 516,675,158, × 5 %): BTC 398 × 82,657 = 32.9M → **1.645M**; ETH 5,738 ×
  2,446 = 14.04M → **702k**; SOL 38,980 × 106.5 = 4.15M → **207k**. Gains' OI caps (35M / 30M / 9M) are far above, so
  the OI ceiling only matters if a facet change makes the depth read absurd (XF-04).
- **Bounds.** `maxPairDepthBps` 1..1,000 (default 500). Above 10 % the capture passes 5 bps of A, which is close to the
  opposite account's own cost once a fee-tier discount is assumed.
- **Paths.** `openTrade` (market and limit / stop placement) and `increaseTrade`. A leverage raise keeps the size, so it
  is not counted. Exits read no depth: a depth cut below the vault's exposure only refuses new risk.

**Turnover budget** (bounds KEY-04 churn and how often the KEY-01 route can repeat; an on-chain bound for EXE-01's
alarm gap)

```
used = Σ openedNotional[h] for the 25 hour buckets h = now/1h − 24 .. now/1h, + this order's new notional
refuse "turnover" if used × 10,000 > maxDailyTurnoverBps × NAV;  else openedNotional[now/1h] += new notional
```

- 25 hourly buckets cover every rolling 24 h window. The oldest hour counts in full, which is at most one hour stricter
  than an exact window. NAV is the one `checkOrder` uses (idle + GainsNav value at the adverse band edge).
- Default **20x NAV per rolling day** (the figure EXECUTOR.md suggests for HL). Bounds 1..1,000,000 bps (100x).
- Destruction it bounds: one full churn of 5 × NAV costs 0.40 % (BTC / ETH) to 0.68 % (SOL) of NAV (GR2-KEY-04). At 20x
  that is at most **1.6 % / 2.7 % of NAV a day** in round-trip fees. Without the budget, only the 15 % daily-loss
  breaker bounds it.
- What counts: a market open, a limit / stop placement (counted at placement, filled or not), and an increase.
  Closes, reduces, cancels and leverage changes add nothing. The budget never blocks an exit.

**Minimum holding time** (the vault never pays the protection close factor by its own choice)

```
held(index) = caller ∈ {manager, agent} ∧ caller ≠ guardian ∧ ¬breached ∧ ¬emergency
            ∧ trade is an open market trade, contractsVersion ≥ v9.2
            ∧ ( floorHeld ∨ gainsHeld )
            ∧ (for close / reduce / flatten) mayBeInProfit
floorHeld = minHoldBlocks ≠ 0 ∧ L2block ≤ lastPosIncreaseBlock + minHoldBlocks
gainsHeld = protectionCloseFactor(pair) > 1x ∧ L2block ≤ lastPosIncreaseBlock + protectionCloseFactorBlocks(pair) + 40
            ∧ costs:  getTradeCumulVolPriceImpactP(vault, pair, long, sizeUsd, inProfit = true,  close, last + 40)
                   ≠ getTradeCumulVolPriceImpactP(vault, pair, long, sizeUsd, inProfit = false, close, last + 40)
mayBeInProfit = grossPnl(at the favourable edge of the NAV band, after Gains' skew impact on close) + realizedPnl
                > holdingFees           (closing fee, spread and cumulative impact left out: all against the trader)
```

- **"Costs".** The factor multiplies only the cumulative-volume impact. The vault asks Gains for that impact with
  `inProfit = true` and `false`, with the window shifted by the margin, so the margin counts too. Equal answers mean
  the factor adds nothing on this trade: the pair has no depth bands for that side, or it is exempt. Then nothing is
  held. Live (§6 fork): ETH's impact reads 0 in both cases, so the factor costs nothing and ETH closes are not held.
  This is the v2 rule. v1 held every pair with a factor above 1x, which held BTC / ETH closes for no saving.
- **Where.** `closeTrade` and `reduceTrade`: refused with `"min hold"`. The operator's shortfall reduce is not a
  manager path and is never held. `flatten` and `flattenIndices` by the manager skip the held trade; `flatten` counts
  it in `remaining`. `setSlTp`: a non-zero TP change, or an SL on the profit side of the entry, is refused in a hold
  window, because Gains executes TP / SL with the factor. `openTrade` refuses `tp != 0` (`"tp at open"`) only where a
  new trade would be held (`policy.openTpHeld`: the floor is set, or the factor costs on the pair now). The TP is then
  set with `setSlTp` after the window.
- **Never held.** The guardian (`flatten`, `closeTrade`), the owner / operator / sentinel exits in a breach or an
  emergency, every exit while `breached` or `emergency`, losing closes, a loss-side SL, a TP removal, and resting-order
  cancels.
- **Fail open.** The vault calls `policy.holdBlocked` under try / catch. A stale Chainlink feed, a down sequencer or a
  Gains facet change (decode or selector failure) never holds an exit.
- **Margin.** A close is a request that fills in a later block. If the request is accepted after the window, the fill is
  after it too, so the margin is not needed for timing. The 40 blocks (~10 s) are a buffer against a change in how Gains
  stamps or compares the block. Gains' own window is read live (`getPairFactors`), so a change Gains makes there (bounded
  at 10 minutes) carries over.
- **Bounds.** `minHoldBlocks` 0..14,400 (~1 h at 0.25 s), default 0 (Gains' window + margin only). It is a floor
  held on every pair, whether or not the factor costs there. For this field, raising is the tightening and lowering
  is the loosening. Lowering cannot shorten the hold below Gains' window + 40 where the factor costs, because that
  rule is not configurable.

**Loss gate in openTrade** (GR2-KEY-01)

```
price  = sharePrice(idle + GainsNav value)           (the NAV the order is checked at; checkRisk's basis)
start  = riskDay == today ? dayStartSharePrice : price
refuse ReduceOnlyMode if (start − price)/start > maxDailyLossBps  or  (peak − price)/peak > maxDrawdownBps
```

- Same formulas as `GainsVaultGovernance._check` (:177-208), at the same NAV basis. On a new UTC day not yet recorded,
  the daily loss is 0, as in `_check`. Runs on `openTrade`, `increaseTrade` and the leverage raise. It only refuses: the
  breach itself is still recorded by the next `checkRisk` (anyone may call it). Below MIN_RISK_NAV or with no shares it
  does nothing, as in `_check`.

### 4.3 Tightening and loosening (consistent with RiskConfig and exit before effect)

`proposeOrderLimits(next)` (owner):
- **Instant** when every field is at least as strict: depth ≤, turnover ≤, minHold ≥. A queued loosening is then
  dropped.
- **Otherwise queued**, with `eta = _noticeEta(pending epoch length)`. This is the GR2-CFG-01 notice: at least the
  timelock, one full epoch plus `EXIT_MARGIN` (1 day), and past any deadline left by a lowered epoch. It is the same
  call `queueAllowAsset` uses after CFG-01.
- `applyPendingOrderLimits()` is permissionless after the eta and expires after `GRACE_PERIOD` (14 days).
  `cancelPendingOrderLimits()` is owner-only.

Defaults are set in `initialize`, so `GainsVaultFactory` and its `CreateParams` are unchanged.

### 4.4 How it stacks with GAINS-GR2-CFG-01

The patch is made against **origin/main + `patches/GAINS-GR2-CFG-01.patch`**. It uses CFG-01's `_noticeEta` for the
loosening notice, and its policy hunks sit next to CFG-01's `EXIT_MARGIN` and `epochDeadlineCeiling`. Apply order:
`GAINS-GR2-CFG-01.patch`, `GAINS-GR2-CFG-01.tests.patch`, `gains/GAINS-OPENTRADE.patch`,
`gains/GAINS-OPENTRADE.tests.patch`. `git apply --check` on origin/main alone **fails** at GainsVaultPolicy.sol:46, by
design. The tests patch (mock diamond views) applies on its own.

The patch does not touch the files or lines CFG-01 changes in Governance, Lens or Math's `epochOverdue`.

It overlaps with audit/gains-r2's own `fixes/GR2-KEY-01/fix.diff`, which this patch supersedes: the same
`Snapshot.pairNotional` / `venueFor` plumbing and the same `_lossGate`. The difference is that the cap is a bounded
policy field instead of a constant, and it adds the OI ceiling (XF-04). Do not apply both. gains-r2's KEY-01 fix tests
pass on this patch unchanged (§6).

### 4.5 Exact diffs

- patches/gains/GAINS-OPENTRADE.patch (not included): `contracts/src`. IGainsDiamond (3 views +
  `PairFactors`), GainsNav (pair notional), GainsVaultMath (`venueFor`), GainsVaultLogic (calls, `_lossGate`, `_held`,
  `_dropHeld`, `_checkExposure`), GainsVaultPolicy (`OrderLimits`, `checkExposure`, `turnoverUsed`, `holdBlocked`,
  `_protectionCosts`, `openTpHeld`, propose / apply / cancel).
- patches/gains/GAINS-OPENTRADE.tests.patch (not included):
  - `MockGainsDiamond`: `getPairSkewDepth`, `getPairMaxOiCollateral`, `getPairFactors` and a cumulative-impact model,
    each with setters. Unset, the mock behaves as before: no cap, no OI ceiling, no factor, impact 0;
  - `IntegrationMock.t.sol`'s `EvilDiamond`;
  - the two GR1-02 cycle tests (§5).

## 5. How it stacks (lead's instruction 2026-10-20: the integrated patch)

Verified stack, in apply order, against `audit/hl-r2` c6227bd (`contracts/src` = origin/main 4ec6feb):
1. `integrated/CONTRACTS.patch` + `integrated/CONTRACTS.tests.patch`. These already contain GAINS-GR2-CFG-01; their
   `src/gains` hunks are byte-identical to `GAINS-GR2-CFG-01.patch`.
2. `gains/GAINS-OPENTRADE.patch` + `gains/GAINS-OPENTRADE.tests.patch`.

Both apply cleanly. The patch also applies unchanged on origin/main + `GAINS-GR2-CFG-01.patch` alone (the first dev
tree), and **not** on origin/main alone.

Two existing tests are adapted in the tests patch, because the turnover budget now ends their loops:
- `R1NavBias::test_GR1_02_repeatedCyclesUnprofitable` waits 25 h per cycle instead of 1 day, so the previous cycle's
  open leaves the rolling window.
- `XReview::test_GR1_02_intradayCyclesNoLongerTakeFromTheHolder` stops its loop at a `"turnover"` refusal, as it
  already did at a breach, and asserts that at least one cycle ran.

The property they check (the cycle is unprofitable, the holder loses at most rounding) is unchanged and still
asserted.

## 6. Tests and results

All runs are in throwaway worktrees under `$TEMP`. Each builds the whole tree (Gains, scripts, every fix test) as
**one compiler job**, as the README and the deploy runbooks do. Verifier: verify-gains.sh (not included). Logs:
`results/gains-opentrade-v2.*` for the final patch. `results/gains-opentrade-v1.*` is the first version, which held
every pair with a factor (§4.2, "Costs"); `results/gains-opentrade-fork.*` is the fork-only rerun.

**The original GR2-KEY-01 PoC.** audit/gains-r2 `XReviewKeySkewFork::test_GR2_XR_08_skewOppositeProfits_ETH_V5M_A5M`,
copied unchanged, run against the real diamond (public RPC, tip − 40).

| Tree | Result | Numbers |
|---|---|---|
| integrated base (block 516,700,878) | **PASS** (the exploit works) | ETH skew depth 13.96M; V = A = 5M; vault NAV 1.047M; extra vault loss 8,943.6 USDC (term 8,951.8); **opposite account +4,941.7 USDC** |
| integrated base + this patch (516,714,689; v2: 516,747,479) | **FAIL, `OrderRejected("pair depth")`** | refused at the 3rd 250k ETH order (cap 5 % × 13.96M = 698k) |

**audit/gains-r2's own KEY-01 fix tests** (5 mock + 1 fork), unchanged:
- on the base: 1 pass, 5 fail, as gains-r2 reported for 4ec6feb;
- **with this patch: 6 / 6 pass.** That includes the fork test, where the first ETH order past the cap is refused.

**This patch's fix tests (mock):** tests-gains/GAINS-OPENTRADE.fix.t.sol (not included),
**23 / 23 pass**.

| Check | Violation refused | Compliant passes | Exits unaffected | Loosening timelocked |
|---|---|---|---|---|
| Depth cap | `depth_perPairCap` (750k > 600k, filled + pending counted), `depth_increaseCounts`, `depth_noSkewDepthRefused`, `depth_oiCapIsTheCeiling` | 100k more fits exactly at 600k; BTC unaffected; 300k at a 300k OI ceiling | close after a depth cut to 1 | `tightenInstant_loosenBehindExitNotice`: eta = queue + 7 d epoch + 1 d; NotReady before, apply after, cancel, Expired after grace, a tightening drops the queue. Also `depth_tighteningBindsAtOnce` |
| Turnover | `turnover_budgetAndRollingWindow` (3x NAV used, then 1k refused; still refused at h0 + 24 h; back at h0 + 25 h), `turnover_increaseCounts_exitsFree` | increase to 240k under 2.5x | reduce and close add nothing to the budget | a queued raise does not lift the budget |
| Minimum hold | `hold_profitableCloseHeldUntilWindowPlusMargin` (held at last + 790, accepted at + 791); `hold_reduceFlattenAgentHeld` (reduce refused, manager flatten sends 0 / remaining 1, flattenIndices 0, agent close refused); `hold_tpAndProfitSideSl` (TP at open on a costly pair, TP change and profit-side SL refused); `hold_policyFloor` | losing close (`hold_losingCloseAllowed`), loss-side SL, TP after the window, TP at open on a pair without cost, `hold_factorThatCostsNothingHoldsNothing`, `hold_noFactorNoHold` | `hold_platformAndBreachExitsNotHeld` (guardian flatten and close, manager close in a breach); `hold_failedReadNeverBlocksExit` (the factors read reverts; a stale feed) | a lower `minHoldBlocks` is queued (in the timelock test) |
| Loss gate | `lossGate_dailyLossRefusesNewRiskBeforeCheckRisk` (open, increase and leverage raise refused at −18 %, before any `checkRisk`); `lossGate_drawdown` (−12 % from the peak, on a new day) | `lossGate_withinLimitStillTrades` (−12 % < 15 %) | the close passes at −18 %; `checkRisk` then records the breach | uses the existing RiskConfig limits |
| Plumbing | `checkExposureVaultOnly`, `limitBounds`, `defaults` | | | |

**Fork tests on the real diamond:** tests-gains/GAINS-OPENTRADE.fork.t.sol (not included),
v2 run at block 516,747,267.

| Pair | protectionCloseFactor / blocks | Gains' cumulative impact inside the window, in profit / not in profit (1e10 %) | 100k close at +1 %: inside vs just after the window | Hold |
|---|---|---|---|---|
| ETH (1) | 20x / 750 | **0 / 0** (no cost) | 10,919.900 vs 10,919.798 USDC. Nothing extra inside; the 0.10 USDC difference is holding fees over the window | **not held** (PASS) |
| SOL (33) | 20x / 750 | **−318,345,140 / −15,917,257** (exactly 20x) | 10,865.593 vs 10,896.117 USDC: **30.52 USDC more inside**, 3.05 bps of notional, 0.31 % of the collateral | see below |
| SOL, losing close | | | | not held (PASS) |

FORK-HOLD-PLACEHOLDER

**Whole suite, one job, stacked patches** (v2; `ARBITRUM_RPC_URL` unset, as in the lead's integrated run):
- **928 tests in 146 suites: 882 pass, 19 fail, 27 skip.**
- The 19 failures:
  - the 17 integrated superseded PoCs (verify-integrated.sh's list; the same 17 as in
    `results/integrated-contracts.log`);
  - `MutMisc::test_HLR2_M41_kills_agentSlotGuards` and `test_HLR2_M72_kills_timelockedSetterBounds`. These are HL
    mutation-kill tests, added to `audit/hl-r2` after the integration run. They expect `CallFailed` but get H01's
    `NotReady`. They **fail on the integrated base too** (`gains-opentrade-v2.pre-named.txt`) and touch no Gains code.
    They are an integration follow-up, not part of this patch.
- **Failing only with this patch: none.**
- The lead's integrated run had 760 pass / 17 fail / 24 skip of 801. The difference comes from three sources: tests
  added to `audit/hl-r2` since then (mutation kills); gains-r2's KEY-01 PoC and fix tests; and these fix tests (23 mock,
  plus 4-5 fork tests that skip without an RPC).

**Sizes** (runtime bytes, integrated + this patch; limit 24,576):

| Contract | Integrated base | + this patch |
|---|---|---|
| GainsVaultLogic (linked library) | 22,014 | **24,142** (434 left) |
| GainsVaultPolicy | 13,068 | 19,528 |
| GainsNav (linked library) | 12,340 | 15,740 |
| GainsVaultGovernance / GainsVault / Lens / Factory | 13,119 / 19,037 / 10,631 / 12,203 | 13,143 / 19,067 / 10,650 / 12,203 |

The one-job build exits 1 on the base and on the patched tree alike. Both times the only cause is the pre-existing
test handlers over EIP-170: GainsHandler, Reaudit2Handler, ReauditHandler, SpecHandler and VaultHandler. They are
never deployed and are listed in INTEGRATION.md.

## 7. What each check closes, and what is left

**Depth cap**
- **Closes** the **GR2-KEY-01** skew route: the PoC fails. The opposite capture per vault round trip is at most
  maxPairDepthBps / 200 of A (2.5 bps at 5 %), below the opposite account's measured cost. It also bounds
  GR2-GNS-03's NAV-move lever, since the vault's own share of the skew is capped.
- **Residual:**
  1. **The cap is per vault, not per platform.** The executor holds every hot agent key, so a thief holding the agent
     keys of N vaults gets N caps on one pair. A factory-level per-pair aggregate or an executor alarm is needed (§8).
  2. The fee-tier discount behind the 5 % is unverified (the second half of XF-04); the fee-tier source was not in
     the fetched facet.
  3. The cumulative-volume (OI window) impact is shared across traders and is not capped here. Turnover bounds how
     often it can repeat.
  4. A depth that Gains reports in the wrong unit is bounded only by the OI ceiling.

**Turnover budget**
- **Closes / bounds:**
  - **GR2-KEY-04** churn: at most 1.6 % (BTC, ETH) or 2.7 % (SOL) of NAV a day in round-trip fees at 20x;
  - the number of KEY-01 round trips;
  - the open/close churn that **GR2-EXE-01** says is not alarmed;
  - ECON-01's hedged-book trick, in volume.
- **Residual:**
  - Volume is counted at placement, so a limit order that never fills still uses budget. This is the strict reading.
  - The budget is relative to NAV at the order, so after a loss the remaining budget shrinks (the conservative
    direction).
  - 20x still lets a key burn about 2.7 % of NAV a day on SOL. Owners can tighten it instantly.

**Minimum holding time**
- **Closes:** the vault no longer **chooses** to pay Gains' protection close factor. Measured: 30.52 USDC per 100k SOL
  close, about 0.3 % of collateral per winning scalp. There is no finding ID; this is a brief item.
- **Residual:**
  1. Gains executes TP / SL by bot. A TP at the open is refused only where the factor costs. An SL that the
     **sentinel** tightens to the profit side during a breach can still fire inside the window, because exits are
     never blocked, by design.
  2. "May be in profit" is judged at Chainlink's favourable band edge, without fees. So a small loser (within band ×
     leverage) is held too, for at most ~3.5 minutes.
  3. A price move between the request and the fill can turn an allowed losing close into a profitable one inside the
     window. The cost is bounded by the factor on that trade.
  4. Fail-open: if Gains changes its views, the hold stops holding. No exit is ever blocked.
  5. Gains' `protectionCloseFactorWhitelist` is not read; the vault is not on it.

**Loss gate**
- **Closes** **GR2-KEY-01**'s "openTrade never calls checkRisk": no new risk past the daily loss or drawdown limit,
  whatever the keeper's cadence.
- **Residual:**
  - The gate only refuses. The breach itself is recorded at the next `checkRisk`.
  - A resting limit / stop order placed before the loss can still be filled by Gains' bot after it. The platform's
    `triggerBreach` cancels resting opens.
  - It uses the same NAV basis as `checkRisk` (the adverse band edge), so a band-sized move can refuse an order that
    a mid-price view would allow.

**Contract size.** GainsVaultLogic has 434 B left. The other gains-r2 fixes (LIVE-01, ECON-03, KEY-06) do not fit on
top as they are. Whichever is integrated next must move code out of Logic, for example `_lossGate` into the policy.

**Gas.** Not measured at 20 positions on a fork. An open, an increase or a leverage raise adds three diamond views, one
Chainlink read and up to 25 SLOADs (turnover): roughly 60-90k gas. A manager or agent close adds `holdBlocked`, up to
8 views.

## 8. Executor and webapp follow-ups (none needed for safety; all small)

- **Executor** (`server/src/venues/gains`):
  - Surface `OrderRejected("pair depth" | "no skew depth" | "turnover")` as strategy limits, not as errors.
  - On `"min hold"`, retry the close after `lastPosIncreaseBlock + protectionCloseFactorBlocks + 40` L2 blocks, read
    from `getTradeInfo` / `getPairFactors`.
  - The submitter already sends `tp: 0` at the open (submitter.ts:278). Keep that, and set the TP with `setSlTp` after
    the window.
  - Add `OrderLimitsQueued` to the guardian alert list next to `ConfigQueued` (owner decision c).
  - Alarm when the vaults of one agent key together hold more than the per-vault cap on one pair (the per-platform
    residual).
  - ABI: `orderLimits()`, `pendingOrderLimits()`, `turnoverUsed()`, `holdBlocked()`, `openTpHeld()`,
    `proposeOrderLimits()`, `applyPendingOrderLimits()`.
- **Webapp:**
  - The order form (`lib/gains.ts` `openParams` sets `tp`): hide or disable the TP-at-open field when `openTpHeld` is
    true, with the copy "set a take profit after the first ~4 minutes".
  - Map the new refusal strings to plain messages.
  - Show the order limits, and any pending loosening with its eta, on the policy panel next to the RiskConfig.
  - The depositor docs should say that the vault caps exposure per pair and opened volume per day.

## 9. Not proven / assumptions

- F1. The fee-tier assumption behind the 5 % default (no tier gives an opposite trader more than ~2/3 off) is carried
  over from gains-r2. It is not verified here.
- F2. That Gains' cumulative impact on a close always goes against the trader is read from the source
  (`_getDepthBandsPriceImpactP` with negative signed volume). Only the fork cases were observed.
- F3. Live values come from blocks on 2026-10-20 (18:10 to 23:55 UTC). Gains can change factors, windows (at most 10
  minutes) and depths at any time; the vault reads them live.
- F4. Gas at 20 positions was not measured.
- F5. Halmos and medusa were not re-run on the patched tree (no heavy tools).
- Conservative readings taken where the brief is open:
  - a TP placed at the open counts as the vault's own choice;
  - a flatten by the manager counts as a manager close;
  - "losing" is judged at the favourable band edge.
