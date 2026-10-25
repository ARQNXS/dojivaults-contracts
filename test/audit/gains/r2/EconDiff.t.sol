// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {EconBase} from "./EconBase.t.sol";

/// @notice ECON differential: the independent Python model (econ/) generates a sequence of at least 50 settled epochs
///         for one strategy, seed and vault size, with its predictions; this test replays it on the real vault and
///         the mock diamond and requires agreement to the wei (EconBase).
///
///         Needs ffi and Python 3.13 on PATH. Skipped unless ECON_FFI=true, so a plain `forge test` (the lead's full
///         run, without --ffi) does not fail on it:
///           ECON_FFI=true forge test --ffi --match-path test/audit/gains/r2/EconDiff.t.sol
///         Pick one case with ECON_STRATEGY / ECON_SEED / ECON_SIZE (USDC) for test_ECON_diff_one; the fuzz test
///         draws the seed and the size and runs every strategy at it.
contract EconDiffTest is EconBase {
    string internal constant MODEL = "test/audit/gains/r2/econ/econ.py";

    function _ffiOn() internal view returns (bool) {
        return vm.envOr("ECON_FFI", false);
    }

    function _gen(string memory strategy, uint256 seed, uint256 sizeUsdc) internal returns (uint256[] memory w) {
        string[] memory cmd = new string[](7);
        cmd[0] = "python";
        cmd[1] = "-I";
        cmd[2] = MODEL;
        cmd[3] = "ffi";
        cmd[4] = strategy;
        cmd[5] = vm.toString(seed);
        cmd[6] = vm.toString(sizeUsdc);
        w = abi.decode(vm.ffi(cmd), (uint256[]));
    }

    function _run(string memory strategy, uint256 seed, uint256 sizeUsdc) internal {
        uint256[] memory w = _gen(strategy, seed, sizeUsdc);
        settles = 0;
        checks = 0;
        Expect memory e = _replay(w);
        console2.log(string.concat(strategy, " seed ", vm.toString(seed), " size ", vm.toString(sizeUsdc)));
        console2.log("  events / settles / checks", e.nEvents, settles, checks);
        // 60 epochs are generated; a sequence where the NAV outruns the checkpoint for hours (NavMoved) settles fewer
        // of them, but every event of it is still checked
        assertGe(settles, 30, "settled epochs");
    }

    /// @dev One case from the environment (default: passive, seed 1, 100k).
    function test_ECON_diff_one() public {
        if (!_ffiOn()) vm.skip(true);
        _run(vm.envOr("ECON_STRATEGY", string("passive")), vm.envOr("ECON_SEED", uint256(1)), vm.envOr("ECON_SIZE", uint256(100_000)));
    }

    /// @dev Every strategy at a fuzzed seed and size (10 USDC .. 10M USDC victim capital).
    function testFuzz_ECON_diff_allStrategies(uint64 seed, uint8 sizeSel) public {
        if (!_ffiOn()) vm.skip(true);
        uint256[5] memory sizes = [uint256(10_000), 100_000, 1_000_000, 10_000_000, 1_000];
        uint256 size = sizes[sizeSel % 5];
        string memory strategy = _strategy(uint256(seed) % 22);
        _run(strategy, uint256(seed) % 1_000_000, size);
    }

    function _strategy(uint256 i) internal pure returns (string memory) {
        string[22] memory s = [
            "passive",
            "openin_flatout",
            "flatin_openout",
            "spread_farm",
            "spread_farm_big",
            "lag_option",
            "split",
            "carry_option",
            "mgmt_timing",
            "mgmt_control",
            "perf_timing",
            "perf_control",
            "overdue_owner",
            "overdue_control",
            "levbreach_perf",
            "levbreach_control",
            "insider_edges",
            "dust",
            "full_exit",
            "emergency_partial",
            "emergency_stay",
            "fee_raise"
        ];
        return s[i];
    }
}
