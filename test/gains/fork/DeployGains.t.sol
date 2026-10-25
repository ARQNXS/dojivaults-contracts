// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "./GainsForkBase.sol";
import {DeployGainsFactory, GainsAddresses} from "../../../script/DeployGains.s.sol";
import {LinkedLibraries} from "../../../script/Deploy.s.sol";
import {GainsVault} from "../../../src/gains/GainsVault.sol";
import {GainsVaultFactory} from "../../../src/gains/GainsVaultFactory.sol";
import {GainsVaultLens} from "../../../src/gains/GainsVaultLens.sol";
import {GainsVaultPolicy} from "../../../src/gains/GainsVaultPolicy.sol";
import {GainsPrice} from "../../../src/gains/GainsPrice.sol";
import {OpenParams} from "../../../src/gains/GainsTypes.sol";

/// @notice Dry run of script/DeployGains.s.sol on an Arbitrum One fork (no broadcast, no mainnet transaction): the
///         real script deploys the libraries, implementations, lens and factory against the real diamond, USDC,
///         Chainlink feeds and sequencer feed; then a vault launched through that factory takes a deposit, settles,
///         trades the real diamond (fills via the Stage 0 oracle emulation) and pays its depositor out.
contract DeployGainsForkTest is GainsForkBase {
    /// @dev vm.startBroadcast() in a test runs as forge's default sender: the script's setters need it as OWNER.
    address internal deployer = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;
    address internal platformGuardian = makeAddr("platformGuardian");
    address internal platformSentinel = makeAddr("platformSentinel");
    address internal registrar = makeAddr("registrar");
    address internal treasury = makeAddr("treasury");
    address internal launcher = makeAddr("launcher");

    DeployGainsFactory internal script;
    GainsVault internal vaultImpl_;
    GainsVaultPolicy internal policyImpl_;
    GainsVaultLens internal lens_;
    GainsVaultFactory internal factory;

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        script = new DeployGainsFactory();
        (vaultImpl_, policyImpl_, lens_, factory) = script.deploy(_cfg(), false, "");
    }

    /// @dev The config run() would read from the env (OWNER = forge's default broadcaster), passed directly.
    function _cfg() internal view returns (DeployGainsFactory.Config memory c) {
        c.owner = deployer;
        c.treasury = treasury;
        c.guardian = platformGuardian;
        c.sentinel = platformSentinel;
        c.registrar = registrar;
        c.curated = new uint256[](3);
        c.curated[0] = 0;
        c.curated[1] = 1;
        c.curated[2] = 33;
        c.maxCap = type(uint256).max;
        c.baseShare = 1_000;
        c.hostedShare = 3_300;
        c.minSeed = 1e6;
        c.minAgentGas = 0.001 ether;
        c.allow = launcher;
    }

    function test_DeployGains_wiringOnTheFork() public view {
        assertEq(block.chainid, 42161);
        (address nav, address logic, address governance,,,,,,,,,) = script.last();
        assertGt(nav.code.length, 0);
        assertGt(logic.code.length, 0);
        assertGt(governance.code.length, 0);
        bytes memory impl = address(vaultImpl_).code;
        assertEq(LinkedLibraries.linked(vm, "out/GainsVault.sol/GainsVault.json", "src/gains/GainsNav.sol", "GainsNav", impl), nav);
        (address n2, address l2, address g2) = script.resolveLibraries(address(vaultImpl_));
        assertEq(n2, nav);
        assertEq(l2, logic);
        assertEq(g2, governance);

        assertEq(address(factory.usdc()), GainsAddresses.USDC);
        assertEq(address(factory.diamond()), GainsAddresses.DIAMOND);
        assertEq(factory.sequencerFeed(), GainsAddresses.SEQUENCER);
        assertEq(factory.sequencerGracePeriod(), 3_600);
        assertEq(factory.owner(), deployer);
        assertEq(factory.pendingOwner(), platformGuardian, "two step hand-over to the cold guardian");
        assertEq(factory.guardian(), platformGuardian);
        assertEq(factory.sentinel(), platformSentinel);
        assertEq(factory.agentRegistrar(), registrar);
        assertEq(factory.maxDepositCap(), type(uint256).max);
        assertEq(factory.minSeedUsdc(), 1e6);
        assertEq(factory.minAgentGas(), 0.001 ether);
        assertTrue(factory.launcherAllowed(launcher));
        uint32[] memory curated = factory.curatedAssets();
        assertEq(curated.length, 3);
        GainsPrice.Feed memory f = factory.pairFeed(33);
        assertEq(f.feed, GainsAddresses.SOL_USD);
        assertEq(f.maxAge, 88_200);
        assertEq(f.bandBps, 25);
        assertEq(f.decimals, 8, "decimals read from the real feed");
        assertEq(factory.pairFeed(0).bandBps, 20);
        assertEq(factory.pairFeed(1).feed, GainsAddresses.ETH_USD);
    }

    function test_DeployGains_vaultLifecycleOnTheDeployedFactory() public {
        vm.startPrank(GUSDC);
        USDC.transfer(launcher, 10e6);
        USDC.transfer(makeAddr("depositor"), 20_000e6);
        vm.stopPrank();
        address depositor = makeAddr("depositor");
        uint32[] memory assets = new uint32[](2);
        assets[0] = BTC;
        assets[1] = ETH;
        vm.prank(launcher);
        USDC.approve(address(factory), 1e6);
        vm.prank(launcher);
        (address va,) = factory.create(
            GainsVaultFactory.CreateParams({
                name: "Dry run",
                symbol: "dry",
                owner: launcher,
                manager: launcher,
                feeRecipient: launcher,
                managementFeeBps: 200,
                performanceFeeBps: 2_000,
                timelockDelay: 2 days,
                depositCap: 100_000e6,
                risk: GainsVaultPolicy.RiskConfig(30_000, 500, 1_500, 100, 250_000e6, 7 days, 2_000, 300),
                assets: assets,
                agent: address(0),
                agentSig: "",
                agentDeadline: 0,
                operator: address(0),
                hosted: false,
                seedUsdc: 1e6,
                salt: keccak256("dry run")
            }),
            GainsVaultFactory.PermitData(0, 0, 0, bytes32(0), bytes32(0))
        );
        GainsVault v = GainsVault(va);
        assertEq(v.collateralIndex(), 3, "USDC collateral index read from the real diamond");
        // GR2-KEY-01b (WP5 port): the guardian's launch caps, 1 % of skew depth (docs/fix-round/DEPLOY-R2.md 3.5)
        vm.startPrank(factory.guardian());
        factory.setPairSkewCap(BTC, 100);
        factory.setPairSkewCap(ETH, 100);
        factory.setPairSkewCap(SOL, 100);
        vm.stopPrank();

        vm.prank(depositor);
        USDC.approve(va, type(uint256).max);
        vm.prank(depositor);
        v.requestDeposit(10_000e6, depositor);
        _ageAnHour(); // GR1-02: a settle that prices deposits runs an hour into the epoch
        v.checkRisk();
        vm.prank(launcher);
        v.settle();
        v.claim(depositor);
        assertEq(v.totalAssets(), 10_001e6);

        uint64 p = _chainlink1e10(0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612);
        vm.recordLogs();
        vm.prank(launcher);
        v.openTrade(OpenParams(ETH, true, 1_000e6, 5_000, p, 1_000, 0, 0, 0));
        Vm.Log[] memory req = vm.getRecordedLogs();
        _roll(1);
        Vm.Log[] memory fill = _fill(req, p);
        uint32 idx = uint32(uint256(_find(fill, G.MarketExecuted.selector).topics[2]));
        assertTrue(DIAMOND.getTrade(va, idx).isOpen);
        assertGt(lens_.status(v).venueValue, 0);

        // GR2-KEY-01b: the manager's close waits the 10-minute minimum hold (MIN_HOLD and MIN_HOLD_L2_BLOCKS)
        _roll(2_700);
        vm.recordLogs();
        vm.prank(launcher);
        v.closeTrade(idx, p);
        req = vm.getRecordedLogs();
        _roll(1);
        _fill(req, p);
        assertEq(DIAMOND.getTrades(va).length, 0);

        uint256 shares = v.balanceOf(depositor);
        vm.prank(depositor);
        v.requestRedeem(shares, depositor, depositor);
        vm.prank(launcher);
        v.settle();
        uint256 before = USDC.balanceOf(depositor);
        v.claim(depositor);
        assertGt(USDC.balanceOf(depositor) - before, 9_990e6, "depositor paid out (minus fees and the round trip cost)");
    }

    /// @dev One hour later, with every curated feed answering its current price as fresh: on the fork no round comes in,
    ///      and BTC / ETH are stale after 44 minutes (heartbeat + margin), as mainnet feeds never are.
    function _ageAnHour() internal {
        _roll(4 * 3_600); // 14,400 L2 blocks, one hour
        address[3] memory feeds = [GainsAddresses.BTC_USD, GainsAddresses.ETH_USD, GainsAddresses.SOL_USD];
        for (uint256 i; i < 3; ++i) {
            (uint80 r, int256 a,,, uint80 ar) = IChainlinkFeed(feeds[i]).latestRoundData();
            uint256 t = vm.getBlockTimestamp();
            vm.mockCall(feeds[i], abi.encodeWithSelector(IChainlinkFeed.latestRoundData.selector), abi.encode(r, a, t, t, ar));
        }
    }

    function test_DeployGains_writesTheDeploymentRecord() public {
        DeployGainsFactory s2 = new DeployGainsFactory();
        (,,, GainsVaultFactory f2) = s2.deploy(_cfg(), true, "arbitrum-dryrun.json");
        string memory json = vm.readFile("deployments/arbitrum-dryrun.json");
        assertEq(vm.parseJsonUint(json, ".chainId"), 42161);
        assertEq(vm.parseJsonAddress(json, ".factory"), address(f2));
        assertEq(vm.parseJsonAddress(json, ".diamond"), GainsAddresses.DIAMOND);
        assertEq(vm.parseJsonAddress(json, ".usdc"), GainsAddresses.USDC);
        assertTrue(vm.parseJsonBool(json, ".ownershipPendingAcceptance"));
        vm.removeFile("deployments/arbitrum-dryrun.json");
    }
}
