// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {HyperVault} from "../src/HyperVault.sol";
import {HyperVaultLens} from "../src/HyperVaultLens.sol";
import {VaultPolicy} from "../src/VaultPolicy.sol";
import {InitParams} from "../src/VaultTypes.sol";
import {HyperVaultFactory} from "../src/HyperVaultFactory.sol";
import {ICoreDepositWallet} from "../src/hypercore/HyperCore.sol";

library Addresses {
    // Mainnet (chain 999). Testnet (998) values are picked automatically.
    address constant USDC_MAINNET = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
    address constant USDC_TESTNET = 0x2B3370eE501B4a559b57D449569354196457D8Ab;
    address constant CDW_MAINNET = 0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24;
    address constant CDW_TESTNET = 0x0B80659a4076E9E93C7DbE0f10675A16a3e5C206;

    function usdc() internal view returns (address) {
        return block.chainid == 998 ? USDC_TESTNET : USDC_MAINNET;
    }

    function cdw() internal view returns (address) {
        return block.chainid == 998 ? CDW_TESTNET : CDW_MAINNET;
    }
}

/// @dev Reads the addresses forge linked into a contract's runtime code. The link offsets come from the compiler
///      artifact (`deployedBytecode.linkReferences`), the bytes at those offsets from the code that is already in
///      the local EVM state, so this never touches the RPC. (An earlier version scanned every 20 byte window of the
///      bytecode and asked the fork for each one's code: ~15,000 eth_getCode calls per run, which rate limited
///      public RPCs and aborted the simulation.)
library LinkedLibraries {
    /// @param artifact e.g. "out/HyperVault.sol/HyperVault.json"
    /// @param sourcePath e.g. "src/VaultGovernance.sol"
    /// @param libName e.g. "VaultGovernance"
    /// @param code the deployed runtime code of the linked contract
    /// @return lib the linked address; reverts when the offsets disagree or none exist
    function linked(Vm vm, string memory artifact, string memory sourcePath, string memory libName, bytes memory code)
        internal
        view
        returns (address lib)
    {
        string memory json = vm.readFile(artifact);
        string memory key = string.concat(".deployedBytecode.linkReferences['", sourcePath, "'].", libName);
        bytes memory raw = vm.parseJson(json, key);
        Ref[] memory refs = abi.decode(raw, (Ref[]));
        require(refs.length > 0, string.concat("no link references for ", libName));
        for (uint256 i; i < refs.length; ++i) {
            require(refs[i].length == 20 && refs[i].start + 20 <= code.length, "bad link reference");
            address at = _addressAt(code, refs[i].start);
            if (i == 0) lib = at;
            else require(at == lib, string.concat("inconsistent link for ", libName));
        }
        require(lib != address(0), string.concat("unlinked ", libName));
    }

    /// @dev Field order must be alphabetical for vm.parseJson: {"length": 20, "start": N}.
    struct Ref {
        uint256 length;
        uint256 start;
    }

    function _addressAt(bytes memory code, uint256 offset) private pure returns (address a) {
        assembly {
            a := shr(96, mload(add(add(code, 0x20), offset)))
        }
    }
}

/// @notice Deploys the platform: the two logic libraries (linked automatically), HyperVault implementation,
///         VaultPolicy implementation, the read-only lens and the factory, applies the platform setup (registrar,
///         curated assets, cap, launcher allowlist), hands the factory ownership to PLATFORM_GUARDIAN (two step:
///         the guardian wallet must call acceptOwnership, printed at the end) and records every address in
///         deployments/<mainnet|testnet>.json.
/// @dev The deployer must use HyperEVM big blocks for this one script. Managers launching through the factory
///      never need big blocks: a create is a pair of EIP-1167 clones.
///      RPC use: the simulation forks the chain and reads only what the transactions touch (the sender's nonce and
///      balance, the USDC / CoreDepositWallet code checks in the constructor). Nothing in the script reads
///      addresses derived from bytecode. Run with `--slow` so every transaction is mined before the next is sent,
///      and `--compute-units-per-second 50` (or lower) on a public RPC that rate limits (error -32005).
///
/// Env:
///   OWNER                     initial factory owner (the deployer: the setters below run as the broadcaster)
///   PROTOCOL_FEE_RECIPIENT    treasury
///   PLATFORM_GUARDIAN         cold guardian read live by every factory vault (a multisig, never on a server);
///                             also the factory owner once it accepts (owner == guardian is allowed)
///   PLATFORM_SENTINEL         hot sentinel read live by every factory vault (the executor's SENTINEL_KEY wallet)
///   AGENT_REGISTRAR           optional, wallet allowed to register platform agents (the executor's registrar)
///   CURATED_ASSETS            optional, comma separated perp indices, default "0,1" (BTC, ETH)
///   MAX_DEPOSIT_CAP           optional, default type(uint256).max (no platform limit, decision of 2026-10-13); 0 is refused
///   BASE_SHARE_BPS            optional, default 1000 (10% of manager fees, own strategy)
///   HOSTED_SHARE_BPS          optional, default 3300 (33% of manager fees, hosted strategy)
///   MIN_SEED_USDC             optional, default 2e6
///   MIN_HYPE_WEI              optional, default 0.01 ether
///   ALLOW_LAUNCHER            optional, one address to allowlist right away
contract DeployFactory is Script {
    struct Config {
        address owner;
        address treasury;
        address guardian;
        address sentinel;
        address registrar;
        uint256[] curated;
        uint256 maxCap;
        uint256 baseShare;
        uint256 hostedShare;
        uint256 minSeed;
        uint256 minHype;
        address allow;
    }

    function run()
        external
        returns (HyperVault vaultImpl, VaultPolicy policyImpl, HyperVaultLens lens, HyperVaultFactory factory)
    {
        Config memory c = _config();

        vm.startBroadcast();
        vaultImpl = new HyperVault(); // forge deploys and links VaultLogic and VaultGovernance first
        policyImpl = new VaultPolicy();
        lens = new HyperVaultLens();
        factory = new HyperVaultFactory(
            c.owner,
            address(vaultImpl),
            address(policyImpl),
            IERC20(Addresses.usdc()),
            ICoreDepositWallet(Addresses.cdw()),
            c.treasury,
            c.guardian,
            c.sentinel
        );
        _setup(factory, c);
        vm.stopBroadcast();

        _report(
            Deployment({
                logic: address(0),
                governance: address(0),
                vaultImpl: address(vaultImpl),
                policyImpl: address(policyImpl),
                lens: address(lens),
                factory: address(factory),
                guardian: c.guardian,
                sentinel: c.sentinel,
                registrar: c.registrar,
                treasury: c.treasury,
                deployer: c.owner
            })
        );
    }

    function _config() internal view returns (Config memory c) {
        c.owner = vm.envAddress("OWNER");
        c.treasury = vm.envAddress("PROTOCOL_FEE_RECIPIENT");
        c.guardian = vm.envAddress("PLATFORM_GUARDIAN");
        c.sentinel = vm.envAddress("PLATFORM_SENTINEL");
        c.registrar = vm.envOr("AGENT_REGISTRAR", address(0));
        uint256[] memory curatedDefault = new uint256[](2);
        curatedDefault[0] = 0;
        curatedDefault[1] = 1;
        c.curated = vm.envOr("CURATED_ASSETS", ",", curatedDefault);
        // No platform limit by default (2026-10-13): type(uint256).max. Vaults are uncapped unless their owner sets a cap.
        // Set MAX_DEPOSIT_CAP (6 decimals) to bring a platform limit back; 0 is refused.
        c.maxCap = vm.envOr("MAX_DEPOSIT_CAP", type(uint256).max);
        require(c.maxCap > 0, "MAX_DEPOSIT_CAP must be > 0");
        c.baseShare = vm.envOr("BASE_SHARE_BPS", uint256(1_000));
        c.hostedShare = vm.envOr("HOSTED_SHARE_BPS", uint256(3_300));
        c.minSeed = vm.envOr("MIN_SEED_USDC", uint256(2e6));
        c.minHype = vm.envOr("MIN_HYPE_WEI", uint256(0.01 ether));
        c.allow = vm.envOr("ALLOW_LAUNCHER", address(0));
    }

    /// @dev Setters run as the broadcaster, so they only work when OWNER is the deployer. Ownership then moves to
    ///      the cold guardian (Ownable2Step): nothing changes until it accepts.
    function _setup(HyperVaultFactory factory, Config memory c) internal {
        for (uint256 i; i < c.curated.length; ++i) {
            factory.setAssetCurated(uint32(c.curated[i]), true);
        }
        if (c.registrar != address(0)) factory.setAgentRegistrar(c.registrar);
        if (c.maxCap != 50_000e6) factory.setMaxDepositCap(c.maxCap);
        if (c.baseShare != 1_000 || c.hostedShare != 3_300) factory.setShares(uint16(c.baseShare), uint16(c.hostedShare));
        if (c.minSeed != 2e6) factory.setMinSeedUsdc(c.minSeed);
        if (c.minHype != 0.01 ether) factory.setMinHypeValue(c.minHype);
        if (c.allow != address(0)) factory.setLauncherAllowed(c.allow, true);
        if (c.guardian != c.owner) factory.transferOwnership(c.guardian);
    }

    /// @notice The last deployment this script instance reported (tests read it).
    Deployment public last;

    /// @notice Library addresses linked into `vaultImpl`: VaultLogic (via VaultGovernance's own links, cross checked
    ///         against the implementation's) and VaultGovernance.
    function resolveLibraries(address vaultImpl) public view returns (address logic, address governance) {
        bytes memory implCode = vaultImpl.code;
        require(implCode.length > 0, "implementation has no code");
        governance = LinkedLibraries.linked(vm, "out/HyperVault.sol/HyperVault.json", "src/VaultGovernance.sol", "VaultGovernance", implCode);
        logic = LinkedLibraries.linked(vm, "out/HyperVault.sol/HyperVault.json", "src/VaultLogic.sol", "VaultLogic", implCode);
        bytes memory govCode = governance.code;
        require(govCode.length > 0, "VaultGovernance has no code");
        address logicViaGov = LinkedLibraries.linked(vm, "out/VaultGovernance.sol/VaultGovernance.json", "src/VaultLogic.sol", "VaultLogic", govCode);
        require(logicViaGov == logic, "VaultGovernance links a different VaultLogic than the implementation");
        require(logic.code.length > 0, "VaultLogic has no code");
    }

    struct Deployment {
        address logic;
        address governance;
        address vaultImpl;
        address policyImpl;
        address lens;
        address factory;
        address guardian;
        address sentinel;
        address registrar;
        address treasury;
        address deployer;
    }

    /// @dev Resolves the linked library addresses from the artifacts' link references and the code forge just
    ///      deployed (two local code reads, no RPC scanning), checks that every reference agrees and that the
    ///      libraries are the ones VaultGovernance itself links against.
    function _report(Deployment memory d) internal {
        (d.logic, d.governance) = resolveLibraries(d.vaultImpl);
        last = d;

        console2.log("VaultLogic library        ", d.logic);
        console2.log("VaultGovernance library   ", d.governance);
        console2.log("HyperVault implementation ", d.vaultImpl);
        console2.log("VaultPolicy implementation", d.policyImpl);
        console2.log("HyperVaultLens            ", d.lens);
        console2.log("HyperVaultFactory         ", d.factory);
        console2.log("");
        if (d.guardian != d.deployer) {
            console2.log("Pending owner (guardian)  ", d.guardian);
            console2.log("From the guardian wallet, send this transaction to the factory to accept ownership:");
            console2.log("  to:    ", d.factory);
            console2.log("  value:  0");
            console2.log("  data:   0x79ba5097   (acceptOwnership())");
            console2.log("  cast:   cast send", d.factory, "\"acceptOwnership()\" --rpc-url hyperevm --legacy --account guardian");
        }
        console2.log("Explorer verification needs the libraries:");
        console2.log("  --libraries src/VaultLogic.sol:VaultLogic:", d.logic);
        console2.log("  --libraries src/VaultGovernance.sol:VaultGovernance:", d.governance);
        _writeDeployment(d);
    }

    /// @dev deployments/mainnet.json (chain 999) or deployments/testnet.json (998): every address plus the
    ///      deploy block, for verification, the executor env and the webapp env.
    function _writeDeployment(Deployment memory d) internal {
        if (vm.envOr("DEPLOY_SKIP_RECORD", false)) return; // the forge test runs this script at chain id 999
        string memory json = "deployment";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeUint(json, "block", block.number);
        vm.serializeUint(json, "timestamp", block.timestamp);
        vm.serializeAddress(json, "deployer", d.deployer);
        vm.serializeAddress(json, "factory", d.factory);
        vm.serializeAddress(json, "lens", d.lens);
        vm.serializeAddress(json, "vaultImplementation", d.vaultImpl);
        vm.serializeAddress(json, "policyImplementation", d.policyImpl);
        vm.serializeAddress(json, "vaultLogicLibrary", d.logic);
        vm.serializeAddress(json, "vaultGovernanceLibrary", d.governance);
        vm.serializeAddress(json, "platformGuardian", d.guardian);
        vm.serializeAddress(json, "platformSentinel", d.sentinel);
        vm.serializeAddress(json, "agentRegistrar", d.registrar);
        vm.serializeAddress(json, "protocolFeeRecipient", d.treasury);
        vm.serializeAddress(json, "usdc", Addresses.usdc());
        vm.serializeAddress(json, "coreDepositWallet", Addresses.cdw());
        vm.serializeBool(json, "ownershipPendingAcceptance", d.guardian != d.deployer);
        string memory out = vm.serializeString(json, "acceptOwnershipCalldata", "0x79ba5097");
        string memory name = block.chainid == 999 ? "mainnet" : block.chainid == 998 ? "testnet" : string.concat("local-", vm.toString(block.chainid));
        string memory path = string.concat("deployments/", name, ".json");
        vm.writeJson(out, path);
        console2.log("Written", path);
    }
}

/// @notice Binds (or unbinds) a platform agent to one vault on an existing factory. Run by the factory owner or
///         the agent registrar. Env: FACTORY, AGENT, VAULT (the predicted or existing vault address; see
///         predictVaultAddress(creator, salt)), REGISTER (bool, default true).
contract RegisterPlatformAgent is Script {
    function run() external {
        HyperVaultFactory factory = HyperVaultFactory(vm.envAddress("FACTORY"));
        address agent = vm.envAddress("AGENT");
        bool register = vm.envOr("REGISTER", true);
        vm.startBroadcast();
        if (register) factory.registerPlatformAgent(agent, vm.envAddress("VAULT"));
        else factory.unregisterPlatformAgent(agent);
        vm.stopBroadcast();
        console2.log("platformAgentFor", agent, factory.platformAgentFor(agent));
    }
}

/// @notice Launches a vault through an existing factory from the broadcaster's wallet. Small block friendly.
/// @dev Uses the allowance path (approve USDC to the factory first, or set APPROVE=true to do it here).
///
/// Env:
///   FACTORY                  factory address
///   VAULT_NAME, VAULT_SYMBOL strings
///   OWNER, MANAGER, FEE_RECIPIENT             default to the broadcaster when unset (guardian is the platform's)
///   MGMT_FEE_BPS, PERF_FEE_BPS                default 200 / 2000
///   DEPOSIT_CAP              USDC 6 decimals, default type(uint256).max = no cap (must be > 0 and <= factory.maxDepositCap())
///   TIMELOCK_DELAY           seconds, default 2 days
///   ASSETS                   comma separated perp indices, e.g. "0,1" (must be curated on the factory)
///   AGENT                    optional platform agent approved at creation (must be registered on the factory)
///   HOSTED                   bool, default false
///   SEED_USDC                default 2e6
///   HYPE_WEI                 msg.value, default 0.01 ether
///   SALT                     bytes32, default keccak(name)
///   APPROVE                  bool, approve the seed to the factory in the same run (default true)
contract LaunchVault is Script {
    function run() external returns (address vault, address policy) {
        HyperVaultFactory factory = HyperVaultFactory(vm.envAddress("FACTORY"));
        address me = msg.sender;
        string memory name = vm.envOr("VAULT_NAME", string("Test Vault"));

        uint256[] memory rawAssets = vm.envOr("ASSETS", ",", new uint256[](0));
        uint32[] memory assets = new uint32[](rawAssets.length == 0 ? 2 : rawAssets.length);
        if (rawAssets.length == 0) {
            assets[0] = 0;
            assets[1] = 1;
        } else {
            for (uint256 i; i < rawAssets.length; ++i) {
                assets[i] = uint32(rawAssets[i]);
            }
        }

        HyperVaultFactory.CreateParams memory p = HyperVaultFactory.CreateParams({
            name: name,
            symbol: vm.envOr("VAULT_SYMBOL", string("dpTEST")),
            owner: vm.envOr("OWNER", me),
            manager: vm.envOr("MANAGER", me),
            feeRecipient: vm.envOr("FEE_RECIPIENT", me),
            managementFeeBps: uint16(vm.envOr("MGMT_FEE_BPS", uint256(200))),
            performanceFeeBps: uint16(vm.envOr("PERF_FEE_BPS", uint256(2_000))),
            timelockDelay: vm.envOr("TIMELOCK_DELAY", uint256(2 days)),
            depositCap: vm.envOr("DEPOSIT_CAP", type(uint256).max),
            risk: VaultPolicy.RiskConfig({
                maxLeverageBps: uint32(vm.envOr("MAX_LEVERAGE_BPS", uint256(30_000))),
                maxDailyLossBps: uint32(vm.envOr("MAX_DAILY_LOSS_BPS", uint256(500))),
                maxDrawdownBps: uint32(vm.envOr("MAX_DRAWDOWN_BPS", uint256(1_500))),
                maxSlippageBps: uint32(vm.envOr("MAX_SLIPPAGE_BPS", uint256(100))),
                maxOrderNotional: uint64(vm.envOr("MAX_ORDER_NOTIONAL", uint256(250_000e6))),
                maxEpochDuration: uint64(vm.envOr("MAX_EPOCH_DURATION", uint256(7 days))),
                maxNavMoveBps: uint32(vm.envOr("MAX_NAV_MOVE_BPS", uint256(2_000))),
                maxFlattenSlippageBps: uint32(vm.envOr("MAX_FLATTEN_SLIPPAGE_BPS", uint256(300)))
            }),
            assets: assets,
            agent: vm.envOr("AGENT", address(0)),
            agentSig: vm.envOr("AGENT_SIG", bytes("")),
            agentDeadline: vm.envOr("AGENT_DEADLINE", uint256(0)),
            operator: vm.envOr("OPERATOR", address(0)),
            hosted: vm.envOr("HOSTED", false),
            seedUsdc: vm.envOr("SEED_USDC", uint256(2e6)),
            salt: vm.envOr("SALT", keccak256(bytes(name)))
        });
        uint256 hype = vm.envOr("HYPE_WEI", uint256(0.01 ether));
        HyperVaultFactory.PermitData memory noPermit = HyperVaultFactory.PermitData(0, 0, 0, bytes32(0), bytes32(0));

        console2.log("Predicted vault", factory.predictVaultAddress(me, p.salt));

        vm.startBroadcast();
        if (vm.envOr("APPROVE", true)) IERC20(address(factory.usdc())).approve(address(factory), p.seedUsdc);
        (vault, policy) = factory.create{value: hype}(p, noPermit);
        vm.stopBroadcast();

        console2.log("HyperVault ", vault);
        console2.log("VaultPolicy", policy);
        console2.log(
            "Next: script/py/check_vault.py <vault> --mainnet should show coreActive, spot USDC and spot HYPE."
        );
    }
}

/// @notice Reference path: a standalone vault (no factory, no protocol share) as a clone of fresh implementations.
/// @dev Kept for completeness; the platform only launches through the factory. Needs big blocks (implementations).
/// Env: OWNER, MANAGER, GUARDIAN, FEE_RECIPIENT, VAULT_NAME, VAULT_SYMBOL, MGMT_FEE_BPS, PERF_FEE_BPS,
///      DEPOSIT_CAP, TIMELOCK_DELAY, ASSETS
contract DeployVault is Script {
    function run() external returns (HyperVault vault, VaultPolicy policy) {
        address owner = vm.envAddress("OWNER");
        uint256 timelock = vm.envOr("TIMELOCK_DELAY", uint256(2 days));
        uint256[] memory rawAssets = vm.envUint("ASSETS", ",");
        uint32[] memory assets = new uint32[](rawAssets.length);
        for (uint256 i; i < rawAssets.length; ++i) {
            assets[i] = uint32(rawAssets[i]);
        }

        VaultPolicy.RiskConfig memory risk = VaultPolicy.RiskConfig({
            maxLeverageBps: uint32(vm.envOr("MAX_LEVERAGE_BPS", uint256(30_000))),
            maxDailyLossBps: uint32(vm.envOr("MAX_DAILY_LOSS_BPS", uint256(500))),
            maxDrawdownBps: uint32(vm.envOr("MAX_DRAWDOWN_BPS", uint256(1_500))),
            maxSlippageBps: uint32(vm.envOr("MAX_SLIPPAGE_BPS", uint256(100))),
            maxOrderNotional: uint64(vm.envOr("MAX_ORDER_NOTIONAL", uint256(250_000e6))),
            maxEpochDuration: uint64(vm.envOr("MAX_EPOCH_DURATION", uint256(7 days))),
            maxNavMoveBps: uint32(vm.envOr("MAX_NAV_MOVE_BPS", uint256(2_000))),
            maxFlattenSlippageBps: uint32(vm.envOr("MAX_FLATTEN_SLIPPAGE_BPS", uint256(300)))
        });

        vm.startBroadcast();
        HyperVault vaultImpl = new HyperVault();
        VaultPolicy policyImpl = new VaultPolicy();
        policy = VaultPolicy(Clones.clone(address(policyImpl)));
        policy.initialize(owner, risk, assets, timelock, address(0));
        vault = HyperVault(Clones.clone(address(vaultImpl)));
        vault.initialize(
            InitParams({
                asset: IERC20(Addresses.usdc()),
                name: vm.envOr("VAULT_NAME", string("DojiPad Vault")),
                symbol: vm.envOr("VAULT_SYMBOL", string("dpVLT")),
                owner: owner,
                manager: vm.envAddress("MANAGER"),
                guardian: vm.envAddress("GUARDIAN"),
                feeRecipient: vm.envAddress("FEE_RECIPIENT"),
                managementFeeBps: uint16(vm.envOr("MGMT_FEE_BPS", uint256(0))),
                performanceFeeBps: uint16(vm.envOr("PERF_FEE_BPS", uint256(0))),
                timelockDelay: timelock,
                depositCap: vm.envOr("DEPOSIT_CAP", uint256(0)),
                policy: policy,
                coreDepositWallet: ICoreDepositWallet(Addresses.cdw()),
                factory: address(0),
                protocolShareBps: 0,
                baseShareBps: 0,
                hosted: false,
                agent: address(0),
                operator: address(0),
                seedUsdc: 0
            })
        );
        vm.stopBroadcast();

        console2.log("VaultPolicy", address(policy));
        console2.log("HyperVault ", address(vault));
        console2.log("Next: activate the vault on HyperCore (send >= 2 USDC + 0.05 HYPE spot to it on Core).");
    }
}
