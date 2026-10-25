# hl-r2 STATIC: Slither, Aderyn (could not run) + manual pass, Lens and deploy scripts

Internal, AI-assisted review (sub-reviewer "flow"), 2026-10-19. Not an independent audit. Scope: `contracts/src`
without `gains/`, plus `script/Deploy.s.sol` and `script/LaunchPermit.s.sol` (manual).

## 1. Tools

| Tool | Version | Status |
|---|---|---|
| Slither | 0.11.6 (pip, venv `%TEMP%\dvsl`; the scratchpad path was too long for pip on Windows: `OSError … Windows Long Path support`) | **ran**. Targets `src/HyperVaultFactory.sol` and `src/HyperVaultLens.sol` (together they import every non-gains source file), `--filter-paths lib/ --exclude-dependencies`, solc 0.8.28, via-ir, cancun. crytic-compile drove `forge build --build-info` per target (it also ran `forge clean`, so the earlier `out/` was rebuilt afterwards) |
| Aderyn | 0.6.8 (latest release) | **could not run.** `npm i @cyfrin/aderyn`: `npm error Platform with type "Windows_NT" and architecture "x64" is not supported by @cyfrin/aderyn. Your system must be one of: aarch64-apple-darwin, aarch64-unknown-linux-gnu, x86_64-apple-darwin, x86_64-unknown-linux-gnu`. The GitHub release has no Windows asset; `cargo` / `rustup` are not installed; WSL is not installed (`wsl --status`: "The Windows Subsystem for Linux is not installed"); no Docker. Replaced by the manual pass in section 3 |

Raw results: `evidence/flow/slither-summary.txt` (155 unique results). Slither's line numbers are shifted by a few
lines on this CRLF checkout; the lines below are the real ones.

## 2. Slither triage (every result)

| Detector (count) | Impact / conf. | Results | Verdict |
|---|---|---|---|
| reentrancy-no-eth (1) | Medium / Medium | `HyperVaultFactory.unregisterPlatformAgent` (:316-328): state written after `HyperVault(vault).revokeAgent()` | **FP.** The callee is a clone of the fixed implementation the factory itself created (`isVault[vault]`), whose `revokeAgent` only calls CoreWriter (no callback into the factory). No attacker-controlled code runs in between |
| reentrancy-benign (2), reentrancy-events (17) | Low / Medium | factory `create`, `lowerProtocolShare`, `unregisterPlatformAgent`; vault `_stop`, `execute`, `initialize`, `triggerEmergency`, `_revokeAgent`, `bridgeToCore`, `bridgeToEvm`, `flatten`, `fundCoreGas`, `leaveHosted`, `moveUsd`, `placeOrder`, `seedCore`, `syncAgent` | **FP.** External calls go to the CoreWriter system contract (emits a log, no callback), the HYPE system contract, Circle USDC / CDW (no hooks), the factory, the policy clone or the vault itself (`execute`, whose targets are `onlySelf` setters). Accepted in round 1 (`audit/notes.md:13`: "Callee is the CoreWriter system contract (no callback)") |
| unused-return (10) | Medium / Medium | `settle` ignores `checkRisk` return; tuple partial reads (`riskLimits`, `claimableWithCarry`, `epochs`, `requests`, `markPx1e8`); **`_depositToCore` ignores `asset.approve` (VaultLogic.sol:488)** | **FP** for the tuples and `checkRisk` (intended). `approve`: Info only, fail-safe: Circle USDC returns true or reverts; a token returning false without approving makes the CDW's `transferFrom` revert the whole bridge. `forceApprove` would be the tidy form |
| incorrect-equality (9) | Medium / High | `eta == 0` (VaultPolicy allowAsset :301, applyTimelockDelay :324), `supply == 0` (Lens previews), `feeAssets == 0 || feeAssets >= assets` (Lens :91), enum equality in `_check` (:185), `owed == 0 || available >= owed` (VaultMath :258) | **FP.** Sentinel / unset values and enums; none compares a balance an attacker can steer by donation (supply cannot be forced to 0) |
| uninitialized-local (7) | Medium / Medium | counters `n`, `listed`, `expected`, `feeShares`, `protocolShares`, `carriedFrom` | **FP.** Zero default is the intended initial value in each (e.g. `expected` is always assigned or the call reverts, VaultGovernance.sol:336-341) |
| missing-zero-check (2) | Low / Medium | `setAgentRegistrar(registrar)`, `VaultPolicy.initialize(factory_)` | **FP, by design**: zero registrar = none (I2-05); zero factory = standalone policy |
| calls-loop (1) | Low / Medium | `VaultPolicy._checkCurated` in the `initialize` asset loop | **FP.** Trusted factory view, bounded by the launcher's own asset list |
| timestamp (20) | Low / Medium | timelocks, epochs, cooldowns, checkpoint age, agent deadline, Lens views | **Accepted.** Second-level proposer skew is irrelevant to day / hour scale rules (round 1 notes) |
| low-level-calls (3) | Info | precompile `staticcall` (HyperCore.sol:102), `address(this).call(data)` (VaultGovernance.sol:359), HYPE `call{value}` (VaultLogic.sol:507) | **FP**, each reviewed in FUND-FLOW.md section 4 (constant targets or the queue whitelist) |
| assembly (2) | Info | `VaultMath.erc20()` / `owner()` fixed slots | **FP.** Slots equal OZ v5.4 `ERC20StorageLocation` 0x52c63247…ace00 and `OwnableStorageLocation` 0x9016d09d…99300 (checked in `lib/openzeppelin-contracts-upgradeable`, ERC20Upgradeable.sol:44, OwnableUpgradeable.sol:28); `ERC20Storage` field order identical |
| cyclomatic-complexity (3), cache-array-length (5), unindexed-event-address (8), naming-convention (65) | Info / Optimization | `create`, `_check`, `settle`; view loops; events | No action (style / gas) |

Detectors with **no** result on this code (Slither's default high-impact set): arbitrary-send-erc20,
arbitrary-send-erc20-permit, arbitrary-send-eth, controlled-delegatecall, delegatecall-loop, msg-value-loop,
reentrancy-eth, suicidal, uninitialized-state, uninitialized-storage, unchecked-transfer, unchecked-lowlevel,
unprotected-upgrade, shadowing-state, shadowing-local, divide-before-multiply, weak-prng, locked-ether,
incorrect-shift, tautology, write-after-write, encode-packed-collision.

No Slither result is a true positive above Info.

## 3. Manual pass in place of Aderyn (its top detectors)

| Detector class | Result |
|---|---|
| Reentrancy | `requestDeposit`, `requestRedeem`, `settle` take the lock (VaultLogic.sol:636-643). `claim`, `cancelDepositRequest`, `cancelRedeemRequest` do not, but zero state before the single USDC transfer (CEI, :107-111, :145-153) and USDC has no hooks. `rescueToken` calls an owner-chosen token after no state change. Factory: external calls only to its own clones and USDC. No issue |
| Unchecked return | `approve` (above, fail-safe). All USDC moves use SafeERC20. CoreWriter returns nothing (fire and forget, by design D-4). `HYPE_SYSTEM_ADDRESS.call` is checked (:508). Precompile reads revert on failure (HyperCore.sol:103) |
| Arbitrary send | none: every recipient is msg.sender, the request's controller, the vault itself, a constant system address, the fee recipients, or the owner's `rescueToken(to)` for non-asset tokens (FUND-FLOW.md) |
| Uninitialized storage | none: storage pointers are `$` (slot 0 of the clone) or the two fixed OZ slots; OZ v5 Initializable / ERC20 / Ownable are namespaced, so no overlap with `$` |
| Shadowing | none flagged; parameters use `_` suffixes (`asset_`, `owner_`, `factory_`) |
| Divide before multiply | `spotBalance.total / 100` before `× 100` in bridgeToEvm drops < 100 wei (< 1e-6 USDC) of spot dust: harmless, makes the send never exceed the balance. PxMath divides by BPS then rounds to 5 s.f. in the safe direction (existing `testFuzz_BoundedPxWithinBand`) |
| Unsafe casts | all narrowing casts are `SafeCast` (toUint64 for HyperCore amounts, toUint192 for the checkpoint) or `uint64(block.timestamp)`; `uint256(uint64(accountValue))` only when `accountValue > 0` (VaultGovernance.sol:192, VaultPolicy.sol:194); `-int256(szi)` on int64 cannot overflow int256 |
| Missing zero checks | vault init checks manager, fee recipient, policy, CDW, guardian / factory (VaultGovernance.sol:58-61); owner zero is refused by OZ `__Ownable_init`; factory constructor and role setters check zero. Remaining zero inputs are deliberate (operator = none, registrar = none) |
| Locked ether | none: no `receive` / `fallback`; both payable entry points forward the full `msg.value` (`test_HLR2_FLOW_fundCoreGasForwardsAllValueAndKeepsNone`) |
| Delegatecall | only linked libraries and EIP-1167 clones to fixed addresses; libraries refuse direct calls (`test_HLR2_FLOW_libraryFunctionsRevertOnDirectCall`) |
| Centralization (Aderyn L-1 class) | known and accepted: factory owner = guardian EOA (HLO-08), vault owner timelock (H-01 fixed with queue whitelist) |

## 4. HyperVaultLens and the HyperEVM deploy scripts (domain 4)

### HyperVaultLens.sol

Stateless views; no value moves. Constants match the vault (`DECIMALS_OFFSET` 6, `ONE_SHARE` 1e12, `BPS`, `YEAR`;
breach reasons 2 / 3 = DAILY_LOSS / DRAWDOWN by enum order, VaultTypes.sol). Bytecode live = source (FUND-FLOW.md
section 5). `pendingFeeShares` computes the protocol part without checking `protocolFeeRecipient != 0`; the factory
forbids a zero recipient (constructor and `setProtocolFeeRecipient`), so it matches the vault. One finding:

**HLR2-F04 (Info): previews ignore exit-only pricing.** `previewRedeem` / `previewWithdraw` apply min(NAV,
checkpoint) only for a daily-loss or drawdown breach (HyperVaultLens.sol:102-109). An emergency settle, and a
platform settle of an overdue epoch, are exit-only: they pay at min(NAV, checkpoint) and refund deposits
(VaultLogic.sol:242-243, 252-253). In those states `previewRedeem` overstates the payout whenever NAV is above the
checkpoint, and `previewDeposit` shows shares for a deposit that an overdue exit-only settle refunds.
`previewEmergencyRedeem` is correct. PoC `test_HLR2_F04_lensPreviewRedeemIgnoresTheExitOnlyCheckpointCap`: NAV 1,100
vs checkpoint 1,000 in emergency, preview ≈ 1,100, actual claim 1,000. Impact: UI only (a depositor sees ~10% more
than the settle pays). Fix: in `_postFeeRedeem` also cap when `v.emergency()` (and when the epoch is overdue), or
point the UI at `previewEmergencyRedeem` in emergency.

### script/Deploy.s.sol

| Item | Check | Result |
|---|---|---|
| Mainnet constants | `USDC_MAINNET 0xb88339CB…630f` (HL docs "USDC" page links this token), `CDW_MAINNET 0x6B9E7731…0A24` (Circle address page) | correct; the live factory's immutables equal them |
| Testnet constants | 0x2B3370eE…8Ab / 0x0B80659a…206 | not verified (testnet out of scope) |
| Chain selection | `block.chainid == 998 ? testnet : mainnet` | any other chain (e.g. a local anvil) gets the mainnet constants; harmless for rehearsals, wrong for a different live chain (none planned) |
| Role wiring | constructor(owner = OWNER, guardian, sentinel); setters run as the broadcaster; `transferOwnership(guardian)` when guardian ≠ owner | correct: the constructor's `_checkRoles` refuses guardian = sentinel and sentinel = owner; if OWNER is not the broadcaster the setters revert in simulation and nothing is sent. Live: owner = guardian accepted, no pending owner |
| `openLaunch` | never set by the script (default false) | correct (live `true` was set later by the owner, a decision covered by HLO) |
| Cap | `MAX_DEPOSIT_CAP` default `type(uint256).max`, 0 refused | as decided 2026-10-13 |
| Library links | `resolveLibraries` reads link offsets from the artifact, cross-checks VaultGovernance's own VaultLogic link | correct; live: VaultGovernance links the same VaultLogic as the implementation (bytecode compare) |
| `CURATED_ASSETS` | `uint32(c.curated[i])` | **HLR2-F07 (Info)**: a value ≥ 2^32 is silently truncated (e.g. 4294967296 curates asset 0). Operator input only; add `require(c.curated[i] <= type(uint32).max)`. Same in `LaunchVault` / `LaunchVaultPermit` `ASSETS` (the factory then refuses non-curated ids, so the effect is a wrong-but-curated asset at worst) |
| `DeployVault` (standalone, reference) | guardian = sentinel by construction, `DEPOSIT_CAP` default 0 = uncapped | Info (part of F07): the platform never uses it; mark it test-only |
| `LaunchVault` | defaults OWNER / MANAGER / FEE_RECIPIENT to `msg.sender`; `predictVaultAddress(me, salt)` | fine when run with one `--account` (forge then uses it as the sender); approves exactly `seedUsdc` |

### script/LaunchPermit.s.sol

Permit `value = p.seedUsdc`, spender = factory, nonce read from USDC, deadline +1 h, signed with `vm.sign(me, …)`
(keystore). The factory pulls exactly `seedUsdc` from `msg.sender`, so the allowance returns to 0 (the script prints
it before and after). `DEPOSIT_CAP` default 100e6 (≤ max cap). No issue.

## 5. Other Info items (fund-flow domain)

**HLR2-F03 (Info): shares sent to the vault are stranded.** The vault holds redemption escrow at its own address. A
plain `transfer(vault, x)` of shares joins no request; nothing (cancel, claim, settle, rescueToken, which excludes the
vault's own shares) ever returns or burns them, so they stay in `totalSupply` and their NAV share is locked for good.
Nobody else gains or loses. PoC `test_HLR2_F03_sharesSentToTheVaultAreStranded` (10% of the supply, about 100 USDC of
NAV, stranded after everyone else exited). Fix (optional): make `transfer` / `transferFrom` to `address(this)` revert
(override `_update`), as is common for ERC-4626 vaults with escrow.

**HLR2-F08 (Info): a deposit made for another controller belongs to that controller.** `requestDeposit(assets,
controller)` lets the payer name any controller; `cancelDepositRequest` refunds `msg.sender` = the controller
(VaultLogic.sol:99, 111). This is ERC-7540 semantics, not a bug; the UI should say so where it offers "deposit for".
