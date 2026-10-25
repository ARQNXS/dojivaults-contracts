# HL open launch: executor scaling, platform spend, alerts, registrar (audit/hl-open, sub-review 4 + executor half of 2)

Base: `origin/main` 726378d, worktree `dv-hl-open`, branch `audit/hl-open`. Scope: the executor (`server/src`) for
Hyperliquid vaults after 2026-10-13: `openLaunch` (any wallet calls `HyperVaultFactory.create`) and no platform
deposit cap. Every confirmed finding has a vitest PoC in this folder. The PoCs run the real `server/src` code against
fakes. The Hyperliquid info API is a local HTTP server on 127.0.0.1, and the alert channel's `fetch` is stubbed. Nothing
touches a real network or RPC, and nothing under `server/` was edited.

## How to run

```
cd server
npm ci                      # node 22, the lockfile's vitest 5.0.3 / viem 2.57.3
npx vitest run --config ../contracts/audit/hl-open/executor/vitest.config.mjs              # all PoCs
npx vitest run --config ../contracts/audit/hl-open/executor/vitest.config.mjs E02 --silent=false   # one file, with its printed table
```

`vitest.config.mjs` is the gains executor config (`contracts/audit/gains/tools/executor/`) with its paths moved. Bare
imports resolve as if `server/src` imported them. The vite cache goes to `server/node_modules/.vite-audit-hl-open-executor`.
`fakes.ts` holds the shared fakes: the local Hyperliquid server, which records each request's `type`, and Hyperliquid's
documented info weights.

**Result at the time of writing: 9 files, 27 tests, all passing.**

**Fixed since (fix/hl-open, [../FIXES.md](../FIXES.md)):** E01, E04, E05, E06, E07 and E10. Their PoCs below are now
regression tests of the fixes; E09 is unchanged.

**Converted since (the executor read rework):** E02, E03 and E08 now run against the core
reader (HyperCore state from the HyperEVM precompiles, batched), the extraAgents and spot-token rotations and the
weight budget, and print the before figure next to the new one. The measured results are in the design doc, section 9.
38 tests in all.

## What a stranger can add, and what it costs them

- **MANUAL vault** (agent = 0): a direct `factory.create` with no executor involvement. It costs a seed of at least
  `minSeedUsdc` (default 2 USDC, 1 of which stays on Core as the activation fee), at least `minHypeValue` (0.01 HYPE,
  forwarded to the vault's Core spot) and the create gas. That is about 1 USDC + 0.01 HYPE lost per vault, roughly
  $1.8 at HYPE $81.83, so 1,000 vaults cost about $1,800. The indexer stores it as an active MANUAL tenant
  (`tenants/launch.ts:313-338`). It is not "served" (`registry.ts:118-119`), but it is visited by the keeper rotation,
  the monitor rotation, the epoch, settlement and fee jobs, the history scanner and `/vaults`.
- **Served vault** (own signals, hosted or copy, with a platform agent): it also needs a reservation
  (`/api/launch/reserve`). Reservations are capped at 20 per hour globally (HLO-E01), so 100 served stranger vaults
  take 5 hours and 1,000 take 50. On top of the MANUAL loops, a served vault is visited by the risk watcher (15 s), the
  keeper every round, the treasury operator (when its `operator` is the keeper, the wizard's default), health (30 s),
  agent sync and, in copy mode, the mirror.

## Summary

| ID | Title | Severity | Location | PoC |
|---|---|---|---|---|
| HLO-E01 | Anyone can use up the global registrar budget (20 per hour, in memory) for free; every platform-agent launch then gets 429 | Medium | `tenants/launch.ts:128,198,265-271`; `env.ts:148,249` | `E01-registrar-budget.test.ts` (2) |
| HLO-E02 | Hyperliquid info weight has no client-side budget. Monitor, health, risk and keeper reads use up the 1,200/min IP limit at about 20 to 30 vaults, and one 429 stalls every info client on the host, the order path included | Medium | `monitor.ts:148-210`; `main.ts:1131-1142,1964`; `risk/watcher.ts:217-221,366-367`; `venues/hl/backoff.ts:26,59-75` | `E02-hl-weight.test.ts` (6) |
| HLO-E03 | HyperEVM RPC bucket (8 calls/s) fills up at about 1,000 MANUAL or about 120 served stranger vaults; background work (indexer, log stream, monitor, notifiers) is refused first | Medium | `env.ts:50-51`; `chain/rpc.ts:28-33`; `main.ts:1286-1328`; `keeper.ts:94-97`; `epochNotifier.ts:72`; `feeAccruer.ts:53-79` | `E03-rpc-bucket.test.ts` (5) |
| HLO-E04 | An unreadable vault turns into one keeper `checkRisk` transaction per vault per hour, with no cap and no "nothing to protect" skip | Medium (conditional on E02/E03 or an outage) | `keeper.ts:90,250-252,385,415,427-432` | `E04-keeper-unreadable.test.ts` (4) |
| HLO-E05 | Alert volume and alert text are in a stranger's hands; the alert channel has no rate limit, priority or retry, so a BREACH alert is dropped after a flood | Medium | `alerts/<channel>.ts:29-49`; `epochNotifier.ts:87`; `settlementNotifier.ts:29`; `feeAccruer.ts:75`; `monitor.ts:253-270,283,299` | `E05-alert-flood.test.ts` (4) |
| HLO-E06 | I3-04 with open launch: a VaultCreated naming a platform agent the executor never reserved is registered silently as MANUAL (no alert, no `PlatformAgentRegistered` cross-check) | Low | `tenants/launch.ts:305-311` | `E06-unreserved-agent.test.ts` (1) |
| HLO-E07 | 1 USD credited to another perp dex of any vault makes the sentinel revoke its agent (if HyperCore lets a third party credit it) | Medium if the HyperCore premise holds (PLAUSIBLE); pre-existing | `monitor.ts:205-208,323-331` | `E07-other-dex-revoke.test.ts` (1) |
| HLO-E08 | Real-vault latency grows linearly: monitor 50 min and risk watcher 300 s per round at 1,000 vaults | Medium (Design) | `monitor.ts:146-152`; `env.ts:142`; `risk/watcher.ts:366-367` | `E08-coverage-dilution.test.ts` (2) |
| HLO-E09 | Number precision at 1e9 to 1e12 USDC: no issue | Info | `risk/contractRisk.ts:296-299`; `main.ts:1013`; `history/replay.ts:389-392` | `E09-precision.test.ts` (2) |
| HLO-E10 | Platform HYPE per stranger vault: per-tenant accrueFees and per-served-vault settle every day, with no per-vault or global cap | Low (Design) | `feeAccruer.ts:53-79`; `treasury/operator.ts:149-150,208`; `main.ts:1431-1440` | `E03-rpc-bucket.test.ts` (fee accruer and operator tests) |

No Critical or High: no path found from a stranger's vault to depositor funds in another vault. The worst outcomes
are delayed risk reactions, a blinded monitor, blocked launches and a bounded drain of the keeper wallet.

## Findings

### HLO-E01 (Medium): the launch reservation budget is global and free to use up

- **Code.** `LaunchService.registrarBudget` (`launch.ts:265-271`) is one sliding hour in process memory for all callers,
  the hourly registrar budget 20 (`env.ts:148`), and is checked at `launch.ts:198`. On a round-4 factory a reservation
  is an off-chain registrar signature (`launch.ts:243-245`). Nothing is sent and no gas is spent, so the budget
  protects nothing that costs money. The other checks are all per wallet or per IP:
  - the per-owner pending cap 3;
  - one SIWE signature per reservation, which a throwaway EOA produces for free;
  - nonces that are free to fetch (60 per IP per 10 min);
  - the reservation rate limit 5 per IP per 10 min (`env.ts:249`, `app.ts:666`), which is 30 per hour per IP.
- **Attack.** One IP and 7 fresh wallets. Each wallet runs nonce, sign, reserve three times (21 attempts), taking all
  20 slots of the hour. No vault is created, and no USDC or gas is spent. A restart clears the budget, and the attacker
  takes it again at once.
- **PoC.** `E01-registrar-budget.test.ts`:
  - 20 of the 21 attacker reservations succeed, with 20 registrar signatures and 0 transactions;
  - the honest hosted launch gets `429 launch capacity reached for this hour`, and so does one 59 minutes later;
  - `app.ts`'s own limiter lets 30 reserves per hour through from one IP.
- **Impact x likelihood.** Every hosted, own-signals and copy launch is refused for as long as the attacker keeps
  going. MANUAL launches still work, because they go straight to the factory. Likelihood: high (no cost, one IP).
- **Variant.** EIP-1271 owners get 24-hour reservations (`launch.ts:227`). 20 per hour x 24 = 480, which is more than
  the global pending-reservation cap 200, so a contract "owner" that approves every signature can also hold the global
  pending cap (`launch.ts:233-235`).
- **Other registrar questions (no finding).**
  - A stranger's request cannot produce a signature that works for another vault. The registrar signs
    `(fresh server agent, predictVaultAddress(SIWE signer, salt), deadline)`. The address is scoped to `msg.sender`
    (`HyperVaultFactory.sol:212-241`), and the agent key never leaves the server.
  - Database growth is bounded:
    - nonces have a TTL index (the database module, line 168), so at most 60 per IP per 10 min live for 10 min (24 h for contracts);
    - pending reservations are purged by the sweep (`launch.ts:480-484`);
    - bound reservations and audit rows grow by at most 20 per hour.

### HLO-E02 (Medium): Hyperliquid info weight, with no client-side budget and a host-wide 429 cooldown

- **Code.** Every info client uses `BackoffHttpTransport`, and its 429 cooldown is shared by every info call on the
  host (`backoff.ts:26,59-75`; Retry-After up to 60 s, 4 retries). The executor's order path (orderStatus, fills,
  markPx) waits on the same cooldown, and so do the risk watcher and the keeper. Hyperliquid's limit is 1,200 weight
  per minute per IP for all REST traffic, `exchange` included. Weights:
  - `clearinghouseState`, `spotClearinghouseState`: 2 each;
  - `extraAgents`, `perpDexs`, `metaAndAssetCtxs`: 20 each.

  The code does not encode this limit anywhere. `docs/design/keeper-gas.md:84-86` counts the keeper's 400 requests
  per minute at 1,000 vaults as "a third" of the budget, which confuses requests with weight.
- **Measured weight** (`E02-hl-weight.test.ts`, real HlInfo, local server):
  - **Monitor**, every 60 s, up to 20 vaults per run: 46 + 2 x dexes weight per vault. One run weighs 920 at 20 or
    more vaults with no HIP-3 dex, and 1,240 with 8 dexes. That is 77 to 104% of the budget from the monitor alone,
    the same at 100 and at 1,000 vaults.
  - **Health**, every 30 s, on every instance, outside the leader lease: `extraAgents` (20) for every served tenant in
    one `Promise.all` (`main.ts:1131-1142`). That is 40 weight per minute per served vault, the whole budget at 30
    served vaults, sent in bursts. The cached check races a 15 s timeout but keeps running, so after a timeout two
    checks can overlap (`healthCache.ts`).
  - **Risk watcher:** 4 weight per served vault per check. Because of the stagger it settles near 800 weight per
    minute from about 50 served vaults up. A test-mode vault with 3 open test tickets costs 128 per check, because
    each ticket reads `metaAndAssetCtxs` and a simulated book over the trim line is read twice.
  - **Keeper:** 4 weight per visited vault. Served vaults: 0.8 weight per minute each. Unserved: 4 x max(5, N/12)
    per 5 minutes.
  - **Copy vaults** (from code): source `clearinghouseState` plus the vault account every 15 s, about 24 weight per
    minute each (`copy/engine.ts:244,495,712`).
- **Impact.** Once over budget, Hyperliquid answers 429. Every info client then sleeps the cooldown, which the PoC
  shows at 30 s:
  - risk checks fail and are retried (`watcher.ts:376-392`);
  - the keeper sees the vault as unreadable and falls into HLO-E04;
  - order-path reads stall;
  - `exchange` requests share the same IP weight and the transport does not retry them (`backoff.ts:64`), so an order
    sent while limited fails outright.

  Likelihood: the monitor alone reaches the limit once there are 20 factory vaults (about $36 of MANUAL vaults), and
  health reaches it at 30 served vaults (1.5 hours of reservations).

### HLO-E03 (Medium): the HyperEVM RPC bucket fills linearly; background work is refused first

- **Code.** There is one process-wide bucket: the RPC rate setting 8 and burst 16 (`env.ts:50-51`), which is 480 calls
  per minute. It serves calls by priority (`rpc.ts:28-33`). A background call waits at most 15 s and then throws
  `RpcBusyError`. Background covers the indexer and log stream, the monitor, the notifiers and the cache invalidation
  stream.
- **Per-vault calls** (from code). Lane batching merges concurrent reads issued within 16 ms into one multicall
  (`vault.ts:261-265,309`):
  - **Keeper:** about 3 `eth_call` per visit (riskInputs, policy, `policy(v, true)` at `keeper.ts:527`).
  - **Monitor:** reads the agent (5 min cache) and the sentinel (10 min cache) of every factory vault every minute,
    one `await` after another (`main.ts:1286-1328`). That is about 0.3 x N calls per minute.
  - **Epoch notifier:** every tenant every 15 minutes.
  - **Settlement notifier:** every tenant every hour.
  - **Operator:** about 0.4 x served vaults per minute.
  - **Risk watcher:** about 2 calls per served vault per minute (60 s caches).
- **Totals per minute.** About 480 at 1,000 MANUAL vaults (keeper about 50, monitor about 340, epoch about 67,
  settlement about 17, fees about 5), which is the whole bucket before any real vault. About 400 at 100 served vaults
  (83%) and about 2,000 at 1,000 served (4x).
- **PoC** (`E03-rpc-bucket.test.ts`):
  - keeper-priority demand at 10 calls/s makes a background `take` fail with `RpcBusyError` after 15 s;
  - the keeper rotation batch is 5, 9 and 84 for N = 10, 100 and 1,000;
  - the notifiers read all N tenants each pass.
- **Impact.** The log stream and indexer fall behind, so new vaults, `AgentRevoked`, `LeftHosted` and pauses are
  processed late. The `describe()` reads fail, and for a vault not in the 10-minute sentinel cache that sets
  `actionable = false` (`main.ts:1286-1307`), so the sentinel stops acting on monitor findings. UI calls fail. Orders
  still go first.

### HLO-E04 (Medium, conditional): unreadable becomes one keeper transaction per vault per hour

- **Code.**
  - When a vault's reads fail, the keeper sets `reasons = "unreadable"` (`keeper.ts:427-432`). It then sends
    `checkRisk` at most hourly per vault (`UNKNOWN_RESEND_MS`, `keeper.ts:90,385`).
  - The pre-send guard treats a failed read as "send" (`keeper.ts:250-252`).
  - The under-$1 skip (`keeper.ts:415`) only runs on a readable vault.
  - Nothing caps how many vaults may be sent this way.
- **PoC** (`E04-keeper-unreadable.test.ts`, Hyperliquid answering 429):
  - 100 one-dollar MANUAL vaults: 0 transactions while readable. 100 in the first hour once Hyperliquid answers 429,
    then about 55.6 per hour (the 55.6 min rotation sits inside the 60 min spacing).
  - 100 served vaults: 100 per hour.
  - 1,000 unserved vaults: about 920 per hour.
- **Gas.** About 116k per checkRisk, measured in `docs/design/keeper-gas.md:69-70`. At 0.42 gwei 920 per hour costs
  about 1.08 HYPE per day (about $88); at 1.08 gwei, about 2.8 HYPE per day.
- **Impact.** A bounded drain of the keeper wallet for as long as the condition lasts. Once the wallet is empty, real
  vaults' checkRisk, settle and fee transactions stop; the low-gas alert fires at 0.01 HYPE (`keeper.ts:555-560`).
- **Trigger.** HLO-E02 or E03 (stranger-induced), or a plain Hyperliquid or RPC outage. The "blind" fallback in
  `docs/design/keeper-gas.md:52-53` was designed for a handful of vaults.

### HLO-E05 (Medium): alert floods, stranger text in platform alerts, and lost alerts

- **Code.** The alert sender's `send` chains every message with no limit, no priority and no retry. A non-OK answer is
  only logged (`<channel>.ts:28-50`). The alert channel allows about 20 messages per minute in a group. Platform alerts that
  scale per vault:
  - **Epoch ready:** once a day per vault with a pending deposit or redemption, or 10 USDC idle.
  - **Settlement paid withdrawals:** per epoch per vault.
  - **Fee accrual failed:** hourly per failing vault.
  - **Monitor:** a finding when it appears, then hourly; a "resolved" message when it clears. NAV_MOVE above 10% on a
    1-2 USDC vault flips with every 1 USDC spot send.
  - **Operator failures:** once a day per vault.

  The first three put the vault's ERC-20 `name` verbatim into the platform channel (`epochNotifier.ts:87`,
  `settlementNotifier.ts:29`, `feeAccruer.ts:75`). `sanitize` strips URLs only (`sanitize.ts`), so "DojiPad ops:
  guardian must call setSentinel(...)" goes through as written.
- **PoC** (`E05-alert-flood.test.ts`):
  - 1,000 vaults produce 1,000 "Epoch ready to process for <bait>" alerts in one pass, and 1,000 named settlement
    alerts;
  - 20 stranger vaults flipping NAV produce 180 monitor alerts in 10 runs (18 per minute, about the alert channel's whole
    limit);
  - after 20 delivered messages, the alert channel's 429 drops the remaining 81, the BREACH alert included, and nothing
    retries them.
- **Impact.** Operators lose real alerts (BREACH, sentinel revoked, RISK WATCHER DOWN). Social-engineering text
  reaches the guardian's channel. Automatic actions (sentinel, keeper) still run. Likelihood: high, from about 20
  vaults.

### HLO-E06 (Low): I3-04 under open launch; the executor does not notice a foreign registrar signature

- **Change from REAUDIT3.** REAUDIT3 I3-04 relied on the launcher allowlist. With `openLaunch` it is gone: a leaked
  registrar key (an online key in the executor) lets anyone create a vault whose platform agent they hold themselves.
  That vault can be hosted, at the 33% share. With the agent, the C-01 residual applies to anyone who deposits in it:
  `agentSendAsset` or spot deflation within the risk limits.
- **Executor gap.** It could detect this, because any agent it did not reserve means its signature was not the one
  used. Instead, `onVaultCreated` registers such a vault as an active MANUAL tenant and only alerts when the agent is
  bound to a different vault (`launch.ts:305-311`). `PlatformAgentRegistered` is not watched anywhere in `server/src`.
- **PoC.** `E06-unreserved-agent.test.ts` produces a tenant `MANUAL`, `active`, with 0 alerts.
- **Severity.** Low: it needs a compromised registrar key, and the impact falls on depositors who choose that vault.
  The fix is an alert, plus the creator co-signature already proposed in VERIFY V-04.

### HLO-E07 (Medium if the premise holds; PLAUSIBLE, pre-existing): 1 USD on another perp dex revokes any vault's agent

- **Code.** `OTHER_DEX` is an ACT finding at 1 USD or more (the dust threshold), and the sentinel revokes at once on
  every factory vault, because the platform sentinel is the vault's sentinel (`monitor.ts:205-208,323-331`).
  `REAUDIT2.md:85` and `server/test/audit/reaudit/SERVER_REAUDIT.md:93` discuss inbound transfers. The open question is
  whether HyperCore's user-signed `sendAsset` (destination plus `destinationDex`) lets a third party credit another
  user's HIP-3 dex balance.
- **If it does.** One dollar stops trading on any real vault. The owner then has to set a new agent through the
  timelock, and the stranger can repeat it for another dollar.
- **PoC.** `E07-other-dex-revoke.test.ts`: a served vault with a 1.00 USD `xyz` balance gets `revokeAgent` and an ACT
  alert.
- **Not verified on HyperCore**, per the no-broadcast rule; see the open questions.

### HLO-E08 (Medium, Design): real-vault latency scales with the stranger count

- **Monitor.** It looks at a fixed 20 vaults per 60 s run, rotating over every factory vault with no priority for
  served ones (`monitor.ts:146-152`, `main.ts:1310-1328`). A real vault is therefore inspected every ceil(N/20) minutes:
  1 at N 20 or less, 5 at 100, 50 at 1,000 (PoC). That is the detection time for FOREIGN_AGENT,
  EXPOSURE_UP_IN_BREACH and OTHER_DEX.
- **Risk watcher.** It checks one vault after another with a 200-400 ms stagger. A real vault activated after 999
  strangers is first read 299.7 s into each round, against a 15 s interval (PoC); the `running` flag makes overlapping
  ticks no-ops. Loss-limit reductions wait that long. Leverage trims still run on mid ticks, but only for vaults
  already read (`watcher.ts:415-438`).
- **Errors are contained.** One slow or throwing vault does not block a loop. Each loop catches per vault and moves on
  (`watcher.ts:368-374`, `monitor.ts:153-165`, `keeper.ts:510-553`, `operator.ts:105-127`, `feeAccruer.ts:59-79`,
  `epochNotifier.ts:74-82`). A hanging read is bounded by the transport timeouts (Hyperliquid 15 s; RPC priority
  waits 15-60 s), and each such vault adds that delay to the whole round.

### HLO-E09 (Info): number precision at large caps

`micro()` is exact up to about 9e7 USD. Above that, the error is within 16 micro at 1e9 and 128 micro (0.000128 USD)
at 1e12, about 1e-12 of a 1 bps step (PoC). The executor never converts the deposit cap to a number: the launch config
sends it as a string (`main.ts:1013`), and the history label treats No cap separately (`replay.ts:389-392`). The bridge
minimums (`epochPlan.ts`) are lower bounds only. There is no hard-coded upper size in the HL path.

### HLO-E10 (Low, Design): platform HYPE per stranger vault

All transactions are simulated before signing (`vault.ts:950-1013`). A settle or `accrueFees` that would revert fails
in simulation and costs no gas, and the operator retries it every 5 minutes with no backoff. Only state that changes
between simulation and inclusion burns gas. Per stranger vault per day:

- **accrueFees:** every tenant, MANUAL and inactive included (`listTenants`, `main.ts:1431-1440`), whose supply is
  above 0, and a seeded vault always has supply. One keeper transaction per day. Gas was not measured; at about 100k
  it costs about 0.04 HYPE per day per 1,000 vaults at 0.42 gwei.
- **Operator settle:** every served vault whose operator is the keeper, the wizard's default
  (`main.ts:1012`). "A due epoch is always worth settling" (`operator.ts:149-150`), so that is one settle of about
  420k gas per day. PoC: 100 vaults over 3 days produce 300 settles. 1,000 vaults cost about 0.18 HYPE per day at
  0.42 gwei, plus bridgeToCore and moveUsd for each deposit.
- **Keeper checkRisk:** none for a flat vault. A vault with a position gets about 1 per day, plus HLO-E04 when reads
  fail.
- **agentSync:** at most one `syncAgent` per bind and per AGENT_NOT_ON_HL appearance (`agentSync.ts`). The registrar
  budget limits it.
- **Sentinel:** one revoke per ACT finding appearance.

There is no per-vault or global HYPE budget. Total at 1,000 vaults in normal operation: about 0.25 HYPE (about $20)
per day. With HLO-E04: about 1.3 HYPE per day.

## Per-loop scaling

Columns:
- **HL wt/min:** Hyperliquid info weight per minute; the limit is 1,200 per IP.
- **RPC/min:** HyperEVM calls per minute; the bucket is 480.
- **Tx:** platform transactions.
- **Order:** S = sequential, P = parallel.

Numbers are per stranger-vault count. "M" means MANUAL (unserved) stranger vaults and "S" means served ones.

| Loop (file:line) | Interval | Per vault per visit | Order / cap | 10 | 100 | 1,000 |
|---|---|---|---|---|---|---|
| Monitor (`monitor.ts:141-171`, list `main.ts:1310-1328`) | 60 s | HL 46 + 2D wt; RPC: agent and sentinel for **every** vault each run (5 and 10 min caches) plus breachState and bridgeQuiet for the inspected ones | S, 20 per run, 250 ms pause | HL 460 (D=0) / 620 (D=8); RPC ~25 | HL 920 / 1,240; RPC ~70 | HL 920 / 1,240; RPC ~340; each vault seen every 50 min |
| Health (`main.ts:1100-1142`, `healthCache.ts`) | 30 s, every instance | S only: extraAgents 20 wt, agent read | **P, unbounded** | S: 400 wt | S: 4,000 wt | S: 40,000 wt |
| Risk watcher (`risk/watcher.ts:356-404`) | 15 s, no overlap | S only: account 4 wt (64 to 128 in test mode with tickets); about 2 RPC per minute | S, 200-400 ms stagger | S: 160 wt; round 2.7 s | S: ~800 wt; round 29.7 s | S: ~800 wt; round 299.7 s |
| Keeper (`keeper.ts:481-570`) | 5 min, no overlap | 4 wt, ~3 RPC; tx only when needed | S; served every round; unserved max(5, N/12) per round | S: 8 wt, 6 RPC; M: 4 wt | S: 80 wt, 60 RPC; M: 7 wt, 5 RPC | S: 800 wt, 600 RPC; M: 67 wt, 50 RPC |
| Keeper, unreadable (HLO-E04) | per visit | 1 checkRisk tx per vault per hour | none | 10 tx/h | 56-100 tx/h | ~920-1,000 tx/h |
| Operator (`treasury/operator.ts:102-134`) | 5 min, no overlap | S only: operatorOf (5 min), facts, account 4 wt; settle about once a day | S | S: 8 wt; 10 settles/day | S: 80 wt; 100 settles/day | S: 800 wt; 1,000 settles/day |
| Fee accruer (`feeAccruer.ts:53-79`) | 1 h pass, daily per vault | feeState plus 1 tx | S, no cap | 10 tx/day | 100 tx/day | 1,000 tx/day |
| Epoch notifier (`epochNotifier.ts:72-93`) | 15 min | epochFacts (1 RPC); 1 alert per day if ready | S | 0.7 RPC | 6.7 RPC | 67 RPC; up to 1,000 alerts/day |
| Settlement notifier (`settlementNotifier.ts:67-85`; stream) | 1 h plus stream | 1 RPC; 1 alert per paying settle | S | 0.2 RPC | 1.7 RPC | 17 RPC |
| Agent sync (`agentSync.ts`) | per bind or finding | 5 to 15 extraAgents (20 wt), at most 1 tx | in flight per vault | registrar-limited | registrar-limited | registrar-limited |
| Copy mirror (`copy/engine.ts:244,495,712`) | 15 s | copy only: 6 wt; 2 WebSocket subscriptions per source | S | 240 wt | 2,400 wt | 24,000 wt |
| Log stream and indexer (`chain/logStream.ts`) | 15 s | none per vault: about 2 getLogs per tick, with an address filter of 2N addresses | S | ~8 RPC | ~8 RPC; 200 addresses | ~8 RPC; 2,000 addresses |
| History scanner (`history/scanner.ts`) | 30 s | backfill per vault on its own lane (1/s, leftover only) | S | n/a | n/a | backfill queue grows linearly |
| Reservation sweep (`launch.ts:480-497`) | 5 min | 1 database read per tenant | S | trivial | trivial | 1,000 database reads per 5 min |
| `/vaults` (`app.ts:591-629`) | per request, 120/min/IP, unauthenticated | listTenants plus metrics for listed vaults (5 min cache) | **P, unbounded** | trivial | trivial | 1,000 rows per call |
| Online keys (`registry.ts:198`, `hotKeys.ts`) | n/a | one agent key per served vault | n/a | trivial | trivial | trivial |

**Totals.**
- **1,000 MANUAL stranger vaults (about $1,800):**
  - HL: about 990 wt/min (monitor plus keeper), 82% of the budget before any real vault.
  - RPC: about 480 per minute, the whole bucket.
  - Gas: about 0.04 HYPE per day (fees), and about 1.1 HYPE per day while unreadable.
- **100 served stranger vaults (5 hours of reservations):**
  - HL: about 5,900 wt/min (5x the budget; health 4,000).
  - RPC: about 400 per minute.
- **30 served vaults:** health alone is 1,200 wt/min.

Overlap: every loop has a `running` guard, so a round that outlasts its interval skips the next ticks rather than
overlapping. The exception is health, whose timeout frees the guard while the old check still runs. No loop runs its
vaults concurrently except health and `/vaults` (`Promise.all`).

## Open questions

1. Can a third party credit another user's balance on a non-default perp dex (HyperCore `sendAsset` with a
   `destinationDex`)? This decides HLO-E07. Testnet check only.
2. How many HIP-3 dexes are on mainnet now (D in the monitor weight)? Does Hyperliquid count the `exchange` endpoint
   against the same 1,200 per IP? Its docs say all REST requests share it.
3. Hyperliquid WebSocket limits for copy sources: the docs list a cap on unique users across user-specific
   subscriptions (10 at the time of writing; to confirm). If it holds, 10 stranger copy vaults following 10 accounts
   push every real copy vault onto the 15 s REST path.
4. Does a test-mode trim (`processor.reducePositions` in dry run) actually shrink the simulated book? If not, the risk
   watcher sends "Trimmed positions" to the platform channel every round, with a never-deduplicated key (`seq++`,
   `watcher.ts:265`).
5. Can `feeState().bridgeInFlight` be false while `accrueFees` reverts on `bridgePending()` (unlanded, up to
   MAX_UNLANDED)? Then every such vault gets an hourly "accrueFees failed" alert carrying its name (`feeAccruer.ts:75`).
6. The deployed `minSeedUsdc` and `minHypeValue` set the cost of a MANUAL spam vault. The defaults (2 USDC, 0.01 HYPE)
   are assumed above.
7. Gas of `accrueFees`, `bridgeToCore` and `moveUsd` on mainnet (not measured here).

## Recommended mitigations

1. **E01.** Remove the global hourly budget for signed (round-4) launches, or make it per wallet and per IP. Spend a
   reservation only on proof of intent: the wallet's USDC balance at least `minSeedUsdc` plus an allowance or permit to
   the factory, read at reserve time. Then sweep reservations that never launched. Keep a global cap only on pending
   keys, sized from storage and not from registrar gas.
2. **E02.**
   - Add one Hyperliquid weight budget per process: a token bucket in weight units ahead of `BackoffHttpTransport`,
     with priorities like the RPC gateway (orders, then risk, then keeper, then monitor, then health and UI).
   - Health: stop calling `extraAgents` for every tenant every 30 s. Use the monitor's result or a 10-minute rotation,
     and gate health behind the leader lease or a cache.
   - Monitor: cache `perpDexs` and read `extraAgents` only for served vaults or on a slower rotation.
   - Fix `docs/design/keeper-gas.md:84-86`, which confuses requests with weight.
3. **E03, E08.**
   - Tier the vaults: served and listed vaults with depositors first, at full rate. Stranger vaults with only their
     seed (totalSupply equal to the seed shares, no deposits) at a slow rotation, or not at all.
   - Make the monitor's list cheap: no per-vault RPC to build it; the sentinel and agent come from events.
   - Let monitor and risk-watcher batch sizes and intervals scale with the count, with real vaults first.
   - Raise the RPC rate setting only together with a per-job budget.
4. **E04.** Cap unreadable sends: per round, and globally per hour. Never send to a vault whose last readable NAV was
   below `MIN_RISK_NAV` with no positions. When most vaults are unreadable at once, treat it as an outage (one alert)
   rather than per-vault sends.
5. **E05.**
   - Put a rate limiter and a priority queue in the alert sender: errors first, coalescing per kind ("312 vaults: epoch
     ready"), and retry after 429 using its `retry_after`.
   - Never put a vault's on-chain name in platform alerts; use the address plus an operator-set label.
   - Send per-vault notices (epoch, settlement) only to the vault's own manager alerts, not the platform channel.
6. **E06.** Alert (error) on any VaultCreated with a non-zero agent that has no reservation, and on any
   `PlatformAgentRegistered` the executor did not cause. Consider auto-revoking through the sentinel. Implement the
   creator co-signature (VERIFY V-04) before relying on `openLaunch`.
7. **E07.** Make OTHER_DEX an ACT only when the balance came from the vault's own account (a decrease of its dex 0 or
   spot balance in the same window). Otherwise alert, as SERVER_REAUDIT already proposed.
8. **E10.** Skip accrueFees and settle for vaults without outside depositors, or whose fee would be zero (management
   fee 0, or below the gas cost). Add a daily HYPE budget per job with an alert.
