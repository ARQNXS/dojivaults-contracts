// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Stage 3 fork gate: a settable Chainlink aggregator installed over a curated feed's address with
///         anvil_setCode (the vault reads the real addresses the factory curated). Also the L2 sequencer uptime feed
///         (answer 0 = up, startedAt = when the status changed). Storage starts at a slot the replaced proxy never
///         used, so the old proxy's storage cannot leak into the answers.
contract ForkFeed {
    struct State {
        uint8 decimals;
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80 roundId;
    }

    bytes32 internal constant SLOT = keccak256("dojivaults.stage3.forkfeed");

    function _s() internal pure returns (State storage s) {
        bytes32 slot = SLOT;
        assembly {
            s.slot := slot
        }
    }

    function init(uint8 decimals_, int256 answer_, uint256 at) external {
        State storage s = _s();
        s.decimals = decimals_;
        s.answer = answer_;
        s.startedAt = at;
        s.updatedAt = at;
        s.roundId = 1;
    }

    function set(int256 answer_, uint256 updatedAt_) external {
        State storage s = _s();
        s.answer = answer_;
        s.updatedAt = updatedAt_;
        s.roundId += 1;
    }

    function setStatus(int256 answer_, uint256 startedAt_) external {
        State storage s = _s();
        s.answer = answer_;
        s.startedAt = startedAt_;
        s.updatedAt = startedAt_;
        s.roundId += 1;
    }

    function decimals() external view returns (uint8) {
        return _s().decimals;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        State storage s = _s();
        return (s.roundId, s.answer, s.startedAt, s.updatedAt, s.roundId);
    }

    function latestAnswer() external view returns (int256) {
        return _s().answer;
    }

    function description() external pure returns (string memory) {
        return "Stage 3 fork feed";
    }
}
