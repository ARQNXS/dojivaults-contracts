# hl-r2: answers to hl-open's open questions 1–7

**This is an internal, AI-assisted review. It is not an independent audit and must not be presented as one.**

Source: `contracts/audit/hl-open/REVIEW.md` section 7. Evidence comes from read-only chain and API reads
(2026-10-19 ~20:30 UTC), code citations and docs with URLs. The HyperEVM public RPC keeps no historical state and
caps `eth_getLogs` at about 100 blocks, so measurements are limited to the last few thousand blocks.

| # | Short answer | Confidence |
|---|---|---|
| 1 | EVM→Core at size lands in the same second: 1,838,830 USDC and 313,201 USDC deposits were credited on Core 0.0 s after their EVM block (Core→EVM not measured). No documented amount or rate limit. Core→EVM costs 200k gas in HYPE from the vault's Core spot | measured (EVM→Core); docs (Core→EVM) |
| 2 | The executor guard bounds each order by the vault's **own** policy only (allowlist, `maxOrderNotional`, `maxLeverageBps` × headroom, margin). An untrusted launcher sets all of them (≤ 50x, notional ≤ 2^64−1), and nothing caps total turnover or exposure per day | code |
| 3 | Yes. `sendAsset` (user-signed) takes any `destination` and `destinationDex`, so anyone can credit another account's HIP-3 dex balance. E07's premise holds; the hl-open fix (act only on outbound value) is the right shape | SDK / docs |
| 4 | No. The executor sends HyperEVM transactions with viem defaults and no tip; the RPC's `eth_maxPriorityFeePerGas` returns 0. Others in recent blocks tip up to 3 gwei. X-01's "the settler wins with a priority fee" does not hold (HLR2-H04) | code + chain |
| 5 | No consumer calls `factory.vaults()` any more (webapp, server, scripts: paged storage reads). The public HyperEVM RPC's `eth_call` cap is **30,000,000 gas**, so `vaults()` would break there at ≈ 12,987 vaults (2M-gas callers at ≈ 865) | grep + measured |
| 6 | Both round 3 vaults belong to the platform's own wallet [platform wallet] (also the platform vault's owner/manager). Caps are 25,000 USDC each, raisable to any value. x402 Test has no shares; Copy HL Test Vault is in emergency. No outside depositor is exposed | chain |
| 7 | Not run. The script writes `contracts/broadcast` (outside this review's write scope) and asserts the old closed, capped configuration. Static analysis: as written it would now fail at check 0 (the deploy default is uncapped), and none of its nine scenarios exercises open launch | code |

## 1. HyperCore at size: landing time and limits

**Measured (EVM→Core).** `evidence/hostile/probe_landing.py` (read-only) takes every USDC `Transfer` into the
CoreDepositWallet `0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24` in the last 3,000 HyperEVM blocks (277 deposits). For
the largest ones it reads the depositor's Core ledger (`info` `userNonFundingLedgerUpdates`, throttled) and compares
the credit time to the EVM block timestamp. Output in `evidence/hostile/landing-2026-10-19.txt`:

| amount (USDC) | EVM block | Core credit after |
|---|---|---|
| 1,838,830.00 | 48,986,407 | **0.0 s** |
| 313,200.60 | 48,987,644 | 0.0 s |
| 22,877.98 | 48,988,354 | 0.1 s |
| 10,099.24 | 48,988,356 | matched at 251 s (probably another credit of a similar amount) |
| 199,999.80, 19,997.98 | | no credit on the sender's ledger (a `depositFor` to another account; not matchable) |

The platform vault's own ledger agrees: the seed (2 USDC) and HYPE were credited in the launch second (2026-10-09 03:25:17 UTC,
including the 1 USDC `accountActivationGas`), and later deposits arrive as `spotTransfer` from `0x2000…0000`. At $1.8M
the landing is in the same block, well inside the vault's 10-block window. The 300-block R3-08 cliff was not
approached at the observed sizes.

**Not measured (Core→EVM).** HyperCore→HyperEVM credits are delivered by a system transaction (docs, below), and the
Core ledger hashes are not EVM transaction hashes. Matching them needs a live watcher that holds a block range under
the ~100-block `getLogs` cap (e.g. the executor's log stream) while a Core→EVM send is observed. Not done here.

**Docs** ([HyperCore <> HyperEVM transfers](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/hypercore-less-than-greater-than-hyperevm-transfers),
fetched 2026-10-19):
- Core→EVM: "credited by a system transaction that calls `transfer(recipient, amount)`" on the linked contract, and
  "A transfer from HyperCore to HyperEVM costs 200k gas at the base gas price of the next HyperEVM block". The vault pays
  that in HYPE from its Core spot balance (seeded with 0.01 HYPE; anyone can top it up with `fundCoreGas`). At
  today's ~0.46 gwei base fee that is ≈ 0.00009 HYPE per bridge, so the seed covers about 100 bridges home. A vault
  whose Core HYPE is gone presumably has its Core→EVM sends fail silently, which keeps the window open up to
  `MAX_UNLANDED_BLOCKS` (300). The executor should keep a HYPE floor on every vault it serves.
- No amount or rate limit is documented for either direction. The page warns "There are currently no checks that the
  system address has sufficient supply", so Core→EVM USDC is paid from the EVM-side balance of the USDC system
  path. hl-open read 640.1M USDC held by the CoreDepositWallet; a Core→EVM send larger than the EVM-side liquidity is
  undocumented behaviour. Keep vault exits far below that (they are, by four orders of magnitude, today).

## 2. The executor order guard under an untrusted launcher

`server/src/core/guard.ts` (`guardOrder`, called from `engine/processor.ts:625` and `:904`) rejects a non-reduce-only
order when the vault is breached, in emergency or trading-paused, when the asset is outside `policy.allowedAssets`,
when `orderNotional > policy.maxOrderNotionalUsd`, when the projected leverage `(open + order) / equity` exceeds
`capBps` (the policy's `maxLeverageBps` times the executor's headroom fraction, processor.ts:610-612), or when the perp
margin is short. Every bound is read from the vault's own policy, which the launcher writes (HLO-03): leverage up to
50x, order notional up to 2^64 − 1, all curated perps. The executor adds no platform envelope, no per-day notional,
turnover or loss-velocity limit, and no limit on the number of orders. The only rate limit found is the TradingView
webhook's per-vault limiter (`tenants/tradingview.ts:253-288`). The total bound on what a launcher makes the platform
agent do is therefore exposure ≤ the launcher's `maxLeverageBps` × equity at any moment, with unlimited churn. At 50x
a 2% adverse move consumes the equity; repeated round trips cost fees and slippage without bound. The contract's
`checkRisk` breakers are the launcher's too (≤ 100%). The agent's other powers (spot, HIP-3 dexes, `vaultTransfer`,
abstraction mode, CONTEXT.md item 1) are outside the guard, which only covers orders the executor itself builds.
Fix: a platform envelope in the executor, independent of the on-chain policy (leverage ≤ 10x, a daily traded-notional
cap as a multiple of equity, e.g. 20x, and a per-day realised loss stop), plus the factory envelope of HLO-03.

## 3. Can a third party credit another account's HIP-3 dex balance?

Yes. The official SDK's `send_asset(destination, source_dex, destination_dex, token, amount)`
(`evidence/hl-sdk/exchange.py:493-516`, user-signed `sign_send_asset_action`) moves the signer's token to any
`destination` on any `destinationDex` ("For the default perp dex use the empty string... Token must match the
collateral token if transferring to or from a perp dex"). CoreWriter action 13 has the same shape
(`destination, subAccount, source_dex, destination_dex, token, wei`). So anyone can put 1 USD on a vault's HIP-3 dex
balance. The pre-fix E07 rule (any other-dex balance → revoke) was a free griefing lever. The fix in `monitor.ts`
(revoke only when the vault's own cash fell by ≥ 98% of the other-dex increase, FIXES.md) addresses exactly this.
Not executed on chain (sending value is outside this review's rules).

## 4. A malicious manager racing the emergency settle; is a priority fee configured?

**No priority fee is configured** for the platform settler on HyperEVM:
- `server/src/chain/vault.ts:1077-1080` (`prepare`): `wallet.prepareTransactionRequest({ account, chain, to, data, value, gas })`,
  with no `maxPriorityFeePerGas` and no chain `fees` override in `hyperEvmChain()` (`vault.ts:164-172`). viem then
  takes the tip from `eth_maxPriorityFeePerGas`.
- Live: `eth_maxPriorityFeePerGas` → `0x0`; `eth_gasPrice` → 462,340,249 wei. `eth_feeHistory(5, latest, [50, 90])`
  rewards include `0xb2d05e00` (3 gwei) at the 50th/90th percentile in some blocks. Other senders tip; the platform does
  not.
- The only explicit tip in `server/src` is the Gains (Arbitrum) client, `maxPriorityFeePerGas: 0n`
  (`venues/gains/chain.ts:18, 179`).

So the X-01 acceptance ("the platform settler wins with a priority fee") does not hold. PoC
`test_HLR2_H04_managerBridgeChainKeepsTheEmergencySettleOut` (HOSTILE-AND-CONFIG H04) shows the manager taking each
window with a 100 USDC bridge. The delay is bounded by Core USDC / 100 USDC windows of 11 blocks (1M ≈ 30 h). If the
vault's Core HYPE is exhausted and failed Core→EVM sends keep the window open for 300 blocks (question 1), the delay
is longer still. Fix: drop the manager from `bridgeToEvm` in emergency, and set an explicit tip (2–5 gwei) for
guardian / sentinel / keeper sends.

## 5. `factory.vaults()` consumers and the HyperEVM `eth_call` gas cap

**Consumers.** `grep` over `webapp/src`, `server/src`, `server/scripts`, `contracts/script` and `scripts` finds no call of
`vaults()` on any factory. The webapp (`src/data/factoryVaults.ts`, `chain.ts:373`, `gainsChain.ts:38`) and the server
(`src/chain/factoryVaults.ts`, `chain/vault.ts:129`) read `vaultCount()` and then the `_vaults` array by paged
`eth_getStorageAt`. Guard tests enforce it (`server/test/factory-vaults.test.ts:67-71`,
`webapp/src/data/factoryVaults.test.ts:68`). The many `this.d.vaults()` in `server/src` are the executor's own
dependency that returns the paged list, not the contract view. `vaults()` remains only in the ABI JSON files and in
`docs/gains/STAGE4.md:39`, a stale sentence ("listed (`vaults()`)").

**Gas cap, measured.** `eth_call` with a state-overridden infinite loop (`0x5b600056`) on `https://rpc.hyperliquid.xyz/evm`:
- no `gas` field → `out of gas: gas required exceeds: 30000000`
- `gas` = 2,000,000 → `... exceeds: 2000000`
- `gas` = 30,000,000 or 1,000,000,000 → `... exceeds: 30000000`

So the public RPC caps `eth_call` at 30M gas (the big-block limit; the latest small block's `gasLimit` read 3,000,000).
With hl-open's 2,310 gas per vault, `vaults()` through this RPC breaks at ≈ 12,987 vaults. A caller that passes 2M
(or a small-block-sized limit) breaks at ≈ 865. Private RPC providers may differ; nothing calls it anyway.

## 6. The round 3 factory's vaults and `maxDepositCap = max`

Live (`evidence/mainnet-probes/live-state-2026-10-19.txt`, re-read 2026-10-19): round 3 factory [an earlier factory],
`openLaunch = false`, `maxDepositCap = 2^256 − 1`. Its two vaults:
- x402 Test [an earlier vault]: owner = manager = fee recipient [platform wallet], cap 25,000 USDC,
  NAV 1 USDC (seed), supply 0, agent `0x6d00…26a6` live on Core.
- Copy HL Test Vault [an earlier vault]: the same owner, cap 25,000 USDC, NAV 0.002411 USDC, breached and in emergency,
  agent revoked.

Both are owned by the wallet that also owns and manages the platform vault: the platform operator's own wallet (an EOA, nonce
35), not outside managers. Who must know: the operator. `setDepositCap` on either now accepts any value
(VaultGovernance.sol:311-312). No outside depositor holds shares in either. Recommendation: keep them closed
(x402 Test: `setDepositsPaused(true)`), or lower the round 3 factory's `maxDepositCap` (that bounds every later
`setDepositCap`, not the current caps, N-13).

## 7. Re-running the round 4 fork rehearsal under `openLaunch = true` and uncapped values

`server/scripts/rehearse-round4.ts` is fork-only (it refuses a non-local RPC, `:209-211`) and keyless (anvil's public
dev keys, `:46-57`). It was **not run**, for two reasons. It writes into `contracts/broadcast` (backs it up, runs
`forge script ... --broadcast`, restores, `:220-253`), outside this review's write scope (`contracts/audit/hl-r2`,
`contracts/test/audit/hl-r2`). It also needs `server/node_modules`, which this worktree does not have.

Static analysis of what it would do now:
- **check 0 fails**: `check("deploy: maxDepositCap <= 50,000 USDC", ...)` (`:258-259`). `Deploy.s.sol:169` now
  defaults `MAX_DEPOSIT_CAP` to `type(uint256).max`, and the script does not pass `MAX_DEPOSIT_CAP`.
- `check("deploy: openLaunch is false")` (`:257`) passes (Deploy never opens launch) but asserts the opposite of the
  live state.
- Scenarios 1–9 launch both vaults from the allowlisted manager (`ALLOW_LAUNCHER`) with a registrar-signed agent and a
  50,000 USDC vault cap (`:285`). Nothing in them depends on `openLaunch`: none launches as a stranger, uses an
  unreserved agent (E06), hits the registrar budget (E01), names another wallet (HLO-02), uses a hostile policy
  (HLO-03) or moves amounts above 30k.

To make it meaningful for the live configuration: pass `MAX_DEPOSIT_CAP` unset and flip the two checks to
`openLaunch == true` (add a `factory.setOpenLaunch(true)` step from the deployer) and `maxDepositCap == max`. Add a
stranger launch with the wizard's parameters, an unreserved-agent launch (expect the E06 alert), and one 10M deposit
through settle and exit. The operator should run it locally (anvil fork, `npx tsx scripts/rehearse-round4.ts`).
