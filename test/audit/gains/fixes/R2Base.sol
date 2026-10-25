// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {R1Base} from "../R1Base.t.sol";
import {GainsVault} from "../../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../../src/gains/GainsVaultPolicy.sol";
import {IGainsDiamond} from "../../../../src/gains/IGainsDiamond.sol";

/// @dev Fix round 2 (contracts/audit/gains/FIXES-R1.md, round 2), from the VERIFY-R1 harness (VerifyBase). The mock harness of GainsBase / R1Base
///      (mock diamond, mock feeds, standalone vaults with guardian == sentinel), plus a vault with all three curated
///      pairs and a few flow helpers.
abstract contract R2Base is R1Base {
    /// @dev 0.06% of position size per side (1e10 percent): the order of gTrade's BTC / ETH / SOL fee.
    uint256 internal constant FEE_P = 6e8;

    /// @dev A standalone vault with BTC, ETH and SOL allowed.
    function _vault3(GainsVaultPolicy.RiskConfig memory risk) internal returns (GainsVault v) {
        uint32[] memory assets = new uint32[](3);
        assets[0] = BTC;
        assets[1] = ETH;
        assets[2] = SOL;
        v = GainsVault(Clones.clone(address(vaultImpl)));
        GainsVaultPolicy p = GainsVaultPolicy(Clones.clone(address(policyImpl)));
        p.initialize(owner, risk, assets, 2 days, address(platform), address(v));
        v.initialize(_standaloneParams(p));
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(v), type(uint256).max);
    }

    function _vault3() internal returns (GainsVault) {
        return _vault3(_defaultRisk());
    }

    /// @dev `who` deposits `amount` into `v`, the manager settles, `who` claims the shares.
    function _seed(GainsVault v, address who, uint256 amount) internal {
        _depositTo(v, who, amount);
        _settleV(v);
        v.claim(who);
    }

    /// @dev Opening and closing fees on every curated pair (the mock defaults to none).
    function _fees() internal {
        diamond.setPair(BTC, FEE_P, 285.7e18, 0.1e18, 0);
        diamond.setPair(ETH, FEE_P, 285.7e18, 0.1e18, 0);
        diamond.setPair(SOL, FEE_P, 285.7e18, 0.1e18, 0);
    }

    function _valueOf(GainsVault v, address who) internal view returns (uint256) {
        return v.convertToAssets(v.balanceOf(who));
    }

    /// @dev Answers every open pending order of `v` at its pair's Chainlink price.
    function _fillAll(GainsVault v) internal {
        IGainsDiamond.PendingOrder[] memory o = diamond.getPendingOrders(address(v));
        for (uint256 i; i < o.length; ++i) {
            diamond.fill(address(v), o[i].index, _px(o[i].trade.pairIndex));
        }
    }

    /// @dev The manager settles after `dt` (feeds kept fresh), with the keeper's checkRisk first.
    function _settleAfter(GainsVault v, uint256 dt) internal {
        _skip(dt);
        v.checkRisk();
        vm.prank(v.manager());
        v.settle();
    }

    /// @dev Moves time by `dt` and leaves the ETH feed at its old round (BTC and SOL stay fresh).
    function _ethStaleBy(uint256 dt) internal {
        uint256 t = vm.getBlockTimestamp() + dt;
        vm.warp(t);
        btcFeed.set(btcFeed.answer(), t);
        solFeed.set(solFeed.answer(), t);
    }
}
