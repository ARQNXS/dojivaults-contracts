// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {R1Base} from "../R1Base.t.sol";
import {GainsVault} from "../../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../../src/gains/GainsVaultPolicy.sol";
import {GainsNav} from "../../../../src/gains/GainsNav.sol";
import {InitParams} from "../../../../src/gains/GainsTypes.sol";
import {BreachReason} from "../../../../src/VaultTypes.sol";

/// @notice Round 2, domain ECON: deterministic PoCs of the multi-epoch economics findings (ECONOMICS.md). Each test
///         asserts the behaviour as it is today, so it passes while the issue exists. Mock diamond, live-like policy
///         (5x, 15 % daily loss, 50 % drawdown, 1 day epochs, 20 % NAV move), ETH band 20 bps.
///         Fix round WP2: the ECON-02 exit-only PoC (GR2-KEY-06) and the ECON-03 PoC are inverted (`_fix_`, they assert
///         the fixed behaviour). ECON-01 (accepted design) and ECON-02's redemption-only form (kept by GR2 XF-02:
///         capped by the per-settle NAV bound, avoidable by cancelling) still pass as documented residuals.
contract EconPoCTest is R1Base {
    address internal carol = makeAddr("econ.carol");

    function _live() internal pure returns (GainsVaultPolicy.RiskConfig memory) {
        return GainsVaultPolicy.RiskConfig({
            maxLeverageBps: 50_000,
            maxDailyLossBps: 1_500,
            maxDrawdownBps: 5_000,
            maxSlippageBps: 100,
            maxOrderNotional: 10_000_000e6,
            maxEpochDuration: 1 days,
            maxNavMoveBps: 2_000,
            maxFlattenSlippageBps: 300
        });
    }

    function _mk(uint16 mgmt, uint16 perf) internal returns (GainsVault v) {
        uint32[] memory assets = new uint32[](2);
        assets[0] = BTC;
        assets[1] = ETH;
        v = GainsVault(Clones.clone(address(vaultImpl)));
        GainsVaultPolicy p = GainsVaultPolicy(Clones.clone(address(policyImpl)));
        p.initialize(owner, _live(), assets, 2 days, address(platform), address(v));
        InitParams memory ip = _standaloneParams(p);
        ip.managementFeeBps = mgmt;
        ip.performanceFeeBps = perf;
        v.initialize(ip);
        usdc.mint(carol, 1_000_000e6);
        address[4] memory who = [alice, bob, carol, feeRecipient];
        for (uint256 i; i < who.length; ++i) {
            vm.prank(who[i]);
            usdc.approve(address(v), type(uint256).max);
        }
    }

    function _settleNoCheck(GainsVault v) internal {
        _ageEpoch(v);
        vm.prank(manager);
        v.settle();
    }

    /// @dev Closes every open trade at the current Chainlink price, after the minimum hold (GR2-KEY-01b: the manager's
    ///      closes wait it out; the price does not move meanwhile, so the ECON-01 book still closes at its open price).
    function _flat(GainsVault v) internal {
        _passHold();
        uint32 n = diamond.tradeCount(address(v));
        for (uint32 i; i < n; ++i) {
            if (diamond.getTrade(address(v), i).isOpen) _closeFilled(v, i, _px(ETH));
        }
    }

    /// @dev Every listed holder redeems everything; settles until nothing is left; returns nothing (read balances).
    function _exitAll(GainsVault v, address[] memory who) internal {
        for (uint256 round; round < 2; ++round) {
            for (uint256 i; i < who.length; ++i) {
                if (v.balanceOf(who[i]) > 0) _redeemFrom(v, who[i], v.balanceOf(who[i]));
            }
            if (v.pendingRedeemShares() == 0) break;
            _skip(2 hours);
            _settleV(v);
            for (uint256 i; i < who.length; ++i) {
                (uint256 e,,) = v.requests(who[i]);
                if (e < v.currentEpoch()) v.claim(who[i]);
            }
        }
    }

    function _holders() internal view returns (address[] memory h) {
        h = new address[](4);
        h[0] = alice;
        h[1] = bob;
        h[2] = carol;
        h[3] = feeRecipient;
    }

    // =================================================================================================================
    // GR2-ECON-01: the manager manufactures the bid / ask spread with a delta-neutral book
    // =================================================================================================================
    /// @dev Alice (the manager's confederate, or any holder) holds 100k bought while flat. Bob queues a 100k deposit.
    ///      Right before the settle the manager opens an ETH long and an ETH short of the same size (no market
    ///      exposure, 4.9x vault leverage), settles, and closes both at the same price. Bob's deposit is priced at the
    ///      favourable band edge of a book that exists only for that settle; bob then leaves while flat. With Gains'
    ///      fees at 0 (mock default) bob pays 0.49 % of his deposit to alice; at a fee of `feeP` per side the book
    ///      costs alice 2 x fee x notional, so it pays when the flow is large against the vault.
    function test_GR2_ECON_01_hedgedBookAtSettleChargesDepositorTheBand() public {
        (uint256 bobOut, uint256 aliceOut) = _spreadFarm(0, 100_000e6, 100_000e6);
        console2.log("fee 0     : bob out of 100,000 (USDC)", bobOut);
        console2.log("fee 0     : alice out of 100,000 (USDC)", aliceOut);
        assertLt(bobOut, 99_550e6, "bob pays about B x 4.9 x his share of the book (0.49 %), nothing changed in value");
        assertGt(aliceOut, 100_450e6, "the holder collects it");
        assertApproxEqAbs(bobOut + aliceOut, 200_000e6, 10, "a pure transfer");
    }

    /// @dev Same with Gains' position fee at 3.6 bps per side (about what the fork tests measured round trip on ETH)
    ///      and a flow twice the vault: the book still pays the holder after its fees.
    function test_GR2_ECON_01_hedgedBookPaysAfterGainsFeesOnALargeFlow() public {
        (uint256 bobOut, uint256 aliceOut) = _spreadFarm(3.6e8, 100_000e6, 200_000e6);
        console2.log("fee 3.6bp : bob out of 200,000 (USDC)", bobOut);
        console2.log("fee 3.6bp : alice out of 100,000 (USDC)", aliceOut);
        assertLt(bobOut, 199_500e6, "bob pays the band on the manufactured book");
        assertGt(aliceOut, 100_150e6, "the holder nets the band minus the book's Gains fees");
    }

    /// @dev Redemption side: carol redeems 50k while the manufactured book is open; she is paid at the adverse edge.
    function test_GR2_ECON_01_hedgedBookAtSettleUnderpaysRedeemer() public {
        GainsVault v = _mk(0, 0);
        _depositTo(v, alice, 100_000e6);
        _depositTo(v, carol, 100_000e6);
        _settleV(v);
        v.claim(alice);
        v.claim(carol);
        _redeemFrom(v, carol, v.balanceOf(carol));
        uint256 nav = v.totalAssets();
        uint120 coll = uint120((nav * 49_000 / 10_000) / 2 / 10); // half the 4.9x book per side, 10x each
        _open(v, ETH, true, coll, 10_000);
        _open(v, ETH, false, coll, 10_000);
        _skip(2 hours);
        _settleV(v);
        uint256 c0 = usdc.balanceOf(carol);
        v.claim(carol);
        uint256 carolOut = usdc.balanceOf(carol) - c0;
        _flat(v);
        console2.log("carol redeemed 100,000 of value, paid (USDC)", carolOut);
        assertLt(carolOut, 99_100e6, "carol is paid B x 4.9 below the value she redeemed (about 0.98 %)");
        assertGt(v.totalAssets(), 100_900e6, "alice keeps it");
    }

    function _spreadFarm(uint256 feeP, uint256 holder, uint256 flow) internal returns (uint256 bobOut, uint256 aliceOut) {
        diamond.setPair(ETH, feeP, 285.7e18, 0.1e18, 0);
        GainsVault v = _mk(0, 0);
        _depositTo(v, alice, holder);
        _settleV(v);
        v.claim(alice);
        _depositTo(v, bob, flow);
        // the manager's book, delta neutral: half long, half short, 4.9x of the vault
        uint256 nav = v.totalAssets();
        uint120 coll = uint120((nav * 49_000 / 10_000) / 2 / 10);
        _open(v, ETH, true, coll, 10_000);
        _open(v, ETH, false, coll, 10_000);
        GainsNav.Snapshot memory s = v.venue();
        console2.log("book notional (USDC) / vault NAV (USDC)", s.notional / 1e6, v.totalAssets() / 1e6);
        _settleV(v); // bob mints at the favourable edge
        v.claim(bob);
        _flat(v); // the book is closed at the same price: nothing gained or lost on the market
        uint256 b0 = usdc.balanceOf(bob);
        uint256 a0 = usdc.balanceOf(alice);
        _exitAll(v, _holders());
        bobOut = usdc.balanceOf(bob) - b0;
        aliceOut = usdc.balanceOf(alice) - a0;
    }

    // =================================================================================================================
    // GR2-ECON-02: a loss-breach settle pays redemptions at the dip the settler picked
    // =================================================================================================================
    /// @dev 200k vault at 4.9x ETH long. ETH -3.5 %: NAV -17 %, checkRisk sets the daily loss breach and moves the
    ///      checkpoint to the dip. Bob asks to redeem everything. ETH recovers +3 % within the hour. The manager (or
    ///      owner, operator, guardian, sentinel) settles redemption-only now: bob is paid at min(NAV, checkpoint) = the
    ///      dip. Nobody can move the checkpoint up within the hour (CHECKPOINT_INTERVAL), so bob cannot protect
    ///      himself except by cancelling. Control: the same settle an hour later after anyone's checkRisk.
    function test_GR2_ECON_02_redemptionOnlySettlePaysTheDipNotTheRebound() public {
        GainsVault v = _mk(0, 0);
        _depositTo(v, alice, 100_000e6);
        _depositTo(v, bob, 100_000e6);
        _settleV(v);
        v.claim(alice);
        v.claim(bob);
        _skip(12 hours);
        _settleV(v); // a new epoch early on a new UTC day (nothing queued); its checkRisk sets the day's reference
        uint256 nav = v.totalAssets();
        _open(v, ETH, true, uint120(nav * 49_000 / 10_000 / 10), 10_000);
        _skip(2 hours);
        uint64 p0 = _px(ETH);
        _setPrice(ETH, p0 * 965 / 1000);
        v.checkRisk();
        assertEq(uint8(v.breachReason()), uint8(BreachReason.DAILY_LOSS), "daily loss breach");
        uint256 dip = v.checkpointNav();
        _redeemFrom(v, bob, v.balanceOf(bob));
        _skip(30 minutes);
        _setPrice(ETH, p0 * 995 / 1000); // rebound
        uint256 navNow = v.totalAssets();
        console2.log("checkpoint at the dip / NAV after the rebound (USDC)", dip / 1e6, navNow / 1e6);
        uint256 snap = vm.snapshotState();

        vm.prank(manager);
        v.settle(); // redemption-only, priced at min(NAV, checkpoint)
        uint256 b0 = usdc.balanceOf(bob);
        v.claim(bob);
        uint256 paidAtDip = usdc.balanceOf(bob) - b0;

        vm.revertToState(snap);
        _skip(31 minutes);
        v.checkRisk(); // anyone, once the hour has passed: the checkpoint follows the NAV
        vm.prank(manager);
        v.settle();
        b0 = usdc.balanceOf(bob);
        v.claim(bob);
        uint256 paidAfterRatchet = usdc.balanceOf(bob) - b0;

        console2.log("bob paid when settled at once (USDC)", paidAtDip);
        console2.log("bob paid an hour later (USDC)", paidAfterRatchet);
        assertLt(paidAtDip * 100, paidAfterRatchet * 90, "the settler's timing takes more than 10 % of bob's redemption");
    }

    /// @dev Exit-only (overdue) variant: the owner lets the epoch run overdue, calls checkRisk at a dip (the next
    ///      ratchet is an hour away for everyone) and settles exit-only after the rebound. Was: priced at
    ///      min(NAV, checkpoint) = the dip, more than 8 % of the redemption kept by the holders. Fixed (GR2-KEY-06):
    ///      an exit-only settle on a fresh checkpoint pays up to the value the dip's ratchet replaced, so after the
    ///      rebound bob is paid what the treasury's normal settle of the same moment pays.
    function test_GR2_ECON_02_fix_overdueExitOnlySettleByOwnerPaysTheRebound() public {
        GainsVault v = _mk(0, 0);
        _depositTo(v, alice, 100_000e6);
        _depositTo(v, bob, 100_000e6);
        _settleV(v);
        v.claim(alice);
        v.claim(bob);
        uint256 nav = v.totalAssets();
        _open(v, ETH, true, uint120(nav * 40_000 / 10_000 / 10), 10_000);
        _redeemFrom(v, bob, v.balanceOf(bob) / 2);
        _skip(1 days + 1); // overdue: nobody settled
        uint64 p0 = _px(ETH);
        _setPrice(ETH, p0 * 975 / 1000); // -2.5 %: NAV -10 %, no breach (daily reference not set today)
        vm.prank(owner);
        v.checkRisk(); // the owner fixes the checkpoint at the dip
        _skip(40 minutes);
        _setPrice(ETH, p0); // full rebound
        uint256 snap = vm.snapshotState();
        vm.prank(owner);
        v.settle(); // exit-only: priced at min(NAV, checkpoint)
        uint256 b0 = usdc.balanceOf(bob);
        v.claim(bob);
        uint256 paidByOwner = usdc.balanceOf(bob) - b0;
        vm.revertToState(snap);
        vm.prank(manager);
        v.settle(); // the treasury's normal settle of the same epoch: live NAV
        b0 = usdc.balanceOf(bob);
        v.claim(bob);
        uint256 paidNormal = usdc.balanceOf(bob) - b0;
        console2.log("bob (half his stake) paid by the owner's exit-only settle", paidByOwner);
        console2.log("bob paid by a normal settle at the same moment", paidNormal);
        assertLe(paidByOwner, paidNormal, "never above the live NAV");
        assertApproxEqRel(paidByOwner, paidNormal, 0.001e18, "the owner's timing takes nothing from bob (within 0.1 %)");
    }

    // =================================================================================================================
    // GR2-ECON-03: a leverage-breach settle mints deposits without crystallising the performance fee
    // =================================================================================================================
    /// @dev Performance fee 20 %, no management fee. Alice holds 100k; the manager's 3x ETH long gains about 9 %
    ///      since the last settle. Bob queues 100k. The manager opens up to the 5x limit; the open's own cost (the
    ///      band on the new notional) puts vault leverage over the limit, so the keeper's checkRisk before the settle
    ///      sets a LEVERAGE breach. A leverage breach settles normally (deposits minted) but charges no performance fee
    ///      and keeps the high water mark: bob buys in above the HWM, and the next normal settle charges 20 % of the
    ///      gain since the HWM on his shares too. Control: the same settle without the breach (fee crystallised first).
    ///      Fixed (GR2-ECON-03): the leverage-breach settle charges the performance fee before it mints, so bob and the
    ///      fee recipient end up as in the control.
    function test_GR2_ECON_03_fix_leverageBreachSettleChargesTheFeeBeforeMinting() public {
        GainsVault v = _mk(0, 2_000);
        _depositTo(v, alice, 100_000e6);
        _settleV(v);
        v.claim(alice);
        _open(v, ETH, true, 30_000e6, 10_000); // 300k notional, 3x
        _skip(3 hours);
        _setPrice(ETH, _px(ETH) * 103 / 100);
        _depositTo(v, bob, 100_000e6);
        uint256 nav = v.totalAssets();
        uint256 notional = v.venue().notional;
        uint120 coll = uint120((nav * 50_000 / 10_000 - notional) / 10);
        _open(v, ETH, true, coll, 10_000); // exactly to the policy's 5x: passes checkOrder
        console2.log("share price (1e6 = 1 USDC) / high water mark", v.sharePrice(), v.highWaterMark());
        uint256 snap = vm.snapshotState();

        // the keeper's flow: checkRisk, then settle
        v.checkRisk();
        assertTrue(v.breached() && v.breachReason() == BreachReason.LEVERAGE, "leverage breach from the open's own cost");
        _settleNoCheck(v);
        assertGt(v.highWaterMark(), 1e6, "performance fee charged, HWM moved, before bob is minted");
        (uint256 bobA, uint256 feeA, uint256 aliceA) = _finishPerf(v, true);

        vm.revertToState(snap);
        _settleNoCheck(v); // control: the same settle with no breach set
        (uint256 bobC, uint256 feeC, uint256 aliceC) = _finishPerf(v, false);

        console2.log("bob out of 100,000: with the breach / without", bobA, bobC);
        console2.log("fee recipient: with the breach / without", feeA, feeC);
        console2.log("alice: with the breach / without", aliceA, aliceC);
        assertApproxEqAbs(bobA, bobC, 1e6, "bob pays no performance fee on gains made before he entered");
        assertApproxEqAbs(feeA, feeC, 1e6, "the fee recipient collects no extra fee");
    }

    function _finishPerf(GainsVault v, bool clear) internal returns (uint256 bobOut, uint256 feeOut, uint256 aliceOut) {
        v.claim(bob);
        _flat(v);
        if (clear) {
            _skip(16 minutes);
            v.clearLeverageBreach();
        }
        uint256 b0 = usdc.balanceOf(bob);
        uint256 f0 = usdc.balanceOf(feeRecipient);
        uint256 a0 = usdc.balanceOf(alice);
        _skip(1 hours);
        _settleV(v); // a normal settle: crystallises the performance fee
        _exitAll(v, _holders());
        bobOut = usdc.balanceOf(bob) - b0;
        feeOut = usdc.balanceOf(feeRecipient) - f0;
        aliceOut = usdc.balanceOf(alice) - a0;
    }
}
