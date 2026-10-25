# hl-r2: multi-epoch economics at scale (domain 3.7)

Internal, AI-assisted review (sub-reviewer "econ"), 2026-10-19. This is not an independent audit. Code: `contracts/src`
(not `gains/`) as deployed in round 4 (last src commit 2305cf2), worktree branch `audit/hl-r2-econ`.

Deliverables:
- Findings with PoCs: `contracts/test/audit/hl-r2/econ/EconPoC.t.sol`, `EconLate.t.sol`, `Liveness.t.sol`.
- Independent model: `contracts/audit/hl-r2/econ/model/model.py` (fair-value model), `diff.py` (replay + compare).
- Differential driver: `contracts/test/audit/hl-r2/econ/Differential.t.sol`.
- Results: `contracts/audit/hl-r2/econ/results/` (summary JSON per campaign).
- Liveness: `contracts/audit/hl-r2/LIVENESS.md`.

Assumptions (conservative readings, written down as CONTEXT.md asks):
1. The vault owner is untrusted (open launch: any launcher owns its vault). The manager may hold shares through
   sybils (N-09). The operator and sentinel are platform online keys; the guardian is a cold EOA that acts by hand.
2. The keeper sends `checkRisk` only "when needed" (a limit is near or hit, or the operator's checkpoint refresh before
   a settle) and none in a full stop (`risk/contractRisk.ts:253-254`), so the NAV checkpoint is usually as old as the
   last settle or the last needed check.
3. Hyperliquid precompiles are trusted for values; their availability and Core -> EVM landing times are not.
4. "Fair" (the model) = holders own NAV pro rata; deposits buy and redemptions sell at the price the documented mode
   names; fees take exactly what the fee formula says. The documented min(NAV, checkpoint) rule is applied by the model
   too (so a divergence measures the code against its own documentation, and the findings below measure the
   documentation against fairness).

## 1. Findings

| ID | Title | Severity | Location | PoC |
|---|---|---|---|---|
| HLR2-E01 | Exit-only (emergency / overdue) settles pay redemptions at min(NAV, checkpoint) with no bound on the checkpoint's age: the settle caller, or an owner who opens the emergency at will, moves the gain since the last checkpoint from the redeemers to the holders who stay (fee recipient, sybils, or the next first depositor when supply hits 0) | Medium | VaultLogic.sol:242-244 (exit-only), 245-249 (redemption-only), VaultGovernance.sol:244-254 | `test_HLR2_E01a..e` |
| HLR2-E06 | A guardian-class full stop (`triggerBreach`) blocks every settle, every mode, every role, for up to `maxEpochDuration` (7 d; the owner can make it 30 d); the vault owner can cause it at will | Medium | VaultLogic.sol:210, VaultGovernance.sol:227-232, 244-246 | `test_HLR2_E06_*`, `test_HLR2_E06b_*` |
| HLR2-E02 | `settle()` trusts the stored breach flag: a drop past `maxDailyLossBps` (inside `maxNavMoveBps`) that no `checkRisk` has seen is settled in normal mode, minting deposits at the dropped NAV; the deflation bound of the C-01 residual is `maxNavMoveBps` per settle, not `maxDailyLossBps` per day as documented (R-1) | Low | VaultLogic.sol:205-216; HyperVault.sol:157-160; KNOWN-ISSUES I3-01 / REAUDIT R-1 | `test_HLR2_E02_settleMintsInsideDailyLossTerritory` |
| HLR2-E03 | Performance fee crystallises at a settle-time spike up to `maxNavMoveBps` above the checkpoint (M-05 residual); a +19% one-block mark moves 3.2% of the vault to the fee recipient and pins the HWM | Low | VaultLogic.sol:228, 336-372 | `test_HLR2_E03_perfFeeOnSpikeAtSettle` |
| HLR2-E07 | A Core -> EVM transfer later than 300 blocks is priced as a loss; the redemption-only settle the operator runs automatically in the resulting breach pays redeemers at the phantom-loss NAV (documented R3-08 trade-off, consequence quantified) | Low | VaultMath.sol:126-148, VaultTypes.sol:291 | `test_HLR2_E07_lateLandingPaysRedeemersAtPhantomLoss` |
| HLR2-E04 | Settle timing for a sybil deposit at an honest trough (N-09 quantified, no breach): 4.9% below the mean | Info (known) | VaultLogic.sol:257 | `test_HLR2_E04_sybilDepositPricedAtChosenTrough` |
| HLR2-E05 | A factory seed is NAV without shares; the first epoch's depositors receive it (first mint rule) | Info | VaultMath.sol:188-191 | `test_HLR2_E05_firstDepositorsReceiveTheSeed` |
| HLR2-E08 | Price quantisation: `sharePrice()` is 1 wei per whole share, so the performance fee and the HWM carry up to ~1 wei per share per charge (<= 3e-7 of NAV at a 1 USDC price); measured mean bias is toward depositors | Info | VaultMath.sol:198-200, VaultLogic.sol:344-347 | differential (section 3) |
| HLR2-E09 | Dust supply with NAV left (after E01-style exits or a near-total loss): the virtual offset and the dust units keep a fixed slice of the NAV for good and share units become coarse (one unit can be worth cents) | Info | VaultMath.sol:188-196 | differential seed 1078 (section 3) |
| HLR2-L01 | No automated or documented emergency unwind (the executor runs nothing in a full stop; no emergency runbook) | Low (Design) | server/src/treasury/epochPlan.ts:148-161 | LIVENESS.md row 7 |
| HLR2-L02 | Operator bounds on chain are weaker than the off-chain reduce bound (whole-position flatten in any breach, no leverage bound on bridgeToEvm) | Low | VaultLogic.sol:438-451, 562-580 | `test_HLR2_L07_*` |

No Critical or High. Nothing here is exploitable for meaningful value on the live vaults today (about 172 USDC in
total, CONTEXT.md); E01 and E06 apply to any future vault with outside depositors.

### HLR2-E01 (Medium): exit pricing at an unbounded-age checkpoint

**Where.** `VaultLogic.settle`: exit-only `priceNav = min(nav, checkpointNav)` (lines 242-244) with no age or bound
check (the `nextCheckpoint` rule is skipped for exit-only); redemption-only `priceNav = min(nav, cp_before)` (245-249).
`checkpointNav` moves only at a settle or at a `checkRisk` at least one hour after the last move, by at most
`maxNavMoveBps` per step. The keeper sends `checkRisk` only when needed and none in a full stop.

**What happens.** Any gain since the last checkpoint is withheld from every redeemer of an exit-only settle and given
to whoever keeps shares. The settle caller picks the moment; the vault owner can also pick the mode (`triggerEmergency`
is instant for the owner), and anyone can once the epoch is overdue.

| PoC | Setup | Fair payout | Paid | Who gains |
|---|---|---|---|---|
| E01a | 100k alice + 100k mallory (the owner's sybil), +30% real gain over 20 h, no checkRisk; owner opens the emergency, manager settles in the same block | 130,000 | 100,000 | mallory: 160k for 100k (+30k from alice) |
| E01b | same, no emergency: the manager does not settle for 7 days, the owner settles exit-only once overdue | 130,000 | 100,000 | the stayers |
| E01c | alice calls `checkRisk` herself first (the cap: +20% per hour) | 130,000 | 120,000 | the stayers |
| E01d | alice holds every share but ~6 USDC of management-fee shares | 130,000 | 99,995 | the fee recipient: ~6 USDC of fee shares now worth 30,004.56 |
| E01e | alice holds every share, fees off: supply returns to 0 with 30k of NAV left; the guardian exits the emergency and clears; a 10 USDC sybil deposit is the next first mint | 130,000 | 100,000 | the sybil: 10 USDC worth 30,009.997 |

Supply returning to 0 with NAV left (question in the brief): yes, reachable exactly this way (and only this way beyond
wei dust: a normal full exit leaves at most the virtual-share remainder, about 1 wei). If dust shares remain in the
vault (claim floors), the leftover is instead attributed to the dust and virtual shares and locked for good; with
supply exactly 0 the next epoch's depositors take it at the first-mint rule (1 USDC per share). Returned (unpaid)
shares of a partial fill keep supply > 0.

**Impact x likelihood.** Loss to redeemers = redeemed fraction x (NAV - checkpoint), the gain since the last checkpoint
(one day of PnL under the operator's daily settles; a whole epoch, up to `maxEpochDuration`, when nobody settles).
Bounded by the market, not by the policy: exit-only skips the `maxNavMoveBps` rule. Likelihood: needs a gain since
the checkpoint plus an exit-only settle; under open launch the owner choosing both is a launcher attacking its own
depositors through a sybil; honestly it happens whenever an emergency or overdue settle follows a good run. Example at
the platform vault scale (250k cap): 50% of supply redeeming after +10% since the last checkpoint loses 12.5k, all to the stayers.
REAUDIT3 recorded "Exit-only pays at min(nav, checkpoint), which raises the price for the holders who stay: never a
loss"; it is a loss for the redeemers, and the stayer can be the party choosing the moment.

**Fix (describe).** Price exits at `min(nav, cpEff)` where `cpEff` is the checkpoint walked toward the live NAV as if
`checkRisk` had run every `CHECKPOINT_INTERVAL` since `checkpointAt`: `cpEff = min(nav, cp * (1 + m)^k)` with
`k = (now - checkpointAt) / 1 h` (closed form or a capped loop), so only a move within the last hour (and at most `m`)
is withheld. Alternatively refresh the checkpoint inside `settle` with the interval-free ratchet before pricing. Keep the
keeper's `checkRisk` running in a full stop. Remove the owner's instant `triggerEmergency` (the guardian keeps it; the
overdue path stays for everyone), or make an owner-triggered emergency pay at the live NAV.

### HLR2-E06 (Medium): a full stop freezes every exit until the epoch is overdue

**Where.** `settle` reverts `ReduceOnlyMode` when `breachReason >= GUARDIAN` and not in emergency (VaultLogic.sol:210),
before any mode is chosen, so redemption-only and the overdue exit-only path are blocked too. `triggerBreach` is open to
the vault owner, the sentinel and the guardian and may be repeated (VaultGovernance.sol:227-232). Only the guardian can
undo it at once (`clearBreach`, or `triggerEmergency`); otherwise depositors wait until `epochStartedAt +
maxEpochDuration`, then anyone triggers the emergency and a role settles.

**PoC.** `test_HLR2_E06_fullStopBlocksAllExitsUntilOverdue`: alice's redemption is fully covered by idle USDC; the owner
calls `triggerBreach` and removes the operator; settle reverts for the manager, owner and guardian; 7 days - 1 s later
still nothing and alice cannot trigger the emergency; at 7 days she can, and the guardian settles. `..._E06b_...`: the
owner first raises `maxEpochDuration` to 30 days (a loosening behind the 2-day policy timelock, applied by anyone), so
the same freeze lasts 30 days.

**Impact x likelihood.** No value moves; every exit of the vault is frozen for up to 7 days on the platform vault settings, 30 days
at the policy maximum, unless the cold guardian reacts. The guardian is a single EOA acting by hand; a hostile owner can
re-trigger after every clear (each call is one transaction). The sentinel online key has the same power on every vault at
once. Medium: griefing of the core exit flow, temporary lock bounded by `maxEpochDuration`.

**Fix (describe).** Let a guardian-class stop settle redemption-only (pay at min(NAV, checkpoint), mint nothing, carry
deposits) for the platform roles, or at least let the overdue exit-only path run in a full stop (move the `hardStop`
check below the mode selection and exempt exit-only). Drop the vault owner from `triggerBreach` (the owner's legitimate
stop is `triggerEmergency`, which keeps exits open). Cap `maxEpochDuration` loosening so it never lands inside the
running epoch (apply a raise only from the next epoch).

### HLR2-E02 (Low): settle trusts a stale breach flag

`settle` decides normal vs redemption-only from the stored `breached` / `breachReason`; only the very first settle runs
`checkRisk` (HyperVault.sol:158). A drop past the daily loss limit that no `checkRisk` has seen yet is settled in normal
mode as long as it is within `maxNavMoveBps` of the checkpoint. PoC (default policy: daily loss 5%, band 20%): a 15% drop,
the manager settles in the same block, a 1M sybil deposit is minted at 85% of the NAV and is worth 1,081,081 after the
reading recovers; the next `checkRisk` finds the 15% daily loss the settle never saw. With a `checkRisk` first, the same
deposit is carried, nothing is minted. The hl-open HLO-07 PoC used exactly this ordering ("settled in the next block,
before any checkRisk sees the drop") without naming it; R-1 / I3-01 state the per-day bound as `maxDailyLossBps`, but
it is `maxNavMoveBps` per settle (20% on the platform vault, where daily loss is also 20%, so the platform vault itself is not weakened).
Likelihood: needs a deflated or transient reading and a settle in the first block that sees it (the manager or a
compromised operator / agent). Fix: run the risk check (`_check`) at the start of every settle, so the mode always
reflects the NAV being priced.

### HLR2-E03 (Low): performance fee at a settle-time spike

M-05 moved crystallisation to `settle`, but `settle` uses the live NAV within `maxNavMoveBps` of the checkpoint. PoC:
1M, +19% one-block mark spike, the manager settles: the fee recipient gets 31,937 USDC of value once the spike is gone
(alice 968,063 vs 999,993 if settled an hour later), and the HWM is pinned at 1.152, so the next 15% of real gains carry
no fee. If the NAV later passes the spike, the fee was only prepaid; if it never does, depositors lost 3.2%. Fix:
compute the performance fee at `min(nav, checkpoint_before)` (the same lag the redemption-only rule uses), so a spike
younger than an hour cannot be charged.

### HLR2-E07 (Low): late Core -> EVM landing priced as a loss

R3-08 accepts that after `MAX_UNLANDED_BLOCKS` (300, ~5 min) a missing transfer counts as lost. Consequence quantified
(`test_HLR2_E07_*`): the operator brings 50k home on a 200k vault, Core debits it, the EVM credit is late; after 301
blocks NAV reads 150k, `checkRisk` fires a drawdown breach, and the redemption-only settle (which the operator's planner
runs automatically in a loss breach) pays alice 18,750 for 25k of shares. When the transfer lands the stayers keep the
difference (mallory 103.6k for 100k). Needs Hyperliquid to deliver a Core -> EVM transfer more than ~5 min late. Fix:
for an EVM-bound transfer keep it "in transit" for pricing until it lands (or until the guardian writes it off), and
let settles that pay redemptions wait rather than price a known in-flight amount as lost.

### HLR2-E08 (Info): price quantisation

`sharePrice()` = assets per 1e12 units, rounded down: a quantum of 1 wei per whole share (1e-6 relative at a price of
1 USDC, 1e-5 at 0.1 USDC). The performance fee uses it (`gain = (price - HWM) * supply / ONE_SHARE`) and the HWM stores
it, so each charge can be off by up to `perf * supply / 1e12` wei either way (about 0.3 USDC per 1M of NAV at 30%). The
differential (section 3) shows divergences only of that size, with the fee recipient's mean below the model (the
floors favour depositors).

## 2. Rounding and conversion review (line by line)

| Conversion | Rounding | Favours | Note |
|---|---|---|---|
| `toShares` deposit (settle 257) | floor | holders | first mint (supply 0): `assets * 1e6`, NAV ignored (E05, E01e) |
| `toAssets` redemption (settle 256) | floor | holders | priced at `priceNav` (E01) |
| partial fill `burned` (settle 268) | floor | redeemers (fewer shares burned for the USDC paid) | <= 1 unit (1e-12 share) per settle |
| `claimable` deposit shares (VaultMath 238) | floor | the vault (dust shares stay in the vault, I-05) | |
| `claimable` redemption assets (243) | floor | the vault (dust USDC stays reserved, I-05) | |
| `claimable` burnedForMe (244) | ceil | the vault (fewer shares returned) | |
| fee `feeAssets` (343) and `feeShares` (353) | floor | depositors | protocol share floor of the fee shares, taken from the manager's part only |
| `sharePrice` / `priceAt` | floor | mixed | E08 |
| `_claimIfSettled` clamp (150) | min(assets, reserve) | never binds: sum of floors <= paid | confirmed by the differential (no reserve shortfall) |

12-decimal shares with the 1e6 virtual offset: the virtual shares are worth about 1 wei at a 1 USDC price. A donation
or first-depositor inflation attack is not profitable: with supply S and a donation D, a victim's deposit loses at most
1 share unit (worth `(D+1)/(S+1e6)` wei), the attacker loses `D * 1e6 / (S + 1e6)` to the virtual shares, and on this
vault the donation must also pass the NAV checkpoint (`maxNavMoveBps` per settle), so it takes hours of hourly ratchets.

Fee accrual sandwiching: `accrueFees()` is permissionless and management-only. Frequent accrual compounds the fee
down (a year at 5% charged continuously is 4.88% instead of 5%), so third parties can only lower it; the manager can
choose the NAV level the period's fee is charged on (the settle moment), worth at most `mgmt * epoch / year * band`, e.g.
5% x 7/365 x 20% = 0.019% of NAV per epoch. Management fee on pending flows: pending and insider deposits and claimable
USDC are excluded from the base (they are reserved out of idle); shares queued for redemption keep paying until they
settle, which is fair because they stay exposed. Protocol share: always a slice of the fee shares, never extra dilution
(differential: the treasury's divergence is at rounding level).

### HLR2-E09 (Info): dust supply after a near-empty vault

When supply is a few units but NAV is not (the E01 leftover with claim-floor dust, or a vault that lost almost
everything while dust shares stayed in the vault), `toShares` prices new deposits at `(nav + 1) / (supply + 1e6)` per
unit: the 1e6 virtual units and the dust own the leftover for good (nobody can redeem it), and one unit can be worth
`nav / 1e6` wei (30k left = 0.03 USDC per unit), so every later floor rounds at that size. In the differential
(campaign B no-fee, seed 1078) a vault fell to 1 USDC with 3 dust units; the next 521,001 USDC deposit was minted at
about 1 unit per wei (1e6 times coarser than the first-mint rule), the HWM jumped to 1e12, and the virtual offset kept
about 1.9e-6 of all later NAV (0.53 USDC on 270k for one depositor). Harmless in size; noted because it is the same
mechanism that locks the E01 leftover when dust exists. Fix: treat a supply below a dust threshold as an empty vault
(burn or sweep the dust, then apply the first-mint rule), and document it.

## 3. Differential test

**Method.** `Differential.t.sol` deploys a fresh factory vault per scenario (protocol share 10% or 33%, the factory's
seed rule, random management fee 0-500 bps, performance fee 0-3,000 bps, daily loss 5/10/20%, drawdown 15/30/50%,
`maxNavMoveBps` 20%, 7-day epochs, owner = manager or separate) and runs 50-70 epochs with 8 actors: 4 users, the
manager's sybil, the manager (insider), the fee recipient (insider, also redeems its fee shares), the owner (insider
when separate), plus the protocol treasury. Per epoch: random deposits (0.1-30% of the NAV scale, >= 10 USDC),
redeems (1-100% of the balance), cancels; 1-3 PnL steps of -8%..+8% with a 4% chance of a -25% crash, random
`checkRisk` and permissionless `accrueFees`; a 2.5% chance per epoch of a guardian emergency, guardian exit + clear,
owner `resume`; liquidity brought home for the redemptions (deliberately short 1 epoch in 12, a random partial in
emergency); the settle by the manager / operator / guardian / sentinel as the state allows; claims; idle redeployed.
NAV scales 1k, 10k, 100k, 1M, 10M USDC; observed NAV from 0 to 63.4M USDC. Every input is printed (`J|` lines); the
model replays the inputs only and predicts acceptance, mode, NAV, breach state and every actor's wealth.

The model (`model.py`) is written from the documented rules in 90-digit decimals, values each request individually (no
pro rata aggregates, no carry pointers, no virtual shares) and mints fee shares so the recipients receive exactly the
fee formula's USDC. Comparison per actor per settled epoch: wealth = USDC delta + shares at the contract's price +
pending deposits at face + pending redemptions at the price, against the same quantities from the model.

Campaign A: the keeper refreshes the checkpoint before every settle. Campaign B (`ECON_LAG=true`): like the live
operator, only when the checkpoint is older than a day (else 25%), so exits meet a lagging checkpoint. 50 scenarios
per forge process (`model/campaign.sh`); summaries in `econ/results/*.txt` and `*.json`. The shared heavy-tool lock was
held by another review (MUT/STAT) during these runs; each forge run is 50 deterministic scenarios (not a fuzz or
invariant campaign) and no campaign with fees exceeds 256 scenarios (A 250, B 200).

| Campaign | Scenarios | Settled epochs | Actor snapshots | Max abs divergence | Acceptance mismatches | Breach-reason mismatches |
|---|---|---|---|---|---|---|
| A, fees | 250 | 14,692 | 132,228 | 5.13 USDC (fee recipient, NAV 50.3M: 1.0e-7 of NAV) | 0 | 3 |
| A, no fees | 100 | 5,843 | 52,587 | 9 wei | 1 | 2 |
| B, fees, lagging checkpoint | 200 | 11,502 | 103,518 | 4.83 USDC (fee recipient, NAV 31.0M: 1.6e-7 of NAV) | 0 | 3 |
| B, no fees, lagging checkpoint | 100 | 5,786 | 52,074 | 0.53 USDC (seed 1078, E09) | 0 | 1 |
| **Total** | **650** | **37,823** | **340,407** | | **1** | **9** |

Relative to NAV the largest divergences are at tiny NAVs (9.8e-5 of a 1,972 USDC vault = 72 wei; 1.7e-4 at a few USDC).

Explanation of every divergence above one wei per operation:
- **Fees on**: all larger divergences trace to the 1-wei-per-whole-share price quantum in the performance fee and the
  HWM (E08). With fees off they vanish (9 wei max over 5,843 epochs); with the management fee only (10-scenario check)
  they stay at tens of wei. In price quanta (divergence / (supply / 1e12)) the maximum is 23-28 wei per whole share
  over up to 70 charges, and the fee recipient's mean signed divergence is negative in every campaign (-0.0105 to
  -0.0141 wei per share): no bias toward the fee recipient, the treasury or any insider.
- **Breach-reason mismatches (9)**: all at a drawdown of 1,500.2 bps against a 1,500 limit; the contract floors the
  metric to whole bps (`mulDiv` floor in `_check`), so a breach fires only from limit + 1 bps. 0 mode mismatches at
  snapshots.
- **Acceptance mismatch (1)**: an emergency settle where the model owed 0.47 wei more than the USDC on hand (exact vs
  floored `redAssets`), so the model saw a partial fill and refused the guardian's `exitEmergency`; the contract paid in
  full. Boundary rounding.
- **Seed 1078 (0.53 USDC)**: the virtual offset at a dust supply (E09).

No divergence above rounding remains unexplained: the code does what its documentation says, to the wei, through
partial fills, carried deposits, insider deferrals, fee accruals, emergencies and resumes, from 1 USDC to 63M USDC.

**What the documented rule itself moves (HLR2-E01, measured).** At every settle where min(NAV, checkpoint) is below the
live NAV the model records the USDC withheld from that settle's redeemers. Campaign A (checkpoint always fresh): 14
settles, 0.00 USDC. Campaign B (operator-like lag): **446 settles, 5.34M USDC withheld in total across 200 scenarios**
(no-fee B: 208 settles, 2.22M). The five largest single settles withheld 467k, 456k, 396k, 317k (redemption-only) and
307k USDC (6.0%, 6.6%, 5.5%, 3.9%, 2.3% of the redemptions, on 17-25M NAV); among settles paying at least 1,000 USDC
the median is 3.4% and the maximum 10.5% of the redemption; the largest took 8.1% of NAV from the redeemers in one
settle. All of it went to the holders who stayed. These are random scenarios with honest actors; an owner timing the
settle (E01a) does better.

## 4. Questions from the brief

- **Can any actor move value from other depositors over time?** Within the contract's own rules, the levers are: the
  exit-pricing rule (E01, Medium: the owner / settle caller moves the gain since the checkpoint from redeemers to
  stayers), the first-mint and dust rules after a full exit (E01e / E09), settle timing (N-09 / E04, and E02 where the
  breach flag is stale), performance fee timing (E03) and the documented late-landing rule (E07). Rounding moves nothing
  measurable and its bias is toward depositors.
- **Manager as a depositor**: deferred one epoch as an insider, but any sybil bypasses it (N-09); with a sybil the
  manager has the E04 / E02 / E03 levers. **Owner**: E01 (instant emergency), E06 (freeze). **Fee recipient**: passive
  gainer in E01d; no lever of its own (accrueFees is management-only and frequent calls only lower the fee).
  **Operator**: settle timing (E04), starving settles and forcing a leverage breach (LIVENESS row 15).
- **Seeded vault, supply 0, NAV > 0**: the first epoch's depositors share the seed pro rata (E05: a 999 USDC seed went
  to a 10 USDC depositor). With the minimum seed (2 USDC, 1 USDC kept by Core) 1 USDC is at stake.
- **Supply back to 0 with a large NAV left**: yes, via exit-only / redemption-only pricing below the live NAV with every
  share redeemed (E01e); with dust shares the leftover is locked instead (E09). Returned partial-fill shares keep supply
  above 0; unrealised PnL cannot be left behind by a normal full exit (it must be paid in USDC).
- **Management fee on pending flows**: excluded correctly (pending, deferred and claimable USDC are not in the base);
  verified by the differential. **Protocol share**: always carved from the fee shares; verified.
