// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IRelay {
    /* ==================== Events ==================== */

    event Withdrawn(
        address indexed token,
        uint256 amount,
        address indexed receipient
    );

    event SwapIntentExecuted(
        uint256 indexed srcChainId,
        uint256 indexed id,
        address token,
        uint256 amount,
        address indexed receipient,
        bytes32 proof
    );

    /* ==================== Owner Functions ==================== */

    function emergencyWithdraw(
        address token,
        uint256 amount,
        address receipient
    ) external;

    /* ==================== Admin Functions ==================== */

    function pause() external;

    function unpause() external;

    /* ==================== Public Functions ==================== */

    function executeSwapIntentByTransfer(
        uint256 srcChainId,
        uint256 id,
        address token,
        uint256 amount,
        address receipient,
        bytes32 solver
    ) external payable returns (bytes32 proof);

    function executeSwapIntentByCall(
        uint256 srcChainId,
        uint256 id,
        address token,
        uint256 amount,
        address receipient,
        bytes32 solver
    ) external returns (bytes32 proof);
}
