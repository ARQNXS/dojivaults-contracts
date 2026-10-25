// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GovBase} from "./GovBase.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {GainsVault} from "../../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../../src/gains/GainsVaultPolicy.sol";
import {GainsVaultFactory} from "../../../../src/gains/GainsVaultFactory.sol";
import {GainsVaultGovernance} from "../../../../src/gains/GainsVaultGovernance.sol";
import {GainsVaultLogic} from "../../../../src/gains/GainsVaultLogic.sol";
import {IGainsDiamond} from "../../../../src/gains/IGainsDiamond.sol";
import {IGainsVaultErrors as E, InitParams} from "../../../../src/gains/GainsTypes.sol";

/// @notice ACCESS-MATRIX.md section 4 (GainsVaultFactory, who) cell by cell, plus the factory half of SPEC L1-L5:
///         registrar signature scope (replay across vaults, factories, chains; expiry; malleability), CREATE2 salt
///         scoping, clone initialization, role collisions incl. the pending owner, maxDepositCap.
contract GovFactoryMatrixTest is GovBase {
    address internal outsider = makeAddr("outsider");

    // ==================================================================
    // create
    // ==================================================================
    function _tryCreate(address who, bytes32 salt) internal returns (bool ok, bytes memory ret) {
        GainsVaultFactory.CreateParams memory p = _cparams(who, salt, address(0));
        usdc.mint(who, 1e6);
        vm.prank(who);
        usdc.approve(address(platform), 1e6);
        vm.prank(who);
        (ok, ret) = address(platform).call(abi.encodeCall(GainsVaultFactory.create, (p, _noPermit())));
    }

    function test_GOV_FM_create_launchAllowlist() public {
        address[6] memory who = [platformOwner, registrar, platformGuardian, platformSentinel, outsider, stranger];
        for (uint256 i; i < who.length; ++i) {
            (bool ok, bytes memory ret) = _tryCreate(who[i], bytes32(uint256(100 + i)));
            assertFalse(ok, "not allowlisted");
            assertEq(bytes4(ret), GainsVaultFactory.LaunchClosed.selector);
        }
        // the allowlisted launcher
        (bool ok2,) = _tryCreate(launcher, bytes32(uint256(99)));
        assertTrue(ok2, "launcher");
        // every role "if allowed"
        for (uint256 i; i < who.length; ++i) {
            vm.prank(platformOwner);
            platform.setLauncherAllowed(who[i], true);
            (bool ok3,) = _tryCreate(who[i], bytes32(uint256(200 + i)));
            assertTrue(ok3, "allowed");
            vm.prank(platformOwner);
            platform.setLauncherAllowed(who[i], false);
        }
        // openLaunch: anyone
        vm.prank(platformOwner);
        platform.setOpenLaunch(true);
        (bool ok4,) = _tryCreate(stranger, bytes32(uint256(300)));
        assertTrue(ok4, "open launch");
    }

    function test_GOV_FM_create_curationCapAndNavBound() public {
        GainsVaultFactory.CreateParams memory p = _cparams(launcher, bytes32(uint256(7)), address(0));
        p.assets = new uint32[](1);
        p.assets[0] = DOGE;
        vm.prank(launcher);
        vm.expectRevert(abi.encodeWithSelector(GainsVaultFactory.AssetNotCurated.selector, uint32(DOGE)));
        platform.create(p, _noPermit());

        uint256 maxCap = platform.maxDepositCap();
        p = _cparams(launcher, bytes32(uint256(7)), address(0));
        p.depositCap = 0;
        vm.prank(launcher);
        vm.expectRevert(abi.encodeWithSelector(GainsVaultFactory.CapAboveMax.selector, 0, maxCap));
        platform.create(p, _noPermit());
        p.depositCap = maxCap + 1;
        vm.prank(launcher);
        vm.expectRevert(abi.encodeWithSelector(GainsVaultFactory.CapAboveMax.selector, p.depositCap, maxCap));
        platform.create(p, _noPermit());

        // SOL band 25 bps, maxNavMoveBps 2000 => vault leverage <= 10x
        p = _cparams(launcher, bytes32(uint256(7)), address(0));
        p.assets = new uint32[](1);
        p.assets[0] = SOL;
        p.risk.maxLeverageBps = 100_001;
        vm.prank(launcher);
        vm.expectRevert(abi.encodeWithSelector(GainsVaultPolicy.LeverageAboveNavBound.selector, uint32(SOL)));
        platform.create(p, _noPermit());
        p.risk.maxLeverageBps = 100_000;
        vm.prank(launcher);
        platform.create(p, _noPermit());
    }

    // ==================================================================
    // registerPlatformAgent / unregisterPlatformAgent
    // ==================================================================
    function test_GOV_FM_registerPlatformAgent_cells() public {
        address predicted = _predicted(launcher, bytes32(uint256(55)));
        address[5] memory nope = [platformGuardian, platformSentinel, launcher, stranger, fvOwner];
        for (uint256 i; i < nope.length; ++i) {
            vm.prank(nope[i]);
            vm.expectRevert(GainsVaultFactory.NotRegistrar.selector);
            platform.registerPlatformAgent(makeAddr("x"), address(fv));
        }
        // registrar: existing vaults only
        vm.prank(registrar);
        vm.expectRevert(GainsVaultFactory.NotRegistrar.selector);
        platform.registerPlatformAgent(makeAddr("x"), predicted);
        vm.prank(registrar);
        platform.registerPlatformAgent(makeAddr("x"), address(fv));
        // owner: any address, pre-binding a predicted one included
        vm.prank(platformOwner);
        platform.registerPlatformAgent(makeAddr("y"), predicted);
        assertEq(platform.agentOfVault(predicted), makeAddr("y"));
        vm.prank(platformOwner);
        vm.expectRevert(abi.encodeWithSelector(GainsVaultFactory.VaultAlreadyHasAgent.selector, predicted, makeAddr("y")));
        platform.registerPlatformAgent(makeAddr("z"), predicted);
        vm.prank(platformOwner);
        vm.expectRevert(GainsVaultFactory.ZeroAddress.selector);
        platform.registerPlatformAgent(address(0), predicted);
    }

    function test_GOV_FM_unregisterPlatformAgent_cells() public {
        // a non-live agent (a replacement for fv that was never set)
        address repl = makeAddr("repl");
        vm.prank(registrar);
        platform.registerPlatformAgent(repl, address(fv));
        address[3] memory nope = [launcher, stranger, fvOwner];
        for (uint256 i; i < nope.length; ++i) {
            vm.prank(nope[i]);
            vm.expectRevert(GainsVaultFactory.NotRegistrar.selector);
            platform.unregisterPlatformAgent(repl);
        }
        address[4] memory yes = [platformOwner, registrar, platformGuardian, platformSentinel];
        for (uint256 i; i < yes.length; ++i) {
            uint256 snap = vm.snapshotState();
            vm.prank(yes[i]);
            platform.unregisterPlatformAgent(repl);
            assertFalse(platform.isPlatformAgent(repl));
            assertEq(fv.agent(), agentA, "live agent untouched");
            vm.revertToState(snap);
        }
        // the live agent: registrar refused (I2-03), owner / guardian / sentinel revoke it on the vault
        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(GainsVaultFactory.LiveAgent.selector, agentA, address(fv)));
        platform.unregisterPlatformAgent(agentA);
        address[3] memory plat = [platformOwner, platformGuardian, platformSentinel];
        for (uint256 i; i < plat.length; ++i) {
            uint256 snap = vm.snapshotState();
            vm.prank(plat[i]);
            platform.unregisterPlatformAgent(agentA);
            assertEq(fv.agent(), address(0), "revoked on the vault");
            vm.revertToState(snap);
        }
        // an unknown agent is a no-op for the allowed callers
        vm.prank(registrar);
        platform.unregisterPlatformAgent(makeAddr("unknown"));
    }

    // ==================================================================
    // owner-only setters, ownership
    // ==================================================================
    function test_GOV_FM_ownerOnlySetters() public {
        address[6] memory nope = [registrar, platformGuardian, platformSentinel, launcher, stranger, fvOwner];
        for (uint256 i; i < nope.length; ++i) {
            address a = nope[i];
            bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, a);
            vm.startPrank(a);
            vm.expectRevert(err);
            platform.setProtocolFeeRecipient(a);
            vm.expectRevert(err);
            platform.setShares(0, 0);
            vm.expectRevert(err);
            platform.setMinSeedUsdc(0);
            vm.expectRevert(err);
            platform.setMinAgentGas(0);
            vm.expectRevert(err);
            platform.setLauncherAllowed(a, true);
            vm.expectRevert(err);
            platform.setOpenLaunch(true);
            vm.expectRevert(err);
            platform.setGuardian(a);
            vm.expectRevert(err);
            platform.setSentinel(a);
            vm.expectRevert(err);
            platform.setAgentRegistrar(a);
            vm.expectRevert(err);
            platform.setAssetCurated(DOGE, true, address(btcFeed), 100, 20);
            vm.expectRevert(err);
            platform.setMaxDepositCap(1);
            vm.expectRevert(err);
            platform.setSequencerFeed(a, SEQ_GRACE);
            vm.expectRevert(err);
            platform.lowerProtocolShare(address(fv), 0);
            vm.expectRevert(err);
            platform.transferOwnership(a);
            vm.expectRevert(err);
            platform.renounceOwnership();
            vm.stopPrank();
        }
        // the owner: every setter works (lowerProtocolShare only lowers)
        vm.startPrank(platformOwner);
        platform.setProtocolFeeRecipient(makeAddr("t2"));
        platform.setShares(500, 2_000);
        platform.setMinSeedUsdc(2e6);
        platform.setMinAgentGas(0);
        platform.setLauncherAllowed(stranger, true);
        platform.setOpenLaunch(true);
        platform.setGuardian(makeAddr("g2"));
        platform.setSentinel(makeAddr("s2"));
        platform.setAgentRegistrar(makeAddr("r2"));
        platform.setAssetCurated(DOGE, true, address(btcFeed), 100, 20);
        platform.setMaxDepositCap(1);
        vm.expectRevert(GainsVaultFactory.ZeroAddress.selector);
        platform.setSequencerFeed(address(0), SEQ_GRACE); // GR1-10: never zero
        platform.setSequencerFeed(makeAddr("seq2"), 7_200);
        assertEq(platform.sequencerFeed(), makeAddr("seq2"));
        assertEq(platform.sequencerGracePeriod(), 7_200);
        platform.lowerProtocolShare(address(fv), 100);
        vm.expectRevert(E.InvalidShare.selector);
        platform.lowerProtocolShare(address(fv), 100);
        vm.expectRevert(GainsVaultFactory.RolesCollide.selector);
        platform.renounceOwnership();
        vm.stopPrank();
    }

    function test_GOV_FM_ownershipAndRoleCollisions_pendingOwnerIncluded() public {
        vm.startPrank(platformOwner);
        // the incoming owner may not be a hot role; the guardian may (one cold multisig)
        vm.expectRevert(GainsVaultFactory.RolesCollide.selector);
        platform.transferOwnership(platformSentinel);
        vm.expectRevert(GainsVaultFactory.RolesCollide.selector);
        platform.transferOwnership(registrar);
        address next = makeAddr("nextFactoryOwner");
        platform.transferOwnership(next);
        // with `next` pending, no hot role may become `next`
        vm.expectRevert(GainsVaultFactory.RolesCollide.selector);
        platform.setSentinel(next);
        vm.expectRevert(GainsVaultFactory.RolesCollide.selector);
        platform.setAgentRegistrar(next);
        // ... nor collide with the current owner or each other
        vm.expectRevert(GainsVaultFactory.RolesCollide.selector);
        platform.setSentinel(platformOwner);
        vm.expectRevert(GainsVaultFactory.RolesCollide.selector);
        platform.setSentinel(platformGuardian);
        vm.expectRevert(GainsVaultFactory.RolesCollide.selector);
        platform.setGuardian(platformSentinel);
        vm.expectRevert(GainsVaultFactory.RolesCollide.selector);
        platform.setGuardian(registrar);
        vm.expectRevert(GainsVaultFactory.RolesCollide.selector);
        platform.setAgentRegistrar(platformGuardian);
        vm.expectRevert(GainsVaultFactory.RolesCollide.selector);
        platform.setAgentRegistrar(platformSentinel);
        vm.expectRevert(GainsVaultFactory.ZeroAddress.selector);
        platform.setGuardian(address(0));
        vm.expectRevert(GainsVaultFactory.ZeroAddress.selector);
        platform.setSentinel(address(0));
        platform.setGuardian(next); // owner == guardian allowed
        platform.setAgentRegistrar(address(0)); // no registrar
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        platform.acceptOwnership();
        vm.prank(next);
        platform.acceptOwnership();
        assertEq(platform.owner(), next);
        assertEq(platform.guardian(), next);
    }

    // ==================================================================
    // registrar signature (SPEC L2 / L3)
    // ==================================================================
    function _sigParams(bytes32 salt, address agent_) internal view returns (GainsVaultFactory.CreateParams memory p) {
        p = _cparams(launcher, salt, agent_);
    }

    function test_GOV_FM_sig_replayAcrossVaultsFactoriesChains() public {
        address agentB = makeAddr("agentB");
        bytes32 s1 = bytes32(uint256(11));
        bytes32 s2 = bytes32(uint256(12));
        GainsVaultFactory.CreateParams memory p = _sigParams(s1, agentB);
        // across vaults: the signature for salt 11's vault, used for salt 12's
        GainsVaultFactory.CreateParams memory q = _sigParams(s2, agentB);
        q.agentSig = p.agentSig;
        vm.prank(launcher);
        vm.expectRevert(GainsVaultFactory.BadAgentSignature.selector);
        platform.create{value: GAS}(q, _noPermit());
        // across creators: another allowlisted launcher replays it with the same salt (its own predicted vault)
        vm.prank(platformOwner);
        platform.setLauncherAllowed(outsider, true);
        usdc.mint(outsider, 1e6);
        vm.deal(outsider, 1 ether);
        vm.prank(outsider);
        usdc.approve(address(platform), 1e6);
        vm.prank(outsider);
        vm.expectRevert(GainsVaultFactory.BadAgentSignature.selector);
        platform.create{value: GAS}(p, _noPermit());

        // across factories: the same implementations behind a second factory
        GainsVaultFactory f2 = new GainsVaultFactory(
            platformOwner,
            address(vaultImpl),
            address(policyImpl),
            IERC20(address(usdc)),
            IGainsDiamond(address(diamond)),
            address(sequencer),
            SEQ_GRACE,
            protocolTreasury,
            platformGuardian,
            platformSentinel
        );
        vm.startPrank(platformOwner);
        f2.setAgentRegistrar(registrar);
        f2.setLauncherAllowed(launcher, true);
        f2.setAssetCurated(BTC, true, address(btcFeed), BTC_MAX_AGE, 20);
        f2.setAssetCurated(ETH, true, address(ethFeed), BTC_MAX_AGE, 20);
        vm.stopPrank();
        address pred2 = f2.predictVaultAddress(launcher, s1);
        GainsVaultFactory.CreateParams memory r = _sigParams(s1, agentB);
        r.agentSig = _sign(registrarKey, _digest(address(platform), block.chainid, agentB, pred2, r.agentDeadline));
        vm.prank(launcher);
        usdc.approve(address(f2), 1e6);
        vm.prank(launcher);
        vm.expectRevert(GainsVaultFactory.BadAgentSignature.selector);
        f2.create{value: GAS}(r, _noPermit());

        // across chains: signed for chain 999 (HyperEVM), used here
        GainsVaultFactory.CreateParams memory c = _sigParams(s1, agentB);
        c.agentSig = _sign(registrarKey, _digest(address(platform), 999, agentB, _predicted(launcher, s1), c.agentDeadline));
        vm.prank(launcher);
        vm.expectRevert(GainsVaultFactory.BadAgentSignature.selector);
        platform.create{value: GAS}(c, _noPermit());

        // the genuine one works once. Its replay is stopped by the CREATE2 collision, not by the signature: the agent
        // is now "pre-bound" to exactly this predicted address, so create() skips the signature branch.
        vm.prank(launcher);
        (address va,) = platform.create{value: GAS}(p, _noPermit());
        assertEq(GainsVault(va).agent(), agentB);
        assertEq(platform.platformAgentFor(agentB), va);
        vm.prank(launcher);
        vm.expectRevert();
        platform.create{value: GAS}(p, _noPermit());
        // and the same signature for another salt of the same creator: the agent is bound to one vault for good
        GainsVaultFactory.CreateParams memory p2 = _sigParams(s2, agentB);
        vm.prank(launcher);
        vm.expectRevert(abi.encodeWithSelector(GainsVaultFactory.AgentAlreadyBound.selector, agentB, va));
        platform.create{value: GAS}(p2, _noPermit());
        // even after the agent is unregistered, the salt's vault exists: the CREATE2 clone cannot be redeployed
        vm.prank(platformSentinel);
        platform.unregisterPlatformAgent(agentB);
        vm.prank(launcher);
        vm.expectRevert();
        platform.create{value: GAS}(p, _noPermit());
    }

    function test_GOV_FM_sig_expiryMalleabilitySigner() public {
        address agentB = makeAddr("agentB");
        bytes32 s1 = bytes32(uint256(21));
        GainsVaultFactory.CreateParams memory p = _sigParams(s1, agentB);
        // expired
        uint256 t0 = vm.getBlockTimestamp();
        _warp(p.agentDeadline + 1);
        vm.prank(launcher);
        vm.expectRevert(GainsVaultFactory.BadAgentSignature.selector);
        platform.create{value: GAS}(p, _noPermit());
        _warp(t0);

        // malleability: the high-s twin and the 64 byte compact form are rejected by OZ ECDSA
        (bytes32 r, bytes32 s, uint8 v) = _split(p.agentSig);
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 sHigh = bytes32(n - uint256(s));
        GainsVaultFactory.CreateParams memory q = p;
        q.agentSig = abi.encodePacked(r, sHigh, v == 27 ? uint8(28) : uint8(27));
        vm.prank(launcher);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, sHigh));
        platform.create{value: GAS}(q, _noPermit());
        bytes32 vs = bytes32(uint256(s) | (uint256(v - 27) << 255));
        q.agentSig = abi.encodePacked(r, vs);
        vm.prank(launcher);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, 64));
        platform.create{value: GAS}(q, _noPermit());

        // signer: only the registrar or the (cold) factory owner; a guardian / sentinel / creator signature fails
        uint256 creatorSigKey = launcherKey;
        q.agentSig = _agentSig(creatorSigKey, agentB, _predicted(launcher, s1), p.agentDeadline);
        vm.prank(launcher);
        vm.expectRevert(GainsVaultFactory.BadAgentSignature.selector);
        platform.create{value: GAS}(q, _noPermit());
        // deadline == now is still valid (fresh params: `q = p` above aliased the memory struct)
        p = _sigParams(s1, agentB);
        _warp(p.agentDeadline);
        vm.prank(launcher);
        platform.create{value: GAS}(p, _noPermit());
    }

    function _split(bytes memory sig) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
    }

    /// SPEC L3: salts are scoped by creator. Another launcher with the same salt gets its own address, the registrar
    /// cannot pre-bind the victim's predicted address, and nobody else can deploy to it.
    function test_GOV_FM_create2SaltScopedNoFrontRun() public {
        bytes32 salt = bytes32(uint256(31));
        address victimPred = _predicted(launcher, salt);
        vm.prank(platformOwner);
        platform.setLauncherAllowed(outsider, true);
        usdc.mint(outsider, 1e6);
        vm.prank(outsider);
        usdc.approve(address(platform), 1e6);
        GainsVaultFactory.CreateParams memory p = _cparams(outsider, salt, address(0));
        vm.prank(outsider);
        (address va,) = platform.create(p, _noPermit());
        assertTrue(va != victimPred, "same salt, other creator, other address");
        vm.prank(registrar);
        vm.expectRevert(GainsVaultFactory.NotRegistrar.selector);
        platform.registerPlatformAgent(makeAddr("squat"), victimPred);
        // the victim launches at its predicted address with its signed agent
        GainsVaultFactory.CreateParams memory v = _cparams(launcher, salt, makeAddr("agentV"));
        vm.prank(launcher);
        (address vv,) = platform.create{value: GAS}(v, _noPermit());
        assertEq(vv, victimPred);
    }

    // ==================================================================
    // clones, policy binding, libraries
    // ==================================================================
    function test_GOV_FM_clonesInitializeOnce_policyBoundToItsVault() public {
        InitParams memory ip = _standaloneParams(fp);
        address[4] memory who = [stranger, address(platform), fvOwner, platformOwner];
        for (uint256 i; i < who.length; ++i) {
            vm.prank(who[i]);
            vm.expectRevert(Initializable.InvalidInitialization.selector);
            fv.initialize(ip);
            vm.prank(who[i]);
            vm.expectRevert(Initializable.InvalidInitialization.selector);
            vaultImpl.initialize(ip);
        }
        // a third party's own clone cannot adopt a policy bound to another vault
        GainsVault rogue = GainsVault(Clones.clone(address(vaultImpl)));
        vm.expectRevert(E.PolicyMismatch.selector);
        rogue.initialize(ip);
        // a policy a third party makes for an existing vault has no effect on it: the vault keeps its own
        GainsVaultPolicy fake = GainsVaultPolicy(Clones.clone(address(policyImpl)));
        uint32[] memory a = new uint32[](1);
        a[0] = BTC;
        fake.initialize(stranger, _defaultRisk(), a, 1 days, address(platform), address(fv));
        assertEq(address(fv.policy()), address(fp));
        vm.prank(stranger);
        vm.expectRevert(GainsVaultPolicy.NotVault.selector);
        fake.setPairFeed(BTC, address(btcFeed), BTC_MAX_AGE, 20);
    }

    /// The linked libraries refuse a direct (non-delegatecall) call: Solidity's library call guard (HL vDirectLibraryCall).
    function test_GOV_FM_librariesRefuseDirectCalls() public {
        (bool ok,) = address(GainsVaultGovernance).call(
            abi.encodeWithSelector(GainsVaultGovernance.queue.selector, uint256(0), abi.encodeCall(GainsVault.setManager, (stranger)))
        );
        assertFalse(ok, "governance library");
        (ok,) = address(GainsVaultGovernance).call(abi.encodeWithSelector(GainsVaultGovernance.clearBreach.selector, uint256(0), stranger));
        assertFalse(ok, "clearBreach direct");
        (ok,) = address(GainsVaultLogic).call(abi.encodeWithSelector(GainsVaultLogic.setAgent.selector, uint256(0), stranger));
        assertFalse(ok, "logic library");
    }

    // ==================================================================
    // maxDepositCap (SPEC R17, N-13, I3-05)
    // ==================================================================
    function test_GOV_FM_maxDepositCap_lowerLaterAndZero() public {
        assertEq(fv.depositCap(), 50_000e6);
        vm.prank(fvOwner);
        vm.expectRevert(E.CapExceeded.selector);
        fv.setDepositCap(0);
        uint256 maxCap = platform.maxDepositCap();
        vm.prank(fvOwner);
        vm.expectRevert(E.CapExceeded.selector);
        fv.setDepositCap(maxCap + 1);
        // the platform lowers its maximum below the vault's cap: the vault keeps its cap and keeps taking deposits
        vm.prank(platformOwner);
        platform.setMaxDepositCap(1_000e6);
        vm.prank(alice);
        fv.requestDeposit(40_000e6, alice);
        assertEq(fv.pendingDepositAssets(), 40_000e6, "existing vault unaffected (N-13 snapshot)");
        // ... but its owner can no longer re-set that cap, only one <= the new maximum
        vm.prank(fvOwner);
        vm.expectRevert(E.CapExceeded.selector);
        fv.setDepositCap(50_000e6);
        vm.prank(fvOwner);
        fv.setDepositCap(1_000e6);
        // maximum 0: no factory vault can change its cap at all (not even lower it) and no launch passes
        vm.prank(platformOwner);
        platform.setMaxDepositCap(0);
        vm.prank(fvOwner);
        vm.expectRevert(E.CapExceeded.selector);
        fv.setDepositCap(1);
        GainsVaultFactory.CreateParams memory p = _cparams(launcher, bytes32(uint256(41)), address(0));
        vm.prank(launcher);
        vm.expectRevert(abi.encodeWithSelector(GainsVaultFactory.CapAboveMax.selector, p.depositCap, 0));
        platform.create(p, _noPermit());
    }
}
