// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// hl-r2 HL-PROXY fix tests (internal, AI-assisted review; not an independent audit). They run only with
// fixes/patches/proxy/HL-PROXY.contracts.patch applied (fixes/verify-proxy.sh copies this file to
// contracts/test/audit/hl-r2/proxy/ in a throwaway worktree). Never block.timestamp / block.number here.

import {HloBase} from "../../hl-open/HloBase.t.sol";
import {HyperVault} from "../../../../src/HyperVault.sol";
import {HyperVaultFactory} from "../../../../src/HyperVaultFactory.sol";
import {HyperCore} from "../../../../src/hypercore/HyperCore.sol";
import {IHyperVaultErrors, IHyperVaultEvents} from "../../../../src/VaultTypes.sol";
import {VaultPolicy} from "../../../../src/VaultPolicy.sol";
import {MockPrecompile} from "../../../mocks/Mocks.sol";

contract GasBurner {
    fallback() external {
        assembly {
            invalid()
        }
    }
}

contract HLPROXY_Fix is HloBase {
    address internal agent = makeAddr("platformAgent");
    uint128 internal constant CLOID = 0x1234_5678_9abc_def0_1234_5678_9abc_def0;
    address internal constant BL = 0x0000000000000000000000000000000000000811;

    function setUp() public override {
        super.setUp();
        _setAgent(vault, agent);
        // 100k USDC of perp equity, no position
        _setCore(address(vault), 100_000e6, 0, 0);
        _setWithdrawable(address(vault), 100_000e6);
    }

    // ------------------------------------------------------------------ helpers
    function _ids(uint256 from) internal view returns (uint24[] memory ids) {
        uint256 n = writer.count();
        ids = new uint24[](n - from);
        for (uint256 i = from; i < n; ++i) {
            (, uint24 id,) = _decode(writer.at(i));
            ids[i - from] = id;
        }
    }

    function _count(uint256 from, uint24 id) internal view returns (uint256 c) {
        uint24[] memory ids = _ids(from);
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] == id) ++c;
        }
    }

    function _buyBtc(address who, uint64 sz, uint64 px, bool reduceOnly, uint8 tif, uint128 cloid) internal {
        vm.prank(who);
        vault.placeOrder(BTC, true, px, sz, reduceOnly, tif, cloid);
    }

    /// @dev The vault's USDC borrow / lend state on 0x811 (mainnet: PrecompileError without state; this mock answers).
    function _setBorrowLend(address v, uint64 borrowValue, uint64 supplyValue) internal {
        if (BL.code.length == 0) vm.etch(BL, address(new MockPrecompile()).code);
        MockPrecompile(BL).setResponse(abi.encode(v, uint64(0)), abi.encode(uint64(0), borrowValue, uint64(0), supplyValue));
    }

    // ------------------------------------------------------------------ 1. the agent trades through placeOrder
    function test_PROXY_agentOrderGoesThroughThePolicyCheckedPath() public {
        uint256 from = writer.count();
        // 0.1 BTC at 100,500 (mark 100,000, inside the 1% band): $10,050 on $100k equity
        vm.expectEmit(true, false, false, true, address(vault));
        emit IHyperVaultEvents.OrderSent(BTC, true, 100_500e8, 1e7, false, 3, CLOID);
        _buyBtc(agent, 1e7, 100_500e8, false, HyperCore.TIF_IOC, CLOID);
        bytes memory raw = writer.last();
        (uint8 version, uint24 id, bytes memory body) = _decode(raw);
        assertEq(version, 1);
        assertEq(id, 1);
        assertEq(body, abi.encode(BTC, true, uint64(100_500e8), uint64(1e7), false, uint8(3), CLOID));
        assertEq(_count(from, 1), 1, "one order");
        assertEq(_count(from, 9), 0, "no API wallet action");
    }

    function test_PROXY_policyViolatingAgentOrdersRevert() public {
        // leverage: 3x cap on $100k -> 3.1 BTC ($311.55k) is over
        vm.expectRevert(abi.encodeWithSelector(IHyperVaultErrors.OrderRejected.selector, "leverage"));
        _buyBtc(agent, 31e7, 100_500e8, false, 3, CLOID);
        // price above the 1% band
        vm.expectRevert(abi.encodeWithSelector(IHyperVaultErrors.OrderRejected.selector, "price above band"));
        _buyBtc(agent, 1e7, 101_100e8, false, 3, CLOID);
        // asset not allowlisted (DOGE)
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(IHyperVaultErrors.OrderRejected.selector, "asset not allowed"));
        vault.placeOrder(DOGE, true, 2_010_000, 100e8, false, 3, CLOID);
        // spot
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(IHyperVaultErrors.OrderRejected.selector, "spot not supported"));
        vault.placeOrder(10_107, true, 1e8, 1e8, false, 3, CLOID);
        // notional cap: tighten maxOrderNotional to $5k (instant), a $10k order is refused
        VaultPolicy.RiskConfig memory c = _defaultRisk();
        c.maxOrderNotional = 5_000e6;
        vm.prank(owner);
        policy.proposeConfig(c);
        vm.expectRevert(abi.encodeWithSelector(IHyperVaultErrors.OrderRejected.selector, "notional too large"));
        _buyBtc(agent, 1e7, 100_500e8, false, 3, CLOID);
    }

    function test_PROXY_agentIsIocOnlyWithItsOwnCloid() public {
        vm.expectRevert(abi.encodeWithSelector(IHyperVaultErrors.OrderRejected.selector, "agent order"));
        _buyBtc(agent, 1e7, 100_500e8, false, HyperCore.TIF_GTC, CLOID); // resting order
        vm.expectRevert(abi.encodeWithSelector(IHyperVaultErrors.OrderRejected.selector, "agent order"));
        _buyBtc(agent, 1e7, 100_500e8, false, HyperCore.TIF_IOC, 0); // no cloid
        vm.expectRevert(abi.encodeWithSelector(IHyperVaultErrors.OrderRejected.selector, "agent order"));
        _buyBtc(agent, 1e7, 100_500e8, false, HyperCore.TIF_IOC, uint128(0xd0a1d0a1) << 96 | 7); // the Order ticket's prefix
        // HLR2-F05 for everyone: only TIF 1..3
        vm.expectRevert(abi.encodeWithSelector(IHyperVaultErrors.OrderRejected.selector, "tif"));
        _buyBtc(manager, 1e7, 100_500e8, false, 4, CLOID);
        // the manager keeps resting orders and the ticket prefix
        _buyBtc(manager, 1e7, 99_900e8, false, HyperCore.TIF_GTC, uint128(0xd0a1d0a1) << 96 | 7);
    }

    function test_PROXY_onlyManagerAndAgent_revokedAgentLosesThePath() public {
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        _buyBtc(stranger, 1e7, 100_500e8, false, 3, CLOID);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        _buyBtc(sentinel, 1e7, 100_500e8, false, 3, CLOID);
        vm.prank(guardian);
        vault.revokeAgent();
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        _buyBtc(agent, 1e7, 100_500e8, false, 3, CLOID);
    }

    function test_PROXY_agentCancels_strangerCannot() public {
        uint256 from = writer.count();
        vm.prank(agent);
        vault.cancelOrder(BTC, 42);
        (, uint24 id, bytes memory body) = _decode(writer.last());
        assertEq(id, 10);
        assertEq(body, abi.encode(BTC, uint64(42)));
        assertEq(_count(from, 10), 1);
        vm.prank(stranger);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        vault.cancelOrder(BTC, 42);
    }

    /// @dev Gas of the agent's orders (the executor's EVM cost per order; HL-PROXY.md section 3). Mainnet eth_estimateGas
    ///      of today's manager-only placeOrder on the platform vault: 109,985.
    function test_PROXY_gas_agentOpenWithPreTradeCheck_andReduce() public {
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.prank(agent);
        uint256 g = gasleft();
        vault.placeOrder(BTC, true, 100_500e8, 1e7, false, 3, CLOID);
        uint256 open = g - gasleft();
        _setPosition(address(vault), BTC, 10_000_000);
        vm.prank(agent);
        g = gasleft();
        vault.placeOrder(BTC, false, 99_500e8, 1e7, true, 3, CLOID + 1);
        uint256 reduce = g - gasleft();
        emit log_named_uint("gas agent open (pre-trade checkRisk + mode pin + order)", open);
        emit log_named_uint("gas agent reduce-only", reduce);
        assertLt(open, 1_000_000, "fits a 3M-gas small block with room");
    }

    // ------------------------------------------------------------------ 2. reduce only and the pre-trade risk check
    function test_PROXY_breachedVault_agentReducesButCannotOpen() public {
        // leverage breach: 4x on a 3x policy
        _setCore(address(vault), 100_000e6, 400_000e6, 0);
        vault.checkRisk();
        assertTrue(vault.breached());
        vm.expectRevert(IHyperVaultErrors.ReduceOnlyMode.selector);
        _buyBtc(agent, 1e7, 100_500e8, false, 3, CLOID);
        // reduce only goes through (the vault can always de-risk)
        _setPosition(address(vault), BTC, -400_000_000); // short 4 BTC
        uint256 from = writer.count();
        _buyBtc(agent, 1e8, 100_500e8, true, 3, CLOID);
        assertEq(_count(from, 1), 1);
    }

    function test_PROXY_preTradeRiskCheckRefusesAnOpenAndKeepsTheBreach() public {
        // one depositor so the share price (and the daily loss) is defined
        _deposit(alice, 100_000e6);
        _setCore(address(vault), 0, 0, 0);
        _settle();
        // the deposit is now on Core (100k), day start set by the first mint
        vm.prank(manager);
        vault.bridgeToCore(100_000e6);
        _skipBridgeWindow();
        _setCore(address(vault), 100_000e6, 0, 0);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vault.checkRisk();
        assertFalse(vault.breached());
        // the vault loses 10% (5% daily limit); nobody has called checkRisk since
        _setCore(address(vault), 90_000e6, 0, 0);
        uint256 from = writer.count();
        vm.expectEmit(true, false, false, true, address(vault));
        emit IHyperVaultEvents.OrderRefused(BTC, CLOID, agent);
        _buyBtc(agent, 1e7, 100_500e8, false, 3, CLOID);
        assertTrue(vault.breached(), "the breach found at order time is kept");
        assertEq(_count(from, 1), 0, "no order sent");
    }

    // ------------------------------------------------------------------ 3. no API wallet, no bypass powers
    function test_PROXY_setAgentApprovesNothingOnHyperCore() public {
        address agent2 = makeAddr("agent2");
        uint256 from = writer.count();
        _setAgent(vault, agent2);
        assertEq(vault.agent(), agent2);
        assertEq(_count(from, 9), 0, "no CoreWriter action 9");
        assertEq(_count(from, 16), 1, "mode pinned on agent change");
    }

    /// @dev Every entry point that writes to HyperCore, once: no action ever approves an API wallet for the agent, and
    ///      nothing outside {1 order, 7 class transfer, 10 cancel, 13 send to the EVM, 16 mode pin}; the revoke sends
    ///      nothing at all (WP5-D14: no action 9, so no API wallet entry appears on the vault's account).
    function test_PROXY_noEntryPointGivesTheAgentApiWalletPowers() public {
        uint256 from = writer.count();
        _buyBtc(agent, 1e7, 100_500e8, false, 3, CLOID);
        vm.prank(agent);
        vault.cancelOrder(BTC, 1);
        _setPosition(address(vault), BTC, 10_000_000);
        vm.prank(manager);
        vault.flatten(BTC, 0);
        vm.prank(owner);
        vault.syncAgent();
        vm.prank(owner);
        vault.pinAccountMode();
        vault.checkRisk();
        _setCore(address(vault), 100_000e6, 0, 100e6);
        _setWithdrawable(address(vault), 100_000e6);
        vm.prank(manager);
        vault.moveUsd(50e6, true);
        vm.prank(manager);
        vault.bridgeToEvm(100e6);
        uint256 n = writer.count();
        for (uint256 i = from; i < n; ++i) {
            (, uint24 id, bytes memory body) = _decode(writer.at(i));
            assertTrue(id == 1 || id == 7 || id == 10 || id == 13 || id == 16, "only order, transfer, cancel, send, mode ids");
            if (id == 16) assertEq(body, abi.encode(address(vault), uint8(1)));
        }
        // the revoke is EVM-only: no CoreWriter action
        uint256 beforeRevoke = writer.count();
        vm.prank(guardian);
        vault.revokeAgent();
        assertEq(writer.count(), beforeRevoke, "the revoke sends nothing to HyperCore");
        assertEq(vault.agent(), address(0));
    }

    function test_PROXY_factoryHostedVault_agentBoundOnTheFactory_tradesThroughTheVaultOnly() public {
        address who = makeAddr("launcher");
        _fundLauncher(who, 1);
        address agentF = makeAddr("factoryAgent");
        bytes32 salt = bytes32(uint256(7));
        address predicted = factory.predictVaultAddress(who, salt);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        HyperVaultFactory.CreateParams memory p = _params(who, salt);
        p.agent = agentF;
        p.agentSig = _agentSig(agentF, predicted, deadline);
        p.agentDeadline = deadline;
        uint256 from = writer.count();
        HyperVault v = _launch(who, p);
        assertEq(address(v), predicted);
        assertEq(v.agent(), agentF);
        assertEq(v.orderPath(), 1);
        _setCore(address(v), 50_000e6, 0, 0);
        // WP1: the seed bridge's window caps the NAV the agent's turnover budget reads at the seed; let it close
        vm.roll(vm.getBlockNumber() + v.MAX_UNLANDED_BLOCKS() + 1);
        // On the integrated stack (HLO-07) the agent has no power during the veto window: not even the vault's order
        // path. agentActiveAt() exists only there; on origin/main the call fails and the order goes through at once.
        (bool has, bytes memory ret) = address(v).staticcall(abi.encodeWithSignature("agentActiveAt()"));
        if (has && ret.length == 32) {
            uint256 activeAt = abi.decode(ret, (uint256));
            vm.prank(agentF);
            vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("AgentWarmingUp(uint256)")), activeAt));
            v.placeOrder(BTC, true, 100_500e8, 1e7, false, 3, CLOID);
            vm.warp(activeAt);
        }
        vm.prank(agentF);
        v.placeOrder(BTC, true, 100_500e8, 1e7, false, 3, CLOID);
        vm.prank(sentinel);
        v.syncAgent(); // the executor's old call: pins the mode, approves nothing
        assertEq(_count(from, 9), 0, "the factory path never approves an API wallet");
        assertGe(_count(from, 16), 1);
        assertEq(_count(from, 1), 1);
    }

    // ------------------------------------------------------------------ 4. account mode: pin and guard
    function test_PROXY_action16EncodingIsByteExact() public {
        vm.prank(owner);
        vault.pinAccountMode();
        bytes memory raw = writer.last();
        bytes memory want = abi.encodePacked(
            bytes1(0x01), bytes3(0x000010), bytes32(uint256(uint160(address(vault)))), bytes32(uint256(1))
        );
        assertEq(raw, want);
        assertEq(vault.modePinnedAt(), vm.getBlockTimestamp());
    }

    function test_PROXY_pinIsRateLimitedForStrangers_freeForRoles() public {
        // setUp's setAgent pinned the mode just now: a stranger waits the interval
        vm.prank(stranger);
        vm.expectRevert(IHyperVaultErrors.NotReady.selector);
        vault.pinAccountMode();
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        vm.prank(stranger);
        vault.pinAccountMode();
        vm.prank(stranger);
        vm.expectRevert(IHyperVaultErrors.NotReady.selector);
        vault.pinAccountMode();
        vm.prank(guardian);
        vault.pinAccountMode();
        vm.prank(owner);
        vault.pinAccountMode();
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        vm.prank(stranger);
        vault.pinAccountMode();
        // checkRisk pins at most once per interval
        uint256 from = writer.count();
        vault.checkRisk();
        assertEq(_count(from, 16), 0, "pinned just now");
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        vault.checkRisk();
        assertEq(_count(from, 16), 1);
    }

    function test_PROXY_noPinBeforeTheCoreAccountExists() public {
        _setCoreUser(address(vault), false);
        uint256 from = writer.count();
        vm.prank(owner);
        vault.pinAccountMode();
        assertEq(writer.count(), from);
    }

    function test_PROXY_modeGuard_portfolioMarginFootprintStopsPricingAndOpens() public {
        _deposit(alice, 100_000e6);
        _setCore(address(vault), 0, 0, 0);
        _settle();
        _setCore(address(vault), 100_000e6, 0, 0);
        assertFalse(vault.accountModeSuspect());
        // portfolio margin (mainnet: every probed PM account has a USDC borrow / supply state on 0x811)
        _setBorrowLend(address(vault), 0, 9_336e8);
        assertTrue(vault.accountModeSuspect());
        vm.expectRevert(IHyperVaultErrors.AccountModeMismatch.selector);
        vault.checkRisk();
        _redeem(alice, 1);
        vm.prank(manager);
        vm.expectRevert(IHyperVaultErrors.AccountModeMismatch.selector);
        vault.settle();
        vm.expectRevert(IHyperVaultErrors.AccountModeMismatch.selector);
        vault.accrueFees();
        vm.expectRevert(IHyperVaultErrors.AccountModeMismatch.selector);
        _buyBtc(agent, 1e7, 100_500e8, false, 3, CLOID);
        // de-risking still works
        _setPosition(address(vault), BTC, -10_000_000);
        _buyBtc(agent, 1e7, 100_500e8, true, 3, CLOID);
        // the platform re-pins at once
        uint256 from = writer.count();
        vm.prank(guardian); // a standalone vault's sentinel is its guardian
        vault.pinAccountMode();
        assertEq(_count(from, 16), 1);
        // exits are never gated: an emergency (exit-only) settle still pays
        vm.prank(guardian);
        vault.triggerEmergency();
        vm.prank(guardian);
        vault.settle();
        // once HyperCore shows no borrow / lend state again, pricing resumes
        _setBorrowLend(address(vault), 0, 0);
        assertFalse(vault.accountModeSuspect());
        vault.checkRisk();
    }

    function test_PROXY_modeGuard_precompileErrorOrNoStateIsStandard() public {
        // mainnet answers PrecompileError for an account without borrow / lend state: not suspect, and the gas cap
        // keeps an error from consuming the call's gas
        vm.etch(BL, address(new GasBurner()).code);
        assertFalse(vault.accountModeSuspect());
        uint256 g = gasleft();
        vault.checkRisk();
        assertLt(g - gasleft(), 1_000_000, "the 0x811 error costs at most its 30k cap");
    }
}
