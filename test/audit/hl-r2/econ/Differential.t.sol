// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {HloBase} from "../../hl-open/HloBase.t.sol";
import {HyperVault} from "../../../../src/HyperVault.sol";
import {HyperVaultFactory} from "../../../../src/HyperVaultFactory.sol";
import {VaultPolicy} from "../../../../src/VaultPolicy.sol";
import {BreachReason} from "../../../../src/VaultTypes.sol";

/// @notice hl-r2 differential driver (domain 3.7). Runs random multi-epoch scenarios on a factory vault (protocol
///         share live) and prints every INPUT (time, Core value, USDC moves, requests, risk checks, emergencies,
///         settles, claims) and a per-actor SNAPSHOT after every settle as `J|...` log lines. The independent Python
///         model (contracts/audit/hl-r2/econ/model/) replays the inputs and compares every snapshot.
///
///         Run (seeds via env, defaults: 2 scenarios from seed 1):
///           ECON_SEED0=1 ECON_SEEDS=50 forge test --match-path "test/audit/hl-r2/econ/Differential.t.sol" -vv \
///             --gas-limit 18446744073709551615 > out.txt
///           python contracts/audit/hl-r2/econ/model/diff.py out.txt
///         The test itself asserts only conservation (no USDC created); the comparison is the model's job.
contract HlR2Differential is HloBase {
    uint256 internal rng;
    HyperVault internal v;
    int64 internal core;
    address[9] internal actors; // 0-3 users, 4 sybil, 5 manager, 6 fee recipient, 7 owner, 8 treasury (shares only)
    uint256 internal scale;

    function setUp() public override {
        super.setUp();
        actors[0] = makeAddr("u0");
        actors[1] = makeAddr("u1");
        actors[2] = makeAddr("u2");
        actors[3] = makeAddr("u3");
        actors[4] = makeAddr("sybil");
        actors[5] = makeAddr("mgr");
        actors[6] = makeAddr("feeR");
        actors[7] = makeAddr("own");
        actors[8] = treasury;
    }

    function _r(uint256 n) internal returns (uint256) {
        rng = uint256(keccak256(abi.encode(rng)));
        return rng % n;
    }

    function _j(string memory s) internal pure {
        console2.log(string.concat("J|", s));
    }

    function _u(uint256 x) internal pure returns (string memory) {
        return vm.toString(x);
    }

    function test_differential() public {
        uint256 s0 = vm.envOr("ECON_SEED0", uint256(1));
        uint256 n = vm.envOr("ECON_SEEDS", uint256(2));
        for (uint256 i; i < n; ++i) {
            _scenario(s0 + i);
        }
    }

    // ------------------------------------------------------------------
    function _setV(int64 c) internal {
        core = c;
        _setCore(address(v), c, 0, 0);
        _j(string.concat("C|", _u(uint256(int256(c)))));
    }

    function _warp(uint256 secs) internal {
        vm.warp(vm.getBlockTimestamp() + secs);
        vm.roll(vm.getBlockNumber() + secs); // 1 block per second, past any bridge window
        _j(string.concat("T|", _u(vm.getBlockTimestamp())));
    }

    function _toEvm(uint256 amt) internal {
        if (amt == 0) return;
        if (amt > uint256(int256(core))) amt = uint256(int256(core));
        core -= int64(int256(amt));
        _setCore(address(v), core, 0, 0);
        usdc.mint(address(v), amt);
        _j(string.concat("X|E|", _u(amt)));
    }

    function _toCore(uint256 amt) internal {
        if (amt == 0) return;
        usdc.burnFrom(address(v), amt);
        core += int64(int256(amt));
        _setCore(address(v), core, 0, 0);
        _j(string.concat("X|C|", _u(amt)));
    }

    function _call(address who, bytes memory data) internal returns (bool ok, bytes4 sel) {
        vm.prank(who);
        bytes memory ret;
        (ok, ret) = address(v).call(data);
        if (!ok && ret.length >= 4) sel = bytes4(ret);
    }

    function _check() internal {
        (bool ok,) = _call(makeAddr("anyone"), abi.encodeCall(HyperVault.checkRisk, ()));
        _j(string.concat("K|", ok ? "1|" : "0|", _u(uint8(v.breachReason())), "|", _u(v.checkpointNav())));
    }

    function _scenario(uint256 seed) internal {
        rng = uint256(keccak256(abi.encode("hl-r2-econ", seed)));
        uint256[5] memory scales = [uint256(1_000e6), 10_000e6, 100_000e6, 1_000_000e6, 10_000_000e6];
        scale = scales[_r(5)];
        uint16 mgmt = uint16(_r(501));
        uint16 perf = uint16(_r(3001));
        if (vm.envOr("ECON_NOPERF", false)) perf = 0;
        if (vm.envOr("ECON_NOFEE", false)) (mgmt, perf) = (0, 0);
        bool hosted = _r(2) == 0;
        bool ownerIsManager = _r(2) == 0;
        uint32[3] memory dailies = [uint32(500), 1_000, 2_000];
        uint32[3] memory dds = [uint32(1_500), 3_000, 5_000];
        uint32 daily = dailies[_r(3)];
        uint32 dd = dds[_r(3)];
        uint256 seedUsdc = _r(4) == 0 ? scale / 100 : 2e6;

        address launcher = makeAddr(string.concat("launcher", _u(seed)));
        _fundLauncher(launcher, 1);
        usdc.mint(launcher, seedUsdc);
        HyperVaultFactory.CreateParams memory p = _params(launcher, bytes32(seed));
        p.owner = ownerIsManager ? actors[5] : actors[7];
        p.manager = actors[5];
        p.feeRecipient = actors[6];
        p.managementFeeBps = mgmt;
        p.performanceFeeBps = perf;
        p.hosted = hosted;
        p.seedUsdc = seedUsdc;
        p.risk.maxDailyLossBps = daily;
        p.risk.maxDrawdownBps = dd;
        p.risk.maxLeverageBps = 30_000;
        p.risk.maxNavMoveBps = 2_000;
        p.risk.maxEpochDuration = 7 days;
        v = _launch(launcher, p);
        core = 0;
        for (uint256 i; i < 8; ++i) {
            usdc.mint(actors[i], scale * 4);
            vm.prank(actors[i]);
            usdc.approve(address(v), type(uint256).max);
        }
        _j(
            string.concat(
                "S|",
                _u(seed),
                "|",
                _u(scale),
                "|",
                _u(mgmt),
                "|",
                _u(perf),
                "|",
                _u(v.protocolShareBps()),
                "|",
                _u(daily),
                "|",
                _u(dd),
                "|2000|604800|",
                ownerIsManager ? "1|" : "0|",
                _u(vm.getBlockTimestamp())
            )
        );
        _snapWallets("W");
        // The seed landed on Core minus the 1 USDC activation fee.
        _setV(int64(int256(seedUsdc - 1e6)));
        _warp(400);
        _check();

        uint256 epochs = 50 + _r(21);
        for (uint256 e; e < epochs; ++e) {
            _epoch();
        }
        _j("Z|");
        // Conservation: the vault never holds less USDC than it owes as reserved.
        assertGe(
            usdc.balanceOf(address(v)), v.claimableRedeemAssets() + v.pendingDepositAssets() + v.deferredDepositAssets(), "reserve"
        );
    }

    function _epoch() internal {
        // 1. requests
        for (uint256 i; i < 8; ++i) {
            address a = actors[i];
            uint256 x = _r(100);
            if (x < 25) {
                uint256 amt = (scale * (1 + _r(300))) / 1000;
                if (amt < 10e6) amt = 10e6;
                (bool ok,) = _call(a, abi.encodeCall(HyperVault.requestDeposit, (amt, a)));
                _j(string.concat("D|", _u(i), "|", _u(amt), ok ? "|1" : "|0"));
            } else if (x < 42) {
                uint256 bal = v.balanceOf(a);
                if (bal == 0) continue;
                uint256 sh = _r(4) == 0 ? bal : (bal * (1 + _r(100))) / 100;
                if (sh == 0) continue;
                (bool ok,) = _call(a, abi.encodeCall(HyperVault.requestRedeem, (sh, a, a)));
                _j(string.concat("R|", _u(i), "|", _u(sh), "|", _u(bal), ok ? "|1" : "|0"));
            } else if (x < 45) {
                (bool ok,) = _call(a, abi.encodeCall(HyperVault.cancelDepositRequest, ()));
                _j(string.concat("CD|", _u(i), ok ? "|1" : "|0"));
            } else if (x < 47) {
                (bool ok,) = _call(a, abi.encodeCall(HyperVault.cancelRedeemRequest, ()));
                _j(string.concat("CR|", _u(i), ok ? "|1" : "|0"));
            }
        }
        // 2. PnL over 1-3 steps of 2-11 hours, risk checks in between
        uint256 steps = 1 + _r(3);
        for (uint256 k; k < steps; ++k) {
            _warp((2 + _r(10)) * 1 hours);
            int256 bps = int256(_r(1601)) - 800;
            if (_r(25) == 0) bps = -2_500;
            int256 c = int256(core);
            int256 nc = (c * (10_000 + bps)) / 10_000;
            if (nc < 1e6) nc = 1e6;
            _setV(int64(nc));
            if (_r(2) == 0) _check();
            if (_r(5) == 0) {
                (bool ok,) = _call(makeAddr("anyone"), abi.encodeCall(HyperVault.accrueFees, ()));
                _j(string.concat("A|", ok ? "1" : "0"));
            }
        }
        // 3. emergency / recovery
        if (!v.emergency() && _r(40) == 0) {
            (bool ok,) = _call(guardian, abi.encodeCall(HyperVault.triggerEmergency, ()));
            _j(string.concat("E|", ok ? "1" : "0"));
        }
        if (v.emergency() && v.pendingRedeemShares() == 0 && _r(3) == 0) {
            (bool ok,) = _call(guardian, abi.encodeCall(HyperVault.exitEmergency, ()));
            _j(string.concat("XE|", ok ? "1" : "0"));
        }
        if (!v.emergency() && v.breached() && uint8(v.breachReason()) >= uint8(BreachReason.GUARDIAN) && _r(2) == 0) {
            (bool ok,) = _call(guardian, abi.encodeCall(HyperVault.clearBreach, ()));
            _j(string.concat("CB|", ok ? "1" : "0"));
        }
        if (v.breached() && v.breachReason() == BreachReason.DRAWDOWN && _r(2) == 0) {
            (bool ok,) = _call(v.owner(), abi.encodeCall(HyperVault.resume, ()));
            _j(string.concat("RS|", ok ? "1" : "0"));
        }
        // 4. refresh the checkpoint (the keeper's checkRisk before a settle). ECON_LAG: like the live operator, only
        //    when the checkpoint is older than a day (else a 25% chance), so exits meet a lagging checkpoint.
        _warp(1 hours + _r(2 hours));
        if (!vm.envOr("ECON_LAG", false) || vm.getBlockTimestamp() > uint256(v.checkpointAt()) + 1 days || _r(4) == 0) _check();
        // 5. liquidity for the redemptions
        uint256 pend = v.pendingRedeemShares();
        if (pend > 0) {
            uint256 need = v.convertToAssets(pend);
            uint256 idle = v.idleAssets();
            uint256 want = need > idle ? need - idle : 0;
            if (v.emergency()) want = (want * _r(130)) / 100;
            else if (_r(12) == 0) want = want / 2; // sometimes short: InsufficientLiquidity
            else want = (want * 102) / 100 + 1e6;
            _toEvm(want);
        }
        // 6. settle
        address caller;
        uint256 who;
        if (v.emergency()) {
            who = 2;
        } else if (v.breached() && (v.breachReason() == BreachReason.DAILY_LOSS || v.breachReason() == BreachReason.DRAWDOWN)) {
            who = _r(4);
        } else {
            who = _r(2);
        }
        caller = who == 0 ? actors[5] : who == 1 ? keeper : who == 2 ? guardian : sentinel;
        (bool sok, bytes4 sel) = _call(caller, abi.encodeCall(HyperVault.settle, ()));
        _j(string.concat("ST|", _u(who), sok ? "|1|" : "|0|", vm.toString(abi.encodePacked(sel))));
        // 7. claims
        for (uint256 i; i < 8; ++i) {
            (uint256 ep, uint256 da, uint256 rs) = v.requests(actors[i]);
            if ((da > 0 || rs > 0) && ep < v.currentEpoch()) {
                (bool ok,) = _call(makeAddr("anyone"), abi.encodeCall(HyperVault.claim, (actors[i])));
                _j(string.concat("CL|", _u(i), ok ? "|1" : "|0"));
            }
        }
        // 8. snapshot
        if (sok) _snap();
        // 9. deploy idle again sometimes
        if (!v.emergency() && !v.breached() && _r(2) == 0) _toCore((v.idleAssets() * _r(100)) / 100);
    }

    function _snapWallets(string memory tag) internal {
        for (uint256 i; i < 9; ++i) {
            _j(string.concat(tag, "|", _u(i), "|", _u(usdc.balanceOf(actors[i]))));
        }
    }

    function _snap() internal {
        for (uint256 i; i < 9; ++i) {
            address a = actors[i];
            (uint256 ep, uint256 da, uint256 rs) = v.requests(a);
            _j(
                string.concat(
                    "P|", _u(i), "|", _u(usdc.balanceOf(a)), "|", _u(v.balanceOf(a)), "|", _u(da), "|", _u(rs), "|", _u(ep)
                )
            );
        }
        _j(
            string.concat(
                "V|",
                _u(v.currentEpoch()),
                "|",
                _u(v.totalAssets()),
                "|",
                _u(v.totalSupply()),
                "|",
                _u(usdc.balanceOf(address(v))),
                "|",
                _u(v.claimableRedeemAssets()),
                "|",
                _u(v.pendingDepositAssets()),
                "|",
                _u(v.deferredDepositAssets()),
                "|",
                _u(v.highWaterMark()),
                "|",
                _u(v.sharePrice()),
                "|",
                _u(uint8(v.breachReason())),
                v.emergency() ? "|1" : "|0"
            )
        );
    }
}
