// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "../../../gains/fork/GainsForkBase.sol";
import {GainsVault} from "../../../../src/gains/GainsVault.sol";
import {GainsVaultFactory} from "../../../../src/gains/GainsVaultFactory.sol";
import {GainsVaultPolicy} from "../../../../src/gains/GainsVaultPolicy.sol";
import {GainsPrice} from "../../../../src/gains/GainsPrice.sol";
import {GainsNav} from "../../../../src/gains/GainsNav.sol";
import {IGainsDiamond} from "../../../../src/gains/IGainsDiamond.sol";
import {MAX_PAIR_SKEW_CAP_BPS, OpenParams} from "../../../../src/gains/GainsTypes.sol";
import {ForkPairCap} from "../../../gains/fork/ForkPairCap.sol";

/// @dev Diamond getters the SDK ABI has and IGainsDiamond / the spike interface lack (names and layouts from
///      the gainsnetwork SDK 1.8.10 GNSMultiCollatDiamond ABI).
interface IGainsExtra {
    struct PairOiToken {
        uint128 oiLongToken;
        uint128 oiShortToken;
    }

    function getPairOiAfterV10Token(uint8 _collateralIndex, uint16 _pairIndex) external view returns (PairOiToken memory);
    function getPairSkewDepth(uint8 _collateralIndex, uint16 _pairIndex) external view returns (uint256);
    function getCollateralPriceUsd(uint8 _collateralIndex) external view returns (uint256);
    function pairMaxLeverage(uint256 _pairIndex) external view returns (uint256);
    function pairMinLeverage(uint256 _pairIndex) external view returns (uint256);
}

/// @notice Exposes GainsNav.tradeValue (internal) for one trade, as the vault would compute it for `t.user`.
/// @dev Fix round (GR1-03): the near-liquidation rule no longer takes the band (the band is in `price`); `bandBps` is
///      kept so the dump and diff scripts keep their call shape, and ignored.
contract NavHarness {
    function tradeValue(IGainsDiamond d, IGainsDiamond.Trade memory t, uint64 price, uint16 bandBps) external view returns (uint256) {
        bandBps;
        uint128 pd = d.getCollateral(t.collateralIndex).precisionDelta;
        return GainsNav.tradeValue(d, t, price, pd);
    }

    function minGovFee(IGainsDiamond d, uint8 ci, uint16 pair) external view returns (uint256) {
        return GainsNav.minGovFee(d, ci, pair);
    }
}

/// @notice Round 1 review (sub-reviewer 3.1, NAV): Arbitrum One fork harness. Same factory + vault setup as
///         test/gains/fork/GainsVaultFork.t.sol (real gTrade v10 diamond, oracle emulation of GainsForkBase, Chainlink
///         frozen per test with mockCall), with configurable fees and risk limits.
abstract contract NavForkBase is GainsForkBase {
    address internal constant BTC_USD = 0x6ce185860a4963106506C203335A2910413708e9;
    address internal constant ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address internal constant SOL_USD = 0x24ceA4b8ce57cdA5058b924B9B9987992450590c;
    address internal constant SEQ = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;

    IGainsDiamond internal D;
    IGainsExtra internal X;
    GainsVaultFactory internal factory;
    GainsVault internal v;
    GainsVaultPolicy internal pol;
    NavHarness internal harness;

    address internal fOwner = makeAddr("fOwner");
    address internal fGuardian = makeAddr("fGuardian");
    address internal fSentinel = makeAddr("fSentinel");
    address internal treasury = makeAddr("treasury");
    address internal creator = makeAddr("creator");
    address internal feeTo = makeAddr("feeTo");
    address internal mgr = makeAddr("mgr");
    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    mapping(address feed => uint64) internal cl;

    function setUp() public virtual override {
        super.setUp();
        if (!forked) return;
        D = IGainsDiamond(address(DIAMOND));
        X = IGainsExtra(address(DIAMOND));
        harness = new NavHarness();
        _setCl(BTC_USD, _round(_chainlink1e10(BTC_USD)));
        _setCl(ETH_USD, _round(_chainlink1e10(ETH_USD)));
        _setCl(SOL_USD, _round(_chainlink1e10(SOL_USD)));

        GainsVault impl = new GainsVault();
        GainsVaultPolicy pimpl = new GainsVaultPolicy();
        factory = new GainsVaultFactory(fOwner, address(impl), address(pimpl), USDC, D, SEQ, 3_600, treasury, fGuardian, fSentinel);
        vm.startPrank(fOwner);
        factory.setLauncherAllowed(creator, true);
        factory.setAssetCurated(BTC, true, BTC_USD, 2_655, 20);
        factory.setAssetCurated(ETH, true, ETH_USD, 2_655, 20);
        factory.setAssetCurated(SOL, true, SOL_USD, 88_200, 25);
        factory.setMaxDepositCap(type(uint256).max);
        vm.stopPrank();
        // GR2-KEY-01b (WP5 port): the guardian sets the launch caps, 1 % of skew depth on BTC, ETH and SOL, as the
        // deploy does (docs/fix-round/DEPLOY-R2.md 3.5). Without them a factory vault takes no new exposure.
        vm.startPrank(factory.guardian());
        factory.setPairSkewCap(uint16(BTC), 100);
        factory.setPairSkewCap(uint16(ETH), 100);
        factory.setPairSkewCap(uint16(SOL), 100);
        vm.stopPrank();

        vm.startPrank(GUSDC);
        USDC.transfer(creator, 10e6);
        USDC.transfer(alice, 1_000_000e6);
        USDC.transfer(bob, 1_000_000e6);
        vm.stopPrank();
    }

    function _risk(uint32 maxLev) internal pure returns (GainsVaultPolicy.RiskConfig memory) {
        return GainsVaultPolicy.RiskConfig({
            maxLeverageBps: maxLev,
            maxDailyLossBps: 9_000,
            maxDrawdownBps: 9_000,
            maxSlippageBps: 100,
            maxOrderNotional: 10_000_000e6,
            maxEpochDuration: 7 days,
            maxNavMoveBps: 2_000,
            maxFlattenSlippageBps: 300
        });
    }

    function _create(bytes32 salt, GainsVaultPolicy.RiskConfig memory risk, uint16 mgmtBps, uint16 perfBps)
        internal
        returns (GainsVault vault, GainsVaultPolicy p)
    {
        uint32[] memory assets = new uint32[](3);
        assets[0] = BTC;
        assets[1] = ETH;
        assets[2] = SOL;
        vm.prank(creator);
        USDC.approve(address(factory), 1e6);
        vm.prank(creator);
        (address va, address pa) = factory.create(
            GainsVaultFactory.CreateParams({
                name: "Nav Review Vault",
                symbol: "nRV",
                owner: creator,
                manager: mgr,
                feeRecipient: feeTo,
                managementFeeBps: mgmtBps,
                performanceFeeBps: perfBps,
                timelockDelay: 2 days,
                depositCap: 100_000_000e6,
                risk: risk,
                assets: assets,
                agent: address(0),
                agentSig: "",
                agentDeadline: 0,
                operator: keeper,
                hosted: false,
                seedUsdc: 1e6,
                salt: salt
            }),
            GainsVaultFactory.PermitData(0, 0, 0, bytes32(0), bytes32(0))
        );
        vault = GainsVault(va);
        p = GainsVaultPolicy(pa);
        vm.prank(alice);
        USDC.approve(va, type(uint256).max);
        vm.prank(bob);
        USDC.approve(va, type(uint256).max);
    }

    // ------------------------------------------------------------------ prices
    function _round(uint64 px) internal pure returns (uint64) {
        return (px / 100) * 100;
    }

    function _feedOf(uint16 pair) internal pure returns (address) {
        return pair == BTC ? BTC_USD : pair == ETH ? ETH_USD : SOL_USD;
    }

    function _band(uint16 pair) internal pure returns (uint16) {
        return pair == SOL ? 25 : 20;
    }

    function _c(uint16 pair) internal view returns (uint64) {
        return cl[_feedOf(pair)];
    }

    function _setCl(address feed, uint64 px) internal {
        cl[feed] = px;
        uint256 t = vm.getBlockTimestamp();
        vm.mockCall(feed, abi.encodeWithSelector(IChainlinkFeed.latestRoundData.selector), abi.encode(uint80(1), int256(uint256(px / 100)), t, t, uint80(1)));
    }

    function _setPx(uint16 pair, uint64 px) internal {
        _setCl(_feedOf(pair), _round(px));
    }

    function _refreshCl() internal {
        _setCl(BTC_USD, cl[BTC_USD]);
        _setCl(ETH_USD, cl[ETH_USD]);
        _setCl(SOL_USD, cl[SOL_USD]);
    }

    function _rollFresh(uint256 blocks) internal {
        _roll(blocks);
        _refreshCl();
    }

    /// @dev GR2-KEY-01b (WP5 port): the minimum hold with the Chainlink mocks kept fresh.
    function _passHold() internal override {
        _rollFresh(HOLD_BLOCKS);
    }

    /// @dev GR2-KEY-01b (WP5 port): for tests that are not about the pair cap and size positions above 1 % of Gains'
    ///      skew depth at the pinned block. Raises `pair` to the code maximum (10 %), the end state of the guardian's
    ///      31-day queued raise, written into the factory's storage (test/gains/fork/ForkPairCap.sol says why).
    function _raisePairCapToMax(uint16 pair) internal {
        assertEq(ForkPairCap.raiseToMax(address(factory), pair), MAX_PAIR_SKEW_CAP_BPS, "pair cap at the 10 % maximum");
    }

    function _adverseP(uint16 pair, bool long) internal view returns (uint64) {
        return GainsPrice.adverse(_c(pair), _band(pair), long);
    }

    // ------------------------------------------------------------------ flows
    function _depositSettle(GainsVault vault, address who, uint256 amt) internal {
        vm.prank(who);
        vault.requestDeposit(amt, who);
        _rollFresh(4 * 3_600);
        vault.checkRisk();
        vm.prank(keeper);
        vault.settle();
        vault.claim(who);
    }

    function _settleK(GainsVault vault) internal {
        _rollFresh(4 * 3_600);
        vault.checkRisk();
        vm.prank(keeper);
        vault.settle();
    }

    function _call(GainsVault vault, address caller, bytes memory data) internal returns (Vm.Log[] memory logs) {
        vm.recordLogs();
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(vault).call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        logs = vm.getRecordedLogs();
    }

    function _open(GainsVault vault, uint16 pair, bool long, uint120 coll, uint24 lev, uint64 fillPx) internal returns (uint32 idx, bool ok) {
        OpenParams memory o = OpenParams(pair, long, coll, lev, _c(pair), 1_000, 0, 0, 0);
        Vm.Log[] memory req = _call(vault, mgr, abi.encodeCall(GainsVault.openTrade, (o)));
        _rollFresh(1);
        Vm.Log[] memory fill = _fill(req, fillPx);
        if (_count(fill, G.MarketExecuted.selector) == 0) return (0, false);
        idx = uint32(uint256(_find(fill, G.MarketExecuted.selector).topics[2]));
        ok = true;
    }

    /// @dev Requests a market close at expected price `p`, fills it at `p`; returns the USDC Gains paid.
    function _closeAt(GainsVault vault, uint32 idx, uint64 p) internal returns (uint256 paid) {
        Vm.Log[] memory req = _call(vault, mgr, abi.encodeCall(GainsVault.closeTrade, (idx, p)));
        uint256 b = USDC.balanceOf(address(vault));
        _fill(req, p);
        paid = USDC.balanceOf(address(vault)) - b;
    }
}
