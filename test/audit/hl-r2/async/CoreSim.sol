// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HyperCore} from "../../../../src/hypercore/HyperCore.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @title CoreSim
/// @notice Explicit HyperCore simulator for the hl-r2 async review. Holds per account Core state (perp cash, positions
///         with marks and unrealised PnL, spot USDC, agent slot, account existence) and the in-flight transfers in
///         both directions. Reads are computed from that state; writes are queued and applied later.
/// @dev Timing model (HL docs, "Interacting with HyperCore"):
///      - Precompile reads are the Core state at the time the EVM block is constructed. In the sim a queued item
///        with `at = B` becomes visible in EVM block B + 1 at the earliest (process() applies `at < block.number`).
///      - CoreWriter actions sent in block B are queued with `at = B + delay[actionId]` (orders and vault transfers
///        a few seconds later on HL; others after the block). A failed or dropped Core action does not revert on
///        the EVM: the sim records it and moves on.
///      - EVM -> Core: the CoreDepositWallet stand-in takes the USDC at once and credits Core spot `depositDelay`
///        blocks later, or never (`depositLost`).
///      - Core -> EVM: a sendAsset to the USDC system address debits spot when it executes and delivers the USDC
///        on the EVM `evmDelay` blocks after that (a system tx), or never (`evmLost`).
///      - The agent (API wallet) acts on Core directly; its actions are applied from the next EVM block on.
///      process() must be called before the vault reads in a block (every handler and test helper does).
contract CoreSim {
    // ------------------------------------------------------------------
    // Units: perp USD and EVM USDC 6 decimals, spot USDC wei 8 decimals, sizes raw szDecimals, prices raw
    // (6 - szDecimals decimals), so notional (6 dec) = |szi| * markRaw.
    // ------------------------------------------------------------------
    struct Pos {
        int64 szi;
        uint64 entryRaw;
    }

    struct Account {
        bool exists;
        int256 cash; // perp margin balance excluding unrealised PnL (6 dec)
        uint256 spotWei; // spot USDC, 8 decimals
        mapping(uint32 => Pos) pos;
        mapping(bytes32 nameHash => address) agent;
    }

    struct Item {
        uint8 kind; // 1 CoreWriter action, 2 EVM->Core credit, 3 Core->EVM delivery, 4 agent action
        address user;
        uint256 at; // EVM block at/after which it executes (visible from at + 1)
        bool done;
        bool dropped;
        bytes data;
        uint256 amount;
    }

    address public immutable usdc;
    address public immutable depositWallet;
    bytes32 internal constant AGENT_NAME_HASH = keccak256("dojipad");

    mapping(address => Account) internal _acct;
    uint32[] public assets;
    mapping(uint32 => uint8) public szDecimals;
    mapping(uint32 => uint64) public markRaw;
    mapping(uint32 => bool) public listed;

    Item[] internal _items;
    uint256 public head; // first not-done item (items before it are all done)

    // Configuration (failure injection)
    mapping(uint24 => uint256) public actionDelay; // blocks after the EVM tx
    mapping(uint24 => uint256) public dropNextAction; // drop the next N actions of this id
    uint256 public depositDelay = 1;
    bool public depositLost;
    uint256 public evmDelay = 0;
    bool public evmLost;
    bool public outage; // every precompile read reverts
    uint256 public marginDivisor = 10; // initial margin = notional / marginDivisor

    // Ghosts (per account)
    mapping(address => int256) public ghostShockPnl; // injected PnL (explicit ghost, category a)
    mapping(address => int256) public ghostRealisedPnl; // realised on position reductions
    mapping(address => uint256) public ghostActivationFee;
    mapping(address => uint256) public ghostLostToCore; // EVM->Core deposits never credited
    mapping(address => uint256) public ghostLostToEvm; // Core->EVM transfers debited on Core, never delivered
    mapping(address => uint256) public inflightToCore; // taken on EVM, not yet credited on Core (not lost)
    mapping(address => uint256) public inflightToEvm; // debited on Core, not yet delivered on EVM (not lost)
    mapping(address => uint256) public deliveredToEvm;
    mapping(address => uint256) public creditedToCore;
    uint256 public droppedActions;
    uint256 public failedActions;
    uint256 public appliedActions;
    mapping(address => uint256) public agentActions; // agent actions applied, per account
    mapping(address => uint256) public agentActionsRejected; // refused because the agent slot no longer matches

    event Applied(uint8 kind, address user, bool ok, uint24 actionId);

    constructor(address usdc_, address depositWallet_) {
        usdc = usdc_;
        depositWallet = depositWallet_;
    }

    // ==================================================================
    // Configuration
    // ==================================================================
    function listAsset(uint32 a, uint8 szDec, uint64 raw) external {
        if (!listed[a]) {
            listed[a] = true;
            assets.push(a);
        }
        szDecimals[a] = szDec;
        markRaw[a] = raw;
    }

    function setMark(uint32 a, uint64 raw) external {
        markRaw[a] = raw;
    }

    function setActionDelay(uint24 id, uint256 d) external {
        actionDelay[id] = d;
    }

    function setDropNext(uint24 id, uint256 n) external {
        dropNextAction[id] = n;
    }

    function setDeposit(uint256 delay, bool lost) external {
        depositDelay = delay;
        depositLost = lost;
    }

    function setEvm(uint256 delay, bool lost) external {
        evmDelay = delay;
        evmLost = lost;
    }

    function setOutage(bool o) external {
        outage = o;
    }

    /// @dev Test setup: an account that already exists with the given balances (no USDC moved, the ghost records
    ///      it as the account's opening balance).
    function openAccount(address user, int256 cash_, uint256 spotUsd_) external {
        Account storage a = _acct[user];
        a.exists = true;
        a.cash += cash_;
        a.spotWei += spotUsd_ * 100;
    }

    // ==================================================================
    // Entry points used by the etched system contracts
    // ==================================================================
    /// @dev CoreWriter forwarder: msg.sender is the forwarder, `user` the EVM caller of sendRawAction.
    function enqueueAction(address user, bytes calldata data) external {
        uint24 id = _actionId(data);
        bool drop;
        if (dropNextAction[id] > 0) {
            dropNextAction[id] -= 1;
            drop = true;
        }
        _items.push(Item({kind: 1, user: user, at: block.number + actionDelay[id], done: false, dropped: drop, data: data, amount: 0}));
    }

    /// @dev CoreDepositWallet stand-in: USDC already taken on the EVM.
    function enqueueDeposit(address user, uint256 amount, uint32 dex) external {
        require(msg.sender == depositWallet, "sim: only wallet");
        if (depositLost) {
            ghostLostToCore[user] += amount;
            return;
        }
        inflightToCore[user] += amount;
        _items.push(Item({kind: 2, user: user, at: block.number + depositDelay, done: false, dropped: false, data: abi.encode(dex), amount: amount}));
    }

    // ==================================================================
    // Agent (API wallet) actions: signed off chain, applied on Core from the next block. Only accepted when the
    // account's "dojipad" slot holds this agent on Core (what HyperCore checks), whatever the EVM side believes.
    // kind 1: spot -> perp (agentSendAsset / class transfer), 2: perp -> spot, 3: open / change a position at mark
    // (szi delta, raw units), 4: close a position at mark.
    // ==================================================================
    function agentAct(address user, address agent, uint8 kind, uint32 asset, int256 amount) external {
        _items.push(Item({kind: 4, user: user, at: block.number, done: false, dropped: false, data: abi.encode(agent, kind, asset), amount: uint256(amount)}));
    }

    // ==================================================================
    // Ghost PnL (explicit): realised PnL booked directly on the perp cash of `user`.
    // ==================================================================
    function shock(address user, int256 delta) external {
        _acct[user].cash += delta;
        ghostShockPnl[user] += delta;
    }

    // ==================================================================
    // Processing
    // ==================================================================
    function process() public {
        uint256 n = _items.length;
        uint256 i = head;
        bool allDone = true;
        for (; i < n; ++i) {
            Item storage it = _items[i];
            if (it.done) continue;
            if (it.at >= block.number) {
                allDone = false;
                continue;
            }
            it.done = true;
            if (allDone) head = i + 1;
            if (it.kind == 1) _applyAction(it);
            else if (it.kind == 2) _applyCredit(it);
            else if (it.kind == 3) _applyDelivery(it);
            else if (it.kind == 4) _applyAgent(it);
            n = _items.length; // deliveries may have been appended
        }
    }

    function pendingItems() external view returns (uint256 c) {
        for (uint256 i = head; i < _items.length; ++i) {
            if (!_items[i].done) ++c;
        }
    }

    function _applyCredit(Item storage it) internal {
        Account storage a = _acct[it.user];
        uint256 amount = it.amount;
        inflightToCore[it.user] -= amount;
        creditedToCore[it.user] += amount;
        if (!a.exists) {
            a.exists = true;
            uint256 fee = amount < 1e6 ? amount : 1e6; // Core keeps 1 USDC as the activation fee
            ghostActivationFee[it.user] += fee;
            amount -= fee;
        }
        uint32 dex = abi.decode(it.data, (uint32));
        if (dex == HyperCore.SPOT_DEX) a.spotWei += amount * 100;
        else a.cash += int256(amount);
        emit Applied(2, it.user, true, 0);
    }

    function _applyDelivery(Item storage it) internal {
        inflightToEvm[it.user] -= it.amount;
        deliveredToEvm[it.user] += it.amount;
        IMintable(usdc).mint(it.user, it.amount);
        emit Applied(3, it.user, true, 0);
    }

    function _applyAction(Item storage it) internal {
        uint24 id = _actionId(it.data);
        Account storage a = _acct[it.user];
        if (it.dropped || !a.exists) {
            // A-13: actions of an account that does not exist on Core yet are dropped.
            ++droppedActions;
            emit Applied(1, it.user, false, id);
            return;
        }
        bytes memory body = _body(it.data);
        bool ok = true;
        if (id == HyperCore.ACTION_LIMIT_ORDER) {
            (uint32 asset, bool isBuy, uint64 limitPx, uint64 sz, bool reduceOnly,,) =
                abi.decode(body, (uint32, bool, uint64, uint64, bool, uint8, uint128));
            ok = _order(it.user, asset, isBuy, limitPx, sz, reduceOnly);
        } else if (id == HyperCore.ACTION_USD_CLASS_TRANSFER) {
            (uint64 ntl, bool toPerp) = abi.decode(body, (uint64, bool));
            ok = toPerp ? _spotToPerp(a, ntl) : _perpToSpot(it.user, a, ntl);
        } else if (id == HyperCore.ACTION_SEND_ASSET) {
            (address dest,, uint32 srcDex,, uint64 token, uint64 wei_) =
                abi.decode(body, (address, address, uint32, uint32, uint64, uint64));
            if (token != 0 || srcDex != HyperCore.SPOT_DEX || a.spotWei < wei_) {
                ok = false;
            } else {
                a.spotWei -= wei_;
                if (dest == HyperCore.USDC_SYSTEM_ADDRESS) {
                    uint256 amt = uint256(wei_) / 100;
                    if (evmLost) {
                        ghostLostToEvm[it.user] += amt;
                    } else {
                        inflightToEvm[it.user] += amt;
                        // Delivered by a system tx evmDelay blocks after the Core block that executed the send.
                        _items.push(Item({kind: 3, user: it.user, at: it.at + evmDelay, done: false, dropped: false, data: "", amount: amt}));
                    }
                } else {
                    _acct[dest].exists = true;
                    _acct[dest].spotWei += wei_;
                }
            }
        } else if (id == HyperCore.ACTION_ADD_API_WALLET) {
            (address wallet,) = abi.decode(body, (address, string));
            a.agent[AGENT_NAME_HASH] = wallet;
        } else if (id == HyperCore.ACTION_CANCEL_BY_OID || id == HyperCore.ACTION_CANCEL_BY_CLOID) {
            // no resting orders in the sim
        } else {
            ok = false;
        }
        if (ok) ++appliedActions;
        else ++failedActions;
        emit Applied(1, it.user, ok, id);
    }

    function _applyAgent(Item storage it) internal {
        (address agent, uint8 kind, uint32 asset) = abi.decode(it.data, (address, uint8, uint32));
        Account storage a = _acct[it.user];
        if (agent == address(0) || a.agent[AGENT_NAME_HASH] != agent) {
            ++agentActionsRejected[it.user];
            return;
        }
        ++agentActions[it.user];
        int256 amount = int256(it.amount);
        if (kind == 1) _spotToPerp(a, uint64(uint256(amount)));
        else if (kind == 2) _perpToSpot(it.user, a, uint64(uint256(amount)));
        else if (kind == 3) _fill(it.user, asset, int64(amount));
        else if (kind == 4) {
            int64 s = a.pos[asset].szi;
            if (s != 0) _fill(it.user, asset, -s);
        }
    }

    function _spotToPerp(Account storage a, uint64 ntl) internal returns (bool) {
        if (a.spotWei < uint256(ntl) * 100) return false;
        a.spotWei -= uint256(ntl) * 100;
        a.cash += int256(uint256(ntl));
        return true;
    }

    function _perpToSpot(address user, Account storage a, uint64 ntl) internal returns (bool) {
        if (_withdrawable(user) < ntl) return false;
        a.cash -= int256(uint256(ntl));
        a.spotWei += uint256(ntl) * 100;
        return true;
    }

    /// @dev Orders fill in full at mark when marketable (limit at or through mark), otherwise they are dropped
    ///      (IOC semantics; GTC is treated the same, the sim keeps no book). Reduce only orders are clipped.
    function _order(address user, uint32 asset, bool isBuy, uint64 limitPx1e8, uint64 sz1e8, bool reduceOnly)
        internal
        returns (bool)
    {
        if (!listed[asset]) return false;
        uint8 d = szDecimals[asset];
        uint256 mark1e8 = uint256(markRaw[asset]) * 10 ** (2 + d);
        if (isBuy ? mark1e8 > limitPx1e8 : mark1e8 < limitPx1e8) return false;
        int256 size = int256(uint256(sz1e8) / 10 ** (8 - d));
        int256 delta = isBuy ? size : -size;
        int64 cur = _acct[user].pos[asset].szi;
        if (reduceOnly) {
            if (cur == 0 || (cur > 0) == (delta > 0)) return false;
            int256 absCur = cur > 0 ? int256(cur) : -int256(cur);
            int256 absD = delta > 0 ? delta : -delta;
            if (absD > absCur) delta = -int256(cur);
        }
        _fill(user, asset, int64(delta));
        return true;
    }

    function _fill(address user, uint32 asset, int64 delta) internal {
        if (delta == 0) return;
        Pos storage p = _acct[user].pos[asset];
        uint64 m = markRaw[asset];
        int256 cur = p.szi;
        int256 nxt = cur + delta;
        if (cur != 0 && (cur > 0) != (delta > 0)) {
            // reduction (possibly flip): realise PnL on the closed part
            int256 closed = (nxt == 0 || (nxt > 0) != (cur > 0)) ? cur : -int256(delta);
            int256 pnl = closed * (int256(uint256(m)) - int256(uint256(p.entryRaw)));
            _acct[user].cash += pnl;
            ghostRealisedPnl[user] += pnl;
            if (nxt != 0 && (nxt > 0) != (cur > 0)) p.entryRaw = m;
        } else {
            // increase: weighted entry
            int256 absCur = cur > 0 ? cur : -cur;
            int256 absD = delta > 0 ? int256(delta) : -int256(delta);
            p.entryRaw = uint64(uint256((absCur * int256(uint256(p.entryRaw)) + absD * int256(uint256(m))) / (absCur + absD)));
        }
        p.szi = int64(nxt);
        if (nxt == 0) p.entryRaw = 0;
    }

    // ==================================================================
    // Views
    // ==================================================================
    function unrealised(address user) public view returns (int256 u) {
        for (uint256 i; i < assets.length; ++i) {
            Pos storage p = _acct[user].pos[assets[i]];
            if (p.szi != 0) u += int256(p.szi) * (int256(uint256(markRaw[assets[i]])) - int256(uint256(p.entryRaw)));
        }
    }

    /// @dev Mainnet rawUsd (checked on an HLP child account, 2026-10-21: accountValue - rawUsd = signed mark
    ///      notional to the cent): cash minus the signed entry notional, so it moves by the notional on every fill.
    function rawUsd(address user) public view returns (int256 r) {
        r = _acct[user].cash;
        for (uint256 i; i < assets.length; ++i) {
            Pos storage p = _acct[user].pos[assets[i]];
            if (p.szi != 0) r -= int256(p.szi) * int256(uint256(p.entryRaw));
        }
    }

    function notional(address user) public view returns (uint256 n) {
        for (uint256 i; i < assets.length; ++i) {
            int64 s = _acct[user].pos[assets[i]].szi;
            if (s != 0) n += uint256(s > 0 ? int256(s) : -int256(s)) * markRaw[assets[i]];
        }
    }

    function accountValue(address user) public view returns (int256) {
        return _acct[user].cash + unrealised(user);
    }

    function _withdrawable(address user) internal view returns (uint256) {
        int256 free = accountValue(user) - int256(notional(user) / marginDivisor);
        if (free <= 0) return 0;
        int256 c = _acct[user].cash;
        // unrealised gains are not withdrawable beyond the cash
        if (free > c) free = c;
        return free > 0 ? uint256(free) : 0;
    }

    function spotUsd(address user) external view returns (uint256) {
        return _acct[user].spotWei / 100;
    }

    function spotWei(address user) external view returns (uint256) {
        return _acct[user].spotWei;
    }

    function cash(address user) external view returns (int256) {
        return _acct[user].cash;
    }

    function exists(address user) external view returns (bool) {
        return _acct[user].exists;
    }

    function agentOf(address user) external view returns (address) {
        return _acct[user].agent[AGENT_NAME_HASH];
    }

    function position(address user, uint32 asset) external view returns (int64 szi, uint64 entryRaw) {
        Pos storage p = _acct[user].pos[asset];
        return (p.szi, p.entryRaw);
    }

    /// @dev Everything on Core and in flight that belongs to `user` (6 dec): spot + perp account value (with
    ///      unrealised PnL) + EVM->Core in flight + Core->EVM in flight. Lost transfers are excluded.
    function trueCoreValue(address user) public view returns (int256) {
        return accountValue(user) + int256(_acct[user].spotWei / 100) + int256(inflightToCore[user]) + int256(inflightToEvm[user]);
    }

    /// @dev Total PnL of `user` from trading (explicit shocks + realised + unrealised).
    function ghostPnl(address user) public view returns (int256) {
        return ghostShockPnl[user] + ghostRealisedPnl[user] + unrealised(user);
    }

    /// @dev Answers a precompile read. Called (static) by the forwarder etched at each precompile address.
    function read(address precompile, bytes calldata input) external view returns (bytes memory) {
        require(!outage, "sim: outage");
        if (precompile == HyperCore.PRECOMPILE_SPOT_BALANCE) {
            (address user, uint64 token) = abi.decode(input, (address, uint64));
            uint256 w = token == 0 ? _acct[user].spotWei : 0;
            return abi.encode(HyperCore.SpotBalance(uint64(w), 0, 0));
        }
        if (precompile == HyperCore.PRECOMPILE_WITHDRAWABLE) {
            address user = abi.decode(input, (address));
            return abi.encode(uint64(_withdrawable(user)));
        }
        if (precompile == HyperCore.PRECOMPILE_MARK_PX || precompile == HyperCore.PRECOMPILE_ORACLE_PX) {
            uint32 a = abi.decode(input, (uint32));
            require(listed[a], "sim: unknown asset");
            return abi.encode(markRaw[a]);
        }
        if (precompile == HyperCore.PRECOMPILE_L1_BLOCK) return abi.encode(uint64(block.number));
        if (precompile == HyperCore.PRECOMPILE_PERP_ASSET_INFO) {
            uint32 a = abi.decode(input, (uint32));
            require(listed[a], "sim: unknown asset");
            return abi.encode(HyperCore.PerpAssetInfo("X", 0, szDecimals[a], 50, false));
        }
        if (precompile == HyperCore.PRECOMPILE_ACCOUNT_MARGIN_SUMMARY) {
            (uint32 dex, address user) = abi.decode(input, (uint32, address));
            if (dex != 0) return abi.encode(HyperCore.AccountMarginSummary(0, 0, 0, 0));
            int256 av = accountValue(user);
            uint256 ntl = notional(user);
            return abi.encode(
                HyperCore.AccountMarginSummary(int64(av), uint64(ntl / marginDivisor), uint64(ntl), int64(rawUsd(user)))
            );
        }
        if (precompile == HyperCore.PRECOMPILE_CORE_USER_EXISTS) {
            address user = abi.decode(input, (address));
            return abi.encode(_acct[user].exists);
        }
        if (precompile == HyperCore.PRECOMPILE_POSITION) {
            (address user, uint32 a) = abi.decode(input, (address, uint32));
            Pos storage p = _acct[user].pos[a];
            uint256 absS = uint256(p.szi > 0 ? int256(p.szi) : -int256(p.szi));
            return abi.encode(HyperCore.Position(p.szi, uint64(absS * p.entryRaw), 0, 10, false));
        }
        revert("sim: unknown precompile");
    }

    // ------------------------------------------------------------------
    function _actionId(bytes memory data) internal pure returns (uint24) {
        return (uint24(uint8(data[1])) << 16) | (uint24(uint8(data[2])) << 8) | uint24(uint8(data[3]));
    }

    function _body(bytes memory raw) internal pure returns (bytes memory body) {
        body = new bytes(raw.length - 4);
        for (uint256 i; i < body.length; ++i) {
            body[i] = raw[i + 4];
        }
    }
}

/// @notice Etched at each precompile address: forwards the input to CoreSim.read by staticcall (read only).
contract PrecompileForwarder {
    CoreSim public immutable sim;

    constructor(CoreSim s) {
        sim = s;
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        (bool ok, bytes memory ret) = address(sim).staticcall(abi.encodeCall(CoreSim.read, (address(this), input)));
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return abi.decode(ret, (bytes));
    }
}

/// @notice Etched at 0x3333...3333: queues every raw action in CoreSim (fire and forget, never reverts on Core
///         outcome).
contract CoreWriterForwarder {
    CoreSim public immutable sim;

    event RawAction(address indexed user, bytes data);

    constructor(CoreSim s) {
        sim = s;
    }

    function sendRawAction(bytes calldata data) external {
        sim.enqueueAction(msg.sender, data);
        emit RawAction(msg.sender, data);
    }
}

/// @notice CoreDepositWallet stand-in: takes the USDC on the EVM at once, CoreSim credits Core spot later (or never).
contract SimDepositWallet {
    IERC20 public immutable usdc;
    CoreSim public sim;

    constructor(IERC20 usdc_) {
        usdc = usdc_;
    }

    function setSim(CoreSim s) external {
        require(address(sim) == address(0), "set");
        sim = s;
    }

    function deposit(uint256 amount, uint32 destinationDex) external {
        usdc.transferFrom(msg.sender, address(this), amount);
        sim.enqueueDeposit(msg.sender, amount, destinationDex);
    }

    function depositFor(address recipient, uint256 amount, uint32 destinationDex) external {
        usdc.transferFrom(msg.sender, address(this), amount);
        sim.enqueueDeposit(recipient, amount, destinationDex);
    }
}

/// @notice HYPE system address stand-in.
contract SimHypeSink {
    receive() external payable {}
}

/// @notice Storage based variants of the forwarders (no immutables): the CoreSim address sits in slot 0 of the etched
///         address (written with vm.store). Used by the Medusa harness, whose etch of immutable-carrying code failed.
contract PrecompileForwarderS {
    address internal sim;

    fallback(bytes calldata input) external returns (bytes memory) {
        (bool ok, bytes memory ret) = sim.staticcall(abi.encodeCall(CoreSim.read, (address(this), input)));
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return abi.decode(ret, (bytes));
    }
}

contract CoreWriterForwarderS {
    address internal sim;

    function sendRawAction(bytes calldata data) external {
        CoreSim(sim).enqueueAction(msg.sender, data);
    }
}

// Distinct names for Medusa's predeployedContracts (one address per contract name).
contract Fwd801 is PrecompileForwarderS {}
contract Fwd803 is PrecompileForwarderS {}
contract Fwd806 is PrecompileForwarderS {}
contract Fwd807 is PrecompileForwarderS {}
contract Fwd809 is PrecompileForwarderS {}
contract Fwd80a is PrecompileForwarderS {}
contract Fwd80F is PrecompileForwarderS {}
contract Fwd810 is PrecompileForwarderS {}
contract Fwd813 is PrecompileForwarderS {}
contract FwdCoreWriter is CoreWriterForwarderS {}
