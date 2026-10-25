// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {HyperVault} from "../src/HyperVault.sol";
import {IHyperVaultErrors, IHyperVaultEvents} from "../src/VaultTypes.sol";
import {HyperVaultLens} from "../src/HyperVaultLens.sol";
import {VaultPolicy} from "../src/VaultPolicy.sol";
import {InitParams} from "../src/VaultTypes.sol";
import {HyperVaultFactory} from "../src/HyperVaultFactory.sol";
import {HyperCore, ICoreDepositWallet} from "../src/hypercore/HyperCore.sol";
import {PxMath} from "../src/libraries/PxMath.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract PolicyTest is Base {
    function test_TighteningIsImmediate() public {
        VaultPolicy.RiskConfig memory c = _defaultRisk();
        c.maxLeverageBps = 20_000;
        vm.prank(owner);
        policy.proposeConfig(c);
        assertEq(policy.maxLeverageBps(), 20_000);
    }

    function test_LooseningIsTimelocked() public {
        VaultPolicy.RiskConfig memory c = _defaultRisk();
        c.maxLeverageBps = 50_000;
        vm.prank(owner);
        policy.proposeConfig(c);
        assertEq(policy.maxLeverageBps(), 30_000);

        vm.expectRevert(VaultPolicy.NotReady.selector);
        policy.applyPendingConfig();

        vm.warp(policy.pendingConfig().eta); // hl-r2 H01 fix: epoch + 1 day
        policy.applyPendingConfig();
        assertEq(policy.maxLeverageBps(), 50_000);
    }

    function test_MixedChangeIsTimelocked() public {
        VaultPolicy.RiskConfig memory c = _defaultRisk();
        c.maxLeverageBps = 10_000; // tighter
        c.maxDailyLossBps = 900; // looser
        vm.prank(owner);
        policy.proposeConfig(c);
        assertEq(policy.maxLeverageBps(), 30_000);
    }

    function test_AssetAllowlist() public {
        vm.prank(owner);
        policy.disallowAsset(ETH);
        assertFalse(policy.isAssetAllowed(ETH));

        vm.prank(owner);
        policy.queueAllowAsset(ETH);
        vm.expectRevert(VaultPolicy.NotReady.selector);
        policy.allowAsset(ETH);
        vm.warp(policy.assetAllowEta(ETH));
        policy.allowAsset(ETH);
        assertTrue(policy.isAssetAllowed(ETH));

        uint32[] memory list = policy.allowedAssets();
        assertEq(list.length, 2);
    }

    function test_SpotAssetsRejected() public {
        vm.prank(owner);
        vm.expectRevert(VaultPolicy.SpotNotSupported.selector);
        policy.queueAllowAsset(10_001);
    }

    function test_InvalidConfigRejected() public {
        VaultPolicy.RiskConfig memory c = _defaultRisk();
        c.maxSlippageBps = 5_000;
        vm.prank(owner);
        vm.expectRevert(VaultPolicy.InvalidConfig.selector);
        policy.proposeConfig(c);
    }

    function test_TimelockDelayLoweringIsTimelocked() public {
        vm.prank(owner);
        policy.proposeTimelockDelay(1 days);
        assertEq(policy.timelockDelay(), 2 days);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        policy.applyTimelockDelay();
        assertEq(policy.timelockDelay(), 1 days);
    }

    function test_LooseningExpiresAfterGrace() public {
        VaultPolicy.RiskConfig memory c = _defaultRisk();
        c.maxLeverageBps = 50_000;
        vm.prank(owner);
        policy.proposeConfig(c);
        vm.warp(policy.pendingConfig().eta + policy.GRACE_PERIOD() + 1);
        vm.expectRevert(VaultPolicy.Expired.selector);
        policy.applyPendingConfig();
    }

    function test_NewFieldsAreTightenOnly() public {
        VaultPolicy.RiskConfig memory c = _defaultRisk();
        c.maxNavMoveBps = 3_000; // a wider band settles sooner: tightening for liveness (audit N-03)
        c.maxFlattenSlippageBps = 300;
        vm.prank(owner);
        policy.proposeConfig(c);
        assertEq(policy.maxNavMoveBps(), 3_000, "immediate");
        assertEq(policy.maxFlattenSlippageBps(), 300);
        c.maxNavMoveBps = 1_000;
        vm.prank(owner);
        policy.proposeConfig(c);
        assertEq(policy.maxNavMoveBps(), 3_000, "narrowing the band is timelocked");
        c.maxNavMoveBps = 499;
        vm.prank(owner);
        vm.expectRevert(VaultPolicy.InvalidConfig.selector);
        policy.proposeConfig(c);
        c.maxNavMoveBps = 500;
        c.maxFlattenSlippageBps = 2_001;
        vm.prank(owner);
        vm.expectRevert(VaultPolicy.InvalidConfig.selector);
        policy.proposeConfig(c);
    }

    function test_CheckpointRule() public {
        // No checkpoint yet: checkRisk records the live NAV as is, a normal settle waits for it (audit N-12).
        (uint256 n, bool upd) = policy.nextCheckpoint(0, 0, 1_000e6, false);
        assertEq(n, 1_000e6);
        assertTrue(upd);
        vm.expectRevert(VaultPolicy.StaleCheckpoint.selector);
        policy.nextCheckpoint(0, 0, 1_000e6, true);
        // A checkpoint at zero NAV protects nothing: the next value is taken as is.
        (n, upd) = policy.nextCheckpoint(0, vm.getBlockTimestamp(), 5_000e6, true);
        assertEq(n, 5_000e6);
        assertTrue(upd);
        uint256 at = vm.getBlockTimestamp();
        // Same interval: kept.
        (, upd) = policy.nextCheckpoint(1_000e6, at, 5_000e6, false);
        assertFalse(upd);
        // Next interval: ratchets by at most 20%.
        vm.warp(at + 1 hours);
        (n, upd) = policy.nextCheckpoint(1_000e6, at, 5_000e6, false);
        assertEq(n, 1_200e6);
        (n,) = policy.nextCheckpoint(1_000e6, at, 100e6, false);
        assertEq(n, 800e6);
        (n,) = policy.nextCheckpoint(1_000e6, at, 1_050e6, false);
        assertEq(n, 1_050e6);
        // Settle: within the band passes, outside reverts, stale reverts.
        (n, upd) = policy.nextCheckpoint(1_000e6, at, 1_200e6, true);
        assertEq(n, 1_200e6);
        vm.expectRevert(abi.encodeWithSelector(VaultPolicy.NavMoved.selector, 1_201e6, 1_000e6));
        policy.nextCheckpoint(1_000e6, at, 1_201e6, true);
        vm.warp(at + 1 days + 1);
        vm.expectRevert(VaultPolicy.StaleCheckpoint.selector);
        policy.nextCheckpoint(1_000e6, at, 1_000e6, true);
    }

    function test_FlattenOrderCapsCustomSlippage() public {
        vm.expectRevert(VaultPolicy.SlippageTooHigh.selector);
        policy.flattenOrder(100_000e1, 5, 1_000_000, 301);
        (bool isBuy, uint64 px,) = policy.flattenOrder(100_000e1, 5, 1_000_000, 300);
        assertFalse(isBuy);
        assertEq(px, 97_000e8, "3% under mark");
        (, px,) = policy.flattenOrder(100_000e1, 5, 1_000_000, 0);
        assertEq(px, 99_000e8, "policy band");
    }

    function test_PolicyCloneCannotReinitialize() public {
        uint32[] memory assets = new uint32[](1);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        policy.initialize(owner, _defaultRisk(), assets, 2 days, address(0));
    }

    function test_PolicyImplementationCannotInitialize() public {
        uint32[] memory assets = new uint32[](1);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        policyImpl.initialize(owner, _defaultRisk(), assets, 2 days, address(0));
    }
}

contract PxMathTest is Base {
    function test_SigFigs() public pure {
        assertEq(PxMath.toSigFigs5(123_456, false), 123_450);
        assertEq(PxMath.toSigFigs5(123_456, true), 123_460);
        assertEq(PxMath.toSigFigs5(123_450, true), 123_450);
        assertEq(PxMath.toSigFigs5(99_999, true), 99_999);
        assertEq(PxMath.toSigFigs5(1_234_567_891, false), 1_234_500_000);
    }

    function test_BoundedPxSell() public pure {
        // ETH mark 3,000.00 (raw 300000, szDecimals 4). Sell with 1% -> 2,970.00
        uint64 px = PxMath.boundedLimitPx1e8(300_000, 4, false, 100);
        assertEq(px, 2_970e8);
    }

    function testFuzz_BoundedPxWithinBand(uint64 rawMark, uint8 szDec, uint16 slip, bool isBuy) public pure {
        rawMark = uint64(bound(rawMark, 1_000, 1e9));
        szDec = uint8(bound(szDec, 0, 6));
        slip = uint16(bound(slip, 1, 2_000));
        uint256 px = PxMath.boundedLimitPx1e8(rawMark, szDec, isBuy, slip);
        uint256 mark1e8 = uint256(rawMark) * 10 ** (2 + szDec);
        uint256 band = (mark1e8 * slip) / 10_000;
        if (isBuy) assertLe(px, mark1e8 + band);
        else assertGe(px + band + 10 ** (2 + szDec), mark1e8);
    }
}

contract CloneInitTest is Base {
    function test_VaultCloneCannotReinitialize() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(_standaloneParams(policy));
    }

    function test_VaultImplementationCannotInitialize() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vaultImpl.initialize(_standaloneParams(policy));
    }

    function test_ImplementationFitsEip170() public {
        uint256 size = address(vaultImpl).code.length;
        emit log_named_uint("HyperVault runtime bytes", size);
        assertLe(size, 24_576, "HyperVault implementation exceeds EIP-170, see README headroom note");
        assertLe(address(policyImpl).code.length, 24_576);
        assertLe(address(lens).code.length, 24_576);
        assertGe(24_576 - size, 1_500, "keep at least 1.5 KB of headroom in the vault");
    }

    function test_Erc4626ViewSurface() public {
        assertEq(vault.asset(), address(usdc));
        assertEq(
            lens.maxDeposit(vault, alice) + lens.maxMint(vault, alice) + lens.maxWithdraw(vault, alice)
                + lens.maxRedeem(vault, alice),
            0
        );
        _deposit(alice, 1_000e6);
        _settle();
        assertEq(vault.previewDeposit(1e6), vault.convertToShares(1e6));
        assertEq(vault.previewRedeem(1e12), vault.convertToAssets(1e12));
        assertGe(vault.previewMint(1e12), vault.convertToAssets(1e12), "mint rounds up");
        assertGe(vault.previewWithdraw(1e6), vault.convertToShares(1e6), "withdraw rounds up");
        // Nothing pending: the lens previews agree with the vault.
        assertEq(lens.previewDeposit(vault, 1e6), vault.previewDeposit(1e6));
        assertEq(lens.previewRedeem(vault, 1e12), vault.previewRedeem(1e12));
    }

    function test_LensPreviewIncludesPendingFees() public {
        _deposit(alice, 1_000e6);
        _settle();
        vm.warp(vm.getBlockTimestamp() + 365 days);
        (uint256 feeShares,) = lens.pendingFeeShares(vault);
        assertGt(feeShares, 0);
        assertGt(lens.previewDeposit(vault, 1e6), vault.previewDeposit(1e6), "fee shares dilute the price");
        HyperVaultLens.Status memory st = lens.status(vault);
        assertEq(st.pendingFeeShares, feeShares);
        assertLt(st.sharePriceAfterFees, st.sharePrice);
        assertFalse(st.coreActive == false);
        assertEq(st.risk.maxNavMoveBps, 2_000);
        assertEq(st.guardian, guardian);
        // Emergency settlements refund deposits, so the lens quotes no shares for them (audit N-15).
        vm.prank(guardian);
        vault.triggerEmergency();
        assertEq(lens.previewDeposit(vault, 1e6), 0);
        assertEq(lens.previewMint(vault, 1e12), 0);
        assertGt(lens.previewRedeem(vault, 1e12), 0);
    }

    function test_CloneStateIsIndependent() public {
        HyperVault other = HyperVault(Clones.clone(address(vaultImpl)));
        InitParams memory p = _standaloneParams(policy);
        p.name = "Other";
        p.managementFeeBps = 0;
        other.initialize(p);
        assertEq(other.name(), "Other");
        assertEq(vault.name(), "DojiPad Vault");
        assertEq(other.managementFeeBps(), 0);
        assertEq(vault.managementFeeBps(), 200);
        assertEq(other.decimals(), 12);
        assertEq(other.asset(), address(usdc));
    }
}

contract FactoryTest is Base {
    HyperVaultFactory internal factory;
    address internal treasury = makeAddr("treasury");
    address internal agentAddr = makeAddr("agent");
    address internal registrar = makeAddr("registrar");
    uint256 internal registrarKey = uint256(keccak256(abi.encodePacked("registrar"))); // makeAddr's key

    uint256 internal creatorKey = 0xA11CE;
    address internal creator;

    uint256 internal constant SEED = 2e6;
    uint256 internal constant HYPE = 0.01 ether;

    function setUp() public override {
        super.setUp();
        creator = vm.addr(creatorKey);
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
        factory.setLauncherAllowed(creator, true);
        factory.setAssetCurated(BTC, true);
        factory.setAssetCurated(ETH, true);
        factory.setAgentRegistrar(registrar);
        vm.stopPrank();
        // Agents are bound to the vault they serve (audit N-07): round 4 binds them in create() from the registrar's
        // signature over (agent, predicted vault, deadline) (V-04); _params signs for salt 1, the default launch.
        usdc.mint(creator, 1_000e6);
        vm.deal(creator, 10 ether);
    }

    function _params(bool hosted, address agent_) internal view returns (HyperVaultFactory.CreateParams memory p) {
        uint32[] memory assets = new uint32[](2);
        assets[0] = BTC;
        assets[1] = ETH;
        p = HyperVaultFactory.CreateParams({
            name: "Manager Vault",
            symbol: "mV",
            owner: creator,
            manager: creator,
            feeRecipient: creator,
            managementFeeBps: 0,
            performanceFeeBps: 2_000,
            timelockDelay: 2 days,
            depositCap: 50_000e6,
            risk: _defaultRisk(),
            assets: assets,
            agent: agent_,
            agentSig: "",
            agentDeadline: 0,
            operator: address(0),
            hosted: hosted,
            seedUsdc: SEED,
            salt: bytes32(uint256(1))
        });
        if (agent_ != address(0)) {
            p.agentDeadline = vm.getBlockTimestamp() + 1 hours;
            p.agentSig = _agentSig(registrarKey, agent_, _predicted(creator, p.salt), p.agentDeadline);
        }
    }

    /// @dev Computed locally: an external call here would consume the caller's vm.prank meant for create().
    function _predicted(address creator_, bytes32 salt) internal view returns (address) {
        return Clones.predictDeterministicAddress(address(vaultImpl), keccak256(abi.encode(creator_, salt)), address(factory));
    }

    function _agentSig(uint256 key, address agent_, address vault_, uint256 deadline) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encode("DojiPad platform agent", block.chainid, address(factory), agent_, vault_, deadline));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, MessageHashUtils.toEthSignedMessageHash(digest));
        return abi.encodePacked(r, s, v);
    }

    function _noPermit() internal pure returns (HyperVaultFactory.PermitData memory) {
        return HyperVaultFactory.PermitData(0, 0, 0, bytes32(0), bytes32(0));
    }

    function _permit(uint256 value, uint256 deadline) internal view returns (HyperVaultFactory.PermitData memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                creator,
                address(factory),
                value,
                usdc.nonces(creator),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(creatorKey, digest);
        return HyperVaultFactory.PermitData(value, deadline, v, r, s);
    }

    function _createWithPermit(bool hosted, address agent_) internal returns (HyperVault v, VaultPolicy p) {
        HyperVaultFactory.PermitData memory pd = _permit(SEED, vm.getBlockTimestamp() + 1 hours);
        vm.prank(creator);
        (address va, address pa) = factory.create{value: HYPE}(_params(hosted, agent_), pd);
        v = HyperVault(va);
        p = VaultPolicy(pa);
        _setCoreUser(va, true);
        _setCore(va, 0, 0, 0);
        _setWithdrawable(va, 0);
        _setPosition(va, BTC, 0);
        _setPosition(va, ETH, 0);
        if (v.agentActiveAt() > vm.getBlockTimestamp()) vm.warp(v.agentActiveAt()); // HLO-07: AGENT_WARMUP
    }

    // ------------------------------------------------------------------
    // Creation
    // ------------------------------------------------------------------
    function test_CreateWithPermit() public {
        address predicted = factory.predictVaultAddress(creator, bytes32(uint256(1)));
        (HyperVault v, VaultPolicy p) = _createWithPermit(false, address(0));
        assertEq(address(v), predicted, "deterministic address");
        assertTrue(factory.isVault(address(v)));
        assertEq(factory.policyOf(address(v)), address(p));
        assertEq(address(v.policy()), address(p));
        assertEq(v.factory(), address(factory));
        assertEq(v.owner(), creator);
        assertEq(p.owner(), creator);
        assertEq(v.guardian(), guardian, "platform guardian, read from the factory");
        assertEq(v.sentinel(), sentinel, "platform sentinel, read from the factory");
        assertEq(p.factory(), address(factory));
        assertEq(v.depositCap(), 50_000e6);
        assertEq(factory.vaultCount(), 1);
        assertEq(v.protocolShareBps(), 1_000);
        assertEq(v.baseShareBps(), 1_000);
        assertFalse(v.hosted());
        assertEq(v.agent(), address(0));
        assertEq(usdc.allowance(creator, address(factory)), 0, "permit consumed exactly");
    }

    function test_CreateWithApproveFallback() public {
        vm.prank(creator);
        usdc.approve(address(factory), SEED);
        vm.prank(creator);
        (address va,) = factory.create{value: HYPE}(_params(false, address(0)), _noPermit());
        assertTrue(factory.isVault(va));
    }

    function test_CreateWithoutAllowanceReverts() public {
        vm.prank(creator);
        vm.expectRevert();
        factory.create{value: HYPE}(_params(false, address(0)), _noPermit());
    }

    function test_FrontRunPermitDoesNotBrickCreate() public {
        HyperVaultFactory.PermitData memory pd = _permit(SEED, vm.getBlockTimestamp() + 1 hours);
        // Someone replays the permit first; the allowance is set and the nonce consumed.
        usdc.permit(creator, address(factory), pd.value, pd.deadline, pd.v, pd.r, pd.s);
        vm.prank(creator);
        (address va,) = factory.create{value: HYPE}(_params(false, address(0)), pd);
        assertTrue(factory.isVault(va));
    }

    function test_SeedBridgedToCoreSpotThenHypeForwarded() public {
        uint256 sinkBefore = hypeSink.received();
        (HyperVault v,) = _createWithPermit(false, address(0));
        // USDC seed: pulled from creator into the deposit wallet, destination spot dex, sent by the vault.
        assertEq(usdc.balanceOf(creator), 1_000e6 - SEED);
        assertEq(depositWallet.totalDeposited(), SEED);
        assertEq(depositWallet.lastDex(), HyperCore.SPOT_DEX);
        assertEq(depositWallet.lastSender(), address(v));
        assertEq(usdc.balanceOf(address(v)), 0, "nothing idle, all bridged");
        // HYPE: forwarded in full from the vault to the system address, after the deposit.
        assertEq(hypeSink.received() - sinkBefore, HYPE);
        assertEq(hypeSink.lastSender(), address(v));
        assertEq(address(v).balance, 0);
        assertEq(address(factory).balance, 0);
        assertTrue(v.bridgeInFlight(), "seed tracked as an in flight bridge");
        assertEq(v.equityAtBridge(), SEED, "snapshot taken while the seed was still idle");
        assertEq(v.bridgeAmount(), SEED);
        assertEq(v.totalAssets(), SEED);
    }

    function test_SeedIsNavNotShares() public {
        (HyperVault v,) = _createWithPermit(false, address(0));
        assertEq(v.totalSupply(), 0, "no shares for the seed");
        _skipBridgeWindow();
        _setCore(address(v), 0, 0, uint64(SEED)); // landed in spot
        assertEq(v.totalAssets(), SEED, "seed is NAV");

        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        vm.prank(alice);
        v.requestDeposit(100e6, alice);
        v.checkRisk();
        vm.prank(creator);
        v.settle();
        v.claim(alice);
        assertEq(v.balanceOf(alice), 100e6 * 1e6, "first mint unaffected by the seed");
        assertApproxEqAbs(v.convertToAssets(v.balanceOf(alice)), 102e6, 1, "seed accrues to the first depositor");
    }

    function test_PreviewMatchesFirstSettleOnSeededVault() public {
        (HyperVault v,) = _createWithPermit(false, address(0));
        _skipBridgeWindow();
        _setCore(address(v), 0, 0, uint64(SEED)); // NAV > 0, supply 0
        assertEq(v.totalSupply(), 0);
        assertGt(v.totalAssets(), 0);
        uint256 preview = v.previewDeposit(100e6);
        assertEq(preview, v.convertToShares(100e6));
        assertEq(preview, 100e6 * 1e6, "first mint rule");
        assertEq(v.previewMint(preview), 100e6);
        assertEq(v.convertToAssets(preview), 100e6);
        assertEq(v.sharePrice(), 1e6, "1 USDC per share before the first mint");

        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        vm.prank(alice);
        v.requestDeposit(100e6, alice);
        v.checkRisk();
        vm.prank(creator);
        v.settle();
        v.claim(alice);
        assertEq(v.balanceOf(alice), preview, "preview == minted");
        assertGt(v.previewDeposit(100e6), 0);
        assertLt(v.previewDeposit(100e6), preview, "after the first mint the seed is priced in");
    }

    /// @dev A-13: the approval sent in the creating transaction is dropped by HyperCore (the Core account does not
    ///      exist yet), so initialize only records the agent. HL-PROXY: it is never approved on HyperCore.
    function test_AgentRecordedAtInitAndApprovedBySync() public {
        uint256 n = writer.count();
        (HyperVault v,) = _createWithPermit(true, agentAddr);
        assertEq(v.agent(), agentAddr, "recorded");
        assertEq(writer.count(), n, "no HyperCore action for the agent inside the creating transaction");
        vm.prank(stranger);
        v.syncAgent();
        // HL-PROXY: never approved on HyperCore; syncAgent is the account-mode pin of the vault itself
        _assertNoApproval(n, agentAddr);
        assertEq(v.agent(), agentAddr, "unchanged");
    }

    function test_SyncAgentIsPermissionlessAndCannotChangeTheAgent() public {
        (HyperVault v,) = _createWithPermit(true, agentAddr);
        _setCoreUser(address(v), true);
        uint256 n = writer.count();
        // A stranger pins at most once per MODE_PIN_INTERVAL; it never names anything but the vault itself.
        vm.prank(stranger);
        v.syncAgent();
        (, uint24 id, bytes memory body) = _decode(writer.last());
        assertEq(id, 16);
        (address user, uint8 mode) = abi.decode(body, (address, uint8));
        assertEq(user, address(v));
        assertEq(mode, 1);
        vm.prank(alice);
        vm.expectRevert(IHyperVaultErrors.NotReady.selector);
        v.syncAgent();
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        vm.prank(creator);
        v.syncAgent();
        assertEq(writer.count(), n + 2);
        _assertNoApproval(n, agentAddr);
        assertEq(v.agent(), agentAddr);
    }

    /// @dev HL-PROXY: the pin is safe without an agent and in a full stop; nothing ever re-approves a revoked agent.
    function test_SyncAgentRefusedWithoutAgentOrWhileReduceOnly() public {
        (HyperVault v,) = _createWithPermit(true, agentAddr);
        _setCoreUser(address(v), true);
        uint256 n = writer.count();
        vm.prank(sentinel);
        v.triggerBreach(); // revokes the agent
        assertEq(v.agent(), address(0));
        vm.prank(sentinel);
        v.syncAgent();
        vm.prank(guardian);
        v.clearBreach();
        assertEq(v.agent(), address(0), "still no agent until the owner sets one through the queue");
        _setAgent(v, agentAddr);
        vm.prank(guardian);
        v.triggerEmergency(); // breaches and revokes
        vm.prank(guardian);
        v.syncAgent();
        assertEq(v.agent(), address(0));
        _assertNoApproval(n, agentAddr);
    }

    /// @dev Every action 9 since `from` is a revoke's burn, never `agent_`.
    function _assertNoApproval(uint256 from, address agent_) internal view {
        for (uint256 i = from; i < writer.count(); ++i) {
            (, uint24 id, bytes memory body) = _decode(writer.at(i));
            if (id != 9) continue;
            (address w,) = abi.decode(body, (address, string));
            assertTrue(w != agent_, "no HyperCore approval for the agent");
        }
    }

    // ------------------------------------------------------------------
    // Platform controls
    // ------------------------------------------------------------------
    function test_OnlyPlatformAgents() public {
        address rogue = makeAddr("rogue");
        HyperVaultFactory.CreateParams memory p = _params(true, rogue);
        // signed by anyone but the registrar (or the owner): refused (round 4, V-04)
        p.agentSig = _agentSig(0xBAD, rogue, _predicted(creator, p.salt), p.agentDeadline);
        vm.prank(creator);
        usdc.approve(address(factory), SEED);
        vm.prank(creator);
        vm.expectRevert(HyperVaultFactory.BadAgentSignature.selector);
        factory.create{value: HYPE}(p, _noPermit());

        // Nor later through the vault's own timelock.
        (HyperVault v,) = _createWithPermit(true, agentAddr);
        bytes memory data = abi.encodeCall(HyperVault.setAgent, (rogue));
        vm.prank(creator);
        v.queue(data);
        vm.warp(v.queuedEta(keccak256(data)));
        vm.expectRevert(
            abi.encodeWithSelector(IHyperVaultErrors.CallFailed.selector, abi.encodeWithSelector(IHyperVaultErrors.NotPlatformAgent.selector))
        );
        v.execute(data);

        // Unregistering a live agent revokes it on its vault on the spot (audit N-07), but only a platform role
        // may do that: the registrar alone cannot stop a vault (audit I2-03).
        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(HyperVaultFactory.LiveAgent.selector, agentAddr, address(v)));
        factory.unregisterPlatformAgent(agentAddr);
        uint256 n = writer.count();
        vm.prank(sentinel);
        factory.unregisterPlatformAgent(agentAddr);
        assertFalse(factory.isPlatformAgent(agentAddr));
        assertEq(v.agent(), address(0), "revoked by the factory");
        assertEq(writer.count(), n, "WP5-D14: the revoke sends nothing to HyperCore");
        // An agent bound to another vault is refused here even through the timelock.
        address other = makeAddr("otherVaultAgent");
        vm.prank(owner); // only the cold owner may still bind a not yet existing vault (V-04)
        factory.registerPlatformAgent(other, makeAddr("someOtherVault"));
        bytes memory d2 = abi.encodeCall(HyperVault.setAgent, (other));
        vm.prank(creator);
        v.queue(d2);
        vm.warp(v.queuedEta(keccak256(d2)));
        vm.expectRevert(
            abi.encodeWithSelector(IHyperVaultErrors.CallFailed.selector, abi.encodeWithSelector(IHyperVaultErrors.NotPlatformAgent.selector))
        );
        v.execute(d2);
        // Rotation to a fresh agent bound to this vault works.
        address fresh = makeAddr("freshAgent");
        vm.prank(registrar);
        factory.registerPlatformAgent(fresh, address(v));
        bytes memory d3 = abi.encodeCall(HyperVault.setAgent, (fresh));
        vm.prank(creator);
        v.queue(d3);
        vm.warp(v.queuedEta(keccak256(d3)));
        v.execute(d3);
        assertEq(v.agent(), fresh);
    }

    /// @dev V-04: the hot registrar key can no longer pre-bind a predicted vault and block a creator's salt; a
    ///      launch carries the registrar's signature for exactly (agent, predicted vault, deadline).
    function test_V04_registrarCannotPreBindAndSignaturesAreScoped() public {
        address predicted = _predicted(creator, bytes32(uint256(1)));
        vm.prank(registrar);
        vm.expectRevert(HyperVaultFactory.NotRegistrar.selector);
        factory.registerPlatformAgent(makeAddr("squatter"), predicted);

        // A signature for another salt (another predicted vault) does not fit this launch.
        HyperVaultFactory.CreateParams memory p = _params(true, agentAddr);
        p.agentSig = _agentSig(registrarKey, agentAddr, _predicted(creator, bytes32(uint256(2))), p.agentDeadline);
        vm.prank(creator);
        usdc.approve(address(factory), type(uint256).max);
        vm.prank(creator);
        vm.expectRevert(HyperVaultFactory.BadAgentSignature.selector);
        factory.create{value: HYPE}(p, _noPermit());

        // Expired.
        p = _params(true, agentAddr);
        vm.warp(p.agentDeadline + 1);
        vm.prank(creator);
        vm.expectRevert(HyperVaultFactory.BadAgentSignature.selector);
        factory.create{value: HYPE}(p, _noPermit());

        // Valid: bound to the vault it deploys, and only once.
        p = _params(true, agentAddr);
        vm.prank(creator);
        (address va,) = factory.create{value: HYPE}(p, _noPermit());
        assertEq(factory.platformAgentFor(agentAddr), va);
        assertEq(factory.agentOfVault(va), agentAddr);
        p.salt = bytes32(uint256(3));
        p.agentSig = _agentSig(registrarKey, agentAddr, _predicted(creator, p.salt), p.agentDeadline);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HyperVaultFactory.AgentAlreadyBound.selector, agentAddr, va));
        factory.create{value: HYPE}(p, _noPermit());

        // The registrar still registers a replacement for an EXISTING vault (rotation through its timelock).
        vm.prank(registrar);
        factory.registerPlatformAgent(makeAddr("replacement"), va);
    }

    function test_RegistrarRole() public {
        address a2 = makeAddr("a2");
        address v2 = makeAddr("v2");
        vm.prank(stranger);
        vm.expectRevert(HyperVaultFactory.NotRegistrar.selector);
        factory.registerPlatformAgent(a2, v2);
        vm.prank(creator);
        vm.expectRevert(HyperVaultFactory.NotRegistrar.selector);
        factory.registerPlatformAgent(a2, v2);
        vm.prank(owner);
        factory.registerPlatformAgent(a2, v2); // owner always can
        assertTrue(factory.isPlatformAgent(a2));
        assertEq(factory.platformAgentFor(a2), v2);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HyperVaultFactory.AgentAlreadyBound.selector, a2, v2));
        factory.registerPlatformAgent(a2, makeAddr("v3")); // one agent, one vault, for good
        vm.prank(registrar);
        factory.unregisterPlatformAgent(a2);
        assertFalse(factory.isPlatformAgent(a2));
        vm.prank(stranger);
        vm.expectRevert();
        factory.setAgentRegistrar(stranger);
    }

    function test_RolesAreRotatedFromTheFactory() public {
        (HyperVault v,) = _createWithPermit(false, address(0));
        bytes memory data = abi.encodeWithSignature("setGuardian(address)", creator);
        vm.prank(creator);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        v.queue(data); // no vault level guardian setter at all
        address g2 = makeAddr("g2");
        address s2 = makeAddr("s2");
        vm.prank(owner);
        factory.setGuardian(g2);
        vm.prank(owner);
        factory.setSentinel(s2);
        assertEq(v.guardian(), g2, "rotation applies to existing vaults (audit N-06)");
        assertEq(v.sentinel(), s2);
        vm.prank(guardian);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        v.triggerBreach(); // the old key lost every power
        vm.prank(s2);
        v.triggerBreach();
        vm.prank(guardian);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        v.clearBreach();
        vm.prank(g2);
        v.clearBreach();
        assertFalse(v.breached());
    }

    function test_SentinelPowersAreRiskReducingOnly() public {
        (HyperVault v,) = _createWithPermit(true, agentAddr);
        _setCore(address(v), 10_000e6, 0, 0);
        vm.startPrank(sentinel);
        v.setDepositsPaused(true);
        v.setTradingPaused(true);
        v.cancelOrder(BTC, 1);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        v.setDepositsPaused(false);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        v.setTradingPaused(false);
        vm.expectRevert(IHyperVaultErrors.NotOverdue.selector);
        v.triggerEmergency();
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        v.flatten(BTC, 100);
        v.revokeAgent();
        assertEq(v.agent(), address(0));
        v.triggerBreach();
        assertTrue(v.breached());
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        v.clearBreach();
        vm.stopPrank();
        bytes memory data = abi.encodeCall(HyperVault.setManager, (stranger));
        vm.prank(creator);
        bytes32 id = v.queue(data);
        vm.prank(sentinel);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        v.cancel(id);
        // The cold guardian has the restoring powers.
        vm.startPrank(guardian);
        v.cancel(id);
        v.clearBreach();
        v.setDepositsPaused(false);
        v.setTradingPaused(false);
        v.triggerEmergency();
        vm.stopPrank();
        assertTrue(v.emergency());
    }

    function test_PlatformGuardianClearsBreachInstantly() public {
        (HyperVault v,) = _createWithPermit(false, address(0));
        vm.prank(guardian);
        v.triggerBreach();
        vm.prank(creator);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        v.clearBreach();
        vm.prank(guardian);
        v.clearBreach();
        assertFalse(v.breached());
    }

    function test_CuratedAssetsOnly() public {
        HyperVaultFactory.CreateParams memory p = _params(false, address(0));
        p.assets = new uint32[](1);
        p.assets[0] = DOGE;
        vm.prank(creator);
        usdc.approve(address(factory), SEED);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HyperVaultFactory.AssetNotCurated.selector, DOGE));
        factory.create{value: HYPE}(p, _noPermit());

        (, VaultPolicy pol) = _createWithPermit(false, address(0));
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(VaultPolicy.AssetNotCurated.selector, DOGE));
        pol.queueAllowAsset(DOGE);

        vm.prank(owner);
        factory.setAssetCurated(DOGE, true);
        uint32[] memory list = factory.curatedAssets();
        assertEq(list.length, 3);
        vm.prank(creator);
        pol.queueAllowAsset(DOGE);
        vm.prank(owner);
        factory.setAssetCurated(DOGE, false);
        vm.warp(pol.assetAllowEta(DOGE));
        vm.expectRevert(abi.encodeWithSelector(VaultPolicy.AssetNotCurated.selector, DOGE));
        pol.allowAsset(DOGE); // uncurated before the delay elapsed
        assertEq(factory.curatedAssets().length, 2);
    }

    function test_DepositCapBoundedByPlatformMax() public {
        HyperVaultFactory.CreateParams memory p = _params(false, address(0));
        p.depositCap = 50_001e6;
        vm.prank(creator);
        usdc.approve(address(factory), SEED);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HyperVaultFactory.CapAboveMax.selector, 50_001e6, 50_000e6));
        factory.create{value: HYPE}(p, _noPermit());
        p.depositCap = 0;
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HyperVaultFactory.CapAboveMax.selector, 0, 50_000e6));
        factory.create{value: HYPE}(p, _noPermit());

        (HyperVault v,) = _createWithPermit(false, address(0));
        vm.prank(creator);
        vm.expectRevert(IHyperVaultErrors.CapExceeded.selector);
        v.setDepositCap(60_000e6);
        vm.prank(creator);
        vm.expectRevert(IHyperVaultErrors.CapExceeded.selector);
        v.setDepositCap(0);
        vm.prank(owner);
        factory.setMaxDepositCap(100_000e6);
        vm.prank(creator);
        v.setDepositCap(60_000e6);
        assertEq(v.depositCap(), 60_000e6);
    }

    /// @dev No platform limit (2026-10-13): maxDepositCap and a vault's cap at type(uint256).max. The deposit check
    ///      `NAV + pending + deferred + assets > depositCap` never adds to the cap, so nothing overflows.
    function test_NoPlatformLimitAndNoCap() public {
        uint256 noCap = type(uint256).max;
        vm.prank(owner);
        factory.setMaxDepositCap(noCap);
        assertEq(factory.maxDepositCap(), noCap);

        HyperVaultFactory.CreateParams memory p = _params(false, address(0));
        p.depositCap = noCap;
        HyperVaultFactory.PermitData memory pd = _permit(SEED, vm.getBlockTimestamp() + 1 hours); // before the prank: it reads the token
        vm.prank(creator);
        (address va,) = factory.create{value: HYPE}(p, pd);
        HyperVault v = HyperVault(va);
        _setCoreUser(va, true);
        _setCore(va, 0, 0, 0);
        _setWithdrawable(va, 0);
        _setPosition(va, BTC, 0);
        _setPosition(va, ETH, 0);
        assertEq(v.depositCap(), noCap, "created uncapped");

        _skipBridgeWindow();
        _setCore(va, 0, 0, uint64(SEED));
        vm.prank(alice);
        usdc.approve(va, noCap);
        vm.prank(alice);
        v.requestDeposit(100e6, alice); // the cap check runs against type(uint256).max
        assertEq(v.pendingDepositAssets(), 100e6);

        // the owner can still set a lower cap, and remove it again; 0 stays refused on a factory vault
        vm.prank(creator);
        v.setDepositCap(60_000e6);
        assertEq(v.depositCap(), 60_000e6);
        vm.prank(creator);
        v.setDepositCap(noCap);
        assertEq(v.depositCap(), noCap);
        vm.prank(creator);
        vm.expectRevert(IHyperVaultErrors.CapExceeded.selector);
        v.setDepositCap(0);
    }

    function test_CreateGasUnderSmallBlock() public {
        HyperVaultFactory.PermitData memory pd = _permit(SEED, vm.getBlockTimestamp() + 1 hours);
        HyperVaultFactory.CreateParams memory p = _params(true, agentAddr);
        vm.prank(creator);
        uint256 g = gasleft();
        factory.create{value: HYPE}(p, pd);
        uint256 used = g - gasleft();
        emit log_named_uint("create gas (permit + agent + seed + hype)", used);
        assertLt(used, 1_800_000, "must fit a HyperEVM small block");
    }

    function test_EmitsVaultCreated() public {
        HyperVaultFactory.PermitData memory pd = _permit(SEED, vm.getBlockTimestamp() + 1 hours);
        address predicted = factory.predictVaultAddress(creator, bytes32(uint256(1)));
        vm.expectEmit(true, false, true, false);
        emit HyperVaultFactory.VaultCreated(
            predicted, address(0), creator, creator, agentAddr, true, 3_300, bytes32(uint256(1))
        );
        vm.prank(creator);
        factory.create{value: HYPE}(_params(true, agentAddr), pd);
    }

    function test_MinSeedAndMinHypeEnforced() public {
        HyperVaultFactory.CreateParams memory p = _params(false, address(0));
        p.seedUsdc = 1e6;
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HyperVaultFactory.SeedTooSmall.selector, 1e6, 2e6));
        factory.create{value: HYPE}(p, _noPermit());

        p.seedUsdc = SEED;
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HyperVaultFactory.HypeTooSmall.selector, 0.001 ether, 0.01 ether));
        factory.create{value: 0.001 ether}(p, _noPermit());
    }

    function test_SaltIsScopedPerCreator() public view {
        assertTrue(
            factory.predictVaultAddress(creator, bytes32(0)) != factory.predictVaultAddress(stranger, bytes32(0))
        );
    }

    // ------------------------------------------------------------------
    // Allowlist
    // ------------------------------------------------------------------
    function test_ClosedLaunchRejectsNonAllowlisted() public {
        usdc.mint(stranger, 10e6);
        vm.deal(stranger, 1 ether);
        vm.startPrank(stranger);
        usdc.approve(address(factory), SEED);
        vm.expectRevert(HyperVaultFactory.LaunchClosed.selector);
        factory.create{value: HYPE}(_params(false, address(0)), _noPermit());
        vm.stopPrank();

        vm.prank(owner);
        factory.setOpenLaunch(true);
        vm.prank(stranger);
        (address va,) = factory.create{value: HYPE}(_params(false, address(0)), _noPermit());
        assertTrue(factory.isVault(va));
    }

    function test_AllowlistEvents() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit HyperVaultFactory.LauncherAllowed(stranger, true);
        factory.setLauncherAllowed(stranger, true);
        assertTrue(factory.canLaunch(stranger));

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit HyperVaultFactory.OpenLaunchSet(true);
        factory.setOpenLaunch(true);

        vm.prank(stranger);
        vm.expectRevert();
        factory.setOpenLaunch(false);
    }

    // ------------------------------------------------------------------
    // Fee split per vault
    // ------------------------------------------------------------------
    function _earnFees(HyperVault v) internal {
        _skipBridgeWindow();
        _setCore(address(v), 0, 0, uint64(SEED)); // the seed has landed in Core spot
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        vm.prank(alice);
        v.requestDeposit(1_000e6, alice);
        v.checkRisk();
        vm.prank(creator);
        v.settle();
        v.claim(alice);

        vm.prank(creator);
        v.bridgeToCore(1_000e6);
        vm.roll(vm.getBlockNumber() + 301); // round 4: the mock books it into perp, not a landing (spot only): wait the cap
        _setCore(address(v), 1_100e6, 0, uint64(SEED)); // +100 profit on top of the seed
        v.checkRisk();
        vm.prank(creator);
        v.settle();
    }

    function test_BaseShare10Percent() public {
        (HyperVault v,) = _createWithPermit(false, address(0));
        _earnFees(v);
        uint256 total = v.convertToAssets(v.balanceOf(creator) + v.balanceOf(treasury));
        assertApproxEqAbs(total, 20e6, 1e4, "20% perf fee on 100 profit");
        assertApproxEqAbs(v.convertToAssets(v.balanceOf(treasury)), 2e6, 1e4, "10% of fees");
    }

    function test_HostedShare33Percent() public {
        (HyperVault v,) = _createWithPermit(true, agentAddr);
        assertEq(v.protocolShareBps(), 3_300);
        _earnFees(v);
        uint256 total = v.convertToAssets(v.balanceOf(creator) + v.balanceOf(treasury));
        assertApproxEqAbs(total, 20e6, 1e4);
        assertApproxEqAbs(v.convertToAssets(v.balanceOf(treasury)), 6.6e6, 1e4, "33% of fees");
    }

    function test_FactoryRateChangesDoNotTouchExistingVaults() public {
        (HyperVault v,) = _createWithPermit(true, agentAddr);
        vm.prank(owner);
        factory.setShares(2_000, 5_000);
        assertEq(v.protocolShareBps(), 3_300, "locked at creation");
        assertEq(v.baseShareBps(), 1_000);
        _earnFees(v);
        assertApproxEqAbs(v.convertToAssets(v.balanceOf(treasury)), 6.6e6, 1e4, "still 33%");

        // New vaults get the new rates.
        HyperVaultFactory.CreateParams memory p = _params(true, address(0));
        p.salt = bytes32(uint256(2));
        vm.prank(creator);
        usdc.approve(address(factory), SEED);
        vm.prank(creator);
        (address v2,) = factory.create{value: HYPE}(p, _noPermit());
        assertEq(HyperVault(v2).protocolShareBps(), 5_000);
        assertEq(HyperVault(v2).baseShareBps(), 2_000);
    }

    function test_RecipientIsReadLive() public {
        (HyperVault v,) = _createWithPermit(false, address(0));
        address newTreasury = makeAddr("newTreasury");
        vm.prank(owner);
        factory.setProtocolFeeRecipient(newTreasury);
        _earnFees(v);
        assertEq(v.balanceOf(treasury), 0);
        assertGt(v.balanceOf(newTreasury), 0);
    }

    function test_ShareCapIsFiftyPercent() public {
        vm.prank(owner);
        vm.expectRevert(HyperVaultFactory.InvalidShare.selector);
        factory.setShares(1_000, 5_001);
    }

    // ------------------------------------------------------------------
    // leaveHosted
    // ------------------------------------------------------------------
    function test_LeaveHosted() public {
        (HyperVault v,) = _createWithPermit(true, agentAddr);
        uint256 n = writer.count();

        vm.prank(stranger);
        vm.expectRevert();
        v.leaveHosted();

        vm.prank(creator);
        vm.expectEmit(false, false, false, true);
        emit IHyperVaultEvents.LeftHosted(1_000);
        v.leaveHosted();

        assertFalse(v.hosted());
        assertEq(v.protocolShareBps(), 1_000, "dropped to base");
        assertEq(v.agent(), address(0), "agent revoked");
        assertEq(writer.count(), n, "WP5-D14: the revoke sends nothing to HyperCore");

        // One way.
        vm.prank(creator);
        vm.expectRevert(IHyperVaultErrors.NotHosted.selector);
        v.leaveHosted();

        // Fees now split at 10%.
        _earnFees(v);
        assertApproxEqAbs(v.convertToAssets(v.balanceOf(treasury)), 2e6, 1e4, "10% after leaving");
    }

    function test_LeaveHostedRevertsOnNonHosted() public {
        (HyperVault v,) = _createWithPermit(false, address(0));
        vm.prank(creator);
        vm.expectRevert(IHyperVaultErrors.NotHosted.selector);
        v.leaveHosted();
    }

    function test_LeaveHostedNeverRaisesALoweredShare() public {
        (HyperVault v,) = _createWithPermit(true, agentAddr);
        vm.prank(owner);
        factory.lowerProtocolShare(address(v), 500); // below base
        vm.prank(creator);
        v.leaveHosted();
        assertEq(v.protocolShareBps(), 500, "stays at the lowered value");
    }

    // ------------------------------------------------------------------
    // lowerProtocolShare
    // ------------------------------------------------------------------
    function test_LowerProtocolShareOnlyLowers() public {
        (HyperVault v,) = _createWithPermit(true, agentAddr);

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit HyperVaultFactory.ProtocolShareLowered(address(v), 2_000);
        factory.lowerProtocolShare(address(v), 2_000);
        assertEq(v.protocolShareBps(), 2_000);

        vm.prank(owner);
        vm.expectRevert(IHyperVaultErrors.InvalidShare.selector);
        factory.lowerProtocolShare(address(v), 2_500);

        vm.prank(owner);
        vm.expectRevert(IHyperVaultErrors.InvalidShare.selector);
        factory.lowerProtocolShare(address(v), 2_000);

        // Only through the factory, only by its owner.
        vm.prank(creator);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        v.lowerProtocolShare(100);
        vm.prank(creator);
        vm.expectRevert();
        factory.lowerProtocolShare(address(v), 100);
        vm.prank(owner);
        vm.expectRevert(HyperVaultFactory.NotAVault.selector);
        factory.lowerProtocolShare(address(vault), 100);
    }

    // ------------------------------------------------------------------
    // fundCoreGas
    // ------------------------------------------------------------------
    function test_FundCoreGasForwardsValue() public {
        (HyperVault v,) = _createWithPermit(false, address(0));
        uint256 before = hypeSink.received();
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectEmit(true, false, false, true);
        emit IHyperVaultEvents.CoreGasFunded(stranger, 0.05 ether);
        v.fundCoreGas{value: 0.05 ether}();
        assertEq(hypeSink.received() - before, 0.05 ether);
        assertEq(hypeSink.lastSender(), address(v));
        assertEq(address(v).balance, 0);

        vm.prank(stranger);
        vm.expectRevert(IHyperVaultErrors.ZeroAmount.selector);
        v.fundCoreGas();
    }

    function test_PlainTransferToVaultReverts() public {
        (HyperVault v,) = _createWithPermit(false, address(0));
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(v).call{value: 1}("");
        assertFalse(ok, "no receive(): HYPE must go through fundCoreGas");
    }

    // ------------------------------------------------------------------
    // Behaviour of a factory vault matches a standalone one
    // ------------------------------------------------------------------
    function test_FactoryVaultTradesUnderPolicy() public {
        (HyperVault v,) = _createWithPermit(false, address(0));
        _setCore(address(v), 10_000e6, 0, 0);
        vm.prank(creator);
        v.placeOrder(BTC, true, 100_500e8, 0.01e8, false, HyperCore.TIF_GTC, 1);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IHyperVaultErrors.OrderRejected.selector, "asset not allowed"));
        v.placeOrder(DOGE, true, 0.2e8, 100e8, false, 2, 0);
    }
}
