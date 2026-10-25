// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {Base} from "../../Base.t.sol";
import {HyperVault} from "../../../src/HyperVault.sol";
import {HyperVaultFactory} from "../../../src/HyperVaultFactory.sol";
import {VaultPolicy} from "../../../src/VaultPolicy.sol";
import {ICoreDepositWallet} from "../../../src/hypercore/HyperCore.sol";

/// @notice hl-open review base: the round 4 factory as it is live on HyperEVM since 2026-10-13 (read 2026-10-19):
///         openLaunch = true, maxDepositCap = type(uint256).max, minSeedUsdc = 2 USDC, minHypeValue = 0.01 HYPE,
///         curated perps BTC (0), ETH (1), SOL (5), a registrar key that signs agent bindings.
abstract contract HloBase is Base {
    HyperVaultFactory internal factory;
    address internal treasury = makeAddr("treasury");
    address internal keeper = makeAddr("keeper"); // the platform operator / keeper
    uint256 internal registrarKey = 0xA11CE;
    address internal registrar;

    uint32 internal constant SOL = 5;

    function setUp() public virtual override {
        super.setUp();
        registrar = vm.addr(registrarKey);
        factory = new HyperVaultFactory(
            owner,
            address(vaultImpl),
            address(policyImpl),
            IERC20(address(usdc)),
            ICoreDepositWallet(address(depositWallet)),
            treasury,
            guardian,
            sentinel
        );
        vm.startPrank(owner);
        factory.setOpenLaunch(true);
        factory.setMaxDepositCap(type(uint256).max);
        factory.setAssetCurated(BTC, true);
        factory.setAssetCurated(ETH, true);
        factory.setAssetCurated(SOL, true);
        factory.setAgentRegistrar(registrar);
        vm.stopPrank();
        _setAsset(SOL, 2, 100_000); // SOL szDecimals 2, raw price has 4 decimals -> 100.0000
    }

    function _assets() internal pure returns (uint32[] memory a) {
        a = new uint32[](3);
        a[0] = BTC;
        a[1] = ETH;
        a[2] = SOL;
    }

    /// @dev What the webapp's wizard sends for a stranger: they own and manage, the keeper is the operator.
    function _params(address who, bytes32 salt) internal view returns (HyperVaultFactory.CreateParams memory p) {
        p = HyperVaultFactory.CreateParams({
            name: "Stranger Vault",
            symbol: "STR",
            owner: who,
            manager: who,
            feeRecipient: who,
            managementFeeBps: 200,
            performanceFeeBps: 2_000,
            timelockDelay: 2 days,
            depositCap: type(uint256).max,
            risk: _defaultRisk(),
            assets: _assets(),
            agent: address(0),
            agentSig: "",
            agentDeadline: 0,
            operator: keeper,
            hosted: false,
            seedUsdc: 2e6,
            salt: salt
        });
    }

    function _noPermit() internal pure returns (HyperVaultFactory.PermitData memory) {
        return HyperVaultFactory.PermitData(0, 0, 0, bytes32(0), bytes32(0));
    }

    function _agentSig(address agent_, address vault_, uint256 deadline) internal view returns (bytes memory) {
        bytes32 digest = factory.agentDigest(agent_, vault_, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(registrarKey, MessageHashUtils.toEthSignedMessageHash(digest));
        return abi.encodePacked(r, s, v);
    }

    function _fundLauncher(address who, uint256 launches) internal {
        usdc.mint(who, 2e6 * launches);
        vm.deal(who, 0.01 ether * launches);
        vm.prank(who);
        usdc.approve(address(factory), type(uint256).max);
    }

    function _launch(address who, HyperVaultFactory.CreateParams memory p) internal returns (HyperVault v) {
        vm.prank(who);
        (address va,) = factory.create{value: 0.01 ether}(p, _noPermit());
        v = HyperVault(va);
        _setCoreUser(va, true);
        _setCore(va, 0, 0, 0);
        _setWithdrawable(va, 0);
        _setPosition(va, BTC, 0);
        _setPosition(va, ETH, 0);
        _setPosition(va, SOL, 0);
    }
}
