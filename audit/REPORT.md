# DojiPad Vaults: Security Audit Report

## 1. Summary

| | |
|---|---|
| Scope | `contracts/src/HyperVault.sol`, `HyperVaultFactory.sol`, `VaultPolicy.sol`, `hypercore/HyperCore.sol`, `libraries/PxMath.sol`; secondary pass on `server/src` |
| Commit | HEAD `896a0d6` on `main`. `contracts/src` is byte-identical to `0a9311a`; the only `server/src` change since then (`index.ts:155`, sweep error handling) affects no finding |
| Method | Pass 0 surface map, Pass 1 tooling, Pass 2 invariant suite, Pass 3 manual review by threat actor (A-F) per area (1-13), Pass 4 HyperCore assumptions (read-only mainnet RPC + info API + HL docs), Pass 5 server, Pass 6 re-run |
| Tools | Foundry `forge 1.8.4` (solc 0.8.28, via_ir), Slither 0.11.6, vitest 5.0.3. Aderyn not run (no Windows build, WSL absent; see notes.md) |
| Results | Contracts: **1 Critical, 2 High, 5 Medium, 6 Low, 8 Info**. Server: **1 High, 3 Medium, 8 Low, 5 Info** (see `server/test/audit/SERVER_FINDINGS.md`) |
| Tests | 17/17 contract PoCs pass (each pass = exploit works). Invariant suite passes 512 runs x depth 200 (102,400 calls). Baseline 88/88 still pass. Server audit tests 18/18 pass |

Auxiliary files: `contracts/audit/surface.md` (Pass 0), `contracts/audit/notes.md` (tool triage, log), `contracts/audit/FIXES.md` (implementation-ready fixes), `server/test/audit/SERVER_FINDINGS.md`.

**Headline.** The contracts' accounting core holds up: share math, rounding, epoch bookkeeping, reserved-USDC backing, the timelock selector whitelist and protocol-share monotonicity all survived 102k random calls with a simulated HyperCore. The serious problems sit at the boundary of what the contract can see. NAV only counts perp dex 0 plus spot USDC, and an agent can move value out of that view at almost no cost. The owner, who on factory vaults is the untrusted manager, can instantly undo every risk control. In combination this lets a malicious third party manager take most of the depositors' money (C-01, about 82% in the PoC).

### How to run

```
cd contracts
forge test --match-path test/audit/AuditPoC.t.sol -vv                       # all PoCs
forge test --match-test test_AUDIT_C01 -vv                                  # one PoC
forge test --match-path test/audit/invariants/VaultInvariants.t.sol -vv     # invariants (~90 s)
cd ../server && npx vitest run test/audit                                   # server PoCs
```

## 2. Findings table

| ID | Title | Severity | PoC | Location |
|---|---|---|---|---|
| C-01 | Agent can deflate NAV out of `coreEquity()`'s view; manager's deposit settles at the depressed price | Critical | `test_AUDIT_C01_agentNavDeflationStealsFromDepositors` passing | HyperVault.sol:434-439, 570-619 |
| H-01 | Owner instantly disarms risk controls and the emergency path (`clearBreach`, `setAgent`, `exitEmergency` untimelocked) | High | `test_AUDIT_H01_*`, `test_AUDIT_H01b_*` passing | HyperVault.sol:830, 920-933 |
| H-02 | Bridge window can be re-armed with 1e-6 USDC to block `settle()` indefinitely (anyone in emergency, manager always) | High | `test_AUDIT_H02_bridgeWindowGriefBlocksEmergencySettle` passing | HyperVault.sol:572, 735-759, 445 |
| M-01 | `checkRisk()` in-flight upper bound double counts: masks breaches, and forces false daily-loss breaches | Medium | `test_AUDIT_M01a_*`, `test_AUDIT_M01b_*` passing | HyperVault.sol:864-873 |
| M-02 | Timelocked fee raise executed inside a bridge window is applied retroactively | Medium | `test_AUDIT_M02_feeRaiseInBridgeWindowIsRetroactive` passing | HyperVault.sol:1032-1038 |
| M-03 | Timelocked changes never expire (vault queue, policy config, asset allow) | Medium | `test_AUDIT_M03_queuedChangesNeverExpire` passing | HyperVault.sol:980-1002; VaultPolicy.sol:159-178, 195-208 |
| M-04 | Contract-path trading is weaker than the policy says: flatten up to 20% regardless of policy, no leverage check per order | Medium | `test_AUDIT_M04a_*`, `test_AUDIT_M04b_*` passing | HyperVault.sol:775-824 |
| M-05 | Performance fee crystallises on transient mark-to-market highs (permissionless `accrueFees`, ratcheting HWM) | Medium | `test_AUDIT_M05_perfFeeOnTransientSpike` passing | HyperVault.sol:622-660 |
| L-01 | `maxOrderNotional` measured at limit price: deep resting bids carry many times the cap | Low | `test_AUDIT_L01_*` passing | VaultPolicy.sol:146-151 |
| L-02 | ERC-4626 previews ignore pending fee accrual; differ from settle | Low | `test_AUDIT_L02_*` passing | HyperVault.sol:375-389 |
| L-03 | Fee dilution counts as drawdown: anyone turns a fee accrual into a breach | Low | `test_AUDIT_L03_*` passing | HyperVault.sol:885-889 |
| L-04 | `totalAssets()` and all conversion views double count inside the bridge window | Low | `test_AUDIT_L04_*` passing | HyperVault.sol:360-364 |
| L-05 | Negative perp `accountValue` clamped to 0 while spot is still added: NAV overstated | Low | `test_AUDIT_L05_*` passing | HyperVault.sol:437 |
| L-06 | `initialize` approves the agent before the deposit that creates the Core account (conditional) | Low | `test_AUDIT_L06_*` passing (ordering) | HyperVault.sol:337-341 |
| I-01..I-08 | See section 3.4 | Info | - | - |

## 3. Findings

### C-01 (Critical): Agent can deflate NAV, manager's deposit settles at the depressed price

**Description.** `coreEquity()` (434-439) counts only `accountMarginSummary(dex 0).accountValue` plus spot **USDC**. A Hyperliquid API wallet can sign `agentSendAsset`. This is documented ("Similar to send asset, but can be signed by an agent. Destination must match the source address") and moves the vault's own USDC from perp dex 0 to another perp dex or to spot. An agent can also buy any spot token with an `order` (asset 10000+i). Either step removes value from what NAV can see without losing it. `settle()` (570) prices pending deposits and redemptions at that NAV. A breach does not block settlement, and the owner can re-arm an agent instantly (H-01). The manager can therefore mint shares at an artificial discount and restore NAV afterwards.

**Impact.** Theft of depositor funds by the manager of any factory vault. On factory vaults the creator picks owner, manager, guardian, fee recipient and agent. The PoC turns Mallory's 1,000,000 USDC into 1,818,181 USDC of claims and takes Alice from 1,000,000 to 181,819. Mallory then withdraws real USDC. Even an honest vault that holds non-USDC spot or funds on a HIP-3 dex is mispriced at every settle.

**Exploit.**
1. Alice has 1M in the vault, deployed to Core perp.
2. Mallory (manager+owner) calls `requestDeposit(1M)` during the epoch.
3. Mallory's agent calls `agentSendAsset` to move 900k of perp USDC to another dex (or buys a spot stable). NAV now reads 100k.
4. If anyone calls `checkRisk()`, the vault breaches (drawdown) and the agent is revoked, but `settle()` is still allowed. Mallory settles: 1M buys about 10x Alice's share count.
5. Mallory calls `clearBreach()` and `setAgent()` in the same block (no timelock). The agent moves the 900k back, NAV is 2M and Mallory owns 10/11.
6. Mallory redeems against the idle USDC.

**PoC.** `forge test --match-test test_AUDIT_C01 -vv`.

**Root cause.** NAV is a partial view of the Core account. The agent can move value between the counted and uncounted parts, and settlement prices at a single spot reading with no sanity bound.

**Fix (describe).**
1. Make NAV complete or make settlement refuse when the view may be incomplete. Count every spot token at oracle or mark price and every perp dex (or assert they are zero).
2. Do not settle when `breached`, or when NAV moved more than X% since the last `checkRisk` or settle. Use NAV = min(current, last checkpoint) for deposits and max for redemptions within the epoch.
3. Cap a single account's share of an epoch's deposits relative to supply, or make deposits by the manager, owner or fee recipient wait one extra epoch.
4. Timelock `setAgent` and `clearBreach` (H-01).

The structural fix is to stop giving API-wallet access to non-hosted managers, or to whitelist agents per vault through the factory owner (D-1).

**HyperCore assumption.** An agent can sign `agentSendAsset` between dexes and spot `order`s for the vault's account. The first is in the HL exchange endpoint docs; the second is the standard order action. It was not executed on mainnet, per the no-broadcast rule.

### H-01 (High): Owner instantly disarms risk controls and the emergency path

**Description.** These owner functions have no timelock:
- `setAgent` (830)
- `clearBreach` (920), which also resets `peakSharePrice` and `dayStartEquity` to the current, post-loss values
- `exitEmergency` (930), which removes the permissionless `bridgeToEvm` path
- `setGuardian`, `setDepositCap`, `transferOwnership`

On factory vaults the owner is the creator (an untrusted manager). The README and contract claim depositors get time to exit before risk increases, and that "depositors can never be trapped by an absent manager". The policy is timelocked; the controls that enforce it are not.

**Impact.** Loss limits are not cumulative. In the PoC, five 30% losses against a 15% drawdown limit leave 16.8% of equity, with `breached` cleared and the agent re-armed in the same block each time. During emergency the owner exits immediately. Strangers can then no longer bridge funds back, settlement fails for lack of liquidity, and the manager can push idle USDC back to Core.

**PoC.** `test_AUDIT_H01_ownerResetsBreachAndRearmsAgentInstantly`, `test_AUDIT_H01b_ownerExitsEmergencyAndTrapsRedeemers`.

**Root cause.** Breach and emergency can be released by the role they are meant to constrain.

**Fix.**
- Route `clearBreach`, `exitEmergency` and `setAgent` through `queue/execute` (timelock), or require the guardian when the guardian is a platform-controlled address.
- Do not reset `peakSharePrice` on `clearBreach`; keep a separate lifetime high and limit total drawdown from it.
- Block `exitEmergency` while `pendingRedeemShares > 0`.

### H-02 (High): Bridge window re-arming blocks `settle()` indefinitely

**Description.** `settle()` and `accrueFees()` revert while `bridgeInFlight()` (block <= lastBridgeBlock + 10). `bridgeToEvm` (735) is open to anyone during emergency and accepts any amount down to 1 (1e-6 USDC). Every call restarts the window. The manager can do the same at any time with `bridgeToEvm` or `bridgeToCore`. Factory vaults always hold dust on Core (1 USDC after the activation fee, verified on mainnet), and anyone can top it up with a Core spot send.

**Impact.** Redemptions never settle, even in emergency, for as long as the griefer is first in one block out of every 11. That costs one cheap transaction about every 11 blocks, and priority ordering on HyperEVM favours whoever pays. A malicious manager uses this to hold depositors hostage. Rated High rather than Critical because the attacker must keep it up and win ordering.

**PoC.** `test_AUDIT_H02_bridgeWindowGriefBlocksEmergencySettle`: 50 consecutive windows, `settle()` reverts with `BridgeInFlight` each time.

**Fix.**
- Make the window amount-aware and non-extendable by dust: require `amount >= minBridge` (e.g. 1% of NAV or a fixed floor).
- Allow `settle()` inside a window by pricing pending amounts at the conservative bound: exclude `pendingToCore` for deposit pricing and include `pendingToEvm` only once it has been observed.
- Rate-limit `bridgeToEvm` by non-managers to one call per epoch.

### M-01 (Medium): In-flight upper bound in `checkRisk()` double counts

**Description.** `checkRisk()` (864-873) uses `idle + coreEquity + pendingToCore + pendingToEvm` while in flight. HyperCore credits EVM->Core deposits at the next L1 block, and Core->EVM sends arrive within a block or two, so the destination usually already shows the funds and the bridged amount is counted twice.
- (a) A manager who bridges back and forth every 11 blocks keeps `checkRisk` from ever seeing a real 30% drawdown (20 cycles in the PoC).
- (b) If the first `checkRisk` of a UTC day falls inside a window, `dayStartEquity` is set to the inflated value (1.4M on 1M real). The next call reports a 28.6% "daily loss" and breaches: agent revoked, deposits closed.

**Impact.** Breach detection can be evaded (a, needs the manager to win block ordering at each window edge), and anyone can force a false breach (b, needs the day's first `checkRisk` inside a window).

**PoC.** `test_AUDIT_M01a_bridgePingPongMasksBreach`, `test_AUDIT_M01b_dayRollInsideBridgeWindowForcesFalseBreach`.

**Fix.**
- Evaluate breaches against a lower bound (no in-flight additions) but only **act** on breaches that also hold for the upper bound computed without double counting: `max(idle + core, idle + core + pending - min(pending, observedCredit))`. Simpler: skip the day-roll baseline update while in flight.
- Track the pre-bridge `idle + core` snapshot and use it as the in-flight equity.

**Assumption.** Bridge credits land within BRIDGE_SETTLE_BLOCKS. The mainnet seed (bridged and visible on Core) is consistent with this.

### M-02 (Medium): Fee raise executed inside a bridge window is retroactive

**Description.** `_setFees` (1032) only crystallises at the old rate when `!bridgeInFlight()`. `execute` is permissionless and the manager can open a window with `bridgeToCore(1e6)` in the same block. The new rates then apply to everything since `lastFeeAccrual`, including management time and unrealised gain earned under the old rate.

**Impact.** Fee theft. In the PoC, 50% gain earned at a 20% perf fee is charged at 30%: 150,164 vs 100,164 USDC.

**PoC.** `test_AUDIT_M02_feeRaiseInBridgeWindowIsRetroactive`.

**Fix.** In `setFees`, revert when `bridgeInFlight()` instead of silently skipping accrual (`lowerFees` may keep skipping). Alternatively, checkpoint `lastFeeAccrual`/HWM at queue time and charge new rates only from the execution timestamp.

### M-03 (Medium): Timelocked changes never expire

**Description.** `queuedEta` (980), `PendingConfig` (159-178) and `assetAllowEta` (195-208) have no grace period. A loosening queued at launch, such as 50x leverage, 100% daily loss, 5%/30% fees or a new thin market, can be applied years later in one transaction. Nothing in between alerts the depositors who joined under the tight config.

**PoC.** `test_AUDIT_M03_queuedChangesNeverExpire` (365 days later: fees, risk config and asset allow all apply).

**Fix.** Add `GRACE_PERIOD` (e.g. 7 days): `execute`/`apply*` revert if `block.timestamp > eta + GRACE`. Expose queued items through an enumerable view so the UI can flag them.

### M-04 (Medium): Contract-path trading is weaker than the policy says

**Description.**
- (a) `flatten(asset, slippageBps)` (800-810) lets the manager or guardian choose up to `MAX_FLATTEN_SLIPPAGE_BPS = 2000` regardless of `policy.maxSlippageBps` (100 in the default config). A 10 BTC long is sold IOC at 80,000 against a 100,000 mark, a price `policy.checkOrder` rejects.
- (b) `placeOrder` (775) checks only band, allowlist and per-order notional. Leverage and position size are only checked afterwards by `checkRisk`. The PoC places 10M of orders on 1k equity.

**Impact.** On an allowlisted thin market the manager can transfer up to 20% of the position notional per flatten to their own resting order, and repeat after `clearBreach` (H-01). The policy's onchain guarantee is weaker than documented. Mainnet allowlist is BTC/ETH (deep books), but the factory accepts any perp index from the creator.

**Fix.** Cap custom flatten slippage at `max(policy.maxSlippageBps, X)` with a guardian-only override when the guardian is platform-controlled. Add an onchain post-trade leverage projection in `placeOrder`: `(ntlPos + notional) / accountValue <= maxLeverage` for non-reduce-only orders.

### M-05 (Medium): Performance fee crystallises on transient highs

**Description.** `accrueFees()` (622) is permissionless and NAV is mark-to-market. Fee shares are minted at any instant where price > HWM, and the HWM ratchets.

**Impact.** A one-block 50% spike that reverts costs depositors 6.7% of the vault (66,666 USDC on 1M) with zero net gain. A manager who can move the mark of an allowlisted thin perp, or time accruals to volatility, harvests fees from noise.

**PoC.** `test_AUDIT_M05_perfFeeOnTransientSpike`.

**Fix.** Crystallise performance fees only at `settle()` (restrict the external `accrueFees` to management fee), and/or use a time-weighted or settle-to-settle NAV for the HWM comparison. Consider a minimum holding period before crystallisation.

### L-01 (Low): Notional cap measured at limit price
`checkOrder` (146-151) computes notional as `limitPx * sz`. A resting buy at 10% of mark carries 10x the cap (100 BTC passes a 1M cap). Per-order caps are also not cumulative (M-04b). **Fix:** compute notional at `max(limitPx, markPx1e8)`. PoC `test_AUDIT_L01_notionalCapUsesLimitPx`.

### L-02 (Low): Previews differ from settle
`preview*` (375-389) price at current NAV without pending fee accrual. After a year at 2% management fee, `previewDeposit(1M)` returns 1.0e18 while settle mints 1.0204e18 (fee dilution lowers the price, so more shares). Value is unchanged, but this breaks the stated "previews match the first settlement" and integrators. **Fix:** add a view that simulates `_accrueFees` (pure computation of fee shares) and use it in previews. PoC `test_AUDIT_L02_previewDiffersFromSettle`. The invariant suite confirms previews match exactly once fees are crystallised in the same block.

### L-03 (Low): Fee dilution counts as drawdown
`checkRisk` sets `peakSharePrice` from pre-fee price; fee minting lowers price. Anyone can call `checkRisk; accrueFees; checkRisk` and breach a vault with a tight drawdown limit after a large gain (500 bps limit, 50% gain, 20% perf fee). **Fix:** after `_accrueFees`, scale `peakSharePrice` down by the same dilution factor, or update the peak only post-fee. PoC `test_AUDIT_L03_*`.

### L-04 (Low): Views double count in the bridge window
`totalAssets()` (360-364) adds `pendingToCore` even when Core already shows it: 1.5M is reported for 1M. This affects previews, `convertTo*`, the `requestDeposit` cap check (486), and `clearBreach` baselines (924-925). Settle and accrue are guarded. **Fix:** the same snapshot approach as M-01. PoC `test_AUDIT_L04_*`.

### L-05 (Low): Negative perp equity ignored
`coreEquity` (437) drops a negative `accountValue` but still adds spot USDC: -100k perp + 300k spot reads 300k. That only happens after bankruptcy or ADL edge cases, but then redeemers are overpaid. **Fix:** compute `int256(spot) + accountValue`, floor at 0. PoC `test_AUDIT_L05_*`.

### L-06 (Low, conditional): Agent approved before the Core account exists
`initialize` sends `addApiWallet` (337) before `_seedCore` (340), whose deposit creates the account. The code's own comment says HYPE must land in an existing account. If HyperCore processes the block's actions in order and rejects actions from a non-existent user (unverified), hosted vaults created with an agent silently have none. Contract state says `agent != 0` and the executor's orders fail. **Fix:** move `_setAgent` after `_seedCore` and `_fundCoreGas`. Verify with one testnet launch that has an agent, using `{"type":"extraAgents","user":vault}`. PoC `test_AUDIT_L06_*` proves the ordering only.

### 3.4 Informational

| ID | Item |
|---|---|
| I-01 | `HyperVault.lowerProtocolShare` emits no event (factory does). Slither events-maths |
| I-02 | HyperVault has 171 B of EIP-170 headroom. Most fixes need bytes: plan to move views (previews, `claimable`, `pendingRequest`) to a lens contract |
| I-03 | `renounceOwnership` is inherited: a renounced vault can never `exitEmergency`/`clearBreach`/`leaveHosted`. Exits still work through overdue settle. Consider overriding to revert |
| I-04 | The first-epoch seed is shared pro rata by first-epoch depositors, so a 1-wei depositor captures ~50% of the 1 USDC seed. First-mint HWM/peak are set by whoever is first. Negligible value, documented as donation |
| I-05 | Rounding dust is never released: `claimableRedeemAssets` keeps per-user floor remainders and the vault keeps share dust from deposit floors. It only grows |
| I-06 | Factory accepts any creator-chosen guardian, owner, perp indices (no market existence check), and `hosted=true` without DojiPad agent involvement. The guardian is therefore not a depositor protection on factory vaults. The UI and server must not present `hosted`/guardian as trust signals unless platform-controlled |
| I-07 | Any holder of 1 share unit can `triggerEmergency` the moment an epoch is overdue by a second (by design, but harsh on honest managers) |
| I-08 | Agent revocation (`_revokeAgent`) is a fire-and-forget `addApiWallet(burn, sameName)`. Revocation relies on HL "same name replaces" semantics (documented) and on the action succeeding (e.g. Core gas availability). The contract cannot confirm it |

Checked and found sound (no finding): implementation `_disableInitializers`; clone + initialize atomic in `create`; salt scoped per creator, so no squatting; `predictVaultAddress` matches `cloneDeterministic`; permit front-run handled (try/catch, transferFrom is the real check); `msg.value` fully forwarded; `protocolShareBps` can only decrease (`lowerProtocolShare` strict `<`, `leaveHosted` min); the factory owner cannot redirect manager fees, raise shares, or brick vaults (recipient read is a plain storage view); `queue` selector whitelist blocks share transfers out of the vault; `rescueToken` excludes USDC and own shares; `execute` cannot run before eta; reduce-only enforced on contract orders during breach; CoreWriter encodings match the documented table (ids 1, 7, 9, 10, 11, 13; layouts and uint64 scaling); `limitPx`/`sz` 1e8 scaling and PxMath rounding (bounded and fuzzed); no unbounded loops in the vault; USDC has no hooks, all state-changing user paths are NR.

## 4. Design-level risks (not fixable by local code changes alone)

| ID | Risk | Mitigations |
|---|---|---|
| D-1 | **Agents are unbounded onchain.** An API wallet can trade any perp or spot market, at any size and price HL accepts, against a counterparty the manager controls. It can move collateral between dexes (C-01), and per the python SDK's `vault_usd_transfer` (unverified) possibly into HL vaults. "Agents cannot withdraw" is true, but trading against yourself is a withdrawal. Worst case per vault: ~100% of Core equity before anyone calls `checkRisk`, which is reactive and only bounds the next loss after an owner `clearBreach` (H-01). | Only platform-controlled agents (hosted) on factory vaults, or factory-owner whitelisting of agents; timelock `setAgent`; platform guardian on every factory vault with automated `checkRisk` every block; per-vault TVL caps until Core-side limits exist |
| D-2 | **NAV is mark-to-market** on whatever markets are allowlisted or traded by the agent. Thin-market marks can be pushed, and redeemers are paid mark value that may not be realisable | Restrict factory allowlists to a curated set of liquid perps; settle-time sanity bounds vs previous NAV; liquidity haircut on large positions |
| D-3 | **Creator picks every role.** Guardian, owner, manager and fee recipient may all be the same untrusted party, so guardian-based protections mean nothing on factory vaults | Factory-enforced platform guardian (non-removable by owner), or a second "depositor guardian" set by the factory |
| D-4 | **CoreWriter is fire and forget.** Revocations, flattens and bridges can silently fail; contract state (`agent == 0`, `pendingToEvm`) may not match Core | Off-chain watcher that verifies `extraAgents`, positions and balances after each action and alerts or retries |
| D-5 | **Executor holds the keys.** The server holds every hosted agent key; the onchain policy is enforced only offchain for agents (server S-04) | HSM/KMS per key, policy checks duplicated in a signing proxy, per-vault notional/velocity limits |

## 5. Invariant suite (Pass 2)

`contracts/test/audit/invariants/VaultHandler.sol` + `VaultInvariants.t.sol`. Target: a factory-created **hosted** vault with protocol share 33%, 5%/30% fees, 1-day timelock. The handler exposes 20 actions: deposit, redeem, cancel x2, claim, settle (weighted x2), accrueFees with time warp, bridgeToCore, bridgeToEvm (manager or stranger), moveUsd, PnL -60%..+60% with random exposure, zero Core, **precompile outage** (etches a reverting 0x80F), checkRisk, stranger flatten with random position, stranger triggerEmergency, owner ops (clearBreach, exitEmergency, setAgent, leaveHosted, factory lowerProtocolShare, pause toggle), queue (4 whitelisted + 1 forbidden selector), execute (early and late).

Result: **PASS, 512 runs x 200 depth = 102,400 calls, 0 reverts**, about 90 s.

| Invariant | Status |
|---|---|
| Reserved USDC (pending deposits + claimable redemptions) <= EVM balance | holds |
| Vault-held shares >= pending redeem + all unclaimed deposit shares; claimable USDC <= reserved | holds |
| Sum of all holders' share value <= NAV (no value from nothing) | holds |
| Share price at settle moves only within rounding (fees crystallised first in the same block) | holds |
| A depositor's settled shares x settle price <= assets deposited (rounding favours vault) | holds, except first-mint epochs, which receive the seed by design (I-04, excluded) |
| Fee value per accrual <= mgmt + perf cap at configured rates | holds |
| Protocol fee shares == floor(feeShares x locked bps / 10,000) | holds |
| `protocolShareBps` never increases; <= creation rate | holds |
| breached => agent == 0; emergency => breached; no deposit accepted while paused/breached/emergency | holds |
| Only whitelisted selectors can be queued; nothing executes before eta | holds |
| Previews == settle results (after same-block crystallisation) | holds (without crystallisation they differ: L-02) |
| Settle never succeeds inside a bridge window or during a precompile outage; redeem requests and cancels still work during an outage | holds |
| Stranger flatten / emergency powers only when allowed | holds |

The invariant suite cannot see the C/H/M findings by construction. They are economic or role-trust issues where every individual state transition is "valid", which is why each has a dedicated PoC. `afterInvariant` logs counters for the last run only.

### Coverage of areas 1-13

| Area | Covered by | Not covered / why |
|---|---|---|
| 1 Initialization | manual, existing tests, L-06 | - |
| 2 Share math | invariants (backing, value, rounding), manual offset/overflow review, I-04/I-05 | - |
| 3 NAV integrity | C-01, L-04, L-05, M-01, Pass 4 RPC, outage action | unified-account `accountValue` semantics unverified (A-11) |
| 4 Epoch lifecycle | invariants, H-02, H-01b | - |
| 5 Fees | invariants (cap, split), M-02, M-05, L-02, L-03 | - |
| 6 Risk/emergency | H-01, H-02, M-01, L-03, invariants | real HL fill behaviour of flatten IOC not simulated |
| 7 Policy | M-03, M-04, L-01, existing fuzz of PxMath, manual tighten/loosen per field (all six fields compare consistently) | - |
| 8 Access/timelock | invariants, M-03, H-01, surface.md | - |
| 9 Factory | manual + existing tests (permit, salt, seed, HYPE), I-06 | - |
| 10 Bridging/CoreWriter | encoding vs docs table, H-02, M-01, Pass 4 | Core->EVM `0x2000..00` destination for native USDC not verifiable without broadcast (A-07) |
| 11 Agent model | C-01, D-1 | worst case quantified analytically, not simulated on HL |
| 12 DoS/griefing | H-02, M-01b, L-03, I-07, loops reviewed | - |
| 13 Server | `server/test/audit` (18 tests), SERVER_FINDINGS.md | live database / HL not exercised |

## 6. HyperCore assumptions (Pass 4)

| # | Assumption in code | Status | How |
|---|---|---|---|
| A-01 | Precompile addresses 0x801/803/806/80a/80F/810/813 and ABI layouts (structs in HyperCore.sol) | **Verified** | `eth_call` against mainnet vault `0x542a...f258` and BTC: outputs decode to the library structs (perpAssetInfo BTC: szDecimals 5, maxLeverage 40) |
| A-02 | Spot USDC balance has 8 decimals (`/100`) | **Verified** | spot total 0x5f5e100 = 1.0 USDC, matching info API `spotClearinghouseState` |
| A-03 | Raw perp mark has (6 - szDecimals) decimals | **Verified** | BTC raw 853410 = 85,341.0; HL docs "divide by 10^(6 - szDecimals)" |
| A-04 | Precompile reverts on invalid input (code reverts NAV reads) | **Verified** | markPx(999999) -> `PrecompileError`; docs: "return an error and consume all gas" |
| A-05 | 1 USDC activation fee on the first deposit | **Verified** | 2 USDC seed -> 1.0 USDC spot on mainnet |
| A-06 | CoreWriter action ids and layouts (1, 7, 9, 10, 11, 13), version byte 1, 1e8 px/sz | **Verified (docs)** | HL "Interacting with HyperCore" action table matches HyperCore.sol exactly |
| A-07 | `sendAsset` to `0x2000...0000`, token 0, spot->spot bridges USDC to HyperEVM | Unverified | Needs a broadcast; only checkable on testnet. If wrong, `bridgeToEvm` burns or strands funds |
| A-08 | Order actions delayed "a few seconds"; other actions next L1 block | **Verified (docs)** | "order actions and vault transfers sent from CoreWriter are delayed onchain for a few seconds" |
| A-09 | Bridges settle within `BRIDGE_SETTLE_BLOCKS` = 10 EVM blocks | Unverified (plausible) | Mainnet seed visible on Core; no timing measurement without broadcast. If slower, NAV undercounts after the window (settle at a depressed price) |
| A-10 | `addApiWallet` with an existing name replaces that agent (revocation) | **Verified (docs)** | "...existing named API Wallet when an ApproveAgent action is sent with a matching name" |
| A-11 | `accountValue` (dex 0) excludes spot USDC (no double count with the spot term) | Verified for current mode only | `userAbstraction` = "default". CoreWriter action 16 "Set abstraction" exists; under a unified/portfolio mode the precompile may include spot, so NAV double counts. Who may set it (agent?) is unverified |
| A-12 | Agents cannot withdraw/transfer out of the account | **Verified (docs)**, with the C-01 caveat | usdSend/spotSend/withdraw3/sendAsset are user-signed; `agentSendAsset` exists but destination must equal source (moves between dexes) |
| A-13 | Actions from an address with no Core account fail | Unverified | Determines L-06 |
| A-14 | CoreWriter calls never revert on Core failure | **Verified (docs)** | Fire-and-forget design; contract code never assumes success |

## 7. Pre-launch checklist

1. **Do not open launch (`openLaunch`) to third parties** until C-01 and H-01 are fixed, or until agents on factory vaults are platform-only. Keep the launcher allowlist to vetted managers.
2. Per-vault `depositCap` on every factory vault; the factory should enforce a platform maximum.
3. A platform guardian on every vault that the owner cannot replace, and a keeper calling `checkRisk()` every block on **every** vault (the current keeper skips tenant vaults: server S-02).
4. Off-chain monitor for: `extraAgents` != the expected agent, non-USDC spot balances, balances on non-zero perp dexes, NAV moves > X% between blocks, `Queued` events (with M-03 there is no expiry), `BreachCleared`/`EmergencyExited`, and bridge calls with dust amounts.
5. Fix server S-01 (the global signal credential can trade tenant vaults) before any tenant is live.
6. Verify A-07 and A-13 on testnet with a launch that includes an agent, plus one `bridgeToEvm` round trip.
7. Bounty scope: all five contracts plus the executor's signal and launch endpoints. Highlight NAV-integrity and role-escalation classes; pay for HyperCore-behaviour findings with testnet reproduction.
8. Re-audit after fixes. The 171 B EIP-170 margin means the fixes will likely move code into a lens contract or a library; that restructuring needs its own review.
