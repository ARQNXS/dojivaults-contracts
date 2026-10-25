// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AuditBase} from "../AuditBase.t.sol";
import {HyperVault} from "../../../src/HyperVault.sol";
import {IHyperVaultErrors, IHyperVaultEvents, VaultStorage} from "../../../src/VaultTypes.sol";
import {VaultLogic} from "../../../src/VaultLogic.sol";
import {VaultGovernance} from "../../../src/VaultGovernance.sol";
import {VaultPolicy} from "../../../src/VaultPolicy.sol";
import {HyperVaultFactory} from "../../../src/HyperVaultFactory.sol";
import {HyperCore} from "../../../src/hypercore/HyperCore.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICoreDepositWallet} from "../../../src/hypercore/HyperCore.sol";

/// @notice Third audit pass (diff e68666c..a75d935), inverted after the round 3 fixes: every test_REAUDIT2_N2* PoC
///         now asserts the fix (claims are O(1), fee raises start next epoch, flatten slippage is capped at 3%,
///         one agent per predicted vault), test_REAUDIT2_I2* cover the informational fixes, test_REAUDIT2_INFO_*
///         document behaviour that stays by design and test_REAUDIT2_OK_* verify the architecture.
///         Run: forge test --match-path test/audit/reaudit2/Reaudit2PoC.t.sol -vv
contract Reaudit2PoC is AuditBase {
    int64 internal perp;
    uint64 internal spot;

    function _core(HyperVault v) internal {
        _setCore(address(v), perp, 0, spot);
        _setWithdrawable(address(v), perp > 0 ? uint64(perp) : 0);
    }

    function _roll(uint256 n) internal {
        vm.roll(vm.getBlockNumber() + n);
    }

    /// @dev One emergency "mini epoch": 100 USDC come home, the window closes, anyone settles pro rata.
    function _miniEpoch(HyperVault v) internal {
        spot = 100e6;
        _core(v);
        vm.prank(sentinel);
        v.bridgeToEvm(100e6);
        usdc.mint(address(v), 100e6);
        spot = 0;
        _core(v);
        _roll(11);
        vm.prank(sentinel);
        v.settle();
    }

    function _claimGas(HyperVault v, address who) internal returns (uint256 g) {
        uint256 snap = vm.snapshotState();
        g = gasleft();
        v.claim(who);
        g -= gasleft();
        vm.revertToState(snap);
    }

    // ==================================================================
    // N2-01 (Medium, fixed)  Claims and cancels cost the same whatever the number of epochs: a request belongs to one
    //                        epoch and an emergency settle is a partial fill plus return (audit V-01), so there is no
    //                        cross epoch state at all.
    // ==================================================================
    // HL-PROXY: every settle now also pins the account mode (one more mock CoreWriter write each), so 1,000 emergency
    // settles exceed the default test gas. The settles are setup: gas metering is paused around them only; the claim
    // gas this test measures is metered as before.
    function test_REAUDIT2_N201_claimGasIsConstantAcross1000EmergencyEpochs() public {
        (HyperVault v,) = _malloryVault();
        _fundAndDeploy(v, mallory, 1_000_000e6, 0);
        perp = 1_000_000e6;
        _core(v);
        uint256 a = v.balanceOf(alice);
        vm.prank(alice);
        v.requestRedeem(a, alice, alice);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        v.checkRisk();
        vm.prank(stranger);
        v.triggerEmergency();

        uint256 g50;
        uint256 g1000;
        for (uint256 i = 1; i <= 1_000; ++i) {
            vm.pauseGasMetering();
            _miniEpoch(v);
            vm.resumeGasMetering();
            if (i == 50) g50 = _claimGas(v, alice);
            if (i == 1_000) g1000 = _claimGas(v, alice);
        }
        emit log_named_uint("claim gas after 50 mini epochs  ", g50);
        emit log_named_uint("claim gas after 1000 mini epochs", g1000);
        assertLt(g1000, 200_000, "claim gas is bounded");
        assertLe(g1000, g50 + 5_000, "claim gas does not grow with the number of epochs");
        // Her request was filled in its own epoch (the first 100 USDC) and the rest of her shares came back.
        (uint256 quotedShares, uint256 quoted) = lens.claimable(v, alice);
        uint256 before = usdc.balanceOf(alice);
        v.claim(alice);
        assertEq(usdc.balanceOf(alice) - before, quoted, "lens == claim");
        assertApproxEqAbs(quoted, 100e6, 2, "the first mini epoch paid her 100 USDC");
        assertEq(v.balanceOf(alice), quotedShares, "the unpaid shares came back");
        assertGt(quotedShares, (a * 999) / 1_000);
        assertEq(v.pendingRedeemShares(), 0, "nothing rolls over");
        // Re-requesting the remainder is one transaction per epoch and costs the same every time.
        uint256 gFirst;
        uint256 gLast;
        for (uint256 i; i < 20; ++i) {
            (uint256 back,) = lens.claimable(v, alice);
            uint256 remaining = v.balanceOf(alice) + back; // returned shares are claimed inside requestRedeem
            uint256 g = gasleft();
            vm.prank(alice);
            v.requestRedeem(remaining, alice, alice); // claims the previous epoch first
            g -= gasleft();
            if (i == 2) gFirst = g; // i == 0 and 1 still write fresh storage slots
            if (i == 19) gLast = g;
            _miniEpoch(v);
        }
        assertLe(gLast, gFirst + 5_000, "re-request cost is flat");
        v.claim(alice);
        // 100 from her first epoch, the 99,900 that piled up idle while nothing was pending (paid by her first
        // re-request), then 100 per re-requested epoch.
        assertApproxEqAbs(usdc.balanceOf(alice) - before, 1_020 * 100e6, 1e6, "every USDC that came home reached her");
    }

    /// @dev Accounting check for the same flow with two redeemers: the sum of what everybody is paid never exceeds
    ///      the epoch's liquidity, every unpaid share comes back, and the remainder settles fully when re-requested.
    function test_REAUDIT2_OK_proRataPayoutsNeverExceedLiquidity() public {
        (HyperVault v,) = _malloryVault();
        vm.prank(bob);
        v.requestDeposit(300_000e6, bob);
        _fundAndDeploy(v, mallory, 1_000_000e6, 0); // alice 1M + bob 300k settled together, 1M bridged
        v.claim(bob);
        perp = 1_000_000e6;
        _core(v);
        uint256 a = v.balanceOf(alice);
        vm.prank(alice);
        v.requestRedeem(a, alice, alice);
        uint256 half = v.balanceOf(bob) / 2;
        vm.prank(bob);
        v.requestRedeem(half, bob, bob); // bob redeems half, keeps half
        vm.warp(vm.getBlockTimestamp() + 7 days);
        v.checkRisk();
        vm.prank(stranger);
        v.triggerEmergency();
        // Liquidity available to redeemers = the 300k that never left the EVM side + 100 USDC from the mini epoch.
        uint256 idle = usdc.balanceOf(address(v)) - v.pendingDepositAssets() - v.claimableRedeemAssets();
        assertEq(idle, 300_000e6);
        assertApproxEqAbs(lens.emergencyFillBps(v), (uint256(300_000e6) * 10_000) / uint256(1_150_000e6), 5, "fill preview before the bridge");
        _miniEpoch(v);
        uint256 paidTotal = 300_100e6;
        (uint256 aShares, uint256 aAssets) = lens.claimable(v, alice);
        (uint256 bShares, uint256 bAssets) = lens.claimable(v, bob);
        (,, uint256 R, uint256 paid, uint256 burned,,,) = v.epochs(1);
        assertEq(R, a + half);
        assertEq(paid, paidTotal, "whatever was on hand was paid");
        assertLe(aAssets + bAssets, paid, "payouts <= liquidity");
        assertGe(aAssets + bAssets + 2, paid, "nothing left unassigned beyond rounding");
        assertLe(aShares + bShares, R - burned, "returned <= not burned");
        assertGe(aShares + bShares + 2, R - burned, "the vault keeps dust only");
        assertEq(v.pendingRedeemShares(), 0);
        // Pro rata: alice holds 1M / 1.15M of the request.
        assertApproxEqRel(aAssets, (paidTotal * 1_000_000) / 1_150_000, 1e12);
        assertApproxEqRel(bAssets, (paidTotal * 150_000) / 1_150_000, 1e12);
        v.claim(alice);
        v.claim(bob);
        assertEq(v.balanceOf(alice), aShares);
        assertLe(v.balanceOf(address(v)), 2, "no orphan shares beyond dust");
        // The rest of the bridged 1M comes home: re-requested remainders settle in full, in the usual way.
        vm.prank(alice);
        v.requestRedeem(aShares, alice, alice);
        vm.prank(bob);
        v.requestRedeem(bShares, bob, bob);
        spot = 0;
        perp = 0;
        usdc.mint(address(v), 1_000_000e6 - 100e6);
        _core(v);
        _setWithdrawable(address(v), 0);
        _roll(11);
        vm.prank(sentinel);
        v.settle();
        assertEq(lens.emergencyFillBps(v), 10_000);
        v.claim(alice);
        v.claim(bob);
        assertEq(v.pendingRedeemShares(), 0);
        assertEq(v.balanceOf(alice), 0);
        assertApproxEqRel(usdc.balanceOf(alice), 1_000_000e6, 2e15, "alice fully paid, minus fees");
        assertApproxEqRel(v.balanceOf(bob), half, 1e12, "bob keeps the half he never redeemed");
    }

    /// @dev Many redeemers with odd sizes and a tiny fill: every rounding step favours the vault, each redeemer gets
    ///      value >= what they submitted (at the settle price) minus rounding, and the dust stays in the vault.
    function test_REAUDIT2_OK_partialFillRoundingFavoursTheVault() public {
        (HyperVault v,) = _malloryVault();
        vm.prank(bob);
        v.requestDeposit(333_333_333_333, bob); // 333,333.333333 USDC
        vm.prank(mallory2);
        v.requestDeposit(777_777_777_777, mallory2);
        _fundAndDeploy(v, mallory, 1_000_000e6, 0);
        v.claim(bob);
        v.claim(mallory2);
        uint256 idleNow = v.idleAssets();
        vm.prank(mallory);
        v.bridgeToCore(idleNow);
        perp = int64(uint64(2_111_111_111_110));
        _core(v);
        _roll(301); // round 4: perp is not a landing signal (spot only): wait the window's cap
        address[3] memory who = [alice, bob, mallory2];
        uint256[3] memory sub;
        for (uint256 i; i < 3; ++i) {
            sub[i] = (v.balanceOf(who[i]) * (i + 7)) / 11; // odd fractions
            vm.prank(who[i]);
            v.requestRedeem(sub[i], who[i], who[i]);
        }
        vm.warp(vm.getBlockTimestamp() + 7 days);
        v.checkRisk();
        vm.prank(stranger);
        v.triggerEmergency();
        // 7 units of USDC arrive: a fill of a few parts per trillion.
        usdc.mint(address(v), 7);
        _roll(11);
        vm.prank(sentinel);
        v.settle();
        (,, uint256 R, uint256 paid, uint256 burned,,,) = v.epochs(1);
        assertEq(paid, 7);
        uint256 sumAssets;
        uint256 sumShares;
        for (uint256 i; i < 3; ++i) {
            (uint256 sh, uint256 as_) = lens.claimable(v, who[i]);
            sumAssets += as_;
            sumShares += sh;
            // value received >= value submitted at the settle price (paid / burned per share), minus rounding
            uint256 burnedMe = sub[i] - sh;
            if (burned > 0) assertGe(as_ * burned + sh * paid + 2 * burned + paid, sub[i] * paid, "redeemer shortchanged");
            else assertEq(sh, sub[i]);
            assertLe(burnedMe * paid, as_ * burned + burned, "burned shares were paid for");
            v.claim(who[i]);
        }
        assertLe(sumAssets, paid);
        assertLe(sumShares, R - burned);
        assertLe(v.balanceOf(address(v)), 3, "dust only stays in the vault");
        assertEq(v.pendingRedeemShares(), 0);
        assertLe(v.claimableRedeemAssets(), 7);
    }

    // ==================================================================
    // N2-02 (Low, fixed)  A performance fee raise takes effect from the next epoch: the running epoch settles at the
    //                     old rate, the pending rate switches inside that settle. Lowering stays immediate.
    // ==================================================================
    function test_REAUDIT2_N202_perfFeeRaiseStartsNextEpoch() public {
        _deposit(alice, 1_000_000e6);
        _settle();
        _claim(alice);
        vm.prank(manager);
        vault.bridgeToCore(1_000_000e6);
        _setCore(address(vault), 1_000_000e6, 0, 0);
        _skipBridgeWindow();
        _setCore(address(vault), 1_100_000e6, 0, 0); // +100k earned at the 20% rate
        _keeperHours(vault, 1);

        bytes memory raise = abi.encodeCall(HyperVault.setFees, (200, 3_000));
        vm.prank(owner);
        vault.queue(raise);
        vm.warp(vault.queuedEta(keccak256(raise)));
        vm.expectEmit(true, true, true, true, address(vault));
        emit IHyperVaultEvents.FeesScheduled(3_000);
        vault.execute(raise); // crystallises the management fee only, schedules the raise
        assertEq(vault.performanceFeeBps(), 2_000, "still the old rate");
        assertEq(vault.pendingPerformanceFeeBps(), 3_000);

        _settle(); // the 100k gain is charged at 20%
        uint256 fee1 = _value(vault, feeRecipient);
        emit log_named_decimal_uint("perf fee on the epoch that ran at 20%", fee1, 6);
        // hl-r2 H01 fix: the raise executes 8 days after the queue (was 2), so ~8 days of management fee ride along.
        assertApproxEqAbs(fee1, 20_000e6, 600e6, "20% of the pre-raise gain, plus a little management fee");
        assertEq(vault.performanceFeeBps(), 3_000, "switched inside settle");
        assertEq(vault.pendingPerformanceFeeBps(), 0);

        // The next epoch's gains are charged at 30% (measured in shares minted, valued after the settle).
        _setCore(address(vault), 1_200_000e6, 0, 0);
        _keeperHours(vault, 1);
        uint256 shares1 = vault.balanceOf(feeRecipient);
        _settle();
        uint256 fee2 = vault.convertToAssets(vault.balanceOf(feeRecipient) - shares1);
        emit log_named_decimal_uint("perf fee on the next epoch at 30%", fee2, 6);
        assertApproxEqAbs(fee2, 30_000e6, 300e6, "30% of the next epoch's gain");
    }

    function test_REAUDIT2_N202_loweringIsImmediateAndCancelsAPendingRaise() public {
        _deposit(alice, 100_000e6);
        _settle();
        bytes memory raise = abi.encodeCall(HyperVault.setFees, (200, 3_000));
        vm.prank(owner);
        vault.queue(raise);
        vm.warp(vault.queuedEta(keccak256(raise)));
        vault.execute(raise);
        assertEq(vault.pendingPerformanceFeeBps(), 3_000);
        // Same values are allowed while a raise is pending: it just drops the raise.
        vm.prank(owner);
        vault.lowerFees(200, 2_000);
        assertEq(vault.pendingPerformanceFeeBps(), 0);
        assertEq(vault.performanceFeeBps(), 2_000);
        // Without a pending raise, same values are still rejected (N-05).
        vm.prank(owner);
        vm.expectRevert(IHyperVaultErrors.InvalidFee.selector);
        vault.lowerFees(200, 2_000);
        // A real lowering applies at once.
        vm.prank(owner);
        vault.lowerFees(100, 1_000);
        assertEq(vault.performanceFeeBps(), 1_000);
        assertEq(vault.managementFeeBps(), 100);
        // A timelocked change that lowers the performance fee applies at once too.
        bytes memory lower = abi.encodeCall(HyperVault.setFees, (150, 500));
        vm.prank(owner);
        vault.queue(lower);
        vm.warp(vault.queuedEta(keccak256(lower)));
        vault.execute(lower);
        assertEq(vault.performanceFeeBps(), 500);
        assertEq(vault.managementFeeBps(), 150, "management changes apply at once (crystallised at the old rate)");
    }

    // ==================================================================
    // N2-03 (Low, fixed)  Custom flatten slippage is capped at 3% by the policy; the guardian may only use a
    //                     custom bound in emergency.
    // ==================================================================
    function test_REAUDIT2_N203_flattenSlippageIsCappedAt3Percent() public {
        (HyperVault v, VaultPolicy p) = _malloryVault();
        assertEq(p.MAX_FLATTEN_SLIPPAGE_BPS(), 300);
        VaultPolicy.RiskConfig memory c = p.config();
        c.maxFlattenSlippageBps = 301;
        vm.prank(mallory);
        vm.expectRevert(VaultPolicy.InvalidConfig.selector);
        p.proposeConfig(c);
        _setPosition(address(v), BTC, int64(1_000_000)); // 10 BTC long
        // Guardian: no custom bound outside emergency, the policy band only.
        vm.prank(guardian);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        v.flatten(BTC, 300);
        // Manager: at most the policy cap.
        vm.prank(mallory);
        vm.expectRevert(VaultPolicy.SlippageTooHigh.selector);
        v.flatten(BTC, 301);
        vm.prank(mallory);
        v.flatten(BTC, 300);
        (,, bytes memory body) = _decode(writer.last());
        (, bool isBuy, uint64 px,,,,) = abi.decode(body, (uint32, bool, uint64, uint64, bool, uint8, uint128));
        assertFalse(isBuy);
        assertEq(px, 97_000e8, "at most 3% under mark");
        // Guardian in emergency: custom bound allowed, still capped.
        vm.prank(guardian);
        v.triggerEmergency();
        vm.prank(guardian);
        vm.expectRevert(VaultPolicy.SlippageTooHigh.selector);
        v.flatten(BTC, 301);
        vm.prank(guardian);
        v.flatten(BTC, 300);
        (,, body) = _decode(writer.last());
        (, isBuy, px,,,,) = abi.decode(body, (uint32, bool, uint64, uint64, bool, uint8, uint128));
        assertEq(px, 97_000e8);
        // Anyone at the policy band in emergency.
        vm.prank(sentinel);
        v.flatten(BTC, 0);
    }

    // ==================================================================
    // N2-04 (Low, fixed onchain)  One agent per predicted vault. A second binding for the same address is refused
    //                             until the first is unregistered; an existing vault may bind a replacement.
    // ==================================================================
    function test_REAUDIT2_N204_oneAgentPerPredictedVault() public {
        address predicted = factory.predictVaultAddress(mallory, bytes32(uint256(7)));
        address a1 = makeAddr("a1");
        address a2 = makeAddr("a2");
        vm.startPrank(owner);
        factory.registerPlatformAgent(a1, predicted);
        vm.expectRevert(abi.encodeWithSelector(HyperVaultFactory.VaultAlreadyHasAgent.selector, predicted, a1));
        factory.registerPlatformAgent(a2, predicted);
        assertEq(factory.agentOfVault(predicted), a1);
        factory.unregisterPlatformAgent(a1); // not live: a plain unbind
        assertEq(factory.agentOfVault(predicted), address(0));
        factory.registerPlatformAgent(a2, predicted);
        assertEq(factory.agentOfVault(predicted), a2);
        vm.stopPrank();
        // An existing vault may receive a replacement binding for a rotation through its timelock.
        (HyperVault v,) = _malloryVault();
        address a3 = makeAddr("a3");
        vm.prank(owner);
        factory.registerPlatformAgent(a3, address(v));
        assertEq(factory.platformAgentFor(a3), address(v));
        assertEq(factory.agentOfVault(address(v)), a3);
        _timelocked(v, abi.encodeCall(HyperVault.setAgent, (a3)));
        assertEq(v.agent(), a3);
    }

    // ==================================================================
    // I2-03 (fixed)  The registrar cannot revoke a live agent: unregistering one needs the owner, the guardian or
    //                the sentinel. Pending (never approved) agents are the registrar's to unbind.
    // ==================================================================
    function test_REAUDIT2_I203_registrarCannotRevokeALiveAgent() public {
        (HyperVault v,) = _malloryVault();
        address registrar = makeAddr("registrar");
        vm.prank(owner);
        factory.setAgentRegistrar(registrar);
        assertEq(v.agent(), platformAgent);
        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(HyperVaultFactory.LiveAgent.selector, platformAgent, address(v)));
        factory.unregisterPlatformAgent(platformAgent);
        assertEq(v.agent(), platformAgent, "still trading");
        // A pending agent is the registrar's to unbind. (Round 4, V-04: only the cold owner may still pre-bind a
        // predicted vault; the registrar's own launches bind at create() from its signature.)
        address pending = makeAddr("pending");
        address predicted2 = factory.predictVaultAddress(mallory2, bytes32(0));
        vm.prank(registrar);
        vm.expectRevert(HyperVaultFactory.NotRegistrar.selector);
        factory.registerPlatformAgent(pending, predicted2);
        vm.prank(owner);
        factory.registerPlatformAgent(pending, predicted2);
        vm.prank(registrar);
        factory.unregisterPlatformAgent(pending);
        assertFalse(factory.isPlatformAgent(pending));
        // The sentinel (or guardian, or owner) revokes through unregister.
        vm.prank(sentinel);
        factory.unregisterPlatformAgent(platformAgent);
        assertEq(v.agent(), address(0));
        assertFalse(factory.isPlatformAgent(platformAgent));
        // Strangers cannot.
        vm.prank(stranger);
        vm.expectRevert(HyperVaultFactory.NotRegistrar.selector);
        factory.unregisterPlatformAgent(pending);
    }

    // ==================================================================
    // I2-04 (fixed)  A fresh vault's first settle runs the risk check itself: no keeper call is needed first.
    // ==================================================================
    function test_REAUDIT2_I204_firstSettleCheckpointsItself() public {
        (HyperVault v,) = _malloryVault();
        assertEq(v.checkpointAt(), 0);
        vm.prank(alice);
        v.requestDeposit(10_000e6, alice);
        vm.prank(mallory);
        v.settle(); // no checkRisk() before: would have reverted StaleCheckpoint
        assertGt(v.checkpointAt(), 0);
        assertEq(v.currentEpoch(), 1);
        v.claim(alice);
        assertEq(v.balanceOf(alice), 10_000e12);
        // Later settles still need a fresh checkpoint (the ratchet protects every epoch after the first).
        vm.prank(alice);
        v.requestDeposit(1_000e6, alice);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.prank(mallory);
        vm.expectRevert(VaultPolicy.StaleCheckpoint.selector);
        v.settle();
        v.checkRisk();
        vm.prank(mallory);
        v.settle();
    }

    // ==================================================================
    // Documented behaviour (REAUDIT2 I2-01, I2-02): kept by design, described in the README and the docs page.
    // ==================================================================
    function test_REAUDIT2_INFO_sentinelRebreachBlocksOwnerClears() public {
        (HyperVault v,) = _malloryVault();
        _fundAndDeploy(v, mallory, 100_000e6, 0);
        vm.prank(sentinel);
        v.triggerBreach();
        vm.warp(vm.getBlockTimestamp() + 1);
        bytes memory clear = abi.encodeCall(HyperVault.clearBreach, ());
        vm.prank(mallory);
        v.queue(clear);
        vm.warp(v.queuedEta(keccak256(clear)));
        vm.prank(sentinel);
        v.triggerBreach(); // re-breach right before the owner executes
        vm.expectRevert(IHyperVaultErrors.NotReady.selector);
        v.execute(clear);
        // Recovery: the factory owner rotates the sentinel (one transaction for every vault), the guardian clears.
        vm.prank(owner);
        factory.setSentinel(makeAddr("sentinel2"));
        vm.prank(sentinel);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        v.triggerBreach();
        vm.prank(guardian);
        v.clearBreach();
        assertFalse(v.breached());
    }

    function test_REAUDIT2_INFO_overdueStrangerSettleRefundsDeposits() public {
        (HyperVault v,) = _malloryVault();
        _fundAndDeploy(v, mallory, 100_000e6, 0);
        vm.prank(bob);
        v.requestDeposit(50_000e6, bob);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        v.checkRisk();
        vm.prank(sentinel);
        v.settle();
        (, uint256 depShares,,,,,,) = v.epochs(1);
        assertEq(depShares, 0, "bob is refunded, not minted: an overdue epoch only pays exits");
        v.claim(bob);
        assertEq(usdc.balanceOf(bob), 1_000_000e6, "refund in full");
    }

    // ==================================================================
    // Architecture verifications (must pass)
    // ==================================================================
    /// @dev Direct calls into the deployed libraries revert (Solidity call protection: ADDRESS != library).
    function test_REAUDIT2_OK_directLibraryCallsRevert() public {
        address logic = _libraryAddress("VaultLogic");
        address gov = _libraryAddress("VaultGovernance");
        assertTrue(logic.code.length > 0 && gov.code.length > 0);
        (bool ok,) = logic.call(abi.encodeWithSignature("settle(uint256)", uint256(0)));
        assertFalse(ok, "VaultLogic.settle direct call must revert");
        (ok,) = logic.call(abi.encodeWithSignature("requestDeposit(uint256,uint256,address)", uint256(0), uint256(1e6), alice));
        assertFalse(ok);
        (ok,) = gov.call(abi.encodeWithSignature("checkRisk(uint256)", uint256(0)));
        assertFalse(ok);
        (ok,) = gov.call(abi.encodeWithSignature("queue(uint256,bytes)", uint256(0), abi.encodeCall(HyperVault.clearBreach, ())));
        assertFalse(ok);
        (ok,) = gov.call(abi.encodeWithSignature("initialize(uint256,(address,string,string,address,address,address,address,uint16,uint16,uint256,uint256,address,address,address,uint16,uint16,bool,address,uint256),uint256)", uint256(0), _standaloneParams(policy), uint256(0)));
        assertFalse(ok);
        // Libraries hold no state and cannot be initialized or destroyed.
        assertEq(vm.load(logic, bytes32(0)), bytes32(0));
    }

    /// @dev The storage struct sits at slot 0; OpenZeppelin's upgradeable mixins use namespaced slots; a clone's
    ///      ERC-20 balances are reachable from the library through the same slots the mixin uses.
    function test_REAUDIT2_OK_storageLayoutIsConsistent() public {
        (HyperVault v,) = _malloryVault();
        // slot 0 of VaultStorage = asset
        assertEq(address(uint160(uint256(vm.load(address(v), bytes32(0))))), address(usdc));
        // ERC-20 namespaced slot: _totalSupply is the third word of the ERC20Storage struct
        bytes32 erc20Slot = 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00;
        _fundAndDeploy(v, mallory, 10_000e6, 0);
        assertEq(uint256(vm.load(address(v), bytes32(uint256(erc20Slot) + 2))), v.totalSupply());
        assertGt(v.totalSupply(), 0);
        // Ownable namespaced slot
        bytes32 ownSlot = 0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300;
        assertEq(address(uint160(uint256(vm.load(address(v), ownSlot)))), mallory);
        // The round 3 field was appended: the pending performance fee rate starts empty.
        assertEq(v.pendingPerformanceFeeBps(), 0);
    }

    /// @dev Reentrancy guard: the lock is set and released across the guarded entry points (no stuck lock).
    function test_REAUDIT2_OK_lockIsReleased() public {
        (HyperVault v,) = _malloryVault();
        _fundAndDeploy(v, mallory, 10_000e6, 0);
        // amounts x10 for MIN_DEPOSIT (10 USDC); same shape: the deposit cannot cover the redemption
        vm.prank(alice);
        v.requestRedeem(20e12, alice, alice);
        vm.prank(alice);
        v.requestDeposit(10e6, alice);
        v.checkRisk();
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(IHyperVaultErrors.InsufficientLiquidity.selector, 10e6, 20e6));
        v.settle(); // reverts: the lock must still be released
        vm.prank(alice);
        v.cancelRedeemRequest();
        vm.prank(alice);
        v.cancelDepositRequest();
        vm.prank(alice);
        v.requestDeposit(10e6, alice);
        v.checkRisk();
        vm.prank(mallory);
        v.settle();
    }

    /// @dev Role rotation mid epoch: the new keys take over at once; nothing stored on the vault changes.
    function test_REAUDIT2_OK_rotationMidEpoch() public {
        (HyperVault v,) = _malloryVault();
        _fundAndDeploy(v, mallory, 10_000e6, 0);
        vm.prank(bob);
        v.requestDeposit(1_000e6, bob);
        address g2 = makeAddr("g2");
        address s2 = makeAddr("s2");
        vm.prank(owner);
        factory.setGuardian(g2);
        vm.prank(owner);
        factory.setSentinel(s2);
        vm.prank(s2);
        v.setDepositsPaused(true);
        vm.prank(g2);
        v.setDepositsPaused(false);
        v.checkRisk();
        vm.prank(mallory);
        v.settle();
        v.claim(bob);
        assertEq(v.guardian(), g2);
    }

    /// @dev Salt reuse: the clone address is taken, create reverts; the agent bound to it stays usable only there.
    function test_REAUDIT2_OK_saltReuseReverts() public {
        _malloryVault(); // salt 0
        vm.startPrank(mallory);
        usdc.approve(address(factory), 2e6);
        vm.expectRevert();
        factory.create{value: 0.01 ether}(_malloryParams(address(0)), _noPermit());
        vm.stopPrank();
    }

    /// @dev Finds a linked library by scanning the implementation's (then VaultGovernance's) runtime code for a
    ///      20 byte window whose code equals the library's compiled runtime code after the 39 byte call-protection
    ///      prefix (PUSH32 <own address> is patched in at deploy time, so the full code hash differs).
    function _libraryAddress(string memory name) internal view returns (address) {
        bytes memory runtime = vm.getDeployedCode(string.concat(name, ".sol:", name));
        address found = _scanFor(address(vaultImpl).code, runtime);
        if (found != address(0)) return found;
        address gov = _scanFor(address(vaultImpl).code, vm.getDeployedCode("VaultGovernance.sol:VaultGovernance"));
        require(gov != address(0), "VaultGovernance not found");
        found = _scanFor(gov.code, runtime);
        require(found != address(0), "library not found");
        return found;
    }

    function _scanFor(bytes memory code, bytes memory runtime) internal view returns (address) {
        bytes32 h = _tailHash(runtime);
        for (uint256 i; i + 20 <= code.length; ++i) {
            address a;
            assembly {
                a := shr(96, mload(add(add(code, 0x20), i)))
            }
            if (a.code.length == runtime.length && _tailHash(a.code) == h) return a;
        }
        return address(0);
    }

    function _tailHash(bytes memory b) internal pure returns (bytes32 h) {
        if (b.length <= 39) return keccak256(b);
        assembly {
            h := keccak256(add(add(b, 0x20), 39), sub(mload(b), 39))
        }
    }
}

/// @notice I2-05 split out of Reaudit2PoC (hl-r2 integration): with HLO-07 in the tree, solc 0.8.28 (via_ir) stops the
///         one-job build with "Tag too large for reserved space" while assembling Reaudit2PoC (a 111 KB test
///         contract). Moving this test (three more HyperVaultFactory creations) into its own contract avoids it.
///         The test itself is unchanged.
contract Reaudit2PoCFactoryRoles is AuditBase {
    // ==================================================================
    // I2-05 (fixed)  Factory roles: guardian != sentinel, the hot roles (sentinel, registrar) are distinct from
    //                each other and from owner and guardian. Owner == guardian is allowed (one cold multisig).
    // ==================================================================
    function test_REAUDIT2_I205_factoryRolesMustNotCollide() public {
        vm.expectRevert(HyperVaultFactory.RolesCollide.selector);
        new HyperVaultFactory(
            owner, address(vaultImpl), address(policyImpl), IERC20(address(usdc)), ICoreDepositWallet(address(depositWallet)), treasury, guardian, guardian
        );
        vm.expectRevert(HyperVaultFactory.RolesCollide.selector);
        new HyperVaultFactory(
            owner, address(vaultImpl), address(policyImpl), IERC20(address(usdc)), ICoreDepositWallet(address(depositWallet)), treasury, guardian, owner
        );
        // Owner == guardian is fine.
        new HyperVaultFactory(
            guardian, address(vaultImpl), address(policyImpl), IERC20(address(usdc)), ICoreDepositWallet(address(depositWallet)), treasury, guardian, sentinel
        );
        address registrar = makeAddr("registrar");
        vm.startPrank(owner);
        factory.setAgentRegistrar(registrar);
        vm.expectRevert(HyperVaultFactory.RolesCollide.selector);
        factory.setSentinel(guardian);
        vm.expectRevert(HyperVaultFactory.RolesCollide.selector);
        factory.setSentinel(owner);
        vm.expectRevert(HyperVaultFactory.RolesCollide.selector);
        factory.setSentinel(registrar);
        vm.expectRevert(HyperVaultFactory.RolesCollide.selector);
        factory.setGuardian(sentinel);
        vm.expectRevert(HyperVaultFactory.RolesCollide.selector);
        factory.setGuardian(registrar);
        vm.expectRevert(HyperVaultFactory.RolesCollide.selector);
        factory.setAgentRegistrar(sentinel);
        vm.expectRevert(HyperVaultFactory.RolesCollide.selector);
        factory.setAgentRegistrar(guardian);
        vm.expectRevert(HyperVaultFactory.RolesCollide.selector);
        factory.setAgentRegistrar(owner);
        factory.setAgentRegistrar(address(0)); // none
        vm.expectRevert(HyperVaultFactory.RolesCollide.selector);
        factory.transferOwnership(sentinel);
        factory.transferOwnership(guardian); // the deploy script's path: the cold guardian becomes the owner
        vm.stopPrank();
        assertEq(factory.owner(), owner, "two step: nothing changed yet");
        vm.prank(guardian);
        factory.acceptOwnership();
        assertEq(factory.owner(), guardian);
        // create() refuses to run on colliding roles (defence in depth: the setters already prevent it).
        (HyperVault v,) = _malloryVault();
        assertEq(v.guardian(), guardian);
    }
}
