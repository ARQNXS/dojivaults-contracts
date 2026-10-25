// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Base} from "../Base.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HyperVault} from "../../src/HyperVault.sol";
import {IHyperVaultErrors, IHyperVaultEvents} from "../../src/VaultTypes.sol";
import {VaultPolicy} from "../../src/VaultPolicy.sol";
import {HyperVaultFactory} from "../../src/HyperVaultFactory.sol";
import {HyperCore, ICoreDepositWallet} from "../../src/hypercore/HyperCore.sol";

/// @dev Audit harness. Adds a factory and a "Mallory" vault: a factory vault whose creator controls every role
///      the platform lets a manager hold (owner, manager, fee recipient). After the audit fixes the guardian is
///      always the platform guardian and the agent is always a platform agent registered by the factory, so
///      Mallory's own key (`malloryAgent`) is never approved on HyperCore. `mallory2` is her sybil depositor.
///
///      HyperCore is simulated with the repo's input-keyed precompile mocks. Bridges are modelled as credited
///      immediately on the destination side (EVM->Core deposits land at the next L1 block in practice, well inside
///      BRIDGE_SETTLE_BLOCKS), which is the assumption every bridge-window test states explicitly.
abstract contract AuditBase is Base {
    HyperVaultFactory internal factory;
    address internal treasury = makeAddr("treasury");
    address internal mallory = makeAddr("mallory");
    address internal mallory2 = makeAddr("mallory2");
    address internal malloryAgent = makeAddr("malloryAgent");
    address internal platformAgent = makeAddr("platformAgent");

    uint256 internal constant ONE_SHARE = 1e12;
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
        factory.registerPlatformAgent(platformAgent, factory.predictVaultAddress(mallory, bytes32(0)));
        factory.setMaxDepositCap(CAP);
        vm.stopPrank();
        usdc.mint(mallory, 10_000_000e6);
        usdc.mint(mallory2, 10_000_000e6);
        vm.deal(mallory, 10 ether);
    }

    function _malloryParams(address agent_) internal view returns (HyperVaultFactory.CreateParams memory cp) {
        uint32[] memory assets = new uint32[](2);
        assets[0] = BTC;
        assets[1] = ETH;
        cp = HyperVaultFactory.CreateParams({
            name: "Mallory Alpha",
            symbol: "mALPHA",
            owner: mallory,
            manager: mallory,
            feeRecipient: mallory,
            managementFeeBps: 200,
            performanceFeeBps: 2_000,
            timelockDelay: 2 days,
            depositCap: CAP,
            risk: _defaultRisk(),
            assets: assets,
            agent: agent_,
            agentSig: "",
            agentDeadline: 0,
            operator: address(0),
            hosted: false,
            seedUsdc: 2e6,
            salt: bytes32(0)
        });
    }

    function _noPermit() internal pure returns (HyperVaultFactory.PermitData memory) {
        return HyperVaultFactory.PermitData(0, 0, 0, bytes32(0), bytes32(0));
    }

    function _malloryVault() internal returns (HyperVault v, VaultPolicy p) {
        vm.startPrank(mallory);
        usdc.approve(address(factory), 2e6);
        (address va, address pa) = factory.create{value: 0.01 ether}(_malloryParams(platformAgent), _noPermit());
        vm.stopPrank();
        v = HyperVault(va);
        p = VaultPolicy(pa);
        // Verified on mainnet: a 2 USDC seed leaves 1 USDC on Core spot after the activation fee.
        _setCoreUser(va, true);
        _setCore(va, 0, 0, 1e6);
        _setWithdrawable(va, 0);
        _setPosition(va, BTC, 0);
        _setPosition(va, ETH, 0);
        vm.prank(alice);
        usdc.approve(va, type(uint256).max);
        vm.prank(bob);
        usdc.approve(va, type(uint256).max);
        vm.prank(mallory);
        usdc.approve(va, type(uint256).max);
        vm.prank(mallory2);
        usdc.approve(va, type(uint256).max);
        vm.roll(vm.getBlockNumber() + 11); // past the seed bridge window
        if (v.agentActiveAt() > vm.getBlockTimestamp()) vm.warp(v.agentActiveAt()); // HLO-07: AGENT_WARMUP
    }

    /// @dev alice deposits `amount`, it settles, and the manager moves it all to the Core perp account.
    function _fundAndDeploy(HyperVault v, address mgr, uint256 amount, uint64 coreSpotDust) internal {
        vm.prank(alice);
        v.requestDeposit(amount, alice);
        v.checkRisk();
        vm.prank(mgr);
        v.settle();
        v.claim(alice);
        vm.prank(mgr);
        v.bridgeToCore(amount);
        _setCore(address(v), int64(uint64(amount)), 0, coreSpotDust);
        _setWithdrawable(address(v), uint64(amount));
        v.syncBridge(); // HLR2-A02 / A08 (a-series patch): the keeper's next transaction sees the credit on Core
        // Round 4 (R-02 / R3-01): the mock puts the funds straight into perp, which is not a landing signal (only
        // Core spot is), so the setup waits out the window's cap instead of 11 blocks.
        vm.roll(vm.getBlockNumber() + 301);
    }

    /// @dev What the keeper does over time: hourly checkRisk() calls that ratchet the NAV checkpoint.
    function _keeperHours(HyperVault v, uint256 hours_) internal {
        for (uint256 i; i < hours_; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            v.checkRisk();
        }
    }

    function _value(HyperVault v, address who) internal view returns (uint256) {
        return v.convertToAssets(v.balanceOf(who));
    }

    function _callFailed(bytes4 inner) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IHyperVaultErrors.CallFailed.selector, abi.encodeWithSelector(inner));
    }
}
