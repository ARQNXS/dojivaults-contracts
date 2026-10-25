// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GovBase} from "./GovBase.t.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {GainsVaultPolicy} from "../../../../src/gains/GainsVaultPolicy.sol";

/// @notice ACCESS-MATRIX.md section 3 (GainsVaultPolicy, who), proven cell by cell on a factory-created policy.
///         Actors: the policy owner (= the vault owner at creation), the vault, and every other role as "anyone"
///         (stranger, depositor, manager, agent, operator, sentinel, guardian, the factory contract, the factory owner).
contract GovPolicyMatrixTest is GovBase {
    address[] internal others;

    function setUp() public override {
        super.setUp();
        others.push(stranger);
        others.push(alice);
        others.push(fvManager);
        others.push(agentA);
        others.push(keeper);
        others.push(platformSentinel);
        others.push(platformGuardian);
        others.push(address(platform));
        others.push(platformOwner);
        others.push(address(fv)); // the vault itself is "anyone" for the owner-only functions
    }

    function _tighter() internal pure returns (GainsVaultPolicy.RiskConfig memory c) {
        c = _defaultRisk();
        c.maxLeverageBps = 20_000;
    }

    function _looser() internal pure returns (GainsVaultPolicy.RiskConfig memory c) {
        c = _defaultRisk();
        c.maxLeverageBps = 40_000;
    }

    // ------------------------------------------------------------------ initialize
    function test_GOV_PM_initialize_nobodyAfterCreate_implNever() public {
        uint32[] memory a = new uint32[](1);
        a[0] = BTC;
        for (uint256 i; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(Initializable.InvalidInitialization.selector);
            fp.initialize(others[i], _defaultRisk(), a, 1 days, address(platform), others[i]);
        }
        vm.prank(fvOwner);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        fp.initialize(fvOwner, _defaultRisk(), a, 1 days, address(platform), address(fv));
        vm.prank(address(platform));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        policyImpl.initialize(fvOwner, _defaultRisk(), a, 1 days, address(platform), address(fv));
        assertEq(fp.vault(), address(fv), "policy bound to its vault");
        assertEq(fp.owner(), fvOwner, "policy owner = vault owner at creation");
    }

    // ------------------------------------------------------------------ owner-only
    function test_GOV_PM_ownerOnlyFunctions() public {
        for (uint256 i; i < others.length; ++i) {
            address a = others[i];
            bytes memory err = abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, a);
            vm.startPrank(a);
            vm.expectRevert(err);
            fp.proposeConfig(_tighter());
            vm.expectRevert(err);
            fp.cancelPendingConfig();
            vm.expectRevert(err);
            fp.disallowAsset(BTC);
            vm.expectRevert(err);
            fp.queueAllowAsset(SOL);
            vm.expectRevert(err);
            fp.proposeTimelockDelay(3 days);
            // GR1-12 / GR1-30: the policy's own ownership functions revert for everyone
            vm.expectRevert(GainsVaultPolicy.OwnershipFollowsVault.selector);
            fp.transferOwnership(a);
            vm.expectRevert(GainsVaultPolicy.OwnershipFollowsVault.selector);
            fp.renounceOwnership();
            vm.stopPrank();
        }
        // the owner: each one succeeds
        vm.startPrank(fvOwner);
        fp.proposeConfig(_looser());
        assertTrue(fp.pendingConfig().exists);
        fp.cancelPendingConfig();
        assertFalse(fp.pendingConfig().exists);
        fp.proposeConfig(_tighter());
        assertEq(fp.maxLeverageBps(), 20_000);
        fp.disallowAsset(BTC);
        assertFalse(fp.isAssetAllowed(BTC));
        fp.queueAllowAsset(SOL);
        assertGt(fp.assetAllowEta(SOL), 0);
        fp.proposeTimelockDelay(3 days);
        assertEq(fp.timelockDelay(), 3 days);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ anyone after eta, within the grace
    function test_GOV_PM_appliersAreAnyoneInTheWindow() public {
        vm.startPrank(fvOwner);
        fp.proposeConfig(_looser());
        fp.queueAllowAsset(SOL);
        fp.proposeTimelockDelay(1 days);
        vm.stopPrank();
        uint256 eta = uint256(fp.pendingConfig().eta); // hl-r2 exit-before-effect: wait for the stored eta
        assertEq(fp.assetAllowEta(SOL), eta, "allowAsset waits as long");

        address[] memory all = new address[](others.length + 1);
        for (uint256 i; i < others.length; ++i) {
            all[i] = others[i];
        }
        all[others.length] = fvOwner;

        for (uint256 i; i < all.length; ++i) {
            uint256 snap = vm.snapshotState();
            vm.startPrank(all[i]);
            vm.expectRevert(GainsVaultPolicy.NotReady.selector);
            fp.applyPendingConfig();
            vm.expectRevert(GainsVaultPolicy.NotReady.selector);
            fp.allowAsset(SOL);
            vm.expectRevert(GainsVaultPolicy.NotReady.selector);
            fp.applyTimelockDelay();
            vm.stopPrank();
            // at eta: everyone may apply
            _warp(eta);
            vm.startPrank(all[i]);
            fp.applyPendingConfig();
            fp.allowAsset(SOL);
            fp.applyTimelockDelay();
            vm.stopPrank();
            assertEq(fp.maxLeverageBps(), 40_000);
            assertTrue(fp.isAssetAllowed(SOL));
            assertEq(fp.timelockDelay(), 1 days);
            vm.revertToState(snap);
            // after eta + 14 days: expired for everyone
            snap = vm.snapshotState();
            _warp(eta + 14 days + 1);
            vm.startPrank(all[i]);
            vm.expectRevert(GainsVaultPolicy.Expired.selector);
            fp.applyPendingConfig();
            vm.expectRevert(GainsVaultPolicy.Expired.selector);
            fp.allowAsset(SOL);
            vm.expectRevert(GainsVaultPolicy.Expired.selector);
            fp.applyTimelockDelay();
            vm.stopPrank();
            vm.revertToState(snap);
        }
        // last second of the window still works
        _warp(eta + 14 days);
        fp.applyPendingConfig();
    }

    // ------------------------------------------------------------------ setPairFeed: the vault only
    function test_GOV_PM_setPairFeed_vaultOnly() public {
        (address f, uint32 maxAge, uint16 band) = (address(ethFeed), BTC_MAX_AGE, uint16(20));
        address[] memory nope = new address[](others.length);
        for (uint256 i; i < others.length - 1; ++i) {
            nope[i] = others[i];
        }
        nope[others.length - 1] = fvOwner;
        for (uint256 i; i < nope.length; ++i) {
            vm.prank(nope[i]);
            vm.expectRevert(GainsVaultPolicy.NotVault.selector);
            fp.setPairFeed(ETH, f, maxAge, band);
        }
        // another factory vault (not this policy's) is "anyone" too
        vm.prank(address(vault));
        vm.expectRevert(GainsVaultPolicy.NotVault.selector);
        fp.setPairFeed(ETH, f, maxAge, band);
        vm.prank(address(fv));
        fp.setPairFeed(ETH, f, maxAge, band);
    }

    // ------------------------------------------------------------------ setSequencerFeed: the vault only (GR1-10)
    function test_GOV_PM_setSequencerFeed_vaultOnly() public {
        address[] memory nope = new address[](others.length);
        for (uint256 i; i < others.length - 1; ++i) {
            nope[i] = others[i];
        }
        nope[others.length - 1] = fvOwner;
        for (uint256 i; i < nope.length; ++i) {
            vm.prank(nope[i]);
            vm.expectRevert(GainsVaultPolicy.NotVault.selector);
            fp.setSequencerFeed(makeAddr("seq2"), 7_200);
        }
        vm.prank(address(vault));
        vm.expectRevert(GainsVaultPolicy.NotVault.selector);
        fp.setSequencerFeed(makeAddr("seq2"), 7_200);
        address seq2 = makeAddr("seq2");
        vm.prank(address(fv));
        fp.setSequencerFeed(seq2, 7_200);
        assertEq(fp.sequencerFeed(), seq2, "sets the feed queued through the vault (GV-03)");
        assertEq(fp.sequencerGracePeriod(), 7_200);
    }

    // ------------------------------------------------------------------ ownership: the vault's owner (GR1-12 / GR1-30)
    /// Was test_GOV_PM_ownershipTwoStepAndRenounceAllowed (the policy had its own two-step ownership and renounce).
    /// Now owner() reads the vault's owner, and transfer / accept / renounce revert OwnershipFollowsVault for everyone.
    function test_GOV_PM_ownershipFollowsTheVault_noTransferNoRenounce() public {
        address next = makeAddr("nextOwner");
        address[] memory all = new address[](others.length + 2);
        for (uint256 i; i < others.length; ++i) {
            all[i] = others[i];
        }
        all[others.length] = fvOwner;
        all[others.length + 1] = next;
        for (uint256 i; i < all.length; ++i) {
            vm.startPrank(all[i]);
            vm.expectRevert(GainsVaultPolicy.OwnershipFollowsVault.selector);
            fp.transferOwnership(next);
            vm.expectRevert(GainsVaultPolicy.OwnershipFollowsVault.selector);
            fp.acceptOwnership();
            vm.expectRevert(GainsVaultPolicy.OwnershipFollowsVault.selector);
            fp.renounceOwnership();
            vm.stopPrank();
        }
        assertEq(fp.owner(), fvOwner);
        // a vault transfer moves it (after accept)
        vm.prank(fvOwner);
        fv.transferOwnership(next);
        assertEq(fp.owner(), fvOwner, "two step on the vault");
        vm.prank(next);
        fv.acceptOwnership();
        assertEq(fp.owner(), next);
        vm.prank(fvOwner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, fvOwner));
        fp.proposeConfig(_tighter());
        vm.prank(next);
        fp.proposeConfig(_tighter());
        assertEq(fp.maxLeverageBps(), 20_000);
    }
}
