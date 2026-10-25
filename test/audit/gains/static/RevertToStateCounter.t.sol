// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

/// @notice Tooling finding (mutation testing, tools/MUTATION.md), fixed in 4cdda5c: AccessMatrix.t.sol counted
///         mismatches in a STORAGE variable and called vm.revertToState(base) before every cell (_enter), which rolled
///         the counter back to 0. The final assertEq(mismatches, 0) therefore only saw the last cell: a mismatch in any
///         earlier cell was logged ("MISMATCH state/fn/actor ...") but never failed the test. Mutant
///         GainsVaultLogic#2009 (flatten L654 `if (slippageBps != 0)` -> `if (false)`) logged 6 mismatches and all 12
///         test_accessMatrix_* passed. This test reproduces the pattern in isolation; the fix (applied) counts in a
///         local (the stack survives revertToState).
contract RevertToStateCounterTest is Test {
    uint256 internal mismatches; // the pattern AccessMatrixTest used before 4cdda5c
    uint256 internal base;

    function setUp() public {
        base = vm.snapshotState();
    }

    /// @dev Three cells, the first two "mismatch": the storage counter ends at 0, the assertion AccessMatrix uses passes.
    function test_storageCounterIsResetByRevertToState() public {
        bool[3] memory mismatch = [true, true, false];
        uint256 local;
        for (uint256 i; i < 3; ++i) {
            vm.revertToState(base); // AccessMatrixTest._enter
            if (mismatch[i]) {
                ++mismatches;
                ++local;
            }
        }
        assertEq(mismatches, 0, "storage counter was rolled back: AccessMatrix's assertEq(mismatches, 0) passes");
        assertEq(local, 2, "a local counter keeps both mismatches");
    }
}
