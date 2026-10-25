// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {HloBase} from "../../hl-open/HloBase.t.sol";
import {HyperVault} from "../../../../src/HyperVault.sol";
import {HyperVaultFactory} from "../../../../src/HyperVaultFactory.sol";
import {VaultPolicy} from "../../../../src/VaultPolicy.sol";
import {HyperCore} from "../../../../src/hypercore/HyperCore.sol";
import {BreachReason, IHyperVaultErrors as E} from "../../../../src/VaultTypes.sol";

/// @notice hl-r2 KEYS PoCs (contracts/audit/hl-r2/KEYS.md). Each test assumes ONLY the named key is compromised; every
///         other actor behaves honestly. The vault is configured like the platform vault (read 2026-10-19): hosted, platform
///         agent, operator = keeper, policy 5x / daily 20% / drawdown 50% / slippage 1% / maxOrderNotional 2.5M /
///         epoch 7 d / maxNavMove 20% / flatten 3% / timelocks 2 d. HyperCore is the repo mock: what a compromised
///         agent does on Core is modelled by setting the precompile answers it would cause (value moved out of
///         coreEquity()'s view, i.e. reported perp accountValue + spot USDC falls without a position/PnL change).
contract HLR2KeysPoC is HloBase {
    address internal agentHolder; // the agent (API wallet) private-key holder
    address internal launcher = makeAddr("launcher"); // vault owner and manager (as on the platform vault)
    address internal sybil = makeAddr("sybil"); // the attacker's depositor wallet: NOT an insider

    function _platformVault() internal pure returns (VaultPolicy.RiskConfig memory) {
        return VaultPolicy.RiskConfig({
            maxLeverageBps: 50_000,
            maxDailyLossBps: 2_000,
            maxDrawdownBps: 5_000,
            maxSlippageBps: 100,
            maxOrderNotional: 2_500_000e6,
            maxEpochDuration: 7 days,
            maxNavMoveBps: 2_000,
            maxFlattenSlippageBps: 300
        });
    }

    /// @dev A hosted factory vault, registrar-signed platform agent, keeper as operator, `nav` USDC of alice's money on
    ///      Core (perp), checkpointed by the keeper, at the start of a fresh UTC day.
    function _hosted(bytes32 salt, uint256 nav) internal returns (HyperVault v) {
        (agentHolder,) = makeAddrAndKey(string(abi.encodePacked("agent", salt)));
        address predicted = factory.predictVaultAddress(launcher, salt);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        _fundLauncher(launcher, 1);
        HyperVaultFactory.CreateParams memory p = _params(launcher, salt);
        p.risk = _platformVault();
        p.hosted = true;
        p.depositCap = type(uint256).max;
        (p.agent, p.agentSig, p.agentDeadline) = (agentHolder, _agentSig(agentHolder, predicted, deadline), deadline);
        v = _launch(launcher, p);
        if (v.agentActiveAt() > vm.getBlockTimestamp()) vm.warp(v.agentActiveAt()); // HLO-07: AGENT_WARMUP
        vm.roll(vm.getBlockNumber() + 400);
        usdc.mint(alice, nav);
        vm.startPrank(alice);
        usdc.approve(address(v), type(uint256).max);
        v.requestDeposit(nav, alice);
        vm.stopPrank();
        v.checkRisk();
        vm.prank(keeper);
        v.settle();
        usdc.burnFrom(address(v), nav); // keeper bridges + moves to perp; modelled as Core holding it
        _setCore(address(v), int64(uint64(nav + 2e6)), 0, 0);
        uint256 t = vm.getBlockTimestamp();
        vm.warp((t / 1 days + 1) * 1 days + 1 hours);
        vm.roll(vm.getBlockNumber() + 400);
        v.checkRisk();
        return v;
    }

    function _approveSybil(HyperVault v, uint256 amount) internal {
        usdc.mint(sybil, amount);
        vm.prank(sybil);
        usdc.approve(address(v), type(uint256).max);
    }

    // ==================================================================
    // HLR2-K03: a compromised agent key + a non-insider depositor + the HONEST keeper's scheduled settle. The agent
    // lowers reported coreEquity by just under maxNavMoveBps (20%), a sybil (not manager/owner/feeRecipient) deposits,
    // the KEEPER (operator, not an insider, acting on its normal schedule) prices the deposit at the deflated NAV, and
    // the agent restores the balance. This is the C-01 class, but the settle is run by the operator: the insider
    // deferral rule (deferredDepositAssets, INSIDER_MIN_EPOCH_AGE) never engages because the sybil is not an insider.
    // ==================================================================
    function _k03(uint256 nav) internal returns (uint256 gainBps) {
        HyperVault v = _hosted(bytes32(uint256(0x3003)), nav);
        _approveSybil(v, nav);
        // Agent hides 19.9% of equity (subaccount / HL vault / spot token / portfolio-margin under-read: none ACTs).
        uint256 deflated = (nav + 2e6) * 801 / 1000;
        _setCore(address(v), int64(uint64(deflated)), 0, 0);
        vm.prank(sybil);
        v.requestDeposit(nav, v == v ? sybil : sybil); // controller = sybil
        // The keeper's scheduled settle: checkpoint is < 20% away so it does not revert; sybil priced at the low NAV.
        v.checkRisk();
        vm.prank(keeper);
        v.settle();
        // Agent restores the hidden value; the sybil's deposit USDC is bridged to Core too.
        usdc.burnFrom(address(v), nav);
        _setCore(address(v), int64(uint64((nav + 2e6) + nav)), 0, 0);
        v.claim(sybil);
        v.claim(alice);
        uint256 sybilShares = v.balanceOf(sybil);
        uint256 sybilValue = v.convertToAssets(sybilShares);
        gainBps = sybilValue > nav ? (sybilValue - nav) * 10_000 / nav : 0;
        console2.log("K03 nav", nav);
        console2.log("K03 sybil deposit worth after one round (6dp)", sybilValue);
        console2.log("K03 sybil gain bps", gainBps);
        // alice (the honest depositor) is diluted
        uint256 aliceValue = v.convertToAssets(v.balanceOf(alice));
        console2.log("K03 alice 100% depositor now worth (6dp)", aliceValue);
    }

    function test_HLR2_K03_operatorSettlesSybilAtAgentDeflatedNav_10k() public {
        uint256 g = _k03(10_000e6);
        assertGt(g, 1_000, "sybil gains ~11% in one round at a stolen agent key, settled by the honest operator");
    }

    function test_HLR2_K03_operatorSettlesSybilAtAgentDeflatedNav_100k() public {
        uint256 g = _k03(100_000e6);
        assertGt(g, 1_000);
    }

    function test_HLR2_K03_operatorSettlesSybilAtAgentDeflatedNav_1m() public {
        uint256 g = _k03(1_000_000e6);
        assertGt(g, 1_000);
    }

    // ==================================================================
    // HLR2-K10 (the coordinator's un-revocable-agent hypothesis, contract side): once a compromised agent switches the
    // vault into portfolio margin (CoreWriter action 16 via agentSetAbstraction), the vault has NO code path that
    // emits action 16, so it can never switch the mode back. revokeAgent still overwrites the named api-wallet slot,
    // but the account stays in portfolio margin: coreEquity() keeps under-reading free spot USDC (and reads a negative
    // USDC balance as 0). This test shows (a) revokeAgent runs and zeroes $.agent, and (b) the only way back to a
    // trading agent is a fresh setAgent through the 2-day owner timelock. Mode itself stays wrong forever.
    // ==================================================================
    // ==================================================================
    // HLR2-K04 (sentinel, hot): a stolen SENTINEL_KEY is risk-reducing only, but it is a full-stop DoS across EVERY
    // factory vault at once (vaults read factory.sentinel() live). triggerBreach revokes the agent and sets a GUARDIAN
    // full stop that the vault owner cannot clear instantly (an owner clearBreach must be queued AFTER the breach and
    // waits the 2-day timelock); only the cold guardian clears it at once. No theft; trading stop until the guardian.
    // ==================================================================
    function test_HLR2_K04_sentinelFullStopNotOwnerClearable() public {
        HyperVault v = _hosted(bytes32(uint256(0x4004)), 100_000e6);
        assertTrue(v.agent() != address(0));
        vm.prank(sentinel);
        v.triggerBreach();
        assertTrue(v.breached());
        assertEq(uint8(v.breachReason()), uint8(BreachReason.GUARDIAN));
        assertEq(v.agent(), address(0), "agent revoked: trading stops on this (and every) factory vault");
        // The owner cannot clear it instantly: clearBreach is guardian-or-self, and a self (timelock) clear only
        // counts when queued after the breach, so it is at least the 2-day timelock away.
        vm.prank(launcher);
        vm.expectRevert(E.Unauthorized.selector);
        v.clearBreach();
        // The cold guardian clears it at once (what stops the DoS).
        vm.prank(guardian);
        v.clearBreach();
        assertFalse(v.breached());
    }

    // ==================================================================
    // HLR2-K06 (factory owner, cold): rotates guardian/sentinel/registrar for EVERY factory vault at once. A stolen
    // factory-owner key can install itself (or any address) as sentinel and then full-stop every vault; it can also
    // sign agent bindings (signer == owner() is accepted by create()), i.e. the HLO-07 self-held-agent theft on a new
    // vault. This test shows the role rotation reaching an existing vault live.
    // ==================================================================
    function test_HLR2_K06_factoryOwnerRotatesSentinelAndStopsExistingVault() public {
        HyperVault v = _hosted(bytes32(uint256(0x6006)), 100_000e6);
        address evilSentinel = makeAddr("evilSentinel");
        vm.prank(owner); // the (stolen) factory owner
        factory.setSentinel(evilSentinel);
        assertEq(v.sentinel(), evilSentinel, "existing vault reads the new sentinel live");
        vm.prank(evilSentinel);
        v.triggerBreach();
        assertEq(v.agent(), address(0), "rotated sentinel full-stops the vault");
    }

    // ==================================================================
    // HLR2-K07 (guardian, cold): the guardian's one value-destroying power is a custom-slippage emergency flatten,
    // capped at policy.maxFlattenSlippageBps (<= MAX_FLATTEN_SLIPPAGE_BPS = 3%). This bounds a guardian-caused loss to
    // ~3% of the open position's notional per flatten. The test decodes the CoreWriter order and checks the limit
    // price sits 3% through the mark (a market-sweeping IOC), the worst a guardian can force.
    // ==================================================================
    function test_HLR2_K07_guardianCustomSlippageFlattenBoundedAt3pct() public {
        HyperVault v = _hosted(bytes32(uint256(0x7007)), 100_000e6);
        // open a long BTC position on the vault's Core account (mark 100,000.0)
        _setPosition(address(v), BTC, 1e5); // szi 1.0 (szDecimals 5)
        vm.prank(guardian);
        v.triggerEmergency(); // guardian can flatten with custom slippage only in emergency
        uint256 before = writer.count();
        vm.prank(guardian);
        v.flatten(BTC, 300); // 3% custom slippage
        assertEq(writer.count(), before + 1, "a flatten order was sent");
        (, uint24 actionId, bytes memory body) = _decode(writer.last());
        assertEq(actionId, 1, "limit order");
        (, bool isBuy, uint64 limitPx,,,,) = abi.decode(body, (uint32, bool, uint64, uint64, bool, uint8, uint128));
        assertFalse(isBuy, "closing a long is a sell");
        // mark 100,000.0 -> 1e8 scale = 100000 * 1e8; sell at 3% below ~ 97,000 * 1e8
        uint256 mark1e8 = 100_000 * 1e8;
        assertApproxEqRel(uint256(limitPx), mark1e8 * 9700 / 10_000, 1e15, "sell limit ~3% through mark");
        console2.log("K07 flatten sell limitPx 1e8", uint256(limitPx));
    }

    function test_HLR2_K10_revokeLeavesModeUnrecoverableAndNeedsTimelockForNewAgent() public {
        HyperVault v = _hosted(bytes32(uint256(0x1010)), 100_000e6);
        // guardian/sentinel revoke the agent after noticing the OTHER findings (NAV move, foreign spot):
        vm.prank(sentinel);
        v.revokeAgent();
        assertEq(v.agent(), address(0), "agent slot cleared");
        // The vault never emits CoreWriter action 16, so nothing here can set the abstraction back. A replacement
        // agent must go through the owner timelock; an instant setAgent is not available.
        (address newAgent,) = makeAddrAndKey("newAgent");
        vm.prank(launcher);
        vm.expectRevert(); // onlySelf: setAgent is only reachable via queue+execute (2 days)
        v.setAgent(newAgent);
    }
}
