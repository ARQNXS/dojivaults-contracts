// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {GainsBase} from "../../gains/GainsBase.t.sol";
import {GainsVault} from "../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../src/gains/GainsVaultPolicy.sol";
import {GainsVaultFactory} from "../../../src/gains/GainsVaultFactory.sol";
import {IGainsVaultErrors as E, MIN_HOLD, MIN_HOLD_L2_BLOCKS, OpenParams} from "../../../src/gains/GainsTypes.sol";
import {MockUSDC} from "../../mocks/Mocks.sol";

/// @notice ACCESS-MATRIX.md, verified cell by cell: every state-changing GainsVault function x 9 actors x 12 vault
///         states. Each state is built from one base snapshot; each cell restores the state, calls as the actor and
///         compares the outcome (success, or the revert selector) with `_expect`, which encodes the matrix. A factory
///         vault (live platform guardian and sentinel, a bound agent, an operator, hosted).
contract AccessMatrixTest is GainsBase {
    enum S {
        N,
        DP,
        TP,
        BL,
        BD,
        BW,
        BG,
        EM,
        OD,
        OP,
        FS,
        SD
    }

    enum A {
        Str,
        Dep,
        Mgr,
        Own,
        Agt,
        Opr,
        Sen,
        Grd,
        Fac
    }

    uint256 internal constant NFN = 44; // round 1 fix: + flattenIndices (two slippages), setSequencerFeed
    bytes4 internal constant OK = 0x00000000;
    bytes4 internal constant ERR_STRING = 0x08c379a0; // the mock diamond's require(…, "PendingMarketOrder")

    GainsVault internal v;
    GainsVaultPolicy internal p;
    address internal agt = makeAddr("agent");
    address internal opr = makeAddr("operator");
    address internal feeRecipient2 = makeAddr("feeRecipient2");
    MockUSDC internal junk;
    uint32 internal idx; // the open ETH trade
    uint32 internal limitIdx; // a resting ETH limit order
    bytes internal queuedData;
    bytes32 internal queuedId;
    uint256 internal base;
    uint64 internal px0; // ETH price at the base snapshot: SL / TP values are relative to it

    function setUp() public override {
        super.setUp();
        vm.startPrank(platformOwner);
        platform.setLauncherAllowed(owner, true);
        platform.setMaxDepositCap(type(uint256).max);
        bytes32 salt = bytes32(uint256(7));
        platform.registerPlatformAgent(agt, platform.predictVaultAddress(owner, salt));
        vm.stopPrank();

        usdc.mint(owner, 1e6);
        vm.deal(owner, 1 ether);
        vm.startPrank(owner);
        usdc.approve(address(platform), 1e6);
        uint32[] memory assets = new uint32[](2);
        assets[0] = BTC;
        assets[1] = ETH;
        (address va, address pa) = platform.create{value: 0.001 ether}(
            GainsVaultFactory.CreateParams({
                name: "AM",
                symbol: "AM",
                owner: owner,
                manager: manager,
                feeRecipient: owner,
                managementFeeBps: 200,
                performanceFeeBps: 2_000,
                timelockDelay: 2 days,
                depositCap: 10_000_000e6,
                risk: _defaultRisk(),
                assets: assets,
                agent: agt,
                agentSig: "",
                agentDeadline: 0,
                operator: opr,
                hosted: true,
                seedUsdc: 1e6,
                salt: salt
            }),
            GainsVaultFactory.PermitData(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();
        v = GainsVault(va);
        p = GainsVaultPolicy(pa);
        assertEq(v.agent(), agt);

        queuedData = abi.encodeCall(GainsVault.setFeeRecipient, (feeRecipient2));
        vm.prank(owner);
        queuedId = v.queue(queuedData);
        _warp(v.queuedEta(queuedId)); // hl-r2 exit-before-effect: wait for the stored eta

        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        vm.prank(alice);
        v.requestDeposit(100_000e6, alice);
        v.checkRisk();
        vm.prank(manager);
        v.settle();
        v.claim(alice);
        for (uint256 a; a < 9; ++a) {
            address who = _actor(A(a));
            vm.prank(alice);
            v.transfer(who, 1e15);
            usdc.mint(who, 1_000e6);
            vm.prank(who);
            usdc.approve(address(v), type(uint256).max);
        }
        vm.prank(alice);
        v.transfer(bob, 1e15);
        vm.prank(alice);
        v.requestRedeem(1e15, alice, alice);
        vm.prank(manager);
        v.settle(); // alice now has a settled, unclaimed redemption (claim(alice) is callable by anyone)

        vm.prank(manager);
        v.openTrade(_params(ETH, true, 50_000e6, 2_000));
        (idx,) = _fillLast(v, _px(ETH));
        vm.prank(manager);
        v.setSlTp(idx, _px(ETH) * 80 / 100, 0);
        OpenParams memory lp = _params(ETH, true, 1_000e6, 2_000);
        lp.tradeType = 1;
        lp.expectedPrice = _px(ETH) * 95 / 100;
        vm.prank(manager);
        v.openTrade(lp);
        limitIdx = diamond.tradeCount(address(v)) - 1;
        junk = new MockUSDC();
        junk.mint(address(v), 1e6);
        // GR2-KEY-01b: the matrix is the vault after the minimum hold (the manager's and agent's exits inside it are
        // refused "min hold", KEY01bFixTest); every cell below is the state once it has passed.
        _skip(MIN_HOLD);
        vm.roll(vm.getBlockNumber() + MIN_HOLD_L2_BLOCKS);
        v.checkRisk();
        px0 = _px(ETH);
        base = vm.snapshotState();
    }

    function _actor(A a) internal view returns (address) {
        if (a == A.Str) return stranger;
        if (a == A.Dep) return alice;
        if (a == A.Mgr) return manager;
        if (a == A.Own) return owner;
        if (a == A.Agt) return agt;
        if (a == A.Opr) return opr;
        if (a == A.Sen) return platformSentinel;
        if (a == A.Grd) return platformGuardian;
        return address(platform);
    }

    function _enter(S s) internal {
        vm.revertToState(base);
        if (s == S.DP) {
            vm.prank(owner);
            v.setDepositsPaused(true);
        } else if (s == S.TP) {
            vm.prank(owner);
            v.setTradingPaused(true);
        } else if (s == S.BL) {
            GainsVaultPolicy.RiskConfig memory r = _defaultRisk();
            r.maxLeverageBps = 10_000;
            vm.prank(owner);
            p.proposeConfig(r); // tighter: applies at once
            v.checkRisk();
            require(uint8(v.breachReason()) == 1, "BL");
        } else if (s == S.BD) {
            _setPrice(ETH, _px(ETH) * 94 / 100);
            v.checkRisk();
            require(uint8(v.breachReason()) == 2, "BD");
        } else if (s == S.BW) {
            _setPrice(ETH, _px(ETH) * 83 / 100);
            v.checkRisk();
            require(uint8(v.breachReason()) == 3, "BW");
        } else if (s == S.BG) {
            vm.prank(platformGuardian);
            v.triggerBreach();
        } else if (s == S.EM) {
            vm.prank(platformGuardian);
            v.triggerEmergency();
        } else if (s == S.OD) {
            vm.prank(bob);
            v.requestRedeem(1e15, bob, bob);
            _skip(7 days);
            v.checkRisk();
        } else if (s == S.OP) {
            vm.prank(manager);
            v.reduceTrade(idx, 1e6, 0, _px(ETH));
        } else if (s == S.FS) {
            uint256 t = vm.getBlockTimestamp() + 2_700;
            vm.warp(t);
            btcFeed.set(btcFeed.answer(), t);
            solFeed.set(solFeed.answer(), t);
        } else if (s == S.SD) {
            sequencer.setStatus(1, vm.getBlockTimestamp());
        }
    }

    function _call(uint256 f, A a) internal returns (bytes4) {
        address who = _actor(a);
        uint64 px = _px(ETH);
        bytes memory data;
        if (f == 0) data = abi.encodeCall(GainsVault.requestDeposit, (10e6, who));
        else if (f == 1) data = abi.encodeCall(GainsVault.requestRedeem, (1e12, who, who));
        else if (f == 2) data = abi.encodeCall(GainsVault.claim, (alice));
        else if (f == 3) data = abi.encodeCall(GainsVault.settle, ());
        else if (f == 4) data = abi.encodeCall(GainsVault.accrueFees, ());
        else if (f == 5) data = abi.encodeCall(GainsVault.openTrade, (_params(ETH, true, 1_000e6, 2_000)));
        else if (f == 6) data = abi.encodeCall(GainsVault.increaseTrade, (idx, 1_000e6, 2_000, px, SLIP));
        else if (f == 7) data = abi.encodeCall(GainsVault.updateLeverage, (idx, 3_000));
        else if (f == 8) data = abi.encodeCall(GainsVault.updateLeverage, (idx, 1_500));
        else if (f == 9) data = abi.encodeCall(GainsVault.closeTrade, (idx, px));
        else if (f == 10) data = abi.encodeCall(GainsVault.reduceTrade, (idx, 1e6, 0, px));
        else if (f == 11) data = abi.encodeCall(GainsVault.setSlTp, (idx, px0 * 90 / 100, 0));
        else if (f == 12) data = abi.encodeCall(GainsVault.setSlTp, (idx, px0 * 70 / 100, 0));
        else if (f == 13) data = abi.encodeCall(GainsVault.setSlTp, (idx, px0 * 80 / 100, px0 * 2));
        else if (f == 14) data = abi.encodeCall(GainsVault.cancelOrder, (limitIdx));
        else if (f == 15) data = abi.encodeCall(GainsVault.flatten, (ETH, 0, px, 1));
        else if (f == 16) data = abi.encodeCall(GainsVault.flatten, (ETH, 100, px, 1));
        else if (f == 17) data = abi.encodeCall(GainsVault.checkRisk, ());
        else if (f == 18) data = abi.encodeCall(GainsVault.clearLeverageBreach, ());
        else if (f == 19) data = abi.encodeCall(GainsVault.triggerBreach, ());
        else if (f == 20) data = abi.encodeCall(GainsVault.triggerEmergency, ());
        else if (f == 21) data = abi.encodeCall(GainsVault.clearBreach, ());
        else if (f == 22) data = abi.encodeCall(GainsVault.resume, ());
        else if (f == 23) data = abi.encodeCall(GainsVault.exitEmergency, ());
        else if (f == 24) data = abi.encodeCall(GainsVault.setOperator, (stranger));
        else if (f == 25) data = abi.encodeCall(GainsVault.revokeOperator, ());
        else if (f == 26) data = abi.encodeCall(GainsVault.revokeAgent, ());
        else if (f == 27) data = abi.encodeCall(GainsVault.setDepositsPaused, (true));
        else if (f == 28) data = abi.encodeCall(GainsVault.setDepositsPaused, (false));
        else if (f == 29) data = abi.encodeCall(GainsVault.setTradingPaused, (true));
        else if (f == 30) data = abi.encodeCall(GainsVault.setTradingPaused, (false));
        else if (f == 31) data = abi.encodeCall(GainsVault.setDepositCap, (1_000_000e6));
        else if (f == 32) data = abi.encodeCall(GainsVault.lowerFees, (100, 2_000));
        else if (f == 33) data = abi.encodeCall(GainsVault.rescueToken, (junk, who));
        else if (f == 34) data = abi.encodeCall(GainsVault.renounceOwnership, ());
        else if (f == 35) data = abi.encodeCall(GainsVault.queue, (abi.encodeCall(GainsVault.setManager, (who))));
        else if (f == 36) data = abi.encodeCall(GainsVault.setManager, (who));
        else if (f == 37) data = abi.encodeCall(GainsVault.leaveHosted, ());
        else if (f == 38) data = abi.encodeCall(GainsVault.lowerProtocolShare, (0));
        else if (f == 39) data = abi.encodeCall(GainsVault.cancel, (queuedId));
        else if (f == 40) data = abi.encodeCall(GainsVault.execute, (queuedData));
        else if (f == 41) data = abi.encodeCall(GainsVault.flattenIndices, (_one(idx), 0, px));
        else if (f == 42) data = abi.encodeCall(GainsVault.flattenIndices, (_one(idx), 100, px));
        else data = abi.encodeCall(GainsVault.setSequencerFeed, (address(sequencer), SEQ_GRACE));
        vm.prank(who);
        (bool ok, bytes memory ret) = address(v).call(data);
        if (ok) return OK;
        if (ret.length < 4) return bytes4(0xffffffff);
        return bytes4(ret);
    }

    function _one(uint32 i) internal pure returns (uint32[] memory a) {
        a = new uint32[](1);
        a[0] = i;
    }

    /// @dev The matrix (ACCESS-MATRIX.md sections 1 and 2) as rules.
    function _expect(uint256 f, A a, S s) internal pure returns (bytes4) {
        bool breached = s == S.BL || s == S.BD || s == S.BW || s == S.BG || s == S.EM;
        bool em = s == S.EM;
        bool stop = s == S.BG || s == S.EM; // full stop: agent revoked
        bool lossBreach = s == S.BD || s == S.BW;
        bool trader = a == A.Mgr || (a == A.Agt && !stop);
        bytes4 price = s == S.FS ? E.PriceStale.selector : s == S.SD ? E.SequencerDown.selector : OK;
        bytes4 pending = s == S.OP ? ERR_STRING : OK; // Gains: a market order already pending on the trade
        // round 1 fix (GR1-01): the vault itself refuses a second request on a trade with a pending order
        bytes4 onePending = s == S.OP ? E.PendingOrderExists.selector : OK;
        bytes4 overdue = s == S.OD ? E.EpochOverdue.selector : OK; // GR1-04: no new collateral in flight once overdue
        bytes4 U = E.Unauthorized.selector;

        if (f == 0) {
            if (s == S.DP || breached) return E.DepositsClosed.selector;
            return price;
        }
        if (f == 1 || f == 2) return OK;
        if (f == 3) {
            bool treasury = a == A.Mgr || a == A.Opr;
            bool platformRole = a == A.Own || a == A.Grd || a == A.Sen;
            if (!treasury && !platformRole) return U;
            if (s == S.BG) return E.ReduceOnlyMode.selector;
            if (platformRole && !em && !lossBreach && s != S.OD) return U;
            // GR1-04: a pending partial close holds no collateral and no longer blocks a settle (was OrdersPending)
            return price;
        }
        if (f == 4 || f == 17) return price;
        if (f == 5 || f == 6 || f == 7) {
            if (!trader) return U;
            if (f == 7 && onePending != OK) return onePending; // updateLeverage checks it before the risk gate
            if (breached) return E.ReduceOnlyMode.selector;
            if (s == S.TP) return E.TradingIsPaused.selector;
            if (overdue != OK) return overdue;
            if (f == 6 && onePending != OK) return onePending;
            if (price != OK) return price;
            return OK;
        }
        if (f == 8) {
            if (!trader) return U;
            if (onePending != OK) return onePending;
            if (stop || lossBreach) return E.ReduceOnlyMode.selector;
            return overdue;
        }
        if (f == 9 || f == 10) {
            bool mayExit = trader || a == A.Grd || ((a == A.Own || a == A.Sen || a == A.Opr) && breached);
            if (!mayExit) {
                if (f == 9 || a != A.Opr) return U;
                return E.ReduceAboveShortfall.selector; // no shortfall: the cap is 0
            }
            return pending;
        }
        if (f == 11 || f == 12 || f == 13) {
            bool sen = a == A.Sen && breached;
            if (!trader && !sen) return U;
            if (f == 12 && breached) return E.SlNotTighter.selector;
            if (f == 13 && !trader) return U;
            return OK;
        }
        if (f == 14) {
            if (!trader && a != A.Sen) return U;
            // GR1-16: a full stop already cancelled the resting limit order (the mock refuses a second cancel)
            return stop ? ERR_STRING : OK;
        }
        if (f == 15 || f == 41) {
            bool listed = a == A.Mgr || a == A.Own || a == A.Grd || a == A.Sen || a == A.Opr;
            if (!listed) return U;
            if (a != A.Mgr && a != A.Grd && !breached) return U;
            return OK;
        }
        if (f == 16 || f == 42) return a == A.Mgr || (a == A.Grd && em) ? OK : U;
        if (f == 43) return U; // setSequencerFeed: onlySelf (GR1-10)
        if (f == 18) return s == S.BL ? E.NotReady.selector : E.NotClearable.selector;
        if (f == 19) return a == A.Own || a == A.Grd || a == A.Sen ? OK : U;
        if (f == 20) return a == A.Own || a == A.Grd || s == S.OD ? OK : E.NotOverdue.selector;
        if (f == 21) {
            if (a != A.Grd) return U;
            if (em) return E.InEmergency.selector;
            return price;
        }
        if (f == 22) {
            if (a != A.Own) return U;
            return s == S.BW ? E.NotReady.selector : E.NotClearable.selector;
        }
        if (f == 23) {
            if (a != A.Grd) return U;
            return s == S.OD ? E.RedemptionsPending.selector : OK;
        }
        if (f == 24 || f == 31 || f == 37) return a == A.Own ? OK : U;
        if (f == 25 || f == 27 || f == 29) return a == A.Own || a == A.Grd || a == A.Sen ? OK : U;
        if (f == 26) return a == A.Own || a == A.Grd || a == A.Sen || a == A.Fac ? OK : U;
        if (f == 28 || f == 30) return a == A.Own || a == A.Grd ? OK : U;
        if (f == 32) return a == A.Own ? price : U;
        if (f == 33) return a == A.Own ? OK : OwnableUpgradeable.OwnableUnauthorizedAccount.selector;
        if (f == 34 || f == 36) return U;
        if (f == 35) return a == A.Own ? OK : U;
        if (f == 38) return a == A.Fac ? OK : U;
        if (f == 39) return a == A.Own || a == A.Grd ? OK : U;
        return OK; // execute after eta: anyone
    }

    /// @dev One test per state (a single test over every cell exceeds the per-test gas limit).
    /// The counters are locals: _enter reverts to the base snapshot, which would reset a storage counter every cell.
    function _runState(S s) internal {
        uint256 cells;
        uint256 mismatches;
        for (uint256 f; f < NFN; ++f) {
            for (uint256 a; a < 9; ++a) {
                _enter(s);
                bytes4 got = _call(f, A(a));
                bytes4 want = _expect(f, A(a), s);
                ++cells;
                if (got != want) {
                    ++mismatches;
                    console2.log("MISMATCH state/fn/actor", uint256(s), f, a);
                    console2.logBytes4(got);
                    console2.logBytes4(want);
                }
            }
        }
        console2.log("cells checked", cells);
        assertEq(mismatches, 0, "ACCESS-MATRIX.md disagrees with the contract");
    }

    function test_accessMatrix_N() public { _runState(S.N); }
    function test_accessMatrix_DP() public { _runState(S.DP); }
    function test_accessMatrix_TP() public { _runState(S.TP); }
    function test_accessMatrix_BL() public { _runState(S.BL); }
    function test_accessMatrix_BD() public { _runState(S.BD); }
    function test_accessMatrix_BW() public { _runState(S.BW); }
    function test_accessMatrix_BG() public { _runState(S.BG); }
    function test_accessMatrix_EM() public { _runState(S.EM); }
    function test_accessMatrix_OD() public { _runState(S.OD); }
    function test_accessMatrix_OP() public { _runState(S.OP); }
    function test_accessMatrix_FS() public { _runState(S.FS); }
    function test_accessMatrix_SD() public { _runState(S.SD); }
}
