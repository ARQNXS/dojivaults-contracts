// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice WP5 deploy rehearsal on a local anvil fork of Arbitrum One. A fork receives no new Chainlink rounds, so the
///         rehearsal script puts this stand-in at each curated feed (anvil_setCode) and sets slot 0 to the feed's price
///         at the fork block (anvil_setStorageAt). Never deployed.
contract RehearsalFeed {
    int256 internal answer; // slot 0: the price, 8 decimals, copied from the real feed at the fork block

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}
