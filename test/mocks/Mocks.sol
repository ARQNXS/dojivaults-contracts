// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice 6 decimal USDC with EIP-2612 permit, like Circle's USDC on HyperEVM (version "2").
contract MockUSDC is ERC20, ERC20Permit {
    constructor() ERC20("USD Coin", "USDC") ERC20Permit("USD Coin") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burnFrom(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @notice Generic precompile stand in. Etched at each precompile address; responds by input hash.
contract MockPrecompile {
    mapping(bytes32 => bytes) internal _resp;
    mapping(bytes32 => bool) internal _set;

    function setResponse(bytes calldata input, bytes calldata output) external {
        _resp[keccak256(input)] = output;
        _set[keccak256(input)] = true;
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        bytes32 k = keccak256(input);
        if (!_set[k]) revert("mock: no response");
        return _resp[k];
    }
}

/// @notice Records every CoreWriter action so tests can decode them.
contract MockCoreWriter {
    bytes[] public actions;

    event RawAction(address indexed user, bytes data);

    function sendRawAction(bytes calldata data) external {
        actions.push(data);
        emit RawAction(msg.sender, data);
    }

    function count() external view returns (uint256) {
        return actions.length;
    }

    function last() external view returns (bytes memory) {
        return actions[actions.length - 1];
    }

    function at(uint256 i) external view returns (bytes memory) {
        return actions[i];
    }
}

contract MockCoreDepositWallet {
    IERC20 public immutable usdc;
    uint256 public totalDeposited;
    uint32 public lastDex;
    address public lastSender;
    /// @dev Monotonic call counter so tests can order this call against other mocks.
    uint256 public calls;

    constructor(IERC20 usdc_) {
        usdc = usdc_;
    }

    function deposit(uint256 amount, uint32 destinationDex) external {
        usdc.transferFrom(msg.sender, address(this), amount);
        totalDeposited += amount;
        lastDex = destinationDex;
        lastSender = msg.sender;
        ++calls;
    }

    function depositFor(address, uint256 amount, uint32 destinationDex) external {
        usdc.transferFrom(msg.sender, address(this), amount);
        totalDeposited += amount;
        lastDex = destinationDex;
        lastSender = msg.sender;
        ++calls;
    }
}

/// @notice Stand in for the HYPE system address 0x2222...2222. Records who sent what and in which order
///         relative to the deposit wallet (via the shared sequence counter).
contract MockHypeSink {
    uint256 public received;
    address public lastSender;
    uint256 public calls;

    receive() external payable {
        received += msg.value;
        lastSender = msg.sender;
        ++calls;
    }
}
