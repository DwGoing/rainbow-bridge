// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

error ErrUnauthorized();
error ErrInvalidAddress(address addr);
error ErrInvalidAmount(uint256 amount);
error ErrInsufficientBalance(
    address token,
    uint256 requested,
    uint256 available
);
error ErrTransferFailed();
