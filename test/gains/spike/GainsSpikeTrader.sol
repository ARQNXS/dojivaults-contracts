// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGainsDiamondSpike} from "./IGainsDiamondSpike.sol";

/// @notice Stage 0 spike only (test code, never deployed to mainnet by the build). A bare contract that is the
///         gTrade trader: it holds USDC, approves the diamond for exactly the collateral of each request, and owns
///         every position. Payouts (close, SL, TP, liq, timeout) land here because trade.user == address(this).
contract GainsSpikeTrader {
    IGainsDiamondSpike public immutable diamond;
    IERC20 public immutable usdc;
    address public immutable owner;

    error NotOwner();
    error TransferFailed();

    constructor(IGainsDiamondSpike _diamond, IERC20 _usdc, address _owner) {
        diamond = _diamond;
        usdc = _usdc;
        owner = _owner;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev Market (tradeType 0), limit (1) or stop (2). trade.user and trade.index are overwritten by the diamond.
    function openTrade(IGainsDiamondSpike.Trade calldata trade, uint16 maxSlippageP) external onlyOwner {
        usdc.approve(address(diamond), trade.collateralAmount);
        diamond.openTrade(trade, maxSlippageP, address(0));
    }

    function closeTradeMarket(uint32 index, uint64 expectedPrice) external onlyOwner {
        diamond.closeTradeMarket(index, expectedPrice);
    }

    function decreasePositionSize(uint32 index, uint120 collateralDelta, uint24 leverageDelta, uint64 expectedPrice)
        external
        onlyOwner
    {
        diamond.decreasePositionSize(index, collateralDelta, leverageDelta, expectedPrice);
    }

    function increasePositionSize(
        uint32 index,
        uint120 collateralDelta,
        uint24 leverageDelta,
        uint64 expectedPrice,
        uint16 maxSlippageP
    ) external onlyOwner {
        usdc.approve(address(diamond), collateralDelta);
        diamond.increasePositionSize(index, collateralDelta, leverageDelta, expectedPrice, maxSlippageP);
    }

    function updateSl(uint32 index, uint64 newSl) external onlyOwner {
        diamond.updateSl(index, newSl);
    }

    function updateTp(uint32 index, uint64 newTp) external onlyOwner {
        diamond.updateTp(index, newTp);
    }

    /// @dev Lowering leverage at constant position size adds collateral, so the diamond pulls `approveAmount`.
    function updateLeverage(uint32 index, uint24 newLeverage, uint256 approveAmount) external onlyOwner {
        usdc.approve(address(diamond), approveAmount);
        diamond.updateLeverage(index, newLeverage);
    }

    function cancelOpenOrder(uint32 index) external onlyOwner {
        diamond.cancelOpenOrder(index);
    }

    /// @dev Anyone may call, mirroring PLAN.md 4.2 `cancelTimedOut` (the diamond only accepts it from the trader).
    function cancelOrderAfterTimeout(uint32 orderIndex) external {
        diamond.cancelOrderAfterTimeout(orderIndex);
    }

    function sweep(IERC20 token, address to, uint256 amount) external onlyOwner {
        token.transfer(to, amount);
    }

    /// @notice Sends this contract's whole `token` balance to the owner. The contract has no receive or payable
    ///         function, so it can never hold ETH; ERC-20 balances are the only funds it can have.
    function withdraw(IERC20 token) external onlyOwner {
        uint256 amount = token.balanceOf(address(this));
        if (!token.transfer(owner, amount)) revert TransferFailed();
    }
}
