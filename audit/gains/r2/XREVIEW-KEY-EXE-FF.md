# Round 2 cross-review: KEY, EXE, FF

**Internal, AI-assisted review. Not an independent audit.**

Cross-reviewer XR-KEY. My job was to attack the conclusions of KEYS.md, EXECUTOR.md and FUND-FLOW.md. Branch
`audit/gains-r2` (from 4ec6feb). I did not edit `contracts/src` or `server/src`. Where the reading was ambiguous I took
the conservative one and wrote the assumption down.

New tests:
- `contracts/test/audit/gains/r2/XReviewKey.t.sol`: mock diamond. Run in the worktree under the forge lock: **4 / 4 passed**.
- `contracts/test/audit/gains/r2/XReviewKeyForkBase.sol` and `XReviewKeySkewFork.t.sol`: Arbitrum fork with the real
  gTrade v10 diamond. The fork block comes from the `XR_FORK_BLOCK` env variable. Run in the scratch copy
  `scratchpad/XR-KEY/wt` at blocks 516,416,592 and later (results in §2).

## Verdict table

| Target | Claim under review | Verdict | Evidence |
|---|---|---|---|
| KEYS.md headline | "No single stolen key TAKES depositor USDC through the vault" | **REFUTED** (when the key holder also holds shares) | XR-01..03 move 4,990 USDC (10 % of a 50k redemption) from a redeemer to the key holder's shares (§1). GR2-KEY-01 at the live caps also pays the thief's outside account (§2). |
| KEYS.md per-key TAKE column: guardian / factory owner | protocol fee recipient, GR1-40 feed swap | **UPGRADED** | Adds: at any moment, `triggerEmergency` + exit-only `settle` at min(NAV, checkpoint) right after a dip it checkpointed (XR-01) |
| KEYS.md per-key TAKE column: owner | fee raise after the timelock; operator → thief | **UPGRADED** | (a) Live shape (owner == manager == fee recipient): `triggerEmergency` + its own exit-only settle (XR-02). (b) owner ≠ manager: `proposeConfig(maxEpochDuration = 1 h)` applies at once, so the epoch is overdue an hour later and the owner's settle is exit-only, with no emergency and the vault still running (XR-03). (c) GR2-ECON-03 at will, by tightening maxLeverage (instant) or as the manager on live; the fee goes to the owner's own fee-recipient address. |
| KEYS.md TAKE: sentinel | None | **UPGRADED** (slow route) | A loss breach (made by the market) gives a redemption-only settle at min(NAV, previous checkpoint) at a moment of its choosing. With its own full stop it reaches the exit-only path after the epoch runs overdue (≥ 1 day). XR-04. |
| KEYS.md TAKE: operator | None | **UPGRADED** (conditional) | It settles redemption-only in a market-made loss breach (ECON-02), and normal settles in a GR2-GNS-01 TP window. A confederate gains only through market events. Its reduces move no value. |
| KEYS.md TAKE: manager / agent | Indirect skew only | **UPGRADED** | GR2-KEY-01 is profitable at the live caps (§2). The manager can also time a settle in a GNS-01 window and, as the manager, create ECON-03. |
| GR2-KEY-01 (Low, design) | Opposite account net negative at the live caps | **UPGRADED to High (conditional theft; not live-exploitable today)** | ETH fork, 1M vault at the live caps (V = 5M), A = 5M: opposite account **+5,036 USDC per round trip**, vault extra loss 9,038. SOL: measured −232 at V = A = 1.5M, right at the predicted break-even (1.47M); above it the SOL PnL could not be measured (§2). §2 |
| GR2-KEY-02 / -03 | sound | CONFIRMED | not re-run; source read (TP: `updateTradeTp` has no distance check; see §3) |
| GR2-KEY-04 / -05 | Low | CONFIRMED. Correction to the manager row: on the live vault, owner == manager is **exempt** from the reduce-rate alarm | `wire.ts:541` exitActors = guardian, owner |
| KEYS.md DESTROY / stop: owner | "Policy tightening into a breach"; stop = guardian cancel / revokeOperator | **CORRECTED** | Nobody but the owner can undo a tightened policy (loosening is owner-only and timelocked). maxDrawdownBps = 1 keeps a vault in a permanent loss breach: redemption-only settles at min(NAV, cp) and a deposit queue that is carried and never priced. A guardian `clearBreach` lasts until the next permissionless `checkRisk`. |
| KEYS.md DESTROY / stop: sentinel | triggerBreach + flatten crystallises a loss; stop = setSentinel | **CONFIRMED + liveness added** | Each `triggerBreach` restarts `breachedAt`, which voids every owner-queued `clearBreach` (N-04) and makes every settle revert `ReduceOnlyMode`. Exits resume only through overdue → anyone's `triggerEmergency` → exit-only. XR-04 |
| KEYS.md guardian `exitEmergency` | — | sound | Refused while redemptions are pending or after a partial fill. After XR-01 the guardian can end the emergency cleanly (asserted). |
| GR2-ECON-02 / GR2-ECON-03 / GR2-GNS-01 as KEY routes | — | ECON-02 **CONFIRMED and reachable at will** (XR-01..03). ECON-03 CONFIRMED: a TAKE for the live owner key. GNS-01 CONFIRMED as a manager / operator route; it stays Low (needs a market spike) | §1 |
| GR2-EXE-01 (Low) | 7702 batching evades the reduce-rate alarm | **CONFIRMED** (live 7702 check below); **moot for the agent**, which can churn opens and closes that no alarm counts (KEY-05); matters for the operator | `cast`: arbOSVersion 116; a type-4 estimate is accepted |
| GR2-EXE-07 (Low) | the requeue resets the new owner's claim; a late open | **CONFIRMED**, impact claim holds | re-run 2 / 2 pass; the orphan-open case is closed by `ticketSignalSeen` |
| FUND-FLOW.md conclusion | no Critical / High / Medium / Low in fund flow | **CONFIRMED for the fund-flow paths**. The value transfers found here are pricing and timing, not paths | §4 |
| GR2-FF-01 (Info) | a stranger's deposit for an insider blocks its redeem | **CONFIRMED** Info | source |

**New finding ids** (domain KEY, filed by the cross-review): **GR2-KEY-06** = the exit-only price is reachable at will
(§1). The GR2-KEY-01 severity change is §2.

## 1. GR2-KEY-06 (Medium): guardian, owner and sentinel keys reach the min(NAV, checkpoint) price whenever they choose; a key holder who also holds shares takes the redeemers' rebound

**What ECON-02 already says.** Exit-only and redemption-only settles pay min(NAV, checkpoint). The checkpoint can be
fixed at a dip (`checkRisk` is permissionless) and then no one can move it for `CHECKPOINT_INTERVAL` (1 h). ECON-02
framed the reach as "a loss breach, or the owner once the epoch is overdue (1 day), or an emergency".

**What is new.** For three keys the precondition costs one transaction, so the price is available at will:

| Key | Route at will | Test |
|---|---|---|
| Guardian (= factory owner on live, every vault) | `checkRisk` at a dip → wait for the rebound (< 1 h) → `triggerEmergency()` (allowed at any time) → `settle()` (guardian: exit-only) → `exitEmergency()` (allowed: nothing pending, paid in full). The vault ends normal, with only events left behind. | `test_GR2_XR_01_guardianKeyAlone_emergencyExitOnlyAtTheDip_movesRedeemerValueToThief` |
| Owner, live shape (owner == manager) | `checkRisk` at the dip → `triggerEmergency()` → `settle()` (manager in emergency: exit-only). One shot: only the guardian ends the emergency. | `test_GR2_XR_02_ownerEqualsManagerKey_triggerEmergencyExitOnlyAtTheDip` |
| Owner ≠ manager | `policy.proposeConfig(maxEpochDuration = 1 hours)` is a tightening and applies at once (GainsVaultPolicy.sol:329-341, `_isTighter`). An hour after the last settle the epoch is overdue, so the owner's settle is exit-only (GainsVaultLogic.sol:228-229). No emergency, no guardian; repeatable every hour. | `test_GR2_XR_03_ownerKey_instantEpochTightening_exitOnlyWithoutEmergency` |
| Owner (either) | `maxDailyLossBps = 1` (instant) turns any dip into a DAILY_LOSS breach, so every settle is redemption-only at min(NAV, previous checkpoint). | source (same price rule as ECON-02's first PoC) |
| Sentinel | In a market-made loss breach: a redemption-only settle at its own moment (ECON-02's first PoC lists the sentinel as an allowed settler). On its own initiative: `triggerBreach` (full stop) → the epoch runs overdue (≥ 1 day; nobody can settle) → anyone's `triggerEmergency` → exit-only at its moment. Its re-triggers void the owner's queued `clearBreach`. | `test_GR2_XR_04_sentinelKey_retriggerVoidsOwnerClearAndForcesTheExitOnlyPath` |

**Numbers (all three key tests, identical market path).** 100k vault: thief 50k, victim 50k. The manager, acting
honestly, holds a 4x ETH long. The victim has queued a full exit. ETH falls 2.5 % (NAV −10 %, no breach), the key
checkpoints, and ETH recovers fully within 40 minutes.

| | victim paid | thief's 50k stake worth |
|---|---|---|
| attack settle (exit-only at the dip checkpoint) | 44,610 USDC | 54,590 USDC |
| control (the treasury's normal settle at the same moment) | 49,600 USDC | 49,600 USDC |
| **moved** | **−4,990** | **+4,990** |

Scaling:
- The take is (rebound since the checkpoint) × vault leverage × the victims' queued redemptions × the thief's share of
  the holders who stay.
- At the live 5x, a 1 % intra-hour dip-and-rebound on ETH (a common move) is 5 % of every queued redemption.
- Exit-only has no NavMoved bound, so the gap is limited only by how far NAV has risen above the checkpoint.

**Severity: Medium.**
- Same rule as ECON-02: a bounded loss, conditional on a dip-and-rebound and queued redemptions.
- It needs the guardian key (cold), the owner key, or the sentinel key (hot, slow route) plus shares bought in advance.
- Not live-exploitable today: the vault has 0 shares and a 101 USDC cap.
- It refutes the KEYS.md headline.

**Fix direction** (in addition to ECON-02's options):
- Price exit-only settles at min(NAV, checkpoint) only when the checkpoint is fresher than CHECKPOINT_INTERVAL, or let
  `checkRisk` ratchet upward immediately.
- Make `maxEpochDuration` timelocked in both directions, or floor it at 1 day. Shortening it is not a safety
  tightening; it changes who may settle and at what price.
- Treat `maxDailyLossBps` / `maxDrawdownBps` tightening below the current loss the same way: timelocked.
- Executor: alert on EmergencyTriggered, on a ConfigApplied that shortens the epoch, and on any `checkRisk` sent by a
  role key outside the keeper.

## 2. GR2-KEY-01 upgraded: at the live caps the opposite account profits

**Model.** KEYS.md's own formula, V·A/(200·depth), is linear in both V and A. Over its round trip the opposite account's
own skew impact cancels: it opens against skew (k0+V) and closes against skew (k0−A), so its net impact is exactly
+V·A/(200·D). Its cost is linear in A. It therefore profits once V > cost-rate × 200·D.

**Break-even from KEYS.md's numbers.** On SOL the opposite account's cost was 1,855.95 + 329.50 = 2,185 USDC on 1.25M
(17.5 bps), and the capture was 96.7 % of the term. So V* = 0.001748 × 200 × 4.07M / 0.967 ≈ **1.47M of SOL**.

**Reachability.** The policy limits notional only by 5 × NAV, 250k per order and 20 positions, with no per-pair limit.
V* is reachable from a ~300k vault on SOL.

**Fork measurements** (XR_FORK_BLOCK = 516,416,592 and later; real diamond; all fills at one oracle price; vault 25x
per trade, opposite account 50x):

| Pair | V (vault) | A (opposite) | Vault NAV | Term | Extra vault loss | Opposite account PnL | Test |
|---|---|---|---|---|---|---|---|
| SOL (depth 4.10M) | 1.5M | 1.5M | 355k | 2,743 / 2,747 | 2,729 / 2,732 | **−235 / −232** (just below break-even, as predicted) | `test_GR2_XR_05_skewNearBreakEven_SOL_V1_5M` |
| ETH (depth 13.8M) | 5M (20 × 250k) | 5M (4 × 1.25M) | 1.047M | 9,047 / 9,054 | 9,038 / 9,045 | **+5,036 / +5,043** (two blocks) | `test_GR2_XR_08_skewOppositeProfits_ETH_V5M_A5M` |
| SOL | 2M / 3M | 2M / 3M | 452k / 644k | 4,883 / 10,986 | 4,703 / 10,334 (96 % / 94 %) | **not measured**: Gains did not execute the opposite account's 1M SOL closes on this block, and its PnL read exactly −collateral with the trades still open | `test_GR2_XR_06_skewExtraVaultLoss_SOL_V2M_A2M`, `test_GR2_XR_07_skewExtraVaultLoss_SOL_V3M_A3M` (vault side only) |
| SOL | 5M | — | 1M | the vault's own SOL opens were not executed by Gains (no MarketExecuted log; a Gains OI / exposure limit on this block). Not a vault limit. | | | run 1 |

**Per-cycle economics, ETH at the live caps (1M vault).**
- The vault loses 13,035 USDC per round trip (1.25 % of NAV): 3,997 own cost plus 9,038 routed.
- The opposite account keeps +5,036 (39 % of the vault's loss) on about 100k of its own collateral.
- `openTrade` never calls `checkRisk` (GR2-KEY-04), so cycles run until the keeper's next `checkRisk` sets the 15 %
  daily-loss breach: about 11-12 cycles, **~55-60k USDC to the thief per day**.
- The daily breach clears the next UTC day and the agent is not revoked by a risk breach. Repeated until the 50 %
  drawdown: about 38 cycles, **~190k USDC** stolen from a 1M vault, unless a human revokes the agent first. KEY-05:
  nothing alerts on the trades.

**Severity: High** (a conditional theft by an online key). Assumption, conservative reading of the scale: "theft" by an online key
is High, even though it is bounded by the drawdown breaker.

**Not live-exploitable today**, so no ALERT: the live vault has a 101 USDC cap and 0 shares, and the break-even needs a
vault of roughly 300k (SOL) / 440k (ETH: cost 8 bps → V* ≈ 2.2M) or more. **It must be fixed or mitigated before any
Gains vault is allowed above ~250k NAV.**

**Fix.**
- A policy cap on vault notional per pair as a fraction of `getPairSkewDepth`. At A = V the opposite account profits
  when V/(200·D) exceeds about 8-17.5 bps, so a cap of V ≤ 0.02·D per pair keeps the edge below about 1 bp.
- Or call a cheap risk check inside `openTrade` / `increaseTrade`, so churn stops at the breaker rather than at keeper
  latency.
- Executor: alarm on TradeRequested count per caller, and on vault notional vs skew depth (KEY-05).

**Caveats.**
- One block; one oracle price per cycle (no price drift).
- Gains limits bound V per pair. They allowed ETH 5M; the vault's SOL 5M opens were not executed. SOL 2M / 3M opens executed, but the opposite account's 1M closes did not, so SOL profit above the break-even is extrapolated, not measured.
- Funding and holding fees over the minutes of a cycle are not included. They are included where blocks were rolled.

## 3. EXE

**GR2-EXE-01: CONFIRMED.** EIP-7702 is live and usable on Arbitrum One:
- `cast call 0x…64 "arbOSVersion()"` = **116** (ArbOS 61; 7702 shipped in ArbOS 40).
- A fresh throwaway EOA signed a 7702 authorization delegating to Multicall3, and `eth_estimateGas` for a type-4 call to
  itself was **accepted: 46,572 gas** (21,356 without the authorization: +25,000 PER_EMPTY_ACCOUNT_COST plus the
  delegated code).
- No transaction was sent. (`eth_call` on the public node returned `0x` with the authorization list, so code execution is
  shown by gas accounting, not by a return value.)

The contract allows a batched multi-reduce: `reduceTrade` has no EOA / `tx.origin` / per-block check (grep: none in
`src/gains`). Gains allows one pending order per trade, so at most 20 reduces per transaction.

Re-assessment:
- For the **agent** the alarm evasion adds nothing. A thief with the agent key churns opens and closes that no alarm
  counts (KEY-05), and §2 shows that churn pays.
- For the **operator** (an EOA keeper wallet, also 7702-capable) the finding stands: 20 reduces per transaction while
  `redemptionShortfall() > 0`, each up to the full cap (EXE-04).
- **Low, CONFIRMED.**
- Correction for KEYS.md's manager row: the alarm exempts the owner (`wire.ts:541`), and on the live vault the manager
  is the owner, so **no** reduce or close by the live manager is counted.

**GR2-EXE-07: CONFIRMED.**
- `EXE_SignalRace.test.ts` re-run: **2 / 2 passed** (vitest, `contracts/test/audit/gains/r2/executor/vitest.config.mjs`).
- I looked for a worse case: an orphan open after the strategy's close was refused. It does not happen. A re-run of
  the open, after the close signal of the same ticket was stored, is refused by `ticketSignalSeen`
  (db/mongo.ts:441-442, `type: {$ne: type}`; processor.ts:467).
- Impact stays "a late open within policy". Low.
- Nit: the test header calls it GR2-EXE-08.

## 4. FF spot checks (both sound)

- **Allowance on every path.**
  - The only `forceApprove` is `_approve` (GainsVaultLogic.sol:782).
  - It is reached from `openTrade`, `increaseTrade` (only when collateral > 0) and the lower-leverage `updateLeverage`.
    Each is followed in the same function by `_clearApproval`, with no try / catch around those diamond calls.
  - `flatten`, `flattenIndices` and `_cancelResting` (the try / catch paths) never approve.
  - Sound.
- **`cancelDepositRequest` refund recipient.**
  - The request is read and paid as `requests[msg.sender]`: the controller, never the payer (L:106-124).
  - A deferred insider request resets its epoch (GR1-32).
  - A carried request reduces `pendingDepositAssets`, where the carried USDC is held.
  - Sound.
- **Claim clamping on partial fills.**
  - `claimableWithCarry` floors each user's assets (`s × redeemAssets / redeemShares`) and ceils each user's burned
    shares, so Σ returned shares ≤ redShares − burned and Σ assets ≤ paid.
  - The `assets > claimableRedeemAssets` clamp (L:163) is a guard that the rounding never reaches.
  - Sound.
- **GR2-FF-01** reproduced by reading: `_isInsider(controller)` defers the request; `requestRedeem` reverts while
  `r.epoch > currentEpoch`. Info, CONFIRMED.
- **FF's conclusion stands for paths.** No new path moves USDC to a wrong recipient. The transfers in §1 / §2 go through
  correct paths at a price or a counterparty the key holder chooses. That is outside FF's path table, which is why FF
  did not see them.

## 5. Open questions
- GR2-KEY-01 with price drift between fills, funding, and a cycle spread over minutes: not measured. Gains OI caps per
  pair set the real ceiling (SOL 5M refused on this block).
- Whether the keeper's checkRisk would fire inside a churn burst: read, not tested. KEYS.md says it sends only near a
  limit.
- `eth_call` with an authorization list returned `0x` on the public node. Execution is inferred from estimateGas.

## 6. Runs
- `forge test --match-path test/audit/gains/r2/XReviewKey.t.sol` (worktree, forge lock): 4 passed. The build took 331 s.
- Fork, scratch copy `scratchpad/XR-KEY/wt` (src identical to the worktree):
  - run 1 (block 516,416,592): XR_05 and XR_08 passed; the SOL 5M variants failed (Gains did not execute the vault's opens; those variants were replaced).
  - run 2 (block 516,418,885): XR_05 and XR_08 passed; XR_06 / XR_07 failed their opposite-account assertion because the opposite account's closes were not executed. The assertion was removed (vault side only).
  - run 3 (block 516,420,853): **4 / 4 passed**. XR_05 opposite account −229; XR_08 opposite account **+5,048** USDC.
- vitest `EXE_SignalRace`: 2 passed.
- No heavy tool was run. The heavy lock was held by MUT throughout. The fork tests were single tests in a scratch copy;
  no campaign was run.
