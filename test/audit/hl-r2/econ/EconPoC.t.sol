// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {EconBase} from "./EconBase.t.sol";
import {HloBase} from "../../hl-open/HloBase.t.sol";
import {HyperVault} from "../../../../src/HyperVault.sol";
import {HyperVaultFactory} from "../../../../src/HyperVaultFactory.sol";
import {VaultPolicy} from "../../../../src/VaultPolicy.sol";
import {BreachReason, IHyperVaultErrors as E} from "../../../../src/VaultTypes.sol";

/// @notice hl-r2 economics PoCs (domain 3.7). Every test passes while the issue it names exists.
contract HlR2EconPoC is EconBase {
    // ------------------------------------------------------------------
    // HLR2-E01: exit-only settles price redemptions at min(NAV, checkpoint) with no bound on how stale the
    // checkpoint is. The settle caller (owner / manager / operator / sentinel / guardian) picks the moment, the
    // owner can open the emergency at will, and the keeper sends no checkRisk in a full stop. A genuine gain since
    // the last checkpoint is taken from the redeemers and handed to the holders who stay.
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // HLR2-E02: settle() trusts the stored breach flag. A NAV drop past maxDailyLossBps (but within maxNavMoveBps of
    // the checkpoint) that no checkRisk has seen yet is settled in NORMAL mode: deposits are minted at the dropped
    // NAV. The redemption-only rule ("no share is ever minted at a NAV that may be deflated") only holds if a
    // checkRisk lands between the drop and the settle; the settle caller controls that ordering.
    // ------------------------------------------------------------------
    function test_HLR2_E02_settleMintsInsideDailyLossTerritory() public {
        vm.prank(owner);
        vault.lowerFees(0, 0);
        _deposit(alice, 1_000_000e6);
        _settleAs(manager);
        vault.claim(alice);
        _toCore(1_000_000e6);
        _hours(2);
        vault.checkRisk(); // cp 1M, day start 1M, default policy: daily loss 5%, nav move 20%

        vm.prank(mallory);
        vault.requestDeposit(1_000_000e6, mallory);
        _setCoreValue(850_000e6); // -15%: three times the daily loss limit, still inside the 20% band
        uint256 snap = vm.snapshotState();

        // Path A: the manager settles first, in the block that shows the drop.
        _settleAs(manager);
        assertFalse(vault.breached());
        vault.claim(mallory);
        (, uint256 dl,) = vault.checkRisk();
        assertGt(dl, 500, "the next check finds a daily loss breach the settle never saw");
        _setCoreValue(1_000_000e6); // the reading recovers (transient / deflated)
        uint256 mValue = _value(mallory);
        console2.log("E02 mallory 1M deposit worth after the recovery", mValue);
        assertGt(mValue, 1_075_000e6, "minted at 85% of the NAV");

        // Path B: a checkRisk lands first -> redemption-only, the deposit is carried, nothing minted.
        vm.revertToState(snap);
        vault.checkRisk();
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DAILY_LOSS));
        _settleAs(manager);
        assertEq(vault.balanceOf(mallory), 0);
        (,, bool carried) = _carried(mallory);
        assertTrue(carried);
    }

    function _carried(address who) internal view returns (uint256, uint256, bool) {
        (uint256 ep, uint256 dep,) = vault.requests(who);
        (uint256 cf, uint256 pi) = vault.carry(ep);
        return (ep, dep, cf != 0 && pi == 0);
    }

    // ------------------------------------------------------------------
    // HLR2-E03: M-05 residual. The performance fee crystallises at whichever moment the settle caller picks, on a
    // NAV up to maxNavMoveBps above the checkpoint. A one-block mark spike settled by the manager mints ~3.2% of the
    // vault to the fee recipient and pins the high water mark at the spike.
    // ------------------------------------------------------------------
    function test_HLR2_E03_perfFeeOnSpikeAtSettle() public {
        _deposit(alice, 1_000_000e6);
        _settleAs(manager);
        vault.claim(alice);
        _toCore(1_000_000e6);
        _hours(2);
        vault.checkRisk();
        uint256 snap = vm.snapshotState();

        _setCoreValue(1_190_000e6); // +19% mark spike for one block
        _settleAs(manager);
        _setCoreValue(1_000_000e6); // the spike is gone
        uint256 aliceA = _value(alice);
        uint256 frA = _value(feeRecipient);
        uint256 hwmA = vault.highWaterMark();

        vm.revertToState(snap);
        _hours(1);
        _settleAs(manager); // the same epoch settled an hour later at the real NAV
        uint256 aliceB = _value(alice);
        console2.log("E03 alice after spike settle", aliceA);
        console2.log("E03 alice after honest settle", aliceB);
        console2.log("E03 fee recipient (spike)", frA);
        assertGt(aliceB - aliceA, 30_000e6, "~3.2% of the vault moved to the fee recipient");
        assertGt(hwmA, 1_140_000, "HWM pinned at the spike: the next 19% of real gains carry no fee");
    }

    // ------------------------------------------------------------------
    // HLR2-E04: the documented sybil / settle-timing residual (N-09) quantified on the deposit side with an honest
    // NAV: the manager's sybil deposit is priced at the trough the manager chose (normal settle, no breach).
    // Not a new finding; recorded so the economics report has a number.
    // ------------------------------------------------------------------
    function test_HLR2_E04_sybilDepositPricedAtChosenTrough() public {
        vm.prank(owner);
        vault.lowerFees(0, 0);
        _deposit(alice, 1_000_000e6);
        _settleAs(manager);
        vault.claim(alice);
        _toCore(1_000_000e6);
        _hours(2);
        vault.checkRisk();
        vm.prank(mallory);
        vault.requestDeposit(1_000_000e6, mallory);
        // default policy: daily loss 5%. A 4.9% trough (no breach) is settled; the mark mean-reverts.
        _setCoreValue(951_000e6);
        _settleAs(manager);
        vault.claim(mallory);
        _setCoreValue(1_000_000e6); // mallory's 1M is idle on EVM: NAV 2M
        console2.log("E04 mallory worth", _value(mallory));
        assertGt(_value(mallory), 1_024_000e6);
    }
}

/// @notice HLR2-E05 (Info): a factory seed (>= 2 USDC, 1 USDC of which Core keeps) is NAV with no shares; the first
///         epoch's depositors are minted at 1 USDC per share and receive it. A launcher who seeds more gives it away.
contract HlR2SeedPoC is HloBase {
    function test_HLR2_E05_firstDepositorsReceiveTheSeed() public {
        address l = makeAddr("launcher");
        _fundLauncher(l, 1);
        usdc.mint(l, 998e6);
        HyperVaultFactory.CreateParams memory p = _params(l, bytes32(0));
        p.seedUsdc = 1_000e6;
        p.managementFeeBps = 0;
        p.performanceFeeBps = 0;
        vm.prank(l);
        usdc.approve(address(factory), type(uint256).max);
        HyperVault v = _launch(l, p);
        _setCore(address(v), 999e6, 0, 0); // the seed landed on Core, minus the 1 USDC activation fee
        vm.roll(vm.getBlockNumber() + 400);
        v.checkRisk();
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        vm.prank(alice);
        v.requestDeposit(10e6, alice);
        vm.prank(keeper);
        v.settle();
        v.claim(alice);
        uint256 worth = v.convertToAssets(v.balanceOf(alice));
        console2.log("E05 alice 10 USDC worth", worth);
        assertGt(worth, 1_000e6, "the 999 USDC seed went to the first depositor");
    }
}
