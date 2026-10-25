// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Base} from "./Base.t.sol";
import {HyperVault} from "../src/HyperVault.sol";
import {MockUSDC, MockPrecompile} from "./mocks/Mocks.sol";
import {HyperCore} from "../src/hypercore/HyperCore.sol";

/// @dev Drives a standalone vault (owner, manager, operator, guardian = sentinel) through deposits, redemptions,
///      settles by the manager and the operator, fee accruals, price moves, risk checks, breaches and emergencies,
///      and lets strangers, depositors and the operator try everything they must not do.
contract Round4Handler is CommonBase, StdCheats, StdUtils {
    HyperVault internal vault;
    MockUSDC internal usdc;
    address internal owner;
    address internal manager;
    address internal operator;
    address internal guardian;
    address internal stranger = address(0xBAD);
    address[3] internal actors = [address(0xA1), address(0xA2), address(0xA3)];

    int64 public perp; // Core perp equity the mock reports
    uint64 public ntl; // open notional

    // ghost violations (must stay 0)
    uint256 public vFlowMovedMetrics; // bps the settle / fee accrual moved daily loss or drawdown, beyond rounding
    uint256 public vOutsiderActed; // a stranger or depositor flattened, bridged or settled in breach / emergency
    uint256 public vOperatorEscaped; // the operator reached a non treasury function
    uint256 public vExposureUp; // an exposure increasing order went through in reduce only mode
    uint256 public settles;
    uint256 public breaches;

    constructor(HyperVault v, MockUSDC u, address o, address m, address op, address g) {
        vault = v;
        usdc = u;
        owner = o;
        manager = m;
        operator = op;
        guardian = g;
        for (uint256 i; i < 3; ++i) {
            u.mint(actors[i], 10_000_000e6);
            vm.prank(actors[i]);
            u.approve(address(v), type(uint256).max);
        }
    }

    /// @dev The transfer lands on Core spot, the landing is latched, then the mock moves it on to perp.
    function _landOnSpot(uint256 amt) internal {
        MockPrecompile(HyperCore.PRECOMPILE_SPOT_BALANCE).setResponse(
            abi.encode(address(vault), uint64(0)), abi.encode(HyperCore.SpotBalance(uint64(amt) * 100, 0, 0))
        );
        vault.syncBridge();
    }

    function _setCore() internal {
        MockPrecompile(HyperCore.PRECOMPILE_ACCOUNT_MARGIN_SUMMARY).setResponse(
            abi.encode(uint32(0), address(vault)), abi.encode(HyperCore.AccountMarginSummary(perp, 0, ntl, perp))
        );
        MockPrecompile(HyperCore.PRECOMPILE_SPOT_BALANCE).setResponse(
            abi.encode(address(vault), uint64(0)), abi.encode(HyperCore.SpotBalance(0, 0, 0))
        );
        MockPrecompile(HyperCore.PRECOMPILE_WITHDRAWABLE).setResponse(abi.encode(address(vault)), abi.encode(perp > 0 ? uint64(perp) : uint64(0)));
    }

    /// @dev daily loss and drawdown as checkRisk would compute them from the stored references (no state change)
    function _metrics() internal view returns (uint256 daily, uint256 dd, bool dust) {
        uint256 ta = vault.totalAssets();
        uint256 s = vault.totalSupply();
        if (s == 0 || ta < 1e6) return (0, 0, true);
        uint256 price = ((ta + 1) * 1e12) / (s + 1e6);
        uint256 start = vault.dayStartSharePrice();
        uint256 peak = vault.peakSharePrice();
        if (start > price) daily = ((start - price) * 10_000) / start;
        if (peak > price) dd = ((peak - price) * 10_000) / peak;
    }

    function _dev(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    // ------------------------------------------------------------------ flows
    function deposit(uint256 who, uint256 amt) external {
        amt = bound(amt, 1e6, 500_000e6);
        vm.prank(actors[who % 3]);
        try vault.requestDeposit(amt, actors[who % 3]) {} catch {}
    }

    function redeem(uint256 who, uint256 pct) external {
        address a = actors[who % 3];
        try vault.claim(a) {} catch {}
        uint256 sh = (vault.balanceOf(a) * bound(pct, 1, 100)) / 100;
        if (sh == 0) return;
        vm.prank(a);
        try vault.requestRedeem(sh, a, a) {} catch {}
    }

    function claim(uint256 who) external {
        try vault.claim(actors[who % 3]) {} catch {}
    }

    /// @dev Brings home what the queue needs (landed), then the manager or the operator settles.
    function settle(bool byOperator) external {
        uint256 owed = vault.convertToAssets(vault.pendingRedeemShares()) + 2e6;
        uint256 idle = vault.idleAssets();
        if (owed > idle && !vault.bridgeInFlight()) {
            uint256 need = owed - idle;
            if (need < 100e6) need = 100e6;
            if (perp > int64(uint64(need))) {
                vm.prank(manager);
                try vault.bridgeToEvm(need) {
                    perp -= int64(uint64(need));
                    usdc.mint(address(vault), need);
                    _setCore();
                    vault.syncBridge();
                } catch {}
            }
        }
        vm.roll(vm.getBlockNumber() + 11);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        try vault.checkRisk() {} catch {}
        (uint256 d0, uint256 dd0, bool dust0) = _metrics();
        bool b0 = vault.breached();
        vm.prank(byOperator ? operator : manager);
        try vault.settle() {
            settles++;
            (uint256 d1, uint256 dd1, bool dust1) = _metrics();
            // flows settle at the share price: neither metric moves beyond rounding (1 bp)
            if (!dust0 && !dust1 && b0 == vault.breached()) {
                uint256 m = _dev(d0, d1) > _dev(dd0, dd1) ? _dev(d0, d1) : _dev(dd0, dd1);
                if (m > 1 && m > vFlowMovedMetrics) vFlowMovedMetrics = m;
            }
        } catch {}
    }

    function bridgeOut(uint256 amt) external {
        uint256 idle = vault.idleAssets();
        if (idle < 100e6) return;
        amt = bound(amt, 100e6, idle);
        vm.prank(operator);
        try vault.bridgeToCore(amt) {
            _landOnSpot(amt);
            perp += int64(uint64(amt));
            _setCore();
        } catch {}
        vm.roll(vm.getBlockNumber() + 11);
    }

    function accrue(uint256 secs) external {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 1 hours, 20 hours));
        (uint256 d0, uint256 dd0, bool dust0) = _metrics();
        try vault.accrueFees() {
            (uint256 d1, uint256 dd1, bool dust1) = _metrics();
            if (!dust0 && !dust1) {
                uint256 m = _dev(d0, d1) > _dev(dd0, dd1) ? _dev(d0, d1) : _dev(dd0, dd1);
                if (m > 1 && m > vFlowMovedMetrics) vFlowMovedMetrics = m;
            }
        } catch {}
    }

    // ------------------------------------------------------------------ market and risk
    function move(int256 bps, uint256 lev) external {
        bps = bound(bps, -300, 300); // ordinary moves; crash() below is the rare big one
        int256 p = int256(perp) + (int256(perp) * bps) / 10_000;
        perp = int64(p > 0 ? p : int256(0));
        ntl = uint64((uint256(uint64(perp)) * bound(lev, 0, 40_000)) / 10_000);
        _setCore();
        try vault.checkRisk() {} catch {}
        if (vault.breached()) breaches++;
    }

    function crash(uint256 what) external {
        if (what % 8 != 0) return;
        perp = int64((int256(perp) * 7) / 10);
        _setCore();
        try vault.checkRisk() {} catch {}
        if (vault.breached()) breaches++;
    }

    function check() external {
        try vault.checkRisk() {} catch {}
    }

    function clearLeverage() external {
        vm.warp(vm.getBlockTimestamp() + 20 minutes);
        try vault.clearLeverageBreach() {} catch {}
    }

    function resume() external {
        vm.prank(owner);
        try vault.resume() {} catch {}
    }

    function guardianActs(uint256 what) external {
        uint256 w = what % 24; // rare: most runs stay in normal or risk breach states
        vm.prank(guardian);
        if (w == 0) try vault.triggerBreach() {} catch {}
        else if (w == 1 || w == 2) try vault.clearBreach() {} catch {}
        else if (w == 3) try vault.triggerEmergency() {} catch {}
        else if (w == 4) try vault.exitEmergency() {} catch {}
    }

    /// @dev seeds the vault: one depositor in, settled, on Core
    function seed() external {
        vm.prank(actors[0]);
        vault.requestDeposit(1_000_000e6, actors[0]);
        vault.checkRisk();
        vm.prank(manager);
        vault.settle();
        vault.claim(actors[0]);
        vm.prank(manager);
        vault.bridgeToCore(1_000_000e6);
        _landOnSpot(1_000_000e6);
        perp = 1_000_000e6;
        _setCore();
        vm.roll(vm.getBlockNumber() + 11);
        vault.checkRisk();
    }

    // ------------------------------------------------------------------ hostile callers
    function outsiders(uint256 who) external {
        if (!vault.breached() && !vault.emergency()) return;
        address[2] memory xs = [stranger, actors[who % 3]];
        for (uint256 i; i < 2; ++i) {
            vm.prank(xs[i]);
            try vault.flatten(0, 0) {
                vOutsiderActed++;
            } catch {}
            vm.prank(xs[i]);
            try vault.bridgeToEvm(100e6) {
                vOutsiderActed++;
            } catch {}
            vm.prank(xs[i]);
            try vault.settle() {
                vOutsiderActed++;
            } catch {}
        }
    }

    function operatorEscapes(uint256 what) external {
        vm.startPrank(operator);
        uint256 w = what % 11;
        bool ok;
        if (w == 0) try vault.placeOrder(0, true, 100_000e8, 0.01e8, false, 2, 0) { ok = true; } catch {}
        else if (w == 1) try vault.queue(abi.encodeCall(HyperVault.setManager, (operator))) { ok = true; } catch {}
        else if (w == 2) try vault.setDepositsPaused(true) { ok = true; } catch {}
        else if (w == 3) try vault.triggerBreach() { ok = true; } catch {}
        else if (w == 4) try vault.clearBreach() { ok = true; } catch {}
        else if (w == 5) try vault.setOperator(address(0xE5C)) { ok = true; } catch {}
        else if (w == 6) try vault.setDepositCap(1) { ok = true; } catch {}
        else if (w == 7) try vault.lowerFees(0, 0) { ok = true; } catch {}
        else if (w == 8) try vault.revokeAgent() { ok = true; } catch {}
        else if (w == 9) try vault.resume() { ok = true; } catch {}
        else try vault.cancelOrder(0, 1) { ok = true; } catch {}
        vm.stopPrank();
        if (ok) vOperatorEscaped++;
    }

    function exposureInReduceOnly() external {
        if (!vault.breached() && !vault.emergency()) return;
        vm.prank(manager);
        try vault.placeOrder(0, true, 100_000e8, 0.001e8, false, 2, 0) {
            vExposureUp++;
        } catch {}
        // more margin is fine in a risk breach, never in a full stop
        if (vault.emergency() || uint8(vault.breachReason()) >= 4) {
            vm.prank(operator);
            try vault.moveUsd(1e6, true) {
                vExposureUp++;
            } catch {}
        }
    }
}

contract Round4Invariants is Base {
    Round4Handler internal h;
    address internal operator = makeAddr("operator");

    function setUp() public override {
        super.setUp();
        vm.prank(owner);
        vault.setOperator(operator);
        h = new Round4Handler(vault, usdc, owner, manager, operator, guardian);
        h.seed();
        targetContract(address(h));
        bytes4[] memory skip = new bytes4[](1);
        skip[0] = Round4Handler.seed.selector;
        excludeSelector(FuzzSelector({addr: address(h), selectors: skip}));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 120
    /// forge-config: default.invariant.fail-on-revert = false
    /// forge-config: default.invariant.show-metrics = true
    function invariant_flowsAndFeesNeverMoveTheRiskMetrics() public view {
        assertEq(h.vFlowMovedMetrics(), 0, "deposit / redeem / fee flows moved daily loss or drawdown");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 120
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_onlyListedRolesUnwind() public view {
        assertEq(h.vOutsiderActed(), 0, "a stranger or depositor flattened, bridged or settled");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 120
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_operatorStaysInTheTreasury() public view {
        assertEq(h.vOperatorEscaped(), 0, "the operator reached a non treasury function");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 120
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_reduceOnlyNeverIncreasesExposure() public view {
        assertEq(h.vExposureUp(), 0, "exposure went up in reduce only mode");
    }

    function afterInvariant() external {
        emit log_named_uint("settles", h.settles());
        emit log_named_uint("breach observations", h.breaches());
    }
}

contract Round4HandlerSanity is Base {
    function test_handlerSettles() public {
        address op = makeAddr("operator");
        vm.prank(owner);
        vault.setOperator(op);
        Round4Handler h = new Round4Handler(vault, usdc, owner, manager, op, guardian);
        h.seed();
        h.deposit(1, 5_000e6);
        h.settle(true);
        h.redeem(0, 10);
        h.move(-100, 10_000);
        h.settle(false);
        h.accrue(5 hours);
        h.deposit(2, 1_000e6);
        h.settle(true);
        assertGe(h.settles(), 3, "the handler really settles");
    }
}
