# hl-open: executor-side fixes

Branch `fix/hl-open` from `origin/main` 726378d, with the review's commits (`audit/hl-open`, audit and test folders
only). Scope: server, webapp and docs. No contract change: the contract findings (HLO-01 on chain, HLO-02 on chain,
HLO-03, HLO-06, HLO-07, HLO-08) go into round 2. HLO-E02, E03 and E08 (read budgets and coverage) are solved in the
next task by moving reads to the RPC provider; nothing here changes how reads are made, only which reads a job asks for.

Every executor PoC in `executor/` was turned into a regression test of the fix, and each was run with the fix's
source file(s) put back to the old code: the new cases fail there and pass on the fix. Cases kept as guards (the
behaviour that must not change) pass on both, as noted.

## Fix table

| Finding | Fix | Regression test | Old code |
|---|---|---|---|
| **HLO-E07** OTHER_DEX revoke on 1 USD from anyone | `monitor.ts`: OTHER_DEX acts (sentinel revoke) only when the vault's own cash fell by at least 98% of the other-dex increase since the previous look. Cash means dex 0 perp minus unrealized PnL, plus spot USDC, so a price move cannot pass for a transfer. An inbound credit, a balance already there at the first look, or a falling mark: alert only. (397239a) | `executor/E07-other-dex-revoke.test.ts` (4) | 3 fail (it revoked); the 900 USD moved-out case is a guard |
| **HLO-E05** alert floods, stranger text, lost alerts | `alerts/<channel>.ts`: a queue with a rate limit (18 a minute, 1 a second), priority (BREACH, revoke, RISK WATCHER DOWN / BLIND, OUTAGE, foreign agent first, then error, warn, info), coalescing per kind ("312 vaults: withdrawals paid"), a retry on 429 using the alert channel's `retry_after`, overflow drops the least urgent and reports the count. Platform alerts carry the address plus an operator label (strategy or tenant mode), never the vault's on-chain name (epoch, settlement, fees, NAME GUARD). Epoch-ready and withdrawals-paid notices go to the vault's own manager alerts (type "epoch"); the platform gets one coalesced line. NAV_MOVE needs a minimum equity setting on either look. (4bf2b41, 95a6f37) | `executor/E05-alert-flood.test.ts` (5), `server/test/<channel>-queue.test.ts` (2) | 5 / 5 fail |
| **HLO-E06** unreserved platform agent accepted silently | `tenants/launch.ts`: an error alert ("PLATFORM AGENT NOT OURS") on a VaultCreated whose non-zero agent no reservation issued (tenant stays MANUAL, audit row `unreserved_agent`). The indexer now decodes `PlatformAgentRegistered`; a binding no reservation names, or an unbinding the executor did not send, alerts. The executor's own unregisters (sweep, conflict) are marked in the store first. One alert per agent. (fc02fe3) | `executor/E06-unreserved-agent.test.ts` (4) | 4 / 4 fail |
| **HLO-E04** unreadable vault = one checkRisk per vault per hour | `keeper.ts`: unreadable vaults are decided after the round. Nothing to protect means no transaction: no outside deposits, under MIN_RISK_NAV with no positions at the last read, or (never read) an on-chain NAV under it. The rest go out at most 5 per round and 20 per hour (both configurable), vaults with positions first. 5 or more unreadable and at least half of those visited is one OUTAGE alert, with the per-vault alerts paused. "Outside deposits" (`tenants/outside.ts`): a non-cancelled deposit request from a controller other than the owner and manager. (3871aff) | `executor/E04-keeper-unreadable.test.ts` (5), `server/test/outside-deposits.test.ts` (2) | 4 fail; the readable case is a guard |
| **HLO-E01** global registrar budget exhausted for free | `tenants/launch.ts`: reservation budgets per wallet (3 an hour) and per IP (10 an hour), counted in the database (`launch_reserves`, 24 h TTL), shared by every instance and kept over a restart. The global hourly cap applies only to a registrar that pays a transaction per reservation. A reservation needs the wallet's USDC on the factory's chain to be at least the factory's `minSeedUsdc` (403 otherwise). (d20496b) | `executor/E01-registrar-budget.test.ts` (4) | 3 fail; the transaction-registrar cap is a guard |
| **HLO-E10** platform HYPE per stranger vault | `feeAccruer.ts`, `treasury/operator.ts`: no accrueFees and no keeper-operator run for a vault without outside depositors (its owner settles it), and no fee-only settle or accrual on a zero management fee. `gasBudget.ts`: every mined executor transaction is charged to its job (gasUsed × effectiveGasPrice). Fees and the operator stop for the UTC day at the fee job's daily gas budget (0.05) / the operator's daily gas budget (0.25), with one alert each. The keeper's budget (0.25) only alerts and never stops a checkRisk. (244b4db) | `executor/E03-rpc-bucket.test.ts` E10 cases (2), `server/test/gas-budget.test.ts` (3) | 2 / 2 fail |
| **HLO-01** `vaults()` breaks a capped `eth_call` at 865 vaults | No factory `vaults()` anywhere. Webapp, server and scripts read `vaultCount()` and then the `_vaults` array with paged `eth_getStorageAt`. The slot is per factory build, verified read-only on chain 2026-10-19: round 4 and round 3 slot 15 (matches `vaults()`), the deployed Gains factory slot 16, current sources HL 15 / Gains 18. The length must equal `vaultCount()`, else it fails closed. The executor's factory ABI drops `vaults()`. (cc7afce, 8153276, e5a0fad) | `webapp/src/data/factoryVaults.test.ts`, `server/test/factory-vaults.test.ts` (6), guard tests over src and scripts | the guard tests fail with the old `chain.ts` / script |
| **HLO-02** impersonation (executor and UI half) | `/vaults` and `/api/launch/status` serve `hosted` from the executor's tenant (a bound, active HOSTED_SIGNALS launch; the chain flag as `chainHosted`) and a `consent` flag. Consent means a bound reservation (owner = manager = the signer) or an owner-signed profile by that owner. The public Depositors tab names the owner / manager wallets only with consent. The webapp's dashboard badge and Manage's hosting card take "Hosted by DojiPad" from the tenant (Leave hosted stays on the flag, an on-chain action). A vault naming the wallet that it never signed for is marked "Not launched by you". (23721a6, df9ad5b) | `server/test/hlo02-attribution.test.ts` (3), `webapp/src/data/attribution.test.ts` (5) | the impersonation route case fails |
| **Docs** (REVIEW.md 6.3) | KNOWN-ISSUES I3-02, I3-04, I3-05, SCOPE.md, the README lines, REVIEW-SUMMARY sections 1 and 6, the `Deploy.s.sol` MAX_DEPOSIT_CAP comment (comment only), and the site's review sentence, all set to the live configuration (open launch, no platform cap). (b071c0b, c2fdf9a) | webapp suite | n/a |

Not changed, by design: HLO-E02, E03, E08 (next task, reads through the RPC provider). Their PoCs and the E09 precision checks are unchanged
and still pass. The executor-only PoC count is now 9 files and 37 tests (was 27).

## Outside depositors and platform-run vaults (precise)

- **Outside depositor** of a vault: a wallet with a deposit request on it (a `DepositRequested` the indexer recorded,
  any epoch, not cancelled) that is neither the vault's owner nor its manager (the tenant record, from `VaultCreated`).
  Shares received by an ERC-20 transfer, and the fee recipient's or protocol treasury's fee shares, do not count
  (`server/src/tenants/outside.ts`).
- **Platform-run vault**: a vault the executor serves (hosted platform strategies, own signals, copy: the
  registry's served tenants), a `strategies.json` vault, or an address in a configured list (both chains).
  It always gets its settles, fee accruals, checkRisk and risk reads: none of the E04 / E10 skips, caps or gas budgets
  apply to it (`platformRunCheck`, `protectsVault`; regression `server/test/platform-vaults.test.ts`: a platform strategy with only
  the owner's deposit, a zero fee and the budgets spent still gets its daily settle, its accrual, a risk read every
  round and its hourly backstop checkRisk).
- The skips apply only to every other vault without an outside depositor.

## Behaviour changes operators should know

- **Alert channel:**
  - Alerts wait in a queue, at most 18 a minute.
  - Urgent ones go first.
  - Same-kind messages that waited arrive as one "N vaults: …" message.
  - Vault names no longer appear; the address and a label do.
- **Manager alerts:** epoch-ready and withdrawals-paid notices reach a manager only through their own manager alerts (type "Epochs").
- **Keeper:**
  - A vault that is neither platform-run nor holding outside deposits gets no backstop checkRisk while unreadable.
  - Unreadable sends are capped at 5 per round and 20 per hour.
  - An "OUTAGE" alert replaces many per-vault alerts.
- **Fee accrual and the treasury operator:**
  - They skip vaults that are neither platform-run nor holding outside deposits; such a vault's owner settles from Manage.
  - Each job stops for the day at its HYPE budget, except for platform-run vaults.
- **Launch reservations:**
  - At most 3 per wallet and 10 per IP an hour.
  - The launching wallet needs the seed USDC.
- **Sentinel:** OTHER_DEX revokes only on value that left the vault's own account; anything else alerts.
- **New executor settings (defaults in the executor's configuration):** the keeper's unreadable-vault limits per round and per hour, the reservation budgets per wallet and per IP, and the daily gas budgets of the fee, operator and keeper jobs. The hosting configuration was not changed; the defaults apply.

## Left open

- **Data retention:** `terms/retention.ts` still counts a vault that names a wallet as that wallet's "last use". It errs on keeping data. Keying it to consent could delete the records of a real owner who launched a MANUAL vault without a reservation or a profile.
- **Manager consent:** a manager who is not the owner has no way to sign consent. Such a vault shows "Not launched by you" to the manager until the owner and manager are the same wallet.
- **Round 2 (contracts):** `owner == msg.sender` at create (HLO-02), the policy envelope (HLO-03), the creator co-signature (HLO-07), and the Safe (HLO-08).

## Gate

Run on a fresh clone of the branch (17665b9), `npm ci` in each package.

| Gate | Result |
|---|---|
| Server `npm test` | 937 passed, 0 failed, 7 skipped (84 files), plus startup 2 / 2. `tsc --noEmit` clean. The contract-errors check skips without forge artifacts in a fresh clone (no contract change on this branch). |
| hl-open executor PoCs (`executor/vitest.config.mjs`) | 9 files, 37 passed, 0 failed |
| Webapp `npm test` | vitest 326 passed, 0 failed, 6 skipped (50 files); Playwright smoke 8 / 8. `tsc -b` clean. |
