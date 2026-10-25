// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "./KeysForkBase.sol";

/// @notice GR2-KEY-02 (measurement): does a TP/SL the agent sets without any policy check let the in-the-money PnL
///         of a vault trade leave to the Gains pool at a price the agent chose, rather than closing at the market?
///         The brief's specific case: a TP set JUST PAST the open price on a deep in-the-money long, and an SL set
///         just inside the market. The test asserts the vault's realized payout against a plain market close at the
///         same oracle price. If the two are equal (within fees) the agent gained nothing by choosing the trigger;
///         if the TP pays materially less, value left to the pool.
///
///         Gains semantics (TradingCallbacksUtils._validateTriggerCloseOrderCallback): a TP/SL executes EXACTLY at
///         the trigger only when the oracle range since the trigger's last update actually reached it
///         (low <= trigger <= high, with the lookback starting at tp/slLastUpdatedBlock). Otherwise it is NOT_HIT
///         (nothing) or SLIPPAGE (nothing). This test measures that on the real diamond.
contract KeysTpSlForkTest is KeysForkBase {
    bytes32 internal constant TRIGGER_CANCELED = keccak256("TriggerOrderCanceled((address,uint32),address,uint8,uint8)");
    uint8 internal constant T_TP = 4;
    uint8 internal constant T_SL = 5;

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        _depositSettle(alice, 100_000e6);
        // GR2-KEY-01b (WP5 port): every test here opens a 250k ETH long, above 1 % of ETH's skew depth (about 142k at
        // 517,076,707); GR2-KEY-02 is about TP / SL execution, not the pair cap, so ETH's cap is raised to the 10 %
        // maximum (the guardian's 31-day raise). With the 1 % cap the three tests failed OrderRejected("pair depth")
        // (WP5 fork2 log).
        _raisePairCapToMax(ETH);
    }

    function _trigger(address caller, uint8 orderType, uint32 idx) internal returns (Vm.Log[] memory logs) {
        address link = IGainsExtraK(address(DIAMOND)).getChainlinkToken();
        deal(link, caller, 10e18);
        vm.prank(caller);
        IERC20(link).approve(address(DIAMOND), type(uint256).max);
        uint256 packed = uint256(orderType) | (uint256(uint160(address(v))) << 8) | (uint256(idx) << 168);
        vm.recordLogs();
        vm.prank(caller);
        IGainsExtraK(address(DIAMOND)).triggerOrder(packed);
        logs = vm.getRecordedLogs();
    }

    function _limitExecuted(Vm.Log[] memory fill)
        internal
        pure
        returns (uint8 orderType, uint256 oraclePrice, uint256 sent, bool exact)
    {
        Vm.Log memory l = _find(fill, G.LimitExecuted.selector);
        G.Trade memory t;
        uint256 mkt;
        (, t,, orderType, oraclePrice, mkt,,,, sent,, exact) = abi.decode(
            l.data,
            (G.Id, G.Trade, address, uint8, uint256, uint256, uint256, G.TradePriceImpact, int256, uint256, uint256, bool)
        );
    }

    /// @dev Deep in-the-money long (price rose a lot after the open), TP set JUST PAST the (old) open price, i.e. far
    ///      below the current market. If Gains filled this at the trigger, the vault would realise almost no gain and
    ///      hand the ITM PnL to the pool. Assert it does NOT: either NOT_HIT (trade stays open) or a market close at C.
    function test_GR2_KEY_02_itmLongTpJustPastOpen_doesNotFillAtTrigger() public {
        uint64 cOpen = cl[ETH_USD];
        uint32 idx = _openVault(mgr, ETH, true, 10_000e6, 25_000, cOpen); // 250k notional, 25x; opens at cOpen
        // price rises 8% -> the long is deep in the money
        uint64 cNow = cOpen * 108 / 100;
        _setCl(ETH_USD, cNow);
        _roll(2);
        uint256 navItm = _nav();
        // TP just past the open price (0.1% above open): far BELOW the current market cNow
        uint64 tp = cOpen * 1_001 / 1_000;
        vm.prank(mgr);
        v.setSlTp(idx, 0, tp);
        assertEq(_trade(idx).tp, tp, "Gains stored the wrong-side TP unchecked");
        _roll(5);
        Vm.Log[] memory req = _trigger(thief, T_TP, idx);
        _roll(1);
        // oracle range tight around the CURRENT market, nowhere near the trigger
        Vm.Log[] memory fill = _fillAt(req, cNow, cNow * 10_005 / 10_000, cNow * 9_995 / 10_000);
        if (_count(fill, G.LimitExecuted.selector) > 0) {
            (uint8 ot, uint256 oracle, uint256 sent, bool exact) = _limitExecuted(fill);
            assertEq(ot, T_TP);
            assertFalse(exact, "TP must NOT be an exact execution at the far trigger");
            assertEq(oracle, cNow, "closed at the current oracle price, a market close");
            // a market close of a +8% long pays far more than the collateral: value stayed with the vault
            assertGe(_nav() + 1, navItm * 99 / 100, "NAV not handed to the pool");
            console2.log("ITM long wrong-side TP: market close, sent", sent, "navItm", navItm);
        } else {
            (,, uint8 reason) = abi.decode(_find(fill, TRIGGER_CANCELED).data, (G.Id, uint8, uint8));
            assertTrue(_trade(idx).isOpen, "NOT_HIT: trade stays open, nothing left to the pool");
            console2.log("ITM long wrong-side TP: cancelled, reason", reason);
        }
    }

    /// @dev SL set just INSIDE the market on an in-the-money long (SL above the open but below current): Gains stores
    ///      it, a bot triggers, and if the market has not fallen to it since the update it is NOT_HIT / market close.
    function test_GR2_KEY_02_itmLongSlJustInside_doesNotFillAtTrigger() public {
        uint64 cOpen = cl[ETH_USD];
        uint32 idx = _openVault(mgr, ETH, true, 10_000e6, 25_000, cOpen);
        uint64 cNow = cOpen * 108 / 100;
        _setCl(ETH_USD, cNow);
        _roll(2);
        uint256 navItm = _nav();
        uint64 sl = cOpen * 1_005 / 1_000; // above open, far below current market
        vm.prank(mgr);
        v.setSlTp(idx, sl, 0);
        assertEq(_trade(idx).sl, sl, "Gains stored the SL unchecked");
        _roll(5);
        Vm.Log[] memory req = _trigger(thief, T_SL, idx);
        _roll(1);
        Vm.Log[] memory fill = _fillAt(req, cNow, cNow * 10_005 / 10_000, cNow * 9_995 / 10_000);
        if (_count(fill, G.LimitExecuted.selector) > 0) {
            (uint8 ot, uint256 oracle,, bool exact) = _limitExecuted(fill);
            assertEq(ot, T_SL);
            assertFalse(exact, "SL must not be exact at the far trigger");
            assertEq(oracle, cNow, "market close at C");
            assertGe(_nav() + 1, navItm * 99 / 100, "NAV not handed to the pool");
        } else {
            (,, uint8 reason) = abi.decode(_find(fill, TRIGGER_CANCELED).data, (G.Id, uint8, uint8));
            assertTrue(_trade(idx).isOpen, "NOT_HIT / SLIPPAGE: trade stays open");
            console2.log("ITM long SL just inside: cancelled, reason", reason);
        }
    }

    /// @dev Control: a plain market close of the same +8% long at C, for the payout comparison the brief asks for.
    function test_GR2_KEY_02_control_marketCloseOfItmLongPaysFull() public {
        uint64 cOpen = cl[ETH_USD];
        uint32 idx = _openVault(mgr, ETH, true, 10_000e6, 25_000, cOpen);
        _passHold(); // GR2-KEY-01b (WP5 port): the manager's close waits the 10-minute minimum hold
        uint64 cNow = cOpen * 108 / 100;
        _setCl(ETH_USD, cNow);
        _roll(2);
        uint256 b0 = _usdc(address(v));
        uint256 sent = _closeVault(mgr, idx, cNow);
        console2.log("market close of +8% 25x long: USDC returned", sent, "collateral was", uint256(10_000e6));
        assertGt(sent, 10_000e6, "an ITM long returns more than its collateral at a market close");
        assertEq(_usdc(address(v)) - b0, sent);
    }
}
