# Round 2, domain ECON (3.6): multi-epoch economics

**Internal, AI-assisted review. Not an independent audit.**

Question: can any actor (depositor, redeemer, the manager through a non-insider confederate, owner, fee recipient,
the operator or any settler choosing the settle moment) move value from other depositors over many epochs, other than
the band spread the design charges flows, and fees within their caps?

Bottom line: no actor can extract value with the deposit/redeem timing games of round 1 (GR1-02, GR1-15): every such
strategy loses money to the holders who stay, by 0.2-1 % of its capital per round trip. The vault matches an independent
model of the spec to the wei over 450+ sequences of 60+ epochs. Three ways remain to move value. The settler decides
when an epoch settles, and the manager decides what is open at that moment, so these two choices can still move value:

| ID | Title | Severity |
|---|---|---|
| GR2-ECON-03 | A leverage-breach settle mints deposits (and pays redemptions) without crystallising the performance fee: new depositors pay the fee on gains made before they entered | Medium |
| GR2-ECON-02 | Loss-breach and exit-only settles pay min(NAV, checkpoint) at a moment the settler picks: the checkpoint can be fixed at a dip and nobody can raise it for an hour | Medium (design) |
| GR2-ECON-01 | The manager can manufacture the bid / ask band with a delta-neutral book opened only for a settle | Low (design) |

## 1. What was built

All code is under `contracts/test/audit/gains/r2/`:

| File | What |
|---|---|
| `econ/model.py` | **Spec model.** An independent re-implementation of the vault's accounting from SPEC.md sections 2-4 and 8, in exact integers: requests, insider deferral, one request per controller, claims, carry runs (`carriedFrom` / `carryPricedIn`), the three settle modes, partial fill + return, the 1 h age rule, ERC-4626 conversions with the virtual offset, management and performance fees with HWM and the scheduled raise, the checkpoint rule (`nextCheckpoint`), and `checkRisk` with its breach state machine (leverage, daily loss, drawdown, resume, clear, emergency). It predicts every revert the sequence provokes. The venue is the mock diamond's economics, re-implemented: Gains' close formula without impact, the opening fee booked as realized, liquidation at -90 %, and the band edges of GainsNav. |
| `econ/fair.py` | **Fair-value transfer ledger** (section 2). |
| `econ/scenario.py`, `econ/strategies.py` | **Generator.** A seeded generator (two PRNG streams: the price path and the behaviour) for an honest background: 3 victims deposit, redeem, cancel and claim at random; the manager trades BTC / ETH at random leverage targets of 0-4.5x with 2-25x trades; the true price follows a random walk (60 bp per sub-step, 4 sub-steps an epoch, 1-4 h each); there are crashes into loss breaches. On top of it runs one of 22 adversarial strategies. Every event is applied to both ledgers and recorded with its expected result. |
| `econ/econ.py` | Entry point. `show` prints one run. `ffi` prints the ABI-encoded sequence and expectations for Foundry. `table` produces the strategy table (`audit/gains/r2/econ/table.json`). |
| `EconBase.t.sol`, `EconDiff.t.sol` | **Differential test.** It replays the model's sequence on the real `GainsVault` clone and `MockGainsDiamond`. The Chainlink price and the true (oracle fill) price are set separately. It asserts, to the wei: every expected revert and its selector; every settle's minted shares, burned shares, paid USDC and NAV after; a state digest after every settle (totalSupply, vault USDC, totalAssets, HWM, checkpoint); and every actor's final USDC. Needs ffi and Python, so it is skipped unless `ECON_FFI=true`. |
| `EconPoC.t.sol` | Deterministic PoCs of the three findings. They need no ffi and pass today. |

Configuration used everywhere unless a row says otherwise:
- Policy: live shape, 5x leverage, 15 % daily loss, 50 % drawdown, 1 day epochs, 20 % NAV move, 1 % slippage.
- maxOrderNotional: 10M instead of 250k, so 1M vaults can trade.
- Band: 20 bp on BTC and ETH.
- Gains fees: 0, except the rows marked 3.6 bp per side, which is about what the fork tests measured round trip on ETH.
- Vault fees: 0 / 0 for the pricing strategies, so fees cannot blur the transfers; 2 % / 20 % for the fee strategies.
- Standalone vault (no protocol share: the protocol share only splits fee shares, so a depositor's cost is the same).

### Differential results (model vs vault)

| Run | Sequences | Result |
|---|---|---|
| Pass 1: 22 strategies x {10k, 100k, 1M} x seeds {1, 2, 3} | 198 (62-64 settles, 1,130-1,740 events each) | 196 exact. **2 mismatches**, both bugs in the model, found by the differential: a reverted `clearLeverageBreach` / `requestDeposit` kept the model's side effects (the escalation to DRAWDOWN, an auto-claim), where the chain rolls them back. After the fix both replay exactly. |
| Pass 2: 22 strategies x 3 sizes x seeds {2, 4, 5, 6, 7} | 330 | 330 exact on every event. One run (overdue_control, 1M, seed 5) settled only 34 epochs: a generator bug that never re-ran `checkRisk` after `StaleCheckpoint`. It was fixed; the run then has 62 settles and replays exactly. |
| `testFuzz_ECON_diff_allStrategies`, 256 runs | strategy, seed and size (1k .. 10M) drawn by the fuzzer | **256 / 256 exact** after two generator fixes: a 10M victim's wallet was overdrawn by its own deposits, and the same `StaleCheckpoint` loop. Neither was a vault mismatch. |

**Maximum divergence observed between the model and the vault: 0 wei** (every passing replay is exact on every check).
Because the spec model is exact, the economics below come from the model, run on runs the differential validated.

## 2. Definition of fair, and how the band is treated

**Fair share value** at any instant = mid NAV / supply. The mid NAV is the vault's own idle USDC plus every open trade
valued at the **true price** (what Gains' oracle fills at) through Gains' close path: collateral + pnl − closing fee −
holding fees + realized pnl. There is no band. Pending collateral counts as GainsNav counts it. The vault's virtual
offset is kept (+1 asset, +1e6 shares), so a share means the same thing in both. Gains' fees are real costs, so they
are in the fair value; the band is not.

Each actor's economic position = (wallet shares + shares escrowed for redemption + settled shares not yet claimed) × fair
share value, + claimable USDC, + queued deposit USDC at face value. Between settles a position changes only through the
market (pro rata, no transfer) or the actor's own value-preserving wallet moves (request, cancel, claim). So value can
move **between** actors only:

- at a settle, when a flow is priced away from the fair value, or through refunds and partial fills;
- at a fee mint.

`fair.py` books, per actor:
- `flow`: the value change across every settle (pricing transfers);
- `fee`: the value change across fee mints;
- `perf_over`: the performance fee the actor bore, minus what a per-lot (equalisation) charge on its own gain would be.

`Σ flow` over all actors is what nobody owns: rounding and the virtual offset.

**The band.** Two-sided pricing (GR1-02 fix) makes every deposit priced while trades are open pay about B × (vault
leverage) × its size above fair, and every redemption take the same below fair. That transfer goes to the holders who
stay, and FIXES-R1 section 6 documents it. **It is designed, so it is not counted as extraction when it comes from
ordinary flows.** It shows as the "passive holder" row below: ~0.9 % of victim capital over 60 epochs, paid by the
victims' own random flows to whoever stays. A strategy **extracts** when it ends with positive `flow` (or a fee
recipient's `fee`) beyond that passive baseline. Every row also shows the difference against a control run on the
same seed: the same price path, the same honest behaviour draws, the strategy's adversarial actions removed.

**Acceptable rounding.** Every conversion rounds toward the vault (floor on mint and pay, ceil on burned-for-me), so
an actor can lose at most 1 wei per conversion and never gain from rounding. Accepted bound: **≤ 1 wei per actor per
settle or claim**, i.e. ≤ 0.0002 USDC over a 60-epoch run (< 0.0002 bp of a 10k vault). Observed: `|Σ flow|` (value
nobody owns) ≤ **0.000031 USDC** per 60-epoch run in every sequence, except where a full exit left a real residual
(section 4, `full_exit`).

## 3. Strategy table

12 seeds x 3 vault sizes, 60 epochs (62-64 settles) each. "Attacker" = the confederate (non-insider) address(es),
capital = victim capital unless stated. Positive = gained from others. bp = of victim capital (the vault size). "Max /
settle" = the largest single-settle gain. "Δ vs control" = mean difference of the attacker's `flow` (or the fee
recipient's `fee`) against the control on the same seeds. Source: `audit/gains/r2/econ/table.json`.

| Strategy | Size | Attacker flow, mean (USDC) | Max over 12 seeds | Max / settle | Δ vs control | Extracts? |
|---|---|---|---|---|---|---|
| Passive holder (baseline: designed band from victims' flows) | 10k / 100k / 1M | +90 / +910 / +9,227 | +165 bp / +166 bp / +209 bp | 16.5 bp | n/a | designed |
| GR1-02 residual: in while open (manager at 4.75x), out when flat | 10k / 100k / 1M | −1,097 / −10,974 / −107,862 | −761 bp | 0 | −1,187 / −11,884 / −117,089 | **no** (loses ~0.4 %/cycle) |
| In when flat, out while open | 10k / 100k / 1M | −715 / −7,152 / −83,868 | −190 bp | 0 | −805 / −8,061 / −93,096 | no |
| Manufactured spread (GR2-ECON-01): book at every settle with flows, Gains fee 0 | 10k / 100k / 1M | +246 / +2,460 / +24,602 | +300 bp | 16.5 bp | (control = no book: 0) | **yes**, see ECON-01 |
| … same, Gains fee 3.6 bp/side (book only when profitable) | all | 0 | 0 | 0 | | no: the honest flows are too small |
| … large victim flows (one = vault size every 5 epochs), fee 0 | 10k / 100k / 1M | +537 / +5,370 / +24,190 | +724 bp / +724 bp / +506 bp | 52.5 bp | | **yes** |
| … large victim flows, fee 3.6 bp | 10k / 100k / 1M | +101 / +1,011 / +3,518 | +260 bp / +260 bp / +80 bp | 51.8 bp | | **yes**, small |
| Chainlink lag 5 bp: deposit / redeem / last-moment cancel option | 10k / 100k / 1M | −1,470 / −14,756 / −155,867 | −803 bp | 0 | −1,560 / −15,666 / −165,094 | no |
| Chainlink lag 50 bp (fast market) | 10k / 100k / 1M | −1,586 / −16,230 / −162,057 | −609 bp | 145 bp | −1,673 / −16,938 / −170,679 | no in total (single settles can win when lag > band) |
| Split requests over 4 addresses, 5 epochs | 10k / 100k / 1M | −10 / −138 / −298 | +28 bp | 14.6 bp | −100 / −1,048 / −9,525 | no |
| Carried deposits as a free option | 10k / 100k / 1M | −427 / −4,644 / −41,502 | −86 bp | 18.5 bp | −485 / −5,125 / −47,344 | no |
| Management fee accrual timing (fee recipient calls accrueFees at NAV highs) | 10k / 100k / 1M | fee recipient +6.64 / +60.48 / +620.51 total | | | fee: +0.001 / −0.015 / +0.007 | **no** (≤ 0.02 USDC) |
| Performance fee at transient highs (manager settles at the first high of the epoch) | 10k / 100k / 1M | | | | fee: −41 / +2,593 / −250 (mean, mixed sign) | no systematic gain (per-share HWM; section 4) |
| Overdue exit-only settle at the checkpoint (owner; confederate stays) | 10k / 100k / 1M | +159 / +1,106 / +12,453 | +306 bp / +268 bp / +284 bp | 107 bp / 69 bp / 64 bp | +64 / +209 / +4,506 | **yes**, see ECON-02 |
| Leverage-breach settle (manager induces, perf 20 %) | 10k / 100k / 1M | victims' per-lot perf overcharge +378 / +2,586 / +5,639 | | | see ECON-03 PoC | **yes** (fee recipient), see ECON-03 |
| Insider deferral edges (manager deposits for the confederate; fee recipient changed to the confederate) | 10k / 100k / 1M | +40 / +333 / +3,802 | +88 bp | 11.7 bp | −45 / −483 / −4,761 | no |
| Dust: 10 USDC requests, 1-unit redemptions, 1 wei donation (3 addresses) | 10k / 100k / 1M | +6.9 / +10.4 / +10.7 | +14 bp at 10k | 3 USDC | n/a: the passive band on ~600 USDC | no (rounding ≤ 1 wei/op) |
| First depositor after a full exit | 10k / 100k / 1M | +66 / +611 / +5,895 | | | −23 / −298 / −3,332 | no (section 4) |
| Emergency partial fills: attacker first in line | 10k / 100k / 1M | −27 / −295 / −2,783 | +18 bp | 8.1 bp | −158 / −1,445 / −13,924 vs staying | no |
| Scheduled fee raise (2/20 → 5/30) executed during a leverage breach | 10k / 100k / 1M | | | | | applied at the next normal settle as specified (R3-06); old gains charged at the old rate |

How to read the extracting rows:
- **Manufactured spread.** With the Gains fee at 0 the confederate gains +300 bp of victim capital over 60 epochs. With
  real fees the book pays only on large flows: +260 bp max at 10k / 100k, 80 bp at 1M.
- **Overdue owner.** Up to +306 bp total, 107 bp in one settle at 10k.
- **Leverage breach.** The PoC shows 1.44 % of a 100k deposit.

## 4. Findings

### GR2-ECON-03: a leverage-breach settle mints deposits without crystallising the performance fee (Medium)

**Location.** GainsVaultLogic.sol:250 `_accrueFees($, !$.breached && !$.emergency, venue)`. Line 230 makes a LEVERAGE breach
a normal settle: deposits minted, redemptions paid at the live NAV. Line 256 has the same condition for the
scheduled raise.

**Description.** A normal settle normally crystallises the performance fee before it prices flows, so a deposit is
always minted at a price ≤ HWM. A settle in a **leverage** breach still mints deposits and pays redemptions, but it
charges no performance fee and keeps the HWM. A deposit settled there buys in above the HWM. The next normal settle then
charges perf × (price − HWM) on **all** shares, the new ones included: the new depositor pays the fee on gains made
before they entered. Redeemers in the same settle leave without paying the fee on their gains (fee recipient loses
that part).

The manager can create the breach at will in the keeper's normal flow. An open that passes `checkOrder` at exactly
maxLeverage is valued at the adverse edge right after the fill, so NAV falls by B × the new notional (plus Gains'
opening and closing fee) and vault leverage ends above the limit. The keeper's `checkRisk` before the settle then sets
LEVERAGE. A price move against the book does the same thing naturally.

**PoC.** `EconPoC.t.sol::test_GR2_ECON_03_leverageBreachSettleChargesNewDepositorForOldGains` (passes):
- Setup: perf 20 %, mgmt 0. Alice holds 100k. A 3x ETH long gains 3 %, so the share price is 1.0792 against an HWM of
  1.0. Bob queues 100k. The manager opens to 5x, and the open's own cost puts leverage over the limit.
- With the breach: bob ends with **97,755.27** USDC, the fee recipient with **3,631.99**.
- Control (same state, settle without the breach): bob ends with **99,193.46**, the fee recipient with **2,212.59**.
- Bob loses **1,438.2 USDC (1.44 %)** and the fee recipient gains **1,419.4**. Alice is unchanged (107,612.7 vs 107,593.9).

**Impact × likelihood.** The new depositor loses perf × (uncrystallised gain since the last normal settle) of the
deposit:
- 20 % × a 7.9 % gain = 1.44 % here;
- on a 1M deposit after a 5 % day, 10k USDC.

The money goes to the fee recipient, which on the live vault is the owner and the manager. It is a fee above the
configured cap for that depositor: they pay 20 % of a gain they did not have. Likelihood is medium: it needs gains since
the last settle (common), deposits queued, and leverage over the limit at the settle (manager-made at will, or market-made).
The model's per-lot comparison agrees: the victims' per-lot overcharge averages **+2,586 USDC per 100k** of victim
capital over 60 epochs with the induced breaches (table row).

**Fix.** Crystallise the performance fee in every settle that prices deposits or pays redemptions at the live NAV. A
leverage breach says nothing about the NAV, so it should not suppress the fee: use `withPerformance = !$.emergency &&
!_lossBreach($)`, and apply the scheduled raise with the same rule. Alternatively, carry the deposit queue (like a loss
breach) whenever the fee cannot be crystallised.

### GR2-ECON-02: loss-breach and exit-only settles pay min(NAV, checkpoint) at a moment the settler picks (Medium, design)

**Location.**
- GainsVaultLogic.sol:264-272: exit-only uses `min(nav, checkpointNav)`; redemption-only uses `min(nav, checkpoint before the
  ratchet)`.
- GainsVaultPolicy.nextCheckpoint: `checkRisk` moves the checkpoint at most once per CHECKPOINT_INTERVAL (1 h).
- GainsVaultLogic.sol:224-232: who may settle which mode.

**Description.** SPEC S4 and S5 price these redemptions at min(NAV, checkpoint) on purpose: a NAV pushed up inside the
bound is never paid out in a loss breach (REAUDIT3 a). The economic effect is an option for whoever settles:
1. A crash fixes the checkpoint at the dip. Any `checkRisk` after the crash does it, including the keeper's own
   (anyone may call it).
2. After that, nobody can raise the checkpoint for an hour.
3. A redemption-only settle any time within that hour pays every queued redemption at the dip, however far the NAV has
   recovered (up to maxNavMove, 20 %).

The redemption-only settle can be sent by the manager, operator, owner, guardian or sentinel, with no age requirement.
The exit-only settle can be sent by the owner (also the manager on the live vault) once the epoch is overdue, or by
anyone allowed in an emergency. Its exit-only price has no NavMoved bound, so the gap is limited only by how stale the
checkpoint is. The redeemers lose the gap, and the holders who stay (a confederate, the insiders) keep it. A redeemer's
only defence is to cancel before the settle, then call `checkRisk` an hour later.

**PoC.**
- `test_GR2_ECON_02_redemptionOnlySettlePaysTheDipNotTheRebound` (passes):
  - 200k vault at 4.9x ETH long. ETH −3.5 % → NAV −17 %, a daily loss breach, checkpoint 163,808. Bob redeems
    everything.
  - ETH rebounds to −0.5 % within 30 min (NAV 193,149).
  - Settled at once: bob is paid **81,904.30** USDC. Settled an hour later after anyone's `checkRisk`: **96,574.90**.
  - Bob loses **14,670.6 USDC (15.2 %)**, and alice keeps it.
- `test_GR2_ECON_02_overdueExitOnlySettleByOwnerPaysTheDip` (passes):
  - The epoch runs overdue. The owner calls `checkRisk` at a −2.5 % ETH dip (4x), then settles exit-only after the
    rebound.
  - Bob's half is paid **44,610** against **49,600** from the treasury's normal settle at the same moment (**−10.1 %**).
- Model, `overdue_owner` row: the confederate stayer gains up to **+306 bp** of victim capital over 60 epochs, and up
  to **107 bp in one settle**, mean Δ against a normal-settle control +209 USDC per 100k and +4,506 per 1M.

**Impact × likelihood.** A bounded loss to redeemers: ≤ maxNavMove of the redemption in a loss breach, unbounded by
the bound in exit-only. It moves to the stayers. It needs a loss breach (or an overdue epoch / emergency) plus a rebound
within the hour, and a settler who times it: a hostile manager or owner with a confederate holder, or simply a keeper
that settles right away after its own `checkRisk`. Medium. Severity is not High because this is the specified
conservative rule; the finding is that its timing is discretionary and large.

**Fix (design options).**
- Price redemption-only and exit-only settles at the checkpoint only when it is younger than CHECKPOINT_INTERVAL **and**
  the NAV is above it, i.e. let anyone ratchet the checkpoint immediately upward to the live NAV when a breach is set.
- Or price at min(NAV, a TWAP of checkpoints).
- Or refuse a redemption-only settle within CHECKPOINT_INTERVAL of the checkpoint that set the breach, so the next
  `checkRisk` can reflect a rebound.
- At minimum, document for depositors that a redemption queued in a breach can be paid at the dip, and that cancelling
  is the defence.

### GR2-ECON-01: the manager can manufacture the bid / ask band (Low, design)

**Location.**
- GainsVaultLogic.sol:280: deposits mint at `max(nav, idle + valueHigh)`.
- GainsVaultLogic.sol:278: redemptions are paid at the adverse NAV.
- GainsVaultPolicy.checkOrder: a delta-neutral book counts as leverage, and nothing more.

**Description.** Two-sided pricing charges every flow B × vault leverage. The manager chooses vault leverage at the
settle moment and does not need market exposure to do it: an equal ETH long and short open only around the settle gives
4.9x of band on the queued flows and nothing else. The flows pay the band to the holders. The book costs the holders
Gains' fees, 2 × fee per side × notional.

**PoC.**
- `test_GR2_ECON_01_hedgedBookAtSettleChargesDepositorTheBand`: Gains fee 0. Bob's 100k deposit ends at **99,512.39**
  and alice ends at **100,487.61**, a 487.6 USDC transfer with no price move.
- `test_GR2_ECON_01_hedgedBookAtSettleUnderpaysRedeemer`: carol redeems 100k of value and is paid **99,020.00**
  (−0.98 %).
- `test_GR2_ECON_01_hedgedBookPaysAfterGainsFeesOnALargeFlow`: fee 3.6 bp per side, a 200k flow into a 100k vault.
  Bob ends at **199,348.03** (−652) and alice at **100,299.17** (+299 net of the book's fees).
- Model (table): with fees at 0, +246 / +2,460 / +24,602 USDC to the confederate over 60 epochs (≤ 300 bp of victim
  capital, ≤ 16.5 bp per settle); with large victim flows up to +724 bp.
- With 3.6 bp fees it pays only on flows ≥ ~56 % of NAV. Then: +1,011 USDC mean per 100k, max 260 bp, and up to 52 bp
  of victim capital in one settle.

**Impact × likelihood.**
- Per flow, the loss is ≤ B × maxLeverage, which the NAV bound keeps ≤ maxNavMove / 8 (1 % at live parameters, at most
  2.5 %). That is no more than the documented worst case of a flow while trades are open.
- The novelty is that the manager can impose it on purpose, without market risk, and route it to a confederate
  holder. The performance fee also charges 20 % of the band income, because it raises the adverse-edge share price.
- With real Gains fees most of the victim's loss goes to Gains, not the attacker.

Low.

**Fix (options).** Cap the band charged to flows by the vault's net directional exposure: value both legs of a pair
at one edge for the purpose of `valueHigh`, i.e. net longs against shorts per pair. Alternatively, accept and
document it: the manager can impose up to B × maxLeverage on any flow.

### Checked and not extracting (with the row or test that shows it)

- **GR1-02 residual** (in while open, out when flat): the confederate loses 0.4 % per cycle, so the fix holds over 60
  epochs at every size. Row "GR1-02 residual"; `R1NavBias.*` (round 1).
- **Chainlink lag (GR1-15).** At 5 bp of lag every last-moment option loses, −803 bp to −1,028 bp of capital. At 50 bp
  (fast markets) single settles can win, up to 145 bp in one settle, but the round trips' band costs more: negative in
  total on all 36 seeds × sizes. Residual risk: a lag larger than the band sustained over a whole in/out cycle (open
  question T3, round 1).
- **Split requests and carried deposits** gain nothing beyond the passive baseline. Pro rata pricing is exact, and a
  carried deposit is priced at the settle that ends the run.
- **Management fee timing**: within 0.02 USDC of the control at 1M. Settles accrue daily, and the fee is linear in time.
- **Performance fee timing**: the per-share HWM charges transient highs (standard), with mixed sign against the control.
  The per-lot comparison shows the usual per-share effects in both directions: holders who entered below the HWM ride
  free, and the band release after a deposit is charged on the new shares. Both are below 0.1 % of capital except the
  ECON-03 path.
- **Insider deferral**: a deposit by the manager for another controller is deferred one epoch. After a fee recipient
  change the new recipient's deposits are deferred and the old one's are not. Differential exact; no gain.
- **Emergency partial fill + return**: being first in line in an emergency is worth ≤ 18 bp, against −158 / −1,445 /
  −13,924 versus staying. Returned shares are re-priced like a stayer's. 9-10 partial fills over the 12 seeds per size,
  all exact.
- **Dust and rounding**: 10 USDC requests and 1-unit redemptions every epoch. Value nobody owns ≤ 0.000031 USDC per
  run; no actor gains from rounding.
- **First depositor after a full exit** (GR1-39 class): when every holder leaves in a redemption-only or exit-only settle
  priced at the checkpoint, the gap stays in the vault. The claim-rounding dust shares (6-14 units) keep the supply
  above 0, so the "first mint at par" gift does not apply. The virtual offset holds the residual, and the residual is
  released pro rata to later holders as the supply grows. Example (seed 7, 1M):
  - the full exit left 522 USDC against 7 share units;
  - the next 62,619 USDC deposit was minted 1.196e8 units, at ≈ 1 USDC per 1.9e3 units;
  - after the final full exit 313.46 USDC stayed in the vault.

  Nobody can capture the residual quickly, so this is not an extraction. It is the redeemers' loss from ECON-02,
  stranded (Info).

## 5. Assumptions (conservative readings)

- **Gains' close costs**: the mock (no spread or impact, opening fee booked as realized, liquidation at −90 %). Fork-level
  impact and holding fees are not modelled: they are real costs to all holders pro rata and move no value between
  holders, except through ECON-01's book, where they make the attack more expensive.
- **Holding fees** are 0. A manufactured book held across settles would pay them, which also makes ECON-01 more
  expensive.
- **"Fair"** values trades at the true (oracle) price. With lag 0 that is Chainlink. A strategy that only gains from the
  band paid by honest flows is counted as designed (passive baseline), not as extraction.
- **Live roles**: owner = manager = fee recipient. The harness uses distinct addresses. ECON-02 and ECON-03 are stronger
  when they are one address, because the beneficiary is then the settler.

## 6. Reproduce

```bash
cd contracts
python -I test/audit/gains/r2/econ/econ.py show levbreach_perf 1 100000      # one run, per-actor transfers
python -I test/audit/gains/r2/econ/econ.py table 1 13 10000,100000,1000000 out.json
forge test --match-path test/audit/gains/r2/EconPoC.t.sol -vv                # PoCs, no ffi
ECON_FFI=true ECON_STRATEGY=passive ECON_SEED=1 ECON_SIZE=100000 \
  forge test --ffi --match-path test/audit/gains/r2/EconDiff.t.sol --match-test diff_one -vv
ECON_FFI=true forge test --ffi --match-path test/audit/gains/r2/EconDiff.t.sol --match-test testFuzz --fuzz-runs 256
```

The PoCs and the differential were run in a scratch copy of the tree, with no forge lock: the worktree's sources
copied, and a test directory holding only the harness and these files. The files committed here are byte-identical.
Raw logs: `audit/gains/r2/econ/diff-pass1.log`, `diff-pass2.log`, `fuzz.log`.
