// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ReauditHandler} from "../reaudit/ReauditHandler.sol";
import {HyperVault} from "../../../src/HyperVault.sol";
import {HyperVaultLens} from "../../../src/HyperVaultLens.sol";
import {HyperVaultFactory} from "../../../src/HyperVaultFactory.sol";
import {MockCoreWriter, MockUSDC} from "../../mocks/Mocks.sol";
import {HyperCore} from "../../../src/hypercore/HyperCore.sol";

/// @notice Third pass handler: many-epoch pro-rata emergency flows, direct library calls, role rotation mid epoch
///         and fee raises across epochs, on top of every earlier action.
contract Reaudit2Handler is ReauditHandler {
    address public immutable logicLib;
    address public immutable govLib;
    address public guardianNow;
    address public sentinelNow;

    uint256 public vDirectLibraryCall; // a direct call into a library succeeded
    uint256 public vClaimOverBudget; // a claim needed more than 200k gas (N2-01)
    uint256 public vPayoutOverLiquidity; // claimable USDC promised > USDC reserved
    uint256 public miniEpochs;
    uint256 public steeredEpochs;
    uint256 public vExitAfterPartialFill; // emergency exited although the last fill was partial (W-01 / W-01b)
    uint256 public vOwnerExit; // the owner ended an emergency, or queued an exit (W-01b)
    uint256 public vSyncChangedAgent; // syncAgent changed vault.agent() (A-13)
    uint256 public vSyncWhileReduceOnly; // syncAgent sent anything but the vault's own Standard mode pin (HL-PROXY)
    uint256 public exitsOk;
    uint256 public rotations;
    uint256 public feeRaises;
    uint256 public maxClaimGas;
    uint256 internal _turn;

    /// @dev Round 4: the emergency unwind (bridge home, settle) is for the listed roles only. Rotates through them so
    ///      every role is exercised; the stranger's attempt is kept and must always fail (vStrangerUnwind).
    function _unwinder() internal returns (address who) {
        address[5] memory roles = [factory.guardian(), manager, factory.sentinel(), owner, vault.operator()];
        for (uint256 i; i < 5; ++i) {
            who = roles[(_turn + i) % 5];
            if (who != address(0)) break;
        }
        ++_turn;
    }

    /// @dev HLR2-H04: in emergency only the guardian and the sentinel bridge home; otherwise the old rotation.
    function _bridger() internal returns (address who) {
        if (!vault.emergency()) return _unwinder();
        who = _turn % 2 == 0 ? factory.guardian() : factory.sentinel();
        ++_turn;
    }

    function _strangerTriesBridge(uint256 amount) internal {
        vm.prank(stranger);
        try vault.bridgeToEvm(amount) {
            vStrangerUnwind++;
        } catch {}
    }

    function _strangerTriesSettle() internal {
        vm.prank(stranger);
        try vault.settle() {
            vStrangerUnwind++;
        } catch {}
    }

    constructor(
        HyperVault vault_,
        HyperVaultLens lens_,
        MockUSDC usdc_,
        HyperVaultFactory factory_,
        address owner_,
        address manager_,
        address guardian_,
        address feeRecipient_,
        address treasury_,
        address agent_,
        address logicLib_,
        address govLib_
    ) ReauditHandler(vault_, lens_, usdc_, factory_, owner_, manager_, guardian_, feeRecipient_, treasury_, agent_) {
        logicLib = logicLib_;
        govLib = govLib_;
        guardianNow = guardian_;
        sentinelNow = factory_.sentinel();
    }

    /// @dev The live guardian forces an emergency so that the pro-rata path is exercised in most runs; when the
    ///      Core side is empty the manager first moves MIN_BRIDGE x 5 across (the window closes before settle).
    function forceEmergency(uint256 seed) external track("forceEmergency") {
        if (vault.emergency()) return;
        if (uint256(spot) < MIN_BRIDGE * 5 && !vault.bridgeInFlight() && vault.idleAssets() >= MIN_BRIDGE * 5 + 1e6) {
            vm.prank(manager);
            try vault.bridgeToCore(MIN_BRIDGE * 5) {
                spot += uint64(MIN_BRIDGE * 5);
                sync();
                _bn = vm.getBlockNumber() + 11;
                vm.roll(_bn);
            } catch {}
        }
        if (seed % 3 == 0) return; // sometimes leave the vault healthy
        vm.prank(factory.guardian());
        try vault.triggerEmergency() {} catch {}
    }

    /// @dev Emergency mini epoch: MIN_BRIDGE comes home, the window closes, an allowed role settles pro rata
    ///      (round 4: the stranger tries first and must fail).
    function miniEpoch() external track("miniEpoch") {
        if (!vault.emergency()) return;
        uint256 avail = uint256(spot) + (perp > 0 ? uint256(uint64(perp)) : 0);
        if (avail < MIN_BRIDGE) return;
        _strangerTriesBridge(MIN_BRIDGE);
        vm.prank(_bridger());
        try vault.bridgeToEvm(MIN_BRIDGE) {
            if (spot >= MIN_BRIDGE) {
                spot -= uint64(MIN_BRIDGE);
            } else {
                perp -= int64(uint64(MIN_BRIDGE - spot));
                spot = 0;
            }
            usdc.mint(address(vault), MIN_BRIDGE);
            sync();
        } catch {
            return;
        }
        _bn = vm.getBlockNumber() + 11;
        vm.roll(_bn);
        try vault.checkRisk() {} catch {}
        _strangerTriesSettle();
        vm.prank(_unwinder());
        try vault.settle() {
            miniEpochs++;
            settlesOk++;
            emergencySettles++;
        } catch {}
    }

    /// @dev Near-complete payout epoch (VERIFY.md): brings home exactly the liquidity for a 90..99.99% fill of the
    ///      pending redemptions, then an allowed role settles (the stranger tries first and must fail). Followed by honest redeemers and a small bridge + settle
    ///      (miniEpoch) this was the V-01 shape; with partial fill + return it must be harmless.
    function steerEpoch(uint256 fillSeed) external track("steerEpoch") {
        if (!vault.emergency() || vault.bridgeInFlight()) return;
        if (vault.pendingRedeemShares() == 0) {
            // Nothing pending (a settle returns everything it could not pay): an honest actor queues half of what
            // they hold, claiming any returned shares first.
            address who = _actor(fillSeed);
            (uint256 back,) = lens.claimable(vault, who);
            uint256 half = (vault.balanceOf(who) + back) / 2;
            if (half == 0) return;
            vm.prank(who);
            try vault.requestRedeem(half, who, who) {} catch {
                return;
            }
        }
        uint256 fill = bound(fillSeed, 9_000, 9_999);
        uint256 redAssets = vault.previewRedeem(vault.pendingRedeemShares());
        uint256 want = (redAssets * fill) / 10_000;
        uint256 idle = vault.idleAssets();
        if (want > idle) {
            uint256 need = want - idle;
            uint256 avail = uint256(spot) + (perp > 0 ? uint256(uint64(perp)) : 0);
            if (need > avail) need = avail;
            if (need == 0) return;
            _strangerTriesBridge(need);
            vm.prank(_bridger());
            try vault.bridgeToEvm(need) {
                if (spot >= need) {
                    spot -= uint64(need);
                } else {
                    perp -= int64(uint64(need - spot));
                    spot = 0;
                }
                usdc.mint(address(vault), need);
                sync();
            } catch {
                return;
            }
            _bn = vm.getBlockNumber() + 11;
            vm.roll(_bn);
        }
        try vault.checkRisk() {} catch {}
        _strangerTriesSettle();
        vm.prank(_unwinder());
        try vault.settle() {
            steeredEpochs++;
            settlesOk++;
            emergencySettles++;
        } catch {}
    }

    /// @dev W-01 / W-01b shape: right after the latest settle (optionally after an empty or dust settle first, the
    ///      W-01b trick) the owner tries to end the emergency, which must never work, and the live guardian tries,
    ///      which must only work when nothing is pending and the last settle of this emergency paid in full.
    function guardianExits(uint256 seed) external track("guardianExits") {
        if (!vault.emergency()) return;
        if (seed % 3 == 0 && !vault.bridgeInFlight()) {
            // The W-01b trick: an empty (or dust) settle before the exit.
            if (seed % 2 == 0) {
                address who = _actor(seed);
                uint256 dust = vault.balanceOf(who) > 1e6 ? 1e6 : vault.balanceOf(who);
                if (dust > 0) {
                    vm.prank(who);
                    try vault.requestRedeem(dust, who, who) {} catch {}
                }
            }
            _strangerTriesSettle();
            vm.prank(_unwinder());
            try vault.settle() {
                settlesOk++;
                emergencySettles++;
            } catch {}
        }
        vm.prank(owner);
        try vault.exitEmergency() {
            vOwnerExit++;
        } catch {}
        vm.prank(owner);
        try vault.queue(abi.encodeCall(HyperVault.exitEmergency, ())) {
            vOwnerExit++;
        } catch {}
        uint256 pending = vault.pendingRedeemShares();
        bool partialSinceEmergency = _lastEpochPartialInEmergency();
        vm.prank(factory.guardian());
        try vault.exitEmergency() {
            exitsOk++;
            if (pending > 0 || partialSinceEmergency) vExitAfterPartialFill++;
        } catch {}
    }

    /// @dev True when the last settled epoch belongs to the current emergency and was a partial fill.
    function _lastEpochPartialInEmergency() internal view returns (bool) {
        uint256 ep = vault.currentEpoch();
        if (ep == 0) return false;
        (,, uint256 R,, uint256 burned,,, uint64 settledAt) = vault.epochs(ep - 1);
        return settledAt >= vault.emergencyAt() && burned < R;
    }

    /// @dev A-13 / HL-PROXY: syncAgent is the account-mode pin. It must never change the agent and never send an
    ///      action other than 16 (the vault's own address, Standard): no HyperCore approval of any agent, in any state.
    function syncAgentAction(uint256 s) external track("syncAgent") {
        address before = vault.agent();
        MockCoreWriter w = MockCoreWriter(HyperCore.CORE_WRITER);
        uint256 n = w.count();
        vm.prank(_actor(s));
        try vault.syncAgent() {
            for (uint256 i = n; i < w.count(); ++i) {
                bytes memory raw = w.at(i);
                uint24 id = (uint24(uint8(raw[1])) << 16) | (uint24(uint8(raw[2])) << 8) | uint24(uint8(raw[3]));
                if (id != HyperCore.ACTION_SET_ABSTRACTION) vSyncWhileReduceOnly++;
            }
        } catch {}
        if (vault.agent() != before) vSyncChangedAgent++;
    }

    /// @dev Claims and records the cost; a claim past 200k gas is the N2-01 regression (O(1) claims since round 3).
    function claimMeasured(uint256 s) external track("claimMeasured") {
        address a = _actor(s);
        uint256 g = gasleft();
        try vault.claim(a) {
            g -= gasleft();
            if (g > maxClaimGas) maxClaimGas = g;
            if (g > 200_000) vClaimOverBudget++;
        } catch {}
    }

    /// @dev Direct (non delegate) calls into the linked libraries must always revert.
    function directLibraryCall(uint256 which) external track("directLibraryCall") {
        bytes memory data;
        which = which % 4;
        if (which == 0) data = abi.encodeWithSignature("settle(uint256)", uint256(0));
        else if (which == 1) data = abi.encodeWithSignature("requestDeposit(uint256,uint256,address)", uint256(0), uint256(1e6), stranger);
        else if (which == 2) data = abi.encodeWithSignature("checkRisk(uint256)", uint256(0));
        else data = abi.encodeWithSignature("clearBreach(uint256,address)", uint256(0), stranger);
        address target = which < 2 ? logicLib : govLib;
        (bool ok,) = target.call(data);
        if (ok) vDirectLibraryCall++;
    }

    /// @dev The factory owner rotates the guardian or the sentinel at any time. Guardian and sentinel keep
    ///      distinct address spaces: the factory itself accepts guardian == sentinel (REAUDIT2 info I2-05).
    function rotateRoles(uint256 seed) external track("rotateRoles") {
        bool toGuardian = seed % 2 == 0;
        address fresh =
            address(uint160(uint256(keccak256(abi.encode(toGuardian ? "inv.guardian" : "inv.sentinel", seed % 5)))));
        vm.startPrank(owner);
        if (toGuardian) {
            try factory.setGuardian(fresh) {
                guardianNow = fresh;
                rotations++;
            } catch {}
        } else {
            try factory.setSentinel(fresh) {
                sentinelNow = fresh;
                rotations++;
            } catch {}
        }
        vm.stopPrank();
    }

    /// @dev Owner queues a fee raise, waits the delay, executes.
    function raiseFees(uint256 mgmt, uint256 perf) external track("raiseFees") {
        uint16 m = uint16(bound(mgmt, vault.managementFeeBps(), 500));
        uint16 p = uint16(bound(perf, vault.performanceFeeBps(), 3_000));
        bytes memory data = abi.encodeCall(HyperVault.setFees, (m, p));
        vm.prank(owner);
        try vault.queue(data) {} catch {
            return;
        }
        vm.warp(vm.getBlockTimestamp() + vault.timelockDelay());
        try vault.execute(data) {
            feeRaises++;
        } catch {}
    }

    /// @dev Promised claims never exceed the USDC reserved for them.
    function checkPayouts() external track("checkPayouts") {
        uint256 owed;
        for (uint256 i; i < 3; ++i) {
            (, uint256 x) = lens.claimable(vault, actors[i]);
            owed += x;
        }
        if (owed > vault.claimableRedeemAssets() + 3) vPayoutOverLiquidity++;
    }
}
