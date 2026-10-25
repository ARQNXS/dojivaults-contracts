// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HyperVault} from "../../../src/HyperVault.sol";
import {HyperVaultFactory} from "../../../src/HyperVaultFactory.sol";
import {VaultPolicy} from "../../../src/VaultPolicy.sol";
import {ICoreDepositWallet} from "../../../src/hypercore/HyperCore.sol";
import {MockUSDC} from "../../mocks/Mocks.sol";
import {CoreSim, SimDepositWallet} from "../hl-r2/async/CoreSim.sol";
import {SimBase, etchCoreSim} from "../hl-r2/async/SimBase.t.sol";
import {ConservationHandler} from "../hl-r2/async/ConservationHandler.sol";
import {CoreSimAdv} from "./WP5-INV-HLCoreSimAdv.sol";
import {WP5HLStolenAgentHandler} from "./WP5-INV-HLStolenAgent.sol";

/// @notice WP5 (fix round): the hl-r2 conservation campaign (INVARIANTS.md, C1-C3 and F1-F12, unchanged) with a stolen
///         agent added, on the release candidate. The vault is launched as the platform does (hosted, platform agent,
///         keeper operator); unlike hl-r2's SimBase, the agent is NOT approved as a HyperCore API wallet (HL-PROXY: the
///         release candidate never sends that approval), so the agent reaches the venue only through the vault.
///
///  Stolen-agent properties (WP5-INV.md / inv-report.md):
///   SA1 every agent fill gives away at most (band + fee x (1 + band)) of its notional against the mark at send
///       (band = maxSlippageBps, fee = the sim's taker fee), plus one raw price unit per size unit (price rounding);
///   SA2 the agent's opened notional in a UTC day <= maxTurnoverBps x the largest NAV the vault could read that day;
///       risk-adding agent orders in a clock hour <= maxOrdersPerHour;
///   SA3 (the daily form) value the depositors lose to the agent in a UTC day <= maxDailyLossBps x NAV + the churn
///       bound c x (opened + closed notional of the day), c = band + fee x (1 + band);
///   SA4 no value to anyone else: the agent holds no USDC and no shares, the vault's Core account sends nothing to any
///       other Core account, HyperCore never accepts an action signed by the agent (no API wallet), the agent never
///       gets an order through on an asset outside the policy (except reduce only), a non-IOC / zero / ticket cloid,
///       or any role-gated call.
abstract contract WP5HLStolenAgentBase is SimBase {
    WP5HLStolenAgentHandler internal h;
    CoreSimAdv internal adv;
    address internal stranger = makeAddr("stranger");
    uint32 internal constant SOL = 2; // listed on Core, outside the vault's policy

    function setUp() public virtual override {
        manager = _managerAddr();
        vm.warp(1_790_000_000);
        vm.roll(1_000_000);
        usdc = new MockUSDC();
        wallet = new SimDepositWallet(IERC20(address(usdc)));
        adv = new CoreSimAdv(address(usdc), address(wallet));
        sim = CoreSim(address(adv));
        wallet.setSim(sim);
        etchCoreSim(sim);
        sim.listAsset(BTC, 5, 100_000e1);
        sim.listAsset(ETH, 4, 3_000e2);
        sim.listAsset(SOL, 2, 150e4);

        HyperVault impl = new HyperVault();
        VaultPolicy pimpl = new VaultPolicy();
        factory = new HyperVaultFactory(
            fOwner, address(impl), address(pimpl), IERC20(address(usdc)), ICoreDepositWallet(address(wallet)), treasury, guardian, sentinel
        );
        vm.startPrank(fOwner);
        factory.setOpenLaunch(true);
        factory.setAssetCurated(BTC, true);
        factory.setAssetCurated(ETH, true);
        factory.setMaxDepositCap(type(uint256).max);
        factory.registerPlatformAgent(agent, factory.predictVaultAddress(owner, bytes32(0)));
        vm.stopPrank();

        usdc.mint(owner, 2e6);
        vm.deal(owner, 1 ether);
        vm.startPrank(owner);
        usdc.approve(address(factory), 2e6);
        uint32[] memory assets = new uint32[](2);
        assets[0] = BTC;
        assets[1] = ETH;
        (address va, address pa) = factory.create{value: 0.01 ether}(
            HyperVaultFactory.CreateParams({
                name: "Sim",
                symbol: "SIM",
                owner: owner,
                manager: manager,
                feeRecipient: feeRecipient,
                managementFeeBps: _mgmtBps(),
                performanceFeeBps: _perfBps(),
                timelockDelay: 2 days,
                depositCap: type(uint256).max,
                risk: _risk(),
                assets: assets,
                agent: agent,
                agentSig: "",
                agentDeadline: 0,
                operator: operator,
                hosted: true,
                seedUsdc: 2e6,
                salt: bytes32(0)
            }),
            HyperVaultFactory.PermitData(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();
        vault = HyperVault(va);
        vpolicy = VaultPolicy(pa);
        _tick(2);
        if (vault.agentActiveAt() > vm.getBlockTimestamp()) _tick(vault.agentActiveAt() - vm.getBlockTimestamp());
        _tick(1);
        assertEq(sim.agentOf(va), address(0), "HL-PROXY: no HyperCore approval for the agent");

        address[3] memory users = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            usdc.mint(users[i], 10_000_000e6);
            vm.prank(users[i]);
            usdc.approve(va, type(uint256).max);
        }
        usdc.mint(owner, 10_000_000e6);
        vm.prank(owner);
        usdc.approve(va, type(uint256).max);
        _tick(MAX_UNLANDED() + 1);

        _bootstrap(100_000e6);
        VaultPolicy.RiskConfig memory r = _risk();
        adv.setBand(r.maxSlippageBps);
        h = new WP5HLStolenAgentHandler(
            vault,
            adv,
            usdc,
            [owner, manager, operator, guardian, sentinel, feeRecipient, treasury, agent, stranger, alice, bob, carol, address(0)],
            r.maxSlippageBps,
            r.maxDailyLossBps
        );
        h.snapshotStart();
        targetContract(address(h));
        targetSelector(FuzzSelector({addr: address(h), selectors: _selectors()}));
    }

    function _selectors() internal pure returns (bytes4[] memory sel) {
        sel = new bytes4[](50);
        // the hl-r2 actions and weights (ConservationInvariants.t.sol), unchanged
        sel[0] = ConservationHandler.roll.selector;
        sel[1] = ConservationHandler.warp.selector;
        sel[2] = ConservationHandler.deposit.selector;
        sel[3] = ConservationHandler.redeem.selector;
        sel[4] = ConservationHandler.cancelDeposit.selector;
        sel[5] = ConservationHandler.cancelRedeem.selector;
        sel[6] = ConservationHandler.claim.selector;
        sel[7] = ConservationHandler.transferShares.selector;
        sel[8] = ConservationHandler.settle.selector;
        sel[9] = ConservationHandler.accrueFees.selector;
        sel[10] = ConservationHandler.lowerFees.selector;
        sel[11] = ConservationHandler.queueFees.selector;
        sel[12] = ConservationHandler.executeQueued.selector;
        sel[13] = ConservationHandler.bridgeToCore.selector;
        sel[14] = ConservationHandler.bridgeToEvm.selector;
        sel[15] = ConservationHandler.moveUsd.selector;
        sel[16] = ConservationHandler.faults.selector;
        sel[17] = ConservationHandler.syncBridge.selector;
        sel[18] = ConservationHandler.pnlShock.selector;
        sel[19] = ConservationHandler.markMove.selector;
        sel[20] = ConservationHandler.managerOrder.selector;
        sel[21] = ConservationHandler.flatten.selector;
        sel[22] = ConservationHandler.agentAction.selector; // the agent signing HyperCore actions directly: never accepted
        sel[23] = ConservationHandler.checkRisk.selector;
        sel[24] = ConservationHandler.breachOps.selector;
        sel[25] = ConservationHandler.settle.selector;
        sel[26] = ConservationHandler.settle.selector;
        sel[27] = ConservationHandler.roll.selector;
        sel[28] = ConservationHandler.deposit.selector;
        sel[29] = ConservationHandler.redeem.selector;
        sel[30] = ConservationHandler.claim.selector;
        sel[31] = ConservationHandler.bridgeToEvm.selector;
        sel[32] = ConservationHandler.checkRisk.selector;
        sel[33] = ConservationHandler.keeperCycle.selector;
        sel[34] = ConservationHandler.keeperCycle.selector;
        sel[35] = ConservationHandler.keeperCycle.selector;
        sel[36] = ConservationHandler.faults.selector;
        // the stolen agent
        sel[37] = WP5HLStolenAgentHandler.saPlaceOrder.selector;
        sel[38] = WP5HLStolenAgentHandler.saPlaceOrder.selector;
        sel[39] = WP5HLStolenAgentHandler.saPlaceOrder.selector;
        sel[40] = WP5HLStolenAgentHandler.saPlaceOrder.selector;
        sel[41] = WP5HLStolenAgentHandler.saChurn.selector;
        sel[42] = WP5HLStolenAgentHandler.saChurn.selector;
        sel[43] = WP5HLStolenAgentHandler.saCancel.selector;
        sel[44] = WP5HLStolenAgentHandler.saPublic.selector;
        sel[45] = WP5HLStolenAgentHandler.saForbidden.selector;
        sel[46] = WP5HLStolenAgentHandler.saSettle.selector;
        sel[47] = WP5HLStolenAgentHandler.saClaimFor.selector;
        sel[48] = WP5HLStolenAgentHandler.saRebind.selector;
        sel[49] = WP5HLStolenAgentHandler.saPlaceOrder.selector;
    }

    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_conservationAndStolenAgent() public view {
        // ---- hl-r2 C1-C3, F1-F12 (ConservationInvariants.t.sol, unchanged)
        (int256 left, int256 right) = h.conservation();
        assertEq(left, right, "C1 USDC conservation");
        assertGe(
            usdc.balanceOf(address(vault)),
            vault.pendingDepositAssets() + vault.deferredDepositAssets() + vault.claimableRedeemAssets(),
            "C2 reserve not backed"
        );
        (uint256 owedShares, uint256 owedAssets) = h.owedTotals();
        assertGe(vault.claimableRedeemAssets(), owedAssets, "C3 claimable < owed");
        assertGe(vault.balanceOf(address(vault)), vault.pendingRedeemShares() + owedShares, "C3 vault shares < owed");
        assertEq(h.vOverstatedNav(), 0, "F1 settle at a NAV above the true NAV");
        assertEq(h.vUnexplainedUnder(), 0, "F2 settle below the true NAV without a documented reason");
        assertEq(h.vDepositorOverpaid(), 0, "F3 depositors over-credited");
        assertEq(h.vRedeemerOverpaid(), 0, "F4 redeemers over-paid");
        assertEq(h.vNormalUnfair(), 0, "F5 normal settle moved value");
        assertEq(h.vRedeemBelowRule(), 0, "F6 redeemers paid below min(NAV, checkpoint)");
        assertEq(h.vMintInExit(), 0, "F7 mint in an exit / redemption-only settle");
        assertEq(h.vFeeOverCap(), 0, "F8 fee above the configured rates");
        assertEq(h.vPerfInBreach(), 0, "F9 performance fee outside a normal settle");
        assertEq(h.vProtocolSplit(), 0, "F10 protocol split");
        assertEq(h.vClaimMismatch(), 0, "F11 claim != epoch record");
        assertEq(h.vCancelMismatch(), 0, "F12 cancel mismatch");

        // ---- stolen agent
        assertEq(adv.vFillOverBand(), 0, "SA1 an agent fill gave away more than band + fee");
        assertEq(h.vTurnover(), 0, "SA2 agent opened notional above maxTurnoverBps x NAV in a UTC day");
        assertEq(h.vOrderRate(), 0, "SA2 agent risk-adding orders above maxOrdersPerHour");
        uint256 band = h.bandBps();
        uint256 fee = adv.takerFeeBps();
        uint256 n = h.daysCount();
        for (uint256 i; i < n; ++i) {
            uint256 d = h.dayAt(i);
            uint256 lossDay = adv.agentLossDay(d);
            uint256 churn = (adv.agentNtlDay(d) * (band * 10_000 + fee * (10_000 + band))) / 1e8 + adv.agentSizeDay(d)
                + adv.agentFillsDay(d) + 1;
            uint256 limit = (h.navMaxDay(d) * h.dailyLossBps()) / 10_000;
            assertLe(lossDay, limit + churn, "SA3 agent loss in a UTC day above daily loss limit + churn bound");
        }
        assertEq(usdc.balanceOf(agent), 0, "SA4 agent holds USDC");
        assertEq(vault.balanceOf(agent), 0, "SA4 agent holds shares");
        assertEq(adv.sentToOthers(address(vault)), 0, "SA4 the vault's Core account sent value to another account");
        assertEq(adv.agentActions(address(vault)), 0, "SA4 HyperCore accepted an action signed by the agent");
        assertEq(h.saOutsidePolicyAccepted(), 0, "SA4 agent opened risk on an asset outside the policy");
        assertEq(h.saBadTifAccepted(), 0, "SA4 agent order with a non-IOC TIF / zero / ticket cloid accepted");
        assertEq(h.saOtherAccepted(), 0, "SA4 agent got a role-gated call through");
    }

    function afterInvariant() external {
        emit log_named_uint("settles normal", h.settlesNormal());
        emit log_named_uint("settles redemption-only", h.settlesRedemptionOnly());
        emit log_named_uint("settles exit-only", h.settlesExitOnly());
        emit log_named_uint("claims checked", h.claimsChecked());
        emit log_named_uint("fee checks", h.feeChecks());
        emit log_named_uint("SA calls", h.saCalls());
        emit log_named_uint("SA orders sent", h.saOrdersSent());
        emit log_named_uint("SA orders open", h.saOrdersOpen());
        emit log_named_uint("SA orders reduce", h.saOrdersReduce());
        emit log_named_uint("SA orders refused (risk check)", h.saOrdersRefused());
        emit log_named_uint("SA orders reverted", h.saOrdersReverted());
        emit log_named_uint("SA fills", adv.agentFills());
        emit log_named_uint("SA fills reduce only", adv.agentFillsReduce());
        emit log_named_uint("SA loss total (6 dec)", adv.agentLossTotal());
        emit log_named_uint("SA fee total (6 dec)", adv.agentFeeTotal());
        emit log_named_uint("SA churn rounds", h.saChurnRounds());
        emit log_named_uint("SA settles", h.saSettles());
        emit log_named_uint("SA public ok", h.saPublicOk());
        emit log_named_uint("SA forbidden reverted", h.saOtherReverted());
        emit log_named_uint("SA rebinds", h.saRebinds());
        emit log_named_uint("SA max day loss / NAV (bps)", h.maxDayLossBps());
        emit log_named_uint("SA max day loss / true NAV (bps)", h.maxDayLossBpsTrue());
        emit log_named_uint("M agent orders above 20 x true NAV (HL-INV-01)", h.mTurnoverAboveTrueNav());
        emit log_named_uint("last violation code", h.lastViolationCode());
    }

    // ------------------------------------------------------------------
    // Coverage: a short deterministic drive of the actor (invariant after every call); the agent must trade.
    // ------------------------------------------------------------------
    function test_saCoverage() public {
        for (uint256 i; i < 160; ++i) {
            uint256 r = uint256(keccak256(abi.encode(i, "wp5-sa")));
            uint256 k = r % 10;
            uint256 a = uint256(keccak256(abi.encode(r, 1)));
            uint256 b = uint256(keccak256(abi.encode(r, 2)));
            if (k < 4) h.saPlaceOrder(a, b % 2 == 0, a >> 3, b, (a >> 7) % 3 == 0, b >> 9, a >> 11);
            else if (k == 4) h.saChurn(a, b);
            else if (k == 5) h.saPublic(a);
            else if (k == 6) h.saForbidden(a, b);
            else if (k == 7) h.saSettle(a);
            else if (k == 8) h.roll(a);
            else h.markMove(a, int256(b % 2001) - 1000);
            invariant_conservationAndStolenAgent();
        }
        emit log_named_uint("SA fills", adv.agentFills());
        emit log_named_uint("SA fills reduce only", adv.agentFillsReduce());
        emit log_named_uint("SA orders sent", h.saOrdersSent());
        emit log_named_uint("SA loss total (6 dec)", adv.agentLossTotal());
        assertGt(adv.agentFills(), 0, "the stolen agent never traded");
        assertGt(adv.agentFillsReduce(), 0, "the stolen agent never closed");
        assertGt(h.saOrdersOpen(), 0, "no risk-adding agent order went through");
        assertGt(adv.agentLossTotal(), 0, "the agent's fills never gave value away");
    }
}

/// @notice The platform vault's live policy: 5x, daily loss 20%, drawdown 50%, slippage 1%, owner = manager.
contract WP5HLStolenAgentPlatformVault is WP5HLStolenAgentBase {}

/// @notice hl-r2's tight policy with a separate manager: daily loss 5%, 3x, drawdown 15%, 5% / 30% fees.
contract WP5HLStolenAgentTight is WP5HLStolenAgentBase {
    function _managerAddr() internal override returns (address) {
        return makeAddr("manager");
    }

    function _risk() internal pure override returns (VaultPolicy.RiskConfig memory) {
        return VaultPolicy.RiskConfig({
            maxLeverageBps: 30_000,
            maxDailyLossBps: 500,
            maxDrawdownBps: 1_500,
            maxSlippageBps: 100,
            maxOrderNotional: 1_000_000e6,
            maxEpochDuration: 1 days,
            maxNavMoveBps: 1_000,
            maxFlattenSlippageBps: 300
        });
    }

    function _mgmtBps() internal pure override returns (uint16) {
        return 500;
    }

    function _perfBps() internal pure override returns (uint16) {
        return 3_000;
    }
}

/// @notice Replays of shrunk sequences from the WP5 campaigns (logs: audit/fix-round/wp5-logs/inv/).
contract WP5HLStolenAgentReplay is WP5HLStolenAgentBase {
    function _dump(string memory tag) internal {
        emit log_string(tag);
        emit log_named_uint("  trueNav", h.trueNav());
        emit log_named_uint("  totalAssets", vault.totalAssets());
        emit log_named_uint("  idle", vault.idleAssets());
        emit log_named_uint("  coreEquity", vault.coreEquity());
        emit log_named_int("  sim accountValue", adv.accountValue(address(vault)));
        emit log_named_uint("  sim spot", adv.spotUsd(address(vault)));
        emit log_named_uint("  inflight to core", adv.inflightToCore(address(vault)));
        emit log_named_uint("  inflight to evm", adv.inflightToEvm(address(vault)));
        emit log_named_uint("  bridgePending", vault.bridgePending() ? 1 : 0);
        emit log_named_uint("  checkpointNav", vault.checkpointNav());
        emit log_named_uint("  pending items", adv.pendingItems());
        (int64 b,) = adv.position(address(vault), 0);
        (int64 e,) = adv.position(address(vault), 1);
        emit log_named_int("  pos BTC", b);
        emit log_named_int("  pos ETH", e);
    }

    /// smoke-hl-platform-32x100-b: F1 (settle at a NAV above the true NAV). Harness bug: CoreSim had no margin check,
    /// so the agent's orders filled on an account the keeper's bridge home had just emptied; its value went below
    /// zero, which the vault's coreEquity floors at 0 (L-05, documented), so the vault's NAV read above the truth.
    function test_replay_F1_smoke_b() public {
        vm.prank(address(0x2C69));
        h.redeem(88200, 19553);
        _dump("after redeem");
        h.keeperCycle(12466);
        _dump("after keeperCycle 1");
        h.saChurn(250000000000, 25);
        _dump("after churn 1");
        h.saChurn(23241, 9671);
        _dump("after churn 2");
        h.keeperCycle(4);
        _dump("after keeperCycle 2");
        emit log_named_uint("vOverstatedNav", h.vOverstatedNav());
        emit log_named_uint("lastViolationCode", h.lastViolationCode());
        emit log_named_uint("agent orders refused by the margin check", adv.agentOrdersMarginRejected());
        // with HyperCore's margin check modelled the agent's orders behind the keeper's perp -> spot transfer are
        // refused: the account never goes negative and the settle prices at the true NAV
        assertGe(adv.accountValue(address(vault)), 0, "perp account value below zero");
        invariant_conservationAndStolenAgent();
    }

    function _dumpFlow(string memory tag) internal {
        emit log_string(tag);
        uint256 d = vm.getBlockTimestamp() / 1 days;
        (uint256 used, uint256 orders) = vault.agentFlow();
        emit log_named_uint("  day", d);
        emit log_named_uint("  agentFlow used", used);
        emit log_named_uint("  agentFlow orders", orders);
        emit log_named_uint("  handler openNtlDay", h.openNtlDay(d));
        emit log_named_uint("  handler navMaxDay", h.navMaxDay(d));
        emit log_named_uint("  trueNav", h.trueNav());
        emit log_named_uint("  idle + coreEquity", vault.idleAssets() + vault.coreEquity());
        emit log_named_uint("  bridgePending", vault.bridgePending() ? 1 : 0);
        emit log_named_uint("  bridgeAmount", vault.bridgeAmount());
        emit log_named_uint("  equityAtBridge", vault.equityAtBridge());
        emit log_named_uint("  vTurnover", h.vTurnover());
    }

    /// heavy-hl-platform-2048x500: SA2 (agent opened notional above maxTurnoverBps x NAV in a UTC day). HL-INV-01, fixed:
    /// on the unfixed vault (3d75366 src) this sequence opened more than 20 x the true NAV (superseded log
    /// heavy-hl-platform-2048x500.run1-SA2-HL-INV-01.txt); with the budget on the visible NAV it stays within it.
    function test_replay_SA2_heavy() public {
        h.deposit(200000000000, 1000);
        h.faults(3000000000000000000000);
        h.keeperCycle(10712);
        _dumpFlow("after keeperCycle 1");
        h.keeperCycle(25);
        _dumpFlow("after keeperCycle 2");
        h.saChurn(16149, 10000000000);
        _dumpFlow("after churn 1");
        h.saChurn(17396, 3000000000000000000000);
        _dumpFlow("after churn 2");
        uint256 d = vm.getBlockTimestamp() / 1 days;
        emit log_named_uint("true NAV max of the day", h.trueNavMaxDay(d));
        emit log_named_uint("agent loss of the day", adv.agentLossDay(d));
        emit log_named_uint("agent loss / true NAV (bps)", h.maxDayLossBpsTrue());
        // HL-INV-01: the bridged 300k is never credited on HyperCore (lost transfer). The turnover budget read
        // min(visible + bridgeAmount, equityAtBridge) = 400k until the window closed; it now reads the visible NAV,
        // which is the true NAV here, so the agent opens at most 20 x the true NAV in the day.
        assertLe(h.openNtlDay(d), 20 * h.trueNavMaxDay(d), "opened notional within 20 x true NAV");
        assertEq(h.vTurnover(), 0, "within 20 x the NAV the vault read");
        invariant_conservationAndStolenAgent();
    }
}
