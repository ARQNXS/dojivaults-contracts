// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {HyperVault} from "../../../../src/HyperVault.sol";
import {VaultPolicy} from "../../../../src/VaultPolicy.sol";
import {HyperCore} from "../../../../src/hypercore/HyperCore.sol";
import {MockUSDC} from "../../../mocks/Mocks.sol";
import {CoreSim} from "./CoreSim.sol";

/// @notice Stateful handler for the hl-r2 conservation suite (INVARIANTS.md). Every USDC unit is tracked across the
///         EVM vault, the CoreDepositWallet / in flight, Core spot, Core perp (incl. the simulated trading PnL, an
///         explicit ghost in CoreSim) and every participant. Value moves between participants are measured at the
///         only places they can happen (settle, fee mints, claims, cancels) against the simulator's TRUE NAV.
contract ConservationHandler is CommonBase, StdCheats, StdUtils {
    using Math for uint256;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant OFF = 1e6; // 10 ** DECIMALS_OFFSET
    uint256 internal constant TOL = 3; // wei of USDC per settle / claim (floor rounding)

    HyperVault public immutable vault;
    CoreSim public immutable sim;
    MockUSDC public immutable usdc;
    VaultPolicy public immutable policy;
    address public immutable owner;
    address public immutable manager;
    address public immutable operator;
    address public immutable guardian;
    address public immutable sentinel;
    address public immutable feeRecipient;
    address public immutable treasury;
    address public immutable agent;
    address public immutable stranger;
    /// @dev Medusa has no getBlockNumber / getBlockTimestamp / recordLogs cheatcodes: read block.* directly there
    ///      (the handler never reads them after a warp in the same function in that mode).
    bool public immutable medusaMode;

    address[] internal _users; // depositors incl. the insiders
    uint256 public initialUsdc; // participants' USDC + the vault's EVM + Core value at start
    int256 public initialPnl;
    uint256 public gMinted; // USDC minted to participants by the handler after the start
    uint256 public initialLosses;

    // ---------------- ghosts: violations (must stay 0) ----------------
    uint256 public vOverstatedNav; // a settle priced at a NAV above the true NAV
    uint256 public vUnexplainedUnder; // a settle priced below the true NAV without a documented reason
    uint256 public vDepositorOverpaid; // depositors got more than fair without a documented reason
    uint256 public vRedeemerOverpaid; // redeemers got more than fair at the true NAV
    uint256 public vNormalUnfair; // a normal settle without deviation moved value beyond rounding
    uint256 public vRedeemBelowRule; // redeemers got less than the documented min(NAV, checkpoint) rule allows
    uint256 public vMintInExit; // an exit-only or redemption-only settle minted shares
    uint256 public vFeeOverCap; // fee value above the configured rates on the true NAV (or above 5% / 30%)
    uint256 public vProtocolSplit; // protocol share != configured bps of the fee
    uint256 public vClaimMismatch; // a claim delivered something else than the epoch record says
    uint256 public vCancelMismatch; // a cancel returned something else than was deposited
    uint256 public vPerfInBreach; // a performance fee was charged in a breach / emergency settle

    // ---------------- measured (documented deviations, allowed) ----------------
    uint256 public mLateSettles; // settles with vault USDC still in flight
    uint256 public mLateDepositGain; // value gained by depositors priced while USDC was in flight
    uint256 public mLateRedeemLoss; // value lost by redeemers priced while USDC was in flight
    uint256 public mLateNavGap; // sum of (true NAV - settle NAV) at those settles
    uint256 public mExitUnderpay; // exit-only / redemption-only: value kept by the vault under min(NAV, checkpoint)
    uint256 public mMaxPendingBlocks; // longest run of bridgePending() observed
    uint256 public mAgentActsAfterStop; // agent actions accepted on Core while the EVM side had revoked it
    uint256 public mDroppedRevokes;
    uint256 public mFeeValue;
    uint256 public mFirstMintWindfall; // HLR2-A08: value a first mint into a supply-0 vault took from leftover NAV

    // ---------------- coverage ----------------
    mapping(bytes32 => uint256) public calls;
    uint256 public settlesNormal;
    uint256 public settlesRedemptionOnly;
    uint256 public settlesExitOnly;
    uint256 public settlesPartial;
    uint256 public claimsChecked;
    uint256 public bridgesToCore;
    uint256 public bridgesToEvm;
    uint256 public feeChecks;
    uint256 public lastViolationCode;
    // fix round WP5: the agent's proxy path (HL-PROXY), the A-series write-off and the XA01 revoke
    uint256 public agentOrdersSent; // placeOrder calls by the agent that the vault accepted
    uint256 public writeOffs;
    uint256 public revokes;
    uint128 internal _agentCloid;

    // bridge bookkeeping
    uint256 internal _inflightBeforeBridge; // vault in-flight amount (older bridges) when the latest bridge opened
    bool internal _lastToCore;
    bool internal _agentFaked;
    uint256 internal _lastAgentToSpotBlock; // agent moved perp -> spot inside an open EVM->Core window (possible fake landing)
    uint256 internal _pendingSince;
    bytes[] internal _queued;

    struct Pre {
        uint256 T; // true NAV
        uint256 S0;
        uint256 hwm;
        uint256 perfBps;
        uint256 mgmtBps;
        uint256 protoBps;
        uint256 lastAccrual;
        uint256 cp;
        bool breached;
        uint8 reason;
        bool emergency;
        uint256 inflight;
        uint256 lastBridge;
        uint256 epoch;
        uint256 feeBal;
        uint256 treasuryBal;
        bool depositHold; // fix round WP5 (HLR2-XA01): after a platform revoke, settles are redemption-only
    }

    constructor(
        HyperVault v,
        CoreSim s,
        MockUSDC u,
        address[13] memory r, // owner, manager, operator, guardian, sentinel, feeRecipient, treasury, agent, stranger, alice, bob, carol, -
        bool medusa_
    ) {
        medusaMode = medusa_;
        vault = v;
        sim = s;
        usdc = u;
        policy = v.policy();
        owner = r[0];
        manager = r[1];
        operator = r[2];
        guardian = r[3];
        sentinel = r[4];
        feeRecipient = r[5];
        treasury = r[6];
        agent = r[7];
        stranger = r[8];
        _users.push(r[9]);
        _users.push(r[10]);
        _users.push(r[11]);
        _users.push(owner);
        if (manager != owner) _users.push(manager);
        _users.push(feeRecipient);
        for (uint256 i; i < _users.length; ++i) {
            vm.prank(_users[i]);
            usdc.approve(address(v), type(uint256).max);
        }
    }

    /// @dev Called once by the invariant contract after setUp.
    function snapshotStart() external {
        initialUsdc = _participantsUsdc() + usdc.balanceOf(address(vault)) + _u(sim.trueCoreValue(address(vault)));
        initialPnl = sim.ghostPnl(address(vault));
        initialLosses = _losses();
    }

    function users() external view returns (address[] memory) {
        return _users;
    }

    // ==================================================================
    // Accounting views
    // ==================================================================
    function _u(int256 x) internal pure returns (uint256) {
        return x > 0 ? uint256(x) : 0;
    }

    function _participantsUsdc() internal view returns (uint256 t) {
        for (uint256 i; i < _users.length; ++i) {
            t += usdc.balanceOf(_users[i]);
        }
        t += usdc.balanceOf(treasury) + usdc.balanceOf(stranger);
    }

    function _losses() internal view returns (uint256) {
        address v = address(vault);
        return sim.ghostActivationFee(v) + sim.ghostLostToCore(v) + sim.ghostLostToEvm(v);
    }

    /// @dev Left = everything participants and the vault hold (EVM + Core + in flight); right = start + trading
    ///      PnL - documented Core losses (activation fee, transfers lost on the bridge).
    function conservation() public view returns (int256 left, int256 right) {
        left = int256(_participantsUsdc() + usdc.balanceOf(address(vault))) + sim.trueCoreValue(address(vault));
        right = int256(initialUsdc + gMinted) + (sim.ghostPnl(address(vault)) - initialPnl) - int256(_losses() - initialLosses);
    }

    function trueNav() public view returns (uint256) {
        uint256 bal = usdc.balanceOf(address(vault));
        uint256 reserved = vault.pendingDepositAssets() + vault.deferredDepositAssets() + vault.claimableRedeemAssets();
        int256 v = int256(bal) - int256(reserved) + sim.trueCoreValue(address(vault));
        return v > 0 ? uint256(v) : 0;
    }

    function _inflight() internal view returns (uint256) {
        return sim.inflightToCore(address(vault)) + sim.inflightToEvm(address(vault));
    }

    function _pre() internal view returns (Pre memory p) {
        p.T = trueNav();
        p.S0 = vault.totalSupply();
        p.hwm = vault.highWaterMark();
        p.perfBps = vault.performanceFeeBps();
        p.mgmtBps = vault.managementFeeBps();
        p.protoBps = vault.protocolShareBps();
        p.lastAccrual = vault.lastFeeAccrual();
        p.cp = vault.checkpointNav();
        p.breached = vault.breached();
        p.reason = uint8(vault.breachReason());
        p.emergency = vault.emergency();
        p.inflight = _inflight();
        p.lastBridge = vault.lastBridgeBlock();
        p.epoch = vault.currentEpoch();
        (p.feeBal, p.treasuryBal) = _feeBal();
        p.depositHold = vault.depositHold();
    }

    function _bn() internal view returns (uint256) {
        return medusaMode ? block.number : vm.getBlockNumber();
    }

    function _ts() internal view returns (uint256) {
        return medusaMode ? block.timestamp : vm.getBlockTimestamp();
    }

    function _feeBal() internal view returns (uint256 f, uint256 t) {
        f = vault.balanceOf(feeRecipient);
        t = vault.balanceOf(treasury);
    }

    function _flag(uint256 code) internal {
        lastViolationCode = code;
    }

    // ==================================================================
    // Common prologue
    // ==================================================================
    modifier step(bytes32 name) {
        sim.process();
        _track();
        ++calls[name];
        _;
        _track();
    }

    function _track() internal {
        bool p = vault.bridgePending();
        if (p) {
            if (_pendingSince == 0) _pendingSince = _bn();
            uint256 len = _bn() - _pendingSince;
            if (len > mMaxPendingBlocks) mMaxPendingBlocks = len;
        } else {
            _pendingSince = 0;
        }
        // EVM side believes the agent is revoked while Core still has it (A01)
        if (vault.agent() == address(0) && sim.agentOf(address(vault)) == agent) {
            uint256 acts = sim.agentActions(address(vault));
            if (acts > mAgentActsAfterStop) mAgentActsAfterStop = acts;
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return _users[seed % _users.length];
    }

    function _role(uint256 seed) internal view returns (address) {
        address[7] memory r = [manager, operator, owner, guardian, sentinel, stranger, _users[seed % 3]];
        return r[seed % 7];
    }

    // ==================================================================
    // Time
    // ==================================================================
    function roll(uint256 blocks) external step("roll") {
        blocks = bound(blocks, 1, 400);
        uint256 b = _bn() + blocks;
        uint256 t = _ts() + blocks;
        vm.roll(b);
        vm.warp(t);
        sim.process();
    }

    function warp(uint256 secs) external step("warp") {
        secs = bound(secs, 1 minutes, 3 days);
        uint256 b = _bn() + secs;
        uint256 t = _ts() + secs;
        vm.roll(b);
        vm.warp(t);
        sim.process();
    }

    // ==================================================================
    // Depositor flow (every auto-claim is checked against the epoch record)
    // ==================================================================
    function deposit(uint256 seed, uint256 amount) external step("deposit") {
        address u = _actor(seed);
        amount = bound(amount, 10e6, 300_000e6);
        if (usdc.balanceOf(u) < amount) {
            usdc.mint(u, amount); // new money: counted on both sides of the conservation
            gMinted += amount;
        }
        (uint256 iS, uint256 iA,, bool settled) = _ideal(u);
        uint256 s0 = vault.balanceOf(u);
        uint256 b0 = usdc.balanceOf(u);
        vm.prank(u);
        try vault.requestDeposit(amount, u) {
            _checkDelta(u, settled, iS, iA, s0, b0, 0, amount);
        } catch {}
    }

    function redeem(uint256 seed, uint256 frac) external step("redeem") {
        address u = _actor(seed);
        uint256 bal = vault.balanceOf(u);
        if (bal == 0) return;
        uint256 shares = bal.mulDiv(bound(frac, 1, BPS), BPS);
        if (shares == 0) shares = bal;
        (uint256 iS, uint256 iA,, bool settled) = _ideal(u);
        uint256 s0 = vault.balanceOf(u);
        uint256 b0 = usdc.balanceOf(u);
        vm.prank(u);
        try vault.requestRedeem(shares, u, u) {
            _checkDelta(u, settled, iS, iA, s0, b0, shares, 0);
        } catch {}
    }

    function cancelDeposit(uint256 seed) external step("cancelDeposit") {
        address u = _actor(seed);
        (, uint256 dep,) = vault.requests(u);
        uint256 b0 = usdc.balanceOf(u);
        vm.prank(u);
        try vault.cancelDepositRequest() {
            if (usdc.balanceOf(u) - b0 != dep) {
                ++vCancelMismatch;
                _flag(11);
            }
        } catch {}
    }

    function cancelRedeem(uint256 seed) external step("cancelRedeem") {
        address u = _actor(seed);
        _claim(u);
        (uint256 ep,, uint256 red) = vault.requests(u);
        uint256 s0 = vault.balanceOf(u);
        vm.prank(u);
        try vault.cancelRedeemRequest() {
            if (ep != vault.currentEpoch() || vault.balanceOf(u) - s0 != red) {
                ++vCancelMismatch;
                _flag(12);
            }
        } catch {}
    }

    function claim(uint256 seed) external step("claim") {
        _claim(_actor(seed));
    }

    function transferShares(uint256 a, uint256 b, uint256 frac) external step("transfer") {
        address from = _actor(a);
        address to = _actor(b);
        uint256 amt = vault.balanceOf(from).mulDiv(bound(frac, 0, BPS), BPS);
        vm.prank(from);
        try vault.transfer(to, amt) {} catch {}
    }

    function _claim(address u) internal {
        (uint256 iS, uint256 iA,, bool settled) = _ideal(u);
        if (!settled) return;
        uint256 s0 = vault.balanceOf(u);
        uint256 b0 = usdc.balanceOf(u);
        try vault.claim(u) {
            _checkDelta(u, true, iS, iA, s0, b0, 0, 0);
        } catch {}
    }

    /// @dev Expected: shares += idealShares - sharesOut, USDC += idealAssets - usdcOut.
    function _checkDelta(address u, bool settled, uint256 iS, uint256 iA, uint256 s0, uint256 b0, uint256 sharesOut, uint256 usdcOut)
        internal
    {
        if (!settled) {
            iS = 0;
            iA = 0;
        }
        ++claimsChecked;
        uint256 s1 = vault.balanceOf(u);
        uint256 b1 = usdc.balanceOf(u);
        if (s1 + sharesOut != s0 + iS || b1 + usdcOut != b0 + iA) {
            ++vClaimMismatch;
            _flag(10);
        }
    }

    /// @dev What the vault's own epoch record owes `c` (independent replica of VaultMath.claimableWithCarry).
    function _ideal(address c) internal view returns (uint256 shares, uint256 assets, bool carried, bool settled) {
        (uint256 ep, uint256 d, uint256 s) = vault.requests(c);
        if (ep >= vault.currentEpoch() || (d == 0 && s == 0)) return (0, 0, false, false);
        settled = true;
        (uint256 depA, uint256 depS, uint256 redS, uint256 redA, uint256 burned,,,) = vault.epochs(ep);
        if (d > 0) {
            (uint256 cf, uint256 pin) = vault.carry(ep);
            if (cf != 0) {
                if (pin == 0) carried = true;
                else (depA, depS,,,,,,) = vault.epochs(pin - 1);
            }
            if (!carried && depA > 0) {
                if (depS == 0) assets = d;
                else shares = d.mulDiv(depS, depA);
            }
        }
        if (s > 0 && redS > 0) {
            assets += s.mulDiv(redA, redS);
            uint256 b = s.mulDiv(burned, redS, Math.Rounding.Ceil);
            if (b < s) shares += s - b;
        }
        if (carried && s == 0) settled = false; // claim() reverts: nothing to deliver
    }

    function owedTotals() external view returns (uint256 shares, uint256 assets) {
        for (uint256 i; i < _users.length; ++i) {
            (uint256 s, uint256 a,, bool settled) = _ideal(_users[i]);
            if (settled) {
                shares += s;
                assets += a;
            }
        }
    }

    // ==================================================================
    // Settle (by each role) with the fairness measurement
    // ==================================================================
    function settle(uint256 seed) external step("settle") {
        address who = _role(seed);
        if (seed % 3 == 0) vault.checkRisk(); // the keeper's routine
        Pre memory p = _pre();
        bool treasuryCaller = who == manager || who == operator;
        // fix round WP5: HLR2-XA01's deposit hold makes a non-emergency settle redemption-only, as a loss breach does
        bool lossBreach = !p.emergency && ((p.breached && (p.reason == 2 || p.reason == 3)) || p.depositHold);
        bool exitOnly = p.emergency || (!treasuryCaller && !lossBreach);
        vm.prank(who);
        try vault.settle() {
            _afterSettle(p, exitOnly, lossBreach);
        } catch {}
    }

    function _afterSettle(Pre memory p, bool exitOnly, bool redemptionOnly) internal {
        (uint256 feeShares,) = _checkFees(p, !p.breached && !p.emergency);
        (uint256 depA, uint256 depS, uint256 redS, uint256 paid, uint256 burned, uint256 postNav,,) = vault.epochs(p.epoch);
        uint256 depIn = (exitOnly || redemptionOnly || depS == 0) ? 0 : depA;
        uint256 S = p.S0 + feeShares; // supply the flows were priced against
        uint256 navUsed = postNav + paid - depIn;

        if (exitOnly) ++settlesExitOnly;
        else if (redemptionOnly) ++settlesRedemptionOnly;
        else ++settlesNormal;
        if (burned < redS) ++settlesPartial;
        if ((exitOnly || redemptionOnly) && depS > 0) {
            ++vMintInExit;
            _flag(20);
        }

        // Documented reasons for a NAV below the truth: USDC in flight of an older bridge (past its cap when the
        // latest one opened), the latest bridge past MAX_UNLANDED_BLOCKS, or a landing the agent may have faked.
        uint256 explained = p.inflight;
        if (!(_bn() > p.lastBridge + 300 || _agentFaked)) {
            explained = p.inflight < _inflightBeforeBridge ? p.inflight : _inflightBeforeBridge;
        }
        // BRIDGE_LANDING_TOLERANCE: a bridge counts as landed within 1 USDC of its amount (documented), so up to
        // 1 USDC of the latest transfer may still be in flight after its window (a dust "full available" bridge).
        explained += p.inflight - explained < 1e6 ? p.inflight - explained : 1e6;
        if (navUsed > p.T + TOL) {
            ++vOverstatedNav;
            _flag(21);
        }
        uint256 gap = p.T > navUsed ? p.T - navUsed : 0;
        if (gap > explained + TOL) {
            ++vUnexplainedUnder;
            _flag(22);
        }
        bool deviated = gap > TOL;
        if (deviated) {
            ++mLateSettles;
            mLateNavGap += gap;
        }

        // value at the true NAV
        uint256 depValue = depS.mulDiv(p.T + 1, S + OFF);
        uint256 burnValue = burned.mulDiv(p.T + 1, S + OFF);
        if (depValue > depIn + TOL) {
            if (deviated) mLateDepositGain += depValue - depIn;
            else if (S == 0) mFirstMintWindfall += depValue - depIn; // known: HLR2-A08 (first mint 1:1 over leftover NAV)
            else {
                ++vDepositorOverpaid;
                _flag(23);
            }
        }
        if (paid > burnValue + TOL) {
            ++vRedeemerOverpaid;
            _flag(24);
        }
        if (!exitOnly && !redemptionOnly && !deviated) {
            if (depIn > depValue + TOL || burnValue > paid + TOL) {
                ++vNormalUnfair;
                _flag(25);
            }
        }
        if (deviated && burnValue > paid) mLateRedeemLoss += burnValue - paid;
        if ((exitOnly || redemptionOnly) && !deviated && burned > 0) {
            // documented: priced at min(NAV, checkpoint before the ratchet)
            uint256 pn = p.cp > 0 && p.cp < p.T ? p.cp : p.T;
            uint256 floorPaid = burned.mulDiv(pn + 1, S + OFF);
            if (paid + TOL < floorPaid) {
                ++vRedeemBelowRule;
                _flag(26);
            }
            if (burnValue > paid) mExitUnderpay += burnValue - paid;
        }
    }

    /// @dev Checks the fee shares minted by the call (balance deltas of the fee recipient and the protocol treasury;
    ///      no share moves to them in the wrapped calls otherwise) against the configured rates on the true NAV.
    function _checkFees(Pre memory p, bool withPerf) internal returns (uint256 feeShares, uint256 protocolShares) {
        (uint256 f1, uint256 t1) = _feeBal();
        protocolShares = t1 - p.treasuryBal;
        feeShares = (f1 - p.feeBal) + protocolShares;
        if (feeShares == 0) return (0, 0);
        ++feeChecks;
        uint256 value = feeShares.mulDiv(p.T + 1, p.S0 + feeShares + OFF);
        mFeeValue += value;
        uint256 elapsed = _ts() - p.lastAccrual;
        uint256 cap = p.T.mulDiv(p.mgmtBps * elapsed, BPS * YEAR);
        uint256 price = (p.T + 1).mulDiv(1e12, p.S0 + OFF);
        uint256 perfCap;
        if (withPerf && price > p.hwm) perfCap = (price - p.hwm).mulDiv(p.S0, 1e12).mulDiv(p.perfBps, BPS);
        if (!withPerf && value > cap + TOL + cap / 1e9) {
            ++vPerfInBreach;
            _flag(31);
        }
        if (value > cap + perfCap + TOL + (cap + perfCap) / 1e9 || p.mgmtBps > 500 || p.perfBps > 3_000) {
            ++vFeeOverCap;
            _flag(30);
        }
        // protocol share: floor(fee * bps / BPS) when a recipient exists (the factory's is set)
        if (protocolShares != feeShares.mulDiv(p.protoBps, BPS)) {
            ++vProtocolSplit;
            _flag(32);
        }
    }

    function accrueFees() external step("accrueFees") {
        Pre memory p = _pre();
        try vault.accrueFees() {
            _checkFees(p, false);
        } catch {}
    }

    function lowerFees(uint256 m, uint256 f) external step("lowerFees") {
        Pre memory p = _pre();
        uint16 mm = uint16(bound(m, 0, p.mgmtBps));
        uint16 ff = uint16(bound(f, 0, p.perfBps));
        vm.prank(owner);
        try vault.lowerFees(mm, ff) {
            _checkFees(p, false);
        } catch {}
    }

    /// @dev Owner queues a fee change (raises included); executed by anyone after the vault timelock.
    function queueFees(uint256 m, uint256 f) external step("queueFees") {
        bytes memory data = abi.encodeCall(HyperVault.setFees, (uint16(bound(m, 0, 500)), uint16(bound(f, 0, 3_000))));
        vm.prank(owner);
        try vault.queue(data) {
            _queued.push(data);
        } catch {}
    }

    function executeQueued(uint256 i) external step("executeQueued") {
        if (_queued.length == 0) return;
        bytes memory data = _queued[i % _queued.length];
        Pre memory p = _pre();
        try vault.execute(data) {
            _checkFees(p, false);
        } catch {}
    }

    // ==================================================================
    // Treasury: bridges both ways (with delays / failures), moveUsd
    // ==================================================================
    function bridgeToCore(uint256 seed, uint256 amount) external step("bridgeToCore") {
        address who = seed % 4 == 0 ? manager : operator;
        uint256 idle = vault.idleAssets();
        if (idle == 0) return;
        amount = seed % 5 == 0 ? idle : bound(amount, 100e6, idle < 100e6 ? 100e6 : idle);
        uint256 before = _inflight();
        vm.prank(who);
        try vault.bridgeToCore(amount) {
            _opened(before, true);
            ++bridgesToCore;
        } catch {}
    }

    function bridgeToEvm(uint256 seed, uint256 amount) external step("bridgeToEvm") {
        address who = seed % 4 == 0 ? manager : seed % 4 == 1 ? _role(seed >> 8) : operator;
        uint256 avail = sim.spotUsd(address(vault)) + HyperCore.withdrawable(address(vault));
        if (avail == 0) return;
        amount = seed % 5 == 0 ? avail : bound(amount, 100e6, avail < 100e6 ? 100e6 : avail);
        uint256 before = _inflight();
        vm.prank(who);
        try vault.bridgeToEvm(amount) {
            _opened(before, false);
            ++bridgesToEvm;
        } catch {}
    }

    function _opened(uint256 inflightBefore, bool toCore) internal {
        _inflightBeforeBridge = inflightBefore;
        _lastToCore = toCore;
        // An agent perp -> spot move queued in this block applies after the bridge opened: it may fake the landing
        // too (found by Medusa: the classifier missed this timing).
        _agentFaked = toCore && _lastAgentToSpotBlock == _bn();
    }

    function moveUsd(uint256 seed, uint256 amount) external step("moveUsd") {
        bool toPerp = seed % 2 == 0;
        uint256 avail = toPerp ? sim.spotUsd(address(vault)) : HyperCore.withdrawable(address(vault));
        if (avail == 0) return;
        amount = bound(amount, 1, avail);
        vm.prank(seed % 3 == 0 ? manager : operator);
        try vault.moveUsd(amount, toPerp) {} catch {}
    }

    /// @dev Bridge timing and failures: delays inside and beyond the 10 / 60 / 300 block windows, rare losses,
    ///      dropped Core actions (class transfer, send, agent approval).
    function faults(uint256 seed) external step("faults") {
        uint256[10] memory dd = [uint256(1), 1, 1, 2, 5, 20, 70, 350, 700, 2_000];
        uint256[10] memory ed = [uint256(0), 0, 0, 1, 3, 30, 70, 350, 700, 2_000];
        sim.setDeposit(dd[seed % 10], (seed >> 8) % 64 == 0);
        sim.setEvm(ed[(seed >> 4) % 10], (seed >> 16) % 64 == 0);
        uint256 k = (seed >> 24) % 16;
        if (k == 0) sim.setDropNext(HyperCore.ACTION_USD_CLASS_TRANSFER, 1);
        else if (k == 1) sim.setDropNext(HyperCore.ACTION_SEND_ASSET, 1);
        else if (k == 2) {
            sim.setDropNext(HyperCore.ACTION_ADD_API_WALLET, 1);
            ++mDroppedRevokes;
        } else if (k == 3) sim.setActionDelay(HyperCore.ACTION_USD_CLASS_TRANSFER, 2);
        else if (k == 4) sim.setActionDelay(HyperCore.ACTION_USD_CLASS_TRANSFER, 0);
    }

    /// @dev The platform keeper's routine (one step): latch landings, check risk, bring liquidity home for the pending
    ///      redemptions, push idle USDC to Core, or settle. Makes realistic sequences (and late-landing settles) likely.
    function keeperCycle(uint256 seed) external step("keeperCycle") {
        vault.syncBridge();
        try vault.checkRisk() {} catch {}
        if (vault.bridgePending()) return;
        uint256 pend = vault.pendingRedeemShares();
        uint256 owed = pend == 0 ? 0 : vault.convertToAssets(pend);
        uint256 idle = vault.idleAssets();
        uint256 k = seed % 3;
        if (owed > idle && k != 0) {
            uint256 avail = sim.spotUsd(address(vault)) + HyperCore.withdrawable(address(vault));
            uint256 need = owed - idle + 1e6;
            if (need < 100e6) need = 100e6;
            if (need > avail) need = avail;
            if (need == 0) return;
            uint256 before = _inflight();
            vm.prank(operator);
            try vault.bridgeToEvm(need) {
                _opened(before, false);
                ++bridgesToEvm;
            } catch {}
            return;
        }
        if (k == 1 && idle >= 100e6 && pend == 0) {
            uint256 before = _inflight();
            vm.prank(operator);
            try vault.bridgeToCore(idle) {
                _opened(before, true);
                ++bridgesToCore;
            } catch {}
            return;
        }
        this.settle(1); // operator, with the fairness measurement
    }

    function syncBridge() external step("syncBridge") {
        vault.syncBridge();
    }

    // ==================================================================
    // Trading: PnL shocks (explicit ghost), mark moves on open positions, manager orders, agent actions
    // ==================================================================
    function pnlShock(int256 bps) external step("pnlShock") {
        int256 av = sim.accountValue(address(vault));
        if (av <= 0) return;
        bps = bound(bps, -800, 800);
        int256 delta = (av * bps) / 10_000;
        // HyperCore liquidates a perp account before its value goes negative (the backstop absorbs a shortfall): the
        // sim keeps account values >= 0, see ASYNC.md HLR2-A06 for what the vault reads in that transient.
        if (av + delta <= 0) return;
        sim.shock(address(vault), delta);
    }

    function markMove(uint256 seed, int256 bps) external step("markMove") {
        uint32 a = uint32(seed % 2);
        bps = bound(bps, -1_000, 1_000);
        uint64 m = sim.markRaw(a);
        uint64 nm = uint64(uint256(int256(uint256(m)) + (int256(uint256(m)) * bps) / 10_000));
        if (nm == 0) return;
        sim.setMark(a, nm);
        // keep the true account value non-negative (L-05 floors the Core sum at zero, a documented rule)
        if (sim.accountValue(address(vault)) < 0) sim.setMark(a, m);
    }

    function managerOrder(uint256 seed, uint256 size) external step("managerOrder") {
        uint32 a = uint32(seed % 2);
        bool isBuy = (seed >> 1) % 2 == 0;
        bool ro = (seed >> 2) % 3 == 0;
        (uint256 px1e8,) = HyperCore.markPx1e8(a);
        uint64 limit = uint64(isBuy ? (px1e8 * 10_050) / 10_000 : (px1e8 * 9_950) / 10_000);
        uint64 sz = uint64(bound(size, 1e3, 5e8)) * (a == 0 ? 1 : 10);
        sz = uint64((sz / 1e3) * 1e3); // whole szDecimals units for both assets
        vm.prank(manager);
        try vault.placeOrder(a, isBuy, limit, sz, ro, HyperCore.TIF_IOC, 0) {} catch {}
    }

    function flatten(uint256 seed) external step("flatten") {
        address who = _role(seed);
        vm.prank(who);
        try vault.flatten(uint32(seed % 2), 0) {} catch {}
    }

    /// @dev The platform agent (off chain, through the executor): only accepted by Core while its slot holds it.
    ///      1 spot -> perp, 2 perp -> spot (inside a to-Core window this may fake a landing), 3 open, 4 close.
    function agentAction(uint256 seed, uint256 amount) external step("agentAction") {
        uint8 kind = uint8(seed % 4) + 1;
        uint32 a = uint32((seed >> 4) % 2);
        int256 amt;
        if (kind == 1) amt = int256(bound(amount, 1, sim.spotUsd(address(vault)) + 1));
        else if (kind == 2) amt = int256(bound(amount, 1, HyperCore.withdrawable(address(vault)) + 1));
        else if (kind == 3) {
            // up to ~3x of the account value, either side
            int256 av = sim.accountValue(address(vault));
            if (av <= 0) return;
            uint256 maxRaw = (uint256(av) * 3) / sim.markRaw(a);
            if (maxRaw == 0) return;
            amt = int256(bound(amount, 1, maxRaw));
            if ((seed >> 8) % 2 == 0) amt = -amt;
        }
        if (kind == 2 && _lastToCore && vault.bridgePending()) _agentFaked = true;
        if (kind == 2) _lastAgentToSpotBlock = _bn();
        sim.agentAct(address(vault), agent, kind, a, amt);
    }

    /// @dev Fix round WP5 (HL-PROXY): the platform agent's only trading path on a vault of the release code, the vault's
    ///      placeOrder (IOC, its own nonzero cloid outside the ticket prefix), under the WP1 turnover budget and order
    ///      rate. Same order shapes as managerOrder; refused orders (limits, warm-up, breach, revoked) are caught.
    function agentOrder(uint256 seed, uint256 size) external step("agentOrder") {
        uint32 a = uint32(seed % 2);
        bool isBuy = (seed >> 1) % 2 == 0;
        bool ro = (seed >> 2) % 3 == 0;
        (uint256 px1e8,) = HyperCore.markPx1e8(a);
        uint64 limit = uint64(isBuy ? (px1e8 * 10_050) / 10_000 : (px1e8 * 9_950) / 10_000);
        uint64 sz = uint64(bound(size, 1e3, 5e8)) * (a == 0 ? 1 : 10);
        sz = uint64((sz / 1e3) * 1e3);
        vm.prank(agent);
        try vault.placeOrder(a, isBuy, limit, sz, ro, HyperCore.TIF_IOC, ++_agentCloid) {
            ++agentOrdersSent;
        } catch {}
    }

    // ==================================================================
    // Risk, breaches, emergency
    // ==================================================================
    function checkRisk() external step("checkRisk") {
        try vault.checkRisk() {} catch {}
    }

    /// @dev Full stops are rarer than the clears so that runs spend time in every mode.
    function breachOps(uint256 seed) external step("breachOps") {
        uint256 k = seed % 16;
        if (k == 1 && (seed >> 8) % 3 != 0) k = 3; // emergencies are sticky: keep them rarer
        if (k == 0) {
            vm.prank(seed % 2 == 0 ? guardian : sentinel);
            try vault.triggerBreach() {} catch {}
        } else if (k == 1) {
            vm.prank(seed % 2 == 0 ? guardian : owner);
            try vault.triggerEmergency() {} catch {}
        } else if (k == 2) {
            vm.prank(stranger);
            try vault.triggerEmergency() {} catch {}
        } else if (k <= 5) {
            vm.prank(guardian);
            try vault.clearBreach() {} catch {}
        } else if (k <= 7) {
            vm.prank(guardian);
            try vault.exitEmergency() {} catch {}
        } else if (k == 8) {
            vm.prank(owner);
            try vault.resume() {} catch {}
        } else if (k <= 10) {
            try vault.clearLeverageBreach() {} catch {}
        } else if (k == 11) {
            // fix round WP5 (HLR2-A02 / A08): the guardian writes off a transfer missing past MAX_UNLANDED_BLOCKS
            vm.prank(guardian);
            try vault.writeOffBridge() {
                ++writeOffs;
            } catch {}
        } else if (k == 12 && (seed >> 12) % 4 == 0) {
            // fix round WP5 (HLR2-XA01): a revoke; by the guardian or the sentinel it also holds deposits
            address[3] memory r = [guardian, sentinel, owner];
            vm.prank(r[(seed >> 8) % 3]);
            try vault.revokeAgent() {
                ++revokes;
            } catch {}
        } else {
            // HL-PROXY: syncAgent() is now pinAccountMode() (no HyperCore approval); any role, or anyone when due
            vm.prank(_role(seed >> 8));
            try vault.pinAccountMode() {} catch {}
        }
    }
}
