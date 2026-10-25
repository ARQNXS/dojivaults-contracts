// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "./GainsForkBase.sol";
import {GainsVault} from "../../../src/gains/GainsVault.sol";
import {GainsVaultFactory} from "../../../src/gains/GainsVaultFactory.sol";
import {GainsVaultPolicy} from "../../../src/gains/GainsVaultPolicy.sol";
import {GainsNav} from "../../../src/gains/GainsNav.sol";
import {IGainsDiamond} from "../../../src/gains/IGainsDiamond.sol";
import {OpenParams} from "../../../src/gains/GainsTypes.sol";

/// @notice Parity fixtures for the executor's off-chain checkRisk on Gains vaults (server/src/risk/contractRisk.ts,
///         generation "gains"; Stage 3). Every scenario runs the real Gains contracts on an Arbitrum One fork: a
///         GainsVault from a GainsVaultFactory, trades on the real gTrade diamond filled by the Stage 0 oracle
///         emulation, Chainlink frozen per scenario. It records what the Gains keeper reads (the vault's storage and
///         its venue() view: GainsNav's value and open notional, at one block), runs the real checkRisk() and records
///         what it computed and stored. test/fixtures/risk-parity-gains.json holds the result: this test fails when
///         the contracts no longer produce it, server/test/risk-parity-gains.test.ts when the mirror no longer does.
///         Regenerate after an intended change: RISK_PARITY_WRITE=true forge test --match-contract GainsRiskParity
contract GainsRiskParityTest is GainsForkBase {
    string internal constant PATH = "test/fixtures/risk-parity-gains.json";
    /// @dev The committed fixture holds chain data (timestamps, prices, Gains fees) at this block: needs an archive RPC.
    uint256 internal constant PARITY_BLOCK = 515_219_884;
    uint256 internal constant SCENARIOS = 17;

    address internal constant BTC_USD = 0x6ce185860a4963106506C203335A2910413708e9;
    address internal constant ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address internal constant SOL_USD = 0x24ceA4b8ce57cdA5058b924B9B9987992450590c;
    address internal constant SEQ = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;

    GainsVaultFactory internal factory;
    GainsVault internal v;
    address internal fOwner = makeAddr("fOwner");
    address internal fGuardian = makeAddr("fGuardian");
    address internal fSentinel = makeAddr("fSentinel");
    address internal creator = makeAddr("creator");
    address internal mgr = makeAddr("mgr");
    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    address internal stranger = makeAddr("stranger");

    mapping(address feed => uint64) internal cl;
    bool internal writing;
    string internal committed;

    function _forkBlock() internal pure override returns (uint256) {
        return PARITY_BLOCK;
    }

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        _setCl(BTC_USD, (_chainlink1e10(BTC_USD) / 100) * 100);
        _setCl(ETH_USD, (_chainlink1e10(ETH_USD) / 100) * 100);
        _setCl(SOL_USD, (_chainlink1e10(SOL_USD) / 100) * 100);
        GainsVault impl = new GainsVault();
        GainsVaultPolicy pimpl = new GainsVaultPolicy();
        factory = new GainsVaultFactory(
            fOwner, address(impl), address(pimpl), USDC, IGainsDiamond(address(DIAMOND)), SEQ, 3_600, makeAddr("treasury"), fGuardian, fSentinel
        );
        vm.startPrank(fOwner);
        factory.setLauncherAllowed(creator, true);
        factory.setAssetCurated(BTC, true, BTC_USD, 2_655, 20);
        factory.setAssetCurated(ETH, true, ETH_USD, 2_655, 20);
        factory.setAssetCurated(SOL, true, SOL_USD, 88_200, 25);
        factory.setMaxDepositCap(type(uint256).max);
        vm.stopPrank();
        // GR2-KEY-01b (WP5 port): the guardian sets the launch caps, 1 % of skew depth on BTC, ETH and SOL, as the
        // deploy does (docs/fix-round/DEPLOY-R2.md 3.5). Without them a factory vault takes no new exposure.
        vm.startPrank(factory.guardian());
        factory.setPairSkewCap(uint16(BTC), 100);
        factory.setPairSkewCap(uint16(ETH), 100);
        factory.setPairSkewCap(uint16(SOL), 100);
        vm.stopPrank();
        vm.startPrank(GUSDC);
        USDC.transfer(creator, 10e6);
        USDC.transfer(alice, 200_000e6);
        vm.stopPrank();
        uint32[] memory assets = new uint32[](3);
        assets[0] = BTC;
        assets[1] = ETH;
        assets[2] = SOL;
        vm.prank(creator);
        USDC.approve(address(factory), 1e6);
        vm.prank(creator);
        (address va,) = factory.create(
            GainsVaultFactory.CreateParams({
                name: "Gains Parity Vault",
                symbol: "gPV",
                owner: creator,
                manager: mgr,
                feeRecipient: creator,
                managementFeeBps: 0,
                performanceFeeBps: 0,
                timelockDelay: 2 days,
                depositCap: 1_000_000e6,
                risk: GainsVaultPolicy.RiskConfig({
                    maxLeverageBps: 30_000,
                    maxDailyLossBps: 500,
                    maxDrawdownBps: 1_500,
                    maxSlippageBps: 100,
                    maxOrderNotional: 1_000_000e6,
                    maxEpochDuration: 7 days,
                    maxNavMoveBps: 2_000,
                    maxFlattenSlippageBps: 300
                }),
                assets: assets,
                agent: address(0),
                agentSig: "",
                agentDeadline: 0,
                operator: keeper,
                hosted: false,
                seedUsdc: 1e6,
                salt: bytes32(uint256(7))
            }),
            GainsVaultFactory.PermitData(0, 0, 0, bytes32(0), bytes32(0))
        );
        v = GainsVault(va);
        vm.prank(alice);
        USDC.approve(address(v), type(uint256).max);
    }

    // ------------------------------------------------------------------ harness
    function _setCl(address feed, uint64 px) internal {
        cl[feed] = px;
        uint256 t = vm.getBlockTimestamp();
        vm.mockCall(feed, abi.encodeWithSelector(IChainlinkFeed.latestRoundData.selector), abi.encode(uint80(1), int256(uint256(px / 100)), t, t, uint80(1)));
    }

    function _refresh() internal {
        _setCl(BTC_USD, cl[BTC_USD]);
        _setCl(ETH_USD, cl[ETH_USD]);
        _setCl(SOL_USD, cl[SOL_USD]);
    }

    function _rollFresh(uint256 blocks) internal {
        _roll(blocks);
        _refresh();
    }

    /// @dev ETH moves by `pct` hundredths of a percent (signed), the oracle and Chainlink together.
    function _moveEth(int256 bpsMove) internal {
        _setCl(ETH_USD, uint64((uint256(cl[ETH_USD]) * uint256(int256(10_000) + bpsMove)) / 10_000 / 100 * 100));
    }

    function _nextDay(uint256 hoursIn) internal {
        uint256 t = (vm.getBlockTimestamp() / 1 days + 1) * 1 days + hoursIn * 1 hours + 1;
        uint256 blocks = (t - vm.getBlockTimestamp()) * 4;
        vm.roll(vm.getBlockNumber() + blocks);
        vm.warp(t);
        _mockArbBlock();
        _refresh();
    }

    function _later() internal {
        _rollFresh(2 * 3_600 * 4);
    }

    /// @dev alice deposits, it settles and is claimed; the day reference is set.
    function _fund(uint256 amount) internal {
        vm.prank(alice);
        v.requestDeposit(amount, alice);
        _rollFresh(4 * 3_600);
        v.checkRisk();
        vm.prank(keeper);
        v.settle();
        v.claim(alice);
        v.checkRisk();
    }

    function _open(uint16 pair, bool long, uint120 coll, uint24 lev) internal returns (uint32 idx) {
        address feed = pair == BTC ? BTC_USD : pair == ETH ? ETH_USD : SOL_USD;
        vm.recordLogs();
        vm.prank(mgr);
        v.openTrade(OpenParams(pair, long, coll, lev, cl[feed], 1_000, 0, 0, 0));
        Vm.Log[] memory req = vm.getRecordedLogs();
        _rollFresh(1);
        Vm.Log[] memory fill = _fill(req, cl[feed]);
        idx = uint32(uint256(_find(fill, G.MarketExecuted.selector).topics[2]));
    }

    /// @dev Builds scenario `i`; returns its name.
    function _scenario(uint256 i) internal returns (string memory) {
        if (i == 0) {
            _fund(10_000e6);
            _later();
            return "calm_no_trades";
        }
        if (i == 1) {
            _fund(10_000e6);
            _open(ETH, true, 2_000e6, 5_000); // 10k notional, 1x vault leverage
            _moveEth(-300);
            return "daily_loss_under_limit";
        }
        if (i == 2) {
            _fund(10_000e6);
            _open(ETH, true, 2_000e6, 5_000);
            _moveEth(-600);
            return "daily_loss_over_limit";
        }
        if (i == 3) {
            _fund(10_000e6);
            _open(ETH, true, 5_700e6, 5_000); // 28.5k notional of 10k: 2.85x of the 3x limit
            return "leverage_in_margin";
        }
        if (i == 4) {
            // a redemption shrinks the NAV, the notional stays: vault leverage over the limit, no loss
            _fund(10_000e6);
            _open(ETH, true, 5_600e6, 5_000);
            uint256 shares = v.balanceOf(alice) / 5;
            vm.prank(alice);
            v.requestRedeem(shares, alice, alice);
            _rollFresh(4 * 3_600);
            v.checkRisk();
            vm.prank(keeper);
            v.settle();
            return "leverage_over_limit_after_redemption";
        }
        if (i == 5) {
            _fund(10_000e6);
            _open(ETH, true, 2_000e6, 5_000);
            _nextDay(1);
            _moveEth(-1_700);
            return "drawdown_over_limit_next_day";
        }
        if (i == 6) {
            _fund(10_000e6);
            _open(ETH, true, 2_000e6, 5_000);
            _nextDay(1);
            _moveEth(-1_250);
            return "drawdown_in_margin_next_day";
        }
        if (i == 7) {
            _fund(10_000e6);
            _open(ETH, true, 2_000e6, 5_000);
            _later();
            _moveEth(400);
            return "new_high";
        }
        if (i == 8) {
            // the day's first check comes after the loss: it becomes the baseline
            _fund(10_000e6);
            _open(ETH, true, 2_000e6, 5_000);
            _nextDay(1);
            _moveEth(-450);
            return "stale_day_loss_rolls_into_baseline";
        }
        if (i == 9) {
            _fund(10_000e6);
            _open(ETH, true, 2_000e6, 5_000);
            _moveEth(-600);
            v.checkRisk(); // daily loss breach
            _nextDay(1);
            return "daily_breach_cleared_next_day";
        }
        if (i == 10) {
            _fund(10_000e6);
            _open(ETH, true, 2_000e6, 5_000);
            vm.prank(fGuardian);
            v.triggerBreach(); // a full stop: checkRisk computes, never touches it
            _moveEth(-1_000);
            return "guardian_stop_untouched";
        }
        if (i == 11) {
            _fund(10_000e6);
            _open(ETH, true, 2_000e6, 5_000);
            _later();
            _moveEth(800);
            v.checkRisk(); // peak raised
            _moveEth(-500);
            return "peak_then_drop_same_day";
        }
        if (i == 12) {
            // an open request pending on the diamond at the check: its collateral (minus the cancel gov fee) counts
            _fund(10_000e6);
            vm.prank(mgr);
            v.openTrade(OpenParams(ETH, true, 2_000e6, 5_000, cl[ETH_USD], 1_000, 0, 0, 0));
            _rollFresh(1);
            return "pending_open_counted";
        }
        if (i >= 13 && i <= 15) {
            // flat at 00:00 UTC (yesterday closed 2% down), first open of the day at 10:00: the keeper sends the
            // day's first check right before it (first-fill), so the baseline is the pre-trade price
            _fund(10_000e6);
            uint32 idx = _open(ETH, true, 2_000e6, 5_000);
            _moveEth(-200);
            v.checkRisk();
            vm.recordLogs();
            // GR2-KEY-01b (WP5 port): the manager's close here would wait the 10-minute minimum hold, which moves the
            // clock and the holding fees the committed fixture records; the guardian's close is never held and leaves
            // the vault in the same state (the closer is not recorded), so the fixture stays as committed
            vm.prank(fGuardian);
            v.closeTrade(idx, cl[ETH_USD]);
            Vm.Log[] memory req = vm.getRecordedLogs();
            _rollFresh(1);
            _fill(req, cl[ETH_USD]);
            _nextDay(10);
            if (i == 13) return "flat_before_first_open_10utc";
            v.checkRisk(); // the pre-trade check
            _open(ETH, true, 2_000e6, 5_000);
            _moveEth(-400);
            if (i == 14) return "flat_open_10utc_loss_4pct";
            _moveEth(-250);
            return "flat_open_10utc_loss_over_limit";
        }
        if (i == 16) {
            // a leverage breach (redemption), then a loss: the breach escalates to daily loss
            _fund(10_000e6);
            _open(ETH, true, 5_600e6, 5_000);
            uint256 shares = v.balanceOf(alice) / 5;
            vm.prank(alice);
            v.requestRedeem(shares, alice, alice);
            _rollFresh(4 * 3_600);
            v.checkRisk();
            vm.prank(keeper);
            v.settle();
            v.checkRisk(); // leverage breach
            _moveEth(-250);
            return "escalate_leverage_to_daily_loss";
        }
        revert("no scenario");
    }

    function _rec(string memory name, string memory field, uint256 value) internal {
        _recStr(name, field, vm.toString(value));
    }

    function _recStr(string memory name, string memory field, string memory value) internal {
        if (writing) {
            vm.serializeString(name, field, value);
        } else {
            assertEq(value, vm.parseJsonString(committed, string.concat(".", name, ".", field)), string.concat(name, ".", field));
        }
    }

    function test_gainsRiskParityFixtures() public {
        writing = vm.envOr("RISK_PARITY_WRITE", false);
        if (!writing) committed = vm.readFile(PATH);
        GainsVaultPolicy pol = v.policy();
        (uint256 maxLev, uint256 maxDaily, uint256 maxDd) = pol.riskLimits();
        string memory root;
        for (uint256 i; i < SCENARIOS; ++i) {
            uint256 snap = vm.snapshotState();
            string memory name = _scenario(i);

            // what the Gains keeper reads before deciding (GainsVaultChain.riskInputs, one block)
            GainsNav.Snapshot memory s = v.venue();
            _recStr(name, "gen", "gains");
            _rec(name, "now", vm.getBlockTimestamp());
            _rec(name, "idle", v.idleAssets());
            _rec(name, "venueValue", s.value);
            _rec(name, "venueNotional", s.notional);
            _rec(name, "totalSupply", v.totalSupply());
            _rec(name, "riskDay", v.riskDay());
            _rec(name, "dayStartSharePrice", v.dayStartSharePrice());
            _rec(name, "peakSharePrice", v.peakSharePrice());
            _rec(name, "breached", v.breached() ? 1 : 0);
            _rec(name, "breachReason", uint8(v.breachReason()));
            _rec(name, "emergency", v.emergency() ? 1 : 0);
            _rec(name, "maxLeverageBps", maxLev);
            _rec(name, "maxDailyLossBps", maxDaily);
            _rec(name, "maxDrawdownBps", maxDd);
            _rec(name, "totalAssets", v.totalAssets());

            // what the contract computes and stores
            vm.prank(stranger);
            (uint256 lev, uint256 daily, uint256 dd) = v.checkRisk();
            _rec(name, "out_leverageBps", lev);
            _rec(name, "out_dailyLossBps", daily);
            _rec(name, "out_drawdownBps", dd);
            _rec(name, "out_riskDay", v.riskDay());
            _rec(name, "out_dayStartSharePrice", v.dayStartSharePrice());
            _rec(name, "out_peakSharePrice", v.peakSharePrice());
            _rec(name, "out_breached", v.breached() ? 1 : 0);
            string memory last;
            if (writing) last = vm.serializeString(name, "out_breachReason", vm.toString(uint8(v.breachReason())));
            else _rec(name, "out_breachReason", uint8(v.breachReason()));
            if (writing) root = vm.serializeString("root", name, last);
            vm.revertToState(snap);
        }
        if (writing) vm.writeJson(root, PATH);
    }
}
