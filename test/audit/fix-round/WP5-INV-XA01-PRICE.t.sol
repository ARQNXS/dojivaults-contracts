// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {HloBase} from "../hl-open/HloBase.t.sol";
import {HyperVault} from "../../../src/HyperVault.sol";
import {HyperVaultFactory} from "../../../src/HyperVaultFactory.sol";
import {VaultPolicy} from "../../../src/VaultPolicy.sol";

/// @notice WP5 (round 2 fix round, internal, AI-assisted; not an independent audit). The forge invariant suite
///         (VaultInvariants, guard 2 run) flagged "share price jumped at settle" on a settle inside the HLR2-XA01
///         deposit hold: after the sentinel's revoke every settle is redemption-only and pays at min(NAV, checkpoint),
///         so with the NAV back above the checkpoint the remaining holders' price rises. That is the intended rule (no
///         redeemer is paid at a NAV the revoked agent may have moved); the handler had not been taught it (fixed in
///         the same commit). This test pins the rule directly: paid at the checkpoint, nothing minted, the remaining
///         holders' price never falls, and the lens previews the payout exactly.
///         Never block.timestamp / block.number here (via_ir rematerialisation).
contract WP5_InvXA01Price is HloBase {
    address internal launcher = makeAddr("launcher");

    function _hosted(uint256 nav) internal returns (HyperVault v) {
        bytes32 salt = bytes32(uint256(0x5A01));
        (address agentHolder,) = makeAddrAndKey("wp5-xa01-agent");
        address predicted = factory.predictVaultAddress(launcher, salt);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        _fundLauncher(launcher, 1);
        HyperVaultFactory.CreateParams memory p = _params(launcher, salt);
        p.risk = VaultPolicy.RiskConfig({
            maxLeverageBps: 50_000,
            maxDailyLossBps: 2_000,
            maxDrawdownBps: 5_000,
            maxSlippageBps: 100,
            maxOrderNotional: 2_500_000e6,
            maxEpochDuration: 7 days,
            maxNavMoveBps: 2_000,
            maxFlattenSlippageBps: 300
        });
        p.hosted = true;
        p.depositCap = type(uint256).max;
        (p.agent, p.agentSig, p.agentDeadline) = (agentHolder, _agentSig(agentHolder, predicted, deadline), deadline);
        v = _launch(launcher, p);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.roll(vm.getBlockNumber() + 400);
        usdc.mint(alice, nav);
        vm.startPrank(alice);
        usdc.approve(address(v), type(uint256).max);
        v.requestDeposit(nav, alice);
        vm.stopPrank();
        v.checkRisk();
        vm.prank(keeper);
        v.settle();
        v.claim(alice);
        // half the NAV on HyperCore, half idle on the EVM side (the redemption below is paid from it)
        usdc.burnFrom(address(v), nav / 2);
        _setCore(address(v), int64(uint64(nav / 2 + 2e6)), 0, 0);
        uint256 t = vm.getBlockTimestamp();
        vm.warp((t / 1 days + 1) * 1 days + 1 hours);
        vm.roll(vm.getBlockNumber() + 400);
        v.checkRisk();
    }

    function test_WP5_INV_XA01_holdPaysRedemptionsAtTheCheckpointAndTheRestKeepTheRise() public {
        uint256 nav = 100_000e6;
        HyperVault v = _hosted(nav);
        vm.prank(sentinel);
        v.revokeAgent();
        assertTrue(v.depositHold());

        // the NAV dips 15 % (inside the daily limit, no breach); a settle in the hold ratchets the checkpoint down
        uint256 core0 = nav / 2 + 2e6;
        _setCore(address(v), int64(uint64(core0 - v.totalAssets() * 15 / 100)), 0, 0);
        v.checkRisk();
        assertFalse(v.breached());
        vm.prank(keeper);
        v.settle();
        uint256 cp = v.checkpointNav();

        // the NAV comes back; alice redeems half inside the same hold
        _setCore(address(v), int64(uint64(core0)), 0, 0);
        uint256 navNow = v.totalAssets();
        assertGt(navNow, cp, "the NAV is back above the checkpoint");
        uint256 half = v.balanceOf(alice) / 2;
        vm.prank(alice);
        v.requestRedeem(half, alice, alice);
        uint256 supply = v.totalSupply();
        uint256 preview = lens.previewRedeem(v, half);
        uint256 priceBefore = v.sharePrice();
        uint256 e = v.currentEpoch();

        vm.prank(keeper);
        v.settle();

        (uint256 depA, uint256 depS,, uint256 ra,,,,) = v.epochs(e);
        assertEq(depA + depS, 0, "nothing priced or minted in the hold");
        assertEq(ra, preview, "the lens previews the payout");
        assertLt(ra, half * navNow / supply, "paid below the live NAV");
        assertLe(ra, half * cp / supply + 1, "paid at the checkpoint");
        assertGe(v.sharePrice() + 1, priceBefore, "the remaining holders' price never falls");
        assertGt(v.sharePrice(), priceBefore, "the rise the redeemer was not paid stays with the remaining holders");
    }
}
