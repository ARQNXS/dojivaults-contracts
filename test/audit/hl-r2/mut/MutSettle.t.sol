// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {MutBase} from "./MutBase.t.sol";
import {HyperVault} from "../../../../src/HyperVault.sol";
import {VaultPolicy} from "../../../../src/VaultPolicy.sol";

/// @title hl-r2 mutation kill tests on settle() and claims
contract HLR2MutSettleTest is MutBase {
    /// @dev A standalone vault whose policy allows a 100% NAV move per checkpoint (the creator's choice, valid).
    function _wideVault() internal {
        VaultPolicy.RiskConfig memory r = _defaultRisk();
        r.maxNavMoveBps = 10_000;
        uint32[] memory assets = new uint32[](0);
        policy = VaultPolicy(Clones.clone(address(policyImpl)));
        policy.initialize(owner, r, assets, 2 days, address(0));
        vault = HyperVault(Clones.clone(address(vaultImpl)));
        vault.initialize(_standaloneParams(policy));
        _setCoreUser(address(vault), true);
        _setCore(address(vault), 0, 0, 0);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    /// Past fix N-11 reverted: VaultLogic.settle `if (depShares == 0) depIn = 0;` deleted. No test reached a
    /// deposit that mints zero shares, so the fix had no regression test and the revert survived the whole suite.
    /// A deposit too small for one share unit must be refunded, not absorbed by the incumbents (the claim would
    /// otherwise draw the refund from the reserve of other users, clamped to what is there).
    function test_HLR2_M12_kills_zeroShareDepositSwallowed() public {
        _wideVault();
        _deposit(alice, 10e6);
        _settle();
        _claim(alice);
        // alice exits all but 1e6 share units (one millionth of a share): NAV ~2 wei
        _redeem(alice, vault.balanceOf(alice) - 1e6);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _settle();
        _claim(alice);
        // the remaining unit's value grows (PnL, here idle USDC) and the checkpoint ratchets after it, 100% per hour
        uint256 nav = vault.totalAssets();
        while (nav < 1_000_000_000e6) {
            usdc.mint(address(vault), nav);
            nav = vault.totalAssets();
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            vault.checkRisk();
        }
        // bob's 10 USDC are worth less than one share unit now
        _deposit(bob, 10e6);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _settle();
        (uint256 depAssets, uint256 depShares,,,,,,) = vault.epochs(vault.currentEpoch() - 1);
        assertEq(depAssets, 10e6);
        assertEq(depShares, 0, "nothing to mint");
        assertGe(vault.claimableRedeemAssets(), 10e6, "the deposit is reserved as a refund");
        uint256 before = usdc.balanceOf(bob);
        _claim(bob);
        assertEq(usdc.balanceOf(bob) - before, 10e6, "refunded in full");
        assertEq(vault.balanceOf(bob), 0);
    }

    function _paid() internal view returns (uint256 paid, uint256 redShares, uint256 burned) {
        (,, redShares, paid, burned,,,) = vault.epochs(vault.currentEpoch() - 1);
    }

    /// Mutants: VaultLogic.settle exit-only pricing `if (checkpointNav > 0 && checkpointNav < nav) priceNav =
    /// checkpointNav` deleted / negated / `&&` -> `||`. In emergency a NAV pushed above the last checkpoint must
    /// not be paid out: redemptions price at min(NAV, checkpoint). No earlier test had live NAV above the checkpoint
    /// in an exit-only settle.
    function test_HLR2_M18_kills_exitOnlyPaysAboveTheCheckpoint() public {
        _settled10k();
        _redeem(alice, vault.balanceOf(alice) / 2);
        vm.prank(guardian);
        vault.triggerEmergency();
        usdc.mint(address(vault), 1_000e6); // NAV 11,000 vs checkpoint 10,000
        vm.prank(guardian);
        vault.settle();
        (uint256 paid,,) = _paid();
        assertApproxEqAbs(paid, 5_000e6, 1e6, "paid at the checkpoint, not at the pushed NAV");
    }

    /// Same line, the other side: NAV below the checkpoint pays at NAV (`<` -> `>=`, `&&` -> `||` pay the
    /// higher checkpoint).
    function test_HLR2_M19_kills_exitOnlyPaysTheHigherCheckpoint() public {
        _settled10k();
        _setCore(address(vault), 1_000e6, 0, 0); // +1,000 of PnL, ratcheted into the checkpoint
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vault.checkRisk();
        assertEq(vault.checkpointNav(), 11_000e6);
        _redeem(alice, vault.balanceOf(alice) / 2);
        vm.prank(guardian);
        vault.triggerEmergency();
        _setCore(address(vault), 0, 0, 0); // the PnL is gone: NAV 10,000 < checkpoint 11,000
        vm.prank(guardian);
        vault.settle();
        (uint256 paid,,) = _paid();
        assertApproxEqAbs(paid, 5_000e6, 1e6, "paid at NAV, the lower of the two");
    }

    /// Mutants: VaultLogic.settle redemption-only pricing `if (redemptionOnly && cp > 0 && cp < nav)` with an
    /// `&&` -> `||`: a NORMAL settle would then pay redemptions at the previous checkpoint instead of the live NAV,
    /// shorting every redeemer of an epoch with gains.
    function test_HLR2_M20_kills_normalSettlePaysAtTheOldCheckpoint() public {
        _settled10k();
        _redeem(alice, vault.balanceOf(alice) / 2);
        usdc.mint(address(vault), 1_000e6); // +10% within the 20% bound
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.prank(manager);
        vault.settle(); // no checkRisk first: the checkpoint is still 10,000
        (uint256 paid,,) = _paid();
        assertGt(paid, 5_350e6, "paid at the live NAV (less the performance fee)");
    }

    /// Mutant: VaultLogic.settle partial fill `burned = redShares.mulDiv(paid, redAssets, Floor)` -> Ceil. The vault
    /// must never burn more shares than the payout covers (audit V-01 rounding direction); the earlier fuzz test
    /// allowed a tolerance of one share unit and missed it.
    function test_HLR2_M21_kills_partialFillOverBurn() public {
        _settled10k();
        _redeem(alice, vault.balanceOf(alice) / 3); // 3,333.33 USDC owed
        // the idle USDC is moved to Core except 1,234.567891: a partial fill
        vm.prank(manager);
        vault.bridgeToCore(10_000e6 - 1_234_567_891);
        _setCore(address(vault), int64(uint64(10_000e6 - 1_234_567_891)), 0, 0);
        _skipBridgeWindow();
        vm.prank(guardian);
        vault.triggerEmergency();
        vm.prank(guardian);
        vault.settle();
        (uint256 paid, uint256 red, uint256 burned) = _paid();
        assertEq(paid, 1_234_567_891);
        uint256 redAssets = (red * (10_000e6 + 1)) / (vault.totalSupply() + burned + 1e6);
        assertLe(burned * redAssets, red * paid, "never over-burn");
        assertEq(burned, (red * paid) / redAssets, "burned rounds down");
    }

    function _settled10k() internal {
        _deposit(alice, 10_000e6);
        _settle();
        _claim(alice);
    }

    /// Mutants: VaultMath.emergencyFillBps (every operator on its lines survived: the view had no numeric test).
    /// It must predict the exit-only fill: liquidity on hand against the redemptions priced at min(NAV, checkpoint),
    /// rounded down, 10_000 when nothing is pending or the payout is covered.
    function test_HLR2_M48_kills_emergencyFillBps() public {
        _settled10k();
        assertEq(vault.emergencyFillBps(), 10_000, "nothing pending");
        _redeem(alice, vault.balanceOf(alice) / 2); // ~5,000 owed
        assertEq(vault.emergencyFillBps(), 10_000, "covered by the idle USDC");
        vm.prank(manager);
        vault.bridgeToCore(10_000e6 - 1_234_567_891); // leave 1,234.567891 idle
        _setCore(address(vault), int64(uint64(10_000e6 - 1_234_567_891)), 0, 0);
        _skipBridgeWindow();
        usdc.mint(address(vault), 0); // no change
        uint256 owed = (vault.pendingRedeemShares() * (10_000e6 + 1)) / (vault.totalSupply() + 1e6);
        uint256 expect = (1_234_567_891 * 10_000) / owed;
        assertEq(vault.emergencyFillBps(), expect, "floor(idle / owed)");
        // a NAV pushed above the checkpoint is not counted
        _setCore(address(vault), int64(uint64(10_000e6 - 1_234_567_891 + 2_000e6)), 0, 0);
        assertEq(vault.emergencyFillBps(), expect, "priced at the checkpoint");
        // and the settle fills exactly that
        vm.prank(guardian);
        vault.triggerEmergency();
        vm.prank(guardian);
        vault.settle();
        (uint256 paid,,) = _paid();
        assertEq((paid * 10_000) / owed, expect);
    }
}
