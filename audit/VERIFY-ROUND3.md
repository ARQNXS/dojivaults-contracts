# DojiPad Vaults: round 4 verification pass (fork rehearsal)

Date: 2026-10-09. Scope: the uncommitted round 4 contracts (after REAUDIT3 and the decisions in its section 12), the
executor (`server/`) and webapp changes of Phase 3, rehearsed together on an anvil fork of HyperEVM mainnet. Nothing
was sent to mainnet. Companion to `REAUDIT3.md` (findings) and `docs/runbooks/relaunch-dojipad-vault.md` (the plan).

## 1. Result

**45 of 45 rehearsal checks pass; the full forge suite passes (244 passed, 0 failed, 2 skipped, 32 suites); the
executor suite passes (376 tests); the webapp suite passes (66 tests), tsc and build are clean, and no route
overflows at 360 / 390 / 430 px.** Two defects were found and fixed during this pass (section 4). The stack is ready
for the capped mainnet deploy, with `openLaunch = false` and `maxDepositCap = 50,000 USDC`, on the user's go.

## 2. How it was run

```bash
# local fork of HyperEVM mainnet (block 48,027,560); the RPC provider's URL is read from the local environment and never printed
anvil --fork-url "<HyperEVM RPC URL>" --chain-id 999 --port 8548 --gas-limit 30000000 --silent
cd server && npx tsx scripts/rehearse-round4.ts        # 45/45 checks, exits 1 on any failure
```

`server/scripts/rehearse-round4.ts` refuses any RPC that is not a local anvil with chain id 999. It:

- installs mock HyperCore precompiles (spot balance, withdrawable, margin summary, core user, mark, asset info,
  position) and a mock CoreWriter at their mainnet addresses (HyperCore does not exist on anvil);
- deploys the full stack with the real `script/Deploy.s.sol:DeployFactory` (broadcast to the fork only,
  `DEPLOY_SKIP_RECORD=true`, `--gas-limit 30000000`: big blocks), backing up and restoring `contracts/broadcast/`
  so the mainnet run logs are untouched (checked afterwards: `run-latest.json` of 2026-10-07 and the 2026-10-05 lock
  are the originals; `deployments/mainnet.json` unchanged);
- uses the real mainnet USDC and CoreDepositWallet contracts on the fork (balances set in USDC storage);
- launches a hosted vault and a copy vault exactly like the wizard: `agentDigest` signed by the registrar, the keeper
  as operator, seed by allowance;
- drives the scenarios through the executor's own classes: `VaultChain` (reads, multicall, signed sends),
  `OperatorRunner`, `VaultMonitor` (sentinel), `guardOrder` and the risk limits. HyperCore is a small model in the
  script (balances, notional, landings), written into the mocks after every action.

Roles are anvil's public dev accounts: deployer, guardian, sentinel, registrar, keeper (= operator), vault owner and
manager, two depositors, a stranger.

## 3. Checks

| # | Scenario | Checks (all PASS) |
|---|---|---|
| 0 | Deploy | `Deploy.s.sol` deploys on the fork; `openLaunch == false`; `maxDepositCap == 50,000 USDC`; `MIN_DEPOSIT == 10 USDC`; guardian and sentinel set |
| 0 | Launch (hosted, copy) | agent bound in `create` from the registrar signature (no pre-registration); operator is the keeper |
| 1 | Deposit | under 10 USDC reverts `DepositTooSmall`; requests queue |
| 2 | Auto processing | nothing settles before the epoch is due; once due the operator settles, both vaults' deposits mint, idle USDC is bridged to Hyperliquid and moved to perp margin; no manager action and no alert |
| 3 | Near the limit | at 2.85x of a 3x policy the executor's trim rule fires (10.5%) and brings the book back to 2.55x (85% headroom); `checkRisk` does not breach |
| 4 | Leverage breach | 3.3x breaches with reason leverage; the agent is kept; `guardOrder` refuses any open on fresh flags; deposits close; not cleared inside the 15 minute cooldown; the operator's `clearLeverageBreach` clears it once leverage is back under the limit |
| 5 | Red day, full exit | -3% (daily limit 5%) does not breach; alice (2/3 of the vault) redeems everything the same UTC day; the operator brings the USDC back and settles; she is paid 19,399.58 USDC; the daily loss reads 3.00% before and 2.99% after the payout (R-01), no breach |
| 6 | Drawdown, resume | -20% breaches with reason drawdown, agent kept; `resume` reverts `NotReady` inside 24 h and `Unauthorized` for a stranger; the operator runs a redemption-only settle and bob is paid 3,879.69 USDC (lens preview at request time 3,879.91; the 0.22 difference is 25 h of the 2% management fee); `bridgeToCore` reverts `ReduceOnlyMode` in the breach; after 24 h the owner resumes and `lastResumeAt` is set (the depositor notice) |
| 7 | Stranger | `flatten`, `settle` and `bridgeToEvm` revert `Unauthorized`, also in a guardian full stop |
| 8 | Sentinel | copy vault in a leverage breach; the agent adds exposure; `VaultMonitor` raises `EXPOSURE_UP_IN_BREACH` and revokes the agent through the sentinel; the sentinel's `revokeOperator` removes the operator and the runner no longer touches that vault |
| 9 | Late landing (R3-08) | a Core -> EVM transfer still unlanded at block 61 does not breach (daily 0.00%); `bridgePending` stays true for the sentinel's 30 block alert; once it lands the NAV is whole |

## 4. Defects found in this pass (both fixed, with tests)

| ID | Where | Defect | Fix | Test |
|---|---|---|---|---|
| R3-07 (Low) | `HyperVaultLens.pendingFeeShares` | The lens added the performance fee in a breach / emergency, while `settle` charges none: price, deposit and redeem previews were off by up to the fee during a breach. Found by the full invariant suite (`share price jumped at settle`, `lens preview != settle`). | Fee gated like `settle` (`!breached && !emergency`). | `Round4BreachFeesTest` (lens previews = settle; fails without the fix by 25,600 in share price); both invariant sequences replayed green |
| OPS-1 | `server/src/treasury/operator.ts` | After `moveUsd` the runner re-read Hyperliquid at once and, on a balance that had not caught up, sent the same move again (six times in one pass on the fork). Harmless on Core (the extra actions fail) but wrong. | A margin move now ends that vault's run, like a bridge; the next run reads the settled balances. | `test/operator.test.ts` "a margin move ends the run" |

The decisions after STOP 3 (REAUDIT3 section 12) are in this build: redemption-only settles pay at
min(live NAV, checkpoint) and the lens previews it; `MIN_DEPOSIT = 10 USDC`; a late landing is carried as in
transit for at most `MAX_UNLANDED_BLOCKS = 300` (R3-08); the sentinel alerts on perp / spot moves inside a pending
window (`PERP_TO_SPOT_IN_WINDOW`, either direction); `setMaxDepositCap` is a runbook item.

## 5. Sizes (EIP-170, 24,576 bytes)

HyperVault 17,156 · VaultLogic 17,379 · VaultGovernance 11,483 · HyperVaultFactory 10,955 · HyperVaultLens 9,096 ·
VaultPolicy 9,927.

## 6. Not covered by the fork

- **HyperCore itself.** Precompiles and CoreWriter are mocks; landing times, the activation fee, `sendAsset` failure
  modes and class transfers are modelled, not observed. The first mainnet launch (relaunch runbook) is the real
  check: seed landing, agent approval on Hyperliquid, one small deposit and withdrawal round trip.
- **Hyperliquid's API.** Orders, fills and the info API are not exercised; the trim scenario checks the executor's
  rule on the contract's leverage, not order placement. Opens refused in a breach are checked through `guardOrder`
  on fresh chain flags (and in the executor's unit tests through the processor).
- **Mainnet timing.** The fork mines on demand; block times and RPC rate limits are not representative.
- **Webapp against the fork.** The UI was tested by unit tests, the build and the overflow check, not clicked
  against the fork.

## 7. Before the mainnet deploy

- Commit the round (explicit paths; the audit window closes with this pass) on the user's go.
- Deploy the executor and webapp code first with the current (round 3) configuration: both generations are
  supported, round 3 vaults keep working.
- Then the deploy commands in the relaunch runbook, the guardian's `acceptOwnership`, and the configuration switch.
