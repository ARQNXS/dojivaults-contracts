// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {MutBase} from "./MutBase.t.sol";
import {HyperVault} from "../../../../src/HyperVault.sol";
import {VaultPolicy} from "../../../../src/VaultPolicy.sol";
import {InitParams, IHyperVaultErrors as E} from "../../../../src/VaultTypes.sol";
import {HyperCore} from "../../../../src/hypercore/HyperCore.sol";
import {MockUSDC} from "../../../mocks/Mocks.sol";

/// @dev A 6 decimal token that calls back into the vault from transferFrom (a hostile asset, test only).
contract ReentrantUSDC is MockUSDC {
    HyperVault public target;
    bool public armed;

    function arm(HyperVault v) external {
        target = v;
        armed = true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false;
            target.requestDeposit(10e6, from); // re-enter
        }
        return super.transferFrom(from, to, amount);
    }
}

contract RevertingSink {
    receive() external payable {
        revert("no");
    }
}

/// @title hl-r2 mutation kill tests: share accounting primitives, orders, flatten, agent slot, lock, gas funding
contract HLR2MutMiscTest is MutBase {
    function _holder() internal returns (uint256 shares) {
        _deposit(alice, 1_000e6);
        _settle();
        _claim(alice);
        shares = vault.balanceOf(alice);
    }

    /// Mutants: VaultMath.transfer / burn `if (bal < amount) revert ERC20InsufficientBalance` deleted. The library
    /// transfers run `unchecked`: without the check a redemption of more shares than held underflows the balance.
    function test_HLR2_M36_kills_shareBalanceChecks() public {
        uint256 s = _holder();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, s, s + 1));
        vault.requestRedeem(s + 1, alice, alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, 1));
        vault.requestRedeem(1, bob, bob);
        assertEq(vault.balanceOf(bob), 0);
    }

    /// Mutants: VaultMath.spendAllowance: the infinite-allowance shortcut deleted, `<` -> `<=`, `current - amount`
    /// -> `+`, the decrement deleted. A redemption on behalf spends exactly the allowance it uses.
    function test_HLR2_M37_kills_allowance() public {
        uint256 s = _holder();
        vm.prank(alice);
        vault.approve(bob, s / 2);
        vm.prank(bob);
        vault.requestRedeem(s / 2, bob, alice); // exactly the allowance
        assertEq(vault.allowance(alice, bob), 0, "spent");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        vault.requestRedeem(1, bob, alice);
        vm.prank(alice);
        vault.approve(stranger, type(uint256).max);
        vm.prank(stranger);
        vault.requestRedeem(1, stranger, alice);
        assertEq(vault.allowance(alice, stranger), type(uint256).max, "infinite stays infinite");
    }

    /// Mutants: placeOrder `if (sz == 0 || limitPx == 0) revert ZeroAmount()` deleted / `&&` / `== 1`.
    function test_HLR2_M38_kills_zeroOrder() public {
        _setCore(address(vault), 10_000e6, 0, 0);
        vm.startPrank(manager);
        vm.expectRevert(E.ZeroAmount.selector);
        vault.placeOrder(BTC, true, 100_000e8, 0, false, 2, 0);
        vm.expectRevert(E.ZeroAmount.selector);
        vault.placeOrder(BTC, true, 0, 0.01e8, false, 2, 0);
        vault.placeOrder(BTC, true, 1, 1, false, 2, 0); // 1 / 1 is a (tiny) valid order
        vm.stopPrank();
    }

    /// Mutants: flatten `asset >= SPOT_ASSET_OFFSET` -> `>` / deleted, `if (p.szi == 0) return` deleted / `== 1`,
    /// and the cloid 0 -> 1. Flatten never touches spot, sends nothing without a position, and its IOC order is
    /// reduce only, uncloided.
    function test_HLR2_M39_kills_flattenGuards() public {
        _setCore(address(vault), 10_000e6, 0, 0);
        _setPosition(address(vault), 10_000, 5);
        _setAsset(10_000, 0, 1_000_000);
        vm.prank(manager);
        vm.expectRevert(E.UnsupportedAsset.selector);
        vault.flatten(10_000, 0);
        uint256 n = writer.count();
        vm.prank(manager);
        vault.flatten(BTC, 0); // no position
        assertEq(writer.count(), n, "nothing sent");
        _setPosition(address(vault), BTC, 1); // the smallest long
        vm.prank(manager);
        vault.flatten(BTC, 0);
        assertEq(writer.count(), n + 1);
        (, uint24 id, bytes memory body) = _decode(writer.last());
        assertEq(id, 1);
        (, bool isBuy,, uint64 sz, bool ro, uint8 tif, uint128 cloid) =
            abi.decode(body, (uint32, bool, uint64, uint64, bool, uint8, uint128));
        assertFalse(isBuy);
        assertEq(sz, 1e3, "1 unit at szDecimals 5");
        assertTrue(ro);
        assertEq(tif, 3);
        assertEq(cloid, 0);
    }

    /// Mutant: cancelOrder's `HyperCore.cancelByOid` deleted.
    function test_HLR2_M40_kills_cancelOrderAction() public {
        vm.prank(manager);
        vault.cancelOrder(ETH, 77);
        (, uint24 id, bytes memory body) = _decode(writer.last());
        assertEq(id, 10);
        (uint32 a, uint64 oid) = abi.decode(body, (uint32, uint64));
        assertEq(a, ETH);
        assertEq(oid, 77);
    }

    /// Mutants: `_storeAgent` zero-address guard deleted / `address(1)`, `_revokeAgent` early return deleted /
    /// `address(1)`. A zero agent cannot be set; revoking with no agent sends nothing.
    function test_HLR2_M41_kills_agentSlotGuards() public {
        vm.prank(owner);
        vault.queue(abi.encodeCall(HyperVault.setAgent, (address(0))));
        // hl-r2 H01 (integrated): the stored eta (an epoch + EXIT_MARGIN), not timelockDelay
        vm.warp(vault.queuedEta(keccak256(abi.encodeCall(HyperVault.setAgent, (address(0))))));
        vm.expectRevert(abi.encodeWithSelector(E.CallFailed.selector, abi.encodeWithSelector(E.ZeroAddress.selector)));
        vault.execute(abi.encodeCall(HyperVault.setAgent, (address(0))));
        uint256 n = writer.count();
        vm.prank(guardian);
        vault.revokeAgent();
        // WP5-D14: with no agent stored the revoke does nothing (the HLR2-A01 burn re-send is removed with action 9)
        assertEq(writer.count(), n, "no agent: nothing is sent");
        _setAgent(vault, address(1)); // address(1) is just an address
        assertEq(vault.agent(), address(1));
        n = writer.count();
        vm.prank(guardian);
        vault.revokeAgent();
        assertEq(writer.count(), n, "WP5-D14: the revoke sends nothing to HyperCore");
        assertEq(vault.agent(), address(0));
    }

    /// Mutants: the reentrancy lock (`if (lock == 1) revert`, `lock = 1`) deleted / set to 0. With a hostile asset
    /// (only possible on a standalone vault) a nested requestDeposit is refused.
    function test_HLR2_M42_kills_reentrancyLock() public {
        ReentrantUSDC t = new ReentrantUSDC();
        InitParams memory p = _standaloneParams(policy);
        p.asset = IERC20(address(t));
        HyperVault v = HyperVault(Clones.clone(address(vaultImpl)));
        v.initialize(p);
        t.mint(alice, 100e6);
        vm.prank(alice);
        t.approve(address(v), type(uint256).max);
        t.arm(v);
        vm.prank(alice);
        vm.expectRevert(E.Reentrancy.selector);
        v.requestDeposit(10e6, alice);
    }

    /// Mutant: fundCoreGas `if (!ok) revert CallFailed(ret)` deleted: a failed HYPE send must not pass silently.
    function test_HLR2_M43_kills_fundCoreGasFailure() public {
        RevertingSink sink = new RevertingSink();
        vm.etch(HyperCore.HYPE_SYSTEM_ADDRESS, address(sink).code);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        vault.fundCoreGas{value: 0.1 ether}();
        assertEq(address(vault).balance, 0);
    }

    /// Mutant: `_accrueFees` `performanceFeeBps > 0` -> `> 1`: a 1 bps performance fee is charged.
    function test_HLR2_M44_kills_oneBpsPerformanceFee() public {
        vm.prank(owner);
        vault.lowerFees(0, 1);
        _holder();
        usdc.mint(address(vault), 100e6); // +10%
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _settle();
        assertGt(vault.balanceOf(feeRecipient), 0, "1 bps of the gain");
    }
}
