// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {HloBase} from "../../hl-open/HloBase.t.sol";
import {HyperVault} from "../../../../src/HyperVault.sol";
import {HyperVaultFactory} from "../../../../src/HyperVaultFactory.sol";
import {VaultPolicy} from "../../../../src/VaultPolicy.sol";

/// @notice hl-r2 hostile / configuration review base: the live round 4 factory (HloBase) plus a vault configured
///         like the platform vault on 2026-10-19 (policy 5x, daily loss 20%, drawdown 50%, slippage 1%, order notional 2.5M,
///         epoch 7 days, NAV move 20%, flatten 3%; vault and policy timelock 2 days; the keeper as operator).
abstract contract HostileBase is HloBase {
    address internal platformVaultOwner = makeAddr("platformVault.owner"); // owner = manager, as on chain

    function _platformVaultRisk() internal pure returns (VaultPolicy.RiskConfig memory) {
        return VaultPolicy.RiskConfig({
            maxLeverageBps: 50_000,
            maxDailyLossBps: 2_000,
            maxDrawdownBps: 5_000,
            maxSlippageBps: 100,
            maxOrderNotional: 2_500_000e6,
            maxEpochDuration: 7 days,
            maxNavMoveBps: 2_000,
            maxFlattenSlippageBps: 300
        });
    }

    /// @dev Hostile but valid: what an owner may queue as one loosening (VaultPolicy._validate bounds).
    function _loose() internal pure returns (VaultPolicy.RiskConfig memory) {
        return VaultPolicy.RiskConfig({
            maxLeverageBps: 500_000,
            maxDailyLossBps: 10_000,
            maxDrawdownBps: 10_000,
            maxSlippageBps: 2_000,
            maxOrderNotional: type(uint64).max,
            maxEpochDuration: 30 days,
            maxNavMoveBps: 10_000,
            maxFlattenSlippageBps: 300
        });
    }

    /// @dev A platform-vault-like vault with `agent` (zero = manual), alice holding 100k of shares, the 100k on Core perp.
    function _platformVaultLike(address agent_) internal returns (HyperVault v) {
        _fundLauncher(platformVaultOwner, 1);
        HyperVaultFactory.CreateParams memory p = _params(platformVaultOwner, bytes32("platformVault"));
        p.name = "Platform";
        p.symbol = "POL";
        p.risk = _platformVaultRisk();
        p.hosted = true;
        p.depositCap = 250_000e6;
        if (agent_ != address(0)) {
            uint256 deadline = vm.getBlockTimestamp() + 1 hours;
            p.agent = agent_;
            p.agentSig = _agentSig(agent_, factory.predictVaultAddress(platformVaultOwner, p.salt), deadline);
            p.agentDeadline = deadline;
        }
        v = _launch(platformVaultOwner, p);
        if (v.agentActiveAt() > vm.getBlockTimestamp()) vm.warp(v.agentActiveAt()); // HLO-07: AGENT_WARMUP
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        vm.roll(vm.getBlockNumber() + 400); // past the seed bridge window
        vm.prank(alice);
        v.requestDeposit(100_000e6, alice);
        v.checkRisk();
        vm.prank(keeper);
        v.settle();
        v.claim(alice);
        // the deposit goes to Core perp margin (the bridge itself is not modelled: the USDC leaves the EVM side)
        usdc.burnFrom(address(v), 100_000e6);
        _setCore(address(v), 100_002e6, 0, 0);
        _setWithdrawable(address(v), 100_002e6);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        v.checkRisk();
    }
}
