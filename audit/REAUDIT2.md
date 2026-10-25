# DojiPad Vaults: third audit pass (round 2 diff `e68666c..a75d935`)

Date: 2026-10-05. Scope: every file changed by audit round 2 (58 files, +5,193 / -1,630), with the new architecture
(thin `HyperVault` + `VaultStorage` struct + linked libraries `VaultLogic` / `VaultGovernance` + internal `VaultMath`),
the pro-rata emergency settlement, the factory-held guardian/sentinel, agent binding and the SIWE-style launch
statement as the priority. Rules: no `src` edits, PoC for Medium and above, no broadcasts, no keys. Everything in
this pass is local and uncommitted:

| File | Content |
|---|---|
| `contracts/audit/REAUDIT2.md` | this report |
| `contracts/test/audit/reaudit2/Reaudit2PoC.t.sol` | 12 tests: PoCs for N2-01..N2-04 (PASS = issue present), two informational demonstrations, six `OK_*` verifications of the architecture |
| `contracts/test/audit/reaudit2/Reaudit2Handler.sol`, `Reaudit2Invariants.t.sol` | handler extending `ReauditHandler` (every earlier action stays in play) plus forced emergencies with many-epoch pro-rata mini epochs, direct library calls, mid-epoch role rotation and fee raises across epochs; one invariant carrying every earlier ghost plus the new ones, run fresh (512 x 200) and emergency-seeded (512 x 500), plus a reachability smoke test |
| `server/test/audit/reaudit2/reaudit2.test.ts` | 4 tests: SIWE replay (N2-04), rotation replay, domain separation, key uniqueness |

Headline: **no Critical or High. One Medium (claim gas grows with the number of emergency epochs), three Low, six
informational.** All 15 N-items, all 9 SN-items and the four residual S-items are fixed or accepted as documented.
The new architecture holds up: slot layout, call protection, immutable linking, lock coverage and the pro-rata
accounting all verified, and the three invariant suites are green at 512 x 200. Judgement in section 10: **ready
for a capped mainnet deploy once N2-01 and N2-02 are fixed and re-tested**; N2-03 / N2-04 can follow in the same
change or the next.

Run:

```bash
cd contracts
forge test --match-path "test/audit/reaudit2/Reaudit2PoC.t.sol" -vv          # 12 passed
forge test --match-path "test/audit/reaudit2/Reaudit2Invariants.t.sol" -vv   # 512 x 200
forge test --match-path "test/audit/{invariants,reaudit}/*.t.sol"            # earlier suites, 512 x 200
forge test --no-match-path "test/audit/**/*Invariants.t.sol"                 # 140 unit tests (the smoke test runs with the invariant file)
cd ../server && npx vitest run                                               # 151 tests
```

## 1. Verification of the round 2 fixes

Status: **Fixed** = regression test inverted and passing, bypass attempts failed; **Accepted** = informational item
handled as documented. Every bypass listed was attempted in the PoC file, the handler or by hand against the source.

### 1.1 Contracts N-01..N-15

| ID | Status | Evidence | Bypass attempts (all failed unless noted) |
|---|---|---|---|
| N-01 held-open window | **Fixed** | One rule in `VaultLogic._openWindow:340-345` (reverts `BridgeInFlight`); `settle:155`, `accrueFees:341` and `setFees` (`VaultGovernance:272`) revert in flight; `MAX_WINDOW_EXTENSION` and the in-window settle are gone. `test_BridgeWindowIsNeverExtended`, `test_REAUDIT_N01_*` (inverted), `invariant_N01` (`vWindowExtended`, `vStaleSettle`), handler `holdWindowSettle` | Second bridge inside the window (either direction, manager or emergency stranger): reverts. Settle, accrue, setFees inside the window: revert. `lowerFees` inside the window is allowed and skips the accrual (`_setFees:292`): the owner can only lower, so the un-accrued period is charged at the lower rate; harmless, by the owner's choice |
| N-01b masking | **Fixed, approach judged acceptable** (1.2) | `VaultGovernance.checkRisk:95-99`: `equity = min(live + bridgeAmount, equityAtBridge)` in flight; no day roll in flight; peak only out of flight. `test_REAUDIT_N01b_*` inverted | Hide a Core loss behind a window: the loss shows through `live + bridgeAmount` as soon as the precompiles see it, and the window closes by itself after 10 blocks. Force a false breach with a large bridge: impossible, the bridged amount is added back on the visible side |
| N-02 emergency deadlock | **Fixed** | No per-epoch slot; anyone bridges home when not in flight (`bridgeToEvm:325`); the full remaining Core balance may be bridged below `MIN_BRIDGE` (`:330`, so no dust is stranded); emergency settle pays pro rata and burns `redShares * paid / redAssets`, deposits refunded. `test_EmergencyBridgeByAnyoneOutsideAWindow`, `test_EmergencySettlePaysProRataAndRefundsDeposits`, `test_REAUDIT_N02_*`, `test_REAUDIT2_OK_proRataPayoutsNeverExceedLiquidity`, handler `forceEmergency` + `miniEpoch` | Starve the redeemers with 100 USDC epochs: every epoch pays what is on hand, leftovers keep their place, the final epoch clears them (PoC). Lock the vault by keeping a window open: a window closes after 10 blocks whatever happens. Mint in emergency: `depIn = 0`, ghost `vEmergencyMinted == 0` |
| N-03 `maxNavMoveBps` freeze | **Fixed** | `VaultPolicy._isTighter:368` (`a.maxNavMoveBps >= b.maxNavMoveBps`), floor 500 (`:358`), so lowering is timelocked with the 14 day grace. `test_NewFieldsAreTightenOnly`, `test_REAUDIT_N03_*` | Lower below 500 through the timelock: `InvalidConfig`. Freeze exits with a tiny band: the exit-only settle never reverts on the band (`priceNav = min(nav, checkpoint)`), so even a 5 % band cannot block an emergency or overdue exit. Note: *raising* the band is instant; the vault owner cannot move NAV (no agent), so this only lowers the protection against a compromised platform agent, which stays bounded by `maxDailyLossBps`. Acceptable |
| N-04 pre-queued `clearBreach` | **Fixed** | Exact calldata length per selector (`queue`), `breachedAt` stamped in `_breach:143`, `execute:247` rejects a clear queued at or before the breach. `test_ClearBreachGuardianInstantOwnerQueuedAfterBreach`, `test_PaddedQueueCalldataRejected`, `test_REAUDIT_N04_*`, ghost `vPrequeuedClear` | Padding: rejected. Queue in the breach second: `queuedAt <= breachedAt`, rejected. Queue one second later: allowed, matures after the vault's own timelock, as intended. Re-breach after the queue: invalidates it (I2-01) |
| N-05 `lowerFees(current, current)` | **Fixed** | Strict decrease required (`lowerFees:214-215`); `_setFees` crystallises the management fee only. `test_LowerFeesOnlyDown`, `test_REAUDIT_N05_*`, `invariant_N05` (`vPerfOutsideSettle`), handler `lowerFeesSame` | `lowerFees(mgmt - 1, perf)`: management accrual only, HWM untouched (`vHwmWithoutFee == 0`). External `accrueFees`: management only |
| N-06 immutable guardian | **Fixed** | Factory `guardian` / `sentinel` read live (`HyperVault.guardian()` / `sentinel()` when `factory != 0`), setters owner-only. `test_RolesAreRotatedFromTheFactory`, `test_REAUDIT2_OK_rotationMidEpoch`, handler `rotateRoles` with invariant "guardian / sentinel == factory's" | Queue `setGuardian` on a factory vault: not a queueable selector (`test_GuardianCannotBeQueued`). Legacy vault keeps its stored guardian (unchanged) |
| N-07 global agents | **Fixed** (residual N2-04, Low) | `platformAgentFor[agent] = vault`; `create` checks the binding against `predictVaultAddress(msg.sender, salt)`; `setAgent` checks `== address(this)`; `unregister` revokes on the vault. `test_OnlyPlatformAgents`, `test_REAUDIT_N07_*`, `invariant_N07`, invariant "agent bound to this vault" | Use a bound agent on another vault: `AgentNotPlatform`. Re-register a bound agent elsewhere: `AgentAlreadyBound`. Salt reuse to steal a binding: the clone exists, `create` reverts (`test_REAUDIT2_OK_saltReuseReverts`). Bind several agents to one predicted vault: allowed (N2-04) |
| N-08 HWM without fee | **Fixed** | `_accrueFees(withPerformance)`: HWM moves only with the performance fee; `settle` passes true, everything else false. `test_REAUDIT_N08_*`, `invariant_N08` (`vHwmWithoutFee`), handler `accrueManagementOnly` | Management-only accrual before a settle at a lower NAV: HWM unchanged, fee charged at settle on gains above the old HWM |
| N-09 insider gate cosmetic | **Accepted** | Documented as a policy statement in `VaultLogic:36-38`; depositor safety rests on platform agents + limits + checkpoint | - |
| N-10 sticky breach | **Accepted** | Depositor-facing banner text in `webapp/src/components/vault/VaultCards.tsx` | - |
| N-11 zero-share deposit refund | **Fixed** | `settle`: `if (depShares == 0) depIn = 0`, so `claimableRedeemAssets += depAssets - depIn` reserves the refund in the normal path too | - |
| N-12 first settle / NAV 0 | **Fixed** | `VaultPolicy.nextCheckpoint`: a manager settle without any checkpoint reverts `StaleCheckpoint` (the keeper's `checkRisk` must run first); `prev == 0` after NAV 0 returns unbounded (nothing left to protect). `test_CheckpointRule` | Settle a fresh vault without a keeper: reverts until anyone calls `checkRisk()` (permissionless). Operational note I2-04 |
| N-13 curation / cap propagation | **Accepted** | Documented ("future vaults only") in `HyperVaultFactory` and the README | - |
| N-14 83 B headroom | **Fixed** | `HyperVault` 14,736 B (9,840 B headroom); `VaultLogic` 14,113 B, `VaultGovernance` 8,387 B, `VaultMath` internal; headroom asserted in `PolicyAndFactory.t.sol` | - |
| N-15 lens previews in emergency | **Fixed** | `HyperVaultLens.previewDeposit / Mint` return 0 in emergency; `claimable` replicates the pro-rata loop (Ceil on burned) | Lens vs vault drift: handler `checkPayouts` and the invariant compare `lens.claimable` with what `claim` pays; no drift found |

### 1.2 N-01b: judgement on `min(snapshot, live + bridgeAmount)`

The round 2 note is correct. With pure `min(snapshot, live)` every bridge of at least `maxDailyLossBps` of NAV would
read as a daily loss during the one or two blocks in which the amount is visible on neither side, so anyone able to
bridge (the manager, or anyone in emergency) could force or suffer a false breach. Adding `bridgeAmount` to the
visible side removes that while keeping the bound the window was introduced for:

- a loss on Core is visible through the precompiles the moment it happens, so `live + bridgeAmount` drops with it and
  the daily-loss / drawdown checks fire inside the window;
- the only thing the formula can hide is a loss of at most `bridgeAmount` (the amount could have arrived or not), for
  at most `BRIDGE_SETTLE_BLOCKS` (10 blocks), after which the window is closed by the block rule and `checkRisk`
  reads live equity again;
- the daily baseline does not roll inside a window, so a window cannot be used to re-base the day at a frozen value;
- settle, fee accrual and fee changes are impossible inside the window, so nothing is priced at the snapshot.

Residual: a bridge of 100 % of NAV hides a 100 % loss for 10 blocks. That is the same exposure every depositor has to
a 10 block precompile outage and is not actionable. Accepted.

### 1.3 Server SN-01..SN-09 and residual S-items

Evidence: `server/test/audit/reaudit/reaudit.test.ts` (22 inverted tests), `server/test/audit/audit.test.ts`,
`server/test/launch.test.ts`, `server/test/monitor.test.ts`, `server/test/keeper.test.ts`; 151 tests pass.

| ID | Status | Evidence / notes |
|---|---|---|
| SN-01 monitor revokes every vault | **Fixed** | HYPE whitelisted up to a configured amount, a dust threshold, deltas only; ACT (auto-revoke) only on `FOREIGN_AGENT` and a non-trivial `OTHER_DEX` balance, ALERT for `FOREIGN_SPOT` / `NAV_MOVE`; actions only through the sentinel on vaults whose sentinel is ours and never on the guard-exempt list. Bypass: spot-send dust: nothing. Spot-send above the dust threshold: alert only. A foreign agent cannot be set through the factory; a legacy vault is exempt |
| SN-02 transient `hosted()` error drops a tenant | **Fixed** | `hosted()` rethrows transport errors (`isContractRevert` heuristic), registry skips instead of dropping. Residual: the heuristic classifies by error shape; an unusual provider wrapping would be treated as transport (skip), which fails safe |
| SN-03 keeper / monitor scale with attacker vaults | **Fixed** | Served vaults every run, other vaults in a bounded rotating batch (configurable per-run limits for the keeper and the monitor) with `pauseMs` between calls |
| SN-04 perpetual revoke loop | **Fixed** | Burn slot (`agentName == "dojipad"`, `onchainAgent == 0`) recognised; hourly dedupe per vault per finding, "resolved" message |
| SN-05 reservation race / registrar gas | **Fixed** | `reserve` serialised through a promise chain, count-before-insert, per-owner cap, hourly registrar budget, `sweep` unregisters expired agents, insert-before-register with delete on failure. Residual: the launch statement has no nonce (N2-04); every accepted request still spends one registrar transaction, bounded by the budget |
| SN-06 bound agent reusable | **Fixed** | Onchain binding (N-07) plus `onVaultCreated` binds only when `r.vault == ev.vault` and owner / manager / txFrom match; reuse raises an alert via `findReservationByAgent`; unknown sender fails closed |
| SN-07 own-mode tenant bricked | **Fixed** | `POST /api/launch/rotate` with an owner signature; `rotateWebhook` refreshes the registry. Residual: the rotation statement replays within 10 min (N2-04) |
| SN-08 shared online keys | **Fixed** | Boot fails when the sentinel, registrar, keeper or agent keys share an address. The factory itself accepts guardian == sentinel (I2-05) |
| SN-09 submitter cache keeps dropped keys | **Fixed** | `onDrop: (name) => submitters.delete(name)` (`index.ts:181`) |
| S-03 front-run griefing / `txFrom` null | **Fixed** | Null `txFrom` fails closed with an alert; the victim's reservation stays claimable for their own vault |
| S-05 stale `tradingPaused` | **Fixed** | Tenant processor reads the policy fresh (`chain.policy(v, true)`, `index.ts:189`) before each order |
| S-08 trusted proxy hop count | **Accepted** | Default stays 1 (the hosting provider has exactly one proxy), documented in the executor's configuration defaults. Rate limits are no longer the only defence (owner signature, per-owner cap, registrar budget) |
| S-11 slippage after restart | **Fixed** | `policySlippageBps` persisted on the ticket; the close fallback is `min(50, last, ticket, override)` |

## 2. New architecture

### 2.1 Storage layout and OpenZeppelin collision

`HyperVault` declares `VaultStorage internal $` as its only state variable; `ERC20Upgradeable`, `OwnableUpgradeable`,
`Ownable2StepUpgradeable` and `Initializable` (v5.4.0) use namespaced slots. Verified with `vm.load`
(`test_REAUDIT2_OK_storageLayoutIsConsistent`): slot 0 holds `asset`, the ERC-20 struct at `0x52c63247…bace00`
holds `totalSupply` at `+2`, the Ownable slot `0x9016d09d…9300` holds the owner, and `forge inspect HyperVault
storage` shows the struct as the single entry at slot 0 (928 bytes, 29 words). The libraries receive `$` by storage
reference, so they operate on the same slot 0 layout; `VaultMath.erc20()` / `owner()` compute the same namespaced
slots the mixins use (verified by minting through the library and reading the balance through the mixin's
`balanceOf`). Clones (EIP-1167) inherit the implementation layout; nothing else is written to storage.

Risk to watch: `VaultStorage` is now part of the ABI contract between four artefacts. Any future change must keep
field order (append only) and must redeploy all three linked code units together. Recommended: a storage-layout
snapshot test (`forge inspect … --json` compared to a committed file). Not a finding.

### 2.2 Initializer interaction

`HyperVault.initialize` is `initializer` (OZ `Initializable`), the implementation runs `_disableInitializers()` in
its constructor (`HyperVault.sol:54`), and `VaultGovernance.initialize($, p, msg.value)` is an internal step of that
single initializer, so it cannot be re-entered or called standalone (the library's external function reverts when
called directly, 2.3). Clones are initialized in the same transaction as their creation (`factory.create`); the
standalone path (`new` + `initialize`) is used only by the legacy deployment. Order inside
`VaultGovernance.initialize` (cap, seed, Core gas, then `setAgent`) matches L-06.

### 2.3 Direct library calls and reentrancy coverage

Both external libraries carry the Solidity call-protection prefix (`ADDRESS PUSH32 <self> EQ` at offset 5), so a
plain `CALL` into `settle`, `requestDeposit`, `checkRisk`, `queue` or `initialize` reverts
(`test_REAUDIT2_OK_directLibraryCallsRevert`; handler `directLibraryCall` with ghost `vDirectLibraryCall == 0`
across the invariant run). The libraries hold no state (slot 0 is empty), cannot be initialized and have no
`selfdestruct`. Events are emitted from the libraries under the vault's address (delegatecall), which the
`IHyperVaultEvents` interface keeps ABI-identical to the earlier monolith.

The storage lock (`$.lock`, `_enter / _exit`) covers `requestDeposit`, `requestRedeem` and `settle`. `claim`,
`cancel*`, the bridges and `flatten` are unlocked. That is sufficient: the only external calls are to USDC (standard
ERC-20, no hooks), the CoreDepositWallet, CoreWriter (fire-and-forget, no callback) and precompiles (static). No path
re-enters the vault, and the lock is released on the revert path by construction (a revert discards the `lock = 1`
write; `test_REAUDIT2_OK_lockIsReleased`). The lock is a struct field rather than OZ's transient `ReentrancyGuard`,
so it is shared across delegatecalls into both libraries. OK.

### 2.4 Library address immutability and the deploy script

The library addresses are embedded in the implementation bytecode at link time (PUSH20 in `HyperVault`'s runtime
code for `VaultGovernance`, in `VaultGovernance`'s runtime code for `VaultLogic`), so they are immutable per
deployment: `test_REAUDIT2_OK_directLibraryCallsRevert` and the invariant harness locate them by scanning that
bytecode and matching the libraries' compiled runtime (after the 39 byte address prefix).
`forge script script/Deploy.s.sol:DeployFactory` deploys and links the two libraries before `new HyperVault()`;
forge does this automatically from the broadcaster's nonces. Two operational points (not findings):

- verification on the explorer needs the library addresses (`--libraries src/VaultLogic.sol:VaultLogic:0x…
  src/VaultGovernance.sol:VaultGovernance:0x…`); record them in the deploy output;
- the libraries contain the per-vault logic, so a bug fix means a new implementation **and** new libraries; existing
  clones keep pointing at the old implementation (not upgradeable, as before).

## 3. Pro-rata emergency settlement

Reviewed `VaultLogic.settle` (emergency branch), `VaultMath.claimable`, `_claimIfSettled`, `cancelRedeemRequest`,
`HyperVaultLens.claimable`.

- **Payouts never exceed liquidity.** Per epoch `paid = min(available, redAssets)`; per user
  `assets += remaining * redeemAssets / redeemShares` rounded down, so the sum of the floors over users is at most
  `paid`; the claim additionally caps at `claimableRedeemAssets`. Verified by
  `test_REAUDIT2_OK_proRataPayoutsNeverExceedLiquidity` (seven 100 USDC epochs plus the 300 k idle, two redeemers,
  one claiming midway) and by the invariant `claimableRedeemAssets + 3 >= Σ lens.claimable` and
  `balanceOf(vault) >= Σ owed shares` across the 512 x 200 run (section 8).
- **Share burn accounting.** The vault burns `burned = redShares * paid / redAssets` (floor) in total and deducts
  `ceil(remaining * redeemBurned / redeemShares)` per user, so Σ per-user burned ≥ total burned: the few wei of
  difference stay in the vault's own balance (never owed to anyone, never paid). The vault therefore always holds at
  least the shares it still owes ("vault-held shares < owed shares" never fired).
- **Double claims.** `_claimIfSettled` returns when `r.epoch >= currentEpoch`; a leftover is re-queued at
  `currentEpoch`, so a second call in the same epoch is a no-op and the loop restarts from the new epoch next time.
- **Leftovers keep their place.** A partially paid redeemer who never claims is carried through every later epoch
  (`pendingRedeemShares` includes leftovers, so no later epoch has `redeemShares == 0` and the loop's `break` never
  skips one of their epochs). They are paid at each later epoch's price alongside everyone else, which is the
  intended fairness rule.
- **Rounding at tiny payouts.** `paid < redAssets / redShares` makes `burned` 0 while `paid > 0`: that epoch pays a
  few wei without burning, the leftover remains in full, and the invariant still holds. Dust only.
- **Unbounded loop.** The loop is `O(epochs since request)`. This is N2-01 (section 7).

## 4. Factory-held guardian and sentinel

- **Factory owner powers over live vaults:** rotate guardian / sentinel / registrar, `lowerProtocolShare`,
  `registerPlatformAgent` / `unregisterPlatformAgent` (the latter revokes a live agent). It cannot upgrade a clone,
  move funds, or change fees, policies or caps of an existing vault. The worst case is a hostile factory owner setting
  itself as guardian: it may then trigger emergency on every vault (forced orderly exit at the checkpoint-bounded
  price), revoke every agent, and run custom-slippage flattens up to the policy's `maxFlattenSlippageBps` (N2-03).
  No path to custody. Since the owner is the deployer EOA for the first deploy ("a Safe later"), this is the single
  key with the largest blast radius: a multisig owner before lifting the launcher allowlist (I2-06).
- **Sentinel escalation:** the sentinel can only revoke, pause (never unpause), breach and cancel orders
  (`test_SentinelPowersAreRiskReducingOnly`; handler `sentinelOps` with ghost `vSentinelPower == 0` across
  rotations). A compromised sentinel is a denial of service: it can re-breach every hour and thereby invalidate every
  owner-queued `clearBreach` (I2-01). Recovery: the factory owner rotates the sentinel (one transaction, all vaults),
  then the owner's next queued clear matures. Trading is down for one timelock on every vault; depositors can still
  exit (a breach allows emergency once overdue, and exit-only settles never revert on the band).
- **Is the cold guardian strictly needed?** For unpause: no, the vault owner can unpause instantly (`_switchAuth`).
  For `cancel(id)`: no, the vault owner can cancel. For `clearBreach`: only to shorten the recovery from a sentinel
  loop or a false breach from one timelock to one transaction; sentinel rotation by the factory owner plus the vault
  owner's timelocked clear covers it. For `triggerEmergency`: the vault owner can, and anyone can once overdue. For
  custom-slippage `flatten`: the manager can. **Conclusion:** the guardian is an escalation convenience, not a
  safety requirement. Simplest sound setup: guardian = factory owner multisig (one cold key instead of two), which
  also removes the "guardian == sentinel" footgun (I2-05).

## 5. Agent binding and the launch statement

- **Binding to the predicted vault.** `platformAgentFor[agent] = predictVaultAddress(creator, salt)` and `create`
  checks it against the actual CREATE2 address, which includes the factory address and the creator, so a binding
  cannot be consumed by another creator, another salt, another factory or another chain (a second factory has its
  own mapping; the factories on chains 998 and 999 are separate contracts). Salt reuse reverts at CREATE2
  (`test_REAUDIT2_OK_saltReuseReverts`). `setAgent` later requires a binding to the live vault address. `unregister`
  deletes the binding and revokes on the vault when it is the live agent (`test_OnlyPlatformAgents`). Residual: one
  predicted vault can accumulate several bound agents (N2-04).
- **SIWE-style statement (server).** `launchMessage` covers owner, mode, salt-or-vault, factory, chain id and
  `issuedAt` (10 min window), verified with viem `verifyMessage` (EOA only). Domain separation verified
  (`REAUDIT2_OK_statement_is_bound_to_…`): changing any field invalidates the signature; a statement signed for
  `hosted` is rejected for `own`. **Missing: a nonce.** The same statement reserves again within 10 minutes and the
  rotation statement rotates again (`REAUDIT2_N204_*`), so a captured request can be replayed by anyone who sees it
  (the reserve endpoint is unauthenticated and the body is the proof). Impact is bounded by the per-owner cap and the
  registrar budget: a replay burns the owner's own cap and one registrar transaction, and in the rotation case
  invalidates the secret the owner just received. Low. Fix in N2-04.
- **Smart-contract wallets** cannot launch (no ERC-1271). Acceptable for the allowlisted phase; document it.

## 6. Fee rule: a performance fee raise applies to the running epoch (N2-02)

A timelocked `setFees` executes `_setFees`, which crystallises the **management** fee (M-02 / N-05 behaviour) and
switches both rates immediately. The performance fee is charged at the next `settle` on all gains above the HWM,
including gains earned before the raise. PoC `test_REAUDIT2_N202_perfFeeRaiseIsRetroactiveWithinTheEpoch`: 1 M
deposited at 20 %, Core PnL +100 k, owner queues 30 %, executes after the delay with no further gain; the settle
charges 30,085.86 USDC of performance fee (30 % of the gain plus a little management fee), i.e. the full +100 k,
earned entirely under the 20 % rate, is charged at 30 % where 20 % would have been about 20 k. The manager chooses the settle time, so the retroactive window is up to
`maxEpochDuration` plus the timelock, and the owner can time the queue to land after a good run. Severity **Low**
(the owner is a trusted role, the raise is timelocked and visible, and the cap is 30 %), but it is a fairness rule
depositors would reasonably expect and it is cheap to fix.

**Recommended rule (as proposed):** on execute, store the raise as a pending rate instead of switching; a raise takes
effect **inside the next `settle`, after that settle's `_accrueFees($, true)` has charged the running epoch at the
old rate**; a lowering stays immediate (`lowerFees`, with the existing management-only accrual). Management can keep
switching immediately (it accrues linearly and is crystallised at the switch), or be scheduled the same way for
symmetry. Concretely in `VaultLogic.settle`, after `_accrueFees($, true)`:
`if ($.pendingPerfBps != 0) { $.performanceFeeBps = $.pendingPerfBps - 1; $.pendingPerfBps = 0; }` (store
`rate + 1` so 0 means none). Add a `FeesScheduled` event and a `pendingPerformanceFeeBps` getter for the lens / UI;
`lowerFees` clears a pending raise. Tests: inverted N2-02 (fee on the running epoch equals the old rate) plus a
two-epoch test where the new rate applies to the second epoch only. One struct field, appended at the end of
`VaultStorage`.

## 7. New findings

| ID | Sev | Title | PoC |
|---|---|---|---|
| N2-01 | **Medium** | `claimable` is `O(epochs since the request)`; a long emergency makes claims and cancels cost millions of gas | `test_REAUDIT2_N201_claimGasGrowsWithEmergencyEpochs`; invariant counter "claims over 2M gas" |
| N2-02 | Low | Performance fee raise applies to the running epoch's gains | `test_REAUDIT2_N202_perfFeeRaiseIsRetroactiveWithinTheEpoch` |
| N2-03 | Low | Custom-slippage `flatten` up to the creator's `maxFlattenSlippageBps` (hard cap 20 %) is a value-transfer lever for the guardian and the manager | `test_REAUDIT2_N203_guardianFlattenAtCreatorChosenSlippage` |
| N2-04 | Low | Launch / rotation statements carry no nonce (replay within 10 min); several agents can be bound to one predicted vault | `REAUDIT2_N204_*` (server); `test_REAUDIT2_N204_severalAgentsCanBeBoundToOnePredictedVault` |
| I2-01 | Info | A sentinel that re-breaches hourly invalidates every owner-queued clear; only the guardian's instant clear or a sentinel rotation ends it | `test_REAUDIT2_INFO_sentinelRebreachBlocksOwnerClears` |
| I2-02 | Info | Once the epoch is overdue, any stranger's settle refunds all pending deposits (exit-only), even when the vault is healthy | `test_REAUDIT2_INFO_overdueStrangerSettleRefundsDeposits` |
| I2-03 | Info | The registrar online key can revoke any live agent through `unregisterPlatformAgent` (DoS, no theft) | `HyperVaultFactory:274-282` |
| I2-04 | Info | A fresh vault's first manager settle reverts `StaleCheckpoint` until `checkRisk` has run once; the keeper covers it, document it for self-hosted managers | `test_CheckpointRule` |
| I2-05 | Info | The factory accepts `guardian == sentinel` (and either == owner / registrar); the server's distinct-key check does not reach the contract | invariant harness (the first run tripped "sentinel power" exactly this way) |
| I2-06 | Info | The factory owner is an EOA at first deploy with instant role rotation; no ERC-1271 for launchers | README deploy section |

### N2-01 (Medium): claim cost grows with the number of emergency epochs

`VaultMath.claimable` walks every epoch from the request's epoch to the current one. In emergency anyone can bridge
`MIN_BRIDGE` (100 USDC) home and settle every 11 blocks, each settle opening a new epoch. PoC (mini epochs of 100
USDC on a 1 M vault whose Core balance is drained slowly):

| mini epochs | `claim(alice)` gas |
|---|---|
| 50 | 444,580 |
| 400 | 2,951,980 |

`cancelRedeemRequest` runs the same loop first (`_claimIfSettled`), so a redeemer who wants to cancel the unpaid part
is blocked the same way; the PoC shows the cancel reverting with a 2 M gas budget. On HyperEVM small blocks (2 M gas) a
claim becomes impossible after roughly 270 epochs, on big blocks (30 M) after about 4,000. A grieving party needs only
gas and 100 USDC of Core liquidity per epoch, so a two-day emergency on a busy vault is enough to lock the late
claimers out, and the lens call (`claimable`) degrades the same way for the UI. The liquidity itself is never lost (the
loop is view-only accounting), but the user cannot reach it until the number of epochs stops growing and they can
afford a big-block transaction.

Fix, O(1) per claim and no loop: keep two cumulative accumulators written at settle, `cumPaidPerShare[e]` (Σ over
epochs ≤ e of `redeemAssets_e / redeemShares_e`, fixed point) and `survival[e]` (Π over epochs ≤ e of
`1 - redeemBurned_e / redeemShares_e`, fixed point). A request made at epoch `r` with `s` shares is worth
`assets = s * (cumPaidPerShare[cur-1] - cumPaidPerShare[r-1]) / survival[r-1]` and has
`leftover = s * survival[cur-1] / survival[r-1]`, both O(1), with the same floor / ceil directions as today.
Alternatives if a struct change is unwanted: cap the loop at `K` epochs per call and let the user call repeatedly
(partial claim, each call advances `r.epoch`), which keeps the current storage and bounds every call; or allow
emergency settles no more often than once per `CHECKPOINT_INTERVAL` (1 h), which caps the growth at 24 epochs a day but
does not remove the unbounded loop. Recommended: the cumulative accumulators (clean, bounded, and the lens follows the
same formula).

### N2-02 (Low): see section 6.

### N2-03 (Low): custom-slippage flatten

`flatten(assetIndex, slippageBps)` with a non-zero slippage is allowed for the manager and the guardian up to
`policy.maxFlattenSlippageBps` (creator-chosen at launch, at most 2,000 bps, visible to depositors). The PoC flattens a
BTC long at 100,000 with 2,000 bps: the order goes out at 80,000. A colluding counterparty resting 19 % below mark
takes it, and the manager (or a guardian rotated in by a hostile factory owner) has moved up to 20 % of the position's
notional out of the vault without touching custody. It is bounded, disclosed and needs a thin book, but a 20 % cap is
far wider than any flatten needs on BTC / ETH. Recommend a hard cap of 300 bps in `VaultPolicy._validate` (keep the
creator-chosen value below it), and allow the guardian's custom slippage only in emergency.

### N2-04 (Low): no nonce in the launch statement; several agents per predicted vault

See section 5. Fix: include a server-issued nonce (or the reservation id) in the statement and reject a seen
`(owner, issuedAt, signature)` within the window; reject a second pending reservation for the same `(owner, salt)`;
for rotation include the current webhook id in the statement. Onchain, optionally reject `registerPlatformAgent` for
a vault that already has a bound agent (one-to-one), which also bounds the registrar's exposure.

### Informational items

- **I2-01 sentinel loop.** Mitigated by rotation; if the sentinel key must stay hot, consider a minimum interval
  between `triggerBreach` calls from the sentinel (one per `maxEpochDuration`) or let the vault owner's queued clear
  survive one re-breach. With guardian = factory multisig (section 4) this needs no code.
- **I2-02 overdue stranger settle.** An overdue epoch means the manager has not settled for `maxEpochDuration`; the
  refund of pending deposits is the designed exit-only behaviour. Document it to depositors (their deposit comes back
  unminted and they must request again) and make sure the keeper never calls `settle()` on the manager's behalf.
- **I2-03 registrar revoke.** The registrar key is hot on the executor. `unregisterPlatformAgent` is what makes the
  N-07 fix complete, so keep it, but note it in the key-handling runbook: a registrar compromise is a trading DoS,
  recoverable by `setAgentRegistrar` and re-registration.
- **I2-04** operational: the keeper runs `checkRisk` hourly on every served vault; self-hosted managers must call it
  once before their first settle.
- **I2-05** hygiene: `setGuardian` / `setSentinel` / `setAgentRegistrar` could reject equality with each other and
  with the owner. One line each.
- **I2-06** deploy: use a multisig as factory owner (or at least as guardian) before lifting the launcher allowlist;
  no ERC-1271 means contract wallets cannot launch.

## 8. Invariant suites (512 x 200)

All suites green. The third-pass handler extends `ReauditHandler`, so every action and ghost of the two earlier
suites stays in play; new actions: `forceEmergency` (the live guardian triggers it, after moving 500 USDC to Core when
the Core side is empty), `miniEpoch` (100 USDC home, window closes, stranger settles pro rata), `claimMeasured`
(records gas, flags any claim above 2 M), `directLibraryCall` (plain `CALL` into both libraries), `rotateRoles`
(factory owner rotates guardian / sentinel to fresh addresses), `raiseFees` (queue, wait, execute a higher rate) and
`checkPayouts` (Σ `lens.claimable` against `claimableRedeemAssets`). New invariant clauses: guardian / sentinel equal
the factory's current values after any rotation, the live agent is bound to this vault, no direct library call
succeeded, promised claims never exceed the reserve, vault-held shares cover every owed share.

| Suite | Runs x depth | Calls | Result | Last-run counters |
|---|---|---|---|---|
| `Reaudit2Invariants.invariant_reaudit2` (fresh vault) | 512 x 200 | 102,400 | PASS | settles 2, rotations 7, fee raises 1, max claim gas 72,864 |
| `Reaudit2EmergencyInvariants.invariant_reaudit2` (every run starts in emergency with 150 k on Core and two redeemers queued) | 512 x 500 | 256,000 | PASS | settles 49, emergency mini epochs 24, rotations 16, fee raises 6, max claim gas 131,752, claims over 2 M: 0 |
| `test_handlerReachesProRataMiniEpochs` (reachability smoke test) | - | - | PASS | 2 mini epochs, claim 71 k gas |
| `audit/invariants` `invariant_suite` (round 1 suite, re-run) | 512 x 200 | 102,400 | PASS | - |
| `audit/reaudit` `invariant_core`, `invariant_N01 / N05 / N07 / N08` (re-run) | 512 x 200 / 500 | 102,400 / 256,000 each | PASS | - |

Notes. The first fuzz run of the new suite failed "sentinel power" after two rotations: both rotations had landed on
the same fresh address, making guardian == sentinel, so the "sentinel" cleared a breach. The factory allows this
(I2-05); the handler now keeps the two address spaces apart. Claim gas stays small in fuzzing because a run contains
at most a few dozen epochs; the growth itself is shown deterministically by the N2-01 PoC (50 and 400 mini epochs).
`afterInvariant` counters are those of the last run only.

## 9. Ordered fix list

| # | Item | Change | Test |
|---|---|---|---|
| 1 | N2-01 (Medium) | O(1) claim accounting with cumulative `paidPerShare` / `survival` accumulators written at settle (`VaultMath.claimable`, `VaultLogic.settle`, `HyperVaultLens.claimable`); append the new fields to `VaultStorage` / `EpochResult` | invert `test_REAUDIT2_N201_*` (claim gas flat across 400 mini epochs); keep `OK_proRataPayoutsNeverExceedLiquidity`; re-run the three invariant suites |
| 2 | N2-02 (Low) | Pending performance fee rate applied inside the next settle after the old-rate accrual; lowering stays immediate and clears the pending raise; `FeesScheduled` event + getter; lens shows the pending rate | invert `test_REAUDIT2_N202_*`; two-epoch test |
| 3 | N2-04 (Low), server + factory | Nonce / reservation id in the launch and rotation statements, replay rejection within the window, one pending reservation per `(owner, salt)`; optionally one bound agent per vault onchain | invert `REAUDIT2_N204_*`; optionally invert `test_REAUDIT2_N204_*` |
| 4 | N2-03 (Low) | Hard cap `maxFlattenSlippageBps <= 300` in `VaultPolicy._validate`; guardian custom slippage only in emergency | invert `test_REAUDIT2_N203_*` (expect `SlippageTooHigh` above 300) |
| 5 | I2-05 | Reject equal roles in the factory setters | unit test |
| 6 | I2-01 / I2-02 / I2-03 / I2-04 / I2-06 | Runbook and depositor documentation; multisig factory owner; guardian = factory owner multisig if two cold keys are not wanted | - |

Items 1 and 2 change `VaultStorage` (append only) and require redeploying both libraries and the implementation
together. Items 3 and 4 are independent. Nothing here touches the legacy vault.

## 10. Readiness judgement

**Yes, with conditions.** In my judgement the code at `a75d935` is ready for a capped mainnet deploy (allowlisted
launchers, `maxDepositCap` 50,000 USDC per vault) once items 1 and 2 of the fix list are implemented, the inverted
tests pass and the three invariant suites are re-run green at 512 x 200. Reasoning:

- the two Critical and the High of round 1 are closed by construction (one window rule, pro-rata exits, exits never
  blocked by the band), not by patches, and the extended invariants did not find a way back;
- the new architecture introduces no new trust assumptions: the libraries are stateless and call-protected, the
  storage layout is a single struct at slot 0 next to OZ's namespaced slots, and the link is immutable;
- the only Medium (N2-01) is a liveness issue in a prolonged emergency, bounded by liquidity never being lost, with a
  clean O(1) fix. At the 50 k cap the economic exposure of every Low is small: N2-03 is at most 20 % of a 50 k
  position with a colluding book, N2-02 at most 10 points of fee on one epoch's gains, N2-04 costs the owner their
  own cap;
- the role model is risk-reducing for every online key (sentinel, registrar, keeper): a compromise is a denial of service
  recoverable by one factory transaction, never a loss of custody.

Conditions for the deploy itself: factory owner (or at least guardian) is a multisig; `PLATFORM_SENTINEL`,
`AGENT_REGISTRAR`, keeper and deployer are distinct addresses (the server enforces this, the factory does not,
I2-05); the mainnet permit test and a vault launch on testnet with the exact deploy artefacts (library addresses
recorded) precede the mainnet factory. Items 3 to 6 should land before the launcher allowlist is lifted.
