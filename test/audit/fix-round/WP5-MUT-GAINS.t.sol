// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// WP5 (round 2 fix round, internal, AI-assisted; not an independent audit): kill tests for mutants of the WP2 (gTrade)
// lines that survived the existing suite (contracts/audit/fix-round/wp5-logs/mut/). Each test passes on the release
// code and fails on the mutant ids named in its comment. Never block.timestamp / block.number here.

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {R1Base} from "../gains/R1Base.t.sol";
import {GainsVault} from "../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../src/gains/GainsVaultPolicy.sol";
import {InitParams, OpenParams, IGainsVaultErrors} from "../../../src/gains/GainsTypes.sol";

contract WP5_MUT_Gains is R1Base {
    bytes4 internal constant SKEW_DEPTH = bytes4(keccak256("getPairSkewDepth(uint8,uint16)"));
    uint8 internal constant CI = 3;
    uint256 internal constant HOLD = 10 minutes;
    uint256 internal constant HOLD_BLOCKS = 2_400;

    function _live() internal pure returns (GainsVaultPolicy.RiskConfig memory) {
        return GainsVaultPolicy.RiskConfig({
            maxLeverageBps: 50_000,
            maxDailyLossBps: 1_500,
            maxDrawdownBps: 5_000,
            maxSlippageBps: 100,
            maxOrderNotional: 250_000e6,
            maxEpochDuration: 1 days,
            maxNavMoveBps: 2_000,
            maxFlattenSlippageBps: 300
        });
    }

    function _mk(uint256 nav) internal returns (GainsVault v) {
        return _mkWith(nav, 2 days);
    }

    function _mkWith(uint256 nav, uint256 delay) internal returns (GainsVault v) {
        uint32[] memory assets = new uint32[](2);
        assets[0] = BTC;
        assets[1] = ETH;
        v = GainsVault(Clones.clone(address(vaultImpl)));
        GainsVaultPolicy p = GainsVaultPolicy(Clones.clone(address(policyImpl)));
        p.initialize(owner, _live(), assets, delay, address(platform), address(v));
        InitParams memory ip = _standaloneParams(p);
        ip.managementFeeBps = 0;
        ip.performanceFeeBps = 0;
        ip.timelockDelay = delay;
        v.initialize(ip);
        if (nav == 0) return v;
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        _depositTo(v, alice, nav);
        _settleV(v);
        v.claim(alice);
    }

    function _minHold() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IGainsVaultErrors.OrderRejected.selector, "min hold");
    }

    /// Mutants 692-694 (GainsNav.snapshot: a resting limit order's notional not counted, or subtracted, in the pair's
    /// notional): a resting 250k limit on ETH plus a 100k market open exceed the 300k pair cap.
    function test_WP5_MUT_restingLimitCountsTowardThePairCap() public {
        GainsVault v = _mk(1_000_000e6);
        uint256 depth = uint256(300_000e6) * 1e22 * 10_000 / (100 * uint256(_px(ETH)));
        vm.mockCall(address(diamond), abi.encodeWithSelector(SKEW_DEPTH, CI, ETH), abi.encode(depth));
        OpenParams memory lim = _params(ETH, true, 10_000e6, 25_000); // 250k notional
        lim.tradeType = 1;
        lim.expectedPrice = _px(ETH) * 995 / 1000;
        vm.prank(manager);
        v.openTrade(lim); // rests (not filled)
        OpenParams memory p = _params(ETH, true, 4_000e6, 25_000); // 100k
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IGainsVaultErrors.OrderRejected.selector, "pair depth"));
        v.openTrade(p); // 350k > 300k
    }

    /// Mutants 750-755 (holdPair: the trade's own Gains-block hold skipped or misread): the pair's time hold is over,
    /// the trade's fill-block hold is not: the manager's flatten of the pair is still refused.
    function test_WP5_MUT_flattenWaitsForTheTradesOwnHold() public {
        GainsVault v = _mk(100_000e6);
        _open(v, ETH, true, 10_000e6, 10_000);
        _skip(HOLD); // the pair stamp (time) has expired
        vm.prank(manager);
        vm.expectRevert(_minHold());
        v.flatten(ETH, 0, _px(ETH), type(uint256).max);
        vm.roll(vm.getBlockNumber() + HOLD_BLOCKS);
        vm.prank(manager);
        v.flatten(ETH, 0, _px(ETH), type(uint256).max);
    }

    /// Mutant 1057 (increaseTrade does not call _spendTurnover): an increase is new risk on the pair; it stamps the pair
    /// hold, so another trade of the same pair cannot be closed right after it.
    function test_WP5_MUT_increaseStampsThePairHold() public {
        GainsVault v = _mk(100_000e6);
        uint32 a = _open(v, ETH, true, 10_000e6, 10_000);
        uint32 b = _open(v, ETH, true, 10_000e6, 10_000);
        _skip(HOLD);
        vm.roll(vm.getBlockNumber() + HOLD_BLOCKS);
        vm.prank(manager);
        v.increaseTrade(b, 2_000e6, 10_000, _px(ETH), SLIP); // new risk on ETH (request; not filled)
        vm.prank(manager);
        vm.expectRevert(_minHold());
        v.closeTrade(a, _px(ETH));
    }

    /// Mutant 1038 (`priorCheckpointNav = prev` deleted in _checkpoint): the exit-only price cap is the higher of the
    /// fresh checkpoint and the value its LAST ratchet replaced, not the settle-time value. A gain is ratcheted in
    /// (cp A), then a dip (cp D, prior A); at the rebound the exit pays what the normal settle pays.
    function test_WP5_MUT_priorIsTheValueTheLastRatchetReplaced() public {
        address stayer = makeAddr("wp5.stayer");
        address leaver = makeAddr("wp5.leaver");
        GainsVault v = _mk(0);
        address[2] memory who = [stayer, leaver];
        for (uint256 i; i < 2; ++i) {
            usdc.mint(who[i], 1_000_000e6);
            vm.prank(who[i]);
            usdc.approve(address(v), type(uint256).max);
            _depositTo(v, who[i], 50_000e6);
        }
        _settleV(v);
        v.claim(stayer);
        v.claim(leaver);
        uint256 nav = v.totalAssets();
        _open(v, ETH, true, uint120(nav / 5), 10_000); // 10x on a fifth: 2x NAV
        _redeemFrom(v, leaver, v.balanceOf(leaver));
        uint64 p0 = _px(ETH);
        _skip(2 hours);
        _setPrice(ETH, p0 * 1050 / 1000); // +10 % NAV
        v.checkRisk(); // cp A (gain), prior = the settle value
        _skip(2 hours);
        _setPrice(ETH, p0); // back down
        v.checkRisk(); // cp D (dip), prior = A
        _skip(40 minutes);
        _setPrice(ETH, p0 * 1050 / 1000); // rebound
        uint256 snap = vm.snapshotState();
        vm.startPrank(guardian);
        v.triggerEmergency();
        v.settle();
        vm.stopPrank();
        v.claim(leaver);
        uint256 paidExit = usdc.balanceOf(leaver);
        vm.revertToState(snap);
        vm.prank(manager);
        v.settle();
        v.claim(leaver);
        uint256 paidNormal = usdc.balanceOf(leaver);
        assertApproxEqAbs(paidExit, paidNormal, 1e6, "the exit pays at the rebound, not at the settle-time value");
    }

    /// Mutants 1156 (the pending config's longer epoch ignored), 1168 / 1171 (the timelock delay ignored): an asset
    /// queued beside a pending config that lengthens the epoch waits for the longer epoch plus the margin, and never
    /// less than the timelock delay.
    function test_WP5_MUT_noticeCoversThePendingEpochAndTheDelay() public {
        GainsVault v = _mkWith(100_000e6, 5 days); // delay 5 d > 1 d epoch + 1 d
        GainsVaultPolicy p = v.policy();
        uint256 t0 = vm.getBlockTimestamp();
        vm.prank(owner);
        p.queueAllowAsset(ETH);
        assertEq(p.assetAllowEta(ETH), t0 + 5 days, "never less than the timelock delay");
        GainsVaultPolicy.RiskConfig memory c = _live();
        c.maxEpochDuration = 10 days; // longer epochs: loosening, so it waits
        vm.prank(owner);
        p.proposeConfig(c);
        vm.prank(owner);
        p.queueAllowAsset(ETH); // queued again beside the pending config
        assertEq(p.assetAllowEta(ETH), t0 + 10 days + 1 days, "the pending longer epoch plus EXIT_MARGIN");
    }

    /// Mutants 748 / 749 (holdPair: the pair's time hold skipped): the trade's block hold is over, the pair's time hold
    /// is not: the manager's flatten of the pair is still refused.
    function test_WP5_MUT_flattenWaitsForThePairsHold() public {
        GainsVault v = _mk(100_000e6);
        _open(v, ETH, true, 10_000e6, 10_000);
        vm.roll(vm.getBlockNumber() + HOLD_BLOCKS); // the trade's own block hold has passed, the clock has not moved
        vm.prank(manager);
        vm.expectRevert(_minHold());
        v.flatten(ETH, 0, _px(ETH), type(uint256).max);
        _skip(HOLD);
        vm.prank(manager);
        v.flatten(ETH, 0, _px(ETH), type(uint256).max);
    }
}
