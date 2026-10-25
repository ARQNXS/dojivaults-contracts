# Gains vault: gas at the MAX_POSITIONS ceiling (round 1, sub-reviewer 3.2 / 3.3)

Measured on an Arbitrum One fork (block 515,219,884) against the real gTrade v10 diamond, forge 1.8.4, via_ir,
optimizer 200 runs. Every value is the execution gas of one top-level vault call. Forge 1.8 starts each top-level call
with cold accounts and slots, so these are per-transaction numbers. Add 21,000 plus calldata for the total.
Arbitrum One block and transaction gas limit: 32,000,000.

Tests: `contracts/test/audit/gains/lifecycle/LC_LivenessFork.t.sol` (`test_lc_gas_*`, `test_lc_maxPositionsNeverBlocksExits`)
and `LC_GriefFork.t.sol` (decoy request). Positions are 400 USDC at 3x unless stated otherwise.

## NAV readers

| Call | State | Gas | Share of 32M |
|---|---|---:|---:|
| totalAssets (view) | 18 trades + 1 resting limit + 1 pending open | 7,406,344 | 23% |
| checkRisk | same | 7,435,202 | 23% |
| totalAssets (view) | 20 open trades (BTC / ETH / SOL) | 8,055,922 | 25% |
| checkRisk | 20 open trades | 8,063,072 | 25% |
| settle (normal, with a redemption) | 20 open trades | 8,300,505 | 26% |
| totalAssets (view) | 20 trades + pending closes | 8,238,941 | 26% |
| **totalAssets (view), worst case** | **20 trades + 20 pending UPDATE_LEVERAGE decreases** | **9,140,755** | 29% |
| **checkRisk, worst case** | **same** | **9,147,905** | 29% |
| openTrade (18 trades → 19th) | | 8,703,537 | 27% |
| openTrade (19 trades → 20th) | | 9,063,254 | 28% |
| redemptionShortfall (view) | 3 pending orders | 204,904 | |
| redemptionShortfall (view) | 20 pending orders | 514,721 | |

The worst NAV state is 40 diamond items (20 trades, each with one pending market order: Gains allows one per trade).
It cannot grow further. MAX_POSITIONS counts trades, resting orders and pending orders, and Gains refuses a second
market order on a trade. settle cannot run while anything is pending, so its worst case is the 20-trade row.

## Exits (no NAV, no price)

| Call | State | Gas |
|---|---|---:|
| closeTrade | 20 trades | 1,406,758 |
| reduceTrade (manager) | 20 trades | 1,441,677 |
| reduceTrade (operator, shortfall path) | 20 trades, 3 pending | 1,486,191 |
| cancelOrder (resting limit) | 19 positions | 191,417 |
| cancelTimedOut | 20 positions | 188,975 |
| setSlTp (TP only) | 20 trades | 160,263 |
| flatten (all SOL trades of a mixed 20) | 6 SOL trades | 6,619,627 |
| **flatten, 20 trades on one pair, one call** | 20 ETH trades | **24,207,973 (76% of 32M)** |
| flatten, same 20 in batches of 7 | 7 / 7 / 6 | 8,865,370 / 9,097,650 / 8,083,004 (26,046,024 total) |
| decoy close request (LC-02) | | 1,406,722 |

## Headroom

- The heaviest NAV reader is 9.15M, 2.6% under the project's own 10M target (X3) and 3.5 times under the 32M limit.
- A single flatten of 20 trades on one pair fits (24.2M), with 7.8M headroom. That is about 1.21M per close request.
  Gains code is behind a 3-day / 14-day timelock, and a facet upgrade that makes `closeTradeMarket` about 33% more
  expensive would make the one-call flatten of 20 overflow. `maxTrades` batching (7 per call ≈ 9M) is the fallback,
  and it works (test_lc_gas_flattenBatches_7_7_6).
- MAX_POSITIONS never blocks an exit: at 19 trades + 3 pending exits (22 items, above the ceiling) close, reduce
  (collateral and leverage), cancelOrder and flatten all go out (test_lc_maxPositionsNeverBlocksExits).
