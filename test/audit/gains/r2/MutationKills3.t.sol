// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {R1Base} from "../R1Base.t.sol";
import {GainsRound4Base} from "../../../gains/GainsRound4.t.sol";
import {MockGainsDiamond} from "../../../gains/mocks/GainsMocks.sol";
import {GainsVault} from "../../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../../src/gains/GainsVaultPolicy.sol";
import {GainsVaultFactory} from "../../../../src/gains/GainsVaultFactory.sol";
import {GainsNav} from "../../../../src/gains/GainsNav.sol";
import {IGainsDiamond} from "../../../../src/gains/IGainsDiamond.sol";
import {InitParams, OpenParams, IGainsVaultErrors as E} from "../../../../src/gains/GainsTypes.sol";
import {BreachReason} from "../../../../src/VaultTypes.sol";

/// @notice Round 2 mutation kills, third set (batch b2 survivors; see MutationKills.t.sol for the convention). No test
///         here calls a GainsNav pure helper directly (those are in MutationKillsNavPure.t.sol), so the artifact-swap
///         driver runs this file for every mutant.
contract MutationKills3Test is R1Base {
    function _funded() internal {
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
    }

    function _noZeroLog(address emitter, bytes32 topic, string memory what) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == topic && logs[i].emitter == emitter) {
                assertGt(abi.decode(logs[i].data, (uint256)), 0, what);
            }
        }
    }

    // ------------------------------------------------------------------ policy

    /// Policy#R379 (settling: `|nav - prev| > cap` -> `>=`): a settle may move the NAV by exactly maxNavMoveBps.
    function test_MUT_PolicyR379_navMoveOfExactlyTheCapAllowed() public view {
        uint256 at = vm.getBlockTimestamp();
        uint256 prev = 100_000e6;
        uint256 cap = (prev * 2_000) / 10_000; // maxNavMoveBps 20%
        (uint256 next, bool upd) = policy.nextCheckpoint(prev, at, prev + cap, true);
        assertTrue(upd);
        assertEq(next, prev + cap, "+20% exactly");
        (next, upd) = policy.nextCheckpoint(prev, at, prev - cap, true);
        assertEq(next, prev - cap, "-20% exactly");
    }

    /// Policy#495 / #496 (settling, NAV below the checkpoint: `prev - nav` -> `prev / nav` / `prev % nav`): a 60%
    /// drop is bounded like a rise (100k % 40k = 20k would just pass the 20k cap).
    function test_MUT_Policy495_496_navDropBounded() public {
        uint256 at = vm.getBlockTimestamp();
        vm.expectRevert(abi.encodeWithSelector(GainsVaultPolicy.NavMoved.selector, 40_000e6, 100_000e6));
        policy.nextCheckpoint(100_000e6, at, 40_000e6, true);
    }

    /// Policy#591 / #593 (allowAsset: `assetAllowEta[asset] = 0` deleted / `= 1`): allowing consumes the queue item.
    function test_MUT_Policy591_593_allowConsumesTheQueueItem() public {
        vm.prank(owner);
        policy.queueAllowAsset(SOL);
        vm.warp(policy.assetAllowEta(SOL)); // GR2-CFG-01: the stored eta, not queue + timelock
        policy.allowAsset(SOL);
        assertTrue(policy.isAssetAllowed(SOL));
        assertEq(policy.assetAllowEta(SOL), 0, "queue item consumed");
        vm.expectRevert(GainsVaultPolicy.NothingPending.selector);
        policy.allowAsset(SOL);
    }

    /// Policy#R404 (setPairFeed: `maxLeverage > navBound` -> `>=`): a leverage limit exactly at the NAV bound is
    /// valid (as at initialize and proposeConfig).
    function test_MUT_PolicyR404_feedRotationAtTheBound() public {
        uint256 bound = policy.navBoundLeverageBps(ETH, 2_000);
        GainsVaultPolicy.RiskConfig memory r = _defaultRisk();
        r.maxLeverageBps = uint32(bound);
        (GainsVault v, GainsVaultPolicy p) = _vaultWith(r);
        vm.prank(address(v));
        p.setPairFeed(ETH, address(ethFeed), BTC_MAX_AGE, 20);
    }

    // ------------------------------------------------------------------ trading input checks

    /// Logic#1688 (increaseTrade: zero check -> never) and #R194 (`||` -> `&&`): a leverage delta of 0 is the
    /// vault's own ZeroAmount, not whatever the diamond says.
    function test_MUT_Logic1688_R194_increaseNeedsALeverageDelta() public {
        _funded();
        uint32 idx = _open(vault, ETH, true, 30_000e6, 2_000);
        uint64 px = _px(ETH);
        vm.prank(manager);
        vm.expectRevert(E.ZeroAmount.selector);
        vault.increaseTrade(idx, 1_000e6, 0, px, SLIP);
    }

    /// Logic#1793 (updateLeverage: `newLeverage == 0` check -> never): ZeroAmount, not a division by zero.
    function test_MUT_Logic1793_leverageZeroRejected() public {
        _funded();
        uint32 idx = _open(vault, ETH, true, 30_000e6, 2_000);
        vm.prank(manager);
        vm.expectRevert(E.ZeroAmount.selector);
        vault.updateLeverage(idx, 0);
    }

    /// Logic#R198 (increaseTrade: `collateralDelta > idle` -> `>=`): all of the idle USDC may be added.
    function test_MUT_LogicR198_increaseWithAllTheIdle() public {
        _funded();
        uint32 idx = _open(vault, ETH, true, 50_000e6, 2_000);
        uint256 idle = vault.idleAssets();
        uint64 px = _px(ETH);
        vm.prank(manager);
        vault.increaseTrade(idx, uint120(idle), 1_000, px, SLIP);
    }

    /// Logic#2402 (`_clearApproval`: `if (allowance != 0)` -> always): when Gains pulled exactly the approved
    /// collateral, no second (zero) approval is sent.
    function test_MUT_Logic2402_noZeroApprovalAfterAnExactPull() public {
        _funded();
        vm.recordLogs();
        _request(vault, ETH, true, 30_000e6, 2_000);
        _noZeroLog(address(usdc), keccak256("Approval(address,address,uint256)"), "no zero approval");
        assertEq(usdc.allowance(address(vault), address(diamond)), 0);
    }

    /// Logic#1777 (updateLeverage raise: Order.nav = `idle + value` -> `idle * value`): a leverage raise is checked
    /// against the real NAV. Here the open notional is already above 3x the NAV after a loss, so the raise is
    /// rejected; with NAV = idle x value (50k x 10k in 1e6 units) it would pass.
    function test_MUT_Logic1777_leverageRaiseCheckedAgainstTheNav() public {
        _funded();
        uint32 idx = _open(vault, ETH, true, 50_000e6, 5_000); // 250k notional on 100k
        _setVenueValue(vault, idx, 10_000e6); // NAV 60k: 4.2x
        vm.prank(manager);
        vm.expectRevert();
        vault.updateLeverage(idx, 6_000);
    }

    // ------------------------------------------------------------------ requests

    /// Logic#264 (cancelDepositRequest of a next-epoch deposit: `r.epoch = currentEpoch` -> `= 1`): the emptied
    /// request belongs to the current epoch again (GR1-32).
    function test_MUT_Logic264_cancelledDeferredDepositBackInTheCurrentEpoch() public {
        _funded();
        _settle();
        _settle(); // epoch 3
        usdc.mint(manager, 1_000e6);
        vm.startPrank(manager);
        usdc.approve(address(vault), type(uint256).max);
        vault.requestDeposit(1_000e6, manager); // insider: next epoch
        (uint256 e,,) = vault.requests(manager);
        assertEq(e, vault.currentEpoch() + 1);
        vault.cancelDepositRequest();
        vm.stopPrank();
        (e,,) = vault.requests(manager);
        assertEq(e, vault.currentEpoch(), "back in the current epoch");
    }

    // ------------------------------------------------------------------ settle pricing with a zero checkpoint

    /// Logic#R111 (exit-only: `checkpointNav > 0 && checkpointNav < nav` -> `>= 0`): after an emergency settle at a
    /// NAV of 0 (a trade valued at 0 near its liquidation price) the stored checkpoint is 0; when the trade recovers,
    /// the next exit is paid at the live NAV, not at that 0.
    function test_MUT_LogicR111_exitAfterAZeroCheckpointPaysTheNav() public {
        uint32 idx = _fundVenue(100_000e6);
        vm.prank(guardian);
        vault.triggerEmergency();
        _setVenueValue(vault, idx, 0);
        vm.prank(guardian);
        vault.settle(); // exit-only at NAV 0: checkpoint 0
        assertEq(vault.checkpointNav(), 0);
        _setVenueValue(vault, idx, 50_000e6);
        usdc.mint(address(vault), 20_000e6); // NAV 70k, 20k idle
        uint256 sh = vault.balanceOf(alice) / 10;
        uint256 expected = vault.convertToAssets(sh);
        _redeem(alice, sh);
        vm.prank(guardian);
        vault.settle();
        (,,, uint256 paid,,,,) = vault.epochs(vault.currentEpoch() - 1);
        assertGt(expected, 6_000e6);
        assertApproxEqRel(paid, expected, 1e15, "paid at the live NAV");
    }

    /// Logic#R117 (redemption-only: `cp > 0 && cp < nav` -> `cp >= 0`): with maxNavMoveBps = 100% a checkRisk can
    /// store a checkpoint of 0 (NAV 0, clamp prev - cap = 0) while a drawdown breach is on; when the NAV recovers, the
    /// redemption-only settle pays at the live NAV, not at 0.
    function test_MUT_LogicR117_redemptionOnlyAfterAZeroCheckpointPaysTheNav() public {
        GainsVaultPolicy.RiskConfig memory r = _defaultRisk();
        r.maxNavMoveBps = 10_000;
        (GainsVault v,) = _vaultWith(r);
        _depositTo(v, alice, 100_000e6);
        _settleV(v);
        v.claim(alice);
        uint32 idx = _open(v, ETH, true, 100_000e6, 1_000);
        _setVenueValue(v, idx, 100_000e6);
        v.checkRisk();
        _setVenueValue(v, idx, 80_000e6);
        _skip(1 hours);
        v.checkRisk();
        assertEq(uint8(v.breachReason()), uint8(BreachReason.DRAWDOWN));
        _setVenueValue(v, idx, 0);
        _skip(1 hours);
        v.checkRisk();
        assertEq(v.checkpointNav(), 0, "checkpoint 0, breach still on");
        assertEq(uint8(v.breachReason()), uint8(BreachReason.DRAWDOWN));
        _setVenueValue(v, idx, 50_000e6);
        usdc.mint(address(v), 20_000e6); // NAV 70k, 20k idle
        uint256 sh = v.balanceOf(alice) / 10;
        uint256 expected = v.convertToAssets(sh);
        _redeemFrom(v, alice, sh);
        vm.prank(manager);
        v.settle(); // redemption-only
        (,,, uint256 paid,,,,) = v.epochs(v.currentEpoch() - 1);
        assertGt(expected, 6_000e6);
        assertApproxEqRel(paid, expected, 1e15, "paid at the live NAV");
    }

    // ------------------------------------------------------------------ settle: risk references

    /// Logic#1110 (first mint into an EMPTY vault: `peakSharePrice = price` deleted): a vault that emptied out and is
    /// refilled starts its drawdown peak from the new price, not from the old holders' peak (which would put the new
    /// depositors in a drawdown breach they never had).
    function test_MUT_Logic1110_refilledVaultRestartsThePeak() public {
        _funded();
        usdc.mint(address(vault), 10_000e6); // +10%
        _skip(1 hours);
        vault.checkRisk();
        vm.prank(manager);
        vault.settle(); // charges the fees of the hour, raises the peak
        uint256 oldPeak = vault.peakSharePrice();
        // everyone leaves in the same block (no fee accrues: elapsed 0)
        _redeem(alice, vault.balanceOf(alice));
        uint256 fr = vault.balanceOf(feeRecipient);
        vm.prank(feeRecipient);
        vault.requestRedeem(fr, feeRecipient, feeRecipient);
        vm.prank(manager);
        vault.settle();
        assertEq(vault.totalSupply(), 0, "empty");
        _claim(alice);
        vault.claim(feeRecipient);
        // a new depositor refills it
        _deposit(bob, 1_000e6);
        _settle();
        (,,,,,, uint256 price,) = vault.epochs(vault.currentEpoch() - 1);
        assertLt(price, oldPeak);
        assertEq(vault.peakSharePrice(), price, "peak restarts at the refill price");
    }

    /// Math#151-#155 (priceAt: `10 ** DECIMALS_OFFSET` -> 10+6 / 10-6 / 10*6 / 10/6 / 10%6): the risk price uses the
    /// same virtual offset as the share conversions. Visible with a small supply: one share unit plus the fee shares.
    function test_MUT_Math151_155_riskPriceOffset() public {
        _deposit(alice, 10e6);
        _settle();
        _claim(alice);
        _redeem(alice, vault.balanceOf(alice) - 1);
        _settle();
        _claim(alice);
        usdc.mint(address(vault), 1_000e6);
        _skip(1 days);
        vault.checkRisk(); // new day: dayStartSharePrice = priceAt(equity, supply)
        uint256 supply = vault.totalSupply();
        assertLt(supply, 1e9, "small supply");
        uint256 expected = Math.mulDiv(vault.idleAssets() + 1, 1e12, supply + 1e6);
        assertEq(vault.dayStartSharePrice(), expected);
    }

    // ------------------------------------------------------------------ fees

    /// Logic#1298 (`if (feeAssets > 0 && feeAssets < assets)` -> always), #R155 (`&&` -> `||`) and #1219 (`elapsed =
    /// now - last` -> `now % last`): a management fee that would exceed the NAV (fees not accrued for 50+ years at 2%)
    /// is skipped, not an underflow that blocks accrueFees and every settle.
    function test_MUT_Logic1298_feeAboveNavSkipped() public {
        _deposit(alice, 1_000e6);
        _settle();
        _claim(alice);
        uint256 supply = vault.totalSupply();
        _skip(60 * 365 days);
        vault.accrueFees();
        assertEq(vault.totalSupply(), supply, "nothing minted");
    }

    /// Logic#R156 (`feeAssets < assets` -> `<=`): exactly 50 years at 2% is a fee equal to the NAV: skipped, not a
    /// division by zero.
    function test_MUT_LogicR156_feeEqualToNavSkipped() public {
        _deposit(alice, 1_000e6);
        _settle();
        _claim(alice);
        uint256 supply = vault.totalSupply();
        _skip(50 * 365 days);
        vault.accrueFees();
        assertEq(vault.totalSupply(), supply, "nothing minted");
    }

    /// Logic#1425 (`if (feeShares > 0 && newPrice < price)` -> always) and #R170: a vault whose NAV collapsed to dust
    /// (share price rounds to 0) still accrues fees; rescaling the risk references by 0 / 0 would revert.
    function test_MUT_Logic1425_dustNavAccruesWithoutRevert() public {
        uint32 idx = _fundVenue(100_000e6);
        _setVenueValue(vault, idx, 1); // NAV 1 wei, 1e17 share units: price 0
        assertEq(vault.sharePrice(), 0);
        _skip(1 days);
        vault.accrueFees();
    }

    /// Logic#R172 (`feeShares > 0 && newPrice < price` -> `||`) and #R173 (`<` -> `<=`): a dust NAV (2 wei) whose fee
    /// still mints shares (1 wei of fee after 26 years) leaves the price at 0 / 0: no rescale.
    function test_MUT_LogicR172_R173_dustFeeMintNoRescale() public {
        uint32 idx = _fundVenue(100_000e6);
        _setVenueValue(vault, idx, 2);
        uint256 supply = vault.totalSupply();
        _skip(26 * 365 days);
        vault.accrueFees();
        assertGt(vault.totalSupply(), supply, "the fee minted shares");
        assertEq(vault.sharePrice(), 0);
    }

    /// Logic#1289 (performance fee: `price - HWM` -> `price % HWM`): a gain of more than 100% over the high water mark
    /// is charged in full (the checkpoint is ratcheted up by hourly checkRisk calls, 20% each).
    function test_MUT_Logic1289_performanceFeeOnMoreThanDoubling() public {
        _funded();
        usdc.mint(address(vault), 150_000e6); // NAV 250k: +150%
        for (uint256 i; i < 7; ++i) {
            _skip(1 hours);
            vault.checkRisk();
        }
        assertEq(vault.checkpointNav(), vault.totalAssets(), "checkpoint caught up");
        vm.prank(manager);
        vault.settle();
        // 20% of the 150k gain = 30k (plus ~16 USDC of management fee)
        assertGt(vault.convertToAssets(vault.balanceOf(feeRecipient)), 29_000e6);
    }
}

/// @notice Fee mints of a factory vault (protocol share) and the risk references of an empty settle.
contract MutationKills3FactoryTest is R1Base {
    address internal creator = makeAddr("mk3-creator");
    address internal agentW = makeAddr("mk3-agent");

    /// The FundFlowR2 factory vault: seed 1 USDC (idle, no shares), hosted (protocol share 33%), creator is owner,
    /// manager and fee recipient.
    function _factoryVault() internal returns (GainsVault v) {
        bytes32 salt = bytes32(uint256(77));
        address predicted = platform.predictVaultAddress(creator, salt);
        vm.startPrank(platformOwner);
        platform.setLauncherAllowed(creator, true);
        platform.registerPlatformAgent(agentW, predicted);
        vm.stopPrank();
        usdc.mint(creator, 1e6);
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        usdc.approve(address(platform), 1e6);
        uint32[] memory assets = new uint32[](2);
        assets[0] = BTC;
        assets[1] = ETH;
        GainsVaultFactory.CreateParams memory cp = GainsVaultFactory.CreateParams({
            name: "MK3",
            symbol: "MK3",
            owner: creator,
            manager: creator,
            feeRecipient: creator,
            managementFeeBps: 200,
            performanceFeeBps: 2_000,
            timelockDelay: 2 days,
            depositCap: 50_000e6, // the factory requires 0 < cap <= maxDepositCap (50k)
            risk: _defaultRisk(),
            assets: assets,
            agent: agentW,
            agentSig: "",
            agentDeadline: 0,
            operator: address(0),
            hosted: true,
            seedUsdc: 1e6,
            salt: salt
        });
        vm.prank(creator);
        (address va,) = platform.create{value: 0.001 ether}(cp, GainsVaultFactory.PermitData(0, 0, 0, bytes32(0), bytes32(0)));
        v = GainsVault(va);
        vm.prank(alice);
        usdc.approve(va, type(uint256).max);
    }

    function _noZeroTransfer(address v) internal {
        bytes32 t = keccak256("Transfer(address,address,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == t && logs[i].emitter == v) {
                assertGt(abi.decode(logs[i].data, (uint256)), 0, "no zero-amount share mint");
            }
        }
    }

    /// A factory vault holding ONE share unit and 2,000 USDC (alice keeps one unit, everything settles in the same
    /// block so no fee share is minted on the way): a share unit is worth ~2,000 USDC, so a small fee rounds to 0 or
    /// 1 share unit.
    function _tinySupplyVault() internal returns (GainsVault v) {
        v = _factoryVault();
        _depositTo(v, alice, 1_000e6);
        _settleV(v);
        v.claim(alice);
        _redeemFrom(v, alice, v.balanceOf(alice) - 1);
        vm.prank(creator);
        v.settle(); // same block: no fee accrues
        v.claim(alice);
        assertEq(v.totalSupply(), 1, "one share unit");
        usdc.mint(address(v), 2_000e6);
        v.accrueFees();
    }

    /// Logic#1378 / #R163 (`if (protocolShares > 0) mint(protocol)` -> always / `>= 0`) and #1388 / #R165 (`if
    /// (feeShares > protocolShares) mint(feeRecipient)` -> always / `>=`): a fee too small to round to a share mints
    /// nothing (no zero-amount Transfer to the protocol treasury or the fee recipient): one second of the 2% fee on
    /// ~2,000 USDC is 1 wei, i.e. 0 share units.
    function test_MUT_Logic1378_1388_dustFeeMintsNothing() public {
        GainsVault v = _tinySupplyVault();
        _skip(1);
        vm.recordLogs();
        v.accrueFees();
        _noZeroTransfer(address(v));
        assertEq(v.totalSupply(), 1, "fee rounds to 0 shares");
    }

    /// Logic#1378 / #R163 alone: a fee of one share unit (2,400 s: ~3,044 wei of fee) is all the fee recipient's (33%
    /// of 1 rounds to 0 for the protocol); no zero-amount Transfer to the treasury.
    function test_MUT_Logic1378_oneUnitFeeNoProtocolMint() public {
        GainsVault v = _tinySupplyVault();
        uint256 fr = v.balanceOf(creator);
        _skip(2_400);
        vm.recordLogs();
        v.accrueFees();
        _noZeroTransfer(address(v));
        uint256 minted = v.totalSupply() - 1;
        assertGt(minted, 0, "a fee share was minted");
        assertLt(minted, 4, "small enough that 33% rounds to 0");
        assertEq(v.balanceOf(creator) - fr, minted, "all of it to the fee recipient");
        assertEq(v.balanceOf(protocolTreasury), 0);
    }

    /// Logic#R140 (`supply == 0 && depShares > 0` -> `depShares >= 0`): a settle that mints nothing leaves the risk
    /// references of an empty vault alone.
    function test_MUT_LogicR140_emptySettleKeepsTheRiskReferences() public {
        GainsVault v = _factoryVault();
        uint256 d0 = v.dayStartSharePrice();
        vm.prank(creator);
        v.settle();
        assertEq(v.totalSupply(), 0);
        // the mutant's only visible write: toAssets(ONE_SHARE, nav, 0) = 1e6 into HWM / peak (their initial values)
        // and into dayStartSharePrice (not read while supply == 0, overwritten by the first mint)
        assertEq(v.dayStartSharePrice(), d0, "day start untouched by an empty settle");
        assertEq(v.highWaterMark(), 1e6, "initial high water mark kept");
        assertEq(v.peakSharePrice(), 1e6, "initial peak kept");
    }
}

/// @notice Protocol share bookkeeping (leaveHosted / lowerProtocolShare). This test contract plays the factory.
contract MutationKills3ShareTest is R1Base {
    function protocolFeeRecipient() external view returns (address) {
        return protocolTreasury;
    }

    /// @dev A vault with a factory requires 0 < depositCap <= factory.maxDepositCap().
    function maxDepositCap() external pure returns (uint256) {
        return type(uint256).max;
    }

    function _hostedVault(uint16 protocolBps, uint16 baseBps) internal returns (GainsVault v) {
        uint32[] memory assets = new uint32[](2);
        assets[0] = BTC;
        assets[1] = ETH;
        v = GainsVault(Clones.clone(address(vaultImpl)));
        GainsVaultPolicy p = GainsVaultPolicy(Clones.clone(address(policyImpl)));
        p.initialize(owner, _defaultRisk(), assets, 2 days, address(platform), address(v));
        InitParams memory ip = _standaloneParams(p);
        ip.factory = address(this);
        ip.protocolShareBps = protocolBps;
        ip.baseShareBps = baseBps;
        ip.hosted = true;
        ip.depositCap = 1_000_000e6;
        v.initialize(ip);
    }

    /// Logic#1529 / #1537 / #R180 (lowerProtocolShare: the base share raised to newBps): lowering the hosted share
    /// to a value above the base leaves the base alone, so leaving the hosted strategy still drops to the base.
    function test_MUT_Logic1529_1537_R180_lowerAboveTheBaseKeepsTheBase() public {
        GainsVault v = _hostedVault(3_300, 1_000);
        v.lowerProtocolShare(2_000);
        assertEq(v.protocolShareBps(), 2_000);
        assertEq(v.baseShareBps(), 1_000, "base unchanged");
        vm.prank(owner);
        v.leaveHosted();
        assertEq(v.protocolShareBps(), 1_000, "drops to the base");
    }

    /// Logic#1530 / #1538 (lowerProtocolShare: the base never lowered): lowering below the base lowers the base too.
    function test_MUT_Logic1530_1538_lowerBelowTheBaseLowersTheBase() public {
        GainsVault v = _hostedVault(3_300, 1_000);
        v.lowerProtocolShare(500);
        assertEq(v.baseShareBps(), 500);
    }

    /// Logic#1490 (leaveHosted: `if (base < protocol) protocol = base` -> always): leaving never RAISES the share
    /// (a vault whose hosted share is below the base keeps it).
    function test_MUT_Logic1490_leaveHostedNeverRaisesTheShare() public {
        GainsVault v = _hostedVault(1_000, 2_000);
        vm.prank(owner);
        v.leaveHosted();
        assertEq(v.protocolShareBps(), 1_000);
    }

    /// Logic#R159 (`factory != 0 && protocolShareBps > 0` -> `||`): a standalone vault (no factory) with a protocol
    /// share configured accrues fees without asking address(0) for a recipient.
    function test_MUT_LogicR159_standaloneVaultWithAShareAccrues() public {
        uint32[] memory assets = new uint32[](2);
        assets[0] = BTC;
        assets[1] = ETH;
        GainsVault v = GainsVault(Clones.clone(address(vaultImpl)));
        GainsVaultPolicy p = GainsVaultPolicy(Clones.clone(address(policyImpl)));
        p.initialize(owner, _defaultRisk(), assets, 2 days, address(platform), address(v));
        InitParams memory ip = _standaloneParams(p);
        ip.protocolShareBps = 1_000;
        v.initialize(ip);
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        _depositTo(v, alice, 1_000e6);
        _settleV(v);
        uint256 supply = v.totalSupply();
        _skip(1 days);
        v.accrueFees();
        assertGt(v.totalSupply(), supply, "fee minted to the fee recipient");
        assertEq(v.balanceOf(protocolTreasury), 0);
    }
}

/// @dev A mock diamond whose stored trades can be rewritten field by field (layout-guard tests).
contract LayoutDiamond is MockGainsDiamond {
    constructor(IERC20 usdc_) MockGainsDiamond(usdc_) {}

    function setLev(address user, uint32 i, uint24 lev) external {
        _trades[user][i].leverage = lev;
    }

    function setColl(address user, uint32 i, uint120 c) external {
        _trades[user][i].collateralAmount = c;
    }

    function setSize(address user, uint32 i, uint160 s) external {
        _trades[user][i].positionSizeToken = s;
    }
}

/// @notice GainsNav layout guards (_plausible, _checkSize) at their boundaries.
contract MutationKills3LayoutTest is R1Base {
    LayoutDiamond internal ld;

    function setUp() public override {
        super.setUp();
        ld = new LayoutDiamond(IERC20(address(usdc)));
        usdc.mint(address(ld), 100_000_000e6);
        diamond = ld;
        (vault, policy) = _vaultWith(_defaultRisk());
        _depositTo(vault, alice, 100_000e6);
        _settleV(vault);
        vault.claim(alice);
    }

    function _limit() internal returns (uint32 idx) {
        OpenParams memory lim = _params(ETH, true, 20_000e6, 2_000);
        lim.tradeType = 1; // LIMIT: rests as an open trade, not size-checked
        lim.expectedPrice = _px(ETH) * 9 / 10;
        vm.prank(manager);
        vault.openTrade(lim);
        idx = ld.tradeCount(address(vault)) - 1;
    }

    /// Nav#R325 (_plausible `leverage > 0` -> `>= 0`): a resting order read with leverage 0 is a layout change.
    function test_MUT_NavR325_restingOrderWithoutLeverageIsALayoutChange() public {
        uint32 idx = _limit();
        ld.setLev(address(vault), idx, 0);
        vm.expectRevert(GainsNav.DiamondLayoutChanged.selector);
        vault.venue();
    }

    /// Nav#R331 (_plausible `collateralAmount > 0` -> `>= 0`): same for collateral 0.
    function test_MUT_NavR331_restingOrderWithoutCollateralIsALayoutChange() public {
        uint32 idx = _limit();
        ld.setColl(address(vault), idx, 0);
        vm.expectRevert(GainsNav.DiamondLayoutChanged.selector);
        vault.venue();
    }

    /// Nav#R338 (`size * 4 < expected` -> `<=`) and #R341 (`size > expected * 4` -> `>=`): the factor-4 tolerance is
    /// inclusive at both ends.
    function test_MUT_NavR338_R341_sizeToleranceInclusive() public {
        uint32 idx = _open(vault, ETH, true, 30_000e6, 2_000);
        IGainsDiamond.Trade memory t = ld.getTrade(address(vault), idx);
        uint256 expected = (uint256(t.collateralAmount) * 1e12 * t.leverage * 1e10) / (1e3 * uint256(t.openPrice));
        assertEq(expected % 4, 0, "chosen to divide by 4");
        ld.setSize(address(vault), idx, uint160(expected / 4));
        vault.venue();
        ld.setSize(address(vault), idx, uint160(expected * 4));
        vault.venue();
    }
}

/// @notice Fee pair of pending orders on a pair other than ETH (pair 1): BTC (pair 0) has no fee, ETH has one.
contract MutationKills3FeePairTest is R1Base {
    function setUp() public override {
        super.setUp();
        diamond.setPair(ETH, 6e8, 285.7e18, 0.1e18, 0);
        _deposit(alice, 200_000e6);
        _settle();
        _claim(alice);
        assertGt(diamond.minGovFee(ETH), 0);
        assertEq(diamond.minGovFee(BTC), 0);
    }

    /// Nav#225 (`feePair = o.trade.pairIndex` -> 1): a pending BTC open keeps BTC's gov fee (0), not ETH's.
    function test_MUT_Nav225_pendingOpenFeeOfItsPair() public {
        uint256 v0 = vault.venue().value;
        _request(vault, BTC, true, 10_000e6, 2_000);
        assertEq(vault.venue().value, v0 + 10_000e6);
    }

    /// Nav#352 (MARKET_PARTIAL_OPEN `feePair = t.pairIndex` -> 1): same for a pending increase of a BTC trade.
    function test_MUT_Nav352_pendingIncreaseFeeOfItsPair() public {
        uint32 idx = _open(vault, BTC, true, 50_000e6, 2_000);
        uint256 v0 = vault.venue().value;
        uint64 px = _px(BTC);
        vm.prank(manager);
        vault.increaseTrade(idx, 10_000e6, 1_000, px, SLIP);
        assertEq(vault.venue().value, v0 + 10_000e6);
    }

    /// Nav#331 (UPDATE_LEVERAGE `feePair = t.pairIndex` -> 1): same for a pending leverage decrease of a BTC trade.
    function test_MUT_Nav331_pendingLeverageDecreaseFeeOfItsPair() public {
        uint32 idx = _open(vault, BTC, true, 50_000e6, 2_000);
        uint256 v0 = vault.venue().value;
        vm.prank(manager);
        vault.updateLeverage(idx, 1_000); // pulls 50k of margin
        assertEq(vault.venue().value, v0 + 50_000e6);
    }

    function _mockCumul(uint32 idx, bool flag, int256 impact) internal {
        IGainsDiamond.Trade memory t = diamond.getTrade(address(vault), idx);
        uint256 size = (uint256(t.collateralAmount) * t.leverage) / 1e3;
        uint256 sizeUsd = diamond.getUsdNormalizedValue(3, size);
        vm.mockCall(
            address(diamond),
            abi.encodeWithSelector(IGainsDiamond.getTradeCumulVolPriceImpactP.selector, address(vault), t.pairIndex, t.long, sizeUsd, flag),
            abi.encode(impact)
        );
    }

    /// Nav#533 (close impact pass 1: fees `feesTiered + (holding - realized)` -> `*`): a trade well in profit takes
    /// the positive-pnl impact (here 0); with the product the fees swamp the value, pass 1 sees a loss and the -1%
    /// negative-pnl impact would apply.
    function test_MUT_Nav533_passOneFeesAreASum() public {
        uint32 idx = _open(vault, ETH, true, 10_000e6, 10_000); // 100k notional
        diamond.setHolding(address(vault), idx, 10e6);
        _setPrice(ETH, uint64((uint256(_px(ETH)) * 105) / 100)); // +5%: ~+50% on the collateral
        uint256 v0 = vault.venue().value;
        assertGt(v0, 13_000e6);
        _mockCumul(idx, false, -1e10);
        _mockCumul(idx, true, 0);
        assertEq(vault.venue().value, v0, "pass 1 sees the profit: no impact");
    }
}

/// @notice Redemption-only settle without deposits: no carry run is opened.
contract MutationKills3CarryTest is GainsRound4Base {
    /// Logic#1021 / #R130 (redemption-only: `if (pendingDepositAssets > 0)` -> always / `>= 0`): a redemption-only
    /// settle with an empty deposit queue records no carry (carry(epoch).carriedFrom == 0) and opens no carry run.
    function test_MUT_Logic1021_noCarryWithoutDeposits() public {
        _warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 21 hours);
        _fund(100_000e6);
        _warp((vm.getBlockTimestamp() / 1 days) * 1 days + 23 hours + 30 minutes);
        _nav(93_000e6); // -7% on the day: daily loss breach
        vault.checkRisk();
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DAILY_LOSS));
        uint256 epoch = vault.currentEpoch();
        vm.prank(manager);
        vault.settle(); // redemption-only, nothing queued
        (uint256 carriedFrom, uint256 pricedIn) = vault.carry(epoch);
        assertEq(carriedFrom, 0, "no carry run");
        assertEq(pricedIn, 0);
    }
}
