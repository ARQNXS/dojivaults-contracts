// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HyperVault} from "../../../../src/HyperVault.sol";
import {HyperVaultFactory} from "../../../../src/HyperVaultFactory.sol";
import {VaultPolicy} from "../../../../src/VaultPolicy.sol";
import {ICoreDepositWallet} from "../../../../src/hypercore/HyperCore.sol";
import {MockUSDC} from "../../../mocks/Mocks.sol";
import {CoreSim, SimDepositWallet} from "./CoreSim.sol";
import {HyperCore} from "../../../../src/hypercore/HyperCore.sol";
import {ConservationHandler} from "./ConservationHandler.sol";

interface IHevm {
    function prank(address) external;
    function deal(address, uint256) external;
    function roll(uint256) external;
    function warp(uint256) external;
    function etch(address, bytes calldata) external;
    function store(address, bytes32, bytes32) external;
}

/// @notice Medusa harness for the hl-r2 conservation properties: same CoreSim, same handler (medusaMode), the
///         the platform vault policy with a separate manager. Medusa advances blocks and time between calls by itself.
/// Run: see contracts/audit/hl-r2/INVARIANTS.md (medusa.json in the scratch tools dir, not in the repo).
contract MedusaConservation {
    IHevm internal constant HEVM = IHevm(address(uint160(uint256(keccak256("hevm cheat code")))));

    MockUSDC public usdc;
    CoreSim public sim;
    HyperVault public vault;
    ConservationHandler public handler;

    address internal constant FOWNER = address(0xF0);
    address internal constant GUARDIAN = address(0xF1);
    address internal constant SENTINEL = address(0xF2);
    address internal constant TREASURY = address(0xF3);
    address internal constant OWNER = address(0xF4);
    address internal constant MANAGER = address(0xF5);
    address internal constant OPERATOR = address(0xF6);
    address internal constant FEE = address(0xF7);
    address internal constant AGENT = address(0xF8);
    address internal constant STRANGER = address(0xF9);
    address internal constant ALICE = address(0xA1);
    address internal constant BOB = address(0xA2);
    address internal constant CAROL = address(0xA3);

    uint256 internal _b;
    uint256 internal _t;

    constructor() payable {
        _b = 1_000_000;
        _t = 1_790_000_000;
        HEVM.roll(_b);
        HEVM.warp(_t);
        HEVM.deal(address(this), 1 ether); // the factory's HYPE value is paid by this contract (prank keeps msg.value)
        usdc = new MockUSDC();
        SimDepositWallet wallet = new SimDepositWallet(IERC20(address(usdc)));
        sim = new CoreSim(address(usdc), address(wallet));
        wallet.setSim(sim);
        _etch();
        sim.listAsset(0, 5, 100_000e1);
        sim.listAsset(1, 4, 3_000e2);

        HyperVaultFactory factory = new HyperVaultFactory(
            FOWNER,
            address(new HyperVault()),
            address(new VaultPolicy()),
            IERC20(address(usdc)),
            ICoreDepositWallet(address(wallet)),
            TREASURY,
            GUARDIAN,
            SENTINEL
        );
        HEVM.prank(FOWNER);
        factory.setOpenLaunch(true);
        HEVM.prank(FOWNER);
        factory.setAssetCurated(0, true);
        HEVM.prank(FOWNER);
        factory.setAssetCurated(1, true);
        HEVM.prank(FOWNER);
        factory.setMaxDepositCap(type(uint256).max);
        address predicted = factory.predictVaultAddress(OWNER, bytes32(0)); // outside the prank
        HEVM.prank(FOWNER);
        factory.registerPlatformAgent(AGENT, predicted);

        usdc.mint(OWNER, 2e6);
        HEVM.deal(OWNER, 1 ether);
        HEVM.prank(OWNER);
        usdc.approve(address(factory), 2e6);
        uint32[] memory assets = new uint32[](2);
        assets[1] = 1;
        HEVM.prank(OWNER);
        (address va,) = factory.create{value: 0.01 ether}(
            HyperVaultFactory.CreateParams({
                name: "Sim",
                symbol: "SIM",
                owner: OWNER,
                manager: MANAGER,
                feeRecipient: FEE,
                managementFeeBps: 200,
                performanceFeeBps: 2_000,
                timelockDelay: 2 days,
                depositCap: type(uint256).max,
                risk: VaultPolicy.RiskConfig({
                    maxLeverageBps: 50_000,
                    maxDailyLossBps: 2_000,
                    maxDrawdownBps: 5_000,
                    maxSlippageBps: 100,
                    maxOrderNotional: 2_500_000e6,
                    maxEpochDuration: 7 days,
                    maxNavMoveBps: 2_000,
                    maxFlattenSlippageBps: 300
                }),
                assets: assets,
                agent: AGENT,
                agentSig: "",
                agentDeadline: 0,
                operator: OPERATOR,
                hosted: true,
                seedUsdc: 2e6,
                salt: bytes32(0)
            }),
            HyperVaultFactory.PermitData(0, 0, 0, bytes32(0), bytes32(0))
        );
        vault = HyperVault(va);
        _tick(2);
        if (vault.agentActiveAt() > _t) _tick(vault.agentActiveAt() - _t); // HLO-07: AGENT_WARMUP (_t, not block.timestamp: via_ir)
        // Fix round WP5 (HL-PROXY): the release code approves no HyperCore API wallet (syncAgent() only pins the account
        // mode). Unlike SimBase, this harness does not simulate the legacy approval: the agent reaches the vault only
        // through placeOrder (agentOrder below); agentAction's direct Core actions are refused by CoreSim.
        HEVM.prank(OPERATOR);
        vault.pinAccountMode();
        _tick(301);

        address[6] memory u = [ALICE, BOB, CAROL, OWNER, MANAGER, FEE];
        for (uint256 i; i < u.length; ++i) {
            usdc.mint(u[i], 10_000_000e6);
        }
        handler = new ConservationHandler(
            vault, sim, usdc, [OWNER, MANAGER, OPERATOR, GUARDIAN, SENTINEL, FEE, TREASURY, AGENT, STRANGER, ALICE, BOB, CAROL, address(0)], true
        );
        // bootstrap: alice 100k settled and on Core perp
        HEVM.prank(ALICE);
        usdc.approve(va, type(uint256).max);
        HEVM.prank(ALICE);
        vault.requestDeposit(100_000e6, ALICE);
        vault.checkRisk();
        HEVM.prank(OPERATOR);
        vault.settle();
        vault.claim(ALICE);
        HEVM.prank(OPERATOR);
        vault.bridgeToCore(100_000e6);
        _tick(2);
        vault.syncBridge();
        _tick(11);
        HEVM.prank(OPERATOR);
        vault.moveUsd(100_000e6, true);
        _tick(2);
        handler.snapshotStart();
    }

    /// @dev Medusa: the forwarders are predeployed at the system addresses (medusa.json predeployedContracts: Fwd801 ..
    ///      Fwd813, FwdCoreWriter, SimHypeSink); etched code at those addresses failed to execute under Medusa 1.5.1
    ///      on Windows. Here only the CoreSim address is written into their slot 0.
    function _etch() internal {
        address[10] memory a = [
            HyperCore.PRECOMPILE_SPOT_BALANCE,
            HyperCore.PRECOMPILE_WITHDRAWABLE,
            HyperCore.PRECOMPILE_MARK_PX,
            HyperCore.PRECOMPILE_ORACLE_PX,
            HyperCore.PRECOMPILE_L1_BLOCK,
            HyperCore.PRECOMPILE_PERP_ASSET_INFO,
            HyperCore.PRECOMPILE_ACCOUNT_MARGIN_SUMMARY,
            HyperCore.PRECOMPILE_CORE_USER_EXISTS,
            HyperCore.PRECOMPILE_POSITION,
            HyperCore.CORE_WRITER
        ];
        bytes32 simWord = bytes32(uint256(uint160(address(sim))));
        for (uint256 i; i < a.length; ++i) {
            require(a[i].code.length > 0, "forwarder not predeployed");
            HEVM.store(a[i], bytes32(0), simWord);
        }
    }

    function _tick(uint256 n) internal {
        _b += n;
        _t += n;
        HEVM.roll(_b);
        HEVM.warp(_t);
        sim.process();
    }

    // ------------------------------------------------------------------
    // Actions (forwarded to the shared handler)
    // ------------------------------------------------------------------
    function roll(uint256 x) external { handler.roll(x); }
    function warp(uint256 x) external { handler.warp(x); }
    function deposit(uint256 s, uint256 a) external { handler.deposit(s, a); }
    function redeem(uint256 s, uint256 f) external { handler.redeem(s, f); }
    function cancelDeposit(uint256 s) external { handler.cancelDeposit(s); }
    function cancelRedeem(uint256 s) external { handler.cancelRedeem(s); }
    function claim(uint256 s) external { handler.claim(s); }
    function transferShares(uint256 a, uint256 b, uint256 f) external { handler.transferShares(a, b, f); }
    function settle(uint256 s) external { handler.settle(s); }
    function accrueFees() external { handler.accrueFees(); }
    function lowerFees(uint256 m, uint256 f) external { handler.lowerFees(m, f); }
    function queueFees(uint256 m, uint256 f) external { handler.queueFees(m, f); }
    function executeQueued(uint256 i) external { handler.executeQueued(i); }
    function bridgeToCore(uint256 s, uint256 a) external { handler.bridgeToCore(s, a); }
    function bridgeToEvm(uint256 s, uint256 a) external { handler.bridgeToEvm(s, a); }
    function moveUsd(uint256 s, uint256 a) external { handler.moveUsd(s, a); }
    function faults(uint256 s) external { handler.faults(s); }
    function syncBridge() external { handler.syncBridge(); }
    function pnlShock(int256 b) external { handler.pnlShock(b); }
    function markMove(uint256 s, int256 b) external { handler.markMove(s, b); }
    function managerOrder(uint256 s, uint256 z) external { handler.managerOrder(s, z); }
    function flatten(uint256 s) external { handler.flatten(s); }
    function agentAction(uint256 s, uint256 a) external { handler.agentAction(s, a); }
    function agentOrder(uint256 s, uint256 z) external { handler.agentOrder(s, z); } // WP5: the proxy path
    function checkRisk() external { handler.checkRisk(); }
    function breachOps(uint256 s) external { handler.breachOps(s); }
    function keeperCycle(uint256 s) external { handler.keeperCycle(s); }
    function keeperCycleProxy() external { handler.keeperCycle(2); }

    // ------------------------------------------------------------------
    // Properties (same as ConservationInvariants)
    // ------------------------------------------------------------------
    function property_C1_conservation() external view returns (bool) {
        (int256 l, int256 r) = handler.conservation();
        return l == r;
    }

    function property_C2_reserveBacked() external view returns (bool) {
        return usdc.balanceOf(address(vault))
            >= vault.pendingDepositAssets() + vault.deferredDepositAssets() + vault.claimableRedeemAssets();
    }

    function property_C3_owedCovered() external view returns (bool) {
        (uint256 s, uint256 a) = handler.owedTotals();
        return vault.claimableRedeemAssets() >= a && vault.balanceOf(address(vault)) >= vault.pendingRedeemShares() + s;
    }

    function property_F_fairness() external view returns (bool) {
        return handler.vOverstatedNav() == 0 && handler.vUnexplainedUnder() == 0 && handler.vDepositorOverpaid() == 0
            && handler.vRedeemerOverpaid() == 0 && handler.vNormalUnfair() == 0 && handler.vRedeemBelowRule() == 0
            && handler.vMintInExit() == 0;
    }

    function property_F_fees() external view returns (bool) {
        return handler.vFeeOverCap() == 0 && handler.vPerfInBreach() == 0 && handler.vProtocolSplit() == 0;
    }

    function property_F_claims() external view returns (bool) {
        return handler.vClaimMismatch() == 0 && handler.vCancelMismatch() == 0;
    }
}
