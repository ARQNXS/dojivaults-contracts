// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {VaultHandler} from "../invariants/VaultHandler.sol";
import {HyperVault} from "../../../src/HyperVault.sol";
import {HyperVaultLens} from "../../../src/HyperVaultLens.sol";
import {HyperVaultFactory} from "../../../src/HyperVaultFactory.sol";
import {MockUSDC} from "../../mocks/Mocks.sol";

/// @notice Re-audit extension of the invariant handler: keeper ratchet steps, registrar actions, a manager that
///         holds the bridge window open and settles inside it, same-value lowerFees, and management-only accruals.
contract ReauditHandler is VaultHandler {
    uint256 public vStaleSettle; // N-01: a settle priced at a NAV view >1% away from the real (visible) NAV
    uint256 public vHwmWithoutFee; // N-08: HWM raised by an accrual that charged no performance fee
    uint256 public vPerfOutsideSettle; // N-05: fee value minted outside settle above the management cap
    uint256 public heldWindowSettles;
    uint256 public registrarCalls;

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
        address agent_
    ) VaultHandler(vault_, lens_, usdc_, factory_, owner_, manager_, guardian_, feeRecipient_, treasury_, agent_) {}

    function _rollBy(uint256 n) internal {
        _bn = vm.getBlockNumber() + n;
        vm.roll(_bn);
    }

    /// @dev Visible real NAV of the model (what totalAssets() returns outside a window).
    function _modelNav() internal view returns (uint256) {
        uint256 bal = usdc.balanceOf(address(vault));
        uint256 reserved = vault.pendingDepositAssets() + vault.deferredDepositAssets() + vault.claimableRedeemAssets();
        uint256 idle = bal > reserved ? bal - reserved : 0;
        int256 core = int256(perp) + int256(uint256(spot));
        return idle + (core > 0 ? uint256(core) : 0);
    }

    function _ping() internal returns (bool) {
        uint256 avail = uint256(spot) + (perp > 0 ? uint256(uint64(perp)) : 0);
        if (avail < MIN_BRIDGE) return false;
        vm.prank(manager);
        try vault.bridgeToEvm(MIN_BRIDGE) {
            if (spot >= MIN_BRIDGE) {
                spot -= uint64(MIN_BRIDGE);
            } else {
                perp -= int64(uint64(MIN_BRIDGE - spot));
                spot = 0;
            }
            usdc.mint(address(vault), MIN_BRIDGE);
            sync();
            return true;
        } catch {
            return false;
        }
    }

    /// @dev Keeper: one hour, one checkRisk (ratchet step).
    function keeperHour() external track("keeperHour") {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        try vault.checkRisk() {} catch {}
    }

    /// @dev Manager holds the window open past MAX_WINDOW_EXTENSION and settles inside it, with an honest deposit.
    function holdWindowSettle(uint256 s, uint256 amt) external track("holdWindowSettle") {
        if (vault.breached() || vault.emergency()) return;
        address a = _actor(s);
        amt = bound(amt, 1_000e6, 1_000_000e6);
        usdc.mint(a, amt);
        vm.prank(a);
        try vault.requestDeposit(amt, a) {} catch {}
        for (uint256 i; i < 4; ++i) {
            if (!_ping()) return;
            _rollBy(10);
        }
        if (!_ping()) return;
        try vault.checkRisk() {} catch {}
        vm.prank(manager);
        try vault.settle() {
            heldWindowSettles++;
            uint256 model = _modelNav();
            uint256 view_ = vault.totalAssets();
            uint256 d = model > view_ ? model - view_ : view_ - model;
            if (d * 100 > model) vStaleSettle++;
        } catch {}
    }

    function lowerFeesSame() external track("lowerFeesSame") {
        if (vault.bridgeInFlight()) return;
        uint256 assets = vault.totalAssets();
        uint256 elapsed = vm.getBlockTimestamp() - vault.lastFeeAccrual();
        uint256 cap = (assets * vault.managementFeeBps() * elapsed) / (BPS * YEAR);
        uint256 f0 = vault.balanceOf(feeRecipient) + vault.balanceOf(treasury);
        (uint16 mg, uint16 pf) = (vault.managementFeeBps(), vault.performanceFeeBps());
        vm.prank(owner);
        try vault.lowerFees(mg, pf) {
            uint256 fee = vault.balanceOf(feeRecipient) + vault.balanceOf(treasury) - f0;
            if (fee > 0 && (fee * (assets + 1)) / (vault.totalSupply() + 1e6) > cap + 1) vPerfOutsideSettle++;
        } catch {}
    }

    function accrueManagementOnly(uint256 secs) external track("accrueMgmt") {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 0, 1 days));
        if (vault.bridgeInFlight() || vault.performanceFeeBps() == 0) return;
        uint256 h0 = vault.highWaterMark();
        vault.accrueFees();
        if (vault.highWaterMark() > h0) vHwmWithoutFee++;
    }

    /// @dev Registrar (here the factory owner): register, unregister the live agent, or queue another platform agent.
    function registrarOps(uint256 op, uint256 seed) external track("registrarOps") {
        registrarCalls++;
        address other = address(uint160(uint256(keccak256(abi.encode("inv.agent", seed % 4)))));
        op = op % 3;
        vm.startPrank(owner);
        if (op == 0) {
            try factory.registerPlatformAgent(other, address(vault)) {} catch {}
            bytes memory data = abi.encodeCall(HyperVault.setAgent, (other));
            try vault.queue(data) {
                _queued.push(data);
            } catch {}
        } else if (op == 1) {
            address cur = vault.agent();
            if (cur != address(0) && cur != agentAddr) factory.unregisterPlatformAgent(cur);
        } else {
            factory.unregisterPlatformAgent(other);
        }
        vm.stopPrank();
    }
}
