// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Base} from "../../Base.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HyperVault} from "../../../src/HyperVault.sol";
import {HyperVaultFactory} from "../../../src/HyperVaultFactory.sol";
import {ICoreDepositWallet} from "../../../src/hypercore/HyperCore.sol";
import {VaultHandler} from "./VaultHandler.sol";

/// @notice Invariant suite for a factory-created, hosted HyperVault with a protocol share, a platform agent and
///         the platform guardian.
/// Run: forge test --match-path test/audit/invariants/VaultInvariants.t.sol -vv
contract VaultInvariants is Base {
    HyperVaultFactory internal factory;
    HyperVault internal fv;
    VaultHandler internal handler;
    address internal treasury = makeAddr("treasury");
    address internal agentAddr = makeAddr("inv.agent");

    uint256 internal constant CAP = 10_000_000e6;

    function setUp() public override {
        super.setUp();
        factory = new HyperVaultFactory(
            owner,
            address(vaultImpl),
            address(policyImpl),
            IERC20(address(usdc)),
            ICoreDepositWallet(address(depositWallet)),
            treasury,
            guardian,
            sentinel
        );
        vm.startPrank(owner);
        factory.setOpenLaunch(true);
        factory.setAssetCurated(BTC, true);
        factory.setAssetCurated(ETH, true);
        factory.registerPlatformAgent(agentAddr, factory.predictVaultAddress(owner, bytes32(0)));
        factory.setMaxDepositCap(CAP);
        usdc.mint(owner, 2e6);
        vm.deal(owner, 1 ether);
        usdc.approve(address(factory), 2e6);
        uint32[] memory assets = new uint32[](2);
        assets[0] = BTC;
        assets[1] = ETH;
        (address va,) = factory.create{value: 0.01 ether}(
            HyperVaultFactory.CreateParams({
                name: "Inv",
                symbol: "INV",
                owner: owner,
                manager: manager,
                feeRecipient: feeRecipient,
                managementFeeBps: 500,
                performanceFeeBps: 3_000,
                timelockDelay: 1 days,
                depositCap: CAP,
                risk: _defaultRisk(),
                assets: assets,
                agent: agentAddr,
                agentSig: "",
                agentDeadline: 0,
                operator: address(0),
                hosted: true,
                seedUsdc: 2e6,
                salt: bytes32(0)
            }),
            HyperVaultFactory.PermitData(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();
        fv = HyperVault(va);
        _setCoreUser(va, true);
        _setPosition(va, BTC, 0);
        _setPosition(va, ETH, 0);

        handler = new VaultHandler(fv, lens, usdc, factory, owner, manager, guardian, feeRecipient, treasury, agentAddr);
        handler.sync();
        vm.roll(vm.getBlockNumber() + 11);
        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](29);
        sel[0] = VaultHandler.warp.selector;
        sel[1] = VaultHandler.requestDeposit.selector;
        sel[2] = VaultHandler.requestRedeem.selector;
        sel[3] = VaultHandler.cancelDeposit.selector;
        sel[4] = VaultHandler.cancelRedeem.selector;
        sel[5] = VaultHandler.claim.selector;
        sel[6] = VaultHandler.settle.selector;
        sel[7] = VaultHandler.accrueFees.selector;
        sel[8] = VaultHandler.bridgeToCore.selector;
        sel[9] = VaultHandler.bridgeToEvm.selector;
        sel[10] = VaultHandler.moveUsd.selector;
        sel[11] = VaultHandler.pnl.selector;
        sel[12] = VaultHandler.zeroCore.selector;
        sel[13] = VaultHandler.outage.selector;
        sel[14] = VaultHandler.checkRisk.selector;
        sel[15] = VaultHandler.flattenStranger.selector;
        sel[16] = VaultHandler.triggerEmergencyStranger.selector;
        sel[17] = VaultHandler.ownerOps.selector;
        sel[18] = VaultHandler.queue.selector;
        sel[19] = VaultHandler.execute.selector;
        sel[20] = VaultHandler.settle.selector; // weight settle x2
        sel[21] = VaultHandler.requestDeposit.selector; // weight deposits x2
        sel[22] = VaultHandler.hide.selector;
        sel[23] = VaultHandler.unhide.selector;
        sel[24] = VaultHandler.insiderDeposit.selector;
        sel[25] = VaultHandler.guardianOps.selector;
        sel[26] = VaultHandler.checkRisk.selector; // weight the keeper x2
        sel[27] = VaultHandler.warp.selector; // weight time x2
        sel[28] = VaultHandler.sentinelOps.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }

    /// forge-config: default.invariant.runs = 512
    /// forge-config: default.invariant.depth = 200
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_suite() public view {
        // 1. Reserved USDC (pending deposits + settled redemptions and refunds) is always backed by EVM USDC.
        assertGe(
            usdc.balanceOf(address(fv)),
            fv.pendingDepositAssets() + fv.claimableRedeemAssets(),
            "reserved USDC not backed"
        );

        // 2. Shares the vault holds cover pending redemptions plus every unclaimed deposit; claimable USDC is covered.
        address[3] memory a = handler.actorList();
        uint256 owedShares = fv.pendingRedeemShares();
        uint256 owedAssets;
        uint256 holderValue;
        for (uint256 i; i < 3; ++i) {
            (uint256 s, uint256 x) = lens.claimable(fv, a[i]);
            owedShares += s;
            owedAssets += x;
            holderValue += fv.convertToAssets(fv.balanceOf(a[i]));
        }
        assertGe(fv.balanceOf(address(fv)), owedShares, "vault-held shares < owed shares");
        assertGe(fv.claimableRedeemAssets(), owedAssets, "claimable USDC < owed USDC");

        // 3. No value from nothing: all holders' share value <= NAV.
        holderValue += fv.convertToAssets(fv.balanceOf(address(fv)));
        holderValue += fv.convertToAssets(fv.balanceOf(feeRecipient));
        holderValue += fv.convertToAssets(fv.balanceOf(treasury));
        assertLe(holderValue, fv.totalAssets() + 1, "share value exceeds NAV");

        // 4. Full stop => agent revoked; emergency => breached (deposits closed via ghost below).
        // Round 4: a full stop (guardian / sentinel / owner breach, emergency) still means the agent is revoked;
        // only the risk breaches (leverage, daily loss, drawdown) keep it. Any live agent is always the platform
        // agent the factory bound to this vault.
        if (fv.emergency() || (fv.breached() && uint8(fv.breachReason()) >= 4)) {
            assertEq(fv.agent(), address(0), "full stop with live agent");
        }
        if (fv.agent() != address(0)) assertEq(factory.platformAgentFor(fv.agent()), address(fv), "live agent not bound to this vault");
        if (fv.emergency()) assertTrue(fv.breached(), "emergency without breach");

        // 5. protocolShareBps only ever <= the hosted rate it was created with.
        assertLe(fv.protocolShareBps(), 3_300, "protocol share above creation rate");

        // 6. Platform roles are fixed: the platform guardian, platform agents only, cap within the platform max.
        assertEq(fv.guardian(), guardian, "guardian replaced");
        assertEq(fv.sentinel(), sentinel, "sentinel replaced");
        assertTrue(fv.agent() == address(0) || factory.isPlatformAgent(fv.agent()), "foreign agent");
        assertLe(fv.depositCap(), factory.maxDepositCap(), "cap above platform max");
        assertGt(fv.depositCap(), 0);

        // 7. Round 4: an insider may hold a pending deposit, but never one priced in the epoch it was requested in
        //    (it always belongs to a later epoch than the one current at the request).
        address[3] memory insiders = [manager, owner, feeRecipient];
        for (uint256 i; i < 3; ++i) {
            (uint256 ep, uint256 dep,) = fv.requests(insiders[i]);
            if (dep > 0) assertGt(ep, handler.insiderAskedAt(insiders[i]), "insider deposit priced in its own epoch");
        }

        // 8. Ghost guarantees recorded by the handler.
        assertEq(handler.vShareIncreased(), 0, "protocol share increased");
        assertEq(handler.vBreachWithAgent(), 0, "full stop left agent");
        assertEq(handler.vEmergencyNotBreached(), 0, "emergency not breached");
        assertEq(handler.vDepositWhileClosed(), 0, "deposit accepted while closed");
        assertEq(handler.vInsiderDeposit(), 0, "insider deposit accepted");
        assertEq(handler.vEarlyExecute(), 0, "timelock executed early");
        assertEq(handler.vLateExecute(), 0, "timelock executed after the grace period");
        assertEq(handler.vBadSelectorQueued(), 0, "non whitelisted selector queued");
        assertEq(handler.vFeeOverCap(), 0, "fee above configured cap");
        assertEq(handler.vProtocolSplit(), 0, "protocol split != locked bps");
        assertEq(handler.vPeakReset(), 0, "fee dilution lowered the peak more than the dilution");
        assertEq(handler.vPriceJump(), 0, "share price jumped at settle");
        assertEq(handler.vPreviewMismatch(), 0, "lens preview != settle");
        assertEq(handler.vDepositOverValued(), 0, "depositor got more than deposited");
        assertEq(handler.vFlattenUnauthorized(), 0, "unauthorised flatten");
        assertEq(handler.vSettleInWindow(), 0, "settled inside bridge window");
        assertEq(handler.vSettleWhileBreached(), 0, "settled while breached outside emergency");
        assertEq(handler.vSettleFarFromCheckpoint(), 0, "settled a NAV outside the checkpoint band");
        assertEq(handler.vEmergencyMinted(), 0, "emergency settlement minted shares");
        assertEq(handler.vEmergencyUnauthorized(), 0, "unauthorised emergency power");
        assertEq(handler.vExitBlockedByOutage(), 0, "redeem request blocked by precompile outage");
        assertEq(handler.vInstantOwnerPower(), 0, "owner bypassed a timelock or exited emergency with redeemers");
        assertEq(handler.vGuardianReplaced(), 0, "platform guardian replaced");
        assertEq(handler.vForeignAgent(), 0, "non platform agent approved");
        assertEq(handler.vDustBridge(), 0, "dust bridge accepted");
        assertEq(handler.vPrequeuedClear(), 0, "clearBreach queued before the breach executed");
        assertEq(handler.vWindowExtended(), 0, "bridge inside a bridge window");
        assertEq(handler.vSentinelPower(), 0, "sentinel used a power it must not have");
    }

    function afterInvariant() external {
        emit log_named_uint("settles ok", handler.settlesOk());
        emit log_named_uint("emergency settles", handler.emergencySettles());
        emit log_named_uint("timelocked executions", handler.timelockedOk());
        emit log_named_uint("fee accruals with fees", handler.feeAccruals());
        emit log_named_uint("breaches", handler.breaches());
        emit log_named_uint("claimable checks", handler.claimsChecked());
        emit log_named_uint("epoch", fv.currentEpoch());
    }
}
