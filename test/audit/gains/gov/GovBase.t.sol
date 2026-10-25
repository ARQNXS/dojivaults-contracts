// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GainsBase} from "../../../gains/GainsBase.t.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {GainsVault} from "../../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../../src/gains/GainsVaultPolicy.sol";
import {GainsVaultFactory} from "../../../../src/gains/GainsVaultFactory.sol";

/// @notice Gains round 1 internal review, sub-reviewer 3.4 / 3.6 (access control, governance, diff vs round 4).
///         Base: GainsBase's standalone vault (`vault`, owner `owner`, guardian `guardian`) plus the platform factory
///         `platform` (owner `platformOwner`, guardian `platformGuardian`, sentinel `platformSentinel`) with a
///         registrar key, an allowlisted launcher key and one factory vault `fv` (operator `keeper`, agent `agentA`).
abstract contract GovBase is GainsBase {
    uint256 internal registrarKey = 0xBEEF01;
    address internal registrar;
    uint256 internal launcherKey = 0xBEEF02;
    address internal launcher;
    address internal keeper = makeAddr("keeper");
    address internal agentA = makeAddr("agentA");
    address internal fvOwner = makeAddr("fvOwner");
    address internal fvManager = makeAddr("fvManager");

    GainsVault internal fv;
    GainsVaultPolicy internal fp;

    uint256 internal constant GAS = 0.001 ether;

    function setUp() public virtual override {
        super.setUp();
        registrar = vm.addr(registrarKey);
        launcher = vm.addr(launcherKey);
        vm.startPrank(platformOwner);
        platform.setAgentRegistrar(registrar);
        platform.setLauncherAllowed(launcher, true);
        vm.stopPrank();
        usdc.mint(launcher, 1_000_000e6);
        vm.deal(launcher, 100 ether);
        vm.prank(launcher);
        usdc.approve(address(platform), type(uint256).max);

        GainsVaultFactory.CreateParams memory p = _cparams(launcher, bytes32(uint256(1)), agentA);
        vm.prank(launcher);
        (address va, address pa) = platform.create{value: GAS}(p, _noPermit());
        fv = GainsVault(va);
        fp = GainsVaultPolicy(pa);
        vm.prank(alice);
        usdc.approve(va, type(uint256).max);
        vm.prank(bob);
        usdc.approve(va, type(uint256).max);
    }

    function _predicted(address creator_, bytes32 salt) internal view returns (address) {
        return Clones.predictDeterministicAddress(address(vaultImpl), keccak256(abi.encode(creator_, salt)), address(platform));
    }

    function _digest(address factory_, uint256 chainId, address agent_, address vault_, uint256 deadline) internal pure returns (bytes32) {
        return keccak256(abi.encode("DojiPad platform agent", chainId, factory_, agent_, vault_, deadline));
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, MessageHashUtils.toEthSignedMessageHash(digest));
        return abi.encodePacked(r, s, v);
    }

    function _agentSig(uint256 key, address agent_, address vault_, uint256 deadline) internal view returns (bytes memory) {
        return _sign(key, _digest(address(platform), block.chainid, agent_, vault_, deadline));
    }

    function _cparams(address creator_, bytes32 salt, address agent_) internal view returns (GainsVaultFactory.CreateParams memory p) {
        uint32[] memory assets = new uint32[](2);
        assets[0] = BTC;
        assets[1] = ETH;
        p = GainsVaultFactory.CreateParams({
            name: "Gov Vault",
            symbol: "gov",
            owner: fvOwner,
            manager: fvManager,
            feeRecipient: feeRecipient,
            managementFeeBps: 0,
            performanceFeeBps: 0,
            timelockDelay: 2 days,
            depositCap: 50_000e6,
            risk: _defaultRisk(),
            assets: assets,
            agent: agent_,
            agentSig: "",
            agentDeadline: 0,
            operator: keeper,
            hosted: true,
            seedUsdc: 1e6,
            salt: salt
        });
        if (agent_ != address(0)) {
            p.agentDeadline = vm.getBlockTimestamp() + 1 hours;
            p.agentSig = _agentSig(registrarKey, agent_, _predicted(creator_, salt), p.agentDeadline);
        }
    }

    function _noPermit() internal pure returns (GainsVaultFactory.PermitData memory) {
        return GainsVaultFactory.PermitData(0, 0, 0, bytes32(0), bytes32(0));
    }

    /// @dev alice deposits into the factory vault and the keeper settles it (normal settle by the operator).
    function _fundFv(uint256 amount) internal {
        vm.prank(alice);
        fv.requestDeposit(amount, alice);
        _ageEpoch(fv); // GR1-02: a settle that prices deposits runs an hour into the epoch
        fv.checkRisk();
        vm.prank(keeper);
        fv.settle();
        fv.claim(alice);
    }

    function _openFv(uint16 pair, uint120 collateral, uint24 leverage) internal returns (uint32 idx) {
        _request(fv, pair, true, collateral, leverage);
        (idx,) = _fillLast(fv, _px(pair));
    }
}
