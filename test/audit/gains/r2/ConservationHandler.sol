// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GainsVault} from "../../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../../src/gains/GainsVaultPolicy.sol";
import {IGainsDiamond} from "../../../../src/gains/IGainsDiamond.sol";
import {OpenParams} from "../../../../src/gains/GainsTypes.sol";
import {BreachReason} from "../../../../src/VaultTypes.sol";
import {MockChainlinkFeed} from "../../../gains/mocks/GainsMocks.sol";
import {LedgerUSDC, CIDiamond} from "./ConservationMocks.sol";
import {CIWorld} from "./ConservationWorld.sol";

/// @notice Round 2, domain CI (conservation). Independent valuation of what the vault holds on the diamond, from the
///         mock's own close math (Gains' close formula), at three prices: the adverse band edge (what the vault must
///         report, N1), the Chainlink mid (the fair value the fairness checks use) and the favourable edge (what
///         deposits must mint at, GR1-02). Pending orders count by their REAL type (the mock's), whatever Gains
///         reports: an order that holds collateral is worth that collateral minus the gov fee a callback cancel keeps.
contract CIValuer {
    struct Venue {
        uint256 adv;
        uint256 mid;
        uint256 fav;
        uint256 heldOrders; // pending orders that hold collateral (by real type)
        uint256 notional;
    }

    function adverse(uint64 mid, uint16 band, bool long) public pure returns (uint64) {
        return long ? uint64((uint256(mid) * (10_000 - band)) / 10_000) : uint64((uint256(mid) * (10_000 + band)) / 10_000);
    }

    function venue(CIDiamond d, address v, uint64 btc, uint64 eth, uint16 band) external view returns (Venue memory r) {
        IGainsDiamond.Trade[] memory t = d.getTrades(v);
        for (uint256 i; i < t.length; ++i) {
            if (t[i].tradeType != 0) {
                r.adv += t[i].collateralAmount;
                r.mid += t[i].collateralAmount;
                r.fav += t[i].collateralAmount;
                continue;
            }
            uint64 p = t[i].pairIndex == 0 ? btc : eth;
            r.adv += d.closeValue(v, t[i].index, adverse(p, band, t[i].long));
            r.mid += d.closeValue(v, t[i].index, p);
            r.fav += d.closeValue(v, t[i].index, adverse(p, band, !t[i].long));
        }
        uint32 n = d.orderCount(v);
        for (uint32 i; i < n; ++i) {
            uint256 h = d.heldBy(v, i);
            if (h == 0) continue;
            IGainsDiamond.PendingOrder memory o = d.getRealOrder(v, i);
            uint16 feePair = o.orderType == 0 ? o.trade.pairIndex : d.getTrade(v, o.trade.index).pairIndex;
            uint256 fee = d.minGovFee(feePair);
            uint256 val = h > fee ? h - fee : 0;
            r.adv += val;
            r.mid += val;
            r.fav += val;
            r.heldOrders++;
        }
    }
}

/// @notice Round 2, domain CI. Drives one factory vault (CIWorld) through every depositor flow, settle mode, fee
///         path, trade and venue outcome, and books every unit of USDC: the instrumented token (LedgerUSDC) sees each
///         transfer, the mock diamond keeps the venue ledger, and this handler keeps the ghost ledger of what each
///         flow was entitled to. Properties are ghost counters that must stay 0 (see CONSERVATION.md for the list).
contract CIHandler is CommonBase, StdUtils {
    using Math for uint256;

    uint256 internal constant OFF = 1e6; // 10 ** DECIMALS_OFFSET
    uint256 internal constant ONE = 1e12; // ONE_SHARE
    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;

    CIWorld public w;
    CIValuer public valuer;
    GainsVault public vault;
    GainsVaultPolicy public policy;
    LedgerUSDC public usdc;
    CIDiamond public diamond;
    MockChainlinkFeed internal btcFeed;
    MockChainlinkFeed internal ethFeed;
    address internal M;
    address internal A;
    address internal K;
    address internal G;
    address internal S;
    address internal T;
    address internal X;
    address[5] internal actors;
    uint16 internal band;

    uint64 public btcPx = 100_000e10;
    uint64 public ethPx = 3_000e10;

    // ------------------------------------------------------------------ ghost ledger
    uint256 public base; // vault USDC when the ledger started (the seed)
    uint256 public gDeposits;
    uint256 public gDonations;
    uint256 public gRefunds; // cancelDepositRequest
    uint256 public gClaims; // claim deliveries (redemptions and deposit refunds), explicit or implicit
    uint256 public gExpectedPull; // collateral the vault's own trader calls asked the diamond to pull
    uint256 public dustBound; // rounding a settled epoch may leave in claimableRedeemAssets (one wei per redeemer)
    mapping(uint256 => uint256) public claimedRed;
    mapping(uint256 => uint256) public returnedShares;
    mapping(uint256 => uint256) public claimedDepShares;
    mapping(uint256 => uint256) public refundedDep;

    // ------------------------------------------------------------------ violations (must stay 0)
    uint256 public vF1HolderDiluted; // a settle lowered the continuing holders' fair (mid) value per share
    uint256 public vF1dDepositPrice; // deposit shares != toShares(depIn, max(advNAV, idle + favNAV)) (independent NAVs)
    uint256 public vF1rRedeemPrice; // redemption payout != toAssets(shares, min(advNAV, cp) | advNAV) / partial fill rule
    uint256 public vS1HeldInFlight; // a settle ran while an order holding collateral was pending (by real type)
    uint256 public vFeeAboveCap; // fee shares worth more than the configured fee (mgmt pro rata + perf above HWM)
    uint256 public vFeeConfig; // a configured fee above its hard cap (5% / 30% / 50%)
    uint256 public vProtocolShare; // protocol shares above protocolShareBps of the fee shares
    uint256 public vFeeRecipient; // fee shares minted to anyone but the fee recipient and the protocol recipient
    uint256 public vClaimOver; // a delivery above the entitlement
    uint256 public vClaimShortWei; // a delivery below the entitlement (wei)
    uint256 public vEpochOverpaid; // claims of an epoch's redeemers > its redeemAssets
    uint256 public vReturnedOver; // shares returned to an epoch's redeemers > its unburned escrow
    uint256 public vDepSharesOver; // deposit shares claimed from an epoch > its depositShares
    uint256 public vRefundOver; // deposit refunds of an epoch > its depositAssets
    uint256 public vLostRequest; // a settled request whose epoch recorded nothing for it
    uint256 public vFlowMovedHolders; // a depositor flow changed idle USDC, supply or the venue
    uint256 public vCancelInexact; // a cancel returned != the request
    uint256 public vCollateral; // the diamond pulled != what a trader call asked, or outside one
    uint256 public vRedeemSharesMoved; // requestRedeem escrowed != the shares

    // ------------------------------------------------------------------ stats
    uint256 public nDeposits;
    uint256 public nRedeems;
    uint256 public nCancels;
    uint256 public nClaims;
    uint256 public nClaimsByStranger;
    uint256 public nDonations;
    uint256 public nSettles;
    uint256 public nSettleNormal;
    uint256 public nSettleRedemptionOnly;
    uint256 public nSettleExitOnly;
    uint256 public nSettlePartial;
    uint256 public nSettleWithDeposits;
    uint256 public nSettleWithOpenTrades;
    uint256 public nFeeMints;
    uint256 public nOpens;
    uint256 public nFills;
    uint256 public nCallbackCancels;
    uint256 public nTimeouts;
    uint256 public nLiquidations;
    uint256 public nTriggers;
    uint256 public nRetypes;
    uint256 public nCloses;
    uint256 public nReduces;
    uint256 public nEmergencies;
    uint256 public maxClaimDust;

    constructor(CIWorld w_, CIValuer valuer_) {
        w = w_;
        valuer = valuer_;
        vault = w_.vault();
        policy = w_.policy();
        usdc = w_.usdc();
        diamond = w_.diamond();
        btcFeed = w_.btcFeed();
        ethFeed = w_.ethFeed();
        M = w_.MANAGER();
        A = w_.AGENT();
        K = w_.KEEPER();
        G = w_.GUARDIAN();
        S = w_.SENTINEL();
        T = w_.TREASURY();
        X = w_.STRANGER();
        actors = w_.actors();
        band = w_.BAND();
        for (uint256 i; i < 5; ++i) {
            usdc.mint(actors[i], 100_000_000e6);
            vm.prank(actors[i]);
            usdc.approve(address(vault), type(uint256).max);
        }
        usdc.mint(X, 100_000_000e6);
        base = usdc.balanceOf(address(vault));
    }

    // ================================================================== helpers
    /// @dev Forge (via_ir) needs the cheatcode reads (block.timestamp can be rematerialised stale after vm.warp);
    ///      Medusa has no such cheatcode and reads the block directly.
    bool public native;

    function setNative(bool n) external {
        native = n;
    }

    function _now() internal view returns (uint256) {
        return native ? block.timestamp : vm.getBlockTimestamp();
    }

    function _blk() internal view returns (uint256) {
        return native ? block.number : vm.getBlockNumber();
    }

    function _fresh() internal {
        ethFeed.set(int256(uint256(ethPx / 100)), _now());
        btcFeed.set(int256(uint256(btcPx / 100)), _now());
    }

    function _skip(uint256 dt) internal {
        vm.warp(_now() + dt);
        vm.roll(_blk() + dt / 12 + 1);
        _fresh();
    }

    function _px(uint16 pair) internal view returns (uint64) {
        return pair == 0 ? btcPx : ethPx;
    }

    function venueNow() public view returns (CIValuer.Venue memory) {
        return valuer.venue(diamond, address(vault), btcPx, ethPx, band);
    }

    function _reserved() internal view returns (uint256) {
        return vault.pendingDepositAssets() + vault.deferredDepositAssets() + vault.claimableRedeemAssets();
    }

    function idleNow() public view returns (uint256) {
        uint256 bal = usdc.balanceOf(address(vault));
        uint256 r = _reserved();
        return bal > r ? bal - r : 0;
    }

    function _toShares(uint256 assets, uint256 nav, uint256 supply) internal pure returns (uint256) {
        if (supply == 0) return assets * OFF;
        return assets.mulDiv(supply + OFF, nav + 1);
    }

    function _toAssets(uint256 shares, uint256 nav, uint256 supply) internal pure returns (uint256) {
        if (supply == 0) return shares / OFF;
        return shares.mulDiv(nav + 1, supply + OFF);
    }

    /// @dev The k-th open trade of the vault (market or resting), if any.
    function _trade(uint256 k) internal view returns (bool ok, IGainsDiamond.Trade memory t) {
        IGainsDiamond.Trade[] memory ts = diamond.getTrades(address(vault));
        if (ts.length == 0) return (false, t);
        return (true, ts[k % ts.length]);
    }

    /// @dev The k-th open pending order (real type), if any.
    function _order(uint256 k) internal view returns (bool ok, IGainsDiamond.PendingOrder memory o) {
        uint32 n = diamond.orderCount(address(vault));
        uint256 open;
        for (uint32 i; i < n; ++i) {
            if (diamond.getRealOrder(address(vault), i).isOpen) ++open;
        }
        if (open == 0) return (false, o);
        uint256 want = k % open;
        for (uint32 i; i < n; ++i) {
            o = diamond.getRealOrder(address(vault), i);
            if (!o.isOpen) continue;
            if (want == 0) return (true, o);
            --want;
        }
    }

    function _fillAll() internal {
        uint32 n = diamond.orderCount(address(vault));
        for (uint32 i; i < n; ++i) {
            IGainsDiamond.PendingOrder memory o = diamond.getRealOrder(address(vault), i);
            if (!o.isOpen) continue;
            if (o.orderType >= 2 && o.orderType <= 6) {
                try diamond.resolveTrigger(address(vault), i, _px(o.trade.pairIndex), true) {} catch {}
            } else {
                uint16 pair = o.orderType == 0 ? o.trade.pairIndex : diamond.getTrade(address(vault), o.trade.index).pairIndex;
                try diamond.fill(address(vault), i, _px(pair)) {
                    nFills++;
                } catch {}
            }
        }
    }

    // ------------------------------------------------------------------ claim expectation (independent of the lens)
    struct Exp {
        bool settled;
        bool carried;
        uint256 e; // the request's epoch (redemption part)
        uint256 pe; // the epoch that priced the deposit part
        uint256 depShares;
        uint256 refund;
        uint256 redAssets;
        uint256 retShares;
    }

    function _expect(address a) internal view returns (Exp memory x) {
        (uint256 e, uint256 dA, uint256 rS) = vault.requests(a);
        if (e >= vault.currentEpoch() || (dA == 0 && rS == 0)) return x;
        x.settled = true;
        x.e = e;
        x.pe = e;
        if (dA > 0) {
            (uint256 cf, uint256 pi) = vault.carry(e);
            if (cf != 0) {
                if (pi == 0) x.carried = true;
                else x.pe = pi - 1;
            }
            if (!x.carried) {
                (uint256 pAssets, uint256 pShares,,,,,,) = vault.epochs(x.pe);
                if (pAssets == 0) {
                    // nothing recorded for a deposit that sat in this epoch's queue: the request would vanish
                    x.depShares = type(uint128).max; // flagged by _book
                } else if (pShares == 0) {
                    x.refund = dA;
                } else {
                    x.depShares = dA.mulDiv(pShares, pAssets);
                }
            }
        }
        if (rS > 0) {
            (,, uint256 eShares, uint256 eAssets, uint256 eBurned,,,) = vault.epochs(e);
            if (eShares == 0) {
                x.redAssets = type(uint128).max; // flagged by _book
            } else {
                x.redAssets = rS.mulDiv(eAssets, eShares);
                uint256 burnedForMe = rS.mulDiv(eBurned, eShares, Math.Rounding.Ceil);
                if (burnedForMe < rS) x.retShares = rS - burnedForMe;
            }
        }
    }

    /// @dev Books a delivery of `received` USDC and `shares` shares to `a` against the expectation computed before the
    ///      call that triggered it.
    function _book(Exp memory x, uint256 received, uint256 shares) internal {
        if (!x.settled) {
            if (received != 0 || shares != 0) vClaimOver++;
            return;
        }
        if (x.depShares == type(uint128).max || x.redAssets == type(uint128).max) {
            vLostRequest++;
            return;
        }
        uint256 exp = x.refund + x.redAssets;
        if (received > exp) vClaimOver++;
        else if (received < exp) vClaimShortWei += exp - received;
        if (shares != x.depShares + x.retShares) {
            if (shares > x.depShares + x.retShares) vClaimOver++;
            else vClaimShortWei += 1;
        }
        gClaims += received;
        nClaims++;
        if (x.redAssets > 0 || x.retShares > 0) {
            claimedRed[x.e] += x.redAssets;
            returnedShares[x.e] += x.retShares;
            (,, uint256 eShares, uint256 eAssets, uint256 eBurned,,,) = vault.epochs(x.e);
            if (claimedRed[x.e] > eAssets) vEpochOverpaid++;
            if (returnedShares[x.e] > eShares - eBurned) vReturnedOver++;
        }
        if (x.depShares > 0 || x.refund > 0) {
            claimedDepShares[x.pe] += x.depShares;
            refundedDep[x.pe] += x.refund;
            (uint256 pAssets, uint256 pShares,,,,,,) = vault.epochs(x.pe);
            if (claimedDepShares[x.pe] > pShares) vDepSharesOver++;
            if (refundedDep[x.pe] > pAssets) vRefundOver++;
        }
    }

    // ------------------------------------------------------------------ flow snapshot: a depositor flow never moves
    // idle USDC, the share supply or the venue (reserves never cross-subsidise the holders, or the other way round)
    struct Flow {
        uint256 idle;
        uint256 supply;
        uint256 toD;
        uint256 fromD;
        uint256 paidA; // USDC paid to the controller so far
        uint256 sharesA;
        uint256 escrow; // vault's own share balance
    }

    function _flow(address a) internal view returns (Flow memory f) {
        f.idle = idleNow();
        f.supply = vault.totalSupply();
        f.toD = usdc.toDiamond();
        f.fromD = usdc.fromDiamond();
        f.paidA = usdc.paidTo(a);
        f.sharesA = vault.balanceOf(a);
        f.escrow = vault.balanceOf(address(vault));
    }

    function _flowUnchanged(Flow memory f, uint256 idleDelta) internal {
        if (idleNow() != f.idle + idleDelta || vault.totalSupply() != f.supply || usdc.toDiamond() != f.toD || usdc.fromDiamond() != f.fromD) {
            vFlowMovedHolders++;
        }
    }

    // ================================================================== starting state (setUp only)
    /// @dev Three depositors in, settled and claimed; an ETH long and a BTC short open on the diamond.
    function seed() external {
        vm.prank(actors[0]);
        vault.requestDeposit(400_000e6, actors[0]);
        vm.prank(actors[1]);
        vault.requestDeposit(200_000e6, actors[1]);
        vm.prank(actors[3]);
        vault.requestDeposit(100_000e6, actors[3]);
        gDeposits += 700_000e6;
        _skip(1 hours);
        vm.prank(K);
        vault.checkRisk();
        _settleAs(M);
        for (uint256 i; i < 4; ++i) {
            Exp memory x = _expect(actors[i]);
            Flow memory f = _flow(actors[i]);
            if (!x.settled) continue;
            usdc.expect(actors[i]);
            vault.claim(actors[i]);
            _book(x, usdc.paidTo(actors[i]) - f.paidA, vault.balanceOf(actors[i]) - f.sharesA);
        }
        usdc.expect(address(0));
        uint256 toD0 = usdc.toDiamond();
        uint256 el0 = diamond.escrowLedger(address(vault));
        vm.prank(M);
        vault.openTrade(OpenParams(1, true, 80_000e6, 3_000, ethPx, 1_000, 0, 0, 0));
        _pulled(toD0, el0, 80_000e6);
        toD0 = usdc.toDiamond();
        el0 = diamond.escrowLedger(address(vault));
        vm.prank(A);
        vault.openTrade(OpenParams(0, false, 100_000e6, 2_000, btcPx, 1_000, 0, 0, 0));
        _pulled(toD0, el0, 100_000e6);
        _fillAll();
        vm.prank(K);
        vault.checkRisk();
    }

    // ================================================================== depositor flows
    function deposit(uint256 who, uint256 payerSeed, uint256 amt) external {
        address c = actors[who % 5];
        address payer = payerSeed % 5 == 0 ? actors[(payerSeed / 5) % 5] : c;
        amt = bound(amt, 10e6, 300_000e6);
        Exp memory x = _expect(c);
        Flow memory f = _flow(c);
        usdc.expect(c);
        vm.prank(payer);
        try vault.requestDeposit(amt, c) {
            nDeposits++;
            gDeposits += amt;
            _book(x, usdc.paidTo(c) - f.paidA, vault.balanceOf(c) - f.sharesA);
            _flowUnchanged(f, 0);
        } catch {}
        usdc.expect(address(0));
    }

    function redeem(uint256 who, uint256 pct) external {
        address a = actors[who % 5];
        uint256 sh = (vault.balanceOf(a) * bound(pct, 1, 100)) / 100;
        if (sh == 0) return;
        Exp memory x = _expect(a);
        Flow memory f = _flow(a);
        uint256 pend0 = vault.pendingRedeemShares();
        usdc.expect(a);
        vm.prank(a);
        try vault.requestRedeem(sh, a, a) {
            nRedeems++;
            uint256 got = x.depShares + x.retShares;
            if (vault.pendingRedeemShares() != pend0 + sh || vault.balanceOf(address(vault)) + got != f.escrow + sh) vRedeemSharesMoved++;
            if (vault.balanceOf(a) + sh < f.sharesA) vRedeemSharesMoved++;
            else _book(x, usdc.paidTo(a) - f.paidA, vault.balanceOf(a) + sh - f.sharesA);
            _flowUnchanged(f, 0);
        } catch {}
        usdc.expect(address(0));
    }

    function cancelDeposit(uint256 who) external {
        address a = actors[who % 5];
        (, uint256 dA,) = vault.requests(a);
        Flow memory f = _flow(a);
        usdc.expect(a);
        vm.prank(a);
        try vault.cancelDepositRequest() {
            nCancels++;
            uint256 got = usdc.paidTo(a) - f.paidA;
            if (got != dA) vCancelInexact++;
            gRefunds += got;
            _flowUnchanged(f, 0);
        } catch {}
        usdc.expect(address(0));
    }

    function cancelRedeem(uint256 who) external {
        address a = actors[who % 5];
        (uint256 e,, uint256 rS) = vault.requests(a);
        bool current = e == vault.currentEpoch();
        Flow memory f = _flow(a);
        usdc.expect(a);
        vm.prank(a);
        try vault.cancelRedeemRequest() {
            nCancels++;
            uint256 back = vault.balanceOf(a) - f.sharesA;
            if (!current || back != rS) vCancelInexact++;
            _flowUnchanged(f, 0);
        } catch {}
        usdc.expect(address(0));
    }

    function claim(uint256 who, bool byStranger) external {
        address a = actors[who % 5];
        Exp memory x = _expect(a);
        Flow memory f = _flow(a);
        uint256 xPaid0 = usdc.paidTo(X);
        usdc.expect(a);
        vm.prank(byStranger ? X : a);
        try vault.claim(a) {
            if (byStranger) nClaimsByStranger++;
            _book(x, usdc.paidTo(a) - f.paidA, vault.balanceOf(a) - f.sharesA);
            if (byStranger && usdc.paidTo(X) != xPaid0) vClaimOver++;
            _flowUnchanged(f, 0);
        } catch {}
        usdc.expect(address(0));
    }

    /// @dev A stranger sends USDC straight to the vault: it is idle USDC, i.e. the holders'.
    function donate(uint256 amt) external {
        amt = bound(amt, 1, 50_000e6);
        Flow memory f = _flow(X);
        vm.prank(X);
        usdc.transfer(address(vault), amt);
        gDonations += amt;
        nDonations++;
        _flowUnchanged(f, amt);
    }

    // ================================================================== settle (every role, every mode)
    struct Pre {
        uint256 supply;
        uint256 idle;
        uint256 bal;
        uint256 pendDep;
        uint256 redShares;
        uint256 cp;
        uint256 hwm;
        uint16 mgmt;
        uint16 perf;
        uint16 protoBps;
        uint64 lastAcc;
        bool breached;
        bool emergency;
        bool exitOnly;
        bool redemptionOnly;
        uint256 cap; // fix round WP2 (GR2-KEY-06): what an exit-only or redemption-only settle pays at most
        uint256 mBal;
        uint256 tBal;
        uint256 epoch;
        CIValuer.Venue v;
    }

    function settle(uint256 role, uint256 prep) external {
        // 3 in 4: the oracle answers what is pending and the keeper frees USDC first (the platform's routine);
        // 1 in 4: settle as things stand (orders in flight, redemptions possibly unfunded)
        if (prep % 4 != 0) {
            _fillAll();
            _operatorFund();
        }
        if (prep % 8 != 1) {
            uint256 ready = uint256(vault.epochStartedAt()) + 1 hours;
            if (_now() < ready) _skip(ready - _now());
        }
        _skip(bound(prep >> 8, 1, 2 hours));
        if (prep % 3 == 0) {
            vm.prank(K);
            try vault.checkRisk() {} catch {}
        }
        address who = [M, K, G, M, K, S][role % 6]; // treasury 2 in 3, platform roles 1 in 3
        _settleAs(who);
        // the guardian's routine: once an emergency settle has paid every redeemer in full, end the emergency
        if (vault.emergency()) {
            vm.prank(G);
            try vault.exitEmergency() {} catch {}
        } else if (vault.breached() && vault.breachReason() == BreachReason.GUARDIAN) {
            vm.prank(G);
            try vault.clearBreach() {} catch {}
        }
    }

    /// @dev The keeper's routine settle (a second selector, so settles get twice the weight of other actions).
    function settleKeeper(uint256 prep) external {
        if (prep % 4 != 0) {
            _fillAll();
            _operatorFund();
        }
        uint256 ready = uint256(vault.epochStartedAt()) + 1 hours;
        if (_now() < ready) _skip(ready - _now());
        _skip(bound(prep >> 8, 1, 30 minutes));
        vm.prank(K);
        try vault.checkRisk() {} catch {}
        _settleAs(K);
    }

    /// @dev The keeper reduces trades (within its cap) to free USDC for the queued redemptions, as the platform does.
    function _operatorFund() internal {
        uint256 short = vault.redemptionShortfall();
        if (short == 0) return;
        IGainsDiamond.Trade[] memory t = diamond.getTrades(address(vault));
        for (uint256 i; i < t.length && vault.redemptionShortfall() > 0; ++i) {
            if (t[i].tradeType != 0 || t[i].collateralAmount < 2) continue;
            uint256 amt = vault.redemptionShortfall();
            if (amt >= t[i].collateralAmount) amt = t[i].collateralAmount - 1;
            vm.prank(K);
            try vault.reduceTrade(t[i].index, uint120(amt), 0, _px(t[i].pairIndex)) {
                nReduces++;
            } catch {}
            _fillAll();
        }
    }

    function _pre(address who) internal view returns (Pre memory p) {
        p.supply = vault.totalSupply();
        p.idle = idleNow();
        p.bal = usdc.balanceOf(address(vault));
        p.pendDep = vault.pendingDepositAssets();
        p.redShares = vault.pendingRedeemShares();
        p.cp = vault.checkpointNav();
        p.hwm = vault.highWaterMark();
        p.mgmt = vault.managementFeeBps();
        p.perf = vault.performanceFeeBps();
        p.protoBps = vault.protocolShareBps();
        p.lastAcc = vault.lastFeeAccrual();
        p.breached = vault.breached();
        p.emergency = vault.emergency();
        BreachReason r = vault.breachReason();
        p.redemptionOnly = !p.emergency && p.breached && (r == BreachReason.DAILY_LOSS || r == BreachReason.DRAWDOWN);
        bool treasury = who == M || (who == K && vault.operator() == K);
        p.exitOnly = p.emergency || (!treasury && !p.redemptionOnly);
        p.mBal = vault.balanceOf(M);
        p.tBal = vault.balanceOf(T);
        p.epoch = vault.currentEpoch();
        p.v = venueNow();
        // fix round WP2 (GR2-KEY-06): the cap is the checkpoint the settle would ratchet to; when it does not move, the
        // checkpoint, or the one the last ratchet replaced if that was higher (never in a loss breach). Never above NAV.
        uint256 nav = p.idle + p.v.adv;
        p.cap = nav;
        if (p.cp > 0) {
            (uint256 next, bool moves) = vault.policy().nextCheckpoint(p.cp, vault.checkpointAt(), nav, false);
            uint256 c = next;
            if (!moves) {
                c = p.cp;
                uint256 prior = vault.priorCheckpointNav();
                if (!p.redemptionOnly && prior > p.cp) c = prior;
            }
            if (c < nav) p.cap = c;
        }
    }

    function _settleAs(address who) internal {
        Pre memory p = _pre(who);
        uint256 redeemers;
        for (uint256 i; i < 5; ++i) {
            (uint256 e,, uint256 rS) = vault.requests(actors[i]);
            if (e == p.epoch && rS > 0) ++redeemers;
        }
        vm.prank(who);
        try vault.settle() {
            nSettles++;
            if (p.exitOnly) nSettleExitOnly++;
            else if (p.redemptionOnly) nSettleRedemptionOnly++;
            else nSettleNormal++;
            dustBound += redeemers + 1;
            if (p.v.heldOrders > 0) vS1HeldInFlight++;
            _checkSettle(p);
        } catch (bytes memory err) {
            bytes4 sel = err.length >= 4 ? bytes4(err) : bytes4(0);
            settleErr[sel]++;
        }
    }

    mapping(bytes4 => uint256) public settleErr;

    function _checkSettle(Pre memory p) internal {
        (uint256 dAssets, uint256 dShares, uint256 rShares, uint256 paid, uint256 burned,,,) = vault.epochs(p.epoch);
        uint256 s1 = vault.totalSupply();
        // fee shares minted by this settle's accrual (deposits are minted to the vault, redemptions burned from it)
        if (s1 + burned < p.supply + dShares) {
            vFeeRecipient++;
            return;
        }
        uint256 fee = s1 + burned - p.supply - dShares;
        uint256 s0f = p.supply + fee;
        // fix round WP2 (GR2-ECON-03, XF-01): the performance fee is charged in every settle that prices deposits
        _checkFees(p, fee, !p.exitOnly && !p.redemptionOnly);
        if (dShares > 0) nSettleWithDeposits++;
        if (p.v.mid != p.v.adv) nSettleWithOpenTrades++;
        if (burned < rShares) nSettlePartial++;

        // F1d: deposits mint at max(adverse NAV, idle + favourable venue), both independent
        uint256 nav = p.idle + p.v.adv;
        uint256 depIn = (p.exitOnly || p.redemptionOnly) ? 0 : p.pendDep;
        uint256 expShares = _toShares(depIn, Math.max(nav, p.idle + p.v.fav), s0f);
        if (expShares == 0) depIn = 0;
        if (dShares != expShares || dAssets != (p.redemptionOnly ? 0 : p.pendDep)) vF1dDepositPrice++;

        // F1r: redemptions paid at the adverse NAV (min the redemption cap in a redemption-only or exit-only settle,
        // GR2-KEY-06), partial fill only in emergency, pro rata to the USDC on hand
        uint256 priceNav = nav;
        if (p.exitOnly || p.redemptionOnly) priceNav = p.cap;
        uint256 redAssets = _toAssets(p.redShares, priceNav, s0f);
        uint256 avail = p.idle + depIn;
        uint256 expPaid = redAssets;
        uint256 expBurned = p.redShares;
        if (avail < redAssets) {
            expPaid = avail;
            expBurned = p.redShares.mulDiv(avail, redAssets);
        }
        if (rShares != p.redShares || paid != expPaid || burned != expBurned) vF1rRedeemPrice++;

        // F1: the continuing holders' fair value per share (Chainlink mid, after the fee dilution) never falls. Exact;
        // a partial fill may favour the redeemers by less than one share unit (burned rounds down).
        if (p.supply > 0) {
            uint256 v0 = p.idle + p.v.mid;
            uint256 v1 = idleNow() + p.v.mid; // the settle does not touch the venue
            uint256 lhs = (v1 + 1) * (s0f + OFF);
            uint256 rhs = (v0 + 1) * (s1 + OFF);
            uint256 tol = burned < rShares ? v0 + 1 : 0;
            if (lhs + tol < rhs) vF1HolderDiluted++;
        }
    }

    /// @dev F3: fee shares minted at the NAV just read are worth at most the configured fee: management fee pro rata
    ///      time, plus (with performance) the performance fee on the gain above the high water mark; the protocol
    ///      takes at most protocolShareBps of them; nobody but the fee recipient and the protocol recipient gets any.
    function _checkFees(Pre memory p, uint256 fee, bool withPerf) internal {
        if (p.mgmt > 500 || p.perf > 3_000 || p.protoBps > 5_000) vFeeConfig++;
        uint256 a = p.idle + p.v.adv;
        uint256 cap;
        if (p.supply > 0 && a > 0) {
            cap = a.mulDiv(uint256(p.mgmt) * (_now() - p.lastAcc), BPS * YEAR);
            uint256 price = (a + 1).mulDiv(ONE, p.supply + OFF);
            if (withPerf && price > p.hwm) cap += (price - p.hwm).mulDiv(p.supply, ONE).mulDiv(p.perf, BPS);
        }
        if (fee > 0) {
            nFeeMints++;
            if (fee * (a + 1) > (cap + 1) * (p.supply + fee + OFF)) vFeeAboveCap++;
        }
        uint256 proto = vault.balanceOf(T) - p.tBal;
        if (proto * BPS > fee * p.protoBps) vProtocolShare++;
        if (vault.balanceOf(M) != p.mBal + fee - proto) vFeeRecipient++;
    }

    // ================================================================== fees outside settle
    function accrue(uint256 dt, bool byStranger) external {
        _skip(bound(dt, 1 minutes, 3 hours));
        Pre memory p = _pre(X);
        vm.prank(byStranger ? X : K);
        try vault.accrueFees() {
            _checkFees(p, vault.totalSupply() - p.supply, false);
        } catch {}
    }

    /// @dev Fee changes: a raise through the timelock (queue, wait, execute by anyone), or an instant lowerFees.
    function feeGov(uint256 m, uint256 perf, uint256 mode) external {
        uint16 mg = uint16(bound(m, 0, 500));
        uint16 pf = uint16(bound(perf, 0, 3_000));
        if (mode % 2 == 0) {
            bytes memory data = abi.encodeCall(GainsVault.setFees, (mg, pf));
            vm.prank(M);
            try vault.queue(data) {} catch {
                return;
            }
            _skip(2 days);
            Pre memory p = _pre(X);
            vm.prank(X);
            try vault.execute(data) {
                _checkFees(p, vault.totalSupply() - p.supply, false);
            } catch {}
        } else {
            uint16 cm = vault.managementFeeBps();
            uint16 cp = vault.performanceFeeBps();
            mg = uint16(bound(m, 0, cm));
            pf = uint16(bound(perf, 0, cp));
            Pre memory p = _pre(X);
            vm.prank(M);
            try vault.lowerFees(mg, pf) {
                _checkFees(p, vault.totalSupply() - p.supply, false);
            } catch {}
        }
    }

    // ================================================================== trading (manager or agent)
    function _trader(bool agent) internal view returns (address) {
        return agent ? A : M;
    }

    function _pulled(uint256 toD0, uint256 escrowLedger0, uint256 expected) internal {
        gExpectedPull += expected;
        if (usdc.toDiamond() - toD0 != expected || diamond.escrowLedger(address(vault)) < escrowLedger0 + expected) vCollateral++;
    }

    function openTrade(bool agent, bool btc, bool long, uint256 pct, uint256 lev, uint256 kind, uint256 outcome) external {
        uint16 pair = btc ? 0 : 1;
        uint256 idle = idleNow();
        uint24 leverage = uint24(bound(lev, 1_100, 25_000));
        uint256 c = (idle * bound(pct, 1, 40)) / 100;
        uint256 maxC = (240_000e6 * 1e3) / leverage; // policy maxOrderNotional 250k
        if (c > maxC) c = maxC;
        if (c < 1e6) c = 1e6;
        uint120 coll = uint120(c);
        uint8 tt = uint8(kind % 4 == 3 ? 0 : kind % 4);
        uint64 px = _px(pair);
        uint64 ep = px;
        if (tt == 1) ep = long ? (px * 99) / 100 : (px * 101) / 100;
        if (tt == 2) ep = long ? (px * 101) / 100 : (px * 99) / 100;
        uint64 tp;
        uint64 sl;
        if ((kind >> 4) % 3 == 0) {
            tp = long ? (px * 105) / 100 : (px * 95) / 100;
            sl = long ? (px * 95) / 100 : (px * 105) / 100;
        }
        OpenParams memory p = OpenParams(pair, long, coll, leverage, ep, 1_000, tp, sl, tt);
        uint256 toD0 = usdc.toDiamond();
        uint256 el0 = diamond.escrowLedger(address(vault));
        vm.prank(_trader(agent));
        try vault.openTrade(p) {
            nOpens++;
            _pulled(toD0, el0, coll);
            if (tt == 0) {
                uint32 o = diamond.orderCount(address(vault)) - 1;
                uint256 w_ = outcome % 8;
                if (w_ >= 3 && w_ <= 6) {
                    // Gains fills within its slippage (here: within 0.5% of Chainlink)
                    int256 dev = int256(bound(outcome >> 8, 0, 100)) - 50;
                    uint64 fpx = uint64(uint256(int256(uint256(px)) + (int256(uint256(px)) * dev) / 10_000));
                    try diamond.fill(address(vault), o, fpx) {
                        nFills++;
                    } catch {}
                } else if (w_ == 7) {
                    try diamond.cancelInCallback(address(vault), o) {
                        nCallbackCancels++;
                    } catch {}
                }
                // 0..2: left pending (Gains delays)
            }
        } catch {}
    }

    function increaseTrade(bool agent, uint256 k, uint256 pct, uint256 levDelta, bool levOnly) external {
        (bool ok, IGainsDiamond.Trade memory t) = _trade(k);
        if (!ok || t.tradeType != 0) return;
        uint24 ld = uint24(bound(levDelta, 100, 5_000));
        uint256 c = levOnly ? 0 : (idleNow() * bound(pct, 1, 20)) / 100;
        if (c * ld > 240_000e6 * 1e3) c = (240_000e6 * 1e3) / ld;
        uint120 coll = uint120(c);
        uint256 toD0 = usdc.toDiamond();
        uint256 el0 = diamond.escrowLedger(address(vault));
        vm.prank(_trader(agent));
        try vault.increaseTrade(t.index, coll, ld, _px(t.pairIndex), 1_000) {
            _pulled(toD0, el0, coll);
        } catch {}
    }

    function updateLeverage(bool agent, uint256 k, uint256 lev) external {
        (bool ok, IGainsDiamond.Trade memory t) = _trade(k);
        if (!ok || t.tradeType != 0) return;
        uint24 nl = uint24(bound(lev, 1_100, 25_000));
        if (nl == t.leverage) return;
        uint256 delta = nl < t.leverage ? (uint256(t.collateralAmount) * t.leverage) / nl - t.collateralAmount : 0;
        uint256 toD0 = usdc.toDiamond();
        uint256 el0 = diamond.escrowLedger(address(vault));
        vm.prank(_trader(agent));
        try vault.updateLeverage(t.index, nl) {
            _pulled(toD0, el0, delta);
        } catch {}
    }

    /// @dev Exits by every role (the vault decides who may); a stranger is always refused.
    function close(uint256 k, uint256 role, bool reduce, uint256 pct) external {
        (bool ok, IGainsDiamond.Trade memory t) = _trade(k);
        if (!ok || t.tradeType != 0) return;
        address who = [M, A, G, S, K, X][role % 6];
        uint64 px = _px(t.pairIndex);
        if (reduce) {
            uint120 d = uint120((uint256(t.collateralAmount) * bound(pct, 1, 90)) / 100);
            if (d == 0) return;
            vm.prank(who);
            try vault.reduceTrade(t.index, d, 0, px) {
                nReduces++;
            } catch {}
        } else {
            vm.prank(who);
            try vault.closeTrade(t.index, px) {
                nCloses++;
            } catch {}
        }
    }

    function slTp(bool agent, uint256 k, uint256 sl, uint256 tp) external {
        (bool ok, IGainsDiamond.Trade memory t) = _trade(k);
        if (!ok || t.tradeType != 0) return;
        uint64 px = _px(t.pairIndex);
        uint64 s = uint64((uint256(px) * bound(sl, 80, 99)) / 100);
        uint64 p = uint64((uint256(px) * bound(tp, 101, 130)) / 100);
        if (!t.long) (s, p) = (uint64((uint256(px) * 200) / 100) - s, uint64((uint256(px) * 200) / 100) - p);
        vm.prank(agent ? A : (sl % 3 == 0 ? S : M));
        try vault.setSlTp(t.index, s, p) {} catch {}
    }

    function cancelResting(uint256 k, uint256 role) external {
        (bool ok, IGainsDiamond.Trade memory t) = _trade(k);
        if (!ok || t.tradeType == 0) return;
        vm.prank([M, A, S][role % 3]);
        try vault.cancelOrder(t.index) {} catch {}
    }

    /// @dev Anyone cancels a market order Gains did not answer within its timeout.
    function cancelTimedOut(uint256 k, bool roll) external {
        if (roll) vm.roll(_blk() + 201);
        (bool ok, IGainsDiamond.PendingOrder memory o) = _order(k);
        if (!ok) return;
        vm.prank(X);
        try vault.cancelTimedOut(o.index) {
            nTimeouts++;
        } catch {}
    }

    function flatten(bool btc, uint256 role, bool indices) external {
        address who = [M, G, S, K][role % 4];
        uint16 pair = btc ? 0 : 1;
        if (indices) {
            IGainsDiamond.Trade[] memory t = diamond.getTrades(address(vault));
            if (t.length == 0) return;
            uint32[] memory idx = new uint32[](t.length);
            for (uint256 i; i < t.length; ++i) {
                idx[i] = t[i].index;
            }
            vm.prank(who);
            try vault.flattenIndices(idx, 0, _px(pair)) {} catch {}
        } else {
            vm.prank(who);
            try vault.flatten(pair, 0, _px(pair), type(uint256).max) {} catch {}
        }
    }

    function operatorReduce(uint256 k, uint256 amt) external {
        (bool ok, IGainsDiamond.Trade memory t) = _trade(k);
        if (!ok || t.tradeType != 0 || t.collateralAmount < 2) return;
        uint120 d = uint120(bound(amt, 1, t.collateralAmount - 1));
        uint64 px = _px(t.pairIndex);
        vm.prank(K);
        try vault.reduceTrade(t.index, d, 0, px) {
            nReduces++;
        } catch {}
    }

    // ================================================================== Gains side (the mock decides the P&L)
    function gFill(uint256 k, uint256 devSeed) external {
        (bool ok, IGainsDiamond.PendingOrder memory o) = _order(k);
        if (!ok) return;
        if (o.orderType >= 2 && o.orderType <= 6) {
            try diamond.resolveTrigger(address(vault), o.index, _px(o.trade.pairIndex), devSeed % 4 != 0) {
                nTriggers++;
            } catch {}
            return;
        }
        uint16 pair = o.orderType == 0 ? o.trade.pairIndex : diamond.getTrade(address(vault), o.trade.index).pairIndex;
        int256 dev = int256(bound(devSeed, 0, 100)) - 50;
        uint64 px = _px(pair);
        uint64 fpx = uint64(uint256(int256(uint256(px)) + (int256(uint256(px)) * dev) / 10_000));
        try diamond.fill(address(vault), o.index, fpx) {
            nFills++;
        } catch {}
    }

    function gCallbackCancel(uint256 k) external {
        (bool ok, IGainsDiamond.PendingOrder memory o) = _order(k);
        if (!ok) return;
        try diamond.cancelInCallback(address(vault), o.index) {
            nCallbackCancels++;
        } catch {}
    }

    function gFillAll() external {
        _fillAll();
    }

    /// @dev Gains' own executions: TP, SL, liquidation (only when the trade is past its liquidation price), limit /
    ///      stop opens; either at once or filed as a pending trigger order that holds nothing (resolved by gFill).
    function gTrigger(uint256 k, uint256 kind, bool file) external {
        (bool ok, IGainsDiamond.Trade memory t) = _trade(k);
        if (!ok) return;
        uint64 px = _px(t.pairIndex);
        if (t.tradeType != 0) {
            if (file) {
                try diamond.fileTrigger(address(vault), t.index, t.tradeType == 1 ? 2 : 3) {} catch {}
            } else {
                try diamond.executeLimit(address(vault), t.index, px) {
                    nTriggers++;
                } catch {}
            }
            return;
        }
        uint8 tt = uint8(4 + (kind % 3)); // TP, SL, LIQ
        if (tt == 6 && diamond.closeValue(address(vault), t.index, px) != 0) return;
        if (file) {
            try diamond.fileTrigger(address(vault), t.index, tt) {} catch {}
        } else {
            try diamond.trigger(address(vault), t.index, px) {
                if (tt == 6) nLiquidations++;
                else nTriggers++;
            } catch {}
        }
    }

    /// @dev Gains reports a pending order that holds collateral under a type the vault does not know (GV-02).
    function gRetype(uint256 k, uint256 tSeed) external {
        (bool ok, IGainsDiamond.PendingOrder memory o) = _order(k);
        if (!ok || diamond.heldBy(address(vault), o.index) == 0) return;
        uint8[5] memory types = [uint8(10), 11, 12, 13, 200];
        try diamond.retype(address(vault), o.index, types[tSeed % 5]) {
            nRetypes++;
        } catch {}
    }

    function gRestore(uint256 k) external {
        (bool ok, IGainsDiamond.PendingOrder memory o) = _order(k);
        if (!ok) return;
        diamond.restoreType(address(vault), o.index);
    }

    function gFees(bool btc, uint256 feeP, uint256 spread, uint256 gov) external {
        diamond.setPair(btc ? 0 : 1, bound(feeP, 0, 1e9), 285.7e18, 0.1e18, bound(spread, 0, 5e7));
        diamond.setGovFeeP(uint24(bound(gov, 0, 100_000)));
    }

    function gHolding(uint256 k, int256 amt) external {
        (bool ok, IGainsDiamond.Trade memory t) = _trade(k);
        if (!ok || t.tradeType != 0) return;
        amt = bound(amt, -int256(uint256(t.collateralAmount) / 20), int256(uint256(t.collateralAmount) / 20));
        diamond.setHolding(address(vault), t.index, diamond.holding(address(vault), t.index) + amt);
    }

    // ================================================================== market and time
    function move(bool btc, int256 bps) external {
        bps = bound(bps, -400, 400);
        if (btc) btcPx = uint64(uint256(int256(uint256(btcPx)) + (int256(uint256(btcPx)) * bps) / 10_000));
        else ethPx = uint64(uint256(int256(uint256(ethPx)) + (int256(uint256(ethPx)) * bps) / 10_000));
        btcPx = (btcPx / 100) * 100;
        ethPx = (ethPx / 100) * 100;
        _fresh();
    }

    function crash(uint256 what) external {
        if (what % 16 != 0) return;
        bool up = (what >> 8) % 2 == 0;
        bool big = (what >> 24) % 3 == 0; // 35% instead of 18%: liquidations and loss breaches
        uint256 f = up ? (big ? 135 : 118) : (big ? 65 : 82);
        if ((what >> 16) % 2 == 0) btcPx = uint64(((uint256(btcPx) * f) / 100 / 100) * 100);
        else ethPx = uint64(((uint256(ethPx) * f) / 100 / 100) * 100);
        _fresh();
    }

    /// @dev Both seed trades go against the vault at once (ETH -35%, BTC +35%): a loss breach, so the next settles are
    ///      redemption-only, and trades at or past liquidation.
    function stress(uint256 what) external {
        if (what % 4 != 0) return;
        ethPx = uint64(((uint256(ethPx) * 65) / 100 / 100) * 100);
        btcPx = uint64(((uint256(btcPx) * 135) / 100 / 100) * 100);
        _fresh();
        vm.prank(K);
        try vault.checkRisk() {} catch {}
    }

    /// @dev A bank run: three holders redeem everything, the guardian (or the owner) triggers the emergency and an
    ///      exit-only settle runs on the USDC at hand, without the keeper freeing any first (partial fill + return).
    function bankRun(uint256 what) external {
        if (what % 10 != 0) return;
        uint256[3] memory who = [uint256(0), 1, 3];
        for (uint256 i; i < 3; ++i) {
            address a = actors[who[i]];
            uint256 sh = vault.balanceOf(a);
            (uint256 e, uint256 dA,) = vault.requests(a);
            if (sh == 0 || dA > 0 || e > vault.currentEpoch()) continue;
            Exp memory x = _expect(a);
            if (x.settled) continue; // keep the claim accounting in redeem()/claim()
            vm.prank(a);
            try vault.requestRedeem(sh, a, a) {
                nRedeems++;
            } catch {}
        }
        vm.prank((what >> 8) % 2 == 0 ? G : M);
        try vault.triggerEmergency() {
            nEmergencies++;
        } catch {}
        _skip(10 minutes);
        _settleAs(G);
    }

    function wait(uint256 secs) external {
        _skip(bound(secs, 1, 2 hours));
    }

    // ================================================================== risk and governance
    function check(bool clearLev) external {
        vm.prank(X);
        try vault.checkRisk() {} catch {}
        if (clearLev) {
            _skip(16 minutes);
            vm.prank(X);
            try vault.clearLeverageBreach() {} catch {}
        }
    }

    function govern(uint256 w_) external {
        uint256 k = w_ % 40;
        if (k == 0) {
            if ((w_ >> 16) % 3 != 0) return; // full stops are rare (each one revokes the agent)
            vm.prank([S, G, M][(w_ >> 8) % 3]);
            try vault.triggerBreach() {} catch {}
        } else if (k == 1) {
            vm.prank([G, M][(w_ >> 8) % 2]);
            try vault.triggerEmergency() {
                nEmergencies++;
            } catch {}
        } else if (k == 2 || k == 3 || k == 4) {
            vm.prank(G);
            try vault.clearBreach() {} catch {}
            vm.prank(G);
            try vault.exitEmergency() {} catch {}
        } else if (k == 5) {
            _skip(1 days);
            vm.prank(M);
            try vault.resume() {} catch {}
        } else if (k == 6) {
            vm.prank([S, G, M][(w_ >> 8) % 3]);
            try vault.setDepositsPaused(true) {} catch {}
        } else if (k == 7 || k == 8) {
            vm.prank(G);
            try vault.setDepositsPaused(false) {} catch {}
            vm.prank(G);
            try vault.setTradingPaused(false) {} catch {}
        } else if (k == 9) {
            // an overdue epoch with redemptions waiting: anyone may trigger the emergency
            vm.prank(X);
            try vault.triggerEmergency() {
                nEmergencies++;
            } catch {}
        } else if (k == 10 && vault.agent() == address(0)) {
            // the owner binds the platform agent again after a full stop (timelocked)
            bytes memory data = abi.encodeCall(GainsVault.setAgent, (A));
            vm.prank(M);
            try vault.queue(data) {} catch {
                return;
            }
            _skip(2 days);
            vm.prank(X);
            try vault.execute(data) {} catch {}
        }
    }
}
