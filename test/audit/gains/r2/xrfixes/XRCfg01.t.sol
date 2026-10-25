// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {R1Base} from "../../R1Base.t.sol";
import {GainsVault} from "../../../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../../../src/gains/GainsVaultPolicy.sol";
import {InitParams} from "../../../../../src/gains/GainsTypes.sol";

/// @notice Cross-review of the GR2-CFG-01 patch (contracts/audit/gains/r2/XREVIEW-FIXES.md), tree with all five patches.
///         Question: can the new rule (timelock >= maxEpochDuration + 1 day, policy and vault) refuse a tightening the
///         depositors need, or brick a configuration?
contract XRCfg01Test is R1Base {
    function _live() internal pure returns (GainsVaultPolicy.RiskConfig memory) {
        return GainsVaultPolicy.RiskConfig({
            maxLeverageBps: 50_000,
            maxDailyLossBps: 1_500,
            maxDrawdownBps: 5_000,
            maxSlippageBps: 300,
            maxOrderNotional: 250_000e6,
            maxEpochDuration: 1 days,
            maxNavMoveBps: 2_000,
            maxFlattenSlippageBps: 300
        });
    }

    function _mk() internal returns (GainsVault v, GainsVaultPolicy p) {
        uint32[] memory assets = new uint32[](2);
        assets[0] = BTC;
        assets[1] = ETH;
        v = GainsVault(Clones.clone(address(vaultImpl)));
        p = GainsVaultPolicy(Clones.clone(address(policyImpl)));
        p.initialize(owner, _live(), assets, 2 days, address(platform), address(v));
        InitParams memory ip = _standaloneParams(p);
        ip.timelockDelay = 2 days;
        v.initialize(ip);
    }

    /// @notice Live shape (T 2 d, E 1 d): every field tightened on its own, and all at once, applies instantly.
    function test_XR_CFG01_everyTighteningStillInstantOnTheLiveShape() public {
        (, GainsVaultPolicy p) = _mk();
        for (uint256 f; f < 9; ++f) {
            GainsVaultPolicy.RiskConfig memory c = _live();
            if (f == 0 || f == 8) c.maxLeverageBps = 20_000;
            if (f == 1 || f == 8) c.maxDailyLossBps = 500;
            if (f == 2 || f == 8) c.maxDrawdownBps = 2_000;
            if (f == 3 || f == 8) c.maxSlippageBps = 100;
            if (f == 4 || f == 8) c.maxOrderNotional = 50_000e6;
            if (f == 5 || f == 8) c.maxEpochDuration = 1 hours;
            if (f == 6 || f == 8) c.maxNavMoveBps = 2_500; // raising it is the tightening (N-03)
            if (f == 7 || f == 8) c.maxFlattenSlippageBps = 100;
            vm.prank(owner);
            p.proposeConfig(c);
            assertFalse(p.pendingConfig().exists, "applied, not queued");
            // back to the live shape through the queue for the next field
            vm.prank(owner);
            p.proposeConfig(_live());
            _skip(2 days);
            p.applyPendingConfig();
        }
        assertEq(p.maxEpochDuration(), 1 days);
    }

    /// @notice A longer epoch stays reachable: raise both timelocks first (policy instant, vault behind its own 2 d
    ///         queue), then queue the epoch raise. No configuration is bricked; it costs the owner T + T'.
    function test_XR_CFG01_epochRaiseReachableByRaisingBothTimelocksFirst() public {
        (GainsVault v, GainsVaultPolicy p) = _mk();
        vm.prank(owner);
        p.proposeTimelockDelay(8 days); // a raise: instant
        _timelocked(v, abi.encodeCall(GainsVault.setTimelockDelay, (8 days)));
        GainsVaultPolicy.RiskConfig memory c = _live();
        c.maxEpochDuration = 7 days;
        vm.prank(owner);
        p.proposeConfig(c); // a loosening: queued 8 days
        _skip(8 days);
        p.applyPendingConfig();
        assertEq(p.maxEpochDuration(), 7 days);
    }
}
