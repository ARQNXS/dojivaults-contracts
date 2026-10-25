// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {MutBase} from "./MutBase.t.sol";
import {VaultPolicy} from "../../../../src/VaultPolicy.sol";

/// @title hl-r2 mutation kill tests on VaultPolicy (initialisation bounds, checkOrder edges, checkpoint age edge)
contract HLR2MutPolicyTest is MutBase {
    function _fresh() internal returns (VaultPolicy p) {
        p = VaultPolicy(Clones.clone(address(policyImpl)));
    }

    /// Mutants: VaultPolicy.initialize timelock bound deleted / `&&` / MIN 0 / MAX doubled, and `_validate`
    /// deleted. A policy clone is initialised by the factory with the creator's values: it must refuse a timelock
    /// outside [1 day, 30 days] and an invalid risk config on its own (the vault's own check covers the vault's
    /// timelock, not the policy's config).
    function test_HLR2_M50_kills_policyInitBounds() public {
        uint32[] memory assets = new uint32[](0);
        VaultPolicy p = _fresh();
        vm.expectRevert(VaultPolicy.InvalidTimelock.selector);
        p.initialize(owner, _defaultRisk(), assets, 1 days - 1, address(0));
        p = _fresh();
        vm.expectRevert(VaultPolicy.InvalidTimelock.selector);
        p.initialize(owner, _defaultRisk(), assets, 30 days + 1, address(0));
        p = _fresh();
        vm.expectRevert(VaultPolicy.InvalidTimelock.selector);
        p.initialize(owner, _defaultRisk(), assets, 60 days, address(0));
        VaultPolicy.RiskConfig memory bad = _defaultRisk();
        bad.maxNavMoveBps = 100; // below the 5% floor (N-03)
        p = _fresh();
        vm.expectRevert(VaultPolicy.InvalidConfig.selector);
        p.initialize(owner, bad, assets, 2 days, address(0));
        p = _fresh();
        p.initialize(owner, _defaultRisk(), assets, 1 days, address(0)); // the bounds themselves are valid
        p = _fresh();
        p.initialize(owner, _defaultRisk(), assets, 30 days, address(0));
    }

    /// Mutants: checkOrder spot guard deleted / `>` / returns true, `markPx1e8 == 0` guard deleted / returns true /
    /// `== 1`, and the band edges `>` -> `>=`, `<` -> `<=`. checkOrder is the policy's public order check: spot is
    /// refused (also for reduce only), a missing mark is refused, and an order exactly on the band edge passes.
    function test_HLR2_M51_kills_checkOrderEdges() public {
        (bool ok, string memory why) = policy.checkOrder(10_000, true, 1e8, 1e8, true, 1e8, 1e12, 0);
        assertFalse(ok);
        assertEq(why, "spot not supported");
        (ok, why) = policy.checkOrder(10_001, true, 1e8, 1e8, true, 1e8, 1e12, 0);
        assertFalse(ok);
        (ok, why) = policy.checkOrder(BTC, true, 100_000e8, 1e5, false, 0, 1e12, 0);
        assertFalse(ok);
        assertEq(why, "no mark");
        (ok,) = policy.checkOrder(BTC, true, 1, 1e5, false, 1, 1e12, 0); // a 1e-8 mark is a mark
        assertTrue(ok);
        // band = 1% of 100,000e8 = 1,000e8
        (ok,) = policy.checkOrder(BTC, true, 101_000e8, 1e5, false, 100_000e8, 1e12, 0);
        assertTrue(ok, "buy exactly on the upper edge");
        (ok,) = policy.checkOrder(BTC, true, 101_000e8 + 1, 1e5, false, 100_000e8, 1e12, 0);
        assertFalse(ok);
        (ok,) = policy.checkOrder(BTC, false, 99_000e8, 1e5, false, 100_000e8, 1e12, 0);
        assertTrue(ok, "sell exactly on the lower edge");
        (ok,) = policy.checkOrder(BTC, false, 99_000e8 - 1, 1e5, false, 100_000e8, 1e12, 0);
        assertFalse(ok);
        // and through the vault: a zero mark rejects the order
        _setCore(address(vault), 10_000e6, 0, 0);
        _setAsset(BTC, 5, 0);
        vm.prank(manager);
        vm.expectRevert();
        vault.placeOrder(BTC, true, 100_000e8, 0.01e8, false, 2, 0);
    }

    /// Mutant: nextCheckpoint `block.timestamp > at + CHECKPOINT_MAX_AGE` -> `>=`: a checkpoint exactly one day old
    /// is still valid for settle.
    function test_HLR2_M52_kills_checkpointAgeEdge() public {
        uint256 at = vm.getBlockTimestamp();
        vm.warp(at + 1 days);
        (uint256 n, bool upd) = policy.nextCheckpoint(1_000e6, at, 1_000e6, true);
        assertTrue(upd);
        assertEq(n, 1_000e6);
        vm.warp(at + 1 days + 1);
        vm.expectRevert(VaultPolicy.StaleCheckpoint.selector);
        policy.nextCheckpoint(1_000e6, at, 1_000e6, true);
    }

    function _looser() internal pure returns (VaultPolicy.RiskConfig memory r) {
        r = _defaultRisk();
        r.maxLeverageBps = 50_000;
    }

    /// Mutants: proposeConfig's tightening path keeps a queued loosening (`delete _pending` deleted), cancel
    /// guard negated / cancel without `delete`. A tightening supersedes a queued loosening; the owner can always
    /// cancel one.
    function test_HLR2_M53_kills_configQueue() public {
        vm.startPrank(owner);
        policy.proposeConfig(_looser());
        assertTrue(policy.pendingConfig().exists);
        policy.cancelPendingConfig();
        assertFalse(policy.pendingConfig().exists, "cancelled");
        policy.proposeConfig(_looser());
        VaultPolicy.RiskConfig memory tighter = _defaultRisk();
        tighter.maxLeverageBps = 20_000;
        policy.proposeConfig(tighter); // applies at once
        vm.stopPrank();
        assertFalse(policy.pendingConfig().exists, "the queued loosening is gone");
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.expectRevert(VaultPolicy.NothingPending.selector);
        policy.applyPendingConfig();
        assertEq(policy.maxLeverageBps(), 20_000);
    }

    /// Mutants: disallowAsset `assetAllowEta[asset] = 0` deleted / set to 1: disallowing an asset also drops its
    /// queued allow, which could otherwise be applied later without a fresh timelock.
    function test_HLR2_M54_kills_disallowDropsTheQueuedAllow() public {
        vm.startPrank(owner);
        policy.queueAllowAsset(DOGE);
        policy.disallowAsset(DOGE);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.expectRevert(VaultPolicy.NothingPending.selector);
        policy.allowAsset(DOGE);
        assertFalse(policy.isAssetAllowed(DOGE));
    }

    /// Mutants: proposeTimelockDelay bounds (deleted, `&&`, MIN 0, MAX doubled, `>=` MAX), the raise path
    /// (`timelockDelay = delay` deleted, `pendingTimelockEta = 0` deleted / 1), and applyTimelockDelay's eta check
    /// deleted, `>=` on the grace edge, GRACE_PERIOD 0.
    function test_HLR2_M55_kills_timelockDelayRules() public {
        vm.startPrank(owner);
        vm.expectRevert(VaultPolicy.InvalidTimelock.selector);
        policy.proposeTimelockDelay(1 days - 1);
        vm.expectRevert(VaultPolicy.InvalidTimelock.selector);
        policy.proposeTimelockDelay(0);
        vm.expectRevert(VaultPolicy.InvalidTimelock.selector);
        policy.proposeTimelockDelay(30 days + 1);
        vm.expectRevert(VaultPolicy.InvalidTimelock.selector);
        policy.proposeTimelockDelay(60 days);
        policy.proposeTimelockDelay(30 days); // a raise to the max applies at once
        assertEq(policy.timelockDelay(), 30 days);
        policy.proposeTimelockDelay(1 days); // a lowering is queued behind the current delay
        vm.stopPrank();
        assertEq(policy.timelockDelay(), 30 days);
        uint256 eta = policy.pendingTimelockEta();
        assertEq(eta, vm.getBlockTimestamp() + 30 days);
        vm.expectRevert(VaultPolicy.NotReady.selector);
        policy.applyTimelockDelay();
        // a raise clears a queued lowering
        vm.prank(owner);
        policy.proposeTimelockDelay(30 days);
        assertEq(policy.pendingTimelockEta(), 0);
        vm.warp(eta);
        vm.expectRevert(VaultPolicy.NothingPending.selector);
        policy.applyTimelockDelay();
        // queue again; applicable through the last second of the grace period, not after
        vm.prank(owner);
        policy.proposeTimelockDelay(2 days);
        eta = policy.pendingTimelockEta();
        uint256 snap = vm.snapshotState();
        vm.warp(eta + 14 days);
        policy.applyTimelockDelay();
        assertEq(policy.timelockDelay(), 2 days);
        vm.revertToState(snap);
        vm.warp(eta + 1);
        policy.applyTimelockDelay();
        assertEq(policy.timelockDelay(), 2 days);
        vm.revertToState(snap);
        vm.warp(eta + 14 days + 1);
        vm.expectRevert(VaultPolicy.Expired.selector);
        policy.applyTimelockDelay();
    }

    function _try(VaultPolicy.RiskConfig memory c) internal returns (bool ok) {
        vm.prank(owner);
        try policy.proposeConfig(c) {
            ok = true;
        } catch (bytes memory err) {
            assertEq(bytes4(err), VaultPolicy.InvalidConfig.selector);
        }
    }

    /// Mutants: every bound of VaultPolicy._validate (`||` -> `&&`, `== 0` -> `== 1`, `<` -> `<=`, ...): each field
    /// is accepted on its bound and refused one past it. Also `_allow` refuses a spot asset at initialisation.
    function test_HLR2_M56_kills_validateBounds() public {
        VaultPolicy.RiskConfig memory c;
        // (field index, lowest valid, highest valid); 0 = none below / above the type limit
        uint256[3][8] memory b = [
            [uint256(0), 1, 500_000], // maxLeverageBps
            [uint256(1), 1, 10_000], // maxDailyLossBps
            [uint256(2), 1, 10_000], // maxDrawdownBps
            [uint256(3), 1, 2_000], // maxSlippageBps
            [uint256(4), 1, type(uint64).max], // maxOrderNotional
            [uint256(5), 1 hours, 30 days], // maxEpochDuration
            [uint256(6), 500, 10_000], // maxNavMoveBps
            [uint256(7), 1, 300] // maxFlattenSlippageBps
        ];
        for (uint256 i; i < 8; ++i) {
            for (uint256 k; k < 4; ++k) {
                c = _defaultRisk();
                uint256 v = k == 0 ? b[i][1] - 1 : k == 1 ? b[i][1] : k == 2 ? b[i][2] : b[i][2] + 1;
                if (k == 3 && i == 4) continue; // uint64 max: nothing above
                _set(c, i, v);
                bool valid = k == 1 || k == 2;
                assertEq(_try(c), valid, string.concat("field ", vm.toString(i), " case ", vm.toString(k)));
            }
        }
        uint32[] memory spot = new uint32[](1);
        spot[0] = 10_000;
        VaultPolicy p = _fresh();
        vm.expectRevert(VaultPolicy.SpotNotSupported.selector);
        p.initialize(owner, _defaultRisk(), spot, 2 days, address(0));
    }

    function _set(VaultPolicy.RiskConfig memory c, uint256 i, uint256 v) internal pure {
        if (i == 0) c.maxLeverageBps = uint32(v);
        else if (i == 1) c.maxDailyLossBps = uint32(v);
        else if (i == 2) c.maxDrawdownBps = uint32(v);
        else if (i == 3) c.maxSlippageBps = uint32(v);
        else if (i == 4) c.maxOrderNotional = uint64(v);
        else if (i == 5) c.maxEpochDuration = uint64(v);
        else if (i == 6) c.maxNavMoveBps = uint32(v);
        else c.maxFlattenSlippageBps = uint32(v);
    }

    /// Mutants: PxMath.boundedLimitPx1e8 `if (rounded == 0) rounded = 1` deleted / `== 1` / `= 0`. A sell flatten on
    /// a 1-tick mark rounds down to zero; the order price is floored at one tick, never zero (a zero price order is
    /// refused by HyperCore and the position would stay open).
    function test_HLR2_M57_kills_zeroPriceFloor() public view {
        (bool isBuy, uint64 px, uint64 sz) = policy.flattenOrder(1, 0, 10, 0);
        assertFalse(isBuy);
        assertEq(px, 1e2, "one tick at szDecimals 0");
        assertEq(sz, 10e8);
    }
}
