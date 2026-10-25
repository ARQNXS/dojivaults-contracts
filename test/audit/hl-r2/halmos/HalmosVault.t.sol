// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {HyperVault} from "../../../../src/HyperVault.sol";
import {VaultLogic} from "../../../../src/VaultLogic.sol";
import {VaultGovernance} from "../../../../src/VaultGovernance.sol";
import {VaultPolicy} from "../../../../src/VaultPolicy.sol";
import {InitParams} from "../../../../src/VaultTypes.sol";
import {HyperCore, ICoreDepositWallet} from "../../../../src/hypercore/HyperCore.sol";
import {MockUSDC, MockPrecompile, MockCoreWriter, MockCoreDepositWallet} from "../../../mocks/Mocks.sol";

/// @title hl-r2 Halmos properties of single vault operations with a symbolic HyperCore (mocked precompiles)
/// @notice `check_` prefix: halmos only (forge test ignores it). The setup is concrete (one settled epoch, alice
///         holds shares, the vault has idle USDC and Core equity); each property makes the next inputs symbolic:
///         Core account value and spot balance (the NAV), the deposit and redemption sizes, and the time.
///         No fees (0 / 0) so that every share price move is attributable to the flows. Standalone vault.
///         Conservation checked, per operation:
///           idle' = idle + dep_in - paid (settle), USDC moves only by the documented amount (claim / cancels),
///           claimable reserve covers every claim, minted shares == the shares the depositors can claim,
///           and the incumbents' share price is never lowered by a flow (rounding favours the vault).
contract HalmosVault is Test {
    MockUSDC internal usdc;
    MockCoreDepositWallet internal depositWallet;
    VaultPolicy internal policy;
    HyperVault internal vault;

    address internal constant OWNER = address(0x10001);
    address internal constant MANAGER = address(0x10002);
    address internal constant GUARDIAN = address(0x10003);
    address internal constant FEES = address(0x10004);
    address internal constant ALICE = address(0x10005);
    address internal constant BOB = address(0x10006);

    /// @dev Halmos does not link external libraries: the halmos project (C:\hlr2\hal, see HALMOS.md) links
    ///      VaultLogic / VaultGovernance at these fixed addresses (foundry `libraries`), and setUp puts their code
    ///      there. Under a normal forge build these constants are unused.
    address internal constant LOGIC = 0x00000000000000000000000000000000000A1001;
    address internal constant GOVERNANCE = 0x00000000000000000000000000000000000A1002;

    uint256 internal t; // our clock (no block.timestamp reads in tests)
    uint256 internal bn; // our block number

    function setUp() public {
        t = 1_700_000_000;
        vm.warp(t);
        bn = 1000;
        vm.roll(bn);
        usdc = new MockUSDC();
        depositWallet = new MockCoreDepositWallet(IERC20(address(usdc)));
        MockCoreWriter cw = new MockCoreWriter();
        vm.etch(HyperCore.CORE_WRITER, address(cw).code);
        MockPrecompile mp = new MockPrecompile();
        vm.etch(HyperCore.PRECOMPILE_SPOT_BALANCE, address(mp).code);
        vm.etch(HyperCore.PRECOMPILE_ACCOUNT_MARGIN_SUMMARY, address(mp).code);
        vm.etch(HyperCore.PRECOMPILE_CORE_USER_EXISTS, address(mp).code);
        vm.etch(HyperCore.PRECOMPILE_WITHDRAWABLE, address(mp).code);

        bytes memory c1 = type(VaultLogic).creationCode;
        address l1;
        assembly ("memory-safe") {
            l1 := create(0, add(c1, 0x20), mload(c1))
        }
        vm.etch(LOGIC, l1.code);
        bytes memory c2 = type(VaultGovernance).creationCode;
        address l2;
        assembly ("memory-safe") {
            l2 := create(0, add(c2, 0x20), mload(c2))
        }
        vm.etch(GOVERNANCE, l2.code);

        VaultPolicy policyImpl = new VaultPolicy();
        HyperVault vaultImpl = new HyperVault();
        policy = VaultPolicy(Clones.clone(address(policyImpl)));
        uint32[] memory assets = new uint32[](0);
        policy.initialize(
            OWNER,
            VaultPolicy.RiskConfig({
                maxLeverageBps: 30_000,
                maxDailyLossBps: 10_000,
                maxDrawdownBps: 10_000,
                maxSlippageBps: 100,
                maxOrderNotional: 1_000_000e6,
                maxEpochDuration: 7 days,
                maxNavMoveBps: 10_000,
                maxFlattenSlippageBps: 300
            }),
            assets,
            2 days,
            address(0)
        );
        vault = HyperVault(Clones.clone(address(vaultImpl)));
        vault.initialize(
            InitParams({
                asset: IERC20(address(usdc)),
                name: "H",
                symbol: "H",
                owner: OWNER,
                manager: MANAGER,
                guardian: GUARDIAN,
                feeRecipient: FEES,
                managementFeeBps: 0,
                performanceFeeBps: 0,
                timelockDelay: 2 days,
                depositCap: 0,
                policy: policy,
                coreDepositWallet: ICoreDepositWallet(address(depositWallet)),
                factory: address(0),
                protocolShareBps: 0,
                baseShareBps: 0,
                hosted: false,
                agent: address(0),
                operator: address(0),
                seedUsdc: 0
            })
        );
        _core(true, 0, 0);
        usdc.mint(ALICE, 1e15);
        usdc.mint(BOB, 1e15);
        vm.prank(ALICE);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(BOB);
        usdc.approve(address(vault), type(uint256).max);

        // epoch 0: alice deposits 1,000 USDC, settled at 1 USDC / share
        vm.prank(ALICE);
        vault.requestDeposit(1_000e6, ALICE);
        _tick(1 hours);
        vault.checkRisk();
        vm.prank(MANAGER);
        vault.settle();
        vault.claim(ALICE);
        _tick(1 hours);
    }

    function _tick(uint256 dt) internal {
        t += dt;
        vm.warp(t);
        bn += 1000;
        vm.roll(bn);
    }

    function _core(bool exists, int64 accountValue, uint64 spotUsdc) internal {
        address v = address(vault);
        MockPrecompile(HyperCore.PRECOMPILE_CORE_USER_EXISTS).setResponse(abi.encode(v), abi.encode(exists));
        MockPrecompile(HyperCore.PRECOMPILE_ACCOUNT_MARGIN_SUMMARY).setResponse(
            abi.encode(uint32(0), v), abi.encode(HyperCore.AccountMarginSummary(accountValue, 0, 0, accountValue))
        );
        MockPrecompile(HyperCore.PRECOMPILE_SPOT_BALANCE).setResponse(
            abi.encode(v, uint64(0)), abi.encode(HyperCore.SpotBalance(spotUsdc * 100, 0, 0))
        );
    }

    function _idle() internal view returns (uint256) {
        uint256 bal = usdc.balanceOf(address(vault));
        uint256 reserved = vault.pendingDepositAssets() + vault.deferredDepositAssets() + vault.claimableRedeemAssets();
        return bal > reserved ? bal - reserved : 0;
    }

    struct Snap {
        uint256 bal;
        uint256 idle;
        uint256 claimable;
        uint256 pendingDep;
        uint256 pendingRed;
        uint256 supply;
        uint256 vaultShares;
        uint256 nav;
    }

    function _snap() internal view returns (Snap memory s) {
        s.bal = usdc.balanceOf(address(vault));
        s.idle = _idle();
        s.claimable = vault.claimableRedeemAssets();
        s.pendingDep = vault.pendingDepositAssets();
        s.pendingRed = vault.pendingRedeemShares();
        s.supply = vault.totalSupply();
        s.vaultShares = vault.balanceOf(address(vault));
        s.nav = vault.totalAssets();
    }

    /// V1. Normal settle with a symbolic NAV (Core account value + spot), a symbolic deposit and a symbolic
    ///     redemption: USDC never moves, the reserve grows by exactly the payout, minted shares are exactly what the
    ///     depositor can claim, the payout never exceeds the reserve, and the incumbents' share price never drops.
    function check_V1_settleNormalConserves(int64 av, uint64 spot, uint128 dep, uint128 red) public {
        vm.assume(av >= 0 && uint64(av) <= 1e15 && spot <= 1e15);
        vm.assume(dep >= 10e6 && dep <= 1e15);
        uint256 aliceShares = vault.balanceOf(ALICE);
        vm.assume(red > 0 && red <= aliceShares);
        vm.prank(BOB);
        vault.requestDeposit(dep, BOB);
        vm.prank(ALICE);
        vault.requestRedeem(red, ALICE, ALICE);
        _core(true, av, spot);
        _tick(1 hours);
        vault.checkRisk();
        Snap memory b = _snap();
        vm.prank(MANAGER);
        vault.settle();
        Snap memory a = _snap();
        (,, uint256 redShares, uint256 paid, uint256 burned,,,) = vault.epochs(vault.currentEpoch() - 1);
        (, uint256 depShares,,,,,,) = vault.epochs(vault.currentEpoch() - 1);

        assert(a.bal == b.bal); // settle moves no USDC
        assert(redShares == red && burned == red); // normal settle: all or nothing
        assert(a.claimable == b.claimable + paid);
        assert(a.pendingDep == 0 && a.pendingRed == 0);
        assert(a.idle + paid == b.idle + dep); // idle' = idle + dep - paid
        assert(a.supply + burned == b.supply + depShares);
        assert(a.vaultShares + burned == b.vaultShares + depShares);
        // claims: bob gets exactly the minted shares, alice exactly the payout, within the reserve
        vault.claim(BOB);
        assert(vault.balanceOf(BOB) == depShares);
        uint256 before = usdc.balanceOf(ALICE);
        vault.claim(ALICE);
        assert(usdc.balanceOf(ALICE) - before == paid);
        assert(vault.claimableRedeemAssets() == b.claimable);
        // incumbents: price after >= price before (cross-multiplied with the virtual offset)
        assert((a.nav + 1) * (b.supply + 1e6) >= (b.nav + 1) * (a.supply + 1e6));
    }

    /// V2. Exit-only settle in emergency with a symbolic NAV and a symbolic redemption: deposits are refunded, never
    ///     minted; the payout is at most the idle USDC and at most the redemption's value at min(NAV, checkpoint);
    ///     never more shares burned than paid for; the reserve covers payout + refunds.
    function check_V2_settleEmergencyConserves(int64 av, uint64 spot, uint128 dep, uint128 red) public {
        vm.assume(av >= 0 && uint64(av) <= 1e15 && spot <= 1e15);
        vm.assume(dep >= 10e6 && dep <= 1e15);
        uint256 aliceShares = vault.balanceOf(ALICE);
        vm.assume(red > 0 && red <= aliceShares);
        vm.prank(BOB);
        vault.requestDeposit(dep, BOB);
        vm.prank(ALICE);
        vault.requestRedeem(red, ALICE, ALICE);
        vm.prank(GUARDIAN);
        vault.triggerEmergency();
        _core(true, av, spot);
        _tick(1 hours);
        Snap memory b = _snap();
        uint256 cp = vault.checkpointNav();
        vm.prank(GUARDIAN);
        vault.settle();
        Snap memory a = _snap();
        (uint256 depAssets, uint256 depShares, uint256 redShares, uint256 paid, uint256 burned,,,) =
            vault.epochs(vault.currentEpoch() - 1);
        uint256 priceNav = cp > 0 && cp < b.nav ? cp : b.nav;

        assert(a.bal == b.bal);
        assert(depShares == 0 && depAssets == dep);
        assert(redShares == red && burned <= red);
        assert(paid <= b.idle);
        assert(paid * (b.supply + 1e6) <= uint256(red) * (priceNav + 1)); // never above the value at min(NAV, cp)
        assert(burned * (priceNav + 1) <= paid * (b.supply + 1e6) + (b.supply + 1e6)); // never over-burn (< 1 unit)
        assert(a.claimable == b.claimable + paid + dep);
        assert(a.pendingDep == 0 && a.pendingRed == 0);
        // claims stay within the reserve and return the unburned shares
        uint256 aliceUsdc = usdc.balanceOf(ALICE);
        vault.claim(ALICE);
        vault.claim(BOB);
        assert(usdc.balanceOf(ALICE) - aliceUsdc <= paid);
        assert(vault.balanceOf(ALICE) == aliceShares - burned); // the unpaid shares come back whole
        assert(vault.balanceOf(BOB) == 0);
        assert(usdc.balanceOf(address(vault)) >= vault.claimableRedeemAssets());
    }

    /// V3. cancelDepositRequest: the USDC returned equals the request, the queue shrinks by the same amount, idle
    ///     and the share supply do not move.
    function check_V3_cancelDepositConserves(uint128 dep) public {
        vm.assume(dep >= 10e6 && dep <= 1e15);
        vm.prank(BOB);
        vault.requestDeposit(dep, BOB);
        Snap memory b = _snap();
        uint256 bobBefore = usdc.balanceOf(BOB);
        vm.prank(BOB);
        vault.cancelDepositRequest();
        Snap memory a = _snap();
        assert(usdc.balanceOf(BOB) - bobBefore == dep);
        assert(b.bal - a.bal == dep);
        assert(b.pendingDep - a.pendingDep == dep);
        assert(a.idle == b.idle && a.supply == b.supply);
    }

    /// V4. cancelRedeemRequest: the shares come back in full, the vault's share balance and the queue shrink by
    ///     the same amount, no USDC moves.
    function check_V4_cancelRedeemConserves(uint128 red) public {
        uint256 aliceShares = vault.balanceOf(ALICE);
        vm.assume(red > 0 && red <= aliceShares);
        vm.prank(ALICE);
        vault.requestRedeem(red, ALICE, ALICE);
        Snap memory b = _snap();
        vm.prank(ALICE);
        vault.cancelRedeemRequest();
        Snap memory a = _snap();
        assert(vault.balanceOf(ALICE) == aliceShares);
        assert(b.vaultShares - a.vaultShares == red && b.pendingRed - a.pendingRed == red);
        assert(a.bal == b.bal && a.supply == b.supply);
    }

    /// V5. requestDeposit / requestRedeem: USDC in == request, queue up by the same amount, idle unchanged; shares
    ///     move into custody, supply unchanged.
    function check_V5_requestsConserve(uint128 dep, uint128 red) public {
        vm.assume(dep >= 10e6 && dep <= 1e15);
        uint256 aliceShares = vault.balanceOf(ALICE);
        vm.assume(red > 0 && red <= aliceShares);
        Snap memory b = _snap();
        vm.prank(BOB);
        vault.requestDeposit(dep, BOB);
        vm.prank(ALICE);
        vault.requestRedeem(red, ALICE, ALICE);
        Snap memory a = _snap();
        assert(a.bal - b.bal == dep && a.pendingDep - b.pendingDep == dep);
        assert(a.idle == b.idle);
        assert(a.vaultShares - b.vaultShares == red && a.pendingRed - b.pendingRed == red && a.supply == b.supply);
    }

    /// Negative controls (expected to FAIL with a counterexample): the symbolic paths of V5 and V1 are reachable,
    /// so their PASS is not vacuous.
    function check_X1_requestsReachable(uint128 dep, uint128 red) public {
        vm.assume(dep >= 10e6 && dep <= 1e15);
        uint256 aliceShares = vault.balanceOf(ALICE);
        vm.assume(red > 0 && red <= aliceShares);
        vm.prank(BOB);
        vault.requestDeposit(dep, BOB);
        vm.prank(ALICE);
        vault.requestRedeem(red, ALICE, ALICE);
        assert(vault.pendingDepositAssets() != dep); // false on every path: halmos must report a counterexample
    }

    function check_X2_settleReachable(int64 av, uint64 spot, uint128 dep, uint128 red) public {
        vm.assume(av >= 0 && uint64(av) <= 1e15 && spot <= 1e15);
        vm.assume(dep >= 10e6 && dep <= 1e15);
        uint256 aliceShares = vault.balanceOf(ALICE);
        vm.assume(red > 0 && red <= aliceShares);
        vm.prank(BOB);
        vault.requestDeposit(dep, BOB);
        vm.prank(ALICE);
        vault.requestRedeem(red, ALICE, ALICE);
        _core(true, av, spot);
        _tick(1 hours);
        vault.checkRisk();
        vm.prank(MANAGER);
        vault.settle();
        assert(vault.pendingDepositAssets() != 0); // false after a settle: a counterexample shows settle is reachable
    }
}
