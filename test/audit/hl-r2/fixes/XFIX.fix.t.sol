// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {HostileBase} from "../hostile/HostileBase.t.sol";
import {HyperVault} from "../../../../src/HyperVault.sol";
import {VaultPolicy} from "../../../../src/VaultPolicy.sol";
import {IHyperVaultErrors as E} from "../../../../src/VaultTypes.sol";

/// @notice Fix tests for XF-01 and XF-02 (XREVIEW-FIXES.md). Internal, AI-assisted review; not an independent audit.
///         Run with HLR2-H01 + COMBINED-B + tests-xfix/patches/XF01.patch + XF02.patch (fixes/verify-xfix.sh stage 2).
contract XFIX_Fix is HostileBase {
    function _emergency(HyperVault v) internal {
        uint256 shares = v.balanceOf(alice);
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        vm.warp(v.epochDeadline());
        vm.prank(alice);
        v.triggerEmergency();
    }

    function _land(HyperVault v, uint256 amount, uint256 coreLeft) internal {
        _setCore(address(v), int64(uint64(coreLeft)), 0, 0);
        _setWithdrawable(address(v), uint64(coreLeft));
        usdc.mint(address(v), amount);
        vm.roll(vm.getBlockNumber() + 11);
        v.syncBridge();
    }

    /// XF-01: the guardian and the sentinel are absent; the honest keeper (operator) brings the USDC home and settles.
    function test_XF01_fix_honestOperatorExitsWithoutThePlatform() public {
        HyperVault v = _platformVaultLike(address(0));
        _emergency(v);
        vm.prank(keeper);
        v.bridgeToEvm(100_002e6);
        _land(v, 100_002e6, 0);
        v.checkRisk();
        vm.prank(keeper);
        v.settle();
        uint256 b0 = usdc.balanceOf(alice);
        v.claim(alice);
        assertGt(usdc.balanceOf(alice) - b0, 99_000e6, "paid without a platform key");
    }

    /// XF-01 keeps H04 closed: the manager cannot open a second window right after the first one closes; the exit
    /// settle lands in the free blocks; only after the cooldown may the manager bridge again.
    function test_XF01_fix_managerCannotChainWindows() public {
        HyperVault v = _platformVaultLike(address(0));
        _emergency(v);
        vm.prank(platformVaultOwner); // manager = owner
        v.bridgeToEvm(100e6);
        _land(v, 100e6, 99_902e6); // window over (landed, 11 blocks)
        vm.prank(platformVaultOwner);
        vm.expectRevert(E.BridgeInFlight.selector);
        v.bridgeToEvm(100e6); // the H04 chain: refused
        // the platform is not bound by the cooldown
        vm.prank(sentinel);
        v.bridgeToEvm(99_902e6);
        _land(v, 99_902e6, 0);
        vm.prank(platformVaultOwner);
        vm.expectRevert(E.BridgeInFlight.selector);
        v.bridgeToEvm(100e6);
        v.checkRisk();
        vm.prank(guardian);
        v.settle(); // lands in the gap
        uint256 b0 = usdc.balanceOf(alice);
        v.claim(alice);
        assertGt(usdc.balanceOf(alice) - b0, 99_000e6);
        // after the cooldown the manager may bridge again (nothing left to bridge here: BridgeTooSmall / liquidity)
        vm.roll(vm.getBlockNumber() + 331);
        _setCore(address(v), 500e6, 0, 500e6);
        _setWithdrawable(address(v), 0);
        vm.prank(platformVaultOwner);
        v.bridgeToEvm(500e6);
        assertTrue(v.bridgePending());
    }

    /// XF-02: after the loosening applies in emergency the default close band is the 3% flatten cap, and a
    /// reduce-only placeOrder outside it is refused.
    function test_XF02_fix_closeBandCappedAtTheFlattenCap() public {
        HyperVault v = _platformVaultLike(address(0));
        VaultPolicy pol = v.policy();
        _setPosition(address(v), BTC, 100_000);
        _setCore(address(v), 100_002e6, 100_000e6, 0);
        vm.prank(platformVaultOwner);
        pol.proposeConfig(_loose());
        _emergency(v);
        vm.warp(pol.pendingConfig().eta);
        pol.applyPendingConfig();
        vm.prank(platformVaultOwner);
        v.flatten(BTC, 0);
        assertEq(_lastLimitPx(), 97_000e8, "default band = min(20%, 3%)");
        vm.prank(platformVaultOwner);
        vm.expectRevert(abi.encodeWithSelector(E.OrderRejected.selector, "price outside the close band"));
        v.placeOrder(BTC, false, 80_000e8, 1e8, true, 3, 0);
        vm.prank(platformVaultOwner);
        v.placeOrder(BTC, false, 97_000e8, 1e8, true, 3, 0);
        assertEq(_lastLimitPx(), 97_000e8);
    }

    /// Control: outside a breach or emergency the honest manager's order band is still maxSlippageBps (1%).
    function test_XF02_fix_normalOrdersUnchanged() public {
        HyperVault v = _platformVaultLike(address(0));
        vm.prank(platformVaultOwner);
        v.placeOrder(BTC, true, 101_000e8, 1e7, false, 3, 0);
        assertEq(_lastLimitPx(), 101_000e8);
        vm.prank(platformVaultOwner);
        v.flatten(BTC, 0); // flat: nothing sent
    }

    function _lastLimitPx() internal view returns (uint64 px) {
        (, uint24 id, bytes memory body) = _decode(writer.last());
        assertEq(id, 1, "limit order");
        (,, px,,,,) = abi.decode(body, (uint32, bool, uint64, uint64, bool, uint8, uint128));
    }
}
