// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice CoreWriter system contract on HyperEVM.
interface ICoreWriter {
    function sendRawAction(bytes calldata data) external;
}

/// @notice System contract that bridges USDC from HyperEVM into HyperCore.
interface ICoreDepositWallet {
    function deposit(uint256 amount, uint32 destinationDex) external;
    function depositFor(address recipient, uint256 amount, uint32 destinationDex) external;
}

/// @title HyperCore
/// @notice Thin, dependency free access layer for HyperCore: read precompiles and CoreWriter actions.
/// @dev Encoding follows the Hyperliquid docs: [version=1][3 byte action id][abi.encode(fields)].
///      CoreWriter actions are fire and forget. A successful EVM call does NOT mean the action
///      succeeded on HyperCore, so callers must never assume state changed until a precompile read
///      in a later block confirms it. Order actions are additionally delayed a few seconds onchain.
library HyperCore {
    // ------------------------------------------------------------------
    // System addresses
    // ------------------------------------------------------------------
    address internal constant CORE_WRITER = 0x3333333333333333333333333333333333333333;

    address internal constant PRECOMPILE_SPOT_BALANCE = 0x0000000000000000000000000000000000000801;
    address internal constant PRECOMPILE_WITHDRAWABLE = 0x0000000000000000000000000000000000000803;
    address internal constant PRECOMPILE_MARK_PX = 0x0000000000000000000000000000000000000806;
    address internal constant PRECOMPILE_ORACLE_PX = 0x0000000000000000000000000000000000000807;
    address internal constant PRECOMPILE_L1_BLOCK = 0x0000000000000000000000000000000000000809;
    address internal constant PRECOMPILE_PERP_ASSET_INFO = 0x000000000000000000000000000000000000080a;
    address internal constant PRECOMPILE_ACCOUNT_MARGIN_SUMMARY = 0x000000000000000000000000000000000000080F;
    address internal constant PRECOMPILE_CORE_USER_EXISTS = 0x0000000000000000000000000000000000000810;
    address internal constant PRECOMPILE_POSITION = 0x0000000000000000000000000000000000000813;
    /// @dev L1Read.sol borrowLendUserState(address user, uint64 token) -> (BasisAndValue borrow, BasisAndValue supply).
    ///      Answers PrecompileError for an account without borrow / lend state for the token (mainnet, 2026-10-20).
    address internal constant PRECOMPILE_BORROW_LEND_USER_STATE = 0x0000000000000000000000000000000000000811;

    /// @dev USDC system address on HyperCore (0x20 prefix + token index 0). Sending spot USDC here bridges it to HyperEVM.
    address internal constant USDC_SYSTEM_ADDRESS = 0x2000000000000000000000000000000000000000;
    /// @dev Native HYPE sent to this address from HyperEVM lands in the sender's HyperCore spot balance.
    address internal constant HYPE_SYSTEM_ADDRESS = 0x2222222222222222222222222222222222222222;

    uint64 internal constant USDC_TOKEN = 0;
    uint32 internal constant SPOT_DEX = type(uint32).max;
    uint32 internal constant DEFAULT_PERP_DEX = 0;

    /// @dev Spot assets use asset id = 10000 + spotIndex. Everything below is a perp on the default dex.
    uint32 internal constant SPOT_ASSET_OFFSET = 10_000;

    // Action ids
    uint24 internal constant ACTION_LIMIT_ORDER = 1;
    uint24 internal constant ACTION_SPOT_SEND = 6;
    uint24 internal constant ACTION_USD_CLASS_TRANSFER = 7;
    uint24 internal constant ACTION_ADD_API_WALLET = 9;
    uint24 internal constant ACTION_CANCEL_BY_OID = 10;
    uint24 internal constant ACTION_CANCEL_BY_CLOID = 11;
    uint24 internal constant ACTION_SEND_ASSET = 13;
    /// @dev hl-r2 HL-PROXY: "Set abstraction | (user, abstraction) | (address, uint8) | abstraction 1 for disabled,
    ///      2 for unifiedAccount, 3 for portfolioMargin" (HL docs, Interacting with HyperCore, fetched 2026-10-20).
    uint24 internal constant ACTION_SET_ABSTRACTION = 16;
    /// @dev "disabled" = the Manual / Standard mode (separate perp and spot balances, separate dex balances): the mode
    ///      coreEquity() is written for. Never-set accounts read "default" in userAbstraction and behave the same on the
    ///      precompiles (measured, hl-r2 mainnet probes); action 16 has no "default" value, so the vault pins "disabled".
    uint8 internal constant ABSTRACTION_DISABLED = 1;

    // Time in force
    uint8 internal constant TIF_ALO = 1;
    uint8 internal constant TIF_GTC = 2;
    uint8 internal constant TIF_IOC = 3;

    // ------------------------------------------------------------------
    // Types (match the precompile ABI)
    // ------------------------------------------------------------------
    struct Position {
        int64 szi;
        uint64 entryNtl;
        int64 isolatedRawUsd;
        uint32 leverage;
        bool isIsolated;
    }

    struct SpotBalance {
        uint64 total;
        uint64 hold;
        uint64 entryNtl;
    }

    struct PerpAssetInfo {
        string coin;
        uint32 marginTableId;
        uint8 szDecimals;
        uint8 maxLeverage;
        bool onlyIsolated;
    }

    struct AccountMarginSummary {
        int64 accountValue; // perp USD, 6 decimals
        uint64 marginUsed;
        uint64 ntlPos; // total notional of open positions, 6 decimals
        int64 rawUsd;
    }

    error PrecompileFailed(address precompile);

    // ------------------------------------------------------------------
    // Reads
    // ------------------------------------------------------------------
    function _read(address precompile, bytes memory input) private view returns (bytes memory out) {
        bool ok;
        (ok, out) = precompile.staticcall(input);
        if (!ok) revert PrecompileFailed(precompile);
    }

    function coreUserExists(address user) internal view returns (bool) {
        return abi.decode(_read(PRECOMPILE_CORE_USER_EXISTS, abi.encode(user)), (bool));
    }

    function accountMarginSummary(address user) internal view returns (AccountMarginSummary memory) {
        return abi.decode(
            _read(PRECOMPILE_ACCOUNT_MARGIN_SUMMARY, abi.encode(DEFAULT_PERP_DEX, user)), (AccountMarginSummary)
        );
    }

    function spotBalance(address user, uint64 token) internal view returns (SpotBalance memory) {
        return abi.decode(_read(PRECOMPILE_SPOT_BALANCE, abi.encode(user, token)), (SpotBalance));
    }

    function withdrawable(address user) internal view returns (uint64) {
        return abi.decode(_read(PRECOMPILE_WITHDRAWABLE, abi.encode(user)), (uint64));
    }

    function position(address user, uint32 perp) internal view returns (Position memory) {
        return abi.decode(_read(PRECOMPILE_POSITION, abi.encode(user, perp)), (Position));
    }

    function markPx(uint32 perp) internal view returns (uint64) {
        return abi.decode(_read(PRECOMPILE_MARK_PX, abi.encode(perp)), (uint64));
    }

    function perpAssetInfo(uint32 perp) internal view returns (PerpAssetInfo memory) {
        return abi.decode(_read(PRECOMPILE_PERP_ASSET_INFO, abi.encode(perp)), (PerpAssetInfo));
    }

    /// @notice true when `user` has a non-zero borrow or supply of `token` on HyperCore's borrow / lend module. A
    ///         precompile error (no state) or an empty answer reads false. Gas capped: an error consumes only the cap.
    function borrowLendActive(address user, uint64 token) internal view returns (bool) {
        (bool ok, bytes memory out) = PRECOMPILE_BORROW_LEND_USER_STATE.staticcall{gas: 30_000}(abi.encode(user, token));
        if (!ok || out.length < 128) return false;
        (uint64 bBasis, uint64 bValue, uint64 sBasis, uint64 sValue) = abi.decode(out, (uint64, uint64, uint64, uint64));
        return bBasis != 0 || bValue != 0 || sBasis != 0 || sValue != 0;
    }

    function l1BlockNumber() internal view returns (uint64) {
        return abi.decode(_read(PRECOMPILE_L1_BLOCK, ""), (uint64));
    }

    /// @notice Mark price of a perp scaled to 1e8 (the scale CoreWriter limit orders use).
    /// @dev Raw precompile price has (6 - szDecimals) decimals.
    function markPx1e8(uint32 perp) internal view returns (uint256 px1e8, uint8 szDecimals) {
        szDecimals = perpAssetInfo(perp).szDecimals;
        px1e8 = uint256(markPx(perp)) * 10 ** (2 + szDecimals);
    }

    // ------------------------------------------------------------------
    // Writes
    // ------------------------------------------------------------------
    function _send(uint24 actionId, bytes memory payload) private {
        ICoreWriter(CORE_WRITER).sendRawAction(abi.encodePacked(uint8(1), actionId, payload));
    }

    /// @param limitPx price * 1e8
    /// @param sz size * 1e8
    function limitOrder(uint32 asset, bool isBuy, uint64 limitPx, uint64 sz, bool reduceOnly, uint8 tif, uint128 cloid)
        internal
    {
        _send(ACTION_LIMIT_ORDER, abi.encode(asset, isBuy, limitPx, sz, reduceOnly, tif, cloid));
    }

    function cancelByOid(uint32 asset, uint64 oid) internal {
        _send(ACTION_CANCEL_BY_OID, abi.encode(asset, oid));
    }

    function cancelByCloid(uint32 asset, uint128 cloid) internal {
        _send(ACTION_CANCEL_BY_CLOID, abi.encode(asset, cloid));
    }

    /// @param ntl perp USD amount, 6 decimals
    function usdClassTransfer(uint64 ntl, bool toPerp) internal {
        _send(ACTION_USD_CLASS_TRANSFER, abi.encode(ntl, toPerp));
    }

    function sendAsset(address destination, uint32 sourceDex, uint32 destinationDex, uint64 token, uint64 amountWei)
        internal
    {
        _send(ACTION_SEND_ASSET, abi.encode(destination, address(0), sourceDex, destinationDex, token, amountWei));
    }

    /// @notice Sets the account abstraction mode of `user` (this contract's own account; HL-PROXY account-mode pin).
    function setAbstraction(address user, uint8 abstraction) internal {
        _send(ACTION_SET_ABSTRACTION, abi.encode(user, abstraction));
    }

    /// @notice Approves an API wallet. HL-PROXY: the vault never approves its agent with it (an API wallet can sign far
    ///         more than orders: vaultTransfer, subaccounts, spot, sendAsset, abstraction); only the revoke's burn uses it.
    function addApiWallet(address wallet, string memory name) internal {
        _send(ACTION_ADD_API_WALLET, abi.encode(wallet, name));
    }
}
