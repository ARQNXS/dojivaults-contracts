// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GainsRound4Base} from "../../../gains/GainsRound4.t.sol";
import {GainsVault} from "../../../../src/gains/GainsVault.sol";
import {GainsVaultFactory} from "../../../../src/gains/GainsVaultFactory.sol";
import {GainsVaultPolicy} from "../../../../src/gains/GainsVaultPolicy.sol";
import {IGainsDiamond} from "../../../../src/gains/IGainsDiamond.sol";
import {IGainsVaultErrors as E, OpenParams} from "../../../../src/gains/GainsTypes.sol";
import {BreachReason} from "../../../../src/VaultTypes.sol";
import {MockChainlinkFeed} from "../../../gains/mocks/GainsMocks.sol";

/// @notice Fix round 1 (contracts/audit/gains/FIXES-R1.md): regression tests for fixes whose ROUND1 evidence was a
///         fork test or a scenario, plus the three tests the surviving mutants of tools/MUTATION.md pointed to. Each
///         fails on the old code (the reverted-check results are in FIXES-R1.md).
contract R1RegressionTest is GainsRound4Base {
    // ==================================================================
    // GR1-03: the near-liquidation zero rule counts the band once
    // ==================================================================
    /// @dev A 100x ETH long alone on the venue; the mock liquidates at 90% of the collateral lost (L = open x 0.991).
    function _longAt100x() internal returns (uint32 idx, uint256 liq) {
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
        idx = _open(vault, ETH, true, 1_000e6, 100_000);
        IGainsDiamond.Trade memory t = diamond.getTrade(address(vault), idx);
        liq = uint256(t.openPrice) - (uint256(t.openPrice) * 90 * 1e3) / (100 * 100_000);
    }

    /// @notice The valuation price C(1 - B) just above L (within L(1 + B)): the old rule zeroed it although the trade
    ///         is not at its liquidation price; it is now valued at what Gains would pay.
    function test_GR1_03_tradeAboveItsLiquidationPriceIsValued() public {
        (uint32 idx, uint256 liq) = _longAt100x();
        uint256 p = liq * 10_010 / 10_000; // P = L x 1.001 (inside the old L x (1 + B) zone)
        _setPrice(ETH, uint64((p * 10_000) / (10_000 - 20)) + 100); // C such that C(1 - B) = P (8-decimal rounding up)
        uint256 v = vault.venue().value;
        assertGt(v, 0, "valued: P is above L");
        uint64 valuationPx = uint64((uint256(_px(ETH)) * (10_000 - 20)) / 10_000);
        assertApproxEqAbs(v, diamond.closeValue(address(vault), idx, valuationPx), 1, "exactly what Gains pays at P");
    }

    /// @notice A trade whose valuation price is at or past L is still worth 0 (C within the band of L).
    function test_GR1_03_tradeWithinTheBandOfLiquidationIsZero() public {
        (, uint256 liq) = _longAt100x();
        _setPrice(ETH, uint64((liq * 10_000) / (10_000 - 10))); // C = L / (1 - B/2): C > L, but C(1 - B) < L
        assertGt(_px(ETH), liq, "the mid is still above L");
        assertEq(vault.venue().value, 0, "valued at 0: the adverse edge is past L");
    }

    // ==================================================================
    // GR1-08: Gains' trade list in a layout the vault cannot decode
    // ==================================================================
    /// @notice The exit keeps working when the list read fails: flattenIndices decodes nothing.
    function test_GR1_08_flattenIndicesWorksWhenTheTradeListIsUnreadable() public {
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
        uint32 a = _open(vault, ETH, true, 10_000e6, 2_000);
        uint32 b = _open(vault, ETH, false, 10_000e6, 2_000);
        // a layout the vault refuses: an odd number of trailing bytes (fix round WP2: in a trade's own getTrade, which
        // the vault reads per index since GR2-LIVE-01, not in getTrades)
        vm.mockCall(address(diamond), abi.encodeCall(IGainsDiamond.getTrade, (address(vault), a)), abi.encodePacked(new bytes(65)));
        vm.prank(guardian);
        vm.expectRevert(E.DiamondLayoutChanged.selector);
        vault.flatten(ETH, 0, _px(ETH), type(uint256).max);

        uint32[] memory ix = new uint32[](3);
        ix[0] = a;
        ix[1] = b;
        ix[2] = 99; // not a trade: skipped, does not block the others
        vm.prank(guardian);
        uint256 sent = vault.flattenIndices(ix, 0, _px(ETH));
        assertEq(sent, 2, "both trades close");
        vm.clearMockedCalls();
        assertEq(vault.venue().pending, 2);
    }

    /// @notice Only the listed roles may use flattenIndices, as for flatten.
    function test_GR1_08_flattenIndicesSameCallersAsFlatten() public {
        uint32[] memory ix = new uint32[](1);
        vm.prank(stranger);
        vm.expectRevert(E.Unauthorized.selector);
        vault.flattenIndices(ix, 0, _px(ETH));
        vm.prank(guardian);
        vm.expectRevert(E.Unauthorized.selector); // a custom slippage is the guardian's only in emergency
        vault.flattenIndices(ix, 100, _px(ETH));
    }

    // ==================================================================
    // GR1-10 and the Slither item: the sequencer feed is never zero and can be rotated
    // ==================================================================
    function test_GR1_10_factoryRefusesAZeroSequencerFeed() public {
        vm.expectRevert(GainsVaultFactory.ZeroAddress.selector);
        new GainsVaultFactory(
            platformOwner,
            address(vaultImpl),
            address(policyImpl),
            IERC20(address(usdc)),
            IGainsDiamond(address(diamond)),
            address(0),
            SEQ_GRACE,
            protocolTreasury,
            platformGuardian,
            platformSentinel
        );
    }

    function test_GR1_10_sequencerFeedRotatesThroughTheTimelock() public {
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
        _open(vault, ETH, true, 10_000e6, 2_000);
        sequencer.setReverts(true); // the uptime feed dies: every priced path is SequencerDown
        vm.expectRevert(E.SequencerDown.selector);
        vault.totalAssets();

        MockChainlinkFeed seq2 = new MockChainlinkFeed(0, 0);
        seq2.setStatus(0, vm.getBlockTimestamp() - 30 days);
        vm.prank(stranger);
        vm.expectRevert(); // only the factory owner
        platform.setSequencerFeed(address(seq2), SEQ_GRACE);
        vm.prank(platformOwner);
        platform.setSequencerFeed(address(seq2), SEQ_GRACE);
        vm.expectRevert(GainsVaultPolicy.NotVault.selector);
        policy.setSequencerFeed(address(seq2), SEQ_GRACE); // only the vault, through its owner's timelock
        _timelocked(vault, abi.encodeCall(GainsVault.setSequencerFeed, (address(seq2), SEQ_GRACE)));
        assertEq(policy.sequencerFeed(), address(seq2));
        assertGt(vault.totalAssets(), 0, "priced again");
    }

    // ==================================================================
    // Earlier bug: pairMinPositionSizeUsd is Gains' fee basis, not a size floor
    // ==================================================================
    function test_policyDoesNotEnforcePairMinPositionSize() public {
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
        // 100 USDC x 2 = 200 USD of size, below the mock's pairMinPositionSizeUsd (285.7 USD); Gains' own minimum is
        // 5 x the min fee = 0.5 USDC of collateral
        _open(vault, ETH, true, 100e6, 2_000);
        assertEq(vault.venue().orders, 1, "opened");
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(E.OrderRejected.selector, "collateral below min"));
        vault.openTrade(_params(ETH, true, 0.4e6, 2_000)); // below Gains' own minimum (5 x min fee): refused
    }

    // ==================================================================
    // Tests the surviving mutants pointed to (tools/MUTATION.md)
    // ==================================================================
    /// @notice GainsVaultLogic#952 (settle `carryOrigin = 0` -> `= 1`): two separate carry runs, each priced in its
    ///         own epoch, each depositor claims the shares of its own run.
    function test_MUT952_twoSeparateCarryRunsEachPricedInItsOwnEpoch() public {
        _fund(100_000e6);
        address d1 = makeAddr("depositor1");
        address d2 = makeAddr("depositor2");
        usdc.mint(d1, 100_000e6);
        usdc.mint(d2, 100_000e6);
        vm.prank(d1);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(d2);
        usdc.approve(address(vault), type(uint256).max);

        // run 1: d1's deposit is carried by a redemption-only settle, then priced after the resume
        vm.prank(d1);
        vault.requestDeposit(10_000e6, d1);
        _drawdown(80_000e6);
        vm.prank(manager);
        vault.settle();
        uint256 run1 = vault.currentEpoch() - 1;
        (uint256 cf1,) = vault.carry(run1);
        assertEq(cf1, run1 + 1, "run 1 starts at its own epoch");
        _recover(100_000e6);
        vm.prank(manager);
        vault.settle();
        vault.claim(d1);
        uint256 d1Shares = vault.balanceOf(d1);
        assertGt(d1Shares, 0, "run 1 priced");

        // run 2: a new carry run must start at its own epoch, not reuse run 1's origin
        vm.prank(d2);
        vault.requestDeposit(10_000e6, d2);
        _drawdown(80_000e6); // (80k + d1's 10k idle) / 110k: -18%
        vm.prank(manager);
        vault.settle();
        uint256 run2 = vault.currentEpoch() - 1;
        (uint256 cf2, uint256 pi2) = vault.carry(run2);
        assertEq(cf2, run2 + 1, "run 2 starts at its own epoch");
        assertEq(pi2, 0, "and is not priced yet");
        vm.expectRevert(E.RequestNotSettled.selector);
        vault.claim(d2); // nothing to deliver while carried
        _recover(100_000e6);
        vm.prank(manager);
        vault.settle();
        vault.claim(d2);
        assertGt(vault.balanceOf(d2), 0, "run 2 priced in its own epoch");
        assertApproxEqRel(vault.convertToAssets(vault.balanceOf(d2)), 10_000e6, 0.01e18, "at the recovered NAV");
    }

    function _drawdown(uint256 navAfter) internal {
        _warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 60);
        _nav(navAfter);
        for (uint256 i; i < 3; ++i) {
            _skip(1 hours);
            vault.checkRisk();
        }
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DRAWDOWN));
    }

    function _recover(uint256 nav) internal {
        _nav(nav);
        _skip(24 hours);
        vm.prank(owner);
        vault.resume();
        for (uint256 i; i < 2; ++i) {
            _skip(1 hours);
            vault.checkRisk();
        }
    }

    /// @notice GainsVaultPolicy#207 (checkOrder band `mark * maxSlippageBps / BPS` mutated): a market order exactly
    ///         at the band edge passes on both sides, one unit beyond it is refused.
    function test_MUT207_checkOrderBandEdgesBothSides() public view {
        uint256 mark = policy.price(ETH);
        uint256 band = (mark * policy.maxSlippageBps()) / 10_000;
        GainsVaultPolicy.Order memory o = GainsVaultPolicy.Order({
            pair: ETH,
            long: true,
            market: true,
            expectedPrice: uint64(mark + band),
            maxSlippageP: 0,
            collateral: 1_000e6,
            notional: 2_000e6,
            minCollateral: 0,
            nav: 100_000e6,
            openNotional: 0
        });
        (bool ok,) = policy.checkOrder(o);
        assertTrue(ok, "long at mark + band");
        o.expectedPrice = uint64(mark + band + 1);
        (ok,) = policy.checkOrder(o);
        assertFalse(ok, "long beyond the band");
        o.long = false;
        o.expectedPrice = uint64(mark - band);
        (ok,) = policy.checkOrder(o);
        assertTrue(ok, "short at mark - band");
        o.expectedPrice = uint64(mark - band - 1);
        (ok,) = policy.checkOrder(o);
        assertFalse(ok, "short beyond the band");
    }

    /// @notice GainsVaultPolicy#753 (applyTimelockDelay without `pendingTimelockEta = 0`): after an apply nothing is
    ///         pending, and a second apply reverts NothingPending.
    function test_MUT753_applyTimelockDelayClearsThePending() public {
        vm.prank(owner);
        policy.proposeTimelockDelay(1 days); // lowering from 2 days: queued
        assertGt(policy.pendingTimelockEta(), 0);
        _skip(2 days);
        policy.applyTimelockDelay();
        assertEq(policy.timelockDelay(), 1 days);
        assertEq(policy.pendingTimelockEta(), 0, "nothing pending after the apply");
        vm.expectRevert(GainsVaultPolicy.NothingPending.selector);
        policy.applyTimelockDelay();
    }
}
