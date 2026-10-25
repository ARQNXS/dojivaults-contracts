// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {GainsVault} from "../../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../../src/gains/GainsVaultPolicy.sol";
import {GainsVaultFactory} from "../../../../src/gains/GainsVaultFactory.sol";
import {IGainsDiamond} from "../../../../src/gains/IGainsDiamond.sol";
import {MockChainlinkFeed} from "../../../gains/mocks/GainsMocks.sol";
import {LedgerUSDC, CIDiamond} from "./ConservationMocks.sol";

/// @notice Round 2, domain CI. Builds the world the conservation suite runs in, the way the live system is set up
///         (contracts/audit/gains/r2/METHOD.md "Live system"): a factory vault (EIP-1167 clone, created through
///         GainsVaultFactory.create) with owner = manager = fee recipient, a bound platform agent, the keeper as
///         operator, hosted (protocol share 33%), fees 2% / 20%, timelock 2 days, the live policy (5x, daily loss 15%,
///         drawdown 50%, slippage 3%, maxOrderNotional 250k, maxEpochDuration 1 day, maxNavMove 20%, flatten 3%), pairs
///         BTC (0) and ETH (1) with a 20 bps band, a 1 USDC seed. Differences from live: no deposit cap (live: 101
///         USDC), the mock diamond (CIDiamond) instead of gTrade, and the instrumented USDC (LedgerUSDC).
///         Plain contract (no forge-std Test) so the Medusa harness can deploy it too.
contract CIWorld is CommonBase {
    LedgerUSDC public usdc;
    CIDiamond public diamond;
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
        diamond = new CIDiamond(IERC20(address(usdc)));
        usdc.mint(address(diamond), 1_000_000_000e6); // the gToken vault that pays profits
        diamond.setPair(0, 3.5e8, 285.7e18, 0.1e18, 1e7);
        diamond.setPair(1, 3.5e8, 285.7e18, 0.1e18, 1e7);

        btcFeed = new MockChainlinkFeed(8, 100_000e8);
        ethFeed = new MockChainlinkFeed(8, 3_000e8);
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

        uint32[] memory assets = new uint32[](2);
        assets[0] = 0;
        assets[1] = 1;
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
