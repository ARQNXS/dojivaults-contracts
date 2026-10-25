// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {GainsBase} from "../../gains/GainsBase.t.sol";
import {GainsVault} from "../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../src/gains/GainsVaultPolicy.sol";

/// @dev Shared helpers for the round 1 Gains review PoCs. Builds on test/gains/GainsBase.t.sol (mock diamond, mock
///      feeds, standalone vault with guardian == sentinel), so every PoC runs against the same harness the Stage 1
///      suites use.
abstract contract R1Base is GainsBase {
    /// @dev A second standalone vault with a custom risk config (same mocks, same roles).
    function _vaultWith(GainsVaultPolicy.RiskConfig memory risk) internal returns (GainsVault v, GainsVaultPolicy p) {
        uint32[] memory assets = new uint32[](2);
        assets[0] = BTC;
        assets[1] = ETH;
        v = GainsVault(Clones.clone(address(vaultImpl)));
        p = GainsVaultPolicy(Clones.clone(address(policyImpl)));
        p.initialize(owner, risk, assets, 2 days, address(platform), address(v));
        v.initialize(_standaloneParams(p));
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(v), type(uint256).max);
    }

    function _depositTo(GainsVault v, address who, uint256 amount) internal {
        vm.prank(who);
        v.requestDeposit(amount, who);
    }

    function _redeemFrom(GainsVault v, address who, uint256 shares) internal {
        vm.prank(who);
        v.requestRedeem(shares, who, who);
    }

    function _settleV(GainsVault v) internal {
        _ageEpoch(v);
        v.checkRisk();
        vm.prank(v.manager());
        v.settle();
    }
}
