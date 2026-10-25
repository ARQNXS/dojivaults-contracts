// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {MutBase} from "./MutBase.t.sol";
import {HyperVault} from "../../../../src/HyperVault.sol";
import {VaultPolicy} from "../../../../src/VaultPolicy.sol";
import {InitParams, IHyperVaultErrors as E} from "../../../../src/VaultTypes.sol";
import {ICoreDepositWallet} from "../../../../src/hypercore/HyperCore.sol";

contract EighteenDecimals is ERC20 {
    constructor() ERC20("X", "X") {}
}

/// @title hl-r2 mutation kill tests: VaultGovernance.initialize parameter checks and the values it stores
/// @notice Factory vaults pass these through create(); a standalone vault takes them as given. No earlier test
///         initialised a vault with an out-of-range parameter.
contract HLR2MutInitTest is MutBase {
    function _init(InitParams memory p) internal returns (bool ok, bytes4 err) {
        HyperVault v = HyperVault(Clones.clone(address(vaultImpl)));
        try v.initialize(p) {
            ok = true;
        } catch (bytes memory e) {
            err = bytes4(e);
        }
    }

    function _expect(InitParams memory p, bytes4 err) internal {
        (bool ok, bytes4 got) = _init(p);
        assertFalse(ok, "must revert");
        assertEq(got, err);
    }

    function test_HLR2_M58_kills_initializeChecks() public {
        InitParams memory p;
        // zero roles and contracts
        p = _standaloneParams(policy);
        p.manager = address(0);
        _expect(p, E.ZeroAddress.selector);
        p = _standaloneParams(policy);
        p.feeRecipient = address(0);
        _expect(p, E.ZeroAddress.selector);
        p = _standaloneParams(policy);
        p.policy = VaultPolicy(address(0));
        _expect(p, E.ZeroAddress.selector);
        p = _standaloneParams(policy);
        p.coreDepositWallet = ICoreDepositWallet(address(0));
        _expect(p, E.ZeroAddress.selector);
        p = _standaloneParams(policy);
        p.guardian = address(0); // standalone without a guardian
        _expect(p, E.ZeroAddress.selector);
        // a non-6-decimal asset
        p = _standaloneParams(policy);
        p.asset = IERC20(address(new EighteenDecimals()));
        _expect(p, E.UnsupportedAsset.selector);
        // fee caps: 5% management, 30% performance, each on its own
        p = _standaloneParams(policy);
        p.managementFeeBps = 501;
        _expect(p, E.InvalidFee.selector);
        p = _standaloneParams(policy);
        p.managementFeeBps = 1_000;
        _expect(p, E.InvalidFee.selector);
        p = _standaloneParams(policy);
        p.performanceFeeBps = 3_001;
        _expect(p, E.InvalidFee.selector);
        p = _standaloneParams(policy);
        p.performanceFeeBps = 6_000;
        _expect(p, E.InvalidFee.selector);
        // timelock bounds
        p = _standaloneParams(policy);
        p.timelockDelay = 1 days - 1;
        _expect(p, E.InvalidTimelock.selector);
        p = _standaloneParams(policy);
        p.timelockDelay = 0;
        _expect(p, E.InvalidTimelock.selector);
        p = _standaloneParams(policy);
        p.timelockDelay = 30 days + 1;
        _expect(p, E.InvalidTimelock.selector);
        p = _standaloneParams(policy);
        p.timelockDelay = 60 days;
        _expect(p, E.InvalidTimelock.selector);
        // protocol / base share caps (50%)
        p = _standaloneParams(policy);
        p.protocolShareBps = 5_001;
        _expect(p, E.InvalidShare.selector);
        p = _standaloneParams(policy);
        p.baseShareBps = 5_001;
        _expect(p, E.InvalidShare.selector);
        p = _standaloneParams(policy);
        p.protocolShareBps = 10_000;
        _expect(p, E.InvalidShare.selector);

        // every bound itself is valid, and address(1) is an ordinary address
        p = _standaloneParams(policy);
        p.managementFeeBps = 500;
        p.performanceFeeBps = 3_000;
        p.timelockDelay = 30 days;
        p.protocolShareBps = 5_000;
        p.baseShareBps = 5_000;
        p.manager = address(1);
        p.feeRecipient = address(1);
        p.guardian = address(1);
        (bool ok,) = _init(p);
        assertTrue(ok);
        p = _standaloneParams(policy);
        p.timelockDelay = 1 days;
        (ok,) = _init(p);
        assertTrue(ok);
    }

    /// Mutants on the values initialize stores (deleted assignments of fees, shares, hosted, roles, cap, epoch
    /// start, risk references) are killed by reading every stored field back.
    function test_HLR2_M59_kills_initializeStores() public {
        InitParams memory p = _standaloneParams(policy);
        p.managementFeeBps = 123;
        p.performanceFeeBps = 456;
        p.timelockDelay = 3 days;
        p.depositCap = 777e6;
        p.protocolShareBps = 1_111;
        p.baseShareBps = 222;
        p.hosted = true;
        p.operator = makeAddr("op");
        HyperVault v = HyperVault(Clones.clone(address(vaultImpl)));
        vm.warp(1_760_000_000); // a real date: riskDay != 0
        uint256 t0 = vm.getBlockTimestamp();
        v.initialize(p);
        assertEq(v.asset(), address(usdc));
        assertEq(address(v.policy()), address(policy));
        assertEq(address(v.coreDepositWallet()), address(depositWallet));
        assertEq(v.factory(), address(0));
        assertEq(v.protocolShareBps(), 1_111);
        assertEq(v.baseShareBps(), 222);
        assertTrue(v.hosted());
        assertEq(v.manager(), manager);
        assertEq(v.guardian(), guardian);
        assertEq(v.feeRecipient(), feeRecipient);
        assertEq(v.managementFeeBps(), 123);
        assertEq(v.performanceFeeBps(), 456);
        assertEq(v.timelockDelay(), 3 days);
        assertEq(v.depositCap(), 777e6);
        assertEq(v.highWaterMark(), 1e6);
        assertEq(v.peakSharePrice(), 1e6);
        assertEq(v.epochStartedAt(), t0);
        assertEq(v.lastFeeAccrual(), t0);
        assertEq(v.riskDay(), t0 / 1 days);
        assertEq(v.operator(), p.operator);
        assertEq(v.owner(), owner);
    }
}
