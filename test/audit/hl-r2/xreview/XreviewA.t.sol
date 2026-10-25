// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {HloBase} from "../../hl-open/HloBase.t.sol";
import {HyperVault} from "../../../../src/HyperVault.sol";
import {HyperVaultFactory} from "../../../../src/HyperVaultFactory.sol";
import {VaultPolicy} from "../../../../src/VaultPolicy.sol";
import {IHyperVaultErrors as E} from "../../../../src/VaultTypes.sol";

/// @notice hl-r2 cross-review A (contracts/audit/hl-r2/XREVIEW-A.md). Same platform-vault-like setup as keys/KeysPoC.t.sol
///         (copied, not inherited, so its tests do not run twice).
contract HLR2XreviewA is HloBase {
    address internal agentHolder;
    address internal launcher = makeAddr("launcher");
    address internal sybil = makeAddr("sybil");

    function _platformVault() internal pure returns (VaultPolicy.RiskConfig memory) {
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

    function _hosted(bytes32 salt, uint256 nav) internal returns (HyperVault v) {
        (agentHolder,) = makeAddrAndKey(string(abi.encodePacked("agent", salt)));
        address predicted = factory.predictVaultAddress(launcher, salt);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        _fundLauncher(launcher, 1);
        HyperVaultFactory.CreateParams memory p = _params(launcher, salt);
        p.risk = _platformVault();
        p.hosted = true;
        p.depositCap = type(uint256).max;
        (p.agent, p.agentSig, p.agentDeadline) = (agentHolder, _agentSig(agentHolder, predicted, deadline), deadline);
        v = _launch(launcher, p);
        if (v.agentActiveAt() > vm.getBlockTimestamp()) vm.warp(v.agentActiveAt()); // HLO-07: AGENT_WARMUP
        vm.roll(vm.getBlockNumber() + 400);
        usdc.mint(alice, nav);
        vm.startPrank(alice);
        usdc.approve(address(v), type(uint256).max);
        v.requestDeposit(nav, alice);
        vm.stopPrank();
        v.checkRisk();
        vm.prank(keeper);
        v.settle();
        usdc.burnFrom(address(v), nav);
        _setCore(address(v), int64(uint64(nav + 2e6)), 0, 0);
        uint256 t = vm.getBlockTimestamp();
        vm.warp((t / 1 days + 1) * 1 days + 1 hours);
        vm.roll(vm.getBlockNumber() + 400);
        v.checkRisk();
    }

    /// @dev The agent deflates (agentSendAsset to another dex: the one move the monitor ACTs on, OTHER_DEX), the
    ///      sybil queues a deposit, and the platform reacts the way the executor does today.
    function _deflateAndQueue(HyperVault v, uint256 nav) internal {
        usdc.mint(sybil, nav);
        vm.prank(sybil);
        usdc.approve(address(v), type(uint256).max);
        _setCore(address(v), int64(uint64((nav + 2e6) * 801 / 1000)), 0, 0);
        vm.prank(sybil);
        v.requestDeposit(nav, sybil);
    }

    // Control: the same detection answered with triggerBreach (a sentinel power) blocks the settle outright.
    function test_HLR2_XA01_control_triggerBreachBlocksTheSettle() public {
        uint256 nav = 100_000e6;
        HyperVault v = _hosted(bytes32(uint256(0xA02)), nav);
        _deflateAndQueue(v, nav);
        vm.prank(sentinel);
        v.triggerBreach();
        vm.prank(keeper);
        vm.expectRevert(E.ReduceOnlyMode.selector);
        v.settle();
    }
}
