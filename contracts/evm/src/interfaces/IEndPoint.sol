// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../Enum.sol";

interface IEndPoint {
    /* ==================== Structs ==================== */

    struct SwapIntent {
        address provider;
        address srcToken;
        uint256 srcAmount;
        uint256 dstChainId;
        bytes dstToken;
        uint256 minDstAmount;
        bytes recipient;
        uint256 deadline;
        uint256 nonce;
        bytes permitData; // Optional ERC20Permit signature: abi.encode(value, deadline, v, r, s)
    }

    struct IntentRecord {
        IntentStatus status;
        address solver;
    }

    struct ValidatorInfo {
        uint256 stake;
        bool active;
    }

    struct PendingSettlement {
        address validator;
        address solver;
        uint256 amountOut;
        uint256 timestamp;
    }

    /* ==================== Events ==================== */

    event Withdrawn(
        address indexed token,
        uint256 amount,
        address indexed receipient
    );

    event IntentSubmitted(bytes32 indexed intentHash, address indexed caller);
    event IntentExecuted(bytes32 indexed intentHash, address indexed solver);

    event SettlementProposed(
        bytes32 indexed intentHash,
        address indexed validator,
        address solver,
        uint256 amountOut
    );

    event SettlementFinalized(bytes32 indexed intentHash, address solver);
    event SettlementChallenged(bytes32 indexed intentHash, address challenger);

    event IntentRefunded(bytes32 indexed intentHash);

    event ValidatorRegistered(address indexed validator, uint256 stake);
    event ValidatorSlashed(address indexed validator, uint256 amount);

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

    function submitIntent(
        SwapIntent calldata intent
    ) external payable returns (bytes32 intentHash);

    function executeIntent(bytes32 intentHash, address solver) external;

    function registerValidator() external payable;

    function proposeSettlement(bytes32 intentHash, uint256 amountOut) external;

    function finalizeSettlement(bytes32 intentHash) external;

    function challengeSettlement(bytes32 intentHash) external;

    function refundIntent(bytes32 intentHash) external;
}
