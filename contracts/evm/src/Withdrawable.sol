// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Core} from "./Core.sol";
import "./Constant.sol";
import "./Error.sol";

/* =================== Events ==================== */

event Withdrawn(
    address indexed token,
    address indexed recipient,
    uint256 amount
);

abstract contract Withdrawable is Core, ReentrancyGuard{
    using SafeERC20 for IERC20;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Authorizes an upgrade to a new implementation
    /// @param newImplementation The address of the new implementation
    function _authorizeUpgrade(
        address newImplementation
    ) internal virtual override onlyOwner {}

    /// @notice Emergency withdraw function
    /// @param token The token address
    /// @param amount The amount to withdraw
    /// @param receipient The receipient address
    function emergencyWithdraw(
        address token,
        uint256 amount,
        address receipient
    ) public virtual onlyOwner nonReentrant {
        if (receipient == address(0)) revert ErrInvalidAddress(receipient);
        if (amount == 0) revert ErrInvalidAmount(amount);

        if (token == NATIVE_TOKEN_ADDRESS) {
            uint256 balance = address(this).balance;
            if (balance < amount)
                revert ErrInsufficientBalance({
                    token: token,
                    requested: amount,
                    available: balance
                });
            (bool success, ) = payable(receipient).call{value: amount}("");
            if (!success) revert ErrTransferFailed();
        } else {
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance < amount)
                revert ErrInsufficientBalance({
                    token: token,
                    requested: amount,
                    available: balance
                });
            bool success = IERC20(token).trySafeTransfer(receipient, amount);
            if (!success) revert ErrTransferFailed();
        }

        emit Withdrawn(token, receipient, amount);
    }
}
