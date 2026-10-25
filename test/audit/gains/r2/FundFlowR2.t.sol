// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {R1Base} from "../R1Base.t.sol";
import {GainsVault} from "../../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../../src/gains/GainsVaultPolicy.sol";
import {GainsVaultFactory} from "../../../../src/gains/GainsVaultFactory.sol";
import {IGainsDiamond} from "../../../../src/gains/IGainsDiamond.sol";
import {IGainsVaultErrors, OpenParams} from "../../../../src/gains/GainsTypes.sol";
import {MockUSDC} from "../../../mocks/Mocks.sol";
import {MockGainsDiamond} from "../../../gains/mocks/GainsMocks.sol";

/// @title Round 2 fund-flow map (domain FF): every value-moving path of contracts/src/gains that can be driven on the
///        mock diamond, with a USDC ledger over every actor and the vault -> diamond allowance after each path.
/// @dev   Table: contracts/audit/gains/r2/FUND-FLOW.md. Each test asserts that USDC moved ONLY between the addresses
///        the table names, by exactly the bounded amount, and that the vault's allowance to the diamond is 0 after
///        the path (including revert, try / catch and "the diamond pulls less than approved" variants).
contract FundFlowR2Test is R1Base {
    address internal creator = makeAddr("ff-creator");
    address internal agentW = makeAddr("ff-agent");
    address internal rescueTo = makeAddr("ff-rescueTo");

    address[] internal _who;

    function setUp() public override {
        super.setUp();
        _who.push(address(vault));
        _who.push(address(diamond));
        _who.push(alice);
        _who.push(bob);
        _who.push(stranger);
        _who.push(manager);
        _who.push(owner);
        _who.push(feeRecipient);
        _who.push(guardian);
        _who.push(protocolTreasury);
        _who.push(address(platform));
        _who.push(address(policy));
        _who.push(creator);
        _who.push(agentW);
        _who.push(rescueTo);

        // alice is the vault's only holder: 100k idle, nothing on the venue
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
    }

    // ==================================================================
    // Ledger helpers
    // ==================================================================
    function _bal() internal view returns (uint256[] memory b) {
        b = new uint256[](_who.length);
        for (uint256 i; i < _who.length; ++i) {
            b[i] = usdc.balanceOf(_who[i]);
        }
    }

    /// @dev Only `a` and `c` moved, by exactly `da` / `dc`; every other tracked address is unchanged.
    function _only(uint256[] memory b0, address a, int256 da, address c, int256 dc, string memory what) internal view {
        for (uint256 i; i < _who.length; ++i) {
            int256 d = int256(usdc.balanceOf(_who[i])) - int256(b0[i]);
            int256 want = _who[i] == a ? da : _who[i] == c ? dc : int256(0);
            assertEq(d, want, string.concat(what, ": USDC delta of ", vm.toString(_who[i])));
        }
        assertEq(usdc.allowance(address(vault), address(diamond)), 0, string.concat(what, ": vault -> diamond allowance"));
    }

    function _none(uint256[] memory b0, string memory what) internal view {
        _only(b0, address(0), 0, address(0), 0, what);
    }

    function _limitParams(uint16 pair, uint120 collateral, uint64 trigger) internal pure returns (OpenParams memory p) {
        p = OpenParams({
            pairIndex: pair,
            long: true,
            collateral: collateral,
            leverage: 2_000,
            expectedPrice: trigger,
            maxSlippageP: SLIP,
            tp: 0,
            sl: 0,
            tradeType: 1
        });
    }

    function _placeLimit(uint120 collateral) internal returns (uint32 idx) {
        OpenParams memory p = _limitParams(ETH, collateral, _px(ETH) - 100e10);
        vm.prank(manager);
        vault.openTrade(p);
        idx = diamond.tradeCount(address(vault)) - 1;
    }

    function _fillOpenOrders(uint64 price) internal {
        uint32 n = diamond.orderCount(address(vault));
        for (uint32 i; i < n; ++i) {
            if (diamond.getPendingOrder(address(vault), i).isOpen) diamond.fill(address(vault), i, price);
        }
    }

    // ==================================================================
    // Vault -> diamond (collateral): exactly the request's collateral, allowance back to 0
    // ==================================================================
    function test_FF_openTradeMarket_pullsExactlyCollateral_allowanceZero() public {
        uint256[] memory b0 = _bal();
        OpenParams memory p = _params(ETH, true, 10_000e6, 2_000);
        vm.expectCall(address(usdc), abi.encodeCall(IERC20.approve, (address(diamond), uint256(10_000e6))));
        vm.prank(manager);
        vault.openTrade(p);
        _only(b0, address(vault), -10_000e6, address(diamond), 10_000e6, "openTrade market");
    }

    function test_FF_openTradeLimit_pullsExactlyCollateral_allowanceZero() public {
        uint256[] memory b0 = _bal();
        _placeLimit(5_000e6);
        _only(b0, address(vault), -5_000e6, address(diamond), 5_000e6, "openTrade limit");
    }

    function test_FF_increaseTrade_withCollateral_pullsExactlyDelta() public {
        uint32 idx = _open(vault, ETH, true, 10_000e6, 2_000);
        uint256[] memory b0 = _bal();
        uint64 px = _px(ETH);
        vm.expectCall(address(usdc), abi.encodeCall(IERC20.approve, (address(diamond), uint256(4_000e6))));
        vm.prank(manager);
        vault.increaseTrade(idx, 4_000e6, 2_000, px, SLIP);
        _only(b0, address(vault), -4_000e6, address(diamond), 4_000e6, "increaseTrade");
    }

    function test_FF_increaseTrade_leverageOnly_noApproveNoPull() public {
        uint32 idx = _open(vault, ETH, true, 10_000e6, 2_000);
        uint256[] memory b0 = _bal();
        uint64 px = _px(ETH);
        vm.expectCall(address(usdc), abi.encodeWithSelector(IERC20.approve.selector), 0);
        vm.prank(manager);
        vault.increaseTrade(idx, 0, 1_000, px, SLIP);
        _none(b0, "increaseTrade leverage-only");
    }

    function test_FF_updateLeverageDown_pullsExactlyTheMarginDelta() public {
        uint32 idx = _open(vault, ETH, true, 10_000e6, 2_000);
        uint256[] memory b0 = _bal();
        // Gains: newCollateral = 10,000 x 2 / 1 = 20,000, delta 10,000
        vm.expectCall(address(usdc), abi.encodeCall(IERC20.approve, (address(diamond), uint256(10_000e6))));
        vm.prank(manager);
        vault.updateLeverage(idx, 1_000);
        _only(b0, address(vault), -10_000e6, address(diamond), 10_000e6, "updateLeverage down");
    }

    function test_FF_updateLeverageUp_noPull_fillReturnsToVault() public {
        uint32 idx = _open(vault, ETH, true, 10_000e6, 2_000);
        uint256[] memory b0 = _bal();
        vm.expectCall(address(usdc), abi.encodeWithSelector(IERC20.approve.selector), 0);
        vm.prank(manager);
        vault.updateLeverage(idx, 4_000);
        _none(b0, "updateLeverage up request");
        _fillLast(vault, _px(ETH));
        // 10,000 at 2x -> 5,000 at 4x: 5,000 comes back to the vault, nowhere else
        _only(b0, address(diamond), -5_000e6, address(vault), 5_000e6, "updateLeverage up fill");
    }

    /// @dev Reserved USDC (queued deposits, claimable redemptions) is never approved to the diamond: the approval is
    ///      bounded by idleAssets, checked before the approve.
    function test_FF_reservedUsdcNeverReachesTheDiamond() public {
        // bob queues 50k: the vault holds 150k, idle is still 100k
        _deposit(bob, 50_000e6);
        assertEq(vault.idleAssets(), 100_000e6);
        OpenParams memory p = _params(ETH, true, 100_000e6 + 1, 1_000);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IGainsVaultErrors.InsufficientIdle.selector, 100_000e6, 100_000e6 + 1));
        vault.openTrade(p);
        uint32 idx = _open(vault, ETH, true, 50_000e6, 1_000);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IGainsVaultErrors.InsufficientIdle.selector, 50_000e6, 50_000e6 + 1));
        vault.increaseTrade(idx, 50_000e6 + 1, 1_000, _px(ETH), SLIP);
        assertEq(usdc.allowance(address(vault), address(diamond)), 0);
    }

    // ==================================================================
    // The diamond pulls less than approved (here: nothing), or reverts: the allowance still ends at 0
    // ==================================================================
    function test_FF_diamondPullsLessThanApproved_openTrade_allowanceCleared() public {
        vm.mockCall(address(diamond), abi.encodeWithSelector(MockGainsDiamond.openTrade.selector), "");
        uint256[] memory b0 = _bal();
        OpenParams memory p = _params(ETH, true, 10_000e6, 2_000);
        vm.expectCall(address(usdc), abi.encodeCall(IERC20.approve, (address(diamond), uint256(10_000e6))));
        vm.expectCall(address(usdc), abi.encodeCall(IERC20.approve, (address(diamond), uint256(0))));
        vm.prank(manager);
        vault.openTrade(p);
        _none(b0, "openTrade, diamond pulled 0");
    }

    function test_FF_diamondPullsLessThanApproved_increaseAndLeverage_allowanceCleared() public {
        uint32 idx = _open(vault, ETH, true, 10_000e6, 2_000);
        vm.mockCall(address(diamond), abi.encodeWithSelector(MockGainsDiamond.increasePositionSize.selector), "");
        vm.mockCall(address(diamond), abi.encodeWithSelector(MockGainsDiamond.updateLeverage.selector), "");
        uint256[] memory b0 = _bal();
        uint64 px = _px(ETH);
        vm.prank(manager);
        vault.increaseTrade(idx, 4_000e6, 2_000, px, SLIP);
        _none(b0, "increaseTrade, diamond pulled 0");
        vm.prank(manager);
        vault.updateLeverage(idx, 1_000);
        _none(b0, "updateLeverage down, diamond pulled 0");
    }

    function test_FF_diamondReverts_nothingMovesNoAllowance() public {
        uint32 idx = _open(vault, ETH, true, 10_000e6, 2_000);
        diamond.setRejectCalls(true);
        uint256[] memory b0 = _bal();
        OpenParams memory p = _params(ETH, true, 10_000e6, 2_000);
        uint64 px = _px(ETH);
        vm.startPrank(manager);
        vm.expectRevert(bytes("mock: trading paused"));
        vault.openTrade(p);
        vm.expectRevert(bytes("mock: trading paused"));
        vault.increaseTrade(idx, 1_000e6, 1_000, px, SLIP);
        vm.expectRevert(bytes("mock: trading paused"));
        vault.updateLeverage(idx, 1_000);
        vm.stopPrank();
        _none(b0, "diamond reverts");
    }

    // ==================================================================
    // Diamond -> vault (payouts): closes, reduces, cancels, timeouts, flatten, full stop
    // ==================================================================
    function test_FF_closeTrade_payoutOnlyToVault() public {
        uint32 idx = _open(vault, ETH, true, 10_000e6, 2_000);
        _passHold(); // GR2-KEY-01b: the manager's exit waits out the minimum hold
        _setPrice(ETH, 3_300e10); // +10% at 2x: +2,000
        uint256[] memory b0 = _bal();
        uint256 want = diamond.closeValue(address(vault), idx, 3_300e10);
        assertEq(want, 12_000e6);
        vm.prank(manager);
        vault.closeTrade(idx, 3_300e10);
        _none(b0, "close request");
        _fillLast(vault, 3_300e10);
        _only(b0, address(diamond), -int256(want), address(vault), int256(want), "close fill");
    }

    function test_FF_reduceTrade_payoutOnlyToVault() public {
        uint32 idx = _open(vault, ETH, true, 10_000e6, 2_000);
        _passHold();
        uint256[] memory b0 = _bal();
        uint64 px = _px(ETH);
        vm.prank(manager);
        vault.reduceTrade(idx, 2_500e6, 0, px);
        _none(b0, "reduce request");
        (, uint256 paid) = _fillLast(vault, px);
        assertEq(paid, 2_500e6);
        _only(b0, address(diamond), -2_500e6, address(vault), 2_500e6, "reduce fill");
    }

    function test_FF_cancelOrder_collateralBackToVault() public {
        uint32 idx = _placeLimit(5_000e6);
        uint256[] memory b0 = _bal();
        vm.prank(manager);
        vault.cancelOrder(idx);
        _only(b0, address(diamond), -5_000e6, address(vault), 5_000e6, "cancelOrder");
    }

    function test_FF_cancelTimedOut_byStranger_collateralBackToVault() public {
        uint32 o = _request(vault, ETH, true, 10_000e6, 2_000);
        vm.roll(vm.getBlockNumber() + 200);
        uint256[] memory b0 = _bal();
        vm.prank(stranger);
        vault.cancelTimedOut(o);
        _only(b0, address(diamond), -10_000e6, address(vault), 10_000e6, "cancelTimedOut by a stranger");
    }

    function test_FF_flatten_closesAndCancels_payoutsOnlyToVault() public {
        _open(vault, ETH, true, 10_000e6, 2_000);
        _open(vault, ETH, false, 8_000e6, 1_000);
        _placeLimit(3_000e6);
        _passHold();
        uint256[] memory b0 = _bal();
        uint64 px = _px(ETH);
        vm.prank(manager);
        (uint256 sent, uint256 remaining) = vault.flatten(ETH, 0, px, type(uint256).max);
        assertEq(sent, 3);
        assertEq(remaining, 0);
        _only(b0, address(diamond), -3_000e6, address(vault), 3_000e6, "flatten requests (limit cancel)");
        _fillOpenOrders(px);
        _only(b0, address(diamond), -21_000e6, address(vault), 21_000e6, "flatten fills");
    }

    function test_FF_flatten_cancelRefusedInTryCatch_nothingMoves() public {
        _placeLimit(3_000e6);
        _passHold();
        diamond.setTriggerInFlight(true); // cancelOpenOrder and the slippage update revert inside try / catch
        uint256[] memory b0 = _bal();
        uint64 px = _px(ETH);
        vm.prank(manager);
        vault.flatten(ETH, 0, px, type(uint256).max);
        _none(b0, "flatten with a refused cancel");
    }

    function test_FF_flattenIndices_payoutsOnlyToVault() public {
        // (the mock accepts a market close of a resting order, which Gains refuses, so resting orders are covered by
        // the flatten and full-stop tests instead)
        uint32 a = _open(vault, ETH, true, 10_000e6, 2_000);
        uint32[] memory ix = new uint32[](2);
        ix[0] = a;
        ix[1] = 999; // not a trade: skipped by try / catch
        _passHold();
        uint256[] memory b0 = _bal();
        uint64 px = _px(ETH);
        vm.prank(manager);
        uint256 sent = vault.flattenIndices(ix, 0, px);
        assertEq(sent, 1);
        _none(b0, "flattenIndices requests");
        _fillOpenOrders(px);
        _only(b0, address(diamond), -10_000e6, address(vault), 10_000e6, "flattenIndices fills");
    }

    function test_FF_fullStop_cancelsRestingOrders_collateralBackToVault() public {
        _placeLimit(3_000e6);
        uint256[] memory b0 = _bal();
        vm.prank(owner);
        vault.triggerBreach();
        _only(b0, address(diamond), -3_000e6, address(vault), 3_000e6, "triggerBreach cancels resting");
    }

    function test_FF_setSlTp_movesNothing() public {
        uint32 idx = _open(vault, ETH, true, 10_000e6, 2_000);
        uint256[] memory b0 = _bal();
        vm.prank(manager);
        vault.setSlTp(idx, 2_500e10, 4_000e10);
        _none(b0, "setSlTp");
    }

    // ==================================================================
    // Depositor flow: USDC only from msg.sender into the vault, and only to the controller out of it
    // ==================================================================
    function test_FF_requestDeposit_forAnotherController_onlySenderPays() public {
        uint256[] memory b0 = _bal();
        vm.prank(bob);
        vault.requestDeposit(20_000e6, stranger);
        _only(b0, bob, -20_000e6, address(vault), 20_000e6, "requestDeposit(controller = stranger)");
        // the controller owns the request: only the controller can cancel, and the refund goes to the controller
        vm.prank(bob);
        vm.expectRevert(IGainsVaultErrors.NothingToCancel.selector);
        vault.cancelDepositRequest();
        vm.prank(stranger);
        vault.cancelDepositRequest();
        _only(b0, bob, -20_000e6, stranger, 20_000e6, "cancelDepositRequest pays the controller");
    }

    function test_FF_claimByStranger_paysOnlyTheController() public {
        uint256 shares = vault.balanceOf(alice) / 4;
        _redeem(alice, shares);
        _settle();
        uint256 owed = vault.claimableRedeemAssets();
        assertEq(owed, 25_000e6);
        uint256[] memory b0 = _bal();
        vm.prank(stranger);
        vault.claim(alice);
        _only(b0, address(vault), -int256(owed), alice, int256(owed), "claim(alice) by a stranger");
        assertEq(vault.claimableRedeemAssets(), 0);
    }

    function test_FF_settle_movesNoUsdc_feesOnlyToFeeRecipient() public {
        _skip(10 days);
        vault.checkRisk();
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 supply0 = vault.totalSupply();
        uint256[] memory b0 = _bal();
        vm.prank(manager);
        vault.settle();
        _none(b0, "settle");
        assertEq(vault.balanceOf(alice), aliceShares, "no share moved from alice");
        uint256 fee = vault.balanceOf(feeRecipient);
        assertGt(fee, 0);
        assertEq(vault.totalSupply(), supply0 + fee, "only the fee recipient's shares were minted");
        // 2% / yr on 100k over 10 days ~ 54.79 USDC of shares; never above the cap
        assertLe(vault.convertToAssets(fee), uint256(100_000e6 * 200 * 10 days) / (10_000 * 365 days) + 1);
    }

    // ==================================================================
    // Factory: seed from msg.sender only, ETH only to the bound agent, protocol share only to the treasury
    // ==================================================================
    function _factoryVault() internal returns (GainsVault v) {
        bytes32 salt = bytes32(uint256(7));
        address predicted = platform.predictVaultAddress(creator, salt);
        vm.startPrank(platformOwner);
        platform.setLauncherAllowed(creator, true);
        platform.registerPlatformAgent(agentW, predicted);
        vm.stopPrank();
        usdc.mint(creator, 1_000e6);
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        usdc.approve(address(platform), 1_000e6); // more than the seed: the rest must stay usable only by creator
        uint32[] memory assets = new uint32[](2);
        assets[0] = BTC;
        assets[1] = ETH;
        GainsVaultFactory.CreateParams memory cp = GainsVaultFactory.CreateParams({
            name: "FF",
            symbol: "FF",
            owner: creator,
            manager: creator,
            feeRecipient: creator,
            managementFeeBps: 200,
            performanceFeeBps: 2_000,
            timelockDelay: 2 days,
            depositCap: 50_000e6,
            risk: _defaultRisk(),
            assets: assets,
            agent: agentW,
            agentSig: "",
            agentDeadline: 0,
            operator: address(0),
            hosted: true,
            seedUsdc: 1e6,
            salt: salt
        });
        uint256[] memory b0 = _bal();
        uint256 agentEth = agentW.balance;
        vm.prank(creator);
        (address va,) = platform.create{value: 0.001 ether}(cp, GainsVaultFactory.PermitData(0, 0, 0, bytes32(0), bytes32(0)));
        v = GainsVault(va);
        assertEq(va, predicted);
        assertEq(usdc.balanceOf(va), 1e6, "seed lands in the vault");
        _only(b0, creator, -1e6, address(0), 0, "create: only the creator pays (the vault is untracked here)");
        assertEq(agentW.balance - agentEth, 0.001 ether, "ETH only to the bound agent");
        assertEq(address(platform).balance, 0, "the factory keeps no ETH");
        assertEq(usdc.balanceOf(address(platform)), 0, "the factory keeps no USDC");
    }

    function test_FF_factoryCreate_seedFromCreatorOnly_ethToBoundAgent() public {
        _factoryVault();
        // creator's leftover allowance to the factory (999 USDC) cannot be spent by anyone else: create pulls from
        // msg.sender only
        vm.prank(platformOwner);
        platform.setOpenLaunch(true);
        GainsVaultFactory.CreateParams memory cp;
        cp.name = "X";
        cp.symbol = "X";
        cp.owner = stranger;
        cp.manager = stranger;
        cp.feeRecipient = stranger;
        cp.timelockDelay = 2 days;
        cp.depositCap = 1_000e6;
        cp.risk = _defaultRisk();
        cp.seedUsdc = 999e6;
        cp.salt = bytes32(uint256(8));
        uint256 creatorBal = usdc.balanceOf(creator);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(platform), 0, 999e6));
        platform.create(cp, GainsVaultFactory.PermitData(0, 0, 0, bytes32(0), bytes32(0)));
        assertEq(usdc.balanceOf(creator), creatorBal);
        assertEq(usdc.allowance(creator, address(platform)), 999e6);
    }

    function test_FF_protocolShare_mintsOnlyToFactoryRecipient() public {
        GainsVault v = _factoryVault();
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        vm.prank(alice);
        v.requestDeposit(10_000e6, alice);
        _skip(1 hours);
        v.checkRisk();
        vm.prank(creator);
        v.settle();
        v.claim(alice);
        uint256 a0 = v.balanceOf(alice);
        uint256 s0 = v.totalSupply();
        _skip(30 days);
        uint256[] memory b0 = _bal();
        v.accrueFees();
        _none(b0, "accrueFees (factory vault)");
        uint256 prot = v.balanceOf(protocolTreasury);
        uint256 mgr = v.balanceOf(creator);
        assertGt(prot, 0);
        assertEq(v.balanceOf(alice), a0);
        assertEq(v.totalSupply(), s0 + prot + mgr, "only the protocol treasury and the fee recipient were minted");
        assertApproxEqAbs(prot * 10_000, (prot + mgr) * 3_300, 10_000, "hosted share 33% of the fee shares");
    }

    // ==================================================================
    // rescueToken: never USDC or the vault's shares; owner only; recipient chosen by the owner
    // ==================================================================
    function test_FF_rescueToken_neverAssetOrShares() public {
        MockUSDC other = new MockUSDC();
        other.mint(address(vault), 5e6);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        vault.rescueToken(IERC20(address(other)), stranger);
        vm.startPrank(owner);
        vm.expectRevert(IGainsVaultErrors.UnsupportedAsset.selector);
        vault.rescueToken(IERC20(address(usdc)), rescueTo);
        vm.expectRevert(IGainsVaultErrors.UnsupportedAsset.selector);
        vault.rescueToken(IERC20(address(vault)), rescueTo);
        uint256[] memory b0 = _bal();
        vault.rescueToken(IERC20(address(other)), rescueTo);
        vm.stopPrank();
        _none(b0, "rescue of another token moves no USDC");
        assertEq(other.balanceOf(rescueTo), 5e6);
    }

    // ==================================================================
    // execute(): the queue whitelist cannot reach any value-moving function
    // ==================================================================
    function _notQueueable() internal view returns (bytes[] memory c) {
        OpenParams memory op = _params(ETH, true, 1e6, 1_000);
        uint32[] memory ix = new uint32[](1);
        c = new bytes[](44);
        uint256 k;
        c[k++] = abi.encodeCall(GainsVault.requestDeposit, (1, alice));
        c[k++] = abi.encodeCall(GainsVault.requestRedeem, (1, alice, alice));
        c[k++] = abi.encodeCall(GainsVault.cancelDepositRequest, ());
        c[k++] = abi.encodeCall(GainsVault.cancelRedeemRequest, ());
        c[k++] = abi.encodeCall(GainsVault.claim, (alice));
        c[k++] = abi.encodeCall(GainsVault.settle, ());
        c[k++] = abi.encodeCall(GainsVault.accrueFees, ());
        c[k++] = abi.encodeCall(GainsVault.leaveHosted, ());
        c[k++] = abi.encodeCall(GainsVault.lowerProtocolShare, (0));
        c[k++] = abi.encodeCall(GainsVault.openTrade, (op));
        c[k++] = abi.encodeCall(GainsVault.increaseTrade, (0, 1, 1, 1, 1));
        c[k++] = abi.encodeCall(GainsVault.updateLeverage, (0, 1));
        c[k++] = abi.encodeCall(GainsVault.closeTrade, (0, 1));
        c[k++] = abi.encodeCall(GainsVault.reduceTrade, (0, 1, 0, 1));
        c[k++] = abi.encodeCall(GainsVault.setSlTp, (0, 1, 1));
        c[k++] = abi.encodeCall(GainsVault.cancelOrder, (0));
        c[k++] = abi.encodeCall(GainsVault.cancelTimedOut, (0));
        c[k++] = abi.encodeCall(GainsVault.flatten, (ETH, 0, 1, 1));
        c[k++] = abi.encodeCall(GainsVault.flattenIndices, (ix, 0, 1));
        c[k++] = abi.encodeCall(GainsVault.revokeAgent, ());
        c[k++] = abi.encodeCall(GainsVault.checkRisk, ());
        c[k++] = abi.encodeCall(GainsVault.triggerBreach, ());
        c[k++] = abi.encodeCall(GainsVault.triggerEmergency, ());
        c[k++] = abi.encodeCall(GainsVault.clearLeverageBreach, ());
        c[k++] = abi.encodeCall(GainsVault.resume, ());
        c[k++] = abi.encodeCall(GainsVault.setOperator, (stranger));
        c[k++] = abi.encodeCall(GainsVault.revokeOperator, ());
        c[k++] = abi.encodeCall(GainsVault.exitEmergency, ());
        c[k++] = abi.encodeCall(GainsVault.setDepositsPaused, (false));
        c[k++] = abi.encodeCall(GainsVault.setTradingPaused, (false));
        c[k++] = abi.encodeCall(GainsVault.setDepositCap, (1));
        c[k++] = abi.encodeCall(GainsVault.lowerFees, (0, 0));
        c[k++] = abi.encodeCall(GainsVault.rescueToken, (IERC20(address(usdc)), stranger));
        c[k++] = abi.encodeCall(GainsVault.queue, (""));
        c[k++] = abi.encodeCall(GainsVault.execute, (""));
        c[k++] = abi.encodeCall(GainsVault.cancel, (bytes32(0)));
        c[k++] = abi.encodeCall(IERC20.transfer, (stranger, 1));
        c[k++] = abi.encodeCall(IERC20.transferFrom, (alice, stranger, 1));
        c[k++] = abi.encodeCall(IERC20.approve, (stranger, type(uint256).max));
        c[k++] = abi.encodeCall(OwnableUpgradeable.transferOwnership, (stranger));
        c[k++] = abi.encodeWithSignature("acceptOwnership()");
        c[k++] = abi.encodeCall(OwnableUpgradeable.renounceOwnership, ());
        // a whitelisted selector with padding (the length is exact per selector)
        c[k++] = abi.encodePacked(abi.encodeCall(GainsVault.setFeeRecipient, (stranger)), uint256(0));
        c[k++] = abi.encodePacked(GainsVault.clearBreach.selector, uint256(1));
        assertEq(k, c.length);
    }

    function test_FF_execute_queueRefusesEveryValueMovingSelector() public {
        bytes[] memory c = _notQueueable();
        for (uint256 i; i < c.length; ++i) {
            vm.prank(owner);
            vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
            vault.queue(c[i]);
        }
    }

    /// @dev Every queueable call executed once: no USDC moves, no allowance, and the only share mint is setFees'
    ///      management fee crystallisation to the fee recipient.
    function test_FF_execute_everyQueueableCallMovesNoUsdc() public {
        vm.prank(guardian);
        vault.triggerBreach();
        _skip(1); // a clearBreach counts only when queued after the breach (N-04)
        uint256 aliceShares = vault.balanceOf(alice);
        bytes[] memory c = new bytes[](8);
        c[0] = abi.encodeCall(GainsVault.setManager, (bob));
        c[1] = abi.encodeCall(GainsVault.setFeeRecipient, (bob));
        c[2] = abi.encodeCall(GainsVault.setTimelockDelay, (2 days));
        c[3] = abi.encodeCall(GainsVault.setFees, (100, 1_000));
        c[4] = abi.encodeCall(GainsVault.clearBreach, ());
        c[5] = abi.encodeCall(GainsVault.setAgent, (agentW));
        c[6] = abi.encodeCall(GainsVault.setPairFeed, (ETH, address(ethFeed), BTC_MAX_AGE, 20));
        c[7] = abi.encodeCall(GainsVault.setSequencerFeed, (address(sequencer), SEQ_GRACE));
        uint256[] memory b0 = _bal();
        uint256 eta;
        for (uint256 i; i < c.length; ++i) {
            vm.prank(owner);
            bytes32 id = vault.queue(c[i]);
            // GR2-CFG-01 (exit before effect): each item waits its own stored eta, not queue + timelock
            if (vault.queuedEta(id) > eta) eta = vault.queuedEta(id);
        }
        vm.warp(eta);
        for (uint256 i; i < c.length; ++i) {
            vault.execute(c[i]);
            _none(b0, string.concat("execute #", vm.toString(i)));
        }
        assertEq(vault.balanceOf(alice), aliceShares, "no share moved from a holder");
        assertEq(vault.manager(), bob);
        assertEq(vault.agent(), agentW);
    }

    // ==================================================================
    // ERC-20 share surface
    // ==================================================================
    function test_FF_shares_escrowCannotBePulled() public {
        _redeem(alice, 1_000e12);
        assertEq(vault.balanceOf(address(vault)), 1_000e12);
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, 1_000e12));
        vault.requestRedeem(1_000e12, stranger, address(vault));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, 1_000e12));
        vault.transferFrom(address(vault), stranger, 1_000e12);
        vm.stopPrank();
        assertEq(vault.allowance(address(vault), stranger), 0);
    }

    function test_FF_shares_requestRedeemBySpender_needsAndSpendsAllowance() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1e12));
        vault.requestRedeem(1e12, bob, alice);
        vm.prank(alice);
        vault.approve(bob, 5e12);
        vm.prank(bob);
        vault.requestRedeem(5e12, bob, alice); // the spender may name itself controller: same power as transferFrom
        assertEq(vault.allowance(alice, bob), 0, "allowance spent exactly");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        vault.requestRedeem(1, bob, alice);
    }

    /// @dev A third party can add to a victim's request (a gift) but cannot block a non-insider's exit.
    function test_FF_shares_thirdPartyRequestsForAVictim_doNotBlockItsExit() public {
        vm.prank(alice);
        vault.transfer(bob, 10e12);
        // bob gifts 1 share unit into alice's redeem request and 10 USDC into a deposit request for alice
        vm.prank(bob);
        vault.requestRedeem(1, alice, bob);
        vm.prank(bob);
        vault.requestDeposit(10e6, alice);
        // alice can still redeem and cancel in the same epoch, and gets bob's gift
        uint256 sh = vault.balanceOf(alice);
        _redeem(alice, sh);
        vm.prank(alice);
        vault.cancelRedeemRequest();
        assertEq(vault.balanceOf(alice), sh + 1);
        vm.prank(alice);
        vault.cancelDepositRequest();
        assertEq(usdc.balanceOf(alice), 1_000_000e6 - 100_000e6 + 10e6);
    }

    /// @notice GR2-FF-01 (Info): anyone can attach a next-epoch deposit to an INSIDER controller (manager, owner, fee
    ///         recipient), which makes that insider's requestRedeem revert RequestPending until the insider cancels it.
    ///         The cancel always works (GR1-32) and refunds the griefer's USDC to the insider, so the block costs the
    ///         griefer at least MIN_DEPOSIT (10 USDC) per use; no depositor value moves the wrong way.
    function test_GR2_FF_01_strangerDepositForInsiderBlocksItsRedeemUntilCancel() public {
        vm.prank(alice);
        vault.transfer(feeRecipient, 1_000e12);
        usdc.mint(stranger, 10e6);
        vm.startPrank(stranger);
        usdc.approve(address(vault), 10e6);
        vault.requestDeposit(10e6, feeRecipient); // insider controller: deferred to the next epoch
        vm.stopPrank();
        (uint256 ep,,) = vault.requests(feeRecipient);
        assertEq(ep, vault.currentEpoch() + 1);
        vm.prank(feeRecipient);
        vm.expectRevert(IGainsVaultErrors.RequestPending.selector);
        vault.requestRedeem(1_000e12, feeRecipient, feeRecipient);
        // the insider's way out: cancel (keeps the griefer's 10 USDC), then redeem
        vm.prank(feeRecipient);
        vault.cancelDepositRequest();
        vm.prank(feeRecipient);
        vault.requestRedeem(1_000e12, feeRecipient, feeRecipient);
        assertEq(usdc.balanceOf(feeRecipient), 10e6, "the griefer paid the insider");
        assertEq(usdc.balanceOf(stranger), 0);
    }
}
