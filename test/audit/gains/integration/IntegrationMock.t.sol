// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {GainsBase} from "../../../gains/GainsBase.t.sol";
import {GainsVault} from "../../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../../src/gains/GainsVaultPolicy.sol";
import {GainsVaultFactory} from "../../../../src/gains/GainsVaultFactory.sol";
import {IGainsDiamond} from "../../../../src/gains/IGainsDiamond.sol";
import {GainsNav} from "../../../../src/gains/GainsNav.sol";
import {GainsPrice} from "../../../../src/gains/GainsPrice.sol";
import {InitParams, OpenParams, IGainsVaultErrors} from "../../../../src/gains/GainsTypes.sol";

/// @dev A future gTrade Trade layout: the trailing 24-bit placeholder split into a new uint16 field + uint8 placeholder
///      (exactly how v10 carved isCounterTrade + positionSizeToken + __placeholder out of v9's uint192 placeholder).
///      Storage packing is unchanged; the ABI grows from 15 to 16 words.
struct TradeV11 {
    address user;
    uint32 index;
    uint16 pairIndex;
    uint24 leverage;
    bool long;
    bool isOpen;
    uint8 collateralIndex;
    uint8 tradeType;
    uint120 collateralAmount;
    uint64 openPrice;
    uint64 tp;
    uint64 sl;
    bool isCounterTrade;
    uint160 positionSizeToken;
    uint16 newField;
    uint8 __placeholder;
}

struct PendingOrderV11 {
    TradeV11 trade;
    address user;
    uint32 index;
    bool isOpen;
    uint8 orderType;
    uint32 createdBlock;
    uint16 maxSlippageP;
}

// ---------------------------------------------------------------------------------------------------------------------
// Hostile integration doubles
// ---------------------------------------------------------------------------------------------------------------------
interface IHook {
    function beforeSend(address to, uint256 amount) external;
    function afterReceive(address from, uint256 amount) external;
}

/// @dev A 6-decimal "USDC" with ERC-777 style sender and receiver hooks (real USDC has none).
contract HookUSDC is ERC20 {
    mapping(address => bool) public hooked;

    constructor() ERC20("Hook USD", "hUSD") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function setHooked(address a, bool b) external {
        hooked[a] = b;
    }

    function _update(address from, address to, uint256 v) internal override {
        if (from != address(0) && hooked[from]) IHook(from).beforeSend(to, v);
        super._update(from, to, v);
        if (to != address(0) && hooked[to]) IHook(to).afterReceive(from, v);
    }
}

/// @dev Minimal hostile diamond. Reads (declared view in IGainsDiamond, so the vault STATICCALLs them) are implemented
///      non-view here and try a state-changing reentry into the vault; request calls (CALL) try every reentry a
///      stranger could make while the vault's approval is outstanding.
contract EvilDiamond {
    IERC20 public immutable token;
    GainsVault public vault;
    bool public attack;
    // results of the request-path reentries
    bool public settleOk;
    bool public openOk;
    bool public depositOk;
    bool public timedOutOk;
    bool public probed;

    constructor(IERC20 t) {
        token = t;
    }

    function setVault(GainsVault v) external {
        vault = v;
    }

    function setAttack(bool a) external {
        attack = a;
    }

    function getCollateralIndex(address c) external view returns (uint8) {
        return c == address(token) ? 3 : 0;
    }

    function getCollateral(uint8 i) external view returns (IGainsDiamond.Collateral memory c) {
        if (i != 3) return c;
        c.collateral = address(token);
        c.isActive = true;
        c.precision = 1e6;
        c.precisionDelta = 1e12;
    }

    /// @dev Static-context probe: cancelTimedOut succeeds in a normal call (see the control) but emits an event, so it
    ///      must fail inside a STATICCALL. If it ever succeeds the read reverts, which would make the NAV read fail.
    function _probe() internal {
        if (address(vault) == address(0)) return;
        (bool ok,) = address(vault).call{gas: 300_000}(abi.encodeCall(GainsVault.cancelTimedOut, (0)));
        if (ok) revert("REENTERED IN A VIEW");
    }

    function getTrades(address) external returns (IGainsDiamond.Trade[] memory) {
        _probe();
        return new IGainsDiamond.Trade[](0);
    }

    function getPendingOrders(address) external returns (IGainsDiamond.PendingOrder[] memory) {
        _probe();
        return new IGainsDiamond.PendingOrder[](0);
    }

    /// @dev GR2-LIVE-01: the vault reads its index set through getCounters (+ getTrade / getPendingOrder per index);
    ///      the probe moves here. No index was ever assigned.
    function getCounters(address, uint8) external returns (IGainsDiamond.Counter memory c) {
        _probe();
        return c;
    }

    function pairMinFeeUsd(uint256) external pure returns (uint256) {
        return 0;
    }

    /// @dev GR2-KEY-01: openTrade reads the pair's skew depth; a depth no test reaches
    function getPairSkewDepth(uint8, uint16) external pure returns (uint256) {
        return 1e36;
    }

    /// @dev GR2 XF-04: no open interest ceiling
    function getPairMaxOiCollateral(uint8, uint16) external pure returns (uint256) {
        return 0;
    }

    function pairMinPositionSizeUsd(uint256) external pure returns (uint256) {
        return 0;
    }

    function getCollateralFromUsdNormalizedValue(uint8, uint256 v) external pure returns (uint256) {
        return v / 1e12;
    }

    function cancelOrderAfterTimeout(uint32) external {}

    function openTrade(IGainsDiamond.Trade calldata t, uint16, address) external {
        token.transferFrom(msg.sender, address(this), t.collateralAmount);
        if (!attack) return;
        probed = true;
        OpenParams memory p = OpenParams(1, true, 1e6, 2_000, 3_000e10, 1_000, 0, 0, 0);
        (settleOk,) = address(vault).call(abi.encodeCall(GainsVault.settle, ()));
        (openOk,) = address(vault).call(abi.encodeCall(GainsVault.openTrade, (p)));
        (depositOk,) = address(vault).call(abi.encodeCall(GainsVault.requestDeposit, (10e6, address(this))));
        (timedOutOk,) = address(vault).call(abi.encodeCall(GainsVault.cancelTimedOut, (0)));
    }
}

/// @dev Depositor contract that reenters the vault from the token hooks.
contract HookAttacker is IHook {
    GainsVault public immutable v;
    HookUSDC public immutable t;
    uint8 public mode;
    bool public r1;
    bool public r2;
    bool public r3;
    bytes public err2;

    constructor(GainsVault v_, HookUSDC t_) {
        v = v_;
        t = t_;
        t_.approve(address(v_), type(uint256).max);
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    function deposit(uint256 a) external {
        v.requestDeposit(a, address(this));
    }

    function redeemAll() external {
        v.requestRedeem(v.balanceOf(address(this)), address(this), address(this));
    }

    function claim() external {
        v.claim(address(this));
    }

    /// mode 1: inside requestDeposit's transferFrom (lock held): cancel the earlier deposit, then deposit again.
    function beforeSend(address, uint256) external {
        if (msg.sender != address(t) || mode != 1) return;
        mode = 0;
        (r1,) = address(v).call(abi.encodeCall(GainsVault.cancelDepositRequest, ()));
        (r2, err2) = address(v).call(abi.encodeCall(GainsVault.requestDeposit, (10e6, address(this))));
    }

    /// mode 2: inside claim's payout transfer (no lock): claim again, cancel redeem, cancel deposit.
    function afterReceive(address, uint256) external {
        if (msg.sender != address(t) || mode != 2) return;
        mode = 0;
        (r1,) = address(v).call(abi.encodeCall(GainsVault.claim, (address(this))));
        (r2,) = address(v).call(abi.encodeCall(GainsVault.cancelRedeemRequest, ()));
        (r3,) = address(v).call(abi.encodeCall(GainsVault.cancelDepositRequest, ()));
    }
}

/// @dev Feed whose latestRoundData writes storage: must fail under GainsPrice's staticcall.
contract WritingFeed {
    uint256 public reads;

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external returns (uint80, int256, uint256, uint256, uint80) {
        ++reads;
        return (1, 3_000e8, block.timestamp, block.timestamp, 1);
    }
}

/// @notice Round 1, section 3.5 (external integrations), unit level on the mock diamond. INT-01 PoCs and the
///         reentrancy / ETH / approval checks. Fork counterpart: IntegrationFork.t.sol.
contract IntegrationMockTest is GainsBase {
    // ------------------------------------------------------------------ helpers
    function _toV11(IGainsDiamond.Trade memory t) internal pure returns (TradeV11 memory x) {
        x.user = t.user;
        x.index = t.index;
        x.pairIndex = t.pairIndex;
        x.leverage = t.leverage;
        x.long = t.long;
        x.isOpen = t.isOpen;
        x.collateralIndex = t.collateralIndex;
        x.tradeType = t.tradeType;
        x.collateralAmount = t.collateralAmount;
        x.openPrice = t.openPrice;
        x.tp = t.tp;
        x.sl = t.sl;
        x.isCounterTrade = t.isCounterTrade;
        x.positionSizeToken = t.positionSizeToken;
        x.newField = 7; // any small value of the new field
    }

    /// @dev From now on the diamond answers getTrades(vault) in the extended layout (a facet upgrade).
    function _upgradeTrades() internal {
        IGainsDiamond.Trade[] memory t = diamond.getTrades(address(vault));
        TradeV11[] memory x = new TradeV11[](t.length);
        for (uint256 i; i < t.length; ++i) {
            x[i] = _toV11(t[i]);
        }
        vm.mockCall(address(diamond), abi.encodeCall(IGainsDiamond.getTrades, (address(vault))), abi.encode(x));
    }

    function _upgradeOrders() internal {
        IGainsDiamond.PendingOrder[] memory o = diamond.getPendingOrders(address(vault));
        PendingOrderV11[] memory x = new PendingOrderV11[](o.length);
        for (uint256 i; i < o.length; ++i) {
            x[i] = PendingOrderV11(_toV11(o[i].trade), o[i].user, o[i].index, o[i].isOpen, o[i].orderType, o[i].createdBlock, o[i].maxSlippageP);
        }
        vm.mockCall(address(diamond), abi.encodeCall(IGainsDiamond.getPendingOrders, (address(vault))), abi.encode(x));
    }

    /// @dev Both lists in the extended layout (a facet upgrade changes the nested Trade of PendingOrder too), read
    ///      from the diamond's current state.
    function _upgradeAll() internal {
        vm.clearMockedCalls();
        _upgradeTrades();
        _upgradeOrders();
    }

    /// @dev The vault reads the same NAV, notional, order counts and shortfall in the extended layout as in v10's.
    function _assertSameAsV10() internal {
        GainsNav.Snapshot memory x = vault.venue();
        uint256 sfx = vault.redemptionShortfall();
        bool px = vault.ordersPending();
        vm.clearMockedCalls();
        GainsNav.Snapshot memory y = vault.venue();
        assertEq(x.value, y.value, "value");
        assertEq(x.valueHigh, y.valueHigh, "valueHigh");
        assertEq(x.notional, y.notional, "notional");
        assertEq(x.orders, y.orders, "orders");
        assertEq(x.pending, y.pending, "pending");
        assertEq(x.blocking, y.blocking, "blocking");
        assertEq(sfx, vault.redemptionShortfall(), "shortfall");
        assertEq(px, vault.ordersPending(), "ordersPending");
        _upgradeAll();
    }

    function _funded() internal returns (uint32 a, uint32 b) {
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
        a = _open(vault, ETH, true, 10_000e6, 2_000);
        b = _open(vault, BTC, false, 10_000e6, 2_000);
        vault.checkRisk();
    }

    // ==================================================================
    // INT-01: a Gains facet upgrade that grows the Trade ABI
    // ==================================================================
    /// @notice Was the GR1-08 PoC `test_INT01_tradeLayoutChange_freezesNavSettleAndFlatten` (with >= 2 open trades the
    ///         fixed 15-word decoder misaligned and NAV, checkRisk, every settle mode, accrueFees, openTrade, deposits
    ///         and flatten reverted). GainsNav now takes the stride from the returndata: in the 16-word layout every one
    ///         of them works and reads exactly the values of the v10 layout.
    function test_GR1_08_tradeLayoutChange_navSettleAndFlattenWorkUnchanged() public {
        (uint32 a,) = _funded();
        vm.prank(owner);
        vault.setDepositCap(10_000_000e6); // factory vaults always run with 0 < cap
        uint256 navBefore = vault.totalAssets();
        (uint256 lev0, uint256 dl0,) = vault.checkRisk();
        _upgradeAll();

        assertEq(vault.totalAssets(), navBefore, "NAV unchanged");
        (uint256 lev1, uint256 dl1,) = vault.checkRisk();
        assertEq(lev1, lev0, "leverage unchanged");
        assertEq(dl1, dl0, "daily loss unchanged");
        _assertSameAsV10();
        vault.accrueFees();
        // deposits and a normal settle
        vm.prank(bob);
        vault.requestDeposit(1_000e6, bob);
        uint256 epoch = vault.currentEpoch();
        _settle();
        assertEq(vault.currentEpoch(), epoch + 1, "normal settle");
        // a new trade (the lists change: re-read them in the new layout)
        vm.prank(manager);
        vault.openTrade(_params(ETH, true, 1_000e6, 2_000));
        _upgradeAll();
        _assertSameAsV10();
        diamond.fill(address(vault), diamond.orderCount(address(vault)) - 1, _px(ETH));
        _upgradeAll();
        _assertSameAsV10();
        assertEq(vault.venue().orders, 3, "three trades read");
        // the guardian's batch exit
        vm.prank(guardian);
        (uint256 sent, uint256 remaining) = vault.flatten(ETH, 0, _px(ETH), type(uint256).max);
        assertEq(sent, 2, "both ETH trades get a close");
        assertEq(remaining, 0);
        _upgradeAll();
        _assertSameAsV10();
        // emergency: the exit-only settle values the venue, closes in flight do not hold it (GR1-04)
        vm.prank(guardian);
        vault.triggerEmergency();
        _redeem(alice, vault.balanceOf(alice) / 2);
        vm.prank(guardian);
        vault.settle();
        assertEq(vault.currentEpoch(), epoch + 2, "emergency settle");
        a;
    }

    /// @notice Was the GR1-08 PoC `test_INT01_pendingOrderLayoutChange_blocksNavFlattenAndOperatorReduce` (the nested
    ///         Trade shifted every PendingOrder field, so one pending order froze NAV, flatten and the operator's
    ///         shortfall reduce). With both lists in the new layout they work, with the v10 values.
    function test_GR1_08_pendingOrderLayoutChange_navFlattenAndOperatorReduceWork() public {
        (uint32 a, uint32 b) = _funded();
        address op = makeAddr("operator");
        vm.prank(owner);
        vault.setOperator(op);
        _redeem(alice, vault.balanceOf(alice)); // more than idle: a shortfall the operator may fund
        _passHold(); // GR2-KEY-01b: the manager's close waits out the minimum hold
        vm.prank(manager);
        vault.closeTrade(a, _px(ETH)); // one order in flight
        uint256 nav0 = vault.totalAssets();
        uint256 sf0 = vault.redemptionShortfall();
        assertGt(sf0, 1_000e6, "the operator reduce is within its cap");
        _upgradeAll();

        assertEq(vault.totalAssets(), nav0, "NAV unchanged");
        assertEq(vault.redemptionShortfall(), sf0, "shortfall unchanged");
        _assertSameAsV10();
        vault.checkRisk();
        vm.prank(op);
        vault.reduceTrade(b, 1_000e6, 0, _px(BTC)); // the operator's shortfall reduce
        _upgradeAll();
        _assertSameAsV10();
        diamond.fill(address(vault), diamond.orderCount(address(vault)) - 1, _px(BTC));
        _upgradeAll();
        vm.prank(guardian);
        (uint256 sent,) = vault.flatten(BTC, 0, _px(BTC), type(uint256).max);
        assertEq(sent, 1, "flatten reads the list and closes the BTC trade");
        _upgradeAll();
        _assertSameAsV10();
    }

    /// @notice GR1-08: a layout the vault cannot read reverts DiamondLayoutChanged() on every priced path and on
    ///         flatten, never a raw decode panic and never a silently wrong value. The full stop still works (its
    ///         resting-order cancel is best effort), and flattenIndices closes the trades by index without decoding
    ///         anything. Ported in fix round WP2 to GR2-LIVE-01's per-index reads: the vault no longer calls getTrades,
    ///         so each trade's own getTrade answers with an odd number of bytes.
    function test_GR1_08_unreadableLayout_revertsDiamondLayoutChanged_flattenIndicesCloses() public {
        (uint32 a, uint32 b) = _funded();
        bytes memory junk = abi.encodePacked(new bytes(65));
        vm.mockCall(address(diamond), abi.encodeCall(IGainsDiamond.getTrade, (address(vault), a)), junk);
        vm.mockCall(address(diamond), abi.encodeCall(IGainsDiamond.getTrade, (address(vault), b)), junk);

        bytes4 e = IGainsVaultErrors.DiamondLayoutChanged.selector;
        vm.expectRevert(e);
        vault.totalAssets();
        vm.expectRevert(e);
        vault.checkRisk();
        vm.prank(manager);
        vm.expectRevert(e);
        vault.settle();
        vm.prank(guardian);
        vm.expectRevert(e);
        vault.flatten(ETH, 0, _px(ETH), type(uint256).max);

        vm.prank(guardian);
        vault.triggerEmergency();
        assertTrue(vault.emergency(), "the full stop is not blocked by the unreadable list");

        uint32[] memory ix = new uint32[](1);
        ix[0] = a;
        vm.prank(guardian);
        assertEq(vault.flattenIndices(ix, 0, _px(ETH)), 1, "ETH trade: close sent by index");
        diamond.fill(address(vault), diamond.orderCount(address(vault)) - 1, _px(ETH));
        ix[0] = b;
        vm.prank(guardian);
        assertEq(vault.flattenIndices(ix, 0, _px(BTC)), 1, "BTC trade: close sent by index");
        diamond.fill(address(vault), diamond.orderCount(address(vault)) - 1, _px(BTC));
        // once Gains' trades are readable again the closed ones drop out and the exit-only settle runs
        vm.clearMockedCalls();
        assertFalse(diamond.getTrade(address(vault), a).isOpen, "closed");
        assertFalse(diamond.getTrade(address(vault), b).isOpen, "closed");
        // an index that is not open is skipped, not a revert
        vm.prank(guardian);
        assertEq(vault.flattenIndices(ix, 0, _px(BTC)), 0, "nothing left to close");
        _redeem(alice, vault.balanceOf(alice));
        uint256 epoch = vault.currentEpoch();
        vm.prank(guardian);
        vault.settle();
        assertEq(vault.currentEpoch(), epoch + 1);
    }

    // ==================================================================
    // Approvals
    // ==================================================================
    /// @notice A diamond that pulls less than approved (here: nothing) never leaves a standing allowance.
    function test_INT_approvalClearedWhenDiamondPullsLess() public {
        (uint32 a,) = _funded();
        uint256 bal = usdc.balanceOf(address(vault));
        vm.mockCall(address(diamond), abi.encodeWithSelector(IGainsDiamond.openTrade.selector), "");
        vm.mockCall(address(diamond), abi.encodeWithSelector(IGainsDiamond.increasePositionSize.selector), "");
        vm.mockCall(address(diamond), abi.encodeWithSelector(IGainsDiamond.updateLeverage.selector), "");
        vm.startPrank(manager);
        vault.openTrade(_params(ETH, true, 1_000e6, 2_000));
        assertEq(usdc.allowance(address(vault), address(diamond)), 0, "open");
        vault.increaseTrade(a, 500e6, 1_000, _px(ETH), SLIP);
        assertEq(usdc.allowance(address(vault), address(diamond)), 0, "increase");
        vault.updateLeverage(a, 1_500);
        assertEq(usdc.allowance(address(vault), address(diamond)), 0, "leverage decrease");
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(vault)), bal, "nothing moved");
    }

    /// @notice updateLeverage(decrease) approves exactly Gains' delta (same integer formula) and the mock, which
    ///         pulls Gains' delta, consumes it to the wei for odd collateral / leverage pairs.
    function testFuzz_INT_leverageDecreaseDeltaExact(uint256 coll, uint256 lev, uint256 newLev) public {
        _deposit(alice, 500_000e6);
        _settle();
        _claim(alice);
        coll = bound(coll, 300e6, 20_000e6) + 7; // odd wei
        lev = bound(lev, 1_500, 20_000);
        newLev = bound(newLev, 1_100, lev - 1);
        uint32 idx = _open(vault, ETH, true, uint120(coll), uint24(lev));
        uint256 bal = usdc.balanceOf(address(vault));
        vm.prank(manager);
        vault.updateLeverage(idx, uint24(newLev));
        uint256 gainsDelta = (coll * lev) / newLev - coll;
        assertEq(bal - usdc.balanceOf(address(vault)), gainsDelta, "pulled = Gains' delta");
        assertEq(usdc.allowance(address(vault), address(diamond)), 0);
    }

    // ==================================================================
    // Native ETH
    // ==================================================================
    function test_INT_noNativeEthPaths() public {
        vm.deal(address(this), 10 ether);
        address[5] memory xs = [address(vault), address(vaultImpl), address(policy), address(platform), address(lens)];
        for (uint256 i; i < xs.length; ++i) {
            (bool ok,) = xs[i].call{value: 1}("");
            assertFalse(ok, "plain ETH refused");
            (ok,) = xs[i].call{value: 1}(hex"deadbeef");
            assertFalse(ok, "no payable fallback");
        }
    }

    /// @notice create forwards the whole msg.value (not just minAgentGas) to the agent: the factory keeps nothing.
    function test_INT_factoryForwardsAllEthToAgent() public {
        address creator = makeAddr("creator");
        address agentW = makeAddr("agentWallet");
        bytes32 salt = bytes32(uint256(9));
        vm.startPrank(platformOwner);
        platform.setLauncherAllowed(creator, true);
        platform.registerPlatformAgent(agentW, platform.predictVaultAddress(creator, salt)); // cold owner pre-bind
        vm.stopPrank();
        usdc.mint(creator, 10e6);
        vm.deal(creator, 2 ether);
        uint32[] memory assets = new uint32[](1);
        assets[0] = ETH;
        GainsVaultFactory.CreateParams memory p = GainsVaultFactory.CreateParams({
            name: "x",
            symbol: "x",
            owner: creator,
            manager: creator,
            feeRecipient: creator,
            managementFeeBps: 0,
            performanceFeeBps: 0,
            timelockDelay: 2 days,
            depositCap: 10_000e6,
            risk: _defaultRisk(),
            assets: assets,
            agent: agentW,
            agentSig: "",
            agentDeadline: 0,
            operator: address(0),
            hosted: true,
            seedUsdc: 1e6,
            salt: salt
        });
        vm.startPrank(creator);
        usdc.approve(address(platform), 1e6);
        platform.create{value: 1.5 ether}(p, GainsVaultFactory.PermitData(0, 0, 0, bytes32(0), bytes32(0)));
        vm.stopPrank();
        assertEq(address(platform).balance, 0, "factory keeps no ETH");
        assertEq(agentW.balance, 1.5 ether, "all of msg.value reaches the agent");
    }

    // ==================================================================
    // Reentrancy
    // ==================================================================
    /// @notice Feeds are read with STATICCALL: a feed that writes state fails, and the read is a named PriceStale.
    ///         Was `test_INT_feedsAreStaticcalled`; GR1-44: such an exceptional halt burned 63/64 of the NAV read's gas
    ///         (about 977M in the round 1 run). The feed call now forwards at most 200,000 gas: the read reverts
    ///         PriceStale having used a bounded amount of gas.
    function test_GR1_44_writingFeedRevertsPriceStaleWithBoundedGas() public {
        _funded();
        WritingFeed w = new WritingFeed();
        w.latestRoundData(); // control: works in a normal call
        vm.etch(address(ethFeed), address(w).code);
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.PriceStale.selector, uint256(ETH)));
        vault.totalAssets();
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = address(vault).staticcall{gas: 50_000_000}(abi.encodeCall(GainsVault.totalAssets, ()));
        uint256 used = g - gasleft();
        console2.log("gas used by a NAV read with a halting feed", used);
        assertFalse(ok);
        assertEq(keccak256(ret), keccak256(abi.encodeWithSelector(GainsPrice.PriceStale.selector, uint256(ETH))), "PriceStale");
        assertLt(used, 2_000_000, "GR1-44: bounded, not 63/64 of the 50M given");
    }

    function _evilVault(IERC20 asset, EvilDiamond evil) internal returns (GainsVault v2) {
        uint32[] memory assets = new uint32[](2);
        assets[0] = BTC;
        assets[1] = ETH;
        v2 = GainsVault(Clones.clone(address(vaultImpl)));
        GainsVaultPolicy p2 = GainsVaultPolicy(Clones.clone(address(policyImpl)));
        p2.initialize(owner, _defaultRisk(), assets, 2 days, address(platform), address(v2));
        InitParams memory ip = _standaloneParams(p2);
        ip.asset = asset;
        ip.diamond = IGainsDiamond(address(evil));
        v2.initialize(ip);
        evil.setVault(v2);
    }

    /// @notice Every diamond read is a STATICCALL (IGainsDiamond declares them view): a diamond that tries to reenter
    ///         from a NAV read cannot change state, so settle / checkRisk cannot be reentered through the venue value.
    function test_INT_diamondReadsCannotReenter() public {
        EvilDiamond evil = new EvilDiamond(IERC20(address(usdc)));
        GainsVault v2 = _evilVault(IERC20(address(usdc)), evil);
        // control: the probe call itself succeeds outside a static context
        v2.cancelTimedOut(0);
        vm.prank(alice);
        usdc.approve(address(v2), type(uint256).max);
        vm.prank(alice);
        v2.requestDeposit(1_000e6, alice);
        _skip(1 hours); // fix round: a settle that prices deposits runs 1 h into the epoch (GR1-02)
        vm.prank(manager);
        v2.settle(); // runs checkRisk + settle: every venue read probed a reentry, none succeeded
        assertEq(v2.currentEpoch(), 1);
    }

    /// @notice Request calls are CALLs while an exact approval is outstanding; a hostile diamond reentering from
    ///         openTrade reaches only the permissionless entry points (role checks stop settle / openTrade).
    ///         Trust-bound: such a diamond could simply keep the collateral (trust T2), so this is no extra exposure.
    function test_INT_diamondRequestReentryReachesOnlyPermissionless() public {
        EvilDiamond evil = new EvilDiamond(IERC20(address(usdc)));
        GainsVault v2 = _evilVault(IERC20(address(usdc)), evil);
        vm.prank(alice);
        usdc.approve(address(v2), type(uint256).max);
        vm.prank(alice);
        v2.requestDeposit(10_000e6, alice);
        _skip(1 hours); // fix round: minimum epoch age for a settle that prices deposits (GR1-02)
        vm.prank(manager);
        v2.settle();
        evil.setAttack(true);
        vm.prank(manager);
        v2.openTrade(_params(ETH, true, 1_000e6, 2_000));
        assertTrue(evil.probed());
        assertFalse(evil.settleOk(), "settle not reachable (Unauthorized)");
        assertFalse(evil.openOk(), "openTrade not reachable (Unauthorized)");
        assertFalse(evil.depositOk(), "the diamond holds no allowance from itself");
        assertTrue(evil.timedOutOk(), "permissionless cancelTimedOut reachable, harmless");
        assertEq(usdc.allowance(address(v2), address(evil)), 0, "approval cleared");
    }

    /// @notice A hooked token reentering from requestDeposit's transferFrom (lock held): requestDeposit is refused
    ///         (Reentrancy), the unguarded cancelDepositRequest goes through and the books stay exact.
    ///         Fix round WP2 (GR2-FF-02): the request is booked BEFORE the transfer, so the reentrant cancel sees and
    ///         refunds the whole request, the 300 still in flight included, out of the vault's balance (here alice's
    ///         queued deposit covers it); the transfer then brings the 300 in. Net: the attacker ends where it started,
    ///         nothing of its stays queued, and the vault holds exactly the queue (alice's). Without other assets in the
    ///         vault the cancel cannot pay the 800 and reverts, which leaves the 800 request whole (the second case).
    function test_INT_hookTokenReentryFromDeposit() public {
        HookUSDC hook = new HookUSDC();
        EvilDiamond evil = new EvilDiamond(IERC20(address(hook)));
        GainsVault v2 = _evilVault(IERC20(address(hook)), evil);
        HookAttacker att = new HookAttacker(v2, hook);
        hook.mint(address(att), 10_000e6);
        hook.mint(alice, 5_000e6);
        vm.prank(alice);
        hook.approve(address(v2), type(uint256).max);
        vm.prank(alice);
        v2.requestDeposit(5_000e6, alice);
        att.deposit(500e6);
        hook.setHooked(address(att), true);
        att.setMode(1);
        att.deposit(300e6);
        assertTrue(att.r1(), "cancelDepositRequest reentered");
        assertFalse(att.r2(), "requestDeposit refused");
        assertEq(bytes4(att.err2()), IGainsVaultErrors.Reentrancy.selector);
        (, uint256 dep,) = v2.requests(address(att));
        assertEq(dep, 0, "the cancel took the whole booked request, the in-flight 300 included");
        assertEq(v2.pendingDepositAssets(), 5_000e6, "queue = alice's request");
        assertEq(hook.balanceOf(address(v2)), 5_000e6, "vault holds exactly the queue");
        assertEq(hook.balanceOf(address(att)), 10_000e6, "attacker got back exactly what it paid in");

        // the same with nothing else in the vault: the cancel cannot pay 800 out of 500 and reverts; the request is whole
        GainsVault v3 = _evilVault(IERC20(address(hook)), new EvilDiamond(IERC20(address(hook))));
        HookAttacker att3 = new HookAttacker(v3, hook);
        hook.mint(address(att3), 10_000e6);
        att3.deposit(500e6);
        hook.setHooked(address(att3), true);
        att3.setMode(1);
        att3.deposit(300e6);
        assertFalse(att3.r1(), "the cancel cannot pay the in-flight part");
        (, dep,) = v3.requests(address(att3));
        assertEq(dep, 800e6, "both deposits queued");
        assertEq(v3.pendingDepositAssets(), 800e6, "queue = request");
        assertEq(hook.balanceOf(address(v3)), 800e6, "vault holds exactly the queue");
    }

    /// @notice A hooked token reentering from claim's payout (no lock): a second claim, cancelRedeemRequest and
    ///         cancelDepositRequest pay nothing; state is zeroed before the transfer (CEI).
    function test_INT_hookTokenReentryFromClaim() public {
        HookUSDC hook = new HookUSDC();
        EvilDiamond evil = new EvilDiamond(IERC20(address(hook)));
        GainsVault v2 = _evilVault(IERC20(address(hook)), evil);
        HookAttacker att = new HookAttacker(v2, hook);
        hook.mint(address(att), 10_000e6);
        hook.mint(alice, 10_000e6);
        vm.prank(alice);
        hook.approve(address(v2), type(uint256).max);
        vm.prank(alice);
        v2.requestDeposit(5_000e6, alice);
        att.deposit(1_000e6);
        _skip(1 hours); // fix round: minimum epoch age for a settle that prices deposits (GR1-02)
        vm.prank(manager);
        v2.settle();
        att.claim();
        v2.claim(alice);
        att.redeemAll();
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _warp(vm.getBlockTimestamp());
        v2.checkRisk();
        vm.prank(manager);
        v2.settle();
        hook.setHooked(address(att), true);
        att.setMode(2);
        uint256 before = hook.balanceOf(address(att));
        uint256 reserve = v2.claimableRedeemAssets(); // only the attacker's redemption is reserved
        assertApproxEqAbs(reserve, 1_000e6, 0.01e6, "~1,000 less the 2 h management fee");
        att.claim();
        uint256 got = hook.balanceOf(address(att)) - before;
        assertEq(got, reserve, "paid exactly once");
        assertEq(v2.claimableRedeemAssets(), 0, "reserve fully consumed, nothing double paid");
        assertGe(hook.balanceOf(address(v2)), v2.pendingDepositAssets() + v2.deferredDepositAssets() + v2.claimableRedeemAssets());
        assertEq(v2.balanceOf(address(att)), 0);
    }
}
