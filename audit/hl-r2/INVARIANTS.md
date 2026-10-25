# hl-r2: conservation invariant on a HyperCore simulator (brief section 3.3)

**This is an internal, AI-assisted review. It is not an independent audit and must not be presented as one.**

Files (`contracts/test/audit/hl-r2/async/`): `CoreSim.sol` (simulator, ASYNC.md section 1), `SimBase.t.sol` (factory
vault launched as the platform does: hosted, platform agent, keeper operator, seed + A-13 agent sync),
`ConservationHandler.sol` (handler and ghost model), `ConservationInvariants.t.sol` (properties, two
configurations, coverage probe), `SensitivitySequences.t.sol` (failing sequences of the sensitivity runs, replayed),
`MedusaConservation.sol` (Medusa harness, same handler).

## 1. Configurations

| Contract | Policy | Roles | Fees |
|---|---|---|---|
| `ConservationPlatformVaultInvariants` | the live platform vault: 5x, daily loss 20%, drawdown 50%, slippage 1%, epoch 7 d, maxNavMove 20%, flatten 3% | owner = manager (as live), keeper operator, platform agent, factory guardian / sentinel | 2% / 20%, hosted 33% protocol share |
| `ConservationTightInvariants` | 3x, daily loss 5%, drawdown 15%, epoch 1 d, maxNavMove 10% | separate manager | 5% / 30% (the caps), 33% |

Both start from a vault with history (alice 100 k settled, bridged and on perp). Participants: alice, bob, carol, the
owner, the manager (if separate) and the fee recipient (insiders), a stranger, the protocol treasury.

## 2. Ghost model

All amounts USDC, 6 decimals. CoreSim keeps, per account: perp cash, positions with entry and mark (unrealised PnL),
spot USDC, the agent slot, account existence; and per vault: USDC in flight EVM->Core and Core->EVM, transfers lost
by the bridge, the activation fee, and the trading PnL ghost (explicit shocks + realised + unrealised).

- **True NAV** `T` = vault EVM balance - reserves (pending + deferred deposits + claimable) + perp account value +
  spot + both in-flight amounts. This is what the depositors own; the vault's `totalAssets()` is compared with it.
- **Boundary**: participants' USDC + vault EVM USDC + vault Core value + in flight. Inflows: handler mints to
  participants (counted). Outflows allowed: trading PnL (ghost), the 1 USDC activation fee, transfers the bridge
  loses (injected, rare). Nothing else.
- **Value transfers between participants** can only happen at settle (pricing), fee mints, claims and cancels. Each is
  measured against `T` at the moment it happens:
  - settle: `S` = supply after the settle's fee mint; depositors receive `depShares * (T+1)/(S+1e6)` for `depIn`;
    redeemers receive `paid` for `burned` shares worth `burned * (T+1)/(S+1e6)`; the NAV the vault used is
    `nav_used = epoch.nav + paid - depIn`;
  - fee mint (settle, `accrueFees`, `lowerFees`, timelocked `setFees`): fee shares = balance deltas of the fee
    recipient and the protocol treasury (no other share moves to them in those calls), valued at `T`;
  - claim / auto-claim in `requestDeposit` / `requestRedeem`: exact deltas against an independent replica of the
    epoch record (`claimableWithCarry`); cancels: exact amounts.

**Documented deviations (allowed, measured):**
- exit-only and redemption-only settles price redemptions at `min(NAV, checkpoint)` (`M exit underpay`);
- a settle while vault USDC is still in flight is allowed only when the latest bridge is older than
  `MAX_UNLANDED_BLOCKS` (R3-08, written off), when the in-flight USDC belongs to an older written-off bridge, or when
  the agent moved perp -> spot inside an open to-Core window (R3-01 residual, a possible fake landing). Measured as
  `M late settles / nav gap / deposit gain / redeem loss` (this is HLR2-A02 / A04 / A05 happening in the run).
- the one-sum floor of `coreEquity` (L-05) is avoided by keeping perp account values >= 0 (HL liquidates first;
  HLR2-A06 covers the transient).

## 3. Properties (`invariant_conservation`, also the Medusa `property_*`)

| Id | Property |
|---|---|
| C1 | USDC conservation, exact to the wei: participants + vault EVM + Core + in flight = start + minted + trading PnL - activation fee - lost transfers |
| C2 | reserves (pending + deferred deposits + claimable) are held on the EVM |
| C3 | what every epoch record owes (USDC and shares, all participants) is covered by `claimableRedeemAssets` and the vault-held shares (beyond pending redemptions) |
| F1 | no settle at a NAV above the true NAV (+3 wei) |
| F2 | no settle below the true NAV beyond the documented in-flight reasons |
| F3 | depositors never credited more than `depIn` at `T`, except in a measured deviation (in-flight settle) or a first mint into a supply-0 vault (HLR2-A08, measured as `M first mint windfall` since it was found) |
| F4 | redeemers never paid more than their burned shares are worth at `T` |
| F5 | a normal settle without deviation moves at most 3 wei either way |
| F6 | exit-only / redemption-only: redeemers paid at least `burned` x `min(T, checkpoint)` price |
| F7 | exit-only / redemption-only settles mint no shares |
| F8 | fee value at `T` <= management (configured rate x `T` x elapsed / year) + performance (configured rate in force before the call x gain of the true price above the HWM x supply), and the configured rates <= 5% / 30% |
| F9 | no performance fee outside a normal settle (breach, emergency, `accrueFees`, fee changes) |
| F10 | protocol shares = floor(fee shares x protocol bps / 10,000) |
| F11 | every claim and auto-claim delivers exactly what the epoch record says (no reserve cap kicks in) |
| F12 | cancels return exactly the pending deposit / redemption |

## 4. Handler actions

Time: `roll` (1-400 blocks, 1 s each), `warp` (1 min - 3 days). Depositors: `deposit`, `redeem`, `cancelDeposit`,
`cancelRedeem`, `claim`, `transferShares` (any participant incl. the insiders). Settles: `settle` by manager,
operator, owner, guardian, sentinel, stranger, a depositor (keeper `checkRisk` first in a third of the calls);
`keeperCycle` (the keeper's routine: sync, checkRisk, bridge home what pending redemptions need, push idle to Core,
or settle). Fees: `accrueFees`, `lowerFees`, `queueFees` + `executeQueued` (timelocked raises and cuts). Treasury:
`bridgeToCore`, `bridgeToEvm` (manager / operator / platform roles), `moveUsd`, `syncBridge`. Faults: `faults` (credit
delay 1..2,000 blocks, delivery delay 0..2,000, 1/64 lost each way, dropped class transfer / send / agent approval,
delayed class transfer). Trading: `pnlShock` (+-8% of perp value), `markMove` (+-10%), `managerOrder` (on-chain,
policy checked), `flatten` (each role), `agentAction` (spot <-> perp, open up to 3x either side, close). Risk:
`checkRisk`, `breachOps` (trigger breach / emergency by each role, clearBreach, exitEmergency, resume,
clearLeverageBreach, syncAgent).

## 5. Runs and results

All campaigns on unmodified `src` (checked with `git diff --quiet contracts/src` before each). Times are wall
clock on the shared Windows machine (another forge session ran in parallel for part of them).

| Campaign | Runs x depth | Calls | Time | Result |
|---|---|---|---|---|
| light, both configs (development) | 512 x 500 | 256,000 each | 223 s / 481 s | F1 fired: a sim artefact (negative perp account value netted against spot, now excluded; real-world side recorded as HLR2-A06) |
| light, both configs, after the fix | 512 x 500 | 256,000 each | ~4-8 min | pass |
| light, seed 0x1234 and 0x77, both configs | 256 x 500 | 128,000 each (x4) | 196-257 s each | pass |
| **heavy #1** (lock 05:22-05:55 local) PlatformVault | 2048 x 500 | failed at run 380 (189,764 calls) | 1,285 s | F2: dust bridge (< 1 USDC, the documented landing tolerance) still in flight after its window; F2 then allowed the 1 USDC tolerance (ASYNC S15b) |
| heavy #1 Tight | 2048 x 500 | failed at run 439 (219,480 calls) | 692 s | same F2 dust case |
| **heavy #2** (lock 14:58-15:47 local, after the reboot) PlatformVault | 2048 x 500 | **failed at run 500 (249,982 calls)** | 552 s | **F5 / F3: HLR2-A08** (exit-only settle at a written-off NAV burns the redeemer for 0; a later first mint takes the value). New finding; the handler now measures it (`M first mint windfall`) |
| heavy #2 Tight | **2048 x 500** | **1,024,000** | 2,230 s | **pass** |
| **heavy #3** (lock 23:53-00:16 local) PlatformVault, after the A08 measure and the A04 timing fix | **2048 x 500** | **1,024,000** | 1,354 s | **pass** |
| sensitivity (section 6) | 256 x 300 / 500 | up to 128,000 | 82-365 s each | see section 6 |
| coverage probe (`test_coverage`) | 24 sequences x 300, invariant after every call | 7,200 per config | ~16 s | pass; totals below |

Coverage totals (coverage probe, PlatformVault / Tight): normal settles 217 / 161, redemption-only 12 / 47, exit-only
34 / 53, partial fills 5 / 4, claims checked 458 / 389, fee checks 220 / 225, bridges to Core 91 / 69, bridges home
132 / 138, settles with USDC in flight (documented) 3 / 3, value moved to depositors at those settles 45,004 /
525 USDC, value lost by redeemers at those settles 0 / 12,736 USDC, exit underpay (min rule) 0 / 9,216 USDC, longest
pending window 290 blocks, agent actions accepted on Core after the EVM side revoked it (A01) 56 / 74.

Caps hit: the first two PlatformVault 2048 x 500 campaigns stopped early (run 380: the dust-tolerance artefact; run 500:
A08, a real finding); the third ran all 2,048 runs and passed. Tight passed 2,048 x 500. Medusa is section 7.

**Interruption.** The machine powered off during the night of 2026-10-20 and rebooted at 12:51 UTC; every process
died. Running at that moment: nothing of this review held the lock; my combined runner (forge 2048 x 500 x 2 then
Medusa) had been waiting for the lock since 06:08 local (the mutation / Halmos reviewers held it in back-to-back
sessions from 23:38 to past 10:44 local). Lost: about 6 h of waiting, no partial results (worktree clean at
e32d059). Restarted after the reboot: the combined runner (lock acquired 14:58 local, heavy #2 above), then Medusa
(section 7), which first failed to start (crytic-compile not on PATH; then forge's dynamic test linking
`foundry-pp/` files unknown to crytic-compile; fixed with a separate build into the scratch dir with
`FOUNDRY_DYNAMIC_TEST_LINKING=false`).

## 6. Sensitivity (fixes from earlier rounds reverted in a temporary local edit)

Method: `scratchpad/sens/run.sh` applies a patch to `contracts/src`, runs the campaign, and restores with
`git checkout -- contracts/src` in an EXIT trap; `git diff contracts/src` was verified empty after every run and
before every commit. `src` was never committed modified. The shrunk sequences are kept as
`SensitivitySequences.t.sol` (they pass on the shipped src and fail with the fix reverted; replay confirmed for all
four).

| Fix reverted | Patch | Random campaign | Caught by | Shrunk sequence |
|---|---|---|---|---|
| V-01 (partial fill burns only what it paid) | `VaultLogic.settle`: `burned = redShares` | Tight, 256 x 300: failed after 11 runs / 3,158 calls (201 s incl. compile) | **F6** redeemers paid below min(NAV, checkpoint) | 3 calls: `redeem` (alice), `breachOps` (owner triggers emergency), `settle` (partial fill with no liquidity burns every requested share for 0) |
| N2-02 (perf fee raise waits a settle) | `VaultLogic.settle`: apply `pendingPerformanceFeeBps` before `_accrueFees` | PlatformVault, 256 x 300: failed after 109 runs / 32,493 calls | **F8** fee above the configured rates | 5 calls: `queueFees(1%, 24.6%)`, `warp` past the timelock, `executeQueued`, `pnlShock`, `keeperCycle` (settle charges the running epoch at 24.6%) |
| R-02 + R3-08 (window waits for the landing, 300 block cap) | `VaultMath.bridgePending` / `totalAssets`: plain 10 block window | PlatformVault, 256 x 300: failed after 18 runs / 5,390 calls | **F2** settle below the true NAV without a documented reason | 6 calls: `deposit`, `settle`, `bridgeToEvm`, `faults` (delivery late), `roll` (bounded to <= 400 blocks), `keeperCycle` (settle with the transfer in flight) |
| R3-01 (to-Core landing on spot only) | `VaultMath.bridgeArrived`: also accept `coreEquity() >= coreAtBridge + want` | PlatformVault 256 x 300 and Tight 256 x 500: **not found** (needs a credit later than 10 blocks plus PnL above the amount inside the window, then a settle before the credit) | **F2** with the hand-written 9-call sequence `test_sens_R301` | `deposit`, `warp`, `settle`, `faults` (credit 2,000 blocks late), `bridgeToCore(5k)`, `pnlShock(+8%)`, `roll(15)`, `deposit`, `keeperCycle` |

Not attempted: C-01 (checkpoint bound). The suite has no "hidden funds" action (an agent parking USDC on another dex
or in a spot token, invisible to `coreEquity`), so a NAV deflation inside the trust boundary is not modelled, and the
checkpoint bound has nothing to protect in this model. L-04 (in-window snapshot) is not observable here: settles and
fee accruals cannot run in a window, so only views change.

## 7. Medusa

Written by the lead from the run logs: the sub-reviewer stopped on an API usage limit right after run 2.
Harness: `MedusaConservation`, which drives the same `ConservationHandler` and `CoreSim` as the forge campaigns
through predeployed storage-based precompile forwarders. Properties C1 conservation, C2 reserve-backed, C3 owed
covered, F claims, F fairness and F fees. Medusa runs on Windows under the shared heavy lock. Config and runner:
`evidence/medusa/final.sh`. Summaries: `evidence/medusa/medusa_run{1,2}.summary.txt`.

| Run | Timeout set | Ran | Calls | Branches / corpus | Result |
|---|---|---|---|---|---|
| 1 (2026-10-20, after the reboot) | 21,600 s | 3 h 25 min (stopped on the failure) | 9,137,813 | 8,454 / 255 | **F_fairness FAILED**, 5 passed: a 6-call sequence (bridgeToEvm, faults, agentAction, bridgeToCore, executeQueued, keeperCycle). The agent's perp -> spot move is queued in the same block as the keeper's `bridgeToCore`, the credit lands late, and the keeper settles 11 blocks later, 809.9 USDC short. That is the HLR2-A04 variant (ASYNC.md), and the forge replay is `MedusaReplay.t.sol`. The handler's landing classifier missed it, and was fixed in c089d24. |
| 2 (lock 23:53 local to about 03:16 local) | 10,800 s | 3 h 00 min (full timeout) | 8,416,739 | 8,458 / 250 | **all 6 properties PASSED**, 0 failures |

Both runs used the unpatched source (A1). Medusa time in total: about 6 h 25 min, against the 12 h cap. The cap
was not hit: run 1 stopped on a finding, and run 2 used a 3 h timeout chosen by the sub-reviewer.

## 8. Caps hit and assumptions

- Perp account value kept >= 0 (HL liquidates first); fills at mark, no fees, no book (slippage is real PnL, not
  asynchrony). One perp dex, no spot tokens, no HL vault deposits, no subaccounts, no abstraction modes.
- Coverage counters: forge prints only the last run's handler; the coverage probe (`test_coverage`, 24 sequences x
  300 calls, invariant checked after every call, needs `FOUNDRY_GAS_LIMIT` raised) gives the totals in section 5.
- The fairness tolerance is 3 wei per settle / claim (floor rounding); the fee tolerance is 3 wei + 1e-9 relative.
