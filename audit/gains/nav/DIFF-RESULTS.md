# Differential NAV: TypeScript (gainsnetwork SDK) vs GainsNav (round 1, sub-reviewer 3.1)

Internal review, not an independent audit. Worktree at `5dd1344` (audit/gains-r1 base), Foundry 1.8.4, solc 0.8.28 via_ir,
`@gainsnetwork/sdk` 1.8.10, Arbitrum One fork at block 515,219,884 (random trades) and at each real fill tx (replay).

## Result

**No divergence above 1 bp.** Max divergence of GainsNav's per-trade value from the independent TypeScript
implementation of the documented NAV rule: **0.005 bp** (1 micro-USDC, integer vs float rounding) over 79 trade
valuations. The TypeScript implementation of Gains' own close rule matches the USDC the diamond actually paid to
**0.0024 bp** on every market close (49 fork closes + 8 real mainnet market closes + the oracle-price rows of 7 real
TP / SL closes).

| Data set | Rows | TS NAV rule vs GainsNav: max / mean | TS Gains-exact vs USDC paid: max |
|---|---|---|---|
| Fork, random trades (3 seeds) + SOL protection-factor window | 49 | 0.0001 bp / 0.0000 bp (max abs 1e-6 USDC) | 0.0001 bp |
| Real mainnet closes (15 txs of GainsForkReplay, partials excluded), at the trigger price and at the oracle price | 30 | 0.0050 bp / 0.0008 bp (max abs 1e-6 USDC) | 0.0024 bp on market closes and on TP / SL at the oracle price (see notes) |

Per pair (all 79 rows, TS NAV rule vs GainsNav):

| Pair | Rows | Max | Mean |
|---|---|---|---|
| 0 BTC | 21 | 0.0050 bp | 0.0007 bp |
| 1 ETH | 29 | 0.0016 bp | 0.0003 bp |
| 33 SOL | 29 | 0.0008 bp | 0.0001 bp |

Per leverage bucket (all 79 rows):

| Leverage | Rows | Max | Mean |
|---|---|---|---|
| 2x - 10x | 18 | 0.0050 bp | 0.0006 bp |
| 10x - 50x | 38 | 0.0013 bp | 0.0002 bp |
| 50x - 150x | 23 | 0.0024 bp | 0.0003 bp |

## What was compared

`contracts/audit/gains/nav/diff/diff.ts` (own `package.json`; `npm install`, then
`npx tsx diff.ts ../../../../deployments/audit-nav-diff-*.json [--md]`) recomputes, per trade, from raw diamond reads:

| Piece | Source in the TS | Taken from the diamond as input |
|---|---|---|
| pnl % (floor -100%) | SDK `getPnlPercent` | |
| trade value (collateral + pnl - fees, floor 0) | SDK `getTradeValue` | |
| fixed spread, reversed on close | SDK `getFixedSpreadP` from `pairSpreadP(trader, pair)` | |
| skew impact (v10) | SDK `getTradeSkewPriceImpact` from `getPairOiAfterV10Token`, `getPairSkewDepth`, `positionSizeToken` | |
| price after impact | SDK `getPriceAfterImpact` | |
| closing fee, min-position basis | SDK `getTotalTradeFeesCollateral` from `pairTotalPositionSizeFeeP`, `pairMinPositionSizeUsd`, `getCollateralPriceUsd`; fee tier = `calculateFeeAmount(trader, 1e12)/1e12` unless `skipFeeTierMultiplier` | |
| realized pnl | SDK `getTradeRealizedPnlCollateral` over `getTradeFeesData` | |
| liquidation price | `BorrowingFeesUtils._getTradeLiquidationPrice` (verified facet source) composed with SDK `getLiqPnlThresholdP` + `convertLiquidationParams` | |
| two-pass close impact decision (net value incl. fee tier, holding, realized > collateral) | TradingCommonUtils.getTradeClosingPriceImpact (verified source) | |
| pending holding fees (funding + borrowing v1/v2) at P | | `getTradePendingHoldingFeesCollateral(trader, index, P)` |
| cumulative-volume impact, both passes | | `getTradeCumulVolPriceImpactP(..., false / true, ...)` (OI windows) |

Two TS values per row: **Gains-exact** (fee tier applied, 0 only past the liquidation price: what Gains pays at P) and
**NAV rule** (the PLAN.md 4.3 rule: no fee tier on the closing fee, 0 when P is within the band of the liquidation
price). GainsNav must equal the NAV rule; the diamond's payout must equal Gains-exact. Side checks per row: TS
liquidation price vs `getTradeLiquidationPrice` (max 0.0019 bp), TS skew vs `getTradeSkewPriceImpactP` (max 1e-10 %),
TS realized pnl vs `getTradeRealizedPnlCollateral` (max 1.3e-15 USDC).

## Inputs

- `test/audit/gains/nav/NavDiffFork.t.sol` (`test_diff_randomTrades_seed{1,2,3}`, `test_diff_solProtectionFactorWindow`):
  a factory GainsVault on the real diamond opens 16 random market trades per seed (pairs 0 / 1 / 33, long or short,
  leverage drawn per bucket 2-10x / 10-50x / 50-150x and clamped to Gains' pair limits, notional 0.5k-40k above the
  pair minimum, fill at Chainlink +-10 bps), ages them one day (funding and borrowing accrue), moves Chainlink +-1.5%,
  runs random position updates on half of them (collateral reduce 30%, leverage reduce 30%, increase +20% collateral,
  leverage decrease to 70%; callback cancels allowed), ages six more hours, moves +-0.6%, then closes every trade at
  its adverse band edge P. Right before each fill it dumps every raw input plus `GainsNav.tradeValue` (through
  `NavHarness`), then records the USDC Gains paid. Coverage in the dump: 21 SOL rows with nonzero cumulative impact,
  3 with the 20x protection factor active (pass 2 differs from pass 1), 9 with nonzero realized pnl (partials), 17
  after an increase / leverage update, 21 with negative (received) funding, 2 within the band of liquidation, 1 past it.
- `test/audit/gains/nav/NavReplayFork.t.sol` (`test_diff_replayRealCloses`): the 15 full closes among the 19 real
  fills of `GainsForkReplay.t.sol` (4 partial closes excluded: GainsNav values whole trades), forked at each fill tx,
  dumped at the trigger price (TP / SL), at the oracle price of the fill, with Chainlink at that state.
- JSON written to `contracts/deployments/audit-nav-diff-*.json` (not committed).

## Notes on the non-zero rows of "TS Gains-exact vs paid" in the replay

- **TP / SL at the trigger price** (4-45 bp): Gains executed them at the fill's oracle price (non-exact execution),
  not at the stored trigger. The same trades evaluated at the oracle price match to 0.0024 bp.
- **LIQ** (3 rows): Gains paid 0 while the TS at the recorded `oraclePrice` says 0.56 / 8.30 / 0 USDC. Liquidations are
  decided on the lookback range (low / high), not on the single price the replay case recorded. GainsNav values all
  three at 0 (within the band of the liquidation price), which is the conservative side.
- **GainsNav vs paid** is never above the payout on the exact rows; it is below by the fee-tier discount of real
  traders (up to 0.74 USDC on a 3,000 USDC trade) and by the near-liquidation rule (seed1: a SOL 131x long valued 0
  while Gains paid 98.03 USDC of 195.22 collateral). The latter is the mechanism behind finding NAV-01.

## SDK observations (not vault findings)

- The SDK's `getTradeClosingPriceImpact` decides the protection-factor pass on `pnlPercent > 0` without fees and
  without skew in the first pass; the verified v10 source (and GainsNav) use the net trade value with fees, holding
  fees, realized pnl and skew (`getTradeValueCollateral(...) > collateral`). The TS here follows the contract. Rows
  where the two rules disagree would make the SDK's own close preview wrong, not GainsNav.
- The SDK's `getLiqPnlThresholdP` returns the start threshold for `leverage < startLeverage` (contract: `<=`) and
  falls back to 0.9 when any param is 0 (contract: only when `maxLiqSpreadP == 0`). Equal on all recorded rows.
