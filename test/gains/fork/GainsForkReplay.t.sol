// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "./GainsForkBase.sol";
import {NavCalc} from "../spike/NavCalc.sol";

/// @notice Stage 0 C against real Gains oracle fills (Arbitrum Sepolia oracles have not answered since
///         2026-09-17, see STAGE0.md B). Each case forks Arbitrum One at the fill transaction (state just before it),
///         evaluates NavCalc for the closed trade at (1) the oracle price of the fill and (2) Chainlink at that state,
///         and compares both with the USDC the trader actually received (event amount).
///         Cases: the most recent USDC closes on pairs 0, 1, 33 before block 515223274, collected from the diamond's
///         MarketExecuted / PositionSizeDecreaseExecuted / LimitExecuted logs.
contract GainsForkReplayTest is GainsForkBase {
    enum Kind { MARKET, PARTIAL, TP, SL, LIQ }

    struct Case {
        Kind kind;
        uint16 pair;
        uint256 block_;
        bytes32 tx_;
        address trader;
        uint32 index;
        uint64 oraclePrice;
        uint256 paid;
        uint120 collateralDelta;
    }

    Case[] internal c;

    function setUp() public virtual override {
        if (bytes(vm.envOr("ARBITRUM_RPC_URL", string(""))).length == 0) {
            vm.skip(true);
            return;
        }
        c.push(Case(Kind.PARTIAL, 0, 515214451, 0x8d6d3bfdadec64ed9894de5d74aef19d1cf18d0270a57a7f6ea454d07269848f, 0xDE23E9483832c24bDBA171cB9FA63D1Aa0D45588, 1, 822073830000000, 682773, 821466));
        c.push(Case(Kind.MARKET, 0, 515214957, 0x25b12eadeb992c93eea20654dc2f450090a23911d9c025ec0ca90ff81568de3b, 0xDE23E9483832c24bDBA171cB9FA63D1Aa0D45588, 1, 822579710000000, 999270, 0));
        c.push(Case(Kind.MARKET, 1, 515221565, 0x5d1a1d1249bb113094623f2672af671eddb12a6ec8af8617f25f3d90ddc031c4, 0x9D086cF6F0DebCfD5852b6D7989664FE1d73aEAe, 1598, 24425564000000, 7086055, 0));
        c.push(Case(Kind.MARKET, 33, 515203383, 0x2e6b1370922835b34fc837999a288a475ec83c6666245ba4de0cd37f45c93bd7, 0xfbfc6911Ae994D937324201209096A93435863cf, 2026, 1052500000000, 142046556, 0));
        c.push(Case(Kind.MARKET, 1, 515203486, 0xbeda0cdd1865dbfb8c5c387b8bab8a64327cd7f6b989b9e4f3d4a1af730b1f88, 0x9D086cF6F0DebCfD5852b6D7989664FE1d73aEAe, 1597, 24394658000000, 8764497, 0));
        c.push(Case(Kind.TP, 1, 515204509, 0xe5a6b49f5141085b798560d90c10d992a4e782f680a7f834aa358c9a804dcbdf, 0x9D086cF6F0DebCfD5852b6D7989664FE1d73aEAe, 1596, 24371214198872, 9411744, 0));
        c.push(Case(Kind.MARKET, 33, 515197984, 0x7b1745250ff79bd9c9d76b7197aa4efc2460ab6d6e8fe7d9cb086fbba5be6380, 0x9D086cF6F0DebCfD5852b6D7989664FE1d73aEAe, 1588, 1057125300000, 6965531, 0));
        c.push(Case(Kind.MARKET, 1, 515200985, 0xa2d49e5e26776f85af780339311291fbf5a387f833e8274d0b830b12def91938, 0x9D086cF6F0DebCfD5852b6D7989664FE1d73aEAe, 1592, 24488796000000, 6813693, 0));
        c.push(Case(Kind.LIQ, 33, 515203168, 0x0196926a0b16f4be6f671d69f576b76560c4542b1ef2971e1a0dc4ddd27b230e, 0x4925C57cB143A803291F3D7f6c72De06697B3BD8, 528, 1052777756701, 0, 0));
        c.push(Case(Kind.PARTIAL, 0, 515183328, 0x4e23b67b4ba8d2feafd768d27d9ba2adec1805de9d792818959ba7479f3bbb71, 0x83e3624B5C9676Ed96B6EE340F5b158E0Be5db44, 10, 822360450000000, 555897, 702526));
        c.push(Case(Kind.SL, 0, 515187815, 0x006547ff8b766cbd891c99506c53b8f6f3bc1a58681a022fe86c117d930b8d2b, 0x310a5086973Bc12D7ae6b8fAb51946AE82395123, 67, 824384958728106, 430366884, 0));
        c.push(Case(Kind.SL, 1, 515188003, 0xccdff72e35785b79fae50809e5c08033e7afcfc7ffb9df1aa1f0f748367ca786, 0xD70D9d88c54ef8584f66351e06Faa653812eFFD0, 234, 24635873058586, 2940895, 0));
        c.push(Case(Kind.PARTIAL, 0, 515192064, 0x085cc59f85d4bb011c2dc649097b58e1c04dc99ae68a0c24973adee609b678ec, 0xDE23E9483832c24bDBA171cB9FA63D1Aa0D45588, 0, 823114280000000, 834364, 988614));
        c.push(Case(Kind.SL, 0, 515173227, 0x410007277829c4676ffcba4b42127f5a7e3b8c704f0246c97d3b8e681de100d4, 0xea908e6c26A2eFAeB5cBBdDD2fB9Ce6ee3a35D4A, 1073, 820039208724116, 1828050, 0));
        c.push(Case(Kind.PARTIAL, 0, 515133514, 0xb42c2f993984602f581e4063b5bf84025b2f307115f180984238bc3abd3b5e43, 0xA0A0b6A691eBF91E4C723aEF6Fb387d74484bE0b, 428, 823593560000000, 125468725, 71286922));
        c.push(Case(Kind.TP, 33, 515095039, 0x7bd2ed5f27dbde9b20a73955cabad2a6415c6667abfb563e55cfc0d6c33bbbb3, 0x9bbC36d40c9C895f0CDEbE90b64A44C3898612f2, 310, 1058961529215, 136362053, 0));
        c.push(Case(Kind.LIQ, 1, 515074227, 0x5d6b4813dca95e36f44aaaa24a6ac3dd7ecb8b165a5801b3923c8b5db111f96f, 0x466eA343585A96Af51F8d98e6981aF043866D148, 281, 23332922393981, 0, 0));
        c.push(Case(Kind.LIQ, 0, 515078357, 0x7204d15feb9835452bdb740c5f29eccfd830f65811c40c09fc2cb2e2cd22eacd, 0xea908e6c26A2eFAeB5cBBdDD2fB9Ce6ee3a35D4A, 1070, 799661049366821, 0, 0));
        c.push(Case(Kind.TP, 0, 515078450, 0xb1c78c88218b3648ad03e77423a20cd47bca7b7f3a1051869baf2ab5237c4ce8, 0x0ba80Bd575C61eCDbA729A7f4f2D23Df54c48193, 2227, 797996587483304, 4038657248, 0));
    }

    function _feed(uint16 pair) internal pure returns (address) {
        if (pair == BTC) return 0x6ce185860a4963106506C203335A2910413708e9;
        if (pair == ETH) return 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
        return 0x24ceA4b8ce57cdA5058b924B9B9987992450590c;
    }

    function _at(Case memory k) internal {
        vm.createSelectFork("arbitrum", k.tx_);
        vm.etch(ARB_SYS, hex"00");
        vm.mockCall(ARB_SYS, abi.encodeWithSelector(IArbSys.arbBlockNumber.selector), abi.encode(k.block_));
    }

    function _value(Case memory k, uint64 price) internal view returns (NavCalc.Breakdown memory) {
        return k.kind == Kind.PARTIAL
            ? NavCalc.partialClose(DIAMOND, k.trader, k.index, price, k.collateralDelta)
            : NavCalc.value(DIAMOND, k.trader, k.index, price);
    }

    function _bps(int256 err, uint256 base) internal pure returns (int256) {
        return base == 0 ? int256(0) : err * 10_000 / int256(base);
    }

    function test_C_replay_market_and_partial_closes_exact_at_oracle_price() public {
        for (uint256 i; i < c.length; i++) {
            Case memory k = c[i];
            if (k.kind != Kind.MARKET && k.kind != Kind.PARTIAL) continue;
            _at(k);
            NavCalc.Breakdown memory b = _value(k, k.oraclePrice);
            uint64 cl = _chainlink1e10(_feed(k.pair));
            NavCalc.Breakdown memory bc = _value(k, cl);
            _log(k, b, bc, cl);
            assertEq(b.value, int256(k.paid), "NavCalc at the oracle price == USDC paid");
        }
    }

    function test_C_replay_trigger_closes_tp_sl_liq() public {
        for (uint256 i; i < c.length; i++) {
            Case memory k = c[i];
            if (k.kind == Kind.MARKET || k.kind == Kind.PARTIAL) continue;
            _at(k);
            G.Trade memory t = DIAMOND.getTrade(k.trader, k.index);
            uint64 trigger = k.kind == Kind.TP ? t.tp : k.kind == Kind.SL ? t.sl : k.oraclePrice;
            NavCalc.Breakdown memory b = _value(k, trigger);
            uint64 cl = _chainlink1e10(_feed(k.pair));
            NavCalc.Breakdown memory bc = _value(k, cl);
            console2.log("trigger price used (tp / sl / oracle for liq)", trigger);
            _log(k, b, bc, cl);
            if (k.kind == Kind.LIQ) assertEq(k.paid, 0);
        }
    }

    function _log(Case memory k, NavCalc.Breakdown memory b, NavCalc.Breakdown memory bc, uint64 cl) internal pure {
        string[5] memory names = ["MARKET", "PARTIAL", "TP", "SL", "LIQ"];
        console2.log(names[uint8(k.kind)], k.pair, k.block_);
        console2.logBytes32(k.tx_);
        console2.log("  trader / index", k.trader, k.index);
        console2.log("  collateral, positionSize, leverage-implied", b.collateral, b.positionSizeCollateral);
        console2.log("  oracle price, chainlink price, price diff bps:", k.oraclePrice, cl);
        console2.logInt(_bps(int256(uint256(cl)) - int256(uint256(k.oraclePrice)), k.oraclePrice));
        console2.log("  paid", k.paid);
        console2.log("  NavCalc @fill price, error USDC 1e6, error bps of paid:");
        console2.logInt(b.value);
        console2.logInt(b.value - int256(k.paid));
        console2.logInt(_bps(b.value - int256(k.paid), k.paid));
        console2.log("  NavCalc @Chainlink, error USDC 1e6, error bps of paid:");
        console2.logInt(bc.value);
        console2.logInt(bc.value - int256(k.paid));
        console2.logInt(_bps(bc.value - int256(k.paid), k.paid));
    }
}
