// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "./KeysForkBase.sol";

/// @notice GR2-KEY-03 (referrer): openTrade passes referrer address(0). Confirm no path registers a referrer for the
///         vault, so a thief cannot attach his own address as referrer and skim referral rebates on the vault's fees.
///         GR2-KEY-04 (fee churn): measure the Gains fee cost per open+close cycle, as USDC and as a fraction of
///         notional, so the "destroy per hour" figure can be computed against the keeper's checkRisk interval.
contract KeysReferrerFeeForkTest is KeysForkBase {
    function setUp() public override {
        super.setUp();
        if (!forked) return;
        _depositSettle(alice, 300_000e6);
        // GR2-KEY-01b (WP5 port): the tests open a 250k (and 375k after the increase) ETH long, above 1 % of ETH's skew
        // depth (about 142k at 517,076,707); KEY-03 / KEY-04 are about referrers and fee cost, not the pair cap, so
        // ETH's cap is raised to the 10 % maximum (the guardian's 31-day raise)
        _raisePairCapToMax(ETH);
    }

    /// @dev After the vault opens and increases a trade, getTraderActiveReferrer(vault) is still zero.
    function test_GR2_KEY_03_vaultNeverGetsAReferrer() public {
        assertEq(IGainsExtraK(address(DIAMOND)).getTraderActiveReferrer(address(v)), address(0), "no referrer at start");
        uint64 c = cl[ETH_USD];
        uint32 idx = _openVault(mgr, ETH, true, 10_000e6, 25_000, c);
        assertEq(IGainsExtraK(address(DIAMOND)).getTraderActiveReferrer(address(v)), address(0), "none after open");
        // an increase is the other size-adding path
        Vm.Log[] memory req = _call(mgr, abi.encodeWithSignature(
            "increaseTrade(uint32,uint120,uint24,uint64,uint16)", idx, uint120(5_000e6), uint24(25_000), c, uint16(1_000)
        ));
        _roll(1);
        _fill(req, c);
        assertEq(IGainsExtraK(address(DIAMOND)).getTraderActiveReferrer(address(v)), address(0), "none after increase");
    }

    /// @dev Even if the thief tries to register HIS address as the vault's referrer directly on the diamond, Gains
    ///      only lets a referrer be set by the trader's own first trade with a referrer argument; a third party's
    ///      registerPotentialReferrer for someone else is a no-op / reverts. Assert the vault's referrer stays zero.
    function test_GR2_KEY_03_thirdPartyCannotSetVaultReferrer() public {
        try IGainsExtraK(address(DIAMOND)).registerPotentialReferrer(address(v), thief) {} catch {}
        assertEq(IGainsExtraK(address(DIAMOND)).getTraderActiveReferrer(address(v)), address(0), "still none");
    }

    /// @dev One open+close cycle at the live max order notional (250k, 25x, ETH). Report the round-trip fee in USDC
    ///      and bps of notional. This is the per-cycle DESTROY figure; multiply by cycles per keeper interval.
    function test_GR2_KEY_04_feeCostPerChurnCycle_ETH() public {
        uint64 c = cl[ETH_USD];
        uint256 vault0 = _usdc(address(v));
        uint32 idx = _openVault(mgr, ETH, true, 10_000e6, 25_000, c); // 250k notional
        // GR2-KEY-01b (WP5 port): the manager's close waits the 10-minute minimum hold; the round trip now includes
        // 11 minutes of holding fees (small next to the opening and closing fees)
        _passHold();
        uint256 sent = _closeVault(mgr, idx, c);
        uint256 loss = vault0 - _usdc(address(v));
        console2.log("250k ETH 25x open+close at same price: vault loss (USDC)", loss, "close returned", sent);
        console2.log("round-trip cost in bps of 250k notional", _bps(loss, 250_000e6));
        assertGt(loss, 0, "a round trip costs fees + spread + impact");
        // sanity: the cost is a small fraction of notional (Gains open+close fees ~ 8 bps each side + spread)
        assertLt(loss, 250_000e6 / 20, "round trip under 5% of notional");
    }
}
