// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {R1Base} from "../R1Base.t.sol";
import {GainsVault} from "../../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../../src/gains/GainsVaultPolicy.sol";
import {InitParams, OpenParams} from "../../../../src/gains/GainsTypes.sol";

/// @notice Round 2, domain ECON. Replays an event sequence produced by the independent Python model
///         (test/audit/gains/r2/econ) on the real vault and the mock diamond, and checks every expectation the model
///         wrote into it: which calls revert and with which error, every settle's minted shares, burned shares, paid
///         USDC and NAV, the state digest after each settle (supply, vault USDC, totalAssets, high water mark,
///         checkpoint) and every actor's final USDC balance. Prices: Chainlink (what the vault reads) and the true
///         price (what Gains fills at) are set separately, so a Chainlink lag can be modelled.
abstract contract EconBase is R1Base {
    uint256 internal constant W = 8; // words per event

    // op codes (econ/scenario.py)
    uint256 internal constant WARP = 1;
    uint256 internal constant PRICE = 2;
    uint256 internal constant DEP = 3;
    uint256 internal constant RED = 4;
    uint256 internal constant CANDEP = 5;
    uint256 internal constant CANRED = 6;
    uint256 internal constant CLAIM = 7;
    uint256 internal constant OPEN = 8;
    uint256 internal constant CLOSE = 9;
    uint256 internal constant SETTLE = 10;
    uint256 internal constant CHECKRISK = 11;
    uint256 internal constant ACCRUE = 12;
    uint256 internal constant EMERG = 13;
    uint256 internal constant EXITEMERG = 14;
    uint256 internal constant CLEARBREACH = 15;
    uint256 internal constant RESUME = 16;
    uint256 internal constant QFEES = 17;
    uint256 internal constant XFEES = 18;
    uint256 internal constant QFEEREC = 19;
    uint256 internal constant XFEEREC = 20;
    uint256 internal constant DONATE = 21;
    uint256 internal constant CHECK = 22;
    uint256 internal constant CLEARLEV = 23;
    uint256 internal constant LOWERFEES = 24;

    GainsVault internal ev;
    address[] internal actors;
    mapping(uint16 pair => uint64) internal truePx;
    uint256 internal settles;
    uint256 internal checks;

    struct Expect {
        uint256 nEvents;
        uint256 nActors;
        uint256 finalsAt; // index of the first final balance
        uint256 cfgAt; // index of the first config word
    }

    function _layout(uint256[] memory w) internal pure returns (Expect memory e) {
        e.nEvents = w[0];
        e.nActors = w[1 + e.nEvents * W];
        e.finalsAt = 2 + e.nEvents * W;
        e.cfgAt = e.finalsAt + e.nActors + 2;
    }

    /// @dev Builds the vault the sequence was generated for: standalone (no factory), roles of GainsBase, risk and
    ///      fees from the config words, Gains fees on BTC and ETH, every actor funded with the model's start balance.
    function _build(uint256[] memory w) internal returns (Expect memory e) {
        e = _layout(w);
        uint256 c = e.cfgAt;
        GainsVaultPolicy.RiskConfig memory r = GainsVaultPolicy.RiskConfig({
            maxLeverageBps: uint32(w[c + 4]),
            maxDailyLossBps: uint32(w[c + 5]),
            maxDrawdownBps: uint32(w[c + 6]),
            maxSlippageBps: 100,
            maxOrderNotional: uint64(w[c + 9]),
            maxEpochDuration: uint64(w[c + 7]),
            maxNavMoveBps: uint32(w[c + 8]),
            maxFlattenSlippageBps: 300
        });
        require(w[c + 3] == 20, "econ: band 20 bps (curated in GainsBase)");
        uint32[] memory assets = new uint32[](2);
        assets[0] = BTC;
        assets[1] = ETH;
        ev = GainsVault(Clones.clone(address(vaultImpl)));
        GainsVaultPolicy p = GainsVaultPolicy(Clones.clone(address(policyImpl)));
        p.initialize(owner, r, assets, 2 days, address(platform), address(ev));
        InitParams memory ip = _standaloneParams(p);
        ip.managementFeeBps = uint16(w[c]);
        ip.performanceFeeBps = uint16(w[c + 1]);
        ev.initialize(ip);
        diamond.setPair(BTC, w[c + 2], 285.7e18, 0.1e18, 0);
        diamond.setPair(ETH, w[c + 2], 285.7e18, 0.1e18, 0);
        truePx[BTC] = _px(BTC);
        truePx[ETH] = _px(ETH);

        delete actors;
        actors.push(owner);
        actors.push(manager);
        actors.push(guardian);
        actors.push(feeRecipient);
        for (uint256 i = 4; i < e.nActors; ++i) {
            actors.push(makeAddr(string.concat("econ.actor", vm.toString(i))));
        }
        uint256 init = w[c + 10];
        for (uint256 i; i < actors.length; ++i) {
            address a = actors[i];
            usdc.mint(a, init - usdc.balanceOf(a));
            vm.prank(a);
            usdc.approve(address(ev), type(uint256).max);
        }
    }

    function _replay(uint256[] memory w) internal returns (Expect memory e) {
        e = _build(w);
        vm.pauseGasMetering();
        for (uint256 i; i < e.nEvents; ++i) {
            uint256 o = 1 + i * W;
            _step(i, w[o], w[o + 1], w[o + 2], w[o + 3], w[o + 4], w[o + 5], w[o + 6], w[o + 7]);
        }
        for (uint256 i; i < e.nActors; ++i) {
            assertEq(usdc.balanceOf(actors[i]), w[e.finalsAt + i], string.concat("final USDC of actor ", vm.toString(i)));
        }
        assertEq(usdc.balanceOf(address(ev)), w[e.finalsAt + e.nActors], "vault USDC left");
        assertEq(ev.totalSupply(), w[e.finalsAt + e.nActors + 1], "supply left");
        vm.resumeGasMetering();
    }

    function _selector(uint256 code) internal pure returns (bytes4) {
        if (code == 1) return bytes4(keccak256("EpochTooYoung()"));
        if (code == 2) return bytes4(keccak256("InsufficientLiquidity(uint256,uint256)"));
        if (code == 3) return bytes4(keccak256("NavMoved(uint256,uint256)"));
        if (code == 4) return bytes4(keccak256("StaleCheckpoint()"));
        if (code == 5) return bytes4(keccak256("Unauthorized()"));
        if (code == 6) return bytes4(keccak256("ReduceOnlyMode()"));
        if (code == 7) return bytes4(keccak256("RequestPending()"));
        if (code == 8) return bytes4(keccak256("DepositsClosed()"));
        if (code == 9) return bytes4(keccak256("NothingToCancel()"));
        if (code == 10) return bytes4(keccak256("RequestNotSettled()"));
        if (code == 11) return bytes4(keccak256("RedemptionsPending()"));
        if (code == 12) return bytes4(keccak256("NotClearable()"));
        if (code == 13) return bytes4(keccak256("NotReady()"));
        if (code == 14) return bytes4(keccak256("InEmergency()"));
        if (code == 15) return bytes4(keccak256("DepositTooSmall()"));
        if (code == 16) return bytes4(keccak256("EpochOverdue()"));
        if (code == 17) return bytes4(keccak256("OrderRejected(string)"));
        if (code == 18) return bytes4(keccak256("InsufficientIdle(uint256,uint256)"));
        if (code == 19) return bytes4(keccak256("InvalidFee()"));
        if (code == 20) return bytes4(keccak256("TooManyPositions(uint256,uint256)"));
        revert("econ: unknown revert code");
    }

    function _expect(uint256 code) internal {
        if (code != 0) vm.expectPartialRevert(_selector(code));
    }

    function _step(uint256 i, uint256 op, uint256 actor, uint256 a, uint256 b, uint256 c, uint256 code, uint256 c1, uint256 c2)
        internal
    {
        address who = actors[actor];
        string memory at = string.concat(" (event ", vm.toString(i), ")");
        if (op == WARP) {
            _warp(vm.getBlockTimestamp() + a);
        } else if (op == PRICE) {
            _setPrice(uint16(a), uint64(b));
            truePx[uint16(a)] = uint64(c);
        } else if (op == DEP) {
            _expect(code);
            vm.prank(who);
            ev.requestDeposit(a, actors[b]);
        } else if (op == RED) {
            _expect(code);
            vm.prank(who);
            ev.requestRedeem(a, who, who);
        } else if (op == CANDEP) {
            _expect(code);
            vm.prank(who);
            ev.cancelDepositRequest();
        } else if (op == CANRED) {
            _expect(code);
            vm.prank(who);
            ev.cancelRedeemRequest();
        } else if (op == CLAIM) {
            _expect(code);
            ev.claim(who);
        } else if (op == OPEN) {
            uint16 pair = uint16(a / 2);
            OpenParams memory p = OpenParams({
                pairIndex: pair,
                long: a % 2 == 1,
                collateral: uint120(b),
                leverage: uint24(c),
                expectedPrice: _px(pair),
                maxSlippageP: SLIP,
                tp: 0,
                sl: 0,
                tradeType: 0
            });
            _expect(code);
            vm.prank(who);
            ev.openTrade(p);
            if (code == 0) diamond.fill(address(ev), diamond.orderCount(address(ev)) - 1, truePx[pair]);
        } else if (op == CLOSE) {
            uint16 pair = diamond.getTrade(address(ev), uint32(a)).pairIndex;
            _expect(code);
            vm.prank(who);
            ev.closeTrade(uint32(a), truePx[pair]);
            if (code == 0) diamond.fill(address(ev), diamond.orderCount(address(ev)) - 1, truePx[pair]);
        } else if (op == SETTLE) {
            _expect(code);
            vm.prank(who);
            ev.settle();
            if (code == 0) {
                ++settles;
                (, uint256 depShares,, uint256 paid, uint256 burned, uint256 navAfter,,) = ev.epochs(ev.currentEpoch() - 1);
                assertEq(depShares, c1, string.concat("deposit shares", at));
                assertEq(paid, c2, string.concat("redemption USDC", at));
                assertEq(burned, a, string.concat("burned shares", at));
                assertEq(navAfter, b, string.concat("NAV after", at));
            }
        } else if (op == CHECKRISK) {
            ev.checkRisk();
        } else if (op == ACCRUE) {
            ev.accrueFees();
        } else if (op == EMERG) {
            _expect(code);
            vm.prank(who);
            ev.triggerEmergency();
        } else if (op == EXITEMERG) {
            _expect(code);
            vm.prank(who);
            ev.exitEmergency();
        } else if (op == CLEARBREACH) {
            _expect(code);
            vm.prank(who);
            ev.clearBreach();
        } else if (op == RESUME) {
            _expect(code);
            vm.prank(who);
            ev.resume();
        } else if (op == QFEES) {
            vm.prank(owner);
            ev.queue(abi.encodeCall(GainsVault.setFees, (uint16(a), uint16(b))));
        } else if (op == XFEES) {
            ev.execute(abi.encodeCall(GainsVault.setFees, (uint16(a), uint16(b))));
        } else if (op == QFEEREC) {
            vm.prank(owner);
            ev.queue(abi.encodeCall(GainsVault.setFeeRecipient, (actors[a])));
        } else if (op == XFEEREC) {
            ev.execute(abi.encodeCall(GainsVault.setFeeRecipient, (actors[a])));
        } else if (op == DONATE) {
            vm.prank(who);
            usdc.transfer(address(ev), a);
        } else if (op == CHECK) {
            ++checks;
            assertEq(ev.totalSupply(), a, string.concat("supply", at));
            assertEq(usdc.balanceOf(address(ev)), b, string.concat("vault USDC", at));
            assertEq(ev.totalAssets(), c, string.concat("totalAssets", at));
            assertEq(ev.highWaterMark(), c1, string.concat("high water mark", at));
            assertEq(ev.checkpointNav(), c2, string.concat("checkpoint", at));
        } else if (op == CLEARLEV) {
            _expect(code);
            ev.clearLeverageBreach();
        } else if (op == LOWERFEES) {
            _expect(code);
            vm.prank(who);
            ev.lowerFees(uint16(a), uint16(b));
        } else {
            revert("econ: unknown op");
        }
    }
}
