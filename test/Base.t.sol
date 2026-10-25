// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {HyperVault} from "../src/HyperVault.sol";
import {HyperVaultLens} from "../src/HyperVaultLens.sol";
import {VaultPolicy} from "../src/VaultPolicy.sol";
import {InitParams} from "../src/VaultTypes.sol";
import {HyperCore, ICoreDepositWallet} from "../src/hypercore/HyperCore.sol";
import {MockUSDC, MockPrecompile, MockCoreWriter, MockCoreDepositWallet, MockHypeSink} from "./mocks/Mocks.sol";

/// @dev Every vault in the suite is an EIP-1167 clone of one implementation, initialized once, exactly as the
///      factory does it. The standalone vault here has factory = 0 (no protocol share).
abstract contract Base is Test {
    MockUSDC internal usdc;
    MockCoreWriter internal writer;
    MockCoreDepositWallet internal depositWallet;
    MockHypeSink internal hypeSink;
    HyperVault internal vaultImpl;
    VaultPolicy internal policyImpl;
    VaultPolicy internal policy;
    HyperVault internal vault;
    HyperVaultLens internal lens;

    address internal owner = makeAddr("owner");
    address internal manager = makeAddr("manager");
    address internal guardian = makeAddr("guardian");
    address internal sentinel = makeAddr("sentinel");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    uint32 internal constant BTC = 0;
    uint32 internal constant ETH = 1;
    uint32 internal constant DOGE = 7; // not allowlisted

    address[] internal precompiles;

    function setUp() public virtual {
        usdc = new MockUSDC();
        depositWallet = new MockCoreDepositWallet(IERC20(address(usdc)));

        // CoreWriter
        MockCoreWriter cw = new MockCoreWriter();
        vm.etch(HyperCore.CORE_WRITER, address(cw).code);
        writer = MockCoreWriter(HyperCore.CORE_WRITER);

        // HYPE system address: native value sent here lands on Core.
        MockHypeSink hs = new MockHypeSink();
        vm.etch(HyperCore.HYPE_SYSTEM_ADDRESS, address(hs).code);
        hypeSink = MockHypeSink(payable(HyperCore.HYPE_SYSTEM_ADDRESS));

        // Precompiles
        MockPrecompile mp = new MockPrecompile();
        precompiles.push(HyperCore.PRECOMPILE_SPOT_BALANCE);
        precompiles.push(HyperCore.PRECOMPILE_WITHDRAWABLE);
        precompiles.push(HyperCore.PRECOMPILE_MARK_PX);
        precompiles.push(HyperCore.PRECOMPILE_ORACLE_PX);
        precompiles.push(HyperCore.PRECOMPILE_L1_BLOCK);
        precompiles.push(HyperCore.PRECOMPILE_PERP_ASSET_INFO);
        precompiles.push(HyperCore.PRECOMPILE_ACCOUNT_MARGIN_SUMMARY);
        precompiles.push(HyperCore.PRECOMPILE_CORE_USER_EXISTS);
        precompiles.push(HyperCore.PRECOMPILE_POSITION);
        for (uint256 i; i < precompiles.length; ++i) {
            vm.etch(precompiles[i], address(mp).code);
        }

        vaultImpl = new HyperVault();
        policyImpl = new VaultPolicy();
        lens = new HyperVaultLens();

        uint32[] memory assets = new uint32[](2);
        assets[0] = BTC;
        assets[1] = ETH;
        policy = VaultPolicy(Clones.clone(address(policyImpl)));
        policy.initialize(owner, _defaultRisk(), assets, 2 days, address(0));

        vault = HyperVault(Clones.clone(address(vaultImpl)));
        vault.initialize(_standaloneParams(policy));

        // Default HyperCore state: account exists and is empty.
        _setCoreUser(address(vault), true);
        _setCore(address(vault), 0, 0, 0);
        _setWithdrawable(address(vault), 0);
        _setAsset(BTC, 5, 100_000e1); // BTC szDecimals 5, raw price has 1 decimal -> 100,000.0
        _setAsset(ETH, 4, 3_000e2); // ETH szDecimals 4, raw price has 2 decimals -> 3,000.00
        _setAsset(DOGE, 0, 200_000); // DOGE szDecimals 0, 6 decimals -> 0.200000
        _setPosition(address(vault), BTC, 0);
        _setPosition(address(vault), ETH, 0);

        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _standaloneParams(VaultPolicy p) internal view returns (InitParams memory) {
        return InitParams({
            asset: IERC20(address(usdc)),
            name: "DojiPad Vault",
            symbol: "dpV",
            owner: owner,
            manager: manager,
            guardian: guardian,
            feeRecipient: feeRecipient,
            managementFeeBps: 200,
            performanceFeeBps: 2_000,
            timelockDelay: 2 days,
            depositCap: 0,
            policy: p,
            coreDepositWallet: ICoreDepositWallet(address(depositWallet)),
            factory: address(0),
            protocolShareBps: 0,
            baseShareBps: 0,
            hosted: false,
            agent: address(0),
            operator: address(0),
            seedUsdc: 0
        });
    }

    function _defaultRisk() internal pure returns (VaultPolicy.RiskConfig memory) {
        return VaultPolicy.RiskConfig({
            maxLeverageBps: 30_000,
            maxDailyLossBps: 500,
            maxDrawdownBps: 1_500,
            maxSlippageBps: 100,
            maxOrderNotional: 1_000_000e6,
            maxEpochDuration: 7 days,
            maxNavMoveBps: 2_000,
            maxFlattenSlippageBps: 300
        });
    }

    // ------------------------------------------------------------------
    // HyperCore state helpers
    // ------------------------------------------------------------------
    function _resp(address precompile, bytes memory input, bytes memory output) internal {
        MockPrecompile(precompile).setResponse(input, output);
    }

    function _setCoreUser(address user, bool exists) internal {
        _resp(HyperCore.PRECOMPILE_CORE_USER_EXISTS, abi.encode(user), abi.encode(exists));
    }

    /// @param accountValue perp equity, 6 decimals
    /// @param ntlPos open notional, 6 decimals
    /// @param spotUsdc spot USDC, 6 decimals (stored as 8 decimal wei)
    function _setCore(address user, int64 accountValue, uint64 ntlPos, uint64 spotUsdc) internal {
        _resp(
            HyperCore.PRECOMPILE_ACCOUNT_MARGIN_SUMMARY,
            abi.encode(uint32(0), user),
            abi.encode(HyperCore.AccountMarginSummary(accountValue, 0, ntlPos, accountValue))
        );
        _resp(
            HyperCore.PRECOMPILE_SPOT_BALANCE,
            abi.encode(user, uint64(0)),
            abi.encode(HyperCore.SpotBalance(spotUsdc * 100, 0, 0))
        );
    }

    function _setWithdrawable(address user, uint64 amount) internal {
        _resp(HyperCore.PRECOMPILE_WITHDRAWABLE, abi.encode(user), abi.encode(amount));
    }

    function _setAsset(uint32 asset, uint8 szDecimals, uint64 rawMark) internal {
        _resp(
            HyperCore.PRECOMPILE_PERP_ASSET_INFO,
            abi.encode(asset),
            abi.encode(HyperCore.PerpAssetInfo("X", 0, szDecimals, 50, false))
        );
        _resp(HyperCore.PRECOMPILE_MARK_PX, abi.encode(asset), abi.encode(rawMark));
    }

    function _setPosition(address user, uint32 asset, int64 szi) internal {
        _resp(
            HyperCore.PRECOMPILE_POSITION, abi.encode(user, asset), abi.encode(HyperCore.Position(szi, 0, 0, 10, false))
        );
    }

    // ------------------------------------------------------------------
    // Flow helpers
    // ------------------------------------------------------------------
    function _deposit(address who, uint256 amount) internal {
        vm.prank(who);
        vault.requestDeposit(amount, who);
    }

    function _redeem(address who, uint256 shares) internal {
        vm.prank(who);
        vault.requestRedeem(shares, who, who);
    }

    /// @dev Settles the way the platform does: the keeper's checkRisk() refreshes the NAV checkpoint first.
    function _settle() internal {
        vault.checkRisk();
        vm.prank(manager);
        vault.settle();
    }

    /// @dev Timelocked owner action on `v`: queue, wait the delay, execute.
    function _timelocked(HyperVault v, bytes memory data) internal {
        vm.prank(v.owner());
        v.queue(data);
        vm.warp(v.queuedEta(keccak256(data))); // hl-r2 H01 fix: the eta is at least an epoch + 1 day out
        v.execute(data);
    }

    function _setAgent(HyperVault v, address a) internal {
        _timelocked(v, abi.encodeCall(HyperVault.setAgent, (a)));
    }

    function _claim(address who) internal {
        vault.claim(who);
    }

    /// @dev Decodes a CoreWriter payload into (version, actionId, body).
    function _decode(bytes memory raw) internal pure returns (uint8 version, uint24 actionId, bytes memory body) {
        version = uint8(raw[0]);
        actionId = (uint24(uint8(raw[1])) << 16) | (uint24(uint8(raw[2])) << 8) | uint24(uint8(raw[3]));
        body = new bytes(raw.length - 4);
        for (uint256 i; i < body.length; ++i) {
            body[i] = raw[i + 4];
        }
    }

    /// @dev Past any bridge window, landed or not (R-02: an unlanded bridge holds the window up to the cap; R3-08:
    ///      the risk check, settle and treasury actions wait for an unlanded transfer up to MAX_UNLANDED_BLOCKS).
    ///      The mocks land a bridge to Core in perp, never on spot, so the vault never sees it land: tests skip past.
    function _skipBridgeWindow() internal {
        vm.roll(vm.getBlockNumber() + vault.MAX_UNLANDED_BLOCKS() + 1);
    }
}
