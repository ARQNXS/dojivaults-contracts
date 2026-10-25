# hl-r2: hostile vaults (3.5) and upgrades, timelock, configuration (3.6)

**This is an internal, AI-assisted review. It is not an independent audit and must not be presented as one.**

Sub-review of hl-r2, branch `audit/hl-r2-hostile`. Code: `contracts/src` outside `gains/` (unchanged since the
round 4 deploy), executor paths read where a question needed them. Nothing deployed, no transaction sent, nothing
pushed; `contracts/src` and `server/src` unchanged. Chain reads are read-only `cast call` / `eth_call` against
`https://rpc.hyperliquid.xyz/evm` and the public Hyperliquid `info` endpoint, 2026-10-19 ~20:30 UTC.

PoCs: `contracts/test/audit/hl-r2/hostile/HostileConfig.t.sol` (10 tests), `HloDeferred.t.sol` (6, see
[HLO-DEFERRED.md](HLO-DEFERRED.md)), base `HostileBase.t.sol` (the live round 4 factory from hl-open's `HloBase`, plus a
vault configured like the platform vault: policy 5x / daily loss 20% / drawdown 50% / slippage 1% / order notional 2.5M / epoch
7 days / NAV move 20% / flatten 3%, vault and policy timelock 2 days, the keeper as operator).

```
cd contracts
forge test --match-path "test/audit/hl-r2/hostile/*" -vv     # 16 tests, all pass
```

## Assumptions

- S1. An "untrusted owner" is in scope: under `openLaunch = true` every launcher is the owner and manager of their vault
  (REPORT.md section 2 already treated the factory-vault owner as untrusted).
- S2. HyperEVM orders transactions inside a block by priority fee (EIP-1559 tip). Not verified from the docs; the
  worse reading for H04.
- S3. Hyperliquid's handling of an `approveAgent` for an agent address that is already some other account's agent is
  not documented (docs "Nonces and API wallets", fetched 2026-10-19). `userRole` returns exactly one user per agent
  (read: the platform vault's agent [an earlier agent] -> `{"role":"agent","data":{"user":"[an earlier vault]"}}`), so a second approval
  either fails or rebinds. H05 is rated on the worse reading, marked premise unverified.
- S4. The keeper's treasury operator settles a served vault whenever its epoch can be settled (not verified per
  cadence); the H06 numbers give the range for 1 h and 24 h epochs.

## Summary

| ID | Title | Severity | Location | PoC (passes) |
|---|---|---|---|---|
| **HLR2-H01** | A queued loosening applies before a depositor who asked to leave in the same block can force an exit; the loosening can push the forced exit from 7 to 30 days. The "so you can leave first" promise is false | **High** (design, untrusted owner) | VaultPolicy.sol:255-274, 365-371; VaultMath.sol:202-204; VaultGovernance.sol:244-246; VaultLogic.sol:205-216; webapp docs/depositors.tsx:319, overview.tsx:26 | `test_HLR2_H01_loosenedPolicyAppliesBeforeASameBlockRedeemerCanForceAnExit`, `test_HLR2_H01b_keeperOperatorCannotGetTheRedeemerOutEither` |
| HLR2-H04 | X-01 variant: in emergency the manager chains MIN_BRIDGE bridges so the platform's exit settle only lands if it is first in one block per window; the executor sends with a zero tip | Medium (conditional) | VaultLogic.sol:438-439, 223-224; server chain/vault.ts:1077-1080 | `test_HLR2_H04_managerBridgeChainKeepsTheEmergencySettleOut` |
| HLR2-H05 | Hyperliquid agent-address pre-emption: anyone can `approveAgent` a vault's announced agent address for their own account before the vault's `syncAgent` lands (or, worse reading, rebind a live one); `syncAgent` re-approval is unrestricted | Medium (premise unverified) | VaultLogic.sol:601-607; HyperVaultFactory.sol:243, 311; HL side | `test_HLR2_C_strangerCallsOnARealVault` (contract half); HL half is a scenario |
| HLR2-H06 | (Executor) a sybil "outside depositor" makes a spam vault served; the shared daily operator / fee HYPE budgets then stop service for genuine third-party vaults | Medium (design, scenario) | server treasury/operator.ts:125-138; gasBudget.ts; tenants/outside.ts | scenario with numbers |
| HLR2-H03 | The owner's timelocked `clearBreach` undoes a guardian stop after the vault timelock (>= 1 day) unless the cold EOA guardian cancels or re-triggers in time | Low (N-04 design restated) | VaultGovernance.sol:259-265, 332-362 | `test_HLR2_H03_ownerTimelockedClearUndoesAGuardianStop` |
| HLR2-H07 | The factory owner key (an EOA, also the guardian) has instant, live powers over every existing vault: guardian / sentinel rotation, protocol fee redirect, agent revocation | Low (process; see HLO-08) | HyperVaultFactory.sol:316-337, 374-396 | `test_HLR2_D_factoryOwnerRedirectsProtocolFeesOfExistingVaultsInstantly`, `test_HLR2_D_newGuardianActsOnEveryExistingVaultAtOnce` |
| HLR2-H02 | `setAssetCurated(false)` is future-only: no platform lever de-lists a perp on existing vaults (N-13 restated) | Info | VaultPolicy.sol:184, 339-341; HyperVaultFactory.sol:410-420 | `test_HLR2_H02_decuratedAssetStaysTradableOnExistingVaults` |
| HLR2-H08 | The hot registrar may register a replacement agent for any existing vault at any time (`agentOfVault` overwritten); it only takes effect through that vault owner's timelock | Info | HyperVaultFactory.sol:303-312 | `test_HLR2_D_registrarRebindsAgentOfVaultOnAnExistingVault` |
| HLR2-H09 | Isolation re-checked: a hostile launch cannot take, name or queue a real vault's agent; stranger calls on a real vault change no role | Info (checked) | HyperVaultFactory.sol:232-244; VaultLogic.sol:609-616 | `test_HLR2_C_hostileLaunchCannotTakeARealVaultsAgent`, `test_HLR2_C_strangerCallsOnARealVault` |

No Critical. H01 is the one High. It is reachable on the live round 4 factory today (`openLaunch = true`): any launcher
can do it to their own vault's depositors. It is not exploitable against today's money: the three live HL vaults hold
about 172 USDC, all owned by the platform's own wallet [platform wallet]. The platform vault is also protected operationally while the
keeper is its operator and its NAV sits free in perp (read 2026-10-19: no positions, `withdrawable` ≈ NAV).

## 3.6 Instant versus timelocked: every setter

V = HyperVault (clone, owner = launcher), P = VaultPolicy (clone, own Ownable2Step owner, the launcher), F = factory
(owner = guardian = EOA `0x1A7a…D7ff`). "Live" = reaches existing vaults.

| Contract | Setter | Who | Instant / timelocked | Reach |
|---|---|---|---|---|
| V | `setManager`, `setFeeRecipient`, `setTimelockDelay` (1–30 d), `setAgent` (factory-bound agent only) | owner queues, **anyone executes** in [eta, eta + 14 d] | timelocked (vault delay) | that vault |
| V | `setFees`: management raise applies at execute (accrued at the old rate first); performance raise from the next normal settle | owner queues, anyone executes | timelocked | that vault |
| V | `clearBreach` | guardian instant; owner via queue created after the breach | both | that vault |
| V | `lowerFees` | owner | instant (lower only) | |
| V | `setOperator` (any address, or 0) | owner | **instant** | |
| V | `revokeOperator` | owner, guardian, sentinel | instant | |
| V | `setDepositsPaused` / `setTradingPaused` | pause: owner, guardian, sentinel; unpause: owner, guardian | instant | |
| V | `setDepositCap` (0 < cap ≤ F.maxDepositCap) | owner | instant | |
| V | `leaveHosted` (one way, revokes agent) | owner | instant | |
| V | `revokeAgent` | owner, guardian, sentinel, factory | instant | |
| V | `triggerBreach` | owner, guardian, sentinel | instant | |
| V | `triggerEmergency` | owner, guardian; anyone once overdue with redemptions | instant | |
| V | `exitEmergency` | guardian | instant | |
| V | `resume` (drawdown breach, ≥ 24 h) | owner | instant | |
| V | `cancel(id)` | owner, guardian | instant | |
| V | `transferOwnership` / `acceptOwnership` | owner, then new owner | **instant** (two step, no delay) | the new owner holds every owner power, and the old owner stops being an insider |
| V | `rescueToken` (not USDC, not shares) | owner | instant | |
| V | `lowerProtocolShare` | F.owner via factory | instant, lower only | live |
| P | `proposeConfig` tighter on every field (incl. **`maxNavMoveBps` up** and `maxEpochDuration` down) | P.owner | **instant** | |
| P | `proposeConfig` looser | P.owner; `applyPendingConfig` anyone in [eta, eta + 14 d] | timelocked (policy delay); a new proposal overwrites the pending one | |
| P | `cancelPendingConfig`, `disallowAsset` | P.owner | instant | |
| P | `queueAllowAsset` / `allowAsset` (curated only, at queue and at allow) | P.owner / anyone | timelocked | |
| P | `proposeTimelockDelay` raise / lower | P.owner / anyone applies | instant / timelocked | |
| P | `transferOwnership` | P.owner | instant (two step); P.owner may differ from V.owner | |
| F | `setGuardian`, `setSentinel` | F.owner | **instant, live for every vault** | live |
| F | `setProtocolFeeRecipient` | F.owner | **instant, live** (read at every accrual) | live |
| F | `setAgentRegistrar` | F.owner | instant; the registrar can then bind launches and replacements | live |
| F | `registerPlatformAgent` | registrar (existing vaults), F.owner (any address) | instant on the factory; on a vault only through its owner's timelock | live (H08) |
| F | `unregisterPlatformAgent` | registrar (not live agents); F.owner, guardian, sentinel (revokes a live agent) | **instant, live** | live |
| F | `setMaxDepositCap` | F.owner | instant; future caps and every owner's `setDepositCap` bound; 0 freezes them (HLO-11) | partly live |
| F | `setAssetCurated` | F.owner | instant; future policies and future `allowAsset`, **not** existing allowlists (H02) | future |
| F | `setShares`, `setMinSeedUsdc`, `setMinHypeValue`, `setLauncherAllowed`, `setOpenLaunch` | F.owner | instant | future |
| F | `transferOwnership` (two step; no hot role), `renounceOwnership` (reverts) | F.owner | instant | |

Code: no path changes the code behind a live vault or policy. Both are EIP-1167 clones of implementations that are
`immutable` in the factory. The vault calls its logic through linked libraries (addresses fixed in the bytecode) and
calls out only to the factory views (`guardian`, `sentinel`, `protocolFeeRecipient`, `platformAgentFor`,
`maxDepositCap`), its own policy clone, USDC, the CoreDepositWallet and the HyperCore system addresses. No
`delegatecall` goes to a mutable address. `$.policy`, `$.factory` and `$.coreDepositWallet` are set once in
`initialize`. What does change behaviour live is the factory views above: the guardian, the sentinel and the fee
recipient. The KNOWN-ISSUES line "the factory ... cannot change an existing vault's code, fees, policy or manager"
is true as written. It leaves out that the factory owner changes, at once and for every vault, who may clear
breaches, end emergencies, cancel queued items and revoke agents, and where protocol fees go (H07).

Other timelock mechanics checked:
- **GRACE_PERIOD 14 days** on both. A queued item can be executed by anyone at any moment in a 14-day window, so the
  owner (or anyone) picks the moment. Expired items revert `Expired`.
- **Queue overwrite.** Re-queuing the same calldata resets its eta later. A new `proposeConfig` overwrites the pending
  config and its eta. A tightening deletes any pending loosening. None of these shortens a delay.
- **Anyone can execute.** Execution is by calldata hash, and only the six whitelisted selectors are queueable with
  exact calldata lengths (N-04). Nothing here is new.
- **clearBreach through the timelock during a guardian stop:** H03.
- **Delay lowering.** Vault `setTimelockDelay` is itself behind the old delay. Policy lowering waits the old delay;
  raising is instant. The minimum is 1 day on both.

## HLR2-H01 (High, design): loosening applies before the redeemer can force an exit

**Claim tested.** VaultPolicy's NatSpec says "loosening waits for a timelock so depositors always get time to exit
before the manager is allowed to take more risk". The webapp says "Loosening limits, raising fees or changing the
manager waits for a timelock of at least a day, so you can leave first" (`webapp/src/docs/depositors.tsx:319`, also
`overview.tsx:26`, `docs/copy/COPY-V2-SPEC.md:90`).

**Why it fails.** A depositor cannot leave on their own. A redemption is paid only by a settle. A normal settle is the
manager's or the operator's (VaultLogic.sol:207-216), and the owner may remove the operator instantly. Even with the
keeper as operator, a normal settle reverts unless the full payout is idle (VaultLogic.sol:263-264), and the keeper
cannot free margin outside a breach (`flatten` needs a breach or emergency for the operator). The only forced exit is
`triggerEmergency` once `epochStartedAt + policy.maxEpochDuration()` has passed (VaultMath.sol:202-204). That is read
**live**, so a loosening that raises `maxEpochDuration` also moves the forced-exit date for redeemers already waiting.
The timelocks are 1–30 days, the epoch 1 hour–30 days, and nothing relates them: the platform vault has 2 days against 7.

**PoC timeline** (`test_HLR2_H01_…`, the platform vault configuration, t0 = epoch start + 1 h):

| time | event | alice |
|---|---|---|
| t0 | owner (= manager): `setOperator(0)` (instant), `proposeConfig(50x, breakers 100%, slippage 20%, notional max, **epoch 30 d**, NAV move 100%)` -> eta t0 + 2 d. Same block: alice `requestRedeem(all)` | 100,002 USDC |
| t0 … t0 + 2 d | alice cannot `settle` (Unauthorized), the keeper cannot (Unauthorized), `triggerEmergency` -> `NotOverdue`. The manager's 45x order is still refused (`notional too large`) | waits |
| t0 + 2 d | anyone `applyPendingConfig()`. The manager's 4.5M-notional order (45x) is accepted | still in, redemption unsettled |
| later | the position loses 95% and is closed; `checkRisk` breaches nothing (limits 100%) | 5,002 USDC |
| epoch start + 7 d + 1 h | the date the old policy promised: `triggerEmergency` -> `NotOverdue` | stuck |
| epoch start + 30 d | first forced exit (29 days after the request) | 5,002 USDC |

`test_HLR2_H01b_…`: same with the keeper kept as operator and the NAV in margin (4x, `withdrawable` 0). The keeper's
`settle` and `bridgeToEvm` revert `InsufficientLiquidity`, its `flatten` reverts `Unauthorized`, and the loosening
applies with the redemption still pending.

**Impact × likelihood.** Impact: a depositor who reacts within the same block to a queued loosening is still exposed
to 100% of the loosened policy for at least `maxEpochDuration − timelock` (the platform vault: 7 d − 2 d = 5 days). When the
loosening also raises the epoch, up to 30 d − 1 d = 29 days. In the PoC alice keeps 5% of her value, i.e. up to 100%
loss, and a temporary lock with no exit for 29 days. Likelihood: it needs a hostile owner. Under open launch that is
any launcher (about $1.8 per vault, HLO-01), but depositors reach a stranger vault only by direct link (Explore is
curated). Against the platform vault it needs the platform's own owner key. High per the scale (conditional loss plus
temporary lock with no exit), and the public copy states the opposite.

**Fix (sketch, either A or B, plus C):**

```solidity
// A. Delays at least one full epoch plus the overdue path (policy and vault, at initialize and on every change):
//    VaultPolicy._validate(c) and initialize/proposeTimelockDelay:
require(timelockDelay >= c.maxEpochDuration + 1 days, "timelock < epoch");   // and for the pending config's epoch
//    HyperVault initialize / setTimelockDelay: delay >= policy.maxEpochDuration() + 1 days

// B. A loosening applies only after an epoch boundary that settled every redemption queued before it:
//    the policy records queuedAt; the vault exposes lastSettleAt (epochStartedAt) and emergency.
function applyPendingConfig() external {
    ...
    require(IVaultView(vault).epochStartedAt() > _pending.queuedAt, "settle first");   // the redeemers were paid
}

// C. Snapshot the forced-exit deadline per epoch, so a later epoch loosening never extends a running epoch:
//    in settle():  $.epochDeadline = uint64(block.timestamp + $.policy.maxEpochDuration());
//    epochOverdue: return block.timestamp >= $.epochDeadline;
```

With B, a manager who does not settle never gets the loosening, and the redeemer reaches the old deadline first. B
needs the policy to know its vault (the factory can pass it at `initialize`). Also restrict `setOperator(0)` while
redemptions are pending, or make the overdue exit-only settle callable by anyone (today it is platform roles only,
I2-02) so that the exit does not depend on the platform being awake. Until fixed, change the copy to say what holds:
"a looser limit takes effect after the timelock; your redemption is paid at the next settlement, at the latest by the
epoch deadline, which the loosening may extend".

## HLR2-H04 (Medium, conditional): the manager's bridge chain in emergency

In emergency the manager (and the operator) may still `bridgeToEvm` (VaultLogic.sol:439). Each bridge opens a window
of `BRIDGE_SETTLE_BLOCKS` (10) blocks plus landing, and every settle reverts `BridgeInFlight` inside it. The guardian
cannot remove the manager (`setManager` is the owner's, timelocked). PoC `test_HLR2_H04_…`: five consecutive windows
are taken by the manager's 100 USDC bridges, the guardian's settle reverts in each, and it succeeds only in a block
the manager did not take. Upper bound of the delay: one window per `MIN_BRIDGE` (100 USDC) of USDC the manager can
move: 1M USDC on Core = 10,000 windows × 11 blocks ≈ 30.5 h at 1 s blocks; 100M = 127 days. Each bridge costs the
manager about 150k gas at ~0.46 gwei (live `eth_gasPrice` 462,340,249 wei) ≈ 0.00007 HYPE. Every bridge moves USDC
home, so the funds are not lost; the exit is delayed. X-01 was accepted on the premise that the platform settler
"wins with a priority fee". It does not set one (open question 4): the executor prepares HyperEVM sends with viem's
defaults, and the RPC's `eth_maxPriorityFeePerGas` answers `0x0`. In the 5 most recent blocks the 90th percentile
tip was 3 gwei (`eth_feeHistory`). Amplifier (unverified): each Core→EVM send costs the vault 200k gas in HYPE
from its Core spot (HL docs). The seed is 0.01 HYPE, about 100 sends. Once that is gone, a manager's bridge
presumably fails on Core without landing, which holds the window for up to 300 blocks per call and moves no USDC.
The platform can counter by topping up with `fundCoreGas` (anyone may call it).

Fix: in emergency only the platform roles bridge (drop the manager from `bridgeToEvm` when `$.emergency`), or let the
emergency exit-only settle run inside a window on the pre-bridge snapshot with idle USDC only. Executor: an explicit
`maxPriorityFeePerGas` for guardian/sentinel/keeper settles, e.g. 2–5 gwei.

## HLR2-H05 (Medium, premise unverified): Hyperliquid agent-address pre-emption

On HyperCore the master signs `approveAgent {agentAddress, agentName, nonce}`. The agent's key is not needed: the
official SDK generates a key and approves its address (`evidence/hl-sdk/exchange.py:635-657`). A vault's agent address
is public before the vault's approval lands. It appears in `create` calldata and `VaultCreated.agent`, and A-13 forces
the approval into a later `syncAgent` transaction. For a rotation it appears in `PlatformAgentRegistered`, then sits
in the vault's timelock queue (the platform vault: 2 days). `userRole` maps an agent to exactly one user (S3). So:
- if Hyperliquid refuses a second approval of an address already used by another user, an attacker who approves the
  announced address on their own (funded) account first makes the vault's `addApiWallet` fail silently, and it can
  repeat that for every replacement. Platform-agent launches (hosted, own signal, copy) and agent rotations become a
  denial of service at the cost of one signed action each. The platform vault's agent is `validUntil` 1799292344459 ms
  (2027-01-06), so its rotation is due within 80 days.
- if Hyperliquid rebinds instead, the same action detaches a live agent from any vault at any time (DoS of every
  served vault; the executor's orders would then trade the attacker's own account).
- `syncAgent` is callable by anyone, unbounded (`test_HLR2_C_strangerCallsOnARealVault`: three approvals of the same
  address by a stranger). The docs say a matching-name approval deregisters the existing named agent and that
  deregistration "may" prune its nonce set, after which "previously signed actions can be replayed". If a re-approval
  of the same address prunes, anyone can open a replay window for the agent's actions signed in the last 2 days (the
  nonce time bound).

No funds leave the vault in either reading; the impact is availability (agent trading stops; the risk breakers still
work). Verify on testnet with own funds: (1) a second master approving an address that is another account's agent;
(2) `syncAgent` twice, then resubmit a recently signed order. Fix: restrict `syncAgent` to the owner, manager, operator,
sentinel and guardian. Executor: check `userRole(agent) == vault` before every order and alert on mismatch, and call
`syncAgent` in the block right after `create` (it already polls, `agentSync.ts`).

## HLR2-H06 (Medium, executor design): budgets shared with sybil-served vaults

Since the E10 fix the keeper operator and the fee accruer serve a non-platform vault only if it has an "outside
depositor" (`tenants/outside.ts`: any non-cancelled deposit request from a controller other than the owner and
manager). One 10 USDC request from a sybil qualifies, refundable by `cancelDepositRequest` or a later redemption. The
daily HYPE budgets are global per job (the operator's daily gas budget 0.25, the fee job's daily gas budget 0.05; `gasBudget.ts`
keys `gas:<job>:<day>`). When they are spent, the operator and the accruer stop for every non-platform vault until
00:00 UTC (`operator.ts:137-138`). Numbers: a settle is about 400–440k gas (`chain/vault.ts:1076`). At 0.46 gwei that
is ≈ 0.0002 HYPE, so 0.25 HYPE ≈ 1,300 operator transactions a day. A spam vault with a 1 h epoch can take up to 24
settles a day (S4): about 55 vaults exhaust the operator budget, about 55 × (2 USDC seed + 10 USDC request) ≈ 660 USDC
of capital, of which ≈ 55 USDC is lost. With daily settles it is about 1,300 vaults (≈ 15.6k capital, ≈ 1.3k lost). The
effect: genuine third-party vaults lose their keeper settles for the rest of the UTC day (their owners can still
settle; platform-run vaults are exempt). Fix: per-vault budgets with a priority for vaults by outside TVL (e.g.
≥ 1,000 USDC of outside deposits for full service), and count "outside" by value, not by request.

## HLR2-H03 (Low): the owner's timelocked clear of a guardian stop

`triggerBreach` by the guardian or sentinel revokes the agent. After the vault timelock (≥ 1 day) the owner's queued
`clearBreach` (queued after the breach) clears it and anyone executes it. The manager trades on chain again
(`test_HLR2_H03_…`). This is N-04 by design, but the counter is the cold guardian, an EOA run by one person: it must
cancel or re-trigger inside the delay. Fix: a GUARDIAN-reason stop is cleared only by the guardian, and the owner's
queued clear covers risk breaches only. Or keep it, and put "owner queued clearBreach during a platform stop" on the
monitor's top alert class with the eta.

## HLR2-H07 (Low, process): the factory owner key reaches every vault at once

Live read (2026-10-19): round 4 and round 3 factories, `owner = guardian = 0x1A7acB7966e6E3632694484dE261B70230eCD7ff`,
no code, nonce 11, no pending owner. That one key can, in one transaction each and with no delay:
- `setGuardian(x)`: x clears any breach on any vault, ends any emergency, cancels any queued item and flattens with 3%
  slippage in emergency (`test_HLR2_D_newGuardianActsOnEveryExistingVaultAtOnce`);
- `setProtocolFeeRecipient(x)`: all future protocol fee shares of every vault go to x
  (`test_HLR2_D_factoryOwnerRedirectsProtocolFeesOfExistingVaultsInstantly`). This is theft of the platform's fees,
  not of depositors' money;
- `unregisterPlatformAgent`: revokes any live agent (the hot sentinel can do this too);
- sign agent bindings for any launcher (HLO-07, `test_HLO07_r2_factoryOwnerKeyAlsoBindsASelfHeldAgent`).

Fix: the Safe runbook (`docs/runbooks/guardian-to-safe.md`), and a factory-level timelock on `setGuardian`,
`setSentinel`, `setProtocolFeeRecipient` and `setAgentRegistrar`. A short one (e.g. 1 day) is enough, so the monitor
sees a rotation before it takes effect. The emergency sentinel rotation can stay instant if it may only rotate
**to** a pre-registered backup key.

## HLR2-H02 (Info): no live de-listing

`setAssetCurated(SOL, false)` leaves `isAssetAllowed(SOL)` true on existing policies, and the manager's on-chain SOL
order still passes (`test_HLR2_H02_…`). Only new vaults and new `allowAsset` calls are refused. KNOWN-ISSUES N-13
documents it. The consequence for incident response: if a curated perp becomes unsafe (oracle incident, delisting),
the platform can only pause trading vault by vault (sentinel `setTradingPaused`). Fix: `checkOrder` also requires
`IFactoryCuration(factory).isAssetCurated(asset)` for non-reduce-only orders (one staticcall), and the executor guard
reads the factory flag too.

## HLR2-H08 / H09 (Info): registrar reach and isolation

- The registrar can `registerPlatformAgent(B, anyExistingVault)` at any time. It overwrites `agentOfVault`, while the
  live agent A stays bound (`platformAgentFor[A]` unchanged). It takes effect only if that vault's owner queues and
  executes `setAgent(B)`. With a leaked registrar key, a hostile owner can bind a self-held agent to their own
  existing vault this way: the HLO-07 path, behind their own (public) timelock.
- A hostile launch cannot use a real vault's agent: `NotPlatformAgent` without a signature, `AgentAlreadyBound` with a
  fresh registrar signature, and `setAgent` through its own timelock fails `NotPlatformAgent`
  (`test_HLR2_C_hostileLaunchCannotTakeARealVaultsAgent`). Predicted addresses and signatures are scoped by creator,
  so a real launch cannot be front-run on chain (hl-open HLO-04 holds).
- Stranger calls on a real vault (`syncAgent`, `fundCoreGas`, `checkRisk`, `accrueFees`, `syncBridge`, `claim`) change
  no role or agent (`test_HLR2_C_strangerCallsOnARealVault`). `checkRisk` is permissionless by design. Its timing sets
  the day's reference price (first check of the UTC day) and can trigger a breach on a wick, which costs a depositor
  nothing and the owner a 24 h resume wait at most.
- Owner, manager or fee recipient as a contract: the vault never calls them (no callbacks, fee shares are minted), so
  a reverting or malicious contract owner cannot block settles, accruals or claims.
- Treasury: it holds fee shares of every stranger vault (HLO-13) and never calls them, and nothing in the executor
  redeems them (`grep requestRedeem server/src`: none). A hostile vault therefore cannot make the treasury pay gas or
  take its USDC. Its only effect is on the treasury's share of that vault's NAV.
- Indexer: the executor's single log stream filters by address, both factories plus active vaults and their
  policies (`chain/logStream.ts:47`), and breach lookups filter by the vault's address (`chain/vault.ts:681`). A
  hostile vault's events are its own; a non-factory contract emitting HyperVault-shaped events is not followed. After
  the HLO-E05 fix platform alerts carry the address and an operator label, not the on-chain name. The E06 fix alerts
  on unknown agents. After the HLO-02 fix the webapp's "Hosted by DojiPad" and owner attribution come from the
  executor's tenant and consent, not the chain flag. What is left is the name and symbol, which stay free on chain
  (HLO-02).
