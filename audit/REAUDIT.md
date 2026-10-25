# DojiPad Vaults: Re-audit of the fix diff

| | |
|---|---|
| Diff | `896a0d6..e68666c` (contracts/src: HyperVault, HyperVaultFactory, VaultPolicy, new HyperVaultLens; server/src; the implementer's rewritten audit tests) |
| Rules | Same as the original audit. No src edits, PoC for Medium+, no broadcasts, no keys. Everything kept local and uncommitted |
| Build | HyperVault runtime 24,493 B (**83 B** EIP-170 margin, was 171 B). Factory 8,330 B, VaultPolicy 9,866 B, Lens 6,107 B |
| Existing tests | 129/129 pass (baseline + implementer's inverted PoCs + original invariant suite 512x200) |
| New contract PoCs | `test/audit/reaudit/ReauditPoC.t.sol`: **9/9 pass** (pass = issue exists) |
| Extended invariants | `test/audit/reaudit/ReauditInvariants.t.sol`: `invariant_core` **passes** 512x200 (102,400 calls). The 4 `invariant_EXPECTFAIL_*` **fail as intended**: the fuzzer independently rediscovers N-01, N-05, N-07, N-08 |
| Server | `server/test/audit/reaudit/` (subagent pass, spot-checked): 17/17 tests pass, full server suite 141/141. Details in `SERVER_REAUDIT.md` |

**Bottom line.** The fixes close the original vectors: the manager no longer holds an agent, ownership powers are timelocked, deposits are gated, and NAV is checkpointed. But the new bridge-window and emergency mechanics open two new Critical paths:
- **N-01:** a manager can hold the bridge window open and settle at a frozen NAV, stealing ~25k from an honest 40k deposit in the PoC. With no agent at all.
- **N-02:** one minimum emergency bridge plus an un-cancellable redemption freezes the emergency exit permanently.

N-03 adds a High: a "tightening" that actually lets the owner freeze exits for weeks. On the server, the new monitor revokes the agent of every factory vault on its first pass (SN-01, High). **Do not deploy e68666c.**

Run:
```
cd contracts
forge test --match-path test/audit/reaudit/ReauditPoC.t.sol -vv
forge test --match-path test/audit/reaudit/ReauditInvariants.t.sol -vv    # 4 EXPECTFAIL invariants fail by design
forge test --match-path test/audit/invariants/VaultInvariants.t.sol -vv   # implementer-extended suite, passes
cd ../server && npx vitest run test/audit/reaudit
```

## 1. Verification of the original findings

| ID | Status | Evidence |
|---|---|---|
| C-01 agent NAV deflation | **Fixed (original vector)**, superseded by N-01 | Factory vaults accept only registered platform agents (`HyperVaultFactory.create`, `HyperVault._setAgent:804`); insiders cannot deposit (`:451`); breached vaults settle only in emergency and emergency settles refund deposits (`:546, :555`); NAV checkpoint (`VaultPolicy.nextCheckpoint:220`). `test_AUDIT_C01_*` (inverted) pass. **Bypass attempts:** the ratchet walk-down only works for whoever can move NAV. The manager has no agent, so the remaining actor is a *compromised platform agent*, bounded per day by `maxDailyLossBps` and overall by `maxDrawdownBps` (lifetime peak) (residual R-1). The emergency-path settle pays exits only, at a checkpoint-bounded NAV: no profitable depression found. The insider gate is cosmetic (a sybil address deposits freely, N-09), and N-01 shows the manager no longer needs an agent |
| H-01 instant disarm | **Partially fixed, bypassable** | `clearBreach`/`setAgent`/`exitEmergency`/`setGuardian` are now `onlySelf`; peak never resets; `exitEmergency` blocked with redeemers. **Bypass:** pre-queued (and byte-padded) `clearBreach` items keep a matured clear always available (N-04). The hot platform guardian can still clear instantly (section 4) |
| H-02 window re-arm | **Dust grief fixed; the mechanism regressed** | `MIN_BRIDGE` (`:685, :732`), settle allowed after `MAX_WINDOW_EXTENSION` (`:547`). **But** the window can still be extended indefinitely (each bridge moves `lastBridgeBlock`, `:697`) and settle then prices at the frozen snapshot (N-01). Limiting the non-manager emergency bridge to one per epoch creates a deadlock (N-02) |
| M-01 in-flight double count | **(b) fixed; (a) regressed** | Day roll deferred in flight (`:836`). Masking is now *easier*: inside a held window `checkRisk` sees only the frozen snapshot, so a 60% loss is masked for 100 hours (`test_REAUDIT_N01b_heldWindowMasksBreach`) |
| M-02 retroactive fee raise | **Fixed** | `setFees` reverts in flight (`:1004`); `test_AUDIT_M02_*` passes |
| M-03 no expiry | **Fixed** | `GRACE_PERIOD` on vault queue and policy (`:983`, `VaultPolicy._checkEta:323`). Rolling re-queues are still possible but visible (N-04) |
| M-04 contract-path limits | **Fixed** | Projected leverage at `max(limit, mark)` (`VaultPolicy.checkOrder:187-194`). Flatten capped by `policy.maxFlattenSlippageBps` (creator-set, at most 20%, visible to depositors) on curated assets only |
| M-05 perf fee at spikes | **Bypassable** | External `accrueFees` is management-only, but `lowerFees(current, current)` passes its `>` check and `_setFees` crystallises the performance fee instantly (N-05). The implementer's M-05 regression test passes partly *because of* N-08 (the HWM is ratcheted without a fee) |
| L-01 notional at limit | **Fixed** | `max(limitPx, mark)` |
| L-02 previews | **Fixed via lens** | `HyperVaultLens.preview*` include pending fees; the vault's own previews remain fee-unaware (documented). The lens previews shares during emergency although settle refunds deposits (N-15, Info) |
| L-03 fee dilution as drawdown | **Fixed** | Peak scaled by the dilution (`:650`) |
| L-04 view double count | **Fixed, but stale** | In-window NAV is the snapshot (`:354`), with no double count. The snapshot ignores the flows settled inside the window (N-01) |
| L-05 negative perp equity | **Fixed** | Netted sum (`:410-412`) |
| L-06 agent before account | **Fixed** | `_setAgent` after seed and HYPE (`:337`). HL behaviour (A-13) is still unverified |
| I-01 event | Fixed | `ProtocolShareLowered` (`:672`) |
| I-02 size | Worse | 83 B left |
| I-03 renounce | Fixed | `renounceOwnership` reverts |
| I-04 / I-05 / I-07 / I-08 | Unchanged | Accepted |
| I-06 factory hostile params | **Fixed**, new issue N-06 | Platform guardian forced, curated assets, platform max cap, platform-only agents. The guardian is now immutable per vault (N-06) |
| D-1 agents unbounded | **Mitigated** | Managers never hold an agent. The platform still does (server compromise = section 4) |

Server S-01..S-17: S-01, S-06, S-07, S-09, S-10, S-12, S-13, S-14, S-15, S-16, S-17 fixed; S-02 fixed but causes SN-03; S-03, S-05, S-08, S-11 partial; S-04 not fixed (design). Evidence in `server/test/audit/reaudit/SERVER_REAUDIT.md`.

## 2. New findings

| ID | Title | Severity | PoC | Location |
|---|---|---|---|---|
| N-01 | Held-open bridge window: settle inside it prices at a frozen snapshot that ignores settled flows; sybil steals deposits; breaches masked | **Critical** | `test_REAUDIT_N01_*`, `N01b` passing; `invariant_EXPECTFAIL_N01` fails | HyperVault.sol:354, 547, 596, 692-698 |
| N-02 | One non-manager emergency bridge per epoch + all-or-nothing settle = permanent emergency deadlock | **Critical** | `test_REAUDIT_N02_*` passing | HyperVault.sol:722-726, 561-562 |
| N-03 | Lowering `maxNavMoveBps` counts as "tighter": the owner instantly freezes all settlement (incl. emergency) for weeks | **High** | `test_REAUDIT_N03_*` passing | VaultPolicy.sol:220-237, 354-358 |
| N-04 | Pre-queued / byte-padded `clearBreach` defeats the breach timelock; daily-loss limit reset on demand | Medium | `test_REAUDIT_N04_*` passing | HyperVault.sol:889-896, 964-988 |
| N-05 | `lowerFees(current, current)` crystallises the performance fee at any instant (M-05 bypass) | Medium | `test_REAUDIT_N05_*` passing; `invariant_EXPECTFAIL_N05` fails | HyperVault.sol:945-948, 1020-1027 |
| N-06 | Platform guardian immutable per vault: a leaked online guardian key can never be rotated out; it can perma-grief governance | Medium | `test_REAUDIT_N06_*` passing | HyperVault.sol:926-931; Factory `setPlatformGuardian` |
| N-07 | Platform agents are a global set: any registered agent can be put on any vault; unregister does not revoke | Low | `test_REAUDIT_N07_*` passing; `invariant_EXPECTFAIL_N07` fails | Factory `registerPlatformAgent`; HyperVault.sol:803-808 |
| N-08 | Management-only accrual ratchets the HWM without charging the performance fee: anyone erases the manager's performance fee | Medium | `test_REAUDIT_N08_*` passing; `invariant_EXPECTFAIL_N08` fails | HyperVault.sol:647-648 |
| N-09..N-15 | See 2.9 | Info | - | - |

### N-01 (Critical): Held-open bridge window, settlement at a frozen NAV

**Description.**
- `_openWindow` (692) snapshots `equityAtBridge` only when no window is open, but *every* bridge moves `lastBridgeBlock`. A manager who bridges `MIN_BRIDGE` (100 USDC) every 10 blocks keeps `bridgeInFlight()` true indefinitely.
- After `MAX_WINDOW_EXTENSION` (30 blocks) `settle()` is allowed inside the window (547) and prices at `totalAssets() == equityAtBridge` (354).
- `settle()` never adds the flows it applies to the snapshot: minted deposits and paid redemptions don't change it. It also re-anchors `checkpointNav = totalAssets()` (596), the stale value, so the next in-window settle passes the checkpoint check too.

**Impact.** Theft by a third-party manager without any agent, plus disabled risk limits.
- **Deposits:** in the PoC (10k vault) an honest 40k deposit settles fairly at the frozen 10k NAV. The manager's sybil then deposits 40k and settles again in the same window, priced as if bob's 40k did not exist. After the window: real NAV 90k, sybil 72,000 (+32k), bob 14,400 (−25.6k), alice 3,600 (−6.4k).
- **Risk masking:** while the window is held, `checkRisk` sees only the snapshot. A 60% loss is never breached over 100 hours (N01b), which also re-opens M-01a.
- Even an honest manager's routine bridging misprices any in-window settle once the market moves.

**Exploit.**
1. Manager calls `bridgeToEvm(100e6)` and repeats every ≤10 blocks.
2. Honest deposits queue.
3. After 30 blocks the manager calls `settle()`.
4. The sybil calls `requestDeposit`; the manager settles again in the same window.
5. The manager stops bridging; real NAV appears and the sybil redeems.

**PoC.** `forge test --match-test test_REAUDIT_N01 -vv`. Root cause: the window is extendable and the snapshot is never reconciled with settled flows.

**Fix.**
- **(a)** Make the window non-extendable. Revert `bridgeToCore`/`bridgeToEvm` while `bridgeInFlight()` (the dust grief that motivated extension is now handled by `MIN_BRIDGE`), and add a cooldown: no new manager bridge within `BRIDGE_SETTLE_BLOCKS` after a window closes if a settlement is pending and overdue.
- **(b)** Never settle on the snapshot. Remove the in-window settle path, *or* in `settle()` adjust the snapshot by flows: `equityAtBridge = equityAtBridge + depIn - redAssets` before computing the checkpoint and stored NAV.
- **(c)** In `checkRisk`, evaluate breaches on `min(snapshot, idle + coreEquity())` so a held window can never hide a loss.

(a)+(c) is the minimal safe set. Byte cost of (a): one condition per bridge function.

### N-02 (Critical): Emergency bridge deadlock

**Description.** In emergency, a non-manager may call `bridgeToEvm` only once per epoch (`_lastEmergencyBridgeEpoch`, 724). `settle()` reverts unless liquidity covers **all** pending redemptions (562), and the epoch only advances on a successful settle, so the slot never reopens.

**Impact.** Permanent freeze of the depositors' exit whenever the manager is absent or malicious, which is exactly when emergency is used.
- **Griefing:** a griefer, typically the manager's sybil holding some shares, front-runs the rescuer with `bridgeToEvm(100e6)` and keeps their own redemption pending. Alice can cancel hers, but the sybil's ~100k redemption can never be covered. In the PoC the epoch is stuck for 30 days with bob's rescue bridge reverting `NotReady` every day.
- **Without an attacker:** an honest rescuer who bridges while positions are still open (withdrawable < equity; flatten orders are delayed on HyperCore) consumes the slot short and creates the same deadlock.

**PoC.** `test_REAUDIT_N02_emergencyBridgeSlotDeadlock`.

**Fix.**
- Drop the per-epoch limit and rate-limit by blocks instead: allow a non-manager emergency bridge whenever `!bridgeInFlight()`. `MIN_BRIDGE` already prevents dust.
- And/or let emergency settlement pay redemptions **pro rata** to available liquidity: `redAssetsPaid = min(redAssets, available)`, burning only the proportional shares and leaving the rest pending.

### N-03 (High): `maxNavMoveBps` tightening freezes all exits

**Description.**
- `_isTighter` treats a lower `maxNavMoveBps` as stricter, so the owner can set it to **1 bps instantly**.
- `settle()` (overdue, emergency, everything) then requires NAV within 0.01% of the checkpoint.
- `checkRisk` moves the checkpoint at most 0.01% per hour.

**Impact.** After any ordinary market move the vault cannot settle for weeks. In the PoC, a 4.5% move (under every breach limit) followed by emergency, a full rescue bridge and 14 days of hourly keeper calls still reverts `NavMoved`; the checkpoint is still at 966,861 vs 955,000. A 10% gap takes ~40 days. The manager keeps accruing management fees meanwhile. Any honest vault with a small `maxNavMoveBps` suffers the same in a fast market.

**PoC.** `test_REAUDIT_N03_navMoveTighteningFreezesExits`.

**Fix.**
- Treat `maxNavMoveBps` as liveness-critical: lowering it must be timelocked (reverse its direction in `_isTighter`), with a floor in `_validate` (e.g. ≥ 500 bps).
- Never apply the NAV bound to emergency or overdue settles that only pay redemptions. Price those at `min(nav, checkpoint)` instead of reverting: conservative for exits, no liveness loss.

### N-04 (Medium): Pre-queued `clearBreach`

`queue()` accepts `clearBreach` at any time. `execute` calls `address(this).call(data)`, and trailing bytes are ignored, so `abi.encodePacked(selector, n)` creates unlimited distinct ids for the same call. An owner who keeps one matured item inside the 14-day grace period can clear any breach in the same block. In the PoC, 11.6% is lost in one day through a 5% daily limit. The drawdown limit still holds, because the peak is never reset. **Fix:** record `breachedAt` and require in `clearBreach` (self path) `queuedAt(id) > breachedAt` (store the queue timestamp, or require `eta >= breachedAt + timelockDelay`). Reject `data.length != 4` for `clearBreach`/`exitEmergency` (exact calldata length per selector).

### N-05 (Medium): `lowerFees` with unchanged values crystallises the performance fee

`lowerFees` only checks `>`, so passing the current rates is accepted, and `_setFees` runs `_accrueFees(true)`. The owner takes the performance fee at any transient high, instantly. The PoC keeps 66,667 USDC from a one-block 50% spike. **Fix:** require at least one strictly lower rate, and crystallise only the **management** fee in `_setFees`; the performance fee crystallises at the next settle at the old rate (store `perfBpsForNextSettle`).

### N-06 (Medium): Platform guardian cannot be rotated

`vault.guardian` is copied at creation and `setGuardian` reverts on factory vaults, so `factory.setPlatformGuardian` only affects new vaults. If the online guardian key leaks, it stays guardian of every existing vault forever. It keeps pause, revoke, triggerBreach, **triggerEmergency at will** (exit is timelocked and blocked with redeemers) and **`cancel` of every owner timelock item**, including recovery items. That is a permanent governance and operations lock across the platform. It also keeps `cancelOrder` and flatten at `maxFlattenSlippageBps`. Rotating the factory value does remove its *instant clearBreach* (`_isPlatformGuardian`). PoC `test_REAUDIT_N06_guardianCannotBeRotated`. **Fix:** read the guardian from the factory (`guardian()` returns `factory.platformGuardian()` for factory vaults), so the factory owner (cold multisig) can rotate. Split the roles as in section 4.

### N-07 (Low): Global agent registry

`isPlatformAgent` is a global set. Any vault owner can timelock-approve any registered agent, including the one serving another tenant, and `unregisterPlatformAgent` leaves it approved on every vault that uses it. The server's foreign-agent detection is the only control. **Fix:** register agents bound to a vault (`agentVault[agent] = predictedVault`, checked in `_setAgent`). Have `unregister` emit per-vault revocation tasks, or let the guardian revoke in batch.

### N-08 (Medium): HWM ratchets without a performance fee

`_accrueFees(false)` still runs `if (newPrice > highWaterMark) highWaterMark = newPrice` (648). Anyone calling the external `accrueFees()` at a high moves the HWM up without charging the performance fee. In the PoC a real, lasting 50% gain yields 100,010 of performance fee honestly and 10 after a stranger's `accrueFees()`. Depositors benefit, but the fee guarantee (and the manager's economics) is broken, and the HWM can be pinned to a transient spike forever. **Fix:** update the HWM only when `withPerformance`.

### 2.9 Informational

| ID | Item |
|---|---|
| N-09 | The insider deposit gate is bypassed by any sybil address; do not rely on it (C-01 safety now rests on platform-only agents + checkpoint) |
| N-10 | A breach blocks **all** non-emergency settlement, redemptions included, until someone may trigger emergency (overdue). With the lifetime-peak drawdown a breach is sticky: clearing it re-breaches at the same NAV, and recovery needs a timelocked looser policy. Document it for depositors |
| N-11 | `_claimable` refunds `r.depositAssets` whenever `e.depositShares == 0`, but a *non-emergency* epoch with rounding-to-zero shares never reserved that USDC (`claimableRedeemAssets += depAssets - depIn` is 0). Degenerate states only, but the claim would draw on other users' reserves or underflow |
| N-12 | `nextCheckpoint` returns unbounded when `checkpointAt == 0 \|\| prev == 0` (first settle, or after NAV hits 0) |
| N-13 | Removing an asset from the factory curation list or lowering `maxDepositCap` does not propagate to existing policies or vaults |
| N-14 | 83 B of EIP-170 headroom. The N-01/N-02/N-04/N-05 fixes must be byte-neutral or move logic into VaultPolicy (as `nextCheckpoint`/`flattenOrder` already do) |
| N-15 | During emergency the lens `previewDeposit` still quotes shares while settle refunds; the UI should key off `emergency()` |
| R-1 | Residual C-01: a *compromised platform agent* (server) can still deflate NAV (agentSendAsset, spot) by up to `maxDailyLossBps` per day without a breach, ratchet the checkpoint, and settle a sybil deposit at the discount. Bounded by limits and the monitor; see section 4 |

## 3. Invariant suite (extended)

`test/audit/reaudit/ReauditHandler.sol` extends the implementer's `VaultHandler` (which already added: insider deposits, hide/unhide of Core funds, guardian ops, timelock-only owner ops, dust bridges, checkpoint-bound and emergency-refund checks) with:
- `keeperHour` (ratchet step)
- `holdWindowSettle` (manager holds the window past `MAX_WINDOW_EXTENSION` with an honest deposit, then settles in it)
- `lowerFeesSame`
- `accrueManagementOnly`
- `registrarOps` (register, queue `setAgent` to another platform agent, unregister the live agent)

| Invariant | Result (512 runs x 200 depth) |
|---|---|
| `invariant_core`: reserved USDC backed; vault-held shares cover owed shares; claimable USDC covered; holders' value ≤ NAV; breach ⇒ no agent; emergency ⇒ breached; protocol share ≤ creation rate; guardian fixed; no early/late/forbidden timelock execution; no instant owner power; emergency settles mint nothing; no settle while breached outside emergency; deposit gate; no dust bridge | **PASS** (102,400 calls, 0 reverts) |
| `invariant_EXPECTFAIL_N01_noStaleWindowSettle` | **FAIL** (shrunk to 4 calls): fuzzer finds N-01 |
| `invariant_EXPECTFAIL_N05_noPerfFeeOutsideSettle` | **FAIL** (shrunk to 12): N-05 |
| `invariant_EXPECTFAIL_N07_agentStillRegistered` | **FAIL** (shrunk to 9): N-07 |
| `invariant_EXPECTFAIL_N08_hwmOnlyWithFee` | **FAIL** (shrunk to 10): N-08 |

The implementer's `VaultInvariants` (same base properties plus checkpoint band, peak-scaling, emergency mint checks) also passes 512x200. It could not see N-01, because inside a held window both its "before" and "after" prices come from the same stale view. Once the fixes land, invert the four EXPECTFAIL invariants into ordinary ones.

## 4. Online keys: role analysis and recommendation

Facts (server re-audit, spot-checked):
- **Guardian key** is used only for `revokeAgent`, fired automatically by the new monitor on any "hard" finding (foreign agent, any non-USDC spot balance, any other-dex balance). The server never calls `clearBreach`, pauses, `triggerEmergency`, `cancel` or `flatten`.
- **Registrar key** calls `registerPlatformAgent` on every unauthenticated launch reservation and `unregister` on conflicts.
- All keys live in one process with every agent key, and nothing enforces that they are distinct.
- **SN-01 (High, verified in code):** every factory vault holds HYPE on Core (`initialize` funds gas; 0.01 HYPE observed on the mainnet vault), and `foreignSpotBalances` flags it (`info.ts:126-130`, `monitor.ts:118-121`). The monitor therefore revokes the agent of **every** factory vault on its first pass, and anyone can force a revoke on any vault by spot-sending dust. Exclude HYPE (and a dust threshold) before enabling the monitor.

**What a full server compromise gives, per key:**
- **Agent keys:** any trade on every served vault; value moved by wash trades or `agentSendAsset`. Bounded only by `checkRisk` frequency and the daily/drawdown limits (R-1).
- **Guardian key:**
  - instant `clearBreach`. A breach already revoked the agent, so this alone does not restore trading, but it does reset the daily baseline, so combined with an owner's queued `setAgent` the daily-loss limit becomes meaningless;
  - `cancel` of every owner timelock item and repeated `triggerEmergency`: a permanent governance and operations lock on every vault, which can't be undone because of N-06;
  - flatten into attacker liquidity at `maxFlattenSlippageBps`.
- **Registrar key:** register attacker agents; any colluding owner (or a fresh attacker vault at `create`, with no timelock) then gets a manager-held agent back. That reopens C-01 for those vaults, bounded by the checkpoint and limits. It can also unregister legitimate agents and break launches.

**Recommendation.**
1. **The hot guardian must not have `clearBreach`.** Split the role:
   - `sentinel` (hot, the monitor): `revokeAgent`, `setDepositsPaused(true)`, `setTradingPaused(true)`, `triggerBreach`, `cancelOrder`. Every power only reduces risk, and each is idempotent and safe to automate.
   - `guardian` (cold multisig): `clearBreach`, `cancel(id)`, `triggerEmergency`, custom-slippage `flatten`.
   - `clearBreach` itself should additionally require either the cold guardian or an owner queue item created **after** the breach (N-04 fix). Instant clearance has no operational need that a cold multisig can't meet within hours.
2. Both roles **rotatable by the factory owner** (cold multisig) for existing vaults (N-06 fix): vaults read them from the factory.
3. **Registrar:** bind each agent to the predicted vault address at registration (N-07). Cap registrations per hour onchain or behind authentication (SN-05). Keep it in a separate signer, or remove it entirely by letting `create()` derive the agent from a server signature over `(predictedVault, agent)` checked against a cold signer key.
4. Agent keys in a KMS or HSM signing service that re-checks the vault policy, separate from the web process. Enforce distinct addresses for all online keys at boot (SN-08).

## 5. Updated fix list (append to FIXES.md; ordered)

| # | Finding | Functions | Tests that must pass after the fix |
|---|---|---|---|
| 1 | N-01 | `bridgeToCore`, `bridgeToEvm`: revert while `bridgeInFlight()`. `settle`: remove the in-window path, or reconcile `equityAtBridge += depIn - redAssets`. `checkRisk`: breach on `min(totalAssets(), idleAssets() + coreEquity())` | `test_REAUDIT_N01*` inverted (2nd settle reverts or prices at real NAV; breach fires); `invariant_EXPECTFAIL_N01` passes; `test_AUDIT_H02_*` adjusted |
| 2 | N-02 | `bridgeToEvm`: replace the per-epoch slot with `!bridgeInFlight()`. Optionally pro-rata emergency redemption in `settle` | `test_REAUDIT_N02_*` inverted (rescue bridge succeeds, alice/mallory2 settle) |
| 3 | N-03 | `VaultPolicy._isTighter`: lower `maxNavMoveBps` is a loosening. `_validate`: floor. `settle`: emergency/overdue exits priced at `min(nav, checkpoint)` instead of reverting | `test_REAUDIT_N03_*` inverted; `test_AUDIT_C01*` still pass |
| 4 | N-04 | `queue`: exact length for no-arg selectors. `clearBreach`: require the queue time to be after `breachedAt` | `test_REAUDIT_N04_*` inverted; `test_AUDIT_H01*` pass |
| 5 | N-05 | `lowerFees`: require a strict decrease. `_setFees`: management only | `test_REAUDIT_N05_*` inverted; `test_AUDIT_M02_*`, `M05` pass; `invariant_EXPECTFAIL_N05` passes |
| 6 | N-08 | `_accrueFees`: HWM update only if `withPerformance` | `test_REAUDIT_N08_*` inverted; `invariant_EXPECTFAIL_N08` passes; `test_AUDIT_M05_*` rewritten to assert no fee at the spike **and** the fee charged on a lasting gain at settle |
| 7 | N-06 + section 4 | `guardian`/`sentinel` read from the factory; split powers; remove instant guardian `clearBreach` | `test_REAUDIT_N06_*` inverted; new sentinel/guardian permission tests |
| 8 | N-07 | Factory `registerPlatformAgent(agent, vault)`; `_setAgent` checks the binding | `test_REAUDIT_N07_*` inverted; `invariant_EXPECTFAIL_N07` passes |
| 9 | Server SN-01 (High) | `monitor.ts`/`info.ts`: ignore HYPE, dust threshold, only act on deltas | `REAUDIT_N1_*` inverted |
| 10 | Server SN-02..SN-09, S-03/S-05/S-08/S-11 partials | see SERVER_REAUDIT.md | server reaudit tests inverted |

Byte budget: 83 B. Items 1, 2 and 6 are roughly byte-neutral (condition swaps and deletions). Move the clearBreach/queue checks (item 4) and the guardian lookup (item 7) into VaultPolicy or the factory, as was done for `nextCheckpoint`.
