// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AuditBase} from "../AuditBase.t.sol";
import {HyperVault} from "../../../src/HyperVault.sol";
import {IHyperVaultErrors as E} from "../../../src/VaultTypes.sol";

/// @notice Verification pass 2 (e5334a9..7933fbf): attempts against partial fill + return.
///         W-01 PASS = issue present; the B-* tests are bypass attempts that PASS when the design holds.
///         Run: forge test --match-path test/audit/verify/Verify2PoC.t.sol -vv
contract Verify2PoC is AuditBase {
    int64 internal perp;
    uint64 internal spot;

    function _core(HyperVault v) internal {
        _setCore(address(v), perp, 0, spot);
        _setWithdrawable(address(v), perp > 0 ? uint64(perp) : 0);
    }

    function _home(HyperVault v, address who, uint256 amount) internal {
        vm.prank(who);
        v.bridgeToEvm(amount);
        if (spot >= amount) spot -= uint64(amount);
        else {
            perp -= int64(uint64(amount - spot));
            spot = 0;
        }
        usdc.mint(address(v), amount);
        _core(v);
        vm.roll(vm.getBlockNumber() + 11);
    }

    function _emergencyVault() internal returns (HyperVault v) {
        (v,) = _malloryVault();
        _fundAndDeploy(v, mallory, 1_000_000e6, 0);
        perp = 1_000_000e6;
        spot = 0;
        _core(v);
    }

    // ==================================================================
    // W-01 (Medium, fixed by removing the owner path, W-01b)  Only the cold guardian ends an emergency, and only
    //       when nothing is pending and the last settle of this emergency paid every redemption. The owner cannot
    //       end it directly or through the queue, so no timing around a partial fill helps.
    // ==================================================================
    function test_VERIFY2_W01_ownerCannotExitAfterAPartialFill() public {
        HyperVault v = _emergencyVault();
        bytes memory exitData = abi.encodeCall(HyperVault.exitEmergency, ());
        vm.prank(mallory);
        vm.expectRevert(E.Unauthorized.selector);
        v.queue(exitData); // never queueable

        uint256 a = v.balanceOf(alice);
        vm.prank(alice);
        v.requestRedeem(a, alice, alice);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        v.checkRisk();
        vm.prank(stranger);
        v.triggerEmergency();
        assertEq(v.emergencyAt(), vm.getBlockTimestamp());

        // Rescue: 100k comes home, the sentinel settles (round 4: listed roles only): 10% fill, 90% of alice's shares come back.
        _home(v, sentinel, 100_000e6);
        vm.prank(sentinel);
        v.settle();
        assertEq(v.pendingRedeemShares(), 0);

        vm.prank(mallory);
        vm.expectRevert(E.Unauthorized.selector);
        v.exitEmergency();
        // The guardian is held back by the partial fill: alice may still re-request her returned shares.
        vm.prank(guardian);
        vm.expectRevert(E.RedemptionsPending.selector);
        v.exitEmergency();
        assertTrue(v.emergency(), "still in emergency: alice can re-request and anyone can keep bridging");

        v.claim(alice);
        uint256 back = v.balanceOf(alice);
        assertGt(back, (a * 85) / 100);
        vm.prank(alice);
        v.requestRedeem(back, alice, alice);
        vm.prank(guardian);
        vm.expectRevert(E.RedemptionsPending.selector);
        v.exitEmergency(); // pending
        _home(v, sentinel, 900_000e6);
        vm.prank(sentinel);
        v.settle();
        v.claim(alice);
        assertApproxEqRel(usdc.balanceOf(alice), 1_000_000e6, 2e15, "alice is out");
        vm.prank(guardian);
        v.exitEmergency(); // paid in full: the guardian ends it
        assertFalse(v.emergency());
    }

    function test_VERIFY2_W01_reTriggerKeepsTheEmergencyStamp() public {
        HyperVault v = _emergencyVault();
        uint256 a = v.balanceOf(alice);
        vm.prank(alice);
        v.requestRedeem(a, alice, alice);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(guardian);
        v.triggerEmergency();
        uint256 at = v.emergencyAt();
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(guardian);
        v.triggerEmergency();
        assertEq(v.emergencyAt(), at, "re-triggering inside an emergency does not move the stamp");
        _home(v, sentinel, 1_000_000e6);
        vm.prank(sentinel);
        v.settle();
        vm.prank(guardian);
        v.exitEmergency();
        assertFalse(v.emergency());
        // A new emergency gets a new stamp.
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(guardian);
        v.triggerEmergency();
        assertGt(v.emergencyAt(), at);
    }

    // ==================================================================
    // B-1  Many odd-sized redeemers vs one large one in a partial fill: each is paid at the epoch's ratio or gets the
    //      shares back; the sums never exceed what the epoch paid / did not burn; claim order does not matter.
    // ==================================================================
    function testFuzz_VERIFY2_B1_partialFillRounding(uint256 seed, uint256 fillSeed) public {
        HyperVault v = _emergencyVault();
        // Alice (1M of shares) redeems a random large chunk; six small redeemers get odd-sized shares from her.
        address[6] memory small;
        uint256 aShares = v.balanceOf(alice);
        for (uint256 i; i < 6; ++i) {
            small[i] = makeAddr(string(abi.encodePacked("small", i)));
            uint256 amt = bound(uint256(keccak256(abi.encode(seed, i))), 1, 997_331_017_000) * 7 + 3; // odd sizes
            vm.prank(alice);
            v.transfer(small[i], amt);
            vm.prank(small[i]);
            v.requestRedeem(amt, small[i], small[i]);
        }
        uint256 big = (v.balanceOf(alice) * bound(seed, 1, 100)) / 100;
        vm.prank(alice);
        v.requestRedeem(big, alice, alice);
        aShares;
        vm.warp(vm.getBlockTimestamp() + 7 days);
        v.checkRisk();
        vm.prank(stranger);
        v.triggerEmergency();

        uint256 owed = v.previewRedeem(v.pendingRedeemShares());
        uint256 fill = bound(fillSeed, 1, owed - 1);
        if (fill < 100e6) fill = 100e6 < owed ? 100e6 : owed - 1;
        _home(v, sentinel, fill);
        vm.prank(sentinel);
        v.settle();
        (,, uint256 R, uint256 paid, uint256 burned,,,) = v.epochs(v.currentEpoch() - 1);

        uint256 sumPaid;
        uint256 sumBack;
        // Claim in reverse order of request.
        address[7] memory who;
        uint256[7] memory req;
        for (uint256 i; i < 6; ++i) {
            who[i] = small[5 - i];
            (, , req[i]) = v.requests(who[i]);
        }
        who[6] = alice;
        (, , req[6]) = v.requests(alice);
        for (uint256 i; i < 7; ++i) {
            uint256 u0 = usdc.balanceOf(who[i]);
            uint256 s0 = v.balanceOf(who[i]);
            v.claim(who[i]);
            uint256 got = usdc.balanceOf(who[i]) - u0;
            uint256 back = v.balanceOf(who[i]) - s0;
            sumPaid += got;
            sumBack += back;
            // Paid at the epoch ratio paid/burned, or returned: value in >= value out, within 2 wei + 1 share unit.
            assertGe(got * burned + back * paid + 2 * burned + paid, req[i] * paid, "shortchanged");
            assertLe(back, req[i]);
        }
        assertLe(sumPaid, paid, "paid more than the epoch paid");
        assertLe(sumBack, R - burned, "returned more than was not burned");
        assertGe(usdc.balanceOf(address(v)), v.claimableRedeemAssets(), "reserve backed");
    }

    // ==================================================================
    // B-2  Cancel after a partial fill: the settled request is claimed first and nothing is pending, so cancel
    //      reverts (and with it the claim); claim() delivers the payout and the returned shares. No loss, no lock.
    // ==================================================================
    function test_VERIFY2_B2_cancelAfterPartialFill() public {
        HyperVault v = _emergencyVault();
        uint256 a = v.balanceOf(alice);
        vm.prank(alice);
        v.requestRedeem(a, alice, alice);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        v.checkRisk();
        vm.prank(stranger);
        v.triggerEmergency();
        _home(v, sentinel, 250_000e6);
        vm.prank(sentinel);
        v.settle();
        vm.prank(alice);
        vm.expectRevert(E.NothingToCancel.selector);
        v.cancelRedeemRequest();
        uint256 u0 = usdc.balanceOf(alice);
        v.claim(alice);
        assertApproxEqAbs(usdc.balanceOf(alice) - u0, 250_000e6, 2);
        assertApproxEqRel(v.balanceOf(alice), (a * 75) / 100, 1e15); // NAV is 1M + seed + fees
    }

    // ==================================================================
    // B-3  Zero-liquidity settle in emergency: anyone may settle with nothing idle; every request comes back whole
    //      (burned 0, paid 0). Griefing only (redeemers re-request); requests made during a bridge window cannot be
    //      flushed this way because settle reverts in flight.
    // ==================================================================
    function test_VERIFY2_B3_zeroLiquiditySettleReturnsEverything() public {
        HyperVault v = _emergencyVault();
        uint256 a = v.balanceOf(alice);
        vm.prank(alice);
        v.requestRedeem(a, alice, alice);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        v.checkRisk();
        vm.prank(stranger);
        v.triggerEmergency();
        vm.prank(sentinel);
        v.settle(); // nothing idle
        v.claim(alice);
        assertEq(v.balanceOf(alice), a, "returned whole");
        // During a rescue window the queue is safe from a flush.
        vm.prank(alice);
        v.requestRedeem(a, alice, alice);
        vm.prank(sentinel);
        v.bridgeToEvm(100_000e6);
        vm.prank(sentinel);
        vm.expectRevert(E.BridgeInFlight.selector);
        v.settle();
    }
}
