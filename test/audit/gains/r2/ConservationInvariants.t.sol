// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GainsVault} from "../../../../src/gains/GainsVault.sol";
import {MIN_HOLD, MIN_HOLD_L2_BLOCKS} from "../../../../src/gains/GainsTypes.sol";
import {LedgerUSDC, CIDiamond} from "./ConservationMocks.sol";
import {CIWorld} from "./ConservationWorld.sol";
import {CIHandler, CIValuer} from "./ConservationHandler.sol";
import {CIChecker} from "./ConservationChecker.sol";

/// @notice Round 2, domain CI: the conservation invariant (contracts/audit/gains/r2/CONSERVATION.md).
///
///  Every unit of USDC that enters or leaves the vault is booked, including collateral in flight at the diamond:
///   C1  USDC into the vault = deposits + donations (+ the seed before the ledger starts); USDC out of the vault =
///       collateral to the diamond + deliveries to the claimant / canceller of that very call; nothing else (strayOut).
///   C2  the diamond's escrow for the vault (its ledger) = the escrow recomputed from its open trades and orders; it
///       pulled exactly what the vault's own trader calls asked for; everything it paid for the vault went to the vault.
///   C3  vault USDC + escrow at the diamond == seed + deposits + donations - refunds - claims + (venue payouts - collateral
///       released), the P&L the mock decided (net of Gains' fees and kept gov fees). Exact.
///  Fairness (checked inside the handler at each settle / claim / fee mint, counters here):
///   F1  a settle never lowers the continuing holders' fair (Chainlink mid) value per share, after the fee dilution;
///   F1d deposit shares = toShares(depIn, max(advNAV, idle + favNAV)), NAVs computed independently from the mock;
///   F1r redemption payout = toAssets(shares, advNAV or min(advNAV, checkpoint)), partial fill only pro rata in emergency;
///   F2  claims: each delivery equals the entitlement; per epoch the claims stay within redeemAssets, the returned
///       shares within the unburned escrow, the deposit shares within depositShares, the refunds within depositAssets;
///   F3  fee shares are worth at most the configured fee (management pro rata time, performance on the gain above the
///       high water mark), rates within the hard caps, protocol share <= its bps, recipients only the two fee addresses;
///   R   reserves: USDC >= pending + deferred deposits + claimable; pending + deferred == the unpriced requests;
///       claimable covers every entitlement with at most the rounding dust; the share escrow covers queued and
///       unclaimed shares; depositor flows never move idle USDC, supply or the venue.
///   N1  totalAssets() == idle + the independent adverse-edge valuation; S1 no settle with collateral in flight.
///   T4  the vault's allowance to the diamond is 0 between calls.
contract ConservationInvariants is Test {
    CIWorld internal w;
    CIHandler internal h;
    CIChecker internal c;
    GainsVault internal vault;
    LedgerUSDC internal usdc;
    CIDiamond internal diamond;
    bool internal checkNav;

    function setUp() public virtual {
        w = new CIWorld();
        h = new CIHandler(w, new CIValuer());
        vault = w.vault();
        usdc = w.usdc();
        diamond = w.diamond();
        // the keeper's first check sets the checkpoint (live: the executor runs checkRisk every few minutes)
        vault.checkRisk();
        h.seed();
        c = new CIChecker(w, h);
        checkNav = !vm.envOr("CI_SKIP_NAV", false);
        targetContract(address(h));
        bytes4[] memory skip = new bytes4[](4);
        skip[0] = CIHandler.venueNow.selector;
        skip[1] = CIHandler.seed.selector;
        skip[2] = CIHandler.idleNow.selector;
        skip[3] = CIHandler.setNative.selector;
        excludeSelector(FuzzSelector({addr: address(h), selectors: skip}));
    }

    /// @dev Runs and depth come from the profile (default 256 x 500); the round 2 campaign set
    ///      FOUNDRY_INVARIANT_RUNS=2048 FOUNDRY_INVARIANT_DEPTH=500 (CONSERVATION.md).
    /// forge-config: default.invariant.fail-on-revert = false
    /// forge-config: default.invariant.show-metrics = true
    function invariant_conservation() public view {
        (bool ok, string memory why) = c.fairness();
        assertTrue(ok, why);
        (ok, why) = c.ledger();
        assertTrue(ok, why);
        (ok, why) = c.reserves();
        assertTrue(ok, why);
        if (checkNav) {
            (ok, why) = c.nav();
            assertTrue(ok, why);
        }
    }

    function afterInvariant() external {
        // Cross-run totals: with CI_STATS_FILE set (and write permission on it, a scratch copy only), one CSV line per run.
        string memory file = vm.envOr("CI_STATS_FILE", string(""));
        if (bytes(file).length > 0) {
            uint256[20] memory n = [
                h.nSettles(), h.nSettleNormal(), h.nSettleRedemptionOnly(), h.nSettleExitOnly(), h.nSettlePartial(),
                h.nSettleWithDeposits(), h.nSettleWithOpenTrades(), h.nDeposits(), h.nRedeems(), h.nCancels(), h.nClaims(),
                h.nFeeMints(), h.nOpens(), h.nFills(), h.nCallbackCancels(), h.nTimeouts(), h.nLiquidations(),
                h.nTriggers(), h.nRetypes(), h.nEmergencies()
            ];
            string memory line = vm.toString(n[0]);
            for (uint256 i = 1; i < 20; ++i) {
                line = string.concat(line, ",", vm.toString(n[i]));
            }
            vm.writeLine(file, line);
        }
        emit log_named_uint("settles", h.nSettles());
        emit log_named_uint("  normal", h.nSettleNormal());
        emit log_named_uint("  redemption-only", h.nSettleRedemptionOnly());
        emit log_named_uint("  exit-only", h.nSettleExitOnly());
        emit log_named_uint("  partial fill", h.nSettlePartial());
        emit log_named_uint("  with deposits minted", h.nSettleWithDeposits());
        emit log_named_uint("  with open trades", h.nSettleWithOpenTrades());
        emit log_named_uint("deposits", h.nDeposits());
        emit log_named_uint("redeems", h.nRedeems());
        emit log_named_uint("cancels", h.nCancels());
        emit log_named_uint("claims (deliveries)", h.nClaims());
        emit log_named_uint("claims by stranger", h.nClaimsByStranger());
        emit log_named_uint("donations", h.nDonations());
        emit log_named_uint("fee mints", h.nFeeMints());
        emit log_named_uint("opens", h.nOpens());
        emit log_named_uint("fills", h.nFills());
        emit log_named_uint("callback cancels", h.nCallbackCancels());
        emit log_named_uint("timeouts", h.nTimeouts());
        emit log_named_uint("liquidations", h.nLiquidations());
        emit log_named_uint("triggers", h.nTriggers());
        emit log_named_uint("retypes", h.nRetypes());
        emit log_named_uint("closes", h.nCloses());
        emit log_named_uint("reduces", h.nReduces());
        emit log_named_uint("emergencies", h.nEmergencies());
        emit log_named_uint("dust bound", h.dustBound());
        emit log_named_uint("settle err OrdersPending", h.settleErr(bytes4(keccak256("OrdersPending()"))));
        emit log_named_uint("settle err InsufficientLiquidity", h.settleErr(bytes4(keccak256("InsufficientLiquidity(uint256,uint256)"))));
        emit log_named_uint("settle err ReduceOnlyMode", h.settleErr(bytes4(keccak256("ReduceOnlyMode()"))));
        emit log_named_uint("settle err EpochTooYoung", h.settleErr(bytes4(keccak256("EpochTooYoung()"))));
        emit log_named_uint("settle err Unauthorized", h.settleErr(bytes4(keccak256("Unauthorized()"))));
        emit log_named_uint("settle err NavMoved", h.settleErr(bytes4(keccak256("NavMoved(uint256,uint256)"))));
    }
}

/// @notice Every handler action once, so a broken action shows up as a failing unit test rather than a silent no-op.
contract ConservationHandlerSanity is Test {
    function test_CI_handlerDrivesEveryAction() public {
        CIWorld w = new CIWorld();
        CIHandler h = new CIHandler(w, new CIValuer());
        GainsVault vault = w.vault();
        vault.checkRisk();
        h.deposit(0, 1, 100_000e6);
        h.deposit(1, 1, 50_000e6);
        h.deposit(3, 1, 20_000e6);
        h.deposit(4, 1, 10_000e6); // manager: deferred
        h.settle(0, 1 << 8 | 2);
        assertEq(h.nSettles(), 1, "first settle");
        h.claim(0, false);
        h.claim(1, true);
        h.openTrade(false, false, true, 30, 3_000, 0, 4); // filled
        h.openTrade(true, true, false, 20, 2_000, 0, 0); // pending
        h.openTrade(false, false, true, 5, 2_000, 1, 0); // limit
        h.gRetype(0, 0);
        h.gRestore(0);
        h.gFill(0, 50);
        h.gFillAll();
        h.increaseTrade(false, 0, 5, 1_000, false);
        h.gFillAll();
        h.updateLeverage(false, 0, 2_000);
        h.gFillAll();
        h.move(false, 200);
        h.redeem(0, 30);
        h.deposit(2, 1, 30_000e6);
        h.settle(1, 1 << 8 | 2);
        h.claim(0, false);
        h.claim(2, false);
        h.close(0, 0, true, 30);
        h.gFillAll();
        h.gTrigger(0, 0, true);
        h.gFill(0, 1);
        h.gHolding(0, 1e6);
        h.gFees(false, 5e8, 1e7, 90_000);
        h.accrue(6 hours, true);
        h.feeGov(300, 2_500, 0);
        h.feeGov(100, 1_000, 1);
        h.donate(1_000e6);
        h.cancelTimedOut(0, true);
        h.flatten(false, 0, false);
        h.gFillAll();
        h.crash(0);
        h.check(true);
        h.redeem(1, 100);
        h.settle(0, 2);
        h.claim(1, false);
        h.govern(1);
        h.settle(2, 2);
        assertGt(h.nSettles(), 2, "settles happen");
        assertGt(h.nClaims(), 2, "claims happen");
        assertGt(h.nFeeMints(), 0, "fees accrue");
        assertEq(h.vF1HolderDiluted() + h.vF1dDepositPrice() + h.vF1rRedeemPrice() + h.vFeeAboveCap(), 0, "fairness");
        assertEq(h.vClaimOver() + h.vClaimShortWei() + h.vEpochOverpaid() + h.vFlowMovedHolders() + h.vCollateral(), 0, "flows");
    }
}

/// @notice Deterministic scenarios of the conservation properties. The first two are the sensitivity checks of
///         CONSERVATION.md: they pass on the fixed code and fail with GR1-02 (resp. GV-02) undone. The third is the
///         PoC of GR2-CI-01 (Info).
contract ConservationScenarios is Test {
    CIWorld internal w;
    CIHandler internal h;
    GainsVault internal vault;
    CIDiamond internal diamond;

    function setUp() public {
        w = new CIWorld();
        h = new CIHandler(w, new CIValuer());
        vault = w.vault();
        diamond = w.diamond();
        vault.checkRisk();
        h.seed(); // 700k in, ETH long 80k x 3, BTC short 100k x 2 open
    }

    function _midPricePerShare() internal view returns (uint256) {
        return ((h.idleNow() + h.venueNow().mid + 1) * 1e12) / (vault.totalSupply() + 1e6);
    }

    function _assertFair(string memory what) internal view {
        assertEq(h.vF1HolderDiluted(), 0, string.concat(what, ": F1 holders diluted"));
        assertEq(h.vF1dDepositPrice(), 0, string.concat(what, ": F1d deposit price"));
        assertEq(h.vF1rRedeemPrice(), 0, string.concat(what, ": F1r redemption price"));
        assertEq(h.vS1HeldInFlight(), 0, string.concat(what, ": S1 collateral in flight priced"));
    }

    /// @dev GR1-02 sensitivity: a confederate deposits 300k while 440k of notional is open; the settle must mint at
    ///      the favourable edge, so the holders' mid value per share does not fall.
    function test_CI_sensitivity_GR102_depositWhileTradesOpen() public {
        uint256 p0 = _midPricePerShare();
        h.deposit(3, 1, 300_000e6); // the confederate (not an insider: priced this epoch)
        h.settle(0, 2); // manager, oracle answered first, epoch aged an hour
        assertEq(h.nSettles(), 2, "settled");
        uint256 p1 = _midPricePerShare();
        emit log_named_uint("holders' mid value per share before", p0);
        emit log_named_uint("holders' mid value per share after", p1);
        _assertFair("GR1-02");
        assertGe(p1 + 1, p0, "the holders' mid value per share did not fall");
    }

    /// @dev GV-02 sensitivity: a leverage decrease holding 80k is reported under unknown type 10. A settle with a
    ///      300k deposit and a 30% redemption queued must not run while that collateral is in flight.
    function test_CI_sensitivity_GV02_unknownTypeHoldsSettle() public {
        h.updateLeverage(false, 0, 1_500); // ETH long 3x -> 1.5x pulls 80k into a pending order
        uint32 o = diamond.orderCount(address(vault)) - 1;
        assertEq(diamond.heldBy(address(vault), o), 80_000e6, "holds 80k");
        diamond.retype(address(vault), o, 10);
        h.deposit(2, 1, 300_000e6);
        h.redeem(0, 30);
        uint256 p0 = _midPricePerShare();
        h.settle(0, 8); // manager, no fill first
        emit log_named_uint("holders' mid value per share before", p0);
        emit log_named_uint("holders' mid value per share after", _midPricePerShare());
        (, uint256 dShares,, uint256 paid,,,,) = vault.epochs(1);
        emit log_named_uint("deposit shares minted for 300k (if settled)", dShares);
        emit log_named_uint("redemption paid (if settled)", paid);
        emit log_named_uint("settles (1 = only the seed's)", h.nSettles());
        _assertFair("GV-02");
        assertEq(h.nSettles(), 1, "settle waits for the unknown order");
    }

    /// @dev GR2-CI-01 (Info): an order that holds NOTHING (a partial close) reported under an unknown type is counted at
    ///      its collateral field: NAV is overstated by that field (minus the gov fee) while the trade is still valued in
    ///      full. Settle is blocked (fail closed), but accrueFees, checkRisk and the deposit cap read the inflated NAV.
    function test_GR2_CI_01_unknownTypeOnNonHoldingOrderOverstatesNav() public {
        // fix round WP2: the manager's reduces come after the GR2-KEY-01b minimum hold (time and L2 blocks)
        h.wait(MIN_HOLD);
        vm.roll(vm.getBlockNumber() + MIN_HOLD_L2_BLOCKS);
        uint256 trueNav = h.idleNow() + h.venueNow().adv;
        assertEq(vault.totalAssets(), trueNav, "NAV exact before");
        uint64 px = h.ethPx();
        vm.prank(w.MANAGER());
        vault.reduceTrade(0, 40_000e6, 0, px); // partial close request: holds no collateral
        uint32 o = diamond.orderCount(address(vault)) - 1;
        assertEq(diamond.heldBy(address(vault), o), 0, "a partial close holds nothing");
        assertEq(vault.totalAssets(), trueNav, "known type: NAV unchanged");
        diamond.retype(address(vault), o, 10);
        uint256 navUnknown = vault.totalAssets();
        uint256 over = navUnknown - trueNav;
        emit log_named_uint("true NAV", trueNav);
        emit log_named_uint("NAV with the order reported as type 10", navUnknown);
        emit log_named_uint("overstatement", over);
        assertEq(over, 40_000e6 - diamond.minGovFee(1), "overstated by the order's collateral field minus the gov fee");
        // settle is held (fail closed)...
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        h.wait(1); // refresh feeds
        vm.prank(w.MANAGER());
        vm.expectRevert(bytes4(keccak256("OrdersPending()")));
        vault.settle();
        // ...but the management fee accrues on the inflated NAV
        h.wait(2 hours);
        uint256 s0 = vault.totalSupply();
        uint256 dt = vm.getBlockTimestamp() - vault.lastFeeAccrual();
        uint256 navIn = vault.totalAssets();
        uint256 navTrue = h.idleNow() + h.venueNow().adv;
        vault.accrueFees();
        uint256 minted = vault.totalSupply() - s0;
        uint256 feeIn = Math.mulDiv(navIn, 200 * dt, 10_000 * 365 days);
        uint256 feeTrue = Math.mulDiv(navTrue, 200 * dt, 10_000 * 365 days);
        assertEq(minted, Math.mulDiv(feeIn, s0 + 1e6, navIn - feeIn), "fee minted on the inflated NAV");
        emit log_named_uint("seconds accrued", dt);
        emit log_named_uint("fee (USDC) charged on the inflated NAV", feeIn);
        emit log_named_uint("fee (USDC) on the true NAV", feeTrue);
        assertGt(feeIn, feeTrue, "overcharged");
    }
}
