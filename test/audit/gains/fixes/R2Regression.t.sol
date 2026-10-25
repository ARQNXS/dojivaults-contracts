// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {R2Base} from "./R2Base.sol";
import {GainsVault} from "../../../../src/gains/GainsVault.sol";
import {GainsVaultFactory} from "../../../../src/gains/GainsVaultFactory.sol";
import {GainsVaultPolicy} from "../../../../src/gains/GainsVaultPolicy.sol";
import {GainsPrice} from "../../../../src/gains/GainsPrice.sol";
import {IGainsDiamond, GTrade} from "../../../../src/gains/IGainsDiamond.sol";
import {GainsNav} from "../../../../src/gains/GainsNav.sol";
import {IGainsVaultErrors, OpenParams} from "../../../../src/gains/GainsTypes.sol";
import {MockChainlinkFeed} from "../../../gains/mocks/GainsMocks.sol";

/// @dev A Trade layout with a field INSERTED before positionSizeToken (VERIFY-R1 GV-01's PoC layout).
struct TradeMid {
    address user;
    uint32 index;
    uint16 pairIndex;
    uint24 leverage;
    bool long;
    bool isOpen;
    uint8 collateralIndex;
    uint8 tradeType;
    uint120 collateralAmount;
    uint64 openPrice;
    uint64 tp;
    uint64 sl;
    bool isCounterTrade;
    uint8 inserted;
    uint160 positionSizeToken;
    uint24 __placeholder;
}

/// @notice Fix round 2 (contracts/audit/gains/FIXES-R1.md section 5, round 2): the findings of the verification pass
///         VERIFY-R1 (GV-01, GV-02, GV-03), each as the PoC of that pass with the fixed behaviour asserted.
contract R2RegressionTest is R2Base {
    // ==================================================================
    // GV-01: a field inserted before positionSizeToken is caught, not misread. GR2-LIVE-01 (fix round WP2): the three
    // GV-01 tests and GV-02's known non-holding types test injected malformed getTrades / getPendingOrders output,
    // which the vault no longer calls. They are ported to the per-index reads in r2/xrfixes/XRLive01Ports.t.sol
    // (test_PORT_GV01_*, test_PORT_GV02_*), which also uses TradeMid above.
    // ==================================================================

    // ==================================================================
    // GV-02: an unknown pending-order type holds settle (fail closed) and counts in NAV
    // ==================================================================
    /// @notice VERIFY-R1's PoC: a 15k open in flight reported with type 10 let settle run at a NAV 15k short and bob,
    ///         redeeming half the vault, was paid about 42.5k. Now the unknown type holds settle like a known open and
    ///         its collateral is in NAV.
    function test_GV02_unknownOrderType_blocksSettleAndCountsInNav() public {
        _seed(vault, alice, 50_000e6);
        _seed(vault, bob, 50_000e6);
        _request(vault, ETH, true, 15_000e6, 2_000); // holds 15k on the diamond
        uint256 navKnown = vault.venue().value;
        _redeem(bob, vault.balanceOf(bob));

        IGainsDiamond.PendingOrder[] memory o = diamond.getPendingOrders(address(vault));
        for (uint8 k = 10; k <= 13; ++k) {
            o[0].orderType = k == 13 ? 200 : k; // 10, 11 (PNL_WITHDRAWAL, never created here), 12, and a far future type
            vm.mockCall(address(diamond), abi.encodeCall(IGainsDiamond.getPendingOrders, (address(vault))), abi.encode(o));
            assertTrue(vault.ordersPending(), "unknown type: settle waits");
            assertEq(vault.venue().value, navKnown, "and its collateral is in NAV like a known open");
            assertEq(vault.venue().blocking, 1);
            vm.prank(manager);
            vm.expectRevert(IGainsVaultErrors.OrdersPending.selector);
            vault.settle();
        }
    }

    // ==================================================================
    // GV-03: the sequencer rotation is snapshotted when queued; the grace period is bounded
    // ==================================================================
    /// @notice VERIFY-R1's V10a: the cold factory owner changed the factory between the queue and the execution and
    ///         the vault adopted a 365-day grace. Now the queue carries the feed and grace (the factory's at queue
    ///         time); a later factory change is not adopted, and a 365-day grace cannot be set at all.
    function test_GV03_rotationAdoptsWhatWasQueued_notTheFactoryAtExecution() public {
        GainsVaultPolicy p = GainsVaultPolicy(address(vault.policy()));
        MockChainlinkFeed seq2 = new MockChainlinkFeed(0, 0);
        seq2.setStatus(0, vm.getBlockTimestamp() - 30 days);
        MockChainlinkFeed seq3 = new MockChainlinkFeed(0, 0);
        seq3.setStatus(0, vm.getBlockTimestamp() - 1 hours);
        vm.prank(platformOwner);
        platform.setSequencerFeed(address(seq2), 7_200);

        // only the factory's current values can be queued
        vm.prank(owner);
        vm.expectRevert(GainsPrice.SequencerFeedNotCurrent.selector);
        vault.queue(abi.encodeCall(GainsVault.setSequencerFeed, (address(seq3), 7_200)));
        vm.prank(owner);
        vm.expectRevert(GainsPrice.SequencerFeedNotCurrent.selector);
        vault.queue(abi.encodeCall(GainsVault.setSequencerFeed, (address(seq2), 1 days)));
        bytes memory d = abi.encodeCall(GainsVault.setSequencerFeed, (address(seq2), 7_200));
        vm.prank(owner);
        vault.queue(d);

        // the factory owner changes the factory before the execution
        vm.prank(platformOwner);
        platform.setSequencerFeed(address(seq3), 1 days);
        vm.warp(vault.queuedEta(keccak256(d)) + 1); // hl-r2 exit-before-effect: wait for the stored eta
        vault.execute(d);
        assertEq(p.sequencerFeed(), address(seq2), "what was queued");
        assertEq(p.sequencerGracePeriod(), 7_200);
    }

    function test_GV03_graceBounded_factoryConstructorAndSetter() public {
        vm.startPrank(platformOwner);
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.SequencerGraceOutOfRange.selector, 365 days));
        platform.setSequencerFeed(address(sequencer), 365 days);
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.SequencerGraceOutOfRange.selector, 1 hours - 1));
        platform.setSequencerFeed(address(sequencer), 1 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.SequencerGraceOutOfRange.selector, 1 days + 1));
        platform.setSequencerFeed(address(sequencer), 1 days + 1);
        platform.setSequencerFeed(address(sequencer), 1 hours);
        platform.setSequencerFeed(address(sequencer), 1 days);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.SequencerGraceOutOfRange.selector, 0));
        new GainsVaultFactory(
            platformOwner, address(vaultImpl), address(policyImpl), usdc, IGainsDiamond(address(diamond)), address(sequencer), 0, makeAddr("pfr"), makeAddr("g"), makeAddr("s")
        );
    }

    /// @notice The policy bounds the grace too (defence in depth: only the vault can call it).
    function test_GV03_policySetterBoundsGrace() public {
        GainsVaultPolicy p = GainsVaultPolicy(address(vault.policy()));
        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.SequencerGraceOutOfRange.selector, 365 days));
        p.setSequencerFeed(address(sequencer), 365 days);
    }
}
