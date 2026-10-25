// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GainsBase} from "./GainsBase.t.sol";
import {GainsVault} from "../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../src/gains/GainsVaultPolicy.sol";
import {GainsPrice} from "../../src/gains/GainsPrice.sol";
import {IGainsVaultErrors as E} from "../../src/gains/GainsTypes.sol";
import {MockChainlinkFeed} from "./mocks/GainsMocks.sol";

/// @notice Feed rotation (setPairFeed through the vault timelock): when Chainlink deprecates a feed the vault's
///         prices go stale and settle stops; the owner rotates to the combination the factory curates now.
contract GainsFeedRotationTest is GainsBase {
    MockChainlinkFeed internal ethFeed2;
    uint32 internal ethTrade;

    function setUp() public override {
        super.setUp();
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
        ethTrade = _open(vault, ETH, true, 10_000e6, 2_000);
        ethFeed2 = new MockChainlinkFeed(8, 3_000e8);
    }

    /// @dev Time passes; BTC and the new ETH feed keep updating, the deprecated ETH feed does not.
    function _passDeprecated(uint256 dt) internal {
        uint256 t = vm.getBlockTimestamp() + dt;
        vm.warp(t);
        btcFeed.set(btcFeed.answer(), t);
        solFeed.set(solFeed.answer(), t);
        ethFeed2.set(ethFeed2.answer(), t);
    }

    function _rotate() internal pure returns (bytes memory) {
        return abi.encodeCall(GainsVault.setPairFeed, (ETH, address(0), BTC_MAX_AGE, 20));
    }

    function _rotateTo(address feed, uint32 maxAge, uint16 band) internal pure returns (bytes memory) {
        return abi.encodeCall(GainsVault.setPairFeed, (ETH, feed, maxAge, band));
    }

    function test_DeprecatedFeed_settleBlocked_rotate_settleWorks() public {
        _skip(1 hours); // GR1-02: past INSIDER_MIN_EPOCH_AGE, so the settle below fails on the price, not EpochTooYoung
        _deposit(bob, 10_000e6);
        // Chainlink deprecates the ETH feed: it stops updating.
        _passDeprecated(BTC_MAX_AGE + 1);
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.PriceStale.selector, uint256(ETH)));
        vault.checkRisk();
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.PriceStale.selector, uint256(ETH)));
        vault.settle();

        // The platform curates the replacement; the owner queues the rotation through the vault timelock.
        vm.prank(platformOwner);
        platform.setAssetCurated(ETH, true, address(ethFeed2), BTC_MAX_AGE, 20);
        assertEq(policy.feedOf(ETH).feed, address(ethFeed), "nothing changes for the vault until it rotates");
        bytes memory data = _rotateTo(address(ethFeed2), BTC_MAX_AGE, 20);
        vm.prank(owner);
        vault.queue(data);
        _passDeprecated(1 days);
        vm.expectRevert(E.NotReady.selector);
        vault.execute(data);
        _passDeprecated(vault.queuedEta(keccak256(data)) - vm.getBlockTimestamp()); // hl-r2 exit-before-effect: wait for the stored eta
        vm.expectEmit(address(policy));
        emit GainsVaultPolicy.FeedSet(ETH, address(ethFeed2), BTC_MAX_AGE, 20);
        vault.execute(data);
        assertEq(policy.feedOf(ETH).feed, address(ethFeed2));
        assertEq(policy.price(ETH), 3_000e10);

        // Prices are back: the keeper checkpoints and the epoch settles, bob is minted.
        vault.checkRisk();
        vm.prank(manager);
        vault.settle();
        _claim(bob);
        assertGt(vault.balanceOf(bob), 0);
        assertEq(vault.totalAssets(), vault.idleAssets() + vault.venue().value);
    }

    function test_OnlyTheCuratedCombinationIsAccepted() public {
        vm.prank(platformOwner);
        platform.setAssetCurated(ETH, true, address(ethFeed2), BTC_MAX_AGE, 20);
        bytes[4] memory wrong = [
            _rotateTo(address(btcFeed), BTC_MAX_AGE, 20), // another feed
            _rotateTo(address(ethFeed2), BTC_MAX_AGE + 1, 20), // looser staleness
            _rotateTo(address(ethFeed2), BTC_MAX_AGE, 19), // narrower band than curated
            _rotate() // zero feed
        ];
        for (uint256 i; i < wrong.length; ++i) {
            vm.prank(owner);
            vault.queue(wrong[i]);
        }
        _warp(vault.queuedEta(keccak256(wrong[3]))); // hl-r2 exit-before-effect: wait for the stored eta
        for (uint256 i; i < wrong.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(E.CallFailed.selector, abi.encodeWithSelector(GainsVaultPolicy.FeedNotCurated.selector, ETH))
            );
            vault.execute(wrong[i]);
        }
        // Checked at execution: a combination curated when queued but changed since is refused too.
        bytes memory data = _rotateTo(address(ethFeed2), BTC_MAX_AGE, 20);
        vm.prank(owner);
        vault.queue(data);
        vm.prank(platformOwner);
        platform.setAssetCurated(ETH, true, address(ethFeed2), BTC_MAX_AGE, 30);
        _warp(vault.queuedEta(keccak256(data))); // hl-r2 exit-before-effect: wait for the stored eta
        vm.expectRevert(
            abi.encodeWithSelector(E.CallFailed.selector, abi.encodeWithSelector(GainsVaultPolicy.FeedNotCurated.selector, ETH))
        );
        vault.execute(data);
        // A pair the platform stopped curating cannot be rotated.
        vm.prank(platformOwner);
        platform.setAssetCurated(ETH, false, address(0), 0, 0);
        bytes memory d30 = _rotateTo(address(ethFeed2), BTC_MAX_AGE, 30);
        vm.prank(owner);
        vault.queue(d30);
        _warp(vault.queuedEta(keccak256(d30))); // hl-r2 exit-before-effect: wait for the stored eta
        vm.expectRevert(
            abi.encodeWithSelector(E.CallFailed.selector, abi.encodeWithSelector(GainsVaultPolicy.AssetNotCurated.selector, ETH))
        );
        vault.execute(d30);
        // Nor a pair this vault never allowed (SOL is curated, but not on this policy).
        MockChainlinkFeed sol2 = new MockChainlinkFeed(8, 150e8);
        vm.prank(platformOwner);
        platform.setAssetCurated(SOL, true, address(sol2), SOL_MAX_AGE, 25);
        bytes memory dsol = abi.encodeCall(GainsVault.setPairFeed, (SOL, address(sol2), SOL_MAX_AGE, 25));
        vm.prank(owner);
        vault.queue(dsol);
        _warp(vault.queuedEta(keccak256(dsol))); // hl-r2 exit-before-effect: wait for the stored eta
        vm.expectRevert(
            abi.encodeWithSelector(E.CallFailed.selector, abi.encodeWithSelector(GainsVaultPolicy.AssetNotCurated.selector, SOL))
        );
        vault.execute(dsol);
        assertEq(policy.feedOf(ETH).feed, address(ethFeed));
    }

    function test_VaultLeverageBoundCheckedAgain() public {
        // maxLeverage 3x at maxNavMoveBps 2,000 allows a band up to 83 bps (2000 / (8 x band) >= 3).
        vm.prank(platformOwner);
        platform.setAssetCurated(ETH, true, address(ethFeed2), BTC_MAX_AGE, 84);
        bytes memory data = _rotateTo(address(ethFeed2), BTC_MAX_AGE, 84);
        vm.prank(owner);
        vault.queue(data);
        _warp(vault.queuedEta(keccak256(data))); // hl-r2 exit-before-effect: wait for the stored eta
        vm.expectRevert(
            abi.encodeWithSelector(
                E.CallFailed.selector, abi.encodeWithSelector(GainsVaultPolicy.LeverageAboveNavBound.selector, ETH)
            )
        );
        vault.execute(data);
        vm.prank(platformOwner);
        platform.setAssetCurated(ETH, true, address(ethFeed2), BTC_MAX_AGE, 83);
        _timelocked(vault, _rotateTo(address(ethFeed2), BTC_MAX_AGE, 83));
        assertEq(policy.feedOf(ETH).bandBps, 83);
    }

    function test_OnlyThroughTheVaultTimelock() public {
        vm.prank(platformOwner);
        platform.setAssetCurated(ETH, true, address(ethFeed2), BTC_MAX_AGE, 20);
        // not directly on the vault, not on the policy (even by its owner), not queued by anyone but the owner
        vm.prank(owner);
        vm.expectRevert(E.Unauthorized.selector);
        vault.setPairFeed(ETH, address(ethFeed2), BTC_MAX_AGE, 20);
        vm.prank(owner);
        vm.expectRevert(GainsVaultPolicy.NotVault.selector);
        policy.setPairFeed(ETH, address(ethFeed2), BTC_MAX_AGE, 20);
        bytes memory data = _rotateTo(address(ethFeed2), BTC_MAX_AGE, 20);
        vm.prank(manager);
        vm.expectRevert(E.Unauthorized.selector);
        vault.queue(data);
        // exact calldata length only (audit N-04)
        vm.prank(owner);
        vm.expectRevert(E.Unauthorized.selector);
        vault.queue(abi.encodePacked(data, uint256(0)));
        // the guardian can cancel a queued rotation
        vm.prank(owner);
        bytes32 id = vault.queue(data);
        vm.prank(guardian);
        vault.cancel(id);
        _warp(vault.queuedEta(keccak256(data))); // hl-r2 exit-before-effect: wait for the stored eta
        vm.expectRevert(E.NotQueued.selector);
        vault.execute(data);
    }
}
