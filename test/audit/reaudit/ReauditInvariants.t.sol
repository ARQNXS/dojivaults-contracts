// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Base} from "../../Base.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HyperVault} from "../../../src/HyperVault.sol";
import {HyperVaultFactory} from "../../../src/HyperVaultFactory.sol";
import {ICoreDepositWallet} from "../../../src/hypercore/HyperCore.sol";
import {ReauditHandler} from "./ReauditHandler.sol";
import {VaultHandler} from "../invariants/VaultHandler.sol";

/// @notice Re-audit invariant suite: the original properties plus the new actions. The four N-* invariants were
///         written as EXPECTFAIL against e68666c (the fuzzer found N-01, N-05, N-07 and N-08); after the round 2
///         fixes they are ordinary invariants and must hold. Run:
///         forge test --match-path test/audit/reaudit/ReauditInvariants.t.sol -vv

contract ReauditInvariants is Base {
    HyperVaultFactory internal factory;
    HyperVault internal fv;
    ReauditHandler internal handler;
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

        handler = new ReauditHandler(fv, lens, usdc, factory, owner, manager, guardian, feeRecipient, treasury, agentAddr);
        handler.sync();
        vm.roll(vm.getBlockNumber() + 11);
        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](34);
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
        sel[28] = ReauditHandler.keeperHour.selector;
        sel[29] = ReauditHandler.holdWindowSettle.selector;
        sel[30] = ReauditHandler.lowerFeesSame.selector;
        sel[31] = ReauditHandler.accrueManagementOnly.selector;
        sel[32] = ReauditHandler.registrarOps.selector;
        sel[33] = ReauditHandler.keeperHour.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }

    /// forge-config: default.invariant.runs = 512
    /// forge-config: default.invariant.depth = 200
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_core() public view {
        assertGe(usdc.balanceOf(address(fv)), fv.pendingDepositAssets() + fv.claimableRedeemAssets(), "reserved USDC not backed");
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
        holderValue += fv.convertToAssets(fv.balanceOf(address(fv)));
        holderValue += fv.convertToAssets(fv.balanceOf(feeRecipient));
        holderValue += fv.convertToAssets(fv.balanceOf(treasury));
        assertLe(holderValue, fv.totalAssets() + 1, "share value exceeds NAV");
        // Round 4: a full stop (guardian / sentinel / owner breach, emergency) still means the agent is revoked;
        // only the risk breaches (leverage, daily loss, drawdown) keep it. Any live agent is always the platform
        // agent the factory bound to this vault.
        if (fv.emergency() || (fv.breached() && uint8(fv.breachReason()) >= 4)) {
            assertEq(fv.agent(), address(0), "full stop with live agent");
        }
        if (fv.agent() != address(0)) assertEq(factory.platformAgentFor(fv.agent()), address(fv), "live agent not bound to this vault");
        if (fv.emergency()) assertTrue(fv.breached(), "emergency without breach");
        assertLe(fv.protocolShareBps(), 3_300, "protocol share above creation rate");
        assertEq(fv.guardian(), guardian, "guardian replaced");
        assertEq(handler.vWindowExtended(), 0, "bridge window extended");
        assertEq(handler.vPrequeuedClear(), 0, "pre-queued clearBreach executed");
        assertEq(handler.vSentinelPower(), 0, "sentinel power");
        assertEq(handler.vEarlyExecute() + handler.vLateExecute() + handler.vBadSelectorQueued(), 0, "timelock");
        assertEq(handler.vInstantOwnerPower(), 0, "instant owner power");
        assertEq(handler.vEmergencyMinted(), 0, "emergency settlement minted shares");
        assertEq(handler.vSettleWhileBreached(), 0, "settled while breached");
        assertEq(handler.vDepositWhileClosed() + handler.vInsiderDeposit(), 0, "deposit gate");
        assertEq(handler.vDustBridge(), 0, "dust bridge");
    }

    /// @dev N-01: settle() must price at a NAV that matches the vault's real visible NAV.
    function invariant_N01_noStaleWindowSettle() public view {
        assertEq(handler.vStaleSettle(), 0, "settled at a stale window NAV");
    }

    /// @dev N-05: no performance fee outside settle().
    function invariant_N05_noPerfFeeOutsideSettle() public view {
        assertEq(handler.vPerfOutsideSettle(), 0, "performance fee crystallised by lowerFees");
    }

    /// @dev N-08: the HWM only moves when a performance fee was charged.
    function invariant_N08_hwmOnlyWithFee() public view {
        assertEq(handler.vHwmWithoutFee(), 0, "HWM raised without charging the fee");
    }

    /// @dev N-07: the live agent is always a registered platform agent.
    function invariant_N07_agentStillRegistered() public view {
        assertTrue(fv.agent() == address(0) || factory.isPlatformAgent(fv.agent()), "unregistered agent still live");
    }

    function afterInvariant() external {
        emit log_named_uint("settles ok", handler.settlesOk());
        emit log_named_uint("held-window settles", handler.heldWindowSettles());
        emit log_named_uint("emergency settles", handler.emergencySettles());
        emit log_named_uint("registrar calls", handler.registrarCalls());
    }
}
