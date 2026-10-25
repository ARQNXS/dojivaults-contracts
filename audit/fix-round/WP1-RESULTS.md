# WP1: Hyperliquid contract fixes in `contracts/src` (round 2 fix round)

Internal, AI-assisted work. It is not an independent audit and must not be presented as one.

Branch `fix/r2-hl-contracts` from origin/main 872b5bf, worktree `dv-fix-r2-hl`. Nothing was pushed, merged, deployed
or sent; no env file or hosting setting was touched; no `server/` or `webapp/` change.
Plan: `docs/fix-round/ROUND2-FIXES.md` (section 2 decisions, WP1).

Base note:
- origin/main moved to 0529f1a during this work. That commit merged the second one-job proof of the review stack
  (`fixes/results/integrated-contracts-s0.*`): the same patches at 4d242c7; 889 passed; the 25 failures were exactly
  the superseded PoCs; fix tests 58/58.
- It changes no patch, no `contracts/src`, `contracts/test` or `contracts/script` file. It changes only results and
  the text of ROUND2.md and the a-series README.
- So this branch applies exactly the stack that proof passed, and it does not overlap with 0529f1a.

## In plain words

- Every Hyperliquid contract fix from the round 2 review is now in `contracts/src`:
  - **exit before effect (H01).** A change that adds risk waits max(timelock, epoch + 1 day), and each epoch's
    deadline is fixed when it starts. The same code covers Gains CFG-01.
  - **The five contract Mediums:**
    - E01: the checkpoint walk before an exit settle;
    - E06: an owner's stop pays redeemers;
    - H04 with XF01: a 330-block cooldown on emergency bridges;
    - HLO-07: the 24 h agent warm-up with veto;
    - XA01: deposits held after a platform revoke.
  - **The XF02 close band.**
  - **HL-PROXY.** The agent orders only through `placeOrder`. No API wallet, the account mode is pinned and guarded,
    orders are IOC only and the TIF is checked.
  - **The A-series:**
    - A01: a retryable revoke;
    - A04: a strict landing check;
    - A02 / A08: a hold of up to a day, ended early by the guardian with `writeOffBridge()`, with the seed bridge
      exempt;
    - A05: no new bridge while a transfer is unresolved.
  - **The first mint with no shares left.** Leftover NAV above 10 USDC goes as shares to the guardian, with an event.
- **New in this task: two limits on the platform agent's orders.**
  - A turnover budget: 20× NAV of opened notional per rolling 24 h.
  - An order-rate cap: 120 orders that add risk per sliding hour.
  - Both are policy settings. Tightening is instant; loosening waits the exit-before-effect notice. Closing and
    de-risking are never limited.
- **The superseded PoCs are gone or inverted.** Each one was first shown to fail against the new code (logs below).
  The suite has no expected failures left.

## 1. What went in (commits on `fix/r2-hl-contracts`)

| Commit | What | Source |
|---|---|---|
| 83a7cc4 | H01 + Gains CFG-01, E01, E06, H04/XF01, HLO-07, XA01, XF02; the integrated test adaptations; fix tests | `fixes/integrated/CONTRACTS.patch` + `CONTRACTS.tests.patch`, `fixes/tests/*`, `fixes/integrated/tests/*`, `fixes/tests-xfix/XFIX*.t.sol` (clean 3-way) |
| 52cdf65 | HL-PROXY | `fixes/patches/proxy/HL-PROXY.contracts.integrated.patch` (clean), `tests-proxy/HLPROXY.fix.t.sol` |
| 0cc4e93 | A01, A04, A02/A08, A05, seed exempt | `fixes/patches/a-series/HLR2-A-SERIES.integrated.patch` + tests patch (**2 conflicts**, section 2), A-series fix tests |
| 01770d2 | First mint at supply 0 (D18) | `HLR2-A08-SUPPLY0.integrated.patch` (clean), its fix test |
| 8f77fa9 | NEW: agent turnover budget and order-rate cap | no prior patch (section 3) |
| d96354f | Cross-review follow-ups (section 4) | |
| 69acb76 | No product-vault names in `contracts/test` | rule |
| 3a0688e | Async simulator under HL-PROXY (section 5) | |
| fc5ba81 | gains-r2 config tests under the shared exit-before-effect rule | sub-agent, section 5 |
| 7a3ede2, 3963242 | Comment fix; superseded PoCs removed or inverted, old-agent-model tests adapted | section 5 |
| fcdbf23 | Five more gains-r2 config-timing tests the first full run found | section 5 |

`contracts/src` files changed: HyperVault, HyperVaultLens, VaultGovernance, VaultLogic, VaultMath, VaultPolicy,
VaultTypes, hypercore/HyperCore, and the seven `src/gains` files of CFG-01 (GainsTypes, GainsVault,
GainsVaultGovernance, GainsVaultLens, GainsVaultLogic, GainsVaultMath, GainsVaultPolicy).

## 2. Conflicts and how they were resolved

Each patch was applied with `git apply --3way` in the order the task gives. The integrated patch, HL-PROXY and the
supply-0 patch applied cleanly. The A-series patch was written on the integrated stack without HL-PROXY, and it
conflicted in two places. Both were resolved as a union that keeps both fixes' intent. No two fixes contradict each
other.

| # | Where | Ours (HL-PROXY) | Theirs (A-series) | Resolution |
|---|---|---|---|---|
| 1 | `VaultTypes.sol`, end of `VaultStorage` | `uint64 modePinnedAt` | `int256 cashAtBridge`, `bool cashKnown`, `bool creditSeen`, `bool debitSeen`, `bool bridgeWrittenOff` | Union: `modePinnedAt`, then the A-series fields. Supply-0 later appends `everMinted`, then WP1 appends `agentFlow`. New deployments only (clones are never upgraded), so the order is free. |
| 2 | `VaultLogic.settle`, after the bridge-in-flight check | mode guard `if (!exitOnly && modeSuspect()) revert AccountModeMismatch();` then `_pinMode` | `if (bridgeUnresolved()) revert TransferUnresolved();` | Union, in this order: `TransferUnresolved` first (A08: every settle waits, exits included), then the mode guard (exit-only never gated, HL-PROXY), then the pin (every settle that passes the checks pins). |

Semantic checks on the hunks that applied cleanly (done by the implementer and repeated by the cross-review):
- **`_revokeAgent` (A01) against HL-PROXY.**
  - A01 re-sends action 9 on every revoke, but it names a burn address, never the agent.
  - HL-PROXY keeps that burn on purpose (HL-PROXY.md 5.1).
  - `HlR2Encoding` now asserts that every action 9 is the burn.
- **A03 / A04 under HL-PROXY.** A04 is not dead code: the manager's `moveUsd` perp to spot still raises spot alone,
  and the cash-sum check catches it. The A03 / A04 agent routes exist only on vaults with an API wallet.
- **The mode guard runs before `syncBridge` in `_check`.** That is harmless, because `settle` syncs on its own.
- **The supply-0 rule** is independent of the other patches.

## 3. The two new limits and their defaults

**Where.**
- `VaultPolicy.AgentLimits {uint32 maxTurnoverBps; uint16 maxOrdersPerHour}` sits beside `RiskConfig`, so the launch
  ABI (`CreateParams.risk`) is unchanged. Every policy starts at the defaults in `initialize`.
- `proposeAgentLimits`:
  - the owner only;
  - instant when both fields are tighter or equal (a queued loosening is then dropped);
  - otherwise queued with `_noticeEta`, the same exit-before-effect notice as `queueAllowAsset`.
- `applyAgentLimits` (anyone, after the eta, within the 14-day grace) and `cancelAgentLimits` (owner).
- Ceilings: 100× NAV and 1,000 orders an hour. Zero in either field means the agent opens nothing.
- The check runs in `VaultLogic.placeOrder`, after the policy, warm-up, breach and mode checks, and only for the
  agent's orders that are not reduce-only.
- Usage is kept in `VaultStorage.agentFlow`: 24 hourly buckets (hour, orders, opened notional), two per storage word.
- Refusals: `OrderRejected("turnover")` and `OrderRejected("order rate")`.
- New view: `HyperVault.agentFlow()` returns (opened notional in the rolling 24 h, orders in the sliding hour).
- `setAgent` gives a new agent a fresh budget.
- Gas (HL-PROXY gas test, mock precompiles, at 8f77fa9): the agent's open costs 578,510 with the limits, against
  510,313 before (+68k: 12 bucket words read and 1 written, plus the NAV reads). It fits a 3M-gas small block.

**Turnover budget: default 20× NAV of opened notional per rolling 24 hours.**
- It has the same shape and the same number as the Gains review (GR2-KEY-01b, `TURNOVER_NAV_MULTIPLE = 20`):
  - Gains refills a token bucket linearly;
  - HL uses 24 hourly buckets, as this task specifies.
- **Why 20×.**
  - **Honest use needs about 1×.** The platform strategy opens about 1× NAV a day: 16 orders over about 4 days, about
    0.53× NAV each, at most 8 in a day.
  - **It leaves room for active strategies.** 20× is four full turns of a 5× book a day.
  - **It bounds churn.** At about 10 bps per round trip (4.5 bps taker each side plus spread, HL-PROXY.md 3.4), a
    stolen agent key can burn at most about 2% of NAV a day in fees.
  - **The loss gate does the rest.** Anything beyond fees is bounded by the policy's daily loss through the
    pre-trade `checkRisk`.
- **NAV used.** The order's own read, `idle + coreEquity`. A bridge in flight counts once, as in `checkRisk`:
  `min(visible + amount, equity at the bridge)`.
- **Caveat (cross-review finding 1).** The vault cannot see fills, so an IOC that fills nothing still spends its full
  notional.
  - **Worst case.** A full flip of a 10M vault at 5× in $5M slices, with every IOC retried 4 times, opens $200M =
    20× NAV, which is the whole day's budget.
  - **In practice.** Retries are rare: 0 of 40,000 modelled IOCs left the 1% band (HL-PROXY.md 3.4).
  - **If it binds.** The owner can loosen it through the notice, and the executor can treat `"turnover"` as a
    strategy limit (WP3).
  - **Alternative.** 40× (about 4% of NAV a day in churn fees) if the owner prefers headroom over the tighter bound.
    The recommendation stays 20×, the Gains value.

**Order-rate cap: default 120 orders that add risk per sliding hour.**
- **Data** (a read-only sub-agent, from `server/config/strategies.json`, the executor and the order-history data).
  The window is a 1-hour token bucket per vault.

  | Source | Orders |
  |---|---|
  | Platform strategy, busiest measured hour | 3 |
  | Platform strategy, busiest measured day | 8 |
  | Platform strategy, worst case with 4 IOC tries | about 24 an hour |
  | Copy mirror, a "very active" source | about 21 an hour on average (500 a day) |
  | Risk watcher and treasury runs, worst case | 12 to 36 an hour |

- **Slicing.** There is no slicing in the executor yet (D8 is WP3). A full flip in $5M slices is 2 orders at 1M NAV,
  20 at 10M and 100 at 50M (×4 with every retry). Only the opening side counts against this cap.
- **Why 120.**
  - It is 40× the busiest measured hour.
  - It is 3× the opening side of a full flip of a 10M vault with every IOC tried 4 times (40).
  - Reduce-only orders (closes, trims, loss stops, flattens) are never counted or refused.
- **Window.** A sliding hour: this clock hour's orders, plus the previous hour's weighted by the part of it still
  inside the last 60 minutes, rounded up. So the clock-hour boundary does not double the rate. The approximation can
  admit up to about 1.5× the cap in a true 60-minute window (cross-review finding 5).
- **What it bounds.** Request-budget spam and many small churn cycles. Losses from churn are bounded by the turnover
  budget.
- **Above about 15M NAV,** a full flip needs more than 120 opening slices in an hour. The owner raises the cap through
  the notice, or the executor queues the orders past it.

Fix test `test/audit/hl-r2/fixes/WP1-AGENT-LIMITS.fix.t.sol`, 14 tests:
- defaults;
- the seventh 2.9 BTC open is refused at 20× on 100k;
- the rolling 24 h window;
- the budget scales with NAV;
- a bridge in flight counts in the NAV;
- reduce-only is never counted or refused;
- the manager is not bound;
- the sliding-hour rate, including the boundary;
- a bucket is reused a day later;
- loosening waits `noticeEta`, tightening is instant;
- a tightening drops a queued loosening;
- owner only, within the ceilings;
- a new agent gets a fresh budget;
- gas.

## 4. Cross-review

A sub-agent that did not do the merge reviewed every conflict resolution, the clean hunks for semantic clashes, a
hunk-by-hunk comparison of each source patch with HEAD, the two new limits and defaults, and the naming rules. It was
read-only.

**No blocking issue. All five source patches are present hunk for hunk** (the +/- line multisets of each patch's src
hunks equal its commit; no later commit removes them). Both union resolutions hold.

| # | Severity | Finding | Done |
|---|---|---|---|
| 1 | Medium (default) | Turnover counts submitted IOC notional, so missed retries spend it. A worst-case 10M flip with 4 tries per slice spends the 20× day. | Documented in the code and in section 3; default kept at 20× (rationale above), 40× named as the alternative for the owner. Open item O1. |
| 2 | Low | The turnover NAV read `idle + coreEquity` drops a bridge in flight, causing avoidable refusals. | Fixed (d96354f): the in-flight formula of `checkRisk`. Test `test_WP1_bridgeInFlightCountsInTheNav`. |
| 3 | Low | The agent key can burn the shared budget with far-below-mark buys, and a replacement agent inherits the spent budget. Exits are never blocked. | `setAgent` resets the budget (d96354f), test `test_WP1_newAgentStartsWithAFreshBudget`. A key holder burning its own budget is self-limiting. |
| 4 | Low (plan gap) | D4 asks for a turnover budget **and a minimum holding time** on both venues; HL has no minimum hold. | Not built; WP1's list names turnover and order rate only. Open item O2 for the owner. |
| 5 | Info | The sliding-hour approximation admits up to about 1.5× the cap across a boundary. "1.5× of 80" in the rationale was wrong: only the opening 40 count, so it is 3×. | Rationale corrected in `VaultPolicy`. |
| 6 | Info | Stale comments after HL-PROXY: `agentActiveAt` says syncAgent reverts in the warm-up; `initialize` says "approved by syncAgent()"; the "anyone" role list; `AGENT_NAME`. A caller with no role gets `NotReady` from syncAgent inside the 10-minute interval, so an executor that still calls it as the agent can revert. | Comments fixed (d96354f, 7a3ede2). The executor part is open item O4 (WP3). |
| R | Rules | A product vault's name appeared in the fix tests this branch added, through helpers defined in pre-existing hostile-test bases (about 180 occurrences in 22 test files). No other product-vault name; no "fund" for a vault; no claim of an independent audit. | Renamed to "the platform vault" across `contracts/test` (69acb76). `contracts/src`, `contracts/test` and `contracts/script` now have no hit. |

## 5. Superseded PoCs: shown failing, then removed or inverted

**Proof that they fail against the new code.**
- Targeted run of every file that held one, at 8f77fa9, before any removal: `wp1-logs/poc-proof.txt`.
  - Result: 370 passed, 52 failed, 1 skipped.
  - Every superseded PoC in INTEGRATION.md §4 and HL-PROXY.md §6.2 fails, with the fix's own revert or assertion:
    `CheckpointBehind`, `NotReady`, `TransferUnresolved`, `BridgeInFlight`, `AgentWarmingUp`, `RequestNotSettled`,
    `OrderRejected("tif")`, "16 != 9", and so on.
  - So does every gains-r2 config test that assumed eta = queue + timelock.
- The A-series PoCs and fix tests could not run there: the async simulator's `setUp` waited for a HyperCore approval
  that HL-PROXY no longer sends.
  - After the simulator fix (3a0688e), the seven A-series PoCs failed: `wp1-logs/after-cleanup-1.txt`.
    - A01: "nothing was sent to Core".
    - A02 ×3 and A05: `TransferUnresolved`.
    - A04: "landing latched".
    - A08: `BridgeInFlight`.
  - The A-series fix tests passed in the same run.

**Deleted, because a fix test proves the opposite:**

| PoC | Proven opposite by |
|---|---|
| `test_HLR2_H01_*`, `test_HLR2_H01b_*`, `test_XB_H01b_*`, `test_HLR2_E06b_*` | `HLR2_H01_Fix` |
| `test_HLR2_XB01_*` | `HLR2_XB01_Fix` (in HLR2-E01.fix) |
| `test_HLR2_E01a`–`e` | `HLR2_E01_Fix`; E01e also `HLR2_A08_Supply0_Fix` |
| `test_HLR2_E06_fullStopBlocksAllExitsUntilOverdue` | `HLR2_E06_Fix` |
| `test_HLR2_H04_managerBridgeChain*` | `test_HLR2_H04_fix_managerOwnerOperatorCannotChainBridgesInEmergency` |
| `test_HLO07_leakedRegistrarKey*` | `HLO07_Fix`, `test_PROXY_factoryHostedVault_*` |
| `test_HLR2_XA01_revokeOnlyAct*` | `HLR2_XA01_Fix` |
| `test_XF01_*`, `test_XF02_*` | `XFIX_Fix` |
| `test_HLR2_A01_*`, `A02_*` ×3, `A04_*`, `A05_*`, `A08_*`, `test_HLR2_E07_*` | `HLR2_A01_Fix`, `HLR2_A03A04_Fix`, `HLR2_A08_Fix` |
| `test_HLR2_F05_*`, `test_HLR2_ENC09_*`, `test_HLR2_F01_*` | `test_PROXY_agentIsIocOnlyWithItsOwnCloid`, `_action16EncodingIsByteExact`, `_setAgentApprovesNothingOnHyperCore` |
| gains-r2 `test_GR2_CFG_01_*` and `CFG_02_*` (ConfigTimelock); `test_GR2_XR_CFG01_guardianRescueAfterApplyBeforeTheMove` | `GainsCfgFix` (`test_FIX_GR2_CFG_01_*`, `_02_*`); the rescue's setup can no longer occur |
| gains-r2 `test_GR2_XR_03_ownerKey_instantEpochTightening_exitOnlyWithoutEmergency` (XReviewKey; failed `Unauthorized` in the first full run) | `test_FIX_GR2_CFG_tighteningAppliesFromTheNextEpoch` |

**Inverted or adapted (property kept, new rule asserted):**

| Test | Change |
|---|---|
| `test_XB_H01a_*` | The loosening applies at the stored eta. |
| `HLO07_Fix::test_HLO07_fix_leakedRegistrarLaunchIsInertUntilVetoed` | The warm-up gates the agent's orders; the vetoed key is `Unauthorized` after it. |
| `Verify5PoC` (5) | Inverted: no path ever approves the agent; syncAgent pins; strangers pin once per 10 min. |
| `HyperVault::test_SetAndRevokeAgent`; `PolicyAndFactory` (3); `Round4` (2); `HostileConfig::test_HLR2_C_*`; `HlR2Encoding::test_HLR2_ENC_onlyIds_*` (now `..._13_16_...`, action 9 only for the burn) | syncAgent is the mode pin. |
| `Reaudit2Handler` ghost | syncAgent may only send action 16. |
| `AuditPoC::test_AUDIT_M04b_*` | Counts orders, not every CoreWriter action. |
| `Reaudit2PoC::test_REAUDIT2_N201_*` | Gas metering paused around the 1,000 setup settles (each now pins too). Claim gas is measured as before: 143,998 at 50 and at 1,000 epochs. |
| `HLPROXY_Fix::test_PROXY_factoryHostedVault_*` | The seed bridge window closes before the agent's order (WP1's NAV read). |
| `async/SimBase.t.sol` | The simulator sends the older vault's approval from the vault's address. The A-series still runs against its worst case: an agent with HyperCore powers. |
| gains-r2 `ConfigLevers` (5), `XReviewEconCfg` (3); `FundFlowR2::test_FF_execute_*`, `MutationKills::test_MUT_Policy543_*`, `MutationKills2::test_MUT_PolicyR344_*`, `MutationKills3::test_MUT_Policy591_593_*` (failed `NotReady` in the first full run) | Stored etas (`pendingConfig().eta`, `assetAllowEta`, `queuedEta`, `noticeEta()`) instead of queue + timelock. The mutation tests still kill their mutants: each asserts the same state after the apply. |

Targeted runs after the cleanup: `wp1-logs/after-cleanup-2.txt` (the last three HL files) 36 / 36; `wp1-logs/gains-r2-fix.txt` (the five Gains files and the Gains CFG fix test) 108 / 108.

## 6. Gate: one-job build and whole suite

Both runs: forge 1.8.4, solc 0.8.28 via_ir, one compiler job for the whole tree (270 files: `src`, Gains, scripts,
every test), as the README and the deploy runbook build it: `forge build --force --sizes`, then `forge test`. Taken
under the shared heavy-tool lock (`$TEMP/dv-heavy.lock`).

| Run | Head | Build | Suite |
|---|---|---|---|
| r1 (`wp1-logs/full-r1.*`) | 3963242 | 1,676 s, compiler run successful | 191 suites: 1,099 passed, **5 failed**, 39 skipped |
| **r2, final (`wp1-logs/full-r2.*`)** | **fcdbf23** | 1,512 s, compiler run successful | 191 suites: **1,103 passed, 0 failed, 39 skipped** (1,142 tests) |

- **r1's five failures** were gains-r2 tests that reached main after the HL proofs and that the targeted runs had not
  covered:
  - four timing tests that waited queue + 2 days;
  - the XR_03 PoC.

  fcdbf23 fixes them (section 5).
- **r2's header shows `dirty=1`.** That one file is this report, which is not a source.
- **Fix tests: 91 / 91 pass in r2** (`test/audit/hl-r2/fixes/*` and `test/audit/hl-r2/proxy/*`):
  - the integrated stack's tests;
  - the A-series and supply-0;
  - XFIX;
  - the Gains CFG fix test;
  - HL-PROXY (16);
  - WP1 agent limits (14).
- **No expected failures are left.** The suite has no superseded PoC and no failing test.
- **The 39 skips are all gated.**
  - 34 are fork suites that skip in `setUp` without an RPC (Arbitrum, HyperEVM): mostly Gains, plus one in
    `HlR2FundFlow`.
  - 5 are opt-in probes:
    - the conservation `test_coverage` pair, which needs a raised `FOUNDRY_GAS_LIMIT`;
    - the sensitivity pair;
    - the two `VerifyMixed` smoke tests.

**Build exit code.** `forge build --sizes` exits 1 only because of EIP-170 messages for test handlers, as in every
earlier integrated proof. Every deployable contract is under the limit.

**Sizes** (runtime bytes, r2 build; EIP-170 = 24,576; libraries from `out/`, since `--sizes` does not list linked
libraries):

| Contract | Runtime | Margin | Before WP1 (integrated + A-series + supply-0, no HL-PROXY) |
|---|---|---|---|
| **VaultLogic** (library) | **22,678** | **1,898** (the tightest) | 19,988 |
| HyperVault | 19,821 | 4,755 | 18,852 |
| VaultGovernance (library) | 13,840 | 10,736 | 13,503 |
| VaultPolicy | 12,218 | 12,358 | 10,620 |
| HyperVaultFactory | 10,955 | 13,621 | 10,955 |
| HyperVaultLens | 9,118 | 15,458 | 9,118 |
| GainsVaultLogic (library) | 22,014 | 2,562 | 22,014 |
| GainsVault | 19,037 | 5,539 | 19,037 |
| GainsVaultGovernance (library) | 13,119 | 11,457 | 13,119 |
| GainsVaultPolicy | 13,068 | 11,508 | 13,068 |
| GainsNav | 12,340 | 12,236 | 12,340 |
| GainsVaultFactory | 12,203 | 12,373 | 12,203 |
| GainsVaultLens | 10,631 | 13,945 | 10,631 |

Initcode is under 49,152 for every deployable contract.

**Over the limit (test harnesses, never deployed):**

| Contract | Runtime | Over by |
|---|---|---|
| Reaudit2Handler | 54,262 | 29,686 |
| CIHandler | 51,954 | 27,378 |
| ReauditHandler | 40,163 | 15,587 |
| ConservationHandler | 37,724 | 13,148 |
| SpecHandler | 36,639 | 12,063 |
| VaultHandler | 33,129 | 8,553 |
| GainsHandler | 24,601 | 25 |

## 7. Open items

- **O1. Turnover default.** 20× (recommended, the Gains value) or 40× (room for retried IOC slices): the owner's
  call. Either way the executor must treat `OrderRejected("turnover")` as a strategy limit (WP3).
- **O2. Minimum holding time on HL (D4).** Not built. D4 names it for both venues; WP1's list does not. It needs an
  owner decision. On HL a thief's churn is already bounded by the turnover budget, the loss gate and the circuit
  breaker (WP3).
- **O3. Order-rate cap above about 15M NAV.** A full flip in $5M slices then needs more than 120 opening orders in an
  hour. D8 slicing (WP3) must count slices against the cap and queue, not drop, past it.
- **O4. Executor (WP3).**
  - Send `syncAgent` / `pinAccountMode` from a vault role (keeper or sentinel), not from the agent: a caller with no
    role gets `NotReady` inside the 10-minute interval.
  - Map `OrderRejected("turnover" | "order rate")` and read `agentFlow()`.
  - The async PoC harness models the API-wallet agent; the proxy path's own fuzzing is WP5.
- **O5. Lens / webapp (WP4).** `agentLimits()`, `pendingAgentLimits()` and `agentFlow()` are new reads. The ABIs
  need regenerating for the new errors and events (`AgentLimitsApplied` / `Queued` / `Cancelled`).
- **O6. Audit docs.** The audit write-ups under `contracts/audit/hl-r2/` still name the deleted PoCs and the old test
  names (the pre-rename identifiers of 69acb76, `test_HLR2_ENC_onlyIds_1_7_9_10_13_...`). They were not edited, because audit
  directories are changed only under an explicit audit instruction. This file is the map.
- **O7. Carried from the review.**
  - A03 (Low) stays on API-wallet vaults only.
  - Positions in markets the policy never listed are outside the A04 cash sum.
  - `HyperVaultLens` deposit previews at supply 0 still show the launch rule (a-series README residuals).
- **O8. VaultLogic has 1,898 bytes left.** WP3 and WP4 need no contract change. Any later contract change must
  check its size, or first move code out of it (the agent-limit bookkeeping, about 1 kB, could go to VaultGovernance).
