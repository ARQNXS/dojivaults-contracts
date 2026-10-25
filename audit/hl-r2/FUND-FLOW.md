# hl-r2 FUND-FLOW: every path that moves value in the HyperEVM vault contracts

Internal, AI-assisted review (sub-reviewer "flow", branch `audit/hl-r2-flow`), 2026-10-19. Not an independent audit.
Scope: `contracts/src` without `gains/` (HyperVault, VaultLogic, VaultGovernance, VaultMath, VaultPolicy, VaultTypes,
HyperVaultFactory, HyperVaultLens, hypercore/HyperCore, libraries/PxMath), source as deployed in round 4 (last src
commit 2305cf2; live bytecode matches, see section 5). Tests: `contracts/test/audit/hl-r2/flow/HlR2FundFlow.t.sol` and
`HlR2Encoding.t.sol` (28 tests, 27 run by default, 1 fork test opt-in with `HLR2_FORK=true`; all pass). Evidence:
`contracts/audit/hl-r2/evidence/flow/`.

## 0. Conclusion

1. **No path sends USDC, shares or HyperCore balances to an address other than the vault's own accounts, a depositor
   who owns the request, the fee recipients, or the launcher's own seed.** Every CoreWriter call site (6 in VaultLogic,
   via the 5 used encoders in HyperCore.sol) was enumerated: the only address-bearing actions are action 13 (destination
   hard-coded to `0x2000…0000`, subAccount hard-coded 0, token 0) and action 9 (the stored agent, validated against
   the factory binding, or the derived burn address). Proven by `test_HLR2_ENC_onlyIds_1_7_9_10_13_andNoForeignAddress`,
   `testFuzz_HLR2_ENC13_sendAssetFieldsForAnyAmount` and, against live mainnet bytes, `test_HLR2_ENC13_bridgeToEvmReproducesLiveCopyVaultBytes`.
2. **No arbitrary call or delegatecall.** The only low-level calls are `address(this).call(data)` in
   `VaultGovernance.execute` (data must be a queued id whose selector is one of six `onlySelf` setters with an exact
   length; queue is owner-only), `HYPE_SYSTEM_ADDRESS.call{value}` (constant target, empty data) and precompile
   `staticcall`s (constant targets). Delegatecalls are only Solidity's linked-library calls to two fixed addresses and
   the EIP-1167 clone proxies to a fixed implementation. The libraries refuse direct calls
   (`test_HLR2_FLOW_libraryFunctionsRevertOnDirectCall`). The one owner-chosen call target is `rescueToken(token, to)`,
   which cannot touch the asset or the shares.
3. **No leftover allowance.** The vault approves the CoreDepositWallet exactly `amount` and calls `deposit(amount,
   spot)`. Circle's CoreDepositWallet (source `circlefin/hyperevm-circle-contracts` @ffcc978, `_deposit` does
   `token.transferFrom(msg.sender, address(this), _amount)`) pulls exactly that; verified against the LIVE contract on a
   read-only fork (`test_HLR2_FLOW_fork_realCoreDepositWalletPullsExactlyTheApprovedAmount`: allowance 0 after, an
   over-approval is never pulled) and on chain: `allowance(vault, CDW) = 0` for the platform vault, x402 Test and Copy HL Test
   Vault at block 48988180.
4. **Core -> EVM via `sendAsset` to `0x2000…0000` (open assumption A-07 since round 1) is now verified on mainnet.**
   The Copy HL Test Vault's `bridgeToEvm(19535906)` (tx 0xf7f5a012…) emitted exactly the bytes the code builds, the
   HyperCore ledger shows `send … destination 0x2000…0000, spot -> spot, 19.535906 USDC`, and the vault then paid
   19.533495 USDC to a redeemer on HyperEVM (claim tx 0xcce07296…). The HL docs page "HyperCore <> HyperEVM transfers"
   documents this path (quote in COREWRITER-ENCODING.md section 3). Only observed at 19.5 USDC; size limits remain open.
5. New findings from this domain: HLR2-F01 (Low, agent approvals expire after 90 days), HLR2-F02 (Low, bridgeToEvm
   counts held spot), HLR2-F03..F08 (Info). None is exploitable for theft. Table in section 6.

## 1. Method

- `grep` over `src` (non-gains) for every `HyperCore.<write>`, `sendRawAction`, `.call`, `delegatecall`, `transfer`,
  `transferFrom`, `approve`, `deposit`, `permit`, `mint`, `burn` and the VaultMath share helpers (list in section 4).
- Each row: function, exact role check (file:line), where value goes, the bound, and a test. "Existing" tests are in
  the main suite; `HLR2` tests are new and pass.
- Live checks are read-only (`cast call`, `cast logs`, `cast code`, HL `info`). Nothing was broadcast.

## 2. EVM value paths

### 2.1 USDC

| # | Path | Who (role check) | From -> to | Bound | Test |
|---|---|---|---|---|---|
| U1 | `requestDeposit` VaultLogic.sol:43-69, `safeTransferFrom` :59 | anyone, for any `controller != 0` (:47); closed when paused / breached / emergency (:48) | msg.sender -> vault | `assets >= MIN_DEPOSIT` (10 USDC), deposit cap (:49) | existing `test_DepositSettleClaim` (HyperVault.t.sol:13) |
| U2 | `cancelDepositRequest` :98-113, `safeTransfer` :111 | the request's controller (msg.sender keyed, :99) | vault -> controller | exactly `r.depositAssets`, zeroed first (:107), only while pending or carried (:101-105) | existing `test_RequestAutoClaimsPreviousEpoch`; F08 note (payer ≠ controller) |
| U3 | claim / `_claimIfSettled` :138-156, `safeTransfer` :153 | anyone triggers, pays only `controller` | vault -> controller | pro-rata of the epoch's `redeemAssets` (VaultMath.sol:243) or refund; capped at `claimableRedeemAssets` (:150) | existing `invariant_mixedRequestsFair`, `invariant_mixedRequestsFairEmergency` (test/audit/verify/VerifyMixedInvariants.t.sol) |
| U4 | `bridgeToCore` :419-433 -> `_depositToCore` :485-490 (`approve` :488, `deposit` :489) | manager or operator (`_treasury` :178-180); not in hard stop or loss breach (:425); Core account must exist (:426) | vault -> CoreDepositWallet -> vault's own Core **spot** (`deposit`, never `depositFor`) | `amount <= idleAssets` (pending deposits and claimable redemptions excluded, VaultMath.sol:112-116), `>= MIN_BRIDGE` unless all idle; allowance exactly `amount`, consumed | `test_HLR2_FLOW_bridgeToCoreLeavesNoAllowanceAndCreditsOnlyTheVault`, fork `test_HLR2_FLOW_fork_realCoreDepositWalletPullsExactlyTheApprovedAmount` |
| U5 | `seedCore` :493-502 (from `VaultGovernance.initialize` :90) | initializer only (once, by the factory in `create`) | seed already on the vault -> its own Core spot | `p.seedUsdc` (the factory transferred exactly that, factory :263) | `test_HLR2_FLOW_factorySeedComesOnlyFromTheLauncher` (allowance 0, sender = vault) |
| U6 | `rescueToken` HyperVault.sol:338-341 | `onlyOwner` | any token except the asset and the vault's own shares -> `to` | full balance of that token | `test_HLR2_FLOW_rescueTokenBound` |
| U7 | Factory `create` HyperVaultFactory.sol:223-295: `permit` :253-255 (try/catch), `safeTransferFrom(msg.sender, vault, seed)` :263 | launcher (`canLaunch` :228) | **launcher** -> new vault | `p.seedUsdc >= minSeedUsdc`; the permit owner is `msg.sender`, a third party's allowance is never used | `test_HLR2_FLOW_factorySeedComesOnlyFromTheLauncher`; existing `test_CreateWithPermit`, `test_FrontRunPermitDoesNotBrickCreate` (PolicyAndFactory.t.sol:396, 432) |
| U8 | Core -> EVM landing (system tx `CDW.transfer(vault, amount)` from `0x2000…0000`) | HyperCore, in response to U-C4 | CDW -> the **sender** of the sendAsset (the vault) | what Core debited | mainnet evidence (section 0 item 4) |

### 2.2 Shares (ERC-20 of the vault, 12 decimals)

| # | Path | Who | From -> to | Bound | Test |
|---|---|---|---|---|---|
| S1 | ERC-20 `transfer` / `transferFrom` / `approve` (OZ ERC20Upgradeable, unmodified) | holders / approved spenders | holder -> anyone | balances / allowances | OZ; F03 (to the vault address = stranded) `test_HLR2_F03_sharesSentToTheVaultAreStranded` |
| S2 | `requestRedeem` VaultLogic.sol:72-96: `spendAllowance` :79, `transfer(owner_, vault)` :87 | `owner_` or a spender with allowance | holder -> vault escrow | allowance; the vault never holds an allowance from itself, so `owner_ = vault` always reverts | `test_HLR2_FLOW_escrowedSharesAreUnreachable` |
| S3 | `cancelRedeemRequest` :116-125, transfer :123 | the controller | escrow -> controller | exactly `r.redeemShares` of the current epoch | `test_HLR2_FLOW_escrowedSharesAreUnreachable` |
| S4 | claim: minted deposit shares and returned (unburned) redemption shares :147 | anyone triggers, to `controller` | escrow -> controller | floor pro rata, burned rounded up (VaultMath.sol:238-245) | existing `testFuzz_VERIFY2_B1_partialFillRounding` (Verify2PoC.t.sol:125), `invariant_mixedRequestsFair` |
| S5 | settle: `burn(vault, burned)` :271, `mint(vault, depShares)` :272 | manager / operator / owner / guardian / sentinel (:207-209), modes :210-216 | escrow burned; new shares into escrow | burned ≤ redShares (:268); mint at NAV within checkpoint bound | existing suite (Round4.t.sol, Reaudit*) |
| S6 | fee mints `_accrueFees` :336-372, mint :358 (protocol recipient read from the factory), :361 (fee recipient) | anyone via `accrueFees` / inside settle and `_setFees` | new shares -> `feeRecipient`, factory `protocolFeeRecipient` | ≤ 5%/yr management, ≤ 30% of gain above HWM (VaultTypes.sol:14-15); protocol part ≤ 50% of fees | `test_HLR2_FLOW_feeMintIsBoundedByTheRate`; existing `test_ProtocolFeeShare` (HyperVault.t.sol:326), `invariant_flowsAndFeesNeverMoveTheRiskMetrics` (Round4Invariants.t.sol:297) |

### 2.3 HYPE (native)

| # | Path | Who | To | Bound | Test |
|---|---|---|---|---|---|
| H1 | `fundCoreGas` VaultLogic.sol:505-510 (HyperVault.sol:225) | anyone, with their own `msg.value` | `0x2222…2222` (system contract, credits `msg.sender` = the vault on Core spot) | exactly `msg.value`; no receive / fallback on the vault, nothing can be left behind | `test_HLR2_FLOW_fundCoreGasForwardsAllValueAndKeepsNone`; existing `test_FundCoreGasForwardsValue` |
| H2 | factory `create{value}` -> `initialize{value}` -> H1 (VaultGovernance.sol:91) | launcher | same | `msg.value >= minHypeValue`, forwarded in full | existing `test_SeedBridgedToCoreSpotThenHypeForwarded` |

## 3. HyperCore value paths (CoreWriter actions) and agent powers

The vault is its own HyperCore account. Each row is one CoreWriter call site (all go through `HyperCore._send`,
HyperCore.sol:150-152).

| # | Action (id) | Call site | Who | Effect / destination | Bound | Test |
|---|---|---|---|---|---|---|
| C1 | limit order (1) | `placeOrder` VaultLogic.sol:546 | manager only (:537) | trades the vault's own account | perp only (< 10000), allowlist, band ±maxSlippage of mark, notional cap, projected leverage (VaultPolicy.sol:173-198); reduce only in breach / pause | `test_HLR2_ENC01_limitOrder_everyTif_reduceOnly_cloid`; existing `test_PlaceOrderPolicyRejections` |
| C2 | limit order (1), reduce only IOC | `flatten` :578 | manager, guardian any time; owner, operator, sentinel in breach / emergency (:562-572) | own account, reduce only | price band ≤ policy slippage or custom ≤ maxFlattenSlippage ≤ 3%; size = position | `test_HLR2_ENC01_flattenIsReduceOnlyIocNoCloid`, `test_HLR2_PC_livePositionDecodesSignedAndFlattenSizes` |
| C3 | cancel by oid (10) | `cancelOrder` :553 | manager or sentinel (:552) | own orders | none needed (no value moves) | `test_HLR2_ENC10_cancelByOid` |
| C4 | usd class transfer (7) | `moveUsd` :519; `bridgeToEvm` :446 | manager / operator (:514); bridgeToEvm see C5 | own spot <-> own perp | `toPerp` refused in hard stop / loss breach (:516); not in a bridge window | `test_HLR2_FLOW_moveUsdTreasuryOnly`, `test_HLR2_ENC07_moveUsdReproducesLivePlatformVaultBytes` |
| C5 | send asset (13) | `bridgeToEvm` :447-449 | manager / operator; owner, guardian, sentinel only in emergency (:439) | **constant** destination `0x2000…0000` (USDC system address), subAccount 0, spot -> spot, token 0: credits the vault's EVM address (docs + mainnet) | `amount <= spot total + perp withdrawable` (:443) (see HLR2-F02), `>= MIN_BRIDGE` unless all; window rules | `testFuzz_HLR2_ENC13_sendAssetFieldsForAnyAmount`, `test_HLR2_ENC13_bridgeToEvmReproducesLiveCopyVaultBytes`, `test_HLR2_FLOW_bridgeToEvmRoles` |
| C6 | add API wallet (9), agent | `setAgent` :588 (timelocked, onlySelf, HyperVault.sol:252), `syncAgent` :605 (anyone, the stored agent only) | owner through the timelock; anyone for sync | API wallet = stored agent; factory vaults require `platformAgentFor(agent) == vault` (:611) | name always "dojipad" (one named slot replaced); not in hard stop | `test_HLR2_ENC09_syncAgentReproducesLivePlatformVaultBytes`; HLR2-F01 |
| C7 | add API wallet (9), revoke | `_revokeAgent` :623-630 via `revokeAgent` (owner, guardian, sentinel, factory, HyperVault.sol:264), `triggerBreach`, `triggerEmergency`, `leaveHosted` | listed roles | API wallet = `address(uint160(keccak256(vault, block.number)))`, no known key | — | `test_HLR2_ENC09_revokeBurnReproducesLiveCopyVaultRevoke` (live burn reproduced) |
| C8 | (USDC into Core) CoreDepositWallet `deposit` | U4 / U5 | see U4 | own Core spot | see U4 | see U4 |
| C9 | HYPE into Core | H1 | anyone | own Core spot | `msg.value` | H1 |

Not emitted by any code path (grep, section 4): 2 vault transfer, 3 token delegate, 4 / 5 staking, 6 spot send,
8 finalize EVM contract, 11 cancel by cloid (encoder exists, HyperCore.sol:166, never called), 12 builder fee,
15 borrow / lend, 16 set abstraction, 17 outcome. `sendAsset`'s only caller passes the constant system address; the
encoder's `destination` parameter is not reachable with any other value.

**What the agent (API wallet) can do on Core is NOT bounded by these contracts** (lead's evidence item 1 and 4:
`vaultTransfer`, `agentSendAsset` between own dexes, spot orders, sub-accounts, abstraction). It cannot send funds to
another user: `usdSend`, `spotSend`, `withdraw3`, `sendAsset` and `approveAgent` are user-signed only, and the vault
has no private key. This review does not re-open that accepted design (D-1, C-01 residual R-1); it only confirms the
contract adds nothing to it.

## 4. Exhaustive call-site enumeration

`grep -rn` over `src` (gains excluded) for value-moving or call primitives, 2026-10-19:

```
HyperCore.sol:151   ICoreWriter(CORE_WRITER).sendRawAction(abi.encodePacked(uint8(1), actionId, payload))  <- only CoreWriter call
HyperVault.sol:340  token.safeTransfer(to, token.balanceOf(address(this)))                                  <- U6 rescueToken
Factory:253         IERC20Permit(usdc).permit(msg.sender, address(this), ...)                               <- U7
Factory:263         usdc.safeTransferFrom(msg.sender, vault, p.seedUsdc)                                    <- U7
VaultGovernance:359 address(this).call(data)                                                                <- timelock execute
VaultLogic:59       asset.safeTransferFrom(msg.sender, address(this), assets)                               <- U1
VaultLogic:87       VaultMath.transfer(owner_, address(this), shares)                                       <- S2
VaultLogic:111      asset.safeTransfer(msg.sender, assets)                                                  <- U2
VaultLogic:123      VaultMath.transfer(address(this), msg.sender, shares)                                   <- S3
VaultLogic:147      VaultMath.transfer(address(this), controller, shares)                                   <- S4
VaultLogic:153      asset.safeTransfer(controller, assets)                                                  <- U3
VaultLogic:271/272  VaultMath.burn / mint (escrow)                                                          <- S5
VaultLogic:358/361  VaultMath.mint(protocolRecipient | feeRecipient)                                        <- S6
VaultLogic:446      HyperCore.usdClassTransfer(amount - spotUsd, false)                                     <- C4
VaultLogic:447      HyperCore.sendAsset(USDC_SYSTEM_ADDRESS, SPOT_DEX, SPOT_DEX, USDC_TOKEN, amount*100)    <- C5
VaultLogic:488/489  asset.approve(cdw, amount); cdw.deposit(amount, SPOT_DEX)                               <- U4/U5
VaultLogic:507      HYPE_SYSTEM_ADDRESS.call{value: value}("")                                              <- H1
VaultLogic:519      HyperCore.usdClassTransfer(amount, toPerp)                                              <- C4
VaultLogic:546/578  HyperCore.limitOrder(...)                                                               <- C1/C2
VaultLogic:553      HyperCore.cancelByOid(asset_, oid)                                                      <- C3
VaultLogic:588/605  HyperCore.addApiWallet(agent, "dojipad")                                                <- C6
VaultLogic:627      HyperCore.addApiWallet(burn, "dojipad")                                                 <- C7
```

Other external calls (no value moves): USDC `balanceOf` / `decimals`; policy clone views (`checkOrder`,
`flattenOrder`, `nextCheckpoint`, `riskLimits`, `maxEpochDuration`); factory views (`guardian`, `sentinel`,
`protocolFeeRecipient`, `platformAgentFor`, `maxDepositCap`); precompile `staticcall`s to constant addresses
(HyperCore.sol:100-104); factory -> vault `initialize`, `revokeAgent`, `lowerProtocolShare`, `agent`; factory ->
policy `initialize`; policy -> factory `isAssetCurated`. No `delegatecall` in source; no `selfdestruct`; no assembly
except the two fixed-slot pointers in VaultMath.sol:47-59.

**Timelock `execute` (VaultGovernance.sol:349-362).** `queue` (:332-347) is owner-only, accepts only the selectors of
`setManager`, `setFeeRecipient`, `setTimelockDelay`, `setAgent` (36 bytes), `setFees` (68), `clearBreach` (4), with
the exact length; `execute` runs only `keccak256(data)` of a queued, matured, unexpired item. All six targets are
`onlySelf` or self-path checked (HyperVault.sol:91-94, VaultGovernance.sol:260). `transfer`, `approve`,
`rescueToken`, `bridgeToEvm`, `setOperator`, `exitEmergency`, `revokeAgent`, `transferOwnership`, `initialize` and
unknown selectors are refused: `test_HLR2_FLOW_queueAcceptsOnlyTheSixSetters` (also existing
`test_PaddedQueueCalldataRejected`, HyperVault.t.sol:627).

**Library delegatecalls.** HyperVault -> VaultLogic / VaultGovernance (linked, fixed addresses, bytecode verified in
section 5); VaultGovernance -> VaultLogic (linked). All storage arguments are the vault's own `$`. Direct CALLs to
the libraries revert (Solidity's `library_deploy_address` guard, visible as the immutable in the live bytecode):
`test_HLR2_FLOW_libraryFunctionsRevertOnDirectCall`.

**Clones.** EIP-1167 runtime `363d3d373d3d3d363d73<impl>5af43d82803e903d91602b57fd5bf3`; live clones read
2026-10-19: the platform vault -> [an earlier vault implementation] (round 4 impl), its policy -> [an earlier policy implementation]; x402 Test and Copy HL Test
Vault -> [an earlier vault implementation] (round 3 impl), their policies -> [an earlier policy implementation] (`evidence/flow/clones.txt`). The
implementations call `_disableInitializers()` in their constructors (test: `vaultImpl.initialize` reverts).

## 5. Live bytecode equals the source

Script `evidence/flow/bytecmp.py` (runtime code via `cast code`, link references resolved from the artifact and
checked against the expected library address, immutables masked, CBOR metadata stripped). Output:
`evidence/flow/bytecode-compare.txt`.

| Contract | Round 4 address | Round 4 (HEAD build) | Round 3 address | Round 3 (build of `git archive 1735b4f`) |
|---|---|---|---|---|
| HyperVault impl | [an earlier vault implementation] | **match** (17,156 B; links -> [an earlier library] ×20, [an earlier library] ×22) | [an earlier vault implementation] | **match** (15,321 B; links -> [an earlier library], [an earlier library]) |
| VaultLogic | [an earlier library] | **match** (17,379 B) | [an earlier library] | **match** (14,374 B) |
| VaultGovernance | [an earlier library] | **match** (11,483 B; links VaultLogic [an earlier library] ×7) | [an earlier library] | **match** (8,675 B) |
| VaultPolicy impl | [an earlier policy implementation] | **match** (9,927 B) | [an earlier policy implementation] | **match** (9,927 B) |
| HyperVaultFactory | [an earlier factory] | **match** (10,955 B); immutables = vault impl [an earlier vault implementation], policy impl [an earlier policy implementation], USDC 0xb883…630f, CDW 0x6B9E…0A24 | [an earlier factory] | **match** (9,611 B); immutables = [an earlier vault implementation], [an earlier policy implementation], USDC, CDW |
| HyperVaultLens | [an earlier lens] | **match** (9,096 B) | [an earlier lens] | **match** (7,662 B) |

Executable code is identical in all twelve. The CBOR metadata hash differs in all twelve: it hashes the source text
and settings, and this Windows checkout has `core.autocrlf = true` (CRLF sources) and a different absolute library
layout. A rebuild of round 3 with LF sources and the original `lib/` layout still differed in metadata only, so the
deployer's exact source bytes (line endings, possibly whitespace) cannot be reproduced here; this does not affect the
code. Assumption (conservative): metadata is not evidence either way; the code match is.

Live factory configuration (round 4, `evidence/flow/factory-config-r4.txt`): owner = guardian = 0x1A7acB79…D7ff
(no code: EOA), no pending owner, sentinel 0x8fEe3840…95F1, registrar 0x67026561…d198, protocol fee recipient
0x18483B23…e797, shares 1000 / 3300 bps, min seed 2 USDC, min HYPE 0.01, max cap 2^256-1, openLaunch true, curated
[0, 1, 5]. The constructor immutables are the right USDC and CDW (CDW address confirmed on Circle's "HyperCore
contract addresses" page; `CDW.token() = USDC`, `CDW.tokenSystemAddress() = 0x2000…0000`, `paused() = false`, proxy
implementation 0x7537af00…0dA3, admin 0x8e66c6ac…fb92).

## 6. Findings from this domain

| ID | Title | Severity | PoC | Passes |
|---|---|---|---|---|
| HLR2-F01 | Agent approvals sent through CoreWriter expire after 90 days; the contract only renews via `syncAgent`, and the executor checks presence, not `validUntil`. The platform vault's agent expires 2027-01-07 03:25 UTC | Low (operational) | `test_HLR2_F01_agentApprovalHasNoExpiryFieldAndOnlySyncAgentRenews` + live `extraAgents` (evidence/flow/extra-agents.txt) | yes |
| HLR2-F02 | `bridgeToEvm` sizes the send from spot `total` (includes `hold`): a resting spot order makes the action fail on Core and blocks settle / treasury for up to 300 blocks | Low | `test_HLR2_F02_bridgeToEvmCountsHeldSpotAndBlocksSettleForTheUnlandedWindow` | yes |
| HLR2-F03 | Shares transferred to the vault address are stranded for good | Info | `test_HLR2_F03_sharesSentToTheVaultAreStranded` | yes |
| HLR2-F04 | `HyperVaultLens.previewRedeem` / `previewDeposit` ignore exit-only pricing (min(NAV, checkpoint), refunds) in emergency and overdue platform settles | Info | `test_HLR2_F04_lensPreviewRedeemIgnoresTheExitOnlyCheckpointCap` | yes |
| HLR2-F05 | `placeOrder` forwards any `tif` byte (0, 4..255 are not HL encodings) | Info | `test_HLR2_F05_placeOrderForwardsUndefinedTif` | yes |
| HLR2-F06 | Circle dependency: Core -> EVM lands through `CoreDepositWallet.transfer`, which is `whenNotPaused` and USDC-blacklist bound; a pause or a blacklisted vault strands a bridge, which the vault counts as lost after 300 blocks | Design (accepted issuer risk class) | scenario (COREWRITER-ENCODING.md section 3) | n/a |
| HLR2-F07 | Deploy scripts: `CURATED_ASSETS` / `ASSETS` are truncated with `uint32(...)` without a range check; `DeployVault` (reference path) uses guardian = sentinel and no cap | Info | review (STATIC.md section 4) | n/a |
| HLR2-F08 | A deposit made for another controller belongs to that controller (`cancelDepositRequest` refunds the controller, not the payer) | Info (ERC-7540 semantics, by design) | covered by U2 | n/a |

Full write-ups: COREWRITER-ENCODING.md section 6 (F01, F02, F05, F06) and STATIC.md section 5 (F03, F04, F07, F08).

## 7. Assumptions and open questions

- A1 (conservative): HL's `extraAgents` may keep listing an expired agent; if so the executor's `AGENT_NOT_ON_HL`
  rule (server/src/monitor.ts:238) never fires on expiry. Not verifiable without waiting for an expiry or a broadcast.
- A2: the Core -> EVM credit is a system transaction that `eth_getLogs` does not show; the landing was inferred from
  the vault paying 19.53 USDC out on EVM after the send. A USDC `Transfer` log scan of blocks 48115829..48117428 shows
  no ERC-20 inflow to the vault (only its two claim payouts), and the vault's Core ledger was emptied by that send
  (its whole NAV today is 0.002411 USDC on EVM). Historical balances are not served by the RPC, so this is an
  inference, not a balance diff.
- Open: sizes above 19.5 USDC for A-07; Core-side rate limits for large `sendAsset`; behaviour of `sendAsset` /
  `usdClassTransfer` under unified / portfolio margin abstraction (lead's item 3).
