// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {EconBase} from "./EconBase.t.sol";
import {HyperVault} from "../../../../src/HyperVault.sol";
import {HyperCore} from "../../../../src/hypercore/HyperCore.sol";
import {BreachReason, IHyperVaultErrors as E} from "../../../../src/VaultTypes.sol";

/// @notice hl-r2 liveness of exits (domain 3.8). Each test documents who can still get out under one condition, the
///         rule chain, and the earliest time. Tests named test_HLR2_E.. are PoCs of findings (they pass while the
///         issue exists); test_HLR2_L.. are liveness facts for LIVENESS.md.
contract HlR2Liveness is EconBase {
    bytes internal constant REVERTER = hex"60006000fd"; // PUSH1 0 PUSH1 0 REVERT

    function _try(address who, bytes memory data) internal returns (bool ok) {
        vm.prank(who);
        (ok,) = address(vault).call(data);
    }

    /// alice 100k + mallory 100k, all on Core; alice asks to redeem half her shares.
    function _standard() internal returns (uint256 aliceShares) {
        _fundTwo(100_000e6, 100_000e6);
        aliceShares = vault.balanceOf(alice) / 2;
        _redeem(alice, aliceShares);
    }

    // ------------------------------------------------------------------
    // L-01: precompile outage. Which entry points still work when one read precompile reverts.
    // ------------------------------------------------------------------
    function _matrix(address pc) internal returns (bool[12] memory r) {
        _fundTwo(100_000e6, 100_000e6);
        _redeem(alice, vault.balanceOf(alice) / 4);
        _toEvm(50_000e6); // idle so that a settle could pay
        vm.prank(bob);
        vault.requestDeposit(20e6, bob); // bob has a pending deposit to cancel
        vm.prank(owner);
        vault.setDepositCap(1e30); // factory vaults always have a non-zero cap, so requestDeposit reads the NAV
        _setWithdrawable(address(vault), 100_000e6); // bridgeToEvm is limited by the precompile only
        vm.etch(pc, REVERTER);
        r[0] = _try(mallory, abi.encodeCall(HyperVault.requestRedeem, (1e12, mallory, mallory)));
        r[1] = _try(mallory, abi.encodeCall(HyperVault.cancelRedeemRequest, ()));
        r[2] = _try(bob, abi.encodeCall(HyperVault.cancelDepositRequest, ()));
        r[3] = _try(bob, abi.encodeCall(HyperVault.requestDeposit, (20e6, bob)));
        r[4] = _try(manager, abi.encodeCall(HyperVault.settle, ()));
        r[5] = _try(stranger, abi.encodeCall(HyperVault.checkRisk, ()));
        r[6] = _try(manager, abi.encodeCall(HyperVault.bridgeToEvm, (100e6)));
        r[7] = _try(manager, abi.encodeCall(HyperVault.flatten, (BTC, 0)));
        r[8] = _try(owner, abi.encodeCall(HyperVault.triggerEmergency, ()));
        r[9] = _try(guardian, abi.encodeCall(HyperVault.settle, ())); // emergency exit-only settle
        r[10] = _try(stranger, abi.encodeCall(HyperVault.accrueFees, ()));
        r[11] = _try(alice, abi.encodeCall(HyperVault.requestRedeem, (1e12, alice, alice)));
    }

    function test_HLR2_L01_precompileOutage_accountMarginSummary() public {
        bool[12] memory r = _matrix(HyperCore.PRECOMPILE_ACCOUNT_MARGIN_SUMMARY);
        _log("0x80F accountMarginSummary", r);
        assertTrue(r[0] && r[1] && r[2] && r[8] && r[11], "requests, cancels, emergency still work");
        assertFalse(r[3] || r[4] || r[5] || r[9] || r[10], "deposit, settle (every mode), checkRisk, accrue blocked");
        assertFalse(r[6], "bridgeToEvm snapshots coreEquity for its window");
        assertTrue(r[7], "flatten still works");
    }

    function test_HLR2_L01_precompileOutage_spotBalance() public {
        bool[12] memory r = _matrix(HyperCore.PRECOMPILE_SPOT_BALANCE);
        _log("0x801 spotBalance", r);
        assertTrue(r[0] && r[1] && r[2] && r[8]);
        assertFalse(r[4] || r[6] || r[9], "settle and bridgeToEvm blocked");
    }

    function test_HLR2_L01_precompileOutage_coreUserExists() public {
        bool[12] memory r = _matrix(HyperCore.PRECOMPILE_CORE_USER_EXISTS);
        _log("0x810 coreUserExists", r);
        assertTrue(r[0] && r[1] && r[2] && r[8]);
        assertFalse(r[4] || r[9], "settle blocked in every mode");
    }

    function test_HLR2_L01_precompileOutage_position() public {
        bool[12] memory r = _matrix(HyperCore.PRECOMPILE_POSITION);
        _log("0x813 position", r);
        assertTrue(r[4] && r[6], "settle and bridgeToEvm unaffected (the later emergency settle / accrue only wait for the bridge window r[6] opened)");
        assertFalse(r[7], "flatten blocked");
    }

    function _log(string memory name, bool[12] memory r) internal pure {
        console2.log(name);
        console2.log(" requestRedeem / cancelRedeem / cancelDeposit / requestDeposit", r[0], r[1], r[2]);
        console2.log("   requestDeposit", r[3]);
        console2.log(" settle(manager) / checkRisk / bridgeToEvm", r[4], r[5], r[6]);
        console2.log(" flatten / triggerEmergency / emergency settle", r[7], r[8], r[9]);
        console2.log(" accrueFees / requestRedeem(alice)", r[10], r[11]);
    }

    // ------------------------------------------------------------------
    // L-02: a delisted / unreadable curated index (position and mark reads revert for that index only).
    // ------------------------------------------------------------------
    function test_HLR2_L02_unreadableIndexBlocksOnlyItsFlatten() public {
        uint32 SOL = 5; // no mock response: position(vault, 5) and markPx(5) revert
        _standard();
        _toEvm(60_000e6);
        vm.prank(guardian);
        vm.expectRevert(); // flatten(5) cannot even read the position
        vault.flatten(SOL, 0);
        vault.checkRisk(); // NAV and leverage read the account summary only
        _settleAs(manager);
        vault.claim(alice);
        assertGt(usdc.balanceOf(alice), 900_000e6 + 49_000e6);
    }

    // ------------------------------------------------------------------
    // L-03: redemption larger than idle USDC (InsufficientLiquidity) and who can unblock it.
    // ------------------------------------------------------------------
    function test_HLR2_L03_insufficientLiquidityChain() public {
        uint256 s = _standard(); // everything on Core, no withdrawable (positions use the margin)
        vm.expectRevert(abi.encodeWithSelector(E.InsufficientLiquidity.selector, 0, vault.convertToAssets(s)));
        _settleAs(manager);
        vm.expectRevert(abi.encodeWithSelector(E.InsufficientLiquidity.selector, 0, vault.convertToAssets(s)));
        _settleAs(operatorK);
        // platform roles cannot settle a healthy, not overdue epoch at all
        vm.prank(guardian);
        vm.expectRevert(E.Unauthorized.selector);
        vault.settle();
        // the operator cannot reduce positions outside a breach (only the manager trades / flattens there)
        vm.prank(operatorK);
        vm.expectRevert(E.Unauthorized.selector);
        vault.flatten(BTC, 0);
        // nobody but the manager / operator can bring USDC home outside emergency
        vm.prank(guardian);
        vm.expectRevert(E.Unauthorized.selector);
        vault.bridgeToEvm(100e6);
        // a stranger cannot trigger the emergency before the epoch is overdue
        vm.prank(alice);
        vm.expectRevert(E.NotOverdue.selector);
        vault.triggerEmergency();
        // overdue: the exit-only settle by a platform role still needs full liquidity outside emergency
        vm.warp(uint256(vault.epochStartedAt()) + 7 days);
        vm.prank(guardian);
        vm.expectRevert();
        vault.settle();
        // anyone triggers the emergency; the guardian settles a partial fill of what is home (here nothing)
        vm.prank(alice);
        vault.triggerEmergency();
        vm.prank(guardian);
        vault.settle();
        vault.claim(alice);
        assertEq(vault.balanceOf(alice), 2 * s, "nothing home: every share returned");
        // the platform flattens and brings USDC home, then settles; alice re-requests
        _setWithdrawable(address(vault), 200_000e6);
        vm.prank(guardian);
        vault.bridgeToEvm(200_000e6);
        _toEvm(200_000e6);
        _setWithdrawable(address(vault), 0);
        _skipBridgeWindow();
        _redeem(alice, s);
        vm.prank(guardian);
        vault.settle();
        vault.claim(alice);
        assertApproxEqAbs(usdc.balanceOf(alice), 950_000e6, 100e6, "paid after overdue + emergency + unwind");
    }

    // ------------------------------------------------------------------
    // L-04: loss breach (daily loss / drawdown): redemption-only settles by ANY listed role, no overdue needed.
    // ------------------------------------------------------------------
    function test_HLR2_L04_lossBreachRedemptionOnlyByAnyRole() public {
        uint256 s = _standard();
        _toEvm(60_000e6);
        _hours(2);
        vault.checkRisk();
        _setCoreValue(_core - 30_000e6); // -15%: daily loss (5%) breach
        vault.checkRisk();
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DAILY_LOSS));
        vm.prank(guardian);
        vault.settle(); // redemption-only, by the guardian, not overdue
        vault.claim(alice);
        assertGt(usdc.balanceOf(alice), 900_000e6 + 42_000e6);
        s;
    }

    // ------------------------------------------------------------------
    // L-05: agent revoked / operator removed / manager absent.
    // ------------------------------------------------------------------
    function test_HLR2_L05_operatorRemovedManagerAbsent() public {
        _standard();
        _toEvm(100_000e6); // idle covers the redemption
        vm.prank(guardian);
        vault.revokeOperator();
        vm.prank(guardian);
        vault.revokeAgent();
        // nobody but the (absent) manager can settle normally
        vm.prank(guardian);
        vm.expectRevert(E.Unauthorized.selector);
        vault.settle();
        vm.warp(uint256(vault.epochStartedAt()) + 7 days);
        vm.prank(guardian);
        vault.settle(); // overdue exit-only by a platform role: liquidity on hand, no emergency needed
        vault.claim(alice);
        assertGt(usdc.balanceOf(alice), 900_000e6 + 49_000e6);
    }

    // ------------------------------------------------------------------
    // L-06: emergency throughput: one partial fill per settle, shares returned, re-requested.
    // ------------------------------------------------------------------
    function test_HLR2_L06_emergencyPartialFillsInRounds() public {
        _standard(); // alice asks for 50k
        uint256 keep = vault.balanceOf(alice);
        vm.prank(guardian);
        vault.triggerEmergency();
        uint256 rounds;
        uint256 t0 = vm.getBlockNumber();
        while (rounds < 10) {
            _setWithdrawable(address(vault), 10_000e6);
            vm.prank(guardian);
            vault.bridgeToEvm(10_000e6);
            _toEvm(10_000e6);
            _setWithdrawable(address(vault), 0);
            vm.roll(vm.getBlockNumber() + 11); // landed: the 10 block window
            vault.syncBridge();
            vm.prank(guardian);
            vault.settle();
            vault.claim(alice);
            ++rounds;
            uint256 back = vault.balanceOf(alice) - keep; // returned unpaid shares
            if (back == 0) break;
            _redeem(alice, back);
        }
        console2.log("L06 rounds of 10k", rounds, "blocks", vm.getBlockNumber() - t0);
        assertEq(rounds, 5, "50k in five 10k fills, 11 blocks each");
    }

    function _pendingRedeem(address who) internal view returns (uint256 r) {
        (,, r) = vault.requests(who);
    }

    // ------------------------------------------------------------------
    // L-07: the operator's contract-side bounds (the "reduce bound" of server/src/treasury/operator.ts is an
    // off-chain rule: reductions need the manager's signed maximum). On chain the operator cannot trade or reduce
    // outside a breach, may flatten a WHOLE position at the policy band in a breach or emergency, and may pull any
    // free Core USDC home regardless of leverage.
    // ------------------------------------------------------------------
    function test_HLR2_L07_operatorBounds() public {
        _fundTwo(100_000e6, 100_000e6);
        _setPosition(address(vault), BTC, 5e5); // 5 BTC long (szDecimals 5)
        vm.prank(operatorK);
        vm.expectRevert(E.Unauthorized.selector);
        vault.placeOrder(BTC, false, 99_000e8, 1e8, true, 3, 0);
        vm.prank(operatorK);
        vm.expectRevert(E.Unauthorized.selector);
        vault.flatten(BTC, 0); // not breached
        // leverage: 500k notional on 200k = 2.5x; the operator pulls free USDC home: 4.2x, over the 3x limit
        _setCore(address(vault), 200_000e6, 500_000e6, 0);
        _setWithdrawable(address(vault), 80_000e6);
        vm.prank(operatorK);
        vault.bridgeToEvm(80_000e6); // no leverage check on chain
        _setCore(address(vault), 120_000e6, 500_000e6, 0);
        usdc.mint(address(vault), 80_000e6);
        _skipBridgeWindow();
        vault.checkRisk();
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.LEVERAGE));
        // in the breach the operator may flatten the whole position at the policy band, no signed maximum
        uint256 n = writer.count();
        vm.prank(operatorK);
        vault.flatten(BTC, 0);
        assertEq(writer.count(), n + 1, "full reduce-only IOC sent by the operator");
        vm.prank(operatorK);
        vm.expectRevert(E.Unauthorized.selector);
        vault.flatten(BTC, 200); // custom slippage: manager / guardian only
    }

    /// L-07b: a (compromised) operator can bridge the idle USDC a pending redemption needs out to Core, so the
    /// manager's settle reverts InsufficientLiquidity; revocation by owner / sentinel / guardian ends it.
    function test_HLR2_L07b_operatorCanStarveTheNextSettle() public {
        uint256 s = _standard();
        _toEvm(60_000e6);
        vm.prank(operatorK);
        vault.bridgeToCore(60_000e6); // idle only: reserved USDC is out of reach, pending redemptions are not reserved
        vm.roll(vm.getBlockNumber() + 11);
        _setCoreValue(_core + 60_000e6);
        _skipBridgeWindow();
        vm.prank(manager);
        vm.expectRevert();
        vault.settle();
        vm.prank(guardian); // standalone vault: guardian = sentinel
        vault.revokeOperator();
        s;
    }
}

interface VaultPolicyLike {
    struct RiskConfig {
        uint32 maxLeverageBps;
        uint32 maxDailyLossBps;
        uint32 maxDrawdownBps;
        uint32 maxSlippageBps;
        uint64 maxOrderNotional;
        uint64 maxEpochDuration;
        uint32 maxNavMoveBps;
        uint32 maxFlattenSlippageBps;
    }

    function config() external view returns (RiskConfig memory);
    function proposeConfig(RiskConfig calldata next) external;
    function applyPendingConfig() external;
}
