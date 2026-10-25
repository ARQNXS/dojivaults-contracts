// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {SimBase} from "./SimBase.t.sol";
import {VaultPolicy} from "../../../../src/VaultPolicy.sol";
import {ConservationHandler} from "./ConservationHandler.sol";

/// @notice hl-r2 conservation invariant on CoreSim (INVARIANTS.md). test_coverage needs FOUNDRY_GAS_LIMIT raised. Two configurations: the live platform vault policy
///         (owner = manager) and a tight policy with a separate manager (breaches and exit modes are frequent).
/// Run (light): forge test --match-path test/audit/hl-r2/async/ConservationInvariants.t.sol
/// Heavy run (lock!): FOUNDRY_INVARIANT_RUNS=2048 FOUNDRY_INVARIANT_DEPTH=500 forge test --match-path ...
abstract contract ConservationBase is SimBase {
    ConservationHandler internal handler;
    address internal stranger = makeAddr("stranger");

    function setUp() public virtual override {
        super.setUp();
        // a vault with history: alice 100k settled and on Core perp
        _bootstrap(100_000e6);
        handler = new ConservationHandler(
            vault,
            sim,
            usdc,
            [owner, manager, operator, guardian, sentinel, feeRecipient, treasury, agent, stranger, alice, bob, carol, address(0)],
            false
        );
        handler.snapshotStart();
        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](37);
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
        sel[22] = ConservationHandler.agentAction.selector;
        sel[23] = ConservationHandler.checkRisk.selector;
        sel[24] = ConservationHandler.breachOps.selector;
        // weights
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
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }

    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_conservation() public view {
        // C1. Every USDC unit: participants + vault EVM + Core + in flight = start + trading PnL - documented Core
        //     losses (activation fee, transfers the bridge lost).
        (int256 left, int256 right) = handler.conservation();
        assertEq(left, right, "C1 USDC conservation");

        // C2. Reserved USDC (pending + deferred deposits, settled redemptions and refunds) is on the EVM.
        assertGe(
            usdc.balanceOf(address(vault)),
            vault.pendingDepositAssets() + vault.deferredDepositAssets() + vault.claimableRedeemAssets(),
            "C2 reserve not backed"
        );

        // C3. What the epoch records owe every participant is covered (USDC reserve, vault-held shares).
        (uint256 owedShares, uint256 owedAssets) = handler.owedTotals();
        assertGe(vault.claimableRedeemAssets(), owedAssets, "C3 claimable < owed");
        assertGe(vault.balanceOf(address(vault)), vault.pendingRedeemShares() + owedShares, "C3 vault shares < owed");

        // F. Fairness and fee ghosts.
        assertEq(handler.vOverstatedNav(), 0, "F1 settle at a NAV above the true NAV");
        assertEq(handler.vUnexplainedUnder(), 0, "F2 settle below the true NAV without a documented reason");
        assertEq(handler.vDepositorOverpaid(), 0, "F3 depositors over-credited");
        assertEq(handler.vRedeemerOverpaid(), 0, "F4 redeemers over-paid");
        assertEq(handler.vNormalUnfair(), 0, "F5 normal settle moved value");
        assertEq(handler.vRedeemBelowRule(), 0, "F6 redeemers paid below min(NAV, checkpoint)");
        assertEq(handler.vMintInExit(), 0, "F7 mint in an exit / redemption-only settle");
        assertEq(handler.vFeeOverCap(), 0, "F8 fee above the configured rates");
        assertEq(handler.vPerfInBreach(), 0, "F9 performance fee outside a normal settle");
        assertEq(handler.vProtocolSplit(), 0, "F10 protocol split");
        assertEq(handler.vClaimMismatch(), 0, "F11 claim != epoch record");
        assertEq(handler.vCancelMismatch(), 0, "F12 cancel mismatch");
    }

    function afterInvariant() external {
        emit log_named_uint("settles normal", handler.settlesNormal());
        emit log_named_uint("settles redemption-only", handler.settlesRedemptionOnly());
        emit log_named_uint("settles exit-only", handler.settlesExitOnly());
        emit log_named_uint("settles partial fill", handler.settlesPartial());
        emit log_named_uint("claims checked", handler.claimsChecked());
        emit log_named_uint("fee checks", handler.feeChecks());
        emit log_named_uint("bridges to core", handler.bridgesToCore());
        emit log_named_uint("bridges to evm", handler.bridgesToEvm());
        emit log_named_uint("M late settles", handler.mLateSettles());
        emit log_named_uint("M late nav gap", handler.mLateNavGap());
        emit log_named_uint("M late deposit gain", handler.mLateDepositGain());
        emit log_named_uint("M late redeem loss", handler.mLateRedeemLoss());
        emit log_named_uint("M exit underpay", handler.mExitUnderpay());
        emit log_named_uint("M max pending blocks", handler.mMaxPendingBlocks());
        emit log_named_uint("M agent acts after stop", handler.mAgentActsAfterStop());
        emit log_named_uint("M fee value", handler.mFeeValue());
        emit log_named_uint("M first mint windfall (A08)", handler.mFirstMintWindfall());
        emit log_named_uint("epoch", vault.currentEpoch());
        emit log_named_uint("last violation code", handler.lastViolationCode());
    }

    // ------------------------------------------------------------------
    // Coverage probe: forge only reports the last run's counters, so test_coverage drives the same handler with
    // pseudo random calls over many sequences (invariant checked after every call) and prints the totals.
    // ------------------------------------------------------------------

    function _call(uint256 r) internal {
        uint256 k = r % 29;
        uint256 a = uint256(keccak256(abi.encode(r, 1)));
        uint256 b = uint256(keccak256(abi.encode(r, 2)));
        if (k == 0) handler.roll(a);
        else if (k == 1) handler.warp(a);
        else if (k == 2 || k == 3) handler.deposit(a, b);
        else if (k == 4) handler.redeem(a, b);
        else if (k == 5) handler.cancelDeposit(a);
        else if (k == 6) handler.cancelRedeem(a);
        else if (k == 7) handler.claim(a);
        else if (k == 8) handler.transferShares(a, b, r);
        else if (k == 9 || k == 10) handler.settle(a);
        else if (k == 11) handler.accrueFees();
        else if (k == 12) handler.queueFees(a, b);
        else if (k == 13) handler.executeQueued(a);
        else if (k == 14) handler.bridgeToCore(a, b);
        else if (k == 15) handler.bridgeToEvm(a, b);
        else if (k == 16) handler.moveUsd(a, b);
        else if (k == 17) handler.faults(a);
        else if (k == 18) handler.pnlShock(int256(b % 1601) - 800);
        else if (k == 19) handler.markMove(a, int256(b % 2001) - 1000);
        else if (k == 20) handler.managerOrder(a, b);
        else if (k == 21) handler.agentAction(a, b);
        else if (k == 22) handler.checkRisk();
        else if (k == 23) handler.breachOps(a);
        else if (k == 24) handler.lowerFees(a, b);
        else if (k == 28) handler.faults(b);
        else handler.keeperCycle(a);
    }

    function _collect(uint256[17] memory tot) internal view {
        uint256[17] memory v = [
            handler.settlesNormal(),
            handler.settlesRedemptionOnly(),
            handler.settlesExitOnly(),
            handler.settlesPartial(),
            handler.claimsChecked(),
            handler.feeChecks(),
            handler.bridgesToCore(),
            handler.bridgesToEvm(),
            handler.mLateSettles(),
            handler.mLateNavGap(),
            handler.mLateDepositGain(),
            handler.mLateRedeemLoss(),
            handler.mExitUnderpay(),
            handler.mMaxPendingBlocks(),
            handler.mAgentActsAfterStop(),
            handler.mFeeValue(),
            vault.currentEpoch()
        ];
        for (uint256 i; i < 17; ++i) {
            if (i == 13) {
                if (v[i] > tot[i]) tot[i] = v[i];
            } else {
                tot[i] += v[i];
            }
        }
    }

    /// Coverage probe: needs a raised gas limit, so it only runs on request:
    /// HLR2_PROBE=true FOUNDRY_GAS_LIMIT=18446744073709551615 forge test --match-test test_coverage ...
    function test_coverage() public {
        if (!vm.envOr("HLR2_PROBE", false)) {
            vm.skip(true);
            return;
        }
        uint256 seqs = vm.envOr("HLR2_PROBE_SEQS", uint256(24));
        uint256 depth = vm.envOr("HLR2_PROBE_DEPTH", uint256(300));
        uint256[17] memory tot; // memory survives revertToState, storage does not
        uint256 snap = vm.snapshotState();
        for (uint256 s; s < seqs; ++s) {
            for (uint256 d; d < depth; ++d) {
                _call(uint256(keccak256(abi.encode(s, d, "hlr2"))));
                invariant_conservation();
            }
            _collect(tot);
            vm.revertToState(snap);
        }
        string[17] memory names = [
            "settles normal",
            "settles redemption-only",
            "settles exit-only",
            "settles partial fill",
            "claims checked",
            "fee checks",
            "bridges to core",
            "bridges to evm",
            "M late settles",
            "M late nav gap",
            "M late deposit gain",
            "M late redeem loss",
            "M exit underpay",
            "M max pending blocks (max)",
            "M agent acts after stop",
            "M fee value",
            "epochs settled"
        ];
        for (uint256 i; i < 17; ++i) {
            emit log_named_uint(names[i], tot[i]);
        }
    }
}

/// @notice Live platform vault policy: 5x, daily loss 20%, drawdown 50%, maxNavMove 20%, owner = manager.
contract ConservationPlatformVaultInvariants is ConservationBase {}

/// @notice Tight policy with a separate manager: breaches, redemption-only and exit-only settles are frequent.
contract ConservationTightInvariants is ConservationBase {
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
