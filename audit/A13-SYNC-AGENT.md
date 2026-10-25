# A-13: agent approval dropped at creation, `syncAgent()`

Date: 2026-10-06. Observed on mainnet with a factory vault, an earlier deployment (own signals,
launched through the wizard): the Core account was activated by the seed (1 USDC fee, 1 USDC + 0.01 HYPE on spot),
`agent()` on chain is set (the agent of an earlier deployment), but Hyperliquid's `extraAgents` stayed empty.
The `addApiWallet` action is sent in the same transaction as the deposit that creates the Core account, and HyperCore
drops actions from an account that does not exist yet. The legacy vault's approval worked because it was a separate
transaction after activation. This confirms the A-13 assumption flagged in REPORT.md section 6.

## Change (implementation, needs a redeploy of the implementation and the factory)

- `VaultLogic.initAgent($, agent)`: used by `initialize` only. Validates and stores the agent (same checks as
  `setAgent`: non zero, bound to this vault on the factory) and emits `AgentSet`, without the HyperCore action.
- `VaultLogic.syncAgent($)`: re-sends `addApiWallet(agent, "dojipad")` for the **currently stored** agent. Callable by
  anyone. Reverts `ZeroAddress` when no agent is stored and `ReduceOnlyMode` while breached or in emergency (the agent
  must stay revoked there). Emits `AgentSynced(agent)`. It cannot change who the agent is.
- `HyperVault.syncAgent()` external wrapper. `setAgent` (timelocked rotation) still stores and approves in one call,
  which is fine after activation.
- Size: HyperVault 15,321 B (9,255 B headroom). VaultLogic 14,36x B.

## What the audit window should check

1. `syncAgent` has no authorisation and no parameters: confirm it cannot be used to approve any address other than
   `$.agent`, and that `$.agent` is only written by `initAgent` / `setAgent` (both bound to the factory registry) and
   `_revokeAgent`.
2. Breached / emergency gate: a vault whose agent was revoked has `agent == 0`, so `syncAgent` reverts; a breached
   vault with a non zero agent cannot exist (breach revokes), but the gate is there for a clear-then-sync race.
3. The HyperCore name slot semantics: `addApiWallet(agent, "dojipad")` replaces the previous "dojipad" slot, so a
   sync after a revoke-and-re-set cannot resurrect an old key (the stored agent is the only value ever sent).
4. Re-sending the approval for an already approved agent is a no-op on HyperCore (same address, same name).
5. Gas griefing: anyone can call `syncAgent` repeatedly; each call is one CoreWriter action paid by the caller. The
   only effect on the vault is the Core gas (HYPE) spent by the vault's Core account per action, bounded by the
   vault's HYPE balance; the monitor alerts on low HYPE.

## Executor and webapp

- `server/src/agentSync.ts`: after a tenant is bound, polls `extraAgents` (5 x 2 s); if the stored agent is missing
  and `vault.agent()` still equals it, calls `syncAgent()` from the keeper wallet and re-checks (10 x 3 s); alerts on
  every outcome. The monitor raises `AGENT_NOT_ON_HL` for served vaults whose stored agent is absent on HyperCore and
  triggers the same sync.
- `/health` lists every active tenant with `approvedOnchain` and `approvedOnHl`, like the static strategies;
  `/api/launch/status/:vault` returns both flags.
- The wizard waits for `approvedOnHl` before calling the vault live; the Manage page's agent card shows the
  Hyperliquid approval state and a "Sync agent" button (anyone).

## Tests

- `test_AgentRecordedAtInitAndApprovedBySync`, `test_SyncAgentIsPermissionlessAndCannotChangeTheAgent`,
  `test_SyncAgentRefusedWithoutAgentOrWhileReduceOnly` (HyperVault.t.sol); `test_AUDIT_L06_*` rewritten: no
  HyperCore action for the agent inside the creating transaction, one after `syncAgent`.
- Invariant handler action `syncAgent` with the ghost "sync changed the agent" in the round 2 suite.
- Server: `test/agentSync.test.ts`; monitor test for `AGENT_NOT_ON_HL`.
