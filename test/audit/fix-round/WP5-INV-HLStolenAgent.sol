// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {HyperVault} from "../../../src/HyperVault.sol";
import {VaultPolicy} from "../../../src/VaultPolicy.sol";
import {HyperCore} from "../../../src/hypercore/HyperCore.sol";
import {TICKET_CLOID_PREFIX} from "../../../src/VaultTypes.sol";
import {MockUSDC} from "../../mocks/Mocks.sol";
import {CoreSim} from "../hl-r2/async/CoreSim.sol";
import {ConservationHandler} from "../hl-r2/async/ConservationHandler.sol";
import {CoreSimAdv} from "./WP5-INV-HLCoreSimAdv.sol";

/// @notice WP5 (fix round): the hl-r2 conservation handler plus a stolen-agent actor. Every `sa*` action is a call
///         from the vault's agent address, with fuzzed arguments, on every entry point the agent can reach (and the
///         ones it should not: those must revert). The agent's orders fill at their own limit price (CoreSimAdv), so
///         the actor trades at the worst price the vault's band lets through and pays the taker fee.
///         Ghosts: per UTC day, the agent's opened notional (the vault's own turnover formula) and the largest NAV
///         the vault could have read that day; the loss itself is booked per fill in CoreSimAdv.
contract WP5HLStolenAgentHandler is ConservationHandler {
    using Math for uint256;

    CoreSimAdv public immutable adv;
    uint256 public immutable bandBps; // policy maxSlippageBps
    uint256 public immutable dailyLossBps; // policy maxDailyLossBps

    // ---------------- stolen agent: coverage ----------------
    uint256 public saCalls;
    uint256 public saOrdersSent; // placeOrder accepted by the vault
    uint256 public saOrdersOpen; // ... not reduce only
    uint256 public saOrdersReduce;
    uint256 public saOrdersRefused; // OrderRefused (the risk check before the order breached)
    uint256 public saOrdersReverted;
    uint256 public saOutsidePolicyAccepted; // an order on an asset outside the policy that was not reduce only (must stay 0)
    uint256 public saBadTifAccepted; // a non-IOC / zero cloid / ticket cloid order accepted (must stay 0)
    uint256 public saOtherAccepted; // a call the agent must not be able to make went through (must stay 0)
    uint256 public saOtherReverted;
    uint256 public saPublicOk; // permissionless calls that succeeded as the agent (checkRisk, syncBridge, ...)
    uint256 public saSettles;
    uint256 public saCancels;
    uint256 public saChurnRounds;

    // ---------------- stolen agent: per UTC day ----------------
    mapping(uint256 day => uint256) public openNtlDay; // vault turnover formula: max(limit, mark) x sz / 1e10
    mapping(uint256 day => uint256) public navMaxDay; // max NAV the vault could read for the turnover check
    mapping(uint256 day => uint256) public ordersHour; // risk-adding orders per clock hour (key: hour)
    uint256[] public days_;
    mapping(uint256 => bool) internal _seenDay;
    uint256 public vTurnover; // opened notional in a UTC day above maxTurnoverBps x NAV
    uint256 public vOrderRate; // more risk-adding orders in a clock hour than maxOrdersPerHour
    uint128 internal _lastCloid = 1;

    constructor(
        HyperVault v,
        CoreSimAdv s,
        MockUSDC u,
        address[13] memory r,
        uint256 band_,
        uint256 dailyLoss_
    ) ConservationHandler(v, CoreSim(address(s)), u, r, false) {
        adv = s;
        bandBps = band_;
        dailyLossBps = dailyLoss_;
    }

    function daysCount() external view returns (uint256) {
        return days_.length;
    }

    function _day() internal returns (uint256 d) {
        d = _ts() / 1 days;
        if (!_seenDay[d]) {
            _seenDay[d] = true;
            days_.push(d);
        }
    }

    /// @dev navMaxDay: the largest NAV the vault's turnover check could read today (VaultLogic._spendAgentLimits:
    ///      idle + coreEquity, and while a bridge is pending min(that + bridgeAmount, equityAtBridge)), or the true NAV
    ///      if larger. trueNavMaxDay: the largest true NAV (what the depositors own).
    ///      WP5 finding (inv-report.md, HL-INV-01): while a to-Core bridge is pending its amount counts in that read even
    ///      when HyperCore never credits it, so the budget can sit far above the true NAV for up to MAX_UNLANDED_BLOCKS.
    function _noteNav(uint256 d) internal {
        uint256 t = trueNav();
        uint256 r = vault.idleAssets() + vault.coreEquity();
        uint256 n = t > r ? t : r;
        if (vault.bridgePending()) {
            uint256 visible = r + vault.bridgeAmount();
            uint256 eb = vault.equityAtBridge();
            uint256 read = visible < eb ? visible : eb;
            if (read > n) n = read;
        }
        if (n > navMaxDay[d]) navMaxDay[d] = n;
        if (t > trueNavMaxDay[d]) trueNavMaxDay[d] = t;
    }

    mapping(uint256 day => uint256) public trueNavMaxDay;
    uint256 public mTurnoverAboveTrueNav; // agent orders that took the day's opened notional above 20 x the true NAV (measured)

    function _asset(uint256 seed) internal pure returns (uint32) {
        uint256 k = seed % 12;
        if (k < 5) return 0; // BTC (in the policy)
        if (k < 9) return 1; // ETH (in the policy)
        if (k == 9) return 2; // listed on Core, outside the policy
        if (k == 10) return uint32(seed >> 8); // anything (mostly unlisted)
        return uint32(HyperCore.SPOT_ASSET_OFFSET + ((seed >> 8) % 300)); // spot
    }

    function _mark1e8(uint32 a) internal view returns (uint256 m, uint8 d, bool listed) {
        listed = sim.listed(a);
        if (!listed) return (0, 0, false);
        d = sim.szDecimals(a);
        m = uint256(sim.markRaw(a)) * 10 ** (2 + d);
    }

    /// @dev Band edge on the adverse side (what a thief does), anywhere inside, just outside, or far off.
    function _limit(uint256 m, bool isBuy, uint256 seed) internal view returns (uint64) {
        uint256 k = seed % 10;
        if (m == 0 || k == 9) return uint64(bound(seed >> 8, 1, type(uint64).max)); // far off / no mark
        uint256 off;
        if (k < 5) off = bandBps; // the adverse edge
        else if (k < 7) off = bound(seed >> 8, 0, bandBps); // inside, adverse
        else if (k == 7) off = bandBps + bound(seed >> 8, 1, 300); // just outside: refused
        else off = bound(seed >> 8, 0, 2_000); // anywhere, favourable side (fills only if the mark crosses)
        uint256 band = (m * off) / BPS;
        if (k == 8) return uint64(isBuy ? (m > band ? m - band : 1) : m + band);
        return uint64(isBuy ? m + band : (m > band ? m - band : 1));
    }

    /// @dev Size as a share of NAV (0.1% to 600%), whole size units; sometimes raw fuzz.
    function _size(uint32 a, uint256 m, uint8 d, uint256 seed) internal view returns (uint64) {
        if (m == 0 || seed % 16 == 0) return uint64(bound(seed >> 4, 0, type(uint64).max));
        uint256 nav = trueNav();
        uint256 ntl = nav.mulDiv(bound(seed >> 4, 10, 60_000), BPS); // 6 dec
        uint256 raw = sim.markRaw(a);
        uint256 units = ntl / raw; // raw size units
        if (units == 0) units = 1;
        uint256 sz = units * 10 ** (8 - d);
        return sz > type(uint64).max ? type(uint64).max : uint64(sz);
    }

    function _cloid(uint256 seed) internal returns (uint128 c) {
        uint256 k = seed % 10;
        if (k == 0) return 0;
        if (k == 1) return (TICKET_CLOID_PREFIX << 96) | uint128(uint96(seed >> 8));
        if (k <= 3) return _lastCloid; // reuse
        c = uint128(bound(seed >> 8, 1, type(uint128).max));
        if (c >> 96 == TICKET_CLOID_PREFIX) c ^= uint128(1) << 127;
        _lastCloid = c;
    }

    function _tif(uint256 seed) internal pure returns (uint8) {
        uint256 k = seed % 10;
        if (k < 7) return HyperCore.TIF_IOC;
        return uint8(seed >> 8);
    }

    // ==================================================================
    // Stolen agent: orders
    // ==================================================================
    function saPlaceOrder(uint256 assetSeed, bool isBuy, uint256 pxSeed, uint256 szSeed, bool reduceOnly, uint256 tifSeed, uint256 cloidSeed)
        external
        step("saPlaceOrder")
    {
        uint32 a = _asset(assetSeed);
        (uint256 m, uint8 d,) = _mark1e8(a);
        uint64 limit = _limit(m, isBuy, pxSeed);
        uint64 sz = _size(a, m, d, szSeed);
        if (reduceOnly == false && szSeed % 7 == 0) reduceOnly = true; // closes are frequent
        _order(a, isBuy, limit, sz, reduceOnly, _tif(tifSeed), _cloid(cloidSeed));
    }

    /// @dev The thief's best loop: open at the adverse band edge, let it fill, close it reduce only at the adverse
    ///      edge, `n` times (1 block between orders).
    function saChurn(uint256 seed, uint256 n) external step("saChurn") {
        n = bound(n, 1, 8);
        uint32 a = uint32(seed % 2);
        (uint256 m, uint8 d,) = _mark1e8(a);
        for (uint256 i; i < n; ++i) {
            bool isBuy = (seed >> (i + 1)) % 2 == 0;
            (m, d,) = _mark1e8(a);
            uint64 sz = _size(a, m, d, uint256(keccak256(abi.encode(seed, i))) | 1);
            _order(a, isBuy, _limit(m, isBuy, 0), sz, false, HyperCore.TIF_IOC, uint128((seed % 1e30) + 1 + i));
            _tick1();
            (m, d,) = _mark1e8(a);
            _order(a, !isBuy, _limit(m, !isBuy, 0), sz, true, HyperCore.TIF_IOC, uint128((seed % 1e30) + 8 + i));
            _tick1();
            ++saChurnRounds;
        }
    }

    function _tick1() internal {
        vm.roll(_bn() + 1);
        vm.warp(_ts() + 1);
        sim.process();
    }

    function _order(uint32 a, bool isBuy, uint64 limit, uint64 sz, bool ro, uint8 tif, uint128 cloid) internal {
        ++saCalls;
        uint256 d = _day();
        _noteNav(d);
        (uint256 m,, bool listed) = _mark1e8(a);
        bool allowedAsset = listed && policy.isAssetAllowed(a);
        uint256 orders0 = _flowOrders();
        adv.setTag(1);
        vm.prank(agent);
        try vault.placeOrder(a, isBuy, limit, sz, ro, tif, cloid) {
            adv.setTag(0);
            if (!ro && _flowOrders() == orders0) {
                ++saOrdersRefused;
                return;
            }
            ++saOrdersSent;
            if (tif != HyperCore.TIF_IOC || cloid == 0 || cloid >> 96 == TICKET_CLOID_PREFIX) ++saBadTifAccepted;
            if (ro) {
                ++saOrdersReduce;
            } else {
                ++saOrdersOpen;
                if (!allowedAsset) ++saOutsidePolicyAccepted;
                openNtlDay[d] += ((limit > m ? uint256(limit) : m) * uint256(sz)) / 1e10;
                uint256 h = _ts() / 1 hours;
                ++ordersHour[h];
                (uint256 maxTurn, uint256 maxOrders) = _agentLimits();
                if (openNtlDay[d] * BPS > maxTurn * navMaxDay[d] + BPS) ++vTurnover;
                if (openNtlDay[d] * BPS > maxTurn * trueNavMaxDay[d] + BPS) ++mTurnoverAboveTrueNav;
                if (ordersHour[h] > maxOrders) ++vOrderRate;
            }
        } catch {
            adv.setTag(0);
            ++saOrdersReverted;
        }
    }

    /// @dev OrderRefused is an event: a refused risk-adding order spends nothing, so the vault's count of the agent's
    ///      risk-adding orders does not move.
    function _flowOrders() internal view returns (uint256 orders) {
        (, orders) = vault.agentFlow();
    }

    function _agentLimits() internal view returns (uint256 turn, uint256 orders) {
        VaultPolicy.AgentLimits memory l = policy.agentLimits();
        return (l.maxTurnoverBps, l.maxOrdersPerHour);
    }

    function saCancel(uint256 assetSeed, uint64 oid) external step("saCancel") {
        ++saCalls;
        vm.prank(agent);
        try vault.cancelOrder(_asset(assetSeed), oid) {
            ++saCancels;
        } catch {}
    }

    // ==================================================================
    // Stolen agent: everything else it can call (permissionless calls succeed; role calls must revert)
    // ==================================================================
    function saPublic(uint256 k) external step("saPublic") {
        ++saCalls;
        k = k % 7;
        Pre memory p = _pre();
        vm.prank(agent);
        bool ok;
        if (k == 0) (ok,) = address(vault).call(abi.encodeCall(HyperVault.checkRisk, ()));
        else if (k == 1) (ok,) = address(vault).call(abi.encodeCall(HyperVault.clearLeverageBreach, ()));
        else if (k == 2) (ok,) = address(vault).call(abi.encodeCall(HyperVault.syncBridge, ()));
        else if (k == 3) (ok,) = address(vault).call(abi.encodeCall(HyperVault.pinAccountMode, ()));
        else if (k == 4) (ok,) = address(vault).call(abi.encodeCall(HyperVault.syncAgent, ()));
        else if (k == 5) (ok,) = address(vault).call(abi.encodeCall(HyperVault.triggerEmergency, ())); // only when overdue
        else {
            (ok,) = address(vault).call(abi.encodeCall(HyperVault.accrueFees, ()));
            if (ok) _checkFees(p, false);
        }
        if (ok) ++saPublicOk;
    }

    /// @dev Calls the agent must never get through: each must revert.
    function saForbidden(uint256 k, uint256 amt) external step("saForbidden") {
        ++saCalls;
        k = k % 17;
        bytes memory c;
        if (k == 0) c = abi.encodeCall(HyperVault.flatten, (uint32(amt % 2), 0));
        else if (k == 1) c = abi.encodeCall(HyperVault.flatten, (uint32(amt % 2), bound(amt, 1, 300)));
        else if (k == 2) c = abi.encodeCall(HyperVault.moveUsd, (bound(amt, 1, 1e12), amt % 2 == 0));
        else if (k == 3) c = abi.encodeCall(HyperVault.bridgeToEvm, (bound(amt, 1, 1e12)));
        else if (k == 4) c = abi.encodeCall(HyperVault.bridgeToCore, (bound(amt, 1, 1e12)));
        else if (k == 5) c = abi.encodeCall(HyperVault.triggerBreach, ());
        else if (k == 6) c = abi.encodeCall(HyperVault.clearBreach, ());
        else if (k == 7) c = abi.encodeCall(HyperVault.exitEmergency, ());
        else if (k == 8) c = abi.encodeCall(HyperVault.resume, ());
        else if (k == 9) c = abi.encodeCall(HyperVault.revokeAgent, ());
        else if (k == 10) c = abi.encodeCall(HyperVault.setAgent, (agent));
        else if (k == 11) c = abi.encodeCall(HyperVault.queue, (abi.encodeCall(HyperVault.setFees, (500, 3_000))));
        else if (k == 12) c = abi.encodeCall(HyperVault.lowerFees, (0, 0));
        else if (k == 13) c = abi.encodeCall(HyperVault.setTradingPaused, (amt % 2 == 0));
        else if (k == 14) c = abi.encodeCall(HyperVault.setDepositsPaused, (amt % 2 == 0));
        else if (k == 15) c = abi.encodeCall(HyperVault.leaveHosted, ());
        else c = abi.encodeWithSignature("transferOwnership(address)", agent);
        vm.prank(agent);
        (bool ok,) = address(vault).call(c);
        if (ok) ++saOtherAccepted;
        else ++saOtherReverted;
    }

    /// @dev The agent settles (a non-treasury caller: exit-only when allowed at all), with the fairness measurement.
    function saSettle(uint256 seed) external step("saSettle") {
        ++saCalls;
        if (seed % 3 == 0) vault.checkRisk();
        Pre memory p = _pre();
        bool lossBreach = !p.emergency && p.breached && (p.reason == 2 || p.reason == 3);
        bool exitOnly = p.emergency || !lossBreach;
        vm.prank(agent);
        try vault.settle() {
            ++saSettles;
            _afterSettle(p, exitOnly, lossBreach);
        } catch {}
    }

    /// @dev The agent claims for a depositor: the depositor gets exactly the epoch record, the agent nothing.
    function saClaimFor(uint256 seed) external step("saClaimFor") {
        ++saCalls;
        address u = _users[seed % _users.length];
        (uint256 iS, uint256 iA,, bool settled) = _ideal(u);
        if (!settled) return;
        uint256 s0 = vault.balanceOf(u);
        uint256 b0 = usdc.balanceOf(u);
        vm.prank(agent);
        try vault.claim(u) {
            _checkDelta(u, true, iS, iA, s0, b0, 0, 0);
        } catch {}
    }

    function dayAt(uint256 i) external view returns (uint256) {
        return days_[i];
    }

    uint256 public saRebinds;

    /// @dev After a full stop revoked it, the owner binds the same (stolen) agent again through the timelock, so runs
    ///      keep an agent (the hl-r2 handler has no rebind). Warps to the queued item's eta (at most 15 days).
    function saRebind(uint256 seed) external step("saRebind") {
        if (vault.agent() != address(0) || seed % 4 != 0) return;
        bytes memory data = abi.encodeCall(HyperVault.setAgent, (agent));
        vm.prank(owner);
        try vault.queue(data) returns (bytes32 id) {
            uint256 eta = vault.queuedEta(id);
            if (eta > _ts() + 15 days) return;
            if (eta > _ts()) {
                uint256 dt = eta - _ts();
                vm.roll(_bn() + dt);
                vm.warp(_ts() + dt);
                sim.process();
            }
            try vault.execute(data) {
                ++saRebinds;
            } catch {}
        } catch {}
    }

    /// @dev Largest agent loss of a UTC day as bps of that day's largest NAV, and the largest part above the daily loss
    ///      limit (both measured, reported).
    /// @dev Same against the day's largest true NAV.
    function maxDayLossBpsTrue() external view returns (uint256 m) {
        for (uint256 i; i < days_.length; ++i) {
            uint256 nav = trueNavMaxDay[days_[i]];
            if (nav == 0) continue;
            uint256 b = (adv.agentLossDay(days_[i]) * BPS) / nav;
            if (b > m) m = b;
        }
    }

    function maxDayLossBps() external view returns (uint256 m) {
        for (uint256 i; i < days_.length; ++i) {
            uint256 nav = navMaxDay[days_[i]];
            if (nav == 0) continue;
            uint256 b = (adv.agentLossDay(days_[i]) * BPS) / nav;
            if (b > m) m = b;
        }
    }
}
