// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {GainsVault} from "../../src/gains/GainsVault.sol";
import {GainsVaultLens} from "../../src/gains/GainsVaultLens.sol";
import {GainsVaultPolicy} from "../../src/gains/GainsVaultPolicy.sol";
import {GainsVaultFactory} from "../../src/gains/GainsVaultFactory.sol";
import {IGainsDiamond} from "../../src/gains/IGainsDiamond.sol";
import {InitParams, OpenParams, MIN_HOLD, MIN_HOLD_L2_BLOCKS} from "../../src/gains/GainsTypes.sol";
import {MockUSDC} from "../mocks/Mocks.sol";
import {MockGainsDiamond, MockChainlinkFeed} from "./mocks/GainsMocks.sol";

/// @dev Gains counterpart of test/Base.t.sol. Every vault is an EIP-1167 clone of one implementation, initialized
///      once, exactly as the factory does it. The standalone vault here has factory = 0 (no protocol share); its
///      policy uses `platform` (a GainsVaultFactory) as curation and price source, as every Gains policy must.
///      The test plays Gains' oracle: market requests stay pending until `_fill` answers them at a price.
abstract contract GainsBase is Test {
    MockUSDC internal usdc;
    MockGainsDiamond internal diamond;
    MockChainlinkFeed internal btcFeed;
    MockChainlinkFeed internal ethFeed;
    MockChainlinkFeed internal solFeed;
    MockChainlinkFeed internal sequencer;
    GainsVault internal vaultImpl;
    GainsVaultPolicy internal policyImpl;
    GainsVaultPolicy internal policy;
    GainsVault internal vault;
    GainsVaultLens internal lens;
    GainsVaultFactory internal platform;

    address internal owner = makeAddr("owner");
    address internal manager = makeAddr("manager");
    address internal guardian = makeAddr("guardian");
    address internal sentinel = makeAddr("sentinel");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");
    address internal platformOwner = makeAddr("platformOwner");
    address internal platformGuardian = makeAddr("platformGuardian");
    address internal platformSentinel = makeAddr("platformSentinel");
    address internal protocolTreasury = makeAddr("protocolTreasury");

    uint16 internal constant BTC = 0;
    uint16 internal constant ETH = 1;
    uint16 internal constant SOL = 33;
    uint16 internal constant DOGE = 7; // curated nowhere

    uint32 internal constant BTC_MAX_AGE = 1_755 + 900;
    uint32 internal constant SOL_MAX_AGE = 86_400 + 1_800;
    uint256 internal constant SEQ_GRACE = 3_600;
    uint16 internal constant SLIP = 1_000; // 1% in Gains precision

    uint256 internal constant START = 1_700_000_000;

    /// @dev Current Chainlink price per pair, 1e10, mirrored here so reading it makes no external call (an external
    ///      call between vm.prank and the call under test would consume the prank).
    mapping(uint16 pair => uint64) internal _price;

    function setUp() public virtual {
        vm.warp(START);
        vm.roll(1_000);
        usdc = new MockUSDC();
        diamond = new MockGainsDiamond(IERC20(address(usdc)));
        usdc.mint(address(diamond), 100_000_000e6); // the gToken vault that pays profits

        btcFeed = new MockChainlinkFeed(8, 100_000e8);
        ethFeed = new MockChainlinkFeed(8, 3_000e8);
        solFeed = new MockChainlinkFeed(8, 150e8);
        _price[BTC] = 100_000e10;
        _price[ETH] = 3_000e10;
        _price[SOL] = 150e10;
        sequencer = new MockChainlinkFeed(0, 0);
        sequencer.setStatus(0, START - 30 days);

        vaultImpl = new GainsVault();
        policyImpl = new GainsVaultPolicy();
        lens = new GainsVaultLens();
        platform = new GainsVaultFactory(
            platformOwner,
            address(vaultImpl),
            address(policyImpl),
            IERC20(address(usdc)),
            IGainsDiamond(address(diamond)),
            address(sequencer),
            SEQ_GRACE,
            protocolTreasury,
            platformGuardian,
            platformSentinel
        );
        vm.startPrank(platformOwner);
        platform.setAssetCurated(BTC, true, address(btcFeed), BTC_MAX_AGE, 20);
        platform.setAssetCurated(ETH, true, address(ethFeed), BTC_MAX_AGE, 20);
        platform.setAssetCurated(SOL, true, address(solFeed), SOL_MAX_AGE, 25);
        vm.stopPrank();
        // GR2-KEY-01b: a pair never set takes no new exposure on factory vaults; the guardian's first setting is immediate
        vm.startPrank(platformGuardian);
        platform.setPairSkewCap(BTC, 100);
        platform.setPairSkewCap(ETH, 100);
        platform.setPairSkewCap(SOL, 100);
        vm.stopPrank();

        uint32[] memory assets = new uint32[](2);
        assets[0] = BTC;
        assets[1] = ETH;
        vault = GainsVault(Clones.clone(address(vaultImpl)));
        policy = GainsVaultPolicy(Clones.clone(address(policyImpl)));
        policy.initialize(owner, _defaultRisk(), assets, 2 days, address(platform), address(vault));
        vault.initialize(_standaloneParams(policy));

        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _standaloneParams(GainsVaultPolicy p) internal view returns (InitParams memory) {
        return InitParams({
            asset: IERC20(address(usdc)),
            name: "DojiPad Gains Vault",
            symbol: "dpG",
            owner: owner,
            manager: manager,
            guardian: guardian,
            feeRecipient: feeRecipient,
            managementFeeBps: 200,
            performanceFeeBps: 2_000,
            timelockDelay: 2 days,
            depositCap: 0,
            policy: p,
            diamond: IGainsDiamond(address(diamond)),
            factory: address(0),
            protocolShareBps: 0,
            baseShareBps: 0,
            hosted: false,
            agent: address(0),
            operator: address(0)
        });
    }

    function _defaultRisk() internal pure returns (GainsVaultPolicy.RiskConfig memory) {
        return GainsVaultPolicy.RiskConfig({
            maxLeverageBps: 30_000,
            maxDailyLossBps: 500,
            maxDrawdownBps: 1_500,
            maxSlippageBps: 100,
            maxOrderNotional: 1_000_000e6,
            maxEpochDuration: 7 days,
            maxNavMoveBps: 2_000,
            maxFlattenSlippageBps: 300
        });
    }

    // ------------------------------------------------------------------
    // Prices (Chainlink 8 decimals; Gains 1e10)
    // ------------------------------------------------------------------
    function _feed(uint16 pair) internal view returns (MockChainlinkFeed) {
        return pair == BTC ? btcFeed : pair == ETH ? ethFeed : solFeed;
    }

    /// @dev Chainlink price of `pair` in Gains precision (1e10).
    function _px(uint16 pair) internal view returns (uint64) {
        return _price[pair];
    }

    function _setPrice(uint16 pair, uint64 px1e10) internal {
        px1e10 = (px1e10 / 100) * 100; // 8 decimal feed
        _price[pair] = px1e10;
        _feed(pair).set(int256(uint256(px1e10 / 100)), vm.getBlockTimestamp());
    }

    /// @dev Warps and keeps every feed fresh (each feed updates at least once per heartbeat on mainnet).
    function _warp(uint256 t) internal {
        vm.warp(t);
        btcFeed.set(btcFeed.answer(), t);
        ethFeed.set(ethFeed.answer(), t);
        solFeed.set(solFeed.answer(), t);
    }

    function _skip(uint256 dt) internal {
        _warp(vm.getBlockTimestamp() + dt);
    }

    /// @dev GR2-KEY-01b: past the minimum hold (MIN_HOLD and MIN_HOLD_L2_BLOCKS), feeds kept fresh, so the manager's or
    ///      the agent's next exit is not refused "min hold".
    function _passHold() internal {
        _skip(MIN_HOLD);
        vm.roll(vm.getBlockNumber() + MIN_HOLD_L2_BLOCKS);
    }

    // ------------------------------------------------------------------
    // Trading through the vault; the test answers as Gains' oracle
    // ------------------------------------------------------------------
    function _params(uint16 pair, bool long, uint120 collateral, uint24 leverage) internal view returns (OpenParams memory) {
        return OpenParams({
            pairIndex: pair,
            long: long,
            collateral: collateral,
            leverage: leverage,
            expectedPrice: _px(pair),
            maxSlippageP: SLIP,
            tp: 0,
            sl: 0,
            tradeType: 0
        });
    }

    function _request(GainsVault v, uint16 pair, bool long, uint120 collateral, uint24 leverage) internal returns (uint32 orderIndex) {
        OpenParams memory p = _params(pair, long, collateral, leverage);
        vm.prank(v.manager());
        v.openTrade(p);
        orderIndex = diamond.orderCount(address(v)) - 1;
    }

    /// @dev Answers the vault's latest pending order at `price`.
    function _fillLast(GainsVault v, uint64 price) internal returns (uint32 tradeIndex, uint256 paid) {
        return diamond.fill(address(v), diamond.orderCount(address(v)) - 1, price);
    }

    function _open(GainsVault v, uint16 pair, bool long, uint120 collateral, uint24 leverage) internal returns (uint32 idx) {
        _request(v, pair, long, collateral, leverage);
        (idx,) = _fillLast(v, _px(pair));
    }

    function _closeFilled(GainsVault v, uint32 idx, uint64 price) internal returns (uint256 paid) {
        address m = v.manager();
        vm.prank(m);
        v.closeTrade(idx, price);
        (, paid) = _fillLast(v, price);
    }

    /// @dev Moves the value of trade `idx` so the vault's venue value is exactly `target` (holding fees are linear).
    function _setVenueValue(GainsVault v, uint32 idx, uint256 target) internal {
        uint256 cur = v.venue().value;
        diamond.setHolding(address(v), idx, diamond.holding(address(v), idx) + int256(cur) - int256(target));
        assertEq(v.venue().value, target, "venue value set");
    }

    /// @dev Alice deposits `amount`, it settles, and the manager puts it all into one 1x ETH long valued at exactly
    ///      `amount`: the Gains analog of Base._fundCore (all NAV on the venue, none idle). Returns the trade index.
    function _fundVenue(uint256 amount) internal returns (uint32 idx) {
        _deposit(alice, amount);
        _settle();
        _claim(alice);
        idx = _open(vault, ETH, true, uint120(amount), 1_000);
        _setVenueValue(vault, idx, amount);
        vault.checkRisk(); // set day baseline
    }

    // ------------------------------------------------------------------
    // Flow helpers
    // ------------------------------------------------------------------
    function _deposit(address who, uint256 amount) internal {
        vm.prank(who);
        vault.requestDeposit(amount, who);
    }

    function _redeem(address who, uint256 shares) internal {
        vm.prank(who);
        vault.requestRedeem(shares, who, who);
    }

    /// @dev Settles the way the platform does: the keeper's checkRisk() refreshes the NAV checkpoint first.
    function _settle() internal {
        _ageEpoch(vault);
        vault.checkRisk();
        vm.prank(manager);
        vault.settle();
    }

    /// @dev A settle that prices deposits runs at least an hour into the epoch (GR1-02, INSIDER_MIN_EPOCH_AGE): warp
    ///      there when deposits are queued.
    function _ageEpoch(GainsVault v) internal {
        uint256 ready = uint256(v.epochStartedAt()) + 1 hours;
        if (v.pendingDepositAssets() > 0 && vm.getBlockTimestamp() < ready) _warp(ready);
    }

    /// @dev Timelocked owner action on `v`: queue, wait the delay, execute.
    function _timelocked(GainsVault v, bytes memory data) internal {
        vm.prank(v.owner());
        v.queue(data);
        _warp(v.queuedEta(keccak256(data))); // hl-r2 exit-before-effect: wait for the stored eta
        v.execute(data);
    }

    function _setAgent(GainsVault v, address a) internal {
        _timelocked(v, abi.encodeCall(GainsVault.setAgent, (a)));
    }

    function _claim(address who) internal {
        vault.claim(who);
    }
}
