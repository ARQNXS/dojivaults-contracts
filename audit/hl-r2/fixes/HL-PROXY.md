# hl-r2 HL-PROXY: the agent trades through the vault's own order path

**Internal, AI-assisted review (hl-r2, fix-design sub-review). It is not an independent audit and must not be presented
as one.** Branch `audit/hl-r2-proxy` (from `audit/hl-r2` 131f6ee, with the integration merge c6227bd). Nothing was
deployed, signed, sent or pushed; no order, no transaction, no env file, no hosting configuration. `contracts/src`,
`server/src` and `webapp/` on this branch are unchanged: every change is a patch file, proven in throwaway worktrees
under `$TEMP` (assumption A4). Every mainnet number below comes from read-only `eth_getLogs` / `eth_call` /
`eth_estimateGas` (a simulation) and Hyperliquid `info` reads at most 2 per second (assumption A6).

## 0. In plain words

- **What changes.**
  - The platform agent stops being a Hyperliquid API wallet. It becomes an ordinary HyperEVM wallet that may call
    two functions of its own vault: `placeOrder` and `cancelOrder`. Every order it sends is checked by VaultPolicy
    exactly like the manager's: curated asset, leverage after the order, notional cap, slippage band, reduce only in
    a breach. On top: a fresh risk check before any order that adds risk, IOC only, its own client order id.
  - The vault never approves its agent on HyperCore (no CoreWriter action 9 for it). So the agent cannot do any of
    the things that bypass the policy today: `vaultTransfer`, subaccounts, spot, `agentSendAsset` to other dexes,
    `agentSetAbstraction`, leverage and isolated margin changes, TWAPs, `reserveRequestWeight`.
  - The vault pins its own HyperCore account to the Standard ("disabled") account mode with CoreWriter action 16:
    when the agent is set, at every settle, at most every 10 minutes from `checkRisk` and the agent's orders, and on
    demand by any vault role. While the precompiles show the portfolio-margin footprint, the vault refuses to price
    NAV: no normal settle, no fee accrual, no `checkRisk`, no order that adds risk. Exits (exit-only settles) and
    de-risking (reduce-only orders) are never blocked.
  - The executor routes every strategy's order for such a vault (platform-vault-style signals, the copy mirror, the risk
    watcher's trims and loss stops, close-all, treasury reductions: they all go through `Executor.execute` ->
    `Submitter.placeOrder`) to a `HyperVault.placeOrder` transaction signed by the vault's agent key. Older vaults keep
    the API wallet path only while `HL_LEGACY_API_ORDERS` is on.
- **What it costs.**
  - **Latency.** The docs' "a few seconds" for CoreWriter orders is not what mainnet does today: 75 matched
    CoreWriter orders executed on HyperCore **335-501 ms after their EVM block (median 395 ms)**. The whole contract
    path, as patched (the executor's usual simulate + estimate + fees + nonce + send, then the next 1 s small block,
    then HyperCore), adds **about 2.0 s (median), 2.5 s (p90), 3.4 s (max)** over today's API path. With a lean
    sender (one RPC round trip, a follow-up) the extra is **0.6 s (median), 1.0 s (p90), 1.4 s (max)**.
  - **Money.** Over 2 s, BTC / ETH / SOL move on average 0.6 / 1.0 / 1.1 bps (3-day 1-minute volatility, random-walk
    scaled). That is noise for an uninformed signal (expected cost about 0). Where the order follows a move (stops,
    trims, copy trades) the measured adverse drift is 0.04 bps (copy, 3,568 source fills) to 0.3 bps (orders after a
    1 s move). No IOC within the 1% policy band was missed in any sample.
    - The platform vault today (170 USDC, about 2 orders a day of about 91 USD): **under 0.01 USD a day**, plus about 0.002 USD
      of HYPE gas per order that adds risk.
    - A 1M USDC vault on the platform vault's strategy (about 2 orders a day of about 535k USD): **about 2-32 USD a day
      expected** (0.04-0.3 bps), with a day-to-day noise of about ±55 USD; a risk trim in a stressed market (5x
      volatility) about 900 USD at the 99th percentile for a 500k USD SOL trim.
- **What it closes.** For vaults built from the patched code: D-1 (agent unbounded on chain), HLR2-X05 (agent-only
  value moves), HLR2-K03 as a free deflation (no hidden-balance path left), HLR2-K11 (a revoke is now an EVM state
  change: no HyperCore quota can delay it), HLR2-K12 and K10 (no actor can switch the mode, the vault re-pins it, the
  guard refuses to price under portfolio margin), the XA01 residual on the abstraction path (refused on chain, not
  only by the monitor), HLR2-F01 (no approval to expire), HLR2-F05 (TIF checked). The monitor gets an ACCOUNT_MODE
  finding for older vaults (revoke) and proxy vaults (re-pin).
- **What it does not close.** Live vaults (the platform vault, x402 Test, Copy HL Test) are immutable clones: they keep the API
  wallet path until they are replaced by vaults from a factory with the patched implementation (section 8). Unified
  mode leaves no reliable precompile footprint (section 4); it is covered by the pin and the monitor only. The agent
  can still lose money within the policy (section 7).

## 1. Assumptions (most conservative reading)

- **P1.** "Default" account mode in the original design = Standard (separate perp and spot balances). Hyperliquid's
  `userAbstraction` answers "default" for an account that never chose (the platform vault today) and "disabled" for one that chose
  Standard; CoreWriter action 16 has no "default" value (1 = disabled, 2 = unifiedAccount, 3 = portfolioMargin, HL
  docs). 38 probed default/disabled accounts read identically on the precompiles (perp and spot separate, both equal
  to the API). So the vault pins **1 = disabled**, and both "default" and "disabled" count as correct.
- **P2.** Whether HyperCore accepts action 16 from a contract account, whether setting the mode the account already
  has is a no-op, and whether a switch is refused while positions are open, are not documented; nothing was sent to
  check (A6). Rated on the worse reading: the pin may silently fail, so the guard (section 4) and the monitor do not
  rely on it. A testnet broadcast is follow-up F1.
- **P3.** Whether CoreWriter actions count against the vault's address-based request budget is not documented.
  Worse reading: yes. So strangers may pin at most once per 10 minutes (144 a day), the same order of magnitude as
  the existing permissionless `syncAgent` (Verification pass 5's open "repeated syncAgent cost" note).
- **P4.** The API path's own latency is not measurable read only. It is taken from the HL docs (co-located
  end-to-end median 0.2 s, p99 0.9 s; marked as such) plus half of the measured `info` round trip from this machine
  (Europe; the executor is hosted in Europe).
- **P5.** A HyperEVM small block is built on the first L1 block after each second boundary (HL docs, "Dual-block
  architecture"), so its whole-second `timestamp` is its build time within one L1 block (about 0.1 s). The
  CoreWriter delays below are measured from that timestamp.
- **P6.** Gains: unchanged by this patch. Gains imports only unchanged constants and types from `VaultTypes.sol`;
  the one-job build of the stacked tree (section 6) compiles it.

## 2. The owner's claims, checked in code (origin/main 4a6b526; src = round 4 deploy)

| Claim | Verdict | Evidence |
|---|---|---|
| HyperVault already has a contract order path, `placeOrder` / `cancelOrder` via CoreWriter | **True** | `HyperVault.sol:236-242`; `VaultLogic.sol:527-554`; CoreWriter action 1 / 10 in `hypercore/HyperCore.sol:156-164` |
| ...checked by VaultPolicy | **True, with gaps** | `VaultLogic.sol:542-545` calls `policy.checkOrder` (`VaultPolicy.sol:173-198`): spot refused (183), asset allowlist unless reduce only (184), mark must exist (185), price band from mark on both sides, reduce only included (186-188), notional at the worse of limit and mark against `maxOrderNotional` (190-193), projected leverage `(ntlPos + notional) <= maxLeverage x accountValue` on dex 0 (194-195). The vault adds: reduce only in breach or emergency (538), trading pause (539), spot refused (541). **Not checked:** the daily loss and drawdown at order time (only the `breached` flag a past `checkRisk` set), the TIF (546, HLR2-F05), the cloid, order rate or turnover, positions on other dexes (`accountMarginSummary` reads dex 0 only, `HyperCore.sol:110-114`) |
| ...that the agent could reuse | **False today: the path is manager only** | `VaultLogic.sol:537` `if (msg.sender != $.manager) revert`; `cancelOrder` manager or sentinel (551-552). Neither the agent nor the operator may call them. On hosted vaults the manager is the launcher (the platform vault: owner = manager = [platform wallet]), so the platform has no contract order path at all. HL-PROXY adds the agent as a caller |
| The API wallet agent was added for latency | **True (stated rationale)** | the manager docs and the order ticket tell managers "HyperCore delays contract orders by a few seconds ... For latency sensitive execution, trade through the approved agent key instead" (`docs/copy/CURRENT.md:1199`, `:2187`, `:2351`, `:2397`, webapp `components/manage/OrderTicket.tsx:211`, `docs/managers.tsx:38`). Measured: 0.4 s, not seconds (section 3) |
| ...and bypasses VaultPolicy | **True** | the executor signs Hyperliquid L1 actions with the agent key (`server/src/venues/hl/exchange.ts:35-68`: `ExchangeClient.order` and `updateLeverage`, no `vaultAddress`), routed for every strategy by `venues/hl/index.ts:27` and `main.ts:441-449`. The contract never sees these orders. The executor's self-limits (`assertPerpOrder` perp only, IOC, its own guard) are code in the key holder, not a bound on the key: per the SDK the same key can also sign `vaultTransfer`, `createSubAccount` / `subAccountTransfer`, spot orders, `agentSendAsset`, `agentSetAbstraction`, `updateIsolatedMargin`, `twapOrder`, `reserveRequestWeight` (CONTEXT evidence 1; `evidence/hl-sdk/exchange.py`). The contract's own comment is wrong: "Agents can trade for the account but cannot withdraw or transfer funds" (`HyperCore.sol:181`) |
| The original design requires the default account mode | **True, documented, not enforced** | `docs/audit-pack/KNOWN-ISSUES.md:41-42` ("Vaults are expected to stay on the default mode"), `README.md:464` ("Keep the vault on the default mode"), `contracts/audit/REPORT.md:265` (A-11, "Verified for current mode only"), `contracts/audit/notes.md:32,36`. Nothing enforces it: the vault never emits action 16 (`HyperCore.sol` has no encoder; COREWRITER-ENCODING section 2), `coreEquity()` assumes it (`VaultMath.sol:119-124`), and the agent can switch it (`agentSetAbstraction`). Live: the platform vault reads "default" |

## 3. Latency on mainnet (read only)

Method, scripts and raw data: `evidence/latency/` (`scripts/*.py`, `data/*`, HL doc snapshots in `docs/`).

### 3.1 Contract path: CoreWriter orders, EVM block to HyperCore

- **Scan.** RawAction logs of `0x3333...3333` in 100-block windows, blocks 49,045,595 to 49,066,096 (about 5.7 hours
  of chain, 2026-10-20 12:10 to 17:28 UTC for the orders), `scripts/scan_orders.py`: 3,916 CoreWriter actions, of
  which 80 limit orders (action 1) from 20 contracts (`data/cw-orders.jsonl`). Every one of them was in a small block
  (gas limit 3M): no CoreWriter order was in a big block (30M) in this sample, so the big-block case is not measured.
  An order in a big block would wait up to 60 s for its block; the agent's order (about 0.1-0.2M gas) always fits a
  small block.
- **Match.** `scripts/match_orders.py`: each order matched to HyperCore by its cloid in `historicalOrders(sender)` and
  to its fills in `userFillsByTime`. 75 of 80 matched (all by cloid, all `filled`); the 5 others are 4 orders without a
  cloid on a HIP-3 asset (110109) and 1 reduce-only BTC order absent from the history (most likely rejected).
- **Result** (`data/cw-matched.json`): HyperCore order timestamp (= fill time for all 75) minus the EVM block
  timestamp: **median 395 ms, p90 461 ms, max 501 ms, min 335 ms.** The docs' "order actions ... sent from CoreWriter
  are delayed onchain for a few seconds" is **not observed**: the delay is under half a second today. (It may be
  re-tuned by Hyperliquid at any time; the patch does not depend on its size.)
- **The EVM legs** (`scripts/rpc_timing.py`, `data/rpc-timing.json`, public RPC from this machine, 12 calls each):
  `eth_blockNumber` / `eth_call` / `eth_estimateGas` / `eth_getTransactionCount` / `eth_gasPrice` round trips
  median 0.31-0.34 s. `eth_estimateGas` of a real `placeOrder` on the platform vault from its manager (a simulation, nothing
  signed): **109,985 gas** today; `checkRisk` 125,109 gas (`data/checkrisk-gas.txt`). The fix test's mock precompiles cost more (agent open 507,599, reduce 305,521; `results/proxy-main-fix.log`); both fit a 3M-gas small block. Gas price 0.1 gwei; HYPE 79.84 USD (`data/hype-mid.txt`).

### 3.2 API path

- **From the HL docs (not measured, P4):** "end-to-end latency has a median 0.2 seconds and 99th percentile 0.9
  seconds" for a co-located client (`docs/overview.md`); IOC orders already run after cancels and ALO orders sent at
  the same time, "spanning several blocks" (`docs/optlat.md`), the same for both paths.
- **Measured:** `info` round trip from this machine, 3,600 calls: median 511 ms, p90 588 ms (`data/mids-1s.jsonl`,
  `rtt`). Half of it is added as the one-way network leg.

### 3.3 Decision to execution, both paths (100,000-sample model from the samples above, `scripts/analyse.py`)

| Path | median | p90 | p99 | max |
|---|---|---|---|---|
| API wallet (today) | 0.44 s | 0.71 s | 1.16 s | 5.5 s |
| Contract, as patched (`VaultChain.send`: simulate, estimate, fees, nonce, send; next small block; CoreWriter) | 2.47 s | 2.90 s | 3.34 s | 3.77 s |
| Contract, lean sender (one send round trip; follow-up F3) | 1.07 s | 1.46 s | 1.58 s | 1.67 s |
| **Extra delay, as patched** | **2.00 s** | **2.48 s** | **2.92 s** | **3.41 s** |
| Extra delay, lean sender | 0.59 s | 1.03 s | 1.23 s | 1.43 s |

### 3.4 What the strategies lose

Price data: BTC / ETH / SOL mids once a second for one hour (2026-10-20 ~20:00-21:00 UTC, `data/mids-1s.jsonl`) and
3 days of 1-minute candles (`data/candles-1m-*.json`). The polled hour was quiet (1-minute sd 3.0 / 5.4 / 6.7 bps
against 4.2 / 6.6 / 7.8 bps over the 3 days), so the cost table uses the 3-day volatility scaled to the delay
(random walk, `model_*`); the polled hour's direct measurement is lower and listed for comparison.

| Over the extra delay (as patched) | BTC | ETH | SOL |
|---|---|---|---|
| mean \|move\|, 3-day volatility | 0.61 bps | 0.97 bps | 1.12 bps |
| p99 \|move\|, 3-day volatility | 1.97 bps | 3.18 bps | 3.72 bps |
| mean \|move\|, polled hour (direct) | 0.14 bps | 0.30 bps | 0.42 bps |
| adverse drift after a 1 s move (stops, trims fire after a move) | 0.21 bps | 0.29 bps | 0.26 bps |
| P(move > 1% band: IOC missed) | 0 of 40,000 | 0 | 0 |

Copy mirror: 3,568 BTC / ETH / SOL fills of 28 active mainnet traders in the polled hour (`data/source-fills.json`):
the mid's drift in the source's direction over the extra delay, starting 0.5 s or 1 s after the source fill (the
mirror's own reaction, unchanged), is **0.04 bps** (± 0.01, as patched) and 0.01 bps (lean sender).

Per strategy that uses the agent today (all of them go through `Executor.execute`):

| Strategy | Orders | Expected cost of the extra delay per order | The platform vault (170 USDC) | 1M USDC vault |
|---|---|---|---|---|
| Hosted signals (the platform vault: BTC / ETH / SOL swing, `config/strategies.json`) | measured 16 orders in 8 days on the platform vault, avg 91 USD = 0.53x NAV (`data/vault-fills.json`) | about 0 expected (the signal is not a short-term move); upper bound 0.3 bps | < 0.003 USD / order, < 0.01 USD / day | 0-16 USD / order (535k), 0-32 USD / day; noise ±1 bps = ±55 USD / order |
| Copy mirror (source fills) | per source trade | 0.04 bps | ~0 | 0.04 bps x notional: 2 USD per 500k USD |
| Risk watcher: trims and loss stops (reduce only) | rare, in moves | 0.2-0.3 bps quiet; in a stressed hour (5x volatility) about 1-1.5 bps mean, ~18 bps p99 (SOL) | ~0 | about 900 USD at p99 on a 500k USD SOL trim in a 5x-volatility hour |
| Close-all, treasury reductions | rare | as trims | ~0 | as trims |
| EVM gas (all orders) | per order | an open: about 0.26M gas (placeOrder 109,985 + the pre-trade checkRisk 125,109, both `eth_estimateGas` on the platform vault, + the pin) x 0.1 gwei = 2.6e-5 HYPE = 0.002 USD; a reduce about 0.13M | about 0.004 USD / day | about 0.004 USD / day |

Reading: on BTC / ETH / SOL the extra 1-3 s costs basis-point fractions per order. No strategy in the repo is a
sub-second strategy; the copy mirror already reacts seconds after its source. The cost is well below the 1% IOC band
and below the taker fee (4.5 bps).

## 4. Account mode: what can be read on chain

No precompile reports the abstraction mode (`L1Read.sol`, 0x800-0x814, `docs/L1Read.sol.txt`). Probe of the 61
active accounts of the round 2 probe set, `scripts/mode_signature.py`, `data/mode-signature.json`:

| Signal | default (16) / disabled (23) | unifiedAccount (16) | portfolioMargin (6) |
|---|---|---|---|
| 0x801 spot USDC `hold` | 0, except 2 accounts with resting spot orders | **0 always** (the API's hold is not on the precompile) | 0 always |
| 0x811 `borrowLendUserState(user, USDC)` | PrecompileError (no state) on 38, all zeros on 1 | error on 12, zeros on 2, a non-zero supply on 2 (these lend USDC) | **non-zero borrow or supply on 6 of 6** |
| 0x803 withdrawable vs (accountValue - marginUsed) | 43-100% | 0-11% | 0.4-42% |

- **The guard (`VaultMath.modeSuspect`)**: the vault's USDC borrow / lend state on 0x811 is non-zero. The vault never
  supplies or borrows (it never emits action 15 and has no API wallet), so a non-zero state means portfolio margin, or
  lending it did not do; in both cases the spot USDC read is 0 and borrowed USDC is not subtracted (CONTEXT evidence 3).
  An error or an empty answer reads as Standard; the call is capped at 30,000 gas so an error cannot consume the
  caller's gas. 6 of 6 portfolio-margin accounts detected, 0 of 39 Standard accounts flagged (2 of 16 unified accounts
  flagged too: they lend USDC, which the vault never does).
- **Unified mode** has no reliable footprint: the hold is invisible on the precompile, and the withdrawable ratio
  overlaps Standard accounts at high usage. The probes found it reads without double count (CONTEXT evidence 3), so
  it is covered by the pin and the monitor (`ACCOUNT_MODE`), not by the on-chain guard. The withdrawable ratio was
  rejected as a guard: it would have flagged legitimate Standard accounts in fast markets (a liveness risk) and it
  breaks the existing test harness (withdrawable 0 with equity).
- **Who can switch the mode of a proxy vault at all?** Only the vault (action 16, which it sends only with value 1),
  or Hyperliquid itself. No API wallet exists, the vault has no master key. The pin is the defence against a
  Hyperliquid-side change of what "default" means, and the guard is the defence if the pin does not land (P2).

## 5. The design

### 5.1 Contracts (`patches/proxy/HL-PROXY.contracts.patch` on origin/main; `HL-PROXY.contracts.integrated.patch` on the integrated stack)

- `HyperVault.placeOrder`: manager or the bound agent. An order that adds risk, outside a breach, runs
  `VaultGovernance.checkRisk` first; when that check puts the vault in reduce only the order is not sent and
  `OrderRefused` is emitted, so the breach stays recorded (an order in a breach that already exists reverts
  `ReduceOnlyMode`, as before).
- `VaultLogic.placeOrder`: agent allowed; TIF 1-3 for everyone (HLR2-F05); the agent sends IOC only, with a non-zero
  cloid that does not carry the Order ticket's prefix (`0xd0a1d0a1`); on the integrated stack the agent has no order
  power during the HLO-07 warm-up (`AgentWarmingUp`); no order that adds risk while `modeSuspect()`; then the
  unchanged policy check (and XF02's close band in a breach); the mode pin when due; CoreWriter action 1.
- `cancelOrder`: manager, sentinel or agent.
- `setAgent` / `initAgent`: store the agent (the factory binding check is unchanged); **no action 9**. `setAgent`
  pins the mode. `revokeAgent` still writes the burn into the named slot (harmless, defensive) and clears `$.agent`,
  which ends the agent's power in the same transaction.
- `pinAccountMode()` (new) and `syncAgent()` (kept for the executor's and integrators' ABI, same behaviour): send
  action 16 `(address(this), 1)`; vault roles (owner, guardian, sentinel, manager, operator) at any time, anyone else
  once per `MODE_PIN_INTERVAL` (10 min); nothing before the Core account exists (A-13). `settle()` pins every time;
  `checkRisk` and the agent's orders when due. New views: `modePinnedAt()`, `orderPath()` (= 1, the executor's
  marker), `accountModeSuspect()`.
- Mode guard: `checkRisk` (and so `clearLeverageBreach`, `resume`, the pre-trade check), normal and redemption-only
  `settle`, `accrueFees` revert `AccountModeMismatch` while `modeSuspect()`. Exit-only settles and reduce-only orders
  run. `HyperCore.setAbstraction` (action 16 encoder) and `borrowLendActive` (0x811, gas capped) are added.
- Storage: one `uint64 modePinnedAt` at the end of `VaultStorage` (new deployments only: clones are never upgraded).
  Sizes: section 6.

### 5.2 Should the vault keep an API wallet at all?

No. Hyperliquid's API wallets are not scoped: an approved agent signs every agent-signable L1 action (CONTEXT
evidence 1). A "cancel-only" or "scheduleCancel-only" API wallet does not exist; any API wallet has the bypass powers.
Cancels go through `cancelOrder` (action 10). `scheduleCancel` (the dead man's switch) has no CoreWriter action and is
not needed: the agent sends IOC orders only, so nothing rests.

What Hyperliquid lets an API wallet do that no contract can restrict (the reason for no API wallet): any perp or spot
order at any size within HL's oracle band, `vaultTransfer` into any HL vault, subaccount creation and transfers,
`agentSendAsset` between dexes and spot, `agentSetAbstraction` / `agentEnableDexAbstraction`, leverage and isolated
margin changes, TWAPs, `setReferrer`, `evmUserModify` (big blocks), `reserveRequestWeight` (spends perp USDC), `noop`
and order spam against the account's request budget.

### 5.3 Executor (`patches/proxy/HL-PROXY.server.patch` on origin/main; `HL-PROXY.server.integrated.patch` on the integrated stack)

- `venues/hl/contractSubmitter.ts` (new): `HlContractSubmitter` sends `placeOrder(asset, isBuy, px x 1e8, sz x 1e8,
  reduceOnly, 3, cloid)` from the agent key through `VaultChain.send` with `resign: false`; a policy refusal is the
  simulation's revert and nothing is signed; it then waits for HyperCore (`orderStatus` by cloid, 30 s) and reads the
  fills. An IOC that found nothing returns HL's retryable answer; no HyperCore answer is not retried (`CORE_NO_ANSWER`,
  X03's class closed for this path). A cloid is never sent twice: this process's record, then the vault's
  `OrderSent` logs of the last 90 blocks (a restart). `resumesInFlight = true`. `updateLeverage` sends nothing
  (CoreWriter has no leverage action; the vault's leverage cap on total notional is the bound).
- `RoutedHlSubmitter` / `readOrderPath`: a vault answering `orderPath() = 1` trades through the contract; an older
  vault (the call reverts) keeps the API wallet path only while `HL_LEGACY_API_ORDERS` (new env, default on, so the
  live vaults keep working) is on. An unreadable answer is an error, never a silent fall back.
- `venues/hl/index.ts` / `main.ts`: `hlVenue().useContractPath({ chain: realChain, ... })`; every strategy's
  `submitterFor` gets the routed submitter, behind the existing bucket fence.
- `monitor.ts`: `MonitoredVault.proxy`; on a proxy vault any HyperCore agent other than a revoke's burn is a
  FOREIGN_AGENT (act), and AGENT_NOT_ON_HL never fires; new `ACCOUNT_MODE` finding from `info userAbstraction`
  (read on the agents' rotation): anything but default / disabled acts (sentinel revoke) on an older vault and
  re-pins (`syncAgent` from the keeper) on a proxy vault. `venues/hl/info.ts`: `userAbstraction`.
- `agentSync.ts`: a proxy vault has nothing to approve; it pins the mode once and reports approved.
- `chain/contractErrors.ts`: regenerated (`npm run gen-errors`) on the stack for the new errors.

### 5.4 How the patches stack

- On origin/main: `HL-PROXY.contracts.patch` and `HL-PROXY.server.patch` apply cleanly.
- On the integrated stack (`integrated/CONTRACTS.patch` + `CONTRACTS.tests.patch`, `integrated/EXECUTOR.patch`,
  `WEBAPP-epochPlan.patch`), a 3-way apply conflicts in four places, resolved as follows and kept as
  `HL-PROXY.contracts.integrated.patch` / `HL-PROXY.server.integrated.patch` (diffs against the integrated tree):
  - `VaultLogic.placeOrder`: XF02's close band kept, then the mode pin.
  - `VaultLogic.syncAgent`: HLO-07's warm-up gate on the HyperCore approval no longer has an approval to guard; the
    warm-up now gates the agent's orders (`AgentWarmingUp` in `placeOrder`), which keeps HLO-07's rule (no agent
    power while the binding can be vetoed).
  - `VaultStorage` tail and the error list: union (`modePinnedAt` after `checkpointLagging`).
  - `main.ts` import line, `monitor.ts` deps and `FindingKind`: union with X05's `UNEXPLAINED_OUTFLOW`.
- The webapp's `epochPlan` copy is untouched (it stays byte-identical to the server's; `server/test/operator.test.ts`).

## 6. Tests and results

Proof recipe: `fixes/verify-proxy.sh` (throwaway worktrees, no links, `npm ci`). The logs below were produced by running its steps one by one in throwaways (`$TEMP/proxy-c`, `proxy-s`, `proxy-i`); the script itself was not run end to end (a full pass is two one-job builds of about 50 minutes each plus the suites). Logs: `results/proxy-*.log`.

### 6.1 Contract fix tests (`tests-proxy/HLPROXY.fix.t.sol`, 16 tests): 16 / 16 on both trees

`results/proxy-main-fix.log` (origin/main + `HL-PROXY.contracts.patch`) and `results/proxy-stack.log` (integrated
stack + `HL-PROXY.contracts.integrated.patch`):

| Test | Proves |
|---|---|
| `test_PROXY_agentOrderGoesThroughThePolicyCheckedPath` | the agent's order is CoreWriter action 1 with the exact fields, `OrderSent`, no action 9 |
| `test_PROXY_policyViolatingAgentOrdersRevert` | leverage, price band, asset not allowed, spot, notional cap: each reverts `OrderRejected(reason)` for the agent |
| `test_PROXY_agentIsIocOnlyWithItsOwnCloid` | the agent: IOC only, cloid required, never the ticket prefix; TIF 1-3 for everyone (F05); the manager keeps GTC and the ticket |
| `test_PROXY_onlyManagerAndAgent_revokedAgentLosesThePath` | strangers and the sentinel cannot place; a revoke ends the agent's power in the same transaction |
| `test_PROXY_agentCancels_strangerCannot` | action 10 by the agent; strangers refused |
| `test_PROXY_breachedVault_agentReducesButCannotOpen` | in a risk breach: opens revert `ReduceOnlyMode`, reduce-only goes through |
| `test_PROXY_preTradeRiskCheckRefusesAnOpenAndKeepsTheBreach` | a 10% loss nobody checked yet: the agent's open runs checkRisk, is refused (`OrderRefused`), the breach is stored, no action 1 |
| `test_PROXY_setAgentApprovesNothingOnHyperCore` | agent change: no action 9, one action 16 |
| `test_PROXY_noEntryPointGivesTheAgentApiWalletPowers` | every HyperCore-writing entry point once: only ids 1, 7, 10, 13, 16; every 16 is `(vault, 1)`; the revoke's 9 names a burn, never the agent |
| `test_PROXY_factoryHostedVault_agentBoundOnTheFactory_tradesThroughTheVaultOnly` | a factory launch with a registrar-signed agent: `orderPath() = 1`, the agent trades through the vault, nothing is approved; on the stack it is refused `AgentWarmingUp` until HLO-07's window ends |
| `test_PROXY_action16EncodingIsByteExact` | `01 000010` + vault + `1`, built word by word |
| `test_PROXY_pinIsRateLimitedForStrangers_freeForRoles` | strangers once per 10 min, roles any time, `checkRisk` pins once per interval |
| `test_PROXY_noPinBeforeTheCoreAccountExists` | no action before the Core account exists (A-13) |
| `test_PROXY_modeGuard_portfolioMarginFootprintStopsPricingAndOpens` | with a USDC borrow / lend state on 0x811: checkRisk, normal settle, accrueFees and opens revert `AccountModeMismatch`; reduce-only and the platform's re-pin work; the emergency (exit-only) settle pays; pricing resumes when the state is gone |
| `test_PROXY_modeGuard_precompileErrorOrNoStateIsStandard` | an erroring 0x811 (mainnet's answer without state) reads Standard, and its gas is capped |
| `test_PROXY_gas_agentOpenWithPreTradeCheck_andReduce` | gas (mock precompiles): open 507,599 (stack 510,313), reduce 305,521 (stack 307,978) |

Sizes (EIP-170 24,576): origin/main + patch: HyperVault 17,887, VaultLogic 18,497, VaultGovernance 11,820 (before:
17,156 / 17,379 / 11,483). Stack: HyperVault 18,260, VaultLogic 19,509, VaultGovernance 12,357, GainsVault 19,037.

### 6.2 Contract suites

- **origin/main + patch** (`results/proxy-suite-post.txt`, Gains removed in the throwaway): 36 suites, 267 passed,
  17 failed, 2 skipped. The same suite files without the patch: all green (`results/proxy-main-baseline.log`).
- **Integrated stack + patch, one job with Gains** (`results/proxy-stack-suite.txt`, `results/proxy-stack.log`;
  build 3,166 s; the EIP-170 messages are the five test handlers, as in the integration's own build): 142 suites,
  846 passed, 43 failed, 24 skipped. 43 = the integration's 17 superseded PoCs (its `SUPERSEDED` list, unchanged)
  + 23 superseded by HL-PROXY (table) + 2 that fail on the integrated tree without HL-PROXY (below) + 1 HL-PROXY fix
  test that ran from a stale copy during the suite (re-run: 16 / 16, `results/proxy-stack.log`).
- **Failing tests HL-PROXY supersedes, by design** (they assert the old agent model):

| Test(s) | What they assert | Why it no longer holds |
|---|---|---|
| `HyperVault.t.sol::test_SetAndRevokeAgent`; `PolicyAndFactory.t.sol::test_AgentRecordedAtInitAndApprovedBySync`, `test_SyncAgentIsPermissionlessAndCannotChangeTheAgent`; `Verify5PoC::test_VERIFY5_syncSendsOnlyTheStoredAgent`; `HlR2Encoding::test_HLR2_ENC09_syncAgentReproducesLivePlatformVaultBytes`; `HlR2FundFlow::test_HLR2_F01_agentApprovalHasNoExpiryFieldAndOnlySyncAgentRenews` | `setAgent` / `syncAgent` send action 9 for the agent | they send action 16; no approval exists (the point of the fix) |
| `PolicyAndFactory::test_SyncAgentRefusedWithoutAgentOrWhileReduceOnly`; `Round4::test_GuardianBreachAndEmergencyAreFullStops`; `Verify5PoC::test_VERIFY5_breachAndEmergencyGate`, `test_VERIFY5_noSyncAfterAnyRevoke`, `test_VERIFY5_syncThenRevokeSameBlock`; `HLO-07.fix::test_HLO07_fix_leakedRegistrarLaunchIsInertUntilVetoed` | `syncAgent` reverts without an agent, in a full stop, after a revoke, in the HLO-07 warm-up | `syncAgent` only pins the mode, which is safe in every state; the HLO-07 warm-up now gates the agent's orders (`test_PROXY_factoryHostedVault_...` on the stack) |
| `Round4::test_LeverageBreach_reduceOnly_agentKept_clearedByAnyoneOnceBackUnder`; `Verify5PoC::test_VERIFY5_repeatedSyncCost`; `HlR2Encoding::test_HLR2_ENC_onlyIds_1_7_9_10_13_andNoForeignAddress`; `HostileConfig::test_HLR2_C_strangerCallsOnARealVault` | a stranger calls `syncAgent` repeatedly, or the id set excludes 16 | strangers may pin once per 10 minutes (P3), `NotReady` otherwise; 16 is a new id |
| `Reaudit2Invariants` (2), `VerifyMixedInvariants` (2): "syncAgent misbehaved (A-13)" | the handler's ghost expects action 9 from `syncAgent` | as above |
| `AuditPoC::test_AUDIT_M04b_placeOrderChecksProjectedLeverage` | `writer.count() == 1` after one order | checkRisk and settle now pin (two action 16 before the order); the leverage check itself still refuses the 1M order |
| `HlR2Encoding::test_HLR2_F05_placeOrderForwardsUndefinedTif` | the F05 PoC: TIF 4 is forwarded | fixed: `OrderRejected("tif")` |
| `Reaudit2PoC::test_REAUDIT2_N201_claimGasIsConstantAcross1000EmergencyEpochs` | 1,000 emergency settles within the default 1.07e9 test gas | each settle now pins (one more mock CoreWriter storage write); with an 8e9 budget it passes and the claim gas stays constant (144,001 at 50 and at 1,000 epochs, `results/proxy-stack.log`): a test-budget artifact, not a property change |

- **Failing on the integrated tree without HL-PROXY** (`results/proxy-integ-baseline.log`, the integration patches
  alone): `MutMisc::test_HLR2_M41_kills_agentSlotGuards` and `MutTimelock::test_HLR2_M72_kills_timelockedSetterBounds`
  (`NotReady` instead of `CallFailed(ZeroAddress)`; consistent with: the mutation tests execute a timelocked call after the old 2-day
  delay, which H01's notice / deadline eta now pushes out). The integration's suite did not contain the `mut` suites, so
  its `SUPERSEDED` list misses them; reported to the lead, not touched here.

### 6.3 Executor

- **origin/main + `HL-PROXY.server.patch`** (`results/proxy-server-main.log`): HL-PROXY fix tests 14 / 14; the
  touched files (monitor x3, agentSync, executor, keeper-venue, hlo02-attribution) 43 / 43; `tsc` clean. Whole
  server suite: 989 passed, 3 failed: `contract-errors` x2 (the generated error list needs the new errors; it is
  regenerated on the stack, which has the Gains artifacts the generator reads) and `startup`'s wall-clock bound
  (load dependent, as in EXECUTOR.md).
- **Integrated stack + `HL-PROXY.server.integrated.patch`** (`results/proxy-server-stack.log`, with
  `contractErrors.ts` regenerated, 208 errors): HL-PROXY fix tests 14 / 14; fixC + integration fix tests 89 / 89;
  cross-review fix tests (the integrated copy) 4 / 4; the integration's touched set + hlo02-attribution +
  contract-errors 469 passed, 3 skipped; `tsc` clean. The webapp's `epochPlan` copy is not touched.
- What the executor tests (`tests-proxy/HLPROXY.proxy.test.ts`, 14) prove: the vault transaction carries the policy
  fields with `resign: false`; a policy refusal signs nothing and is not retried; `OrderRefused` is an error; an IOC
  miss is retryable; no HyperCore answer is not retried and the cloid is never sent twice; a restart finds the cloid
  in the vault's `OrderSent` logs; `updateLeverage` sends nothing; `Executor.execute` end to end FILLED through the
  vault; routing (proxy -> contract, an older vault only with the legacy flag, an unknown path never falls back);
  `hlVenue` with the contract path sends the agent's order to the vault; the monitor (any agent on a proxy vault is
  foreign, the burn is tolerated, no AGENT_NOT_ON_HL, ACCOUNT_MODE pins on a proxy vault and revokes on an older one);
  agentSync on a proxy vault pins once and never waits for a HyperCore approval.

## 7. Residual risk: what an agent key can still do

- Trade curated main-dex perps within the policy, like the manager: leverage after the order, notional cap, 1% band.
  Against a counterparty the thief controls, each round trip transfers at most about the band (1%) plus fees of the
  notional, repeatable; the pre-trade risk check stops new risk once the day's loss passes `maxDailyLossBps` (20% on
  The platform vault) and the drawdown limit (50%). On BTC / ETH / SOL the books make this expensive for the thief (KEYS (d)), but
  the bound is the policy's daily loss, not zero. Follow-up F5: a turnover budget and an order-rate cap (Gains' list).
- Reduce-only orders and cancels at any time, also in a breach (they cannot add risk but can crystallise a loss at
  the band).
- Spend its own HYPE gas; send orders that revert (EVM only, no HyperCore action).
- Spend the vault's HyperCore request budget with orders (if CoreWriter actions count, P3): delays later CoreWriter
  actions (flatten, bridges), not a revoke (EVM state).
- Nothing else: no transfer, no other dex, no spot, no subaccount, no HL vault, no mode change, no leverage setting.

## 8. Follow-ups

- **F1** Testnet broadcast of action 16 from a contract (value 1 on a default account, and with an open position) and
  of a revoke-free proxy vault's first order, before mainnet (P2).
- **F2** Live vaults: they cannot get this code. The platform vault (platform money) moves to a vault from a factory deployed with
  the patched implementation; until then, `HL_LEGACY_API_ORDERS` keeps them on the API path and the new ACCOUNT_MODE
  monitor finding revokes on a mode switch. An interim option without a redeploy (not patched): a small forwarder
  contract set as the vault's manager through the 2-day timelock, which lets the agent EVM key call only
  `placeOrder` / `cancelOrder`, followed by `revokeAgent`; it trades through the manager-only path today (no pin, no
  guard; the manager's other powers must stay with the owner).
- **F3** A lean HyperEVM sender for orders (pre-estimated gas limit, cached fees, local nonce: one round trip)
  halves the extra latency (section 3.3).
- **F4** Webapp and docs: the "a few seconds" copy for contract orders (`OrderTicket.tsx:211`, `docs/managers.tsx`,
  `RunPage.tsx`, `Platform.tsx`) says 0.4 s on mainnet today; the "approved agent key" advice goes away with the proxy.
- **F5** Gains-style order-rate cap and daily turnover budget in `placeOrder` for the agent.
- **F6** Factory and launch flow: the factory's agent binding is unchanged; the launch wizard's text about approving an
  API wallet and the "agent approved on Hyperliquid" status need a new wording for proxy vaults.
- **F7** Agent gas: the agent wallet now needs HYPE on HyperEVM (about 2e-5 HYPE per order); the keeper's gas budget
  should top it up as Gains' factory does for Arbitrum.

## 9. Unproven

- Action 16's acceptance from a contract and its behaviour with open positions (P2, F1).
- The CoreWriter delay in big blocks (no sample) and under load (one 5-hour sample).
- The API path's latency (docs figure, P4).
- Whether CoreWriter actions count against the address request budget (P3).
- The guard's coverage of unified mode (none on chain, section 4).
