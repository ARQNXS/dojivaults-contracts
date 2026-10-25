// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "../lifecycle/LifecycleForkBase.sol";
import {GainsSpikeTrader} from "../../../gains/spike/GainsSpikeTrader.sol";

/// @dev Gains governance / manager entry points the vault never calls (selectors from the verified v10 facets on
///      Sourcify: GNSPriceImpact, GNSTradingInteractions; and the TradingStorage interface in the same bundles).
interface IGainsGov {
    function getPairSkewDepth(uint8 collateralIndex, uint16 pairIndex) external view returns (uint256);
    function setPairSkewDepths(uint8[] calldata collateralIndices, uint16[] calldata pairIndices, uint256[] calldata depths) external;
    function getPairOiAfterV10Token(uint8 collateralIndex, uint16 pairIndex) external view returns (uint128 oiLong, uint128 oiShort);
    function initiateManualNegativePnlRealization(address trader, uint32 index, bool isHoldingFeesRealization) external;
    function hasRole(address account, uint8 role) external view returns (bool);
    function getMaxSkewCollateral(uint8 collateralIndex, uint16 pairIndex) external view returns (uint256);
}

/// @notice Round 2, domain GNS (the Gains side). The round-1 lifecycle harness (real gTrade v10 diamond, oracle
///         answers emulated by pranking the diamond's Chainlink operator nodes, Chainlink feeds frozen with mockCall),
///         re-pinned to a block >= 516,000,000 as METHOD.md requires. This base forks at R2_BLOCK (= FORK_BLOCK, so
///         _arbBlock() returns R2_BLOCK + blocks rolled). Everything after the fork is LifecycleForkBase.setUp, copied.
abstract contract GainsSideForkBase is LifecycleForkBase {
    /// @dev GNS_FORK_BLOCK, else GAINS_FORK_BLOCK, else GAINS_FORK_BLOCK_DEFAULT (round 2 run of record: 516,300,000).
    ///      The public RPC keeps ~10-20 min of state, so a pinned block must be recent (or use an archive RPC).
    uint256 internal R2_BLOCK;

    // Gains roles (IAddressStore.Role) and holders at R2_BLOCK (hasRole read on chain, AccessControlUpdated history)
    uint8 internal constant ROLE_GOV_TIMELOCK = 0;
    uint8 internal constant ROLE_GOV = 1;
    uint8 internal constant ROLE_MANAGER = 2;
    uint8 internal constant ROLE_GOV_EMERGENCY = 3;
    uint8 internal constant ROLE_GOV_EMERGENCY_TIMELOCK = 4;
    address internal constant GAINS_MANAGER = 0xE72DfEC45cCc0B5571D659Cb8B482523C45439dB; // MANAGER (EOA)
    address internal constant GAINS_GOV_SAFE = 0xc07EEd650aB255190CA9766162CfB47cFDf72f3a; // GOV (Safe, 4 of n)

    IGainsGov internal GOV = IGainsGov(address(0xFF162c694eAA571f685030649814282eA457f169));

    function _forkBlock() internal view virtual override returns (uint256) {
        return vm.envOr("GNS_FORK_BLOCK", super._forkBlock());
    }

    function setUp() public virtual override {
        if (bytes(vm.envOr("ARBITRUM_RPC_URL", string(""))).length == 0) {
            vm.skip(true);
            return;
        }
        R2_BLOCK = _forkBlock();
        require(R2_BLOCK >= 516_000_000, "pin >= 516,000,000");
        _forkAt(R2_BLOCK);
        forked = true;
        require(_arbBlock() == R2_BLOCK, "arb block");

        trader = new GainsSpikeTrader(DIAMOND, USDC, address(this));
        vm.prank(GUSDC);
        USDC.transfer(address(trader), 1_000e6);

        // LifecycleForkBase.setUp after super.setUp(), verbatim
        _setCl(BTC_USD, _round(_chainlink1e10(BTC_USD)));
        _setCl(ETH_USD, _round(_chainlink1e10(ETH_USD)));
        _setCl(SOL_USD, _round(_chainlink1e10(SOL_USD)));

        GainsVault impl = new GainsVault();
        GainsVaultPolicy pimpl = new GainsVaultPolicy();
        lens = new GainsVaultLens();
        factory = new GainsVaultFactory(
            fOwner, address(impl), address(pimpl), USDC, D, SEQ, 3_600, treasury, fGuardian, fSentinel
        );
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
        USDC.transfer(alice, 200_000e6);
        USDC.transfer(bob, 200_000e6);
        vm.stopPrank();
        (v, pol) = _createLive(bytes32(uint256(7)));
        vm.prank(alice);
        USDC.approve(address(v), type(uint256).max);
        vm.prank(bob);
        USDC.approve(address(v), type(uint256).max);
    }

    /// @dev The live vault's policy shape (METHOD.md "Live system"): 5x, daily loss 15%, drawdown 50%, slippage 3%,
    ///      maxNavMove 20%, flatten 3%, 1 day epochs; maxOrderNotional raised so one trade can carry the vault's
    ///      leverage (the live 250,000 USDC per order only splits the same exposure over more trades).
    function _createLive(bytes32 salt) internal returns (GainsVault vault, GainsVaultPolicy p) {
        uint32[] memory assets = new uint32[](3);
        assets[0] = BTC;
        assets[1] = ETH;
        assets[2] = SOL;
        vm.prank(creator);
        USDC.approve(address(factory), 1e6);
        vm.prank(creator);
        (address va, address pa) = factory.create(
            GainsVaultFactory.CreateParams({
                name: "Gains R2 GNS Vault",
                symbol: "gGNS",
                owner: creator,
                manager: mgr,
                feeRecipient: creator,
                managementFeeBps: 0,
                performanceFeeBps: 0,
                timelockDelay: 2 days,
                depositCap: 10_000_000e6,
                risk: GainsVaultPolicy.RiskConfig({
                    maxLeverageBps: 50_000,
                    maxDailyLossBps: 1_500,
                    maxDrawdownBps: 5_000,
                    maxSlippageBps: 300,
                    maxOrderNotional: 5_000_000e6,
                    maxEpochDuration: 1 days,
                    maxNavMoveBps: 2_000,
                    maxFlattenSlippageBps: 300
                }),
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
        return (GainsVault(va), GainsVaultPolicy(pa));
    }

    /// @dev Two holders in, settled in one epoch.
    function _twoHolders(uint256 a, uint256 b) internal {
        vm.prank(alice);
        v.requestDeposit(a, alice);
        vm.prank(bob);
        v.requestDeposit(b, bob);
        _rollFresh(4 * 3_600);
        v.checkRisk();
        vm.prank(keeper);
        v.settle();
        v.claim(alice);
        v.claim(bob);
    }

    /// @dev An outside Gains trader (not the vault) with `usdc` of its own.
    function _outsider(uint256 usdc) internal returns (GainsSpikeTrader t) {
        t = new GainsSpikeTrader(DIAMOND, USDC, address(this));
        vm.prank(GUSDC); // USDC is FiatToken v2.2 (balance and blacklist bit share a slot): no deal()
        USDC.transfer(address(t), usdc);
    }

    function _openOutside(GainsSpikeTrader t, uint16 pair, bool long, uint120 coll, uint24 lev) internal returns (uint32 idx) {
        uint64 px = cl[_feed(pair)];
        vm.recordLogs();
        t.openTrade(_trade(pair, long, coll, lev, px, 0), 1000);
        Vm.Log[] memory req = vm.getRecordedLogs();
        _rollFresh(1);
        Vm.Log[] memory fill = _fill(req, px);
        idx = uint32(uint256(_find(fill, G.MarketExecuted.selector).topics[2]));
    }

    function _closeOutside(GainsSpikeTrader t, uint16 pair, uint32 idx) internal returns (uint256 sent) {
        uint64 px = cl[_feed(pair)];
        vm.recordLogs();
        t.closeTradeMarket(idx, px);
        Vm.Log[] memory req = vm.getRecordedLogs();
        _rollFresh(1);
        Vm.Log[] memory fill = _fill(req, px);
        (,,,, sent) = _decodeMarketExecuted(_find(fill, G.MarketExecuted.selector));
    }

    /// @dev Market close of a vault trade by the manager, filled at the frozen Chainlink price; USDC the vault got.
    function _closeV(uint32 idx, uint16 pair) internal returns (uint256 got) {
        uint64 px = cl[_feed(pair)];
        Vm.Log[] memory req = _req(mgr, abi.encodeCall(GainsVault.closeTrade, (idx, px)));
        _rollFresh(1);
        uint256 b0 = _usdc();
        _fill(req, px);
        got = _usdc() - b0;
    }
}
