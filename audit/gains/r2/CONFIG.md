# Gains round 2, domain CFG (3.4): upgrades, timelock, configuration

**Internal, AI-assisted review. Not an independent audit.** Sub-reviewer CFG, worktree `dv-audit-gains-r2`, branch
`audit/gains-r2` from 4ec6feb. Live reads at Arbitrum blocks 516,384,440 to 516,385,550 (public RPC
`https://arb1.arbitrum.io/rpc`, 2026-10-19).

Tests: `contracts/test/audit/gains/r2/ConfigTimelock.t.sol` (5) and `ConfigLevers.t.sol` (8), all on the mock
harness (GovBase / GainsBase). On-chain verification: `contracts/audit/gains/r2/cfg/` (`verify-onchain.sh`,
`compare.js`, `srchash.js`, raw outputs in `cfg/data/`).

**Run** (worktree, forge lock held, 2026-10-19 22:17 to 22:23): `forge test --skip Conservation Econ FundFlowR2
GainsSide Keys Live --match-path "test/audit/gains/{r2/Config*,gov/Governance,gov/PolicyMatrix,gov/FactoryMatrix,fixes/R2Regression}.t.sol" -vv`.
Result: **6 suites, 55 passed, 0 failed, 0 skipped**. That is my 13 tests plus the 42 round-1 and fix-round tests this
report cites. Output: `cfg/data/forge-run.txt`. The `--skip` was needed because two other reviewers' in-progress r2
files did not compile at that moment (`ConservationHandler.sol`: a shadowed `wait`; a fork base: an address checksum).
I did not touch them.

## Bottom line

- **Code and wiring cannot change.**
  - The live vault and policy are canonical EIP-1167 clones of the implementations in `arbitrum.json`.
  - All seven deployed contracts (both implementations, three libraries, factory, lens) are byte-for-byte equal to the
    4ec6feb build, with the libraries linked from the artifacts' link references.
  - Neither the vault nor the policy has a setter for its diamond, policy, factory, asset or libraries.
  - Prices and the sequencer feed change only through the owner's timelocks.
  - Initializers cannot be re-run.
- **Factory changes cannot move depositor value or lock exits.** What reaches an existing vault is the instant
  rotation of the two platform roles, the recipient of the protocol's own fee shares, and a lowering of the protocol
  share.
- **The timelock does NOT always leave a depositor time to exit.**
  - **GR2-CFG-01:** the factory and the webapp accept a policy timelock shorter than the epoch. A redeemer can then
    sit under a loosened policy, with no exit, for up to 29 days.
  - **GR2-CFG-02:** a loosening that raises `maxEpochDuration` turns an overdue epoch back into a current one. Even on
    the live vault's shape, the redeemer gets only a 24 h window to protect herself.

No ALERT: the live vault has timelock 2 days and epoch 1 day, so CFG-01 does not apply to it. Its only holders today are
the owner and the protocol.

## Findings

| Id | Title | Severity (proposed) | PoC | Run |
|---|---|---|---|---|
| GR2-CFG-01 | Policy timelock shorter than `maxEpochDuration` is accepted: a redeemer is trapped behind a loosening for up to E − T (29 days) | Medium | `ConfigTimelock.t.sol::test_GR2_CFG_01_timelockShorterThanEpoch_redeemerTrappedBehindLoosening` (control `test_GR2_CFG_01_control_timelockAtLeastEpoch_redeemerPaidBeforeEta`) | passed |
| GR2-CFG-02 | A loosening that raises `maxEpochDuration` makes an overdue epoch current again: it re-enables new risk and removes the stranger's emergency trigger | Low | `ConfigTimelock.t.sol::test_GR2_CFG_02_epochRaiseInLooseningLiftsAnOverdueEpoch` (control `test_GR2_CFG_02_control_emergencyInsideTheWindowSurvivesTheApply`) | passed |
| GR2-CFG-03 | The platform has no veto on policy-side queues (config, allowAsset, timelock delay); re-allowing an allowed pair is a second feed rotation outside the guardian-cancellable vault queue | Info | `ConfigLevers.t.sol::test_GR2_CFG_03_reAllowOfAnAllowedPairRotatesTheFeed_guardianCannotCancel`, `test_GR2_CFG_cancelRights` | passed |

### GR2-CFG-01 (Medium): timelock shorter than the epoch traps redeemers behind a loosening

**Location.**
- `GainsVaultFactory.create` (`GainsVaultFactory.sol:288`, `:305`): it checks `timelockDelay` (1 to 30 days,
  `GainsVaultPolicy.sol:145`, `GainsVaultGovernance.sol:70`) and `maxEpochDuration` (1 h to 30 days,
  `GainsVaultPolicy.sol:477`) independently.
- `GainsVaultPolicy.proposeConfig` / `applyPendingConfig` (`:329-350`).
- Exit gates:
  - `GainsVaultLogic.settle` `:223-232` (the platform roles settle exit-only only if the epoch is overdue or in
    emergency);
  - `GainsVaultGovernance.triggerEmergency` `:258-260` (a stranger only if overdue with redemptions pending);
  - `GainsVaultMath.epochOverdue` `:183-185`.
- The broken guarantee is written in `GainsVaultPolicy.sol:19-20`: "loosening waits for a timelock so depositors
  always get time to exit". Threat-model T7 assumes "depositors watch queued loosening".

**Scenario** (the brief's worst case; numbers from the PoC):
1. A vault is launched with T = 1 day and E = 30 days. Owner = manager = fee recipient, as on the live vault.
2. Alice deposits 10,000 USDC.
3. At t0 the owner:
   - settles normally, so the epoch restarts at t0;
   - calls `setOperator(0)` (instant);
   - proposes a loosening: 3x → 12x leverage, daily-loss and drawdown breakers at 100%;
   - also queues `setFees(500, 3000)`.
4. Alice requests redemption of all her shares at t0.
5. From t0 to t0 + 30 days, every path is refused:
   - `triggerEmergency` by alice or a stranger: NotOverdue;
   - exit-only settle by the guardian or sentinel: Unauthorized;
   - settle by the removed keeper: Unauthorized.
6. At t0 + 1 day anyone applies the loosening. The 12x open that was refused one second earlier is now accepted, with
   alice's USDC as collateral.
7. ETH falls 5%. checkRisk records only a leverage breach. That breach is reduce-only and settles normally, so it still
   gives alice no exit.
8. At t0 + 30 days alice triggers the emergency herself, the guardian closes the trade and settles, and alice is paid
   **3,984.89 USDC of 10,000**.
9. Meanwhile the management fee at the raised 5% was minted to the owner for 29 days.

**Worst case over the factory's extremes** (`test_GR2_CFG_table_worstCaseTrap`, hours). The redeemer asks right
after the queue, and the epoch was restarted at the queue. E_new = 30 days is always available to the owner, because
the loosening itself may raise E.

| T \ E_old | 1 h | 1 d | 2 d | 7 d | 30 d |
|---|---|---|---|---|---|
| 1 d | window 23 h; trapped 696 h if nobody acts | race at the same second (T = E); then 696 h | **trapped 24 h** (E unchanged) / 696 h | **144 h** / 696 h | **696 h** |
| 2 d (webapp, live) | window 47 h; else 672 h | **window 24 h; else 672 h** (live) | race; else 672 h | **120 h** / 672 h | **672 h** |
| 7 d | window 167 h; else 552 h | window 144 h; else 552 h | window 120 h; else 552 h | race; else 552 h | **552 h** |
| 30 d | safe (window 719 h) | safe | safe | safe | race; else 0 |

How to read the table:
- **Bold** = trapped with no self-help possible (T < E_old), even if E is not raised.
- "window" = the time between the epoch becoming overdue and the eta. Inside it the redeemer must trigger the
  emergency herself.
- "race" = overdue and eta fall in the same second. The owner can put `applyPendingConfig` first in the block.

**Reachability.**
- `GainsLaunch.tsx:225` hard-codes `timelockDelay = 2 days`, and `:233` lets the launcher type any epoch length in
  days (default 1). So any webapp launch with an epoch of 3 days or more has T < E.
- Neither the vault page banner (`VaultCards.tsx:219-224`: leverage, daily loss, drawdown only) nor the executor
  warns about this. The executor has no handler or alert for `ConfigQueued`, `AssetAllowQueued` or `TimelockQueued`;
  they appear only in `server/src/history/`.

**What is new against prior docs.**
- HL `VERIFY.md` (W-01) and HLO-03 record "timelock ≥ 1 day shorter than the epoch (up to 30 days)" only for the
  HL round 4 emergency-exit path and for 30-day epochs as a policy-envelope item.
- Neither applies it to the policy loosening path, and nothing in Gains rounds 1 and 2 does.
- New here:
  - a loosening applies while a redemption that was asked **before** the queue is still unpayable;
  - the exposure has a length (E − T, up to 29 days) and a measured loss;
  - the factory and the webapp both admit the configuration.

**Impact × likelihood.**
- Impact: up to 100% of each redeemer's position is exposed to a risk policy she tried to leave, for up to 29 days. The
  12x / −5% PoC loses 60%. On top comes up to 0.24% of NAV of extra management fee (5% − 2% over 29/365 years).
- The attacker gains no USDC directly: Gains' counterparty is the gToken vault. The owner's gain is the
  performance-fee option on the gamble.
- Likelihood: needs a hostile owner (T7) and a vault launched with E > T. No such vault is live. Launch is allowlisted
  (one launcher).
- By the letter of the scale, "temporary lock with no exit" is High. Medium is proposed because the lock ends at a
  known time and the cold guardian can end it at any moment with `triggerBreach` / `triggerEmergency`, if it watches
  (it currently gets no alert). The lead may raise it.

**Fix** (any one):
1. Require `timelockDelay ≥ maxEpochDuration` (+ margin) in `create`, in `proposeConfig` (against the new E and against
   the policy's own delay), in `proposeTimelockDelay` and in the vault's `setTimelockDelay`.
2. Measure a loosening's eta from max(queue + T, epochStartedAt + E + margin), so every redemption asked before the
   queue reaches an overdue epoch first.
3. Let a redemption asked before a queued loosening be force-settled (exit-only) by anyone once the loosening's eta
   passes.

Also: show E and queued `allowAsset` items in the vault banner, and alert the guardian on `ConfigQueued` /
`AssetAllowQueued`.

### GR2-CFG-02 (Low): raising `maxEpochDuration` in a loosening lifts an overdue epoch

**Location.**
- `GainsVaultMath.epochOverdue` reads `policy.maxEpochDuration()` live, and overdue is not sticky.
- `GainsVaultPolicy.applyPendingConfig` (`:343-350`).

**Scenario** (live vault's shape, T = 2 days, E = 1 day; PoC `test_GR2_CFG_02_*`):
1. The owner settles, removes the operator and queues a loosening with E raised to 30 days and 12x leverage. Alice
   redeems at t0.
2. At t0 + 1 day the epoch is overdue: `triggerEmergency` by alice works (shown on a state snapshot).
3. If nobody acts before t0 + 2 days, anyone applies the loosening at the eta.
4. The epoch is current again:
   - `triggerEmergency` → NotOverdue;
   - the platform's settle → Unauthorized;
   - the manager's new risk is accepted again (12x opened, notional > 100k).
5. Alice waits until t0 + 30 days.

**Control.** An emergency triggered inside the window survives the apply: `ReduceOnlyMode`, then the guardian pays
alice in full (`test_GR2_CFG_02_control_*`).

**New.** The overdue state can be undone by a queued config. Prior docs treat "overdue" as the depositor's guaranteed
backstop (FIXES-R1 §6: "once an epoch is overdue, the vault takes no new risk until it is settled").

**Impact × likelihood.** The same exposure as CFG-01 for 30 − T days. It needs a hostile owner and nobody (redeemer,
sentinel, guardian) acting within the T − E_old window. That window is 24 h on the live vault. No platform role
automates the overdue path: `treasury/epochPlan.ts:211` tells users to "wait for the overdue path". Low.

**Fix.** Use the E in force when the epoch started (store `epochDeadline` at settle), or make a loosening of E apply
only from the next epoch.

### GR2-CFG-03 (Info): no platform veto on policy-side queues; a second feed-rotation path

- `GainsVault.cancel` (owner or guardian) covers the vault queue only.
- `cancelPendingConfig`, `disallowAsset` (which drops a queued allow) and re-proposing the timelock delay are
  owner-only. The guardian and sentinel get `OwnableUnauthorizedAccount` (`test_GR2_CFG_cancelRights`; round 1 showed
  the config half in `test_GOV_PL_..._guardianCannotCancel`).
- The platform's only counter to a queued loosening is a full stop. A full stop does survive the apply
  (`test_GR2_CFG_cancelRights`, last block).
- `queueAllowAsset(pair)` is accepted for a pair the policy already allows. `allowAsset` then re-copies the factory's
  current feed and band.
  - The PoC goes band 20 → 30 bps with a new feed, and NAV steps down at an executor-chosen moment.
  - This is a feed rotation that bypasses the guardian-cancellable `setPairFeed` path.
  - It needs the cold factory owner to have re-curated the pair, which is GR1-40's trust boundary.
- Fix (optional): `queueAllowAsset` reverts for an allowed pair; let the guardian cancel policy queues.

## Question 1: can code, policy, libraries, feeds or the trusted diamond change without the timelock?

**No.** Evidence, all read-only:

| Check | Result |
|---|---|
| Live vault [an earlier vault] runtime | `0x363d3d373d3d3d363d73` + the [an earlier vault implementation] address + `5af43d82803e903d91602b57fd5bf3`: the canonical EIP-1167 clone of the GainsVault impl in arbitrum.json (93 hex chars incl. 0x, `cfg/data/vault.hex`) |
| Its policy [an earlier policy] (`vault.policy()`, `factory.policyOf(vault)`) | the EIP-1167 clone of [an earlier policy implementation] (`cfg/data/policy.hex`) |
| Implementations, libraries, factory, lens vs the deploy build (4ec6feb, `out/` of the deploying checkout) | **full byte equality, CBOR metadata included, for all 7** (`cfg/data/compare-deploybuild.txt`). GainsVault: 48 link refs filled with GainsNav / Logic / Governance. Logic: 5 (Nav). Governance: 6 (Nav, Logic). Lens: 2. The library call-protection immutable equals each library's own address. Factory immutables = vaultImpl [an earlier vault implementation], policyImpl [an earlier policy implementation], USDC `0xaf88…5831`, diamond `0xFF16…f169`. |
| The same against an independent build (scratch: `git archive 4ec6feb`, same lib commits, solc 0.8.28, via_ir) | **equal for all 7 with the CBOR metadata stripped** (`compare-scratchbuild.txt`). The metadata hash differs only because the scratch build's metadata carries absolute-path remappings of the scratch directory. Every source hash in the deploy build's metadata equals the scratch build's: 179 / 179 (`srchash-deploybuild-vs-archive.txt`), so the deploy build compiled exactly the 4ec6feb sources. |
| Sizes chain = build | vault impl 18,984 B, policy 12,936, Nav 12,340, Logic 21,919, Governance 12,871, factory 12,203, lens 10,938 |
| SELFDESTRUCT / CALLCODE in code sections (PUSH data skipped) | 0 in all 7 |
| DELEGATECALL | Vault 49, Logic 8, Governance 6, Lens 3; 0 in policy, factory, Nav. `src/gains` contains no `delegatecall` keyword and no assembly call. Solidity emits DELEGATECALL here only for linked-library calls, whose targets are the PUSH20 link constants verified above. The clone delegates to its baked-in implementation. |
| Proxy admin / upgrade | EIP-1967 implementation and admin slots are 0 on clones and impls (`init.txt`). No `upgradeTo*`. Both NatSpecs say "Not upgradeable". |
| Initializers | OZ `_initialized` = 1 on the vault and policy clones and `0xffffffffffffffff` on both impls. `eth_call` `initialize(...)` on the policy clone and the impl → `0xf92ee8a9` InvalidInitialization (`init.txt`). |
| Storage-held trusted addresses | `$.asset/policy/diamond/factory/collateralIndex` are written only in `GainsVaultGovernance.initialize` (grep). Policy `factory`, `vault` are init-only. `_feeds[pair]` is written only by `_allow` (init, `allowAsset`: timelocked) and `setPairFeed` (vault-only = vault queue). `sequencerFeed` is written only by init and `setSequencerFeed` (vault-only, queue-time snapshot GV-03). Live: `vault.diamond()` = `factory.diamond()` = `0xFF16…f169`; policy feeds = factory curation for 0 / 1 / 33; sequencer = `0xFdB6…697D`, grace 3600 (`reads.txt`). |

**Outside the contracts (trust, unchanged):**
- Gains can upgrade its diamond facets behind its own timelocks (T2; GR1-08 covers ABI changes).
- Chainlink's proxy owners can change the aggregators behind the feeds and the sequencer feed without any vault
  timelock (T4; decimals change GR1-13 fixed).
- Circle can upgrade USDC (T5).

## Question 2: what the timelocks can do, and the exit window

**Vault queue** (`GainsVaultGovernance.queue :346-371`): owner only; exact lengths; id = keccak(data).
- The whitelist: setManager / setFeeRecipient / setTimelockDelay / setAgent (36), setFees (68), clearBreach (4),
  setSequencerFeed (68, must equal the factory's current feed and grace at queue time, grace 1 h to 1 day), setPairFeed
  (132).
- Execute: anyone, in [eta, eta + 14 d]. Cancel: owner or guardian.
- `clearBreach` counts only if queued after the breach.
- Round-1 tests re-run here: `test_GOV_TL_queue_ownerOnly_exactSelectorsAndLengths`, `_dirtyBitsNeverExecute`,
  `_duplicateIdRequeueResetsEta_executeWindow_cancel`, `_failedExecuteKeepsTheItem`; GV-03 in `R2Regression`
  (8 / 8 pass).

**Policy:**
- `proposeConfig`: tighter on every field → instant (and drops any pending loosening); otherwise queued at
  `now + policy.timelockDelay`.
- `queueAllowAsset`: timelocked.
- `proposeTimelockDelay`: raising is instant, lowering is timelocked by the current delay.
- All appliers are anyone within 14 days.

**The two timelocks are separate** (`test_GR2_CFG_vaultAndPolicyTimelocksAreIndependent`). They start equal. The
policy's can be raised instantly while the vault's raise is itself queued.

**Fees.**
- A performance-fee raise is only scheduled. It switches inside the next settle that charged the running epoch at the
  old rate, and an emergency settle never switches it. A trapped redeemer is never charged the new performance rate.
- A management-fee raise applies at execution, after crystallising the old rate. A trapped redeemer pays it for the
  trap (CFG-01, ≤ 0.24% of NAV over 29 days).

**Exit window.**
- Worst case as modelled: owner = manager, operator removed instantly, no manager settle.
- A redeemer's protection exists only if T ≥ E_old, and then only if someone triggers the emergency or settles exit-only
  inside [epochStart + E_old, queue + T). See the table in CFG-01 and the PoCs.
- Without anyone acting (or with T < E_old) the trap lasts until epochStart + E_new, with E_new up to 30 days.
- `setManager` / `setAgent` loosenings: the agent must be a platform agent bound to this vault, and the new manager
  trades under the same policy. In a T < E vault, though, the change applies while a pre-queue redeemer still cannot
  leave.

## Question 3: factory levers on existing vaults

PoC `test_GR2_CFG_factorySettersReachExistingVaultOnlyThroughLiveRoles`, `test_GR2_CFG_agentRegistrationOnExistingVault`,
plus round-1 `GovFactoryMatrixTest` (12 / 12 re-run).

| Lever (factory owner unless noted) | Effect on an existing vault | Instant? | Moves value? | Locks exits? |
|---|---|---|---|---|
| setGuardian / setSentinel | `guardian()` / `sentinel()` read live: every platform power moves at once; the old key loses them | yes | no: neither role can move USDC except by closing trades (≤ 3% custom slippage, guardian, emergency) | no (neither role can block a redemption; GR1-04 fixed) |
| setAgentRegistrar | none (registrar binds new launches / replacement agents) | yes | no | no |
| setProtocolFeeRecipient | the protocol's fee shares at the next accrual go to the new address | yes | protocol's own share only | no (a share mint, no callback; zero refused) |
| setShares | none (share locked at create; `baseShareBps` stored) | — | no | no |
| lowerProtocolShare | lowers that vault's protocol share; raising reverts InvalidShare | yes | in the manager's favour only | no |
| setMinSeedUsdc / setMinAgentGas / setLauncherAllowed / setOpenLaunch | create only | — | no | no |
| setSequencerFeed | none until the vault owner queues the same values (GV-03) | via vault queue | no | no |
| setAssetCurated (re-curate) | none: the policy keeps its copied feed; only setPairFeed / re-allow adopt it (timelocked) | via queue | via the band step (GR1-35 class) | no |
| setAssetCurated (de-curate) | the pair stays allowed, valued and tradeable in the vault (N-13); setPairFeed and queueAllowAsset revert AssetNotCurated (`test_GOV_FR_queuedRotationFollowsTheCurationAtExecute`). With a dying feed, settle waits for a flatten (GR1-09) | yes | no | delays settle only if the feed also dies (GR1-09, known) |
| setMaxDepositCap lower | the vault's cap and deposits up to it are unchanged; `setDepositCap` above the new maximum reverts; 0 freezes every setDepositCap (I3-05, known) | yes | no | no |
| transferOwnership | two step, no hot role as owner | on accept | no | no |
| registerPlatformAgent (registrar / owner) | binds only; the vault owner still needs `setAgent` through the queue, guardian-cancellable; agentOfVault desync (GR1-29, accepted) | yes | no | no |
| unregisterPlatformAgent | registrar: LiveAgent for a live agent; owner / guardian / sentinel: revokes the live agent at once (risk reducing) | yes | no | no |

## Question 4: policy configuration

- **`_isTighter`** (`test_GR2_CFG_isTighterFieldByField`, 16 cases): each field's tight direction applies at once and
  the loose direction queues. `maxNavMoveBps` is reversed (raising is the tightening, N-03; its use as a C-01 lever is
  the known residual in HL-RETEST). A mixed proposal queues as a whole.
- **`applyPendingConfig`** re-checks the NAV bound for every listed pair (GR1-31 fixed; `test_GOV_PL_loosening_boundAtApply_*`).
  `_validate` is not re-run, but its constants cannot change. Not re-checked: whether a redemption from before the
  queue has been paid (CFG-01) and whether the epoch is overdue (CFG-02).
- **`disallowAsset`** (instant) with an open trade (`test_GR2_CFG_disallowAssetWithOpenTrade`):
  - the trade keeps its feed and value, and exits work;
  - open, increase and leverage-up are refused ("asset not allowed"), while a leverage decrease (adds margin) is
    allowed;
  - it drops a queued allow, and re-allowing needs the timelock.
- **setPairFeed:** no queue-time check. At execution the values must equal the factory's current curation, the pair
  must be listed and curated, and the NAV bound must hold (fail-closed, round-1 test). **setSequencerFeed:** checked at
  queue time and adopted as queued (GV-03); grace is bounded at both ends.
- **14-day grace:** identical for all four queues. A stranger executes at eta + 14 d; at eta + 14 d + 1 s all four
  revert Expired (`test_GR2_CFG_graceWindowsAllFourQueues`).
- **Cancel rights:** see CFG-03.
- **Queue ids:** exact-length calldata per selector, so no padding variant exists. Dirty upper bits make a new id that
  fails at execute with no state change. Re-queuing identical data overwrites (a later) eta. Ids cannot collide across
  selectors because the selector is part of the hashed data.
- **Execution by anyone and the chosen moment:** the moment matters for setPairFeed (GR1-35, known), for a
  re-allow-as-rotation (CFG-03), for `applyPendingConfig` against an overdue epoch (CFG-02), and for the moment a
  management raise starts. Nothing else.

## Config lever table

T_v = vault timelock, T_p = policy timelock (both 2 d live), E = maxEpochDuration (1 d live).

| Lever | Who | Instant / timelocked | Can move value | Can lock exits | Depositor exit window |
|---|---|---|---|---|---|
| proposeConfig, tighter | owner | instant | no (E down can make the epoch overdue → anyone triggers emergency; deposits refunded) | no | n/a |
| proposeConfig, maxNavMoveBps up | owner | instant (N-03) | C-01 residual (known) | no | none (known) |
| proposeConfig, looser | owner; apply: anyone | T_p, 14 d grace | market exposure beyond what was accepted | **yes, if T_p < E (CFG-01) or E is raised and nobody acts (CFG-02)** | max(0, T_p − E_old) to self-trigger the emergency |
| queueAllowAsset / allowAsset | owner; anyone | T_p | new pair exposure; feed and band step (CFG-03, GR1-40) | as above | as above |
| disallowAsset | owner | instant | no | no | n/a |
| proposeTimelockDelay | owner; anyone | raise instant, lower T_p | no | no | n/a |
| setPairFeed | owner queue; anyone | T_v, guardian-cancellable | band step (GR1-35) | no | T_v − E |
| setSequencerFeed | owner queue | T_v, queue-time snapshot | no | no | — |
| setFees raise | owner queue | T_v; performance from the next normal settle | management fee ≤ 5%/yr | no | T_v − E |
| lowerFees | owner | instant | in depositors' favour | no | — |
| setManager / setAgent / setFeeRecipient | owner queue | T_v, guardian-cancellable; setAgent refused in a full stop | no direct | no | T_v − E |
| setTimelockDelay | owner queue | T_v | no | no | — |
| clearBreach | owner queue (after the breach) / guardian | T_v from the breach / instant | no | no | — |
| setOperator(0) | owner | instant | no | removes the keeper's settle (used in CFG-01) | — |
| setDepositCap / pauses / triggerBreach / triggerEmergency | owner (+ platform) | instant | no | no (exits never gated) | — |
| vault transferOwnership | owner | two step | no (policy follows, GR1-12) | no | — |
| Factory setters | factory owner | see Q3 | protocol share only | no | — |

## Open questions

1. Should the guardian get a veto on policy-side queues? That is a design decision; see CFG-03.
2. The executor and the webapp are out of this domain (EXE): no alert on policy `ConfigQueued` / `AssetAllowQueued` /
   `TimelockQueued`; the vault banner omits E and queued allowAsset items; no automated sentinel response to an
   overdue epoch with redemptions pending. Each of these widens CFG-01 / CFG-02 in practice. I did not test the
   executor.

## Caps, tools not run

- No heavy tools (fuzzing, mutation, Halmos) in this domain.
- No fork tests: the bytecode checks were direct RPC reads, and the mocks cover the logic.
- `cast keccak` on CRLF source files did not reproduce solc's source hashes, so the source identity was shown by
  comparing two builds' metadata hashes (solc's own), not by hashing the files.
- The independent build's CBOR differs for the stated reason only. Equality is claimed without CBOR for that build, and
  with CBOR for the deploy build.
