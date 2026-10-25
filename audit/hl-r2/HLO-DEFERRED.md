# hl-r2: the hl-open contract findings deferred to round 2

**This is an internal, AI-assisted review. It is not an independent audit and must not be presented as one.**

hl-open (`contracts/audit/hl-open/REVIEW.md`, FIXES.md "Left open") deferred HLO-02 (on-chain half), HLO-03, HLO-06,
HLO-07 and HLO-08 to round 2. Each is re-tested here on the current `contracts/src` (unchanged since the round 4
deploy). PoCs are in `contracts/test/audit/hl-r2/hostile/HloDeferred.t.sol`; all pass on the current code:

```
cd contracts && forge test --match-path "test/audit/hl-r2/hostile/*" -vv
```

| ID | Verdict on current code | Re-rated | PoC (passes) |
|---|---|---|---|
| HLO-02 | **confirmed** (on-chain half; the executor/UI half was fixed in fix/hl-open) | Low (unchanged) | `test_HLO02_r2_ownerManagerNameAndHostedAreStillFree` |
| HLO-03 | **confirmed**, and worse with HLR2-H01: a loosening applies before a waiting redeemer can force an exit | Low standalone; it multiplies HLO-07 and H01 | `test_HLO03_r2_ownerTurnsTheNavMoveBoundOffInstantly` |
| HLO-06 | **confirmed** | Low (Design) (unchanged) | `test_HLO06_r2_oneLargeRedemptionBlocksEveryRequestOfTheEpoch` (+ hl-open `test_HLO06_whaleExitBlocksTheEpochThenAnyoneStopsTheVault`) |
| HLO-07 | **confirmed** for the registrar key **and** the factory owner key. The proposed creator co-signature does **not** close it | Medium (unchanged); per-round bound up to 100% (HLO-03) | `test_HLO07_r2_factoryOwnerKeyAlsoBindsASelfHeldAgent`, `test_HLO07_r2_creatorCoSignatureIsProducedByTheAttacker`, `test_HLO07_r2_commitThenVetoWorksWithTodaysFunctions` (+ hl-open `test_HLO07_leakedRegistrarKeyGivesAnyLauncherASelfHeldAgent`) |
| HLO-08 | **confirmed live** (cast, 2026-10-19 20:28 UTC) | Low (process), but it carries H07's live powers | read below |

## HLO-02: impersonation, on-chain half (confirmed, Low)

`create` takes `owner`, `manager`, `feeRecipient`, `name`, `symbol` and `hosted` from the caller unchecked
(HyperVaultFactory.sol:258-294). The PoC launches a vault named like the platform vault with another wallet as owner and manager and
`hosted = true`. The vault gets the hosted protocol share (33%), and the named wallet has never signed anything. A
detail hl-open did not list: the named wallet is now an **insider** of a vault it never made, so its own deposits
there are deferred to the next epoch (`requestDeposit` returns `currentEpoch + 1`). It also becomes the vault's owner,
with every owner power, and becomes the target of anything the indexer attributes by `VaultCreated.owner`.

Numbers: hl-open measured 3,350 USDC of fee value per year on a 100k deposit for the launcher. The executor/UI half is
fixed (attribution and "Hosted by DojiPad" now come from the tenant and owner consent). What is left on chain is
cosmetic plus the forced-insider detail, so Low stands: impact bounded to fees on deposits reached by direct link,
likelihood low (Explore is curated).

Fix sketch:

```solidity
// HyperVaultFactory.create
if (p.owner != msg.sender) {
    // EIP-712 consent of the named owner over the whole launch (also closes HLO-10's "signature does not cover the params")
    bytes32 h = _hashTypedDataV4(keccak256(abi.encode(CREATE_TYPEHASH, msg.sender, keccak256(abi.encode(p)), p.salt)));
    if (!SignatureChecker.isValidSignatureNow(p.owner, h, p.ownerSig)) revert NotOwnerConsent();  // EIP-1271 ok
}
// hosted is a platform statement: require it to be signed by the registrar together with the agent binding, or drop
// the flag from CreateParams and set it from the registrar-signed binding.
```

The manager needs the same consent: either it equals the owner, or `setManager` acceptance becomes two-step
(`pendingManager`, `acceptManager`).

## HLO-03: no policy envelope (confirmed, Low; multiplier)

Still true: the factory checks only the assets and the cap (HyperVaultFactory.sol:245-248), `_validate` allows 50x,
100% breakers, 20% slippage, 30-day epochs and a 100% NAV move. The PoC shows the default-policy vault's owner
raising `maxNavMoveBps` to 10,000 **in the same transaction** (it counts as a tightening, N-03; `pendingConfig` stays
empty), and a launch with the full hostile envelope. New since hl-open: HLR2-H01 shows that even a *timelocked*
loosening applies before a depositor who reacts in the same block can force an exit, so "the depositor sees the
loosening and leaves" is not a mitigation for the timelocked fields either.

Re-rating: Low standalone (the policy is visible before deposit; a manual vault's manager cannot hide NAV, so the NAV
bound matters only with an agent or a mark manipulation). It sets the per-round bound of HLO-07 (100% instead of
20%) and the damage of H01.

Fix sketch:

```solidity
// HyperVaultFactory: one envelope, checked at create and by every policy change
struct Envelope { uint32 maxLev; uint32 maxDaily; uint32 maxDd; uint32 maxSlip; uint64 maxEpoch; uint32 minNavMove; uint32 maxNavMove; }
function checkEnvelope(VaultPolicy.RiskConfig calldata c) public view {
    Envelope memory e = envelope;
    if (c.maxLeverageBps > e.maxLev || c.maxDailyLossBps > e.maxDaily || c.maxDrawdownBps > e.maxDd
        || c.maxSlippageBps > e.maxSlip || c.maxEpochDuration > e.maxEpoch
        || c.maxNavMoveBps < e.minNavMove || c.maxNavMoveBps > e.maxNavMove) revert OutsideEnvelope();
}
// VaultPolicy.proposeConfig: if (factory != address(0)) IFactory(factory).checkEnvelope(next);
// and treat a maxNavMoveBps RAISE as loosening (timelocked), keeping a lowering timelocked too (N-03 liveness):
// i.e. any change of maxNavMoveBps goes through the timelock.
```

Suggested values (hl-open 6.1): leverage ≤ 10x and ≤ the perp's HL maximum, daily loss ≤ 20%, drawdown ≤ 50%,
slippage ≤ 2%, epoch ≤ 7 days, `maxNavMoveBps` in [500, 2,000].

## HLO-06: large exits (confirmed, Low Design)

A normal settle pays every redemption in full or reverts (VaultLogic.sol:263-264). PoC: NAV 10,100,002 USDC, 95%
deployed, 500,000 USDC idle. A 10M whale's full redemption reverts the settle, and with it alice's 1 USDC redemption
and bob's 1,000 USDC deposit. Nothing settles until the whale's 10M is idle, or until the epoch is overdue and someone
triggers the emergency (hl-open PoC: the agent is revoked, 505 bps filled pro rata). Impact × likelihood as hl-open:
the stayers bear ≈ f × leverage × slippage of the unwind (0.5 × 2.5 × 1.5% ≈ 1.9%), and every other request of the
epoch waits up to `maxEpochDuration`. Likelihood rises with the lifted cap. With H01 there is a second consequence: a
large pending redemption is also a way for an owner to stall settles legitimately while a loosening matures.

Fix sketch: settle what is payable instead of all or nothing, outside emergency too:

```solidity
// VaultLogic.settle, normal mode: pay pro rata to the idle USDC, return the rest (the emergency path already does this)
if (available < redAssets) {
    paid = available;
    burned = redShares.mulDiv(paid, redAssets, Math.Rounding.Floor);   // same as the V-01 partial fill
}
// deposits mint as usual; unpaid shares return to redeemers on claim and may be re-requested
```

The keeper then unwinds in steps (flatten within the policy band, bridge, settle), and the platform deposit cap should
be tied to the thinnest curated book (hl-open 6.2).

## HLO-07: a leaked registrar or owner key gives any launcher a self-held "platform" agent (confirmed, Medium)

Still true on the current code. `create` accepts `signer == agentRegistrar || signer == owner()`
(HyperVaultFactory.sol:240). `test_HLO07_r2_factoryOwnerKeyAlsoBindsASelfHeldAgent` shows the owner-key leg, which
hl-open named but did not test. The factory owner is a single EOA (HLO-08). With the owner able to raise
`maxNavMoveBps` to 100% at once (HLO-03), the per-round bound of the hl-open PoC (10.5% of a depositor's value at the
default 20%) is the attacker's choice, up to the whole vault.

**Creator co-signature, evaluated.** The proposed mitigation was "the creator co-signs the binding". It does not close
HLO-07:
- In HLO-07 the attacker **is** the creator. The registrar digest already binds the creator, because
  `predictVaultAddress(msg.sender, salt)` scopes the vault address by `msg.sender`, and `msg.sender` already
  authenticates the creator. A co-signature over `(agent, vault, deadline, creator)` is one more signature with the
  attacker's own key. `test_HLO07_r2_creatorCoSignatureIsProducedByTheAttacker` models it: the co-signature verifies
  and the launch with the leaked registrar signature still binds the attacker's agent.
- What it would protect against, a registrar signature for creator A being used by creator B, is already impossible
  (`test_HLO04_registrarSignatureIsBoundToTheCreator`).
- What it breaks: one more wallet prompt in the wizard, and no EIP-1271 creators unless it uses `SignatureChecker`.
  It also gives a false sense of closure.

The binding has to prove that the **platform**, not the key holder, generated and holds the agent. A key that leaks
can always sign that. So the on-chain fix has to make a leaked key insufficient on its own, through time plus an
independent veto:

```solidity
// 1. No owner() signer path for agents (the cold key should never be a hot signer):
if (signer != agentRegistrar) revert BadAgentSignature();
// 2. Commit then launch: the registrar commits (agent, creator, salt) on chain; create accepts it only after a delay
//    in which the sentinel or guardian can veto (unregisterPlatformAgent already deletes a pre-bound agent).
mapping(address agent => Commit) public commits;   // {creator, salt, at}
function commitAgent(address agent, address creator, bytes32 salt) external onlyRegistrar { ... emit AgentCommitted(...); }
// in create:
Commit memory c = commits[p.agent];
if (c.creator != msg.sender || c.salt != p.salt || block.timestamp < c.at + COMMIT_DELAY) revert NotPlatformAgent(p.agent);
// 3. Velocity bound for new agent vaults: depositCap <= NEW_AGENT_CAP for the first N days (factory-enforced).
```

Evaluation: with COMMIT_DELAY of a few hours and the executor's E06 alert on any commitment absent from the
reservation store, a registrar-only leak is caught and vetoed before any launch, provided the veto key and the monitor
are independent of the registrar process. Today the sentinel and the registrar are both online keys in the same executor
(S-04), so a full executor compromise still wins; the guardian (cold) must hold a veto too. Cost: the launch is no
longer one transaction. The wizard must wait COMMIT_DELAY between reservation and launch; manual launches are
unaffected. V-04 (the registrar pre-binding a predicted address to block a salt) does not come back, because the
commit names `(creator, salt)` and the creator can pick another salt. `test_HLO07_r2_commitThenVetoWorksWithTodaysFunctions`
shows that today's owner pre-bind plus sentinel veto already work as a manual version of this flow.

Off chain (cheaper, partial): the registrar key in a KMS/HSM with a signing policy (one signature per reservation
record, rate limits), and the E06 alert routed to the guardian.

## HLO-08: unmet deploy conditions (confirmed live, Low process)

Read-only, `https://rpc.hyperliquid.xyz/evm`, 2026-10-19 20:28 UTC (block ≈ 48,988,121):

| | round 4 factory [an earlier factory] | round 3 factory [an earlier factory] |
|---|---|---|
| `owner()` | `0x1A7acB7966e6E3632694484dE261B70230eCD7ff` | same |
| `pendingOwner()` | 0 | 0 |
| `guardian()` | `0x1A7acB7966e6E3632694484dE261B70230eCD7ff` (no code, nonce 11) | same |
| `sentinel()` / `agentRegistrar()` | `0x8fEe…95F1` (EOA, nonce 1) / `0x6702…d198` (EOA, nonce 3) | same |
| `openLaunch` / `maxDepositCap` | true / 2^256 − 1 | false / 2^256 − 1 |
| `protocolFeeRecipient` | `0x18483B23B326c30dd80E59C617A1483842B7e797` (EOA, nonce 0) | same |

The owner/guardian is still one EOA, and `docs/runbooks/guardian-to-safe.md` has not been executed (no pending owner).
REAUDIT2 I2-06 (multisig before lifting the allowlist) and the VERIFY pass 4 condition (fix V-04 before `openLaunch`)
remain unmet while `openLaunch = true`. What that key does today, instantly and for every vault (HOSTILE-AND-CONFIG
H07): rotate the guardian (clear every breach, end every emergency, cancel every queued item), rotate the sentinel,
redirect every vault's protocol fees, revoke any agent, and sign agent bindings for any launcher (HLO-07).

Re-rating: Low (process) stands as a finding about the deploy conditions. Its consequence, a compromise of one
routinely used EOA, is theft of the protocol fees (High on the scale for the platform) and the HLO-07 path for
depositors. The impact sits in H07 and HLO-07.

Fix: execute the Safe runbook (`transferOwnership(safe)`, `acceptOwnership` from the Safe, `setGuardian(safe)` on both
factories). Remove `owner()` as an agent signer (HLO-07 fix 1). Add a short factory timelock on `setGuardian`,
`setSentinel`, `setProtocolFeeRecipient` and `setAgentRegistrar` (H07). Until then, `setOpenLaunch(false)` on the
round 4 factory (one transaction, future launches only).
