# Gains round 1, tools task 3: real gTrade trades replayed through a GainsVault (fork)

Internal review tooling, not an independent audit. Code: `contracts/src/gains/*` at audit/gains-r1 (9f39013).
Test: `contracts/test/audit/gains/replay/VaultReplayFork.t.sol` (20 tests: 19 replays + 1 diagnostic).

```
# Git Bash, contracts/, ARBITRUM_RPC_URL exported in the shell (archive RPC: forks at a tx hash)
FOUNDRY_OUT=out-replay FOUNDRY_CACHE_PATH=cache-replay forge test \
  --match-path 'test/audit/gains/replay/*' --match-test 'test_replay_|test_diag' -vv
# Ran 20 tests: 20 passed, 0 failed (build 108 s, run ~7 s wall once the RPC cache is warm)
```

## Method

Cases: the 19 recorded USDC exits on the gTrade v10 diamond `0xFF16…f169` of `test/gains/fork/GainsForkReplay.t.sol`
(Arbitrum One blocks 515,074,227 to 515,221,565): 7 market closes, 4 partial closes, 3 TP, 3 SL, 3 liquidations, on
BTC (0), ETH (1) and SOL (33), long and short, 5x to 111x. For each case:

1. Fork Arbitrum One **at the exit tx** (`vm.createSelectFork(rpc, txHash)`: the state just before it, same block, same
   OI / skew / funding / fee parameters as the real exit). ArbSys mocked to follow `vm.roll` from the tx's L2 block.
2. Deploy a fresh `GainsVaultFactory` + factory vault (real diamond, real USDC, real sequencer feed; Chainlink feeds
   mocked fresh), deposit `notional / 5 + 1,000` USDC, settle (operator).
3. Open the same pair / side / leverage **through `vault.openTrade`** with the real collateral (scaled up only where the
   policy needs it: collateral ≥ 5 × min fee, size ≥ pair minimum; scale `k` in the table). Chainlink is set to the
   real trade's open price for the policy check; the open is filled by the emulated Chainlink nodes at an oracle answer
   solved on two state snapshots so that **the vault trade's Gains open price equals the real trade's open price**
   (all 19 equal to ≤ 1e-10 relative). TP / SL cases then set the real trade's TP / SL through `vault.setSlTp`.
4. Apply the real exit through the vault: `closeTrade` / `reduceTrade` (real collateral delta × k) answered at the real
   aggregated oracle price; TP / SL / LIQ through a bot `triggerOrder` answered with **the real tx's oracle answer
   (current, open, high, low)**, recovered from the exit tx's call trace (`debug_traceTransaction`: the diamond's
   internal trigger callback carries the signed aggregated answer). Market fills aggregate node answers over several
   txs, so they are answered at the event's oracle price (the median).
5. Measure (all in 1e-6 USDC and in bp of the vault trade's notional):
   - **e1** vault USDC realized − independent Gains model (`NavCalc`, the spike model proven exact on real market closes)
     at the execution price; plus `balance delta == amountSentToTrader` of the vault's own Gains event (asserted).
   - **e3** vault payout − real trader payout × k; **e3adj** the same after re-basing the real payout off the real trade's
     history (its pending holding fees, total realized pnl incl. its opening fee, its fee-tier closing fee) and onto the
     vault's own; **e3g** gross value (collateral + pnl after impact) vault − real × k.
   - **e2** GainsNav continuity at band 0: `totalAssets` before − after the exit with `policy.navPrice` mocked to
     (execution price, band 0) = GainsNav's value of what was closed − what Gains paid. **e2raw** the same with the real
     band (Chainlink at the execution price): SPEC N4 (asserted ≤ 0 on every case).

## Results

| # | type | pair side | exit tx | lev | real coll | vault coll | notional | real paid × k | vault paid | e3 USDC | e3 bp | e3adj bp | e3g bp | e1 bp | e2 bp | e2raw bp |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 00 | PARTIAL | BTC long | 0x8d6d3bfd | 5.0x | 1.971356 | 62.864646 | 314.32 | 21.772973 | 26.145494 | 4.372521 | 139.109 | -57.150 | 0.001 | 0.000 | 2.864 | -5.476 |
| 01 | MARKET | BTC long | 0x25b12ead | 5.0x | 1.149890 | 62.864646 | 314.32 | 54.630229 | 63.067578 | 8.437349 | 268.429 | 0.001 | 0.001 | -0.000 | 0.000 | -20.027 |
| 02 | MARKET | ETH short | 0x5d1a1d12 | 34.0x | 8.000000 | 9.244903 | 314.33 | 8.188736 | 8.193754 | 0.005018 | 0.160 | 0.001 | 0.001 | 0.000 | 0.000 | -20.053 |
| 03 | MARKET | SOL long | 0x2e6b1370 | 15.5x | 150.000000 | 150.000000 | 2325.00 | 142.046556 | 141.983957 | -0.062599 | -0.269 | 0.028 | 0.028 | 0.000 | -0.000 | -24.939 |
| 04 | MARKET | ETH short | 0xbeda0cdd | 35.0x | 8.244918 | 8.244918 | 288.57 | 8.764497 | 8.759525 | -0.004972 | -0.172 | 0.001 | 0.001 | 0.000 | 0.000 | -19.950 |
| 05 | TP | ETH short | 0xe5a6b49f | 35.0x | 8.244918 | 8.244918 | 288.57 | 9.411744 | 9.406798 | -0.004946 | -0.171 | 0.000 | 0.001 | -0.001 | 0.001 | -19.904 |
| 06 | MARKET | SOL long | 0x7b174525 | 35.0x | 8.244918 | 8.244918 | 288.57 | 6.965531 | 6.956449 | -0.009082 | -0.315 | 0.003 | 0.003 | 0.000 | 0.000 | -24.913 |
| 07 | MARKET | ETH long | 0xa2d49e5e | 35.0x | 8.000000 | 8.981014 | 314.34 | 7.649234 | 7.657125 | 0.007891 | 0.251 | 0.001 | 0.001 | -0.000 | 0.000 | -19.930 |
| 08 | LIQ | SOL long | 0x0196926a | 111.0x | 2.220000 | 2.220000 | 246.42 | 0 | 0 | 0 | 0.000 | n/a | 0.003 | 0.000 | 0.000 | 0.000 |
| 09 | PARTIAL | BTC short | 0x4e23b67b | 99.5x | 1.900000 | 3.159180 | 314.34 | 0.924304 | 1.011401 | 0.087097 | 2.771 | -1.128 | 0.000 | 0.000 | 2.864 | -4.532 |
| 10 | SL | BTC short | 0x006547ff | 33.0x | 447.000000 | 447.000000 | 14751.00 | 430.366884 | 429.454680 | -0.912204 | -0.618 | 0.000 | 0.023 | -0.022 | 0.022 | -19.987 |
| 11 | SL | ETH short | 0xccdff72e | 50.0x | 5.000000 | 6.286795 | 314.34 | 3.697760 | 3.708516 | 0.010756 | 0.342 | -0.000 | 0.001 | -0.001 | 0.001 | -20.149 |
| 12 | PARTIAL | BTC long | 0x085cc59f | 5.0x | 1.977228 | 62.866101 | 314.33 | 26.528660 | 31.143712 | 4.615052 | 146.822 | -48.837 | -0.000 | 0.000 | 2.864 | -7.128 |
| 13 | SL | BTC long | 0x41000727 | 100.0x | 1.000000 | 3.143312 | 314.33 | 5.746131 | 6.183949 | 0.437818 | 13.929 | -0.000 | 0.000 | -0.001 | 0.001 | -20.207 |
| 14 | PARTIAL | BTC long | 0xb42c2f99 | 53.5x | 142.575000 | 142.575000 | 7627.76 | 125.468725 | 125.585411 | 0.116686 | 0.153 | -0.185 | 0.006 | -0.000 | 0.000 | -10.149 |
| 15 | TP | SOL long | 0x7bd2ed5f | 10.0x | 100.000000 | 100.000000 | 1000.00 | 136.362053 | 136.289853 | -0.072200 | -0.722 | -0.031 | -0.018 | -0.013 | 0.013 | -25.919 |
| 16 | LIQ | ETH long | 0x5d6b4813 | 50.0x | 40.000000 | 40.000000 | 2000.00 | 0 | 0 (survived, then liq.) | 0 | 0.000 | n/a | 0.007 | n/a | 0.000 | 0.000 |
| 17 | LIQ | BTC long | 0x7204d15f | 100.0x | 1.000000 | 3.143273 | 314.33 | 0 | 0 (survived, then liq.) | 0 | 0.000 | n/a | 0.000 | n/a | 0.000 | 0.000 |
| 18 | TP | BTC short | 0xb1c78c88 | 19.0x | 3000.000000 | 3000.000000 | 57000.00 | 4038.657248 | 4033.189293 | -5.467955 | -0.959 | 0.000 | 0.086 | -0.086 | 0.086 | -19.537 |

Full exit tx hashes are in the test (`c.push(Case(...))`); the real oracle answers in `ans.push(...)`.

### Maximum errors

- **Vault vs Gains' own accounting:** the vault's USDC delta equals the `amountSentToTrader` (or `TradeValueTransferred`)
  of its Gains event in all 19 cases, to the wei. Market closes and partials equal the independent model to ≤ 1e-6 USDC
  (partial 14: 15e-6 USDC = 0.00002 bp, per-step rounding of the model).
- **Vault vs the real trader (same prices, same block):** on every trade that executed with scale k = 1 or a small k,
  after removing the real trade's history, **max |e3adj| = 0.031 bp of notional** (case 15, 0.0031 USDC on 1,000
  notional); gross value **max |e3g| = 0.086 bp** (case 18). Where the trigger price path is identical the execution
  price is identical: case 18 vault 798,043.413002135 vs real 798,043.412567261 (5e-10 relative), case 10 824,361.146318
  vs 824,361.146313. The raw e3 (up to −0.96 bp on k = 1 trades) is the real trade's history, not a vault effect: e.g.
  case 18 the real short had received 4.47 USDC of holding/funding and paid a 2.5%-tier closing fee (19.45 vs the vault's
  19.95 USDC); case 10 it had received 0.91 USDC. Partials 00 / 12 (k ≈ 32) and 09 (k = 1.66) and liquidation 17
  (k = 3.1) were scaled up from sub-minimum collateral, so the min-basis fees and earlier realized pnl do not scale; their
  e3adj (−57, −49, −1.1, −13 bp) is that nonlinearity (e3g ≤ 0.001 bp shows the price path is the same).
- **GainsNav vs payout (SPEC N4):** with the real band, GainsNav of what was closed is below what Gains paid in all 19
  cases: e2raw from −4.5 bp (small partials) to −25.9 bp, ≈ −B on full closes (B = 20 bps BTC/ETH, 25 SOL). Never above.
- **GainsNav at band 0 vs payout:** market closes 0 to ±1e-6 USDC (exact). Partial closes +2.86 bp (+0.090 USDC each,
  see O-1). Triggers up to **+0.086 bp** (case 18, +0.49 USDC on 57,000 notional; see O-2), always absorbed by the band.
- **Liquidations (SPEC N3):** 08 liquidated at the real answer, 0 paid, NAV 0 before. 16 and 17: under the real answer
  the vault's trade **survived** (`TriggerOrderCanceled` NOT_HIT): the real trades had accrued holding fees (0.21 and
  0.0003 USDC) that moved their liquidation price above the answer's low (vault liq 23,330.4165 vs answer low
  23,332.102; vault 798,612.93 vs low 799,262.31); GainsNav already valued the surviving trade at 0 with the band (price
  within B of liquidation) and 8.51 / 1.20 USDC at band 0. Continuing the path 0.1 bp past the vault's own liquidation
  price liquidated it: 0 paid, `totalAssets` before = idle exactly (trade worth 0), asserted in `_liqContinue`.

## Observations (no new finding)

- **O-1 (known, GOV-01 cost):** every partial close costs ~0.09 USDC more than GainsNav's whole-trade valuation (the
  close fee on `max(delta size, pairMinPositionSizeUsd)` plus the minimum-basis rounding): e2 = +0.090011 / +0.090014 /
  +0.090014 USDC on cases 00, 09, 12 (sizes under ~286 USD), 3e-5 USDC on 14 (delta size 3,814 USD). GainsNav values a full
  close, which is the right NAV; the per-partial cost is what GOV-01 (operator / agent grinding reduces into fees)
  exploits. Rediscovered, not re-reported.
- **O-2 (Info, inside the band):** Gains executes TP / SL closes at a price that can differ from its market-close price
  for the same answer by a skew-impact term: case 18 the vault's trigger filled at current × (1 + 5.868e-5) while the
  market-close model (which GainsNav implements, and which matches every market close to the wei) gives current ×
  (1 + 4.987e-5); the vault's own `LimitExecuted.priceImpact` reports the model's components (skew −0.0000126%), yet the
  fill price matches the real trader's (whose event reports skew +0.000868%). Net: a triggered close paid up to 0.086 bp
  of notional less than GainsNav's band-0 value (cases 10: 0.022 bp, 15: 0.013 bp, 05 / 11 / 13: ≤ 0.001 bp). Bounded
  far below B (≥ 19.5 bp margin on every case), so N4 holds; root cause inside the Gains trigger callback not isolated.
  Open question for Gains, not a vault defect.
- **O-3 (harness):** a synthetic trigger answer whose range only touches the SL at its edge (low = SL, or open = current
  = high = low = SL) is NOT_HIT on the real diamond (`test_diag_shortSl_10`, modes 1 / 2, cancel reason 11); a range
  strictly containing it executes (mode 3). Fork tests that trigger TP / SL must answer with a range strictly past the
  trigger, or with the real recorded answer as here. (Earlier harness runs that used synthetic edge ranges showed the
  vault's SL "not executing"; that was this artifact, not a vault issue.)
- The vault's Gains fee tier is none (closing fee = untiered raw fee in all cases), as GainsNav assumes (PLAN.md 4.3);
  real traders with a tier pay up to 2.5% less fee (case 18), a cost of trading through the vault, not a NAV error.

## Checked and sound (by this replay)

- E1 units / encoding end to end on the real diamond: vault `openTrade` (1e10 price, 1e3 leverage and slippage,
  collateral index 3) produced the requested trade exactly (open price, leverage, collateral); `closeTrade`,
  `reduceTrade` (1e6 collateral delta), `setSlTp` (1e10 SL / TP) executed as the real trader's calls did.
- The vault receives exactly what Gains reports it sent (19/19), and as the trader it is treated identically to the
  real EOA trader at the same state and prices (execution prices equal to ≤ 5e-10; payouts equal to ≤ 0.031 bp after
  history; fee-tier and holding-history differences explained to the micro-USDC).
- GainsNav (SPEC N2) equals Gains' market-close payout at band 0 (e2 = 0 ± 1e-6 USDC on 7 market closes), never exceeds
  any real exit's payout with the band (N4, 19/19), and values a trade at its liquidation price at 0 (N3, cases 08, 16,
  17).
- Allowances (T4) are not asserted here; see the integration task.

Known findings touched: GOV-01 (O-1, rediscovered as the partial-close min-basis cost). No NAV-xx / LC-xx divergence
reproduced; nothing above 1 bp unexplained.
