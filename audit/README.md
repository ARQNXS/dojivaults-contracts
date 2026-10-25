# Security reviews

This directory holds the reports of every completed internal security review of the DojiVaults contracts. The
reviews were done by the team, not by an independent auditor. Each report is kept as written: findings, severities,
scenarios, statuses, fixes and test references are unchanged. Infrastructure detail (hosting, configuration names, key
storage, providers, internal addresses and local paths), strategy names and the addresses of earlier deployments are
replaced with neutral wording or a bracketed label.

Commit hashes in the reports and in this index refer to the private development repository, not to this one. Each
review covers the version at its reviewed commit; the contracts exported here are the round 2 release (private commit
`2bd7e53`), which includes every fix marked "Fixed in" below.

Proofs of concept and regression tests from the reviews are in [`../test/audit/`](../test/audit). Not in this
repository: the executor's proofs of concept (they run against the private executor; their results are in the
reports), the tests of the gTrade VERIFY-R1 pass, which target the code before fix round 2, and the fork tests and
byte-for-byte checks that are tied to earlier deployments (see round 2 below).

**Status** is one of: *Fixed in `commit`* (the commit that changed the code; "(executor)" marks a fix in the off-chain
executor), *Accepted risk*, or *Scheduled for the next contract version*. Where none of these is true the status says
what is: *Open*, *No change* (an observation with nothing to fix), *No issue* (checked and sound), *Superseded by
open launch* (the status rested on the launcher allowlist, which open launch removed) or *Reopened*.

Executor findings are tracked separately; the executor is out of scope for this repository.

## Hyperliquid vault reviews

Supporting documents (no entry of their own): [FIXES.md](FIXES.md) (fix list for the first review), [notes.md](notes.md) and [surface.md](surface.md) (working notes of the first review), [A13-SYNC-AGENT.md](A13-SYNC-AGENT.md) (incident and fix note for the agent approval dropped at creation; it rates no findings; the change it describes was verified in verification pass 5).

### Hyperliquid review round 1 (REPORT.md)

| Date | Scope | Commit reviewed | Critical | High | Medium | Low | Info | Design risk |
|---|---|---|---|---|---|---|---|---|
| 2026-10-05 | HyperVault, HyperVaultFactory, VaultPolicy, the HyperCore library and PxMath; secondary pass on the executor (its findings are in a separate executor report) | `896a0d6` | 1 | 2 | 5 | 6 | 8 | 5 |

| ID | Severity | Finding | Status | Report |
|---|---|---|---|---|
| C-01 | Critical | The agent can move value out of the part of the account the NAV counts, so the manager's deposit settles at a deflated price and takes most of the depositors' money (about 82% in the PoC) | Fixed in `e68666c` (bypass N-01 fixed in `a75d935`) | [REPORT.md §3](REPORT.md#c-01-critical-agent-can-deflate-nav-managers-deposit-settles-at-the-depressed-price) |
| H-01 | High | The owner (the untrusted manager on factory vaults) can instantly undo the risk controls and the emergency path: `clearBreach`, `setAgent` and `exitEmergency` were not timelocked | Fixed in `a75d935` (partial fix in `e68666c`; bypass N-04) | [REPORT.md §3](REPORT.md#h-01-high-owner-instantly-disarms-risk-controls-and-the-emergency-path) |
| H-02 | High | The bridge window can be re-armed with 1e-6 USDC to block `settle()` indefinitely (by anyone in emergency, by the manager always) | Fixed in `a75d935` (dust grief fixed in `e68666c`; regression N-01) | [REPORT.md §3](REPORT.md#h-02-high-bridge-window-re-arming-blocks-settle-indefinitely) |
| M-01 | Medium | The in-flight bound in `checkRisk()` double counts: it masks real breaches and can force false daily-loss breaches | Fixed in `a75d935` (partial fix in `e68666c`; see N-01b) | [REPORT.md §3](REPORT.md#m-01-medium-in-flight-upper-bound-in-checkrisk-double-counts) |
| M-02 | Medium | A timelocked fee raise executed inside a bridge window is applied retroactively | Fixed in `e68666c` | [REPORT.md §3](REPORT.md#m-02-medium-fee-raise-executed-inside-a-bridge-window-is-retroactive) |
| M-03 | Medium | Timelocked changes never expire (vault queue, policy config, asset allow) | Fixed in `e68666c` | [REPORT.md §3](REPORT.md#m-03-medium-timelocked-changes-never-expire) |
| M-04 | Medium | Contract-path trading is weaker than the policy says: flatten up to 20% slippage regardless of policy, and no leverage check per order | Fixed in `e68666c` | [REPORT.md §3](REPORT.md#m-04-medium-contract-path-trading-is-weaker-than-the-policy-says) |
| M-05 | Medium | The performance fee crystallises on transient mark-to-market highs (permissionless `accrueFees`, ratcheting high-water mark) | Fixed in `a75d935` (bypasses N-05 and N-08 after `e68666c`) | [REPORT.md §3](REPORT.md#m-05-medium-performance-fee-crystallises-on-transient-highs) |
| L-01 | Low | The per-order notional cap is measured at the limit price, so deep resting bids carry many times the cap | Fixed in `e68666c` | [REPORT.md §3](REPORT.md#l-01-low-notional-cap-measured-at-limit-price) |
| L-02 | Low | ERC-4626 previews ignore pending fee accrual and differ from what settle pays | Fixed in `e68666c` (previews in the lens; the vault's own previews documented as fee-unaware) | [REPORT.md §3](REPORT.md#l-02-low-previews-differ-from-settle) |
| L-03 | Low | Fee dilution counts as drawdown: anyone can turn a fee accrual into a breach | Fixed in `e68666c` | [REPORT.md §3](REPORT.md#l-03-low-fee-dilution-counts-as-drawdown) |
| L-04 | Low | `totalAssets()` and all conversion views double count inside the bridge window | Fixed in `e68666c` (stale snapshot covered by N-01) | [REPORT.md §3](REPORT.md#l-04-low-views-double-count-in-the-bridge-window) |
| L-05 | Low | Negative perp account value is clamped to 0 while spot is still added, so NAV is overstated | Fixed in `e68666c` | [REPORT.md §3](REPORT.md#l-05-low-negative-perp-equity-ignored) |
| L-06 | Low | `initialize` approves the agent before the deposit that creates the Core account, so the approval may be dropped (conditional) | Fixed in `f11359d` (the reorder in `e68666c` stayed in the creating transaction and was still dropped; see A-13) | [REPORT.md §3](REPORT.md#l-06-low-conditional-agent-approved-before-the-core-account-exists) |
| I-01 | Info | `HyperVault.lowerProtocolShare` emits no event | Fixed in `e68666c` | [REPORT.md §3.4](REPORT.md#34-informational) |
| I-02 | Info | HyperVault had 171 bytes of EIP-170 headroom, too little for the fixes | Fixed in `a75d935` (thin vault and linked libraries; see N-14) | [REPORT.md §3.4](REPORT.md#34-informational) |
| I-03 | Info | Inherited `renounceOwnership` would leave a vault unable to exit emergency, clear a breach or leave hosted mode | Fixed in `e68666c` | [REPORT.md §3.4](REPORT.md#34-informational) |
| I-04 | Info | The first-epoch seed is shared pro rata, so a 1-wei depositor captures about half of the 1 USDC seed | Accepted risk | [REPORT.md §3.4](REPORT.md#34-informational) |
| I-05 | Info | Rounding dust is never released and only grows | Accepted risk | [REPORT.md §3.4](REPORT.md#34-informational) |
| I-06 | Info | The factory accepts any creator-chosen guardian, owner and markets, so the guardian is no depositor protection on factory vaults | Fixed in `e68666c` | [REPORT.md §3.4](REPORT.md#34-informational) |
| I-07 | Info | Any holder of one share unit can trigger emergency as soon as an epoch is overdue by a second | Accepted risk | [REPORT.md §3.4](REPORT.md#34-informational) |
| I-08 | Info | Agent revocation is fire and forget on HyperCore; the contract cannot confirm it | Accepted risk | [REPORT.md §3.4](REPORT.md#34-informational) |
| D-1 | Design risk | Agents are unbounded on chain: an API wallet can trade against a counterparty the manager controls, which is a withdrawal in effect | Accepted risk (mitigated in `e68666c`: managers never hold an agent, platform agents only) | [REPORT.md §4](REPORT.md#4-design-level-risks-not-fixable-by-local-code-changes-alone) |
| D-2 | Design risk | NAV is mark-to-market; thin-market marks can be pushed and redeemers paid value that may not be realisable | Accepted risk (mitigated in `e68666c`: curated markets and a NAV checkpoint) | [REPORT.md §4](REPORT.md#4-design-level-risks-not-fixable-by-local-code-changes-alone) |
| D-3 | Design risk | The creator picks every role, so guardian-based protections mean nothing on factory vaults | Fixed in `e68666c` (platform guardian forced on factory vaults) | [REPORT.md §4](REPORT.md#4-design-level-risks-not-fixable-by-local-code-changes-alone) |
| D-4 | Design risk | CoreWriter actions are fire and forget; revocations, flattens and bridges can fail silently | Accepted risk (mitigated by the executor monitor added in `e68666c`) | [REPORT.md §4](REPORT.md#4-design-level-risks-not-fixable-by-local-code-changes-alone) |
| D-5 | Design risk | The executor holds every hosted agent key, and the policy is enforced only off chain for agents | Accepted risk, mitigation planned: per-vault agent keys and on-chain trade validation (next contract version) | [REPORT.md §4](REPORT.md#4-design-level-risks-not-fixable-by-local-code-changes-alone) |

### Hyperliquid review round 2 (REAUDIT.md)

| Date | Scope | Commit reviewed | Critical | High | Medium | Low | Info |
|---|---|---|---|---|---|---|---|
| 2026-10-05 | The round 1 fix diff `896a0d6..e68666c`: HyperVault, HyperVaultFactory, VaultPolicy, the new HyperVaultLens and the executor; verification of every round 1 finding | `e68666c` | 2 | 2 | 4 | 1 | 8 |

| ID | Severity | Finding | Status | Report |
|---|---|---|---|---|
| N-01 | Critical | A manager can hold the bridge window open and settle inside it at a frozen NAV that ignores settled flows: a sybil steals deposits (about 25k of an honest 40k deposit in the PoC) and breaches are masked | Fixed in `a75d935` | [REAUDIT.md §2](REAUDIT.md#n-01-critical-held-open-bridge-window-settlement-at-a-frozen-nav) |
| N-02 | Critical | One non-manager emergency bridge per epoch plus all-or-nothing settle permanently freezes the emergency exit | Fixed in `a75d935` | [REAUDIT.md §2](REAUDIT.md#n-02-critical-emergency-bridge-deadlock) |
| N-03 | High | Lowering `maxNavMoveBps` counts as tightening, so the owner can instantly freeze all settlement, emergency included, for weeks | Fixed in `a75d935` | [REAUDIT.md §2](REAUDIT.md#n-03-high-maxnavmovebps-tightening-freezes-all-exits) |
| N-04 | Medium | A pre-queued or byte-padded `clearBreach` defeats the breach timelock and resets the daily-loss limit on demand | Fixed in `a75d935` | [REAUDIT.md §2](REAUDIT.md#n-04-medium-pre-queued-clearbreach) |
| N-05 | Medium | `lowerFees` with unchanged values crystallises the performance fee at any instant (bypass of M-05) | Fixed in `a75d935` | [REAUDIT.md §2](REAUDIT.md#n-05-medium-lowerfees-with-unchanged-values-crystallises-the-performance-fee) |
| N-06 | Medium | The platform guardian is fixed per vault: a leaked online guardian key can never be rotated out and can lock governance | Fixed in `a75d935` | [REAUDIT.md §2](REAUDIT.md#n-06-medium-platform-guardian-cannot-be-rotated) |
| N-07 | Low | Platform agents are one global set: any registered agent can be put on any vault, and unregistering does not revoke | Fixed in `a75d935` (residual N2-04) | [REAUDIT.md §2](REAUDIT.md#n-07-low-global-agent-registry) |
| N-08 | Medium | Management-only accrual ratchets the high-water mark without charging the performance fee, so anyone can erase the manager's performance fee | Fixed in `a75d935` | [REAUDIT.md §2](REAUDIT.md#n-08-medium-hwm-ratchets-without-a-performance-fee) |
| N-09 | Info | The insider deposit gate is bypassed by any sybil address | Accepted risk (documented) | [REAUDIT.md §2.9](REAUDIT.md#29-informational) |
| N-10 | Info | A breach blocks all non-emergency settlement, redemptions included, and is sticky under the lifetime-peak drawdown | Accepted risk (documented for depositors) | [REAUDIT.md §2.9](REAUDIT.md#29-informational) |
| N-11 | Info | A non-emergency epoch whose deposit rounds to zero shares refunds USDC that was never reserved | Fixed in `a75d935` | [REAUDIT.md §2.9](REAUDIT.md#29-informational) |
| N-12 | Info | `nextCheckpoint` is unbounded on the first settle or after NAV reaches 0 | Fixed in `a75d935` | [REAUDIT.md §2.9](REAUDIT.md#29-informational) |
| N-13 | Info | Removing a curated asset or lowering the deposit cap on the factory does not reach existing vaults | Accepted risk (documented: future vaults only) | [REAUDIT.md §2.9](REAUDIT.md#29-informational) |
| N-14 | Info | Only 83 bytes of EIP-170 headroom left for the fixes | Fixed in `a75d935` | [REAUDIT.md §2.9](REAUDIT.md#29-informational) |
| N-15 | Info | During emergency the lens still quotes deposit shares while settle refunds deposits | Fixed in `a75d935` | [REAUDIT.md §2.9](REAUDIT.md#29-informational) |
| R-1 | Info | Residual of C-01: a compromised platform agent can still deflate NAV by up to the daily-loss limit per day without a breach and settle a sybil deposit at the discount | Accepted risk (bounded by the risk limits and the monitor; widened per I3-01) | [REAUDIT.md §2.9](REAUDIT.md#29-informational) |
| SN-01 | High | The executor's new monitor would revoke the agent of every factory vault on its first pass (the vault's own HYPE on Core is flagged), and anyone can force a revoke by sending spot dust | Fixed in `a75d935` (executor) | [REAUDIT.md §4](REAUDIT.md#4-online-keys-role-analysis-and-recommendation) |

### Hyperliquid review round 3 (REAUDIT2.md)

| Date | Scope | Commit reviewed | Critical | High | Medium | Low | Info |
|---|---|---|---|---|---|---|---|
| 2026-10-05 | The round 2 diff `e68666c..a75d935`: thin HyperVault with linked libraries, pro-rata emergency settlement, factory-held guardian and sentinel, agent binding, the signed launch statement, executor changes; verification of N-01..N-15 and the executor items | `a75d935` | 0 | 0 | 1 | 3 | 6 |

| ID | Severity | Finding | Status | Report |
|---|---|---|---|---|
| N2-01 | Medium | Claim and cancel cost grows with the number of emergency epochs; a long emergency makes claims cost millions of gas and locks late claimers out | Fixed in `7933fbf` (first fix in `875c1c4` regressed as V-01) | [REAUDIT2.md §7](REAUDIT2.md#n2-01-medium-claim-cost-grows-with-the-number-of-emergency-epochs) |
| N2-02 | Low | A performance fee raise applies to the running epoch's gains, including gains earned under the old rate | Fixed in `875c1c4` (breach-settle regression R3-06 fixed in `2305cf2`) | [REAUDIT2.md §6](REAUDIT2.md#6-fee-rule-a-performance-fee-raise-applies-to-the-running-epoch-n2-02) |
| N2-03 | Low | Custom-slippage `flatten` up to the creator's limit (hard cap 20%) lets the guardian or manager move value to a colluding counterparty | Fixed in `875c1c4` (cap 3%) | [REAUDIT2.md §7](REAUDIT2.md#n2-03-low-custom-slippage-flatten) |
| N2-04 | Low | Launch and rotation statements carry no nonce (replay within 10 minutes), and several agents can be bound to one predicted vault | Fixed in `875c1c4` (contracts and executor; residuals V-02, V-04) | [REAUDIT2.md §7](REAUDIT2.md#n2-04-low-no-nonce-in-the-launch-statement-several-agents-per-predicted-vault) |
| I2-01 | Info | A sentinel that re-breaches hourly invalidates every owner-queued clear | Accepted risk (the factory owner rotates the sentinel) | [REAUDIT2.md §7](REAUDIT2.md#informational-items) |
| I2-02 | Info | Once the epoch is overdue, any stranger's settle refunds all pending deposits, even in a healthy vault | Accepted risk (documented) | [REAUDIT2.md §7](REAUDIT2.md#informational-items) |
| I2-03 | Info | The registrar online key can revoke any live agent through `unregisterPlatformAgent` (denial of service) | Fixed in `875c1c4` | [REAUDIT2.md §7](REAUDIT2.md#informational-items) |
| I2-04 | Info | A fresh vault's first manager settle reverts until `checkRisk` has run once | Fixed in `875c1c4` | [REAUDIT2.md §7](REAUDIT2.md#informational-items) |
| I2-05 | Info | The factory accepts guardian == sentinel (and either equal to the owner or registrar) | Fixed in `875c1c4` (residual V-03) | [REAUDIT2.md §7](REAUDIT2.md#informational-items) |
| I2-06 | Info | The factory owner is an EOA at first deploy with instant role rotation; no ERC-1271 for launchers | Fixed in `875c1c4` (deploy script hands ownership to the guardian) | [REAUDIT2.md §7](REAUDIT2.md#informational-items) |

### Verification pass 1, round 3 fixes (VERIFY.md)

| Date | Scope | Commit reviewed | Critical | High | Medium | Low | Info |
|---|---|---|---|---|---|---|---|
| 2026-10-06 | The round 3 diff `1bd2153..875c1c4`: O(1) pro-rata claims, deferred performance fee raise, 3% flatten cap, one agent per predicted vault, launch nonce, factory role checks, deploy script hand-off | `875c1c4` | 1 | 0 | 0 | 2 | 1 |

| ID | Severity | Finding | Status | Report |
|---|---|---|---|---|
| V-01 | Critical | The survival floor in emergency settlement burns every pending share when the era-wide factor drops below the floor: an unprivileged actor can steer it and wipe a fresh redemption (98.99 USDC paid for shares worth 999,616 USDC in the PoC) | Fixed in `7933fbf` | [VERIFY.md §3](VERIFY.md#v-01-critical-the-survival-floor-burns-honest-redemptions) |
| V-02 | Low | The executor's launch nonce store evicts the oldest nonces and lives in one process, so an attacker can evict legitimate nonces and launches fail until retried | Fixed in `e62baa1` (executor) | [VERIFY.md §3](VERIFY.md#v-02-low-server-nonce-store-eviction-and-single-process-state) |
| V-03 | Info | The factory role checks compare against the current owner, not the pending owner, and `renounceOwnership` is inherited | Fixed in `7933fbf` | [VERIFY.md §3](VERIFY.md#v-03-info-factory-role-checks) |
| V-04 | Low | A compromised registrar key can bind an agent to any predicted vault address: it blocks a launch with that salt and can hand an allowlisted attacker a self-held agent | Fixed in `2305cf2` (binding from a signature in `create`); residual (I3-04) superseded by open launch, see HLO-07 | [VERIFY.md §3](VERIFY.md#v-04-low-registrar-pre-binding) |

### Verification pass 2, V-01 / V-03 fixes (VERIFY.md)

| Date | Scope | Commit reviewed | Critical | High | Medium | Low | Info |
|---|---|---|---|---|---|---|---|
| 2026-10-06 | The diff `e5334a9..7933fbf`: emergency settle as partial fill and return, lens partial-fill views, factory renounce and pending-owner checks, webapp partial-fill banner | `7933fbf` | 0 | 0 | 1 | 0 | 3 |

| ID | Severity | Finding | Status | Report |
|---|---|---|---|---|
| W-01 | Medium | The owner can exit emergency right after each partial fill (a pre-queued `exitEmergency` passes once no shares are pending), freezing exits until the epoch is overdue again | Superseded by open launch, see HLO-07 (fixed in `eeb723c`; first fix in `5dd5a91` bypassed, see W-01b) | [VERIFY.md pass 2 §2](VERIFY.md#w-01-medium-the-owner-exits-emergency-right-after-each-partial-fill) |
| (unnumbered) | Info | Anyone may settle an emergency epoch with zero liquidity and flush the queue (all shares returned whole); griefing only | Fixed in `2305cf2` (round 4 limits settle to the treasury and platform roles) | [VERIFY.md pass 2 §1](VERIFY.md#1-passfail) |
| (unnumbered) | Info | A fairness assertion in the invariant suite is a tautology | Fixed in `5dd5a91` | [VERIFY.md pass 2 §1](VERIFY.md#1-passfail) |
| (unnumbered) | Info | The lens `partialFill` returns 0 once claimed, despite its comment | Open (comment unchanged) | [VERIFY.md pass 2 §1](VERIFY.md#1-passfail) |

### Verification pass 3, W-01 fix (VERIFY.md)

| Date | Scope | Commit reviewed | Critical | High | Medium | Low | Info |
|---|---|---|---|---|---|---|---|
| 2026-10-06 | The W-01 fix `101fb70..5dd5a91`: emergency timestamp for queued exits and the "last fill complete" rule | `5dd5a91` | 0 | 0 | 1 | 0 | 0 |

| ID | Severity | Finding | Status | Report |
|---|---|---|---|---|
| W-01b | Medium | The "last fill complete" condition can be reset by an empty or dust settle, so the owner can still end the emergency right after a partial fill | Fixed in `eeb723c` | [VERIFY.md pass 3](VERIFY.md#w-01b-medium-the-last-fill-complete-condition-can-be-spoofed) |

### Verification pass 4, W-01b fix (VERIFY.md)

| Date | Scope | Commit reviewed | Critical | High | Medium | Low | Info |
|---|---|---|---|---|---|---|---|
| 2026-10-06 | The W-01b fix `6d74c1c..eeb723c`: `exitEmergency` guardian only; traps for owner and manager; bridge window re-arm | `eeb723c` | 0 | 0 | 0 | 1 | 1 |

| ID | Severity | Finding | Status | Report |
|---|---|---|---|---|
| X-01 | Low | Once Core is drained, a griefer can top it up with 1e-6 USDC and bridge the full amount to re-open the bridge window each round, delaying settlement (residual of H-02) | Superseded by open launch, see HLO-07 (fixed in `2305cf2`; round 4 limits bridging to the treasury) | [VERIFY.md pass 4](VERIFY.md#verification-pass-4-w-01b-fix-6d74c1ceeb723c) |
| (unnumbered) | Info | The guardian's exit check looks at the last epoch only, so an empty settle after a partial fill re-opens the gate for the guardian | Accepted risk (guardian runbook) | [VERIFY.md pass 4](VERIFY.md#verification-pass-4-w-01b-fix-6d74c1ceeb723c) |

### Verification pass 5, A-13 agent sync (VERIFY.md)

| Date | Scope | Commit reviewed | Critical | High | Medium | Low | Info |
|---|---|---|---|---|---|---|---|
| 2026-10-07 | The A-13 change `a07d2fd..f11359d`: agent recorded at `initialize`, permissionless `syncAgent()`, executor sync and monitor | `f11359d` | 0 | 0 | 0 | 0 | 1 |

| ID | Severity | Finding | Status | Report |
|---|---|---|---|---|
| (unnumbered) | Info (rated "Low / Info (conditional)") | If HyperCore charges HYPE per CoreWriter action (unverified), repeated `syncAgent` calls could drain the vault's Core HYPE so that a later revoke fails silently | Accepted risk (open non-blocking item; monitor detection, no cooldown added) | [VERIFY.md pass 5](VERIFY.md#verification-pass-5-a-13-agent-sync-a07d2fdf11359d) |

### Hyperliquid review round 4 (REAUDIT3.md)

| Date | Scope | Commit reviewed | Critical | High | Medium | Low | Info |
|---|---|---|---|---|---|---|---|
| 2026-10-08 | The round 4 diff: breach as derisk, treasury operator, settle modes, insider deposits one epoch later, signed agent binding, the deploy and launch scripts, `_rejoinCarry` | `76d012c` plus the uncommitted round 4 diff (committed as `2305cf2`) | 0 | 0 | 1 | 7 | 8 |

| ID | Severity | Finding | Status | Report |
|---|---|---|---|---|
| R3-01 | Medium | The EVM-to-Core landing signal reads Core equity, which moves with unrealised PnL: a late bridge is latched as landed, giving a false NAV drop (false breach) or a settle at an understated NAV | Fixed in `2305cf2` | [REAUDIT3.md §5](REAUDIT3.md#r3-01-medium-evm-core-landing-latched-by-unrealised-pnl) |
| R3-02 | Low | Insider "next epoch" pricing is defeated by two settles in the same block | Fixed in `2305cf2` | [REAUDIT3.md §5](REAUDIT3.md#r3-02-low-insider-deferral-bypassed-by-back-to-back-settles) |
| R3-03 | Low | A second `triggerEmergency` after `exitEmergency` does not restart `breachedAt`, so an owner clear queued between the two emergencies still executes | Fixed in `2305cf2` | [REAUDIT3.md §5](REAUDIT3.md#r3-03-low-second-emergency-does-not-restart-breachedat) |
| R3-04 | Low | `bridgeToCore` and `moveUsd(toPerp)` stay open in a daily-loss or drawdown breach, adding margin for the agent and draining idle USDC from under the redemption-only settle | Fixed in `2305cf2` | [REAUDIT3.md §5](REAUDIT3.md#r3-04-low-margin-can-be-added-in-a-daily-loss--drawdown-breach) |
| R3-05 | Low | A bridge that never lands holds the window for 300 blocks: settle is blocked and a loss of up to the bridged amount is masked from `checkRisk` | Fixed in `2305cf2` (mitigated: window cap 300 to 60 blocks) | [REAUDIT3.md §5](REAUDIT3.md#r3-05-low-an-unlanded-bridge-holds-the-window-300-blocks-and-masks-a-loss-up-to-its-amount) |
| R3-06 | Low | A breach or emergency settle charges no performance fee but still switches on a scheduled raise, so gains earned under the old rate are charged at the new one (N2-02 regression) | Fixed in `2305cf2` | [REAUDIT3.md §9](REAUDIT3.md#new-findings-from-the-fixes) |
| R3-07 | Low | The lens added the performance fee in a breach or emergency while settle charges none, so price and preview figures were off by up to the fee | Fixed in `2305cf2` | [REAUDIT3.md §12](REAUDIT3.md#12-decisions-after-stop-3-implementer-2026-10-08) |
| R3-08 | Low | After the 60-block window a transfer that had not yet landed read as a loss, so a slow but real landing could breach the vault | Fixed in `2305cf2` | [REAUDIT3.md §12](REAUDIT3.md#12-decisions-after-stop-3-implementer-2026-10-08) |
| I3-01 | Info | The C-01 residual is wider: a deflation between the daily and drawdown limits auto-clears at midnight, and the owner's `resume` resets the peak | Accepted risk (documented; the monitor stays on) | [REAUDIT3.md §5](REAUDIT3.md#informational) |
| I3-02 | Info | An insider can stamp a victim's controller "next epoch" with a 1 wei deposit, blocking the victim's `requestRedeem` on it until cancel or settle | Accepted risk (documented) | [REAUDIT3.md §5](REAUDIT3.md#informational) |
| I3-03 | Info | Donations latch either landing signal (costs about the bridged amount, harmless) | Accepted risk | [REAUDIT3.md §5](REAUDIT3.md#informational) |
| I3-04 | Info | A compromised registrar can still sign a self-held agent for an allowlisted attacker's own launch | Superseded by open launch, see HLO-07 | [REAUDIT3.md §5](REAUDIT3.md#informational) |
| I3-05 | Info | The deploy script's and the factory's deposit cap have no upper bound; the 50k limit is a default only | Reopened: premise removed in `0b6a0c0`, reviewed in the next contract version (script bound from `2305cf2`) | [REAUDIT3.md §5](REAUDIT3.md#informational) |
| I3-06 | Info | Test changes: the insider invariant checks epoch numbers only and is blind to R3-02; otherwise no assertion was weakened | Accepted risk (documented) | [REAUDIT3.md §5](REAUDIT3.md#informational) |
| I3-07 | Info | Anyone can arm the one-hour insider delay with a 1 wei deposit for the manager's controller | Fixed in `2305cf2` (10 USDC minimum deposit) | [REAUDIT3.md §9](REAUDIT3.md#new-findings-from-the-fixes) |
| I3-08 | Info | The performance fee on gains realised by redeemers during a breach is never charged | Accepted risk | [REAUDIT3.md §9](REAUDIT3.md#new-findings-from-the-fixes) |

### Round 4 verification pass, fork rehearsal (VERIFY-ROUND3.md)

| Date | Scope | Commit reviewed | Low | Not rated |
|---|---|---|---|---|
| 2026-10-09 | The round 4 contracts, executor and webapp rehearsed together on a local fork of HyperEVM mainnet (45 scenario checks) | the uncommitted round 4 build (committed as `2305cf2` contracts, `c5ef01d` executor) | 1 | 1 |

| ID | Severity | Finding | Status | Report |
|---|---|---|---|---|
| R3-07 | Low | The lens added the performance fee in a breach or emergency while settle charges none (same finding as REAUDIT3 R3-07) | Fixed in `2305cf2` | [VERIFY-ROUND3.md §4](VERIFY-ROUND3.md#4-defects-found-in-this-pass-both-fixed-with-tests) |
| OPS-1 | Not rated | After a margin move the treasury runner re-read Hyperliquid at once and sent the same move again when the balance had not caught up | Fixed in `c5ef01d` (executor) | [VERIFY-ROUND3.md §4](VERIFY-ROUND3.md#4-defects-found-in-this-pass-both-fixed-with-tests) |


## Hyperliquid open-launch review

### Hyperliquid open-launch review (hl-open/REVIEW.md)

| Date | Scope | Commit reviewed | Critical | High | Medium | Low | Info | Info (checked) | Design |
|---|---|---|---|---|---|---|---|---|---|
| 2026-10-19 | The Hyperliquid contracts (outside gTrade) after open launch and the removal of the platform deposit cap | `726378d` | 0 | 0 | 2 | 4 | 5 | 2 | 1 |

| ID | Severity | Finding | Status | Report |
|---|---|---|---|---|
| HLO-07 | Medium | With open launch, a leaked registrar key (online, in the executor) or factory owner key lets any wallet launch a vault whose "platform" agent it holds itself; the PoC takes 10.5% of a 1M depositor's value in one settle at the default policy | Scheduled for the next contract version (round 2, see FIXES.md; the executor alert, HLO-E06, is fixed in `fc02fe3`) | [hl-open/REVIEW.md](hl-open/REVIEW.md#hlo-07-medium-i3-04-reopened-a-leaked-registrar-or-owner-key-gives-any-wallet-a-self-held-agent) |
| HLO-01 | Medium | Launch spam is cheap (about $1.8 per vault, no per-wallet or global limit) and its cost lands on the executor; the factory's `vaults()` view passes a 2M-gas call at 865 vaults | Fixed in `cc7afce` (the `vaults()` reads: paged reads in the webapp, executor and scripts with `8153276`, `e5a0fad`; the on-chain half goes to round 2, see FIXES.md) | [hl-open/REVIEW.md](hl-open/REVIEW.md#hlo-01-medium-launch-spam-is-cheap-its-cost-lands-on-the-executor) |
| HLO-03 | Low | The factory enforces no policy envelope: any launcher may publish 50x leverage, loss and drawdown breakers at 100%, 20% slippage, 30-day epochs and a 100% NAV move per settle, which turns off the NAV checkpoint defence | Scheduled for the next contract version (round 2, see FIXES.md) | [hl-open/REVIEW.md](hl-open/REVIEW.md#hlo-03-low-no-factory-policy-envelope) |
| HLO-02 | Low | Impersonation: name, symbol, owner, manager, fee recipient and the `hosted` flag are free choices, so a vault can name another manager's wallet as owner and manager without consent, with the fees going to the launcher | Fixed in `23721a6` (executor and UI half, with `df9ad5b`: attribution and "hosted" from the executor's tenant and owner consent; `owner == msg.sender` at create is scheduled for the next contract version, round 2) | [hl-open/REVIEW.md](hl-open/REVIEW.md#hlo-02-low-impersonation) |
| HLO-06 | Low (Design) | A large redemption blocks the whole epoch (all or nothing) until it can be paid in full, anyone can stop the vault once the epoch is overdue, and exits valued at mark meet real order-book depth, with the unwind cost borne by the depositors who stay | Scheduled for the next contract version (round 2, see FIXES.md) | [hl-open/REVIEW.md](hl-open/REVIEW.md#hlo-06-low-design-large-exits) |
| HLO-08 | Low (process) | Earlier deploy conditions are unmet: the factory owner and guardian is a single-key wallet (EOA), not a multisig, and V-04 was not fixed before open launch | Open (the move of owner and guardian to the Safe is prepared, not executed; listed under round 2 in FIXES.md) | [hl-open/REVIEW.md](hl-open/REVIEW.md#hlo-08-low-process-unmet-deploy-conditions) |
| HLO-09 | Info | A victim's cancel of an insider-made deposit does not lift the block on the victim's redemption request; the documented "cancellable" mitigation is wrong on HyperVault | Open (the known-issues text corrected in `b071c0b`; no code change) | [hl-open/REVIEW.md](hl-open/REVIEW.md#info-items) |
| HLO-10 | Info | The registrar signature covers only (agent, vault, deadline), not `hosted`, operator, policy or owner; one agent signed for two vaults binds to the first launch | Open (no change recorded in FIXES.md) | [hl-open/REVIEW.md](hl-open/REVIEW.md#info-items) |
| HLO-11 | Info | Lifting the platform cap cannot be recalled for vaults launched meanwhile, and `maxDepositCap = 0` freezes every owner's cap setter | Accepted risk (no platform deposit cap by decision of 2026-10-13; documented in the known issues, `b071c0b`) | [hl-open/REVIEW.md](hl-open/REVIEW.md#info-items) |
| HLO-12 | Info | HyperCore representation limits: at most 184,467,440,737 USDC per bridge call, NAV reads limited to int64 (9.22e12 USDC); not reachable at today's sizes | No change (not reachable at today's sizes, per the report) | [hl-open/REVIEW.md](hl-open/REVIEW.md#info-items) |
| HLO-13 | Info | The protocol treasury receives fee shares of every stranger's vault | No change (observation) | [hl-open/REVIEW.md](hl-open/REVIEW.md#info-items) |
| HLO-05 | Info (checked) | Contract math at scale (precision, fees, overflow, claims) is sound: a 10 USDC depositor next to a 1e12 USDC holder loses nothing to rounding | No issue (checked sound) | [hl-open/REVIEW.md](hl-open/REVIEW.md#info-items) |
| HLO-04 | Info (checked) | Cross-vault isolation holds: a stranger's launch reaches no other vault, factory role or agent | No issue (checked sound) | [hl-open/REVIEW.md](hl-open/REVIEW.md#info-items) |
| D-1/D-5 | Design | The deposit cap was a named mitigation of the agent and executor-key design risks; without it, the blast radius of an agent or executor compromise is the sum of all vaults' NAV | Open (no platform cap by decision of 2026-10-13; no per-vault notional or velocity limit recorded) | [hl-open/REVIEW.md](hl-open/REVIEW.md#33-design-risks) |

### Executor sub-review at 10 / 100 / 1,000 vaults (hl-open/executor/RESULTS.md)

| Date | Scope | Commit reviewed | Critical | High | Medium | Low | Info |
|---|---|---|---|---|---|---|---|
| 2026-10-19 | The executor's Hyperliquid paths (scaling, platform spend, alerts, registrar) after open launch and uncapped deposits | `726378d` | 0 | 0 | 7 | 2 | 1 |

| ID | Severity | Finding | Status | Report |
|---|---|---|---|---|
| HLO-E01 | Medium | Anyone can use up the global launch reservation budget (20 per hour, in memory) for free with a few throwaway wallets; every platform-agent launch then gets 429 | Fixed in `d20496b` (executor) | [hl-open/executor/RESULTS.md](hl-open/executor/RESULTS.md#hlo-e01-medium-the-launch-reservation-budget-is-global-and-free-to-use-up) |
| HLO-E02 | Medium | Hyperliquid info weight has no client-side budget; the executor's loops use up the 1,200/min IP limit at about 20 to 30 vaults, and one 429 stalls every info client on the host, the order path included | Fixed in `b0e5fcc` (executor; read rework with one weight budget, `0892455`, and the core reader, `31daad4`) | [hl-open/executor/RESULTS.md](hl-open/executor/RESULTS.md#hlo-e02-medium-hyperliquid-info-weight-with-no-client-side-budget-and-a-host-wide-429-cooldown) |
| HLO-E03 | Medium | The HyperEVM RPC bucket fills at about 1,000 manual or about 120 served stranger vaults; background work is refused first, so the indexer falls behind and the sentinel stops acting on monitor findings | Fixed in `b0e5fcc` (executor; read rework: batched core reader, `31daad4`, and RPC URL lists, `467caf0`) | [hl-open/executor/RESULTS.md](hl-open/executor/RESULTS.md#hlo-e03-medium-the-hyperevm-rpc-bucket-fills-linearly-background-work-is-refused-first) |
| HLO-E04 | Medium (conditional on E02/E03 or an outage) | An unreadable vault becomes one keeper `checkRisk` transaction per vault per hour, with no cap and no "nothing to protect" skip (about 920 per hour at 1,000 vaults), draining the keeper wallet | Fixed in `3871aff` (executor) | [hl-open/executor/RESULTS.md](hl-open/executor/RESULTS.md#hlo-e04-medium-conditional-unreadable-becomes-one-keeper-transaction-per-vault-per-hour) |
| HLO-E05 | Medium | Alert volume and alert text are in a stranger's hands; the alert channel had no rate limit, priority or retry, so a BREACH alert is dropped after a flood | Fixed in `4bf2b41` (executor, with `95a6f37`) | [hl-open/executor/RESULTS.md](hl-open/executor/RESULTS.md#hlo-e05-medium-alert-floods-stranger-text-in-platform-alerts-and-lost-alerts) |
| HLO-E06 | Low | A new vault naming a platform agent the executor never reserved is stored silently as a manual vault, with no alert and no check of agent registrations | Fixed in `fc02fe3` (executor) | [hl-open/executor/RESULTS.md](hl-open/executor/RESULTS.md#hlo-e06-low-i3-04-under-open-launch-the-executor-does-not-notice-a-foreign-registrar-signature) |
| HLO-E07 | Medium if the HyperCore premise holds (PLAUSIBLE); pre-existing | 1 USD credited to another perp dex of any vault makes the sentinel revoke its agent, if HyperCore lets a third party credit it | Fixed in `397239a` (executor) | [hl-open/executor/RESULTS.md](hl-open/executor/RESULTS.md#hlo-e07-medium-if-the-premise-holds-plausible-pre-existing-1-usd-on-another-perp-dex-revokes-any-vaults-agent) |
| HLO-E08 | Medium (Design) | Detection latency for real vaults grows linearly with the vault count: at 1,000 vaults the monitor looks at a vault every 50 minutes and the risk watcher takes 300 s per round | Fixed in `b0e5fcc` (executor; read rework, the monitor looks at every vault each run, `6a782cc`) | [hl-open/executor/RESULTS.md](hl-open/executor/RESULTS.md#hlo-e08-medium-design-real-vault-latency-scales-with-the-stranger-count) |
| HLO-E09 | Info | Number precision at 1e9 to 1e12 USDC: no issue | No issue (checked) | [hl-open/executor/RESULTS.md](hl-open/executor/RESULTS.md#hlo-e09-info-number-precision-at-large-caps) |
| HLO-E10 | Low (Design) | The platform pays HYPE for every stranger vault (daily fee accruals and operator settles) with no per-vault or global cap | Fixed in `244b4db` (executor) | [hl-open/executor/RESULTS.md](hl-open/executor/RESULTS.md#hlo-e10-low-design-platform-hype-per-stranger-vault) |


## gTrade vault reviews

### gTrade review round 1 (gains/ROUND1.md)

| Date | Scope | Commit reviewed | Critical | High | Medium | Low | Info | Design |
|---|---|---|---|---|---|---|---|---|
| 2026-10-17 | Gains (gTrade) vault contracts and deploy script, plus the executor paths that sign or decide for Gains vaults | `5dd1344` | 0 | 2 | 6 | 14 | 22 | 1 |

Severities are ROUND1's own, after its cross-review ([gains/XREVIEW.md](gains/XREVIEW.md)). The fixes are in [gains/FIXES-R1.md](gains/FIXES-R1.md) and [gains/fixes/EXECUTOR.md](gains/fixes/EXECUTOR.md). The deployed Arbitrum factory includes the round 1 and round 2 fixes (deploy commit `4ec6feb`).

| ID | Severity | Finding | Status | Report |
|---|---|---|---|---|
| GR1-01 | High | Pending leverage-only increases count as zero size, so several sent at once each pass the policy's leverage check and push the vault far above its maximum leverage (manager or one compromised agent key) | Fixed in `d8570e4` (with `c463d86`: one pending order per trade; FIXES-R1 corrects the "about 31x" example to about 16.5x, severity unchanged) | [gains/ROUND1.md](gains/ROUND1.md#gr1-01-pending-leverage-only-increases-add-no-notional-several-bypass-maxleveragebps-high) |
| GR1-02 | High | Deposits and redemptions use the same conservative NAV, so a deposit made while trades are open and redeemed once they close takes value from existing holders; with no minimum epoch age it can be repeated every few minutes, limited only by the daily-loss breaker | Fixed in `c463d86` (two-sided settle pricing and a 1 hour minimum epoch age for settles that mint shares) | [gains/ROUND1.md](gains/ROUND1.md#gr1-02-deposits-mint-at-the-adverse-edge-nav-repeatable-intraday-high) |
| GR1-03 | Medium | The near-liquidation rule counts the price band twice, so very high-leverage trades are valued at zero from the moment they open, which multiplies GR1-02 | Fixed in `d8570e4` | [gains/ROUND1.md](gains/ROUND1.md#gr1-03-near-liquidation-zero-rule-counts-the-band-twice-medium) |
| GR1-04 | Medium | Any pending order blocks every settle, including the emergency exit-only settle, so a role that may exit can keep re-sending decoy closes and hold redemptions for as long as it wins the race against the guardian | Fixed in `c463d86` (follow-up in round 2: unknown order types fail closed) | [gains/ROUND1.md](gains/ROUND1.md#gr1-04-decoy-market-orders-keep-the-emergency-settle-blocked-medium) |
| GR1-05 | Medium | The executor can send a second full-size Gains order when it cannot tell whether the first was sent (crash after broadcast, database error during the wait) | Fixed in `feb24bd` (executor) | [gains/ROUND1.md](gains/ROUND1.md#gr1-05-executor-resubmits-an-in-flight-gains-order-medium) |
| GR1-06 | Medium | The executor releases its leader lease before draining its queues, so during a deploy the standby re-runs signals the old instance is still executing and sends duplicate orders | Fixed in `feb24bd` (executor) | [gains/ROUND1.md](gains/ROUND1.md#gr1-06-executor-releases-the-leader-lease-before-draining-its-queues-medium) |
| GR1-07 | Medium | The executor treats "no answer from Gains" as retryable and sends a fresh order, up to four times the intended size, with no alert while its fill tracking is blind | Fixed in `feb24bd` (executor) | [gains/ROUND1.md](gains/ROUND1.md#gr1-07-executor-retries-no-answer-from-gains-with-a-fresh-order-medium) |
| GR1-08 | Medium | The vault decodes Gains' trade and pending-order lists with a fixed layout, so a Gains upgrade that adds a field makes NAV, every settle mode and flatten revert in every Gains vault at once | Fixed in `d8570e4` (with `c463d86`: index-based flattenIndices; round 2 added plausibility checks) | [gains/ROUND1.md](gains/ROUND1.md#gr1-08-a-gains-trade--pendingorder-abi-change-freezes-nav-settle-and-flatten-medium) |
| GR1-09 | Low | The exit-only settle still prices open trades, so one stale price feed holds every redemption until that pair's trades are closed | Accepted risk (documented: the guardian closes the stale pair, then the vault settles) | [gains/ROUND1.md](gains/ROUND1.md#gr1-09-exit-only-settle-prices-the-venue-a-stale-feed-holds-redemptions-low) |
| GR1-10 | Low | The sequencer uptime feed cannot be replaced, and the factory accepted a zero feed that silently disables the sequencer check | Fixed in `674a7b5` (with `2bd5d5b`, `c463d86`; rotation reworked in round 2, `4c5c894`) | [gains/ROUND1.md](gains/ROUND1.md#gr1-10-the-sequencer-uptime-feed-cannot-be-rotated-low) |
| GR1-11 | Low | reduceTrade has no minimum size, so a compromised online key can grind a vault's collateral into Gains' minimum fees with many tiny reduces | Accepted risk (executor alarm on reduce frequency added in `93aec69`) | [gains/ROUND1.md](gains/ROUND1.md#gr1-11-reducetrade-has-no-minimum-size-low) |
| GR1-12 | Low | The policy has its own owner, so after a vault transfer the old owner can still tighten the policy into a permanent breach and lock out the new owner | Fixed in `c463d86` | [gains/ROUND1.md](gains/ROUND1.md#gr1-12-the-policys-owner-survives-a-vault-transfer-low) |
| GR1-13 | Low | Feed decimals are cached when a feed is curated, so a decimals change misprices the vault without a revert | Fixed in `3bf24e2` | [gains/ROUND1.md](gains/ROUND1.md#gr1-13-feed-decimals-cached-at-curation-low) |
| GR1-14 | Low | The SOL price may be up to 24.5 hours old, so a halted feed is trusted for a day by settles and can overpay a redeemer | Accepted risk (a shorter limit would block SOL vaults on the feed's 24 h heartbeat) | [gains/ROUND1.md](gains/ROUND1.md#gr1-14-sol-staleness-limit-of-245-h-low) |
| GR1-15 | Low | Requests can be cancelled for free until the settle transaction, giving requesters a free option on Chainlink price lag (and outsiders a way to take GR1-02) | Fixed in `c463d86` (by the GR1-02 fix) | [gains/ROUND1.md](gains/ROUND1.md#gr1-15-requests-and-cancels-are-free-until-the-settle-transaction-low) |
| GR1-16 | Low | Resting limit and stop orders survive a full stop or emergency and can still open new exposure | Fixed in `2bd5d5b` (executor half in `93aec69`) | [gains/ROUND1.md](gains/ROUND1.md#gr1-16-resting-orders-survive-a-full-stop-and-emergency-low) |
| GR1-17 | Low | The executor re-signs an open on "already known" or "nonce too low", which can produce a duplicate open | Fixed in `feb24bd` (executor) | [gains/ROUND1.md](gains/ROUND1.md#gr1-1722-executor-low) |
| GR1-18 | Low | The executor marks a request that did land as failed after a 60 second receipt timeout, leaving the resulting trade unmanaged | Fixed in `feb24bd` (executor) | [gains/ROUND1.md](gains/ROUND1.md#gr1-1722-executor-low) |
| GR1-19 | Low | The executor holds a vault's queue up to 20 minutes per order, delaying risk trims and reduces | Fixed in `feb24bd` (executor; wait bounded to 10 minutes, trims still queue behind a waiting order) | [gains/ROUND1.md](gains/ROUND1.md#gr1-1722-executor-low) |
| GR1-20 | Low | The executor's free-margin plan counts idle USDC twice and queued deposits as cash, so the manager's signed reduction is too small or zero | Fixed in `93aec69` (executor) | [gains/ROUND1.md](gains/ROUND1.md#gr1-1722-executor-low) |
| GR1-21 | Low | The executor's risk watcher measures leverage differently from the contract, so it does not trim before a contract leverage breach | Fixed in `93aec69` (executor) | [gains/ROUND1.md](gains/ROUND1.md#gr1-1722-executor-low) |
| GR1-22 | Low | Launch binding fails when the indexer lags at the deadline, and Safe owners can never bind, so the vault loses its automation | Fixed in `93aec69` (executor; 15 minute grace instead of a block-time check) | [gains/ROUND1.md](gains/ROUND1.md#gr1-1722-executor-low) |
| GR1-23 | Info | After every depositor redeems, a 1 USDC donation makes normal settles revert for about 55 hours on a dust-sized vault | Fixed in `c463d86` | [gains/ROUND1.md](gains/ROUND1.md#33-informational-gr1-2344) |
| GR1-24 | Info | The adverse price is truncated to 64 bits without a check, so an absurd feed answer wraps a short's valuation price to near zero | Fixed in `3bf24e2` (with `d8570e4` for priceAfterImpact) | [gains/ROUND1.md](gains/ROUND1.md#33-informational-gr1-2344) |
| GR1-25 | Info | Anyone can block setSlTp and cancelOrder for about 20 blocks per 1 LINK Gains trigger; closes and settle are unaffected | Accepted risk | [gains/ROUND1.md](gains/ROUND1.md#33-informational-gr1-2344) |
| GR1-26 | Info | flatten uses one expected price for longs and shorts, so a hot role in a breach can make one side always cancel, costing a gov fee each time | Accepted risk | [gains/ROUND1.md](gains/ROUND1.md#33-informational-gr1-2344) |
| GR1-27 | Info | flatten reports nothing remaining while trades still sit behind a timed-out close or a decoy | Accepted risk (documented) | [gains/ROUND1.md](gains/ROUND1.md#33-informational-gr1-2344) |
| GR1-28 | Info | Pending partial-open and leverage-update gov fees are priced on pair 0 instead of the trade's own pair | Fixed in `d8570e4` | [gains/ROUND1.md](gains/ROUND1.md#33-informational-gr1-2344) |
| GR1-29 | Info | registerPlatformAgent can bind any number of agents to an existing vault and overwrite its recorded agent | Accepted risk | [gains/ROUND1.md](gains/ROUND1.md#33-informational-gr1-2344) |
| GR1-30 | Info | The policy keeps renounceOwnership, which would freeze its configuration and leave a queued loosening uncancellable | Fixed in `c463d86` | [gains/ROUND1.md](gains/ROUND1.md#33-informational-gr1-2344) |
| GR1-31 | Info | The NAV bound check skips pairs that are listed but disallowed while they still have exposure | Fixed in `c463d86` | [gains/ROUND1.md](gains/ROUND1.md#33-informational-gr1-2344) |
| GR1-32 | Info | The documented recovery for a known issue (cancelled next-epoch deposit blocking redeem) is wrong | Fixed in `c463d86` | [gains/ROUND1.md](gains/ROUND1.md#33-informational-gr1-2344) |
| GR1-33 | Info | The redemption shortfall is priced at a possibly stale checkpoint and can overstate what needs to be freed | Accepted risk | [gains/ROUND1.md](gains/ROUND1.md#33-informational-gr1-2344) |
| GR1-34 | Info | The redemption shortfall ignores queued deposits that a settle would net, so the operator may reduce when no reduce is needed | Accepted risk | [gains/ROUND1.md](gains/ROUND1.md#33-informational-gr1-2344) |
| GR1-35 | Info | Anyone may execute a queued setPairFeed after its delay and so picks the moment of the resulting NAV step | Accepted risk | [gains/ROUND1.md](gains/ROUND1.md#33-informational-gr1-2344) |
| GR1-36 | Info | Opening cost plus the price band is booked as a daily loss at once when a trade opens | Accepted risk (documented) | [gains/ROUND1.md](gains/ROUND1.md#33-informational-gr1-2344) |
| GR1-37 | Info | The management fee rounds to zero under per-second fee accrual calls on vaults under about 1,577 USDC | Accepted risk | [gains/ROUND1.md](gains/ROUND1.md#33-informational-gr1-2344) |
| GR1-38 | Info | Trade valuation reverts on absurd inputs (never returns a wrong value) | Accepted risk | [gains/ROUND1.md](gains/ROUND1.md#33-informational-gr1-2344) |
| GR1-39 | Info | The launch seed is gifted to the first depositors instead of returning to the owner | Accepted risk (documented) | [gains/ROUND1.md](gains/ROUND1.md#33-informational-gr1-2344) |
| GR1-40 | Info | allowAsset copies the factory's curation at execution, not what the owner queued (needs the factory owner) | Accepted risk | [gains/ROUND1.md](gains/ROUND1.md#33-informational-gr1-2344) |
| GR1-41 | Info | flatten with slippage 0 uses the policy's maximum slippage (up to 20%) while a custom flatten is capped at 3% | Fixed in `c463d86` | [gains/ROUND1.md](gains/ROUND1.md#33-informational-gr1-2344) |
| GR1-42 | Info | requestDeposit reads NAV on every factory vault, so a stale feed also freezes deposit requests, contrary to the audit diff document | Accepted risk (documented) | [gains/ROUND1.md](gains/ROUND1.md#33-informational-gr1-2344) |
| GR1-43 | Info | The executor attached a viem nonce manager it never used; a library change could have wedged hot wallets | Fixed in `feb24bd` (executor) | [gains/ROUND1.md](gains/ROUND1.md#33-informational-gr1-2344) |
| GR1-44 | Info | A feed that halts exceptionally consumes almost all of the NAV read's gas instead of reverting with a stale-price error | Fixed in `3bf24e2` | [gains/ROUND1.md](gains/ROUND1.md#33-informational-gr1-2344) |
| GR1-45 | Design | Venue liveness: a Gains pause or close-only mode, a pair Gains stops serving, or a USDC blacklist of the vault can stop trades, settles or exits | Accepted risk (documented) | [gains/ROUND1.md](gains/ROUND1.md#gr1-45-venue-liveness-design-trust-t2--t5) |

#### Supporting documents (gTrade round 1)

- [gains/SPEC.md](gains/SPEC.md): numbered, testable specification of the Gains contracts used as the review baseline.
- [gains/THREAT-MODEL.md](gains/THREAT-MODEL.md): assets at risk, actors and trust assumptions for the review.
- [gains/ACCESS-MATRIX.md](gains/ACCESS-MATRIX.md): expected outcome of every state-changing function per actor and vault state, verified cell by cell.
- [gains/AUDIT-DIFF.md](gains/AUDIT-DIFF.md): what the Gains contracts copy, change or add relative to the Hyperliquid round 4 contracts, with the fix round changes and gas table.
- [gains/XREVIEW.md](gains/XREVIEW.md): cross-review that challenged and re-rated the domain findings before consolidation.
- [gains/nav/FINDINGS.md](gains/nav/FINDINGS.md): sub-report on NAV and share pricing.
- [gains/nav/DIFF-RESULTS.md](gains/nav/DIFF-RESULTS.md): differential test of the vault's trade valuation against an independent TypeScript implementation and real closes.
- [gains/lifecycle/FINDINGS.md](gains/lifecycle/FINDINGS.md): sub-report on the asynchronous order lifecycle, exits and liveness (fork tests on the real gTrade diamond).
- [gains/lifecycle/GAS.md](gains/lifecycle/GAS.md): gas of each vault call at the maximum number of positions.
- [gains/gov/FINDINGS.md](gains/gov/FINDINGS.md): sub-report on access control, governance and the diff against round 4.
- [gains/gov/HL-RETEST.md](gains/gov/HL-RETEST.md): every earlier Hyperliquid finding class retested on the Gains contracts.
- [gains/tools/README.md](gains/tools/README.md): the analysis tools and versions used.
- [gains/tools/SLITHER-TRIAGE.md](gains/tools/SLITHER-TRIAGE.md): triage of every Slither result.
- [gains/tools/ADERYN-TRIAGE.md](gains/tools/ADERYN-TRIAGE.md): triage of every Aderyn result.
- [gains/tools/MUTATION.md](gains/tools/MUTATION.md): limited mutation-testing run and its survivors.
- [gains/tools/HALMOS.md](gains/tools/HALMOS.md): symbolic checks with Halmos: what was proven, counterexamples, timeouts.
- [gains/tools/FUZZING.md](gains/tools/FUZZING.md): invariant fuzzing campaigns (Foundry and Medusa).
- [gains/tools/FORK-REPLAY.md](gains/tools/FORK-REPLAY.md): real gTrade exits replayed through a vault on a fork.
- [gains/tools/INTEGRATION.md](gains/tools/INTEGRATION.md): external integration checks (diamond layouts, feeds, approvals).
- [gains/tools/executor/RESULTS.md](gains/tools/executor/RESULTS.md): sub-report on the executor and online keys for Gains vaults.
- [gains/FIXES-R1.md](gains/FIXES-R1.md): round 1 fixes with regression tests and reverted checks, triage of unfixed items, and the later round 2 fixes.
- [gains/fixes/EXECUTOR.md](gains/fixes/EXECUTOR.md): executor fixes for round 1 (one order per intent, drain before lease release).
- [gains/fixes/TESTS-A1.md](gains/fixes/TESTS-A1.md): round 1 PoCs converted to regression tests (NAV, lifecycle, integration, replay, symbolic, invariants).
- [gains/fixes/TESTS-A2.md](gains/fixes/TESTS-A2.md): round 1 PoCs converted to regression tests (governance, access matrix, Gains suites).


### gTrade verification of the round 1 fixes (gains/VERIFY-R1.md)

| Date | Scope | Commit reviewed | Critical | High | Medium | Low | Info |
|---|---|---|---|---|---|---|---|
| 2026-10-18 | Internal check, by the author of the fixes, of the gTrade round 1 fixes, their regressions, the executor's design decisions, the unfixed Lows and gas at 20 positions | `56cc78c` | 0 | 0 | 0 | 2 | 4 |

Verdicts on the earlier findings ([summary table](gains/VERIFY-R1.md#1-summary-table)): every round 1 finding that was fixed is rated closed, none partially closed or not closed. Two verdicts are qualified: GR1-08 is closed for fields appended to the trade layout only (an inserted field is GV-01), and GR1-16 is closed for its contract half. For the three Lows left unfixed (GR1-09, GR1-11, GR1-14) the reason for not fixing holds; for GR1-14 the report adds that FIXES-R1 overstates the mitigation.

| ID | Severity | Finding | Status | Report |
|---|---|---|---|---|
| GV-01 | Info | A trade layout with a field inserted before the position size is misread without any error, so vault notional reads about 0 and the leverage check passes anything (in the test a 3x policy accepted 4.74x) | Fixed in `f496dc7` | [gains/VERIFY-R1.md](gains/VERIFY-R1.md#gv-01-a-trade-layout-with-a-field-inserted-before-positionsizetoken-is-misread-silently-info) |
| GV-02 | Low | A pending-order type the vault does not know neither holds settle nor counts in NAV, so settle can run at a NAV short by that order's collateral and pay redeemers too little (fail open where round 1 failed closed) | Fixed in `f496dc7` | [gains/VERIFY-R1.md](gains/VERIFY-R1.md#gv-02-a-pending-order-type-the-vault-does-not-know-neither-holds-settle-nor-counts-in-nav-low) |
| GV-03 | Info | The vault's timelocked sequencer-feed rotation adopts whatever the factory holds at execution, with any grace period, so the factory owner can swap in a value that blocks every priced path (exits still work) | Fixed in `4c5c894` | [gains/VERIFY-R1.md](gains/VERIFY-R1.md#gv-03-the-sequencer-rotation-adopts-the-factorys-feed-at-execution-with-any-grace-period-info) |
| GV-04 | Low | A hostile manager or compromised agent key can still send decoy closes that each cost the vault the venue's fee, and the executor's rate alarm counted reduces only, so a stream of decoy closes was never alerted | Fixed in `956bf19` (executor) | [gains/VERIFY-R1.md](gains/VERIFY-R1.md#gv-04-decoy-closes-no-longer-hold-settle-but-still-cost-the-gov-fee-and-the-rate-alarm-counts-reduces-only-low) |
| GV-05 | Info | Anyone can queue a minimum deposit and make the manager's next redemption settle wait until the epoch is an hour old | Accepted risk (documented) | [gains/VERIFY-R1.md](gains/VERIFY-R1.md#gv-05-anyone-can-make-a-redemption-settle-wait-up-to-an-hour-info) |
| GV-06 | Info | A leverage-only increase does not hold settle, so a redemption settled while it is pending is paid at the NAV before its fill books the fees on the added size | Accepted risk (documented) | [gains/VERIFY-R1.md](gains/VERIFY-R1.md#gv-06-a-non-holding-orders-fill-steps-nav-after-a-settle-that-ran-beside-it-info) |

### gTrade verification of fix round 2 (gains/VERIFY-R2.md)

| Date | Scope | Commit reviewed | Critical | High | Medium | Low | Info |
|---|---|---|---|---|---|---|---|
| 2026-10-19 | Check by an agent that did not write them of the round 2 fixes (GV-01 to GV-04), gas at 20 positions and the rest of the round 2 diff | `5aa1178` | 0 | 0 | 0 | 1 | 0 |

Verdicts on the earlier findings ([verdicts](gains/VERIFY-R2.md#verdicts)): all six items checked hold (the GV-01, GV-02 and GV-03 fixes, gas at 20 positions and the rest of the diff); the GV-04 fix holds for closes and reduces but raises one false alarm, filed as R2-01. GV-05 and GV-06 had no code change and are not given a verdict.

| ID | Severity | Finding | Status | Report |
|---|---|---|---|---|
| R2-01 | Low | The guardian's fallback exit (closing trades by index) with 11 or more open trades, or an agent close-all, trips the executor's rate alarm, which then tells the operator to revoke the actor doing the exit; no on-chain effect | Fixed in `526a08f` (executor) | [gains/VERIFY-R2.md](gains/VERIFY-R2.md#r2-01-low-a-degraded-mode-flatten-raises-the-revoke-the-caller-alarm) |


## Round 2: reviews, fix round and release verification

Round 2 reviewed both venues again at `4ec6feb` (the code of the earlier factories), fixed every High and Medium in
the contracts, and verified the result before the round 2 release, the contracts deployed today (see
[deployments](../README.md#deployments)). Statuses below are the state of that release (private commit `2bd7e53`);
every "Fixed in" commit is part of it.

What this repository holds of round 2: the reports and the fix-round results below, and the proofs of concept, fix
tests and campaign harnesses in [`../test/audit/hl-r2/`](../test/audit/hl-r2), [`../test/audit/gains/r2/`](../test/audit/gains/r2)
and [`../test/audit/fix-round/`](../test/audit/fix-round). Not included: raw logs, evidence dumps and data, the patch
files the reports cite (the fixes are in `src/` now), the reviewers' working notes and brief, the executor reports
(the hl-r2 and gains/r2 EXECUTOR.md, hl-r2 fixes/EXECUTOR-MEDIUMS.md, fix-round WP3), the website work package (WP4)
and the executor's proofs of concept. One Hyperliquid test file is left out: `test/audit/hl-r2/flow/HlR2Encoding.t.sol`
checks CoreWriter actions byte for byte against live actions of earlier vaults whose addresses are inside the
asserted bytes. Reports name earlier deployments by a bracketed label, for example [an earlier factory].

Statuses use the scale above, plus *Fixed in the executor* for findings in the off-chain executor (out of scope here).

### Hyperliquid review round 2 (hl-r2/ROUND2.md)

| Date | Scope | Commit reviewed | Critical | High | Medium | Low | Info |
|---|---|---|---|---|---|---|---|
| 2026-10-19 to 2026-10-21 | HyperVault, HyperVaultFactory, VaultPolicy, VaultLogic, VaultGovernance, VaultMath, HyperVaultLens, the HyperCore library, the deploy scripts and the executor: fund flow and encodings, asynchrony with HyperCore, conservation invariants, stolen keys, hostile vaults and configuration, multi-epoch economics, exit liveness, mutation, past fixes, Halmos, static analysis, known exploit classes; two cross-reviews | `4ec6feb` | 0 | 2 | 18 | 32 | 21 |

The Low count includes the nine test gaps found by mutation (HLR2-M01 to M09); the Info count includes one design
item (HLR2-K03). Two open questions (H05, K11) rest on undocumented Hyperliquid behaviour. The fix round's commits
are listed in [fix-round/WP1-RESULTS.md](fix-round/WP1-RESULTS.md).

| ID | Severity | Finding | Status | Report |
|---|---|---|---|---|
| HLR2-H01 | High | A policy loosening (2 days) applies before a redeemer can force an exit (7 to 30 days), and the loosening can push the deadline itself | Fixed in `83a7cc4` (exit before effect: stored epoch deadline, every loosening waits an epoch plus a day) | [hl-r2/HOSTILE-AND-CONFIG.md](hl-r2/HOSTILE-AND-CONFIG.md), [hl-r2/fixes/EXIT-BEFORE-EFFECT.md](hl-r2/fixes/EXIT-BEFORE-EFFECT.md) |
| HLR2-A08 | High | An exit-only settle at a short NAV (a bridge transfer home written off after 300 blocks) pays every redeemer about 0, and the late arrival goes to the next depositor (conditional, low likelihood) | Fixed in `0cc4e93` and `01770d2` (settles and bridges wait while a late transfer leaves the NAV short, at most a day; first mint at supply 0) | [hl-r2/ASYNC.md](hl-r2/ASYNC.md) |
| HLR2-E01 | Medium | Exit-only settles pay at min(NAV, checkpoint) with no bound on the checkpoint's age; an instant epoch tightening opens that price (with XB01) | Fixed in `83a7cc4` (`CheckpointBehind`) | [hl-r2/ECONOMICS.md](hl-r2/ECONOMICS.md), [hl-r2/fixes/CONTRACT-MEDIUMS.md](hl-r2/fixes/CONTRACT-MEDIUMS.md) |
| HLR2-E06 | Medium | An owner's full stop blocks every settle for up to the epoch | Fixed in `83a7cc4` (an owner stop is redemption-only) | [hl-r2/LIVENESS.md](hl-r2/LIVENESS.md), [hl-r2/fixes/CONTRACT-MEDIUMS.md](hl-r2/fixes/CONTRACT-MEDIUMS.md) |
| HLR2-H04 | Medium | In an emergency the manager chains bridges so the exit settle only lands if it is first in a block | Fixed in `83a7cc4` (330-block bridge cooldown in emergency, XF01 version) | [hl-r2/HOSTILE-AND-CONFIG.md](hl-r2/HOSTILE-AND-CONFIG.md), [hl-r2/fixes/CONTRACT-MEDIUMS.md](hl-r2/fixes/CONTRACT-MEDIUMS.md) |
| HLO-07 | Medium | A leaked registrar key binds a self-held agent on a new vault | Fixed in `83a7cc4` (24-hour agent warm-up with a veto) | [hl-r2/HLO-DEFERRED.md](hl-r2/HLO-DEFERRED.md) |
| HLR2-XA01 | Medium | A monitor revoke does not stop the keeper's settle at the deflated NAV | Fixed in `83a7cc4` (`depositHold` on a platform revoke) and in the executor | [hl-r2/XREVIEW-A.md](hl-r2/XREVIEW-A.md), [hl-r2/fixes/CONTRACT-MEDIUMS.md](hl-r2/fixes/CONTRACT-MEDIUMS.md) |
| HLR2-XF-01 | Medium | Regression of the first H04 fix: exits needed a platform key forever | Fixed in `83a7cc4` | [hl-r2/fixes/XREVIEW-FIXES.md](hl-r2/fixes/XREVIEW-FIXES.md) |
| HLR2-XF-03 | Medium | Regression: the monitor's response as `triggerBreach` froze exits under the E06 fix | Fixed in the executor (revoke first, breach as fallback) | [hl-r2/fixes/XREVIEW-FIXES.md](hl-r2/fixes/XREVIEW-FIXES.md) |
| HLR2-XF-04 | Medium | The keeper sends no `checkRisk` in an emergency, so E01 settles revert | Fixed in the executor | [hl-r2/fixes/XREVIEW-FIXES.md](hl-r2/fixes/XREVIEW-FIXES.md) |
| HLR2-XF-05 | Medium | The settle planner never settles an owner stop and counts held deposits as cash | Fixed in the executor | [hl-r2/fixes/XREVIEW-FIXES.md](hl-r2/fixes/XREVIEW-FIXES.md) |
| HLR2-XF-06 | Medium | The unexplained-outflow alert sums read noise and fires on an honest vault within about 20 hours | Fixed in the executor | [hl-r2/fixes/XREVIEW-FIXES.md](hl-r2/fixes/XREVIEW-FIXES.md) |
| HLR2-X01 | Medium | The copy mirror sizes from a stale account: duplicate opens, missed closes | Fixed in the executor | [hl-r2/ROUND2.md](hl-r2/ROUND2.md) |
| HLR2-X03 | Medium | A lost submit answer with an unreadable status sends a second order | Fixed in the executor | [hl-r2/ROUND2.md](hl-r2/ROUND2.md) |
| HLR2-X04 | Medium | The hosted fan-out stops at the first tenant whose guard read throws | Fixed in the executor | [hl-r2/XREVIEW-A.md](hl-r2/XREVIEW-A.md) |
| HLR2-X05 | Medium | Value moves by the agent alone never trigger a response (with K12) | Fixed in `52cdf65` for new vaults (HL-PROXY: the agent trades through the vault under the policy; no API wallet) and in the executor | [hl-r2/fixes/HL-PROXY.md](hl-r2/fixes/HL-PROXY.md) |
| HLR2-X07 | Medium | One first-in-first-out order weight tier for every vault | Fixed in the executor | [hl-r2/ROUND2.md](hl-r2/ROUND2.md) |
| HLR2-H06 | Medium | A sybil spam vault exhausts the shared operator and fee gas budgets | Fixed in the executor (per-vault and per-owner budgets) | [hl-r2/HOSTILE-AND-CONFIG.md](hl-r2/HOSTILE-AND-CONFIG.md) |
| HLR2-A01 | Medium | A dropped burn approval leaves the agent live on HyperCore through a full stop, with no retry | Fixed in `0cc4e93`; for new vaults superseded by `52cdf65` and `00bc8d5` (no API wallet; the revoke sends no HyperCore action, WP5-D14) | [hl-r2/ASYNC.md](hl-r2/ASYNC.md) |
| HLR2-A02 | Medium | A transfer landing after 300 blocks is written off, and settles price at the deflated NAV (low likelihood) | Fixed in `0cc4e93` (the A08 hold) | [hl-r2/ASYNC.md](hl-r2/ASYNC.md) |
| HLR2-XB02 | Low | No alert on a queued loosening, a timelock lowering or `OperatorSet(0)` | Fixed in the executor (governance alerts) | [hl-r2/XREVIEW-B.md](hl-r2/XREVIEW-B.md) |
| HLR2-A04 | Low | The agent can fake an EVM to Core landing; with a late credit the window closes after 10 blocks and a settle prices without the USDC in transit | Fixed in `0cc4e93` | [hl-r2/ASYNC.md](hl-r2/ASYNC.md) |
| HLR2-A05 | Low | A written-off transfer that lands later latches the next bridge in the same direction | Fixed in `0cc4e93` | [hl-r2/ASYNC.md](hl-r2/ASYNC.md) |
| HLR2-XF-02 | Low | Fix-round regression found in the cross-review of the fixes | Fixed in `83a7cc4` | [hl-r2/fixes/XREVIEW-FIXES.md](hl-r2/fixes/XREVIEW-FIXES.md) |
| HLR2-XF-07, XF-08 | Low | Fix-round regressions in the executor patches | Fixed in the executor | [hl-r2/fixes/XREVIEW-FIXES.md](hl-r2/fixes/XREVIEW-FIXES.md) |
| HLR2-A03 | Low | The agent can hide a landing or make a bridge home fail: settles, bridges and `moveUsd` wait 300 blocks per bridge, and `checkRisk` masks a loss up to the bridged amount meanwhile | Open on vaults with an API wallet (earlier factories); does not arise on vaults of the current factory (no API wallet, `52cdf65`) | [hl-r2/ASYNC.md](hl-r2/ASYNC.md) |
| HLR2-X02, X06, X08, H03, E02, E03, E07, L01, L02, F01, F02, K10 | Low | Lows described in the domain reports | Open (Low, described; not part of the fix round) | [hl-r2/ROUND2.md](hl-r2/ROUND2.md) and the domain reports |
| HLO-02, HLO-03, HLO-06, HLO-08 | Low | Earlier open-launch items re-examined | Open (confirmed, not patched); HLO-06 is a design item | [hl-r2/HLO-DEFERRED.md](hl-r2/HLO-DEFERRED.md) |
| HLR2-M01 to M09 | Low | Test gaps found by mutation (rescueToken, bridge trackers, exit pricing, depositor guards, governance negatives, four past fixes without a catching test) | Fixed (85 kill tests in `test/audit/hl-r2/mut/`) | [hl-r2/MUTATION.md](hl-r2/MUTATION.md), [hl-r2/PAST-FIXES.md](hl-r2/PAST-FIXES.md) |
| HLR2-K03 | Design | Agent deflation priced into a non-insider deposit (= R-1 / I3-01) | Fixed in `52cdf65` for new vaults (the NAV only moves by real trading); accepted risk on earlier vaults | [hl-r2/KEYS.md](hl-r2/KEYS.md) |
| X09, E04, E05, E08, E09, F03 to F05, F07, F08, XB03, XB04, A06, A07, KN01, KN02, HAL01, M10 to M12 | Info | Observations | No change | [hl-r2/ROUND2.md](hl-r2/ROUND2.md) and the domain reports |
| H05, K11 | Open question (at most Medium if confirmed) | Agent-address pre-emption; a stolen agent blocks its own revocation for up to 24 hours (undocumented Hyperliquid behaviour) | Closed for new vaults by `52cdf65` (no API wallet) | [hl-r2/ROUND2.md](hl-r2/ROUND2.md) |

Supporting documents: [hl-r2/FUND-FLOW.md](hl-r2/FUND-FLOW.md), [hl-r2/COREWRITER-ENCODING.md](hl-r2/COREWRITER-ENCODING.md),
[hl-r2/ASYNC.md](hl-r2/ASYNC.md), [hl-r2/INVARIANTS.md](hl-r2/INVARIANTS.md), [hl-r2/KEYS.md](hl-r2/KEYS.md),
[hl-r2/HOSTILE-AND-CONFIG.md](hl-r2/HOSTILE-AND-CONFIG.md), [hl-r2/ECONOMICS.md](hl-r2/ECONOMICS.md),
[hl-r2/LIVENESS.md](hl-r2/LIVENESS.md), [hl-r2/MUTATION.md](hl-r2/MUTATION.md), [hl-r2/PAST-FIXES.md](hl-r2/PAST-FIXES.md),
[hl-r2/HALMOS.md](hl-r2/HALMOS.md), [hl-r2/STATIC.md](hl-r2/STATIC.md), [hl-r2/KNOWN-EXPLOITS.md](hl-r2/KNOWN-EXPLOITS.md),
[hl-r2/HLO-DEFERRED.md](hl-r2/HLO-DEFERRED.md), [hl-r2/HLO-OPEN-QUESTIONS.md](hl-r2/HLO-OPEN-QUESTIONS.md), the
cross-reviews [hl-r2/XREVIEW-A.md](hl-r2/XREVIEW-A.md) and [hl-r2/XREVIEW-B.md](hl-r2/XREVIEW-B.md), and the fix
designs [hl-r2/fixes/EXIT-BEFORE-EFFECT.md](hl-r2/fixes/EXIT-BEFORE-EFFECT.md),
[hl-r2/fixes/CONTRACT-MEDIUMS.md](hl-r2/fixes/CONTRACT-MEDIUMS.md), [hl-r2/fixes/HL-PROXY.md](hl-r2/fixes/HL-PROXY.md),
[hl-r2/fixes/GAINS-OPENTRADE.md](hl-r2/fixes/GAINS-OPENTRADE.md), [hl-r2/fixes/INTEGRATION.md](hl-r2/fixes/INTEGRATION.md)
and [hl-r2/fixes/XREVIEW-FIXES.md](hl-r2/fixes/XREVIEW-FIXES.md).

### gTrade review round 2 (gains/r2/ROUND2.md)

| Date | Scope | Commit reviewed | Critical | High | Medium | Low | Info |
|---|---|---|---|---|---|---|---|
| 2026-10-19 to 2026-10-21 | The gTrade contracts (GainsVault, GainsVaultFactory, GainsVaultPolicy, GainsVaultLogic, GainsVaultGovernance, GainsVaultMath, GainsNav, GainsPrice, GainsVaultLens) and the executor: fund flow, compromised keys, configuration, the Gains side, conservation invariant, multi-epoch economics, exit liveness, mutation, Halmos, static analysis, known exploit classes; every finding challenged by a second reviewer | `4ec6feb` | 0 | 2 | 3 | 11 | 8 |

The fix round's commits are listed in [fix-round/WP2-RESULTS.md](fix-round/WP2-RESULTS.md).

| ID | Severity | Finding | Status | Report |
|---|---|---|---|---|
| GR2-LIVE-01 | High | Settle, NAV and `openTrade` walk every Gains index the vault ever used: normal settles stop fitting in a block, and a narrow band locks for good | Fixed in `881e7af` (the vault keeps its own index set; `syncIndexes`) and `26dce56` (XF-03) | [gains/r2/LIVENESS.md](gains/r2/LIVENESS.md), [gains/r2/fixes/GR2-LIVE-01/README.md](gains/r2/fixes/GR2-LIVE-01/README.md) |
| GR2-KEY-01 | High | Vault notional per pair is unbounded against Gains' skew depth: a stolen trading key routes vault loss to an opposite trader | Fixed in `af1f81d`, `39d4a47` (KEY-01b: factory pair cap, turnover budget, minimum hold, loss gate) and `b718e0c` (XF-04) | [gains/r2/KEYS.md](gains/r2/KEYS.md), [gains/r2/fixes/GR2-KEY-01b/README.md](gains/r2/fixes/GR2-KEY-01b/README.md) |
| GR2-ECON-03 | Medium | A leverage-breach settle mints deposits without crystallising the performance fee | Fixed in `1a00f26` | [gains/r2/ECONOMICS.md](gains/r2/ECONOMICS.md), [gains/r2/fixes/GR2-ECON-03/README.md](gains/r2/fixes/GR2-ECON-03/README.md) |
| GR2-KEY-06 | Medium | The guardian, owner and sentinel keys choose when redemptions are priced at min(NAV, checkpoint) | Fixed in `31df7ec` | [gains/r2/XREVIEW-KEY-EXE-FF.md](gains/r2/XREVIEW-KEY-EXE-FF.md), [gains/r2/fixes/GR2-KEY-06/README.md](gains/r2/fixes/GR2-KEY-06/README.md) |
| GR2-CFG-01 | Medium | The factory accepts a policy timelock shorter than the maximum epoch: a redeemer can be trapped behind a loosening for up to 29 days | Fixed in `83a7cc4` (the exit-before-effect rule shared with HLR2-H01) | [gains/r2/CONFIG.md](gains/r2/CONFIG.md), [gains/r2/fixes/GR2-CFG-01/README.md](gains/r2/fixes/GR2-CFG-01/README.md) |
| GR2-GNS-01 | Low | A trade past its take-profit is valued at the market; Gains pays the take-profit | Open (no ready, tested fix) | [gains/r2/GAINS-SIDE.md](gains/r2/GAINS-SIDE.md) |
| GR2-XR-01 | Low | A crossed resting limit open is valued at its collateral; Gains opens it at the worse limit | Open (no ready, tested fix) | [gains/r2/XREVIEW-LIVE-GNS.md](gains/r2/XREVIEW-LIVE-GNS.md) |
| GR2-XR-02 | Low | An unclosable pair with a stale feed: no settle mode pays, not even idle; only the owner's timelocked feed change helps | Open (no ready, tested fix) | [gains/r2/XREVIEW-LIVE-GNS.md](gains/r2/XREVIEW-LIVE-GNS.md) |
| GR2-ECON-02 | Low (design) | Loss-breach and exit-only settles pay min(NAV, checkpoint) at a settler-chosen moment | Exit-only form fixed in `31df7ec` (through KEY-06); redemption-only form accepted risk (bounded by `maxNavMoveBps`, avoidable by cancelling) | [gains/r2/ECONOMICS.md](gains/r2/ECONOMICS.md) |
| GR2-ECON-01 | Low (design) | A hedged book opened around a settle manufactures the bid / ask band | Accepted risk (documented band) | [gains/r2/ECONOMICS.md](gains/r2/ECONOMICS.md) |
| GR2-CFG-02 | Low | Raising the maximum epoch duration makes an overdue epoch current again | Fixed in `31df7ec` (through KEY-06) and `83a7cc4` (stored epoch deadline) | [gains/r2/CONFIG.md](gains/r2/CONFIG.md) |
| GR2-LIVE-02 | Low | An owner's full stop holds every settle until the guardian acts or the epoch is overdue | Open (no ready, tested fix) | [gains/r2/LIVENESS.md](gains/r2/LIVENESS.md) |
| GR2-CI-01 | Low | An unknown-type order that holds nothing is valued at its collateral field: fees accrue on the inflated NAV and a false daily-loss breach can follow | Open (needs a snapshot field and an ABI change; only after a Gains facet change) | [gains/r2/CONSERVATION.md](gains/r2/CONSERVATION.md), [gains/r2/XREVIEW-FIXES.md](gains/r2/XREVIEW-FIXES.md) |
| GR2-EXE-01, EXE-02, EXE-07 | Low | Executor: the reduce-rate alarm counts a batched transaction once; a strategy close is not retried while another order is pending; a fenced owner's requeue resets the new owner's claim | Fixed in the executor | [gains/r2/ROUND2.md](gains/r2/ROUND2.md) |
| GR2-XF-01 to XF-04 | Low | Changes the cross-review of the fixes required (no performance fee in an exit-only settle; the prior-checkpoint cap for exit-only settles only; index sync before closes; Gains' pair open-interest ceiling bounds the pair cap) | Fixed in `1f3a2df`, `4b74f4c`, `26dce56`, `b718e0c` | [gains/r2/XREVIEW-FIXES.md](gains/r2/XREVIEW-FIXES.md) |
| GR2-FF-02 | Info | `requestDeposit` pulls the asset before booking the request, and `checkRisk` runs outside the lock (not reachable with native USDC) | Fixed in `d5ed772` | [gains/r2/KNOWN-EXPLOITS.md](gains/r2/KNOWN-EXPLOITS.md) |
| GR2-FF-01 | Info | Anyone can block an insider's redeem with a 10 USDC deposit on its controller until it cancels | No change | [gains/r2/FUND-FLOW.md](gains/r2/FUND-FLOW.md) |
| GR2-GNS-02 | Design | NAV re-implements Gains' close formula; a Gains facet change can make it silently wrong | Accepted risk (watch Gains' timelocks, replay the NAV suites) | [gains/r2/GAINS-SIDE.md](gains/r2/GAINS-SIDE.md) |
| GR2-GNS-03, KEY-04, CFG-03 | Info | Outside skew moves NAV (unprofitable below about 0.25M to 1.05M per pair); fee churn per full turnover; no platform veto on policy-side queues | No change | [gains/r2/ROUND2.md](gains/r2/ROUND2.md) |
| GR2-EXE-03 to EXE-06 | Info | Executor observations | Executor findings, out of scope here | [gains/r2/ROUND2.md](gains/r2/ROUND2.md) |

Supporting documents: [gains/r2/FUND-FLOW.md](gains/r2/FUND-FLOW.md), [gains/r2/KEYS.md](gains/r2/KEYS.md),
[gains/r2/CONFIG.md](gains/r2/CONFIG.md), [gains/r2/GAINS-SIDE.md](gains/r2/GAINS-SIDE.md),
[gains/r2/CONSERVATION.md](gains/r2/CONSERVATION.md), [gains/r2/ECONOMICS.md](gains/r2/ECONOMICS.md),
[gains/r2/LIVENESS.md](gains/r2/LIVENESS.md), [gains/r2/MUTATION.md](gains/r2/MUTATION.md),
[gains/r2/HALMOS.md](gains/r2/HALMOS.md), [gains/r2/STATIC-TRIAGE.md](gains/r2/STATIC-TRIAGE.md),
[gains/r2/KNOWN-EXPLOITS.md](gains/r2/KNOWN-EXPLOITS.md), [gains/r2/FIX-DESIGN.md](gains/r2/FIX-DESIGN.md), the
cross-reviews [gains/r2/XREVIEW-ECON-CFG.md](gains/r2/XREVIEW-ECON-CFG.md),
[gains/r2/XREVIEW-KEY-EXE-FF.md](gains/r2/XREVIEW-KEY-EXE-FF.md), [gains/r2/XREVIEW-LIVE-GNS.md](gains/r2/XREVIEW-LIVE-GNS.md)
and [gains/r2/XREVIEW-FIXES.md](gains/r2/XREVIEW-FIXES.md), and the fix notes in [gains/r2/fixes/COMBINED.md](gains/r2/fixes/COMBINED.md).

### Round 2 fix round and release verification (fix-round/)

| Date | Scope | Commit reviewed | Critical | High | Medium | Low | Info |
|---|---|---|---|---|---|---|---|
| 2026-10-21 to 2026-10-24 | The fixes in `src/` (WP1 Hyperliquid, WP2 gTrade) and the verification of the release tree (WP5): a fresh internal review by reviewers who had not worked on the fixes, a stolen-agent review, Medusa, invariant campaigns, mutation, Halmos, fork tests, a HyperEVM testnet run and the release bytecode | `2bd7e53` (release) | 0 | 0 | 3 | 8 | 6 |

The counts include the executor findings of the fix round (WP3 P1, Medium; WP3 B1, B2, B3, G1, G2, Low; a flaky
executor test, Info), all fixed or explained in the executor and not listed below. Reports: [fix-round/WP1-RESULTS.md](fix-round/WP1-RESULTS.md), [fix-round/WP2-RESULTS.md](fix-round/WP2-RESULTS.md),
[fix-round/WP5-RESULTS.md](fix-round/WP5-RESULTS.md), [fix-round/WP5-UNCROSS.md](fix-round/WP5-UNCROSS.md) and the
release bytecode record [fix-round/RELEASE-BYTECODE.md](fix-round/RELEASE-BYTECODE.md).

| ID | Severity | Finding | Status | Report |
|---|---|---|---|---|
| WP5-HL-01 | Medium | Agent churn on Hyperliquid can cost more than the "about 2 % a day" a code comment claimed | Fixed in `668b621` (comment corrected); platform launch limits set at deploy (owner decision) | [fix-round/WP5-RESULTS.md](fix-round/WP5-RESULTS.md) |
| WP5-BOTH-02 | Medium | The daily stop lifts at midnight with a stolen key still in place, so the loss can repeat day after day | Fixed in the executor (foreign-order revoke) | [fix-round/WP5-RESULTS.md](fix-round/WP5-RESULTS.md) |
| WP5-GAINS-03 | Low | The gTrade per-pair cap is per vault, so several vaults on one pair add up | Accepted risk (owner decision) | [fix-round/WP5-RESULTS.md](fix-round/WP5-RESULTS.md) |
| WP5-BOTH-04 | Low / Info | The factories do not cap the risk limits a launcher chooses | Accepted risk (owner decision) | [fix-round/WP5-RESULTS.md](fix-round/WP5-RESULTS.md) |
| HL-INV-01 | Low | A lost bridge transfer inflated the agent's turnover budget for up to 5 minutes | Fixed in `24b8efe` | [fix-round/WP5-RESULTS.md](fix-round/WP5-RESULTS.md) |
| WP5-HL-05 | Info | The rolling 24-hour turnover window can hold about 40x NAV in a true 24 hours | Accepted risk (documented, bounded by the daily loss limit) | [fix-round/WP5-RESULTS.md](fix-round/WP5-RESULTS.md) |
| WP5-D14 | Info | `revokeAgent` created a keyless 90-day API wallet entry on HyperCore (found on testnet) | Fixed in `00bc8d5` | [fix-round/WP5-RESULTS.md](fix-round/WP5-RESULTS.md) |
| WP5 bytecode | Info | The recorded bytecode depends on the whole compiler job (via_ir) | No change: the record holds for the exact release compiler job; how to check it is in [README.md](../README.md#checking-the-deployed-bytecode) | [fix-round/RELEASE-BYTECODE.md](fix-round/RELEASE-BYTECODE.md) |
| WP5 leverage raise | Info | Raising the leverage of an open trade spends no turnover and has no hold | No change | [fix-round/WP5-RESULTS.md](fix-round/WP5-RESULTS.md) |
| HLFIX-E01, GFIX-CFG01 | Info | Two round 2 fix tests passed without their fix | Fixed (stronger tests in `test/audit/fix-round/`) | [fix-round/WP5-RESULTS.md](fix-round/WP5-RESULTS.md) |

Two test harness changes after the release, in this repository's tests only (private commits `407eda7` and
`cbc4a04`; `src/` and the release bytecode are unchanged). First, the gTrade stolen-agent campaign's mock diamond
([`../test/audit/fix-round/WP5-INV-GainsDiamond.sol`](../test/audit/fix-round/WP5-INV-GainsDiamond.sol)) liquidated
every trade at a fixed -90 % distance. gTrade v10 moves the liquidation price by the trade's closing fee, holding
balance and realized pnl, as [gains/nav/DIFF-RESULTS.md](gains/nav/DIFF-RESULTS.md) records. An unseeded run found an
SA1 counterexample that only the mock allowed: a holding credit lost with a trade the mock liquidated too early. The
mock now uses gTrade's formula, and the sequence is kept as `test_replay_SA1_holdingCredit`. Second, the SA1 bound
took the push against the mid, but pnl and liquidation are measured against the fill price: a short filled p below the
mid moves p / (1 - p) of its open price back to the mid. A seeded run found a 29.25x short liquidated 13 USDC over the
old bound (the old mock fails it the same way). The push term is now p / (1 - p) of the notional, and the sequence is
kept as `test_replay_SA1_shortPush`. The fixed campaign passes at 2,048 runs × 500 calls on three seeds.
