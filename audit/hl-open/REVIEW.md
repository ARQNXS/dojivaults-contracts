# Hyperliquid contracts and executor: open launch and uncapped deposits (hl-open)

**This is an internal review. It is not an independent audit and must not be presented as one.**

Scope: the two 2026-10-13 changes (`0b6a0c0`, `6dfb9ae`): open launch (anyone may call `HyperVaultFactory.create`)
and no platform deposit cap (`maxDepositCap = type(uint256).max`). Code: `contracts/src` outside `gains/`, and the
executor paths in `server/src` that serve Hyperliquid vaults, at `origin/main` 726378d. Branch `audit/hl-open`. Nothing
deployed, no transaction sent, nothing pushed; `contracts/src` and `server/src` unchanged.

Evidence standard (as in `contracts/audit/gains/ROUND1.md`): a PoC test for each finding, numbers for design
findings, open questions otherwise. Severity on the HL scale (brief section 5): Critical (direct loss or permanent lock
of depositor funds), High (conditional loss, theft of yield or fees, temporary lock with no exit), Medium (bounded
loss, griefing that blocks core flows, broken invariant without direct loss), Low, Informational, Design.

Files: this report; [INVENTORY-DRAFT.md](INVENTORY-DRAFT.md) (every past item that relied on a closed launch or a
50k cap, 65 rows, with sources); [executor/RESULTS.md](executor/RESULTS.md) (executor sub-review and its PoCs);
contract PoCs in `contracts/test/audit/hl-open/` (`HloBase.t.sol`, `HloOpenLaunch.t.sol`, `HloScale.t.sol`).

## 0. Live configuration (read on chain 2026-10-19, read-only `eth_call`)

| | Round 4 factory [an earlier factory] | Round 3 factory [an earlier factory] |
|---|---|---|
| `openLaunch` | **true** | false |
| `maxDepositCap` | **2^256 − 1** | 2^256 − 1 |
| `minSeedUsdc` / `minHypeValue` | 2 USDC / 0.01 HYPE | 2 USDC / 0.01 HYPE |
| curated perps | 0 BTC, 1 ETH, 5 SOL | 0, 1, 5 |
| `vaultCount` | 1 | 2 |
| owner = guardian | `0x1A7acB79…D7ff`, **an EOA** (no code) | same |
| registrar | `0x67026561…d198` | same |

Context numbers used below (read 2026-10-19 01:49 UTC): Hyperliquid order book depth (`l2Book`, `nSigFigs` 3, both
sides, approximate) within 1% / 3% of mid: BTC ≈ $108–116M / ≥ $166M, ETH ≈ $44–48M / ≈ $93–100M, SOL ≈ $7–17M /
≈ $36M. USDC held by the CoreDepositWallet on HyperEVM: 640.1M USDC (total HyperEVM USDC supply 6.60B).

## 1. Executive summary

The contracts hold up under both changes as far as isolation and arithmetic go. A stranger's launch cannot touch
another vault, the factory's roles or the platform agent of anyone else (HLO-04, 7 negative tests). The share,
fee and claim math is exact from 10 USDC to the HyperCore representation limits: a 10 USDC depositor next to a
1e12 USDC whale loses nothing to rounding, and a 512-run fuzz up to 9e18 units (9 trillion USDC) moves the share price by
rounding only (HLO-05). No Critical or High.

What no longer holds is the set of arguments that relied on "only vetted managers launch" and "a vault is at most
50k":

1. **The earlier GO conditions for opening launch are not met.** VERIFY pass 4: "Fix V-02 and V-04 before
   `openLaunch`". V-04 / I3-04 (a registrar signature for a launcher-held agent) was mitigated only by the
   allowlist. With open launch, a leaked registrar key, which is an online key in the executor process, lets
   **any** wallet launch a vault whose "platform agent" it holds itself. The executor stores that vault silently as
   MANUAL (HLO-07 + HLO-E06). The PoC takes 10.5% of a 1M depositor's value in one settle at the default
   policy. REAUDIT2's other condition, a multisig factory owner before lifting the allowlist, is also unmet: the owner
   and guardian is an EOA on chain. That key can sign the same agent bindings.
2. **Spam is cheap and degrades the platform for real vaults.** A vault costs about 2 USDC + 0.01 HYPE + 1.18M gas
   (about $1.8 of which ~1 USDC is gone for good, HLO-01). The executor has no budget for Hyperliquid info weight. It
   uses up the 1,200/min limit at about 20–30 served vaults, and one 429 stalls the order path too (E02). Its HyperEVM
   bucket fills at about 1,000 MANUAL vaults (E03). Unreadable vaults cost one keeper transaction per hour each (E04),
   and alerts have no rate limit, so a BREACH alert is dropped after a flood (E05). At 1,000 vaults a real vault is
   looked at by the monitor once every 50 minutes (E08). The registrar's global 20 launches/hour can be used up for
   free by 7 throwaway wallets (E01).
3. **The factory enforces no policy envelope.** Any launcher may publish a vault with 50x leverage, the daily loss and
   drawdown breakers off (100%), 20% slippage, 30-day epochs and a 100% NAV move per settle. The last one turns off
   the C-01 checkpoint defence for that vault (HLO-03, PoC: a confederate's 50k becomes 100k). Names, symbols, owner
   and manager addresses and the `hosted` flag are free choices, so a vault can be launched under another manager's
   name and address without their consent, with the fees going to the launcher (HLO-02).
4. **The cap was itself a named mitigation.** D-1 ("per-vault TVL caps until Core-side limits exist"), D-5 / S-04
   ("per-vault notional limits") and REPORT section 7 item 2 ("the factory should enforce a platform maximum") all
   relied on it. Every residual that is bounded "per vault" in percent is now unbounded in USDC. Large exits also meet
   real book depth: SOL has about $36M within 3%, and the custom flatten slippage is capped at 3%. A large redemption
   blocks the whole epoch until it can be paid in full, and once the epoch is overdue anyone may stop the vault
   (HLO-06).

**Recommendation: set `openLaunch` back to false now**. It is one guardian transaction, it affects future launches
only, and the round 4 factory has one vault. Reopen it after the items in section 6.1. A per-wallet launch cap is
**not** a sufficient control: a sybil wallet costs about $1.8, and seven of them already exhaust the registrar budget.
Put a platform `maxDepositCap` back too (section 6.2). N-13 means lowering it later does not reach vaults launched
while it was lifted, so doing it while the round 4 factory has one vault is cheapest.

Counts (contracts + executor): **0 Critical, 0 High, 9 Medium, 6 Low, 6 Info (plus 2 checked-and-sound), 1 Design.** Contract PoCs 22/22 pass,
executor PoCs 27/27 pass (section 8).

## 2. Summary table

| ID | Title | Severity | Location | PoC |
|---|---|---|---|---|
| HLO-07 | I3-04 reopened: a leaked registrar (or owner) key lets any wallet launch with a self-held "platform" agent; the executor does not notice (with E06) | Medium | HyperVaultFactory.sol:232-244; server tenants/launch.ts:305-311 | `HloOpenLaunch.t.sol::test_HLO07_leakedRegistrarKeyGivesAnyLauncherASelfHeldAgent`; `executor/E06-unreserved-agent.test.ts` |
| HLO-01 | Launch spam: no per-wallet or global limit, ~$1.8 per vault; executor load grows linearly (E02, E03, E04, E08) and `vaults()` exceeds a 2M-gas call at 865 vaults | Medium | HyperVaultFactory.sol:180-182, 223-295 | `test_HLO01_oneWalletLaunchesManyVaults_costPerVault`, `test_HLO01_vaultsViewGasIsLinear` |
| HLO-E01 | Global registrar budget (20/h) exhausted for free; honest platform-agent launches get 429 | Medium | tenants/launch.ts:128,198,265-271 | `executor/E01-registrar-budget.test.ts` |
| HLO-E02 | No Hyperliquid info weight budget; limit reached at ~20–30 served vaults; one 429 stalls the order path | Medium | monitor.ts:148-210; main.ts:1131-1142; risk/watcher.ts; venues/hl/backoff.ts | `executor/E02-hl-weight.test.ts` |
| HLO-E03 | HyperEVM RPC bucket (8/s) full at ~1,000 MANUAL or ~120 served vaults; monitor reads fail, the sentinel stops acting | Medium | env.ts:50-51; chain/rpc.ts:28-33 | `executor/E03-rpc-bucket.test.ts` |
| HLO-E04 | Unreadable vault = one keeper checkRisk tx per hour, uncapped (~920 tx/h at 1,000 vaults) | Medium (conditional) | keeper.ts:90,250-252,385-432 | `executor/E04-keeper-unreadable.test.ts` |
| HLO-E05 | Alert floods with stranger-chosen text; no alert-channel rate limit or priority, BREACH dropped | Medium | alerts/<channel>.ts:29-49 | `executor/E05-alert-flood.test.ts` |
| HLO-E07 | 1 USD on another perp dex revokes any vault's agent (if a third party can credit it; pre-existing) | Medium (premise unconfirmed) | monitor.ts:205-208,323-331 | `executor/E07-other-dex-revoke.test.ts` |
| HLO-E08 | Real-vault detection latency grows with vault count: monitor 50 min, risk watcher 300 s at 1,000 | Medium (Design) | monitor.ts:146-152; risk/watcher.ts:366-367 | `executor/E08-coverage-dilution.test.ts` |
| HLO-03 | No factory policy envelope: 50x, breakers at 100%, 20% slippage, 30-day epochs, 100% NAV move (C-01 bound off) | Low | HyperVaultFactory.sol:245-248; VaultPolicy.sol:354-363 | `test_HLO03_*` (4) |
| HLO-02 | Impersonation: name, symbol, owner, manager and `hosted` are free; another wallet can be named owner and manager without consent | Low | HyperVaultFactory.sol:258-294 | `test_HLO02_*` (2) |
| HLO-06 | A large exit blocks the whole epoch (all or nothing), and anyone stops the vault once it is overdue; mark-valued exits versus real depth | Low (Design) | VaultLogic.sol:260-264; VaultGovernance.sol:244-254 | `HloScale.t.sol::test_HLO06_whaleExitBlocksTheEpochThenAnyoneStopsTheVault` |
| HLO-08 | Unmet deploy conditions: factory owner and guardian is an EOA (REAUDIT2 I2-06); V-04 not fixed (VERIFY pass 4) | Low (process) | on chain | section 0 |
| HLO-E06 | (Executor half of HLO-07) unreserved agent stored silently as MANUAL | Low | tenants/launch.ts:305-311 | `executor/E06-unreserved-agent.test.ts` |
| HLO-E10 | Platform HYPE per stranger vault (daily accrueFees, keeper-operator settles), no cap: ~0.25 HYPE/day at 1,000 | Low (Design) | feeAccruer.ts:53-79; treasury/operator.ts | `executor/E03-rpc-bucket.test.ts` |
| HLO-09 | I3-02 on HyperVault: the victim's cancel does not lift an insider's redeem block (the documented mitigation is wrong) | Info | VaultLogic.sol:86, 98-113 | `HloScale.t.sol::test_HLO_I302_cancelDoesNotLiftTheInsiderRedeemBlock` |
| HLO-10 | The registrar signature covers (agent, vault, deadline) only, not hosted, operator, policy or owner; one agent signed twice binds to the first launch | Info | HyperVaultFactory.sol:212-214 | `test_HLO04_signatureDoesNotCoverTheLaunchParameters`, `test_HLO04_oneAgentSignedTwiceFirstLaunchWins` |
| HLO-11 | Lifting the platform cap cannot be recalled for vaults launched meanwhile (N-13); `maxDepositCap = 0` freezes every owner's setter | Info | VaultGovernance.sol:311-315 | `test_HLO_N13_*`, `test_HLO_maxDepositCapZeroFreezesEveryOwnersCapSetter` |
| HLO-12 | HyperCore representation limits: largest bridgeToEvm 184,467,440,737 USDC per call, NAV readers int64 (9.22e12 USDC) | Info | VaultLogic.sol:446-448; HyperCore.sol:94-99 | `test_HLO05_hyperCoreRepresentationLimits` |
| HLO-13 | The protocol treasury receives fee shares of every stranger vault | Info | VaultLogic.sol:354-360 | `test_HLO04_treasuryReceivesSharesOfStrangerVaults` |
| HLO-E09 | Executor number precision at 1e9–1e12 USDC: fine | Info | risk/contractRisk.ts:296-299 | `executor/E09-precision.test.ts` |
| HLO-05 | Contract math at scale (precision, fees, overflow, claims): sound | Info (checked) | VaultMath.sol, VaultLogic.sol | `test_HLO05_trillionUsdcWhaleAndTenUsdcDepositor`, `testFuzz_HLO05_settleIsPriceNeutralAtAnySize` (512 runs) |
| HLO-04 | Cross-vault isolation: a launch reaches no other vault, factory role or agent | Info (checked) | HyperVaultFactory.sol | `test_HLO04_*` (5) |
| D-1/D-5 | The TVL cap was a named mitigation of D-1 and S-04; the blast radius of an agent or executor compromise is now the sum of all NAV | Design | REPORT.md section 4 | section 3, C-01, C-05 |

## 3. Verdict per past assumption

Every row of [INVENTORY-DRAFT.md](INVENTORY-DRAFT.md) (sources and quotes there). Verdicts: **holds**, **holds
(scaled)** = the bound is still true in percent of NAV but not in USDC, **weakened**, **no longer holds**, **open**.

### 3.1 Findings and accepted risks

| Item | Verdict | Evidence |
|---|---|---|
| C-01 agent NAV deflation | **holds** while every agent is platform-held; **no longer holds** after a registrar or owner key leak (no allowlist to stop the attacker launching) | HLO-07 PoC: 1M confederate deposit at an 81% NAV, worth 1.105M after the restore |
| H-01 owner instant disarm | holds | queue whitelist unchanged; untrusted owner was already assumed |
| H-02 / X-01 bridge window re-arm | holds for strangers (Verify4PoC). A malicious **manager** can still bridge MIN_BRIDGE home each window in an emergency; the platform settler wins with a priority fee, as accepted for X-01 | not re-tested by PoC; open question 4 |
| M-04 / N2-03 flatten slippage (manager ≤ 3%) | **weakened**: a colluding order only fills after the book within 3% is used up. That needs positions above about $36M notional on SOL ($93M ETH, $166M BTC), which the old cap ruled out and the lifted cap allows | section 0 depth numbers |
| N-09 insider rule bypassed by a sybil | holds as accepted, **scaled**: every launcher is now a potential insider with a sybil | `test_HLO_N09_confederatePricedNowManagerSettlesAtWill` |
| R3-02 back-to-back settles residual | **weakened**: the argument "the NAV is not moved by the manager" no longer holds for own-signal and copy vaults, where any launcher steers the platform agent's orders, bounded per order by the executor guard. Not re-reviewed here | open question 2 |
| I3-02 controller griefing, "cancellable" | the mitigation text is **wrong** on HyperVault; impact still Info (the delay lasts until the next settle) | HLO-09 |
| I3-07 stranger arms the insider delay | holds (10 USDC per arm, 1 h bound) | unchanged code |
| I3-04 / V-04 registrar self-held agent | **no longer holds** | HLO-07, E06 |
| R-1 / I3-01 compromised agent residual | holds in percent; the "needs the owner too" leg is free under open launch: the attacker launches and owns the vault | HLO-07 |
| N2-02 / R3-06 performance fee raise | holds (structural) | existing regressions pass |
| N2-04 replay; per-owner cap; EOA-only launch | replay fix holds; the per-owner cap is sybil-bypassable (E01); EOA-only launch (no ERC-1271), accepted "for the allowlisted phase", now applies to everyone (Info) | E01 |
| N-07 / GOV-02 agents per existing vault | unchanged (registrar or owner only); not re-tested | open |
| I-06 / D-3 creator picks roles | **partially no longer holds**: the "platform max cap" leg is gone; `hosted`, operator, owner and manager are anyone's choice | HLO-02 |
| N-13 cap changes do not propagate | holds in code; consequence: the lift is irreversible for vaults launched meanwhile | HLO-11 |
| I3-05 cap unbounded, script refuses > 50k | **no longer holds** by decision; KNOWN-ISSUES, SCOPE.md and `Deploy.s.sol:95` are stale | inventory A-16 |
| R3-01 landing latched by PnL | holds (scaled) | unchanged code |
| R3-05 / R3-08 unlanded bridge masks a loss (60 / 300 blocks) | holds (scaled). Each new bridge re-snapshots the true equity (`_openWindow`), so a chain of failed bridges masks only the losses inside one window, ≤ 300 blocks | VaultLogic.sol:455-463, VaultGovernance.sol:173-176 |
| N-01b min(snapshot, live + amount) | holds (scaled) | unchanged |
| REAUDIT3 question (a) live NAV in normal settle | **weakened**: the bound is the owner's `maxNavMoveBps`, which can be raised instantly to 100% (raising counts as tightening, N-03) | HLO-03 |
| W-01 / W-01b emergency exit | holds (guardian only) | existing regressions |
| VERIFY pass 4 guardian gate | holds; operational load grows with vault count | n/a |
| V5 syncAgent HYPE (conditional) | unchanged per vault; detection by the monitor is diluted (E08) | E08 |
| I3-08 no performance fee in a breach | holds | unchanged |
| I2-01 sentinel re-breach | holds | unchanged |
| Rounding at small scale (B1, N2 "dust only") | **holds at any size** | HLO-05: 512-run fuzz up to 9e18 units, ≤ 2 units + 1e-9 relative |
| Absolute constants (MIN_BRIDGE, 1 USDC tolerance, MIN_RISK_NAV, MIN_DEPOSIT) | holds | relatively tighter as NAV grows |
| HyperCore A-07 / A-09 / A-11, landing time at size | **open**: never observed above seed size | open question 1 |

### 3.2 GO, readiness and deploy conditions

| Item | Verdict |
|---|---|
| REPORT section 7 item 1 ("do not open launch until C-01 and H-01 are fixed, or agents are platform-only; keep the allowlist to vetted managers") | technical leg met; the vetted-manager leg is dropped. Holds only as long as the registrar and owner keys hold (HLO-07) |
| REPORT section 7 item 2 (platform maximum cap) | **no longer holds** |
| REPORT section 7 item 3 (platform guardian; keeper checkRisk on every vault) | guardian leg holds; keeper coverage diluted (E08) |
| REPORT section 7 items 4–6 (monitor; A-07 on testnet) | monitor coverage diluted (E08); A-07 at size open |
| REAUDIT2 section 10 readiness ("capped deploy, allowlisted launchers"; items 3–6 before lifting the allowlist) | **no longer holds**: item 6 (multisig owner) not met, owner is an EOA (HLO-08) |
| REAUDIT2 I2-06 (multisig before lifting the allowlist) | **not met** |
| VERIFY passes 1–5 GO conditions (`openLaunch = false`, cap ≤ 50k; "fix V-02 and V-04 before openLaunch") | **not met**: V-02 fixed, V-04 not |
| REAUDIT3 section 1 item 10, section 7 readiness | **no longer holds** as written |
| REAUDIT3 section 8 (executor behaviour assumed) | the executor now carries more of the protection against untrusted managers. This review covers its scaling and registrar paths, not the order guard (open question 2) |
| VERIFY-ROUND3 (round 4 fork rehearsal, check 0 asserts closed launch and 50k) | **not re-run** under the live configuration |
| Audit pack, README, KNOWN-ISSUES statements | stale (inventory B-16..B-18) |
| HL-RETEST B-19 (maxDepositCap 0 freeze) | applies to HyperVault (HLO-11) |

### 3.3 Design risks

| Item | Verdict |
|---|---|
| D-1 agents unbounded on chain | **no longer "mitigated"**: one of its four listed mitigations was the per-vault TVL cap |
| D-2 NAV is mark-to-market | **weakened**: no liquidity haircut exists, positions can now exceed the curated books' 3% depth (HLO-06) |
| D-3 creator picks every role | guardian and sentinel leg holds; the rest is now any wallet's choice (HLO-02, HLO-03) |
| D-4 CoreWriter fire-and-forget, watcher | depends on monitor coverage (E08, E03) |
| D-5 / S-04 executor holds the keys | severity argument scales with total TVL; with no per-vault notional or velocity limit, re-rate it High (design) once outside TVL is material |
| REAUDIT online-key analysis ("a compromise is a denial of service, never a loss of custody") | **no longer holds** for the registrar (HLO-07) |
| KNOWN-ISSUES trust assumptions (after-the-fact bound) | holds (scaled) |

### 3.4 Executor items

| Item | Verdict |
|---|---|
| S-04 | see D-5 |
| SN-03 keeper and monitor bounded against attacker vaults | **no longer holds as bounded**: E02, E03, E08 |
| SN-05 / S-08 reservations, registrar budget | custody holds; availability **no longer holds** (E01) |
| S-03 / SN-06 reservation front-run | holds: the binding is scoped to `predictVaultAddress(msg.sender, salt)` (HLO-04) |
| V-02 nonce store | holds |
| S-02 keeper checkRisk coverage | holds per vault; latency grows (E08) |
| SN-01 monitor ACT rules | holds; see E07 (conditional, pre-existing) |
| A-13 agent sync from the keeper | holds; cost scales (E10) |
| S-01 / own-signal and copy modes | **open**: the executor guard is the only per-order bound on what an untrusted launcher can make the platform agent do |
| OPS-1 operator runner | holds; cost E10 |
| Executor unreviewed after 2026-10-09 | partially covered here (scaling, registrar, alerts), not the order path |

## 4. Contract findings

### HLO-07 (Medium): I3-04 reopened, a leaked registrar or owner key gives any wallet a self-held agent

`create` accepts an agent when `agentRegistrar` or `owner()` signed `(agent, predictVaultAddress(msg.sender, salt),
deadline)` (HyperVaultFactory.sol:232-244). The registrar is an online key in the executor process (S-04); the owner is a
cold EOA (section 0). With the allowlist, a leaked key was usable only by an allowlisted launcher (I3-04, "mitigated
by the launcher allowlist"). Now anyone can use it: the attacker signs a binding for a key they hold and launches. On
chain the agent is indistinguishable from a platform agent (`isPlatformAgent` true). The executor stores the vault as
MANUAL without an alert (E06). An HL API wallet trades the account unchecked by the contract (D-1). It can send perp
USDC to another dex (`agentSendAsset`, C-01), outside `coreEquity()`'s view, while a confederate's deposit is settled
by the attacker as manager. The default `maxNavMoveBps` (20%) bounds one round, but not the number of rounds.

PoC `test_HLO07_leakedRegistrarKeyGivesAnyLauncherASelfHeldAgent`: Alice 1M, NAV hidden down to 81%, confederate 1M
settled in the next block. After the restore the confederate holds **1,104,972 USDC** and Alice **895,026**: 10.5% of
Alice's value in one round. With the hostile policy of HLO-03 the per-round bound is 100%.

Impact × likelihood: up to all depositor funds of the attacker's vault (deposits need a direct link, Explore is
curated) × an online-key compromise. The prior GO said to fix V-04 before opening launch. Mitigation: the creator co-signs
the binding and the executor signs only for agents it reserved; alert on `PlatformAgentRegistered` /
`VaultCreated.agent` not in the reservation store (E06); move the factory owner to the Safe.

### HLO-01 (Medium): launch spam is cheap; its cost lands on the executor

One wallet launched 50 vaults back to back. Per vault: **2 USDC** seed (1 USDC kept by Core as the activation fee,
the rest belongs to the vault's future depositors), **0.01 HYPE** forwarded to Core, **1,176,159 gas** (about 59% of a
2M small block). No per-wallet, per-block or global limit exists on chain. `vaults()` copies the array: **2,310 gas
per vault** cold. It passes 2M gas at **865 vaults** and 30M gas at **12,987**: a consumer that uses `vaults()`
through an `eth_call` capped near the block limit breaks there. The contract-side harm stops there. The platform-side
harm is in the executor: E02 (info weight), E03 (RPC bucket), E04 (keeper transactions while unreadable), E05
(alerts), E08 (latency), E10 (HYPE). At 1,000 MANUAL vaults the executor spends about 990 of 1,200 info weight per
minute and the whole 480/min RPC bucket before serving any real vault (executor/RESULTS.md). That is about $1,800 for
the attacker.

Mitigation: close launch, or tier service: full-rate work only for vaults with outside deposits above a threshold,
and a bounded best-effort rotation for the rest (E08). Use `vaultCount` + paginated reads instead of `vaults()`.
A higher `minSeedUsdc` raises the cost, but the seed is not refundable to the launcher.

### HLO-03 (Low): no factory policy envelope

The factory checks only the assets and the cap (HyperVaultFactory.sol:245-248). `VaultPolicy._validate` allows
`maxLeverageBps` ≤ 50x, daily loss and drawdown up to 100%, slippage up to 20%, epochs up to 30 days, NAV move up to
100%. Raising `maxNavMoveBps` is instant (it counts as tightening, N-03). PoCs:
- `test_HLO03_hostilePolicyIsAcceptedAndDisablesTheBreakers`: a 95% loss at 49x does not breach.
- `test_HLO03_maxNavMove100pctLetsANormalSettlePriceAHalvedNav`: the keeper's normal settle mints a confederate's
  50,000 USDC at a halved NAV, worth **99,999.5 USDC** after the restore. `test_HLO03_sameMoveRevertsUnderTheDefaultPolicy`
  shows the default policy refusing it.
- `test_HLO03_redemptionsWaitUpTo30DaysBeforeAnyoneCanForceAnExit`.

Under the allowlist the platform saw every policy. The webapp shows the policy, and Explore is curated, so the reach
is direct links only: Low. It multiplies HLO-07. Mitigation: a factory envelope checked at `create` and on
`proposeConfig` (e.g. leverage ≤ the curated perps' HL maximum and ≤ 10x, daily loss ≤ 20%, drawdown ≤ 50%,
`maxNavMoveBps` ≤ 2,000 with raising timelocked, epoch ≤ 7 days), or a "within platform limits" flag the UI
shows.

### HLO-02 (Low): impersonation

`name`, `symbol`, `owner`, `manager`, `feeRecipient` and `hosted` are free. PoC
`test_HLO02_strangerClonesNameAndNamesAnotherWalletAsOwnerAndManager`: Mallory launches "Famous BTC Trend / fBTC"
with the famous manager's wallet as owner **and** manager (no consent), fees to herself, `hosted = true`. The indexed
`owner` topic of `VaultCreated` is the famous wallet. After a year on a 100k deposit Mallory's fee shares are worth
3,350 USDC. `test_HLO02_platformAddressesCanBeNamedInAStrangersVault`: owner = sentinel, manager = keeper, fee
recipient = treasury are all accepted. Profiles are per vault and owner-signed (`profiles/service.ts`), and Explore is
curated, so the vault page on the DojiPad domain is reached by direct link. On-chain `hosted` only raises the
protocol share; the public vault page does not render it, only the manage view and dashboard do. Mitigation:
`owner == msg.sender` (or an owner signature) at `create`; never attribute a vault to `owner`/`manager` addresses in
UI or indexer without their consent; derive `hosted` from the executor's tenant, not the chain flag.

### HLO-06 (Low, Design): large exits

A normal settle pays every redemption in full or reverts with `InsufficientLiquidity` (VaultLogic.sol:263-264), for
every request of the epoch at once. PoC `test_HLO06_whaleExitBlocksTheEpochThenAnyoneStopsTheVault`: Alice 1M, a
99M whale, 95% deployed (2.5x). The whale's full redemption blocks Bob's deposit and every other request. When the
epoch is overdue (default 7 days, 1 hour allowed), a stranger triggers the emergency (I-07), the agent is revoked and
the settle fills the whale pro rata to the 5M on hand (**505 bps**). Bob is refunded. Unwinding is bounded by real
depth: 237.5M notional of SOL is about 6.6x the ~$36M within 3%, and `flatten` takes one IOC per call within ≤ 3%.
The unwind cost lands on everyone pro rata before the settle prices, so the stayers bear (1 − f) of the cost of
unwinding the exiting fraction f. Relative loss for stayers ≈ f × leverage × average slippage, e.g. 0.5 × 2.5 × 1.5%
≈ 1.9%. At 50k this was nil. Mitigation: a platform cap tied to depth (section 6.2), a liquidity haircut or exit fee
on large redemptions (D-2), and the keeper settling partial liquidity in steps rather than waiting for full cover.

### HLO-08 (Low, process): unmet deploy conditions

The round 4 factory owner and guardian `0x1A7acB79…D7ff` has no code (an EOA). REAUDIT2 section 4: "a multisig owner
before lifting the launcher allowlist (I2-06)". The owner key can sign agent bindings (`signer == owner()`) and
rotate the registrar, so its leak is HLO-07 for every launcher. `docs/runbooks/guardian-to-safe.md` is prepared but
not executed.

### Info items

- **HLO-09** I3-02 on HyperVault. An insider deposit made for a victim's controller blocks the victim's
  `requestRedeem` (`RequestPending`). The victim's `cancelDepositRequest` refunds the 10 USDC but keeps
  `r.epoch = current + 1`, so the block stays until the next settle. KNOWN-ISSUES calls it "cancellable"; it is not.
  Every launcher is such an insider. Fix as GR1-32 on Gains (reset `r.epoch` on cancel).
- **HLO-10** The registrar signature covers neither `hosted`, `operator`, policy nor owner. A launcher who obtained a
  signature for one configuration may launch any other. If the executor signs the same agent for two predicted vaults,
  the first launch binds it and the other reverts. The executor must read the launch result from chain, not from the
  reservation.
- **HLO-11** N-13: vaults launched while the cap is lifted keep `depositCap = max` after `setMaxDepositCap` is lowered
  (deposits continue). `setMaxDepositCap(0)` makes every owner's `setDepositCap` revert (as HL-RETEST B-19).
- **HLO-12** Size ceilings: `bridgeToEvm` reverts above 184,467,440,737 USDC per call (uint64 of amount × 100); the
  NAV reads `int64 accountValue` (9.22e12 USDC) and `uint64` spot (1.84e11 USDC); `size1e8` caps a flatten at
  1.84e11 coins at szDecimals 0. None is reachable at today's sizes; at a cap above 1.8e11 USDC the treasury must split
  bridges.
- **HLO-13** The protocol treasury accrues fee shares of every stranger vault (and is not an insider of them).
- **HLO-05** (checked) `test_HLO05_trillionUsdcWhaleAndTenUsdcDepositor`: 10 USDC next to 1e12 USDC is worth exactly
  10.000000 USDC after the settle. A year at 5% + 30% charges 85,005,980,283.70 USDC of fees on a 1.1e12 NAV, within
  0.01% of 5% of NAV plus 30% of the gain. The full exit pays the claims within the reserve. Fuzz
  `testFuzz_HLO05_settleIsPriceNeutralAtAnySize` (512 runs, NAV 10 USDC .. 9e12 USDC, deposit 10 .. 1e9 USDC, PnL −4%
  .. +15%, redemption 0–100%): the share price moves ≤ 2 units + 1e-9 relative, and a small depositor loses ≤ 2 units
  + 1e-9.
- **HLO-04** (checked) A signature copied from the mempool fails for any other creator. Salts are scoped per creator.
  A stranger cannot call `registerPlatformAgent`, `unregisterPlatformAgent`, `lowerProtocolShare`, or another vault's
  `settle`, `revokeAgent` or `triggerBreach`. Their own owner powers do not reach `exitEmergency`, and their vault
  still reads the factory's guardian and sentinel.

## 5. Executor findings

Full detail, numbers and file:line in [executor/RESULTS.md](executor/RESULTS.md). Every PoC runs the real
`server/src` against fakes (no network). Summary of the per-loop scaling (HL = info weight per minute, budget 1,200;
RPC = HyperEVM calls per minute, budget 480; S = served vault, M = MANUAL):

| Loop | 10 | 100 | 1,000 |
|---|---|---|---|
| Monitor (20 vaults/min) | HL 460–620 | HL 920–1,240 | HL 920–1,240, each vault every 50 min |
| Health (30 s, S only) | HL 400 | HL 4,000 | HL 40,000 |
| Risk watcher (S, 15 s) | HL 160, round 2.7 s | HL ~800, round 29.7 s | HL ~800, round 299.7 s |
| Keeper (5 min) | S: 8 HL, 6 RPC | S: 80 HL, 60 RPC | S: 800 HL, 600 RPC; M: 67 HL, 50 RPC |
| Keeper while unreadable | 10 tx/h | 56–100 tx/h | ~920–1,000 tx/h |
| Fee accruer (all tenants) | 10 tx/day | 100 tx/day | 1,000 tx/day |
| Copy mirror (per copy vault) | HL 240 | HL 2,400 | HL 24,000 |

Totals: 1,000 MANUAL vaults ≈ 990 HL/min and ≈ 480 RPC/min; 100 served ≈ 5,900 HL/min (5x the budget) and ≈ 400
RPC/min. Loops catch errors per vault (one throwing vault does not block the others) and skip overlapping ticks,
except health. A settle that would revert fails in simulation (no gas) but is retried every 5 minutes without backoff.

## 6. Recommended mitigations

### 6.1 Before reopening launch (in order)

1. `setOpenLaunch(false)` now (guardian, one transaction; existing vaults unaffected).
2. HLO-07 / E06: creator co-signature of the agent binding, or a registrar that signs only agents it reserved, plus an
   alert for any `VaultCreated.agent` / `PlatformAgentRegistered` not in the reservation store. Move the factory owner
   to the Safe (HLO-08).
3. Executor budgets: one client-side HL info weight budget with priorities (orders > risk on vaults with outside
   deposits > monitor > health), health off the per-vault hot path (E02). Full-rate service only for vaults with
   outside deposits above a threshold, a bounded rotation for the rest (E03, E08). Cap unreadable keeper sends per hour
   and skip vaults with nothing to protect (E04). An alert queue with rate limit, priority and retry on 429, and no
   vault-chosen text in platform alerts (E05). Per-wallet and per-IP registrar budgets in the database instead of one global
   in-memory budget (E01).
4. Factory policy envelope at `create` and in `proposeConfig`, at least `maxNavMoveBps` bounded and raised only by
   timelock (HLO-03).
5. `owner == msg.sender` or an owner signature at `create`; UI attribution only with consent (HLO-02).

On a per-wallet launch cap: on chain it is sybil-bypassable for about $1.8 per wallet, so it does not address HLO-01
or E01. As a soft executor rule (serve at most k vaults per verified wallet at full rate) it is useful together with
item 3.

### 6.2 Deposit caps

Put a platform maximum back until D-1 and D-5 have per-vault notional and velocity limits in the executor. A
reasonable bound ties the largest notional a vault can carry (NAV × policy leverage) to a fraction of the thinnest
curated book within 3%. With SOL at about $36M and 3x, a NAV of about $4M keeps one vault's full unwind within a third
of that depth. Lower it while the round 4 factory has one vault (N-13: later lowering does not reach existing vaults).
If caps stay lifted: a liquidity haircut or an exit fee for redemptions above a share of depth (D-2, HLO-06). Measure
bridge landing times at size on mainnet with own funds before any vault crosses about $1M (open question 1).

### 6.3 Docs

KNOWN-ISSUES (I3-02 "cancellable", I3-04 "mitigated", I3-05 "script refuses > 50k"), SCOPE.md, README lines 13, 97,
186, 532, 566, `Deploy.s.sol:95` and REVIEW-SUMMARY section 6 need the live configuration. The site's security
sentence should not imply that the reviews covered open launch or uncapped deposits before this review's items are
closed.

## 7. Open questions

1. HyperCore at size: landing time and any per-transaction or rate limit for EVM→Core deposits and Core→EVM
   `sendAsset` of $1M–$100M. The CoreDepositWallet holds 640M USDC on HyperEVM. Is that the liquidity for Core→EVM
   USDC? A landing beyond 300 blocks reads as a loss (R3-08).
2. The executor order guard (`tenants/guard.ts`, own-signal / copy / TradingView sizing) under an untrusted launcher.
   What is the total, not per-order, bound on what a launcher can make the platform agent do? (R3-02, S-01, D-1.)
3. Can a third party credit another account's HIP-3 dex balance? (E07.)
4. A malicious manager racing the emergency settle with MIN_BRIDGE bridges every window (X-01 variant). Is the
   platform settler's priority fee configured on HyperEVM?
5. Does any consumer (webapp, indexer, scripts) call `factory.vaults()` through an RPC whose `eth_call` gas cap is
   near 2M? HyperEVM's RPC cap was not measured here.
6. The round 3 factory's two vaults and its `maxDepositCap = max`: do their owners know they can raise their caps
   without bound?
7. Re-run the round 4 fork rehearsal (`server/scripts/rehearse-round4.ts`) under `openLaunch = true` and uncapped
   values.

## 8. How to reproduce

```
cd contracts
forge test --match-path "test/audit/hl-open/*.t.sol" -vv          # 22 tests, all pass
cd ../server && npm ci
npx vitest run --config ../contracts/audit/hl-open/executor/vitest.config.mjs   # 9 files, 27 tests, all pass
```

Regression of the earlier suites on this branch: `forge test --no-match-path "*gains*"` ran 35 suites, 269 passed, 0 failed,
2 skipped (271 tests, 768 s), including every earlier HL PoC, regression and invariant suite and the 22 hl-open tests.

The on-chain values in section 0 are `cast call` reads against `https://rpc.hyperliquid.xyz/evm`; the book depth is
the public `info` endpoint (`l2Book`, `nSigFigs` 3). Both are snapshots of 2026-10-19 01:49 UTC.
