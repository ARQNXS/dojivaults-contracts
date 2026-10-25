// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GovBase} from "./GovBase.t.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GainsVault} from "../../../../src/gains/GainsVault.sol";
import {IGainsVaultErrors as E, operatorReduceCap} from "../../../../src/gains/GainsTypes.sol";
import {DECIMALS_OFFSET} from "../../../../src/VaultTypes.sol";

/// @notice Task 2: the operator's reduce bound outside a breach (redemptionShortfall + 2% + 1 USDC, GainsTypes.sol:29).
///         Concurrent and repeated reduces, fills, cancels, a stale checkpoint, the claimable reserve, deferred insider
///         deposits, and what a compromised operator (or agent) can burn through Gains fees.
contract GovOperatorBoundTest is GovBase {
    uint32 internal a; // ETH trade
    uint32 internal b; // BTC trade

    /// alice: 10,000 USDC in the factory vault (+1 USDC seed). Two 2x trades of 4,500 USDC collateral each; 1,001 idle.
    function _two() internal {
        _fundFv(10_000e6);
        a = _openFv(ETH, 4_500e6, 2_000);
        b = _openFv(BTC, 4_500e6, 2_000);
    }

    function _redeemHalf() internal returns (uint256 owed) {
        uint256 shares = fv.balanceOf(alice) / 2;
        vm.prank(alice);
        fv.requestRedeem(shares, alice, alice);
        owed = Math.mulDiv(shares, uint256(fv.checkpointNav()) + 1, fv.totalSupply() + 10 ** DECIMALS_OFFSET);
    }

    // ------------------------------------------------------------------ concurrency: several trades in one block
    function test_GOV_OB_concurrentReducesInOneBlockStayWithinOneCap() public {
        _two();
        _redeemHalf();
        uint256 s0 = fv.redemptionShortfall();
        uint256 cap0 = operatorReduceCap(s0);
        assertApproxEqAbs(s0, 3_999.5e6, 1e6);
        // split: 2,000 on A, then the rest of the cap on B, all in the same block, before any fill
        uint64 pa = _px(ETH);
        uint64 pb = _px(BTC);
        vm.startPrank(keeper);
        fv.reduceTrade(a, 2_000e6, 0, pa);
        uint256 s1 = fv.redemptionShortfall();
        assertEq(s1, s0 - 2_000e6, "the in-flight reduce counts as returned");
        uint256 cap1 = operatorReduceCap(s1);
        vm.expectRevert(abi.encodeWithSelector(E.ReduceAboveShortfall.selector, s1, cap1 + 1));
        fv.reduceTrade(b, uint120(cap1 + 1), 0, pb);
        fv.reduceTrade(b, uint120(cap1), 0, pb);
        assertEq(fv.redemptionShortfall(), 0);
        vm.expectRevert(abi.encodeWithSelector(E.ReduceAboveShortfall.selector, 0, 1));
        fv.reduceTrade(b, 1, 0, pb);
        vm.stopPrank();
        // total requested in the block: shortfall + 2% of what was left for the last reduce + 1 USDC, <= one cap
        uint256 total = 2_000e6 + cap1;
        assertLe(total, cap0);
        assertEq(total - s0, s1 * 200 / 10_000 + 1e6);
    }

    // ------------------------------------------------------------------ repeated after a fill, cancelled reduces
    /// A reduce cancelled in Gains' callback (slippage vs the operator's expectedPrice, LIQ_REACHED, WRONG_TRADE) frees
    /// nothing, so the shortfall and the cap come back unchanged: there is no count limit. On the real diamond each such
    /// cancel realizes the min gov fee onto the trade (~0.0425 USDC on BTC / ETH, gains-diamond-research Q1 / Q5).
    function test_GOV_OB_cancelledReducesRestoreTheCapWithoutLimit() public {
        _two();
        _redeemHalf();
        uint256 s0 = fv.redemptionShortfall();
        for (uint256 i; i < 25; ++i) {
            vm.prank(keeper);
            fv.reduceTrade(a, uint120(operatorReduceCap(s0)), 0, type(uint64).max); // an expectedPrice no fill can meet
            diamond.cancelInCallback(address(fv), diamond.orderCount(address(fv)) - 1);
            assertEq(fv.redemptionShortfall(), s0, "cap restored after every cancel");
        }
    }

    // ------------------------------------------------------------------ GOV-01: fee grinding
    /// GOV-01 PoC. Gains charges a partial close its closing fee on max(delta size, pairMinPositionSizeUsd): 0.10 USD
    /// for any delta under ~286 USD of size on BTC / ETH (STAGE0 B3: 0.100014 on a 2.5 USD delta). reduceTrade has no
    /// minimum size, and the operator cap bounds each request's collateralDelta, not the fees the requests cost. With a
    /// redemption pending, a compromised operator key sends 0.11 USDC reduces: each frees ~0.01 USDC and burns ~0.10
    /// USDC of depositor value; the shortfall barely moves, so the cap never binds. Passes while the bug exists.
    function test_GOV_01_operatorGrindsCollateralIntoMinFees() public {
        // Gains-like fee schedule on ETH: 0.035% of size, min basis 285.7 USD => min closing fee 0.10 USDC
        diamond.setPair(ETH, 350_000_000, 285.7e18, 0.1e18, 0);
        _fundFv(10_000e6);
        a = _openFv(ETH, 9_000e6, 2_000);
        _redeemHalf();
        uint256 s0 = fv.redemptionShortfall();
        uint256 nav0 = fv.totalAssets();
        uint256 n = 40;
        uint64 px = _px(ETH);
        for (uint256 i; i < n; ++i) {
            vm.prank(keeper);
            fv.reduceTrade(a, 110_000, 0, px); // 0.11 USDC collateral, 0.22 USD of size
            (, uint256 paid) = _fillLast(fv, px);
            assertLt(paid, 11_000, "frees ~0.01 USDC per reduce");
        }
        uint256 burned = nav0 - fv.totalAssets();
        // ~0.10 USDC of NAV gone per reduce; the shortfall moved by ~0.01 per reduce, so the operator can go on
        assertGe(burned, n * 95_000, "NAV burned >= 0.095 USDC per reduce");
        assertGt(fv.redemptionShortfall(), s0 - n * 11_000);
        assertGt(operatorReduceCap(fv.redemptionShortfall()), 110_000, "cap never binds");
        emit log_named_uint("reduces", n);
        emit log_named_uint("NAV burned (1e-6 USDC)", burned);
        emit log_named_uint("USDC freed for redemptions (1e-6)", s0 - fv.redemptionShortfall());
    }

    /// GOV-01, agent / manager side: reduceTrade is an exit for the trader at any time and in every breach, with no
    /// shortfall needed, so a compromised agent key grinds the same way, past maxDailyLossBps (a daily-loss breach
    /// keeps the agent and allows exits) until the sentinel revokes it.
    function test_GOV_01_agentGrindsEvenInADailyLossBreach() public {
        diamond.setPair(ETH, 350_000_000, 285.7e18, 0.1e18, 0);
        _fundFv(10_000e6);
        a = _openFv(ETH, 9_000e6, 2_000);
        assertEq(fv.redemptionShortfall(), 0);
        _passHold(); // GR2-KEY-01b: the agent's first exit waits out the minimum hold (same UTC day; the breach exits are not held)
        uint64 px = _px(ETH);
        vm.prank(agentA);
        fv.reduceTrade(a, 110_000, 0, px);
        _fillLast(fv, px);
        // a daily loss breach: the agent is kept and reduce stays open to it
        diamond.setHolding(address(fv), a, int256(1_000e6));
        fv.checkRisk();
        assertTrue(fv.breached());
        assertEq(fv.agent(), agentA, "risk breach keeps the agent");
        for (uint256 i; i < 10; ++i) {
            vm.prank(agentA);
            fv.reduceTrade(a, 110_000, 0, px);
            _fillLast(fv, px);
        }
    }

    // ------------------------------------------------------------------ stale checkpoint: owed priced at the checkpoint
    /// The shortfall prices pending redemptions at checkpointNav, which only checkRisk / settle move (<= maxNavMoveBps
    /// per hour). After a 9% NAV drop with no checkRisk yet, the operator may free ~9% more than the redemptions need at
    /// the settle NAV. The surplus stays idle in the vault (no loss except the closing fee on it): Info.
    function test_GOV_OB_staleCheckpointOverstatesTheNeed() public {
        _two();
        uint256 owedCp = _redeemHalf();
        // ETH -20% on a 2x trade of 4,500: about -1,800 of NAV (-18%) ... use -10% => ~-900 (-9%)
        _setPrice(ETH, uint64(uint256(_px(ETH)) * 90 / 100));
        uint256 nav = fv.totalAssets();
        uint256 owedNav = Math.mulDiv(fv.pendingRedeemShares(), nav + 1, fv.totalSupply() + 10 ** DECIMALS_OFFSET);
        uint256 s = fv.redemptionShortfall();
        assertEq(s, owedCp - usdc.balanceOf(address(fv)), "priced at the stale checkpoint");
        uint256 over = owedCp - owedNav;
        assertGt(over, 400e6, "overstated by > 400 USDC of a ~5,000 USDC need");
        // after a checkRisk (an hour after the last checkpoint) the shortfall follows the NAV
        _skip(1 hours);
        _setPrice(ETH, _px(ETH));
        fv.checkRisk();
        assertLt(fv.redemptionShortfall(), s - 400e6);
    }

    // ------------------------------------------------------------------ claimable reserve and deferred insider deposits
    function test_GOV_OB_claimableAndDeferredAreNeutral() public {
        _two();
        _redeemHalf();
        // the manager (insider) deposits: deferred to the next epoch, never counted as available
        usdc.mint(fvManager, 2_000e6);
        vm.prank(fvManager);
        usdc.approve(address(fv), type(uint256).max);
        vm.prank(fvManager);
        fv.requestDeposit(2_000e6, fvManager);
        assertEq(fv.deferredDepositAssets(), 2_000e6);
        uint256 s = fv.redemptionShortfall();
        assertApproxEqAbs(s, 3_999.5e6, 1e6, "deferred USDC is not available for redemptions");
        // the operator frees exactly the cap; the settle pays the redemptions in full (no manager needed)
        uint64 px = _px(ETH);
        vm.prank(keeper);
        fv.reduceTrade(a, uint120(operatorReduceCap(s)), 0, px);
        _fillLast(fv, px);
        fv.checkRisk();
        vm.prank(keeper);
        fv.settle();
        assertEq(fv.pendingRedeemShares(), 0);
        // alice has not claimed: claimable is owed and held, so it never creates a shortfall
        assertGt(fv.claimableRedeemAssets(), 0);
        assertEq(fv.redemptionShortfall(), 0);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(E.ReduceAboveShortfall.selector, 0, 1));
        fv.reduceTrade(b, 1, 0, _px(BTC));
    }
}
