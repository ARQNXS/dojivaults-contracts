# Fix list (prioritised, implementation-ready)

Do not apply blindly: each fix lists the functions to change and the tests that must pass afterwards. Each PoC in
`test/audit/AuditPoC.t.sol` is written to PASS while the bug exists. After the fix, **invert its final assertions,
or replace it with an `expectRevert`**, keep it as a regression test, and re-run the invariant suite.

**Size budget.** HyperVault has 171 B of EIP-170 headroom. Before starting, move the read-only surface (`preview*`,
`convertTo*`, `max*`, `claimable`, `pendingRequest`, `epochOverdue`, `coreActive`) into a `HyperVaultLens` contract
and keep only what settlement needs in the vault. Check `test_ImplementationFitsEip170` after every fix.

Global regression gate after every fix:
`forge test` (baseline 88 + audit) and `forge test --match-path test/audit/invariants/VaultInvariants.t.sol`.

---

## 1. C-01 (Critical): NAV deflation via agent
**Change**
- `coreEquity()`: either (a) add every non-zero spot token valued at the spot mark (needs a token list owned by the policy, read via precompile 0x801 and spot px 0x808), plus the account value on every perp dex the vault could hold collateral on; or (b) cheaper and recommended for v1: make `settle()` revert when the view may be incomplete. Store a `navCheckpoint` (NAV + timestamp) on every `checkRisk()` and `settle()`. In `settle()`, revert if `breached`, or if `|nav - navCheckpoint| > policy.maxNavMoveBps` (new policy field, tighten-only rules apply).
- `settle()`: price deposits at `max(nav, navCheckpoint)` and redemptions at `min(nav, navCheckpoint)` within the epoch (conservative for incumbents).
- `requestDeposit()`: reject when `controller` or `msg.sender` is `manager`, `owner()` or `feeRecipient`. Deeper fix: manager deposits wait one extra epoch.
- Plus H-01 below (timelocked `setAgent` / `clearBreach`).

**Tests that must pass**
- `test_AUDIT_C01_*` inverted: `settle()` reverts after the 90% NAV drop (or Mallory's value <= what she paid + rounding).
- New: settle succeeds after a legitimate NAV move below `maxNavMoveBps`.
- Invariant suite: add the handler action "agent moves X% to an unseen dex" and the invariant "no depositor's value grows by more than NAV growth".

## 2. H-01 (High): Owner instantly disarms controls
**Change**
- Add `clearBreach`, `exitEmergency`, `setAgent`, `setGuardian` to the `queue()` whitelist; make them `onlySelf` (and `leaveHosted` stays owner-only, since it only lowers risk). Keep `revokeAgent`, `triggerBreach`, pauses and `disallowAsset` instant.
- `clearBreach()`: do not reset `peakSharePrice`. Add `lifetimePeak` and breach on `maxDrawdownBps` measured from it.
- `exitEmergency()`: revert while `pendingRedeemShares > 0`.
- Optional: override `renounceOwnership` to revert (I-03).

**Tests that must pass**
- `test_AUDIT_H01_*` inverted: a direct `clearBreach()`/`setAgent()` reverts `Unauthorized`; via queue it works only after the delay.
- `test_AUDIT_H01b_*` inverted: `exitEmergency()` reverts with redemptions pending.
- Existing `test_SetAndRevokeAgent`, `test_SwitchingAgentNameRevokesOld` updated to go through queue/execute.

## 3. H-02 (High): Bridge window re-arm blocks settle
**Change**
- `bridgeToEvm()` / `bridgeToCore()`: `require(amount >= MIN_BRIDGE || amount == fullAvailable)` with `MIN_BRIDGE` e.g. 100 USDC.
- `bridgeToEvm()` by non-manager (emergency): allowed at most once per `BRIDGE_SETTLE_BLOCKS * k` blocks, and only for `amount >= min(available, MIN_BRIDGE)`.
- `settle()`: do not revert in-window when the epoch is overdue or in emergency. Price with `pendingToCore` excluded and `pendingToEvm` excluded (conservative lower NAV) **for redemptions only if liquidity suffices**. Alternatively, record `bridgeStartBlock` and allow settle once `block.number > bridgeStartBlock + MAX_WINDOW_EXTENSION` regardless of later bridges.

**Tests that must pass**
- `test_AUDIT_H02_*` inverted: `bridgeToEvm(1)` reverts; settle succeeds within 11 blocks of the rescue bridge.
- Existing bridge tests (`test_DepositsFundRedemptionsInSameEpoch`, `test_SettleRevertsWithoutLiquidity`, bridge window tests) still pass.

## 4. M-01 (Medium): checkRisk in-flight double count
**Change**
- In `_depositToCore`/`bridgeToEvm`, store `equityAtBridge = idleAssets() + coreEquity()` **before** the transfer.
- `checkRisk()`: when `inFlight`, use `equity = equityAtBridge + subsequent PnL estimate`. Simplest correct version: `equity = equityAtBridge` for the daily/drawdown checks, and skip the `riskDay` rollover baseline update while in flight (defer to the next out-of-window call).
- `totalAssets()` (L-04): return `max(idle + core, equityAtBridge)` only if needed; prefer `idle + core` (no add-back) and rely on settle/accrue being blocked.

**Tests that must pass**
- `test_AUDIT_M01a_*` inverted: breach fires inside the ping-pong.
- `test_AUDIT_M01b_*` inverted: no breach, `dayStartEquity` == 1,000,000e6.
- `test_AUDIT_L04_*` inverted: `totalAssets()` == 1,000,000e6 in window.

## 5. M-02 (Medium): Retroactive fee raise
**Change** `setFees()` (the `onlySelf` path): `if (bridgeInFlight()) revert BridgeInFlight();` before `_setFees`. `lowerFees` keeps the current behaviour.
**Tests** `test_AUDIT_M02_*` inverted: `execute(data)` in-window reverts `CallFailed(BridgeInFlight)`; the honest path is unchanged.

## 6. M-03 (Medium): Timelocks never expire
**Change**
- HyperVault: `GRACE_PERIOD = 14 days`; `execute()` reverts `Expired` if `block.timestamp > eta + GRACE_PERIOD`.
- VaultPolicy: same check in `applyPendingConfig()`, `allowAsset()`, `applyTimelockDelay()`. Store `pendingTimelockEta` semantics unchanged.

**Tests** `test_AUDIT_M03_*` inverted (all three apply calls revert after 365 days). `test_LooseningIsTimelocked`, `test_AssetAllowlist`, `test_TimelockDelayLoweringIsTimelocked` still pass (they apply right at eta).

## 7. M-04 (Medium): Contract-path trading limits
**Change**
- `flatten()`: custom `slippageBps` capped at `max(policy.maxSlippageBps(), policy.maxFlattenSlippageBps())` (new policy field, tighten-only), not the 2,000 constant.
- `placeOrder()`: for `!reduceOnly`, read `accountMarginSummary` and require `(ntlPos + notionalAtMark) * BPS <= maxLeverageBps * accountValue`.
- `VaultPolicy.checkOrder` (L-01): notional at `max(limitPx, markPx1e8)`.

**Tests** `test_AUDIT_M04a_*`, `test_AUDIT_M04b_*`, `test_AUDIT_L01_*` inverted. Existing `test_ReduceOnlyMayCloseNonAllowlistedAsset` and the flatten/placeOrder tests pass.

## 8. M-05 (Medium): Perf fee on transient highs
**Change** Split `_accrueFees(bool withPerformance)`. External `accrueFees()` and `_setFees` accrue management only. `settle()` accrues both. Optionally compare HWM against the lower of current price and the last settle price.
**Tests** `test_AUDIT_M05_*` inverted (no fee shares minted by the external call). The invariant fee cap still holds; fee tests in `HyperVault.t.sol` that call `accrueFees()` for performance fees need updating to settle.

## 9. L-02 (Low): Previews
**Change** Add `_previewFeeShares()` (view, same math as `_accrueFees` without minting) and use `supply + feeShares` in `_convertTo*` for previews. If bytes do not allow it, document that previews exclude unaccrued fees and expose `previewSettle()` in the lens.
**Tests** `test_AUDIT_L02_*` inverted (equality).

## 10. L-03 (Low): Fee dilution as drawdown
**Change** In `_accrueFees`, after minting: `peakSharePrice = peakSharePrice * newPrice / priceBeforeFees` (only if it lowers it).
**Tests** `test_AUDIT_L03_*` inverted.

## 11. L-05 (Low): Negative perp equity
**Change** `coreEquity()`: `int256 e = int256(m.accountValue) + int256(spotUsd); equity = e > 0 ? uint256(e) : 0;`
**Tests** `test_AUDIT_L05_*` inverted (200,000e6).

## 12. L-06 (Low): Agent before account
**Change** In `initialize`, move `if (p.agent != address(0)) _setAgent(...)` after `_seedCore` and `_fundCoreGas`.
**Tests** `test_AUDIT_L06_*` inverted (deposit Transfer log precedes RawAction). Also check on testnet: launch with an agent, then `extraAgents` lists it.

## 13. Info
- I-01: `emit ProtocolShareLowered(newBps)` in `HyperVault.lowerProtocolShare` (if bytes allow).
- I-03: `renounceOwnership` override reverting.
- I-05: sweep dust: after the last claim of an epoch, release the remainder of `claimableRedeemAssets` (needs a per-epoch outstanding counter). Low priority.
- I-06: factory: enforce `guardian == platformGuardian` (or add a second immutable platform guardian role in the vault) and validate `assets` against a factory-level curated allowlist.

## Server (from server/test/audit/SERVER_FINDINGS.md), in priority order
1. **S-01 High**: in `app.ts` `/signal`, resolve only static strategies (`strategies.get`); never fall through to `registry.get` for tenant-derived names. Test `AUDIT_S1_*` inverted.
2. **S-02 Medium**: keeper iterates registry tenant vaults as well as static ones for `checkRisk()`. Test `AUDIT_S2_*` inverted.
3. **S-03 Medium**: bind a reservation to `(agent, expected owner/manager = reserving wallet)` and verify `VaultCreated.owner/manager` and `tx.from` before binding. Test `AUDIT_S3_*` inverted.
4. **S-05..S-12 Low**: re-check `hosted()` and `agent()` at order time; bind each stored agent key to its tenant and verify the key's address when it is loaded; `trust proxy` set to the actual hop count; auth on `/tickets`, `/executions`, `/positions`; reject expired reservations at bind time; use `min(policy, default)` slippage on close fallback; send boot re-queues through the tenant guard.
5. **S-13..S-17 Info**: harden the key-encryption parameters, make claim atomic (findOneAndUpdate), expire claim tokens after bind, production CORS default empty, indexer confirmation depth.
