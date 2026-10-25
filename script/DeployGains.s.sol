// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GainsVault} from "../src/gains/GainsVault.sol";
import {GainsVaultLens} from "../src/gains/GainsVaultLens.sol";
import {GainsVaultPolicy} from "../src/gains/GainsVaultPolicy.sol";
import {GainsVaultFactory} from "../src/gains/GainsVaultFactory.sol";
import {IGainsDiamond} from "../src/gains/IGainsDiamond.sol";
import {LinkedLibraries} from "./Deploy.s.sol";

/// @notice Arbitrum One addresses (PLAN.md section 2, verified in STAGE0.md A4 / A7).
library GainsAddresses {
    uint256 constant CHAIN = 42161;
    address constant DIAMOND = 0xFF162c694eAA571f685030649814282eA457f169;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // native USDC, collateral index 3
    address constant SEQUENCER = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;
    uint256 constant SEQUENCER_GRACE = 3_600;

    address constant BTC_USD = 0x6ce185860a4963106506C203335A2910413708e9;
    address constant ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address constant SOL_USD = 0x24ceA4b8ce57cdA5058b924B9B9987992450590c;

    /// @notice Curation table: Gains pair index -> Chainlink feed, staleness limit (heartbeat + margin) and NAV band
    ///         (deviation threshold + 15 bps measured spread, PLAN.md 4.3).
    function pair(uint256 index) internal pure returns (address feed, uint32 maxAge, uint16 bandBps) {
        if (index == 0) return (BTC_USD, 1_755 + 900, 20);
        if (index == 1) return (ETH_USD, 1_755 + 900, 20);
        if (index == 33) return (SOL_USD, 86_400 + 1_800, 25);
        revert("no curation entry for this pair");
    }
}

/// @notice Deploys the Gains platform on Arbitrum One: the three linked libraries (GainsNav, GainsVaultLogic,
///         GainsVaultGovernance; forge deploys and links them), the GainsVault and GainsVaultPolicy implementations,
///         the lens and the factory; curates BTC, ETH and SOL with their feeds and bands; applies the platform setup
///         and hands the factory to PLATFORM_GUARDIAN (two step). Records every address in deployments/arbitrum.json.
///         The Gains counterpart of script/Deploy.s.sol (DeployFactory): same env, same reporting, same rule that
///         nothing reads addresses derived from bytecode (linked libraries come from the artifacts' linkReferences).
///
/// Env (as Deploy.s.sol, minus the HyperCore values):
///   OWNER, PROTOCOL_FEE_RECIPIENT, PLATFORM_GUARDIAN, PLATFORM_SENTINEL   required
///   AGENT_REGISTRAR      optional
///   CURATED_ASSETS       optional, comma separated Gains pair indexes, default "0,1,33"
///   MAX_DEPOSIT_CAP      optional, default type(uint256).max (no platform limit)
///   BASE_SHARE_BPS / HOSTED_SHARE_BPS   optional, default 1000 / 3300
///   MIN_SEED_USDC        optional, default 1e6
///   MIN_AGENT_GAS_WEI    optional, default 0.001 ether
///   ALLOW_LAUNCHER       optional
///   DEPLOY_SKIP_RECORD   true for dry runs: nothing is written
///   DEPLOY_RECORD_NAME   optional file name under deployments/ (default arbitrum.json on 42161)
contract DeployGainsFactory is Script {
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
        uint256 minAgentGas;
        address allow;
    }

    struct Deployment {
        address nav;
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

    /// @notice The last deployment this script instance reported (tests read it).
    Deployment public last;

    function run()
        external
        returns (GainsVault vaultImpl, GainsVaultPolicy policyImpl, GainsVaultLens lens, GainsVaultFactory factory)
    {
        return deploy(_config(), !vm.envOr("DEPLOY_SKIP_RECORD", false), vm.envOr("DEPLOY_RECORD_NAME", string("arbitrum.json")));
    }

    /// @notice The deployment itself, without env reads (forge tests call it directly: env vars are process wide and
    ///         the HL DeployFactory test sets the same names in parallel).
    /// @param record write deployments/<recordName>
    function deploy(Config memory c, bool record, string memory recordName)
        public
        returns (GainsVault vaultImpl, GainsVaultPolicy policyImpl, GainsVaultLens lens, GainsVaultFactory factory)
    {
        require(block.chainid == GainsAddresses.CHAIN, "DeployGains targets Arbitrum One (42161)");

        vm.startBroadcast();
        vaultImpl = new GainsVault(); // forge deploys and links GainsNav, GainsVaultLogic and GainsVaultGovernance first
        policyImpl = new GainsVaultPolicy();
        lens = new GainsVaultLens();
        factory = new GainsVaultFactory(
            c.owner,
            address(vaultImpl),
            address(policyImpl),
            IERC20(GainsAddresses.USDC),
            IGainsDiamond(GainsAddresses.DIAMOND),
            GainsAddresses.SEQUENCER,
            GainsAddresses.SEQUENCER_GRACE,
            c.treasury,
            c.guardian,
            c.sentinel
        );
        _setup(factory, c);
        vm.stopBroadcast();

        _report(
            Deployment({
                nav: address(0),
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
            }),
            record,
            recordName
        );
    }

    function _config() internal view returns (Config memory c) {
        c.owner = vm.envAddress("OWNER");
        c.treasury = vm.envAddress("PROTOCOL_FEE_RECIPIENT");
        c.guardian = vm.envAddress("PLATFORM_GUARDIAN");
        c.sentinel = vm.envAddress("PLATFORM_SENTINEL");
        c.registrar = vm.envOr("AGENT_REGISTRAR", address(0));
        uint256[] memory curatedDefault = new uint256[](3);
        curatedDefault[0] = 0;
        curatedDefault[1] = 1;
        curatedDefault[2] = 33;
        c.curated = vm.envOr("CURATED_ASSETS", ",", curatedDefault);
        c.maxCap = vm.envOr("MAX_DEPOSIT_CAP", type(uint256).max);
        require(c.maxCap > 0, "MAX_DEPOSIT_CAP must be > 0");
        c.baseShare = vm.envOr("BASE_SHARE_BPS", uint256(1_000));
        c.hostedShare = vm.envOr("HOSTED_SHARE_BPS", uint256(3_300));
        c.minSeed = vm.envOr("MIN_SEED_USDC", uint256(1e6));
        c.minAgentGas = vm.envOr("MIN_AGENT_GAS_WEI", uint256(0.001 ether));
        c.allow = vm.envOr("ALLOW_LAUNCHER", address(0));
    }

    /// @dev Setters run as the broadcaster, so they only work when OWNER is the deployer. Ownership then moves to
    ///      the cold guardian (Ownable2Step): nothing changes until it accepts.
    function _setup(GainsVaultFactory factory, Config memory c) internal {
        for (uint256 i; i < c.curated.length; ++i) {
            (address feed, uint32 maxAge, uint16 band) = GainsAddresses.pair(c.curated[i]);
            factory.setAssetCurated(uint32(c.curated[i]), true, feed, maxAge, band);
        }
        if (c.registrar != address(0)) factory.setAgentRegistrar(c.registrar);
        if (c.maxCap != 50_000e6) factory.setMaxDepositCap(c.maxCap);
        if (c.baseShare != 1_000 || c.hostedShare != 3_300) factory.setShares(uint16(c.baseShare), uint16(c.hostedShare));
        if (c.minSeed != 1e6) factory.setMinSeedUsdc(c.minSeed);
        if (c.minAgentGas != 0.001 ether) factory.setMinAgentGas(c.minAgentGas);
        if (c.allow != address(0)) factory.setLauncherAllowed(c.allow, true);
        if (c.guardian != c.owner) factory.transferOwnership(c.guardian);
    }

    /// @notice Library addresses linked into `vaultImpl`, cross checked against the libraries' own links (two local
    ///         code reads per library, no RPC scanning).
    function resolveLibraries(address vaultImpl) public view returns (address nav, address logic, address governance) {
        bytes memory implCode = vaultImpl.code;
        require(implCode.length > 0, "implementation has no code");
        string memory art = "out/GainsVault.sol/GainsVault.json";
        governance = LinkedLibraries.linked(vm, art, "src/gains/GainsVaultGovernance.sol", "GainsVaultGovernance", implCode);
        logic = LinkedLibraries.linked(vm, art, "src/gains/GainsVaultLogic.sol", "GainsVaultLogic", implCode);
        nav = LinkedLibraries.linked(vm, art, "src/gains/GainsNav.sol", "GainsNav", implCode);
        bytes memory govCode = governance.code;
        require(govCode.length > 0, "GainsVaultGovernance has no code");
        string memory govArt = "out/GainsVaultGovernance.sol/GainsVaultGovernance.json";
        require(
            LinkedLibraries.linked(vm, govArt, "src/gains/GainsVaultLogic.sol", "GainsVaultLogic", govCode) == logic,
            "GainsVaultGovernance links a different GainsVaultLogic than the implementation"
        );
        require(
            LinkedLibraries.linked(vm, govArt, "src/gains/GainsNav.sol", "GainsNav", govCode) == nav,
            "GainsVaultGovernance links a different GainsNav than the implementation"
        );
        bytes memory logicCode = logic.code;
        require(logicCode.length > 0, "GainsVaultLogic has no code");
        require(
            LinkedLibraries.linked(vm, "out/GainsVaultLogic.sol/GainsVaultLogic.json", "src/gains/GainsNav.sol", "GainsNav", logicCode)
                == nav,
            "GainsVaultLogic links a different GainsNav than the implementation"
        );
        require(nav.code.length > 0, "GainsNav has no code");
    }

    function _report(Deployment memory d, bool record, string memory recordName) internal {
        (d.nav, d.logic, d.governance) = resolveLibraries(d.vaultImpl);
        last = d;

        console2.log("GainsNav library            ", d.nav);
        console2.log("GainsVaultLogic library     ", d.logic);
        console2.log("GainsVaultGovernance library", d.governance);
        console2.log("GainsVault implementation   ", d.vaultImpl);
        console2.log("GainsVaultPolicy impl       ", d.policyImpl);
        console2.log("GainsVaultLens              ", d.lens);
        console2.log("GainsVaultFactory           ", d.factory);
        console2.log("");
        if (d.guardian != d.deployer) {
            console2.log("Pending owner (guardian)    ", d.guardian);
            console2.log("From the guardian wallet, send this transaction to the factory to accept ownership:");
            console2.log("  to:    ", d.factory);
            console2.log("  value:  0");
            console2.log("  data:   0x79ba5097   (acceptOwnership())");
            console2.log("  cast:   cast send", d.factory, "\"acceptOwnership()\" --rpc-url arbitrum --account guardian");
        }
        console2.log("Explorer verification needs the libraries:");
        console2.log("  --libraries src/gains/GainsNav.sol:GainsNav:", d.nav);
        console2.log("  --libraries src/gains/GainsVaultLogic.sol:GainsVaultLogic:", d.logic);
        console2.log("  --libraries src/gains/GainsVaultGovernance.sol:GainsVaultGovernance:", d.governance);
        if (record) _writeDeployment(d, recordName);
    }

    /// @dev The L2 block number (eth_blockNumber of the script's RPC); block.number off Arbitrum or without one.
    function _l2Block() internal returns (uint256 n) {
        if (block.chainid != 42161 && block.chainid != 421614) return block.number;
        try vm.rpc("eth_blockNumber", "[]") returns (bytes memory r) {
            for (uint256 i; i < r.length; ++i) {
                n = (n << 8) | uint8(r[i]);
            }
        } catch {
            n = block.number;
        }
    }

    /// @dev deployments/arbitrum.json: every address plus the deploy block, for verification, the executor env
    ///      (GAINS_FACTORY_ADDRESS, GAINS_LENS_ADDRESS, GAINS_INDEXER_START_BLOCK) and the webapp env.
    function _writeDeployment(Deployment memory d, string memory name) internal {
        string memory json = "gains-deployment";
        vm.serializeUint(json, "chainId", block.chainid);
        // On Arbitrum `block.number` is the L1 block: the executor's indexers count L2 blocks (eth_getLogs), so the
        // record takes the L2 head from the RPC (read before the broadcast: a lower bound of the deployment block).
        vm.serializeUint(json, "block", _l2Block());
        vm.serializeUint(json, "timestamp", block.timestamp);
        vm.serializeAddress(json, "deployer", d.deployer);
        vm.serializeAddress(json, "factory", d.factory);
        vm.serializeAddress(json, "lens", d.lens);
        vm.serializeAddress(json, "vaultImplementation", d.vaultImpl);
        vm.serializeAddress(json, "policyImplementation", d.policyImpl);
        vm.serializeAddress(json, "gainsNavLibrary", d.nav);
        vm.serializeAddress(json, "vaultLogicLibrary", d.logic);
        vm.serializeAddress(json, "vaultGovernanceLibrary", d.governance);
        vm.serializeAddress(json, "platformGuardian", d.guardian);
        vm.serializeAddress(json, "platformSentinel", d.sentinel);
        vm.serializeAddress(json, "agentRegistrar", d.registrar);
        vm.serializeAddress(json, "protocolFeeRecipient", d.treasury);
        vm.serializeAddress(json, "usdc", GainsAddresses.USDC);
        vm.serializeAddress(json, "diamond", GainsAddresses.DIAMOND);
        vm.serializeAddress(json, "sequencerFeed", GainsAddresses.SEQUENCER);
        vm.serializeBool(json, "ownershipPendingAcceptance", d.guardian != d.deployer);
        string memory out = vm.serializeString(json, "acceptOwnershipCalldata", "0x79ba5097");
        string memory path = string.concat("deployments/", name);
        vm.writeJson(out, path);
        console2.log("Written", path);
    }
}
