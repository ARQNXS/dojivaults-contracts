# Round 2, domain GNS (3.5): the Gains side

**Internal, AI-assisted review. Not an independent audit.**

Sub-reviewer GNS. Question (METHOD.md): can value leave a Gains vault, or move between depositors, because of
something Gains does (an upgrade, a parameter, a pause, a third party trading on Gains, the gToken, USDC)?

Evidence:

- `contracts/test/audit/gains/r2/GainsSideForkBase.sol`: the round 1 lifecycle harness, re-pinned to block
  516,300,000 (`GNS_FORK_BLOCK` overrides it).
- `contracts/test/audit/gains/r2/GainsSideFork.t.sol`: the fork tests (real diamond, oracle answers emulated by
  pranking Gains' Chainlink nodes, feeds frozen with `mockCall`).
- Scratchpad (not in the repo): the verified sources in `gns-src/`, the governance log scan in `gns-scan/`.

## 0. Assumptions

| # | Assumption |
|---|---|
| G-1 | Arbiscan refuses automated fetches. Sources come from Sourcify (v2 API, `full`/`exact_match` or `match`). Five facets are not on Sourcify: TradingStorage, TradingCallbacks, PairsStorage, PriceAggregator and an unidentified 4-selector facet. The libraries those facets compile in (TradingCallbacksUtils, TradingCommonUtils, TradingStorageUtils, ...) ship inside the verified bundles, all from the same 2026-09-19 cut. **Conservative reading:** the unverified callbacks facet runs the newest bundled TradingCallbacksUtils. All six bundles carry the same TradingCallbacksUtils; three versions of TradingCommonUtils exist, and the newest is the one in GNSTradingInteractions. Where behaviour matters, a fork test on the live diamond stands in for the source. |
| G-2 | The public RPC serves state only for some blocks. 516,380,000 answered during the parameter reads and stopped answering within an hour. 516,300,000 answers about 3 reads in 4. Fork tests default to 516,300,000. That block also stopped answering during this run, so the recorded runs used `GNS_FORK_BLOCK` = head − 300 (section 6). A run that fails on `missing trie node` / `historical state not available` is an RPC failure, not a test result; rerun it with `GNS_FORK_BLOCK=<recent block>`. |
| G-3 | Parameters quoted in this report (skew depths, OI, fees, gToken limits) are `cast call` reads at block 516,380,000 (2026-10-19). |
| G-4 | "Live vault" means the deployed factory [an earlier factory]'s vault [an earlier vault]: cap 101 USDC, no trades. No item below is exploitable on it today. |

## 1. Facet map

The diamond address 0xFF16…f169 is itself a **TransparentUpgradeableProxy**:

- implementation: GNSMultiCollatDiamond 0xff84…e0ed, exact match;
- ProxyAdmin: 0xe18b…b2eb, exact match.

The ProxyAdmin is owned by **TimelockController 0x5f5E…DF0F, minimum delay 14 days**. That timelock also owns gUSDC.

The implementation holds `diamondCut`, the loupe and the role store (GNSAddressStore). The 15 facets at block 516,384,157 (`facets()`):

| Facet | Address | Sourcify | Installed (cut block, date) | Vault selectors behind it |
|---|---|---|---|---|
| GNSTradingInteractions | 0x66B2…D327 | match (0.8.23) | 506,848,958 (2026-09-19) | openTrade, closeTradeMarket, decrease/increasePositionSize, updateSl/Tp, updateLeverage, updateMaxClosingSlippageP, cancelOpenOrder, cancelOrderAfterTimeout, getTradingDelegate, getMarketOrdersTimeoutBlocks |
| GNSTradingStorage (inferred from selectors) | 0xaFBD…90D9 | **not verified** | 506,848,958 | getTrades, getTrade, getTradeInfo, getPendingOrders, getTradeLiquidationParams, getCollateral, getCollateralIndex (also getTradingActivated, updateTradingActivated, getGToken) |
| GNSPairsStorage (inferred) | 0xc03d…b408 | **not verified** | 506,848,958 | pairSpreadP, pairMinPositionSizeUsd, pairMinFeeUsd, pairTotalPositionSizeFeeP, pairMaxLeverage, getPairFlags, getTradeFeeParams (also getPairCounterTradeFeeRateMultiplier) |
| GNSPriceImpact | 0xDCAD…4e55 | match | 506,848,958 | getTradeSkewPriceImpactP, getTradeCumulVolPriceImpactP |
| GNSBorrowingFees | 0x5D27…E5f9 | match | 506,848,958 | getTradeLiquidationPrice |
| GNSFundingFees | 0xe197…798B | match | 506,848,958 | getTradePendingHoldingFeesCollateral, getTradeRealizedPnlCollateral |
| GNSPriceAggregator (inferred) | 0xe068…9E36 | **not verified** | 506,848,958 | getUsdNormalizedValue, getCollateralFromUsdNormalizedValue (also fulfill, getChainlinkToken) |
| GNSTradingCallbacks (inferred) | 0x7bDF…E76D | **not verified** | 506,848,958 | none directly; it executes every fill (close payout path) |
| GNSFeeTiers | 0x846e…F2Fb | exact_match | 443,462,970 (2026-03-19) | calculateFeeAmount |
| GNSReferrals | 0xa29e…F93C | exact_match | 443,462,970 | none |
| GNSOtc | 0x6F3A…a17B | exact_match | 443,462,970 | none |
| GNSTriggerRewards | 0xa964…00d1 | exact_match | 407,480,767 (2025-12-05) | none (triggerOrder is in TradingInteractions) |
| GNSMulticall | 0x04b2…4391 | exact_match | 377,721,703 (2025-09-10) | none |
| GNSChainConfig | 0x359D…4CB4 | exact_match | 377,721,703 | none |
| unidentified (4 selectors 0xdfa02be1, 0x1b2f097a, 0xb998164d, 0x4d564aad) | 0xFAA2…9CDa | not verified | 506,848,958 | none |

Source links have the form `https://sourcify.dev/server/v2/contract/42161/<address>?fields=sources`. The selector-to-facet map came from `facetAddress(selector)` on the 34 vault selectors.

**Source versions.** Every verified bundle compiles with 0.8.23. TradingCommonUtils exists in three versions across the bundles:

- **Newest** (TradingInteractions, FeeTiers, Otc, FundingFees): counter-trade fee multiplier and `skipFeeTierMultiplierCounterTrade`.
- **Middle** (PriceImpact): `skipFeeTierMultiplier` only.
- **Oldest** (BorrowingFees): no skip flag.

All three have the same `getPnlPercent` (floor at −100 %, no cap above) and the same close formula.

## 2. Upgrade history

Source: public-RPC `eth_getLogs` over blocks 100,000,000 to 516,380,000, one topic per request in 10M-block chunks. Topics: `DiamondCut`, `AccessControlUpdated`, `Upgraded`. Script and output are in the scratchpad (`gns-scan/scanlogs.mjs`, `gov-logs.json`, `decoded.txt`).

- **Proxy implementation upgrades** (`Upgraded`, ProxyAdmin behind the 14-day timelock):
  - block 167,122,054: 0x1b7a…;
  - 211,888,187: 0xe7b5…;
  - 261,370,325: 0x6825…;
  - 364,917,633 (2025-08-04): 0xff84… (current).
- **diamondCut transactions:** 28, from 2024-05-16 to 2026-09-19 (178 cut entries).
  - Dates: 2024-05-16, 06-24, 07-01, 07-12, 08-04, 08-08, 08-30, 09-06, 10-07, 10-11, 10-19; 2025-01-08, 02-18, 02-24, 03-04, 03-11, 03-20, 08-04, 08-10, 09-10, 10-21, 10-29, 12-05, 12-11; 2026-01-08, 03-19, 09-12, 09-19.
  - That is **one cut every ~31 days**. Since 2025-09 every cut has replaced at least one facet behind a vault selector.
  - The last two cuts, 2026-09-12 (tx 0x70b1…) and **2026-09-19 (tx 0x3024…)**, replaced the facets behind 29 of the 34 vault selectors (TradingInteractions, TradingStorage, PairsStorage, PriceImpact, BorrowingFees, PriceAggregator, FundingFees, Callbacks). The vault's Gains integration was written against the v10 ABI before 2026-09-19 and still matches on the fork (round 1 `IntegrationForkTest`, round 2 tests here).
- **Who executed the cuts:**
  - 2026-09-19 and 2026-03-19: the **GOV_EMERGENCY_TIMELOCK 0x893f…e75a (minimum delay 36,000 s = 10 hours)**, proposed by the GOV Safe and the emergency Safe respectively;
  - 2026-09-12: the GOV_TIMELOCK 0x1632…F637 (3 days).

## 3. Governance roles and delays (diamond, at block ~516.38M)

| Role (IAddressStore.Role) | Holder | Delay | Powers relevant to a vault |
|---|---|---|---|
| GOV_TIMELOCK (0) | TimelockController 0x1632…F637 | **3 days** | diamondCut, setRoles, cumulative factor / exemptions |
| GOV_EMERGENCY_TIMELOCK (4) | TimelockController 0x893f…e75a | **10 hours** | diamondCut, setRoles |
| GOV (1) | Safe 0xc07E…2f3a (threshold 4) | none | timeout blocks, impact windows, protection factors, user price impact, fees and pair parameters (PairsStorage, unverified), pause (inferred), manual PnL / holding-fee realization |
| GOV_EMERGENCY (3) | Safe 0xe899…cAB5 (2 of 4) | none | pause / CLOSE_ONLY (inferred), skew depths, funding parameters, borrowing cap, impact settings |
| MANAGER (2) | EOAs 0xe72D…39Db and 0x4842…a384 (the second added at block 506,889,246) | **none** | `setPairSkewDepths`, `setPairDepthBands`, borrowing pair / group parameters, every funding-fee parameter, `setMaxSkewCollateral`, `initiateManualNegativePnlRealization` / holding-fee realization on any trade |
| ProxyAdmin owner | TimelockController 0x5f5E…DF0F | 14 days | replace the whole diamond implementation (diamondCut, loupe, roles) |
| gUSDC | owner 0x5f5E (14 d), manager 0x1632 (3 d), admin Safe 0xe899 (2 of 4) | | gToken parameters (`maxDailyAccPnlDelta`, …), upgrade |

What this means for a vault:

- **The fastest code change** to the facets the vault reads and trades through is **10 hours**. That is shorter than the vault's own timelock (2 days live), its epoch (1 day) and any setPairFeed rotation.
- **Instant changes.** Every economic parameter the NAV reads (fees, spreads, skew depth, depth bands, holding-fee rates, max skew) can be changed with no delay by a Safe or by a MANAGER **EOA**.

## 4. Answers

### Q1. What can an upgrade or a parameter change do to vault funds?

**Principle.** GainsNav values each trade with Gains' own close formula. It reads every input live from the diamond:

- spread, skew impact, cumulative-volume impact (two passes, protection factor);
- fee rate with the minimum-position basis;
- holding fees, realized PnL;
- liquidation price.

It applies Gains' `getPnlPercent` and `getTradeValuePure`. Three consequences:

- A **parameter** change moves NAV and the payout together. NAV is not wrong, it steps; the step is real value and the normal settle bound (maxNavMove 20 %) applies.
- A **code** change (a facet upgrade) that changes the formula, or adds a term GainsNav does not mirror, makes NAV wrong **silently**. Only layout changes are detected (GR1-08 fix, GV-01 checks).
- **Liquidity** changes (pause, delisting, gToken refusal, blacklist) leave NAV at full value while the value cannot be realized. A settle in that state pays redeemers from idle at that NAV.

Table "Gains change → vault effect" (detected = an on-chain revert or a named error the vault raises):

| Gains change | Who / delay | Vault effect | Detected? | Exits? | NAV silently wrong? |
|---|---|---|---|---|---|
| Facet upgrade that appends fields to Trade / PendingOrder | timelock 10 h / 3 d | none (stride-tolerant decoder) | n/a | yes | no |
| Facet upgrade that inserts / reorders fields | 10 h / 3 d | `DiamondLayoutChanged` on priced paths and flatten | yes | flattenIndices, full stop | no (fails closed) |
| **Facet upgrade that changes the close formula** (a PnL cap, a new fee, a different fee basis, a new impact term, a protection-factor change in TradingCallbacks) | 10 h / 3 d | GainsNav keeps the old formula | **no** | yes | **yes, by the size of the change** (GR2-GNS-02) |
| Proxy implementation upgrade (loupe / roles / cut logic) | 14 d | anything | no | n/a | possible |
| Closing fee rate, spread, min position size, fee-tier flags | GOV Safe, instant (PairsStorage, unverified) | NAV reads them live | no revert (step) | yes | no (equals payout) |
| Skew depth / depth bands / cumulative factor / protection factor / windows | MANAGER EOA or Safe, instant | NAV step | no revert | yes | no; fork: depth ÷4 moved NAV by >1,000 USDC on 500k, payout still ≥ NAV (`test_GNS_managerSkewDepthChange_navStepsSilently_matchesPayout`) |
| Holding-fee (borrowing, funding) parameters | MANAGER EOA, instant | future fees change; NAV reads pending fees live | no | yes | no |
| Manual negative-PnL / holding-fee realization on the vault's trade | GOV or MANAGER EOA | bookkeeping between diamond and gToken | n/a | yes | no; fork: NAV within 2 USDC, no USDC moved (`test_GNS_managerManualRealizations_navNeutral`) |
| Liquidation parameters | GOV / MANAGER | stored per trade at open: open trades keep theirs | n/a | yes | no |
| pairMaxLeverage lowered | GOV | new opens / increases cancelled at the callback (MAX_LEVERAGE); open trades unaffected | callback cancel, 1 gov fee | yes | no |
| Market-order timeout blocks (uint16) | GOV, instant | a pending open holds settle for up to 65,535 blocks (~4.5 h) (GR1-04 bound) | n/a | yes | no |
| CLOSE_ONLY | GOV / GOV_EMERGENCY (inferred) | GR1-45, unchanged | Gains reverts on opens | yes | no |
| PAUSED | same | every Gains call reverts; NAV still values trades at full | no | **no** (Gains) | value correct, not realizable; an emergency settle pays from idle pro rata |
| Pair delisted / Gains oracle stops for a pair | GOV | closes of that pair do not fill; NAV still uses Chainlink | no | that pair no | NAV values a trade the vault cannot close (GR1-45) |
| Gains oracle source change (Gains' price ≠ Chainlink beyond the band) | GOV | NAV at Chainlink ± band, payout at Gains' price | no | yes | yes beyond the band (round 1 open question 1, trust T3) |
| Collateral (USDC index 3) deactivated | GOV | opens refused (inferred, unverified TradingStorage) | Gains reverts | yes (closes do not check isActive in the bundled callbacks) | no |
| gToken refuses a payout (`MaxDailyPnl`, `NotEnoughAssets`) | market / gToken manager | profitable closes do not fill (the oracle answer reverts); NAV keeps the profit | no | **profitable closes no**, losing ones yes | value correct, not realizable until the daily reset (`test_GNS_gTokenRefusesPayout_closeDoesNotFill_navUnchanged`) |
| `isCounterTrade` | trader only, at open | the vault never sets it (GainsVaultLogic.openTrade leaves it false); Gains cannot flip a stored trade's flag without a facet upgrade | n/a | n/a | no |

### Q2. NAV-vs-payout gaps not covered by round 1

**(a) Positive PnL cap.** None in v10:

- `TradingCommonUtils.getPnlPercent` (every bundled version) floors at −100 % and has no upper cap.
- The close callbacks (`closeTradeMarketCallback`, `executeTriggerCloseOrderCallbackDirect` → `_unregisterTrade` → `getTradeValueCollateral`) apply none.
- TP updates are unchecked (round 1 `LC_LimitStopFork.test_lc_wrongSideTakeProfit_executesAsMarketClose`).
- GainsNav applies none either, so the two agree.

Fork: a 150x ETH long after +8 % closes for more than 11× its collateral, with NAV ≤ payout and the gap equal to the band (`test_GNS_noPositivePnlCap_marketClosePaysBeyond900Percent`). There is therefore no 150x / 5x overpayment to compute.

**(b) Counter trades.** `isCounterTrade` is set only by the trader at open (`_openTradePrep` → `_validateCounterTrade`). The vault always passes false. Gains has no setter for a stored trade's flag. A counter trade would change:

- the fee (`getPairCounterTradeFeeRateMultiplier`, which GainsNav does not read);
- the fee-tier skip;
- the liquidation input (GainsNav passes `t.isCounterTrade` through).

Not reachable for a vault. If a future vault version opens counter trades, GainsNav must read the multiplier.

**(c) TP / SL and limit / stop execution.** From `_validateTriggerCloseOrderCallback`, TP and SL execute **exactly at the trigger** (converted from market to oracle price, then closing spread and impact) whenever the trigger lies inside the oracle's open / high / low range since the request. Otherwise they execute at the current price. Liquidations execute at the liquidation price with value 0. Limit and stop opens execute exactly at the trigger price.

Consequences:

- **SL:** the vault gets ≥ market when the price ran through the SL. NAV understates; conservative.
- **TP:** the vault gets the TP when the price ran past it. NAV values the trade at the market, so it is above the payout until Gains' bot triggers. That is **GR2-GNS-01** (section 5).

**(d) Collateral changing on the diamond without the vault calling it.**

- Holding fees (borrowing v1 / v2 and v10 funding) accrue continuously and are read live (`getTradePendingHoldingFeesCollateral`).
- Gains' MANAGER or GOV can realize holding fees and negative PnL on any trade (types 12 / 13, filed under the caller, not under the vault). These only move bookkeeping between the diamond and the gToken. `getTradeValueCollateral` does not depend on them. Fork: NAV unchanged within 2 USDC, no USDC moved to the vault, the later close pays NAV + band.
- `withdrawPositivePnl` (type 11) is trader-only, and the vault has no entry point for it.

**(e) gToken limits on trader payouts.** `GToken.sendAssets` reverts with:

- `NotEnoughAssets` when the payout would push `accPnlPerToken` above `1e18 + accRewardsPerToken` (gUSDC insolvency);
- `MaxDailyPnl` when the day's net trader PnL passes `maxDailyAccPnlDelta`. Live: 0.5 per gUSDC × 3.10M gUSDC ≈ **1.55M USDC of net trader profit per day across all of Gains' USDC traders**; at block 516,380,000 the day stood at −0.0004.

A close is never paid less than computed: it either pays in full or the oracle answer reverts (fork). The trade stays open and the close times out. NAV keeps the full profit. Liquidity only. Exits of profitable trades wait for the daily reset or for gToken liquidity. Normal settles with redemptions above idle revert `InsufficientLiquidity`; the emergency settle pays pro rata from idle.

### Q3. Third-party NAV manipulation through Gains' skew and volume impact

**Mechanism (GNSPriceImpact, verified).**

- **Skew impact.** For a trade of size T (tokens) the skew impact in % is `(S + T/2) / D / 2`. S is the pair's v10 token OI skew on USDC (long − short); D is `pairSkewDepths[USDC][pair]` in tokens. For a close, T is negative and the sign flips. A vault long's close therefore gains `X / (2D)` % for every X tokens of extra long skew an outsider adds, and loses as much for extra short skew.
- **Round trip.** Skew impact is path independent. The outsider pays `(S + X/2) / 2D` on the open and gets the same back on the close. Their cost is therefore only:
  - fees (opening + closing, `pairTotalPositionSizeFeeP`);
  - the fixed spread;
  - the cumulative-volume impact (zero for BTC and ETH: no depth bands set);
  - holding fees for the time they hold.
- **Cumulative-volume impact on the vault.** It uses the opposite side's OI windows (4 × 90 s). An outsider's open on the same side as the vault's trade does not raise the vault's close impact; an opposite-side open does, for 6 minutes, on SOL only.

**Live parameters (block 516,380,000):**

| Pair | Skew depth D | ≈ USD | Skew now | Max skew | Fee per side | Spread | Cumulative-volume bands |
|---|---|---|---|---|---|---|---|
| BTC (0) | 398 BTC | 32.7M | +4.18 BTC | 10M USD | 0.035 % | 0.01 % (½ per side) | none |
| ETH (1) | 5,738 ETH | 13.8M | +132.7 ETH | 8.5M | 0.035 % | 0.01 % | none |
| SOL (33) | 38,980 SOL | 4.1M | +248 SOL | 4.5M | 0.05 % | 0 | 1M: +2.7 bp open / −1.8 bp close; 4M: +13.5 / −9.1 bp |

**Algebra.**

- NAV change of a vault holding N of notional on the pair, when an outsider adds X USD of same-direction skew: **ΔNAV = N · X / (200 · D_usd)**. Per 1M of outside skew and per 1M of vault notional: BTC 153 USDC, ETH 362 USDC, SOL 1,224 USDC (fork, section 6).
- The outsider is paid only their share f of ΔNAV. Their cost is c · X (BTC / ETH c ≈ 8 bp, SOL c ≈ 14.5 bp at 1M).
- **Break-even: f · N > 200 · c · D_usd**, independent of X. That is BTC ≈ 5.2M, ETH ≈ 2.2M, SOL ≈ 1.2M of the outsider's own pro-rata notional on one pair. At 5x vault leverage the outsider must redeem (or deposit) ≥ 1.05M / 0.44M / 0.24M USDC of vault value concentrated on that pair.

**Fork** (`test_GNS_skew_outsideSkewMovesNav_unprofitableBelowBreakEven`): the measured ΔNAV matches the prediction within 0.4 % on all three pairs; the outsider's round trip costs 8.0 bp (BTC, ETH) and 15.3 bp (SOL); the break-even is 5.23M / 2.21M / 1.25M of pro-rata notional (section 6).

**Bounds that apply:**

- **Max skew:** caps one outsider's X at 10M / 8.5M / 4.5M. The largest NAV move is N × 0.15 % (BTC), 0.31 % (ETH) or 0.55 % (SOL), far below the 20 % settle bound.
- **Settle timing:** chosen by the manager / operator (daily keeper). The outsider must hold X across an uncertain window and pays holding fees plus market risk (hedgeable off Gains).
- **Two-sided pricing (GR1-02):** redemptions at the adverse edge, deposits at the favourable edge. The skew move is additive to that spread, not limited by it.

**Verdict.**

- Not profitable for any redeemer below ~0.24M (SOL) / 0.44M (ETH) / 1.05M (BTC) of vault value at 5x on one pair. The live vault cap is 101 USDC.
- For a redeemer who would open the same Gains position anyway (rotating from the vault into a direct trade), the fee is not an extra cost. The gain is f · N · X / (200 · D), at most 0.15–0.55 % of their pro-rata notional, taken from the remaining holders.
- Recorded as **GR2-GNS-03 (Info / Design)**. No ALERT.

### Q4. USDC (Circle) blacklist, pause, upgrade

| Event | Effect | Exits | NAV |
|---|---|---|---|
| Vault blacklisted | GR1-45: close fills and a pending open's `cancelTimedOut` revert; the vault's own USDC is frozen (every claim reverts) | none | unchanged; settle can still book redemptions that cannot be claimed |
| **Diamond blacklisted** | every Gains USDC transfer fails: opens, closes, refunds; profitable and losing closes alike do not fill | redemptions from idle: yes (settle books, claim pays vault → redeemer); trade exits: no | unchanged, full value of trades that cannot be realized (`test_GNS_usdcBlacklistDiamondAndPause_failClosed_noMisvalue`) |
| USDC paused | every transfer reverts: deposits, claims, Gains opens and closes; settle still books (it moves no USDC) | none until unpause | unchanged |
| USDC upgraded (Circle's proxy) | arbitrary; out of model (trust: USDC) | | |

No path moves value between depositors silently. Every case freezes flows, and the books stay consistent when the freeze lifts. The one residual: a settle during a diamond freeze prices redemptions at a NAV whose trade part may later be realized at a different price, which is ordinary market risk on frozen positions.

## 5. Findings

### GR2-GNS-01 A trade past its take profit is valued at the market, while Gains pays the TP (Low)

**Location.**

- GainsNav.sol:213-220 (`_valueAt` values the trade at the band edge of Chainlink and never looks at `t.tp`).
- Gains: TradingCallbacksUtils `_validateTriggerCloseOrderCallback` (exact execution at the trigger when it lies in the oracle range).

**Description.**

- Once the price runs through a trade's TP, Gains will pay the TP (plus closing impact), however far the market goes before the trigger bot lands.
- Until the bot's trigger is filled (one triggerOrder plus one oracle round; seconds normally, longer in congestion, never while Gains is PAUSED), NAV values the trade at the market.
- The bot's TP_CLOSE order is filed under the bot, so the vault does not see it, and settle is not held.

A settle in that window pays redeemers at the overstated NAV:

- the manager or the operator chooses when to settle;
- the executor sets TPs (`setSlTp`);
- the manager and agent may set any TP.

The overstatement is the remaining holders' loss. The performance fee is also charged on the overstated gain.

**Impact.**

- Per trade: `(C × (1 − B) − TP_after_impact) / openPrice × notional`.
- Fork (`test_GR2_GNS_01_takeProfitPastTheMarket_navAboveWhatGainsPays_redeemerOverpaid`): a 200k vault (alice / bob 50 / 50) holding 500k of ETH long at 100x, TP +1 %, market +2 % at the settle. NAV at the settle was 208,580.11 USDC against 204,457.09 once the TP filled: **4,123.02 USDC (2.0 % of NAV) overstated**. Bob (50 %) was paid 104,290.06 instead of 102,228.55: **+2,061.51 USDC, exactly what alice lost**. Gains paid 9,456.09 at the TP.
- At the live 5x and a 1 % overshoot beyond the band, the overstatement is 5 % of NAV, so a redeemer of half the vault takes 2.5 % of NAV (5 % of their own redemption) from the holders who stay.

**Likelihood.** Low:

- it needs a TP and an overshoot of more than the band (20 bp BTC / ETH, 25 bp SOL) before the trigger;
- a settle must land inside a window of seconds;
- it is natural only in fast markets or a Gains pause;
- a hostile manager with a queued confederate can watch for it.

Impact medium × likelihood low → **Low**.

**Fix.** In GainsNav, for an open market trade with `tp > 0`, value at `min(P, tp)` for a long (`max(P, tp)` for a short), with the same closing impact. Optionally treat a TP crossed by Chainlink as a pending close.

### GR2-GNS-02 NAV mirrors Gains' close formula; a facet upgrade can change it silently, behind a 10-hour timelock (Design / Info)

**Location.** GainsNav.sol:196-314 (the close formula re-implemented); IGainsDiamond.sol (no version pin).

**Description.**

- GR1-08's fix catches layout changes. Nothing catches a change to the **formula** in the unverified TradingCallbacks / TradingStorage / PairsStorage facets.
- Every facet behind the vault's 34 selectors was replaced on 2026-09-12 / 09-19. The 09-19 cut ran through the GOV_EMERGENCY_TIMELOCK with a **10-hour** delay. Gains cuts about monthly.
- The bundled TradingCommonUtils already exists in three versions (counter-trade fee multiplier and skip flags added between them).

A future change such as a positive PnL cap (v8 had +900 %), a new closing fee for vaults, or a different fee basis or impact term would make NAV differ from the payout with no revert. Redeemers would be paid at a NAV that is wrong by that amount until the vault is redeployed (vaults are not upgradeable; the diamond address is immutable per factory).

**Impact.** Unbounded in principle; in practice the size of the change × open notional. **Likelihood:** a Gains release; the 10-hour delay is shorter than any vault-side reaction (2-day timelock).

**Fix (operational, no code).**

- Watch both Gains timelocks (0x1632…F637, 3 days; 0x893f…e75a, 10 hours) and the ProxyAdmin timelock (0x5f5E…DF0F) for `CallScheduled` targeting the diamond.
- On any cut touching the vault's facets, rerun the NAV-diff and replay fork suites against the post-cut code (fork the scheduled cut with `vm.prank(timelock)`) before it executes.
- If they diverge, set the vaults' deposits paused and settle exit-only.

### GR2-GNS-03 Outsiders can move NAV through Gains' skew impact; unprofitable below ~0.24M–1.05M of pro-rata vault value (Info / Design)

See Q3. No PoC of profit: the fork test measures the effect and asserts the break-even is above 1M of pro-rata notional on every pair. Recommended:

- keep settle timing unpredictable or close to Chainlink rounds;
- optionally value trades without the skew term (an approximation that departs from the payout), or cap NAV changes between settles from skew.

## 6. Fork results

Two runs of `forge test --match-path "test/audit/gains/r2/GainsSide*.t.sol"`, forge 1.8.4, public RPC:
- run 3 at block 516,394,847;
- run 4 at block 516,399,010 (the three tests fixed after run 3: a cleared ArbSys mock, a band bound, a consumed prank).

The fixed default block 516,300,000 failed on `historical state not available` (G-2). The runs therefore set `GNS_FORK_BLOCK` to the head minus 300 blocks. **7 / 7 pass.**

| Test | Result | Numbers |
|---|---|---|
| `test_GR2_GNS_01_takeProfitPastTheMarket_navAboveWhatGainsPays_redeemerOverpaid` | PASS (PoC) | 200k vault, 500k ETH long at 100x, TP +1 %, market +2 %. NAV in the window 208,580.11 against 204,457.09 after the TP fill (+4,123.02). Bob's redemption 104,290.06 against 102,228.55 (+2,061.51); alice −2,061.51. Exact execution at the TP: 9,456.09 paid. |
| `test_GNS_noPositivePnlCap_marketClosePaysBeyond900Percent` | PASS | 2,000 USDC at 150x, +8 %: Gains paid 25,757.61 (+1,188 %); NAV valued 25,109.67, below the payout by 647.93 (the band). |
| `test_GNS_skew_outsideSkewMovesNav_unprofitableBelowBreakEven` | PASS | see the table below |
| `test_GNS_managerSkewDepthChange_navStepsSilently_matchesPayout` | PASS | Gains MANAGER EOA, one call: ETH skew depth ÷4 moves the vault trade's value from 24,324.55 to 26,787.23 (+2,462.68 on 500k, +0.49 %) with no revert; the close still pays at least NAV. |
| `test_GNS_managerManualRealizations_navNeutral` | PASS | Gains MANAGER realizes negative PnL, then holding fees, on the vault's losing trade: value 8,861.642 → 8,861.641 USDC; no USDC moved; the close pays NAV + 98 (the band). |
| `test_GNS_gTokenRefusesPayout_closeDoesNotFill_navUnchanged` | PASS | `sendAssets` reverting (`MaxDailyPnl`): all 3 oracle answers revert, the trade stays open, NAV keeps the profit, settle is not held (GR1-04). |
| `test_GNS_usdcBlacklistDiamondAndPause_failClosed_noMisvalue` | PASS | Diamond blacklisted: the close does not execute (an oracle answer is accepted, the trade stays open), NAV unchanged, a redemption is paid from idle. USDC paused: settle books, claim reverts. |

Skew (vault 500k long at 20x, outsider 1M long at 100x, filled and closed at the same oracle price):

| Pair | ΔNAV measured / predicted N·X/(200·D) | Per 1M skew per 1M vault notional | Outsider round trip on 1M | Break-even f·N | At 5x: vault value redeemed |
|---|---|---|---|---|---|
| BTC | 76.53 / 76.69 | 153 | 799.97 (8.0 bp) | 5.23M | 1.05M |
| ETH | 181.11 / 181.53 | 362 | 799.95 (8.0 bp) | 2.21M | 0.44M |
| SOL | 612.08 / 614.12 | 1,224 | 1,532.89 (15.3 bp) | 1.25M | 0.25M |

## 7. Not covered

- **Unverified facets** (TradingStorage, TradingCallbacks, PairsStorage, PriceAggregator, the 4-selector facet). Behaviour is taken from the bundled libraries and confirmed on the fork where it matters (fills, TP, manual realizations, gToken refusal).
- **PairsStorage setters** (fees, spreads, max leverage, delisting) and the pause setter's role were not exercised on the fork. Their effect on NAV follows from GainsNav reading them live.
- **Timelock proposer and executor sets** of 0x1632 / 0x893f / 0x5f5E were not enumerated (RoleGranted logs not scanned).
- **The vault cannot react to a GOV / MANAGER parameter change.** It can be instant, but it moves NAV and payout together.
