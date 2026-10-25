// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CIWorld} from "../ConservationWorld.sol";
import {CIHandler, CIValuer} from "../ConservationHandler.sol";
import {CIChecker} from "../ConservationChecker.sol";
import {MIN_HOLD, MIN_HOLD_L2_BLOCKS} from "../../../../../src/gains/GainsTypes.sol";

interface IHevmRoll {
    function roll(uint256) external;
}

/// @notice Round 2, domain CI: Medusa harness for the conservation invariant. Same world, handler and checks as
///         ConservationInvariants.t.sol (forge); every handler action is exposed 1:1 and every check is a property_.
///         Build and run: contracts/audit/gains/r2/CONSERVATION.md ("Medusa").
contract ConservationMedusa {
    CIWorld internal w;
    CIHandler internal h;
    CIChecker internal c;

    constructor() {
        w = new CIWorld();
        h = new CIHandler(w, new CIValuer());
        h.setNative(true);
        w.vault().checkRisk();
        h.seed();
        c = new CIChecker(w, h);
    }

    // ------------------------------------------------------------------ properties
    function property_fairness() external view returns (bool ok) {
        (ok,) = c.fairness();
    }

    function property_ledger() external view returns (bool ok) {
        (ok,) = c.ledger();
    }

    function property_reserves() external view returns (bool ok) {
        (ok,) = c.reserves();
    }

    function property_nav() external view returns (bool ok) {
        (ok,) = c.nav();
    }

    /// @dev Which property failed, for the shrunk sequence's report.
    function why() external view returns (string memory s) {
        bool ok;
        (ok, s) = c.fairness();
        if (!ok) return s;
        (ok, s) = c.ledger();
        if (!ok) return s;
        (ok, s) = c.reserves();
        if (!ok) return s;
        (ok, s) = c.nav();
    }

    // ------------------------------------------------------------------ actions (CIHandler)
    function deposit(uint256 who, uint256 payerSeed, uint256 amt) external {
        h.deposit(who, payerSeed, amt);
    }

    function redeem(uint256 who, uint256 pct) external {
        h.redeem(who, pct);
    }

    function cancelDeposit(uint256 who) external {
        h.cancelDeposit(who);
    }

    function cancelRedeem(uint256 who) external {
        h.cancelRedeem(who);
    }

    function claim(uint256 who, bool byStranger) external {
        h.claim(who, byStranger);
    }

    function donate(uint256 amt) external {
        h.donate(amt);
    }

    function settle(uint256 role, uint256 prep) external {
        h.settle(role, prep);
    }

    function settleKeeper(uint256 prep) external {
        h.settleKeeper(prep);
    }

    function accrue(uint256 dt, bool byStranger) external {
        h.accrue(dt, byStranger);
    }

    function feeGov(uint256 m, uint256 perf, uint256 mode) external {
        h.feeGov(m, perf, mode);
    }

    function openTrade(bool agent, bool btc, bool long, uint256 pct, uint256 lev, uint256 kind, uint256 outcome) external {
        h.openTrade(agent, btc, long, pct, lev, kind, outcome);
    }

    function increaseTrade(bool agent, uint256 k, uint256 pct, uint256 levDelta, bool levOnly) external {
        h.increaseTrade(agent, k, pct, levDelta, levOnly);
    }

    function updateLeverage(bool agent, uint256 k, uint256 lev) external {
        h.updateLeverage(agent, k, lev);
    }

    function close(uint256 k, uint256 role, bool reduce, uint256 pct) external {
        h.close(k, role, reduce, pct);
    }

    function slTp(bool agent, uint256 k, uint256 sl, uint256 tp) external {
        h.slTp(agent, k, sl, tp);
    }

    function cancelResting(uint256 k, uint256 role) external {
        h.cancelResting(k, role);
    }

    function cancelTimedOut(uint256 k, bool roll) external {
        h.cancelTimedOut(k, roll);
    }

    function flatten(bool btc, uint256 role, bool indices) external {
        h.flatten(btc, role, indices);
    }

    function operatorReduce(uint256 k, uint256 amt) external {
        h.operatorReduce(k, amt);
    }

    function gFill(uint256 k, uint256 devSeed) external {
        h.gFill(k, devSeed);
    }

    function gCallbackCancel(uint256 k) external {
        h.gCallbackCancel(k);
    }

    function gFillAll() external {
        h.gFillAll();
    }

    function gTrigger(uint256 k, uint256 kind, bool file) external {
        h.gTrigger(k, kind, file);
    }

    function gRetype(uint256 k, uint256 tSeed) external {
        h.gRetype(k, tSeed);
    }

    function gRestore(uint256 k) external {
        h.gRestore(k);
    }

    function gFees(bool btc, uint256 feeP, uint256 spread, uint256 gov) external {
        h.gFees(btc, feeP, spread, gov);
    }

    function gHolding(uint256 k, int256 amt) external {
        h.gHolding(k, amt);
    }

    function move(bool btc, int256 bps) external {
        h.move(btc, bps);
    }

    function crash(uint256 what) external {
        h.crash(what);
    }

    function stress(uint256 what) external {
        h.stress(what);
    }

    function bankRun(uint256 what) external {
        h.bankRun(what);
    }

    function wait(uint256 secs) external {
        h.wait(secs);
    }

    /// @dev Fix round WP5 (GR2-KEY-01b): the manager's and the agent's exits wait MIN_HOLD and MIN_HOLD_L2_BLOCKS after
    ///      the pair's last new risk / the trade's last increase. This world rolls one block per 12 s (wait() caps at
    ///      2 h, about 600 blocks), so 2,400 blocks would take four waits in a row; this action passes the hold in
    ///      one step (time with fresh feeds through the handler, then the block clock), as GainsBase._passHold does.
    function passHold() external {
        h.wait(MIN_HOLD);
        IHevmRoll(address(uint160(uint256(keccak256("hevm cheat code"))))).roll(block.number + MIN_HOLD_L2_BLOCKS);
    }

    function check(bool clearLev) external {
        h.check(clearLev);
    }

    function govern(uint256 w_) external {
        h.govern(w_);
    }
}
