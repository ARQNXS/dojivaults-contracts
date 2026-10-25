"""Revert-check harness for FIXES-R1.md.

Each entry undoes ONE fix in a scratch copy of contracts/ (never in the worktree) with exact replacements of the fixed
code by the round-1 code, then the entry's regression tests are run there: they must FAIL. The scratch copy is reset
from the worktree before every entry.

usage: python unfix.py <scratch-contracts-dir> <fix-id>      applies the un-fix
       python unfix.py --list                                prints id | tests
"""
import sys

UNFIX = {
    # control: nothing undone, every regression test must pass on the fixed code
    "CONTROL": ([], "test_GR1_|test_MUT|test_policyDoesNot"),
    # GR1-01: a pending leverage-only increase counts 0 again (round-1 formula), and no PendingOrderExists check
    "GR1-01": (
        [("src/gains/GainsNav.sol",
          "added = GTrade.positionSize(t.collateralAmount, o.trade.leverage);",
          "added = GTrade.positionSize(o.trade.collateralAmount, o.trade.leverage);"),
         ("src/gains/GainsVaultLogic.sol",
          "if (GainsNav.hasPendingOrder($.diamond, address(this), index)) revert E.PendingOrderExists(index);",
          "")],
        "test_GR1_01_"),
    # GR1-02a: deposits mint at the redemption (adverse) NAV again
    "GR1-02a": (
        [("src/gains/GainsVaultLogic.sol",
          "GainsVaultMath.toShares(depIn, Math.max(nav, $.idleAssets() + v.valueHigh), supply, Math.Rounding.Floor)",
          "GainsVaultMath.toShares(depIn, nav, supply, Math.Rounding.Floor)")],
        "test_GR1_02_(depositWhileOpen|repeatedCycles|intraday|fork)|test_GR1_15_"),
    # GR1-02b: the minimum epoch age applies to insider deposits only again
    "GR1-02b": (
        [("src/gains/GainsVaultLogic.sol",
          "!exitOnly && !redemptionOnly && ($.insiderInQueue || $.pendingDepositAssets > 0)",
          "!exitOnly && !redemptionOnly && $.insiderInQueue")],
        "test_GR1_02_settleThatMintsWaitsAnHour"),
    # GR1-03: the band counted a second time (round-1 rule; the band is the curated 20 bps of BTC / ETH)
    "GR1-03": (
        [("src/gains/GainsNav.sol",
          "return t.long ? uint256(price) <= liq : uint256(price) >= liq;",
          "return t.long ? uint256(price) * BPS <= liq * (BPS + 20) : uint256(price) * BPS >= liq * (BPS - 20);")],
        "test_GR1_03_"),
    # GR1-04a: any pending order blocks settle again
    "GR1-04a": (
        [("src/gains/GainsVaultMath.sol", "return GainsNav.blockingOrders($.diamond, address(this)) > 0;",
          "return GainsNav.readPendingOrders($.diamond, address(this)).length > 0;")],
        "test_GR1_04_(decoy|exitRoleCloses|overdueEmergencyNotBlocked)"),
    # GR1-04b: new risk allowed while the epoch is overdue again
    "GR1-04b": (
        [("src/gains/GainsVaultLogic.sol", "        if ($.epochOverdue()) revert E.EpochOverdue();\n    }", "    }"),
         ("src/gains/GainsVaultLogic.sol", "            if ($.epochOverdue()) revert E.EpochOverdue();\n", "")],
        "test_GR1_04_(holdingOrder|openInFlight)"),
    # GR1-08: the round-1 high-level ABI decode of both lists
    "GR1-08": (
        [("src/gains/GainsNav.sol",
          "        bytes memory r = _call(d, abi.encodeCall(IGainsDiamond.getTrades, (trader)));\n        bool ok;",
          "        trades = d.getTrades(trader);\n        if (trades.length >= 0) return (trades, 0);\n        bytes memory r = _call(d, abi.encodeCall(IGainsDiamond.getTrades, (trader)));\n        bool ok;"),
         ("src/gains/GainsNav.sol",
          "        bytes memory r = _call(d, abi.encodeCall(IGainsDiamond.getPendingOrders, (trader)));",
          "        orders = d.getPendingOrders(trader);\n        if (orders.length >= 0) return orders;\n        bytes memory r = _call(d, abi.encodeCall(IGainsDiamond.getPendingOrders, (trader)));")],
        "test_GR1_08_(flattenIndicesWorks|pendingOrderLayout|tradeLayout|unreadableLayout)"),
    # GR1-10: zero sequencer feed accepted again; rotation copies nothing (the old policy had no rotation)
    "GR1-10": (
        [("src/gains/GainsVaultFactory.sol", "|| sentinel_ == address(0) || sequencerFeed_ == address(0)",
          "|| sentinel_ == address(0)"),
         ("src/gains/GainsVaultPolicy.sol", "        sequencerFeed = feed;\n        sequencerGracePeriod =",
          "        feed;\n        sequencerGracePeriod =")],
        "test_GR1_10_"),
    # GR1-12 / GR1-30: the policy owns itself again (Ownable2Step, renounce allowed)
    "GR1-12": (
        [("src/gains/GainsVaultPolicy.sol",
          """    function owner() public view override returns (address) {
        return OwnableUpgradeable(vault).owner();
    }

    function transferOwnership(address) public pure override {
        revert OwnershipFollowsVault();
    }

    function acceptOwnership() public pure override {
        revert OwnershipFollowsVault();
    }

    function renounceOwnership() public pure override {
        revert OwnershipFollowsVault();
    }
""", "")],
        "test_GR1_12_|test_GR1_30_"),
    # GR1-13: decimals not re-checked
    "GR1-13": (
        [("src/gains/GainsPrice.sol", "        if (_decimals(f.feed) != f.decimals) revert PriceStale(pairIndex);\n", "")],
        "test_GR1_13_"),
    # GR1-16: a full stop leaves resting orders
    "GR1-16": (
        [("src/gains/GainsVaultGovernance.sol", "        _cancelResting($);\n", "")],
        "test_GR1_16_"),
    # GR1-23: a dust checkpoint bounds settle again
    "GR1-23": (
        [("src/gains/GainsVaultPolicy.sol", "        if (prev < MIN_RISK_NAV) return (nav, true);\n", "")],
        "test_GR1_23_"),
    # GR1-24: uint64 accepted in read, priceAfterImpact wraps
    "GR1-24": (
        [("src/gains/GainsPrice.sol", "if (px == 0 || px > MAX_PRICE) revert PriceStale(pairIndex);",
          "if (px == 0 || px > type(uint64).max) revert PriceStale(pairIndex);"),
         ("src/gains/GainsNav.sol",
          "        if (raw <= 0) return 0;\n        return uint256(raw) > type(uint64).max ? type(uint64).max : uint64(uint256(raw));",
          "        return raw > 0 ? uint64(uint256(raw)) : 0;")],
        "test_GR1_24_"),
    # GR1-28: pending gov fee on the order's pairIndex (0) again
    "GR1-28": (
        [("src/gains/GainsNav.sol", "            feePair = t.pairIndex;\n            if (o.trade.collateralAmount > 0)",
          "            if (o.trade.collateralAmount > 0)"),
         ("src/gains/GainsNav.sol", "            feePair = t.pairIndex;\n            // A decrease",
          "            // A decrease")],
        "test_GR1_28_"),
    # GR1-31: only allowed pairs checked again
    "GR1-31": (
        [("src/gains/GainsVaultPolicy.sol", "            if (c.maxLeverageBps > navBoundLeverageBps(a, c.maxNavMoveBps)) revert LeverageAboveNavBound(a);",
          "            if (isAssetAllowed[a] && c.maxLeverageBps > navBoundLeverageBps(a, c.maxNavMoveBps)) revert LeverageAboveNavBound(a);")],
        "test_GR1_31_"),
    # GR1-32: a cancel keeps the next-epoch pointer
    "GR1-32": (
        [("src/gains/GainsVaultLogic.sol", "            r.epoch = $.currentEpoch;\n        } else {", "        } else {")],
        "test_GR1_32_"),
    # GR1-41: flatten(0) uses maxSlippageBps uncapped
    "GR1-41": (
        [("src/gains/GainsVaultPolicy.sol",
          "slippageBps = _config.maxSlippageBps < _config.maxFlattenSlippageBps ? _config.maxSlippageBps : _config.maxFlattenSlippageBps;",
          "slippageBps = _config.maxSlippageBps;")],
        "test_GR1_41_"),
    # GR1-44: feed calls get 63/64 of the gas again
    "GR1-44": (
        [("src/gains/GainsPrice.sol", "(ok, ret) = feed.staticcall{gas: FEED_GAS}(abi.encodeCall(IChainlinkFeed.latestRoundData, ()));",
          "(ok, ret) = feed.staticcall(abi.encodeCall(IChainlinkFeed.latestRoundData, ()));")],
        "test_GR1_44_"),
    # Earlier bug: the policy's pairMinPositionSizeUsd floor (same check, at the vault)
    "MINPOS": (
        [("src/gains/GainsVaultLogic.sol", "        uint8 ci = $.collateralIndex;\n        _checkOrder(",
          "        uint8 ci = $.collateralIndex;\n        if (GTrade.positionSize(o.collateral, o.leverage) < d.getCollateralFromUsdNormalizedValue(ci, d.pairMinPositionSizeUsd(o.pairIndex))) revert E.OrderRejected(\"position below min\");\n        _checkOrder(")],
        "test_policyDoesNotEnforcePairMinPositionSize"),
    # The surviving mutants re-applied against the new tests
    "MUT952": (
        [("src/gains/GainsVaultLogic.sol", "                $.carryOrigin = 0;", "                $.carryOrigin = 1;")],
        "test_MUT952_"),
    "MUT207": (
        [("src/gains/GainsVaultPolicy.sol", "uint256 band = (mark * _config.maxSlippageBps) / BPS;",
          "uint256 band = (mark / _config.maxSlippageBps) / BPS;")],
        "test_MUT207_"),
    "MUT753": (
        [("src/gains/GainsVaultPolicy.sol", "        timelockDelay = pendingTimelockDelay;\n        pendingTimelockEta = 0;",
          "        timelockDelay = pendingTimelockDelay;")],
        "test_MUT753_"),
}


def main():
    if sys.argv[1] == "--list":
        for k, (_, t) in UNFIX.items():
            print(f"{k}|{t}")
        return
    root, fid = sys.argv[1], sys.argv[2]
    for rel, new, old in UNFIX[fid][0]:
        p = root + "/" + rel
        s = open(p, encoding="utf-8", newline="").read()
        nl = "\r\n" if "\r\n" in s else "\n"
        s = s.replace("\r\n", "\n")
        if s.count(new) != 1:
            sys.exit(f"{fid}: {rel}: fixed code not found exactly once: {new[:80]!r}")
        s = s.replace(new, old)
        open(p, "w", encoding="utf-8", newline="").write(s.replace("\n", nl))
    print("unfixed", fid)


if __name__ == "__main__":
    main()
