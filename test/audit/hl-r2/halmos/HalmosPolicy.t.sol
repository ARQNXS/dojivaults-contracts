// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {VaultPolicy} from "../../../../src/VaultPolicy.sol";

/// @title hl-r2 Halmos properties of VaultPolicy.nextCheckpoint (the NAV bound behind audit C-01 / N-03 / N-12)
/// @notice `check_` prefix: halmos only. Results in contracts/audit/hl-r2/HALMOS.md.
contract HalmosPolicy is Test {
    VaultPolicy internal policy;

    function _policy(uint32 maxNavMoveBps) internal returns (VaultPolicy p) {
        VaultPolicy impl = new VaultPolicy();
        p = VaultPolicy(Clones.clone(address(impl)));
        VaultPolicy.RiskConfig memory c = VaultPolicy.RiskConfig({
            maxLeverageBps: 30_000,
            maxDailyLossBps: 500,
            maxDrawdownBps: 1_500,
            maxSlippageBps: 100,
            maxOrderNotional: 1_000_000e6,
            maxEpochDuration: 7 days,
            maxNavMoveBps: maxNavMoveBps,
            maxFlattenSlippageBps: 300
        });
        uint32[] memory assets = new uint32[](0);
        p.initialize(address(this), c, assets, 2 days, address(0));
    }

    /// P1. checkRisk (settling = false): the stored checkpoint never moves by more than maxNavMoveBps of the previous
    ///     one, never moves inside CHECKPOINT_INTERVAL, and equals the live NAV whenever that is inside the band.
    function check_P1_ratchetBounded(uint32 bps, uint128 prev, uint64 at, uint128 nav, uint64 now_) public {
        vm.assume(bps >= 500 && bps <= 10_000);
        VaultPolicy p = _policy(bps);
        vm.assume(at > 0 && prev > 0 && now_ >= at);
        vm.warp(now_);
        (uint256 next, bool update) = p.nextCheckpoint(prev, at, nav, false);
        uint256 cap = (uint256(prev) * bps) / 10_000;
        if (uint256(now_) < uint256(at) + 1 hours) {
            assert(!update && next == prev);
        } else {
            assert(update);
            assert(next <= uint256(prev) + cap);
            assert(next + cap >= prev);
            if (uint256(nav) <= uint256(prev) + cap && uint256(nav) + cap >= prev) assert(next == nav);
        }
    }

    /// P2. settle (settling = true): returns only for a checkpoint younger than CHECKPOINT_MAX_AGE and a NAV within
    ///     maxNavMoveBps of it; never for a vault that was never checkpointed (N-12).
    function check_P2_settleBound(uint32 bps, uint128 prev, uint64 at, uint128 nav, uint64 now_) public {
        vm.assume(bps >= 500 && bps <= 10_000);
        VaultPolicy p = _policy(bps);
        vm.assume(now_ >= at);
        vm.warp(now_);
        try p.nextCheckpoint(prev, at, nav, true) returns (uint256 next, bool update) {
            assert(at != 0);
            assert(update && next == nav);
            if (prev != 0) {
                uint256 cap = (uint256(prev) * bps) / 10_000;
                assert(uint256(now_) <= uint256(at) + 1 days);
                uint256 d = nav > prev ? uint256(nav) - prev : uint256(prev) - nav;
                assert(d <= cap);
            }
        } catch {
            // a revert is always allowed: settle waits
        }
    }

    /// P3. Liveness side of P2: an honest move inside the band on a fresh checkpoint always settles.
    function check_P3_honestMoveSettles(uint32 bps, uint128 prev, uint64 at, uint128 nav, uint64 now_) public {
        vm.assume(bps >= 500 && bps <= 10_000);
        VaultPolicy p = _policy(bps);
        vm.assume(at > 0 && prev > 0 && now_ >= at && uint256(now_) <= uint256(at) + 1 days);
        uint256 cap = (uint256(prev) * bps) / 10_000;
        uint256 d = nav > prev ? uint256(nav) - prev : uint256(prev) - nav;
        vm.assume(d <= cap);
        vm.warp(now_);
        (uint256 next, bool update) = p.nextCheckpoint(prev, at, nav, true);
        assert(update && next == nav);
    }
}
