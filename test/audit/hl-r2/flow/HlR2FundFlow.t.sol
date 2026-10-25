// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {HloBase} from "../../hl-open/HloBase.t.sol";
import {HyperVault} from "../../../../src/HyperVault.sol";
import {HyperVaultFactory} from "../../../../src/HyperVaultFactory.sol";
import {VaultLogic} from "../../../../src/VaultLogic.sol";
import {VaultGovernance} from "../../../../src/VaultGovernance.sol";
import {IHyperVaultErrors} from "../../../../src/VaultTypes.sol";
import {HyperCore, ICoreDepositWallet} from "../../../../src/hypercore/HyperCore.sol";
import {LinkedLibraries} from "../../../../script/Deploy.s.sol";

contract Junk is ERC20 {
    constructor() ERC20("Junk", "J") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// @notice hl-r2 flow review: the bound of every path that moves USDC, shares, allowances or HyperCore balances.
///         One test per row of FUND-FLOW.md that no earlier test pins down exactly.
contract HlR2FundFlowTest is HloBase {
    function _seeded(uint256 amount) internal returns (uint256 shares) {
        _deposit(alice, amount);
        _settle();
        _claim(alice);
        shares = vault.balanceOf(alice);
    }

    // ------------------------------------------------------------------
    // F-USDC-2: bridgeToCore approves exactly `amount` to the CoreDepositWallet, which pulls exactly that.
    // ------------------------------------------------------------------
    function test_HLR2_FLOW_bridgeToCoreLeavesNoAllowanceAndCreditsOnlyTheVault() public {
        _seeded(1_000e6);
        vm.prank(stranger);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        vault.bridgeToCore(500e6);
        vm.prank(owner);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        vault.bridgeToCore(500e6);

        uint256 before = usdc.balanceOf(address(vault));
        vm.prank(manager);
        vault.bridgeToCore(600e6);
        assertEq(usdc.allowance(address(vault), address(depositWallet)), 0, "no leftover allowance");
        assertEq(before - usdc.balanceOf(address(vault)), 600e6);
        assertEq(depositWallet.lastSender(), address(vault), "deposit(), never depositFor(): credits msg.sender");
        assertEq(depositWallet.lastDex(), type(uint32).max, "spot dex");
        // Bound: never more than idle (pending deposits and claimable redemptions are not bridgeable).
        _deposit(bob, 300e6);
        _skipBridgeWindow();
        uint256 idle = vault.idleAssets();
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IHyperVaultErrors.InsufficientIdle.selector, idle, idle + 1));
        vault.bridgeToCore(idle + 1);
    }

    // ------------------------------------------------------------------
    // F-CORE-4: bridgeToEvm roles: manager / operator always, owner / guardian / sentinel only in emergency.
    // ------------------------------------------------------------------
    function test_HLR2_FLOW_bridgeToEvmRoles() public {
        _setCore(address(vault), 500e6, 0, 0);
        _setWithdrawable(address(vault), 500e6);
        address[3] memory denied = [stranger, owner, guardian];
        for (uint256 i; i < 3; ++i) {
            vm.prank(denied[i]);
            vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
            vault.bridgeToEvm(200e6);
        }
        vm.prank(guardian);
        vault.triggerEmergency();
        vm.prank(guardian);
        vault.bridgeToEvm(200e6);
        (,, bytes memory body) = _decode(writer.last());
        (address dest,,,,,) = abi.decode(body, (address, address, uint32, uint32, uint64, uint64));
        assertEq(dest, HyperCore.USDC_SYSTEM_ADDRESS);
        vm.prank(stranger);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        vault.bridgeToEvm(200e6);
    }

    // ------------------------------------------------------------------
    // F-CORE-3: moveUsd: manager / operator only, own spot <-> own perp.
    // ------------------------------------------------------------------
    function test_HLR2_FLOW_moveUsdTreasuryOnly() public {
        address[4] memory denied = [stranger, owner, guardian, alice];
        for (uint256 i; i < 4; ++i) {
            vm.prank(denied[i]);
            vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
            vault.moveUsd(1e6, true);
        }
        vm.prank(owner);
        vault.setOperator(keeper);
        vm.prank(keeper);
        vault.moveUsd(1e6, false);
        assertEq(writer.last(), abi.encodePacked(hex"01000007", bytes32(uint256(1e6)), bytes32(0)));
    }

    // ------------------------------------------------------------------
    // F-HYPE-1: fundCoreGas forwards all of msg.value to 0x2222..2222 (credited to msg.sender = the vault on Core).
    // ------------------------------------------------------------------
    function test_HLR2_FLOW_fundCoreGasForwardsAllValueAndKeepsNone() public {
        vm.deal(stranger, 1 ether);
        uint256 before = hypeSink.received();
        vm.prank(stranger);
        vault.fundCoreGas{value: 0.3 ether}();
        assertEq(hypeSink.received() - before, 0.3 ether);
        assertEq(hypeSink.lastSender(), address(vault));
        assertEq(address(vault).balance, 0);
        vm.expectRevert(IHyperVaultErrors.ZeroAmount.selector);
        vault.fundCoreGas{value: 0}();
        // No receive / fallback: plain HYPE cannot be locked in the vault.
        vm.prank(stranger);
        (bool ok,) = address(vault).call{value: 1}("");
        assertFalse(ok);
    }

    // ------------------------------------------------------------------
    // F-SHARE: the escrow (shares held by the vault for pending redemptions) is unreachable for anyone else.
    // ------------------------------------------------------------------
    function test_HLR2_FLOW_escrowedSharesAreUnreachable() public {
        uint256 shares = _seeded(1_000e6);
        _redeem(alice, shares / 2);
        assertEq(vault.balanceOf(address(vault)), shares / 2);
        // requestRedeem with owner_ = the vault needs the vault's allowance, which nothing ever grants
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, shares / 2)
        );
        vault.requestRedeem(shares / 2, stranger, address(vault));
        vm.prank(stranger);
        vm.expectRevert();
        vault.transferFrom(address(vault), stranger, 1);
        vm.prank(stranger);
        vm.expectRevert(IHyperVaultErrors.NothingToCancel.selector);
        vault.cancelRedeemRequest();
        // the redeemer gets exactly their shares back
        vm.prank(alice);
        vault.cancelRedeemRequest();
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.balanceOf(address(vault)), 0);
    }

    // ------------------------------------------------------------------
    // F-CALL: execute() only reaches the six onlySelf setters; nothing else can be queued; onlySelf is self only.
    // ------------------------------------------------------------------
    function test_HLR2_FLOW_queueAcceptsOnlyTheSixSetters() public {
        bytes[10] memory bad = [
            abi.encodeCall(IERC20.transfer, (stranger, 1)),
            abi.encodeCall(IERC20.approve, (stranger, type(uint256).max)),
            abi.encodeCall(HyperVault.rescueToken, (IERC20(address(usdc)), stranger)),
            abi.encodeCall(HyperVault.bridgeToEvm, (1)),
            abi.encodeCall(HyperVault.setOperator, (stranger)),
            abi.encodeCall(HyperVault.exitEmergency, ()),
            abi.encodeCall(HyperVault.revokeAgent, ()),
            abi.encodeWithSignature("transferOwnership(address)", stranger),
            abi.encodeWithSignature("upgradeToAndCall(address,bytes)", stranger, ""),
            abi.encodeCall(HyperVault.initialize, (_standaloneParams(policy)))
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(owner);
            vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
            vault.queue(bad[i]);
        }
        // the onlySelf setters refuse every direct caller, the owner included
        vm.startPrank(owner);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        vault.setManager(stranger);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        vault.setFeeRecipient(stranger);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        vault.setFees(0, 0);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        vault.setTimelockDelay(1 days);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        vault.setAgent(stranger);
        vm.stopPrank();
        // execute is permissionless but only runs an exact queued id
        vm.expectRevert(IHyperVaultErrors.NotQueued.selector);
        vault.execute(abi.encodeCall(HyperVault.setManager, (stranger)));
    }

    // ------------------------------------------------------------------
    // F-CALL: the linked libraries refuse a direct CALL (Solidity's library delegatecall guard), so their storage
    // pointer arguments can never be pointed at the libraries' own state or used to move funds out of context.
    // ------------------------------------------------------------------
    function test_HLR2_FLOW_libraryFunctionsRevertOnDirectCall() public {
        bytes memory code = address(vaultImpl).code;
        address logic = LinkedLibraries.linked(vm, "out/HyperVault.sol/HyperVault.json", "src/VaultLogic.sol", "VaultLogic", code);
        address gov =
            LinkedLibraries.linked(vm, "out/HyperVault.sol/HyperVault.json", "src/VaultGovernance.sol", "VaultGovernance", code);
        (bool ok,) = logic.call(abi.encodeWithSelector(VaultLogic.settle.selector, uint256(0), guardian, guardian));
        assertFalse(ok);
        (ok,) = logic.call(abi.encodeWithSelector(VaultLogic.fundCoreGas.selector, uint256(0), uint256(0)));
        assertFalse(ok);
        (ok,) = logic.call(abi.encodeWithSelector(VaultLogic.bridgeToEvm.selector, uint256(0), uint256(1), guardian, guardian));
        assertFalse(ok);
        (ok,) = gov.call(abi.encodeWithSelector(VaultGovernance.execute.selector, uint256(0), bytes("")));
        assertFalse(ok);
        (ok,) = gov.call(abi.encodeWithSelector(VaultGovernance.checkRisk.selector, uint256(0)));
        assertFalse(ok);
        // the implementation itself cannot be initialized (clones only)
        vm.expectRevert();
        vaultImpl.initialize(_standaloneParams(policy));
    }

    // ------------------------------------------------------------------
    // F-USDC-6: rescueToken: owner only, never the asset, never the vault's own shares.
    // ------------------------------------------------------------------
    function test_HLR2_FLOW_rescueTokenBound() public {
        _seeded(1_000e6);
        Junk j = new Junk();
        j.mint(address(vault), 5e18);
        vm.prank(manager);
        vm.expectRevert();
        vault.rescueToken(IERC20(address(j)), manager);
        vm.startPrank(owner);
        vm.expectRevert(IHyperVaultErrors.UnsupportedAsset.selector);
        vault.rescueToken(IERC20(address(usdc)), owner);
        vm.expectRevert(IHyperVaultErrors.UnsupportedAsset.selector);
        vault.rescueToken(IERC20(address(vault)), owner);
        vault.rescueToken(IERC20(address(j)), owner);
        vm.stopPrank();
        assertEq(j.balanceOf(owner), 5e18);
    }

    // ------------------------------------------------------------------
    // F-MINT: fee mints are bounded by the fee rates; nothing is minted to anyone but the fee recipient and the
    // factory's protocol recipient. One year at 2% management, flat NAV: about 2% of the supply's value.
    // ------------------------------------------------------------------
    function test_HLR2_FLOW_feeMintIsBoundedByTheRate() public {
        _seeded(1_000_000e6);
        uint256 supply0 = vault.totalSupply();
        vm.warp(vm.getBlockTimestamp() + 365 days);
        vault.accrueFees();
        uint256 minted = vault.totalSupply() - supply0;
        assertEq(vault.balanceOf(feeRecipient), minted, "standalone: everything to the fee recipient");
        uint256 value = vault.convertToAssets(minted);
        assertApproxEqAbs(value, 20_000e6, 2e6, "2% of 1M");
        assertLe(value, 20_000e6);
    }

    // ------------------------------------------------------------------
    // F-FACT: the factory pulls the seed only from msg.sender; a victim's standing allowance is never used.
    // ------------------------------------------------------------------
    function test_HLR2_FLOW_factorySeedComesOnlyFromTheLauncher() public {
        address victim = makeAddr("victim");
        usdc.mint(victim, 1_000e6);
        vm.prank(victim);
        usdc.approve(address(factory), type(uint256).max);
        address attacker = makeAddr("attacker");
        vm.deal(attacker, 1 ether);
        HyperVaultFactory.CreateParams memory p = _params(attacker, bytes32("x"));
        vm.prank(attacker);
        vm.expectRevert();
        factory.create{value: 0.01 ether}(p, _noPermit());
        assertEq(usdc.balanceOf(victim), 1_000e6);
        // with its own funds the launch works and the victim is untouched
        _fundLauncher(attacker, 1);
        HyperVault v = _launch(attacker, p);
        assertEq(usdc.balanceOf(victim), 1_000e6);
        assertEq(usdc.allowance(victim, address(factory)), type(uint256).max);
        assertEq(usdc.allowance(address(v), address(depositWallet)), 0, "seed bridge leaves no allowance");
        assertEq(depositWallet.lastSender(), address(v));
    }

    // ------------------------------------------------------------------
    // Findings
    // ------------------------------------------------------------------
    /// @notice HLR2-F02: bridgeToEvm sizes the sendAsset from spot `total`, which includes `hold` (spot orders). The
    ///         vault asks HyperCore to send more than is free; the action fails on Core, the window stays open until
    ///         MAX_UNLANDED_BLOCKS and settle is refused meanwhile.
    function test_HLR2_F02_bridgeToEvmCountsHeldSpotAndBlocksSettleForTheUnlandedWindow() public {
        _seeded(1_000e6);
        vault.checkRisk();
        // 200 USDC on spot, 150 of it held by a resting spot order (placed by the agent, not the contract)
        _resp(
            HyperCore.PRECOMPILE_SPOT_BALANCE,
            abi.encode(address(vault), uint64(0)),
            abi.encode(HyperCore.SpotBalance(200e6 * 100, 150e6 * 100, 0))
        );
        _setWithdrawable(address(vault), 0);
        vm.prank(manager);
        vault.bridgeToEvm(200e6); // accepted: only 50 is free on Core
        (,, bytes memory body) = _decode(writer.last());
        (,,,,, uint64 wei_) = abi.decode(body, (address, address, uint32, uint32, uint64, uint64));
        assertEq(wei_, 200e6 * 100, "asks for the held part too");
        uint256 start = vm.getBlockNumber();
        vm.roll(start + vault.MAX_UNLANDED_BLOCKS());
        assertTrue(vault.bridgePending());
        vm.prank(manager);
        vm.expectRevert(IHyperVaultErrors.BridgeInFlight.selector);
        vault.settle();
        vm.roll(start + vault.MAX_UNLANDED_BLOCKS() + 1);
        assertFalse(vault.bridgePending());
    }

    /// @notice HLR2-F03: shares transferred to the vault address join no request and no function returns them; they
    ///         stay in totalSupply for good (the sender's value is stranded, nobody else gains or loses).
    function test_HLR2_F03_sharesSentToTheVaultAreStranded() public {
        uint256 shares = _seeded(1_000e6);
        vm.prank(alice);
        vault.transfer(address(vault), shares / 10);
        _redeem(alice, vault.balanceOf(alice));
        vault.checkRisk();
        vm.prank(manager);
        vault.settle();
        _claim(alice);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(address(vault)), shares / 10, "stranded");
        assertEq(vault.totalSupply(), shares / 10);
        assertGt(vault.totalAssets(), 99e6, "about 100 USDC of NAV belongs to nobody");
        vm.prank(alice);
        vm.expectRevert(IHyperVaultErrors.NothingToCancel.selector);
        vault.cancelRedeemRequest();
    }

    /// @notice HLR2-F04: HyperVaultLens.previewRedeem prices an emergency (exit-only) redemption at the live NAV, but
    ///         settle pays min(NAV, checkpoint). With NAV 10% above the checkpoint the preview overstates the payout.
    function test_HLR2_F04_lensPreviewRedeemIgnoresTheExitOnlyCheckpointCap() public {
        uint256 shares = _seeded(1_000e6);
        // +100 USDC of PnL on Core after the last checkpoint
        _setCore(address(vault), 100e6, 0, 0);
        _redeem(alice, shares);
        vm.prank(guardian);
        vault.triggerEmergency();
        uint256 preview = lens.previewRedeem(vault, shares);
        (uint256 emPaid,) = lens.previewEmergencyRedeem(vault, shares);
        vm.prank(guardian);
        vault.settle();
        uint256 before = usdc.balanceOf(alice);
        _claim(alice);
        uint256 paid = usdc.balanceOf(alice) - before;
        assertApproxEqAbs(paid, 1_000e6, 1e6, "paid at the checkpoint");
        assertGt(preview, paid + 90e6, "previewRedeem overstates by ~100 USDC");
        assertApproxEqAbs(emPaid, paid, 1e6, "previewEmergencyRedeem is right");
    }

}

/// @notice Read-only fork of HyperEVM mainnet: Circle's live CoreDepositWallet pulls exactly `amount` (never more,
///         never less) from msg.sender and credits msg.sender's Core spot. Opt in with HLR2_FORK=true.
contract HlR2CdwForkTest is Test {
    IERC20 internal constant USDC = IERC20(0xb88339CB7199b77E23DB6E890353E22632Ba630f);
    address internal constant CDW = 0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24;
    address internal constant PLATFORM_VAULT = address(0x7A017); // any account: the CDW pulls from msg.sender

    event Transfer(address indexed from, address indexed to, uint256 value);

    function test_HLR2_FLOW_fork_realCoreDepositWalletPullsExactlyTheApprovedAmount() public {
        if (!vm.envOr("HLR2_FORK", false)) vm.skip(true);
        vm.createSelectFork("hyperevm");
        // Fund the platform vault address from the CDW's own USDC (a prank, nothing is broadcast).
        vm.prank(CDW);
        USDC.transfer(PLATFORM_VAULT, 1_000e6);
        uint256 cdwBefore = USDC.balanceOf(CDW);

        // Exactly the vault's sequence: approve(amount) then deposit(amount, spot).
        vm.startPrank(PLATFORM_VAULT);
        USDC.approve(CDW, 400e6);
        vm.expectEmit(true, true, false, true, CDW);
        emit Transfer(PLATFORM_VAULT, HyperCore.USDC_SYSTEM_ADDRESS, 400e6); // the log HyperCore credits from
        ICoreDepositWallet(CDW).deposit(400e6, type(uint32).max);
        assertEq(USDC.allowance(PLATFORM_VAULT, CDW), 0, "no leftover allowance");
        assertEq(USDC.balanceOf(PLATFORM_VAULT), 600e6);
        assertEq(USDC.balanceOf(CDW), cdwBefore + 400e6);

        // Over-approval is never pulled: the CDW takes exactly the amount argument.
        USDC.approve(CDW, 500e6);
        ICoreDepositWallet(CDW).deposit(300e6, type(uint32).max);
        assertEq(USDC.allowance(PLATFORM_VAULT, CDW), 200e6);
        vm.stopPrank();
    }
}
