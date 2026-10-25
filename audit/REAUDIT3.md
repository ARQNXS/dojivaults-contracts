# DojiPad Vaults: fourth audit pass (round 4, uncommitted diff against `76d012c`)

Date: 2026-10-08. Scope: the uncommitted round 4 diff in `contracts/` (src, script, tests), read as full files:
`HyperVault.sol`, `VaultLogic.sol`, `VaultGovernance.sol`, `VaultMath.sol`, `VaultTypes.sol`,
`HyperVaultFactory.sol`, `HyperVaultLens.sol`, `script/Deploy.s.sol`, `script/LaunchPermit.s.sol`, the new
`test/Round4.t.sol` / `test/Round4Invariants.t.sol` and the rewritten audit tests. It also covers the late change
`_rejoinCarry` in `VaultLogic.sol` (a carried deposit rejoins the current epoch on `requestDeposit` /
`requestRedeem`). The reviewer had not seen this implementation before. Rules: no `src` edits, PoC for Medium and
above, no broadcasts, no keys, targeted forge runs only (the full invariant suite was running elsewhere).

| File | Content |
|---|---|
| `contracts/audit/REAUDIT3.md` | this report |
| `contracts/test/audit/reaudit3/Reaudit3PoC.t.sol` | 7 tests: PoCs for R3-01..R3-05 (inverted by the implementer after the fixes, section 9) and one `OK_` check of `_rejoinCarry` |
| `contracts/test/audit/reaudit3/Reaudit3FollowUp.t.sol` | 8 tests: R3-06 PoC, I3-07, question (a) bound (3), question (b) fees (3) |

Run:

```bash
cd contracts
timeout 2700 forge test --match-path "test/audit/reaudit3/Reaudit3PoC.t.sol" -vv   # 7 passed
timeout 2700 forge build --sizes
```

**Headline (updated 2026-10-08, after the fixes and the decisions in section 12): no Critical or High. One Medium
(R3-01) and seven Low (R3-02 .. R3-08), all fixed or mitigated; eight informational (I3-01 .. I3-08): I3-05 and
I3-07 fixed, I3-08 accepted, the rest documented.** R3-06 came from the fixes (section 9), R3-07 and R3-08 from the
implementer's Phase 3 runs and the decisions after STOP 3 (section 12). The carry pointer accounting, the breach
state machine, the role checks of the restricted unwind, the operator, V-04 and X-01 all hold, and `_rejoinCarry`
is sound (section 3). Judgement in section 7.

*Original headline of the first pass: one Medium (R3-01), four Low (R3-02 .. R3-05), six informational.*

## 1. Verification against the round 4 spec

| # | Item | Status | Evidence / notes |
|---|---|---|---|
| 1 | R-01 share price metrics | **Met** | `_check` (`VaultGovernance:168-209`) uses `priceAt(equity, supply)` against `dayStartSharePrice` and `peakSharePrice`; the dollar baseline adjustment is gone from settle; `_accrueFees` rescales both references on fee dilution (`VaultLogic`, after `newPrice`); `equity >= MIN_RISK_NAV` gates both metrics. Normal settle mints at `nav` rounded down and pays at `priceNav` rounded down, so a flow can only raise the price by rounding. Exit-only pays at `min(nav, checkpoint)`, which raises the price for the holders who stay: never a loss. `Round4.t.sol` R-01 tests incl. the fuzz pass. |
| 2 | Breach = derisk | **Met**, one gap (R3-03) | Reason ordered enum; `_check` escalates only (`breachReason < r`) and never touches GUARDIAN/EMERGENCY; leverage cleared by `clearLeverageBreach` (anyone, cooldown, every limit, no window, re-checks after `_check` so an escalation in the same call is not cleared); daily loss cleared by the day roll in `_check` (outside a window, not in emergency); drawdown only by `resume()` (owner, 24 h, leverage and daily within limits, peak reset, `lastResumeAt`). Only `_stop` revokes. N-04: `_derisk` and `_stop` restart `breachedAt`, `execute` rejects a clear queued at or before it, except after a second emergency (R3-03). |
| 3 | Restricted unwind | **Met** | `flatten` gates on manager / owner / guardian / sentinel / operator, then the old slippage matrix; `bridgeToEvm` = treasury, or `_platform` in emergency; `settle` = treasury or platform. Strangers and depositors revert on all three (`Round4FactoryTest`, `vStrangerUnwind` ghost). `requestRedeem` / `claim` are ungated. |
| 4 | Settle modes | **Met** | Redemption-only: `depAssets = 0`, `depIn = 0`, checkpoint bound applied (`_checkpoint(..., true)`), full payment or `InsufficientLiquidity`; carry run recorded; C-01 stays closed in that mode (`test_D4_C01_noMintAtADeflatedNav`). Exit-only unchanged, overdue only for platform roles. See section 3 for the pointer accounting. |
| 5 | Treasury operator | **Met** | `setOperator` owner only; `revokeOperator` owner / guardian / sentinel; the operator reaches only `settle`, `bridgeToCore`, `bridgeToEvm`, `moveUsd` and the breach / emergency `flatten` at the policy band (custom slippage is manager / guardian only). Not a queue / policy / fee / role / recipient caller anywhere (`test_OperatorGrantedAtLaunch_runsTheTreasuryOnly`). Set from `CreateParams.operator`. |
| 6 | Insider deposits next epoch | **Met as written, ineffective in practice** (R3-02) | Insider requests carry `epoch = currentEpoch + 1` and sit in `deferredDepositAssets` (reserved in `idleAssets`, in the cap check). Nothing stops the manager from settling the current and the next epoch in the same block. |
| 7 | V-04 | **Met** | `create` binds from an EIP-191 signature over (`"DojiPad platform agent"`, chainid, factory, agent, predicted vault, deadline), signer = registrar or owner, checks `AgentAlreadyBound` / `VaultAlreadyHasAgent`; `registerPlatformAgent` refuses a non-vault address unless the caller is the owner. Front-running the signature is useless (the predicted address is scoped to `msg.sender`). OZ `ECDSA.recover` rejects malleable signatures. Residual I3-04. |
| 8 | X-01 | **Met** | Only the treasury (and platform roles in emergency) bridge; `test_VERIFY4_X01_strangerCannotReopenTheWindow`. |
| 9 | R-02 | **Not met for EVM->Core bridges** (R3-01); bounded masking (R3-05) | `bridgeInFlight` waits for `bridgeArrived` up to `MAX_BRIDGE_WAIT_BLOCKS`; `_syncBridge` latches it. The Core->EVM signal (EVM balance net of tracked deposits / cancels / claims) is exact apart from donations. The EVM->Core signal accepts `coreEquity() >= coreAtBridge + want`, and Core equity moves with unrealised PnL. |
| 10 | Launch settings | **Met** | `openLaunch` defaults false and is never set by `Deploy.s.sol`; `maxDepositCap = 50_000e6`. Script override not bounded (I3-05). |

## 2. Sizes (EIP-170)

`forge build --sizes` (runtime bytes): `HyperVault` 16,932, `VaultLogic` 16,750, `VaultGovernance` 11,365,
`HyperVaultFactory` 10,914, `HyperVaultLens` 8,501, `VaultPolicy` 9,927. All production code is under 24,576. The
build reports "some contracts exceed the runtime size limit": these are the test handlers (`Reaudit2Handler` 53 k,
`ReauditHandler` 40 k, `VaultHandler` 33 k), not deployable artefacts. The libraries are not printed in this forge
version's table; the sizes above come from `out/*.json` `deployedBytecode`.

## 3. Carry pointer accounting (incl. `_rejoinCarry`)

Model: `pendingDepositAssets` is one shared queue. A redemption-only settle leaves it in place, stamps
`epochs[e].carriedFrom = carryOrigin` (opening the run at `e + 1` if none is open) and appends the insiders'
`deferredDepositAssets`. The next settle that is not redemption-only (normal, exit-only overdue, or emergency) takes
the whole queue as `depAssets`, writes `carryPricedIn[origin - 1] = epoch + 1` and closes the run. A request whose
epoch has `carriedFrom != 0` looks up the pricing epoch once (`claimableWithCarry`).

Checked paths (by hand and in the PoC file):

- **Normal pricing after the run:** `epochs[P].depositAssets` includes every carried deposit plus the deposits of
  `P`, so every request in the run gets `depositAssets * depositShares / depositAssets` of the same epoch, at the same
  price. Floors sum to at most `depositShares`.
- **Exit-only / emergency (partial fill or not):** `depShares = 0`, `claimableRedeemAssets += depAssets`, and the
  carried request resolves to a refund through `pe.depositShares == 0`. The redemption leg uses the request's own
  epoch `e`, never `pe`, so partial fills are unaffected.
- **Insider deferred deposits:** their request epoch is `E + 1`. If `E` is redemption-only they enter the queue and,
  when `E + 1` is redemption-only too, `E + 1` carries the same origin; if `E + 1` prices, they are priced there
  directly. Either way the lookup is right.
- **Cancel of a carried deposit:** allowed only while `carried`; it reduces `pendingDepositAssets`. A run emptied by
  cancels stays open (`carryOrigin != 0`) and is closed by the next pricing settle. Harmless.
- **Claims:** `claim` refuses a request that is only a carried deposit; `_claimIfSettled` delivers a same-epoch
  redemption and keeps the carried deposit with its pointer. One lookup, O(1) (`test_D4_carriedDepositAcrossEpochs`).
- **Origins are unique** (the first redemption-only epoch + 1), so `carryPricedIn` is never overwritten for a live run.
- **Lens** mirrors the lookup exactly (`HyperVaultLens.claimable`).

**`_rejoinCarry` (late change).** The argument holds. While a request is `carried`, its run is still open, so
`carryOrigin` equals the request's origin. Moving the request's epoch to `currentEpoch` changes nothing in the queue.
The current epoch's settle then either (a) is redemption-only, `pendingDepositAssets > 0` holds because this very
deposit is in it, and it stamps the same `carryOrigin`, or (b) prices / refunds the whole queue, this deposit included,
in the same epoch the old pointer would have resolved to. The result is identical in all three settle modes.
`test_REAUDIT3_OK_rejoinedCarryIsPricedWithItsRun`: alice's rejoined deposit is carried a second time in the same run
and is then priced at exactly bob's price per USDC, and `pendingDepositAssets` returns to 0. Side effects checked:
- A third party can trigger a rejoin with `requestDeposit` / `requestRedeem(controller = victim)`. That is harmless:
  same result, and the third party's own USDC or shares go to the victim.
- An insider whose carried request rejoins `currentEpoch` still cannot add a next-epoch deposit (`RequestPending`), as
  before.
- `cancelDepositRequest` after a rejoin goes through the `r.epoch == currentEpoch` branch and decrements the queue.
  Correct.
- `requestRedeem` is no longer gated by a carried deposit, so spec item 3 now holds even for carried controllers.

## 4. Breach state machine

Reachable states are `(breached, reason, emergency)`. Transitions verified: NONE->LEVERAGE/DAILY/DRAWDOWN
(`_derisk`), any->higher risk reason, any->GUARDIAN (`triggerBreach`, keeps EMERGENCY), any->EMERGENCY
(`triggerEmergency`), DAILY->NONE at the day roll, LEVERAGE->NONE (`clearLeverageBreach`), DRAWDOWN->NONE (`resume`),
any->NONE outside emergency (`clearBreach`: guardian, or owner via a queue made after `breachedAt`), EMERGENCY->
(emergency false, still breached EMERGENCY) on `exitEmergency`. `hardStop` (GUARDIAN or EMERGENCY reason, or
emergency) blocks `settle` (outside emergency), `setAgent`, `syncAgent`, `bridgeToCore` and `moveUsd(toPerp)`.
`checkRisk` never lowers a reason. The one gap is R3-03.

The owner's `resume` resets the peak, which changes the R-1 residual of REAUDIT (I3-01).

## 5. Findings

| ID | Sev | Title | PoC |
|---|---|---|---|
| R3-01 | **Medium** | The EVM->Core landing signal reads Core equity, which moves with PnL: a late bridge is latched as landed, the window closes with the USDC in transit, giving a false NAV drop (false breach) or a settle at an understated NAV | `test_REAUDIT3_R301_pnlLatchesAnUnlandedBridge_falseDailyLossBreach`, `test_REAUDIT3_R301_settleRunsWithUsdcUnaccounted` |
| R3-02 | Low | Insider "next epoch" pricing is defeated by two settles in the same block (no minimum epoch length) | `test_REAUDIT3_R302_insiderDeferralBypassedByBackToBackSettles` |
| R3-03 | Low | A second `triggerEmergency` after `exitEmergency` does not restart `breachedAt`: an owner clear queued between the two emergencies still executes (N-04 variant) | `test_REAUDIT3_R303_ownerClearQueuedBetweenTwoEmergenciesStillCounts` |
| R3-04 | Low | `bridgeToCore` and `moveUsd(toPerp)` stay open in a daily loss / drawdown breach: more margin for an agent the contract cannot hold to reduce only, and idle USDC drained from under the redemption-only settle | `test_REAUDIT3_R304_bridgeToCoreInDrawdownBreachStarvesRedemptions` |
| R3-05 | Low | A bridge that never lands (failed Core action) holds the window for 300 blocks instead of 10: settle blocked, and a loss of up to the bridged amount masked from `checkRisk` | `test_REAUDIT3_R305_unlandedBridgeMasksALossFor300Blocks` |
| I3-01 | Info | C-01 residual R-1 widened: daily loss auto-clears at midnight and `resume` resets the peak | analysis |
| I3-02 | Info | An insider can make a victim's controller "next epoch" with a 1 wei deposit, which blocks the victim's `requestRedeem` on that controller until cancel / settle | analysis |
| I3-03 | Info | Donations latch either landing signal (costs about the bridged amount, harmless) | analysis |
| I3-04 | Info | V-04 residual: a compromised registrar can still sign a self-held agent for an allowlisted attacker's own launch | analysis |
| I3-05 | Info | `MAX_DEPOSIT_CAP` (script) and `setMaxDepositCap` (factory) have no upper bound; the 50 k limit is a default only | `Deploy.s.sol:166,182`, `HyperVaultFactory:420` |
| I3-06 | Info | Test changes: the insider invariant now checks epoch numbers only (blind to R3-02); otherwise the rewrites follow the spec and weaken nothing beyond it | section 6 |

### R3-01 (Medium): EVM->Core landing latched by unrealised PnL

**Location.** `VaultMath.bridgeArrived:138-143` (`if ($.bridgeToCoreDir) return coreEquity() >= $.coreAtBridge +
want || coreSpotUsd() >= $.spotAtBridge + want;`), latched by `VaultLogic._syncBridge:451` (and by every `settle`,
`accrueFees`, `moveUsd`, `checkRisk`, `syncBridge`).

**Description.** R-02 requires the window to stay open until the transfer has landed, read on the destination side
"never from the vault's total (which moves with PnL)". For EVM->Core the first disjunct uses `coreEquity()` =
perp `accountValue` + spot USDC, and `accountValue` includes unrealised PnL. If Core equity rises by
`bridgeAmount - 1 USDC` from PnL while the deposit is still in transit, anyone's `syncBridge()` (or any guarded
call) latches `bridgeLanded = true`. Once the 10 base blocks have passed, `bridgeInFlight()` is false although the
USDC is on neither side. Spot is also not a clean signal on its own: the platform agent can move perp->spot
(`agentSendAsset` / class transfer), which lifts spot USDC by the same amount.

**Failure scenarios (both PoCs pass).**
1. False breach: a 100 k vault (3x, 300 k notional) bridges 6 k of idle USDC to Core. The landing is late (the R-02
   premise). A 2 % favourable move gives +6 k PnL, the window latches and closes. The move reverts. True NAV is
   106 k (100 k + 6 k in transit), but the vault reads 100 k: a 5.7 % "daily loss", a DAILY_LOSS breach, reduce only,
   and deposits carried. This is exactly the false NAV drop R-02 was meant to stop.
2. Mispriced settle: the same latch, then carol deposits 50 k and the manager settles at 106 k while the true NAV is
   112 k. After the landing carol's shares are worth about 51.9 k: about 1.9 k moved from alice and bob to carol. The
   loss is bounded by the bridged amount times the depositors' share of the new supply, and the settle passes the
   checkpoint bound because the visible NAV did not jump.

On a leveraged vault a move of a few percent equals a typical bridge size, so this needs no attacker: a late landing
plus normal volatility is enough. A depositor watching `bridgeLanded` / `lastBridgeBlock` and the Core balances (all
public) can queue a deposit right after an early latch.

**Recommendation.** For EVM->Core use a signal that PnL cannot move. The deposit goes to `SPOT_DEX`, so
`coreSpotUsd() >= spotAtBridge + want` is the right primary signal. Drop the `coreEquity()` disjunct. To keep the
agent from faking it, treat any spot increase beyond the bridged amount as suspicious, or compare
`spot + (accountValue - unrealisedPnl)`, i.e. perp `rawUsd` / margin balance excluding PnL if a precompile exposes it.
If the agent later moves landed spot to perp, the window simply runs to `MAX_BRIDGE_WAIT_BLOCKS` (R3-05 bound), which
is the safe direction. Add the PoC above, inverted, plus a test where PnL rises by more than the amount inside the
wait and the window stays open.

### R3-02 (Low): insider deferral bypassed by back-to-back settles

**Location.** `VaultLogic.requestDeposit:52-61`, `VaultLogic.settle:197` (no minimum epoch length; nothing records
when an epoch started relative to the insider's request).

**Description.** An insider request is stamped `currentEpoch + 1`. The manager (or the operator, which the manager's
owner chooses) controls settle timing and can settle epoch `E` and epoch `E + 1` in the same transaction: the second
settle passes the checkpoint bound trivially (the first one just set it). The insider deposit is priced at the same
block's NAV, so "never in the epoch whose timing and NAV the insider can influence" does not hold.

**Scenario (PoC).** 100 k vault, a 4 % dip inside every limit. The manager deposits 40 k (stamped `E + 1`), calls
`settle()` twice in one block, and after the recovery holds 41.1 k+ (about +2.9 %). The deferral bought nothing.

**Severity.** Low. N-09 already accepted that an insider can use a sybil address, and the NAV is moved by the
market or the platform agent, not by the manager. But the hard block was replaced by this rule, and the rule gives
no protection as built.

**Recommendation.** Give the next epoch real time: price insider deposits only in a settle at least
`CHECKPOINT_INTERVAL` (or a policy `minEpochDuration`) after the epoch they were requested in, e.g. store
`epochs[e].settledAt` and require `block.timestamp >= epochs[requestEpoch - 1].settledAt + MIN` before a normal
settle prices a queue that holds deferred insider assets (otherwise keep them deferred). Or enforce a minimum epoch
length for every normal settle. Then update the invariant (I3-06) to compare timestamps.

### R3-03 (Low): second emergency does not restart `breachedAt`

**Location.** `VaultGovernance.triggerEmergency:243-252` (`if ($.breachReason != BreachReason.EMERGENCY) _stop(...)`).

**Description.** `exitEmergency` leaves `breached = true, reason = EMERGENCY`. A later `triggerEmergency` sets
`emergency = true` but skips `_stop` because the reason is already EMERGENCY, so `breachedAt` keeps the first
emergency's timestamp. An owner `clearBreach` queued between the two emergencies (valid for the first) is therefore
still valid after the second: the N-04 rule ("a clear queued before the latest breach must not count") is broken.

**Scenario (PoC).** Emergency #1 at t0, guardian exits, the owner queues `clearBreach`, emergency #2 later, guardian
exits again. After the timelock the owner's clear executes and lifts the full stop the guardian left in place.

**Severity.** Low: the guardian has already ended the emergency, and the owner path is timelocked.

**Recommendation.** In `triggerEmergency`, always stamp `breachedAt = block.timestamp` when `emergency` flips from
false to true (or call `_stop` whenever `!$.emergency`). The agent revoke is a no-op when the agent is already zero.

### R3-04 (Low): margin can be added in a daily loss / drawdown breach

**Location.** `VaultLogic.bridgeToCore:396` (`if ($.hardStop()) revert`) and `VaultLogic.moveUsd:488`
(`toPerp && $.hardStop()`).

**Description.** The comment's rationale ("more margin lowers leverage") fits a LEVERAGE breach only. In a DAILY_LOSS
or DRAWDOWN breach the agent is kept, and the contract cannot hold it to reduce only (accepted trust boundary). Adding
margin increases what a misbehaving or compromised executor can lose, which makes that boundary worse on chain. It
also moves the idle USDC the redemption-only settle pays from, so the settle reverts `InsufficientLiquidity` until
someone bridges back.

**Scenario (PoC).** Drawdown breach with 10 k idle and bob redeeming; the manager bridges the 10 k to Core and moves
it to perp; the guardian's redemption-only settle reverts.

**Recommendation.** Allow `bridgeToCore` and `moveUsd(toPerp)` in a breach only when `breachReason == LEVERAGE`
(i.e. block them for `>= DAILY_LOSS`). Optionally also block `bridgeToCore` while `pendingRedeemShares` would no
longer be covered by idle.

### R3-05 (Low): an unlanded bridge holds the window 300 blocks and masks a loss up to its amount

**Location.** `VaultMath.bridgeInFlight:129-135`, `VaultGovernance._check:171-175`.

**Description.** CoreWriter actions are fire and forget. A `bridgeToEvm` whose Core action fails (e.g. no HYPE on
Core for the send, or margin consumed between the EVM check and the Core action) never lands, so the window runs to
`MAX_BRIDGE_WAIT_BLOCKS`. Inside it `_check` uses `min(snapshot, live + amount)`, and `live` still contains the
amount, so a real loss of up to `amount` reads as zero. Settle, fee accrual and `setFees` are blocked for the whole
period. Before round 4 both effects lasted 10 blocks.

**Scenario (PoC).** 50 k of a 100 k vault "bridged" home, the action fails, a 45 % loss inside the window reads 0
and no breach fires; the manager's settle reverts `BridgeInFlight`; after block 301 the loss is seen. A re-opened
window snapshots the post-loss equity, so a loss is hidden at most once, for at most 300 blocks. The bound holds.

**Severity.** Low. This is the accepted R-02 cap, but the masking bound grew 30x and is reachable by the treasury
(manager or operator), not only by chance.

**Recommendation.** Document the 300 block masking bound next to N-01b. Consider shortening the wait for the
Core->EVM direction, where the EVM signal is exact and a non-arrival after the base window means a failed action,
not a slow one. Also have the keeper check the Core HYPE balance before bridging.

### Informational

- **I3-01 C-01 residual.** REAUDIT R-1 bounded a compromised platform agent's deflation at `maxDailyLossBps` per day
  and `maxDrawdownBps` overall. Now a deflation between the two limits auto-clears at the next UTC midnight
  (`dayStartSharePrice` restarts from the deflated price), and a normal settle then mints at it. The overall bound
  also resets each time the owner `resume`s. That needs both the platform agent and the owner (or a deflation that
  stays under the drawdown limit). This is by design (spec item 2); record it in the residual-risk section and make
  sure the monitor's OTHER_DEX / foreign-spot ACT stays enabled.
- **I3-02 controller griefing.** An insider can deposit 1 wei with `controller = victim`. The victim's request is
  then stamped `currentEpoch + 1`, and `requestRedeem` for that controller reverts `RequestPending` until the
  victim cancels (getting the 1 wei) or the epoch settles. The victim can also redeem to another controller. Cheap fix:
  only allow a next-epoch stamp when `controller == msg.sender`, or let `requestRedeem` move a deferred dust deposit.
- **I3-03 donations.** Sending USDC to the vault (EVM) or to its Core spot (Core) latches the respective signal. The
  donation replaces the missing amount in NAV within the 1 USDC tolerance, so nothing is gained.
- **I3-04 V-04 residual.** The hot registrar can no longer pre-bind, but it still signs launches. Compromised, it
  can sign `(attackerAgent, attackerPredictedVault)` for an allowlisted attacker. The launcher allowlist covers it
  for now; the creator co-signature from VERIFY V-04 remains the post-launch fix.
- **I3-05 cap.** `Deploy.s.sol` reads `MAX_DEPOSIT_CAP` from the environment without a bound, and
  `setMaxDepositCap` accepts any value. Add `require(c.maxCap <= 50_000e6)` in the script for this phase.
- **I3-06 tests.** The changed audit tests replace `InsiderDeposit` reverts with "waits an epoch", "agent revoked"
  with "agent kept, reduce only" for risk breaches, and stranger unwinds with `Unauthorized`. All of these are what the
  spec requires; no assertion was dropped without a replacement that checks the new rule. One invariant
  (`ep > insiderAskedAt`) checks epoch numbers, which R3-02 shows is not time separation.

## 6. Other areas reviewed and found sound

- **Role checks on every entry point**: `setOperator`, `revokeOperator`, `resume`, `clearLeverageBreach`,
  `syncBridge`, `flatten`, `bridgeToEvm`, `settle`, `cancelOrder` (manager / sentinel), `revokeAgent`
  (owner / guardian / sentinel / factory), `unregisterPlatformAgent` (registrar cannot revoke a live agent).
- **Reentrancy**: `settle`, `requestDeposit` and `requestRedeem` are locked; the new external calls are the factory,
  the policy clone, USDC and precompiles. No callback path.
- **Rounding**: unchanged directions (mint and payout floor, per-user burn ceil, claim capped at the reserve).
- **Storage**: new fields are appended to `VaultStorage`; `dayStartEquity` -> `dayStartSharePrice` keeps its slot and
  type; `EpochResult.carriedFrom` is appended. This only works because it ships as a new implementation behind a new
  factory; existing clones are untouched.
- **Liveness**: every window ends by `MAX_BRIDGE_WAIT_BLOCKS`; a carried deposit is always cancellable; a GUARDIAN
  stop with redemptions still reaches `triggerEmergency` once overdue; emergency settles only need a listed role
  (accepted).

## 7. Readiness judgement

*Updated 2026-10-08 (first pass: "yes, with one condition: fix R3-01").*

**Ready for the capped deploy, subject to the Phase 4 verification pass (`VERIFY-ROUND3.md`).** Every Medium and Low
is fixed with an inverted PoC or a dedicated test: R3-01 (landing on spot only), R3-02 (one hour before insider
deposits are priced), R3-03, R3-04, R3-05 (cap 60 blocks, sentinel alert at 30), R3-06 (raise waits for a settle
that charged the old rate), R3-07 (lens previews follow the breach fee rule) and R3-08 (a late landing is carried as
in transit for at most 300 blocks). Question (a)'s optional hardening is applied (redemption-only settles pay at
min(live NAV, checkpoint)). I3-07 is closed by the 10 USDC minimum deposit; I3-08 is accepted. What remains is
documented: I3-01 (C-01 residual, monitor ACT must stay on), I3-02 (controller griefing, cancellable), I3-03, I3-04
(registrar signs launches; allowlist), I3-05's on-chain half (`setMaxDepositCap` unbounded, runbook), I3-06, and the
R3-01 trust boundary (the agent can fake a landing by moving perp to spot; the sentinel alerts on it). The deploy
keeps `openLaunch = false` and `maxDepositCap <= 50,000 USDC`.

## 8. Not verified

- HyperCore semantics this report depends on: whether a contract's `sendAsset` to the system address can fail
  silently (HYPE gas) and how long EVM->Core deposits can lag. R3-01 and R3-05 are shown against the mocks.
- The full invariant suites (`Round4Invariants.t.sol` and the earlier ones) were not run here, by instruction.
- Server / executor behaviour (opens refused in any breach, sentinel revoke on exposure increase) is assumed.

## 9. Fix status (re-verified by the reviewer, 2026-10-08)

All fixes are uncommitted in `contracts/`. Each was re-read in source. Both PoC files pass:
`Reaudit3PoC.t.sol` (7 tests; the implementer inverted R3-01..R3-05, and I checked every inversion asserts the
opposite of the original issue in the same scenario) and `Reaudit3FollowUp.t.sol` (8 new tests, sections 9-11). The
implementer's `Round4AuditFixesTest`, `Round4BreachFeesTest` and `test_DeployScript_RefusesACapAbove50k` pass.

| ID / change | Status | Verification and remarks |
|---|---|---|
| R3-01 (Medium) | **Fixed** | `VaultMath.bridgeArrived`: EVM->Core lands only on Core spot USDC (`coreSpotUsd() >= spotAtBridge + want`). PnL can no longer latch. The inverted PoCs show the window staying open through +6k PnL, no false breach, `settle` reverting `BridgeInFlight` until spot shows the amount, then carol priced at the true 112k. Residuals, both Info: (1) the platform agent can still fake a landing by moving perp->spot (trust boundary; the monitor should alert on agent class transfers inside a window); (2) with the cap now 60 blocks, a landing that really takes more than 60 blocks is read as missing after the cap, i.e. the R-02 false drop returns for very slow landings. That is the deliberate trade-off against R3-05 and should be documented. |
| R3-02 (Low) | **Fixed**, side effect I3-07 | `INSIDER_MIN_EPOCH_AGE = 1 h`, `insiderInQueue` set when deferred insider assets roll into the queue (both branches of `settle`) and recomputed by every settle that prices or refunds the queue. A normal settle that would price them reverts `EpochTooYoung` inside the first hour of the epoch; redemption-only and exit-only settles are never delayed. The inverted PoC: the second same-block settle reverts and the deposit is priced an hour later at the recovered NAV. The insider now has at least one hour between request and pricing (no longer zero), but the manager still picks *when* after that hour; that is the same optionality any sybil has (N-09), accepted. |
| R3-03 (Low) | **Fixed** | `triggerEmergency` always calls `_stop(EMERGENCY)`, so every trigger restarts `breachedAt`. The inverted PoC: the owner's clear queued between the two emergencies reverts `NotReady`. Side effect checked: an overdue stranger re-triggering restarts `breachedAt` again. That only invalidates an owner clear queued before the stranger's trigger, and only while the vault is overdue with redemptions waiting, which is when it should. |
| R3-04 (Low) | **Fixed** | `_lossBreach` (daily loss or drawdown, outside emergency) blocks `bridgeToCore` and `moveUsd(toPerp)`; both stay open in a leverage breach. The inverted PoC: both revert `ReduceOnlyMode` and the guardian's redemption-only settle pays bob from the idle USDC. `bridgeToEvm` and `moveUsd(toSpot)` stay open, so liquidity can always be brought home. |
| R3-05 (Low) | **Mitigated** (cap 300 -> 60 blocks) | The inverted PoC: after 61 blocks the unlanded window is gone and the 45 % loss breaches. Masking is now at most 60 blocks (about a minute on small blocks) and at most once per loss. The sentinel's 30 block alert is off-chain (Phase 3) and not verified here. |
| I3-05 | **Fixed** | `Deploy.s.sol:169` requires `0 < MAX_DEPOSIT_CAP <= 50_000e6`; `test_DeployScript_RefusesACapAbove50k`. `setMaxDepositCap` on the factory is still unbounded (owner key, runbook item). |
| Change 7: no performance fee in any breach / emergency settle | **Correct, one new issue (R3-06)** | `settle` calls `_accrueFees($, !breached && !emergency)`. Section 11 verifies the amounts. But the pending performance raise is still switched on by that same settle: **R3-06** below. |
| I3-01 .. I3-04, I3-06 | Noted | Runbook / documentation items, unchanged. |

### New findings from the fixes

| ID | Sev | Title | PoC |
|---|---|---|---|
| R3-06 | **Low** | A breach / emergency settle charges no performance fee but still switches on a scheduled raise, so gains earned under the old rate are later charged at the new one (N2-02 regression) | `test_REAUDIT3_R306_breachSettleSwitchesAPendingRaiseWithoutChargingTheOldRate` |
| I3-07 | Info | Anyone can arm the one-hour insider delay with a 1 wei deposit for `controller = manager` (or owner / fee recipient); the manager cancelling the dust does not lift it | `test_REAUDIT3_INFO_strangerArmsInsiderDelay` |
| I3-08 | Info | Performance fee on gains realised by redeemers during a breach is never charged (the deferral becomes a waiver for the exited part) | analysis |

**R3-06 (Low).** In `VaultLogic.settle`, right after `_accrueFees($, !$.breached && !$.emergency)`, the block
`if (pendingPerf != 0) { $.performanceFeeBps = pendingPerf; ... }` runs unconditionally. N2-02's rule is "the
running epoch is charged at the old rate, then the raise applies". In a breach settle the running epoch is not
charged at all, the rate switches, and the HWM stays where it was. The next normal settle therefore charges the new
rate on every gain above the old HWM, including the gains earned before the raise. PoC: +10 k above the HWM earned
at 20 %, the owner's timelocked raise to 30 % is pending, a leverage breach settle switches it, the breach is
cleared, and the next normal settle charges about 3 k instead of about 2 k. The owner cannot cause the leverage
breach, but a raise and a breach in the same epoch is an ordinary combination. **Fix:** apply
`pendingPerformanceFeeBps` only in a settle that charged the performance fee
(`if (pendingPerf != 0 && !$.breached && !$.emergency)`), so the raise waits for the first settle that crystallises
the old rate. One condition; invert the PoC.

**I3-07 (Info).** `requestDeposit` classifies a request as insider when `controller` is an insider, whatever the
sender, so anyone (carol in the PoC) can deposit 1 wei for the manager. The next settle sets `insiderInQueue`; the
manager's `cancelDepositRequest` refunds the dust but leaves the flag, and the next normal settle is refused for up to
`INSIDER_MIN_EPOCH_AGE` after the epoch started. Bound: one hour per epoch, normal settles only. Exits through
redemption-only and exit-only settles are unaffected, and a normal settle's redemptions wait at most that hour.
Acceptable. If wanted, track the insider amount in the queue (`insiderQueuedAssets`, decremented on cancel) instead
of a bool.

**I3-08 (Info).** Performance fees are deferred, not waived, for the holders who stay: the HWM does not move, so the
next normal settle charges their gains. Redeemers who exit in a breach epoch take their gains above the HWM without
the fee. That is a fee-recipient loss, never a depositor loss, and it matches the stated intent ("no performance fee
in any breach").

Sizes after the fixes: HyperVault 16,930 B, VaultLogic 17,066, VaultGovernance 11,296, HyperVaultFactory 10,914.
All under EIP-170 with at least 7.5 k to spare.

## 10. Question (a): redemption-only settle at a stale NAV

**How a redemption-only settle is priced.** `VaultLogic.settle` reads `nav = totalAssets()` live (precompiles; it
cannot run in a bridge window), calls `_checkpoint($, nav, true)` and pays
`redAssets = toAssets(redShares, nav, ...)` at that live `nav`. `VaultPolicy.nextCheckpoint(settling = true)`
reverts `StaleCheckpoint` when the checkpoint is older than `CHECKPOINT_MAX_AGE` (1 day), and `NavMoved` when
`|nav - checkpoint| > checkpoint * maxNavMoveBps` (policy, default 2,000, floor 500). Between settles, `checkRisk`
(anyone, at most once per `CHECKPOINT_INTERVAL` = 1 h) moves the checkpoint toward the live NAV by at most
`maxNavMoveBps` per step. Exit-only, by contrast, pays at `min(nav, checkpoint)`.

**A stale NAV is never paid.** The payout always uses the live reading. When the live NAV is far below the
checkpoint (a crash), the settle reverts until the hourly ratchet has walked the checkpoint down to within the band,
and then it pays the *live* NAV. In `test_REAUDIT3_QA_boundIsARateLimit_sustainedReadingAndCrash` (crash leg) a -50 %
reading reverts; four hourly checks later the settle pays bob a third of the live 60 k, never the old 120 k. So a
redeemer cannot exit at a stale higher value after a real loss. Redemptions are delayed by a few hours at most, not
overpaid.

**What the bound allows: a live reading that is above true value.** If the live NAV is momentarily above what the
vault is really worth (a mark spike on a held position, or anything else that inflates `accountValue` or spot for a
moment), a redemption-only settle pays it out:

| Case (PoC) | Checkpoint | Live NAV | Paid to bob (1/3 of the shares) | Fair (true NAV 120 k) | Taken from the holders who stay |
|---|---|---|---|---|---|
| +19 % spike, one settle (`test_REAUDIT3_QA_inflatedReadingWithinTheBoundIsPaidOut`) | 120 k | 142.8 k | 47.6 k | 40 k | ~7.6 k (alice holds ~72.4 k instead of 80 k) |
| +21 % (`test_REAUDIT3_QA_readingBeyondTheBoundReverts`) | 120 k | 145.2 k | reverts `NavMoved` | - | 0 |
| +24 % held for 2 h (`..._sustainedReadingAndCrash`) | 120 -> 144 -> 148.8 k | 148.8 k | 49.6 k after two hourly checks | 40 k | ~9.6 k |

Worst case per settle: redeemers holding fraction `f` of the supply receive up to `f * m * NAV_true` too much, with
`m = maxNavMoveBps` (20 % by default, 5 % at the policy floor). Over time the band is a rate limit, not a cap: a
reading that stays inflated is walked into the checkpoint by `m` per hour and then paid in full. A reading that stays
for hours, though, is the market's price rather than a mispricing.

**Is this new?** No. A normal settle prices redemptions at the same live `nav` under the same bound; a normal epoch
without deposits is exactly a redemption-only settle. Redemption-only mode adds no new path. Its one difference is
that no depositor buys at the same inflated price, but in a normal settle the depositors overpaying is the other side
of the same transfer, not a protection for the holders who stay. Any listed role (owner, manager, operator, sentinel,
guardian) chooses the settle moment. A manager who also redeems through a sybil can wait for a favourable spike,
exactly as in a normal settle today.

**Verdict: acceptable as is.** It is the same exposure as a normal settle, bounded per settle by `maxNavMoveBps`
(Info). Recommended cheap hardening, because the mode exists precisely when the NAV is in question: price
redemption-only exits at `min(nav, checkpointBefore)`, like exit-only. Note that `_checkpoint(..., true)` overwrites
`checkpointNav` with `nav`, so the checkpoint must be read *before* that call. With `min`, an upward reading is paid
at the lagging checkpoint (at most one hour and at most `m` behind), which favours the holders who stay; in a falling
market `min` equals the live NAV and nothing changes. The same could apply to the redemptions of a normal settle in a
leverage breach. If changed, add the +19 % PoC above, inverted (bob paid 40 k).

## 11. Question (b): fees in a breach settle

Code: `settle` calls `_accrueFees($, !$.breached && !$.emergency)`. On every call, `_accrueFees` charges
`assets * managementFeeBps * (now - lastFeeAccrual) / (BPS * YEAR)` and sets `lastFeeAccrual = now`. When
`withPerformance` is false it skips the performance fee and the HWM update. When fee shares lower the price, it
rescales `peakSharePrice` and `dayStartSharePrice` by `newPrice / price`.

| Property | Result | Evidence |
|---|---|---|
| Management fee amount in a breach settle | **Correct**: NAV x 2 %/yr x time since the last accrual, within 0.1 % | `test_REAUDIT3_QB_leverageBreachSettle_managementOnly_hwmKept_metricsUnmoved` (10 h in a leverage breach, +3 % above the HWM: the fee recipient gets exactly the management fee, not the ~600 USDC performance fee) |
| No double accrual across consecutive redemption-only settles | **Correct**: each settle charges its own interval only; `lastFeeAccrual` = the settle's timestamp | `test_REAUDIT3_QB_consecutiveRedemptionOnlySettles_noDoubleAccrual` (two drawdown-breach settles one hour apart: the second charges exactly one hour) |
| Risk references rescaled | **Correct**: daily loss and drawdown read the same before and after the breach settle (within 1 bps) | same leverage test |
| No performance fee in a leverage breach | **Correct**, HWM unchanged | same leverage test |
| No performance fee in a daily-loss / drawdown (redemption-only) settle | **Correct** (the flag removes it even after a rebound above the HWM inside the breach) | code path; `Round4BreachFeesTest` |
| No performance fee in an emergency settle | **Correct**, HWM unchanged, management dust only | `test_REAUDIT3_QB_emergencySettle_noPerformanceFee` (+10 % above the HWM, guardian's emergency settle) |
| Scheduled raise in a breach settle | **Wrong**: switched without the old-rate charge | R3-06 (section 9) |
| External `accrueFees()` / `setFees` / `lowerFees` | Unchanged: management only (`withPerformance = false`), blocked in a window | code |

Verdict: the fee rule is implemented as intended, apart from R3-06. Once the breach is over, the next normal settle
charges the performance fee on the holders' gains above the unchanged HWM. A breach therefore defers the fee and
never waives it for holders who stay (I3-08 covers those who exit).

### Addendum (implementer): R3-06 fixed

`VaultLogic.settle` switches a scheduled performance fee raise on only in a settle that charged the running epoch at
the old rate (`pendingPerf != 0 && !$.breached && !$.emergency`); a breach or emergency settle leaves the raise
pending. `test_REAUDIT3_R306_*` inverted and passing: the raise stays pending through the leverage-breach settle,
the 10k gain earned under 20% is charged ~2k at the next normal settle, and 30% applies from there on.

## 12. Decisions after STOP 3 (implementer, 2026-10-08)

| ID | Sev | Decision | Change | Test |
|---|---|---|---|---|
| R3-07 | Low | Fix (found by the Phase 3 invariant run) | `HyperVaultLens.pendingFeeShares` added the performance fee in a breach / emergency, while `settle` charges none there: `sharePriceAfterFees`, `previewDeposit` and `previewRedeem` were off by up to the fee during a breach. The lens now gates the fee like `settle` (`!breached && !emergency`). The vault's own math was right; nothing on mainnet is affected (the lens ships with the round 4 factory). | `Round4BreachFeesTest` asserts lens price and fee previews equal the settle (fails without the fix by 25,600 in share price); the failing `VaultInvariants` sequences (`share price jumped at settle`, `lens preview != settle`) replayed green |
| (a) | - | Apply the optional hardening | A redemption-only settle pays at min(live NAV, previous checkpoint), the checkpoint read before the ratchet. A NAV pushed up inside the per-settle bound is never paid out in a daily loss / drawdown breach. The lens's `previewRedeem` / `previewWithdraw` use the same min in such a breach. | `Round4Stop3DecisionsTest.test_D1_redemptionOnlyPaysAtMinOfNavAndCheckpoint`: 80k checkpoint, live 84k, the redeemer is paid at 80k and the lens preview equals the payout to the unit |
| I3-07 | Info | Fix | `MIN_DEPOSIT = 10 USDC` (VaultTypes, readable as `vault.MIN_DEPOSIT()` and `factory.MIN_DEPOSIT()`); `requestDeposit` reverts `DepositTooSmall` below it. Arming the insider delay for an insider now costs at least 10 USDC, credited to that insider. | `test_D2_minimumDeposit`, `test_D2_insiderDelayGriefingCostsTenUsdc`, `Round4FactoryTest.test_D2_factoryMinimumDeposit` |
| I3-08 | Info | Accept | Redeemers who exit in a breach epoch keep their gains above the HWM without the performance fee. A fee-recipient loss, never a depositor loss, and the stated intent ("no performance fee in any breach"). Holders who stay are charged at the next normal settle. | analysis (section 9) |
| R3-08 | Low | Fix (R3-01 residual 2) | **Yes, it could breach.** After the 60 block window `bridgeInFlight()` is false even when the transfer has not landed, so a permissionless `checkRisk` read the NAV short by the bridged amount: 50k of a 100k vault late by one block past the cap read 10,000 bps of daily loss + drawdown and breached. Fix: `bridgePending()` = in flight, or unlanded and at most `MAX_UNLANDED_BLOCKS = 300` blocks old. The risk check treats a pending transfer as in transit (`equity = min(visible + amount, equityAtBridge)`, so only the bridged amount is carried and trading losses still count), and `settle`, new bridges, `moveUsd`, fee accrual and fee changes wait for it. After 300 blocks a missing transfer counts as lost. `totalAssets()` keeps its 60 block snapshot cap (R3-05). The sentinel alerts on any pending window older than 30 blocks (it reads `bridgePending()`). | `Round4LateLandingTest.test_lateLandingIsNotALoss` (failed before the fix with `10000 != 0`), `test_D4b_aTradingLossWhileUnlandedStillBreaches`, `test_D4c_aTransferThatNeverLandsCountsAsLostAfterTheCap`, `test_D4d_noNewBridgeWhileTheLastOneIsLate` |
| R3-01 residual 1 | Info | Accept, alert | The platform agent can move perp to spot on Hyperliquid and fake an EVM->Core landing (trust boundary). The vault itself cannot move USDC between perp and spot inside a window (`moveUsd` waits), so the sentinel alerts `PERP_TO_SPOT_IN_WINDOW` when USDC moves between perp and spot (either way: perp -> spot can fake a landing, spot -> perp can hide one) while a bridge is pending. | `server/test/monitor-breach.test.ts` (decision 5) |
| I3-05 | Info | Runbook | `setMaxDepositCap` stays unbounded on chain; `docs/runbooks/relaunch-dojipad-vault.md` requires the cap at or under 50,000 USDC and a check after every factory owner action. | - |

Trade-off of R3-08, stated plainly: for up to 300 blocks (about five minutes on small blocks) a transfer that never
lands is carried at its amount, so a loss of exactly that USDC shows up to five minutes late; any other loss shows
at once, and the sentinel alerts from block 30. Before the fix, a slow but real landing breached the vault.
