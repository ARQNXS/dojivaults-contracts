# Gains round 1 fixes: verification pass

**This is an internal verification of the fix round [FIXES-R1.md](FIXES-R1.md) for the internal review [ROUND1.md](ROUND1.md). It is not an independent audit and must not be presented as one.**

**Independence.** This pass was run by the same agent that wrote the round 1 fixes, under the instruction to check them as an outside reviewer. That is a real limit:
- FIXES-R1's claims were not taken as evidence. Every verdict below rests on a test written for this pass, or on a re-run of an existing test that is named.
- An independent reviewer should still repeat at least sections 3 and 4.

## Scope

- **Branch:** `verify/gains-r1` in the worktree `dv-verify-gains`.
  - Created from `fix/gains-r1` (56cc78c), with `origin/main` 7eb6712 merged in (f002735).
  - The merge changed nothing under `contracts/`. On the server it removed only main's old landing "copy featured" code (`app.ts`, `history/service.ts`, `main.ts`).
  - So the contracts verified here are byte for byte those of `fix/gains-r1`.
- **Read:**
  - ROUND1.md, FIXES-R1.md, fixes/EXECUTOR.md, docs/gains/AUDIT-DIFF.md, docs/gains/VENUE-LIVENESS.md;
  - the full fix diff for `contracts/src` and `server/src`, taken as `e850c3d..fix/gains-r1`. e850c3d is the fix branch's own merge of main, so `audit/gains-r1..fix/gains-r1` would also show main's unrelated changes.
- **Written:** only in `contracts/audit/gains/` (this file) and `contracts/test/audit/gains/verify/`.
- **Not done:**
  - no edit to `contracts/src` or `server/src`;
  - nothing deployed, no transaction sent, nothing pushed, nothing merged.
- **Baseline on the merged branch, before any new test:**
  - Full `forge test` with the Arbitrum RPC: **94 suites, 759 passed, 0 failed, 2 skipped** (2,556 s). The existing `invariant_spec` passed at 2,048 runs × 500 depth (1,024,000 calls, 1,099 reverts).
  - Executor: `npm test` main run **909 passed, 0 failed, 6 skipped**. Two timing tests failed once and passed when re-run alone: `dojipad-ec` batching timed out at 20 s while solc held the CPU (52 / 52 alone), and `startup.test.ts` answered /health in 8.2 s against 2 s right after the main run (2 / 2 alone, twice). Neither touches Gains code. `tsc --noEmit` is clean.

## Tests written for this pass

All are in `contracts/test/audit/gains/verify/`, and all pass.

| File | What | Tests |
|---|---|---|
| `VerifyFixes.t.sol` | Item 1: variants of each fixed finding's PoC (pairs, sides, several vaults, edge values) | 23 |
| `VerifyRegressions.t.sol` | Item 2: regressions, plus the PoCs of GV-01 and GV-02 | 16 |
| `VerifyLiveness.t.sol` | Item 4: the landing-page claim in every settle mode against every price fault | 5 |
| `VerifyLaunch.t.sol` | Item 3, contract side: what the CREATE2 address commits to; a late fill | 5 |
| `VerifyFork.t.sol` | Item 5 gas on the Arbitrum fork; the fork side of items 2 and 4 | 6 |
| `VerifyInvariants.t.sol` | Item 2: a random-ordering invariant for two-sided pricing | 1 invariant |
| `executor/verify-r1.test.ts` | Item 3, executor side: binding rules, late fill, the reduce-rate alarm | 7 (vitest) |

```bash
cd contracts
forge test --match-path "test/audit/gains/verify/*"     # the fork file needs ARBITRUM_RPC_URL, it skips without
cd ../server && npx vitest run --config ../contracts/test/audit/gains/verify/executor/vitest.config.mjs
```

Severity uses the ROUND1 scale (brief section 5: the HL scale calibrated with Immunefi; impact × likelihood).

## 1. Summary table

**Verdicts** are closed, partially closed or not closed. **Verified by** names the tests of this pass; the fix's own regression tests were re-run in the baseline. "No new variant" means only the fix's own tests stand behind the verdict.

| Finding | Verdict | Verified by | Note |
|---|---|---|---|
| GR1-01 pending leverage-only increases | **Closed** | V01a-e | Shorts on BTC / ETH / SOL, an open and a leverage raise after pending increases, exact to one leverage step, per vault |
| GR1-02 deposits at the adverse edge | **Closed** | V02a-h, `invariant_noSettleLowersPerShareTrueValue`, V20a-e | Short / long, 25 bps SOL, fees, split deposits, redeem plus deposit in one settle, near liquidation, flat vault. Residuals: GV-05, GV-06, and the performance fee on the spread (section 3.1) |
| GR1-03 band counted twice | **Closed** | V03a, V03b | Short side and SOL, on both sides of L |
| GR1-04 decoys hold the emergency settle | **Closed** | V04a-c, V20a, V21a | No holding order can be created once overdue or in emergency, by the manager or the agent. Residual: decoys still cost the gov fee (GV-04). Regression: unknown order types (GV-02) |
| GR1-05 / 06 / 07 executor resubmits | **Closed** | late-fill test (vitest), the fix's tests | No new variant beyond the late fill |
| GR1-08 Trade ABI change | **Closed** for what ROUND1 describes (fields appended) | V23a-d | Stronger claims in the NatSpec do not hold: GV-01 |
| GR1-09 exit-only settle prices the venue | Not fixed; **reason holds** | V40a, R1PoC STALESETTLE | Section 5 |
| GR1-10 sequencer feed rotation | **Closed** | V10a, the fix's tests | Info GV-03 |
| GR1-11 reduce without a floor | Not fixed; **reason holds** | the fix's alarm test | The alarm does not see closes (GV-04) |
| GR1-12 policy owner | **Closed** | V12a | Including the two-step window |
| GR1-13 decimals cached | **Closed** | V13a | Up, down, reverting, empty, malformed |
| GR1-14 SOL 24.5 h | Not fixed; **reason holds**, impact as stated | V40c, VF deployed limits | FIXES-R1 §3 overstates the mitigation (section 5) |
| GR1-15 free cancel option | **Closed** (by GR1-02) | the fix's test, V02a-f | |
| GR1-16 resting orders survive a stop | **Closed** (contract half) | V21a, V25 | The cancel cannot be starved by a gas limit. A bot trigger in flight still blocks it (GR1-25, accepted) |
| GR1-17..22 executor Lows | **Closed** | the fix's tests; section 4 for GR1-22 | No new variant except GR1-22 |
| GR1-23 dust checkpoint | **Closed** | the fix's tests | No new variant; MIN_RISK_NAV is 1 USDC, so only dust skips the bound |
| GR1-24 uint64 truncation | **Closed** | V24a | The price cap at its exact edge |
| GR1-28, 30, 31, 32, 43, 44 | **Closed** | the fix's tests | No new variant |
| GR1-41 flatten(0) slippage | **Closed** | V41a | |
| Earlier bugs (minPosition, executor minimum, runbook seed) | **Closed** | the fix's tests | No new variant |
| **GV-01** a field inserted before positionSizeToken is misread silently | **New, Info** | `test_GV01_*` | Section 7 |
| **GV-02** an unknown pending-order type neither holds settle nor counts in NAV | **New, Low** | `test_GV02_*` | Section 7 |
| **GV-03** the sequencer rotation adopts the factory's value at execution; any grace accepted | **New, Info** | V10a | Section 7 |
| **GV-04** decoy closes still cost the gov fee, and the rate alarm counts reduces only | **New, Low** | VF decoys, vitest alarm | Section 7 |
| **GV-05** anyone can make a redemption settle wait up to 1 h | **New, Info** | V20e | Section 7 |
| **GV-06** a non-holding order's fill steps NAV after a settle | **New, Info** | V24a, VF leverage fill | Section 7 |

No Critical, High or Medium was found.

## 2. Item 1: does each fix close its finding?

### GR1-01 (closed)

ROUND1's PoC used longs on ETH and BTC in one vault.

| Variant | Test | Result |
|---|---|---|
| Shorts on all three pairs, SOL included. Three trades of 10k notional, each with a +25x leverage-only increase (+125k) | V01a | Two accepted, the third refused with `leverage`. Within 3x before and after the fills. |
| A new open after two pending increases (270k on about 100k) | V01b | 15k fits, 30k is refused. |
| A leverage raise (an order of 0 notional) after a 35% move against three shorts | V01c | Refused. Open plus pending is 290,500 against 3 × 89,412. The round 1 view (40,500 open) would have accepted it. |
| Edge value: an increase that fills the room under 3x to within one leverage step (27,988 steps = 279,880 USDC) | V01d | Accepted. One more step (10 USDC of size) on another trade is refused: the check is exact to the unit. |
| Several vaults | V01e | Each vault counts only its own pending orders. |

### GR1-02 (closed)

The scenario in every row: a holder (alice, 100k) is in a vault with 270k of open notional. A depositor (bob, 100k) enters while the trade is open and leaves after it closes at the same price. Each row is compared with the same timeline without bob.

| Variant | Test | bob gets back for 100k | alice, with bob / without | fee recipient, with / without |
|---|---|---|---|---|
| ETH short, no fees | V02a | 99,676.99 (−323.01) | 100,215.02 / 99,999.54 | 108.00 / 0.46 |
| SOL long (band 25 bps), no fees | V02b | 99,596.64 (−403.36) | 100,268.69 / 99,999.54 | 134.68 / 0.46 |
| BTC short, with fees (0.06% per side) and 120 of holding fees | V02c | 99,729.90 (−270.10) | 99,825.41 / 99,555.55 | 0.68 / 0.45 |
| ETH long, with the same fees | V02d | 99,729.90 (−270.10) | 99,825.41 / 99,555.55 | 0.68 / 0.45 |
| Deposit split over 4 epochs (4 × 25k) | V02e | 99,676.79 (−323.21) | 100,214.47 / 99,998.86 | |
| Redeem and re-deposit in the same settle | V02f | bob's wealth −539.49 compared with simply holding | alice not diluted | |
| One trade inside the band of its liquidation (worth 0 at the adverse edge, 1,123.92 at the favourable one), then liquidated | V02g | 99,713.15 (−286.85) | 291,285.29 / 290,998.67 | |
| Flat vault | V02h | 99,999.77 (−0.23: one hour of the 2% management fee) | | |

In every row bob loses and alice is never diluted (each test asserts it, within 10 wei of rounding). Bob and the fee recipient together never gain either, so a manager cannot profit through a confederate's deposit. The 1 h rule (V20a-e) and the random-ordering invariant are in section 3.

### GR1-03 (closed)

| Variant | Test | Result |
|---|---|---|
| ETH 10x short opened at 3,000, liquidated at 3,270, Chainlink at 3,263 | V03a | The adverse edge is 3,269.5, short of L: valued at 507.90 USDC, never above what Gains pays at 3,263. Round 1 zeroed it. At 3,265 the edge is past L: 0. |
| SOL 20x long, band 25 bps, L = 143.25, Chainlink at 143.8 | V03b | Valued at 627.00 (round 1: 0). At 143.5: 0. |

### GR1-04 (closed)

| Variant | Test | Result |
|---|---|---|
| Overdue, not yet in emergency | V04a | Every request refuses with `EpochOverdue`, for the manager and the agent: open, increase with collateral, leverage-only increase, leverage decrease, leverage raise. So no order that holds collateral can appear in front of the exit-only settle. |
| In emergency | V04b | The manager gets `ReduceOnlyMode` on all five. The agent was revoked by the stop. |
| All non-holding order kinds at once | V04c | The emergency settle runs with a leverage-only increase, a decoy close and a 1 USDC decoy reduce all pending. |

The residual cost of decoys is GV-04. The regression in how settle decides what holds it is GV-02.

### GR1-08 (closed for appended fields)

| Variant | Test | Result |
|---|---|---|
| One trade with an appended field (the case round 1 decoded silently) | V23a | Read exactly. |
| A dynamic field appended | V23b | `DiamondLayoutChanged` on every priced path. |
| PendingOrder grows its own tail while no trade is open (no stride to cross-check) | V23c | `DiamondLayoutChanged`, not a misread. |
| `flattenIndices` with getTrades, getPendingOrders, getTrade and getTradeInfo all reverting | V23d | Both closes go out, and no feed is called (`vm.expectCall(..., 0)`). |

The NatSpec claims more ("never decodes silently wrong"). GV-01 shows a layout for which that is false.

### GR1-10, 12, 13, 16, 24, 41 (closed)

- **GR1-10 (V10a):** the rotation runs through the vault timelock, and anyone can execute it. What it adopts is the factory's value at execution time, not at queue time: GV-03.
- **GR1-12 (V12a):** during the vault's two-step transfer the policy answers to the current owner and refuses the pending one. After acceptance it answers only to the new owner.
- **GR1-13 (V13a):** each of these is `PriceStale`: decimals 18, decimals 6, a reverting `decimals()`, empty returndata, and a uint256 with high bits set.
- **GR1-16 (V21a, V25):**
  - A stop triggered by a stranger (overdue with redemptions waiting) cancels the resting orders.
  - V25 searched every gas limit from 60k to 3M in 5k steps for one where an inner call runs out of gas and the stop still completes with an order alive. There is none: at the lowest gas at which the stop completes, everything is cancelled.
  - The structural reason: after a starved call, the rest of the stop needs more than 1/64 of what a cancel or the list read needs. That should also hold on the real diamond, whose reads and cancels cost more than the mock's. This was not measured on the fork.
- **GR1-24 (V24a):** the largest accepted answer is `MAX_PRICE` rounded to the feed's 8 decimals. One unit more is `PriceStale`. Its 10% band edge still fits a uint64.
- **GR1-41 (V41a):** `flatten(0)` takes `min(maxSlippageBps, maxFlattenSlippageBps)`: 50 bps with maxSlippage 50, and 1% with the default.

### Executor findings (closed)

- The fix's tests (GR1-05/06/07 idempotency, GR1-17..22 lows, GR1-16 sentinel, GR1-11 alarm) pass in the executor suite.
- One new variant was added: the late fill in section 4.
- No further executor variants were attempted. These verdicts rest on the fix's tests, which this pass re-ran but did not extend.

## 3. Item 2: regressions the fixes could cause

### 3.1 Two-sided pricing

- **Ordering, split deposits, deposit plus redeem in one settle:** none extracts value (V02a-h, section 2).
- **Random orderings.** The invariant `VerifyBandInvariants.invariant_noSettleLowersPerShareTrueValue` sets up:
  - two attackers;
  - their random deposits, redemptions, cancels and claims;
  - the manager's opens, closes, and leverage-only increases, some left pending across settles;
  - fills and settles, in any order;
  - no price move and no fees; every trade is valued at what Gains pays for it at the unchanged Chainlink price.

  It asserts that no settle lowers the per-share true value. **512 runs × 200 depth, 102,400 calls: no settle lowered it.** In the last run: 25 settles, 20 with trades open, 11 with trades open and flows queued.
  - **The property catches the old bug.** It was run once on a scratch copy with the GR1-02 fix undone (`fixes/revert-check/unfix.py GR1-02a`: deposits mint at the adverse NAV again). It failed on a 3-call sequence: open a trade, deposit, settle.
  - **A first formulation failed for a reason unrelated to the vault, and was replaced.** It measured a passive holder against the trades' collateral. The mock diamond's rounding, when an increase re-weights openPrice and leverage, moved that by 15.05 USDC in a sequence with no deposit or redemption at all (open, two leverage-only increases, close). The property now measures what each settle does to the per-share true value, with every trade at what Gains pays at the Chainlink price. Settle is the only call that mints or burns shares, so this is exactly what flows can do.
- **Zero open trades:** both edges are equal. A round trip costs only the management fee for the time in the vault (V02h).
- **One trade near liquidation:** the depositor pays the favourable-edge value and carries the loss if Gains liquidates. The holder is not diluted (V02g).
- **Fees accruing** (opening and closing fees, holding fees, the management fee): the depositor still loses and the holder still gains (V02c, V02d).
- **Not a defect, worth knowing.** Without fees (V02a, V02b), the spread the depositor pays lifts the share price above the high-water mark, so the next settle charges the performance fee on part of it.
  - The fee recipient took 107.54 of bob's 323.01 (ETH) and 134.22 of 403.36 (SOL).
  - Bob and the fee recipient together still lose, so it is not a collusion route.
  - The holders receive the spread net of that fee.

### 3.2 The 1 h rule for settles that price deposits

| Case | Test | Result |
|---|---|---|
| Emergency settle 5 minutes into the epoch, deposits queued | V20a | Runs; the deposits are refunded, not minted. |
| Loss-breach redemption-only settle 5 minutes in, deposits queued | V20b | Runs; the deposits are carried. |
| Overdue | V20c | The platform's exit-only settle needs the epoch overdue, and maxEpochDuration is at least 1 h, so it can never be younger than the hour. At the minimum (maxEpochDuration = 1 h), at 1 h − 1 s neither a normal settle with deposits nor a platform settle runs; at 1 h both do. There is no window in which no settle can run. |
| A settle that pays only redemptions | V20d | Runs 1 minute after the last one. |

**Residual (GV-05, Info):** anyone can queue MIN_DEPOSIT and make the manager's next normal settle wait until the epoch is an hour old (V20e).

### 3.3 EpochOverdue and PendingOrderExists against exits

- `EpochOverdue` is checked only in `_newRisk` (open, increase, leverage raise) and in the leverage-decrease branch.
- `PendingOrderExists` is checked only in `increaseTrade` and `updateLeverage`.
- V21a runs, overdue and then in emergency with orders pending on the trades: `cancelOrder`, `closeTrade`, `reduceTrade`, `cancelTimedOut` (by a stranger), `setSlTp` (the sentinel, tightening), `flatten`, `flattenIndices`, the exit-only settle, `claim` and `requestRedeem`. All succeed; new risk is refused throughout.
- **Neither error can block an exit.**
- The one de-risking action that `EpochOverdue` does block is the leverage decrease, which adds margin to a trade. That is deliberate (it holds collateral in front of settle); a reduce or close remains available.

### 3.4 Permissionless cancelTimedOut

- A stranger's cancel of a timed-out open returns the collateral to the wei, and NAV goes back to exactly its value before the request (V22a). On the real diamond the refund is also full (`LC_LifecycleFork.test_lc_timedOutCancel_twice_andLateAnswerAfterCancel`).
- A stranger's cancel of a timed-out close leaves the trade open and moves no USDC and no NAV, on the mock (V22a) and on the fork (VF).
- Before the timeout, and for an index that is not the vault's, Gains reverts.
- **It costs the vault nothing.** The worst a stranger can do is make the manager re-send a close that had already timed out.

### 3.5 The tolerant decoder and flattenIndices

- Appended fields read exactly (V23a and the fix's tests).
- A dynamic field, or a grown PendingOrder tail, reverts (V23b, V23c).
- `flattenIndices` decodes and prices nothing (V23d).
- **A crafted layout can make NAV misread:** a field inserted before positionSizeToken passes every range check (GV-01).

### 3.6 Orders without collateral (settle does not wait for them)

**Shares:** no fill of any kind moves shares (V24a, V24b, V31a).

**NAV:**
- **A close in flight** is valued as the open trade. Its fill at the Chainlink price moves NAV by the band only, upward (+180 on 90k, V24b).
- **A leverage-only increase** steps NAV down at its fill, by Gains' fees on the added size plus the band on it:
  - mock: 640, of which 240 is fees and 400 is band, on +200k (V24a);
  - real diamond: 139.99 on +50k, of which 100 is band and about 40 is fees (VF).
  - A redemption settled while it is pending is paid at the NAV before the step. Bob, half the vault, received 49,968 instead of 49,648.
  - That is GV-06 (Info): the same as an order sent one block after the settle, bounded by one order's fees, and not repeatable for profit.
- **A pending order of a type the vault does not know** (GV-02, Low) neither holds settle nor counts in NAV. That is the real regression of the GR1-04 fix.

## 4. Item 3: the executor's two design decisions

### 4.1 Launch binding without an owner sender (GR1-22)

**The premise does not hold: the CREATE2 salt does not commit to the owner, the agent or the policy settings.**
- The vault address is CREATE2(factory, keccak256(creator, salt), the one clone init code).
- It commits to the factory, the creator (`msg.sender` of `create`) and the salt, and to nothing else.
- V30a creates two vaults, from the same creator and salt, with a different owner, manager, hosted flag, fees, risk config, operator and agent. Both land on the same address.

The binding is still sound, for three separate reasons:

| What | Committed by | Test |
|---|---|---|
| Creator | The address: only the creator can ever deploy at its predicted address, and only once. Another sender gets another address, and a second create at the same address reverts. | V30b |
| Owner and manager | The executor: `creatorMatches` requires `owner == manager == the reserving wallet` from the VaultCreated event. A vault at the predicted address with another owner or another manager is refused. So is an unreadable sender (fail closed). | vitest |
| Agent | The registrar's signature over (chainid, factory, agent, predicted vault, deadline). Another sender cannot use it. | V30b; FactoryMatrix `test_GOV_FM_sig_replayAcrossVaultsFactoriesChains` |
| Hosted flag | The executor: a hosted reservation created with `hosted = false` is bound inactive, and its key is never handed over. | vitest |
| Policy settings, fees, operator | **Nothing.** They are the creator's own choice, and the executor serves the vault with whatever was chosen. | V30a |

Replay:
- **Across factories:** another factory predicts another address (V30c), and the signature names the factory.
- **Across chains:** the predicted address does not depend on the chain. With a factory at the same address, the same creator and salt give the same vault address on another chain (V30c).
  - What ties a launch to one chain is the agent signature (chainid; refused in V30c) and the executor running one service per chainId.
  - A manual launch (no agent) is never bound to a reservation.
  - A Safe address held by someone else on another chain could create a vault at that address there, but it cannot name the agent, so nothing binds.
- **A contract-wallet creator** lands at `predicted(Safe, salt)`, although tx.origin is its signer (V30d). That is the case the change was made for.

**Verdict:** sound for binding; nobody can bind a different vault at the predicted address. But the claim "the salt proves the creator" covers the creator only; the roles come from the event and the agent from the signature.

**Recommendation (operations, not security):** the policy is unconstrained, so a hosted strategy can be served on a policy that does not suit it (for example maxLeverage 1x, or maxEpochDuration 1 h). The executor could check a hosted tenant's policy against the strategy before activating it.

### 4.2 Late fills alerted instead of booked

- **On chain nothing depends on the executor's books** (V31a). A request that Gains fills after its timeout is in NAV, in the policy's exposure (a further open over 3x is refused) and in the next settle (bob paid half the NAV including it), the moment it fills. The fill moves no shares.
- **The executor does not double** (vitest late-fill test):
  - After an unresolved order fills late, the next signal for another ticket nets against what the chain holds and sends only its own size.
  - A resume of the first signal sends nothing.
- **What stays out of sync** is the ticket book: the late-filled trade belongs to no ticket, so a later close of that ticket does not close it. That is exposure inside the policy until the manager reconciles after the alert, a strategy-tracking risk, not an accounting one.
- **Confirmed:** on-chain NAV and shares stay correct while the executor is out of sync.

## 5. Item 4: the unfixed Lows and the landing-page claim

### GR1-09 (reason holds, impact as stated)

**Impact as stated:**
- An emergency or overdue exit-only settle reverts `PriceStale` while a pair is stale, although idle USDC covers the redemption (R1PoC `test_STALESETTLE_*` and V40a).
- Exits read no price (V40b), so the guardian can flatten the stale pair, and then the flat vault settles (V40d).

**Why not fixing holds:**
- Both remedies in ROUND1 pay redeemers before the stale pair's value is known: from idle at a capped NAV, or with the pair at 0.
- One overpays the redeemers at the stayers' expense, the other underpays them.
- That is a design decision, not a small fix.

### GR1-11 (reason holds, impact as stated)

- A size floor would reintroduce the `pairMinPositionSizeUsd` rule this round removed, or block legitimate small reduces.
- The harm needs a compromised online key and gives the attacker nothing.
- The mitigation (an alarm on more than 10 ReduceRequested in 10 minutes) is in place and tested.
- It does not cover the same grinding done with close requests: GV-04.

### GR1-14 (reason holds; FIXES-R1 overstates the mitigation)

- **The deployed factory** (an earlier deployment, read on the latest Arbitrum state) curates SOL at maxAge 88,200 s (24.5 h), BTC and ETH at 2,655 s, and a sequencer grace of 3,600 s.
- **Observed rounds.** Over each feed's last 60 rounds the largest gap was:

  | Feed | Largest gap | Window covered |
  |---|---|---|
  | BTC | 1,321 s | 5.1 h |
  | ETH | 840 s | 2.3 h |
  | SOL | 1,832 s | 4.65 h |

  So in normal markets SOL updates far more often than its limit. The limit exists for the 24 h heartbeat, which is the only guarantee in calm markets. A sample of a few hours cannot show how long calm stretches get, so a 1-2 h limit could still revert SOL settles. **The reason holds.**
- **Impact as stated:** a SOL answer 23 h 59 min old prices every settle mode, the emergency and overdue exit-only settles included (V40c).
- **FIXES-R1 §3 overstates the mitigation.** It says two-sided pricing and the 1 h minimum age "shrink what a frozen price can be used for". They do so only on the deposit side. ROUND1's GR1-14 case is a redemption paid at a stale mid, and both band edges sit around that stale mid. The redemption-paying settle modes have no minimum age.

### The landing-page claim

> "If a price feed is old or the network is down, the contract waits instead of guessing."

**Not true as written.** In detail:

| Part of the claim | Holds? | Evidence |
|---|---|---|
| "the network is down" | Yes, in every settle mode. With Arbitrum's sequencer down, or back up for less than the 1 h grace, every settle (normal, redemption-only, exit-only overdue, exit-only emergency), checkRisk, accrueFees, totalAssets and a deposit request revert `SequencerDown`. The grace edge is exact to the second. | V40a, V40b, V40e |
| A feed that reverts or answers garbage | Yes: `PriceStale`, in every mode | V40a, V13a |
| "a price feed is old" | **Only if "old" means older than the curated limit:** 44 minutes for BTC and ETH, 24.5 hours for SOL. A 23 h 59 min old SOL price, or a 44 min old BTC / ETH price, prices every settle mode, emergency and overdue included. | V40c |
| "the contract waits" | For anything that prices shares. Exits do not wait (closes, reduces, flatten, flattenIndices, cancels, redemption requests, claims), because they need no price from the contract: Gains prices closes with its own oracle. With no open trade nothing is priced, so a settle runs whatever the feeds say. That is consistent with "not guessing". | V40b, V40d |

Wording that is true in every mode:

> **"Share prices come only from Chainlink. If a price is older than its limit (45 minutes for BTC and ETH, 24.5 hours for SOL), or Arbitrum's sequencer is down or restarted less than an hour ago, deposits and payouts wait instead of guessing a price. Closing positions and requesting a withdrawal never wait."**

If the page should not carry numbers: "...If a Chainlink price is past its staleness limit, or Arbitrum's sequencer is down, ...". **Do not say "old"** without the limit, because the SOL limit is a day.

## 6. Item 5: gas at 20 positions (Arbitrum fork, real diamond)

| Call at 20 positions | Gas | Headroom to 32M |
|---|---|---|
| settle pricing deposits plus a redemption (20 trades on BTC / ETH / SOL, each valued at both edges) | 13,462,609 | 18,537,391 (57%) |
| settle, redemption only (20 trades) | 8,047,073 | 23,952,927 (74%) |
| `venue()` view, both edges (20 trades) | 13,125,356 | 18,874,644 (58%) |
| flatten, 20 ETH trades in one call | 24,335,510 | 7,664,490 (23%) |
| flattenIndices, the same 20 by index | 23,925,536 | 8,074,464 (25%) |

- These match FIXES-R1 (settle with deposits 13,404,159, flatten 24,335,507) to within 0.5%. The settle here also pays a redemption.
- The figures are execution gas. The transaction's intrinsic cost and calldata add well under 0.1M for these calls (calldata of a few hundred bytes, under 1 KB for 20 indices).
- **The tightest is flatten, at 23% headroom.** It is an exit and can be split with `maxTrades`.

## 7. New findings

### GV-01 A Trade layout with a field inserted before positionSizeToken is misread silently (Info)

- **Location:** GainsNav.sol `_trade` / `_list` (the tolerant decoder).
- **Description:**
  - The decoder reads the first 14 words of each element at the stride it infers from the returndata, and range-checks each one against its v10 type.
  - A layout that inserts a small field anywhere among the first 14 positions shifts every later word by one. When the shifted values still fit their types, every check passes.
  - In the PoC a uint8 is inserted before positionSizeToken: the inserted word is read as positionSizeToken, and the real one is ignored as a trailing field.
  - The NatSpec says the decoder "never decodes silently wrong". That holds for appended fields only.
- **Impact:**
  - Vault notional reads about 0 while NAV reads right, because the value uses collateral, leverage and openPrice.
  - The leverage check then passes anything: in the PoC a 10k × 20x open on a vault already at 2.7x is accepted under a 3x policy, ending at 4.74x (47,445 bps).
  - Other insert positions misread other fields. Shifting into tradeType or collateralAmount values the trade like a resting order, wrongly.
- **Likelihood:** very low. Gains has only grown Trade by carving the trailing placeholder, after positionSizeToken. An insertion would also move Trade's storage layout, which Gains cannot do without a migration. Impact 3/5 × likelihood 1/5: Info.
- **PoC:** `VerifyRegressions.test_GV01_fieldInsertedBeforePositionSize_misreadsNotionalSilently`.
- **Fix (optional):** add semantic checks to `_trade`, each cheap:
  - for an open market trade, `positionSizeToken` within a tolerance of `collateral × leverage / openPrice` (in the token's units);
  - `collateralIndex` equal to the vault's;
  - `tradeType <= STOP`;
  - `leverage > 0` and `openPrice > 0`.
  
  Or correct the NatSpec to "fields appended after positionSizeToken".

### GV-02 A pending-order type the vault does not know neither holds settle nor counts in NAV (Low)

- **Location:** GainsNav.sol `_pendingEffect`, used by `blockingOrders` / `ordersPending` and by `snapshot`.
- **Description:**
  - The GR1-04 fix lists the order types that hold collateral (MARKET_OPEN, MARKET_PARTIAL_OPEN with collateral, UPDATE_LEVERAGE decrease) and treats every other type as holding nothing.
  - Round 1's settle waited for every pending order (fail closed). The fixed settle lets every other type through (fail open), and NAV values them at 0, as it did before.
  - A future Gains version that gives an order the vault creates a new type value would therefore be invisible to both. Gains has added order types before: PNL_WITHDRAWAL is 11.
- **Impact:**
  - Settle runs while that order holds collateral, at a NAV short by it. In the PoC, a 15k open reported as type 10 lets settle run at NAV 85k instead of about 100k, and bob, redeeming half the vault, is paid 42,500 instead of about 50,000.
  - Deposits in the same settle mint cheap.
  - The per-settle NAV bound (maxNavMoveBps) and the order's own size limit the transfer.
  - With the known type the same settle reverts `OrdersPending` (same test).
- **Likelihood:** very low; it needs a Gains upgrade that renumbers what the vault's own calls create. Impact 3/5 × likelihood 1/5. Rated Low rather than Info because it is a value path that went from failing closed to failing open.
- **PoC:** `VerifyRegressions.test_GV02_unknownOrderTypeHoldingCollateral_neitherBlocksNorCounts`.
- **Fix:** whitelist the non-holding types too (MARKET_CLOSE, MARKET_PARTIAL_CLOSE, UPDATE_LEVERAGE increase, MARKET_PARTIAL_OPEN with collateral 0), and treat any other type as blocking: `held = o.trade.collateralAmount` and counted in `blocking`. That keeps GR1-04's fix and fails closed on the unknown.

### GV-03 The sequencer rotation adopts the factory's feed at execution, with any grace period (Info)

- **Location:** GainsVaultFactory.setSequencerFeed, GainsVaultPolicy.setSequencerFeed, the vault's timelocked `setSequencerFeed()`.
- **Description:**
  - The vault owner queues `setSequencerFeed()`, which takes no arguments, and anyone may execute it after the delay.
  - It copies whatever the factory holds at execution, not what the owner reviewed when queuing.
  - The factory setter accepts any grace period.
- **Impact:** the cold factory owner (trust T6) can change the value between the queue and the execution. In V10a a feed with a 365-day grace is adopted, and every priced path then reverts `SequencerDown` for a year after the feed's last status change. That is a liveness loss for the vault: exits still work.
- **Likelihood:** needs the cold factory owner. The vault owner's remedy is to cancel the queued item in time. This is the same class as GR1-40, which was accepted.
- **Fix (optional):** take the expected feed and grace as arguments (queued and checked against the factory at execution), and bound the factory's grace (for example 1 h ≤ grace ≤ 1 day).

### GV-04 Decoy closes no longer hold settle but still cost the gov fee, and the rate alarm counts reduces only (Low)

- **Location:** GainsVaultLogic.closeTrade; server `venues/gains/reduceRate.ts` (the GR1-11 mitigation).
- **Description:**
  - After the GR1-04 fix a decoy close has no purpose for a rational manager, but a hostile manager or a compromised agent key can still send closes at a price far off the market.
  - Gains cancels each in its callback and books its gov fee on the trade.
  - The executor's alarm consumes `ReduceRequested` only (vitest), so a stream of decoy closes is never alerted.
- **Impact:** 0.212566 USDC for 5 decoys on the fork, about 0.0425 USDC each. That is ROUND1's figure: about 300 USDC an hour at 2 decoys a second, bounded by the collateral. It is the GR1-11 harm by another call.
- **Likelihood:** a hostile manager or a compromised online key, plus hours without reaction. Same as GR1-11: Low.
- **Fix:** count `CloseRequested` in the same alarm (the same consumer, a second topic).

### GV-05 Anyone can make a redemption settle wait up to an hour (Info)

- **Location:** GainsVaultLogic.settle, the minimum-age rule for settles that price deposits.
- **Description:** any depositor can queue MIN_DEPOSIT, which turns the manager's next normal settle into one that prices deposits. That settle then waits until the epoch is an hour old (V20e).
- **Impact:** a redemption the manager would settle at once is delayed by at most one hour per epoch. The age counts from the epoch start, so a later deposit does not extend it. The manager cannot cancel another depositor's request. Emergency and redemption-only settles are unaffected (V20a, V20b).
- **Likelihood:** anyone, but it matters only for vaults that settle more than hourly. The keeper settles daily.
- **Fix:** none needed. Document it with the GR1-02 behaviour change in FIXES-R1 §6.

### GV-06 A non-holding order's fill steps NAV after a settle that ran beside it (Info)

- **Location:** the GR1-04 fix (settle waits only for orders that hold collateral).
- **Description:** a leverage-only increase holds nothing, so settle runs while it is pending. Its fill then books Gains' fees on the added size and puts the band on it.
- **Impact:**
  - A redemption settled in between is paid at the NAV before the step: mock +320 for half the vault on +200k; real diamond, a step of 139.99 on +50k.
  - The fee part is a real cost the redeemer avoids. The band part comes back to the holders when the trade closes.
  - This is the same as sending the order one block after the settle: bounded by one order's fees, and not a transfer anyone can repeat for profit.
  - A close in flight steps NAV only upward, by the band (V24b).
- **Fix:** none. Recorded for completeness of item 2.

## 8. Tooling and caps

| Tool | What ran | Result | Cap |
|---|---|---|---|
| forge, full suite (baseline, merged branch) | `forge test` with the Arbitrum RPC | 94 suites, 759 / 0 / 2 skipped; `invariant_spec` 2,048 × 500 | none hit (2,556 s) |
| forge, this pass | 49 mock + 6 fork tests | all pass | none |
| Invariant campaign (new) | `invariant_noSettleLowersPerShareTrueValue`, 512 runs × 200 depth | pass, 102,400 calls. A deliberate un-fix of GR1-02 fails it in 3 calls. The first formulation failed on mock rounding and was replaced (section 3.1) | 3 h cap not reached |
| Medusa | not re-run | The merge changed nothing under `contracts/`, so the fix round's 1 h run (7,470,737 calls, 19 / 19, FIXES-R1 §8) is on identical contracts. The new invariant above targets GR1-02 directly. | none hit |
| vitest (executor) | full suite; and this pass's 7 tests | `npm test` main run **909 passed, 0 failed, 6 skipped**. Two timing tests failed once and passed when re-run alone: `dojipad-ec` batching timed out at 20 s while solc held the CPU (52 / 52 alone), and `startup.test.ts` answered /health in 8.2 s against 2 s right after the main run (2 / 2 alone, twice). Neither touches Gains code; 7 / 7 | none |

**Not covered by this pass:**
- **Executor variants** beyond the late fill. The verdicts on GR1-05/06/07 and 17-21 rest on the fix's own tests.
- **GR1-16's gas starvation on the real diamond** (mock only).
- **GR1-23, 28, 30, 31, 32, 43, 44** (no new variants).
- **Halmos** (not re-run).
