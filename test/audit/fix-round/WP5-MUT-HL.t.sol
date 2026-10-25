// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// WP5 (round 2 fix round, internal, AI-assisted; not an independent audit): kill tests for mutants of the WP1
// (Hyperliquid) lines that survived the existing suite (contracts/audit/fix-round/wp5-logs/mut/). Each test passes on
// the release code and fails on the mutant ids named in its comment (mutants.json in the same folder). Never
// block.timestamp / block.number here (via_ir rematerialisation): vm.getBlockTimestamp() / vm.getBlockNumber().

import {Vm} from "forge-std/Vm.sol";
import {HloBase} from "../hl-open/HloBase.t.sol";
import {SimBase} from "../hl-r2/async/SimBase.t.sol";
import {EconBase} from "../hl-r2/econ/EconBase.t.sol";
import {HyperVault} from "../../../src/HyperVault.sol";
import {HyperVaultFactory} from "../../../src/HyperVaultFactory.sol";
import {VaultPolicy} from "../../../src/VaultPolicy.sol";
import {HyperCore} from "../../../src/hypercore/HyperCore.sol";
import {IHyperVaultErrors as E, IHyperVaultEvents} from "../../../src/VaultTypes.sol";

/// placeOrder / agent limits (HL-PROXY, WP1).
contract WP5_MUT_HL_Orders is HloBase {
    address internal agent = makeAddr("platformAgent");
    uint128 internal cloid = 0x1234_5678_9abc_def0_1234_5678_9abc_def0;

    function setUp() public override {
        super.setUp();
        _setAgent(vault, agent);
        _setCore(address(vault), 100_000e6, 0, 0);
        _setWithdrawable(address(vault), 100_000e6);
    }

    function _open(address who, uint64 sz) internal {
        vm.prank(who);
        vault.placeOrder(BTC, true, 100_500e8, sz, false, HyperCore.TIF_IOC, cloid++);
    }

    /// Mutant 1 (`trader = msg.sender != manager || ...`): the manager's opening order must run the pre-trade risk
    /// check too, exactly like the agent's (test_PROXY_preTradeRiskCheckRefusesAnOpenAndKeepsTheBreach covers the
    /// agent only).
    function test_WP5_MUT_managerOpenRunsThePreTradeRiskCheck() public {
        _deposit(alice, 100_000e6);
        _setCore(address(vault), 0, 0, 0);
        _settle();
        vm.prank(manager);
        vault.bridgeToCore(100_000e6);
        _skipBridgeWindow();
        _setCore(address(vault), 100_000e6, 0, 0);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vault.checkRisk();
        assertFalse(vault.breached());
        _setCore(address(vault), 90_000e6, 0, 0); // -10% on a 5% daily limit, nobody checked since
        vm.expectEmit(true, false, false, true, address(vault));
        emit IHyperVaultEvents.OrderRefused(BTC, cloid, manager);
        _open(manager, 1e7);
        assertTrue(vault.breached(), "the breach found at the manager's order is kept");
    }

    /// Mutant 295 (`shift = (i % 2) / 128`): the turnover of an even clock hour must still count in the next (odd)
    /// hour; the two hours share one storage word. Regression test only: the mutant loses the even hour only when an
    /// order is written in the odd hour, and here the second order is refused before it is written (the kill check
    /// did not kill 295; a third small order would).
    function test_WP5_MUT_turnoverOfTheEvenHourSurvivesTheOddHour() public {
        vm.prank(owner);
        policy.proposeAgentLimits(VaultPolicy.AgentLimits({maxTurnoverBps: 2_000, maxOrdersPerHour: 60})); // 20k a day
        uint256 h = vm.getBlockTimestamp() / 1 hours;
        uint256 next = (h % 2 == 0) ? (h + 2) : (h + 1); // the next even hour
        vm.warp(next * 1 hours + 1);
        _open(agent, 1e7); // 10,050 in the even hour
        vm.warp(vm.getBlockTimestamp() + 1 hours); // the odd hour
        (uint256 used,) = vault.agentFlow();
        assertEq(used, 10_050e6, "the even hour's turnover is still counted");
        vm.expectRevert(abi.encodeWithSelector(E.OrderRejected.selector, "turnover"));
        _open(agent, 1e7); // 20,100 > 20,000
    }

    /// Mutant 364 (`delete $.agentFlow` removed): a new agent starts with a fresh budget. Regression test only: setAgent
    /// waits the exit notice (> 24 h), so the rolling window is empty anyway and the mutant is not killed.
    function test_WP5_MUT_newAgentStartsWithAFreshBudget() public {
        _open(agent, 1e7);
        (uint256 used, uint256 orders) = vault.agentFlow();
        assertEq(orders, 1);
        assertGt(used, 0);
        address agent2 = makeAddr("agent2");
        _setAgent(vault, agent2);
        (used, orders) = vault.agentFlow();
        assertEq(used, 0, "fresh turnover");
        assertEq(orders, 0, "fresh order count");
    }
}

/// HLR2-XA01: the deposit hold after a platform revoke.
contract WP5_MUT_HL_Hold is HloBase {
    address internal agentHolder;
    address internal launcher = makeAddr("launcher");

    function _hosted(bytes32 salt, uint256 nav) internal returns (HyperVault v) {
        (agentHolder,) = makeAddrAndKey(string(abi.encodePacked("agent", salt)));
        address predicted = factory.predictVaultAddress(launcher, salt);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        _fundLauncher(launcher, 1);
        HyperVaultFactory.CreateParams memory p = _params(launcher, salt);
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
        usdc.burnFrom(address(v), nav);
        _setCore(address(v), int64(uint64(nav + 2e6)), 0, 0);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.roll(vm.getBlockNumber() + 400);
        v.checkRisk();
    }

    /// Mutant 70 (`msg.sender == guardian || $.depositHold`): the owner's queued clearBreach (it runs as the vault
    /// itself) never lifts the hold; only the guardian does.
    function test_WP5_MUT_ownersQueuedClearKeepsTheDepositHold() public {
        HyperVault v = _hosted(bytes32(uint256(0x5A01)), 100_000e6);
        vm.prank(sentinel);
        v.revokeAgent();
        assertTrue(v.depositHold());
        _timelocked(v, abi.encodeCall(HyperVault.clearBreach, ()));
        assertTrue(v.depositHold(), "the owner's clear does not lift the hold");
        vm.prank(guardian);
        v.clearBreach();
        assertFalse(v.depositHold());
    }
}

/// HLR2-E01: the exit-only price at min(NAV, checkpoint) only for a checkpoint younger than EXIT_CHECKPOINT_FRESH.
contract WP5_MUT_HL_ExitPrice is EconBase {
    /// Mutants 121 (`>` instead of `>=`) and 126 (EXIT_CHECKPOINT_FRESH * 2): a checkpoint exactly one hour old that
    /// trails the NAV is not a price; the exit-only settle waits for the walk.
    function test_WP5_MUT_exitWaitsForAnHourOldTrailingCheckpoint() public {
        vm.prank(owner);
        vault.lowerFees(0, 0);
        _fundTwo(100_000e6, 100_000e6);
        _hours(20);
        vault.checkRisk(); // fresh checkpoint at 200k, not capped
        assertFalse(vault.checkpointLagging());
        uint256 at = vault.checkpointAt();
        _redeem(alice, vault.balanceOf(alice));
        vm.prank(owner);
        vault.triggerEmergency();
        _setCoreValue(250_000e6);
        _toEvm(110_000e6);
        vm.warp(at + 1 hours);
        vm.roll(vm.getBlockNumber() + 10);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(E.CheckpointBehind.selector, uint256(200_000e6), uint256(250_000e6)));
        vault.settle();
    }
}

/// HLR2-A02 / A08: the transfer hold and its Core-side latches (creditSeen / debitSeen).
contract WP5_MUT_HL_TransferHold is SimBase {
    /// Mutants 190 (`creditSeen = true` at arm), 412 (the to-Core branch of bridgeUnresolved deleted), 428
    /// (`c >= cashAtBridge - half`): a bridge to Core that never arrives, with the NAV short by it, holds the settle.
    function test_WP5_MUT_lostBridgeToCoreHoldsTheSettle() public {
        _bootstrap(100_000e6);
        _deposit(bob, 50_000e6);
        _warp(1 hours);
        _keeperSettle();
        vault.claim(bob);
        sim.setDeposit(0, true); // the next deposit to Core is lost
        vm.prank(operator);
        vault.bridgeToCore(50_000e6);
        _tick(2);
        vault.syncBridge();
        _tick(MAX_UNLANDED() + 1);
        assertTrue(vault.bridgeUnresolved(), "missing to-Core transfer: hold");
        _deposit(carol, 1_000e6);
        vm.prank(operator);
        vm.expectRevert(E.TransferUnresolved.selector);
        vault.settle();
    }

    /// Mutants 210 (`c < cashAtBridge + half`) and the creditSeen latch: a landing hidden on perp (the landing signal
    /// misses it) is latched while visible; a realised loss afterwards takes the cash back under the credit, and the
    /// NAV reads short against the snapshot, but nothing is held: the transfer did arrive.
    function test_WP5_MUT_latchedCreditHoldsNothingAfterARealisedLoss() public {
        _bootstrap(100_000e6);
        _deposit(bob, 50_000e6);
        _warp(1 hours);
        _keeperSettle();
        vault.claim(bob);
        vm.prank(operator);
        vault.bridgeToCore(50_000e6);
        sim.agentAct(address(vault), agent, 1, 0, int256(50_000e6)); // hides the landing on perp
        _tick(2);
        vault.syncBridge(); // the credit is visible in spot + perp cash now: latched
        sim.shock(address(vault), -30_000e6); // a realised loss: cash below the credit again
        _tick(MAX_UNLANDED() + 1);
        assertLt(vault.totalAssets() + 25_000e6, vault.equityAtBridge(), "the NAV reads short against the snapshot");
        assertFalse(vault.bridgeUnresolved(), "the credit was seen: no hold");
    }

    /// Mutant 191 (creditSeen not reset at arm): the latch of an earlier bridge never excuses a later lost one.
    function test_WP5_MUT_earlierCreditLatchDoesNotExcuseALaterLostBridge() public {
        _bootstrap(100_000e6);
        _deposit(bob, 100_000e6);
        _warp(1 hours);
        _keeperSettle();
        vault.claim(bob);
        vm.prank(operator);
        vault.bridgeToCore(50_000e6);
        sim.agentAct(address(vault), agent, 1, 0, int256(50_000e6)); // hidden landing, latched below
        _tick(2);
        vault.syncBridge();
        _tick(MAX_UNLANDED() + 1);
        assertFalse(vault.bridgeUnresolved());
        sim.setDeposit(0, true);
        vm.prank(operator);
        vault.bridgeToCore(50_000e6); // lost
        _tick(2);
        vault.syncBridge();
        _tick(MAX_UNLANDED() + 1);
        assertTrue(vault.bridgeUnresolved(), "the new transfer is missing: hold");
    }

    /// Mutants 214-218 (the debit latch): a bridge home whose Core debit was seen, lost on the way, holds the settle
    /// even after Core cash recovers part of it (the NAV still reads short by more than half: a loss on a position).
    function test_WP5_MUT_latchedDebitKeepsTheHoldAfterCashRecovers() public {
        _bootstrap(100_000e6);
        _warp(1 hours);
        vault.checkRisk();
        sim.agentAct(address(vault), agent, 3, BTC, 2e5); // 2 BTC long, 200k notional
        _tick(1);
        sim.setEvm(0, true); // the delivery to the EVM is lost
        vm.prank(operator);
        vault.bridgeToEvm(30_000e6);
        _tick(2);
        vault.syncBridge(); // the Core debit is visible: latched
        sim.shock(address(vault), 20_000e6); // cash comes back by 20k (over half of the 30k) ...
        sim.setMark(BTC, 90_000e1); // ... while the position loses 20k unrealised
        _tick(MAX_UNLANDED() + 1);
        assertTrue(vault.bridgeUnresolved(), "the debit was seen and the delivery is missing: hold");
    }
}

/// HLR2-A08 part 3: the orphaned NAV at supply 0 is minted to the guardian at the first-mint rule, and the depositor
/// is priced against it (exact share counts).
contract WP5_MUT_HL_Orphan is SimBase {
    /// Mutants 145 / 146 (orphanShares from toShares(nav, 1, 0) / toShares(nav, 0, 1)), 148 (Ceil), 150 (the deposit
    /// not re-priced against the orphan shares): exact share counts.
    function test_WP5_MUT_orphanAndDepositSharesAreExact() public {
        _bootstrap(100_000e6);
        _redeem(alice, vault.balanceOf(alice));
        vm.prank(owner);
        vault.triggerEmergency();
        _tick(331);
        sim.setEvm(2_000, false);
        uint256 all = sim.spotUsd(address(vault)) + HyperCore.withdrawable(address(vault));
        vm.prank(operator);
        vault.bridgeToEvm(all);
        _tick(MAX_UNLANDED() + 1);
        vm.prank(guardian);
        vault.writeOffBridge();
        _settleBy(operator);
        vault.claim(alice);
        assertEq(vault.totalSupply(), 0, "every share burned");
        vm.startPrank(guardian);
        vault.exitEmergency();
        vault.clearBreach();
        vm.stopPrank();
        _tick(2_000); // the transfer lands
        _deposit(carol, 10e6);
        _warp(1 hours);
        vault.checkRisk();
        uint256 g0 = vault.balanceOf(guardian);
        vm.recordLogs();
        _keeperSettle();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 nav;
        uint256 orphan;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == IHyperVaultEvents.OrphanedNavReserved.selector) {
                (nav, orphan) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
        assertGt(nav, 99_000e6, "the orphaned NAV was reserved");

        assertEq(orphan, nav * 1e6, "first-mint rule: 1e6 share units per USDC unit");
        assertEq(vault.balanceOf(guardian) - g0, orphan, "the guardian holds exactly the orphan shares");
        uint256 dep = (10e6 * (orphan + 1e6)) / (nav + 1);
        vault.claim(carol);
        assertEq(vault.balanceOf(carol), dep, "carol is priced against the orphan shares, rounded down");
    }
}
