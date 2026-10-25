// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GainsVault} from "../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../src/gains/GainsVaultPolicy.sol";
import {GainsVaultFactory} from "../../../src/gains/GainsVaultFactory.sol";
import {IGainsDiamond} from "../../../src/gains/IGainsDiamond.sol";
import {MockChainlinkFeed} from "../../gains/mocks/GainsMocks.sol";
import {LedgerUSDC} from "../gains/r2/ConservationMocks.sol";
import {WP5Diamond} from "./WP5-INV-GainsDiamond.sol";

/// @notice A Chainlink stand-in that is always fresh (WP5: pair 2's feed, which the CI handler does not refresh).
contract WP5FreshFeed {
    uint8 public constant decimals = 8;
    int256 public answer;

    constructor(int256 a) {
        answer = a;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}

/// @notice WP5 (fix round): test/audit/gains/r2/ConservationWorld.sol CIWorld with three changes: the diamond is
///         WP5Diamond (finite skew depth on BTC and ETH, so the 1 % pair cap binds), and the vault's policy has a
///         third pair (2) that is curated but has no skew cap set (fail closed). Same getters (the CI handler, valuer
///         and checker use it through a CIWorld cast).
contract WP5GainsWorld is CommonBase {
    LedgerUSDC public usdc;
    WP5Diamond public diamond;
    WP5FreshFeed public solFeed;
    MockChainlinkFeed public btcFeed;
    MockChainlinkFeed public ethFeed;
    MockChainlinkFeed public sequencer;
    GainsVaultFactory public factory;
    GainsVault public vault;
    GainsVaultPolicy public policy;

    address public constant MANAGER = address(0xC1A0); // = owner = fee recipient (live)
    address public constant AGENT = address(0xC1A1);
    address public constant KEEPER = address(0xC1A2); // operator
    address public constant GUARDIAN = address(0xC1A3);
    address public constant SENTINEL = address(0xC1A4);
    address public constant TREASURY = address(0xC1A5); // protocol fee recipient
    address public constant STRANGER = address(0xC1A6);
    address public constant CONFEDERATE = address(0xC1A7); // a non-insider address the manager controls
    address public constant D0 = address(0xC1B0);
    address public constant D1 = address(0xC1B1);
    address public constant D2 = address(0xC1B2);

    uint256 public constant START = 1_700_000_000;
    uint16 public constant BAND = 20;
    uint256 public constant SEED = 1e6;

    constructor() {
        vm.warp(START);
        vm.roll(1_000);
        usdc = new LedgerUSDC();
        diamond = new WP5Diamond(IERC20(address(usdc)));
        usdc.mint(address(diamond), 1_000_000_000e6); // the gToken vault that pays profits
        diamond.setPair(0, 3.5e8, 285.7e18, 0.1e18, 1e7);
        diamond.setPair(1, 3.5e8, 285.7e18, 0.1e18, 1e7);
        diamond.setPair(2, 3.5e8, 285.7e18, 0.1e18, 1e7);
        // WP5: finite skew depths, so the 1 % pair cap binds: BTC cap 3M USD (3,000 BTC), ETH cap 2M USD (66,667 ETH)
        diamond.setSkewDepth(0, 3_000e18);
        diamond.setSkewDepth(1, 66_667e18);
        diamond.setSkewDepth(2, 1_000_000e18);

        btcFeed = new MockChainlinkFeed(8, 100_000e8);
        ethFeed = new MockChainlinkFeed(8, 3_000e8);
        solFeed = new WP5FreshFeed(150e8);
        sequencer = new MockChainlinkFeed(0, 0);
        sequencer.setStatus(0, START - 30 days);

        GainsVault impl = new GainsVault();
        GainsVaultPolicy pimpl = new GainsVaultPolicy();
        factory = new GainsVaultFactory(
            address(this),
            address(impl),
            address(pimpl),
            IERC20(address(usdc)),
            IGainsDiamond(address(diamond)),
            address(sequencer),
            3_600,
            TREASURY,
            GUARDIAN,
            SENTINEL
        );
        factory.setAssetCurated(0, true, address(btcFeed), 2_655, BAND);
        factory.setAssetCurated(1, true, address(ethFeed), 2_655, BAND);
        // WP5: pair 2 is in the vault's policy and curated, but the guardian never set its skew cap: it must take no
        // new exposure (fail closed, GR2-KEY-01b)
        factory.setAssetCurated(2, true, address(solFeed), 2_655, BAND);
        factory.setMaxDepositCap(type(uint256).max);
        factory.setMinAgentGas(0);
        // GR2-KEY-01b: a pair never set takes no new exposure; the guardian's first setting (1 %, the launch value) is immediate
        vm.startPrank(GUARDIAN);
        factory.setPairSkewCap(0, 100);
        factory.setPairSkewCap(1, 100);
        vm.stopPrank();
        factory.setLauncherAllowed(address(this), true);
        bytes32 salt = bytes32(uint256(0xC1));
        factory.registerPlatformAgent(AGENT, factory.predictVaultAddress(address(this), salt));

        uint32[] memory assets = new uint32[](3);
        assets[0] = 0;
        assets[1] = 1;
        assets[2] = 2;
        GainsVaultFactory.CreateParams memory p = GainsVaultFactory.CreateParams({
            name: "CI Vault",
            symbol: "ci",
            owner: MANAGER,
            manager: MANAGER,
            feeRecipient: MANAGER,
            managementFeeBps: 200,
            performanceFeeBps: 2_000,
            timelockDelay: 2 days,
            depositCap: type(uint256).max,
            risk: GainsVaultPolicy.RiskConfig({
                maxLeverageBps: 50_000,
                maxDailyLossBps: 1_500,
                maxDrawdownBps: 5_000,
                maxSlippageBps: 300,
                maxOrderNotional: 250_000e6,
                maxEpochDuration: 1 days,
                maxNavMoveBps: 2_000,
                maxFlattenSlippageBps: 300
            }),
            assets: assets,
            agent: AGENT,
            agentSig: "",
            agentDeadline: 0,
            operator: KEEPER,
            hosted: true,
            seedUsdc: SEED,
            salt: salt
        });
        usdc.mint(address(this), SEED);
        usdc.approve(address(factory), SEED);
        (address v, address pol) = factory.create(p, GainsVaultFactory.PermitData(0, 0, 0, bytes32(0), bytes32(0)));
        vault = GainsVault(v);
        policy = GainsVaultPolicy(pol);
        usdc.watch(v, address(diamond));
    }

    function actors() external pure returns (address[5] memory a) {
        a = [D0, D1, D2, CONFEDERATE, MANAGER];
    }
}
