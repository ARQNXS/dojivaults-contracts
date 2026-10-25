// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {R2Base} from "../fixes/R2Base.sol";
import {GainsVault} from "../../../../src/gains/GainsVault.sol";
import {GainsNav} from "../../../../src/gains/GainsNav.sol";
import {IGainsDiamond, GTrade} from "../../../../src/gains/IGainsDiamond.sol";
import {IGainsVaultErrors} from "../../../../src/gains/GainsTypes.sol";

/// @notice VERIFY-R2 item 2 (GV-02) on the mock harness: every value of Gains' real PendingOrderType enum
///         (ITradingStorage, GNSTradingInteractions 0x66B2...D327 verified sources: 0 MARKET_OPEN .. 13
///         MANUAL_NEGATIVE_PNL_REALIZATION), each with the `trade` fields Gains stores for it, plus values Gains does not
///         define. For each: does settle wait (ordersPending, venue().blocking), and what NAV counts for it.
contract VerifyR2MockTest is R2Base {
    struct Case {
        uint8 kind;
        uint120 coll; // pendingOrder.trade.collateralAmount as Gains stores it
        uint24 lev; // pendingOrder.trade.leverage as Gains stores it
        bool refersToTrade; // trade.index is the open trade, trade.pairIndex 0 (GR1-28)
        bool blocks;
        uint120 held; // what NAV adds (before the gov fee)
        string what;
    }

    function test_R2_GV02_everyRealOrderType_classified() public {
        _seed(vault, alice, 100_000e6);
        uint32 idx = _open(vault, ETH, true, 10_000e6, 20_000); // an open 20x ETH long
        uint256 base = vault.venue().value;
        uint256 fee = GainsNav.minGovFee(IGainsDiamond(address(diamond)), vault.collateralIndex(), ETH);

        Case[] memory c = new Case[](19);
        // stored under the vault (the vault or its delegate created them)
        c[0] = Case(GTrade.MARKET_OPEN, 15_000e6, 20_000, false, true, 15_000e6, "0 MARKET_OPEN: full collateral");
        c[1] = Case(GTrade.MARKET_CLOSE, 0, 0, true, false, 0, "1 MARKET_CLOSE: collateral 0");
        c[2] = Case(GTrade.UPDATE_LEVERAGE, 5_000e6, 10_000, true, true, 5_000e6, "7 UPDATE_LEVERAGE decrease 20x -> 10x: the delta paid in");
        c[3] = Case(GTrade.UPDATE_LEVERAGE, 3_333e6, 30_000, true, false, 0, "7 UPDATE_LEVERAGE increase 20x -> 30x: the delta paid out at the fill");
        c[4] = Case(GTrade.MARKET_PARTIAL_OPEN, 2_000e6, 10_000, true, true, 2_000e6, "8 MARKET_PARTIAL_OPEN with collateral");
        c[5] = Case(GTrade.MARKET_PARTIAL_OPEN, 0, 5_000, true, false, 0, "8 MARKET_PARTIAL_OPEN leverage only");
        c[6] = Case(GTrade.MARKET_PARTIAL_CLOSE, 1_000e6, 0, true, false, 0, "9 MARKET_PARTIAL_CLOSE collateral delta");
        c[7] = Case(GTrade.MARKET_PARTIAL_CLOSE, 0, 5_000, true, false, 0, "9 MARKET_PARTIAL_CLOSE leverage delta");
        c[8] = Case(10, 0, 0, true, true, 0, "10 PARAM_UPDATE (deprecated, no creator): fail closed");
        c[9] = Case(GTrade.PNL_WITHDRAWAL, 750e6, 0, true, true, 750e6, "11 PNL_WITHDRAWAL (the vault never creates it): fail closed, the PnL amount counted");
        // stored under the CALLER by Gains (a bot's trigger, anyone's manual realization): never in the vault's list.
        // Classified anyway, should a Gains upgrade ever file them under the trader.
        c[10] = Case(GTrade.LIMIT_OPEN, 0, 0, true, false, 0, "2 LIMIT_OPEN trigger");
        c[11] = Case(GTrade.STOP_OPEN, 0, 0, true, false, 0, "3 STOP_OPEN trigger");
        c[12] = Case(GTrade.TP_CLOSE, 0, 0, true, false, 0, "4 TP_CLOSE trigger");
        c[13] = Case(GTrade.SL_CLOSE, 0, 0, true, false, 0, "5 SL_CLOSE trigger");
        c[14] = Case(GTrade.LIQ_CLOSE, 0, 0, true, false, 0, "6 LIQ_CLOSE trigger");
        c[15] = Case(12, 0, 0, true, true, 0, "12 MANUAL_HOLDING_FEES_REALIZATION: fail closed");
        c[16] = Case(13, 0, 0, true, true, 0, "13 MANUAL_NEGATIVE_PNL_REALIZATION: fail closed");
        // not defined by Gains
        c[17] = Case(14, 1_000e6, 10_000, true, true, 1_000e6, "14 undefined: fail closed");
        c[18] = Case(255, 1_000e6, 10_000, true, true, 1_000e6, "255 undefined: fail closed");

        IGainsDiamond.PendingOrder[] memory one = new IGainsDiamond.PendingOrder[](1);
        uint32 next = diamond.orderCount(address(vault));
        for (uint256 i; i < c.length; ++i) {
            IGainsDiamond.PendingOrder memory o = one[0];
            o.user = address(vault);
            o.index = next;
            o.isOpen = true;
            o.orderType = c[i].kind;
            o.createdBlock = uint32(vm.getBlockNumber());
            o.trade.user = address(vault);
            o.trade.index = c[i].refersToTrade ? idx : 100;
            o.trade.pairIndex = c[i].refersToTrade ? 0 : ETH;
            o.trade.collateralIndex = vault.collateralIndex();
            o.trade.collateralAmount = c[i].coll;
            o.trade.leverage = c[i].lev;
            o.trade.long = true;
            // GR2-LIVE-01 (ported in fix round WP2): the vault reads orders by index, not getPendingOrders. The case is
            // the next order index Gains would assign: the counter is raised by one and that index answers with it.
            vm.mockCall(
                address(diamond),
                abi.encodeCall(IGainsDiamond.getCounters, (address(vault), uint8(1))),
                abi.encode(IGainsDiamond.Counter(next + 1, 0, 0))
            );
            vm.mockCall(address(diamond), abi.encodeCall(IGainsDiamond.getPendingOrder, (IGainsDiamond.Id(address(vault), next))), abi.encode(o));

            assertEq(vault.ordersPending(), c[i].blocks, c[i].what);
            assertEq(vault.venue().blocking, c[i].blocks ? 1 : 0, c[i].what);
            uint256 expected = base + (c[i].held > fee ? c[i].held - fee : 0);
            assertEq(vault.venue().value, expected, c[i].what);
            if (c[i].blocks) {
                vm.prank(manager);
                vm.expectRevert(IGainsVaultErrors.OrdersPending.selector);
                vault.settle();
            }
        }
    }
}
