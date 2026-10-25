// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

import {HloBase} from "./HloBase.t.sol";
import {HyperVault} from "../../../src/HyperVault.sol";
import {HyperVaultFactory} from "../../../src/HyperVaultFactory.sol";
import {VaultPolicy} from "../../../src/VaultPolicy.sol";
import {IHyperVaultErrors as E} from "../../../src/VaultTypes.sol";

/// @notice hl-open, open launch: what a stranger can do on the live configuration (openLaunch = true, no cap).
///         Run: forge test --match-path "test/audit/hl-open/HloOpenLaunch.t.sol" -vv
contract HloOpenLaunchTest is HloBase {
    address internal famous = makeAddr("famous.manager"); // a known manager with a real vault
    address internal mallory = makeAddr("mallory");

    // ------------------------------------------------------------------
    // HLO-01: spam. One wallet, no per-wallet limit, cost per vault = seed + HYPE + gas.
    // ------------------------------------------------------------------
    function test_HLO01_oneWalletLaunchesManyVaults_costPerVault() public {
        uint256 n = 50;
        _fundLauncher(mallory, n);
        uint256 usdcBefore = usdc.balanceOf(mallory);
        uint256 hypeBefore = mallory.balance;
        uint256 gasTotal;
        for (uint256 i; i < n; ++i) {
            HyperVaultFactory.CreateParams memory p = _params(mallory, bytes32(i));
            vm.prank(mallory);
            factory.create{value: 0.01 ether}(p, _noPermit());
            gasTotal += vm.lastCallGas().gasTotalUsed;
        }
        assertEq(factory.vaultCount(), n, "every launch from one wallet went through");
        uint256 usdcPer = (usdcBefore - usdc.balanceOf(mallory)) / n;
        uint256 hypePer = (hypeBefore - mallory.balance) / n;
        console2.log("HLO-01 USDC per vault (6 dp)", usdcPer);
        console2.log("HLO-01 HYPE per vault (wei)", hypePer);
        console2.log("HLO-01 create gas per vault (avg)", gasTotal / n);
        assertEq(usdcPer, 2e6);
        assertEq(hypePer, 0.01 ether);
    }

    /// @dev factory.vaults() copies the whole array: cold cost grows ~2.1k gas per vault. Measured with cold slots.
    function test_HLO01_vaultsViewGasIsLinear() public {
        _fundLauncher(mallory, 400);
        uint256[3] memory ns = [uint256(50), 200, 400];
        uint256 made;
        uint256[3] memory g;
        for (uint256 k; k < 3; ++k) {
            for (; made < ns[k]; ++made) {
                vm.prank(mallory);
                factory.create{value: 0.01 ether}(_params(mallory, bytes32(made)), _noPermit());
            }
            vm.cool(address(factory));
            factory.vaults();
            g[k] = vm.lastCallGas().gasTotalUsed;
            console2.log("HLO-01 vaults() gas at n =", ns[k], g[k]);
        }
        uint256 slope = (g[2] - g[0]) / (ns[2] - ns[0]);
        console2.log("HLO-01 vaults() gas per vault", slope);
        console2.log("HLO-01 n where vaults() > 2,000,000 gas (small block)", 2_000_000 / slope);
        console2.log("HLO-01 n where vaults() > 30,000,000 gas (big block)", 30_000_000 / slope);
        assertGt(slope, 2_000, "cold SLOAD per element");
    }

    // ------------------------------------------------------------------
    // HLO-02: impersonation. Name, symbol, owner, manager and the hosted flag are free text / free choice.
    // ------------------------------------------------------------------
    function test_HLO02_strangerClonesNameAndNamesAnotherWalletAsOwnerAndManager() public {
        _fundLauncher(famous, 1);
        HyperVaultFactory.CreateParams memory real = _params(famous, bytes32(0));
        real.name = "Famous BTC Trend";
        real.symbol = "fBTC";
        HyperVault original = _launch(famous, real);

        // Mallory launches a vault with the same name and symbol, names the famous wallet as owner AND manager
        // (no consent needed), keeps the fee recipient, and flags it hosted.
        _fundLauncher(mallory, 1);
        HyperVaultFactory.CreateParams memory fake = _params(mallory, bytes32(0));
        fake.name = "Famous BTC Trend";
        fake.symbol = "fBTC";
        fake.owner = famous;
        fake.manager = famous;
        fake.feeRecipient = mallory;
        fake.managementFeeBps = 500;
        fake.hosted = true;
        vm.recordLogs();
        HyperVault clone = _launch(mallory, fake);

        assertEq(clone.name(), original.name());
        assertEq(clone.symbol(), original.symbol());
        assertEq(clone.owner(), famous, "the famous wallet is the clone's owner without having signed anything");
        assertEq(clone.manager(), famous);
        assertEq(clone.feeRecipient(), mallory, "but the fees go to mallory");
        assertTrue(clone.hosted(), "any launcher can flag a vault as hosted");
        assertEq(clone.protocolShareBps(), factory.hostedShareBps());

        // The indexed `owner` topic of VaultCreated is the famous wallet: an indexer that lists "vaults by owner"
        // shows the clone under the famous manager.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(factory) && logs[i].topics[0] == HyperVaultFactory.VaultCreated.selector) {
                assertEq(address(uint160(uint256(logs[i].topics[3]))), famous);
                seen = true;
            }
        }
        assertTrue(seen);

        // Fees accrue to mallory on deposits that believe they are with the famous manager.
        vm.prank(alice);
        usdc.approve(address(clone), type(uint256).max);
        vm.roll(vm.getBlockNumber() + 400);
        vm.prank(alice);
        clone.requestDeposit(100_000e6, alice);
        clone.checkRisk();
        vm.prank(keeper);
        clone.settle();
        vm.warp(vm.getBlockTimestamp() + 365 days);
        clone.accrueFees();
        uint256 malloryValue = clone.convertToAssets(clone.balanceOf(mallory));
        console2.log("HLO-02 fee value to mallory after 1y on 100k (6 dp)", malloryValue);
        assertGt(malloryValue, 3_000e6);
    }

    /// @dev Platform addresses may also be named in a stranger's vault: owner = sentinel, manager = keeper,
    ///      fee recipient = protocol treasury. The contract does not care; the executor must not infer trust from it.
    function test_HLO02_platformAddressesCanBeNamedInAStrangersVault() public {
        _fundLauncher(mallory, 1);
        HyperVaultFactory.CreateParams memory p = _params(mallory, bytes32(0));
        p.owner = sentinel;
        p.manager = keeper;
        p.feeRecipient = treasury;
        HyperVault v = _launch(mallory, p);
        assertEq(v.owner(), sentinel);
        assertEq(v.manager(), keeper);
        assertEq(v.operator(), keeper);
        assertEq(v.feeRecipient(), treasury);
    }

    // ------------------------------------------------------------------
    // HLO-03: hostile but valid policy. The factory checks assets and the cap only; VaultPolicy._validate allows
    // 50x, a 100% daily loss and drawdown (breakers off), 20% slippage, 30 day epochs, a 100% NAV move per settle.
    // ------------------------------------------------------------------
    function _hostile() internal pure returns (VaultPolicy.RiskConfig memory) {
        return VaultPolicy.RiskConfig({
            maxLeverageBps: 500_000,
            maxDailyLossBps: 10_000,
            maxDrawdownBps: 10_000,
            maxSlippageBps: 2_000,
            maxOrderNotional: type(uint64).max,
            maxEpochDuration: 30 days,
            maxNavMoveBps: 10_000,
            maxFlattenSlippageBps: 300
        });
    }

    function _hostileVault() internal returns (HyperVault v) {
        _fundLauncher(mallory, 1);
        HyperVaultFactory.CreateParams memory p = _params(mallory, bytes32(0));
        p.risk = _hostile();
        p.managementFeeBps = 500;
        p.performanceFeeBps = 3_000;
        p.timelockDelay = 30 days;
        v = _launch(mallory, p);
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        vm.roll(vm.getBlockNumber() + 400);
        vm.prank(alice);
        v.requestDeposit(100_000e6, alice);
        v.checkRisk();
        vm.prank(keeper);
        v.settle();
        // the deposit is now on Core
        usdc.burnFrom(address(v), 100_000e6);
        _setCore(address(v), 100_002e6, 0, 0);
    }

    function test_HLO03_hostilePolicyIsAcceptedAndDisablesTheBreakers() public {
        HyperVault v = _hostileVault();
        VaultPolicy pol = v.policy();
        assertEq(pol.maxLeverageBps(), 500_000);
        assertEq(pol.maxNavMoveBps(), 10_000);

        // A 95% loss with 49x leverage: no breach, the agent and trading stay on.
        _setCore(address(v), 5_000e6, 245_000e6, 0);
        (uint256 lev, uint256 daily, uint256 dd) = v.checkRisk();
        console2.log("HLO-03 leverage bps / daily loss bps / drawdown bps", lev, daily, dd);
        assertFalse(v.breached(), "breakers off");
        assertGt(daily, 9_000);
    }

    function test_HLO03_maxNavMove100pctLetsANormalSettlePriceAHalvedNav() public {
        HyperVault v = _hostileVault();
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        v.checkRisk();
        // NAV halves (a mark spike, a deflation by a compromised agent, I3-01): a confederate deposit is minted at it.
        _setCore(address(v), 50_001e6, 0, 0);
        address conf = makeAddr("confederate");
        usdc.mint(conf, 50_000e6);
        vm.startPrank(conf);
        usdc.approve(address(v), type(uint256).max);
        v.requestDeposit(50_000e6, conf);
        vm.stopPrank();
        vm.prank(keeper);
        v.settle(); // the platform keeper settles it: no NavMoved
        (, uint256 depShares,,,,,,) = v.epochs(v.currentEpoch() - 1);
        assertGt(depShares, 0);
        // NAV comes back: the confederate holds half the vault for a third of the money.
        _setCore(address(v), 150_001e6, 0, 0);
        uint256 confValue = v.convertToAssets(depShares);
        console2.log("HLO-03 confederate 50k deposit worth after NAV restores (6 dp)", confValue);
        assertGt(confValue, 74_000e6);
    }

    function test_HLO03_sameMoveRevertsUnderTheDefaultPolicy() public {
        _fundLauncher(mallory, 1);
        HyperVault v = _launch(mallory, _params(mallory, bytes32(0)));
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        vm.roll(vm.getBlockNumber() + 400);
        vm.prank(alice);
        v.requestDeposit(100_000e6, alice);
        v.checkRisk();
        vm.prank(keeper);
        v.settle();
        usdc.burnFrom(address(v), 100_000e6);
        _setCore(address(v), 100_002e6, 0, 0);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        v.checkRisk();
        _setCore(address(v), 50_001e6, 0, 0);
        vm.prank(bob);
        usdc.approve(address(v), type(uint256).max);
        vm.prank(bob);
        v.requestDeposit(50_000e6, bob);
        vm.prank(keeper);
        vm.expectRevert(); // NavMoved (or the drawdown breach turns it redemption-only and nothing is minted)
        v.settle();
    }

    function test_HLO03_redemptionsWaitUpTo30DaysBeforeAnyoneCanForceAnExit() public {
        HyperVault v = _hostileVault();
        vm.prank(alice);
        v.claim(alice);
        uint256 shares = v.balanceOf(alice);
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        vm.warp(vm.getBlockTimestamp() + 29 days);
        vm.prank(stranger);
        vm.expectRevert(E.NotOverdue.selector);
        v.triggerEmergency();
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.prank(stranger);
        v.triggerEmergency();
        assertTrue(v.emergency());
    }

    // ------------------------------------------------------------------
    // HLO-04: isolation. What a stranger's launch can and cannot do to other vaults, the factory and agents.
    // ------------------------------------------------------------------
    function test_HLO04_registrarSignatureIsBoundToTheCreator() public {
        address agentA = makeAddr("agentA");
        address predicted = factory.predictVaultAddress(famous, bytes32(0));
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _agentSig(agentA, predicted, deadline);

        // Mallory copies the signature from the mempool: her predicted vault differs, the signature fails.
        _fundLauncher(mallory, 1);
        HyperVaultFactory.CreateParams memory p = _params(mallory, bytes32(0));
        p.agent = agentA;
        p.agentSig = sig;
        p.agentDeadline = deadline;
        vm.prank(mallory);
        vm.expectRevert(HyperVaultFactory.BadAgentSignature.selector);
        factory.create{value: 0.01 ether}(p, _noPermit());

        // The famous launch still goes through.
        _fundLauncher(famous, 1);
        HyperVaultFactory.CreateParams memory q = _params(famous, bytes32(0));
        q.agent = agentA;
        q.agentSig = sig;
        q.agentDeadline = deadline;
        HyperVault v = _launch(famous, q);
        assertEq(v.agent(), agentA);
    }

    /// @dev The signature covers (agent, predicted vault, deadline) only. A launcher who got a signature for one
    ///      set of parameters may launch with any other: hosted, any operator, any policy, any owner.
    function test_HLO04_signatureDoesNotCoverTheLaunchParameters() public {
        address agentM = makeAddr("agentM");
        address predicted = factory.predictVaultAddress(mallory, bytes32(uint256(7)));
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _agentSig(agentM, predicted, deadline);

        _fundLauncher(mallory, 1);
        HyperVaultFactory.CreateParams memory p = _params(mallory, bytes32(uint256(7)));
        p.agent = agentM;
        p.agentSig = sig;
        p.agentDeadline = deadline;
        p.hosted = true;
        p.owner = famous;
        p.risk = _hostile();
        HyperVault v = _launch(mallory, p);
        assertEq(v.agent(), agentM);
        assertTrue(v.hosted());
        assertEq(v.owner(), famous);
        assertEq(v.policy().maxLeverageBps(), 500_000);
    }

    /// @dev An agent the registrar signed for two predicted vaults binds to whichever launches first; the other
    ///      launch reverts. Only matters if the executor ever hands one agent to two launch requests.
    function test_HLO04_oneAgentSignedTwiceFirstLaunchWins() public {
        address agentX = makeAddr("agentX");
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sigFamous = _agentSig(agentX, factory.predictVaultAddress(famous, bytes32(0)), deadline);
        bytes memory sigMallory = _agentSig(agentX, factory.predictVaultAddress(mallory, bytes32(0)), deadline);

        _fundLauncher(mallory, 1);
        HyperVaultFactory.CreateParams memory p = _params(mallory, bytes32(0));
        (p.agent, p.agentSig, p.agentDeadline) = (agentX, sigMallory, deadline);
        _launch(mallory, p);

        _fundLauncher(famous, 1);
        HyperVaultFactory.CreateParams memory q = _params(famous, bytes32(0));
        (q.agent, q.agentSig, q.agentDeadline) = (agentX, sigFamous, deadline);
        vm.prank(famous);
        vm.expectRevert();
        factory.create{value: 0.01 ether}(q, _noPermit());
    }

    /// @dev A stranger cannot use a launch to touch another vault or the factory's roles. Every factory entry point
    ///      a stranger can reach is create() and the views; the vault calls back only protocolFeeRecipient(),
    ///      platformAgentFor(), guardian(), sentinel() and maxDepositCap().
    function test_HLO04_strangerCannotReachPlatformOrOtherVaults() public {
        _fundLauncher(famous, 1);
        HyperVault theirs = _launch(famous, _params(famous, bytes32(0)));
        _fundLauncher(mallory, 1);
        HyperVault mine = _launch(mallory, _params(mallory, bytes32(0)));

        vm.startPrank(mallory);
        vm.expectRevert(HyperVaultFactory.NotRegistrar.selector);
        factory.registerPlatformAgent(mallory, address(theirs));
        vm.expectRevert(HyperVaultFactory.NotRegistrar.selector);
        factory.unregisterPlatformAgent(address(1));
        vm.expectRevert();
        factory.lowerProtocolShare(address(mine), 0);
        vm.expectRevert(E.Unauthorized.selector);
        theirs.settle();
        vm.expectRevert(E.Unauthorized.selector);
        theirs.revokeAgent();
        vm.expectRevert(E.Unauthorized.selector);
        theirs.triggerBreach();
        // and her own vault's owner powers do not reach the platform roles
        mine.setOperator(mallory);
        vm.expectRevert(E.Unauthorized.selector);
        mine.exitEmergency();
        vm.stopPrank();
        assertEq(mine.guardian(), guardian);
        assertEq(mine.sentinel(), sentinel);
        // same salt, different creators: different addresses (salts are scoped per creator)
        assertTrue(address(theirs) != address(mine));
    }

    /// @dev Protocol fee shares of every stranger vault are minted to the one treasury address. Harmless to the
    ///      treasury (it never calls the vault), but the treasury accumulates positions in vaults it never vetted.
    function test_HLO04_treasuryReceivesSharesOfStrangerVaults() public {
        HyperVault v = _hostileVault();
        vm.warp(vm.getBlockTimestamp() + 30 days);
        v.accrueFees();
        assertGt(v.balanceOf(treasury), 0);
    }

    // ------------------------------------------------------------------
    // Re-test N-09 under open launch: the insider rule covers the manager, owner and fee recipient; a sybil
    // confederate deposit is priced in the current epoch and the manager settles it whenever they like.
    // ------------------------------------------------------------------
    function test_HLO_N09_confederatePricedNowManagerSettlesAtWill() public {
        _fundLauncher(mallory, 1);
        HyperVaultFactory.CreateParams memory p = _params(mallory, bytes32(0));
        p.operator = address(0);
        HyperVault v = _launch(mallory, p);
        vm.roll(vm.getBlockNumber() + 400);
        address conf = makeAddr("confederate");
        usdc.mint(conf, 10_000e6);
        usdc.mint(mallory, 10_000e6);
        vm.prank(conf);
        usdc.approve(address(v), type(uint256).max);
        vm.prank(mallory);
        usdc.approve(address(v), type(uint256).max);

        vm.prank(mallory);
        uint256 insiderEpoch = v.requestDeposit(10_000e6, mallory);
        vm.prank(conf);
        uint256 confEpoch = v.requestDeposit(10_000e6, conf);
        assertEq(insiderEpoch, v.currentEpoch() + 1, "insider deferred");
        assertEq(confEpoch, v.currentEpoch(), "confederate priced in this epoch");
        v.checkRisk();
        vm.prank(mallory); // the manager settles one block after the request
        v.settle();
        assertGt(v.balanceOf(address(v)), 0, "confederate shares minted at the manager-chosen moment");
    }

}
