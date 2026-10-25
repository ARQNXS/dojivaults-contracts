// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GainsVaultMath} from "../../../../../src/gains/GainsVaultMath.sol";
import {operatorReduceCap} from "../../../../../src/gains/GainsTypes.sol";
import {BPS, DECIMALS_OFFSET} from "../../../../../src/VaultTypes.sol";

/// @title Conservation of value in single operations (round 2, domain STAT, Halmos)
/// @dev Shared by the Halmos harness (HalmosConservation.t.sol, check_*) and its forge fuzz twins
///      (HalmosConservationFuzz.t.sol, test_*). Every property is an internal function that asserts.
///
///      Two kinds of property:
///      C-series (linear bookkeeping). Each operation's state changes are COPIED statement by statement from
///        contracts/src/gains (4ec6feb, line numbers given at each COPY) with VaultStorage replaced by a memory struct.
///        The results of the non-linear conversions (toShares / toAssets / the partial-fill mulDiv / claimable) enter
///        as FREE symbolic values, constrained only by what the production code itself enforces (a revert) or by an
///        N-series property (named where used). So a C proof says: whatever those conversions return, the operation
///        moves USDC and shares only between the listed buckets, and the buckets stay backed.
///      N-series (rounding, non-linear). The production pure functions (GainsVaultMath.toShares / toAssets,
///        operatorReduceCap) are called directly (inlined); the claim and partial-fill expressions are COPIED (they
///        read VaultStorage in production). Domains are narrow (uint16 / uint32) because round 1 showed that every
///        mulDiv over 64-bit or wider inputs times out.
///
///      A Halmos "pass" means: no input in the stated domain that does not revert reaches a failing assert.
abstract contract ConservationProps is Test {
    uint256 internal constant OFF = 10 ** DECIMALS_OFFSET;

    /// @dev The USDC side of a vault: balance and the three reserves (GainsVaultMath.idleAssets, lines 102-106).
    struct Usdc {
        uint256 bal;
        uint256 pend; // pendingDepositAssets
        uint256 defer; // deferredDepositAssets
        uint256 claim; // claimableRedeemAssets
    }

    function _reserved(Usdc memory u) internal pure returns (uint256) {
        return u.pend + u.defer + u.claim;
    }

    /// COPY GainsVaultMath.idleAssets 103-105
    function _idle(Usdc memory u) internal pure returns (uint256) {
        uint256 reserved = u.pend + u.defer + u.claim;
        return u.bal > reserved ? u.bal - reserved : 0;
    }

    // =====================================================================================================
    // C1 deposit request (GainsVaultLogic.requestDeposit 68-73)
    // =====================================================================================================
    /// The depositor's USDC moves into the vault and into exactly one queue; idle (the holders' USDC) does not move.
    function _c1(uint128 bal, uint128 pend, uint128 defer, uint128 claim, uint128 wallet, uint128 assets, bool insider)
        internal
        pure
    {
        vm.assume(assets <= wallet); // safeTransferFrom reverts otherwise
        Usdc memory u = Usdc(bal, pend, defer, claim);
        uint256 idle0 = _idle(u);
        uint256 total0 = uint256(wallet) + u.bal;
        uint256 w = wallet;
        // COPY 68 + 72-73
        w -= assets;
        u.bal += assets;
        if (insider) u.defer += assets;
        else u.pend += assets;
        assert(_idle(u) == idle0);
        assert(w + u.bal == total0);
        assert(u.pend + u.defer == uint256(pend) + defer + assets);
        // an insider's deposit waits for the next epoch (deferred), anyone else's joins this epoch's queue
        if (insider) assert(u.defer == uint256(defer) + assets && u.pend == pend);
        else assert(u.pend == uint256(pend) + assets && u.defer == defer);
        assert(u.claim == claim);
    }

    // =====================================================================================================
    // C2 redeem request (requestRedeem 87, 95-99; GainsVaultMath.transfer / spendAllowance 77-96)
    // =====================================================================================================
    /// Shares move from the owner into the vault's escrow and into the pending count, one for one; supply and
    /// every other balance are unchanged; a spender moves at most its allowance.
    function _c2(
        uint128 ownerBal,
        uint128 escrow,
        uint128 others,
        uint128 pendRed,
        uint128 shares,
        uint256 allowance,
        bool bySpender
    ) internal pure {
        vm.assume(shares > 0); // ZeroAmount
        vm.assume(escrow >= pendRed); // the escrow holds every pending redemption (C4, C5 keep it)
        uint256 supply = uint256(ownerBal) + escrow + others;
        uint256 o = ownerBal;
        uint256 e = escrow;
        uint256 p = pendRed;
        uint256 a = allowance;
        // COPY spendAllowance 90-95
        if (bySpender && a != type(uint256).max) {
            vm.assume(a >= shares); // ERC20InsufficientAllowance
            a = a - shares;
        }
        // COPY transfer 79-84
        vm.assume(o >= shares); // ERC20InsufficientBalance
        o = o - shares;
        e += shares;
        // COPY 98-99
        p += shares;
        assert(o + e + others == supply);
        assert(e >= p);
        assert(e - p == uint256(escrow) - pendRed); // escrow surplus (returned, unclaimed shares) unchanged
        if (bySpender && allowance != type(uint256).max) assert(allowance - a == shares);
    }

    // =====================================================================================================
    // C3 cancel deposit (cancelDepositRequest 114-124) and C4 cancel redeem (cancelRedeemRequest 133-136)
    // =====================================================================================================
    function _c3(uint128 bal, uint128 pend, uint128 defer, uint128 claim, uint128 assets, bool deferred) internal pure {
        Usdc memory u = Usdc(bal, pend, defer, claim);
        vm.assume(u.bal >= _reserved(u)); // backed before (the invariant settle and claim keep: C5, C6)
        vm.assume(deferred ? assets <= defer : assets <= pend); // checked subtraction in production
        uint256 idle0 = _idle(u);
        // COPY 115-124
        if (deferred) u.defer -= assets;
        else u.pend -= assets;
        u.bal -= assets; // safeTransfer to the canceller
        assert(_idle(u) == idle0);
        assert(u.bal >= _reserved(u));
        assert(u.claim == claim);
    }

    function _c4(uint128 escrow, uint128 pendRed, uint128 holder, uint128 shares) internal pure {
        vm.assume(shares <= pendRed && escrow >= pendRed); // checked subtraction; escrow holds the pending shares
        uint256 e = escrow;
        uint256 p = pendRed;
        uint256 h = holder;
        // COPY 134-136
        p -= shares;
        e -= shares; // transfer(address(this), msg.sender, shares)
        h += shares;
        assert(e >= p);
        assert(e + h == uint256(escrow) + holder);
    }

    // =====================================================================================================
    // C5 settle (GainsVaultLogic.settle 262-319): normal, redemption-only, exit-only, emergency partial fill
    // =====================================================================================================
    struct Settle {
        uint256 pend;
        uint256 defer;
        uint256 claim;
        uint256 supply;
        uint256 escrow;
        uint256 paid;
        uint256 burned;
        uint256 depAssets;
        uint256 depIn;
        uint256 depShares;
    }

    /// @param redAssets free: toAssets(redShares, priceNav, supply, Floor) (bounded by N4 for shares <= supply)
    /// @param depSharesRaw free: toShares(depIn, ...), except toShares(0, ..) == 0 (N0)
    /// @param burnedPartial free with burnedPartial <= redShares: the partial-fill mulDiv (N2)
    function _settleCopy(
        Usdc memory u,
        uint256 supply,
        uint256 escrow,
        uint256 redShares,
        bool emergency,
        bool lossBreach,
        bool treasury,
        uint256 redAssets,
        uint256 depSharesRaw,
        uint256 burnedPartial
    ) internal pure returns (Settle memory s) {
        // modes, COPY 230-231
        bool redemptionOnly = !emergency && lossBreach;
        bool exitOnly = emergency || (!treasury && !redemptionOnly);
        // COPY 274-281
        s.depAssets = redemptionOnly ? 0 : u.pend;
        s.depIn = exitOnly ? 0 : s.depAssets;
        s.depShares = s.depIn == 0 ? 0 : depSharesRaw; // N0: toShares(0, ..) == 0
        if (s.depShares == 0) s.depIn = 0;
        // COPY 283-292
        uint256 available = _idle(u) + s.depIn;
        s.paid = redAssets;
        s.burned = redShares;
        if (available < redAssets) {
            vm.assume(emergency); // InsufficientLiquidity otherwise
            s.paid = available;
            vm.assume(burnedPartial <= redShares); // N2
            s.burned = burnedPartial;
        }
        // COPY 294-295 (burn reverts when the escrow is short)
        vm.assume(escrow >= s.burned);
        s.escrow = escrow - s.burned + s.depShares;
        s.supply = supply - s.burned + s.depShares;
        // COPY 297
        s.claim = u.claim + s.paid + s.depAssets - s.depIn;
        // COPY 300-319
        if (redemptionOnly) {
            s.pend = u.pend + u.defer;
        } else {
            s.pend = u.defer;
        }
        s.defer = 0;
    }

    /// Settle moves no USDC in or out; it only re-labels: the payout and the refunds go from idle / the queue to the
    /// claim reserve, priced deposits from the queue to idle. Afterwards every reserve is still backed, nothing was
    /// paid that idle plus priced deposits did not cover, and the shares burned are at most the queued ones.
    function _c5(
        uint64 bal,
        uint64 pend,
        uint64 defer,
        uint64 claim,
        uint128 supply,
        uint128 escrow,
        uint128 redShares,
        bool emergency,
        bool lossBreach,
        bool treasury,
        uint64 redAssets,
        uint128 depSharesRaw,
        uint128 burnedPartial
    ) internal pure {
        Usdc memory u = Usdc(bal, pend, defer, claim);
        vm.assume(u.bal >= _reserved(u)); // backed before
        vm.assume(escrow >= redShares && supply >= escrow); // the escrow holds the pending redemptions
        uint256 idle0 = _idle(u);
        Settle memory s = _settleCopy(u, supply, escrow, redShares, emergency, lossBreach, treasury, redAssets, depSharesRaw, burnedPartial);
        Usdc memory a = Usdc(u.bal, s.pend, s.defer, s.claim);
        // backed after, and the USDC identity: idle' = idle - paid + priced deposits
        assert(a.bal >= _reserved(a));
        assert(_idle(a) + s.paid == idle0 + s.depIn);
        // every queued dollar is exactly one of: priced (idle), refunded (claim), still queued
        assert(uint256(pend) + defer == s.depIn + (s.depAssets - s.depIn) + s.pend + s.defer);
        // the claim reserve grows by the payout and the refunds only
        assert(s.claim - claim == s.paid + s.depAssets - s.depIn);
        // shares
        assert(s.burned <= redShares);
        assert(s.supply + s.burned == uint256(supply) + s.depShares);
        assert(s.escrow + s.burned == uint256(escrow) + s.depShares);
        // per mode
        bool redemptionOnly = !emergency && lossBreach;
        bool exitOnly = emergency || (!treasury && !redemptionOnly);
        if (exitOnly || redemptionOnly) assert(s.depShares == 0); // never mints outside a normal settle
        if (redemptionOnly) assert(s.depAssets == 0 && s.pend == uint256(pend) + defer); // queue carried whole
        if (exitOnly) assert(s.claim == uint256(claim) + s.paid + pend); // every queued deposit refunded
        if (!emergency) assert(s.paid == redAssets && s.burned == redShares); // paid in full or reverted
        if (emergency && s.paid < redAssets) assert(_idle(a) == 0); // partial fill pays out all of idle
    }

    // =====================================================================================================
    // C6 claim (GainsVaultLogic._claimIfSettled 158-166)
    // =====================================================================================================
    /// A claim pays from the claim reserve only (clamped), returns shares from the escrow only; idle and the queues
    /// are untouched.
    function _c6(uint128 bal, uint128 pend, uint128 defer, uint128 claim, uint128 escrow, uint128 shares, uint128 assets)
        internal
        pure
    {
        Usdc memory u = Usdc(bal, pend, defer, claim);
        vm.assume(u.bal >= _reserved(u));
        uint256 idle0 = _idle(u);
        uint256 e = escrow;
        uint256 paidOut;
        // COPY 160-166
        if (shares > 0) {
            vm.assume(e >= shares); // transfer reverts otherwise
            e -= shares;
        }
        uint256 x = assets;
        if (x > 0) {
            if (x > u.claim) x = u.claim;
            u.claim -= x;
            u.bal -= x;
            paidOut = x;
        }
        assert(_idle(u) == idle0);
        assert(u.bal >= _reserved(u));
        assert(paidOut <= assets && paidOut <= claim);
        assert(u.pend == pend && u.defer == defer);
        assert(uint256(escrow) - e == shares);
    }

    // =====================================================================================================
    // C7 fee accrual (GainsVaultLogic._accrueFees 375-387)
    // =====================================================================================================
    /// Fees move no USDC; they mint exactly feeShares, split between the fee recipient and the protocol, and touch
    /// no other balance. protocolShares <= feeShares (the split is real arithmetic here: x * bps / BPS).
    function _c7(uint128 supply, uint64 assets, uint64 feeAssets, uint128 feeSharesRaw, uint16 protoBps, uint128 holders)
        internal
        pure
    {
        vm.assume(protoBps <= BPS); // factory / initializer bound
        vm.assume(holders <= supply);
        uint256 sup = supply;
        uint256 rec;
        uint256 pro;
        uint256 feeShares;
        uint256 protocolShares;
        // COPY 377-387 (feeShares free: feeAssets.mulDiv(supply + OFF, assets - feeAssets), see N-series / FE1 round 1)
        if (feeAssets > 0 && feeAssets < assets) {
            feeShares = feeSharesRaw;
            protocolShares = Math.mulDiv(feeShares, protoBps, BPS);
            if (protocolShares > 0) {
                sup += protocolShares;
                pro += protocolShares;
            }
            if (feeShares > protocolShares) {
                sup += feeShares - protocolShares;
                rec += feeShares - protocolShares;
            }
        }
        assert(protocolShares <= feeShares);
        assert(sup - supply == feeShares);
        assert(rec + pro == feeShares);
        assert(holders <= sup); // other balances unchanged (only rec and pro were credited)
    }

    // =====================================================================================================
    // N-series: rounding (production functions or COPY), narrow domains
    // =====================================================================================================
    /// N0 toShares(0, ..) == 0 and toAssets(0, ..) == 0 (used by C5). Full uint128 domain.
    function _n0(uint128 nav, uint128 supply) internal pure {
        assert(GainsVaultMath.toShares(0, nav, supply, Math.Rounding.Floor) == 0);
        assert(GainsVaultMath.toAssets(0, nav, supply, Math.Rounding.Floor) == 0);
    }

    /// N1 two redeemers of one epoch (COPY GainsVaultMath.claimableWithCarry 222-227): payouts sum to <= the epoch's
    ///    payout; returned shares sum to <= the escrow left after the burn.
    function _n1(uint16 s1, uint16 s2, uint16 paid, uint16 burned) internal pure {
        uint256 S = uint256(s1) + s2;
        vm.assume(S > 0 && burned <= S);
        uint256 a1 = Math.mulDiv(s1, paid, S, Math.Rounding.Floor);
        uint256 a2 = Math.mulDiv(s2, paid, S, Math.Rounding.Floor);
        assert(a1 + a2 <= paid);
        uint256 b1 = Math.mulDiv(s1, burned, S, Math.Rounding.Ceil);
        uint256 b2 = Math.mulDiv(s2, burned, S, Math.Rounding.Ceil);
        uint256 r1 = b1 < s1 ? s1 - b1 : 0;
        uint256 r2 = b2 < s2 ? s2 - b2 : 0;
        assert(r1 + r2 <= S - burned);
    }

    /// N1p the same with plain arithmetic (equal to mulDiv in this domain: no product reaches 2^256).
    function _n1p(uint16 s1, uint16 s2, uint16 paid, uint16 burned) internal pure {
        uint256 S = uint256(s1) + s2;
        vm.assume(S > 0 && burned <= S);
        uint256 a1 = uint256(s1) * paid / S;
        uint256 a2 = uint256(s2) * paid / S;
        assert(a1 + a2 <= paid);
        uint256 b1 = (uint256(s1) * burned + S - 1) / S;
        uint256 b2 = (uint256(s2) * burned + S - 1) / S;
        uint256 r1 = b1 < s1 ? s1 - b1 : 0;
        uint256 r2 = b2 < s2 ? s2 - b2 : 0;
        assert(r1 + r2 <= S - burned);
    }

    /// N2 emergency partial fill (COPY settle 290-291): burned <= redShares and the burned shares are worth at most
    ///    what was paid for them at the epoch price (burned * redAssets <= paid * redShares).
    function _n2(uint16 redShares, uint16 redAssets, uint16 available) internal pure {
        vm.assume(available < redAssets);
        uint256 paid = available;
        uint256 burned = Math.mulDiv(redShares, paid, redAssets, Math.Rounding.Floor);
        assert(burned <= redShares);
        assert(burned * redAssets <= paid * redShares);
    }

    /// N3 two depositors of one epoch (COPY claimableWithCarry 219): delivered shares sum to <= the epoch's mint.
    function _n3(uint16 d1, uint16 d2, uint16 depShares) internal pure {
        uint256 D = uint256(d1) + d2;
        vm.assume(D > 0);
        uint256 x1 = Math.mulDiv(d1, depShares, D, Math.Rounding.Floor);
        uint256 x2 = Math.mulDiv(d2, depShares, D, Math.Rounding.Floor);
        assert(x1 + x2 <= depShares);
    }

    /// N4 settle never owes redeemers more than the NAV it prices at (toAssets Floor, shares <= supply).
    function _n4(uint32 shares, uint32 nav, uint32 supply) internal pure {
        vm.assume(supply > 0 && shares <= supply);
        assert(GainsVaultMath.toAssets(shares, nav, supply, Math.Rounding.Floor) <= nav);
    }

    /// N5 a deposit minted at Floor never dilutes the holders: price per share after >= before (cross-multiplied).
    function _n5(uint32 a, uint32 nav, uint32 supply) internal pure {
        vm.assume(supply > 0);
        uint256 sh = GainsVaultMath.toShares(a, nav, supply, Math.Rounding.Floor);
        assert((uint256(nav) + a + 1) * (uint256(supply) + OFF) >= (uint256(nav) + 1) * (uint256(supply) + sh + OFF));
    }

    /// N6 a redemption paid at Floor never dilutes the remaining holders.
    function _n6(uint32 sh, uint32 nav, uint32 supply) internal pure {
        vm.assume(supply > 0 && sh <= supply);
        uint256 paid = GainsVaultMath.toAssets(sh, nav, supply, Math.Rounding.Floor);
        assert(paid <= nav);
        assert((uint256(nav) - paid + 1) * (uint256(supply) + OFF) >= (uint256(nav) + 1) * (uint256(supply) - sh + OFF));
    }

    /// N7 the operator bound is monotone and above the shortfall for every uint32 shortfall (round 1 OB3 timed out on
    ///    uint64 / uint200).
    function _n7(uint32 a, uint32 b) internal pure {
        vm.assume(a <= b);
        assert(operatorReduceCap(a) <= operatorReduceCap(b));
        assert(operatorReduceCap(b) >= b);
    }

    /// N8 fee split: protocolShares = feeShares * bps / BPS <= feeShares, full uint128 domain.
    function _n8(uint128 feeShares, uint16 bps) internal pure {
        vm.assume(bps <= BPS);
        assert(Math.mulDiv(feeShares, bps, BPS) <= feeShares);
    }
}
