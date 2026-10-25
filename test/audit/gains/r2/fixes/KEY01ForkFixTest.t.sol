// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "../XReviewKeyForkBase.sol";

interface ISkewDepthK {
    function getPairSkewDepth(uint8 collateralIndex, uint16 pairIndex) external view returns (uint256);
}

/// @notice GR2-KEY-01 fix test on the real diamond (contracts/audit/gains/r2/fixes/GR2-KEY-01). Run it from
///         contracts/test/audit/gains/r2/fixes/ with
///         ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc GAINS_FORK_BLOCK=$(( $(cast block-number --rpc-url $ARBITRUM_RPC_URL) - 40 ))
///         (or the GAINS_FORK_BLOCK_DEFAULT pin on an archive RPC; XR_FORK_BLOCK, if set, overrides GAINS_FORK_BLOCK)
///         XR_08's vault side: a ~1.06M vault at the live caps sends 250k ETH longs one after the other (the route that
///         let a thief's opposite account net +5,036 USDC per round trip at V = 5M). With the fix the first order that
///         takes the vault's ETH notional above 5 % of ETH's 1 % skew depth (~688k at the measured 13.76M) is refused
///         with OrderRejected("pair depth"); on 4ec6feb all 20 are accepted. Since KEY-01b the cap is the factory's
///         pairSkewCapBps (1 % at launch), and the test asserts the refusal there.
contract KEY01ForkFixTest is XReviewKeyForkBase {
    function test_KEY01_fix_fork_XR08_ethOpensRefusedAtTheSkewDepthCap() public {
        uint256 perTrade = 250_000e6;
        _depositSettle(alice, 20 * perTrade / 5 + 60_000e6);
        uint64 c = cl[_feed(ETH)];
        uint256 depthUsd = ISkewDepthK(address(DIAMOND)).getPairSkewDepth(USDC_INDEX, ETH) * c / 1e22;
        // WP5 port: KEY-01's 5 % cap is superseded by KEY-01b's factory cap (1 % at launch); assert at the cap the
        // factory actually holds. At 517,076,707 ETH's depth is 14.19M, so 1 % is about 142k, below one 250k order: the
        // very first order is refused (the 5 % version allowed two, up to 709.7k).
        uint256 capBps = factory.pairSkewCapBps(ETH);
        assertEq(capBps, 100, "the guardian's launch cap");
        uint256 capUsd = depthUsd * capBps / 10_000;
        console2.log("ETH 1 % skew depth (USDC 1e6) / factory cap", depthUsd, capUsd);
        uint256 opened;
        bool refused;
        for (uint256 i; i < 20; ++i) {
            vm.recordLogs();
            vm.prank(mgr);
            (bool ok, bytes memory ret) =
                address(v).call(abi.encodeCall(GainsVault.openTrade, (_params(ETH, true, uint120(perTrade / 25), 25_000))));
            Vm.Log[] memory req = vm.getRecordedLogs();
            if (!ok) {
                assertEq(ret, abi.encodeWithSignature("OrderRejected(string)", "pair depth"), "refused by the pair cap");
                refused = true;
                break;
            }
            _roll(1);
            _fill(req, c);
            opened += perTrade;
        }
        console2.log("ETH notional opened before the refusal (USDC 1e6)", opened);
        assertTrue(refused, "an order was refused before V reached XR_08's 5M");
        assertLe(opened, capUsd, "never above the cap");
        assertGt(opened + perTrade, capUsd, "refused exactly at the first order past the cap");
    }
}
