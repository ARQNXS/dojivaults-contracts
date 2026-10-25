// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {HyperCore} from "./hypercore/HyperCore.sol";
import {VaultMath} from "./VaultMath.sol";
import {VaultPolicy} from "./VaultPolicy.sol";
import {
    BPS,
    BreachReason,
    INSIDER_MIN_EPOCH_AGE,
    DECIMALS_OFFSET,
    EXIT_CHECKPOINT_FRESH,
    EMERGENCY_BRIDGE_COOLDOWN,
    EpochResult,
    IHyperVaultErrors as E,
    IHyperVaultEvents as Ev,
    IVaultFactory,
    MIN_BRIDGE,
    MIN_DEPOSIT,
    MODE_PIN_INTERVAL,
    ONE_SHARE,
    ORPHAN_DUST,
    Request,
    TICKET_CLOID_PREFIX,
    VaultStorage,
    YEAR
} from "./VaultTypes.sol";

/// @title VaultLogic
/// @notice Depositor flow, settlement, fees, bridging, trading and the agent slot of HyperVault. Linked as an
///         external library: every function runs by delegatecall on the vault's own storage.
library VaultLogic {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using VaultMath for VaultStorage;

    // ==================================================================
    // Depositor flow
    // ==================================================================
    /// @dev A deposit by the manager, the owner or the fee recipient (as sender or controller) is priced at the NEXT
    ///      epoch's settlement, never in the epoch whose timing and NAV the insider can influence. Such a request
    ///      belongs to epoch currentEpoch + 1 and its USDC is held apart (deferredDepositAssets) until then. A
    ///      controller has one request at a time: mixing a current-epoch request with a next-epoch one reverts.
    function requestDeposit(VaultStorage storage $, uint256 assets, address controller) external returns (uint256 epoch) {
        _enter($);
        if (assets == 0) revert E.ZeroAmount();
        if (assets < MIN_DEPOSIT) revert E.DepositTooSmall();
        if (controller == address(0)) revert E.ZeroAddress();
        if ($.depositsPaused || $.breached || $.emergency || $.depositHold) revert E.DepositsClosed();
        // HLO-07: no deposit while a launch-time agent binding can still be vetoed.
        if ($.agent != address(0) && block.timestamp < $.agentActiveAt) revert E.AgentWarmingUp($.agentActiveAt);
        if ($.depositCap != 0 && $.totalAssets() + $.pendingDepositAssets + $.deferredDepositAssets + assets > $.depositCap) {
            revert E.CapExceeded();
        }

        _claimIfSettled($, controller);
        _rejoinCarry($, controller);
        bool insider = _isInsider($, msg.sender) || _isInsider($, controller);
        epoch = insider ? $.currentEpoch + 1 : $.currentEpoch;
        Request storage r = $.requests[controller];
        if ((r.depositAssets > 0 || r.redeemShares > 0) && r.epoch != epoch) revert E.RequestPending();
        $.asset.safeTransferFrom(msg.sender, address(this), assets);
        $.evmInSinceBridge += assets;

        r.epoch = epoch;
        r.depositAssets += assets;
        if (insider) $.deferredDepositAssets += assets;
        else $.pendingDepositAssets += assets;

        emit Ev.DepositRequested(controller, msg.sender, epoch, assets);
        _exit($);
    }

    /// @dev Always allowed, including during breach or emergency: exits are never gated.
    function requestRedeem(VaultStorage storage $, uint256 shares, address controller, address owner_)
        external
        returns (uint256 epoch)
    {
        _enter($);
        if (shares == 0) revert E.ZeroAmount();
        if (controller == address(0)) revert E.ZeroAddress();
        if (msg.sender != owner_) VaultMath.spendAllowance(owner_, msg.sender, shares);

        _claimIfSettled($, controller);
        _rejoinCarry($, controller);
        Request storage r = $.requests[controller];
        // A deposit waiting for the next epoch must settle first: one request per controller. (A carried deposit
        // has just rejoined the current epoch, so exits are never gated by it.)
        if (r.epoch > $.currentEpoch) revert E.RequestPending();
        VaultMath.transfer(owner_, address(this), shares);

        r.epoch = $.currentEpoch;
        r.redeemShares += shares;
        $.pendingRedeemShares += shares;

        emit Ev.RedeemRequested(controller, owner_, $.currentEpoch, shares);
        _exit($);
        return $.currentEpoch;
    }

    function cancelDepositRequest(VaultStorage storage $) external {
        Request storage r = $.requests[msg.sender];
        if (r.depositAssets == 0) revert E.NothingToCancel();
        if (r.epoch < $.currentEpoch) {
            // only a deposit still carried by a redemption-only epoch is cancellable once its epoch has passed
            (,, bool carried) = $.claimableWithCarry(msg.sender);
            if (!carried) revert E.NothingToCancel();
        }
        uint256 assets = r.depositAssets;
        r.depositAssets = 0;
        if (r.epoch > $.currentEpoch) $.deferredDepositAssets -= assets;
        else $.pendingDepositAssets -= assets;
        $.evmOutSinceBridge += assets;
        $.asset.safeTransfer(msg.sender, assets);
        emit Ev.DepositCancelled(msg.sender, assets);
    }

    /// @dev Cancels what is still pending in the current epoch (a settled request is claimed first).
    function cancelRedeemRequest(VaultStorage storage $) external {
        _claimIfSettled($, msg.sender);
        Request storage r = $.requests[msg.sender];
        if (r.epoch != $.currentEpoch || r.redeemShares == 0) revert E.NothingToCancel();
        uint256 shares = r.redeemShares;
        r.redeemShares = 0;
        $.pendingRedeemShares -= shares;
        VaultMath.transfer(address(this), msg.sender, shares);
        emit Ev.RedeemCancelled(msg.sender, shares);
    }

    /// @dev Delivers settled shares and USDC to `controller`. Callable by anyone.
    function claim(VaultStorage storage $, address controller) external {
        Request storage r = $.requests[controller];
        if (r.epoch >= $.currentEpoch) revert E.RequestNotSettled();
        (,, bool carried) = $.claimableWithCarry(controller);
        if (carried && r.redeemShares == 0) revert E.RequestNotSettled();
        _claimIfSettled($, controller);
    }

    /// @dev Delivers the epoch's result: minted shares and refunds for deposits, the pro rata payout for
    ///      redemptions plus the shares the epoch could not pay for (partial fill + return, audit V-01).
    function _claimIfSettled(VaultStorage storage $, address controller) internal {
        Request storage r = $.requests[controller];
        if (r.epoch >= $.currentEpoch) return;
        if (r.depositAssets == 0 && r.redeemShares == 0) return;
        (uint256 shares, uint256 assets, bool carried) = $.claimableWithCarry(controller);
        uint256 epoch = r.epoch;
        // A carried deposit stays queued (with its epoch pointer); only the redemption part is delivered.
        if (!carried) r.depositAssets = 0;
        r.redeemShares = 0;
        if (shares > 0) VaultMath.transfer(address(this), controller, shares);
        if (assets > 0) {
            // Pro rata rounding can leave a few wei short of the reserve; never pay out of other users' money.
            if (assets > $.claimableRedeemAssets) assets = $.claimableRedeemAssets;
            $.claimableRedeemAssets -= assets;
            $.evmOutSinceBridge += assets;
            $.asset.safeTransfer(controller, assets);
        }
        emit Ev.Claimed(controller, epoch, shares, assets);
    }

    /// @dev A deposit still carried by a redemption-only epoch moves to the current epoch. Sound because the carried
    ///      USDC is in the shared queue (pendingDepositAssets) and the current epoch either continues the same carry
    ///      run (another redemption-only settle) or prices it; either way the request resolves to the same result.
    function _rejoinCarry(VaultStorage storage $, address controller) internal {
        Request storage r = $.requests[controller];
        if (r.depositAssets == 0 || r.epoch >= $.currentEpoch) return;
        (,, bool carried) = $.claimableWithCarry(controller);
        if (carried) r.epoch = $.currentEpoch;
    }

    function _isInsider(VaultStorage storage $, address a) internal view returns (bool) {
        return a == $.manager || a == VaultMath.owner() || a == $.feeRecipient;
    }

    /// @dev A daily loss or drawdown breach outside emergency (redemption-only settles, no added margin).
    function _lossBreach(VaultStorage storage $) internal view returns (bool) {
        return !$.emergency && $.breached && ($.breachReason == BreachReason.DAILY_LOSS || $.breachReason == BreachReason.DRAWDOWN);
    }

    /// @dev Treasury actions: the manager or the operator.
    function _treasury(VaultStorage storage $) internal view returns (bool) {
        return msg.sender == $.manager || (msg.sender == $.operator && $.operator != address(0));
    }

    /// @dev Platform and owner roles that may unwind a vault in breach or emergency.
    function _platform(VaultStorage storage $, address guardian, address sentinel) internal view returns (bool) {
        return msg.sender == VaultMath.owner() || msg.sender == guardian || msg.sender == sentinel || msg.sender == $.manager;
    }

    // ==================================================================
    // Settlement and fees
    // ==================================================================
    /// @notice Prices the epoch at NAV, mints shares for deposits and reserves USDC for redemptions.
    /// @dev Three modes, for the owner, manager, operator, sentinel and guardian only.
    ///      Normal (the manager or the operator, outside emergency and outside any breach except a leverage one):
    ///      deposits are minted, redemptions paid in full or the call reverts, NAV must be within
    ///      policy.maxNavMoveBps of the keeper's checkpoint.
    ///      Redemption-only (any listed role, in a daily loss or drawdown breach): redemptions are paid in full at
    ///      the current NAV under the same checkpoint bound; nothing is minted and the deposit queue is carried to
    ///      the epoch that prices it once the breach clears (claims follow it in O(1); a carried deposit can be
    ///      cancelled). Audit C-01 stays closed: no share is ever minted at a NAV that may be deflated.
    ///      Exit only (emergency, or once the epoch is overdue; by the owner, manager, operator, sentinel or
    ///      guardian, never by anyone else): queued deposits are refunded, never minted; redemptions are priced at
    ///      min(NAV, checkpoint) and, in emergency, filled pro rata to the liquidity on hand: only the shares that
    ///      were paid for are burned, the rest go back to the redeemers on claim (partial fill + return, audit
    ///      V-01). Nothing rolls into a later epoch except the insiders' next-epoch deposits. The NAV bound never
    ///      blocks an exit. Never inside a bridge window.
    function settle(VaultStorage storage $, address guardian, address sentinel) external {
        _enter($);
        bool treasury = msg.sender == $.manager || (msg.sender == $.operator && $.operator != address(0));
        bool platform = msg.sender == VaultMath.owner() || msg.sender == guardian || msg.sender == sentinel;
        if (!treasury && !platform) revert E.Unauthorized();
        // HLR2-E06: a full stop outside emergency freezes every settle only when the guardian or the sentinel imposed
        // it (platformHold), or after an emergency the guardian ended without clearing. A full stop the vault owner
        // imposed alone settles redemption-only: the owner cannot freeze the exits until the epoch is overdue.
        bool ownerStop = $.hardStop() && !$.emergency;
        if (ownerStop && ($.platformHold || $.breachReason != BreachReason.GUARDIAN)) revert E.ReduceOnlyMode();
        // A daily loss or drawdown breach may be the visible side of a deflated NAV (audit C-01): such a settle is
        // redemption-only (pays redemptions at the current NAV within the checkpoint bound, mints nothing, carries
        // the deposit queue). A leverage breach says nothing about the NAV and settles normally.
        // HLR2-XA01: after a platform revoke the NAV may be deflated by the revoked agent: no deposit is priced until
        // the guardian clears the hold.
        bool redemptionOnly = _lossBreach($) || ownerStop || ($.depositHold && !$.emergency);
        bool exitOnly = $.emergency || (!treasury && !redemptionOnly);
        if (exitOnly && !$.emergency && !$.epochOverdue()) revert E.Unauthorized();
        // R3-02: a settle that would PRICE insider deposits runs at least INSIDER_MIN_EPOCH_AGE into the epoch, so two
        // settles in one block cannot price an insider at a NAV of their choosing. Exits are never delayed by it:
        // redemption-only and exit-only settles price no deposit.
        if (!exitOnly && !redemptionOnly && $.insiderInQueue && block.timestamp < uint256($.epochStartedAt) + INSIDER_MIN_EPOCH_AGE) {
            revert E.EpochTooYoung();
        }
        _syncBridge($);
        if ($.bridgePending()) revert E.BridgeInFlight();
        // HLR2-A02 / A08: never price anything, exits included, at a NAV short by a transfer that is merely late.
        if ($.bridgeUnresolved()) revert E.TransferUnresolved();
        // HL-PROXY: a NAV read under a non-Standard account mode is not a NAV (unified / portfolio margin move or hide
        // balances, CONTEXT evidence 3): nothing is minted or paid at it. Exit-only settles are never gated (they price
        // at min(NAV, checkpoint)); every settle re-pins the mode.
        if (!exitOnly && VaultMath.modeSuspect()) revert E.AccountModeMismatch();
        _pinMode($);

        // No performance fee is ever charged in a breach or emergency settle (any reason, leverage included): only the
        // management fee accrues, and the high water mark does not move until the vault is out of the breach.
        _accrueFees($, !$.breached && !$.emergency);
        // A scheduled performance fee raise starts with the next epoch: the running one was just charged at the
        // old rate (audit N2-02).
        uint16 pendingPerf = $.pendingPerformanceFeeBps;
        // Only a settle that charged the running epoch at the old rate switches the raise on (N2-02); a breach or
        // emergency settle charges no performance fee, so the raise waits for the next normal one (R3-06).
        if (pendingPerf != 0 && !$.breached && !$.emergency) {
            $.performanceFeeBps = pendingPerf;
            $.pendingPerformanceFeeBps = 0;
            emit Ev.FeesUpdated($.managementFeeBps, pendingPerf);
        }

        uint256 nav = $.totalAssets();
        uint256 priceNav = nav;
        if (exitOnly) {
            // HLR2-E01: min(NAV, checkpoint) may only withhold a rise younger than one checkpoint interval (a
            // spike). A checkpoint that trails the NAV and could still be walked up (an hour or more old, or capped
            // at its last step) would withhold real gains from the redeemers, so the settle waits for the walk
            // (permissionless checkRisk, one step of maxNavMoveBps per hour) instead of paying at it.
            uint256 cp = $.checkpointNav;
            if (cp > 0 && cp < nav) {
                if ($.checkpointLagging || block.timestamp >= uint256($.checkpointAt) + EXIT_CHECKPOINT_FRESH) {
                    revert E.CheckpointBehind(cp, nav);
                }
                priceNav = cp;
            }
        } else {
            // A redemption-only settle pays at min(live NAV, previous checkpoint), read before the ratchet: a NAV
            // pushed up inside the per-settle bound is never paid out in a loss breach (REAUDIT3 question a).
            uint256 cp = $.checkpointNav;
            _checkpoint($, nav, true);
            if (redemptionOnly && cp > 0 && cp < nav) priceNav = cp;
        }

        uint256 depAssets = redemptionOnly ? 0 : $.pendingDepositAssets;
        uint256 depIn = exitOnly ? 0 : depAssets;
        uint256 redShares = $.pendingRedeemShares;
        uint256 supply = VaultMath.totalSupply();
        uint256 redAssets = VaultMath.toAssets(redShares, priceNav, supply, Math.Rounding.Floor);
        uint256 depShares = VaultMath.toShares(depIn, nav, supply, Math.Rounding.Floor);
        // HLR2-A08 part 3 / E01e: back at supply 0 with NAV left over, the first mint would hand that NAV to the new
        // depositor. It is minted at the first-mint rule to the guardian instead (who returns it to the redeemers it
        // belongs to), and the deposit is priced against it, so the depositor gets exactly the value paid.
        uint256 orphanShares;
        if (supply == 0 && depShares > 0 && $.everMinted && nav > ORPHAN_DUST && guardian != address(0)) {
            orphanShares = VaultMath.toShares(nav, 0, 0, Math.Rounding.Floor);
            depShares = VaultMath.toShares(depIn, nav, orphanShares, Math.Rounding.Floor);
        }
        if (depShares == 0) depIn = 0; // nothing to mint: refund instead of swallowing the deposit (N-11)

        uint256 available = $.idleAssets() + depIn;
        uint256 paid = redAssets;
        uint256 burned = redShares;
        if (available < redAssets) {
            if (!$.emergency) revert E.InsufficientLiquidity(available, redAssets);
            // Partial fill: burn only the shares the payout covers (rounded down, so the vault never over-burns);
            // the remaining shares are returned to the redeemers when they claim.
            paid = available;
            burned = redShares.mulDiv(paid, redAssets, Math.Rounding.Floor);
        }

        if (burned > 0) VaultMath.burn(address(this), burned);
        if (depShares > 0) {
            if (orphanShares > 0) {
                VaultMath.mint(guardian, orphanShares);
                emit Ev.OrphanedNavReserved(guardian, nav, orphanShares);
            }
            VaultMath.mint(address(this), depShares);
            $.everMinted = true;
        }

        $.claimableRedeemAssets += paid + depAssets - depIn;
        uint256 epoch = $.currentEpoch;
        uint256 carriedFrom;
        if (redemptionOnly) {
            // The deposit queue is carried, not priced: it stays reserved and joins (or opens) the carry run.
            if ($.pendingDepositAssets > 0) {
                if ($.carryOrigin == 0) $.carryOrigin = epoch + 1;
                carriedFrom = $.carryOrigin;
            }
            if ($.deferredDepositAssets > 0) $.insiderInQueue = true;
            $.pendingDepositAssets += $.deferredDepositAssets;
        } else {
            // This settle priced (or refunded) the queue, carried deposits included.
            if ($.carryOrigin != 0) {
                $.carryPricedIn[$.carryOrigin - 1] = epoch + 1;
                $.carryOrigin = 0;
            }
            $.pendingDepositAssets = $.deferredDepositAssets;
            $.insiderInQueue = $.deferredDepositAssets > 0;
        }
        // The insiders' deposits for the next epoch become that epoch's queue.
        $.deferredDepositAssets = 0;
        $.pendingRedeemShares = 0;

        // Flows settle at the share price, so the risk references (day start price, peak) need no adjustment
        // (R-01). A first mint into an empty vault starts them from the new price.
        uint256 price = $.sharePrice();
        if (supply == 0 && depShares > 0) {
            $.highWaterMark = price;
            $.peakSharePrice = price;
            $.dayStartSharePrice = price;
        }
        if (price > $.peakSharePrice) $.peakSharePrice = price;

        $.epochs[epoch] = EpochResult({
            depositAssets: depAssets,
            depositShares: depShares,
            redeemShares: redShares,
            redeemAssets: paid,
            redeemBurned: burned,
            nav: $.totalAssets(),
            sharePrice: price,
            settledAt: uint64(block.timestamp),
            carriedFrom: carriedFrom
        });
        $.currentEpoch = epoch + 1;
        $.epochStartedAt = uint64(block.timestamp);
        $.epochDeadline = uint64(block.timestamp + $.policy.maxEpochDuration());
        // Flows are applied now, so the next bound starts from the post settlement NAV.
        _setCheckpoint($, $.totalAssets());

        emit Ev.EpochSettled(epoch, nav, depAssets, depShares, redShares, paid);
        _exit($);
    }

    /// @notice Accrues the management fee by minting shares. The performance fee only crystallises in settle()
    ///         and the high water mark only moves there (audit M-05 / N-05 / N-08).
    function accrueFees(VaultStorage storage $) external {
        _syncBridge($);
        if ($.bridgePending()) revert E.BridgeInFlight();
        if (VaultMath.modeSuspect()) revert E.AccountModeMismatch();
        _accrueFees($, false);
    }

    function _accrueFees(VaultStorage storage $, bool withPerformance) internal {
        uint256 supply = VaultMath.totalSupply();
        uint256 assets = $.totalAssets();
        uint256 elapsed = block.timestamp - $.lastFeeAccrual;
        $.lastFeeAccrual = uint64(block.timestamp);
        if (supply == 0 || assets == 0) return;

        uint256 feeAssets = assets.mulDiv(uint256($.managementFeeBps) * elapsed, BPS * YEAR);
        uint256 price = $.sharePrice();
        if (withPerformance && price > $.highWaterMark && $.performanceFeeBps > 0) {
            uint256 gain = (price - $.highWaterMark).mulDiv(supply, ONE_SHARE);
            feeAssets += gain.mulDiv($.performanceFeeBps, BPS);
        }

        uint256 feeShares;
        uint256 protocolShares;
        if (feeAssets > 0 && feeAssets < assets) {
            feeShares = feeAssets.mulDiv(supply + 10 ** DECIMALS_OFFSET, assets - feeAssets);
            if ($.factory != address(0) && $.protocolShareBps > 0) {
                address protocolRecipient = IVaultFactory($.factory).protocolFeeRecipient();
                if (protocolRecipient != address(0)) {
                    protocolShares = feeShares.mulDiv($.protocolShareBps, BPS);
                    if (protocolShares > 0) VaultMath.mint(protocolRecipient, protocolShares);
                }
            }
            if (feeShares > protocolShares) VaultMath.mint($.feeRecipient, feeShares - protocolShares);
        }

        uint256 newPrice = $.sharePrice();
        if (withPerformance && newPrice > $.highWaterMark) $.highWaterMark = newPrice;
        // Fee dilution is not a loss: scale both risk references by the same factor (audit L-03, R-01).
        if (feeShares > 0 && newPrice < price) {
            $.peakSharePrice = $.peakSharePrice.mulDiv(newPrice, price);
            $.dayStartSharePrice = $.dayStartSharePrice.mulDiv(newPrice, price);
        }
        emit Ev.FeesAccrued(feeShares, protocolShares, newPrice);
    }

    // ------------------------------------------------------------------
    // NAV checkpoint (rule in VaultPolicy.nextCheckpoint, audit C-01 / N-03 / N-12)
    // ------------------------------------------------------------------
    function _checkpoint(VaultStorage storage $, uint256 nav, bool settling) internal {
        (uint256 next, bool update) = $.policy.nextCheckpoint($.checkpointNav, $.checkpointAt, nav, settling);
        if (update) {
            _setCheckpoint($, next);
            if (next < nav) $.checkpointLagging = true; // a capped step up: more steps are due (HLR2-E01)
        }
    }

    function _setCheckpoint(VaultStorage storage $, uint256 nav) internal {
        $.checkpointNav = SafeCast.toUint192(nav);
        $.checkpointAt = uint64(block.timestamp);
        $.checkpointLagging = false;
    }

    /// @dev Exposed for VaultGovernance.checkRisk (same delegatecall context).
    function checkpoint(VaultStorage storage $, uint256 nav) external {
        _checkpoint($, nav, false);
    }

    // ==================================================================
    // Hosting and protocol share
    // ==================================================================
    /// @notice Leaves the hosted strategy: drops the protocol share to the base rate and revokes the agent. One way.
    function leaveHosted(VaultStorage storage $) external {
        if (msg.sender != VaultMath.owner()) revert E.Unauthorized();
        if (!$.hosted) revert E.NotHosted();
        $.hosted = false;
        if ($.baseShareBps < $.protocolShareBps) $.protocolShareBps = $.baseShareBps;
        _revokeAgent($);
        emit Ev.LeftHosted($.protocolShareBps);
    }

    /// @notice Factory only. Lowers this vault's protocol share. Raising is impossible by construction.
    function lowerProtocolShare(VaultStorage storage $, uint16 newBps) external {
        if (msg.sender != $.factory) revert E.Unauthorized();
        if (newBps >= $.protocolShareBps) revert E.InvalidShare();
        $.protocolShareBps = newBps;
        if (newBps < $.baseShareBps) $.baseShareBps = newBps;
        emit Ev.ProtocolShareLowered(newBps);
    }

    // ==================================================================
    // Bridging. One rule: a bridge opens a window of BRIDGE_SETTLE_BLOCKS during which nothing bridges, settles
    // or accrues; the window closes by itself and is never extended (audit N-01).
    // ==================================================================
    /// @notice Moves idle USDC into the vault's HyperCore spot balance. Use moveUsd to fund perp margin.
    function bridgeToCore(VaultStorage storage $, uint256 amount) external {
        if (!_treasury($)) revert E.Unauthorized();
        if (amount == 0) revert E.ZeroAmount();
        // More margin lowers leverage: allowed in a leverage breach. Refused in a daily loss / drawdown breach (it
        // would feed an agent the contract cannot hold to reduce only, and drain the idle USDC redemption-only
        // settles pay from, R3-04) and in a full stop.
        if ($.hardStop() || _lossBreach($)) revert E.ReduceOnlyMode();
        if (!HyperCore.coreUserExists(address(this))) revert E.CoreAccountInactive();
        uint256 idle = $.idleAssets();
        if (amount > idle) revert E.InsufficientIdle(idle, amount);
        if (amount < MIN_BRIDGE && amount != idle) revert E.BridgeTooSmall();
        _openWindow($, amount, true);
        _depositToCore($, amount);
        emit Ev.BridgedToCore(amount);
    }

    /// @notice Moves USDC from HyperCore back to the vault on HyperEVM. The manager or the operator outside
    ///         emergency; during emergency only the guardian and the sentinel (never anyone else, which also closes
    ///         X-01). HLR2-H04: every bridge opens a window in which no settle can run, so in emergency no
    ///         owner-chosen address (manager, owner, operator) may open one and keep the exit settle out.
    ///         Uses spot USDC first, then pulls the rest from the perp account.
    function bridgeToEvm(VaultStorage storage $, uint256 amount, address guardian, address sentinel) external {
        if ($.emergency) {
            // XF-01 (hl-r2 cross-review of H04): the guardian and the sentinel bridge at any time. The owner-chosen
            // roles (manager, owner, operator) may still bring USDC home without the platform, but never within
            // EMERGENCY_BRIDGE_COOLDOWN blocks of the previous bridge: every window is followed by free blocks in which
            // the exit settle can land, so no chain of windows can keep it out (H04 stays closed).
            if (msg.sender != guardian && msg.sender != sentinel) {
                if (!_platform($, guardian, sentinel) && !_treasury($)) revert E.Unauthorized();
                if ($.lastBridgeBlock != 0 && block.number <= $.lastBridgeBlock + EMERGENCY_BRIDGE_COOLDOWN) revert E.BridgeInFlight();
            }
        } else if (!_treasury($)) {
            revert E.Unauthorized();
        }
        if (amount == 0) revert E.ZeroAmount();
        uint256 spotUsd = uint256(HyperCore.spotBalance(address(this), HyperCore.USDC_TOKEN).total) / 100;
        uint256 perpFree = HyperCore.withdrawable(address(this));
        if (amount > spotUsd + perpFree) revert E.InsufficientLiquidity(spotUsd + perpFree, amount);
        if (amount < MIN_BRIDGE && amount != spotUsd + perpFree) revert E.BridgeTooSmall();
        _openWindow($, amount, false);
        if (amount > spotUsd) HyperCore.usdClassTransfer(SafeCast.toUint64(amount - spotUsd), false);
        HyperCore.sendAsset(
            HyperCore.USDC_SYSTEM_ADDRESS, HyperCore.SPOT_DEX, HyperCore.SPOT_DEX, HyperCore.USDC_TOKEN, SafeCast.toUint64(amount * 100)
        );
        emit Ev.BridgedToEvm(amount);
    }

    /// @dev Snapshot NAV and the destination side before the transfer and open the window. Reverts while one is
    ///      open (a landed bridge is latched first, R-02).
    function _openWindow(VaultStorage storage $, uint256 amount, bool toCore) internal {
        _syncBridge($);
        if ($.bridgePending()) revert E.BridgeInFlight();
        // HLR2-A05: a new window would read the late arrival of the missing transfer as its own landing.
        if ($.bridgeUnresolved()) revert E.TransferUnresolved();
        uint256 core = VaultMath.coreEquity();
        $.equityAtBridge = $.idleAssets() + core;
        $.bridgeAmount = amount;
        $.lastBridgeBlock = block.number;
        _arm($, toCore, core);
    }

    function _arm(VaultStorage storage $, bool toCore, uint256 core) internal {
        $.bridgeToCoreDir = toCore;
        $.bridgeLanded = false;
        $.coreAtBridge = core;
        $.spotAtBridge = VaultMath.coreSpotUsd();
        ($.cashKnown, $.cashAtBridge) = $.tryCoreCash();
        $.creditSeen = false;
        $.debitSeen = false;
        $.bridgeWrittenOff = false;
        $.evmAtBridge = $.asset.balanceOf(address(this));
        $.evmInSinceBridge = 0;
        $.evmOutSinceBridge = 0;
    }

    /// @dev Latches the landing of the latest bridge the first time a transaction sees it (R-02).
    function _syncBridge(VaultStorage storage $) internal {
        if ($.lastBridgeBlock == 0 || $.bridgeLanded) return;
        if ($.bridgeArrived()) {
            $.bridgeLanded = true;
            return;
        }
        // HLR2-A02 / A08: latch what HyperCore shows of the transfer while it is still fresh (a real reading only).
        if (!$.cashKnown || $.creditSeen || $.debitSeen) return;
        (bool ok, int256 c) = $.tryCoreCash();
        if (!ok) return;
        int256 half = int256($.bridgeAmount / 2);
        if ($.bridgeToCoreDir) {
            if (c >= $.cashAtBridge + half) $.creditSeen = true;
        } else if (c + half <= $.cashAtBridge) {
            $.debitSeen = true;
        }
    }

    /// @dev Exposed for VaultGovernance (same delegatecall context).
    function syncBridge(VaultStorage storage $) external {
        _syncBridge($);
    }

    function _depositToCore(VaultStorage storage $, uint256 amount) internal {
        // Circle USDC blocks direct transfers to the system address, and the CoreDepositWallet's forward into
        // perp fails for contracts. Depositing into our own spot balance takes the direct path.
        $.asset.approve(address($.coreDepositWallet), amount);
        $.coreDepositWallet.deposit(amount, HyperCore.SPOT_DEX);
    }

    /// @dev Seed bridge at initialization: the Core account does not exist yet, the seed is the whole NAV.
    function seedCore(VaultStorage storage $, uint256 amount) external {
        $.equityAtBridge = amount;
        $.bridgeAmount = amount;
        $.lastBridgeBlock = block.number;
        // The Core account does not exist yet: nothing to read, the seed lands on an empty spot balance.
        $.bridgeToCoreDir = true;
        $.bridgeLanded = false;
        $.cashAtBridge = 0;
        $.cashKnown = false;
        $.creditSeen = false;
        $.debitSeen = false;
        // HLR2-A02 / A08: the seed is the launcher's own money and lands before any depositor is priced on mainnet;
        // a lost seed (testnet drops credits to addresses absent on mainnet) must not hold the first settles.
        $.bridgeWrittenOff = true;
        _depositToCore($, amount);
        emit Ev.BridgedToCore(amount);
    }

    /// @notice Sends native HYPE to the vault's HyperCore spot balance so Core actions (bridgeToEvm) have gas.
    function fundCoreGas(VaultStorage storage, uint256 value) external {
        if (value == 0) revert E.ZeroAmount();
        (bool ok, bytes memory ret) = HyperCore.HYPE_SYSTEM_ADDRESS.call{value: value}("");
        if (!ok) revert E.CallFailed(ret);
        emit Ev.CoreGasFunded(msg.sender, value);
    }

    /// @notice Moves USDC between the vault's HyperCore spot and perp balances (6 decimals).
    function moveUsd(VaultStorage storage $, uint256 amount, bool toPerp) external {
        if (!_treasury($)) revert E.Unauthorized();
        if (amount == 0) revert E.ZeroAmount();
        if (toPerp && ($.hardStop() || _lossBreach($))) revert E.ReduceOnlyMode();
        _syncBridge($);
        if ($.bridgePending()) revert E.BridgeInFlight();
        HyperCore.usdClassTransfer(SafeCast.toUint64(amount), toPerp);
        emit Ev.UsdMoved(amount, toPerp);
    }

    // ==================================================================
    // Trading
    // ==================================================================
    /// @notice Sends a policy checked limit order from the vault's HyperCore account. The manager, or the platform agent
    ///         (HL-PROXY: the agent's only trading path; it is never approved as a HyperCore API wallet). The agent
    ///         sends IOC orders only, always with its own cloid (never the Order ticket's prefix).
    function placeOrder(
        VaultStorage storage $,
        uint32 asset_,
        bool isBuy,
        uint64 limitPx,
        uint64 sz,
        bool reduceOnly,
        uint8 tif,
        uint128 cloid
    ) external {
        bool isAgent = msg.sender == $.agent && $.agent != address(0);
        if (msg.sender != $.manager && !isAgent) revert E.Unauthorized();
        if (($.breached || $.emergency) && !reduceOnly) revert E.ReduceOnlyMode();
        if ($.tradingPaused && !reduceOnly) revert E.TradingIsPaused();
        if (sz == 0 || limitPx == 0) revert E.ZeroAmount();
        if (asset_ >= HyperCore.SPOT_ASSET_OFFSET) revert E.OrderRejected("spot not supported");
        // HLR2-F05: only the three TIFs HyperCore defines
        if (tif == 0 || tif > HyperCore.TIF_IOC) revert E.OrderRejected("tif");
        // HLO-07 (integrated): the agent has no power at all while its binding can still be vetoed
        if (isAgent && block.timestamp < $.agentActiveAt) revert E.AgentWarmingUp($.agentActiveAt);
        if (isAgent && (tif != HyperCore.TIF_IOC || cloid == 0 || cloid >> 96 == TICKET_CLOID_PREFIX)) {
            revert E.OrderRejected("agent order");
        }
        // HL-PROXY: no risk is added while the account mode is not the Standard one (NAV and leverage would misread)
        if (!reduceOnly && VaultMath.modeSuspect()) revert E.AccountModeMismatch();
        (uint256 mark1e8,) = HyperCore.markPx1e8(asset_);
        HyperCore.AccountMarginSummary memory m = HyperCore.accountMarginSummary(address(this));
        (bool ok, string memory reason) = $.policy.checkOrder(asset_, isBuy, limitPx, sz, reduceOnly, mark1e8, m.accountValue, m.ntlPos);
        if (!ok) revert E.OrderRejected(reason);
        if ($.breached || $.emergency) {
            // XF-02: in a breach or emergency (reduce only) the close band is the flatten cap, not maxSlippageBps
            uint256 band = (mark1e8 * $.policy.maxFlattenSlippageBps()) / BPS;
            if (isBuy ? uint256(limitPx) > mark1e8 + band : uint256(limitPx) + band < mark1e8) {
                revert E.OrderRejected("price outside the close band");
            }
        }
        // WP1: the agent's orders that add risk spend its turnover budget and order rate (reduce-only never does)
        if (isAgent && !reduceOnly) _spendAgentLimits($, ((limitPx > mark1e8 ? limitPx : mark1e8) * uint256(sz)) / 1e10);
        if (_pinDue($)) _pinMode($);
        HyperCore.limitOrder(asset_, isBuy, limitPx, sz, reduceOnly, tif, cloid);
        emit Ev.OrderSent(asset_, isBuy, limitPx, sz, reduceOnly, tif, cloid);
    }

    /// @dev WP1 (HL-PROXY F5, the Gains turnover budget's shape): the agent may open at most maxTurnoverBps of NAV in
    ///      notional over the rolling 24 hours (the current clock hour and the 23 before it) and send at most
    ///      maxOrdersPerHour orders that add risk in the sliding hour (this clock hour's orders plus the previous
    ///      hour's, weighted by the part of it still inside the last 60 minutes, rounded up). NAV is this order's own
    ///      read.
    function _spendAgentLimits(VaultStorage storage $, uint256 notional) internal {
        VaultPolicy.AgentLimits memory lim = $.policy.agentLimits();
        uint256 hour = block.timestamp / 1 hours;
        (uint256 used, uint256 orders) = _agentFlow($, hour);
        if (orders >= lim.maxOrdersPerHour) revert E.OrderRejected("order rate");
        used += notional;
        // HL-INV-01 (WP5): the visible NAV only, never the amount of a bridge in flight. A transfer HyperCore never
        // credits would otherwise size the budget on money that is gone until the window closes; a pending bridge
        // can only tighten the budget for its few minutes.
        uint256 nav = $.idleAssets() + VaultMath.coreEquity();
        if (used * BPS > uint256(lim.maxTurnoverBps) * nav) {
            revert E.OrderRejected("turnover");
        }
        uint256 i = hour % 24;
        uint256 shift = (i % 2) * 128;
        uint256 w = $.agentFlow[i / 2];
        uint256 b = uint128(w >> shift);
        (uint256 o, uint256 n) = uint32(b >> 96) == hour ? (uint16(b >> 80), uint80(b)) : (0, 0);
        b = (hour << 96) | ((o + 1) << 80) | SafeCast.toUint80(n + notional);
        $.agentFlow[i / 2] = (w & ~(uint256(type(uint128).max) << shift)) | (b << shift);
    }

    /// @dev Opened notional of the rolling 24 hours ending in `hour`, and the orders of the sliding hour.
    function _agentFlow(VaultStorage storage $, uint256 hour) internal view returns (uint256 used, uint256 orders) {
        uint256 prev;
        for (uint256 j; j < 12; ++j) {
            uint256 w = $.agentFlow[j];
            for (uint256 k; k < 2; ++k) {
                uint256 b = uint128(w >> (k * 128));
                uint256 h = uint32(b >> 96);
                if (h + 24 > hour && b != 0) {
                    used += uint80(b);
                    if (h == hour) orders += uint16(b >> 80);
                    else if (h + 1 == hour) prev = uint16(b >> 80);
                }
            }
        }
        orders += Math.ceilDiv(prev * (1 hours - block.timestamp % 1 hours), 1 hours);
    }

    /// @notice The agent's opened notional in the rolling 24 hours and its orders that add risk in the sliding hour.
    function agentFlow(VaultStorage storage $) external view returns (uint256 used, uint256 orders) {
        return _agentFlow($, block.timestamp / 1 hours);
    }

    /// @notice Manager, sentinel or the platform agent (HL-PROXY). A cancel never adds risk.
    function cancelOrder(VaultStorage storage $, uint32 asset_, uint64 oid, address sentinel) external {
        bool isAgent = msg.sender == $.agent && $.agent != address(0);
        if (msg.sender != $.manager && msg.sender != sentinel && !isAgent) revert E.Unauthorized();
        HyperCore.cancelByOid(asset_, oid);
    }

    /// @notice Closes a perp position with a reduce only IOC order.
    /// @param slippageBps 0 uses the policy band. A custom bound (thin markets, at most
    ///        policy.maxFlattenSlippageBps, itself capped at 3%) is the manager's, or the guardian's in emergency
    ///        (audit N2-03). The manager and the guardian flatten at any time; the owner, operator and sentinel
    ///        while breached or in emergency. Nobody else, depositors included: a stranger must not crystallise a
    ///        temporary loss at the worst moment.
    function flatten(VaultStorage storage $, uint32 asset_, uint256 slippageBps, address guardian, address sentinel) external {
        bool isManager = msg.sender == $.manager;
        bool isGuardian = msg.sender == guardian;
        if (!isManager && !_platform($, guardian, sentinel) && !(msg.sender == $.operator && $.operator != address(0))) {
            revert E.Unauthorized();
        }
        if (slippageBps != 0) {
            if (!isManager && !(isGuardian && $.emergency)) revert E.Unauthorized();
        } else if (!isManager && !isGuardian && !$.breached && !$.emergency) {
            revert E.Unauthorized();
        }
        if (asset_ >= HyperCore.SPOT_ASSET_OFFSET) revert E.UnsupportedAsset();
        HyperCore.Position memory p = HyperCore.position(address(this), asset_);
        if (p.szi == 0) return;
        (bool isBuy, uint64 px, uint64 sz) =
            $.policy.flattenOrder(HyperCore.markPx(asset_), HyperCore.perpAssetInfo(asset_).szDecimals, p.szi, slippageBps);
        HyperCore.limitOrder(asset_, isBuy, px, sz, true, HyperCore.TIF_IOC, 0);
        emit Ev.Flattened(asset_, p.szi, px, msg.sender);
    }

    // ==================================================================
    // Agent (platform api wallet)
    // ==================================================================
    /// @dev Factory vaults accept only the platform agent the factory bound to this vault (audit N-07).
    ///      HL-PROXY: the agent is an EVM caller of placeOrder / cancelOrder only. It is never approved on HyperCore
    ///      (no CoreWriter action 9 for it), so it holds none of the API wallet powers that bypass VaultPolicy
    ///      (vaultTransfer, subaccounts, spot, sendAsset, abstraction, other dexes, leverage and margin changes).
    function setAgent(VaultStorage storage $, address newAgent) external {
        _storeAgent($, newAgent);
        _pinMode($);
    }

    /// @dev Initialization only: records the agent (nothing is sent to HyperCore for it, HL-PROXY).
    function initAgent(VaultStorage storage $, address newAgent) external {
        _storeAgent($, newAgent);
    }

    /// @notice HL-PROXY: re-pins the vault's HyperCore account to the Standard mode (CoreWriter action 16,
    ///         abstraction 1). The owner, guardian, sentinel, manager or operator at any time; anyone else at most
    ///         once per MODE_PIN_INTERVAL. Nothing is sent before the Core account exists (HyperCore drops it, A-13).
    function pinAccountMode(VaultStorage storage $, address guardian, address sentinel) external {
        bool role = _platform($, guardian, sentinel) || (msg.sender == $.operator && $.operator != address(0));
        if (!role && !_pinDue($)) revert E.NotReady();
        _pinMode($);
    }

    function _pinMode(VaultStorage storage $) internal {
        if (!HyperCore.coreUserExists(address(this))) return;
        HyperCore.setAbstraction(address(this), HyperCore.ABSTRACTION_DISABLED);
        $.modePinnedAt = uint64(block.timestamp);
        emit Ev.AccountModePinned(msg.sender);
    }

    /// @dev Exposed for VaultGovernance.checkRisk (same delegatecall context): pins at most once per interval.
    function pinModeIfDue(VaultStorage storage $) external {
        if (_pinDue($)) _pinMode($);
    }

    /// @dev Never pinned, or the last pin is at least MODE_PIN_INTERVAL old.
    function _pinDue(VaultStorage storage $) internal view returns (bool) {
        return $.modePinnedAt == 0 || block.timestamp >= uint256($.modePinnedAt) + MODE_PIN_INTERVAL;
    }

    function _storeAgent(VaultStorage storage $, address newAgent) internal {
        if (newAgent == address(0)) revert E.ZeroAddress();
        if ($.factory != address(0) && IVaultFactory($.factory).platformAgentFor(newAgent) != address(this)) {
            revert E.NotPlatformAgent();
        }
        $.agent = newAgent;
        // WP1: a new agent starts with a fresh budget (the change itself waited the exit notice)
        delete $.agentFlow;
        emit Ev.AgentSet(newAgent);
    }

    /// @dev HL-PROXY: the agent is never approved on HyperCore, so the revoke is EVM-only: clearing $.agent ends its
    ///      placeOrder / cancelOrder path at once, and nothing is sent to HyperCore. WP5-D14 (HL testnet): the
    ///      earlier HLR2-A01 burn (action 9 with keccak256(vault, block.number) in the "dojipad" slot) created a
    ///      90-day API wallet entry on an account that had none; it is no longer sent. The callers are role gated
    ///      (HyperVault.revokeAgent) or full stops; a call with no agent does nothing.
    function revokeAgent(VaultStorage storage $) external {
        _revokeAgent($);
    }

    function _revokeAgent(VaultStorage storage $) internal {
        address old = $.agent;
        if (old == address(0)) return;
        $.agent = address(0);
        emit Ev.AgentRevoked(old);
    }

    // ------------------------------------------------------------------
    // Reentrancy guard. The asset is a trusted token and every other call goes to a HyperCore system contract,
    // the factory or the policy clone; the guard covers the entry points that move shares and settle.
    // ------------------------------------------------------------------
    function _enter(VaultStorage storage $) internal {
        if ($.lock == 1) revert E.Reentrancy();
        $.lock = 1;
    }

    function _exit(VaultStorage storage $) internal {
        $.lock = 0;
    }
}
