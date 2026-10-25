// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {HloBase} from "./HloBase.t.sol";
import {HyperVault} from "../../../src/HyperVault.sol";
import {HyperVaultFactory} from "../../../src/HyperVaultFactory.sol";
import {IHyperVaultErrors as E} from "../../../src/VaultTypes.sol";

/// @notice hl-open, high caps: precision, overflow, fees, bridges and big exits on an uncapped factory vault.
///         Run: forge test --match-path "test/audit/hl-open/HloScale.t.sol" -vv
contract HloScaleTest is HloBase {
    HyperVault internal v;
    address internal whale = makeAddr("whale");
    address internal mgr = makeAddr("hlo.manager");

    function setUp() public override {
        super.setUp();
        _fundLauncher(mgr, 1);
        HyperVaultFactory.CreateParams memory p = _params(mgr, bytes32(0));
        p.managementFeeBps = 500;
        p.performanceFeeBps = 3_000;
        v = _launch(mgr, p);
        vm.roll(vm.getBlockNumber() + 400); // past the seed bridge window
        address[3] memory who = [alice, bob, whale];
        for (uint256 i; i < 3; ++i) {
            vm.prank(who[i]);
            usdc.approve(address(v), type(uint256).max);
        }
    }

    function _dep(address who, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.prank(who);
        v.requestDeposit(amt, who);
    }

    function _settleNow() internal {
        v.checkRisk();
        vm.prank(keeper);
        v.settle();
    }

    /// @dev NAV moves by minting / burning idle USDC (no bridge window). Checkpoint ratchets after an interval.
    function _pnl(int256 bps) internal {
        uint256 nav = v.totalAssets();
        uint256 d = (nav * uint256(bps < 0 ? -bps : bps)) / 10_000;
        if (bps > 0) usdc.mint(address(v), d);
        else usdc.burnFrom(address(v), d);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        v.checkRisk();
    }

    // ------------------------------------------------------------------
    // HLO-05: the uncapped math. A 1e12 USDC whale next to a 10 USDC depositor, a year of fees, full exits.
    // ------------------------------------------------------------------
    function test_HLO05_trillionUsdcWhaleAndTenUsdcDepositor() public {
        _dep(whale, 1e12 * 1e6); // 1 trillion USDC
        _dep(alice, 10e6);
        _settleNow();
        v.claim(alice);
        v.claim(whale);
        uint256 aliceValue = v.convertToAssets(v.balanceOf(alice));
        console2.log("HLO-05 alice 10 USDC worth after settle next to 1e12 (6 dp)", aliceValue);
        assertApproxEqAbs(aliceValue, 10e6, 2, "no precision loss for the small depositor");

        // +10% over a year, then the settle charges 5% management + 30% performance.
        _pnl(1_000);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        v.checkRisk();
        vm.prank(keeper);
        v.settle();
        uint256 feeValue = v.convertToAssets(v.balanceOf(mgr)) + v.convertToAssets(v.balanceOf(treasury));
        uint256 nav = v.totalAssets();
        console2.log("HLO-05 fee value (6 dp)", feeValue);
        console2.log("HLO-05 NAV after (6 dp)", nav);
        // 5% of the NAV for the year plus 30% of the 10% gain, within 0.5% of that (rounding of the two-step mint)
        uint256 expected = (nav * 500) / 10_000 + ((nav * 1_000) / 11_000) * 3_000 / 10_000;
        assertApproxEqRel(feeValue, expected, 0.05e18);

        // Everyone exits in full; claims never exceed the reserve.
        uint256 aShares = v.balanceOf(alice);
        uint256 wShares = v.balanceOf(whale);
        vm.prank(alice);
        v.requestRedeem(aShares, alice, alice);
        vm.prank(whale);
        v.requestRedeem(wShares, whale, whale);
        _settleNow();
        uint256 reserve = v.claimableRedeemAssets();
        v.claim(alice);
        v.claim(whale);
        assertLe(usdc.balanceOf(alice) + usdc.balanceOf(whale), reserve + 2e12 * 1e6);
        assertGe(usdc.balanceOf(address(v)), v.claimableRedeemAssets() + v.pendingDepositAssets());
        console2.log("HLO-05 alice paid (6 dp)", usdc.balanceOf(alice));
    }

    /// @dev Fuzz: at any NAV up to the HyperCore int64 limit (9.2e12 USDC), a settle mints and burns at the share
    ///      price (rounding only) and a small depositor's round trip loses at most 2 units.
    function testFuzz_HLO05_settleIsPriceNeutralAtAnySize(uint256 base, uint256 small, int256 pnlBps, uint256 redPct) public {
        base = bound(base, 10e6, 9e18);
        small = bound(small, 10e6, 1e15);
        pnlBps = bound(pnlBps, -400, 1_500);
        redPct = bound(redPct, 0, 100);
        vm.prank(mgr);
        v.lowerFees(0, 0); // fees are tested separately: here only rounding may move the price
        _dep(whale, base);
        _settleNow();
        v.claim(whale);
        if (pnlBps != 0) _pnl(pnlBps);

        uint256 p0 = v.sharePrice();
        _dep(alice, small);
        uint256 red = (v.balanceOf(whale) * redPct) / 100;
        if (red > 0) {
            vm.prank(whale);
            v.requestRedeem(red, whale, whale);
        }
        vm.prank(keeper);
        v.settle();
        uint256 p1 = v.sharePrice();
        assertApproxEqAbs(p1, p0, 2 + p0 / 1e9, "settle moved the share price beyond rounding");

        v.claim(alice);
        uint256 val = v.convertToAssets(v.balanceOf(alice));
        assertLe(val, small);
        assertGe(val + 2 + small / 1e9, small, "small depositor lost more than rounding");
        assertGe(usdc.balanceOf(address(v)), v.claimableRedeemAssets() + v.pendingDepositAssets() + v.deferredDepositAssets());
    }

    /// @dev The NAV readers' own ceilings: perp accountValue is int64 (9.22e12 USDC), spot USDC uint64 at 8 dp
    ///      (1.84e11 USDC). bridgeToEvm casts amount * 100 to uint64: above 184,467,440,737 USDC it reverts.
    function test_HLO05_hyperCoreRepresentationLimits() public {
        _dep(whale, 5e18);
        _settleNow();
        // everything on Core perp, at the int64 ceiling
        usdc.burnFrom(address(v), 5e18);
        _setCore(address(v), type(int64).max, 0, 0);
        _setWithdrawable(address(v), type(uint64).max);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        // a 84% NAV jump is refused by the checkpoint rule, not by an overflow
        (uint256 lev,,) = v.checkRisk();
        assertEq(lev, 0);
        assertGt(v.totalAssets(), 9e18);

        uint256 tooBig = uint256(type(uint64).max) / 100 + 1;
        vm.prank(mgr);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 64, tooBig * 100));
        v.bridgeToEvm(tooBig);
        vm.prank(mgr);
        v.bridgeToEvm(tooBig - 1); // the largest single bridge home
        console2.log("HLO-05 largest single bridgeToEvm (USDC)", (tooBig - 1) / 1e6);
    }

    // ------------------------------------------------------------------
    // HLO-06: a big holder's exit. A normal settle pays every redemption in full or reverts, for everybody's
    // requests at once; once the epoch is overdue anyone forces the emergency, which revokes the agent.
    // ------------------------------------------------------------------
    function test_HLO06_whaleExitBlocksTheEpochThenAnyoneStopsTheVault() public {
        _dep(alice, 1_000_000e6);
        _dep(whale, 99_000_000e6);
        _settleNow();
        v.claim(alice);
        v.claim(whale);
        // 95% deployed on Core (SOL at 2.5x, under the 3x policy): 5M idle
        usdc.burnFrom(address(v), 95_000_000e6);
        _setCore(address(v), 95_000_002e6, 237_500_000e6, 0);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        v.checkRisk();

        uint256 wAll = v.balanceOf(whale);
        vm.prank(whale);
        v.requestRedeem(wAll, whale, whale);
        _dep(bob, 10_000e6); // bob's deposit is in the same epoch

        vm.prank(keeper);
        vm.expectRevert(); // InsufficientLiquidity(5M + 10k, ~99M): nobody's request settles
        v.settle();

        // The policy's maxEpochDuration (7 days by default; 1 hour is allowed) passes before the unwind is done.
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(stranger);
        v.triggerEmergency();
        assertTrue(v.emergency());
        assertEq(v.agent(), address(0), "agent revoked: every open position now waits for the platform unwind");
        // bob's deposit is refunded, not minted; the whale is filled pro rata to the 5M on hand
        vm.prank(keeper);
        v.settle();
        (,, uint256 rs, uint256 ra, uint256 rb,,,) = v.epochs(v.currentEpoch() - 1);
        console2.log("HLO-06 emergency fill bps", (ra * 10_000) / 99_000_000e6);
        assertLt(rb, rs, "partial fill");
    }

    // ------------------------------------------------------------------
    // Re-tests of past items on the live configuration
    // ------------------------------------------------------------------
    /// @dev I3-02 (Info, "cancellable"): an insider deposit for a victim controller blocks the victim's redemption
    ///      until the next settle. On HyperVault the victim's cancel refunds the USDC but does NOT lift the block
    ///      (the request keeps epoch + 1), as HL-RETEST found for Gains. Every launcher is now such an insider.
    function test_HLO_I302_cancelDoesNotLiftTheInsiderRedeemBlock() public {
        _dep(alice, 1_000e6);
        _settleNow();
        v.claim(alice);
        usdc.mint(mgr, 10e6);
        vm.prank(mgr);
        usdc.approve(address(v), type(uint256).max);
        vm.prank(mgr);
        v.requestDeposit(10e6, alice); // the manager deposits FOR alice: insider, next epoch
        uint256 shares = v.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(E.RequestPending.selector);
        v.requestRedeem(shares, alice, alice);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        v.cancelDepositRequest(); // alice gets the manager's 10 USDC
        assertEq(usdc.balanceOf(alice) - before, 10e6);
        vm.prank(alice);
        vm.expectRevert(E.RequestPending.selector); // still blocked
        v.requestRedeem(shares, alice, alice);
        // until a settle moves the epoch on (the manager decides when, unless the keeper is the operator)
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _settleNow();
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
    }

    /// @dev HL-RETEST B-19 on HyperVault: a factory maxDepositCap of 0 freezes every vault's setDepositCap.
    function test_HLO_maxDepositCapZeroFreezesEveryOwnersCapSetter() public {
        vm.prank(owner);
        factory.setMaxDepositCap(0);
        vm.prank(mgr);
        vm.expectRevert(E.CapExceeded.selector);
        v.setDepositCap(1_000e6);
    }

    /// @dev N-13 under the lifted cap: a vault launched while the factory is uncapped keeps an uncapped vault cap
    ///      after the platform lowers its maximum; deposits continue. Only its owner can lower it.
    function test_HLO_N13_liftedCapIsNotRecalledByLoweringTheMaximum() public {
        vm.prank(owner);
        factory.setMaxDepositCap(50_000e6);
        assertEq(v.depositCap(), type(uint256).max);
        _dep(whale, 10_000_000e6);
        assertEq(v.pendingDepositAssets(), 10_000_000e6);
    }
}
