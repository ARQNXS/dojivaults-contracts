// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GainsBase} from "./GainsBase.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GainsVault} from "../../src/gains/GainsVault.sol";
import {GainsVaultFactory} from "../../src/gains/GainsVaultFactory.sol";
import {GainsVaultPolicy} from "../../src/gains/GainsVaultPolicy.sol";
import {IGainsVaultErrors as E, IGainsVaultEvents} from "../../src/gains/GainsTypes.sol";
import {MockUSDC} from "../mocks/Mocks.sol";

/// @notice Owner and platform administration on the Gains contracts: the timelocked setters, the scheduled
///         performance fee raise (N2-02), rescueToken, the factory owner surface, policy config cancellation and the
///         lens emergency previews. Same behavior as round 4; these paths were not reached by the mirrored suites.
contract GainsAdminTest is GainsBase {
    function test_TimelockedSettersAndTheScheduledFeeRaise() public {
        _deposit(alice, 1_000e6);
        _settle();
        // Raising the performance fee is scheduled: the running epoch is charged at the old rate first (N2-02).
        bytes memory fees = abi.encodeCall(GainsVault.setFees, (uint16(200), uint16(2_500)));
        vm.prank(owner);
        bytes32 id = vault.queue(fees);
        assertGt(vault.queuedEta(id), 0);
        assertEq(vault.queuedAt(id), vm.getBlockTimestamp());
        _warp(vault.queuedEta(keccak256(fees))); // hl-r2 exit-before-effect: wait for the stored eta
        vault.execute(fees);
        assertEq(vault.performanceFeeBps(), 2_000, "unchanged until the next settle");
        assertEq(vault.pendingPerformanceFeeBps(), 2_500);
        _settle();
        assertEq(vault.performanceFeeBps(), 2_500);
        assertEq(vault.pendingPerformanceFeeBps(), 0);

        address r2 = makeAddr("recipient2");
        _timelocked(vault, abi.encodeCall(GainsVault.setFeeRecipient, (r2)));
        assertEq(vault.feeRecipient(), r2);
        _timelocked(vault, abi.encodeCall(GainsVault.setTimelockDelay, (3 days)));
        assertEq(vault.timelockDelay(), 3 days);
        bytes memory bad = abi.encodeCall(GainsVault.setTimelockDelay, (31 days));
        vm.prank(owner);
        vault.queue(bad);
        _warp(vault.queuedEta(keccak256(bad))); // hl-r2 exit-before-effect: wait for the stored eta
        vm.expectRevert(abi.encodeWithSelector(E.CallFailed.selector, abi.encodeWithSelector(E.InvalidTimelock.selector)));
        vault.execute(bad);
        // only through the queue
        vm.prank(owner);
        vm.expectRevert(E.Unauthorized.selector);
        vault.setFees(0, 0);
    }

    function test_RescueTokenNeverTouchesTheAssetOrTheShares() public {
        MockUSDC other = new MockUSDC();
        other.mint(address(vault), 5e6);
        vm.prank(stranger);
        vm.expectRevert();
        vault.rescueToken(IERC20(address(other)), stranger);
        vm.prank(owner);
        vault.rescueToken(IERC20(address(other)), owner);
        assertEq(other.balanceOf(owner), 5e6);
        vm.prank(owner);
        vm.expectRevert(E.UnsupportedAsset.selector);
        vault.rescueToken(IERC20(address(usdc)), owner);
        vm.prank(owner);
        vm.expectRevert(E.UnsupportedAsset.selector);
        vault.rescueToken(IERC20(address(vault)), owner);
    }

    function test_SwitchesAndStateGetters() public {
        assertFalse(vault.depositsPaused());
        assertFalse(vault.tradingPaused());
        vm.prank(guardian);
        vault.setDepositsPaused(true);
        vm.prank(guardian);
        vault.setTradingPaused(true);
        assertTrue(vault.depositsPaused());
        assertTrue(vault.tradingPaused());
        assertEq(vault.riskDay(), START / 1 days);
        assertEq(vault.INSIDER_MIN_EPOCH_AGE(), 1 hours);
        assertEq(vault.feeRecipient(), feeRecipient);
        assertEq(vault.emergencyAt(), 0);
        vm.prank(guardian);
        vault.triggerEmergency();
        assertEq(vault.emergencyAt(), vm.getBlockTimestamp());
    }

    function test_FactoryOwnerSurface() public {
        vm.startPrank(platformOwner);
        platform.setMinSeedUsdc(5e6);
        platform.setMinAgentGas(0.01 ether);
        vm.expectRevert(GainsVaultFactory.RolesCollide.selector);
        platform.transferOwnership(platformSentinel); // a hot role can never own the factory
        vm.expectRevert(GainsVaultFactory.RolesCollide.selector);
        platform.renounceOwnership();
        platform.transferOwnership(platformGuardian); // owner == guardian is allowed (one cold multisig)
        vm.stopPrank();
        assertEq(platform.minSeedUsdc(), 5e6);
        assertEq(platform.minAgentGas(), 0.01 ether);
        assertEq(platform.pendingOwner(), platformGuardian);
        vm.prank(platformGuardian);
        platform.acceptOwnership();
        assertEq(platform.owner(), platformGuardian);
        assertEq(platform.vaults().length, 0, "the standalone vault was not created by the factory");
        vm.prank(stranger);
        vm.expectRevert();
        platform.setMinSeedUsdc(0);
    }

    function test_PolicyCancelPendingConfigAndViews() public {
        GainsVaultPolicy.RiskConfig memory c = _defaultRisk();
        assertEq(policy.maxDailyLossBps(), c.maxDailyLossBps);
        assertEq(policy.maxDrawdownBps(), c.maxDrawdownBps);
        assertEq(policy.maxSlippageBps(), c.maxSlippageBps);
        assertEq(policy.maxOrderNotional(), c.maxOrderNotional);
        c.maxLeverageBps = 40_000;
        vm.prank(owner);
        policy.proposeConfig(c);
        assertTrue(policy.pendingConfig().exists);
        vm.prank(stranger);
        vm.expectRevert();
        policy.cancelPendingConfig();
        vm.prank(owner);
        policy.cancelPendingConfig();
        assertFalse(policy.pendingConfig().exists);
        vm.prank(owner);
        vm.expectRevert(GainsVaultPolicy.NothingPending.selector);
        policy.cancelPendingConfig();
    }

    function test_LensEmergencyPreviewsAndOrderViews() public {
        uint32 idx = _fundVenue(10_000e6);
        assertFalse(lens.epochOverdue(vault));
        assertFalse(lens.ordersPending(vault));
        assertEq(lens.emergencyFillBps(vault), 10_000, "nothing queued: paid in full");
        _redeem(alice, vault.balanceOf(alice) / 2);
        assertEq(lens.emergencyFillBps(vault), 0, "everything is on the venue: nothing idle to pay with");
        (uint256 paid, uint256 back) = lens.previewEmergencyRedeem(vault, 1e12);
        assertEq(paid, 0);
        assertEq(back, 1e12);
        _passHold(); // GR2-KEY-01b: the manager's exit waits out the minimum hold
        vm.prank(manager);
        vault.reduceTrade(idx, 5_000e6, 0, _px(ETH));
        assertFalse(lens.ordersPending(vault), "GR1-04: a pending partial close holds no collateral, settle need not wait");
        assertEq(lens.openPositions(vault), 2, "the trade and its pending reduce");
        _fillLast(vault, _px(ETH));
        assertGe(lens.emergencyFillBps(vault), 9_990);
        assertGt(lens.previewWithdraw(vault, 1e6), 0);
        _skip(7 days);
        assertTrue(lens.epochOverdue(vault));
    }
}
