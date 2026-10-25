// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {R1Base} from "../../R1Base.t.sol";
import {GovBase} from "../../gov/GovBase.t.sol";
import {GainsVault} from "../../../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../../../src/gains/GainsVaultPolicy.sol";
import {GainsVaultFactory} from "../../../../../src/gains/GainsVaultFactory.sol";
import {IGainsDiamond} from "../../../../../src/gains/IGainsDiamond.sol";
import {InitParams, OpenParams, IGainsVaultErrors} from "../../../../../src/gains/GainsTypes.sol";

/// @notice GR2-KEY-01b fix test, mock diamond (contracts/audit/gains/r2/fixes/GR2-KEY-01b, FIX-DESIGN.md A). Asserts
///         the FIXED behaviour on top of the GR2-KEY-01 patch. It imports no KEY-01 / KEY-01b constant and calls the
///         factory's pair-cap functions by signature, so it compiles on the KEY-01 tree, on the first KEY-01b tree (cap
///         a constant) and on this one: the KEY01b_fix tests fail on the trees without the respective part, the GUARD
///         tests pass on all. Run it from contracts/test/audit/gains/r2/fixes/.
///         Local copies: MIN_HOLD 10 min, MIN_HOLD_L2_BLOCKS 2,400 (block.number off Arbitrum), TURNOVER_NAV_MULTIPLE 20,
///         DEFAULT_PAIR_SKEW_CAP_BPS 100, MAX_PAIR_SKEW_CAP_BPS 1,000, PAIR_CAP_RAISE_DELAY 31 days (policy MAX_EPOCH_DURATION
///         30 days + 1 day).
contract KEY01bFixTest is R1Base {
    bytes4 internal constant SKEW_DEPTH = bytes4(keccak256("getPairSkewDepth(uint8,uint16)"));
    uint8 internal constant CI = 3;
    uint256 internal constant HOLD = 10 minutes;
    uint256 internal constant HOLD_BLOCKS = 2_400;
    uint256 internal constant K = 20;

    function _live() internal pure returns (GainsVaultPolicy.RiskConfig memory) {
        return GainsVaultPolicy.RiskConfig({
            maxLeverageBps: 50_000,
            maxDailyLossBps: 1_500,
            maxDrawdownBps: 5_000,
            maxSlippageBps: 100,
            maxOrderNotional: 250_000e6,
            maxEpochDuration: 1 days,
            maxNavMoveBps: 2_000,
            maxFlattenSlippageBps: 300
        });
    }

    function _mk(uint256 nav) internal returns (GainsVault v) {
        uint32[] memory assets = new uint32[](2);
        assets[0] = BTC;
        assets[1] = ETH;
        v = GainsVault(Clones.clone(address(vaultImpl)));
        GainsVaultPolicy p = GainsVaultPolicy(Clones.clone(address(policyImpl)));
        p.initialize(owner, _live(), assets, 2 days, address(platform), address(v));
        InitParams memory ip = _standaloneParams(p);
        ip.managementFeeBps = 0;
        ip.performanceFeeBps = 0;
        ip.timelockDelay = 2 days;
        v.initialize(ip);
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        _depositTo(v, alice, nav);
        _settleV(v);
        v.claim(alice);
    }

    function _waitHold() internal {
        _skip(HOLD);
        vm.roll(vm.getBlockNumber() + HOLD_BLOCKS);
    }

    function _try(GainsVault v, uint16 pair, uint120 coll, uint24 lev) internal returns (bool ok) {
        OpenParams memory p = _params(pair, true, coll, lev);
        vm.prank(manager);
        try v.openTrade(p) {
            ok = true;
            _fillLast(v, _px(pair));
        } catch {}
    }

    function _minHold() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IGainsVaultErrors.OrderRejected.selector, "min hold");
    }

    // ------------------------------------------------------------------ (1) the cap's size, standalone vault
    /// @notice A standalone vault (no factory) caps every pair at DEFAULT_PAIR_SKEW_CAP_BPS = 1 % of the 1 % skew depth
    ///         (FIX-DESIGN.md A1 / B: the counter-trade double swing beats 5 %). With depth set so that 1 % is 300k: 250k
    ///         fits, 100k more is refused (at 5 % it would fit).
    function test_KEY01b_fix_pairCapIsOnePercentOfSkewDepth() public {
        GainsVault v = _mk(1_000_000e6);
        uint256 depth = uint256(300_000e6) * 1e22 * 10_000 / (100 * uint256(_px(ETH)));
        vm.mockCall(address(diamond), abi.encodeWithSelector(SKEW_DEPTH, CI, ETH), abi.encode(depth));
        assertTrue(_try(v, ETH, 10_000e6, 25_000), "250k fits");
        OpenParams memory p = _params(ETH, true, 4_000e6, 25_000);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IGainsVaultErrors.OrderRejected.selector, "pair depth"));
        v.openTrade(p); // 350k > 300k
    }

    // ------------------------------------------------------------------ (3) minimum hold
    /// @notice The manager's and the agent's close and reduce inside the hold are refused; after it they go through.
    function test_KEY01b_fix_minHold_traderExitsHeld() public {
        GainsVault v = _mk(100_000e6);
        address agent = makeAddr("agent01b");
        _setAgent(v, agent); // timelocked (2 days): settle once more so the epoch is fresh
        _settleV(v);
        uint32 a = _open(v, ETH, true, 10_000e6, 10_000);
        vm.prank(manager);
        vm.expectRevert(_minHold());
        v.closeTrade(a, _px(ETH));
        vm.prank(agent);
        vm.expectRevert(_minHold());
        v.closeTrade(a, _px(ETH));
        vm.prank(agent);
        vm.expectRevert(_minHold());
        v.reduceTrade(a, 5_000e6, 0, _px(ETH));
        vm.prank(manager);
        vm.expectRevert(_minHold());
        v.flatten(ETH, 0, _px(ETH), type(uint256).max);
        uint32[] memory idx = new uint32[](1);
        idx[0] = a;
        vm.prank(manager);
        vm.expectRevert(_minHold());
        v.flattenIndices(idx, 0, _px(ETH));
        _waitHold();
        vm.prank(agent);
        v.closeTrade(a, _px(ETH));
    }

    /// @notice The pair stamp: a new open on the pair re-arms the hold for every trade of that pair (no rotation:
    ///         open #2 then close the old #1 at once).
    function test_KEY01b_fix_minHold_newRiskOnThePairReArmsIt() public {
        GainsVault v = _mk(100_000e6);
        uint32 a = _open(v, ETH, true, 10_000e6, 10_000);
        _waitHold();
        _open(v, ETH, true, 10_000e6, 10_000);
        vm.prank(manager);
        vm.expectRevert(_minHold());
        v.closeTrade(a, _px(ETH));
        // another pair is not held
        uint32 b = _open(v, BTC, true, 10_000e6, 10_000);
        _skip(HOLD);
        vm.roll(vm.getBlockNumber() + HOLD_BLOCKS);
        vm.prank(manager);
        v.closeTrade(b, _px(BTC));
    }

    /// @notice A resting limit order filled long after its request: the pair stamp has expired, Gains'
    ///         lastPosIncreaseBlock (fill time) still holds the trade.
    function test_KEY01b_fix_minHold_lateLimitFillHeldByGainsBlock() public {
        GainsVault v = _mk(100_000e6);
        OpenParams memory p = _params(ETH, true, 10_000e6, 10_000);
        p.tradeType = 1;
        p.expectedPrice = _px(ETH) * 995 / 1000;
        vm.prank(manager);
        v.openTrade(p);
        uint32 idx = diamond.tradeCount(address(v)) - 1;
        _skip(2 hours);
        vm.roll(vm.getBlockNumber() + 30_000);
        diamond.executeLimit(address(v), idx, p.expectedPrice);
        vm.prank(manager);
        vm.expectRevert(_minHold());
        v.closeTrade(idx, _px(ETH));
        vm.roll(vm.getBlockNumber() + HOLD_BLOCKS);
        vm.prank(manager);
        v.closeTrade(idx, _px(ETH));
    }

    /// @notice GUARD (passes on every tree): platform exits are never held: the guardian at once, and the owner, the
    ///         manager himself once a breach is recorded (standalone vault: sentinel() == guardian()).
    function test_KEY01b_guard_platformAndBreachExitsNeverHeld() public {
        GainsVault v = _mk(100_000e6);
        uint32 a = _open(v, ETH, true, 10_000e6, 10_000);
        uint32 b = _open(v, ETH, true, 10_000e6, 10_000);
        uint32 c = _open(v, BTC, true, 10_000e6, 10_000);
        vm.prank(guardian);
        v.closeTrade(a, _px(ETH));
        _fillLast(v, _px(ETH));
        vm.prank(owner);
        v.triggerBreach();
        vm.prank(manager);
        v.closeTrade(b, _px(ETH));
        _fillLast(v, _px(ETH));
        vm.prank(owner);
        v.flatten(BTC, 0, _px(BTC), type(uint256).max);
        _fillLast(v, _px(BTC));
        assertFalse(diamond.getTrade(address(v), c).isOpen, "BTC closed in the breach");
    }

    /// @notice GUARD (passes on every tree): Gains' own take-profit / stop-loss closes are never held. Inside the hold
    ///         the manager may still set a stop loss and a take profit (setSlTp is not held; here a take profit already
    ///         behind the market, which Gains' bots execute at the next trigger), the manager's own close is refused,
    ///         and the bot's TP close at the same moment goes through (mock diamond: trigger = Gains' TP / SL / liq path,
    ///         which never passes through the vault).
    function test_KEY01b_guard_gainsTpSlClosesAreNotHeld() public {
        GainsVault v = _mk(100_000e6);
        uint32 a = _open(v, ETH, true, 10_000e6, 10_000);
        uint64 px = _px(ETH);
        uint64 tp = px * 999 / 1000; // behind the market for a long: Gains closes it at the next trigger
        vm.prank(manager);
        v.setSlTp(a, px * 95 / 100, tp);
        assertEq(diamond.getTrade(address(v), a).tp, tp, "TP set inside the hold");
        vm.prank(manager);
        vm.expectRevert(_minHold());
        v.closeTrade(a, px);
        uint256 idleBefore = usdc.balanceOf(address(v));
        uint256 paid = diamond.trigger(address(v), a, px); // Gains' bot, same block, inside the hold
        assertGt(paid, 0, "the bot's close paid out");
        assertEq(usdc.balanceOf(address(v)), idleBefore + paid, "to the vault");
        assertFalse(diamond.getTrade(address(v), a).isOpen, "closed by Gains inside the hold");
    }

    // ------------------------------------------------------------------ (2) turnover budget
    /// @notice Opened notional per day is bounded by 20 x NAV (token bucket refilling over a day); closes are never
    ///         refused for it. 100k vault: 2M per day. Each cycle opens 2 x 200k (4x), waits the hold, closes both.
    function test_KEY01b_fix_turnoverBudget() public {
        GainsVault v = _mk(100_000e6);
        uint256 opened;
        bool refused;
        for (uint256 cycle; cycle < 10 && !refused; ++cycle) {
            uint32[2] memory ix;
            uint256 n;
            for (uint256 j; j < 2; ++j) {
                OpenParams memory p = _params(ETH, true, 8_000e6, 25_000);
                vm.prank(manager);
                try v.openTrade(p) {
                    (ix[n],) = _fillLast(v, _px(ETH));
                    ++n;
                    opened += 200_000e6;
                } catch (bytes memory err) {
                    assertEq(err, abi.encodeWithSelector(IGainsVaultErrors.OrderRejected.selector, "turnover"), "turnover");
                    refused = true;
                    break;
                }
            }
            _waitHold();
            for (uint256 j; j < n; ++j) {
                _closeFilled(v, ix[j], _px(ETH)); // closes are never refused for turnover
            }
        }
        uint256 nav = v.totalAssets();
        console2.log("opened before the refusal / budget (USDC 1e6)", opened, nav * K);
        assertTrue(refused, "refused once the day's budget is spent");
        // budget 20 x NAV plus the refill over the cycles' hold waits (< 10 x 10 min of a 1-day bucket)
        assertLe(opened, 100_000e6 * K + 100_000e6 * K * 10 * HOLD / 1 days, "within budget + refill");
        _skip(12 hours); // refills 1M; the epoch (1 day) is not overdue yet
        assertTrue(_try(v, ETH, 8_000e6, 25_000), "the bucket refills over the day");
    }
}

/// @notice GR2-KEY-01b, revision 2: the pair cap is a per-pair factory parameter (GainsVaultFactory.pairSkewCapBps)
///         that every factory vault reads at each new-risk order. The guardian sets it; a lowering applies at once
///         (guardian or sentinel), a raise only PAIR_CAP_RAISE_DELAY (31 days: the longest epoch + 1 day, exit before
///         effect) after the guardian queued it, and only by the guardian; never above
///         MAX_PAIR_SKEW_CAP_BPS; a pair never set takes no new exposure (the guardian's first setting up to 1 % is
///         immediate). GovBase: `fv` is a factory vault (BTC, ETH; deposit cap 50k); GainsBase sets BTC / ETH / SOL to
///         100 bps on the patched tree.
contract KEY01bPairCapFixTest is GovBase {
    bytes4 internal constant SKEW_DEPTH = bytes4(keccak256("getPairSkewDepth(uint8,uint16)"));
    uint256 internal constant DELAY = 31 days;
    uint16 internal constant CEILING = 1_000;

    event PairSkewCapSet(uint16 indexed pair, uint16 bps);
    event PairSkewCapQueued(uint16 indexed pair, uint16 bps, uint256 eta);
    event PairSkewCapCancelled(uint16 indexed pair);

    // ---- the factory's pair-cap API, by signature (absent on the trees before this revision: the calls fail)
    function _capOf(GainsVaultFactory f, uint16 pair) internal view returns (uint16) {
        (bool ok, bytes memory r) = address(f).staticcall(abi.encodeWithSignature("pairSkewCapBps(uint16)", pair));
        require(ok && r.length == 32, "no per-pair cap on this tree");
        return abi.decode(r, (uint16));
    }

    function _etaOf(uint16 pair) internal view returns (uint64 eta) {
        (bool ok, bytes memory r) = address(platform).staticcall(abi.encodeWithSignature("pairSkewCap(uint16)", pair));
        require(ok && r.length == 128, "no per-pair cap on this tree");
        (,,, eta) = abi.decode(r, (uint16, bool, uint16, uint64));
    }

    function _act(GainsVaultFactory f, address who, bytes memory data) internal returns (bool ok, bytes memory ret) {
        vm.prank(who);
        (ok, ret) = address(f).call(data);
    }

    function _set(GainsVaultFactory f, address who, uint16 pair, uint16 bps) internal returns (bool ok, bytes memory ret) {
        return _act(f, who, abi.encodeWithSignature("setPairSkewCap(uint16,uint16)", pair, bps));
    }

    function _queue(address who, uint16 pair, uint16 bps) internal returns (bool ok, bytes memory ret) {
        return _act(platform, who, abi.encodeWithSignature("queuePairSkewCap(uint16,uint16)", pair, bps));
    }

    function _exec(address who, uint16 pair) internal returns (bool ok, bytes memory ret) {
        return _act(platform, who, abi.encodeWithSignature("executePairSkewCap(uint16)", pair));
    }

    function _cancel(address who, uint16 pair) internal returns (bool ok, bytes memory ret) {
        return _act(platform, who, abi.encodeWithSignature("cancelPairSkewCap(uint16)", pair));
    }

    /// @dev Bubbles the call's revert up when it failed.
    function _ok(bool ok, bytes memory ret) internal pure {
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function _err(bool ok, bytes memory ret, bytes memory expected, string memory what) internal pure {
        require(!ok, string.concat(what, ": did not revert"));
        require(keccak256(ret) == keccak256(expected), string.concat(what, ": wrong revert"));
    }

    function _invalid(uint16 bps) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("InvalidPairCap(uint16)", bps);
    }

    function _notGuardian() internal pure returns (bytes memory) {
        return abi.encodeWithSignature("NotGuardian()");
    }

    /// @dev Pair depth such that `capBpsForUsd` of it is `usd` (1e6) at the current Chainlink price.
    function _depthFor(uint16 pair, uint256 usd, uint256 capBpsForUsd) internal {
        uint256 depth = usd * 1e22 * 10_000 / (capBpsForUsd * uint256(_px(pair)));
        vm.mockCall(address(diamond), abi.encodeWithSelector(SKEW_DEPTH, uint8(3), pair), abi.encode(depth));
    }

    function _tryFv(uint16 pair, uint120 coll, uint24 lev) internal returns (bool ok, bytes memory err) {
        OpenParams memory p = _params(pair, true, coll, lev);
        vm.prank(fvManager);
        try fv.openTrade(p) {
            ok = true;
            _fillLast(fv, _px(pair));
        } catch (bytes memory e) {
            err = e;
        }
    }

    function _rejected(string memory reason) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IGainsVaultErrors.OrderRejected.selector, reason);
    }

    /// @notice A factory vault reads its pair's cap from the factory at each order; caps are per pair; a guardian or
    ///         sentinel lowering applies to the next order at once; a zero cap refuses new exposure ("pair cap").
    function test_KEY01b_fix_pairCap_factoryVaultReadsThePairCapPerPair() public {
        _fundFv(40_000e6); // policy: 3x NAV in total
        _depthFor(ETH, 60_000e6, 100); // ETH: 1 % = 60k
        _depthFor(BTC, 60_000e6, 100); // BTC: 1 % = 60k
        assertEq(_capOf(platform, ETH), 100, "ETH at 1 %");
        (bool ok,) = _tryFv(ETH, 2_000e6, 20_000);
        assertTrue(ok, "40k ETH fits under 60k");
        bytes memory err;
        (ok, err) = _tryFv(ETH, 1_500e6, 20_000);
        assertFalse(ok, "70k ETH refused");
        assertEq(err, _rejected("pair depth"), "pair depth");

        (bool s, bytes memory r) = _set(platform, platformSentinel, ETH, 50); // the hot sentinel may lower
        _ok(s, r);
        assertEq(_capOf(platform, ETH), 50, "ETH lowered at once");
        (ok, err) = _tryFv(ETH, 500e6, 10_000);
        assertFalse(ok, "5k more ETH refused: 45k > 30k");
        assertEq(err, _rejected("pair depth"), "lowered cap binds the next order");
        (ok,) = _tryFv(BTC, 2_000e6, 20_000);
        assertTrue(ok, "BTC keeps its own 1 %: 40k fits");

        (s, r) = _set(platform, platformGuardian, ETH, 0);
        _ok(s, r);
        (ok, err) = _tryFv(ETH, 500e6, 10_000);
        assertFalse(ok, "ETH closed to new exposure");
        assertEq(err, _rejected("pair cap"), "pair cap");
        assertEq(_capOf(platform, BTC), 100, "BTC untouched");
    }

    /// @notice Lowering is immediate; a raise needs the queue and the 31-day wait: NotReady at once and at 31 days - 1 s,
    ///         applied at 31 days.
    function test_KEY01b_fix_pairCap_lowerIsImmediateRaiseWaits() public {
        (bool s, bytes memory r) = _set(platform, platformGuardian, ETH, 50);
        _ok(s, r);
        assertEq(_capOf(platform, ETH), 50, "immediate");
        (s, r) = _set(platform, platformGuardian, ETH, 100);
        _err(s, r, _invalid(100), "a raise is not immediate");

        uint256 eta = vm.getBlockTimestamp() + DELAY;
        vm.expectEmit(true, false, false, true, address(platform));
        emit PairSkewCapQueued(ETH, 300, eta);
        (s, r) = _queue(platformGuardian, ETH, 300);
        _ok(s, r);
        assertEq(_capOf(platform, ETH), 50, "not yet");
        (s, r) = _exec(platformGuardian, ETH);
        _err(s, r, abi.encodeWithSignature("NotReady(uint256)", eta), "execute at once");
        _skip(DELAY - 1);
        (s, r) = _exec(platformGuardian, ETH);
        _err(s, r, abi.encodeWithSignature("NotReady(uint256)", eta), "execute 1 s early");
        _skip(1);
        vm.expectEmit(true, false, false, true, address(platform));
        emit PairSkewCapSet(ETH, 300);
        (s, r) = _exec(platformGuardian, ETH);
        _ok(s, r);
        assertEq(_capOf(platform, ETH), 300, "raised");
        assertEq(_etaOf(ETH), 0, "queue cleared");
    }

    /// @notice Only the guardian queues, executes and raises; the sentinel may only lower and cancel; nobody else
    ///         (factory owner, vault owner, manager, a stranger) may do anything.
    function test_KEY01b_fix_pairCap_onlyGuardianRaises() public {
        address[4] memory others = [platformOwner, fvOwner, fvManager, makeAddr("stranger")];
        for (uint256 i; i < others.length; ++i) {
            (bool s, bytes memory r) = _set(platform, others[i], ETH, 50);
            _err(s, r, _notGuardian(), "set by a non-guardian");
            (s, r) = _queue(others[i], ETH, 200);
            _err(s, r, _notGuardian(), "queue by a non-guardian");
        }
        (bool s2, bytes memory r2) = _set(platform, platformSentinel, ETH, 200);
        _err(s2, r2, _invalid(200), "the sentinel cannot raise");
        (s2, r2) = _queue(platformSentinel, ETH, 200);
        _err(s2, r2, _notGuardian(), "the sentinel cannot queue");
        (s2, r2) = _queue(platformGuardian, ETH, 200);
        _ok(s2, r2);
        _skip(DELAY);
        for (uint256 i; i < others.length; ++i) {
            (bool s, bytes memory r) = _exec(others[i], ETH);
            _err(s, r, _notGuardian(), "execute by a non-guardian");
            (s, r) = _cancel(others[i], ETH);
            _err(s, r, _notGuardian(), "cancel by a non-guardian");
        }
        (s2, r2) = _exec(platformSentinel, ETH);
        _err(s2, r2, _notGuardian(), "the sentinel cannot execute");
        vm.expectEmit(true, false, false, false, address(platform));
        emit PairSkewCapCancelled(ETH);
        (s2, r2) = _cancel(platformSentinel, ETH);
        _ok(s2, r2);
        (s2, r2) = _exec(platformGuardian, ETH);
        _err(s2, r2, abi.encodeWithSignature("NotQueued()"), "nothing left to execute");
        assertEq(_capOf(platform, ETH), 100, "unchanged");
    }

    /// @notice The hard ceiling: 10 % of the skew depth. A queue must raise.
    function test_KEY01b_fix_pairCap_ceiling() public {
        (bool s, bytes memory r) = _queue(platformGuardian, ETH, CEILING + 1);
        _err(s, r, _invalid(CEILING + 1), "above the ceiling");
        (s, r) = _queue(platformGuardian, ETH, 100);
        _err(s, r, _invalid(100), "not a raise");
        (s, r) = _queue(platformGuardian, ETH, CEILING);
        _ok(s, r);
        _skip(DELAY);
        (s, r) = _exec(platformGuardian, ETH);
        _ok(s, r);
        assertEq(_capOf(platform, ETH), CEILING, "10 %");
    }

    /// @notice Exit before effect: the raise delay is the policy's longest accepted epoch plus one day (31 days), and a
    ///         vault with that longest epoch launches; a raise queued at its epoch start applies a day after the epoch is
    ///         overdue (anyone can then settle it, so a redeemer who asked at the queue is out first).
    function test_KEY01b_fix_pairCap_raiseDelayIsLongestEpochPlusOneDay() public {
        (bool ok, bytes memory r) = address(fp).staticcall(abi.encodeWithSignature("MAX_EPOCH_DURATION()"));
        require(ok && r.length == 32, "no MAX_EPOCH_DURATION on this tree");
        uint256 maxEpoch = abi.decode(r, (uint256));
        assertEq(maxEpoch, 30 days, "policy bound on maxEpochDuration");
        assertEq(DELAY, maxEpoch + 1 days, "delay = longest epoch + 1 day");
        // the bound is the one the policy enforces: a 30-day epoch is accepted, 30 days + 1 s is not
        GainsVaultFactory.CreateParams memory c = _cparams(launcher, bytes32(uint256(77)), address(0));
        c.risk.maxEpochDuration = uint64(maxEpoch);
        c.timelockDelay = 30 days;
        vm.prank(launcher);
        (address va,) = platform.create(c, _noPermit());
        uint256 epochEnd = GainsVault(va).epochStartedAt() + maxEpoch;
        c = _cparams(launcher, bytes32(uint256(78)), address(0));
        c.risk.maxEpochDuration = uint64(maxEpoch + 1);
        c.timelockDelay = 30 days;
        vm.prank(launcher);
        vm.expectRevert();
        platform.create(c, _noPermit());
        // a raise queued now applies one day after that vault's epoch is overdue, not before
        (ok, r) = _queue(platformGuardian, ETH, 200);
        _ok(ok, r);
        uint256 eta = vm.getBlockTimestamp() + DELAY;
        assertEq(eta, epochEnd + 1 days, "applies a day after the longest epoch ends");
        _skip(DELAY - 1);
        (ok, r) = _exec(platformGuardian, ETH);
        _err(ok, r, abi.encodeWithSignature("NotReady(uint256)", eta), "31 days - 1 s");
        _skip(1);
        (ok, r) = _exec(platformGuardian, ETH);
        _ok(ok, r);
        assertEq(_capOf(platform, ETH), 200, "applied at 31 days");
    }

    /// @notice A lowering (here by the sentinel) drops a queued raise: a raise cannot outlive an alarm.
    function test_KEY01b_fix_pairCap_lowerDropsQueuedRaise() public {
        (bool s, bytes memory r) = _queue(platformGuardian, ETH, 500);
        _ok(s, r);
        (s, r) = _set(platform, platformSentinel, ETH, 80);
        _ok(s, r);
        assertEq(_etaOf(ETH), 0, "queue dropped");
        _skip(DELAY);
        (s, r) = _exec(platformGuardian, ETH);
        _err(s, r, abi.encodeWithSignature("NotQueued()"), "the old raise is gone");
        assertEq(_capOf(platform, ETH), 80, "stays lowered");
    }

    /// @notice A pair never set has cap 0 (no new exposure). The guardian's first setting is immediate up to 1 %, not
    ///         above, and not by the sentinel; once set, a later raise from 0 waits like any other.
    function test_KEY01b_fix_pairCap_unsetPairDefaultsToNoExposure() public {
        GainsVaultFactory f2 = new GainsVaultFactory(
            platformOwner,
            address(vaultImpl),
            address(policyImpl),
            IERC20(address(usdc)),
            IGainsDiamond(address(diamond)),
            address(sequencer),
            SEQ_GRACE,
            protocolTreasury,
            platformGuardian,
            platformSentinel
        );
        assertEq(_capOf(f2, ETH), 0, "unset = 0 = no new exposure");
        (bool s, bytes memory r) = _set(f2, platformSentinel, ETH, 100);
        _err(s, r, _invalid(100), "the sentinel cannot set a first cap");
        (s, r) = _set(f2, platformGuardian, ETH, 101);
        _err(s, r, _invalid(101), "first setting above 1 % waits");
        (s, r) = _set(f2, platformGuardian, ETH, 100);
        _ok(s, r);
        assertEq(_capOf(f2, ETH), 100, "first setting up to 1 % is immediate");
        (s, r) = _set(f2, platformGuardian, ETH, 0);
        _ok(s, r);
        (s, r) = _set(f2, platformGuardian, ETH, 100);
        _err(s, r, _invalid(100), "once set, every raise waits");
    }

    /// @notice Gas of a factory vault's openTrade (the factory read added by this revision). Logs only.
    function test_KEY01b_gas_factoryVaultOpen() public {
        _fundFv(40_000e6);
        OpenParams memory p = _params(ETH, true, 2_000e6, 10_000);
        vm.prank(fvManager);
        uint256 g = gasleft();
        fv.openTrade(p);
        console2.log("factory vault openTrade, first on the pair", g - gasleft());
        _fillLast(fv, _px(ETH));
        vm.prank(fvManager);
        g = gasleft();
        fv.openTrade(p);
        console2.log("factory vault openTrade, second on the pair", g - gasleft());
    }
}
