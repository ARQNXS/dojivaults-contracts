// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BPS, BreachReason, DECIMALS_OFFSET, EpochResult, ONE_SHARE, Request} from "../VaultTypes.sol";
import {IGainsDiamond, GTrade} from "./IGainsDiamond.sol";
import {VaultStorage} from "./GainsTypes.sol";
import {GainsNav} from "./GainsNav.sol";

/// @dev Internal helpers shared by the vault and its logic libraries: NAV views, share conversions, claim
///      accounting and direct access to the OpenZeppelin ERC-20 / Ownable storage (so the delegatecalled
///      libraries can mint, burn and move shares on the vault's own balances). Round 4 VaultMath with the HyperCore
///      equity and bridge window replaced by GainsNav.
library GainsVaultMath {
    using Math for uint256;

    // ------------------------------------------------------------------
    // OpenZeppelin namespaced storage (v5.4.0 upgradeable mixins)
    // ------------------------------------------------------------------
    struct ERC20Storage {
        mapping(address account => uint256) _balances;
        mapping(address account => mapping(address spender => uint256)) _allowances;
        uint256 _totalSupply;
        string _name;
        string _symbol;
    }

    struct OwnableStorage {
        address _owner;
    }

    bytes32 internal constant ERC20_SLOT = 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00;
    bytes32 internal constant OWNABLE_SLOT = 0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300;

    function erc20() internal pure returns (ERC20Storage storage e) {
        assembly {
            e.slot := ERC20_SLOT
        }
    }

    function owner() internal view returns (address o) {
        OwnableStorage storage s;
        assembly {
            s.slot := OWNABLE_SLOT
        }
        return s._owner;
    }

    function totalSupply() internal view returns (uint256) {
        return erc20()._totalSupply;
    }

    function balanceOf(address a) internal view returns (uint256) {
        return erc20()._balances[a];
    }

    function mint(address to, uint256 amount) internal {
        ERC20Storage storage e = erc20();
        e._totalSupply += amount;
        e._balances[to] += amount;
        emit IERC20.Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) internal {
        ERC20Storage storage e = erc20();
        uint256 bal = e._balances[from];
        if (bal < amount) revert IERC20Errors.ERC20InsufficientBalance(from, bal, amount);
        unchecked {
            e._balances[from] = bal - amount;
            e._totalSupply -= amount;
        }
        emit IERC20.Transfer(from, address(0), amount);
    }

    function transfer(address from, address to, uint256 amount) internal {
        ERC20Storage storage e = erc20();
        uint256 bal = e._balances[from];
        if (bal < amount) revert IERC20Errors.ERC20InsufficientBalance(from, bal, amount);
        unchecked {
            e._balances[from] = bal - amount;
        }
        e._balances[to] += amount;
        emit IERC20.Transfer(from, to, amount);
    }

    function spendAllowance(address holder, address spender, uint256 amount) internal {
        ERC20Storage storage e = erc20();
        uint256 current = e._allowances[holder][spender];
        if (current == type(uint256).max) return;
        if (current < amount) revert IERC20Errors.ERC20InsufficientAllowance(spender, current, amount);
        unchecked {
            e._allowances[holder][spender] = current - amount;
        }
    }

    // ------------------------------------------------------------------
    // NAV
    // ------------------------------------------------------------------
    /// @dev USDC held by the vault that belongs to share holders (not reserved for deposits or claims).
    function idleAssets(VaultStorage storage $) internal view returns (uint256) {
        uint256 bal = $.asset.balanceOf(address(this));
        uint256 reserved = $.pendingDepositAssets + $.deferredDepositAssets + $.claimableRedeemAssets;
        return bal > reserved ? bal - reserved : 0;
    }

    /// @dev Full stop: emergency, or a breach by the guardian / sentinel / owner. The risk breaches (leverage, daily
    ///      loss, drawdown) are reduce only modes in which the vault keeps running.
    function hardStop(VaultStorage storage $) internal view returns (bool) {
        return $.emergency || ($.breached && $.breachReason >= BreachReason.GUARDIAN);
    }

    /// @dev Share price from a NAV, the formula checkRisk and settle use (0 without shares).
    function priceAt(uint256 nav, uint256 supply) internal pure returns (uint256) {
        if (supply == 0) return 0;
        return (nav + 1).mulDiv(ONE_SHARE, supply + 10 ** DECIMALS_OFFSET);
    }

    /// @dev Value of everything on the diamond (trades, resting and pending orders), its open notional and order
    ///      counts (GainsNav, PLAN.md 4.3). Reverts PriceStale / SequencerDown when a feed cannot be trusted.
    function venue(VaultStorage storage $) internal view returns (GainsNav.Snapshot memory) {
        return GainsNav.snapshot($.diamond, $.policy, $.collateralIndex, false, GainsNav.NO_PAIR);
    }

    /// @dev As venue, `high` also values the trades at the favourable band edge (valueHigh, GR1-02).
    function venue(VaultStorage storage $, bool high) internal view returns (GainsNav.Snapshot memory) {
        return GainsNav.snapshot($.diamond, $.policy, $.collateralIndex, high, GainsNav.NO_PAIR);
    }

    /// @dev As venue, plus the vault's notional on `pair` (pairNotional, GR2-KEY-01).
    function venueFor(VaultStorage storage $, uint16 pair) internal view returns (GainsNav.Snapshot memory) {
        return GainsNav.snapshot($.diamond, $.policy, $.collateralIndex, false, pair);
    }

    /// @dev NAV = idle USDC + GainsNav value. No bridge window: collateral in flight is a pending order on the
    ///      diamond, valued there, and settle() refuses while one exists.
    function totalAssets(VaultStorage storage $) internal view returns (uint256) {
        return idleAssets($) + venue($).value;
    }

    /// @dev A pending order that holds collateral (timed out or not): the ones settle waits for (GR1-04). A plain
    ///      read: no price, safe on exit paths.
    function ordersPending(VaultStorage storage $) internal view returns (bool) {
        return GainsNav.blockingOrders($.diamond, address(this)) > 0;
    }

    /// @dev USDC the redemptions need beyond what the vault holds for them: the pending redemptions at the NAV
    ///      checkpoint plus the claimable reserve, against the USDC balance net of queued deposits plus the collateral
    ///      of closes already in flight. Bounds the operator's reduceTrade outside a breach (PLAN.md 5.3).
    /// @dev No price read: reduceTrade is an exit (PLAN.md section 1), so the pending redemptions are priced at the
    ///      checkpoint NAV (checkRisk / settle), which a normal settle may not move by more than maxNavMoveBps. A
    ///      close in flight counts at its collateral (PnL unknown until Gains fills it).
    function redemptionShortfall(VaultStorage storage $) internal view returns (uint256) {
        uint256 owed = $.claimableRedeemAssets;
        uint256 pending = $.pendingRedeemShares;
        if (pending > 0) owed += toAssets(pending, $.checkpointNav, totalSupply(), Math.Rounding.Floor);
        uint256 bal = $.asset.balanceOf(address(this));
        uint256 deposits = $.pendingDepositAssets + $.deferredDepositAssets;
        uint256 available = bal > deposits ? bal - deposits : 0;
        IGainsDiamond d = $.diamond;
        IGainsDiamond.PendingOrder[] memory orders = GainsNav.readPendingOrders(d, address(this));
        for (uint256 i; i < orders.length; ++i) {
            IGainsDiamond.PendingOrder memory o = orders[i];
            if (!o.isOpen) continue;
            if (o.orderType == GTrade.MARKET_CLOSE) available += d.getTrade(address(this), o.trade.index).collateralAmount;
            else if (o.orderType == GTrade.MARKET_PARTIAL_CLOSE && o.trade.leverage == 0) available += o.trade.collateralAmount;
        }
        return owed > available ? owed - available : 0;
    }

    /// @dev OpenZeppelin ERC-4626 formula with a virtual offset. While no shares exist the first mint rule
    ///      applies (1 USDC = 10 ** DECIMALS_OFFSET share units), exactly what settle() mints.
    function toShares(uint256 assets, uint256 nav, uint256 supply, Math.Rounding rounding) internal pure returns (uint256) {
        if (supply == 0) return assets * 10 ** DECIMALS_OFFSET;
        return assets.mulDiv(supply + 10 ** DECIMALS_OFFSET, nav + 1, rounding);
    }

    function toAssets(uint256 shares, uint256 nav, uint256 supply, Math.Rounding rounding) internal pure returns (uint256) {
        if (supply == 0) return shares / 10 ** DECIMALS_OFFSET;
        return shares.mulDiv(nav + 1, supply + 10 ** DECIMALS_OFFSET, rounding);
    }

    function sharePrice(VaultStorage storage $) internal view returns (uint256) {
        return toAssets(ONE_SHARE, totalAssets($), totalSupply(), Math.Rounding.Floor);
    }

    /// @dev The deadline is the one stored when the epoch started (GR2-CFG-02): a policy change to maxEpochDuration
    ///      never moves a running epoch's deadline, and an overdue epoch stays overdue.
    function epochOverdue(VaultStorage storage $) internal view returns (bool) {
        return block.timestamp >= uint256($.epochDeadline);
    }

    /// @dev Starts an epoch now: its deadline uses the maxEpochDuration in force at its start.
    function startEpoch(VaultStorage storage $) internal {
        $.epochStartedAt = uint64(block.timestamp);
        $.epochDeadline = uint64(block.timestamp + $.policy.maxEpochDuration());
    }

    /// @dev GR2-KEY-06. The NAV a redemption-only or exit-only settle pays at: min(nav, cap). The cap protects the holders
    ///      who stay from a NAV pushed up inside the per-settle bound (audit C-01, REAUDIT3 question a). It is
    ///      - while the checkpoint is fresh (checkRisk may not move it yet): for an exit-only settle (emergency or
    ///        overdue, the moment a key holder can choose) the higher of the checkpoint and the value its last ratchet
    ///        replaced, so a checkpoint taken at a dip (by anyone, at a moment of their choice) cannot price redemptions
    ///        at the dip after the market came back, and a NAV above both is still never paid; for a redemption-only
    ///        settle (a loss breach outside emergency) the checkpoint itself, so the hour after a downward ratchet does
    ///        not pay a NAV pushed back up toward the pre-loss level (GR2 XF-02);
    ///      - once it is stale: what checkRisk would ratchet it to at this NAV (at most maxNavMoveBps toward it), i.e.
    ///        exactly what any caller could set with a checkRisk right before the settle.
    function redemptionCap(VaultStorage storage $, uint256 nav) internal view returns (uint256) {
        uint256 cp = $.checkpointNav;
        if (cp == 0) return nav;
        (uint256 next, bool moves) = $.policy.nextCheckpoint(cp, $.checkpointAt, nav, false);
        uint256 cap = next;
        if (!moves) {
            cap = cp;
            bool lossBreach = !$.emergency && $.breached
                && ($.breachReason == BreachReason.DAILY_LOSS || $.breachReason == BreachReason.DRAWDOWN);
            uint256 prior = $.priorCheckpointNav;
            if (!lossBreach && prior > cp) cap = prior;
        }
        return cap < nav ? cap : nav;
    }

    // ------------------------------------------------------------------
    // Claims
    // ------------------------------------------------------------------
    /// @dev What a settled request is worth. A request belongs to exactly one epoch (audit V-01). Deposits are
    ///      priced in their epoch (refunded in USDC when it minted no shares for them). Redemptions are paid pro
    ///      rata to what the epoch could pay: `assets` is the redeemer's part of the epoch's payout and the shares
    ///      that were not burned for it come back as `shares` (partial fill + return). Rounding favours the vault:
    ///      the sum over users never exceeds what the vault paid or still holds.
    function claimable(VaultStorage storage $, address controller) internal view returns (uint256 shares, uint256 assets) {
        (shares, assets,) = claimableWithCarry($, controller);
    }

    /// @dev `carried` = the request's deposit sits in a carry run that has not been priced yet (a redemption-only
    ///      epoch passed over it): it stays queued, nothing is delivered for it. Otherwise the deposit is priced in
    ///      its own epoch, or in the epoch that priced its carry run (one lookup, claims stay O(1), audit N2-01).
    function claimableWithCarry(VaultStorage storage $, address controller)
        internal
        view
        returns (uint256 shares, uint256 assets, bool carried)
    {
        Request storage r = $.requests[controller];
        if (r.epoch >= $.currentEpoch) return (0, 0, false);
        EpochResult storage e = $.epochs[r.epoch];
        if (r.depositAssets > 0) {
            EpochResult storage pe = e;
            if (e.carriedFrom != 0) {
                uint256 p = $.carryPricedIn[e.carriedFrom - 1];
                if (p == 0) carried = true;
                else pe = $.epochs[p - 1];
            }
            if (!carried && pe.depositAssets > 0) {
                if (pe.depositShares == 0) assets = r.depositAssets;
                else shares = r.depositAssets.mulDiv(pe.depositShares, pe.depositAssets, Math.Rounding.Floor);
            }
        }
        uint256 s = r.redeemShares;
        if (s > 0 && e.redeemShares > 0) {
            assets += s.mulDiv(e.redeemAssets, e.redeemShares, Math.Rounding.Floor);
            uint256 burnedForMe = s.mulDiv(e.redeemBurned, e.redeemShares, Math.Rounding.Ceil);
            if (burnedForMe < s) shares += s - burnedForMe;
        }
    }

    /// @dev Expected fill of the pending redemptions if an exit-only settle ran now: the USDC on hand against the
    ///      redemptions priced at redemptionCap (GR2-KEY-06). 10_000 = paid in full.
    function emergencyFillBps(VaultStorage storage $) internal view returns (uint256) {
        uint256 pending = $.pendingRedeemShares;
        if (pending == 0) return BPS;
        uint256 nav = redemptionCap($, totalAssets($));
        uint256 owed = toAssets(pending, nav, totalSupply(), Math.Rounding.Floor);
        uint256 available = idleAssets($);
        if (owed == 0 || available >= owed) return BPS;
        return available.mulDiv(BPS, owed, Math.Rounding.Floor);
    }
}
