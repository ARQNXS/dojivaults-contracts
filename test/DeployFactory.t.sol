// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Addresses, DeployFactory, LinkedLibraries} from "../script/Deploy.s.sol";
import {HyperVault} from "../src/HyperVault.sol";
import {HyperVaultFactory} from "../src/HyperVaultFactory.sol";
import {HyperVaultLens} from "../src/HyperVaultLens.sol";
import {VaultPolicy} from "../src/VaultPolicy.sol";
import {MockCoreDepositWallet, MockUSDC} from "./mocks/Mocks.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @notice Runs the real DeployFactory script in the test EVM (mainnet chain id, USDC and CoreDepositWallet mocks
///         etched at the mainnet addresses) and checks what the deploy must guarantee: every link reference in the
///         implementation and in VaultGovernance points at the deployed libraries, every contract has code, and a
///         vault created through the factory settles a deposit (the library delegatecalls work end to end).
///         The same script against a local anvil: script/anvil-deploy-check.sh.
contract DeployFactoryTest is Base {
    /// @dev vm.startBroadcast() in a test runs as forge's default sender: the script's setters need it as OWNER.
    address internal deployer = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;
    address internal platformGuardian = makeAddr("platformGuardian");
    address internal platformSentinel = makeAddr("platformSentinel");
    address internal registrar = makeAddr("registrar");
    address internal treasury = makeAddr("treasury");
    address internal launcher = makeAddr("launcher");
    address internal agentAddr = makeAddr("agent");

    DeployFactory internal script;
    HyperVault internal vaultImpl_;
    VaultPolicy internal policyImpl_;
    HyperVaultLens internal lens_;
    HyperVaultFactory internal factory;

    function setUp() public override {
        super.setUp();
        // Mainnet chain id and the real USDC / CoreDepositWallet addresses, with mock code behind them.
        vm.chainId(999);
        vm.etch(Addresses.USDC_MAINNET, address(usdc).code);
        MockCoreDepositWallet cdw = new MockCoreDepositWallet(IERC20(Addresses.USDC_MAINNET));
        vm.etch(Addresses.CDW_MAINNET, address(cdw).code); // the usdc address is an immutable, so it travels with the code

        vm.setEnv("OWNER", vm.toString(deployer));
        vm.setEnv("PROTOCOL_FEE_RECIPIENT", vm.toString(treasury));
        vm.setEnv("PLATFORM_GUARDIAN", vm.toString(platformGuardian));
        vm.setEnv("PLATFORM_SENTINEL", vm.toString(platformSentinel));
        vm.setEnv("AGENT_REGISTRAR", vm.toString(registrar));
        vm.setEnv("CURATED_ASSETS", "0,1");
        vm.setEnv("ALLOW_LAUNCHER", vm.toString(launcher));
        vm.setEnv("DEPLOY_SKIP_RECORD", "true"); // never write deployments/mainnet.json from a test

        script = new DeployFactory();
        (vaultImpl_, policyImpl_, lens_, factory) = script.run();
    }

    function test_DeployScript_EveryContractHasCode() public view {
        assertGt(address(vaultImpl_).code.length, 0, "implementation");
        assertGt(address(policyImpl_).code.length, 0, "policy implementation");
        assertGt(address(lens_).code.length, 0, "lens");
        assertGt(address(factory).code.length, 0, "factory");
        (address logic, address governance,,,,,,,,,) = script.last();
        assertGt(logic.code.length, 0, "VaultLogic");
        assertGt(governance.code.length, 0, "VaultGovernance");
        assertTrue(logic != governance && logic != address(vaultImpl_) && governance != address(vaultImpl_));
    }

    /// @dev Every link reference in the artifacts points at the deployed library, and the deployed libraries' code
    ///      is the compiled library code (after the 39 byte call-protection prefix that embeds its own address).
    function test_DeployScript_LinkedLibrariesMatchDeployedLibraries() public view {
        (address logic, address governance,,,,,,,,,) = script.last();
        bytes memory impl = address(vaultImpl_).code;
        assertEq(LinkedLibraries.linked(vm, "out/HyperVault.sol/HyperVault.json", "src/VaultGovernance.sol", "VaultGovernance", impl), governance);
        assertEq(LinkedLibraries.linked(vm, "out/HyperVault.sol/HyperVault.json", "src/VaultLogic.sol", "VaultLogic", impl), logic);
        assertEq(LinkedLibraries.linked(vm, "out/VaultGovernance.sol/VaultGovernance.json", "src/VaultLogic.sol", "VaultLogic", governance.code), logic);
        assertEq(_tailHash(logic.code), _tailHash(vm.getDeployedCode("VaultLogic.sol:VaultLogic")), "VaultLogic code");
        assertEq(_tailHash(governance.code), _tailHash(vm.getDeployedCode("VaultGovernance.sol:VaultGovernance")), "VaultGovernance code");
        // No window of the implementation's code other than the link sites is consulted: the resolver is pure.
        (address l2, address g2) = script.resolveLibraries(address(vaultImpl_));
        assertEq(l2, logic);
        assertEq(g2, governance);
    }

    function test_DeployScript_SetupAndOwnershipHandOff() public view {
        assertEq(factory.owner(), deployer, "deployer stays owner until the guardian accepts");
        assertEq(factory.pendingOwner(), platformGuardian);
        assertEq(factory.guardian(), platformGuardian);
        assertEq(factory.sentinel(), platformSentinel);
        assertEq(factory.agentRegistrar(), registrar);
        assertEq(factory.protocolFeeRecipient(), treasury);
        assertEq(factory.maxDepositCap(), type(uint256).max, "no platform limit by default");
        assertFalse(factory.openLaunch());
        assertTrue(factory.canLaunch(launcher));
        assertTrue(factory.isAssetCurated(0) && factory.isAssetCurated(1));
        assertEq(factory.vaultImplementation(), address(vaultImpl_));
        assertEq(factory.policyImplementation(), address(policyImpl_));
        assertEq(address(factory.usdc()), Addresses.USDC_MAINNET);
        assertEq(address(factory.coreDepositWallet()), Addresses.CDW_MAINNET);
    }

    /// @dev A vault created through the deployed factory accepts a deposit and settles it: initialize, requestDeposit,
    ///      checkRisk and settle all run through the linked libraries by delegatecall.
    function test_DeployScript_FactoryVaultSettlesADeposit() public {
        MockUSDC mainnetUsdc = MockUSDC(Addresses.USDC_MAINNET);
        address predicted = factory.predictVaultAddress(launcher, bytes32(0));
        // Round 4 (V-04): the registrar signs the launch instead of pre-binding the predicted address.
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (uint8 sv, bytes32 sr, bytes32 ss) = vm.sign(
            uint256(keccak256(abi.encodePacked("registrar"))), MessageHashUtils.toEthSignedMessageHash(factory.agentDigest(agentAddr, predicted, deadline))
        );
        bytes memory agentSig = abi.encodePacked(sr, ss, sv);
        mainnetUsdc.mint(launcher, 2e6);
        vm.deal(launcher, 1 ether);
        uint32[] memory assets = new uint32[](2);
        assets[0] = 0;
        assets[1] = 1;
        vm.startPrank(launcher);
        mainnetUsdc.approve(address(factory), 2e6);
        (address va, address pa) = factory.create{value: 0.01 ether}(
            HyperVaultFactory.CreateParams({
                name: "Deploy Test",
                symbol: "dpDT",
                owner: launcher,
                manager: launcher,
                feeRecipient: launcher,
                managementFeeBps: 200,
                performanceFeeBps: 2_000,
                timelockDelay: 2 days,
                depositCap: 50_000e6,
                risk: _defaultRisk(),
                assets: assets,
                agent: agentAddr,
                agentSig: agentSig,
                agentDeadline: deadline,
                operator: address(0),
                hosted: true,
                seedUsdc: 2e6,
                salt: bytes32(0)
            }),
            HyperVaultFactory.PermitData(0, 0, 0, bytes32(0), bytes32(0))
        );
        vm.stopPrank();
        HyperVault v = HyperVault(va);
        assertTrue(factory.isVault(va));
        assertEq(v.agent(), agentAddr);
        assertEq(v.guardian(), platformGuardian);
        assertEq(v.sentinel(), platformSentinel);
        assertEq(VaultPolicy(pa).maxFlattenSlippageBps(), 300);

        // Core state after the seed: account exists, 1 USDC left on spot after the activation fee.
        _setCoreUser(va, true);
        _setCore(va, 0, 0, 1e6);
        _setWithdrawable(va, 0);
        _setPosition(va, 0, 0);
        _setPosition(va, 1, 0);
        vm.roll(vm.getBlockNumber() + 11);
        if (v.agentActiveAt() > vm.getBlockTimestamp()) vm.warp(v.agentActiveAt()); // HLO-07: AGENT_WARMUP

        mainnetUsdc.mint(alice, 10_000e6);
        vm.startPrank(alice);
        mainnetUsdc.approve(va, type(uint256).max);
        v.requestDeposit(10_000e6, alice);
        vm.stopPrank();
        vm.prank(launcher);
        v.settle(); // first settle checkpoints itself
        v.claim(alice);
        assertEq(v.currentEpoch(), 1);
        assertGt(v.balanceOf(alice), 0, "shares minted through the linked libraries");
        assertApproxEqRel(v.convertToAssets(v.balanceOf(alice)), 10_000e6, 1e15, "worth the deposit (seed donation aside)");
        (uint256 sh, uint256 as_) = lens_.claimable(v, alice);
        assertEq(sh + as_, 0, "claimed");
        assertEq(lens_.status(v).guardian, platformGuardian);
    }

    function _tailHash(bytes memory b) internal pure returns (bytes32 h) {
        if (b.length <= 39) return keccak256(b);
        assembly {
            h := keccak256(add(add(b, 0x20), 39), sub(mload(b), 39))
        }
    }

    /// @dev MAX_DEPOSIT_CAP of 0 would block every launch: refused.
    function test_DeployScript_RefusesAZeroPlatformLimit() public {
        vm.setEnv("MAX_DEPOSIT_CAP", "0");
        DeployFactory d = new DeployFactory();
        vm.expectRevert(bytes("MAX_DEPOSIT_CAP must be > 0"));
        d.run();
        vm.setEnv("MAX_DEPOSIT_CAP", vm.toString(type(uint256).max)); // back to the default for the other tests
    }

}
