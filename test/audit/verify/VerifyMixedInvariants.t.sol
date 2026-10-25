// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {HyperVault} from "../../../src/HyperVault.sol";
import {MockUSDC} from "../../mocks/Mocks.sol";
import {Reaudit2Invariants} from "../reaudit2/Reaudit2Invariants.t.sol";

/// @notice Second fuzz target next to the Reaudit2 handler: one actor queues a deposit AND a redemption in the same
///         epoch, the case the fairness clause in Reaudit2Invariants skips.
contract MixedActor is CommonBase, StdUtils {
    HyperVault public immutable v;
    MockUSDC public immutable usdc;
    address[3] internal actors;
    uint256 public mixed;

    constructor(HyperVault v_, MockUSDC usdc_, address[3] memory actors_) {
        v = v_;
        usdc = usdc_;
        actors = actors_;
    }

    function mixedRequest(uint256 s, uint256 amt, uint256 pct) external {
        address a = actors[s % 3];
        amt = bound(amt, 1e6, 200_000e6);
        usdc.mint(a, amt);
        vm.prank(a);
        try v.requestDeposit(amt, a) {} catch {}
        uint256 sh = (v.balanceOf(a) * bound(pct, 1, 100)) / 100;
        if (sh == 0) return;
        vm.prank(a);
        try v.requestRedeem(sh, a, a) {
            (, uint256 d, uint256 r) = v.requests(a);
            if (d > 0 && r > 0) mixed++;
        } catch {}
    }
}

contract VerifyMixedInvariants is Reaudit2Invariants {
    MixedActor internal mixedActor;

    function setUp() public virtual override {
        super.setUp();
        mixedActor = new MixedActor(fv, usdc, handler.actorList());
        targetContract(address(mixedActor));
    }

    /// forge-config: default.invariant.runs = 512
    /// forge-config: default.invariant.depth = 200
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_mixedRequestsFair() public view {
        _mixed();
    }

    /// @dev Reachability 1: deposit + redemption in one normal epoch; the claim carries minted shares and USDC.
    function test_mixedNormalEpochReachable() public virtual {
        address[3] memory a = handler.actorList();
        handler.requestDeposit(0, 100_000e6);
        handler.warp(2 hours, 12);
        handler.checkRisk();
        handler.settle();
        handler.claim(0);
        mixedActor.mixedRequest(0, 10_000e6, 50);
        handler.warp(2 hours, 12);
        handler.checkRisk();
        handler.settle();
        (uint256 ep, uint256 d, uint256 r) = fv.requests(a[0]);
        assertLt(ep, fv.currentEpoch(), "settled");
        assertGt(d, 0);
        assertGt(r, 0);
        _mixed();
    }

    /// @dev Reachability 2: deposit + redemption queued, then an emergency and a 100 USDC pro rata epoch: the claim
    ///      is a refund plus a partial fill plus returned shares.
    function test_mixedEmergencyPartialFillReachable() public virtual {
        address[3] memory a = handler.actorList();
        handler.requestDeposit(0, 100_000e6);
        handler.warp(2 hours, 12);
        handler.checkRisk();
        handler.settle();
        handler.claim(0);
        handler.bridgeToCore(90_000e6, false);
        handler.warp(1 hours, 12);
        mixedActor.mixedRequest(0, 10_000e6, 100);
        vm.prank(factory.guardian());
        fv.triggerEmergency();
        handler.miniEpoch();
        (uint256 ep, uint256 d, uint256 r) = fv.requests(a[0]);
        assertLt(ep, fv.currentEpoch(), "settled");
        (,, uint256 R, uint256 paid, uint256 burned,,,) = fv.epochs(ep);
        assertGt(d, 0);
        assertGt(r, 0);
        assertGt(R, burned, "partial fill");
        assertGt(paid, 0);
        _mixed();
    }

    function _mixed() internal view {
        address[3] memory a = handler.actorList();
        for (uint256 i; i < 3; ++i) {
            (uint256 ep, uint256 dep, uint256 red) = fv.requests(a[i]);
            if (ep >= fv.currentEpoch() || dep == 0 || red == 0) continue;
            (uint256 eDepA, uint256 eDepS, uint256 R, uint256 paid, uint256 burned,, uint256 price,) = fv.epochs(ep);
            (uint256 sh, uint256 as_) = lens.claimable(fv, a[i]);
            uint256 depSh;
            uint256 refund;
            if (eDepA > 0) {
                if (eDepS == 0) refund = dep;
                else depSh = (dep * eDepS) / eDepA;
            }
            assertGe(sh, depSh, "mixed: fewer shares than the deposit minted");
            assertGe(as_, refund, "mixed: refund short");
            uint256 shR = sh - depSh;
            uint256 asR = as_ - refund;
            if (R == 0) {
                assertEq(shR + asR, 0, "mixed: redemption value from an epoch without redemptions");
            } else if (burned == 0) {
                assertEq(shR, red, "mixed: unpaid epoch must return every share");
            } else {
                assertGe(asR * burned + shR * paid + 2 * burned + paid, red * paid, "mixed: redeemer shortchanged");
                assertLe(shR, red, "mixed: returned more than submitted");
            }
            if (!handler.firstMintEpoch(ep)) assertLe((depSh * price) / 1e12, dep + 2, "mixed: deposit over-valued");
        }
    }

}

/// @notice Emergency-seeded variant: the same seed as Reaudit2EmergencyInvariants (150k on Core, two redeemers,
///         emergency on), plus the mixed-request actor and the steering action from the Reaudit2 handler.
contract VerifyMixedEmergencyInvariants is VerifyMixedInvariants {
    function setUp() public override {
        super.setUp();
        handler.requestDeposit(0, 100_000e6);
        handler.requestDeposit(1, 100_000e6);
        handler.warp(2 hours, 12);
        handler.checkRisk();
        handler.settle();
        handler.claim(0);
        handler.claim(1);
        handler.bridgeToCore(150_000e6, false);
        handler.warp(1 hours, 12);
        handler.requestRedeem(0, 60_000e12);
        handler.requestRedeem(1, 20_000e12);
        handler.forceEmergency(1);
        require(fv.emergency(), "seed: emergency");
    }

    /// forge-config: default.invariant.runs = 512
    /// forge-config: default.invariant.depth = 500
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_mixedRequestsFairEmergency() public view {
        _mixed();
    }

    /// @dev The reachability tests start from a healthy vault; they run in the fresh suite only.
    function test_mixedNormalEpochReachable() public override {
        vm.skip(true);
    }

    function test_mixedEmergencyPartialFillReachable() public override {
        vm.skip(true);
    }
}
