// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HyperCore} from "./hypercore/HyperCore.sol";
import {
    BPS,
    BRIDGE_SETTLE_BLOCKS,
    BreachReason,
    DECIMALS_OFFSET,
    EpochResult,
    IHyperVaultErrors,
    BRIDGE_LANDING_TOLERANCE,
    MAX_BRIDGE_WAIT_BLOCKS,
    MAX_UNLANDED_BLOCKS,
    UNRESOLVED_WAIT_BLOCKS,
    ONE_SHARE,
    Request,
    VaultStorage
} from "./VaultTypes.sol";

/// @dev Internal helpers shared by the vault and its logic libraries: NAV views, share conversions, claim
///      accounting and direct access to the OpenZeppelin ERC-20 / Ownable storage (so the delegatecalled
///      libraries can mint, burn and move shares on the vault's own balances).
library VaultMath {
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
    /// @dev USDC held on HyperEVM that belongs to share holders.
    function idleAssets(VaultStorage storage $) internal view returns (uint256) {
        uint256 bal = $.asset.balanceOf(address(this));
        uint256 reserved = $.pendingDepositAssets + $.deferredDepositAssets + $.claimableRedeemAssets;
        return bal > reserved ? bal - reserved : 0;
    }

    /// @dev Vault equity on HyperCore: perp account value plus spot USDC, floored at zero as one sum (audit L-05).
    function coreEquity() internal view returns (uint256) {
        if (!HyperCore.coreUserExists(address(this))) return 0;
        int256 e = int256(HyperCore.accountMarginSummary(address(this)).accountValue)
            + int256(uint256(HyperCore.spotBalance(address(this), HyperCore.USDC_TOKEN).total) / 100);
        return e > 0 ? uint256(e) : 0;
    }

    /// @dev HL-PROXY account-mode guard. No precompile reports the abstraction mode, so this reads its footprint. The
    ///      vault never borrows or lends (it never emits CoreWriter action 15 and has no API wallet), so any borrow /
    ///      lend state of its USDC means portfolio margin (every probed portfolio-margin account had one, no Standard
    ///      account without lending did) or lending it did not do: in both cases spot USDC on 0x801 reads 0 and
    ///      borrowed USDC is not subtracted (CONTEXT evidence 3), so the NAV read is not the vault's equity.
    ///      Unified mode leaves no reliable footprint (HL-PROXY.md section 4) and is covered by the pin alone.
    function modeSuspect() internal view returns (bool) {
        return HyperCore.borrowLendActive(address(this), HyperCore.USDC_TOKEN);
    }

    /// @dev The window is BRIDGE_SETTLE_BLOCKS long, and stays open after that until the transfer has landed (R-02),
    ///      so a late landing is never read as a NAV drop nor settled around. Landing is read on the destination
    ///      side only, never from the vault's total (which moves with PnL and would let the in-window rule mask a
    ///      real loss). Bounded by MAX_BRIDGE_WAIT_BLOCKS, after which whatever is still missing counts as missing.
    function bridgeInFlight(VaultStorage storage $) internal view returns (bool) {
        uint256 last = $.lastBridgeBlock;
        if (last == 0) return false;
        if (block.number <= last + BRIDGE_SETTLE_BLOCKS) return true;
        if ($.bridgeLanded || block.number > last + MAX_BRIDGE_WAIT_BLOCKS) return false;
        return !bridgeArrived($);
    }

    /// @dev The latest bridge has not landed and is at most MAX_UNLANDED_BLOCKS old (past the NAV window).
    function bridgeUnlanded(VaultStorage storage $) internal view returns (bool) {
        uint256 last = $.lastBridgeBlock;
        if (last == 0 || $.bridgeLanded || block.number > last + MAX_UNLANDED_BLOCKS) return false;
        return !bridgeArrived($);
    }

    /// @dev Nothing that reads or moves the NAV runs while a transfer is in flight or late (R3-01 residual).
    function bridgePending(VaultStorage storage $) internal view returns (bool) {
        return bridgeInFlight($) || bridgeUnlanded($);
    }

    /// @dev Has the latest bridge's amount shown up on its destination side?
    function bridgeArrived(VaultStorage storage $) internal view returns (bool) {
        uint256 want = $.bridgeAmount > BRIDGE_LANDING_TOLERANCE ? $.bridgeAmount - BRIDGE_LANDING_TOLERANCE : 0;
        // EVM -> Core lands on Core SPOT. HLR2-A04: spot alone can be faked by a perp -> spot move, so spot + perp
        // cash must be up by the amount too (a fill in a listed market changes neither). Never equity (it moves
        // with unrealised PnL, R3-01). Without a cash reading (precompile failure) this is spot alone, as before.
        // A miss only runs the window to MAX_UNLANDED_BLOCKS; it holds nothing after it (bridgeUnresolved).
        if ($.bridgeToCoreDir) {
            if (coreSpotUsd() < $.spotAtBridge + want) return false;
            if (!$.cashKnown) return true;
            (bool ok, int256 c) = tryCoreCash($);
            return !ok || c >= $.cashAtBridge + int256(want);
        }
        uint256 bal = $.asset.balanceOf(address(this)) + $.evmOutSinceBridge;
        return bal >= $.evmAtBridge + $.evmInSinceBridge + want;
    }

    /// @dev HLR2-A02 / A08: the latest transfer is past MAX_UNLANDED_BLOCKS, has not landed, the guardian has not
    ///      written it off, it is at most UNRESOLVED_WAIT_BLOCKS old, HyperCore shows it missing (to Core: no credit
    ///      of half the amount ever seen in spot + perp cash; to EVM: the debit seen, the EVM credit not), and the
    ///      visible NAV is short by at least half of it. Pricing at that NAV would hand the missing amount from the
    ///      depositors priced now to the ones after the landing, so nothing settles or bridges meanwhile. A
    ///      transfer that failed at its source, or landed where the landing signal does not look, holds nothing.
    function bridgeUnresolved(VaultStorage storage $) internal view returns (bool) {
        uint256 last = $.lastBridgeBlock;
        if (last == 0 || $.bridgeLanded || $.bridgeWrittenOff) return false;
        if (block.number <= last + MAX_UNLANDED_BLOCKS || block.number > last + UNRESOLVED_WAIT_BLOCKS) return false;
        if (bridgeArrived($)) return false;
        if (idleAssets($) + coreEquity() + $.bridgeAmount / 2 >= $.equityAtBridge) return false;
        if ($.bridgeToCoreDir) return !$.creditSeen && !_cashMoved($, true);
        return $.debitSeen || !$.cashKnown || _cashMoved($, false);
    }

    /// @dev Spot + perp cash moved by half the bridged amount since the bridge: up (to Core: the credit) or down
    ///      (to EVM: the debit). An unreadable cash counts as moved for a debit (hold) and as not moved for a credit.
    function _cashMoved(VaultStorage storage $, bool up) internal view returns (bool) {
        if (!$.cashKnown) return false;
        (bool ok, int256 c) = tryCoreCash($);
        if (!ok) return !up;
        int256 half = int256($.bridgeAmount / 2);
        return up ? c >= $.cashAtBridge + half : c + half <= $.cashAtBridge;
    }

    /// @dev Spot USDC plus perp cash on HyperCore (6 decimals): rawUsd plus the signed entry notional of every
    ///      market the policy ever listed, i.e. the perp account value without unrealised PnL. 0 before the Core
    ///      account exists. ok = false when a precompile read fails: never reverts (L01: an outage of the position
    ///      precompile must not stop a bridge or a settle).
    function tryCoreCash(VaultStorage storage $) internal view returns (bool ok, int256 c) {
        if (!HyperCore.coreUserExists(address(this))) return (true, 0);
        c = int256(coreSpotUsd());
        (bool s, bytes memory out) = HyperCore.PRECOMPILE_ACCOUNT_MARGIN_SUMMARY.staticcall(
            abi.encode(HyperCore.DEFAULT_PERP_DEX, address(this))
        );
        if (!s || out.length < 128) return (false, 0);
        c += int256(abi.decode(out, (HyperCore.AccountMarginSummary)).rawUsd);
        uint32[] memory list = $.policy.listedAssets();
        for (uint256 i; i < list.length; ++i) {
            (s, out) = HyperCore.PRECOMPILE_POSITION.staticcall(abi.encode(address(this), list[i]));
            if (!s || out.length < 160) return (false, 0);
            HyperCore.Position memory p = abi.decode(out, (HyperCore.Position));
            if (p.szi > 0) c += int256(uint256(p.entryNtl));
            else if (p.szi < 0) c -= int256(uint256(p.entryNtl));
        }
        return (true, c);
    }

    /// @dev Spot USDC on HyperCore, 6 decimals (0 before the Core account exists).
    function coreSpotUsd() internal view returns (uint256) {
        if (!HyperCore.coreUserExists(address(this))) return 0;
        return uint256(HyperCore.spotBalance(address(this), HyperCore.USDC_TOKEN).total) / 100;
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

    /// @dev NAV. Inside a bridge window it is the pre-bridge snapshot, so a transfer is never counted on
    ///      both sides (audit L-04). Nothing settles or accrues inside the window.
    function totalAssets(VaultStorage storage $) internal view returns (uint256) {
        if (bridgeInFlight($)) return $.equityAtBridge;
        return idleAssets($) + coreEquity();
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

    /// @dev The deadline is the one stored when the epoch started (hl-r2 H01 / XB01): a policy change to
    ///      maxEpochDuration never moves a running epoch's deadline, and an overdue epoch stays overdue.
    function epochOverdue(VaultStorage storage $) internal view returns (bool) {
        return block.timestamp >= uint256($.epochDeadline);
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
    ///      redemptions priced at min(NAV, checkpoint). 10_000 = paid in full.
    function emergencyFillBps(VaultStorage storage $) internal view returns (uint256) {
        uint256 pending = $.pendingRedeemShares;
        if (pending == 0) return BPS;
        uint256 nav = totalAssets($);
        if ($.checkpointNav > 0 && $.checkpointNav < nav) nav = $.checkpointNav;
        uint256 owed = toAssets(pending, nav, totalSupply(), Math.Rounding.Floor);
        uint256 available = idleAssets($);
        if (owed == 0 || available >= owed) return BPS;
        return available.mulDiv(BPS, owed, Math.Rounding.Floor);
    }
}
