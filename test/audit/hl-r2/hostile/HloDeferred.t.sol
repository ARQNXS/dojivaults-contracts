// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {HostileBase} from "./HostileBase.t.sol";
import {HyperVault} from "../../../../src/HyperVault.sol";
import {HyperVaultFactory} from "../../../../src/HyperVaultFactory.sol";
import {VaultPolicy} from "../../../../src/VaultPolicy.sol";
import {IHyperVaultErrors as E} from "../../../../src/VaultTypes.sol";

/// @notice hl-r2: the hl-open contract findings deferred to round 2 (HLO-02, 03, 06, 07), re-tested on the current
///         source. HLO-08 is a live-state item (cast reads in HLO-DEFERRED.md).
///         Run: forge test --match-path "test/audit/hl-r2/hostile/*" -vv
contract HloDeferredTest is HostileBase {
    address internal mallory = makeAddr("mallory");
    address internal famous = makeAddr("famous");

    // ------------------------------------------------------------------ HLO-02 (confirmed, unchanged on chain)
    function test_HLO02_r2_ownerManagerNameAndHostedAreStillFree() public {
        _fundLauncher(mallory, 1);
        HyperVaultFactory.CreateParams memory p = _params(mallory, bytes32(0));
        p.name = "Platform";
        p.symbol = "POL";
        p.owner = famous; // never signed anything
        p.manager = famous;
        p.feeRecipient = mallory;
        p.hosted = true;
        HyperVault v = _launch(mallory, p);
        assertEq(v.owner(), famous);
        assertEq(v.manager(), famous);
        assertTrue(v.hosted());
        assertEq(v.protocolShareBps(), factory.hostedShareBps(), "the treasury share is the hosted one (33%)");
        // the named owner never accepted: but holds every owner power and is an insider (deferred deposits)
        usdc.mint(famous, 10e6);
        vm.startPrank(famous);
        usdc.approve(address(v), 10e6);
        uint256 ep = v.requestDeposit(10e6, famous);
        vm.stopPrank();
        assertEq(ep, v.currentEpoch() + 1, "the impersonated wallet is treated as an insider of a vault it never made");
    }

    // ------------------------------------------------------------------ HLO-03 (confirmed; worse with H01)
    /// @dev The default-policy vault's owner turns the C-01 bound off INSTANTLY: raising maxNavMoveBps counts as a
    ///      tightening (N-03). No envelope, no timelock.
    function test_HLO03_r2_ownerTurnsTheNavMoveBoundOffInstantly() public {
        HyperVault v = _platformVaultLike(address(0));
        VaultPolicy pol = v.policy();
        VaultPolicy.RiskConfig memory c = _platformVaultRisk();
        c.maxNavMoveBps = 10_000;
        c.maxEpochDuration = 1 hours; // shorter epochs also count as tighter
        vm.prank(platformVaultOwner);
        pol.proposeConfig(c);
        assertEq(pol.maxNavMoveBps(), 10_000, "applied in the same transaction");
        assertFalse(pol.pendingConfig().exists);
        // the hostile envelope itself is also accepted at create
        _fundLauncher(mallory, 1);
        HyperVaultFactory.CreateParams memory p = _params(mallory, bytes32(0));
        p.risk = _loose();
        HyperVault h = _launch(mallory, p);
        assertEq(h.policy().maxLeverageBps(), 500_000);
    }

    // ------------------------------------------------------------------ HLO-06 (confirmed)
    function test_HLO06_r2_oneLargeRedemptionBlocksEveryRequestOfTheEpoch() public {
        HyperVault v = _platformVaultLike(address(0));
        // a 10M whale joins; 95% of NAV is deployed
        address whale = makeAddr("whale");
        vm.prank(platformVaultOwner);
        v.setDepositCap(type(uint256).max);
        usdc.mint(whale, 10_000_000e6);
        vm.startPrank(whale);
        usdc.approve(address(v), type(uint256).max);
        v.requestDeposit(10_000_000e6, whale);
        vm.stopPrank();
        vm.prank(keeper);
        v.settle();
        v.claim(whale);
        uint256 nav = v.totalAssets();
        usdc.burnFrom(address(v), 9_500_000e6);
        _setCore(address(v), int64(uint64(100_002e6 + 9_500_000e6)), 25_000_000e6, 0);
        _setWithdrawable(address(v), 0);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        v.checkRisk();
        uint256 w = v.balanceOf(whale);
        vm.prank(whale);
        v.requestRedeem(w, whale, whale);
        // bob's 1,000 USDC exit-free deposit and alice's small redemption are held hostage by the whale's
        usdc.mint(bob, 1_000e6);
        vm.startPrank(bob);
        usdc.approve(address(v), type(uint256).max);
        v.requestDeposit(1_000e6, bob);
        vm.stopPrank();
        vm.prank(alice);
        v.requestRedeem(1e12, alice, alice);
        vm.prank(keeper);
        vm.expectRevert(); // InsufficientLiquidity: all or nothing
        v.settle();
        console2.log("HLO-06 NAV (6 dp)", nav);
        console2.log("HLO-06 idle (6 dp)", v.idleAssets());
    }

    // ------------------------------------------------------------------ HLO-07 (confirmed; co-signature evaluated)
    /// @dev The factory OWNER key (an EOA on chain, HLO-08) also signs agent bindings, not only the registrar.
    function test_HLO07_r2_factoryOwnerKeyAlsoBindsASelfHeldAgent() public {
        (address ownerK, uint256 ownerKey) = makeAddrAndKey("factory.owner.eoa");
        vm.prank(owner);
        factory.transferOwnership(ownerK);
        vm.prank(ownerK);
        factory.acceptOwnership();

        (address heldAgent,) = makeAddrAndKey("attacker.agent");
        address predicted = factory.predictVaultAddress(mallory, bytes32(0));
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(factory.agentDigest(heldAgent, predicted, deadline));
        (uint8 v8, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
        _fundLauncher(mallory, 1);
        HyperVaultFactory.CreateParams memory p = _params(mallory, bytes32(0));
        (p.agent, p.agentSig, p.agentDeadline) = (heldAgent, abi.encodePacked(r, s, v8), deadline);
        HyperVault v = _launch(mallory, p);
        assertEq(v.agent(), heldAgent);
        assertTrue(factory.isPlatformAgent(heldAgent));
    }

    /// @dev Why a creator co-signature does not close HLO-07: the attacker IS the creator. The digest already binds
    ///      the creator (predictVaultAddress scopes the salt by msg.sender), and msg.sender already authenticates
    ///      the creator; an extra creator signature over (agent, vault, deadline, creator) is one the attacker makes
    ///      with his own key. Modelled here: both signatures of the "fixed" check come from attacker-held keys.
    function test_HLO07_r2_creatorCoSignatureIsProducedByTheAttacker() public {
        (address creator, uint256 creatorKey) = makeAddrAndKey("attacker.creator");
        (address heldAgent,) = makeAddrAndKey("attacker.agent");
        address predicted = factory.predictVaultAddress(creator, bytes32(0));
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        // the proposed co-signed digest
        bytes32 co = keccak256(abi.encode("DojiPad agent co-sign", block.chainid, address(factory), heldAgent, predicted, deadline, creator));
        (uint8 v8, bytes32 r, bytes32 s) = vm.sign(creatorKey, MessageHashUtils.toEthSignedMessageHash(co));
        assertEq(ecrecover(MessageHashUtils.toEthSignedMessageHash(co), v8, r, s), creator, "co-signature valid");
        // and the registrar half with the leaked key: the launch goes through exactly as in HLO-07
        _fundLauncher(creator, 1);
        HyperVaultFactory.CreateParams memory p = _params(creator, bytes32(0));
        (p.agent, p.agentSig, p.agentDeadline) = (heldAgent, _agentSig(heldAgent, predicted, deadline), deadline);
        HyperVault v = _launch(creator, p);
        assertEq(v.agent(), heldAgent);
    }

    /// @dev The fix that does bound it, with today's functions: bind by commitment (owner pre-binds the predicted
    ///      address on chain) and let a second, independent platform key veto during a delay. Today the sentinel can
    ///      already unregister a pre-bound agent before the launch, after which the launch reverts.
    function test_HLO07_r2_commitThenVetoWorksWithTodaysFunctions() public {
        address agentX = makeAddr("committed.agent");
        address predicted = factory.predictVaultAddress(mallory, bytes32(0));
        vm.prank(owner);
        factory.registerPlatformAgent(agentX, predicted); // commitment, visible on chain (PlatformAgentRegistered)
        vm.prank(sentinel);
        factory.unregisterPlatformAgent(agentX); // veto inside the delay
        _fundLauncher(mallory, 1);
        HyperVaultFactory.CreateParams memory p = _params(mallory, bytes32(0));
        p.agent = agentX;
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(HyperVaultFactory.NotPlatformAgent.selector, agentX));
        factory.create{value: 0.01 ether}(p, _noPermit());
    }
}
