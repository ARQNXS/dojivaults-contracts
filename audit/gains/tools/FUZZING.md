# Gains round 1: invariant fuzzing (brief section 4, "Fuzzing")

This is an internal review by a sub-reviewer. It is not an independent audit.
- Source: contracts/src/gains/* at 9f39013.
- Tools: forge (foundry, local install), Medusa 1.5.1 with crytic-compile 0.4.2.

## 1. Foundry suite: `test/audit/gains/invariants/GainsSpecInvariants.t.sol`

**What it is.** A new handler, `SpecHandler`, drives a standalone GainsVault on the mock diamond. It uses the same actions as test/gains/GainsRound4Invariants.t.sol (deposits, redemptions, settles, fees, trades that fill / cancel in the callback / time out, price moves, crashes, funding, liquidations, breaches, emergencies, sequencer and feed outages). It adds:
- settles by every role (manager, operator, owner, guardian = sentinel);
- explicit claims checked against `GainsVaultLens.claimable`, and deposit / redeem cancels;
- resting limit orders, executed or not;
- `tradeReserved`: tries to trade, or add margin with, reserved USDC;
- `operatorReduce`: the operator at and above its cap, with a leverage delta, and a close attempt;
- `raiseFee`: a timelocked setFees;
- `config`: policy tighten or loosen, an early `applyPendingConfig`, and the apply after eta;
- `nextDay` and `resume`.

**One campaign.** Every property is a ghost counter that must stay 0, plus direct state checks. All of them sit in one `invariant_spec`, because forge runs one campaign per invariant function.

| SPEC | Checked as |
|---|---|
| D1 | requestDeposit pulls exactly `assets` from the sender; the request and pendingDepositAssets grow by exactly that |
| D4 | requestRedeem by a holder with no next-epoch request never reverts (also during a sequencer outage and with every feed stale); the escrow grows by exactly the shares |
| D5 | cancelDepositRequest returns exactly the request's USDC; cancelRedeemRequest returns exactly the shares |
| D6 | Per epoch: Σ USDC claimed by its redeemers <= `epochs(e).redeemAssets`, and Σ shares returned <= redeemShares − redeemBurned. Every claim delivers <= `lens.claimable` assets and exactly its shares; the largest shortfall vs the view is recorded (it was 0) |
| D7 | openTrade above idle, increaseTrade above idle and a leverage decrease needing more than idle are all refused; USDC balance >= pending + deferred + claimable at every step |
| S1 | no settle succeeds while the diamond holds a pending order (every role, every mode) |
| S3/S4 | outside emergency, a settle always burns every queued share (paid in full or reverts) |
| S8 | after a settle: currentEpoch + 1, pendingRedeemShares 0, deferred 0, checkpointNav = epochs(e).nav, checkpointAt = epochStartedAt = settledAt = now |
| N1 | `totalAssets()` == idle + an independent sum (see below) |
| T4 | the vault's USDC allowance to the diamond is 0 at every step |
| K1 | around every checkRisk: a breach only escalates; the only de-escalation is the daily-loss reset on a new UTC day; a full stop (guardian, emergency) is never touched; no reason without a breach |
| F2 | HWM changes only in a normal settle and only upwards (except the first mint into an empty vault); performanceFeeBps never changes in accrueFees or in a breach / emergency settle |
| F3 | deposits, redemptions and fee mints never move daily loss or drawdown by more than 1 bp |
| F4 | a performance fee raise via the timelock sets only `pendingPerformanceFeeBps`; it switches on exactly at the next normal settle, and not at a breach or emergency settle |
| G1 | a proposal that is tighter on every field applies at once; anything looser leaves the config unchanged, `applyPendingConfig` before eta reverts, and it applies after eta |
| R5 | outside a breach the operator's reduce succeeds only with leverageDelta 0 and collateralDelta <= operatorReduceCap(shortfall); its closeTrade always reverts |
| X1/X2 | every close / reduce / cancelOrder / cancelTimedOut / flatten under a price outage goes through |
| (accounting) | Σ holders' shares = totalSupply; the vault's escrow >= pendingRedeemShares |

**N1 independent sum.** Idle, plus:
- every open trade valued at `GainsPrice.adverse(mid, band)` through the mock's own close math (`closeValue`), set to 0 when the price sits within the band of its liquidation price;
- the collateral of resting orders;
- pending open, partial open and leverage-decrease collateral, net of the mock's min gov fee.

**Runs.** The calm variant `GainsSpecInvariantsCalm` makes full stops and emergencies 33x rarer, for depth in normal mode.

```
FOUNDRY_OUT=out-inv FOUNDRY_CACHE_PATH=cache-inv forge test --match-path test/audit/gains/invariants/GainsSpecInvariants.t.sol --match-test invariant_spec -vv
FOUNDRY_OUT=out-inv FOUNDRY_CACHE_PATH=cache-inv forge test --match-path test/audit/gains/invariants/GainsSpecInvariants.t.sol --match-contract GainsSpecInvariantsCalm -vv
```

| Campaign | Runs × depth | Calls | Reverts | Result | Wall time |
|---|---|---|---|---|---|
| GainsSpecInvariants.invariant_spec | **2,048 × 500** (inline forge-config) | 1,024,000 | 1,148 (all in `guardianActs`) | **PASS: no property broken** | 3,751 s (62.5 min) after a 6 min build |
| GainsSpecInvariantsCalm.invariant_spec | 512 × 500 (inline config is not inherited; profile default runs) | 256,000 | 14 (guardianActs) | **PASS** | 985 s |
| GainsSpecHandlerSanity.test_specHandlerDrivesEveryAction | unit | | | PASS | |

**Calls and reverts.**
- Each of the 26 selectors received about 39,000 to 39,700 calls in the main campaign, and about 9,700 to 10,000 in the calm one.
- Every handler action wraps the vault in try/catch. The only handler-level reverts come from `guardianActs`; the vault itself never reverted unexpectedly. The `guardianActs` reverts (2.9% of its calls) come from the handler call itself, because every vault call inside it is in try/catch. I did not isolate their cause; the most likely candidate is the cheatcode layer around the guardian prank. They cannot hide a property violation, because the invariant is checked after every call, reverted or not.

**Per-run activity, from the last run of each campaign (afterInvariant logs).**
- Main campaign: 10 settles (2 normal, 7 emergency), 4 claims (2 redemption claims), 59 breach observations, 13 tightenings, 9 loosenings, 17 fee changes, 1 timed-out cancel, 9 outage rounds, 0 operator reduces accepted.
- Calm campaign: 13 settles (12 normal), 10 claims (5 redemption claims), 1 operator reduce accepted within the cap, 10 tightenings / 4 loosenings, 17 fee changes, 5 outages.
- Maximum claim shortfall vs the lens view: 0 wei in both.

**Coverage limitation, stated for ROUND1.** Per run, the handler reaches only about 10 settles and a handful of redemption claims in 500 calls, because:
- `settle` warps 1 h and needs filled orders;
- emergencies persist once triggered (main campaign);
- accepted operator reduces under the cap are rare, because a shortfall needs pending redemptions above idle.

Over 2,048 runs this is still about 20,000 settles and several thousand redemption claims. R5 is mostly exercised on its refusal side.

**Broken invariants.** None. During development the handler's own G1 check fired once in the sanity test. The cause was a memory-struct alias in the handler (`RiskConfig memory n = c` copies the reference), not the vault; it was fixed before the campaigns.

## 2. Medusa: `test/audit/gains/invariants/medusa/GainsMedusa.sol`

**Harness.** Self-contained: the constructor deploys MockUSDC, the mock diamond, feeds, a factory (curation and price source), one standalone vault clone and its policy, the same way GainsBase does. Medusa's hevm cheatcodes are used for prank, warp and roll.

Actions: deposit, redeem, claim (checked against the lens), cancelDeposit, cancelRedeem, settle (manager), emergencySettle (guardian trigger + settle + exit), accrue, trade, closeOne, move, liquidate.

Properties:
- `property_reservesBacked`
- `property_sharesAccounted`
- `property_escrowCoversQueue`
- `property_usdcConserved`: the sum over actors + vault + diamond + fee recipient is constant
- `property_claimsNeverExceedEpoch`: per-epoch redemption claims <= redeemAssets, and every claim <= lens.claimable
- `property_noStandingApproval`: also checked right after each openTrade
- `property_navNotAbovePayout`

**Build on Windows (worked).** crytic-compile cannot build this via_ir project quickly by itself: it would run a full `forge build` of src + test + script, about 20 min, on the shared `out/`. So the build goes into a private directory and Medusa uses `--ignore-compile`:

```
FOUNDRY_SRC=test/audit/gains/invariants/medusa FOUNDRY_TEST=test/audit/gains/invariants/medusa FOUNDRY_SCRIPT=test/audit/gains/invariants/medusa \
  FOUNDRY_OUT=out-medusa FOUNDRY_CACHE_PATH=cache-medusa forge build --build-info          # 4.5 min
PATH="~/AppData/Roaming/Python/Python313/Scripts:$PATH" \
  ~/tools/medusa/medusa.exe fuzz --config audit/gains/tools/medusa.json       # crytic-compile args: --foundry-out-directory out-medusa --ignore-compile
```

- Config: `contracts/audit/gains/tools/medusa.json`: 8 workers, callSequenceLength 100, timeout 3,600 s, assertion + property mode, codeSizeCheckDisabled, cheatcodes on, slither off.
- Medusa linked the external libraries (GainsVaultLogic, GainsVaultGovernance, GainsNav) itself.
- Medusa writes the corpus and lcov next to the config (`audit/gains/tools/medusa-corpus/`). I moved them to `contracts/medusa-corpus/` after the run; they are generated output, so do not copy them.

**Result.** Capped by its time limit at **1 h** (user rule: no single run beyond about 2 h).
- 1,439,150 calls in 14,454 sequences, about 500 calls/s.
- 4,414 branches, 86 corpus entries.
- **19/19 tests passed**: 7 properties and 12 assertion-mode actions. No failure.

Line coverage of src/gains from Medusa's lcov:

| File | Lines hit |
|---|---|
| GainsNav.sol | 65 / 79 (82%) |
| GainsPrice.sol | 21 / 24 (88%) |
| GainsVaultLogic.sol | 176 / 292 (60%) |
| GainsVaultMath.sol | 38 / 70 (54%) |
| GainsVaultGovernance.sol | 71 / 171 (42%) |
| GainsVaultPolicy.sol | 61 / 138 (44%) |
| GainsVault.sol | 33 / 125 (26%, mostly view getters) |

The factory and lens are low (19% / 18%) because the harness creates no vault through the factory.

Echidna 2.3.3 was not run: Medusa built and ran, and the brief asks for one of the two.

## 3. Symbolic fuzz twins

`test/audit/gains/symbolic/SymbolicFuzzTwins.t.sol` runs 42 forge fuzz tests at 100,000 runs each, all of which pass. They cover every Halmos check expected to hold; see HALMOS.md.

## Caps (user rule)

| Run | Cap | Reached |
|---|---|---|
| Foundry invariant_spec | none needed (finished in 62.5 min) | 2,048 runs × 500 = 1,024,000 calls |
| Foundry Calm | none needed (16 min) | 512 × 500 = 256,000 calls |
| Medusa | `timeout: 3600` (1 h) | 1,439,150 calls, 14,454 sequences, 4,414 branches; coverage table above |
