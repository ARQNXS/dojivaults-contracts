// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "../../../gains/fork/GainsForkBase.sol";
import {IGainsDiamond} from "../../../../src/gains/IGainsDiamond.sol";
import {NavHarness} from "./NavForkBase.sol";
import {NavDump} from "./NavDump.sol";

/// @notice Differential NAV on recorded real mainnet closes (round 1 review, 3.1). The 19 real fills of
///         test/gains/fork/GainsForkReplay.t.sol (block, trader, index, oracle price, USDC paid): fork at the fill tx
///         (state just before it), dump the trade's raw close inputs and GainsNav.tradeValue at the fill price and at
///         Chainlink, plus the real payout. Partial closes are skipped (GainsNav values whole trades only).
///         A normal run writes nothing; with NAV_DIFF_DUMP=1 the output goes to ./deployments/audit-nav-diff-replay.json,
///         which is then copied to contracts/audit/gains/nav/data/ (the committed copy).
contract NavReplayForkTest is GainsForkBase {
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

    function setUp() public override {
        if (bytes(vm.envOr("ARBITRUM_RPC_URL", string(""))).length == 0) {
            vm.skip(true);
            return;
        }
        c.push(Case(Kind.MARKET, 0, 515214957, 0x25b12eadeb992c93eea20654dc2f450090a23911d9c025ec0ca90ff81568de3b, 0xDE23E9483832c24bDBA171cB9FA63D1Aa0D45588, 1, 822579710000000, 999270, 0));
        c.push(Case(Kind.MARKET, 1, 515221565, 0x5d1a1d1249bb113094623f2672af671eddb12a6ec8af8617f25f3d90ddc031c4, 0x9D086cF6F0DebCfD5852b6D7989664FE1d73aEAe, 1598, 24425564000000, 7086055, 0));
        c.push(Case(Kind.MARKET, 33, 515203383, 0x2e6b1370922835b34fc837999a288a475ec83c6666245ba4de0cd37f45c93bd7, 0xfbfc6911Ae994D937324201209096A93435863cf, 2026, 1052500000000, 142046556, 0));
        c.push(Case(Kind.MARKET, 1, 515203486, 0xbeda0cdd1865dbfb8c5c387b8bab8a64327cd7f6b989b9e4f3d4a1af730b1f88, 0x9D086cF6F0DebCfD5852b6D7989664FE1d73aEAe, 1597, 24394658000000, 8764497, 0));
        c.push(Case(Kind.TP, 1, 515204509, 0xe5a6b49f5141085b798560d90c10d992a4e782f680a7f834aa358c9a804dcbdf, 0x9D086cF6F0DebCfD5852b6D7989664FE1d73aEAe, 1596, 24371214198872, 9411744, 0));
        c.push(Case(Kind.MARKET, 33, 515197984, 0x7b1745250ff79bd9c9d76b7197aa4efc2460ab6d6e8fe7d9cb086fbba5be6380, 0x9D086cF6F0DebCfD5852b6D7989664FE1d73aEAe, 1588, 1057125300000, 6965531, 0));
        c.push(Case(Kind.MARKET, 1, 515200985, 0xa2d49e5e26776f85af780339311291fbf5a387f833e8274d0b830b12def91938, 0x9D086cF6F0DebCfD5852b6D7989664FE1d73aEAe, 1592, 24488796000000, 6813693, 0));
        c.push(Case(Kind.LIQ, 33, 515203168, 0x0196926a0b16f4be6f671d69f576b76560c4542b1ef2971e1a0dc4ddd27b230e, 0x4925C57cB143A803291F3D7f6c72De06697B3BD8, 528, 1052777756701, 0, 0));
        c.push(Case(Kind.SL, 0, 515187815, 0x006547ff8b766cbd891c99506c53b8f6f3bc1a58681a022fe86c117d930b8d2b, 0x310a5086973Bc12D7ae6b8fAb51946AE82395123, 67, 824384958728106, 430366884, 0));
        c.push(Case(Kind.SL, 1, 515188003, 0xccdff72e35785b79fae50809e5c08033e7afcfc7ffb9df1aa1f0f748367ca786, 0xD70D9d88c54ef8584f66351e06Faa653812eFFD0, 234, 24635873058586, 2940895, 0));
        c.push(Case(Kind.SL, 0, 515173227, 0x410007277829c4676ffcba4b42127f5a7e3b8c704f0246c97d3b8e681de100d4, 0xea908e6c26A2eFAeB5cBBdDD2fB9Ce6ee3a35D4A, 1073, 820039208724116, 1828050, 0));
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

    function test_diff_replayRealCloses() public {
        string memory out;
        string[5] memory names = ["MARKET", "PARTIAL", "TP", "SL", "LIQ"];
        for (uint256 i; i < c.length; i++) {
            Case memory k = c[i];
            vm.createSelectFork("arbitrum", k.tx_);
            vm.etch(ARB_SYS, hex"00");
            vm.mockCall(ARB_SYS, abi.encodeWithSelector(IArbSys.arbBlockNumber.selector), abi.encode(k.block_));
            IGainsDiamond d = IGainsDiamond(address(DIAMOND));
            NavDump dump = new NavDump(d, new NavHarness());
            uint16 band = k.pair == SOL ? 25 : 20;
            uint64 cl = _chainlink1e10(_feed(k.pair));
            IGainsDiamond.Trade memory t = d.getTrade(k.trader, k.index);
            uint64 px = k.kind == Kind.TP ? t.tp : k.kind == Kind.SL ? t.sl : k.oraclePrice;
            string memory tag = string.concat(names[uint8(k.kind)], "-", vm.toString(uint256(k.pair)), "-", vm.toString(k.block_));
            string memory paid = vm.toString(k.paid);
            string memory rec = string.concat("{\"rec\":", dump.record(tag, k.trader, k.index, cl, band, px, true, k.paid), ",\"paidAmount\":\"", paid, "\"}");
            // the same trade evaluated at the oracle price of the fill (TP / SL rows above use the trigger price)
            string memory recO = string.concat(
                "{\"rec\":", dump.record(string.concat(tag, "-oracle"), k.trader, k.index, cl, band, k.oraclePrice, true, k.paid), ",\"paidAmount\":\"", paid, "\"}"
            );
            out = i == 0 ? string.concat(rec, ",\n", recO) : string.concat(out, ",\n", rec, ",\n", recO);
        }
        if (vm.envOr("NAV_DIFF_DUMP", false)) vm.writeFile("./deployments/audit-nav-diff-replay.json", string.concat("[\n", out, "\n]\n"));
    }
}
