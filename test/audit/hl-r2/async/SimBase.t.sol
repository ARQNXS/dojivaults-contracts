// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HyperVault} from "../../../../src/HyperVault.sol";
import {HyperVaultFactory} from "../../../../src/HyperVaultFactory.sol";
import {VaultPolicy} from "../../../../src/VaultPolicy.sol";
import {HyperCore, ICoreDepositWallet} from "../../../../src/hypercore/HyperCore.sol";
import {MockUSDC} from "../../../mocks/Mocks.sol";
import {CoreSim, PrecompileForwarder, CoreWriterForwarder, SimDepositWallet, SimHypeSink} from "./CoreSim.sol";

/// @notice Etches the CoreSim forwarders at every precompile address, at the CoreWriter and at the HYPE system address.
function etchCoreSim(CoreSim sim) {
    VmLike vm_ = VmLike(address(uint160(uint256(keccak256("hevm cheat code")))));
    PrecompileForwarder pf = new PrecompileForwarder(sim);
    address[9] memory pcs = [
        HyperCore.PRECOMPILE_SPOT_BALANCE,
        HyperCore.PRECOMPILE_WITHDRAWABLE,
        HyperCore.PRECOMPILE_MARK_PX,
        HyperCore.PRECOMPILE_ORACLE_PX,
        HyperCore.PRECOMPILE_L1_BLOCK,
        HyperCore.PRECOMPILE_PERP_ASSET_INFO,
        HyperCore.PRECOMPILE_ACCOUNT_MARGIN_SUMMARY,
        HyperCore.PRECOMPILE_CORE_USER_EXISTS,
        HyperCore.PRECOMPILE_POSITION
    ];
    for (uint256 i; i < pcs.length; ++i) {
        vm_.etch(pcs[i], address(pf).code);
    }
    CoreWriterForwarder cw = new CoreWriterForwarder(sim);
    vm_.etch(HyperCore.CORE_WRITER, address(cw).code);
    SimHypeSink hs = new SimHypeSink();
    vm_.etch(HyperCore.HYPE_SYSTEM_ADDRESS, address(hs).code);
}

interface VmLike {
    function etch(address, bytes calldata) external;
}

/// @notice Deploys a factory vault exactly as the platform launches one (hosted, platform agent, treasury operator),
///         on top of CoreSim instead of the hash-keyed mocks of test/Base.t.sol.
abstract contract SimBase is Test {
    MockUSDC internal usdc;
    CoreSim internal sim;
    SimDepositWallet internal wallet;
    HyperVaultFactory internal factory;
    HyperVault internal vault;
    VaultPolicy internal vpolicy;

    address internal fOwner = makeAddr("factoryOwner"); // = platform guardian on the live factories
    address internal guardian = makeAddr("guardian");
    address internal sentinel = makeAddr("sentinel");
    address internal treasury = makeAddr("protocolTreasury");
    address internal owner = makeAddr("vaultOwner");
    address internal manager; // = owner on the platform vault
    address internal operator = makeAddr("keeper");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal agent = makeAddr("platformAgent");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint32 internal constant BTC = 0;
    uint32 internal constant ETH = 1;

    /// @dev The platform vault's risk config (live, 2026-10-19).
    function _platformVaultRisk() internal pure returns (VaultPolicy.RiskConfig memory) {
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

    function _risk() internal view virtual returns (VaultPolicy.RiskConfig memory) {
        return _platformVaultRisk();
    }

    function _managerAddr() internal virtual returns (address) {
        return owner;
    }

    function _mgmtBps() internal view virtual returns (uint16) {
        return 200;
    }

    function _perfBps() internal view virtual returns (uint16) {
        return 2_000;
    }

    function setUp() public virtual {
        manager = _managerAddr(); // the platform vault: owner = manager
        vm.warp(1_790_000_000);
        vm.roll(1_000_000);
        usdc = new MockUSDC();
        wallet = new SimDepositWallet(IERC20(address(usdc)));
        sim = new CoreSim(address(usdc), address(wallet));
        wallet.setSim(sim);
        etchCoreSim(sim);
        sim.listAsset(BTC, 5, 100_000e1); // 100,000.0
        sim.listAsset(ETH, 4, 3_000e2); // 3,000.00

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

        // The seed lands (minus the 1 USDC activation fee), then the agent's HyperCore approval lands (A-13).
        _tick(2);
        if (vault.agentActiveAt() > vm.getBlockTimestamp()) _tick(vault.agentActiveAt() - vm.getBlockTimestamp()); // HLO-07: AGENT_WARMUP
        // HL-PROXY: a vault from the fixed code never approves its agent on HyperCore. The simulator keeps the API
        // wallet agent of the older vaults (the A-series' worst case: an agent with HyperCore powers) by sending the
        // approval the older syncAgent sent, from the vault's address.
        vm.prank(va);
        CoreWriterForwarder(HyperCore.CORE_WRITER).sendRawAction(
            abi.encodePacked(uint8(1), uint24(HyperCore.ACTION_ADD_API_WALLET), abi.encode(agent, "dojipad"))
        );
        _tick(1);
        assertEq(sim.agentOf(va), agent, "agent approved on Core (legacy API wallet, simulated)");

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
    }

    function MAX_UNLANDED() internal pure returns (uint256) {
        return 300;
    }

    // ------------------------------------------------------------------
    // Time: one HyperEVM small block per second. Every helper processes the Core queue for the new block.
    // ------------------------------------------------------------------
    function _tick(uint256 blocks) internal {
        vm.roll(vm.getBlockNumber() + blocks);
        vm.warp(vm.getBlockTimestamp() + blocks);
        sim.process();
    }

    function _warp(uint256 secs) internal {
        uint256 blocks = secs; // 1 s blocks
        vm.roll(vm.getBlockNumber() + blocks);
        vm.warp(vm.getBlockTimestamp() + secs);
        sim.process();
    }

    function _deposit(address who, uint256 amount) internal {
        vm.prank(who);
        vault.requestDeposit(amount, who);
    }

    function _redeem(address who, uint256 shares) internal {
        vm.prank(who);
        vault.requestRedeem(shares, who, who);
    }

    function _settleBy(address who) internal {
        vm.prank(who);
        vault.settle();
    }

    /// @dev Keeper flow: checkRisk, then the operator settles.
    function _keeperSettle() internal {
        vault.checkRisk();
        _settleBy(operator);
    }

    /// @dev Bridge idle USDC to Core, land it on spot, move it to perp (the keeper's routine), everything landed.
    function _fundCore(uint256 amount) internal {
        vm.prank(operator);
        vault.bridgeToCore(amount);
        _tick(2);
        vault.syncBridge();
        _tick(11);
        vm.prank(operator);
        vault.moveUsd(amount, true);
        _tick(1);
    }

    /// @dev Vault value as the simulator knows it: idle EVM USDC (balance minus reserves) + everything on Core
    ///      and in flight.
    function _trueNav() internal view returns (uint256) {
        uint256 bal = usdc.balanceOf(address(vault));
        uint256 reserved = vault.pendingDepositAssets() + vault.deferredDepositAssets() + vault.claimableRedeemAssets();
        int256 v = int256(bal) - int256(reserved) + sim.trueCoreValue(address(vault));
        return v > 0 ? uint256(v) : 0;
    }

    function _valueOf(address who) internal view returns (uint256) {
        uint256 s = vault.totalSupply();
        if (s == 0) return 0;
        return (vault.balanceOf(who) * (_trueNav() + 1)) / (s + 1e6);
    }

    /// @dev Bootstraps a vault with `aliceAmt` from alice settled and on Core perp.
    function _bootstrap(uint256 aliceAmt) internal {
        _deposit(alice, aliceAmt);
        _keeperSettle();
        vault.claim(alice);
        _fundCore(aliceAmt);
    }
}
