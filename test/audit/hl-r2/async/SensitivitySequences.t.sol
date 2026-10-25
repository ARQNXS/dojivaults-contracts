// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ConservationPlatformVaultInvariants, ConservationTightInvariants} from "./ConservationInvariants.t.sol";

/// @notice The failing call sequences of the sensitivity runs (INVARIANTS.md section 6), replayed on the shipped src.
///         Each test PASSES on the current contracts (every property holds) and FAILS when the named fix is reverted
///         (the property that caught it fires). Sequences are the shrunk ones forge printed, arguments verbatim.
contract SensitivityPlatformVault is ConservationPlatformVaultInvariants {
    /// N2-02 (performance fee raise waits for a settle at the old rate). Reverted: F8.
    function test_sens_N202() public {
        handler.queueFees(100, 2460);
        handler.warp(55146061494691528332033440763451929231490047943629499565737);
        handler.executeQueued(241);
        handler.pnlShock(-1000);
        handler.keeperCycle(7000318240655287162027824830627287634600079157581412401956632365);
        invariant_conservation();
    }

    /// R-02 + R3-08 (the window waits for the landing, then 300 blocks). Reverted: F2.
    function test_sens_R02() public {
        handler.deposit(37351275843251424135089718237132180777, 99922106158872807006553038511640344239242403461);
        handler.settle(23);
        handler.bridgeToEvm(4, 19951359110387386070568041753890692550679822717642223336305994525977511478077);
        handler.faults(837626020139512105343984806041);
        handler.roll(8603);
        handler.keeperCycle(12217658113241507308233);
        invariant_conservation();
    }

    /// R3-01 (to-Core landing on spot only, never on Core equity). Not found by the random campaigns at 256 runs; this
    /// hand-written sequence shows the property catches it. Reverted: F2.
    function test_sens_R301() public {
        handler.deposit(0, 50_000e6); // alice
        handler.warp(2 hours);
        handler.settle(1); // operator
        handler.faults(100729129); // EVM->Core credit 2,000 blocks late
        handler.bridgeToCore(1, 5_000e6); // operator bridges 5k of the idle 50k
        handler.pnlShock(800); // +8% of the perp value (+8k) while the 5k is in transit
        handler.roll(15);
        handler.deposit(2, 20_000e6); // carol
        handler.keeperCycle(2); // operator settle
        invariant_conservation();
    }
}

contract SensitivityTight is ConservationTightInvariants {
    /// V-01 (partial fill burns only the shares it paid for). Reverted: F6.
    function test_sens_V01() public {
        handler.redeem(60319015461568540396643250, 21567239703145786797165032373479132269391075976160566633);
        handler.breachOps(20817);
        handler.settle(3680131858);
        invariant_conservation();
    }
}
