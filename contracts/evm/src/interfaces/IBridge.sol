// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IBridge {
    /* ==================== Enums ==================== */

    enum OrderStatus {
        None, // Default state before submission
        Submitted, // User has submitted the order on the source chain
        Executed, // Solver has executed the transfer on the destination chain
        Completed, // Order has been validated and settled
        Settled, // Order has been settled (funds distributed)
        Refunded // Order has been refunded to the user
    }

    /* ==================== Structs ==================== */

    struct Order {
        // Phase 1: User submission (source chain)
        address user;
        uint256 srcChainId;
        address srcToken;
        uint256 srcAmount;
        uint256 srcAmountWithFee;
        // Cross-chain target
        uint256 dstChainId;
        bytes dstToken;
        uint256 minDstAmount;
        // Recipient and timing
        address recipient;
        uint256 deadline;
        uint256 nonce;
        // Phase 2: Solver execution (destination chain)
        address solver;
        uint256 executionTime;
        address dstTokenAddress;
        uint256 dstAmount;
        bytes32 executionProof;
        // Phase 3: Validation and settlement
        OrderStatus status;
        uint256 validationTime;
        uint256 approvalCount;
        bool settled;
    }

    struct ValidatorInfo {
        uint256 stake;
        bool active;
        uint256 joinTime;
        uint256 slashCount;
    }

    struct SolverInfo {
        uint256 stake;
        bool active;
        uint256 joinTime;
        address rewardRecipient;
    }

    /* ==================== Events ==================== */

    event OrderCreated(
        bytes32 indexed orderId,
        address indexed user,
        uint256 srcChainId,
        address srcToken,
        uint256 srcAmount,
        uint256 dstChainId,
        bytes dstToken,
        uint256 minDstAmount,
        address indexed recipient,
        uint256 deadline
    );
    event OrderExecuted(
        bytes32 indexed orderId,
        address indexed solver,
        uint256 dstChainId,
        address dstToken,
        uint256 dstAmount,
        address indexed dstRecipient,
        bytes32 proof
    );
    event OrderSettlement(
        bytes32 indexed orderId,
        address indexed validator,
        uint256 signerCount,
        bool approved
    );
    event OrderSettled(
        bytes32 indexed orderId,
        uint256 userRefund,
        uint256 solverReward
    );
    event OrderRefunded(
        bytes32 indexed orderId,
        address indexed user,
        uint256 amount
    );
    event SolverStaked(address indexed solver, uint256 amount);
    event SolverUnstaked(address indexed solver, uint256 amount);
    event ValidatorRegistered(address indexed validator, uint256 stake);
    event ValidatorUnregistered(address indexed validator, uint256 stake);
    event ValidatorSlashed(address indexed validator, uint256 amount);
    event Withdrawn(
        address indexed token,
        address indexed recipient,
        uint256 amount
    );

    /* ==================== User Functions ==================== */

    function submitOrder(
        address srcToken,
        uint256 srcAmount,
        uint256 dstChainId,
        bytes calldata dstToken,
        uint256 minDstAmount,
        address recipient,
        uint256 deadline
    ) external payable returns (bytes32 orderId);

    function refundOrder(bytes32 orderId) external;

    /* ==================== Solver Functions ==================== */

    function registerSolver(address rewardRecipient) external payable;

    function unregisterSolver() external;

    function setSolverRewardRecipient(address newRecipient) external;

    function executeTransfer(
        bytes32 orderId,
        address dstToken,
        uint256 dstAmount,
        address dstRecipient,
        bytes32 proof
    ) external;

    /* ==================== Validator Functions ==================== */

    function registerValidator() external payable;

    function unregisterValidator() external;

    function approveOrderSettlement(bytes32 orderId, bool approved) external;

    function settleOrder(bytes32 orderId) external;

    /* ==================== Admin Functions ==================== */

    function emergencyWithdraw(
        address token,
        uint256 amount,
        address recipient
    ) external;

    function pause() external;

    function unpause() external;

    function setProtocolFee(uint256 feeBps) external;

    function setMinValidatorStake(uint256 amount) external;

    function setMinSolverStake(uint256 amount) external;

    function setRequiredValidators(uint256 count) external;

    function slashValidator(address validator, uint256 amount) external;

    /* ==================== Query Functions ==================== */

    function getOrder(bytes32 orderId) external view returns (Order memory);

    function getUserOrders(
        address user
    ) external view returns (bytes32[] memory);

    function getOrderApprovals(
        bytes32 orderId
    ) external view returns (address[] memory);

    function getValidatorCount() external view returns (uint256);

    function getSolverCount() external view returns (uint256);

    function isOrderCompleted(bytes32 orderId) external view returns (bool);
}
