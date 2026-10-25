# hl-r2 §3.4 — Stolen-key worst case (KEYS.md)

**Internal, AI-assisted review. Not an independent audit.** Branch `audit/hl-r2-keys`. Source unchanged
(`contracts/src`, `server/src`). Evidence: `keys/evidence/` (HL docs `.md` snapshots, live book depth
`books/books.json` read 2026-10-19 20:32 UTC, SDK under `../evidence/hl-sdk`, mainnet probes under
`../evidence/mainnet-probes`). PoCs: `contracts/test/audit/hl-r2/keys/KeysPoC.t.sol` (7 pass).

## Assumptions (most conservative reading)

- **KA1.** platform-vault-class policy for the numbers: 5x / daily 20% / drawdown 50% / slippage 1% / maxOrderNotional 2.5M
  / epoch 7 d / **maxNavMoveBps 20%** / flatten 3% / timelock 2 d. Live factory: `openLaunch = true`,
  `maxDepositCap = 2^256−1`. The platform vault's own `depositCap` is 250k, so a thief of the platform vault is capped at 250k TVL; the 1M
  column is a hypothetical larger vault at the same policy.
- **KA2.** "One key stolen" = only that key; every other actor (keeper, sentinel, guardian, registrar) is honest and
  on schedule. The monitor runs with `MONITOR_INTERVAL_MS = 60 s`, `maxPerRun = 20`; a served vault is looked at
  roughly once per run; the risk watcher runs every `RISK_WATCH_MS = 15 s`.
- **KA3 (= CONTEXT A3).** HL behaviour not in its docs/SDK is rated on the worse reading, flagged. The agent is
  **not bound by the contract** for anything off-chain: the curated list, `maxLeverageBps`, `maxOrderNotional` and
  `maxSlippageBps` bound **only the manager's on-chain `placeOrder`** (proof: `VaultLogic.placeOrder` is the only
  caller of `policy.checkOrder`, and it is `msg.sender != $.manager → revert`; the agent signs off-chain and touches
  no contract function). The agent can trade any perp, any spot, any size/price HL accepts, move collateral between
  dexes, into HL vaults, into subaccounts, and change the account abstraction mode.

---

## (a) Live Critical/High exploitable TODAY without a key theft

**None found that is new.** Exposure today is ~172 USDC total across the three live vaults (the platform vault 170.76, x402
Test 1.0, Copy HL Test 0.0024, the last already breached+emergency with the agent revoked). The live-today risks are
the **already-accepted** `openLaunch = true` + leaked-registrar path (I3-04 / HLO-07, Medium, open) and the agent
trust boundary (D-1). This review did not find a no-key-theft Critical/High on a live vault. The items below are
stolen-key or conditional, and one (HLR2-K10/K11) is a bound that earlier rounds believed held and does not on the
worse reading — see §(e).

---

## (b) Findings

| ID | Title | Severity | Location | PoC |
|---|---|---|---|---|
| HLR2-K03 | Agent deflates NAV, a **non-insider** sybil deposit is priced at the deflated NAV by the **honest operator's** scheduled settle; insider-deferral never engages | High (new framing of C-01: the settler is not an insider) | `VaultLogic.settle` 205-257; `_isInsider` 168-170 | `test_HLR2_K03_*` (10k/100k/1M) |
| HLR2-K11 | A stolen agent can make itself **un-revocable for up to ~24 h**: switch to unified/portfolio margin (the vault has no path to switch back), then burn the documented **50k user-actions/day** quota (reach it via `reserveRequestWeight`, ~25 USDC) so every later user action from the Core account — including the guardian/sentinel `revokeAgent` — is rejected until 00:00 UTC | High (conditional; depends on whether the revoke CoreWriter action counts against the account quota — undocumented, rated on worse reading per KA3) | off-chain (HL); contract can't emit action 16 (`HyperCore.sol` has no `setAbstraction`); revoke = action 9 from the vault account | code cite + K10 (mode-stuck half) |
| HLR2-K10 | Revoke leaves the abstraction mode wrong forever; a replacement agent needs the 2-day owner timelock; `coreEquity()` keeps mis-reading | Medium (recovery gap) | `HyperVault.setAgent` onlySelf 523; `revokeAgent` 535; `coreEquity` under PM (probes) | `test_HLR2_K10_*` |
| HLR2-K12 | Portfolio-margin NAV deflation is **not an ACT finding**: the monitor only auto-revokes on FOREIGN_AGENT / OTHER_DEX(from own) / EXPOSURE_UP_IN_BREACH; a mode switch shows as NAV_MOVE = **alert only** (+checkRisk), so the C-01 deflation path that evades the sentinel's revoke is the abstraction one, not `agentSendAsset` | Medium | `monitor.ts:205-331` (OTHER_DEX reads dex balances, not mode); `coreEquity` 119-124 | code cite + probes |
| HLR2-K04 | Stolen sentinel (hot) = full-stop DoS on **every** factory vault; owner cannot clear instantly (only cold guardian) | Design (accepted role power, DoS not theft) | `VaultGovernance.triggerBreach` 227; `clearBreach` 259 | `test_HLR2_K04_*` |
| HLR2-K06 | Stolen factory owner rotates guardian/sentinel/registrar for all vaults live, and can sign agent bindings (HLO-07 self-agent theft on a new vault) | Design/High (= HLO-07) | `HyperVaultFactory.setSentinel/setGuardian/setAgentRegistrar` 374-396; `create` signer==owner 240 | `test_HLR2_K06_*` + HLO-07 |
| HLR2-K07 | Stolen guardian's only value-destroying power is a custom-slippage emergency flatten, bounded at ≤3% of position notional/flatten | Design (bounded) | `VaultLogic.flatten` 562-580; `VaultPolicy.flattenOrder` 202-213 | `test_HLR2_K07_*` |

HLR2-K03 is **High** (not merely Design): REPORT C-01 and HLO-07 both have the **manager** (an insider) run the
settle. Here the settle is run by the **operator/keeper** — explicitly listed in the brief as "not an insider". The
sybil depositor is not an insider either, so neither the `deferredDepositAssets` deferral nor `INSIDER_MIN_EPOCH_AGE`
engages; the honest keeper's normal daily settle is the one that prices the sybil at the agent-deflated NAV. PoC
transfers **11.04%** of the honest holder's value in one round at a 19.9% deflation and a 1:1 sybil:victim ratio
(10k → sybil 11,105 / alice 8,896; 100k → 111,049 / 88,947; 1M → 1,110,494 / 889,457). The deflation is free (no
trading loss) when done via the portfolio-margin under-read (HLR2-K12) or `agentSendAsset`.

---

## (c) Per-key worst case

USDC a thief can take **or destroy**, by vault size, with the honest-rest assumption (KA2). "Vaults" = how many at
once. Speed = time to first irreversible effect. All three live vaults share one guardian/sentinel/registrar/owner,
so the platform-key rows hit every factory vault at once.

| Key (stolen) | 10k vault | 100k vault | 1M vault | Vaults | Speed | Alerts (rule, latency) | What stops it |
|---|---|---|---|---|---|---|---|
| **Vault agent** (API wallet) | ~1.1k/settle (C-01, K03); up to ~10k if it drains spot/wash before revoke | ~11k/settle; up to ~100k | ~110k/settle; up to ~1M | 1 (its own vault) | deflation instant; theft bounded next settle (daily) or next checkRisk | `OTHER_DEX`→ACT revoke (monitor, ~≤1 run ≈60 s) for `agentSendAsset`/subaccount; **but PM-mode deflation = `NAV_MOVE` alert-only** (K12); `FOREIGN_TRADE`/`FOREIGN_SPOT` alert | contract: checkRisk breach (reduce-only, reactive, bounds *next* loss); maxNavMoveBps 20%/settle; sentinel/guardian `revokeAgent` — **blockable up to 24 h, K11**; cold guardian `triggerEmergency` |
| **Platform agent** (hosted) — same powers as vault agent, but **one key per vault** (see §(f)): a leak is NOT all vaults | as above, per vault | as above | as above | **1 per leaked key** (the executor guarantees distinct keys; a leak of the agent key store = all, see §(f)) | same | same | same |
| **Operator / keeper** | 0 direct (settle/bridge/moveUsd only); enables K03 if combined with an agent | 0 | 0 | all it operates | n/a | not an insider; settle bounded by maxNavMoveBps + checkpoint | contract role scope: no trading, no roles; owner/guardian/sentinel `revokeOperator` |
| **Sentinel** (hot) | 0 theft; **DoS** (full-stop, agent revoked) | 0 / DoS | 0 / DoS | **all factory vaults** | instant | its own actions are the alert; `triggerBreach` emits Breached | cold guardian `clearBreach`; factory owner `setSentinel` to rotate the key out |
| **Registrar** (hot) | ~1.1k+/settle via a self-agent on a **new** vault (HLO-07) | ~11k+ | ~110k+ | new vaults it signs | one launch + settle | `VaultCreated`/`PlatformAgentRegistered` not-ours → error alert (HLO-E06) | can't bind an existing vault (V-04); creator co-sign (planned); owner `setAgentRegistrar` |
| **Manager** | C-01 full insider path, but insider deposits deferred + 1 h min epoch age; ~11k-class/settle via sybil | ~11k-class | ~110k-class | its own vault | per settle | `NAV_MOVE` alert; checkRisk | maxNavMoveBps; insider deferral; cold guardian |
| **Owner** (vault) | can set a new agent (2-day timelock), lower/clear, resume; with an agent = full C-01 | — | — | its own vault | 2 days (timelock) for a new agent | queue events; `Queued`/`Executed` | 2-day timelock; cold guardian cancel; depositors can exit (if they watch) |
| **Guardian** (cold) | ≤3% of open position/flatten (K07); DoS via emergency | ≤3%/flatten | ≤3%/flatten | all factory vaults | instant (emergency) | `EmergencyTriggered`, `Flattened` | bounded at 3% (`MAX_FLATTEN_SLIPPAGE_BPS`); nothing recovers an emergency but the guardian itself |
| **Factory owner** (cold) | rotate all roles + HLO-07 self-agent theft (~11k-class/settle) | ~11k-class | ~110k-class | **all factory vaults** (DoS) + own new vault (theft) | instant (rotate) / one launch (theft) | `GuardianUpdated`/`SentinelUpdated`/`VaultCreated` | 2-step ownership; `_checkRoles`; move to Safe (runbook) |
| **Launcher** | = owner+manager of its own vault; under open launch, an insider of its own vault | — | — | own vault | — | — | policy + checkpoint + platform agent (if hosted) |
| **Safe owner signer** (planned) | 0 alone (threshold 2-of-3) | 0 | 0 | none below threshold | n/a | — | Safe threshold; runbook forbids a signer that is also sentinel/registrar/keeper/deployer |

Today owner == guardian == factory owner is one **EOA** `0x1A7a…D7ff` (no code). So one cold-key theft = guardian +
both factory owners = rotate every role + DoS every vault + HLO-07 theft on a new vault. The guardian-to-Safe
runbook (`docs/runbooks/guardian-to-safe.md`) moves this to a 2-of-3 Safe; until then the cold EOA is the single
largest blast radius.

---

## (d) Agent-trading extraction, per curated asset and technique (live depth, read 2026-10-19 20:32 UTC)

"Agent cannot withdraw" is true, but **trading against a counterparty you control is a withdrawal.** Depth from
`keys/evidence/books/books.json` (`analysis.txt`). vwap_bps = cost of sweeping the whole notional vs mid; a
round-trip wash loses roughly 2× the spread plus the market impact, paid to the attacker's resting order.

### Curated perps — walk cost of one order at policy leverage

| Asset (idx, maxLev) | day volume / OI | 10k×5 = 50k | 100k×5 = 500k | 1M×5 = 5M | 1M×maxLev |
|---|---|---|---|---|---|
| BTC (0, 40x) | $2.37B / 39.8k | 0.1 bps | 0.1 bps | 1.9 bps (vwap), 2.7 last | 40M → 8.9 bps vwap, 18.6 last |
| ETH (1, 25x) | $874M / 1.08M | 1.3 bps | 2.6 bps | 4.9 bps | 25M → 14.4 bps vwap, 31.5 last |
| SOL (5, 20x) | $210M / 5.49M | 5.3 bps | 8.3 bps | 15.9 bps | 20M → **52.2 bps vwap, 103.9 last** |

Reading: on BTC/ETH the curated books are too deep to move meaningfully even at 1M×maxLev — wash-trading the vault's
whole book costs single-to-low-double-digit bps per round-trip. **The extraction on curated assets is not a single
big print; it is unlimited repetition** (order spam, limited only by HL rate limits, §(e)). SOL is the soft spot: a
1M vault at 20x sweeps 104 bps to the last level — one hostile round-trip against an attacker's resting SOL order
costs the vault on the order of ~1% of the swept notional, repeatable.

### Techniques (numbers)

- **Wash trade vs attacker account, thin book.** The curated list does not bind the agent (KA3), so the agent can
  also trade **non-curated** perps. Thinnest live perps (maxLev 3) have ask depth within 1% of only $8–35k
  (TNSR $18k, ME $9k, WCT $8k). A wash round-trip there moves the mark several %, paid to the attacker. But these
  are not in NAV (not held), so this is a loss-not-a-mark path: value crosses to the attacker directly.
- **Buy an attacker-deployed/illiquid HIP-1 spot token at the attacker's ask.** HL rejects an order only when the
  limit price is **too far from the oracle** (`Oracle: "Order price too far from oracle"`,
  `error-responses.md`); for a freshly deployed HIP-1 token the oracle *is* its own thin book, so the attacker sets
  the ask arbitrarily and the band is relative to it. Thinnest live spot books total **$200–$7.4k** on the ask side
  (`@2` $2.4k, `@3` $773, `@6` $1.3k). One agent buy spends the vault's **entire spot USDC** on a worthless token;
  `coreEquity()` counts only USDC spot (token 0), not the token received, so the spent USDC leaves NAV with no
  offset. Ceiling = 100% of the vault's spot USDC in one order. (the platform vault holds its value in perp today, so the live
  spot balance is ~0; a vault holding spot USDC is fully exposed.)
- **`vaultTransfer` into an attacker-led HL vault.** Agent-signable (SDK `vault_usd_transfer`, exchange endpoint
  `vaultTransfer`). Moves the vault's **perp** USDC into any HL vault. It leaves `coreEquity()`'s view immediately
  (not dex-0 perp, not spot). The leader can then bleed the HL vault to its own account by trading; **user-vault
  lockup is 1 day** and the **leader must keep ≥5%** (`for-vault-leaders-legacy.md`), so recovery of the principal
  is delayed a day and the leader can trade-loss it out meanwhile. NAV-deflation-now + loss-later.
- **`agentSendAsset` to another dex / HIP-3.** Moves collateral off dex 0 → invisible to `coreEquity`. **This is the
  one the monitor ACTs on** (`OTHER_DEX` from-own → sentinel revoke, ≤~60 s), so it is the *detected* deflation path.
- **`agentSetAbstraction` to portfolio margin (HLR2-K12, the quiet deflation).** Measured on mainnet
  (`pm-unified-equity.txt`): under PM the spot precompile reads **0** even when the API shows +9,336 USDC free, and
  reads **0** for a −443,390 borrowed USDC balance. So the agent can (i) make NAV read **lower** (free spot USDC →
  0: the C-01 deflation, no trade, no loss) **or** (ii) make NAV read **higher** (borrow USDC, negative balance → 0,
  so the debt is not subtracted while the borrowed-funded perp margin still counts in `accountValue`) → redemptions
  paid at a premium. The vault has **no path to switch the mode back** (never emits CoreWriter action 16), and this
  deflation is **NAV_MOVE (alert only)**, not an ACT (K12) — it evades the sentinel's auto-revoke.
- **Self-liquidation / mark push / funding.** On BTC/ETH the robust mark (median incl. Binance/OKX/Bybit, 150 s EMA;
  `robust-price-indices.md`) resists a single-venue push, so mark manipulation is a SOL-and-thinner story. Funding
  is capped and slow — not a per-settle lever.
- **Leverage change / order spam fees.** `updateLeverage` to the asset max raises how much notional the agent can
  take against thin depth (SOL 20x, BTC 40x) but does not itself move money. Order spam is the delivery mechanism for
  the un-revocable finding (§e), not a direct drain.

### Per-settle accounting ceiling (the realistic steady-state theft)

Regardless of technique, the **operator-settled C-01 round (K03)** is bounded by `maxNavMoveBps = 20%/settle`:
one round at 19.9% deflation and a 1:1 sybil ratio transfers **~11%** of honest value (PoC). Per vault per daily
settle: **10k → ~1.1k, 100k → ~11k, 1M → ~110k**, auto-clearing at the next UTC midnight (I3-01), repeatable daily
until a human sets a new agent through the 2-day timelock.

---

## (e) The un-revocable-agent hypothesis (coordinator's high-priority item)

**Docs quoted (`keys/evidence/docs/`):**

- Address-based limit (`rate-limits-and-user-limits.md`): "1 request per 1 USDC traded cumulatively since address
  inception. Each address starts with an initial buffer of 10000 requests. When rate limited, an address is allowed
  one request every 10 seconds. Cancels have cumulative limit `min(limit + 100000, limit * 2)` … Note that this rate
  limit only applies to actions, not info requests." Batched: "as `n` requests for address-based rate limiting."
- `reserveRequestWeight` (`exchange-endpoint.md`): "this action allows reserving additional actions for 0.0005 USDC
  per request. The cost is paid from the Perps balance." So the address limit is **buyable**: 50,000 actions ≈ **25
  USDC**.
- Abstraction (`account-abstraction-modes.md`): "Portfolio margin and unified account are **limited to 50k user
  actions per day.** Standard mode has no such restrictions." `agentSetAbstraction` is agent-signable (SDK).
- CoreWriter (`interacting-with-hypercore.md`): a system-contract call "emits a log to be processed by HyperCore as
  an action" — i.e. revoke (`addApiWallet`, action 9) is a **user action on the vault's Core account**.

**Finding HLR2-K11 (High, conditional, rated on worse reading per KA3).** Two sub-mechanisms:

1. **Documented 50k/day freeze.** A stolen agent switches the vault to unified/portfolio margin (the vault can never
   switch back, K10), `reserveRequestWeight`s ~25 USDC of extra actions to get past the address rate limit, and burns
   the **50k user-actions/day** quota with cheap no-fills (`noop`/`modify`/cancels). Once the account hits 50k/day,
   **every later user action from the vault account is rejected until 00:00 UTC** — including the guardian's/
   sentinel's `revokeAgent` (a user action on that account). Whether the 50k cap rejects the revoke specifically is
   not documented; on the worse reading it does. **Window: up to ~24 h.**
2. **Plain address-limit drag (weaker).** Without PM: the agent exhausts the 10k buffer fast, after which the account
   is 1 action / 10 s. Revoke (`addApiWallet`) is not a cancel, so it competes for the 1/10 s slot — delay of seconds
   to tens of seconds per attempt, not a true block. This alone is Low.

**Loss inside the 24 h window.** While frozen the agent also cannot trade, so the loss is what was staged before the
freeze plus the mis-reading that cannot be corrected: a single C-01 operator-settled round (the keeper's settle is a
**HyperEVM** transaction, *not* an HL user action, so it is **not** rate-limited and still fires) = **~1.1k / 11k /
110k** for 10k/100k/1M, and the stuck PM mode keeps NAV mis-reading for every read in the window. The revoke that
"always stopped a compromised agent" in rounds 1–4 does **not** stop it here for up to a day.

**Fix (describe, do not implement):** have the keeper detect an abstraction-mode change (the probes show it in the
spot-clearinghouse read) and treat it as an ACT finding, not NAV_MOVE; have the vault refuse settles while the mode
is non-default (a `coreEquity` sanity read); and, structurally, give the contract a CoreWriter action-16 path so the
guardian can force the mode back instead of only setting a new agent through the 2-day timelock.

---

## (f) Executor key storage — is one leak all vaults?

**No single secret derives all agents, but one store holds them all.** Per-vault agent keys are each
random, generated per vault, and held by the executor's agent key store, each bound to its agent address. The
executor
refuses to start if any two online roles share an address. So:

- A **leak of one decrypted agent key** = that **one vault** only.
- A **leak of the agent key store** = **every** hosted/tenant agent at once (D-5 stands). This is the catastrophic row:

  for N served vaults, the ceiling is the agent row times N, with the same per-vault numbers.
- A leak of the sentinel, registrar or keeper key = the platform-role rows above (distinct wallets).

The key store has no hardware or cloud key management (D-5), so
the blast radius of a host compromise is "all hosted agents," bounded only by the per-vault
contract limits (maxNavMoveBps, checkpoint, the monitor's revoke — itself subject to HLR2-K11).

---

## Last commit / files

- Files written: `contracts/audit/hl-r2/KEYS.md`; `contracts/test/audit/hl-r2/keys/KeysPoC.t.sol` (7 PoCs, pass);
  `contracts/audit/hl-r2/keys/evidence/` (HL doc `.md` snapshots, `books/` live depth + scripts, analysis).
- Run: `forge test --match-path "test/audit/hl-r2/keys/*"` (skip gains per the build tip). 7 passed.
