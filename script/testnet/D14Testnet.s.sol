// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {HyperVault} from "../../src/HyperVault.sol";
import {VaultPolicy} from "../../src/VaultPolicy.sol";
import {InitParams} from "../../src/VaultTypes.sol";
import {ICoreDepositWallet} from "../../src/hypercore/HyperCore.sol";
import {Addresses} from "../Deploy.s.sol";

/// @notice D14 (round 2, WP5 step 4), step 2: launches the HyperCore test vault on HyperEVM testnet (chain 998) from
///         the implementations that `script/Deploy.s.sol:DeployFactory` deployed (read from deployments/testnet.json).
///
/// Why a standalone clone and not factory.create(): a factory vault launched with an agent waits AGENT_WARMUP (24 h,
/// `agentActiveAt`) before the agent's first order (VaultLogic.placeOrder reverts AgentWarmingUp), and a factory vault
/// launched without one can only get it through the owner timelock (queue + execute, at least MIN_TIMELOCK = 1 day).
/// VaultGovernance.initialize sets agentActiveAt only when `factory != 0`, so a standalone clone of the SAME
/// implementation with the agent in InitParams has agentActiveAt = 0 and the agent may trade at once. Everything D14
/// checks is the same code in both: placeOrder (IOC only, cloid, turnover / order rate, checkRisk first, mode guard),
/// pinAccountMode / _pinMode (CoreWriter action 16) and the precompile reads. Only the role lookup differs: a
/// standalone vault's guardian and sentinel are the one `guardian` field (here the owner).
///
/// No USDC seed and no HYPE value: on testnet an EVM -> Core deposit to an address with no HyperCore MAINNET state is
/// dropped silently, and a fresh contract never has mainnet state. The vault's Core account is opened and funded by a
/// HyperCore spot send from the owner's wallet (docs/fix-round/TESTNET-D14.md, step 3).
///
/// Signing: only `--account <keystore>` (or `--interactive`); the broadcaster becomes owner, manager, guardian and
/// fee recipient. Small blocks are enough (two EIP-1167 clones and two initializers).
///
/// Env:
///   AGENT          required: the agent wallet (keystore d14-agent); recorded at initialization (nothing sent to Core)
///   D14_ASSET      perp index, default 3 (BTC on HL testnet; mainnet BTC is 0). Allowed in the vault's policy.
///   D14_DEPLOYMENT default deployments/testnet.json (written by DeployFactory)
///   D14_RECORD     default deployments/testnet-d14.json (written here)
/// Risk parameters: the production defaults of script/Deploy.s.sol:LaunchVault (3x, 5% daily, 15% drawdown, 1%
/// slippage band, 250k per order, 7 day epoch, 20% NAV move, 3% flatten cap); agent limits: the VaultPolicy defaults
/// (20x NAV turnover a day, 120 orders an hour).
contract D14Launch is Script {
    function run() external returns (HyperVault vault, VaultPolicy policy) {
        require(block.chainid == 998, "D14Launch: HyperEVM testnet (998) only");
        address me = msg.sender;
        address agent = vm.envAddress("AGENT");
        require(agent != address(0) && agent != me, "AGENT must be a separate wallet");
        uint32 asset = uint32(vm.envOr("D14_ASSET", uint256(3)));

        string memory dep = vm.readFile(vm.envOr("D14_DEPLOYMENT", string("deployments/testnet.json")));
        address vaultImpl = vm.parseJsonAddress(dep, ".vaultImplementation");
        address policyImpl = vm.parseJsonAddress(dep, ".policyImplementation");
        require(vaultImpl.code.length > 0 && policyImpl.code.length > 0, "implementations not deployed");

        uint32[] memory assets = new uint32[](1);
        assets[0] = asset;
        VaultPolicy.RiskConfig memory risk = VaultPolicy.RiskConfig({
            maxLeverageBps: 30_000,
            maxDailyLossBps: 500,
            maxDrawdownBps: 1_500,
            maxSlippageBps: 100,
            maxOrderNotional: 250_000e6,
            maxEpochDuration: 7 days,
            maxNavMoveBps: 2_000,
            maxFlattenSlippageBps: 300
        });

        vm.startBroadcast();
        policy = VaultPolicy(Clones.clone(policyImpl));
        policy.initialize(me, risk, assets, 2 days, address(0));
        vault = HyperVault(Clones.clone(vaultImpl));
        vault.initialize(
            InitParams({
                asset: IERC20(Addresses.usdc()),
                name: "D14 Testnet Vault",
                symbol: "dpD14",
                owner: me,
                manager: me,
                guardian: me,
                feeRecipient: me,
                managementFeeBps: 200,
                performanceFeeBps: 2_000,
                timelockDelay: 2 days,
                depositCap: 0,
                policy: policy,
                coreDepositWallet: ICoreDepositWallet(Addresses.cdw()),
                factory: address(0),
                protocolShareBps: 0,
                baseShareBps: 0,
                hosted: false,
                agent: agent,
                operator: address(0),
                seedUsdc: 0
            })
        );
        vm.stopBroadcast();

        require(vault.agent() == agent, "agent not recorded");
        require(vault.agentActiveAt() == 0, "agent warm-up set (not a standalone vault?)");
        require(vault.modePinnedAt() == 0, "pinned before the Core account exists");
        require(vault.orderPath() == 1, "not an HL-PROXY implementation");
        require(policy.isAssetAllowed(asset), "asset not allowed");

        console2.log("VaultPolicy       ", address(policy));
        console2.log("HyperVault        ", address(vault));
        console2.log("agent             ", agent);
        console2.log("agentActiveAt      0 (no warm-up)");
        console2.log("asset             ", uint256(asset));

        string memory j = "d14";
        vm.serializeUint(j, "chainId", block.chainid);
        vm.serializeUint(j, "block", block.number);
        vm.serializeAddress(j, "vault", address(vault));
        vm.serializeAddress(j, "policy", address(policy));
        vm.serializeAddress(j, "owner", me);
        vm.serializeAddress(j, "agent", agent);
        vm.serializeAddress(j, "vaultImplementation", vaultImpl);
        string memory out = vm.serializeUint(j, "asset", asset);
        string memory path = vm.envOr("D14_RECORD", string("deployments/testnet-d14.json"));
        vm.writeJson(out, path);
        console2.log("Written", path);
        console2.log("Next: open the vault's Core account with a HyperCore spot send to it (TESTNET-D14.md step 3).");
    }
}
