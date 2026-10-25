// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GainsRound4Base} from "../../../gains/GainsRound4.t.sol";
import {R1Base} from "../R1Base.t.sol";
import {GainsVault} from "../../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../../src/gains/GainsVaultPolicy.sol";
import {IGainsVaultErrors as E} from "../../../../src/gains/GainsTypes.sol";
import {BreachReason} from "../../../../src/VaultTypes.sol";
import {MockGainsDiamond} from "../../../gains/mocks/GainsMocks.sol";

/// @notice Round 2 mutation kills that need the round 4 carry helpers (see MutationKills.t.sol for the convention).
contract MutationKillsCarryTest is GainsRound4Base {
    /// Math#418 (claimableWithCarry `!carried && pe.depositAssets > 0` -> true): a deposit still carried by a
    /// redemption-only epoch is worth nothing yet. With the guard gone it is "refunded" out of the claim reserve while
    /// it also stays queued: here bob would take 5k of alice's redemption payout.
    function test_MUT_Math418_carriedDepositPaysNothingFromTheReserve() public {
        _fund(100_000e6); // alice holds the vault, all on the venue
        _deposit(bob, 10_000e6);
        _skip(1 hours);
        vault.checkRisk();
        vm.prank(manager);
        vault.settle();
        vault.claim(bob); // bob holds shares too
        _redeem(alice, vault.balanceOf(alice) / 10);
        _deposit(bob, 5_000e6);
        _warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 60);
        _nav(82_000e6); // (82k + 10k idle) / 110k: drawdown breach
        for (uint256 i; i < 3; ++i) {
            _skip(1 hours);
            vault.checkRisk();
        }
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DRAWDOWN));
        vm.prank(manager);
        vault.settle(); // redemption-only: alice paid into the reserve, bob's 5k carried
        uint256 reserve = vault.claimableRedeemAssets();
        assertGt(reserve, 5_000e6, "alice's payout is reserved");
        uint256 b0 = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.requestRedeem(1e6, bob, bob); // runs _claimIfSettled(bob) on the carried request
        assertEq(usdc.balanceOf(bob), b0, "nothing paid for a carried deposit");
        assertEq(vault.claimableRedeemAssets(), reserve, "alice's reserve untouched");
        (, uint256 dep,) = vault.requests(bob);
        assertEq(dep, 5_000e6, "still queued");
    }

    /// Logic#825 (settle's `_checkpoint($, nav, true)` deleted): a normal settle is bounded by the NAV checkpoint
    /// (audit C-01): it reverts NavMoved when NAV moved more than maxNavMoveBps (20%) since the last checkpoint, and
    /// StaleCheckpoint when that checkpoint is older than a day. (Unit tests call policy.nextCheckpoint directly;
    /// this pins the call in settle.)
    function test_MUT_Logic825_settleBoundedByTheCheckpoint() public {
        _fund(100_000e6);
        _deposit(bob, 1_000e6);
        _skip(1 hours);
        vault.checkRisk(); // checkpoint ~100k
        _nav(125_000e6); // +25% inside the hour: checkRisk may not move the checkpoint that far
        vm.prank(manager);
        vm.expectPartialRevert(GainsVaultPolicy.NavMoved.selector);
        vault.settle();
        _nav(100_000e6);
        _skip(1 days + 1); // checkpoint now older than CHECKPOINT_MAX_AGE, nobody called checkRisk
        _deposit(alice, 1_000e6);
        vm.prank(manager);
        vm.expectRevert(GainsVaultPolicy.StaleCheckpoint.selector);
        vault.settle();
    }
}

/// @dev Gains leaves trade.pairIndex 0 on pending orders that refer to an existing trade (partial open, leverage
///      update; GR1-28). The shared mock copies the pair; this one can zero it, as the real diamond stores it.
contract ZeroPairDiamond is MockGainsDiamond {
    constructor(IERC20 usdc_) MockGainsDiamond(usdc_) {}

    function zeroPair(address user, uint32 orderIndex) external {
        _orders[user][orderIndex].trade.pairIndex = 0;
    }
}

contract MutationKillsFeePairTest is R1Base {
    ZeroPairDiamond internal zp;

    function setUp() public override {
        super.setUp();
        zp = new ZeroPairDiamond(IERC20(address(usdc)));
        usdc.mint(address(zp), 100_000_000e6);
        diamond = zp; // _standaloneParams reads it
        (vault, policy) = _vaultWith(_defaultRisk());
        zp.setPair(ETH, 6e8, 285.7e18, 0.1e18, 0); // 0.06% fee on ETH; BTC (pair 0) keeps fee 0
    }

    function _funded() internal returns (uint32 idx) {
        _depositTo(vault, alice, 100_000e6);
        _settleV(vault);
        vault.claim(alice);
        idx = _open(vault, ETH, true, 50_000e6, 2_000);
    }

    /// Nav#328 / #329 (UPDATE_LEVERAGE: `feePair = t.pairIndex` deleted / 0): a pending leverage decrease is valued
    /// at its collateral minus the gov fee of the TRADE's pair, not of pair 0.
    function test_MUT_Nav328_329_leverageDecreaseFeeOfTheTradePair() public {
        uint32 idx = _funded();
        uint256 v0 = vault.venue().value;
        vm.prank(manager);
        vault.updateLeverage(idx, 1_000); // 2x -> 1x pulls 50k of margin, pending
        zp.zeroPair(address(vault), zp.orderCount(address(vault)) - 1);
        uint256 fee = zp.minGovFee(ETH);
        assertGt(fee, 0);
        assertEq(vault.venue().value, v0 + 50_000e6 - fee, "held minus the ETH gov fee");
    }

    /// Nav#349 / #350 (MARKET_PARTIAL_OPEN: `feePair = t.pairIndex` deleted / 0): same for a pending increase.
    function test_MUT_Nav349_350_increaseFeeOfTheTradePair() public {
        uint32 idx = _funded();
        uint256 v0 = vault.venue().value;
        vm.prank(manager);
        vault.increaseTrade(idx, 10_000e6, 1_000, _px(ETH), SLIP);
        zp.zeroPair(address(vault), zp.orderCount(address(vault)) - 1);
        assertEq(vault.venue().value, v0 + 10_000e6 - zp.minGovFee(ETH), "held minus the ETH gov fee");
    }
}

/// @notice Round 2 mutation kills on the redemption-only (loss breach) settle path.
contract MutationKillsBreachSettleTest is GainsRound4Base {
    function _insiderDeposit(uint256 amount) internal {
        usdc.mint(manager, amount);
        vm.startPrank(manager);
        usdc.approve(address(vault), type(uint256).max);
        vault.requestDeposit(amount, manager);
        vm.stopPrank();
    }

    /// Daily loss breach at 23:30 (same UTC day as the `_fund` deposit), cleared by the first checkRisk of the next day.
    function _dailyLossAt2330(uint256 insiderAmount) internal {
        _warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 21 hours);
        _fund(100_000e6);
        if (insiderAmount > 0) _insiderDeposit(insiderAmount); // before the breach: deposits close in one
        _warp((vm.getBlockTimestamp() / 1 days) * 1 days + 23 hours + 30 minutes);
        _nav(93_000e6); // -7% on the day (limit 5%), drawdown 7% (limit 15%)
        vault.checkRisk();
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DAILY_LOSS));
    }

    /// Logic#1066 / #1067 (redemption-only: `pendingDepositAssets += deferredDepositAssets` deleted / += 0) and
    /// #1056 / #1063 / #1064 (`insiderInQueue = true` skipped): an insider's next-epoch deposit joins the carried
    /// queue (it stays reserved, never becomes the holders' idle USDC), and the epoch that now holds it keeps the
    /// one-hour minimum age even after the insider cancels.
    function test_MUT_Logic1066_1056_insiderDepositAcrossARedemptionOnlySettle() public {
        _dailyLossAt2330(5_000e6);
        assertEq(vault.deferredDepositAssets(), 5_000e6);
        uint256 idle0 = vault.idleAssets();
        vm.prank(manager);
        vault.settle(); // redemption-only
        assertEq(vault.pendingDepositAssets(), 5_000e6, "deferred joined the queue");
        assertEq(vault.deferredDepositAssets(), 0);
        assertEq(vault.idleAssets(), idle0, "still reserved, not the holders' USDC");
        _warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 5 minutes); // 00:05, epoch 35 min old
        vault.checkRisk(); // new day: daily loss cleared
        assertFalse(vault.breached());
        vm.prank(manager);
        vault.cancelDepositRequest(); // the queue is empty again, the insider flag stays for this epoch
        vm.prank(manager);
        vm.expectRevert(E.EpochTooYoung.selector);
        vault.settle();
    }

    /// Logic#1055 (redemption-only: `if (deferred > 0) insiderInQueue = true` -> always): with no insider deposit
    /// the next normal settle carries no age requirement.
    function test_MUT_Logic1055_noInsiderNoAgeAfterRedemptionOnly() public {
        _dailyLossAt2330(0);
        vm.prank(manager);
        vault.settle(); // redemption-only, nothing queued
        _warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 5 minutes);
        vault.checkRisk();
        assertFalse(vault.breached());
        vm.prank(manager);
        vault.settle(); // 35 min into the epoch, nothing to price: allowed
    }

    /// Logic#1008 / #1020 (normal settle: `insiderInQueue = deferred > 0` deleted / always false): the epoch that
    /// receives insiders' deposits keeps the one-hour minimum age even if they cancel.
    function test_MUT_Logic1008_1020_insiderFlagOnNormalSettle() public {
        _fund(100_000e6);
        _insiderDeposit(5_000e6);
        _skip(1 hours);
        vault.checkRisk();
        vm.prank(manager);
        vault.settle(); // normal: the insider's deposit becomes the next epoch's queue
        vm.prank(manager);
        vault.cancelDepositRequest();
        vm.prank(manager);
        vm.expectRevert(E.EpochTooYoung.selector);
        vault.settle();
    }

    function _drawdown(uint256 navAfter) internal {
        _warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 60);
        _nav(navAfter);
        for (uint256 i; i < 3; ++i) {
            _skip(1 hours);
            vault.checkRisk();
        }
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DRAWDOWN));
    }

    function _recover(uint256 nav) internal {
        _nav(nav);
        _skip(24 hours);
        vm.prank(owner);
        vault.resume();
        for (uint256 i; i < 2; ++i) {
            _skip(1 hours);
            vault.checkRisk();
        }
    }

    /// Logic#1030 (`if (carryOrigin == 0) carryOrigin = epoch + 1` -> always): two CONSECUTIVE redemption-only
    /// settles are one carry run; a deposit carried by the first is priced when the run is priced (with the origin
    /// overwritten it would stay carried forever).
    function test_MUT_Logic1030_consecutiveRedemptionOnlySettlesOneRun() public {
        _fund(100_000e6);
        _deposit(bob, 10_000e6);
        _drawdown(82_000e6);
        vm.prank(manager);
        vault.settle(); // redemption-only #1: bob carried
        _skip(1 hours);
        vault.checkRisk();
        vm.prank(manager);
        vault.settle(); // redemption-only #2: same run
        _recover(100_000e6);
        vm.prank(manager);
        vault.settle(); // prices the run
        vault.claim(bob);
        assertGt(vault.balanceOf(bob), 0, "bob's carried deposit was priced");
        (, uint256 dep,) = vault.requests(bob);
        assertEq(dep, 0);
    }
}
