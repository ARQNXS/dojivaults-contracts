// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGainsDiamondSpike} from "../../test/gains/spike/IGainsDiamondSpike.sol";
import {GainsSpikeTrader} from "../../test/gains/spike/GainsSpikeTrader.sol";

/// @notice Stage 0 only: deploys the test spike trader on Arbitrum One, owned by the broadcaster (GAINS_TEST_KEY).
///         Funding, trading and withdrawal are done by server/scripts/gains-stage0.ts `live`, step by step.
///   forge script script/gains/Stage0Arbitrum.s.sol --rpc-url arbitrum --private-key $GAINS_TEST_KEY --broadcast
contract Stage0Arbitrum is Script {
    IGainsDiamondSpike internal constant DIAMOND = IGainsDiamondSpike(0xFF162c694eAA571f685030649814282eA457f169);
    IERC20 internal constant USDC = IERC20(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);

    function run() external returns (GainsSpikeTrader spike) {
        require(block.chainid == 42161, "Arbitrum One only");
        require(DIAMOND.getCollateralIndex(address(USDC)) == 3, "USDC is not collateral 3");
        vm.startBroadcast();
        spike = new GainsSpikeTrader(DIAMOND, USDC, msg.sender);
        vm.stopBroadcast();
        require(spike.owner() == msg.sender, "owner");
        console2.log("GainsSpikeTrader", address(spike));
        console2.log("owner", msg.sender);
    }
}
