// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {HyperVaultFactory} from "../src/HyperVaultFactory.sol";
import {VaultPolicy} from "../src/VaultPolicy.sol";

/// @notice Mainnet permit path test: one transaction, no approve. The EIP-2612 permit is signed by the script
///         wallet (`--account launcher`) via vm.sign(address, digest), so the key never leaves the keystore.
///
/// Env (same as LaunchVault): FACTORY, VAULT_NAME, VAULT_SYMBOL, DEPOSIT_CAP, SEED_USDC, HYPE_WEI, ASSETS, SALT, HOSTED,
///      AGENT (a registered platform agent), OWNER / MANAGER / FEE_RECIPIENT (default: broadcaster)
contract LaunchVaultPermit is Script {
    bytes32 constant PERMIT_TYPEHASH = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function run() external returns (address vault, address policy) {
        HyperVaultFactory factory = HyperVaultFactory(vm.envAddress("FACTORY"));
        IERC20Permit usdc = IERC20Permit(address(factory.usdc()));
        address me = msg.sender;
        string memory name = vm.envOr("VAULT_NAME", string("Permit Test"));

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
            symbol: vm.envOr("VAULT_SYMBOL", string("dpPERMIT")),
            owner: vm.envOr("OWNER", me),
            manager: vm.envOr("MANAGER", me),
            feeRecipient: vm.envOr("FEE_RECIPIENT", me),
            managementFeeBps: uint16(vm.envOr("MGMT_FEE_BPS", uint256(200))),
            performanceFeeBps: uint16(vm.envOr("PERF_FEE_BPS", uint256(2_000))),
            timelockDelay: vm.envOr("TIMELOCK_DELAY", uint256(2 days)),
            depositCap: vm.envOr("DEPOSIT_CAP", uint256(100e6)),
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

        // EIP-2612 digest for USDC (domain separator read from the token, so it matches "USDC" / version "2").
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, me, address(factory), p.seedUsdc, usdc.nonces(me), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(me, digest);
        HyperVaultFactory.PermitData memory permit = HyperVaultFactory.PermitData({value: p.seedUsdc, deadline: deadline, v: v, r: r, s: s});

        console2.log("Launcher      ", me);
        console2.log("Predicted vault", factory.predictVaultAddress(me, p.salt));
        console2.log("Allowance before (should be 0)", IERC20(address(factory.usdc())).allowance(me, address(factory)));

        vm.startBroadcast();
        (vault, policy) = factory.create{value: hype}(p, permit);
        vm.stopBroadcast();

        console2.log("HyperVault ", vault);
        console2.log("VaultPolicy", policy);
        console2.log("Allowance after (should be 0)", IERC20(address(factory.usdc())).allowance(me, address(factory)));
    }
}
