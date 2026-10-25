// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GainsVault} from "./GainsVault.sol";
import {GainsVaultPolicy} from "./GainsVaultPolicy.sol";
import {GainsNav} from "./GainsNav.sol";
import {IGainsDiamond, GTrade} from "./IGainsDiamond.sol";
import {BreachReason} from "../VaultTypes.sol";

/// @title GainsVaultLens
/// @notice Read-only helpers for GainsVault clones: ERC-4626 max*, settlement previews that include the fees
///         settle() will mint (audit L-02), claimable / pending request views, epoch and order status.
///         Stateless; one deployment serves every vault. Round 4 HyperVaultLens with coreActive replaced by the
///         pending / timed-out order views the keeper uses (PLAN.md 4.3 step 3).
contract GainsVaultLens {
    using Math for uint256;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;
    uint8 internal constant DECIMALS_OFFSET = 6;
    uint256 internal constant ONE_SHARE = 10 ** (6 + DECIMALS_OFFSET);

    // ------------------------------------------------------------------
    // ERC-4626 surface that the vault does not carry
    // ------------------------------------------------------------------
    /// @notice The synchronous ERC-4626 paths are closed: every max* is 0. Use requestDeposit / requestRedeem.
    function maxDeposit(GainsVault, address) external pure returns (uint256) {
        return 0;
    }

    function maxMint(GainsVault, address) external pure returns (uint256) {
        return 0;
    }

    function maxWithdraw(GainsVault, address) external pure returns (uint256) {
        return 0;
    }

    function maxRedeem(GainsVault, address) external pure returns (uint256) {
        return 0;
    }

    // ------------------------------------------------------------------
    // Previews with pending fees (what settle() would use right now). In emergency a settlement refunds queued
    // deposits instead of minting, so the deposit previews are 0 (audit N-15).
    // ------------------------------------------------------------------
    /// @notice Shares settle() would mint for `assets` if it ran now: management and performance fees accrue first.
    function previewDeposit(GainsVault v, uint256 assets) public view returns (uint256) {
        if (v.emergency()) return 0;
        (uint256 supply, uint256 nav) = _postFee(v);
        if (supply == 0) return assets * 10 ** DECIMALS_OFFSET;
        return assets.mulDiv(supply + 10 ** DECIMALS_OFFSET, nav + 1, Math.Rounding.Floor);
    }

    function previewMint(GainsVault v, uint256 shares) external view returns (uint256) {
        if (v.emergency()) return 0;
        (uint256 supply, uint256 nav) = _postFee(v);
        if (supply == 0) return shares / 10 ** DECIMALS_OFFSET;
        return shares.mulDiv(nav + 1, supply + 10 ** DECIMALS_OFFSET, Math.Rounding.Ceil);
    }

    function previewWithdraw(GainsVault v, uint256 assets) external view returns (uint256) {
        (uint256 supply, uint256 nav) = _postFeeRedeem(v);
        if (supply == 0) return assets * 10 ** DECIMALS_OFFSET;
        return assets.mulDiv(supply + 10 ** DECIMALS_OFFSET, nav + 1, Math.Rounding.Ceil);
    }

    function previewRedeem(GainsVault v, uint256 shares) public view returns (uint256) {
        (uint256 supply, uint256 nav) = _postFeeRedeem(v);
        if (supply == 0) return shares / 10 ** DECIMALS_OFFSET;
        return shares.mulDiv(nav + 1, supply + 10 ** DECIMALS_OFFSET, Math.Rounding.Floor);
    }

    /// @notice Share price after pending fees (assets per whole share).
    function sharePriceAfterFees(GainsVault v) external view returns (uint256) {
        return previewRedeem(v, ONE_SHARE);
    }

    /// @notice Fee shares settle() would mint now: (total, protocol part).
    function pendingFeeShares(GainsVault v) public view returns (uint256 feeShares, uint256 protocolShares) {
        uint256 supply = v.totalSupply();
        uint256 assets = v.totalAssets();
        if (supply == 0 || assets == 0) return (0, 0);
        uint256 elapsed = block.timestamp - v.lastFeeAccrual();
        uint256 feeAssets = assets.mulDiv(uint256(v.managementFeeBps()) * elapsed, BPS * YEAR);
        uint256 price = v.sharePrice();
        uint256 hwm = v.highWaterMark();
        // Like settle(): no performance fee in a daily loss / drawdown breach or in emergency (management fee only); a
        // normal or leverage-breach settle charges it (GR2-ECON-03). Once the epoch is overdue the preview is the
        // exit-only settle a redeemer can force, which charges no performance fee either (GR2 XF-01); the manager's or
        // operator's own settle would still charge it.
        uint8 r = uint8(v.breachReason());
        bool lossBreach = v.breached() && (r == uint8(BreachReason.DAILY_LOSS) || r == uint8(BreachReason.DRAWDOWN));
        bool overdue = block.timestamp >= uint256(v.epochDeadline());
        if (price > hwm && v.performanceFeeBps() > 0 && !v.emergency() && !lossBreach && !overdue) {
            uint256 gain = (price - hwm).mulDiv(supply, ONE_SHARE);
            feeAssets += gain.mulDiv(v.performanceFeeBps(), BPS);
        }
        if (feeAssets == 0 || feeAssets >= assets) return (0, 0);
        feeShares = feeAssets.mulDiv(supply + 10 ** DECIMALS_OFFSET, assets - feeAssets);
        if (v.factory() != address(0)) protocolShares = feeShares.mulDiv(v.protocolShareBps(), BPS);
    }

    function _postFee(GainsVault v) internal view returns (uint256 supply, uint256 nav) {
        (uint256 feeShares,) = pendingFeeShares(v);
        return (v.totalSupply() + feeShares, v.totalAssets());
    }

    /// @dev Like settle(): a daily loss / drawdown breach pays redemptions at the redemption NAV (min(NAV, cap),
    ///      GR2-KEY-06).
    function _postFeeRedeem(GainsVault v) internal view returns (uint256 supply, uint256 nav) {
        (supply, nav) = _postFee(v);
        uint8 r = uint8(v.breachReason());
        if (v.breached() && !v.emergency() && (r == 2 || r == 3)) {
            uint256 rn = v.redemptionNav();
            if (rn < nav) nav = rn;
        }
    }

    // ------------------------------------------------------------------
    // Requests
    // ------------------------------------------------------------------
    /// @notice What a settled request delivers on claim: shares (minted for deposits, or returned from a partly
    ///         filled redemption) and USDC (the redemption payout, or a refund). Same rule as VaultMath.claimable.
    function claimable(GainsVault v, address controller) public view returns (uint256 shares, uint256 assets) {
        (shares, assets,) = _claimable(v, controller);
    }

    /// @notice Pending (unsettled) amounts for a controller: the current epoch's request.
    function pendingRequest(GainsVault v, address controller) external view returns (uint256 depositAssets, uint256 redeemShares) {
        (uint256 epoch, uint256 dep, uint256 red) = v.requests(controller);
        if (epoch == v.currentEpoch()) return (dep, red);
        return (0, 0);
    }

    /// @notice A settled redemption that was only partly filled: the shares that came back (claimable, or already
    ///         claimed when `claimed` is true) and the USDC paid for the rest. Zero when the request was paid in full.
    function partialFill(GainsVault v, address controller) external view returns (uint256 sharesReturned, uint256 assetsPaid, uint256 epoch) {
        (uint256 ep,, uint256 red) = v.requests(controller);
        if (ep >= v.currentEpoch()) return (0, 0, 0);
        (uint256 returned, uint256 paid) = _redemption(v, ep, red);
        return (returned, paid, ep);
    }

    /// @notice Expected fill of the pending redemptions if an exit-only settle ran now: 10_000 = paid in full.
    function emergencyFillBps(GainsVault v) public view returns (uint256) {
        return v.emergencyFillBps();
    }

    /// @notice What an emergency redemption of `shares` would deliver if settled now: the USDC paid and the shares
    ///         returned, at the current fill ratio.
    function previewEmergencyRedeem(GainsVault v, uint256 shares) external view returns (uint256 assetsPaid, uint256 sharesReturned) {
        uint256 fill = v.emergencyFillBps();
        uint256 nav = v.redemptionNav();
        uint256 supply = v.totalSupply();
        uint256 owed = supply == 0 ? shares / 10 ** DECIMALS_OFFSET : shares.mulDiv(nav + 1, supply + 10 ** DECIMALS_OFFSET, Math.Rounding.Floor);
        assetsPaid = owed.mulDiv(fill, BPS, Math.Rounding.Floor);
        uint256 burned = shares.mulDiv(fill, BPS, Math.Rounding.Ceil);
        sharesReturned = burned < shares ? shares - burned : 0;
    }

    function _claimable(GainsVault v, address controller) internal view returns (uint256 shares, uint256 assets, uint256 epoch) {
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
    function _redemption(GainsVault v, uint256 epoch, uint256 s) internal view returns (uint256 returned, uint256 paid) {
        (,, uint256 eShares, uint256 eAssets, uint256 eBurned,,,) = v.epochs(epoch);
        if (s == 0 || eShares == 0) return (0, 0);
        paid = s.mulDiv(eAssets, eShares, Math.Rounding.Floor);
        uint256 burnedForMe = s.mulDiv(eBurned, eShares, Math.Rounding.Ceil);
        returned = burnedForMe < s ? s - burnedForMe : 0;
    }

    // ------------------------------------------------------------------
    // Status
    // ------------------------------------------------------------------
    function epochOverdue(GainsVault v) external view returns (bool) {
        return block.timestamp >= uint256(v.epochDeadline());
    }

    /// @notice An order that holds collateral is pending on the diamond: settle waits until it fills or is cancelled.
    ///         Closes, partial closes and leverage increases do not hold settle (GR1-04).
    function ordersPending(GainsVault v) external view returns (bool) {
        return v.ordersPending();
    }

    /// @notice Pending market orders past Gains' timeout (L2 blocks), which the keeper cancels with
    ///         cancelTimedOut(orderIndex) within cancelWithinBlocks (PLAN.md 4.3 step 3). Until then Gains may still
    ///         fill them.
    function timedOutOrders(GainsVault v) external view returns (uint32[] memory out) {
        IGainsDiamond d = v.diamond();
        (, IGainsDiamond.PendingOrder[] memory orders) = v.openItems(); // the vault's index set (GR2-LIVE-01)
        uint256 timeout = d.getMarketOrdersTimeoutBlocks();
        uint256 nowBlock = GTrade.l2BlockNumber();
        uint256 n;
        out = new uint32[](orders.length);
        for (uint256 i; i < orders.length; ++i) {
            if (orders[i].isOpen && uint256(orders[i].createdBlock) + timeout <= nowBlock) out[n++] = orders[i].index;
        }
        assembly {
            mstore(out, n)
        }
    }

    /// @notice The vault's gas-safety ceiling on open trades + resting orders + pending orders (MAX_POSITIONS). At the
    ///         ceiling openTrade, increaseTrade and new limit / stop orders revert TooManyPositions; exits never do.
    function maxPositions(GainsVault v) external view returns (uint256) {
        return v.MAX_POSITIONS();
    }

    /// @notice What counts against maxPositions: open trades + resting limit / stop orders + pending orders on the
    ///         diamond. Plain diamond reads, no price: works while a feed is stale (the executor's copy-mode pre-check).
    function openPositions(GainsVault v) external view returns (uint256) {
        (IGainsDiamond.Trade[] memory trades, IGainsDiamond.PendingOrder[] memory orders) = v.openItems(); // GR2-LIVE-01
        return trades.length + orders.length;
    }

    /// @notice Everything the frontend shows in one call.
    struct Status {
        uint256 totalAssets;
        uint256 sharePrice;
        uint256 sharePriceAfterFees;
        uint256 pendingFeeShares;
        bool ordersPending;
        bool epochOverdue;
        uint256 openPositions; // open trades + resting orders + pending orders on the diamond
        uint256 maxPositions; // the gas-safety ceiling on openPositions
        uint256 checkpointNav;
        uint64 checkpointAt;
        address guardian;
        address sentinel;
        uint256 emergencyFillBps;
        GainsVaultPolicy.RiskConfig risk;
        // round 4
        uint8 breachReason; // 0 none, 1 leverage, 2 daily loss, 3 drawdown, 4 guardian, 5 emergency
        address operator;
        uint256 dayStartSharePrice;
        uint256 deferredDepositAssets;
        uint64 lastResumeAt;
        // Gains
        uint256 venueValue; // GainsNav value of trades and orders
        uint256 openNotional; // for vault leverage
    }

    function status(GainsVault v) external view returns (Status memory s) {
        (uint256 feeShares,) = pendingFeeShares(v);
        s.totalAssets = v.totalAssets();
        s.sharePrice = v.sharePrice();
        s.sharePriceAfterFees = previewRedeem(v, ONE_SHARE);
        s.pendingFeeShares = feeShares;
        GainsNav.Snapshot memory venue = v.venue();
        s.ordersPending = venue.pending > 0;
        s.epochOverdue = block.timestamp >= uint256(v.epochDeadline());
        s.openPositions = venue.orders;
        s.maxPositions = v.MAX_POSITIONS();
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
        s.venueValue = venue.value;
        s.openNotional = venue.notional;
    }
}
