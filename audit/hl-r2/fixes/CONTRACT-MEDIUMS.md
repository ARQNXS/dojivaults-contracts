# hl-r2 fixes, sub-reviewer B: the contract-side Mediums

Internal, AI-assisted security review (hl-r2). It is not an independent audit. Branch `audit/hl-r2-fixB` (from
`audit/hl-r2` 154856b). Nothing here was deployed, sent, or pushed; `contracts/src` and `server/src` on this branch are
unchanged. Each fix is a patch against `contracts/src` at origin/main 4ec6feb (identical to this branch's `src`), proven
in a throwaway worktree by `fixes/verify-B.sh` (assumption A4).

| ID | Fix in one line | Patch | Existing tests changed |
|---|---|---|---|
| HLR2-E01 (+ XB01) | An exit-only settle never pays at a checkpoint that trails the NAV and could still be walked up: it waits for the (permissionless, hourly) walk instead | `patches/HLR2-E01.patch` | none |
| HLR2-E06 | A full stop the vault owner imposes alone settles redemption-only; only a guardian or sentinel stop freezes every settle | `patches/HLR2-E06.patch` | none |
| HLR2-H04 | In emergency only the guardian and the sentinel may bridge to EVM; no owner-chosen address (manager, owner, operator) can hold a bridge window open | `patches/HLR2-H04.patch` | `patches/HLR2-H04.tests.patch` (2 Round4 helpers + 1 Round4 test, 1 AuditPoC expectation, Reaudit2Handler bridger) |
| HLO-07 | A factory vault launched with an agent is inert for 24 h: no deposit, no HyperCore approval of the agent; the guardian or sentinel vetoes with the existing `unregisterPlatformAgent` | `patches/HLO-07.patch` | `patches/HLO-07.tests.patch` (7 helpers / setUps: wait out the 24 h) |
| HLR2-XA01 | A guardian / sentinel / factory revoke of a live agent puts the vault on deposit hold: deposits closed, every settle redemption-only, until the guardian clears | `patches/HLR2-XA01.patch` | none |
| all five | stacked | `patches/COMBINED-B.patch` + `COMBINED-B.tests.patch` | union of the above |

Fix tests: `fixes/tests/<ID>.fix.t.sol` (copied to `test/audit/hl-r2/fixes/` in the throwaway). Logs:
`fixes/results/<ID>.log`. Results summary in section 7.

Common facts for every patch:
- New storage fields are appended at the end of `VaultStorage` (fresh deploys only; the vault is a clone, nothing is
  upgraded in place). Each patch appends its own field, so stacking two patches is a textual merge on the same lines
  (`COMBINED-B.patch` is that merge, verified on its own).
- Size after `COMBINED-B`: well inside EIP-170 (unpatched HyperVault 17,156 B, VaultLogic 17,379 B; the patches add a
  few hundred bytes; the build reports no src contract above the limit, only test handlers as before).

---

## 1. HLR2-E01 (+ HLR2-XB01, merged): exit pricing at an unbounded-age checkpoint

**One-liner.** An exit-only settle pays at min(NAV, checkpoint) only while the checkpoint is current; if the
checkpoint trails the NAV and checkRisk could still move it, the settle reverts `CheckpointBehind` until anyone walks it.

**Two options considered (design decision).**
- A. "Walked checkpoint" (ECONOMICS.md sketch): price at min(NAV, cp * (1 + m)^k), k = hours since the checkpoint.
  Never blocks an exit. But it pays a one-block spike up to cp * (1 + m)^k: after 20 h at m = 20% that is any spike at
  all. In emergency the settler can be the hostile manager / owner, so A moves the E01 loss from the redeemers to the
  stayers (a manipulated mark in the settle block is paid out). Rejected as the less conservative option.
- B (implemented). "Converged checkpoint": the min() may only withhold a rise younger than one checkpoint interval
  (a spike). If cp < NAV and either the checkpoint is at least `EXIT_CHECKPOINT_FRESH` (1 h, = `CHECKPOINT_INTERVAL`)
  old or its last ratchet step was capped (`checkpointLagging`), the exit-only settle reverts. Anyone (the redeemer
  included) calls `checkRisk`, which walks the checkpoint one capped step per hour; once a step reaches the NAV the
  settle pays the walked price. Nobody can pay at a stale checkpoint and nobody can pay a fresh spike. Cost: liveness,
  bounded and permissionless (below).

**Diff** (`patches/HLR2-E01.patch`, summary):
```solidity
// VaultTypes.sol
uint256 constant EXIT_CHECKPOINT_FRESH = 1 hours;           // = VaultPolicy.CHECKPOINT_INTERVAL
struct VaultStorage { ...; bool checkpointLagging; }         // last checkRisk step was capped below the NAV
error CheckpointBehind(uint256 checkpoint, uint256 nav);
// VaultLogic.settle, exit-only branch (was: if (cp > 0 && cp < nav) priceNav = cp;)
uint256 cp = $.checkpointNav;
if (cp > 0 && cp < nav) {
    if ($.checkpointLagging || block.timestamp >= uint256($.checkpointAt) + EXIT_CHECKPOINT_FRESH) {
        revert E.CheckpointBehind(cp, nav);
    }
    priceNav = cp;
}
// VaultLogic._checkpoint: after a ratchet update, `if (next < nav) $.checkpointLagging = true;`
// VaultLogic._setCheckpoint: `$.checkpointLagging = false;`
// HyperVault: `checkpointLagging()` view
```
Redemption-only and normal settles are unchanged (they already require a checkpoint younger than 1 day and a NAV
within `maxNavMoveBps`).

**Fix tests** (`tests/HLR2-E01.fix.t.sol`, contract `HLR2_E01_Fix`, standalone Base vault, fees off):
- `test_HLR2_E01_fix_ownerEmergencySettleWaitsForTheWalkAndPaysFair`: E01a inverted. Owner emergency + same-block
  settle reverts `CheckpointBehind(200k, 260k)`; after one stranger `checkRisk` (cp 240k, lagging) it still reverts;
  an hour later alice's own `checkRisk` reaches 260k and the settle pays her 130,000 (fair); mallory keeps 130,000.
- `test_HLR2_E01_fix_overdueExitOnlyWaitsForTheWalk`: E01b inverted (7-day overdue exit-only by the owner).
- `test_HLR2_XB01_fix_epochTighteningNoLongerOpensTheStalePrice`: XB01 inverted (pricing half). Written to pass with or
  without fixA's deadline snapshot: the owner's settle reverts `CheckpointBehind` (no snapshot) or `Unauthorized`
  (snapshot); after the walk alice is paid fair.
- `test_HLR2_E01_fix_soleHolderExitLeavesNoOrphanedGain`: E01d / E01e inverted: alice is paid the whole 130k, supply 0,
  NAV left < 1 USDC (no gift to the fee dust or the next first depositor).
- `test_HLR2_E01_fix_freshSpikeIsStillWithheld`: the protection the min() exists for is kept: a +25% one-block spike
  over a fresh, uncapped checkpoint is not paid out.
- `test_HLR2_E01_fix_lossIsPaidAtOnce`: NAV below the checkpoint pays at once at the NAV.
- `test_HLR2_E01_fix_livenessAtTheNavMoveFloor`: at `maxNavMoveBps` = 5% (the policy floor) a +30% gap takes exactly 6
  hourly steps, then the exit pays fair.

Original PoCs, expected to fail with the patch: `test_HLR2_E01a..e`, `test_HLR2_XB01_...` (all revert
`CheckpointBehind`). `test_XB_E01c_anyoneWalksTheCheckpointUpInAnHonestEmergency` keeps passing (it is the walk).

**Liveness bound.** A gap NAV / cp = g needs ceil(ln g / ln(1 + m)) hourly `checkRisk` calls: at m = 20% (the platform vault) a +30%
gap is 2 steps (one hour), +100% is 4 steps (3 h); at the 5% floor +30% is 6 steps (5 h), +100% 15 steps (14 h).
`checkRisk` is permissionless and needs no role, so no party can prevent the walk. A hostile owner can lower
`maxNavMoveBps` only through the policy timelock (a lowering is a loosening, N-03), not below 5%.

**Residual risk.**
- Up to one hour of gain can still be withheld: a checkpoint set by an uncapped step (or a settle) inside the last hour
  plus a rise after it. That is the spike rule, by design.
- A checkpoint set during a one-block dip (manipulated mark at the `checkRisk` moment) is "fresh and uncapped" for an
  hour; the withheld amount is bounded by the dip the attacker paid to create and lasts at most one hour.
- Redemption-only settles (loss breach) still pay at min(NAV, cp_before) with cp_before up to 1 day old and the gap at
  most `maxNavMoveBps`; that is the REAUDIT3 "question a" decision and is unchanged here. The same convergence rule could
  be applied there; it would weaken "a recovery after a loss is never paid out" to "never within the hour", so it is
  left to the lead.
- The exit now depends on someone calling `checkRisk` hourly while the gap closes. Executor half (not in this branch):
  the keeper must keep sending `checkRisk` in emergency / overdue / full stop (today `risk/contractRisk.ts:253-254` skips
  it), and on a `CheckpointBehind` revert of a settle it sends `checkRisk` and retries after `EXIT_CHECKPOINT_FRESH`.
  The redeemer can do the same from any wallet.

**Documented behaviour changed.** `webapp/src/docs/depositors.tsx:249` ("Redemptions are priced at the lower of the
live value and the last checkpoint") and REAUDIT/round 4 natspec "The NAV bound never blocks an exit" (VaultLogic.sol
settle docstring): an exit now waits until the checkpoint has caught up with the value (hours, anyone can drive it), then
pays at the lower of the live value and a checkpoint at most an hour old. Docs need that sentence.

**Overlap with fixA's epoch-deadline snapshot.** Touches `settle` (exit-only pricing branch only, after the mode
selection). Does not touch `epochOverdue` or `triggerEmergency`. Stacks with a deadline snapshot by text merge; the
XB01 fix test is written to pass with either.

---

## 2. HLR2-E06: an owner-caused full stop freezes every exit until overdue

**One-liner.** A full stop the vault owner imposes alone no longer freezes settles: any listed role settles it
redemption-only (pays redemptions at min(NAV, checkpoint) within the checkpoint bound, mints nothing, carries the
deposit queue). A stop imposed or re-imposed by the guardian or the sentinel still freezes every settle as before.

**Options considered.** (a) Drop the owner from `triggerBreach` entirely. Smaller, but removes the owner's
legitimate "revoke the agent and go reduce only now" lever (e.g. a leaked manager key) and does nothing for the stop
already imposed. (b, implemented) keep the owner's stop (reduce only, agent revoked, deposits closed) but take away its
power to freeze exits. Both keep the guardian's real full stop. The sentinel's stop also keeps freezing (an online key's
stop is a platform incident response; the guardian clears; K04 already accepts a sentinel DoS) — more conservative than
relaxing it, because a sentinel stop usually follows a suspected NAV manipulation where paying redemptions at the
reading would hurt the redeemers.

**Diff** (`patches/HLR2-E06.patch`, summary):
```solidity
// VaultTypes.sol: struct VaultStorage { ...; bool platformHold; }
// VaultGovernance.triggerBreach, after _stop(...):
if (msg.sender == guardian || msg.sender == sentinel) $.platformHold = true;   // never downgraded by the owner
// VaultGovernance._clear: $.platformHold = false;
// VaultLogic.settle (was: if ($.hardStop() && !$.emergency) revert E.ReduceOnlyMode(); bool redemptionOnly = _lossBreach($);)
bool ownerStop = $.hardStop() && !$.emergency;
if (ownerStop && ($.platformHold || $.breachReason != BreachReason.GUARDIAN)) revert E.ReduceOnlyMode();
bool redemptionOnly = _lossBreach($) || ownerStop;
// HyperVaultLens._postFeeRedeem: also clamps to the checkpoint for (r == 4 && !platformHold)
// HyperVault: platformHold() view
```
A stop left behind by an emergency the guardian ended without clearing (reason EMERGENCY, not in emergency) still
freezes, as before.

**Fix tests** (`tests/HLR2-E06.fix.t.sol`):
- `HLR2_E06_Fix.test_HLR2_E06_fix_ownerStopSettlesRedemptionOnlyAtOnce`: E06 inverted. Owner `triggerBreach` +
  operator removed; the guardian settles in the same block, alice is paid, bob's deposit is carried (not minted), only
  burns; a stranger still cannot settle.
- `..._guardianStopStillFreezesEverySettle`: manager, owner, guardian all revert `ReduceOnlyMode`.
- `..._holdOnlyEscalates`: owner, guardian, owner again: the hold stays; the guardian's clear removes it.
- `..._ownerStopStillStopsRisk`: agent revoked, deposits closed.
- `HLR2_E06_FixFactory.test_HLR2_E06_fix_sentinelStopHoldsOwnerStopDoesNot`: factory vault (sentinel is a separate key):
  sentinel stop freezes the keeper; after the guardian clears, the owner's stop lets the guardian settle and pays 25k.

Original PoC expected to fail: `test_HLR2_E06_fullStopBlocksAllExitsUntilOverdue` (the guardian's settle no longer
reverts). `test_HLR2_E06b_ownerLengthensTheWaitTo30Days` keeps passing: it is merged into H01 leg C (fixA, deadline
snapshot) and only asserts `triggerEmergency` timing, which this patch does not change. The XA01 control test
(`test_HLR2_XA01_control_triggerBreachBlocksTheSettle`, sentinel stop) keeps passing.

**Residual risk.** Under an owner stop the manager (often = owner) can still settle redemption-only; that is the safe
mode (no mint). A hostile manager can still delay those settles with bridge windows outside emergency (H04 is fixed
in emergency only); the guardian's `triggerEmergency` turns that into the H04-fixed path. A sentinel or guardian stop
still freezes up to `maxEpochDuration` if nobody clears it (accepted K04 / L01).

**Documented behaviour changed.** `depositors.tsx:231` and `security.tsx:201` ("A breach triggered by the owner,
DojiPad's guardian or DojiPad's sentinel is a full stop"): a stop by the owner keeps redemptions settling
(redemption-only, deposits wait); only the guardian's and the sentinel's stop freezes settlement.

**Overlap with an epoch-deadline snapshot.** Touches `settle` (the hard-stop guard and the `redemptionOnly` line, both
before the overdue check) and `triggerBreach`; not `epochOverdue`, not `triggerEmergency`.

---

## 3. HLR2-H04 (contract half): the manager's bridge chain in emergency

**One-liner.** In emergency only the guardian and the sentinel may call `bridgeToEvm`; the manager, the owner and the
operator (all owner-chosen; `setOperator` is the owner's, instant) cannot open a bridge window, so they cannot keep the
exit settle out.

**Options.** (A, implemented) restrict who bridges in emergency. (B) let the emergency exit-only settle run inside a
bridge window, paying from idle USDC on the pre-bridge snapshot. B removes the dependency on who bridges but prices an
exit inside a window where `totalAssets` is a snapshot and Core / EVM may double- or under-count until landing; A is
simpler to reason about and keeps the "nothing settles inside a window" invariant. A variant of A that keeps the
operator (and freezes `setOperator` in emergency) was rejected: a hostile owner sets the operator before triggering.

**Diff** (`patches/HLR2-H04.patch`):
```solidity
// VaultLogic.bridgeToEvm (was: if (!_treasury($) && !($.emergency && _platform($, guardian, sentinel))) revert E.Unauthorized();)
if ($.emergency ? (msg.sender != guardian && msg.sender != sentinel) : !_treasury($)) revert E.Unauthorized();
```

**Fix tests** (`tests/HLR2-H04.fix.t.sol`, platform-vault-like factory vault): 
- `test_HLR2_H04_fix_managerOwnerOperatorCannotBridgeInEmergency`: manager/owner and operator revert `Unauthorized`, no
  window, the guardian's exit settle lands at once.
- `test_HLR2_H04_fix_sentinelAndGuardianStillBridgeInEmergency`.
- `test_HLR2_H04_fix_outsideEmergencyUnchanged`: manager bridges, sentinel cannot.

Original PoC expected to fail: `test_HLR2_H04_managerBridgeChainKeepsTheEmergencySettleOut` (the manager's first bridge
reverts `Unauthorized`).

**Existing tests changed** (`patches/HLR2-H04.tests.patch`), all because they had the manager bridge home in emergency:
- `test/Round4.t.sol`: both `_home` helpers prank `vault.emergency() ? guardian : manager` (used by
  `test_DepositorsRequestAndClaimInBreachAndEmergency` and others); `test_R302_insiderAgeNeverDelaysExits` bridges as the
  guardian in emergency.
- `test/audit/AuditPoC.t.sol::test_AUDIT_H02_bridgeWindowCannotBlockEmergencySettle`: the manager's bridge inside the
  sentinel's window in emergency now reverts `Unauthorized` instead of `BridgeInFlight` (stronger: it may not bridge at
  all); the expectation is updated, the rest of the test is unchanged.
- `test/audit/reaudit2/Reaudit2Handler.sol`: new `_bridger()` (guardian / sentinel in emergency, the old rotation
  otherwise) for the two `bridgeToEvm` calls; the stranger probe is unchanged. Without it
  `test_handlerReachesProRataMiniEpochs` (Reaudit2Invariants, VerifyMixedInvariants) and the two
  `test_mixed...Reachable` smoke tests no longer reach a mini epoch.

**Executor half (other sub-reviewer).** (1) In emergency the treasury operator must send `bridgeToEvm` from the
sentinel key, not the operator key (`treasury/operator.ts:137` via `operate`); `gasBudget.ts:11` maps `bridgeToEvm` to
the operator budget. (2) The priority-fee half stands for every emergency settle and bridge: set an explicit
`maxPriorityFeePerGas` (2-5 gwei) for guardian / sentinel / keeper sends (`chain/vault.ts:1077-1080`). With this patch the
manager can no longer chain windows in emergency, so the tip matters only against a hostile sentinel (accepted) or an
outside-emergency stall.

**Residual risk.** Outside emergency the manager can still chain bridges and delay normal and redemption-only settles
(and, with E06, an owner-stop's redemption-only settles). The remedy is the guardian's `triggerEmergency` (or anyone's
once overdue), after which this patch applies.

**Documented behaviour changed.** `depositors.tsx:426-427` / `security.tsx:223` / `managers.tsx:431` (the operator
"bridges USDC ... in a breach or an emergency"): in an emergency only DojiPad's guardian or sentinel brings USDC home.

**Overlap with an epoch-deadline snapshot.** None (`bridgeToEvm` only).

---

## 4. HLO-07: self-held agent through the agent binding (commit-then-veto)

**One-liner.** The binding a launch makes (registrar signature or owner pre-bind) is recorded but inert for
`AGENT_WARMUP` = 1 day: the vault takes no deposit and `syncAgent` refuses to approve the agent on HyperCore. In that
window the guardian or the sentinel vetoes a binding the platform does not hold with the existing
`factory.unregisterPlatformAgent(agent)`, which revokes it on the vault. No third-party money can reach a vault whose
agent the platform could still veto.

**Options.** (A) Factory-side commit (HLO-DEFERRED sketch): the registrar's signature only records a commitment;
`create` accepts the agent after `COMMIT_DELAY`. No vault exists until then. Cost: the launch becomes two
transactions a delay apart, the wizard and the executor change, and ~70 test sites that launch with a signature
in one transaction change. (B, implemented) vault-side warm-up: one-transaction launch kept, the binding queued in the
vault. Security property is the same ("no deposits accepted until it applies", the agent has no Core power until it
applies, veto in between); B also covers the owner pre-bind leg with no extra code. B chosen because it changes no
flow and is the smaller diff; A is the alternative if the lead prefers no vault at all during the window.

**Diff** (`patches/HLO-07.patch`, summary):
```solidity
// VaultTypes.sol
uint256 constant AGENT_WARMUP = 1 days;                       // = MIN_TIMELOCK, the replacement path's window
struct VaultStorage { ...; uint64 agentActiveAt; }
error AgentWarmingUp(uint256 activeAt);
// VaultGovernance.initialize
if (p.agent != address(0)) {
    VaultLogic.initAgent($, p.agent);
    if (p.factory != address(0)) $.agentActiveAt = uint64(block.timestamp + AGENT_WARMUP);
}
// VaultLogic.requestDeposit
if ($.agent != address(0) && block.timestamp < $.agentActiveAt) revert E.AgentWarmingUp($.agentActiveAt);
// VaultLogic.syncAgent
if (block.timestamp < $.agentActiveAt) revert E.AgentWarmingUp($.agentActiveAt);
// HyperVault: agentActiveAt() view
```
After a veto the vault has no agent and is a manual vault (deposits open at once; the held key has no power). A
replacement agent (`setAgent`) already waits behind the vault timelock (`MIN_TIMELOCK` = 1 day), so it can never land
before `agentActiveAt`.

**Fix tests** (`tests/HLO-07.fix.t.sol`, live-like factory):
- `test_HLO07_fix_leakedRegistrarLaunchIsInertUntilVetoed`: the hl-open theft launch; alice's 1M deposit reverts
  `AgentWarmingUp`, `syncAgent` reverts; the sentinel vetoes; agent 0 on the vault, not a platform agent; after the
  window `syncAgent` has nothing to approve.
- `test_HLO07_fix_ownerKeyBindingGetsTheSameWindow`: the owner-key leg; the cold guardian vetoes.
- `test_HLO07_fix_honestLaunchOpensAfterTheWindow`: after 1 day `syncAgent` and deposits work.
- `test_HLO07_fix_manualLaunchUnaffected`: no agent, no window.

Original PoC expected to fail: `test_HLO07_leakedRegistrarKeyGivesAnyLauncherASelfHeldAgent` (alice's deposit reverts
`AgentWarmingUp`). `test_HLO07_r2_factoryOwnerKeyAlsoBindsASelfHeldAgent` and
`test_HLO07_r2_creatorCoSignatureIsProducedByTheAttacker` keep passing by design: they assert only that the binding is
recorded, which it still is (inert until the window ends). `test_HLO07_r2_commitThenVetoWorksWithTodaysFunctions` keeps
passing.

**Existing tests changed** (`patches/HLO-07.tests.patch`): one line each, `if (v.agentActiveAt() > now) vm.warp(v.agentActiveAt());`
after a launch with an agent and before the first deposit / `syncAgent`, in the shared helpers:
`test/audit/AuditBase.t.sol::_malloryVault`, `test/audit/hl-r2/hostile/HostileBase.t.sol::_platformVaultLike`,
`test/audit/hl-r2/keys/KeysPoC.t.sol::_hosted`, `test/audit/hl-r2/xreview/XreviewA.t.sol::_hosted`,
`test/PolicyAndFactory.t.sol::_createWithPermit`, `test/DeployFactory.t.sol::test_DeployScript_FactoryVaultSettlesADeposit`,
`test/audit/reaudit2/Reaudit2Invariants.t.sol::setUp` (inherited by `VerifyMixedInvariants`). Without it ~54 tests
(AuditPoC, Reaudit*, Verify*, KeysPoC, XreviewA, HostileConfig, PolicyAndFactory, DeployFactory) revert
`AgentWarmingUp` at their first deposit, and the Reaudit2 / VerifyMixed reachability smoke tests
(`test_handlerReachesProRataMiniEpochs`, `test_mixed...Reachable`) never reach a funded epoch. `HloBase._launch` is deliberately not changed, so the hl-open theft PoC
stays the unpatched one.

**Residual risk.**
- The veto needs someone to act within the day. Executor half: a monitor alert (error, routed to the guardian) on every
  `PlatformAgentRegistered` / `VaultCreated` with an agent that is not in the reservation store, and the sentinel's
  automatic `unregisterPlatformAgent` for such an agent. The sentinel and registrar are both online keys in the same
  executor today (S-04): a full executor compromise still wins; the cold guardian's veto is the backstop.
- A leaked factory OWNER key can rotate the guardian and the sentinel instantly (`setGuardian` / `setSentinel`), so it
  can disable the veto: the owner leg is closed only once owner = guardian is a Safe with independent signers
  (guardian-to-Safe runbook). Recommendation kept from HLO-DEFERRED: drop the `owner()` signer path in `create`.
- Replacement agents on an existing vault (registrar `registerPlatformAgent` + owner's timelocked `setAgent`) are vetoed
  in the vault timelock (>= 1 day) by the same monitor rule; no code change needed, the alert must cover
  `TimelockQueued(setAgent)`.

**Documented behaviour changed.** `managers.tsx:140` (launch steps): a vault launched with a DojiPad strategy opens for
deposits 24 hours after the launch; the wizard and the executor's post-launch `syncAgent` (A-13) must wait for
`agentActiveAt`.

**Overlap with an epoch-deadline snapshot.** None (initialize, requestDeposit, syncAgent).

---

## 5. HLR2-XA01 (contract half): the monitor's revoke does not stop the deflated-NAV mint

**One-liner.** A revoke of a live agent by the guardian, the sentinel or the factory (the monitor's ACT, or a veto)
sets `depositHold`: deposits close and every settle is redemption-only (queued deposits carried, cancellable, never
minted) until the guardian clears with `clearBreach`. The owner's own revoke (going manual, `leaveHosted`) does not hold.

**Options.** (A) make the revoke a full stop (`triggerBreach`): already available to the sentinel, but it freezes
exits too (the E06 class) and needs the guardian. (B, implemented) hold only the deposit pricing: exits keep settling,
no share is minted at a NAV the revoked agent may have deflated. "Until a fresh checkpoint" was rejected: the
deflation persists until the replacement agent (2-day timelock) moves the parked funds home, so a fresh checkpoint
would just ratify the deflated NAV.

**Diff** (`patches/HLR2-XA01.patch`, summary):
```solidity
// VaultTypes.sol: struct VaultStorage { ...; bool depositHold; }  event DepositHold(bool held);
// HyperVault.revokeAgent, before VaultLogic.revokeAgent:
if (msg.sender != owner() && $.agent != address(0) && !$.depositHold) { $.depositHold = true; emit DepositHold(true); }
// VaultLogic.requestDeposit: DepositsClosed also when $.depositHold
// VaultLogic.settle: bool redemptionOnly = _lossBreach($) || ($.depositHold && !$.emergency);
// VaultGovernance.clearBreach: if (msg.sender == guardian && $.depositHold) { $.depositHold = false; emit DepositHold(false); }
// HyperVaultLens: previewDeposit / previewMint return 0 under the hold; redeem previews clamp to the checkpoint
// HyperVault: depositHold() view
```

**Fix tests** (`tests/HLR2-XA01.fix.t.sol`, same platform-vault-like setup as `XreviewA.t.sol`, robust to HLO-07):
- `test_HLR2_XA01_fix_revokeHoldsDepositsSoTheKeeperSettleMintsNothing`: XA01 inverted. Same deflation, same sentinel
  revoke, same keeper settle: the settle runs (redemption-only), deposit shares 0, the sybil's 100k stays queued and is
  cancelled back in full; new deposits revert `DepositsClosed`.
- `test_HLR2_XA01_fix_onlyTheGuardianLiftsTheHold`: the owner's direct `clearBreach` reverts; the guardian's clears and
  deposits reopen.
- `test_HLR2_XA01_fix_ownerRevokeDoesNotHold`: the owner's revoke and a revoke with no live agent leave no hold.

Original PoC expected to fail: `test_HLR2_XA01_revokeOnlyActStillLetsTheKeeperSettleAtTheDeflatedNav` (it fails with
`RequestNotSettled` at `claim(sybil)`: the sybil's deposit was carried, not minted, so there is nothing to claim).

**Residual risk.** Redemptions in the held epochs are paid at min(NAV, checkpoint), possibly at the deflated NAV (the
same rule as a loss breach); a redeemer who sees the hold can cancel and wait. A deflation the monitor never ACTs on
(XA-05 / X05 classes) is untouched. The owner's queued `clearBreach` clears a breach but not the hold (owner-free clear).

**Executor half (other sub-reviewer).** Nothing is required for safety (the contract now refuses to price deposits),
but: the operator should not treat a carried deposit as an error and should skip pointless settles while held; the
monitor should alert the guardian with the revoke reason so it can review and `clearBreach`; the UI should show
"deposits on hold" (`depositHold()`); a keeper that refuses to settle after a revoke is no longer needed and would only
delay redemptions.

**Documented behaviour changed.** `depositors.tsx:342` / `security.tsx:198` (sentinel revokes the key): after DojiPad
revokes a key, deposits close and queued deposits wait until DojiPad's guardian reviews and reopens; withdrawals keep
settling.

**Overlap with an epoch-deadline snapshot.** Touches `settle` (the `redemptionOnly` line only) and `clearBreach`; not
`epochOverdue`, not `triggerEmergency`.

---

## 6. Stacking notes for the lead

- `settle` is touched by E01 (exit-only pricing), E06 (hard-stop guard + `redemptionOnly`), XA01 (`redemptionOnly`).
  The combined line is `bool redemptionOnly = _lossBreach($) || ownerStop || ($.depositHold && !$.emergency);`
  (`COMBINED-B.patch`). None of my patches touch `epochOverdue` or `triggerEmergency`; a deadline snapshot (fixA, H01)
  that changes `epochOverdue` / the overdue check in `settle` / `triggerEmergency` merges textually with these.
- `VaultStorage` gets four appended fields (`checkpointLagging`, `platformHold`, `agentActiveAt`, `depositHold`); order
  is irrelevant for new deployments.
- `HyperVaultLens._postFeeRedeem` is touched by E06 and XA01 (combined in `COMBINED-B.patch`).
- Interaction checked by the combined run: E06 + XA01 (an owner stop and a hold both settle redemption-only), E01 + H04
  (emergency settle waits for the walk; only the platform bridges), HLO-07 + XA01 (a veto via the factory also sets the
  deposit hold, so a vetoed launch stays closed until the guardian reopens it — the conservative outcome).

## 7. Results

Throwaway runs by `verify-B.sh` (logs in `fixes/results/`), forge 1.8.4, solc 0.8.28 via_ir, non-Gains suite.
Unpatched baseline of the same suite: 353 tests, 350 passed, 0 failed, 3 skipped. During the runs origin/main moved from
4ec6feb to 4a6b526; the logs record that `contracts/src` is identical in both and on this branch.

| ID | (1) unpatched: original PoCs | (2a) patched: fix tests | (2b) patched: original PoCs | (3) patched: whole non-Gains suite |
|---|---|---|---|---|
| HLR2-E01 | 6/6 pass (E01a-e, XB01) | 7/7 pass | 6/6 fail (`CheckpointBehind`) | 351 pass, 6 fail = the 6 PoCs, 3 skip (one compiler job) |
| HLR2-E06 | 1/1 pass | 5/5 pass | 1/1 fails (the settle no longer reverts) | 354 pass, 1 fail = the PoC, 3 skip (one job) |
| HLR2-H04 | 1/1 pass | 3/3 pass | 1/1 fails (`Unauthorized`) | 352 pass, 1 fail = the PoC, 3 skip (one job) |
| HLO-07 | 1/1 pass | 4/4 pass | 1/1 fails (`AgentWarmingUp`) | one-job build: solc ICE (below). Three jobs: 360 pass, 1 fail = the PoC, 3 skip |
| HLR2-XA01 | 1/1 pass | 3/3 pass | 1/1 fails (`RequestNotSettled`) | 352 pass, 1 fail = the PoC, 3 skip (one job) |
| COMBINED-B | 10/10 pass | 22/22 pass | 10/10 fail | one-job build: solc ICE. Three jobs: 369 pass, 10 fail = exactly the 10 PoCs, 3 skip |

The suite's three skips are the same as in the baseline. Totals differ between runs because each run adds its own fix
tests. The PoCs that keep passing by design are `test_XB_E01c_...` (the walk), `test_HLR2_E06b_...` (merged into H01),
`test_HLR2_XA01_control_...` (sentinel stop), `test_HLO07_r2_factoryOwnerKey...`, `test_HLO07_r2_creatorCoSignature...` and
`test_HLO07_r2_commitThenVeto...`.

**Compiler note (needs the lead's attention before merge).** With `HLO-07.patch` (alone or in `COMBINED-B`) the
one-job `forge build` / `forge test` of the whole non-Gains tree stops with a solc 0.8.28 internal compiler error,
"Assembly exception for bytecode: Tag too large for reserved space". Every file compiles on its own, and so do the
three halves (top-level tests + mocks; `test/audit` without hl-r2/hl-open; hl-r2 + hl-open), each as one job. The
unpatched tree and the E01, E06, H04 and XA01 trees build in one job. `verify-B.sh` records the ICE in the log and
then builds file by file (same compiler and settings) before running the suite. I did not find which contract trips
it. It is a compiler limit on a large job (probably a test contract that embeds the vault, factory and lens creation
code), not a source error. But CI and the Deploy script build in one job, so the lead must check the merged tree with
Gains included. Options: split the build (`forge build <paths>`), or cut the largest test handlers.

## 8. Assumptions

- A4 as written in ROUND2.md. Existing-test adaptations that are needed for the suite to run under a patch are
  delivered as `<ID>.tests.patch` (diffs against origin/main `contracts/test`), applied in the throwaway only.
- E01: "conservative" read as "no party is paid at a price the contract cannot justify", accepting a bounded,
  permissionless delay of exits over a mispriced exit. The webapp copy "the NAV bound never blocks an exit" changes.
- E06: the sentinel is treated like the guardian (its stop keeps freezing), the conservative reading for an online key used
  on attack detection.
- HLO-07: 24 h window (= MIN_TIMELOCK). A shorter window (the HLO-DEFERRED "few hours") is a one-constant change; the
  guardian is a manual cold key, so the longer window is the conservative choice.
- XA01: the hold is set only by a platform revoke of a live agent; only the guardian lifts it.
- The throwaway deletes `src/gains`, `test/gains`, `test/audit/gains`, `script/gains`, `script/DeployGains.s.sol`; nothing
  in the HL code imports them. The `git diff --stat` printed in the logs lists those deletions too (throwaway only).
