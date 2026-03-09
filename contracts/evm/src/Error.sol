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
error ErrInvalidProvider();
error ErrInvalidDeadline(uint256 current, uint256 deadline);
error ErrInvalidChainId();
error ErrInvalidRecepient();
error ErrIntentExisted(bytes32 intentHash);
error ErrDismatchAmount(uint256 expected, uint256 actual);
error ErrSwapIntentNotFound(uint256 id);
error ErrInvalidIntentStatus();
error ErrSwapIntentExecuted(uint256 srcChainId, uint256 id);
error ErrSwapIntentVerified(uint256 id);
error ErrInvalidCaller(address caller);
error ErrIntentNotFound(bytes32 intentHash);
error ErrInvalidSolver();
error ErrNotIntentProvider();
error ErrValidatorNotActive(address validator);
error ErrChallengeWindowNotElapsed(uint256 current, uint256 required);
error ErrChallengeWindowElapsed(uint256 current, uint256 deadline);
