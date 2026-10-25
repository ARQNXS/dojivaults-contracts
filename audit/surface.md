# Pass 0: External surface map

Baseline: HEAD `896a0d6` (contracts/src identical to `0a9311a`). Line numbers refer to that tree.
Legend: CW = CoreWriter action (fire and forget), PC = precompile read, NR = `nonReentrant`.

## HyperVault.sol (EIP-1167 clone, initialized once)

| Function (line) | Access | State written | External calls / value flow |
|---|---|---|---|
| `initialize(InitParams)` (295) payable | `initializer` (impl locked in ctor 289) | all config, HWM/peak = 1e6, epochStartedAt, lastFeeAccrual, riskDay, agent, bridge vars | CW addApiWallet (if agent), USDC approve + CDW.deposit(seed, SPOT), HYPE `call` to 0x2222 |
| `requestDeposit(assets, controller)` (482) | anyone, NR | requests[controller], pendingDepositAssets | PC (only if cap set), USDC transferFrom(msg.sender); auto-claims controller |
| `requestRedeem(shares, controller, owner_)` (502) | owner_ or allowance, NR | requests, pendingRedeemShares, share balances | none; auto-claims controller |
| `cancelDepositRequest()` (523) | requester, current epoch, NR | requests, pendingDepositAssets | USDC transfer out |
| `cancelRedeemRequest()` (533) | requester, current epoch, NR | requests, pendingRedeemShares | share transfer out |
| `claim(controller)` (544) | anyone, NR | requests, claimableRedeemAssets | share + USDC transfer to controller |
| `settle()` (570) | manager; anyone if overdue or emergency; NR; not in bridge window | fees, supply, claimableRedeemAssets, pending*, dayStartEquity, HWM/peak, epochs, currentEpoch | PC NAV |
| `accrueFees()` (622) | anyone, NR, not in window | supply (fee mints), lastFeeAccrual, HWM | PC NAV, factory.protocolFeeRecipient() |
| `leaveHosted()` (668) | owner | hosted, protocolShareBps | CW addApiWallet(burn) |
| `lowerProtocolShare(bps)` (677) | factory | protocolShareBps, baseShareBps | none (no event) |
| `bridgeToCore(amount)` (689) | manager, NR, !emergency/breach, !window | pendingToCore, pendingToEvm, lastBridgeBlock | USDC approve + CDW.deposit |
| `fundCoreGas()` (720) payable | anyone | none | HYPE `call` to 0x2222 |
| `bridgeToEvm(amount)` (735) | manager; anyone in emergency; NR; !window | pendingToEvm, pendingToCore, lastBridgeBlock | CW usdClassTransfer (perp->spot) + CW sendAsset to 0x2000..00 |
| `moveUsd(amount, toPerp)` (762) | manager (toPerp blocked in breach/emergency) | none | CW usdClassTransfer |
| `placeOrder(...)` (775) | manager | none | PC perpAssetInfo/markPx, policy.checkOrder, CW limitOrder |
| `cancelOrder(asset, oid)` (791) | manager / guardian | none | CW cancelByOid |
| `flatten(asset, slippageBps)` (800) | slippage 0: anyone in breach/emergency, else mgr/guardian; custom (<=20%): mgr/guardian | none | PC position/assetInfo/markPx, CW IOC reduce-only order |
| `setAgent(agent, name)` (830) | owner, not breached/emergency | agent, agentName | CW addApiWallet (x2 if name changes) |
| `revokeAgent()` (844) | guardian / owner | agent | CW addApiWallet(burn) |
| `checkRisk()` (863) | anyone | riskDay, dayStartEquity, peakSharePrice, breached, agent | PC NAV + margin summary, policy limits, CW revoke on breach |
| `triggerBreach()` (901) | guardian / owner | breached, agent | CW revoke |
| `triggerEmergency()` (912) | guardian / owner; anyone if overdue + pending redeem | emergency, breached, agent | CW revoke |
| `clearBreach()` (920) | owner, not in emergency | breached, peakSharePrice, dayStartEquity, riskDay | PC NAV |
| `exitEmergency()` (930) | owner | emergency | none |
| `setDepositsPaused` / `setTradingPaused` (938/945) | owner; guardian may only pause | flags | none |
| `setGuardian` (951), `setDepositCap` (958) | owner (instant) | guardian / depositCap | none |
| `lowerFees` (964) | owner (instant, lower only) | fees (+ accrual if !window) | PC |
| `rescueToken(token, to)` (970) | owner; not asset, not own shares | none | token transfer |
| `queue(data)` (980) | owner; selector whitelist: setManager/setFees/setFeeRecipient/setTimelockDelay | queuedEta | none |
| `execute(data)` (993) | anyone after eta, NR | queuedEta, target setter | self call |
| `cancel(id)` (1004) | guardian / owner | queuedEta | none |
| `setManager/setFees/setFeeRecipient/setTimelockDelay` (1010-1026) | `onlySelf` (via execute) | config | setFees accrues if !window |
| ERC20 `transfer/transferFrom/approve`, Ownable2Step `transferOwnership/acceptOwnership/renounceOwnership` | standard | balances / owner | none |
| Views: `totalAssets` 360, `convertTo*` 366/370, `preview*` 375-389, `max*` (=0) 392-406, `idleAssets` 427, `coreEquity` 434, `bridgeInFlight` 445, `sharePrice` 450, `epochOverdue` 454, `claimable` 459, `pendingRequest` 472 | view | - | PC |

## HyperVaultFactory.sol (Ownable2Step, non-upgradeable)

| Function (line) | Access | State written | External calls / value flow |
|---|---|---|---|
| `create(p, permit)` (146) payable | `canLaunch(msg.sender)` | _vaults, isVault, policyOf | permit (try/catch), cloneDeterministic(salt scoped to sender), clone policy + initialize, USDC transferFrom(sender -> vault), vault.initialize{value: msg.value} |
| `setProtocolFeeRecipient` (205) | owner | protocolFeeRecipient (read live by every vault) | none |
| `setShares` (211) | owner, <= 50% | base/hosted share for future vaults | none |
| `lowerProtocolShare(vault, bps)` (219) | owner, isVault | - | vault.lowerProtocolShare |
| `setMinSeedUsdc` (225), `setMinHypeValue` (230), `setLauncherAllowed` (235), `setOpenLaunch` (240) | owner | config | none |
| Views: `vaults`, `vaultCount`, `predictVaultAddress` (131), `canLaunch` (135) | view | - | - |

## VaultPolicy.sol (clone, initialized once, Ownable2Step)

| Function (line) | Access | Notes |
|---|---|---|
| `initialize` (67) | initializer | validates config, allowlists assets (no market existence check) |
| `checkOrder` (135) | view | band vs mark, allowlist (skipped for reduce only), notional at limitPx (skipped for reduce only) |
| `proposeConfig` (159) | owner | tighter on every field: immediate (and deletes pending); else queued, no expiry |
| `applyPendingConfig` (172) | anyone after eta | no expiry |
| `cancelPendingConfig` (180) | owner | - |
| `disallowAsset` (189) | owner, immediate | - |
| `queueAllowAsset` (195) / `allowAsset` (202) | owner / anyone after eta | no expiry |
| `proposeTimelockDelay` (213) / `applyTimelockDelay` (226) | owner / anyone after eta | raise instant, lower timelocked |
| Views | - | `config`, `pendingConfig`, `allowedAssets` (loop over list), `max*` getters |

## HyperCore.sol / PxMath.sol
Internal libraries only. Reads revert on precompile failure (`_read`, line 100); writes are `abi.encodePacked(uint8(1), uint24 actionId, abi.encode(...))` to 0x3333..3333.
