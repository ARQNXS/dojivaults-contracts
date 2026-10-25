// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GovBase} from "../gov/GovBase.t.sol";
import {console2} from "forge-std/Test.sol";
import {GainsPrice} from "../../../../src/gains/GainsPrice.sol";
import {IGainsDiamond} from "../../../../src/gains/IGainsDiamond.sol";

/// @notice Cross-review of LIVENESS.md section 2 (XREVIEW-LIVE-GNS.md): a combination the scenario table lists only
///         row by row. Row E2 (a pair Gains no longer closes) says "settle pays idle pro rata"; row P1 / GR1-09 (a stale
///         feed) says "flatten that pair, then settle". Together, on the same pair, neither way out exists: the open
///         trade cannot be closed, so every settle mode prices it and reverts PriceStale, and idle USDC is not paid
///         either. Only the vault owner can rotate the feed (setPairFeed is onlySelf, behind the owner's timelock).
contract XReviewLiveGnsStateMachineTest is GovBase {
    function test_GR2_XR_LIVE_staleFeedOnAnUnclosablePair_noSettleModePaysEvenIdle() public {
        _fundFv(10_000e6);
        uint32 idx = _openFv(ETH, 2_000e6, 1_000); // 8k idle covers any redemption below 80%
        uint256 shares = fv.balanceOf(alice) / 4;
        vm.prank(alice);
        fv.requestRedeem(shares, alice, alice);
        vm.prank(platformGuardian);
        fv.triggerEmergency();
        // Gains no longer serves the pair (row E2) and its Chainlink feed is stale or deprecated (row P1)
        vm.mockCallRevert(address(diamond), abi.encodeWithSelector(IGainsDiamond.closeTradeMarket.selector), "pair not served");
        ethFeed.set(ethFeed.answer(), vm.getBlockTimestamp() - 10 days);

        vm.prank(platformGuardian);
        vm.expectRevert();
        fv.closeTrade(idx, _px(ETH));
        uint32[] memory ix = new uint32[](1);
        ix[0] = idx;
        vm.prank(platformGuardian);
        assertEq(fv.flattenIndices(ix, 0, _px(ETH)), 0, "nothing could be sent");

        address[3] memory settlers = [platformSentinel, platformGuardian, keeper];
        for (uint256 i; i < settlers.length; ++i) {
            vm.prank(settlers[i]);
            vm.expectRevert(abi.encodeWithSelector(GainsPrice.PriceStale.selector, uint256(ETH)));
            fv.settle();
        }
        assertEq(fv.pendingRedeemShares(), shares, "the redemption stays unpaid although idle covers it 3x over");

        // no platform role can rotate the feed: the vault's setPairFeed is onlySelf (owner queue + timelock)
        vm.prank(platformGuardian);
        vm.expectRevert();
        fv.setPairFeed(ETH, address(btcFeed), 3_600, 20);
        console2.log("idle USDC held while no settle mode can run", usdc.balanceOf(address(fv)));
    }
}
