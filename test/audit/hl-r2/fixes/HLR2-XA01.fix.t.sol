// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {HloBase} from "../../hl-open/HloBase.t.sol";
import {HyperVault} from "../../../../src/HyperVault.sol";
import {HyperVaultFactory} from "../../../../src/HyperVaultFactory.sol";
import {VaultPolicy} from "../../../../src/VaultPolicy.sol";
import {IHyperVaultErrors as E} from "../../../../src/VaultTypes.sol";

/// @notice Fix test for HLR2-XA01 (contract half): a platform revoke of a live agent (the monitor's ACT) holds
///         deposits: deposits close, every settle is redemption-only (queued deposits carried, nothing minted) until
///         the guardian clears. Same platform-vault-like setup as xreview/XreviewA.t.sol. Runs with
///         patches/HLR2-XA01.patch. The helper waits one day after the launch so the test also runs with HLO-07.
contract HLR2_XA01_Fix is HloBase {
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
        vm.warp(vm.getBlockTimestamp() + 1 days); // HLO-07 warm-up (no effect without that patch)
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

    function _deflateAndQueue(HyperVault v, uint256 nav) internal {
        usdc.mint(sybil, nav);
        vm.prank(sybil);
        usdc.approve(address(v), type(uint256).max);
        _setCore(address(v), int64(uint64((nav + 2e6) * 801 / 1000)), 0, 0);
        vm.prank(sybil);
        v.requestDeposit(nav, sybil);
    }

    /// XA01 inverted: same detection, same sentinel revoke, same keeper settle. The settle goes through (exits stay
    /// open) but is redemption-only: the sybil's deposit is carried, not minted, and she can take it back in full.
    function test_HLR2_XA01_fix_revokeHoldsDepositsSoTheKeeperSettleMintsNothing() public {
        uint256 nav = 100_000e6;
        HyperVault v = _hosted(bytes32(uint256(0xA01)), nav);
        _deflateAndQueue(v, nav);
        vm.prank(sentinel);
        v.revokeAgent();
        assertTrue(v.depositHold());
        assertFalse(v.breached());

        v.checkRisk();
        vm.prank(keeper);
        v.settle(); // not blocked, but redemption-only
        (uint256 depAssets, uint256 depShares,,,,,,) = v.epochs(v.currentEpoch() - 1);
        assertEq(depShares, 0, "nothing minted at the deflated NAV");
        assertEq(depAssets, 0, "no deposit priced in this epoch");
        assertEq(v.pendingDepositAssets(), nav, "the sybil's deposit stays queued");
        (uint256 carriedFrom,) = v.carry(v.currentEpoch() - 1);
        assertGt(carriedFrom, 0, "the sybil's deposit is carried");
        vm.expectRevert(E.RequestNotSettled.selector); // a carried deposit has nothing to claim
        v.claim(sybil);
        assertEq(v.balanceOf(sybil), 0);
        uint256 b0 = usdc.balanceOf(sybil);
        vm.prank(sybil);
        v.cancelDepositRequest();
        assertEq(usdc.balanceOf(sybil) - b0, nav, "the sybil only gets her own money back");

        // new deposits are closed while the hold lasts
        usdc.mint(bob, 1_000e6);
        vm.startPrank(bob);
        usdc.approve(address(v), type(uint256).max);
        vm.expectRevert(E.DepositsClosed.selector);
        v.requestDeposit(1_000e6, bob);
        vm.stopPrank();
    }

    /// Only the guardian lifts the hold; the vault owner cannot (directly, and its clearBreach path is the queue).
    function test_HLR2_XA01_fix_onlyTheGuardianLiftsTheHold() public {
        uint256 nav = 100_000e6;
        HyperVault v = _hosted(bytes32(uint256(0xA03)), nav);
        vm.prank(sentinel);
        v.revokeAgent();
        vm.prank(launcher);
        vm.expectRevert(E.Unauthorized.selector);
        v.clearBreach();
        assertTrue(v.depositHold());
        vm.prank(guardian);
        v.clearBreach();
        assertFalse(v.depositHold());
        usdc.mint(bob, 1_000e6);
        vm.startPrank(bob);
        usdc.approve(address(v), type(uint256).max);
        v.requestDeposit(1_000e6, bob);
        vm.stopPrank();
    }

    /// The owner's own revoke (switch to manual, leaveHosted) does not hold deposits; a revoke with no live agent is
    /// a no-op for the hold too.
    function test_HLR2_XA01_fix_ownerRevokeDoesNotHold() public {
        uint256 nav = 100_000e6;
        HyperVault v = _hosted(bytes32(uint256(0xA04)), nav);
        vm.prank(launcher);
        v.revokeAgent();
        assertFalse(v.depositHold());
        vm.prank(sentinel);
        v.revokeAgent(); // agent already zero
        assertFalse(v.depositHold());
    }
}
