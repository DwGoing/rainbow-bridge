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

// Fee and parameter errors
error ErrFeeTooHigh(uint256 fee);
error ErrPenaltyTooHigh(uint256 penalty);
error ErrInvalidValidatorCount(uint256 count);

// Stake errors
error ErrInsufficientStake(uint256 provided, uint256 required);
error ErrSlashExceedsStake(uint256 slashAmount, uint256 stake);

// Registration errors
error ErrAlreadyRegistered(address account);
error ErrNotValidator(address account);
error ErrNotSolver(address account);
error ErrAlreadyInactive(address account);

// Payment errors
error ErrInsufficientETH(uint256 provided, uint256 required);
error ErrUnexpectedETH();

// Order validation errors
error ErrInvalidDestinationChain(uint256 chainId);
error ErrExpiredDeadline(uint256 deadline);
error ErrInvalidDestinationToken();
error ErrOrderNotFound(bytes32 orderId);
error ErrInvalidOrderStatus(uint8 status);
error ErrWrongChain(uint256 expectedChain, uint256 actualChain);
error ErrInsufficientOutput(uint256 amount, uint256 minAmount);

// ZK and execution errors
error ErrVerifierNotSet();
error ErrNullifierUsed(bytes32 nullifier);
error ErrExecutionReplayed(bytes32 digest);
error ErrInvalidSolverSignature();
error ErrInvalidZKProof();

// Solver/Validator state errors
error ErrSolverInactive(address solver);
error ErrValidatorInactive(address validator);
error ErrAlreadyApproved(address validator, bytes32 orderId);

// Settlement errors
error ErrCannotSettle();
error ErrAlreadySettled(bytes32 orderId);
error ErrChallengeWindowOpen(uint256 readyAt);

// Refund errors
error ErrCannotRefund();
error ErrCannotRefundYet(uint256 deadline);

// Challenge errors
error ErrNoRejectVotes(bytes32 orderId);
error ErrValidatorDidNotVote(address validator, bytes32 orderId);
