// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Base} from "../../Base.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HyperVault} from "../../../src/HyperVault.sol";
import {HyperVaultFactory} from "../../../src/HyperVaultFactory.sol";
import {ICoreDepositWallet} from "../../../src/hypercore/HyperCore.sol";
import {Reaudit2Handler} from "./Reaudit2Handler.sol";
import {ReauditHandler} from "../reaudit/ReauditHandler.sol";
import {VaultHandler} from "../invariants/VaultHandler.sol";

/// @notice Third pass invariant suite (diff e68666c..a75d935): every earlier property plus many-epoch pro-rata
///         emergencies, direct library calls, role rotation mid epoch and fee raises across epochs.
///         Run: forge test --match-path test/audit/reaudit2/Reaudit2Invariants.t.sol -vv
contract Reaudit2Invariants is Base {
    HyperVaultFactory internal factory;
    HyperVault internal fv;
    Reaudit2Handler internal handler;
    address internal treasury = makeAddr("treasury");
    address internal agentAddr = makeAddr("inv.agent");

    uint256 internal constant CAP = 10_000_000e6;

    function setUp() public virtual override {
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
                performanceFeeBps: 2_000,
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
        if (fv.agentActiveAt() > vm.getBlockTimestamp()) vm.warp(fv.agentActiveAt()); // HLO-07: AGENT_WARMUP
        _setCoreUser(va, true);
        _setPosition(va, BTC, 0);
        _setPosition(va, ETH, 0);

        handler = new Reaudit2Handler(
            fv, lens, usdc, factory, owner, manager, guardian, feeRecipient, treasury, agentAddr, _lib("VaultLogic"), _lib("VaultGovernance")
        );
        handler.sync();
        vm.roll(vm.getBlockNumber() + 11);
        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](46);
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
        sel[20] = VaultHandler.settle.selector;
        sel[21] = VaultHandler.requestDeposit.selector;
        sel[22] = VaultHandler.hide.selector;
        sel[23] = VaultHandler.unhide.selector;
        sel[24] = VaultHandler.insiderDeposit.selector;
        sel[25] = VaultHandler.guardianOps.selector;
        sel[26] = VaultHandler.sentinelOps.selector;
        sel[27] = ReauditHandler.keeperHour.selector;
        sel[28] = ReauditHandler.holdWindowSettle.selector;
        sel[29] = ReauditHandler.lowerFeesSame.selector;
        sel[30] = ReauditHandler.accrueManagementOnly.selector;
        sel[31] = ReauditHandler.registrarOps.selector;
        sel[32] = Reaudit2Handler.miniEpoch.selector;
        sel[33] = Reaudit2Handler.miniEpoch.selector; // weight x3: long emergencies
        sel[34] = Reaudit2Handler.miniEpoch.selector;
        sel[35] = Reaudit2Handler.claimMeasured.selector;
        sel[36] = Reaudit2Handler.directLibraryCall.selector;
        sel[37] = Reaudit2Handler.rotateRoles.selector;
        sel[38] = Reaudit2Handler.raiseFees.selector;
        sel[39] = Reaudit2Handler.checkPayouts.selector;
        sel[40] = Reaudit2Handler.forceEmergency.selector;
        sel[41] = Reaudit2Handler.miniEpoch.selector;
        sel[42] = Reaudit2Handler.steerEpoch.selector;
        sel[43] = Reaudit2Handler.steerEpoch.selector;
        sel[44] = Reaudit2Handler.guardianExits.selector;
        sel[45] = Reaudit2Handler.syncAgentAction.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }

    /// forge-config: default.invariant.runs = 512
    /// forge-config: default.invariant.depth = 200
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_reaudit2() public view {
        // Original accounting properties.
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
        assertGe(fv.claimableRedeemAssets() + 3, owedAssets, "claimable USDC < owed USDC");
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
        // Roles follow the factory, whatever the rotation.
        assertEq(fv.guardian(), handler.guardianNow(), "guardian not the factory's");
        assertEq(fv.sentinel(), handler.sentinelNow(), "sentinel not the factory's");
        assertTrue(fv.agent() == address(0) || factory.platformAgentFor(fv.agent()) == address(fv), "agent not bound to this vault");
        // Earlier ghosts.
        assertEq(handler.vEarlyExecute() + handler.vLateExecute() + handler.vBadSelectorQueued(), 0, "timelock");
        assertEq(handler.vInstantOwnerPower(), 0, "instant owner power");
        assertEq(handler.vEmergencyMinted(), 0, "emergency settlement minted shares");
        assertEq(handler.vSettleWhileBreached(), 0, "settled while breached");
        assertEq(handler.vDepositWhileClosed() + handler.vInsiderDeposit(), 0, "deposit gate");
        assertEq(handler.vDustBridge() + handler.vWindowExtended(), 0, "bridge window");
        assertEq(handler.vPrequeuedClear(), 0, "pre-queued clear");
        assertEq(handler.vSentinelPower(), 0, "sentinel power");
        assertEq(handler.vStaleSettle() + handler.vPerfOutsideSettle() + handler.vHwmWithoutFee(), 0, "N-01/05/08");
        // Third pass ghosts.
        assertEq(handler.vDirectLibraryCall(), 0, "direct library call succeeded");
        assertEq(handler.vPayoutOverLiquidity(), 0, "claims promised beyond the reserve");
        assertEq(handler.vClaimOverBudget(), 0, "a claim cost more than 200k gas (N2-01)");
        // Partial fill + return (V-01): for every settled, unclaimed redemption the value received (USDC paid plus
        // the shares returned, at the epoch's settle price paid / burned) is at least the value submitted, within
        // rounding (2 units of USDC and one share unit).
        for (uint256 i; i < 3; ++i) {
            (uint256 ep, uint256 dep, uint256 red) = fv.requests(a[i]);
            // A deposit settled in the same epoch adds minted shares to the claim: skip those mixed cases here
            // (the round 1 handler's _checkClaimable covers the deposit side).
            if (ep >= fv.currentEpoch() || red == 0 || dep > 0) continue;
            (,, uint256 R, uint256 paid, uint256 burned,,,) = fv.epochs(ep);
            if (R == 0) continue;
            (uint256 sh, uint256 as_) = lens.claimable(fv, a[i]);
            if (burned == 0) {
                assertEq(sh, red, "unpaid epoch must return every share");
            } else {
                assertGe(as_ * burned + sh * paid + 2 * burned + paid, red * paid, "redeemer shortchanged (V-01)");
                assertLe(sh, red, "returned more than submitted");
            }
        }
        assertEq(handler.vExitAfterPartialFill(), 0, "emergency exited with an unpaid partial fill (W-01 / W-01b)");
        assertEq(handler.vOwnerExit(), 0, "the owner ended or queued an emergency exit (W-01b)");
        assertEq(handler.vStrangerUnwind(), 0, "a stranger bridged home or settled (round 4: listed roles only)");
        assertEq(handler.vSyncChangedAgent() + handler.vSyncWhileReduceOnly(), 0, "syncAgent misbehaved (A-13 / HL-PROXY: agent changed or not a mode pin)");
        if (fv.emergency()) assertGe(fv.emergencyAt(), 1);
    }

    /// @dev Smoke test: the forced-emergency and mini-epoch paths are reachable from the handler (else the
    ///      invariant would silently never exercise the pro-rata accounting).
    function test_handlerReachesProRataMiniEpochs() public {
        handler.requestDeposit(0, 50_000e6);
        handler.requestDeposit(1, 50_000e6);
        handler.warp(2 hours, 12);
        handler.checkRisk();
        handler.settle();
        emit log_named_uint("settles ok", handler.settlesOk());
        handler.claim(0);
        handler.claim(1);
        handler.requestRedeem(0, 10_000e12);
        handler.forceEmergency(1);
        emit log_named_string("emergency", fv.emergency() ? "yes" : "no");
        emit log_named_uint("spot", handler.spot());
        handler.miniEpoch();
        handler.miniEpoch();
        emit log_named_uint("mini epochs", handler.miniEpochs());
        assertTrue(fv.emergency(), "emergency not reached");
        assertGe(handler.miniEpochs(), 1, "mini epoch not reached");
        assertEq(handler.vStrangerUnwind(), 0, "the stranger could not unwind");
        // Depositors still get paid in emergency: the settle reserved USDC for the redeemer, and the claim pays it.
        uint256 reserved = fv.claimableRedeemAssets();
        assertGt(reserved, 0, "nothing reserved for the redeemer");
        handler.claimMeasured(0);
        assertLt(fv.claimableRedeemAssets(), reserved, "the redeemer was paid");
        emit log_named_uint("claim gas", handler.maxClaimGas());
    }

    function afterInvariant() external {
        emit log_named_uint("settles ok", handler.settlesOk());
        emit log_named_uint("emergency mini epochs", handler.miniEpochs());
        emit log_named_uint("steered (near-full) epochs", handler.steeredEpochs());
        emit log_named_uint("guardian emergency exits", handler.exitsOk());
        emit log_named_uint("role rotations", handler.rotations());
        emit log_named_uint("fee raises", handler.feeRaises());
        emit log_named_uint("max claim gas", handler.maxClaimGas());
        emit log_named_uint("claims over 200k gas (N2-01)", handler.vClaimOverBudget());
    }

    function _lib(string memory name) internal view returns (address) {
        bytes memory runtime = vm.getDeployedCode(string.concat(name, ".sol:", name));
        address found = _scanFor(address(vaultImpl).code, runtime);
        if (found != address(0)) return found;
        address gov = _scanFor(address(vaultImpl).code, vm.getDeployedCode("VaultGovernance.sol:VaultGovernance"));
        require(gov != address(0), "VaultGovernance not found");
        found = _scanFor(gov.code, runtime);
        require(found != address(0), "library not found");
        return found;
    }

    function _scanFor(bytes memory code, bytes memory runtime) internal view returns (address) {
        bytes32 h = _tailHash(runtime);
        for (uint256 i; i + 20 <= code.length; ++i) {
            address a;
            assembly {
                a := shr(96, mload(add(add(code, 0x20), i)))
            }
            if (a.code.length == runtime.length && _tailHash(a.code) == h) return a;
        }
        return address(0);
    }

    function _tailHash(bytes memory b) internal pure returns (bytes32 h) {
        if (b.length <= 39) return keccak256(b);
        assembly {
            h := keccak256(add(add(b, 0x20), 39), sub(mload(b), 39))
        }
    }
}

/// @notice Same actions and invariant, but every run starts inside an emergency with 150k on Core and two
///         redeemers queued, so the pro-rata mini epochs, claims and cancels are exercised in every run.
contract Reaudit2EmergencyInvariants is Reaudit2Invariants {
    function setUp() public override {
        super.setUp();
        handler.requestDeposit(0, 100_000e6);
        handler.requestDeposit(1, 100_000e6);
        handler.warp(2 hours, 12);
        handler.checkRisk();
        handler.settle();
        handler.claim(0);
        handler.claim(1);
        handler.bridgeToCore(150_000e6, false);
        handler.warp(1 hours, 12);
        handler.requestRedeem(0, 60_000e12);
        handler.requestRedeem(1, 20_000e12);
        handler.forceEmergency(1);
        require(fv.emergency(), "seed: emergency");
    }
}
