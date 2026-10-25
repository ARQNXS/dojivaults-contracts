// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HyperVault} from "./HyperVault.sol";
import {VaultPolicy} from "./VaultPolicy.sol";
import {HyperCore} from "./hypercore/HyperCore.sol";
import {UNRESOLVED_WAIT_BLOCKS} from "./VaultTypes.sol";

/// @title HyperVaultLens
/// @notice Read-only helpers for HyperVault clones: ERC-4626 max*, settlement previews that include the fees
///         settle() will mint (audit L-02), claimable / pending request views, epoch and Core status.
///         Stateless; one deployment serves every vault.
contract HyperVaultLens {
    using Math for uint256;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;
    uint8 internal constant DECIMALS_OFFSET = 6;
    uint256 internal constant ONE_SHARE = 10 ** (6 + DECIMALS_OFFSET);

    // ------------------------------------------------------------------
    // ERC-4626 surface that the vault does not carry
    // ------------------------------------------------------------------
    /// @notice The synchronous ERC-4626 paths are closed: every max* is 0. Use requestDeposit / requestRedeem.
    function maxDeposit(HyperVault, address) external pure returns (uint256) {
        return 0;
    }

    function maxMint(HyperVault, address) external pure returns (uint256) {
        return 0;
    }

    function maxWithdraw(HyperVault, address) external pure returns (uint256) {
        return 0;
    }

    function maxRedeem(HyperVault, address) external pure returns (uint256) {
        return 0;
    }

    // ------------------------------------------------------------------
    // Previews with pending fees (what settle() would use right now). In emergency a settlement refunds queued
    // deposits instead of minting, so the deposit previews are 0 (audit N-15).
    // ------------------------------------------------------------------
    /// @notice Shares settle() would mint for `assets` if it ran now: management and performance fees accrue first.
    function previewDeposit(HyperVault v, uint256 assets) public view returns (uint256) {
        if (v.emergency() || v.depositHold()) return 0; // HLR2-XA01: a held queue is carried, not minted
        (uint256 supply, uint256 nav) = _postFee(v);
        if (supply == 0) return assets * 10 ** DECIMALS_OFFSET;
        return assets.mulDiv(supply + 10 ** DECIMALS_OFFSET, nav + 1, Math.Rounding.Floor);
    }

    function previewMint(HyperVault v, uint256 shares) external view returns (uint256) {
        if (v.emergency() || v.depositHold()) return 0;
        (uint256 supply, uint256 nav) = _postFee(v);
        if (supply == 0) return shares / 10 ** DECIMALS_OFFSET;
        return shares.mulDiv(nav + 1, supply + 10 ** DECIMALS_OFFSET, Math.Rounding.Ceil);
    }

    function previewWithdraw(HyperVault v, uint256 assets) external view returns (uint256) {
        (uint256 supply, uint256 nav) = _postFeeRedeem(v);
        if (supply == 0) return assets * 10 ** DECIMALS_OFFSET;
        return assets.mulDiv(supply + 10 ** DECIMALS_OFFSET, nav + 1, Math.Rounding.Ceil);
    }

    function previewRedeem(HyperVault v, uint256 shares) public view returns (uint256) {
        (uint256 supply, uint256 nav) = _postFeeRedeem(v);
        if (supply == 0) return shares / 10 ** DECIMALS_OFFSET;
        return shares.mulDiv(nav + 1, supply + 10 ** DECIMALS_OFFSET, Math.Rounding.Floor);
    }

    /// @notice Share price after pending fees (assets per whole share).
    function sharePriceAfterFees(HyperVault v) external view returns (uint256) {
        return previewRedeem(v, ONE_SHARE);
    }

    /// @notice Fee shares settle() would mint now: (total, protocol part).
    function pendingFeeShares(HyperVault v) public view returns (uint256 feeShares, uint256 protocolShares) {
        uint256 supply = v.totalSupply();
        uint256 assets = v.totalAssets();
        if (supply == 0 || assets == 0) return (0, 0);
        uint256 elapsed = block.timestamp - v.lastFeeAccrual();
        uint256 feeAssets = assets.mulDiv(uint256(v.managementFeeBps()) * elapsed, BPS * YEAR);
        uint256 price = v.sharePrice();
        uint256 hwm = v.highWaterMark();
        // Like settle(): no performance fee in any breach or emergency settlement (round 4), management fee only.
        if (price > hwm && v.performanceFeeBps() > 0 && !v.breached() && !v.emergency()) {
            uint256 gain = (price - hwm).mulDiv(supply, ONE_SHARE);
            feeAssets += gain.mulDiv(v.performanceFeeBps(), BPS);
        }
        if (feeAssets == 0 || feeAssets >= assets) return (0, 0);
        feeShares = feeAssets.mulDiv(supply + 10 ** DECIMALS_OFFSET, assets - feeAssets);
        if (v.factory() != address(0)) protocolShares = feeShares.mulDiv(v.protocolShareBps(), BPS);
    }

    function _postFee(HyperVault v) internal view returns (uint256 supply, uint256 nav) {
        (uint256 feeShares,) = pendingFeeShares(v);
        return (v.totalSupply() + feeShares, v.totalAssets());
    }

    /// @dev Like settle(): a daily loss / drawdown breach pays redemptions at min(NAV, checkpoint).
    function _postFeeRedeem(HyperVault v) internal view returns (uint256 supply, uint256 nav) {
        (supply, nav) = _postFee(v);
        uint8 r = uint8(v.breachReason());
        // HLR2-E06: a full stop the owner imposed alone (no platform hold) settles redemption-only too.
        // HLR2-XA01: a deposit hold settles redemption-only too.
        if (!v.emergency() && ((v.breached() && (r == 2 || r == 3 || (r == 4 && !v.platformHold()))) || v.depositHold())) {
            uint256 cp = v.checkpointNav();
            if (cp > 0 && cp < nav) nav = cp;
        }
    }

    // ------------------------------------------------------------------
    // Requests
    // ------------------------------------------------------------------
    /// @notice What a settled request delivers on claim: shares (minted for deposits, or returned from a partly
    ///         filled redemption) and USDC (the redemption payout, or a refund). Same rule as VaultMath.claimable.
    function claimable(HyperVault v, address controller) public view returns (uint256 shares, uint256 assets) {
        (shares, assets,) = _claimable(v, controller);
    }

    /// @notice Pending (unsettled) amounts for a controller: the current epoch's request.
    function pendingRequest(HyperVault v, address controller) external view returns (uint256 depositAssets, uint256 redeemShares) {
        (uint256 epoch, uint256 dep, uint256 red) = v.requests(controller);
        if (epoch == v.currentEpoch()) return (dep, red);
        return (0, 0);
    }

    /// @notice A settled redemption that was only partly filled: the shares that came back (claimable, or already
    ///         claimed when `claimed` is true) and the USDC paid for the rest. Zero when the request was paid in full.
    function partialFill(HyperVault v, address controller) external view returns (uint256 sharesReturned, uint256 assetsPaid, uint256 epoch) {
        (uint256 ep,, uint256 red) = v.requests(controller);
        if (ep >= v.currentEpoch()) return (0, 0, 0);
        (uint256 returned, uint256 paid) = _redemption(v, ep, red);
        return (returned, paid, ep);
    }

    /// @notice Expected fill of the pending redemptions if an exit-only settle ran now: 10_000 = paid in full.
    function emergencyFillBps(HyperVault v) public view returns (uint256) {
        return v.emergencyFillBps();
    }

    /// @notice What an emergency redemption of `shares` would deliver if settled now: the USDC paid and the shares
    ///         returned, at the current fill ratio.
    function previewEmergencyRedeem(HyperVault v, uint256 shares) external view returns (uint256 assetsPaid, uint256 sharesReturned) {
        uint256 fill = v.emergencyFillBps();
        uint256 nav = v.totalAssets();
        uint192 cp = v.checkpointNav();
        if (cp > 0 && cp < nav) nav = cp;
        uint256 supply = v.totalSupply();
        uint256 owed = supply == 0 ? shares / 10 ** DECIMALS_OFFSET : shares.mulDiv(nav + 1, supply + 10 ** DECIMALS_OFFSET, Math.Rounding.Floor);
        assetsPaid = owed.mulDiv(fill, BPS, Math.Rounding.Floor);
        uint256 burned = shares.mulDiv(fill, BPS, Math.Rounding.Ceil);
        sharesReturned = burned < shares ? shares - burned : 0;
    }

    function _claimable(HyperVault v, address controller) internal view returns (uint256 shares, uint256 assets, uint256 epoch) {
        uint256 depositAssets;
        uint256 redeemShares;
        (epoch, depositAssets, redeemShares) = v.requests(controller);
        if (epoch >= v.currentEpoch()) return (0, 0, epoch);
        if (depositAssets > 0) {
            uint256 pe = epoch;
            (uint256 carriedFrom, uint256 pricedIn) = v.carry(epoch);
            bool carried = carriedFrom != 0 && pricedIn == 0; // still queued: nothing to deliver yet
            if (carriedFrom != 0 && pricedIn != 0) pe = pricedIn - 1;
            (uint256 eDepAssets, uint256 eDepShares,,,,,,) = v.epochs(pe);
            if (!carried && eDepAssets > 0) {
                if (eDepShares == 0) assets = depositAssets;
                else shares = depositAssets.mulDiv(eDepShares, eDepAssets, Math.Rounding.Floor);
            }
        }
        if (redeemShares > 0) {
            (uint256 returned, uint256 paid) = _redemption(v, epoch, redeemShares);
            assets += paid;
            shares += returned;
        }
    }

    /// @dev One request's share of its epoch's redemption result, rounded the way the vault rounds.
    function _redemption(HyperVault v, uint256 epoch, uint256 s) internal view returns (uint256 returned, uint256 paid) {
        (,, uint256 eShares, uint256 eAssets, uint256 eBurned,,,) = v.epochs(epoch);
        if (s == 0 || eShares == 0) return (0, 0);
        paid = s.mulDiv(eAssets, eShares, Math.Rounding.Floor);
        uint256 burnedForMe = s.mulDiv(eBurned, eShares, Math.Rounding.Ceil);
        returned = burnedForMe < s ? s - burnedForMe : 0;
    }

    // ------------------------------------------------------------------
    // Status
    // ------------------------------------------------------------------
    function epochOverdue(HyperVault v) external view returns (bool) {
        return block.timestamp >= uint256(v.epochDeadline());
    }

    function coreActive(HyperVault v) external view returns (bool) {
        return HyperCore.coreUserExists(address(v));
    }

    /// @notice Everything the frontend shows in one call.
    struct Status {
        uint256 totalAssets;
        uint256 sharePrice;
        uint256 sharePriceAfterFees;
        uint256 pendingFeeShares;
        bool coreActive;
        bool epochOverdue;
        bool bridgeInFlight;
        uint256 checkpointNav;
        uint64 checkpointAt;
        address guardian;
        address sentinel;
        uint256 emergencyFillBps;
        VaultPolicy.RiskConfig risk;
        // round 4
        uint8 breachReason; // 0 none, 1 leverage, 2 daily loss, 3 drawdown, 4 guardian, 5 emergency
        address operator;
        uint256 dayStartSharePrice;
        uint256 deferredDepositAssets;
        uint64 lastResumeAt;
    }

    function status(HyperVault v) external view returns (Status memory s) {
        (uint256 feeShares,) = pendingFeeShares(v);
        s.totalAssets = v.totalAssets();
        s.sharePrice = v.sharePrice();
        s.sharePriceAfterFees = previewRedeem(v, ONE_SHARE);
        s.pendingFeeShares = feeShares;
        s.coreActive = HyperCore.coreUserExists(address(v));
        s.epochOverdue = block.timestamp >= uint256(v.epochDeadline());
        s.bridgeInFlight = v.bridgeInFlight();
        s.checkpointNav = v.checkpointNav();
        s.checkpointAt = v.checkpointAt();
        s.guardian = v.guardian();
        s.sentinel = v.sentinel();
        s.emergencyFillBps = v.emergencyFillBps();
        s.risk = v.policy().config();
        s.breachReason = uint8(v.breachReason());
        s.operator = v.operator();
        s.dayStartSharePrice = v.dayStartSharePrice();
        s.deferredDepositAssets = v.deferredDepositAssets();
        s.lastResumeAt = v.lastResumeAt();
    }

    /// @notice What holds the vault back right now (round 2): the frontend reads it before offering a settle, a bridge
    ///         or a deposit, so nobody is handed a transaction that reverts on a hold. Vaults from older factories
    ///         lack these views, so the call reverts there.
    struct Holds {
        uint64 epochDeadline; // this epoch's deadline, fixed when it started (exit before effect)
        uint256 noticeEta; // earliest eta a change that adds risk queued now gets (policy notice)
        bool depositHold; // after a platform revoke: deposits closed, settles redemption-only until the guardian clears
        bool platformHold; // the full stop is the guardian's or the sentinel's: nothing settles until the guardian acts
        bool bridgeUnresolved; // a transfer is late and the NAV reads short by it: settles and bridges revert
        uint256 bridgeHoldEndsBlock; // the bridge hold ends by itself after this block (0 = no hold)
        uint64 agentActiveAt; // the platform agent's warm-up ends (deposits open); 0 = no warm-up
        bool checkpointLagging; // an exit-only settle waits for the next checkpoint step (checkRisk, hourly)
    }

    function holds(HyperVault v) external view returns (Holds memory h) {
        h.epochDeadline = v.epochDeadline();
        h.noticeEta = v.policy().noticeEta();
        h.depositHold = v.depositHold();
        h.platformHold = v.platformHold();
        h.bridgeUnresolved = v.bridgeUnresolved();
        if (h.bridgeUnresolved) h.bridgeHoldEndsBlock = v.lastBridgeBlock() + UNRESOLVED_WAIT_BLOCKS;
        h.agentActiveAt = v.agentActiveAt();
        h.checkpointLagging = v.checkpointLagging();
    }
}
