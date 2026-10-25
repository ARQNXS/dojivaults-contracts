// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {GainsVault} from "../../../../../src/gains/GainsVault.sol";
import {GainsVaultLens} from "../../../../../src/gains/GainsVaultLens.sol";
import {GainsVaultPolicy} from "../../../../../src/gains/GainsVaultPolicy.sol";
import {GainsVaultFactory} from "../../../../../src/gains/GainsVaultFactory.sol";
import {IGainsDiamond} from "../../../../../src/gains/IGainsDiamond.sol";
import {InitParams, OpenParams} from "../../../../../src/gains/GainsTypes.sol";
import {MockUSDC} from "../../../../mocks/Mocks.sol";
import {MockGainsDiamond, MockChainlinkFeed} from "../../../../gains/mocks/GainsMocks.sol";

/// @dev Medusa / Echidna property harness for the core accounting (deposit / redeem / settle / claim / fees, plus
///      market trades that fill at the Chainlink price and price moves). Self-contained: the constructor deploys
///      the mocks, a factory (curation + price source), one standalone vault clone and its policy, exactly as
///      test/gains/GainsBase.t.sol does. Uses the hevm cheatcodes (prank, warp, roll) Medusa supports.
///      Properties: property_* (Medusa property mode) and assertion checks inside the actions (assertion mode).
contract GainsMedusa is CommonBase {
    MockUSDC internal usdc;
    MockGainsDiamond internal diamond;
    MockChainlinkFeed internal btcFeed;
    MockChainlinkFeed internal ethFeed;
    MockChainlinkFeed internal sequencer;
    GainsVault internal vault;
    GainsVaultPolicy internal policy;
    GainsVaultLens internal lens;
    GainsVaultFactory internal platform;

    address internal constant OWNER = address(0x0E1);
    address internal constant MANAGER = address(0x0E2);
    address internal constant GUARDIAN = address(0x0E3);
    address internal constant FEES = address(0x0E4);
    address[3] internal actors = [address(0xA1), address(0xA2), address(0xA3)];

    uint64 internal ethPx = 3_000e10;
    uint64 internal btcPx = 100_000e10;
    uint256 internal usdcTotal; // conserved: actors + vault + diamond (+ fee recipient, never paid USDC)

    mapping(uint256 => uint256) internal claimedRedeem;
    bool internal overpaid;
    bool internal claimMismatch;
    bool internal allowanceLeft;

    constructor() {
        vm.warp(1_700_000_000);
        vm.roll(1_000);
        usdc = new MockUSDC();
        diamond = new MockGainsDiamond(IERC20(address(usdc)));
        usdc.mint(address(diamond), 100_000_000e6);
        diamond.setPair(1, 3.5e8, 285.7e18, 0.1e18, 1e7);
        diamond.setPair(0, 3.5e8, 285.7e18, 0.1e18, 1e7);
        btcFeed = new MockChainlinkFeed(8, 100_000e8);
        ethFeed = new MockChainlinkFeed(8, 3_000e8);
        sequencer = new MockChainlinkFeed(0, 0);
        sequencer.setStatus(0, 1_700_000_000 - 30 days);
        GainsVault impl = new GainsVault();
        GainsVaultPolicy pimpl = new GainsVaultPolicy();
        lens = new GainsVaultLens();
        platform = new GainsVaultFactory(
            address(this),
            address(impl),
            address(pimpl),
            IERC20(address(usdc)),
            IGainsDiamond(address(diamond)),
            address(sequencer),
            3_600,
            address(0xFEE),
            address(0x6A),
            address(0x5E)
        );
        platform.setAssetCurated(0, true, address(btcFeed), 2_655, 20);
        platform.setAssetCurated(1, true, address(ethFeed), 2_655, 20);
        uint32[] memory assets = new uint32[](2);
        assets[0] = 0;
        assets[1] = 1;
        vault = GainsVault(Clones.clone(address(impl)));
        policy = GainsVaultPolicy(Clones.clone(address(pimpl)));
        policy.initialize(
            OWNER,
            GainsVaultPolicy.RiskConfig({
                maxLeverageBps: 30_000,
                maxDailyLossBps: 500,
                maxDrawdownBps: 1_500,
                maxSlippageBps: 100,
                maxOrderNotional: 1_000_000e6,
                maxEpochDuration: 7 days,
                maxNavMoveBps: 2_000,
                maxFlattenSlippageBps: 300
            }),
            assets,
            2 days,
            address(platform),
            address(vault)
        );
        vault.initialize(
            InitParams({
                asset: IERC20(address(usdc)),
                name: "G",
                symbol: "G",
                owner: OWNER,
                manager: MANAGER,
                guardian: GUARDIAN,
                feeRecipient: FEES,
                managementFeeBps: 200,
                performanceFeeBps: 2_000,
                timelockDelay: 2 days,
                depositCap: 0,
                policy: policy,
                diamond: IGainsDiamond(address(diamond)),
                factory: address(0),
                protocolShareBps: 0,
                baseShareBps: 0,
                hosted: false,
                agent: address(0),
                operator: address(0)
            })
        );
        for (uint256 i; i < 3; ++i) {
            usdc.mint(actors[i], 10_000_000e6);
            vm.prank(actors[i]);
            usdc.approve(address(vault), type(uint256).max);
        }
        usdcTotal = usdc.balanceOf(address(diamond)) + 30_000_000e6;
    }

    // ---------------------------------------------------------------- helpers
    function _clamp(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + (x % (hi - lo + 1));
    }

    function _fresh() internal {
        ethFeed.set(int256(uint256(ethPx / 100)), block.timestamp);
        btcFeed.set(int256(uint256(btcPx / 100)), block.timestamp);
    }

    function _fillAll() internal {
        IGainsDiamond.PendingOrder[] memory o = diamond.getPendingOrders(address(vault));
        for (uint256 i; i < o.length; ++i) {
            try diamond.fill(address(vault), o[i].index, o[i].trade.pairIndex == 0 ? btcPx : ethPx) {} catch {}
        }
    }

    function _claim(address a) internal {
        (uint256 e, uint256 dep, uint256 red) = vault.requests(a);
        if (e >= vault.currentEpoch() || (dep == 0 && red == 0)) return;
        (, uint256 expAssets) = lens.claimable(vault, a);
        uint256 u0 = usdc.balanceOf(a);
        try vault.claim(a) {
            uint256 du = usdc.balanceOf(a) - u0;
            if (du > expAssets) claimMismatch = true;
            if (red > 0 && dep == 0) {
                claimedRedeem[e] += du;
                (,,, uint256 paid,,,,) = vault.epochs(e);
                if (claimedRedeem[e] > paid) overpaid = true;
            }
        } catch {}
    }

    // ---------------------------------------------------------------- actions
    function deposit(uint8 who, uint256 amt) external {
        address a = actors[who % 3];
        _claim(a);
        (,, uint256 red) = vault.requests(a);
        if (red > 0) return;
        vm.prank(a);
        try vault.requestDeposit(_clamp(amt, 10e6, 1_000_000e6), a) {} catch {}
    }

    function redeem(uint8 who, uint256 pct) external {
        address a = actors[who % 3];
        _claim(a);
        (, uint256 dep,) = vault.requests(a);
        if (dep > 0) return;
        uint256 sh = (vault.balanceOf(a) * _clamp(pct, 1, 100)) / 100;
        if (sh == 0) return;
        vm.prank(a);
        try vault.requestRedeem(sh, a, a) {} catch {}
    }

    function claim(uint8 who) external {
        _claim(actors[who % 3]);
    }

    function cancelDeposit(uint8 who) external {
        vm.prank(actors[who % 3]);
        try vault.cancelDepositRequest() {} catch {}
    }

    function cancelRedeem(uint8 who) external {
        vm.prank(actors[who % 3]);
        try vault.cancelRedeemRequest() {} catch {}
    }

    function settle(uint256 dt) external {
        _fillAll();
        vm.warp(block.timestamp + _clamp(dt, 1 hours, 2 days));
        _fresh();
        try vault.checkRisk() {} catch {}
        vm.prank(MANAGER);
        try vault.settle() {} catch {}
    }

    function emergencySettle(uint256 dt) external {
        vm.warp(block.timestamp + _clamp(dt, 1 hours, 1 days));
        _fresh();
        vm.prank(GUARDIAN);
        try vault.triggerEmergency() {} catch {}
        _fillAll();
        vm.prank(GUARDIAN);
        try vault.settle() {} catch {}
        vm.prank(GUARDIAN);
        try vault.exitEmergency() {} catch {}
    }

    function accrue(uint256 dt) external {
        vm.warp(block.timestamp + _clamp(dt, 1, 30 days));
        _fresh();
        try vault.accrueFees() {} catch {}
    }

    function trade(bool btc, bool long, uint256 pct, uint256 lev) external {
        uint16 pair = btc ? 0 : 1;
        uint256 idle = vault.idleAssets();
        uint120 coll = uint120((idle * _clamp(pct, 1, 40)) / 100);
        OpenParams memory p = OpenParams(pair, long, coll, uint24(_clamp(lev, 1_100, 20_000)), btc ? btcPx : ethPx, 1_000, 0, 0, 0);
        vm.prank(MANAGER);
        try vault.openTrade(p) {
            if (usdc.allowance(address(vault), address(diamond)) != 0) allowanceLeft = true;
            _fillAll();
        } catch {}
    }

    function closeOne(uint256 which) external {
        IGainsDiamond.Trade[] memory t = diamond.getTrades(address(vault));
        if (t.length == 0) return;
        IGainsDiamond.Trade memory x = t[which % t.length];
        vm.prank(MANAGER);
        try vault.closeTrade(x.index, x.pairIndex == 0 ? btcPx : ethPx) {
            _fillAll();
        } catch {}
    }

    function move(bool btc, uint256 bps, bool up) external {
        uint256 b = _clamp(bps, 0, 400);
        if (btc) btcPx = uint64(up ? btcPx + (btcPx * b) / 10_000 : btcPx - (btcPx * b) / 10_000);
        else ethPx = uint64(up ? ethPx + (ethPx * b) / 10_000 : ethPx - (ethPx * b) / 10_000);
        ethPx = (ethPx / 100) * 100;
        btcPx = (btcPx / 100) * 100;
        _fresh();
        try vault.checkRisk() {} catch {}
    }

    function liquidate() external {
        IGainsDiamond.Trade[] memory t = diamond.getTrades(address(vault));
        for (uint256 i; i < t.length; ++i) {
            uint64 px = t[i].pairIndex == 0 ? btcPx : ethPx;
            if (diamond.closeValue(address(vault), t[i].index, px) == 0) {
                try diamond.trigger(address(vault), t[i].index, px) {} catch {}
            }
        }
    }

    // ---------------------------------------------------------------- properties
    function property_reservesBacked() external view returns (bool) {
        return usdc.balanceOf(address(vault))
            >= vault.pendingDepositAssets() + vault.deferredDepositAssets() + vault.claimableRedeemAssets();
    }

    function property_sharesAccounted() external view returns (bool) {
        uint256 held = vault.balanceOf(address(vault)) + vault.balanceOf(FEES);
        for (uint256 i; i < 3; ++i) {
            held += vault.balanceOf(actors[i]);
        }
        return held == vault.totalSupply();
    }

    function property_escrowCoversQueue() external view returns (bool) {
        return vault.balanceOf(address(vault)) >= vault.pendingRedeemShares();
    }

    function property_usdcConserved() external view returns (bool) {
        uint256 s = usdc.balanceOf(address(vault)) + usdc.balanceOf(address(diamond)) + usdc.balanceOf(FEES);
        for (uint256 i; i < 3; ++i) {
            s += usdc.balanceOf(actors[i]);
        }
        return s == usdcTotal;
    }

    function property_claimsNeverExceedEpoch() external view returns (bool) {
        return !overpaid && !claimMismatch;
    }

    function property_noStandingApproval() external view returns (bool) {
        return !allowanceLeft && usdc.allowance(address(vault), address(diamond)) == 0;
    }

    /// @dev NAV never above the oracle payout (idle + every trade closed at the Chainlink price + pending opens).
    function property_navNotAbovePayout() external view returns (bool) {
        uint256 payout = vault.idleAssets();
        IGainsDiamond.Trade[] memory t = diamond.getTrades(address(vault));
        for (uint256 i; i < t.length; ++i) {
            payout += diamond.closeValue(address(vault), t[i].index, t[i].pairIndex == 0 ? btcPx : ethPx);
        }
        IGainsDiamond.PendingOrder[] memory o = diamond.getPendingOrders(address(vault));
        for (uint256 i; i < o.length; ++i) {
            uint256 fee = diamond.minGovFee(o[i].trade.pairIndex);
            if (o[i].orderType == 0 && o[i].trade.collateralAmount > fee) payout += o[i].trade.collateralAmount - fee;
        }
        try vault.totalAssets() returns (uint256 nav) {
            return nav <= payout;
        } catch {
            return true;
        }
    }
}
