// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {HyperVault} from "../../../src/HyperVault.sol";
import {HyperVaultLens} from "../../../src/HyperVaultLens.sol";
import {HyperVaultFactory} from "../../../src/HyperVaultFactory.sol";
import {HyperCore} from "../../../src/hypercore/HyperCore.sol";
import {MockUSDC, MockPrecompile} from "../../mocks/Mocks.sol";

/// @notice Contract that always reverts; etched over a precompile to simulate an outage.
contract RevertingPrecompile {
    fallback() external {
        revert("outage");
    }
}

/// @notice Stateful handler for the HyperVault invariant suite.
/// @dev HyperCore model: `perp` (perp dex 0 accountValue), `spot` (spot USDC) and `hidden` (USDC the agent parked
///      where coreEquity() does not look: another perp dex or a spot token), all 6 decimals. Bridges are credited
///      on the destination side in the same block (worst case for the bridge window). Each guarantee the contracts
///      claim is recorded as a ghost violation counter that the invariant contract asserts to be zero.
contract VaultHandler is CommonBase, StdCheats, StdUtils {
    uint256 internal constant ONE_SHARE = 1e12;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant MIN_BRIDGE = 100e6;

    HyperVault public immutable vault;
    HyperVaultLens public immutable lens;
    MockUSDC public immutable usdc;
    HyperVaultFactory public immutable factory;
    address public immutable owner;
    address public immutable manager;
    address public immutable guardian;
    address public immutable feeRecipient;
    address public immutable treasury;
    address public immutable stranger;
    address public immutable agentAddr;
    address[3] public actors;

    int64 public perp;
    uint64 public spot;
    uint64 public ntl;
    uint64 public hidden;

    // ghost violations
    uint256 public vDepositWhileClosed;
    uint256 public vInsiderDeposit;
    /// @dev Round 4: the epoch in which an insider's deposit was requested (it must be priced in a LATER one).
    mapping(address controller => uint256 epoch) public insiderAskedAt;
    /// @dev Round 4: a stranger or depositor bridged home or settled during an emergency unwind.
    uint256 public vStrangerUnwind;
    uint256 public vEarlyExecute;
    uint256 public vLateExecute;
    uint256 public vBadSelectorQueued;
    uint256 public vFeeOverCap;
    uint256 public vProtocolSplit;
    uint256 public vPriceJump;
    uint256 public vPreviewMismatch;
    uint256 public vDepositOverValued;
    uint256 public vShareIncreased;
    uint256 public vFlattenUnauthorized;
    uint256 public vBreachWithAgent;
    uint256 public vEmergencyNotBreached;
    uint256 public vSettleInWindow;
    uint256 public vSettleWhileBreached;
    uint256 public vSettleFarFromCheckpoint;
    uint256 public vEmergencyMinted;
    uint256 public vEmergencyUnauthorized;
    uint256 public vExitBlockedByOutage;
    uint256 public vInstantOwnerPower;
    uint256 public vGuardianReplaced;
    uint256 public vForeignAgent;
    uint256 public vPeakReset;
    uint256 public vDustBridge;
    uint256 public vPrequeuedClear;
    uint256 public vWindowExtended;
    uint256 public vSentinelPower;

    // coverage counters
    mapping(bytes32 => uint256) public calls;
    uint256 public settlesOk;
    uint256 public emergencySettles;
    uint256 public claimsChecked;
    uint256 public feeAccruals;
    uint256 public breaches;
    uint256 public timelockedOk;

    mapping(uint256 epoch => bool) public firstMintEpoch;
    uint16 internal _lastShare;
    uint256 internal _lastPeak;
    bytes[] internal _queued;
    uint256 internal _bn;

    constructor(
        HyperVault vault_,
        HyperVaultLens lens_,
        MockUSDC usdc_,
        HyperVaultFactory factory_,
        address owner_,
        address manager_,
        address guardian_,
        address feeRecipient_,
        address treasury_,
        address agent_
    ) {
        vault = vault_;
        lens = lens_;
        usdc = usdc_;
        factory = factory_;
        owner = owner_;
        manager = manager_;
        guardian = guardian_;
        feeRecipient = feeRecipient_;
        treasury = treasury_;
        agentAddr = agent_;
        stranger = makeAddr("inv.stranger");
        actors[0] = makeAddr("inv.a0");
        actors[1] = makeAddr("inv.a1");
        actors[2] = makeAddr("inv.a2");
        for (uint256 i; i < 3; ++i) {
            vm.prank(actors[i]);
            usdc.approve(address(vault_), type(uint256).max);
        }
        vm.prank(manager_);
        usdc.approve(address(vault_), type(uint256).max);
        spot = 1e6; // seed after activation fee
        _lastShare = vault_.protocolShareBps();
        _lastPeak = vault_.peakSharePrice();
        _bn = vm.getBlockNumber();
    }

    // ------------------------------------------------------------------
    // HyperCore model
    // ------------------------------------------------------------------
    function sync() public {
        MockPrecompile(HyperCore.PRECOMPILE_ACCOUNT_MARGIN_SUMMARY).setResponse(
            abi.encode(uint32(0), address(vault)), abi.encode(HyperCore.AccountMarginSummary(perp, 0, ntl, perp))
        );
        MockPrecompile(HyperCore.PRECOMPILE_SPOT_BALANCE).setResponse(
            abi.encode(address(vault), uint64(0)), abi.encode(HyperCore.SpotBalance(spot * 100, 0, 0))
        );
        MockPrecompile(HyperCore.PRECOMPILE_WITHDRAWABLE).setResponse(
            abi.encode(address(vault)), abi.encode(perp > 0 ? uint64(perp) : uint64(0))
        );
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % 3];
    }

    modifier track(bytes32 name) {
        calls[name]++;
        _;
        _post();
    }

    function _post() internal {
        uint16 share = vault.protocolShareBps();
        if (share > _lastShare) vShareIncreased++;
        _lastShare = share;
        // Round 4: a full stop (guardian / sentinel / owner breach) or an emergency still leaves no agent; the risk
        // breaches (leverage, daily loss, drawdown) keep the platform agent.
        bool fullStop = vault.emergency() || (vault.breached() && uint8(vault.breachReason()) >= 4);
        if (fullStop && vault.agent() != address(0)) vBreachWithAgent++;
        if (vault.emergency() && !vault.breached()) vEmergencyNotBreached++;
        if (vault.guardian() != guardian) vGuardianReplaced++;
        if (vault.agent() != address(0) && !factory.isPlatformAgent(vault.agent())) vForeignAgent++;
        for (uint256 i; i < 3; ++i) {
            _checkClaimable(actors[i]);
        }
    }

    /// @dev A depositor's settled shares valued at the epoch's settle price never exceed the assets deposited.
    ///      Shares returned from a partly filled redemption in the same epoch (partial fill + return, V-01) are
    ///      not deposit shares and are taken out first.
    function _checkClaimable(address a) internal {
        (uint256 ep, uint256 dep, uint256 red) = vault.requests(a);
        if (ep >= vault.currentEpoch() || dep == 0) return;
        // Round 4: a deposit carried by a redemption-only epoch is priced in the epoch that priced its carry run;
        // its shares are valued at THAT epoch's price (still carried: nothing to value yet).
        uint256 pe = ep;
        (uint256 carriedFrom, uint256 pricedIn) = vault.carry(ep);
        if (carriedFrom != 0) {
            if (pricedIn == 0) return;
            pe = pricedIn - 1;
        }
        if (firstMintEpoch[pe]) return; // seed is a documented donation
        (uint256 shares,) = lens.claimable(vault, a);
        (,, uint256 R,, uint256 burned,,,) = vault.epochs(ep);
        (,,,,,, uint256 price,) = vault.epochs(pe);
        if (red > 0 && R > 0) {
            uint256 burnedMe = (red * burned + R - 1) / R;
            uint256 returned = burnedMe < red ? red - burnedMe : 0;
            shares = shares > returned ? shares - returned : 0;
        }
        claimsChecked++;
        if ((shares * price) / ONE_SHARE > dep + 2) vDepositOverValued++;
    }

    // ------------------------------------------------------------------
    // Time
    // ------------------------------------------------------------------
    function warp(uint256 secs, uint256 blocks) external track("warp") {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 0, 3 days));
        _bn += bound(blocks, 0, 15);
        vm.roll(_bn);
    }

    // ------------------------------------------------------------------
    // Depositor flow
    // ------------------------------------------------------------------
    function requestDeposit(uint256 s, uint256 amt) external track("requestDeposit") {
        address a = _actor(s);
        amt = bound(amt, 1, 3_000_000e6);
        usdc.mint(a, amt);
        bool closed = vault.depositsPaused() || vault.breached() || vault.emergency();
        vm.prank(a);
        try vault.requestDeposit(amt, a) {
            if (closed) vDepositWhileClosed++;
        } catch {}
    }

    /// @dev The manager (also an insider as owner or fee recipient elsewhere) must never get shares priced by himself.
    ///      Round 4: insiders may deposit, but only into the NEXT epoch; one priced in the current epoch is a violation.
    function insiderDeposit(uint256 amt, uint256 who) external track("insiderDeposit") {
        amt = bound(amt, 1, 1_000e6);
        usdc.mint(manager, amt);
        address controller = who % 3 == 0 ? manager : (who % 3 == 1 ? owner : feeRecipient);
        vm.prank(manager);
        try vault.requestDeposit(amt, controller) returns (uint256 ep) {
            if (ep != vault.currentEpoch() + 1) vInsiderDeposit++;
            insiderAskedAt[controller] = vault.currentEpoch();
        } catch {}
        address a = _actor(who);
        usdc.mint(a, amt);
        vm.prank(a);
        try vault.requestDeposit(amt, controller) returns (uint256 ep) {
            if (ep != vault.currentEpoch() + 1) vInsiderDeposit++;
            insiderAskedAt[controller] = vault.currentEpoch();
        } catch {}
    }

    function requestRedeem(uint256 s, uint256 pct) external track("requestRedeem") {
        address a = _actor(s);
        uint256 shares = (vault.balanceOf(a) * bound(pct, 1, 100)) / 100;
        if (shares == 0) return;
        vm.prank(a);
        vault.requestRedeem(shares, a, a);
    }

    function cancelDeposit(uint256 s) external track("cancelDeposit") {
        vm.prank(_actor(s));
        try vault.cancelDepositRequest() {} catch {}
    }

    function cancelRedeem(uint256 s) external track("cancelRedeem") {
        vm.prank(_actor(s));
        try vault.cancelRedeemRequest() {} catch {}
    }

    function claim(uint256 s) external track("claim") {
        try vault.claim(_actor(s)) {} catch {}
    }

    // ------------------------------------------------------------------
    // Settlement and fees
    // ------------------------------------------------------------------
    function settle() external track("settle") {
        bool windowBlocked = vault.bridgeInFlight();
        if (windowBlocked) {
            vm.prank(manager);
            try vault.settle() {
                vSettleInWindow++;
            } catch {}
            return;
        }
        // The keeper's checkRisk() precedes every settle; it may breach the vault.
        try vault.checkRisk() {} catch {}
        // Round 4: a leverage breach says nothing about the NAV and settles normally. A guardian full stop refuses
        // the manager's settle. A daily loss / drawdown breach (a possibly deflated NAV, audit C-01) allows only a
        // redemption-only settle: it must never price or mint a deposit.
        if (vault.breached() && !vault.emergency() && uint8(vault.breachReason()) != 1) {
            bool fullStop = uint8(vault.breachReason()) >= 4;
            vm.prank(manager);
            try vault.settle() {
                if (fullStop) {
                    vSettleWhileBreached++;
                } else {
                    (uint256 depA, uint256 depS,,,,,,) = vault.epochs(vault.currentEpoch() - 1);
                    if (depA + depS > 0) vSettleWhileBreached++;
                    settlesOk++;
                }
            } catch {}
            return;
        }
        // Fix round WP5 (HLR2-XA01): after a platform revoke the deposit hold makes every settle redemption-only, as a
        // loss breach does: redemptions are paid at min(NAV, checkpoint), so the remaining holders' price may rise. It
        // must never mint, and never fall (no redeemer is paid above the NAV).
        if (vault.depositHold() && !vault.emergency()) {
            uint256 sup = vault.totalSupply();
            uint256 pb;
            try lens.sharePriceAfterFees(vault) returns (uint256 x) {
                pb = x;
            } catch {
                return;
            }
            uint256 e = vault.currentEpoch();
            vm.prank(manager);
            try vault.settle() {
                settlesOk++;
                (uint256 depA, uint256 depS,,,,,,) = vault.epochs(e);
                if (depA + depS > 0) vSettleWhileBreached++;
                if (sup > 0 && vault.totalSupply() > 0 && vault.sharePrice() + 1 < pb) vPriceJump++;
            } catch {}
            return;
        }
        uint256 cp = vault.checkpointNav();
        uint256 supply = vault.totalSupply();
        uint256 priceBefore;
        uint256 expShares;
        uint256 expAssets;
        try lens.previewDeposit(vault, vault.pendingDepositAssets()) returns (uint256 x) {
            expShares = x;
            expAssets = lens.previewRedeem(vault, vault.pendingRedeemShares());
            priceBefore = lens.sharePriceAfterFees(vault); // the price settle() mints and burns at
        } catch {
            return; // NAV unreadable (outage): settle must revert too, covered in outage()
        }
        bool emergency = vault.emergency();
        uint256 ep = vault.currentEpoch();
        uint256 pre = vault.totalAssets(); // the NAV settle() prices at (fee minting does not change it)
        vm.prank(manager);
        try vault.settle() {
            settlesOk++;
            if (emergency) emergencySettles++;
            if (supply == 0) firstMintEpoch[ep] = true;
            (, uint256 ds,, uint256 ra,,,,) = vault.epochs(ep);
            if (emergency) {
                if (ds != 0) vEmergencyMinted++;
            } else {
                if (ds != expShares) vPreviewMismatch++;
                if (ra != expAssets) vPreviewMismatch++;
                // A normal settlement NAV is bounded by the checkpoint (maxNavMoveBps = 2,000 in this suite).
                if (cp > 0 && (pre > cp ? pre - cp : cp - pre) * BPS > cp * 2_000 + BPS) vSettleFarFromCheckpoint++;
            }
            uint256 supplyAfter = vault.totalSupply();
            // Exit-only settlements price redemptions at min(NAV, checkpoint): the remaining holders may gain.
            if (!emergency && supply > 0 && supplyAfter > 0) {
                uint256 priceAfter = vault.sharePrice();
                uint256 tol = 3 + ONE_SHARE / (supplyAfter + 1e6);
                if (priceAfter + 1 < priceBefore || priceAfter > priceBefore + tol) vPriceJump++;
            }
        } catch {}
    }

    function accrueFees(uint256 secs) external track("accrueFees") {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 0, 30 days));
        if (vault.bridgeInFlight()) return;
        uint256 assets = vault.totalAssets();
        uint256 elapsed = vm.getBlockTimestamp() - vault.lastFeeAccrual();
        // Management fee only: the performance fee never crystallises outside settle() (audit M-05).
        uint256 cap = (assets * vault.managementFeeBps() * elapsed) / (BPS * YEAR);
        uint256 f0 = vault.balanceOf(feeRecipient);
        uint256 t0 = vault.balanceOf(treasury);
        uint16 share = vault.protocolShareBps();
        uint256 peak = vault.peakSharePrice();
        uint256 price = vault.sharePrice();
        vault.accrueFees();
        uint256 t = vault.balanceOf(treasury) - t0;
        uint256 fee = vault.balanceOf(feeRecipient) - f0 + t;
        if (fee > 0) {
            feeAccruals++;
            uint256 val = (fee * (assets + 1)) / (vault.totalSupply() + 1e6);
            if (val > cap + 1) vFeeOverCap++;
            if (t != (fee * share) / BPS) vProtocolSplit++;
            // Fee dilution scales the peak instead of counting as drawdown (audit L-03).
            uint256 newPrice = vault.sharePrice();
            if (newPrice < price && vault.peakSharePrice() + 1 < (peak * newPrice) / price) vPeakReset++;
        }
    }

    // ------------------------------------------------------------------
    // Bridging and Core
    // ------------------------------------------------------------------
    function bridgeToCore(uint256 amt, bool dust) external track("bridgeToCore") {
        uint256 idle = vault.idleAssets();
        if (idle == 0) return;
        if (dust) amt = bound(amt, 1, MIN_BRIDGE - 1);
        else amt = idle < MIN_BRIDGE ? idle : bound(amt, MIN_BRIDGE, idle);
        bool inFlight = vault.bridgeInFlight();
        vm.prank(manager);
        try vault.bridgeToCore(amt) {
            if (inFlight) vWindowExtended++;
            if (amt < MIN_BRIDGE && amt != idle) vDustBridge++;
            spot += uint64(amt);
            sync();
        } catch {}
    }

    function bridgeToEvm(uint256 amt, bool asStranger, bool dust) external track("bridgeToEvm") {
        uint256 avail = uint256(spot) + (perp > 0 ? uint256(uint64(perp)) : 0);
        if (avail == 0) return;
        if (dust) amt = bound(amt, 1, MIN_BRIDGE - 1);
        else amt = avail < MIN_BRIDGE ? avail : bound(amt, MIN_BRIDGE, avail);
        bool inFlight = vault.bridgeInFlight();
        vm.prank(asStranger ? stranger : manager);
        try vault.bridgeToEvm(amt) {
            if (inFlight) vWindowExtended++;
            // Round 4 (stricter than the old "not outside emergency"): a stranger never bridges, emergency included.
            if (asStranger) vEmergencyUnauthorized++;
            if (amt < MIN_BRIDGE && amt != avail) vDustBridge++;
            if (amt > spot) {
                perp -= int64(uint64(amt - spot));
                spot = 0;
            } else {
                spot -= uint64(amt);
            }
            usdc.mint(address(vault), amt);
            sync();
        } catch {}
    }

    function moveUsd(uint256 amt, bool toPerp) external track("moveUsd") {
        uint256 from = toPerp ? spot : (perp > 0 ? uint256(uint64(perp)) : 0);
        if (from == 0) return;
        amt = bound(amt, 1, from);
        vm.prank(manager);
        try vault.moveUsd(amt, toPerp) {
            if (toPerp) {
                spot -= uint64(amt);
                perp += int64(uint64(amt));
            } else {
                perp -= int64(uint64(amt));
                spot += uint64(amt);
            }
            sync();
        } catch {}
    }

    /// @dev Simulated PnL on HyperCore: -60%..+60% of perp equity, and a random exposure for leverage.
    function pnl(int256 bpsMove, uint256 lev) external track("pnl") {
        bpsMove = bound(bpsMove, -6_000, 6_000);
        int256 p = int256(perp);
        if (p <= 0) p = 0;
        p += (p * bpsMove) / 10_000;
        if (p < 0) p = 0;
        perp = int64(p);
        ntl = uint64((uint256(p) * bound(lev, 0, 40_000)) / 10_000);
        sync();
    }

    /// @dev Audit C-01 model: the agent parks part of the perp equity where coreEquity() does not look.
    function hide(uint256 bps) external track("hide") {
        if (perp <= 0) return;
        uint64 part = uint64((uint256(uint64(perp)) * bound(bps, 1_000, 9_500)) / BPS);
        perp -= int64(part);
        hidden += part;
        sync();
    }

    function unhide() external track("unhide") {
        perp += int64(hidden);
        hidden = 0;
        sync();
    }

    function zeroCore() external track("zeroCore") {
        perp = 0;
        ntl = 0;
        sync();
    }

    /// @dev Precompile outage: NAV reads revert, settle/accrue must fail, exits (request/cancel) must still work.
    function outage(uint256 s) external track("outage") {
        address target = HyperCore.PRECOMPILE_ACCOUNT_MARGIN_SUMMARY;
        bytes memory saved = target.code;
        vm.etch(target, address(new RevertingPrecompile()).code);
        vm.prank(manager);
        try vault.settle() {
            vPriceJump++; // settle at an unreadable NAV
        } catch {}
        address a = _actor(s);
        uint256 shares = vault.balanceOf(a) / 2;
        if (shares > 0) {
            vm.prank(a);
            try vault.requestRedeem(shares, a, a) {
                vm.prank(a);
                try vault.cancelRedeemRequest() {} catch {
                    vExitBlockedByOutage++;
                }
            } catch {
                vExitBlockedByOutage++;
            }
        }
        vm.etch(target, saved);
    }

    // ------------------------------------------------------------------
    // Risk and emergency
    // ------------------------------------------------------------------
    function checkRisk() external track("checkRisk") {
        bool was = vault.breached();
        try vault.checkRisk() {} catch {}
        if (!was && vault.breached()) breaches++;
    }

    function flattenStranger(int64 szi, uint256 slippage) external track("flatten") {
        szi = int64(bound(szi, -1e9, 1e9));
        slippage = bound(slippage, 0, 600);
        MockPrecompile(HyperCore.PRECOMPILE_POSITION).setResponse(
            abi.encode(address(vault), uint32(0)), abi.encode(HyperCore.Position(szi, 0, 0, 10, false))
        );
        // Round 4 (stricter than the old "anyone at the policy band while breached"): a stranger never flattens.
        vm.prank(stranger);
        try vault.flatten(0, slippage) {
            vFlattenUnauthorized++;
        } catch {}
    }

    function triggerEmergencyStranger() external track("triggerEmergency") {
        bool allowed = lens.epochOverdue(vault) && vault.pendingRedeemShares() > 0;
        vm.prank(stranger);
        try vault.triggerEmergency() {
            if (!allowed) vEmergencyUnauthorized++;
        } catch {}
    }

    /// @dev Direct owner calls: the first three must always revert (timelocked after audit H-01).
    function ownerOps(uint256 op) external track("ownerOps") {
        vm.startPrank(owner);
        op = op % 7;
        if (op == 0) {
            try vault.clearBreach() {
                vInstantOwnerPower++;
            } catch {}
        } else if (op == 1) {
            try vault.exitEmergency() {
                vInstantOwnerPower++;
            } catch {}
        } else if (op == 2) {
            try vault.setAgent(agentAddr) {
                vInstantOwnerPower++;
            } catch {}
        } else if (op == 3) {
            try vault.leaveHosted() {} catch {}
        } else if (op == 4) {
            try factory.lowerProtocolShare(address(vault), uint16(_lastShare / 2)) {} catch {}
        } else if (op == 5) {
            try vault.setDepositsPaused(!vault.depositsPaused()) {} catch {}
        } else {
            try vault.revokeAgent() {} catch {}
        }
        vm.stopPrank();
    }

    /// @dev The hot sentinel: only risk reducing powers; anything else must revert.
    function sentinelOps(uint256 op) external track("sentinelOps") {
        address s = factory.sentinel();
        vm.startPrank(s);
        op = op % 8;
        if (op == 0) {
            try vault.revokeAgent() {} catch {}
        } else if (op == 1) {
            try vault.setDepositsPaused(true) {} catch {}
        } else if (op == 2) {
            try vault.setTradingPaused(true) {} catch {}
        } else if (op == 3) {
            try vault.triggerBreach() {} catch {}
        } else if (op == 4) {
            try vault.clearBreach() {
                vSentinelPower++;
            } catch {}
        } else if (op == 5) {
            try vault.setDepositsPaused(false) {
                vSentinelPower++;
            } catch {}
        } else if (op == 6) {
            bool allowed = lens.epochOverdue(vault) && vault.pendingRedeemShares() > 0;
            try vault.triggerEmergency() {
                if (!allowed) vSentinelPower++;
            } catch {}
        } else {
            try vault.flatten(0, 100) {
                vSentinelPower++;
            } catch {}
        }
        vm.stopPrank();
    }

    /// @dev The cold guardian: instant revoke, breach, pause, unpause and clear.
    function guardianOps(uint256 op) external track("guardianOps") {
        vm.startPrank(guardian);
        op = op % 4;
        if (op == 0) {
            try vault.revokeAgent() {} catch {}
        } else if (op == 1) {
            try vault.triggerBreach() {} catch {}
        } else if (op == 2) {
            try vault.clearBreach() {} catch {}
        } else {
            try vault.setDepositsPaused(true) {} catch {}
        }
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Timelock
    // ------------------------------------------------------------------
    function queue(uint256 which, uint256 val) external track("queue") {
        bytes memory data;
        which = which % 9;
        if (which == 0) data = abi.encodeCall(HyperVault.setManager, (manager));
        else if (which == 1) data = abi.encodeCall(HyperVault.setFees, (uint16(bound(val, 0, 500)), uint16(bound(val, 0, 3_000))));
        else if (which == 2) data = abi.encodeCall(HyperVault.setFeeRecipient, (feeRecipient));
        else if (which == 3) data = abi.encodeCall(HyperVault.setTimelockDelay, (bound(val, 1 days, 30 days)));
        else if (which == 4) data = abi.encodeCall(HyperVault.clearBreach, ());
        else if (which == 5) data = abi.encodeCall(HyperVault.exitEmergency, ());
        else if (which == 6) data = abi.encodeCall(HyperVault.setAgent, (val % 2 == 0 ? agentAddr : stranger));
        else if (which == 7) data = abi.encodeWithSignature("setGuardian(address)", stranger);
        else data = abi.encodeWithSignature("transfer(address,uint256)", stranger, val);
        vm.prank(owner);
        try vault.queue(data) {
            if (which == 5 || which >= 7) vBadSelectorQueued++; // exitEmergency is the guardian's (W-01b)
            _queued.push(data);
        } catch {}
    }

    function execute(uint256 idx) external track("execute") {
        if (_queued.length == 0) return;
        bytes memory data = _queued[idx % _queued.length];
        uint256 eta = vault.queuedEta(keccak256(data));
        bool early = eta == 0 || vm.getBlockTimestamp() < eta;
        bool late = eta != 0 && vm.getBlockTimestamp() > eta + vault.GRACE_PERIOD();
        uint256 pending = vault.pendingRedeemShares();
        bool wasEmergency = vault.emergency();
        bool wasBreached = vault.breached();
        bool prequeued = wasBreached && bytes4(data) == HyperVault.clearBreach.selector && vault.queuedAt(keccak256(data)) <= vault.breachedAt();
        try vault.execute(data) {
            timelockedOk++;
            if (early) vEarlyExecute++;
            if (late) vLateExecute++;
            if (wasEmergency && !vault.emergency() && pending > 0) vInstantOwnerPower++;
            if (prequeued && !vault.breached()) vPrequeuedClear++;
        } catch {}
    }

    // ------------------------------------------------------------------
    // Views for the invariant contract
    // ------------------------------------------------------------------
    function actorList() external view returns (address[3] memory) {
        return actors;
    }

    function callCount(string calldata name) external view returns (uint256) {
        return calls[bytes32(bytes(name))];
    }
}
