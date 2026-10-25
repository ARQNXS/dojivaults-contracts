// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GainsBase} from "./GainsBase.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {GainsVault} from "../../src/gains/GainsVault.sol";
import {GainsVaultLens} from "../../src/gains/GainsVaultLens.sol";
import {GainsVaultPolicy} from "../../src/gains/GainsVaultPolicy.sol";
import {GainsVaultFactory} from "../../src/gains/GainsVaultFactory.sol";
import {GainsPrice} from "../../src/gains/GainsPrice.sol";
import {IGainsDiamond} from "../../src/gains/IGainsDiamond.sol";
import {IGainsVaultErrors, IGainsVaultEvents, InitParams, OpenParams} from "../../src/gains/GainsTypes.sol";
import {MockChainlinkFeed} from "./mocks/GainsMocks.sol";

/// @notice Mirrors test/PolicyAndFactory.t.sol for the Gains contracts. PxMath has no Gains counterpart (Gains takes
///         1e10 prices as is); the seed bridge, syncAgent and fundCoreGas tests become seed-is-idle and agent-gas tests.
contract GainsPolicyTest is GainsBase {
    function test_TighteningIsImmediate() public {
        GainsVaultPolicy.RiskConfig memory c = _defaultRisk();
        c.maxLeverageBps = 20_000;
        vm.prank(owner);
        policy.proposeConfig(c);
        assertEq(policy.maxLeverageBps(), 20_000);
    }

    function test_LooseningIsTimelocked() public {
        GainsVaultPolicy.RiskConfig memory c = _defaultRisk();
        c.maxLeverageBps = 50_000;
        vm.prank(owner);
        policy.proposeConfig(c);
        assertEq(policy.maxLeverageBps(), 30_000);

        vm.expectRevert(GainsVaultPolicy.NotReady.selector);
        policy.applyPendingConfig();

        _warp(uint256(policy.pendingConfig().eta)); // hl-r2 exit-before-effect: wait for the stored eta
        policy.applyPendingConfig();
        assertEq(policy.maxLeverageBps(), 50_000);
    }

    function test_MixedChangeIsTimelocked() public {
        GainsVaultPolicy.RiskConfig memory c = _defaultRisk();
        c.maxLeverageBps = 10_000;
        c.maxDailyLossBps = 900;
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
        vm.expectRevert(GainsVaultPolicy.NotReady.selector);
        policy.allowAsset(ETH);
        _warp(policy.assetAllowEta(ETH)); // hl-r2 exit-before-effect: wait for the stored eta
        policy.allowAsset(ETH);
        assertTrue(policy.isAssetAllowed(ETH));

        uint32[] memory list = policy.allowedAssets();
        assertEq(list.length, 2);
    }

    function test_PairIndexOutOfRangeRejected() public {
        vm.prank(owner);
        vm.expectRevert(GainsVaultPolicy.InvalidPair.selector);
        policy.queueAllowAsset(70_000);
    }

    function test_InvalidConfigRejected() public {
        GainsVaultPolicy.RiskConfig memory c = _defaultRisk();
        c.maxSlippageBps = 5_000;
        vm.prank(owner);
        vm.expectRevert(GainsVaultPolicy.InvalidConfig.selector);
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
        GainsVaultPolicy.RiskConfig memory c = _defaultRisk();
        c.maxLeverageBps = 50_000;
        vm.prank(owner);
        policy.proposeConfig(c);
        _warp(uint256(policy.pendingConfig().eta) + policy.GRACE_PERIOD() + 1); // hl-r2 exit-before-effect: wait for the stored eta
        vm.expectRevert(GainsVaultPolicy.Expired.selector);
        policy.applyPendingConfig();
    }

    function test_NewFieldsAreTightenOnly() public {
        GainsVaultPolicy.RiskConfig memory c = _defaultRisk();
        c.maxNavMoveBps = 3_000;
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
        vm.expectRevert(GainsVaultPolicy.InvalidConfig.selector);
        policy.proposeConfig(c);
        c.maxNavMoveBps = 500;
        c.maxFlattenSlippageBps = 2_001;
        vm.prank(owner);
        vm.expectRevert(GainsVaultPolicy.InvalidConfig.selector);
        policy.proposeConfig(c);
    }

    function test_CheckpointRule() public {
        (uint256 n, bool upd) = policy.nextCheckpoint(0, 0, 1_000e6, false);
        assertEq(n, 1_000e6);
        assertTrue(upd);
        vm.expectRevert(GainsVaultPolicy.StaleCheckpoint.selector);
        policy.nextCheckpoint(0, 0, 1_000e6, true);
        (n, upd) = policy.nextCheckpoint(0, vm.getBlockTimestamp(), 5_000e6, true);
        assertEq(n, 5_000e6);
        assertTrue(upd);
        uint256 at = vm.getBlockTimestamp();
        (, upd) = policy.nextCheckpoint(1_000e6, at, 5_000e6, false);
        assertFalse(upd);
        vm.warp(at + 1 hours);
        (n, upd) = policy.nextCheckpoint(1_000e6, at, 5_000e6, false);
        assertEq(n, 1_200e6);
        (n,) = policy.nextCheckpoint(1_000e6, at, 100e6, false);
        assertEq(n, 800e6);
        (n,) = policy.nextCheckpoint(1_000e6, at, 1_050e6, false);
        assertEq(n, 1_050e6);
        (n, upd) = policy.nextCheckpoint(1_000e6, at, 1_200e6, true);
        assertEq(n, 1_200e6);
        vm.expectRevert(abi.encodeWithSelector(GainsVaultPolicy.NavMoved.selector, 1_201e6, 1_000e6));
        policy.nextCheckpoint(1_000e6, at, 1_201e6, true);
        vm.warp(at + 1 days + 1);
        vm.expectRevert(GainsVaultPolicy.StaleCheckpoint.selector);
        policy.nextCheckpoint(1_000e6, at, 1_000e6, true);
    }

    function test_FlattenSlippageCapsCustomSlippage() public {
        vm.expectRevert(GainsVaultPolicy.SlippageTooHigh.selector);
        policy.flattenSlippage(301);
        assertEq(policy.flattenSlippage(300), 3_000, "3% in Gains precision");
        assertEq(policy.flattenSlippage(0), 1_000, "policy band");
    }

    function test_PolicyCloneCannotReinitialize() public {
        uint32[] memory assets = new uint32[](1);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        policy.initialize(owner, _defaultRisk(), assets, 2 days, address(platform), address(vault));
    }

    function test_PolicyImplementationCannotInitialize() public {
        uint32[] memory assets = new uint32[](1);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        policyImpl.initialize(owner, _defaultRisk(), assets, 2 days, address(platform), address(vault));
    }

    // ------------------------------------------------------------------
    // Gains: NAV error bound on vault leverage (PLAN.md 4.3), prices
    // ------------------------------------------------------------------
    function test_NavBoundTable() public view {
        // maxLeverage <= maxNavMoveBps / (8 x band): the PLAN.md 4.3 table, in bps of vault leverage.
        assertEq(policy.navBoundLeverageBps(BTC, 500), 31_250, "BTC 3.1x at the minimum maxNavMoveBps");
        assertEq(policy.navBoundLeverageBps(ETH, 2_000), 125_000, "ETH 12.5x at the default");
    }

    function test_NavBoundOnInitConfigAndAllowlist() public {
        uint32[] memory assets = new uint32[](1);
        assets[0] = SOL;
        GainsVaultPolicy.RiskConfig memory c = _defaultRisk();
        c.maxLeverageBps = 100_001; // SOL: 2000 / (8 x 25 bps) = 10x
        GainsVaultPolicy p = GainsVaultPolicy(Clones.clone(address(policyImpl)));
        vm.expectRevert(abi.encodeWithSelector(GainsVaultPolicy.LeverageAboveNavBound.selector, SOL));
        p.initialize(owner, c, assets, 2 days, address(platform), address(vault));
        c.maxLeverageBps = 100_000;
        p.initialize(owner, c, assets, 2 days, address(platform), address(vault));
        assertEq(p.maxLeverageBps(), 100_000);

        // A loosening of maxNavMoveBps (lowering it) must keep the bound, queued and at apply.
        c.maxNavMoveBps = 1_000; // SOL bound drops to 5x
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GainsVaultPolicy.LeverageAboveNavBound.selector, SOL));
        p.proposeConfig(c);
        c.maxLeverageBps = 50_000;
        vm.prank(owner);
        p.proposeConfig(c); // leverage tighter, nav move looser: queued
        assertEq(p.maxLeverageBps(), 100_000);
        _warp(uint256(p.pendingConfig().eta)); // hl-r2 exit-before-effect: wait for the stored eta
        p.applyPendingConfig();
        assertEq(p.maxLeverageBps(), 50_000);

        // Allowing a pair checks the bound under the current config: BTC at 20 bps allows 6.25x at 1000.
        GainsVaultPolicy.RiskConfig memory d = c;
        d.maxLeverageBps = 60_000;
        d.maxNavMoveBps = 2_000;
        vm.prank(owner);
        p.proposeConfig(d); // queued (looser leverage)
        _warp(uint256(p.pendingConfig().eta)); // hl-r2 exit-before-effect: wait for the stored eta
        p.applyPendingConfig(); // SOL at 2000: 10x >= 6x, fine
        vm.prank(owner);
        p.queueAllowAsset(BTC);
        _warp(p.assetAllowEta(BTC)); // hl-r2 exit-before-effect: wait for the stored eta
        p.allowAsset(BTC); // BTC 12.5x >= 6x
        assertTrue(p.isAssetAllowed(BTC));
    }

    function test_PriceReadsAndNamedErrors() public {
        assertEq(policy.price(ETH), 3_000e10);
        (uint64 px, uint16 band) = policy.navPrice(BTC);
        assertEq(px, 100_000e10);
        assertEq(band, 20);

        // Stale: past maxAge (heartbeat + margin).
        vm.warp(vm.getBlockTimestamp() + BTC_MAX_AGE + 1);
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.PriceStale.selector, uint256(ETH)));
        policy.price(ETH);
        _warp(vm.getBlockTimestamp());
        // Broken feed, zero or negative answer.
        ethFeed.setReverts(true);
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.PriceStale.selector, uint256(ETH)));
        policy.price(ETH);
        ethFeed.setReverts(false);
        ethFeed.set(0, vm.getBlockTimestamp());
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.PriceStale.selector, uint256(ETH)));
        policy.price(ETH);
        _setPrice(ETH, 3_000e10);
        // No feed for a pair this policy never allowed.
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.NoPriceFeed.selector, uint256(SOL)));
        policy.price(SOL);

        // Sequencer down, then inside the grace period after it came back.
        sequencer.setStatus(1, vm.getBlockTimestamp());
        vm.expectRevert(GainsPrice.SequencerDown.selector);
        policy.price(ETH);
        sequencer.setStatus(0, vm.getBlockTimestamp() - SEQ_GRACE);
        vm.expectRevert(GainsPrice.SequencerDown.selector);
        policy.price(ETH);
        sequencer.setStatus(0, vm.getBlockTimestamp() - SEQ_GRACE - 1);
        assertEq(policy.price(ETH), 3_000e10);
    }

    function test_SolKeepsItsLongHeartbeat() public {
        uint32[] memory assets = new uint32[](1);
        assets[0] = SOL;
        GainsVaultPolicy p = GainsVaultPolicy(Clones.clone(address(policyImpl)));
        p.initialize(owner, _defaultRisk(), assets, 2 days, address(platform), address(vault));
        vm.warp(vm.getBlockTimestamp() + 86_400); // a day without an update: inside SOL's heartbeat
        assertEq(p.price(SOL), 150e10);
        vm.warp(vm.getBlockTimestamp() + 1_801);
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.PriceStale.selector, uint256(SOL)));
        p.price(SOL);
    }

    function test_FeedSnapshotIsTheVaults() public {
        // The factory owner re-points ETH: an existing policy keeps the feed it copied (PLAN.md 4.3).
        MockChainlinkFeed rogue = new MockChainlinkFeed(8, 9_999e8);
        vm.prank(platformOwner);
        platform.setAssetCurated(ETH, true, address(rogue), BTC_MAX_AGE, 20);
        assertEq(policy.price(ETH), 3_000e10);
        assertEq(policy.feedOf(ETH).feed, address(ethFeed));
        // Only a re-allowlisting through the policy's own timelock picks it up.
        vm.prank(owner);
        policy.disallowAsset(ETH);
        vm.prank(owner);
        policy.queueAllowAsset(ETH);
        _warp(policy.assetAllowEta(ETH)); // hl-r2 exit-before-effect: wait for the stored eta
        rogue.set(9_999e8, vm.getBlockTimestamp());
        policy.allowAsset(ETH);
        assertEq(policy.price(ETH), 9_999e10);
    }
}

contract GainsCloneInitTest is GainsBase {
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
        emit log_named_uint("GainsVault runtime bytes", size);
        assertLe(size, 24_576);
        assertLe(address(policyImpl).code.length, 24_576);
        assertLe(address(lens).code.length, 24_576);
        assertLe(address(platform).code.length, 24_576);
        assertGe(24_576 - size, 1_500, "keep at least 1.5 KB of headroom in the vault");
    }

    function test_AssetMustBeAnActiveDiamondCollateral() public {
        InitParams memory p = _standaloneParams(policy);
        p.asset = IERC20(makeAddr("notUsdc"));
        GainsVault other = GainsVault(Clones.clone(address(vaultImpl)));
        vm.mockCall(address(p.asset), abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        vm.expectRevert(IGainsVaultErrors.UnsupportedAsset.selector);
        other.initialize(p);
        assertEq(vault.collateralIndex(), 3);
        assertEq(address(vault.diamond()), address(diamond));
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
        assertEq(lens.previewDeposit(vault, 1e6), vault.previewDeposit(1e6));
        assertEq(lens.previewRedeem(vault, 1e12), vault.previewRedeem(1e12));
    }

    function test_LensPreviewIncludesPendingFees() public {
        _deposit(alice, 1_000e6);
        _settle();
        _skip(365 days);
        (uint256 feeShares,) = lens.pendingFeeShares(vault);
        assertGt(feeShares, 0);
        assertGt(lens.previewDeposit(vault, 1e6), vault.previewDeposit(1e6), "fee shares dilute the price");
        GainsVaultLens.Status memory st = lens.status(vault);
        assertEq(st.pendingFeeShares, feeShares);
        assertLt(st.sharePriceAfterFees, st.sharePrice);
        assertFalse(st.ordersPending);
        assertEq(st.openPositions, 0);
        assertEq(st.risk.maxNavMoveBps, 2_000);
        assertEq(st.guardian, guardian);
        vm.prank(guardian);
        vault.triggerEmergency();
        assertEq(lens.previewDeposit(vault, 1e6), 0);
        assertEq(lens.previewMint(vault, 1e12), 0);
        assertGt(lens.previewRedeem(vault, 1e12), 0);
    }

    function test_LensStatusShowsTheVenue() public {
        _deposit(alice, 10_000e6);
        _settle();
        _open(vault, ETH, true, 1_000e6, 5_000);
        _request(vault, BTC, false, 1_000e6, 2_000);
        GainsVaultLens.Status memory st = lens.status(vault);
        assertTrue(st.ordersPending);
        assertEq(st.openPositions, 2);
        assertApproxEqAbs(st.openNotional, 7_000e6, 1);
        assertEq(st.totalAssets, vault.totalAssets());
        assertEq(st.venueValue, vault.venue().value);
    }

    function test_VaultRefusesAPolicyBoundToAnotherVault() public {
        GainsVault other = GainsVault(Clones.clone(address(vaultImpl)));
        vm.expectRevert(IGainsVaultErrors.PolicyMismatch.selector);
        other.initialize(_standaloneParams(policy)); // policy names `vault`
        uint32[] memory assets = new uint32[](1);
        GainsVaultPolicy p = GainsVaultPolicy(Clones.clone(address(policyImpl)));
        vm.expectRevert(GainsVaultPolicy.ZeroAddress.selector);
        p.initialize(owner, _defaultRisk(), assets, 2 days, address(platform), address(0));
    }

    function test_CloneStateIsIndependent() public {
        GainsVault other = GainsVault(Clones.clone(address(vaultImpl)));
        uint32[] memory assets = new uint32[](1);
        GainsVaultPolicy op = GainsVaultPolicy(Clones.clone(address(policyImpl)));
        op.initialize(owner, _defaultRisk(), assets, 2 days, address(platform), address(other));
        InitParams memory p = _standaloneParams(op);
        p.name = "Other";
        p.managementFeeBps = 0;
        other.initialize(p);
        assertEq(other.name(), "Other");
        assertEq(vault.name(), "DojiPad Gains Vault");
        assertEq(other.managementFeeBps(), 0);
        assertEq(vault.managementFeeBps(), 200);
        assertEq(other.decimals(), 12);
        assertEq(other.asset(), address(usdc));
    }
}

contract GainsFactoryTest is GainsBase {
    GainsVaultFactory internal factory;
    address internal treasury = makeAddr("treasury");
    address internal agentAddr = makeAddr("agent");
    address internal registrar = makeAddr("registrar");
    uint256 internal registrarKey = uint256(keccak256(abi.encodePacked("registrar")));

    uint256 internal creatorKey = 0xA11CE;
    address internal creator;

    uint256 internal constant SEED = 1e6;
    uint256 internal constant GAS = 0.001 ether;

    function setUp() public override {
        super.setUp();
        creator = vm.addr(creatorKey);
        factory = new GainsVaultFactory(
            owner,
            address(vaultImpl),
            address(policyImpl),
            IERC20(address(usdc)),
            IGainsDiamond(address(diamond)),
            address(sequencer),
            SEQ_GRACE,
            treasury,
            guardian,
            sentinel
        );
        vm.startPrank(owner);
        factory.setLauncherAllowed(creator, true);
        factory.setAssetCurated(BTC, true, address(btcFeed), BTC_MAX_AGE, 20);
        factory.setAssetCurated(ETH, true, address(ethFeed), BTC_MAX_AGE, 20);
        factory.setAgentRegistrar(registrar);
        vm.stopPrank();
        // GR2-KEY-01b: a pair never set takes no new exposure on factory vaults
        vm.startPrank(guardian);
        factory.setPairSkewCap(BTC, 100);
        factory.setPairSkewCap(ETH, 100);
        vm.stopPrank();
        usdc.mint(creator, 1_000e6);
        vm.deal(creator, 10 ether);
    }

    function _cparams(bool hosted, address agent_) internal view returns (GainsVaultFactory.CreateParams memory p) {
        uint32[] memory assets = new uint32[](2);
        assets[0] = BTC;
        assets[1] = ETH;
        p = GainsVaultFactory.CreateParams({
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

    function _gas(address agent_) internal pure returns (uint256) {
        return agent_ == address(0) ? 0 : GAS;
    }

    function _predicted(address creator_, bytes32 salt) internal view returns (address) {
        return Clones.predictDeterministicAddress(address(vaultImpl), keccak256(abi.encode(creator_, salt)), address(factory));
    }

    function _agentSig(uint256 key, address agent_, address vault_, uint256 deadline) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encode("DojiPad platform agent", block.chainid, address(factory), agent_, vault_, deadline));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, MessageHashUtils.toEthSignedMessageHash(digest));
        return abi.encodePacked(r, s, v);
    }

    function _noPermit() internal pure returns (GainsVaultFactory.PermitData memory) {
        return GainsVaultFactory.PermitData(0, 0, 0, bytes32(0), bytes32(0));
    }

    function _permit(uint256 value, uint256 deadline) internal view returns (GainsVaultFactory.PermitData memory) {
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
        return GainsVaultFactory.PermitData(value, deadline, v, r, s);
    }

    function _createWithPermit(bool hosted, address agent_) internal returns (GainsVault v, GainsVaultPolicy p) {
        GainsVaultFactory.PermitData memory pd = _permit(SEED, vm.getBlockTimestamp() + 1 hours);
        GainsVaultFactory.CreateParams memory cp = _cparams(hosted, agent_);
        vm.prank(creator);
        (address va, address pa) = factory.create{value: _gas(agent_)}(cp, pd);
        v = GainsVault(va);
        p = GainsVaultPolicy(pa);
    }

    // ------------------------------------------------------------------
    // Creation
    // ------------------------------------------------------------------
    function test_CreateWithPermit() public {
        address predicted = factory.predictVaultAddress(creator, bytes32(uint256(1)));
        (GainsVault v, GainsVaultPolicy p) = _createWithPermit(false, address(0));
        assertEq(address(v), predicted, "deterministic address");
        assertTrue(factory.isVault(address(v)));
        assertEq(factory.policyOf(address(v)), address(p));
        assertEq(address(v.policy()), address(p));
        assertEq(v.factory(), address(factory));
        assertEq(v.owner(), creator);
        assertEq(p.owner(), creator);
        assertEq(v.guardian(), guardian);
        assertEq(v.sentinel(), sentinel);
        assertEq(p.factory(), address(factory));
        assertEq(p.sequencerFeed(), address(sequencer));
        assertEq(p.sequencerGracePeriod(), SEQ_GRACE);
        assertEq(p.feedOf(ETH).feed, address(ethFeed));
        assertEq(p.feedOf(ETH).decimals, 8);
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
        GainsVaultFactory.CreateParams memory cp = _cparams(false, address(0));
        vm.prank(creator);
        (address va,) = factory.create(cp, _noPermit());
        assertTrue(factory.isVault(va));
    }

    function test_CreateWithoutAllowanceReverts() public {
        GainsVaultFactory.CreateParams memory cp = _cparams(false, address(0));
        vm.prank(creator);
        vm.expectRevert();
        factory.create(cp, _noPermit());
    }

    function test_FrontRunPermitDoesNotBrickCreate() public {
        GainsVaultFactory.PermitData memory pd = _permit(SEED, vm.getBlockTimestamp() + 1 hours);
        usdc.permit(creator, address(factory), pd.value, pd.deadline, pd.v, pd.r, pd.s);
        GainsVaultFactory.CreateParams memory cp = _cparams(false, address(0));
        vm.prank(creator);
        (address va,) = factory.create(cp, pd);
        assertTrue(factory.isVault(va));
    }

    function test_SeedIsIdleAndAgentGasForwarded() public {
        uint256 agentBefore = agentAddr.balance;
        (GainsVault v,) = _createWithPermit(true, agentAddr);
        assertEq(usdc.balanceOf(creator), 1_000e6 - SEED);
        assertEq(usdc.balanceOf(address(v)), SEED, "the seed is idle USDC in the vault");
        assertEq(v.totalAssets(), SEED);
        assertEq(agentAddr.balance - agentBefore, GAS, "ETH for Arbitrum gas goes to the bound agent");
        assertEq(address(v).balance, 0);
        assertEq(address(factory).balance, 0);
    }

    function test_SeedIsNavNotShares() public {
        (GainsVault v,) = _createWithPermit(false, address(0));
        assertEq(v.totalSupply(), 0, "no shares for the seed");
        assertEq(v.totalAssets(), SEED, "seed is NAV");
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        vm.prank(alice);
        v.requestDeposit(100e6, alice);
        _ageEpoch(v);
        v.checkRisk();
        vm.prank(creator);
        v.settle();
        v.claim(alice);
        assertEq(v.balanceOf(alice), 100e6 * 1e6, "first mint unaffected by the seed");
        assertApproxEqAbs(v.convertToAssets(v.balanceOf(alice)), 101e6, 1, "seed accrues to the first depositor");
    }

    function test_PreviewMatchesFirstSettleOnSeededVault() public {
        (GainsVault v,) = _createWithPermit(false, address(0));
        assertEq(v.totalSupply(), 0);
        assertGt(v.totalAssets(), 0);
        uint256 preview = v.previewDeposit(100e6);
        assertEq(preview, v.convertToShares(100e6));
        assertEq(preview, 100e6 * 1e6, "first mint rule");
        assertEq(v.previewMint(preview), 100e6);
        assertEq(v.convertToAssets(preview), 100e6);
        assertEq(v.sharePrice(), 1e6);

        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        vm.prank(alice);
        v.requestDeposit(100e6, alice);
        _ageEpoch(v);
        v.checkRisk();
        vm.prank(creator);
        v.settle();
        v.claim(alice);
        assertEq(v.balanceOf(alice), preview, "preview == minted");
        assertLt(v.previewDeposit(100e6), preview, "after the first mint the seed is priced in");
    }

    function test_AgentBoundAtInitTradesThroughTheVault() public {
        (GainsVault v,) = _createWithPermit(true, agentAddr);
        assertEq(v.agent(), agentAddr, "recorded and live: no venue-side approval exists on Gains");
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        vm.prank(alice);
        v.requestDeposit(10_000e6, alice);
        _ageEpoch(v);
        v.checkRisk();
        vm.prank(creator);
        v.settle();
        vm.prank(agentAddr);
        v.openTrade(_params(ETH, true, 1_000e6, 2_000));
        assertEq(diamond.getPendingOrders(address(v)).length, 1);
        assertEq(diamond.getTradingDelegate(address(v)), address(0), "never a Gains delegate (decision D1)");
    }

    function test_AgentGasRules() public {
        GainsVaultFactory.CreateParams memory p = _cparams(true, agentAddr);
        vm.prank(creator);
        usdc.approve(address(factory), type(uint256).max);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(GainsVaultFactory.AgentGasTooSmall.selector, GAS - 1, GAS));
        factory.create{value: GAS - 1}(p, _noPermit());
        // Manual mode (no agent) sends no ETH: nobody would receive it.
        p = _cparams(false, address(0));
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(GainsVaultFactory.AgentGasTooSmall.selector, 1, GAS));
        factory.create{value: 1}(p, _noPermit());
    }

    // ------------------------------------------------------------------
    // Platform controls
    // ------------------------------------------------------------------
    function test_OnlyPlatformAgents() public {
        address rogue = makeAddr("rogue");
        GainsVaultFactory.CreateParams memory p = _cparams(true, rogue);
        p.agentSig = _agentSig(0xBAD, rogue, _predicted(creator, p.salt), p.agentDeadline);
        vm.prank(creator);
        usdc.approve(address(factory), SEED);
        vm.prank(creator);
        vm.expectRevert(GainsVaultFactory.BadAgentSignature.selector);
        factory.create{value: GAS}(p, _noPermit());

        (GainsVault v,) = _createWithPermit(true, agentAddr);
        bytes memory data = abi.encodeCall(GainsVault.setAgent, (rogue));
        vm.prank(creator);
        v.queue(data);
        _warp(v.queuedEta(keccak256(data))); // hl-r2 exit-before-effect: wait for the stored eta
        vm.expectRevert(
            abi.encodeWithSelector(IGainsVaultErrors.CallFailed.selector, abi.encodeWithSelector(IGainsVaultErrors.NotPlatformAgent.selector))
        );
        v.execute(data);

        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(GainsVaultFactory.LiveAgent.selector, agentAddr, address(v)));
        factory.unregisterPlatformAgent(agentAddr);
        vm.prank(sentinel);
        factory.unregisterPlatformAgent(agentAddr);
        assertFalse(factory.isPlatformAgent(agentAddr));
        assertEq(v.agent(), address(0), "revoked by the factory");

        address other = makeAddr("otherVaultAgent");
        vm.prank(owner);
        factory.registerPlatformAgent(other, makeAddr("someOtherVault"));
        bytes memory d2 = abi.encodeCall(GainsVault.setAgent, (other));
        vm.prank(creator);
        v.queue(d2);
        _warp(v.queuedEta(keccak256(d2))); // hl-r2 exit-before-effect: wait for the stored eta
        vm.expectRevert(
            abi.encodeWithSelector(IGainsVaultErrors.CallFailed.selector, abi.encodeWithSelector(IGainsVaultErrors.NotPlatformAgent.selector))
        );
        v.execute(d2);
        address fresh = makeAddr("freshAgent");
        vm.prank(registrar);
        factory.registerPlatformAgent(fresh, address(v));
        bytes memory d3 = abi.encodeCall(GainsVault.setAgent, (fresh));
        vm.prank(creator);
        v.queue(d3);
        _warp(v.queuedEta(keccak256(d3))); // hl-r2 exit-before-effect: wait for the stored eta
        v.execute(d3);
        assertEq(v.agent(), fresh);
    }

    function test_V04_registrarCannotPreBindAndSignaturesAreScoped() public {
        address predicted = _predicted(creator, bytes32(uint256(1)));
        vm.prank(registrar);
        vm.expectRevert(GainsVaultFactory.NotRegistrar.selector);
        factory.registerPlatformAgent(makeAddr("squatter"), predicted);

        GainsVaultFactory.CreateParams memory p = _cparams(true, agentAddr);
        p.agentSig = _agentSig(registrarKey, agentAddr, _predicted(creator, bytes32(uint256(2))), p.agentDeadline);
        vm.prank(creator);
        usdc.approve(address(factory), type(uint256).max);
        vm.prank(creator);
        vm.expectRevert(GainsVaultFactory.BadAgentSignature.selector);
        factory.create{value: GAS}(p, _noPermit());

        p = _cparams(true, agentAddr);
        vm.warp(p.agentDeadline + 1);
        vm.prank(creator);
        vm.expectRevert(GainsVaultFactory.BadAgentSignature.selector);
        factory.create{value: GAS}(p, _noPermit());

        _warp(vm.getBlockTimestamp());
        p = _cparams(true, agentAddr);
        vm.prank(creator);
        (address va,) = factory.create{value: GAS}(p, _noPermit());
        assertEq(factory.platformAgentFor(agentAddr), va);
        assertEq(factory.agentOfVault(va), agentAddr);
        p.salt = bytes32(uint256(3));
        p.agentSig = _agentSig(registrarKey, agentAddr, _predicted(creator, p.salt), p.agentDeadline);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(GainsVaultFactory.AgentAlreadyBound.selector, agentAddr, va));
        factory.create{value: GAS}(p, _noPermit());

        vm.prank(registrar);
        factory.registerPlatformAgent(makeAddr("replacement"), va);
    }

    function test_AgentDigestIsChainScoped() public view {
        // An HL signature (chain 999) never binds on Arbitrum and vice versa: block.chainid is in the digest.
        bytes32 here = factory.agentDigest(agentAddr, address(1), 1);
        bytes32 other = keccak256(abi.encode("DojiPad platform agent", uint256(999), address(factory), agentAddr, address(1), uint256(1)));
        assertTrue(here != other);
    }

    function test_RegistrarRole() public {
        address a2 = makeAddr("a2");
        address v2 = makeAddr("v2");
        vm.prank(stranger);
        vm.expectRevert(GainsVaultFactory.NotRegistrar.selector);
        factory.registerPlatformAgent(a2, v2);
        vm.prank(creator);
        vm.expectRevert(GainsVaultFactory.NotRegistrar.selector);
        factory.registerPlatformAgent(a2, v2);
        vm.prank(owner);
        factory.registerPlatformAgent(a2, v2);
        assertTrue(factory.isPlatformAgent(a2));
        assertEq(factory.platformAgentFor(a2), v2);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GainsVaultFactory.AgentAlreadyBound.selector, a2, v2));
        factory.registerPlatformAgent(a2, makeAddr("v3"));
        vm.prank(registrar);
        factory.unregisterPlatformAgent(a2);
        assertFalse(factory.isPlatformAgent(a2));
        vm.prank(stranger);
        vm.expectRevert();
        factory.setAgentRegistrar(stranger);
    }

    function test_RolesAreRotatedFromTheFactory() public {
        (GainsVault v,) = _createWithPermit(false, address(0));
        bytes memory data = abi.encodeWithSignature("setGuardian(address)", creator);
        vm.prank(creator);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        v.queue(data);
        address g2 = makeAddr("g2");
        address s2 = makeAddr("s2");
        vm.prank(owner);
        factory.setGuardian(g2);
        vm.prank(owner);
        factory.setSentinel(s2);
        assertEq(v.guardian(), g2);
        assertEq(v.sentinel(), s2);
        vm.prank(guardian);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        v.triggerBreach();
        vm.prank(s2);
        v.triggerBreach();
        vm.prank(guardian);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        v.clearBreach();
        vm.prank(g2);
        v.clearBreach();
        assertFalse(v.breached());
    }

    function test_SentinelPowersAreRiskReducingOnly() public {
        (GainsVault v,) = _createWithPermit(true, agentAddr);
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        vm.prank(alice);
        v.requestDeposit(10_000e6, alice);
        _ageEpoch(v);
        v.checkRisk();
        vm.prank(creator);
        v.settle();
        OpenParams memory lp = _params(ETH, true, 1_000e6, 2_000);
        lp.tradeType = 1; // a resting limit order
        lp.expectedPrice = _px(ETH) * 90 / 100;
        vm.prank(creator);
        v.openTrade(lp);
        vm.startPrank(sentinel);
        v.setDepositsPaused(true);
        v.setTradingPaused(true);
        v.cancelOrder(0);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        v.setDepositsPaused(false);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        v.setTradingPaused(false);
        vm.expectRevert(IGainsVaultErrors.NotOverdue.selector);
        v.triggerEmergency();
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        v.flatten(ETH, 100, _px(ETH), type(uint256).max);
        v.revokeAgent();
        assertEq(v.agent(), address(0));
        v.triggerBreach();
        assertTrue(v.breached());
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        v.clearBreach();
        vm.stopPrank();
        bytes memory data = abi.encodeCall(GainsVault.setManager, (stranger));
        vm.prank(creator);
        bytes32 id = v.queue(data);
        vm.prank(sentinel);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        v.cancel(id);
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
        (GainsVault v,) = _createWithPermit(false, address(0));
        vm.prank(guardian);
        v.triggerBreach();
        vm.prank(creator);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        v.clearBreach();
        vm.prank(guardian);
        v.clearBreach();
        assertFalse(v.breached());
    }

    function test_CuratedAssetsOnly() public {
        GainsVaultFactory.CreateParams memory p = _cparams(false, address(0));
        p.assets = new uint32[](1);
        p.assets[0] = DOGE;
        vm.prank(creator);
        usdc.approve(address(factory), SEED);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(GainsVaultFactory.AssetNotCurated.selector, DOGE));
        factory.create(p, _noPermit());

        (, GainsVaultPolicy pol) = _createWithPermit(false, address(0));
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(GainsVaultPolicy.AssetNotCurated.selector, DOGE));
        pol.queueAllowAsset(DOGE);

        MockChainlinkFeed dogeFeed = new MockChainlinkFeed(8, 0.2e8);
        vm.prank(owner);
        factory.setAssetCurated(DOGE, true, address(dogeFeed), BTC_MAX_AGE, 50);
        uint32[] memory list = factory.curatedAssets();
        assertEq(list.length, 3);
        vm.prank(creator);
        pol.queueAllowAsset(DOGE);
        vm.prank(owner);
        factory.setAssetCurated(DOGE, false, address(0), 0, 0);
        _warp(pol.assetAllowEta(DOGE)); // hl-r2 exit-before-effect: wait for the stored eta
        vm.expectRevert(abi.encodeWithSelector(GainsVaultPolicy.AssetNotCurated.selector, DOGE));
        pol.allowAsset(DOGE);
        assertEq(factory.curatedAssets().length, 2);
    }

    function test_CurationNeedsAValidFeed() public {
        vm.startPrank(owner);
        vm.expectRevert(GainsVaultFactory.InvalidFeed.selector);
        factory.setAssetCurated(SOL, true, address(0), SOL_MAX_AGE, 25);
        vm.expectRevert(GainsVaultFactory.InvalidFeed.selector);
        factory.setAssetCurated(SOL, true, address(solFeed), 0, 25);
        vm.expectRevert(GainsVaultFactory.InvalidFeed.selector);
        factory.setAssetCurated(SOL, true, address(solFeed), SOL_MAX_AGE, 0);
        vm.expectRevert(GainsVaultFactory.InvalidFeed.selector);
        factory.setAssetCurated(SOL, true, address(solFeed), SOL_MAX_AGE, 1_001);
        vm.expectRevert(GainsVaultFactory.InvalidFeed.selector);
        factory.setAssetCurated(70_000, true, address(solFeed), SOL_MAX_AGE, 25);
        factory.setAssetCurated(SOL, true, address(solFeed), SOL_MAX_AGE, 25);
        vm.stopPrank();
        GainsPrice.Feed memory f = factory.pairFeed(SOL);
        assertEq(f.feed, address(solFeed));
        assertEq(f.maxAge, SOL_MAX_AGE);
        assertEq(f.bandBps, 25);
        assertEq(f.decimals, 8);
    }

    function test_CreateEnforcesTheNavBound() public {
        GainsVaultFactory.CreateParams memory p = _cparams(false, address(0));
        p.risk.maxNavMoveBps = 500; // BTC/ETH: 3.1x
        p.risk.maxLeverageBps = 31_251;
        vm.prank(creator);
        usdc.approve(address(factory), SEED);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(GainsVaultPolicy.LeverageAboveNavBound.selector, BTC));
        factory.create(p, _noPermit());
        p.risk.maxLeverageBps = 31_250;
        vm.prank(creator);
        (address va,) = factory.create(p, _noPermit());
        assertTrue(factory.isVault(va));
    }

    function test_DepositCapBoundedByPlatformMax() public {
        GainsVaultFactory.CreateParams memory p = _cparams(false, address(0));
        p.depositCap = 50_001e6;
        vm.prank(creator);
        usdc.approve(address(factory), SEED);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(GainsVaultFactory.CapAboveMax.selector, 50_001e6, 50_000e6));
        factory.create(p, _noPermit());
        p.depositCap = 0;
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(GainsVaultFactory.CapAboveMax.selector, 0, 50_000e6));
        factory.create(p, _noPermit());

        (GainsVault v,) = _createWithPermit(false, address(0));
        vm.prank(creator);
        vm.expectRevert(IGainsVaultErrors.CapExceeded.selector);
        v.setDepositCap(60_000e6);
        vm.prank(creator);
        vm.expectRevert(IGainsVaultErrors.CapExceeded.selector);
        v.setDepositCap(0);
        vm.prank(owner);
        factory.setMaxDepositCap(100_000e6);
        vm.prank(creator);
        v.setDepositCap(60_000e6);
        assertEq(v.depositCap(), 60_000e6);
    }

    function test_NoPlatformLimitAndNoCap() public {
        uint256 noCap = type(uint256).max;
        vm.prank(owner);
        factory.setMaxDepositCap(noCap);
        GainsVaultFactory.CreateParams memory p = _cparams(false, address(0));
        p.depositCap = noCap;
        GainsVaultFactory.PermitData memory pd = _permit(SEED, vm.getBlockTimestamp() + 1 hours);
        vm.prank(creator);
        (address va,) = factory.create(p, pd);
        GainsVault v = GainsVault(va);
        assertEq(v.depositCap(), noCap, "created uncapped");
        vm.prank(alice);
        usdc.approve(va, noCap);
        vm.prank(alice);
        v.requestDeposit(100e6, alice);
        assertEq(v.pendingDepositAssets(), 100e6);
        vm.prank(creator);
        v.setDepositCap(60_000e6);
        vm.prank(creator);
        v.setDepositCap(noCap);
        assertEq(v.depositCap(), noCap);
        vm.prank(creator);
        vm.expectRevert(IGainsVaultErrors.CapExceeded.selector);
        v.setDepositCap(0);
    }

    function test_CreateGas() public {
        GainsVaultFactory.PermitData memory pd = _permit(SEED, vm.getBlockTimestamp() + 1 hours);
        GainsVaultFactory.CreateParams memory p = _cparams(true, agentAddr);
        vm.prank(creator);
        uint256 g = gasleft();
        factory.create{value: GAS}(p, pd);
        uint256 used = g - gasleft();
        emit log_named_uint("create gas (permit + agent + seed + agent gas)", used);
        assertLt(used, 2_500_000);
    }

    function test_EmitsVaultCreated() public {
        GainsVaultFactory.PermitData memory pd = _permit(SEED, vm.getBlockTimestamp() + 1 hours);
        address predicted = factory.predictVaultAddress(creator, bytes32(uint256(1)));
        GainsVaultFactory.CreateParams memory p = _cparams(true, agentAddr);
        vm.expectEmit(true, false, true, false);
        emit GainsVaultFactory.VaultCreated(predicted, address(0), creator, creator, agentAddr, true, 3_300, bytes32(uint256(1)));
        vm.prank(creator);
        factory.create{value: GAS}(p, pd);
    }

    function test_MinSeedEnforced() public {
        GainsVaultFactory.CreateParams memory p = _cparams(false, address(0));
        p.seedUsdc = 0.5e6;
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(GainsVaultFactory.SeedTooSmall.selector, 0.5e6, 1e6));
        factory.create(p, _noPermit());
    }

    function test_SaltIsScopedPerCreator() public view {
        assertTrue(factory.predictVaultAddress(creator, bytes32(0)) != factory.predictVaultAddress(stranger, bytes32(0)));
    }

    function test_ClosedLaunchRejectsNonAllowlisted() public {
        usdc.mint(stranger, 10e6);
        GainsVaultFactory.CreateParams memory p = _cparams(false, address(0));
        vm.startPrank(stranger);
        usdc.approve(address(factory), SEED);
        vm.expectRevert(GainsVaultFactory.LaunchClosed.selector);
        factory.create(p, _noPermit());
        vm.stopPrank();
        vm.prank(owner);
        factory.setOpenLaunch(true);
        vm.prank(stranger);
        (address va,) = factory.create(p, _noPermit());
        assertTrue(factory.isVault(va));
    }

    function test_AllowlistEvents() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit GainsVaultFactory.LauncherAllowed(stranger, true);
        factory.setLauncherAllowed(stranger, true);
        assertTrue(factory.canLaunch(stranger));
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit GainsVaultFactory.OpenLaunchSet(true);
        factory.setOpenLaunch(true);
        vm.prank(stranger);
        vm.expectRevert();
        factory.setOpenLaunch(false);
    }

    // ------------------------------------------------------------------
    // Fee split per vault
    // ------------------------------------------------------------------
    function _earnFees(GainsVault v) internal {
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        vm.prank(alice);
        v.requestDeposit(1_000e6, alice);
        _ageEpoch(v);
        v.checkRisk();
        vm.prank(creator);
        v.settle();
        v.claim(alice);
        // +100 profit on top of the seed: 1000 at 1x, valued exactly through the holding fee lever
        uint32 idx = _open(v, ETH, true, 1_000e6, 1_000);
        _setVenueValue(v, idx, 1_100e6);
        _ageEpoch(v);
        v.checkRisk();
        vm.prank(creator);
        v.settle();
    }

    function test_BaseShare10Percent() public {
        (GainsVault v,) = _createWithPermit(false, address(0));
        _earnFees(v);
        uint256 total = v.convertToAssets(v.balanceOf(creator) + v.balanceOf(treasury));
        assertApproxEqAbs(total, 20e6, 1e4, "20% perf fee on 100 profit");
        assertApproxEqAbs(v.convertToAssets(v.balanceOf(treasury)), 2e6, 1e4, "10% of fees");
    }

    function test_HostedShare33Percent() public {
        (GainsVault v,) = _createWithPermit(true, agentAddr);
        assertEq(v.protocolShareBps(), 3_300);
        _earnFees(v);
        uint256 total = v.convertToAssets(v.balanceOf(creator) + v.balanceOf(treasury));
        assertApproxEqAbs(total, 20e6, 1e4);
        assertApproxEqAbs(v.convertToAssets(v.balanceOf(treasury)), 6.6e6, 1e4, "33% of fees");
    }

    function test_FactoryRateChangesDoNotTouchExistingVaults() public {
        (GainsVault v,) = _createWithPermit(true, agentAddr);
        vm.prank(owner);
        factory.setShares(2_000, 5_000);
        assertEq(v.protocolShareBps(), 3_300);
        assertEq(v.baseShareBps(), 1_000);
        _earnFees(v);
        assertApproxEqAbs(v.convertToAssets(v.balanceOf(treasury)), 6.6e6, 1e4, "still 33%");

        GainsVaultFactory.CreateParams memory p = _cparams(true, address(0));
        p.salt = bytes32(uint256(2));
        vm.prank(creator);
        usdc.approve(address(factory), SEED);
        vm.prank(creator);
        (address v2,) = factory.create(p, _noPermit());
        assertEq(GainsVault(v2).protocolShareBps(), 5_000);
        assertEq(GainsVault(v2).baseShareBps(), 2_000);
    }

    function test_RecipientIsReadLive() public {
        (GainsVault v,) = _createWithPermit(false, address(0));
        address newTreasury = makeAddr("newTreasury");
        vm.prank(owner);
        factory.setProtocolFeeRecipient(newTreasury);
        _earnFees(v);
        assertEq(v.balanceOf(treasury), 0);
        assertGt(v.balanceOf(newTreasury), 0);
    }

    function test_ShareCapIsFiftyPercent() public {
        vm.prank(owner);
        vm.expectRevert(GainsVaultFactory.InvalidShare.selector);
        factory.setShares(1_000, 5_001);
    }

    function test_LeaveHosted() public {
        (GainsVault v,) = _createWithPermit(true, agentAddr);
        vm.prank(stranger);
        vm.expectRevert();
        v.leaveHosted();
        vm.prank(creator);
        vm.expectEmit(false, false, false, true);
        emit IGainsVaultEvents.LeftHosted(1_000);
        v.leaveHosted();
        assertFalse(v.hosted());
        assertEq(v.protocolShareBps(), 1_000, "dropped to base");
        assertEq(v.agent(), address(0), "agent revoked");
        vm.prank(creator);
        vm.expectRevert(IGainsVaultErrors.NotHosted.selector);
        v.leaveHosted();
        _earnFees(v);
        assertApproxEqAbs(v.convertToAssets(v.balanceOf(treasury)), 2e6, 1e4, "10% after leaving");
    }

    function test_LeaveHostedRevertsOnNonHosted() public {
        (GainsVault v,) = _createWithPermit(false, address(0));
        vm.prank(creator);
        vm.expectRevert(IGainsVaultErrors.NotHosted.selector);
        v.leaveHosted();
    }

    function test_LeaveHostedNeverRaisesALoweredShare() public {
        (GainsVault v,) = _createWithPermit(true, agentAddr);
        vm.prank(owner);
        factory.lowerProtocolShare(address(v), 500);
        vm.prank(creator);
        v.leaveHosted();
        assertEq(v.protocolShareBps(), 500);
    }

    function test_LowerProtocolShareOnlyLowers() public {
        (GainsVault v,) = _createWithPermit(true, agentAddr);
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit GainsVaultFactory.ProtocolShareLowered(address(v), 2_000);
        factory.lowerProtocolShare(address(v), 2_000);
        assertEq(v.protocolShareBps(), 2_000);
        vm.prank(owner);
        vm.expectRevert(IGainsVaultErrors.InvalidShare.selector);
        factory.lowerProtocolShare(address(v), 2_500);
        vm.prank(owner);
        vm.expectRevert(IGainsVaultErrors.InvalidShare.selector);
        factory.lowerProtocolShare(address(v), 2_000);
        vm.prank(creator);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        v.lowerProtocolShare(100);
        vm.prank(creator);
        vm.expectRevert();
        factory.lowerProtocolShare(address(v), 100);
        vm.prank(owner);
        vm.expectRevert(GainsVaultFactory.NotAVault.selector);
        factory.lowerProtocolShare(address(vault), 100);
    }

    function test_PlainTransferToVaultReverts() public {
        (GainsVault v,) = _createWithPermit(false, address(0));
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(v).call{value: 1}("");
        assertFalse(ok, "no receive(): the vault never holds ETH");
    }

    function test_FactoryVaultTradesUnderPolicy() public {
        (GainsVault v,) = _createWithPermit(false, address(0));
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        vm.prank(alice);
        v.requestDeposit(10_000e6, alice);
        _ageEpoch(v);
        v.checkRisk();
        vm.prank(creator);
        v.settle();
        _open(v, BTC, true, 1_000e6, 2_000);
        OpenParams memory op = _params(SOL, true, 1_000e6, 2_000);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IGainsVaultErrors.OrderRejected.selector, "asset not allowed"));
        v.openTrade(op);
    }
}
