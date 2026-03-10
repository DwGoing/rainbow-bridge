// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBridge} from "./interfaces/IBridge.sol";
import {Core} from "./Core.sol";
import "./Constant.sol";
import "./Error.sol";

/* =================== Main Contract ==================== */

contract Bridge is IBridge, Core, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* =================== State Variables ==================== */

    uint256 public chainId;
    uint256 public protocolFeeBps = 30; // 0.3%
    uint256 public minValidatorStake = 100 ether;
    uint256 public minSolverStake = 10 ether;
    uint256 public requiredValidators = 3; // M-of-N signatures required
    uint256 public totalValidators = 0;

    // Order management
    mapping(bytes32 => Order) public orders;
    mapping(address => uint256) public userOrderCount;
    mapping(address => bytes32[]) public userOrders;
    mapping(uint256 => uint256) public dstChainExecutedCount; // Track execution count per chain

    // Validator management
    mapping(address => ValidatorInfo) public validators;
    address[] public validatorList;
    mapping(address => bool) public isValidator;

    // Solver management
    mapping(address => SolverInfo) public solvers;
    address[] public solverList;
    mapping(address => bool) public isSolver;

    // Settlement tracking
    mapping(bytes32 => address[]) public orderApprovals;
    mapping(bytes32 => mapping(address => bool)) public hasApproved;

    receive() external payable {}

    /* =================== Initialization ==================== */

    /// @notice Initialize the Bridge contract
    /// @param owner The owner address
    /// @param chainId_ The chain ID of this endpoint
    function initialize(address owner, uint256 chainId_) public initializer {
        __Core_init(owner);

        chainId = chainId_;
        protocolFeeBps = 30;
        minValidatorStake = 100 ether;
        minSolverStake = 10 ether;
        requiredValidators = 3;
    }

    /* =================== Admin Functions ==================== */

    function setProtocolFee(uint256 feeBps) external onlyOwner {
        require(feeBps <= 10000, "Fee too high");
        protocolFeeBps = feeBps;
    }

    function setMinValidatorStake(uint256 amount) external onlyOwner {
        minValidatorStake = amount;
    }

    function setMinSolverStake(uint256 amount) external onlyOwner {
        minSolverStake = amount;
    }

    function setRequiredValidators(uint256 count) external onlyOwner {
        require(
            count > 0 && count <= totalValidators,
            "Invalid validator count"
        );
        requiredValidators = count;
    }

    /* =================== Validator Management ==================== */

    /// @notice Register as a validator with ETH stake
    function registerValidator() external payable nonReentrant {
        require(msg.value >= minValidatorStake, "Insufficient stake");
        require(!isValidator[msg.sender], "Already registered");

        isValidator[msg.sender] = true;
        validatorList.push(msg.sender);
        totalValidators++;

        validators[msg.sender] = ValidatorInfo({
            stake: msg.value,
            active: true,
            joinTime: block.timestamp,
            slashCount: 0
        });

        emit ValidatorRegistered(msg.sender, msg.value);
    }

    /// @notice Unregister as validator and withdraw stake
    function unregisterValidator() external nonReentrant {
        require(isValidator[msg.sender], "Not a validator");
        ValidatorInfo storage info = validators[msg.sender];
        require(info.active, "Already inactive");

        uint256 stakeAmount = info.stake;
        info.active = false;
        isValidator[msg.sender] = false;
        totalValidators--;

        (bool success, ) = payable(msg.sender).call{value: stakeAmount}("");
        require(success, "Transfer failed");

        emit ValidatorUnregistered(msg.sender, stakeAmount);
    }

    /// @notice Slash a validator for misbehavior
    function slashValidator(
        address validator,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(isValidator[validator], "Not a validator");
        ValidatorInfo storage info = validators[validator];
        require(amount <= info.stake, "Slash exceeds stake");

        info.stake -= amount;
        info.slashCount++;

        if (info.stake < minValidatorStake) {
            info.active = false;
        }

        emit ValidatorSlashed(validator, amount);
    }

    /* =================== Solver Management ==================== */

    /// @notice Register as a solver with ETH stake
    /// @param rewardRecipient Address to receive rewards
    function registerSolver(
        address rewardRecipient
    ) external payable nonReentrant {
        require(msg.value >= minSolverStake, "Insufficient stake");
        require(!isSolver[msg.sender], "Already registered");
        require(rewardRecipient != address(0), "Invalid recipient");

        isSolver[msg.sender] = true;
        solverList.push(msg.sender);

        solvers[msg.sender] = SolverInfo({
            stake: msg.value,
            active: true,
            joinTime: block.timestamp,
            rewardRecipient: rewardRecipient
        });

        emit SolverStaked(msg.sender, msg.value);
    }

    /// @notice Unregister as solver and withdraw stake
    function unregisterSolver() external nonReentrant {
        require(isSolver[msg.sender], "Not a solver");
        SolverInfo storage info = solvers[msg.sender];
        require(info.active, "Already inactive");

        uint256 stakeAmount = info.stake;
        info.active = false;
        isSolver[msg.sender] = false;

        (bool success, ) = payable(msg.sender).call{value: stakeAmount}("");
        require(success, "Transfer failed");

        emit SolverUnstaked(msg.sender, stakeAmount);
    }

    /// @notice Update solver reward recipient
    function setSolverRewardRecipient(address newRecipient) external {
        require(isSolver[msg.sender], "Not a solver");
        require(newRecipient != address(0), "Invalid recipient");
        solvers[msg.sender].rewardRecipient = newRecipient;
    }

    /* =================== Phase 1: User Submits Order ==================== */

    /// @notice User submits a cross-chain swap order on source chain
    /// @param srcToken The token to swap from
    /// @param srcAmount The amount to swap
    /// @param dstChainId The destination chain ID
    /// @param dstToken The token to swap to (as bytes for chain compatibility)
    /// @param minDstAmount Minimum amount on destination chain
    /// @param recipient Final recipient address
    /// @param deadline Order expiration time
    function submitOrder(
        address srcToken,
        uint256 srcAmount,
        uint256 dstChainId,
        bytes calldata dstToken,
        uint256 minDstAmount,
        address recipient,
        uint256 deadline
    ) external payable nonReentrant whenNotPaused returns (bytes32 orderId) {
        require(srcAmount > 0, "Invalid amount");
        require(
            dstChainId != 0 && dstChainId != chainId,
            "Invalid destination chain"
        );
        require(recipient != address(0), "Invalid recipient");
        require(deadline > block.timestamp, "Expired deadline");
        require(dstToken.length > 0, "Invalid destination token");

        // Calculate protocol fee
        uint256 fee = (srcAmount * protocolFeeBps) / 10000;
        uint256 srcAmountWithFee = srcAmount + fee;

        // Lock assets
        if (srcToken == NATIVE_TOKEN_ADDRESS) {
            require(msg.value == srcAmountWithFee, "Insufficient ETH");
        } else {
            require(msg.value == 0, "ETH not needed");
            IERC20(srcToken).safeTransferFrom(
                msg.sender,
                address(this),
                srcAmountWithFee
            );
        }

        // Create order
        uint256 nonce = userOrderCount[msg.sender]++;
        orderId = keccak256(
            abi.encode(msg.sender, chainId, nonce, block.timestamp)
        );

        Order storage order = orders[orderId];
        order.user = msg.sender;
        order.srcChainId = chainId;
        order.srcToken = srcToken;
        order.srcAmount = srcAmount;
        order.srcAmountWithFee = srcAmountWithFee;
        order.dstChainId = dstChainId;
        order.dstToken = dstToken;
        order.minDstAmount = minDstAmount;
        order.recipient = recipient;
        order.deadline = deadline;
        order.nonce = nonce;
        order.status = OrderStatus.Submitted;

        userOrders[msg.sender].push(orderId);

        emit OrderCreated(
            orderId,
            msg.sender,
            chainId,
            srcToken,
            srcAmount,
            dstChainId,
            dstToken,
            minDstAmount,
            recipient,
            deadline
        );

        return orderId;
    }

    /* =================== Phase 2: Solver Executes Transfer ==================== */

    /// @notice Solver executes transfer on destination chain
    /// @param orderId The order ID from source chain
    /// @param dstToken The token address on destination chain
    /// @param dstAmount The amount actually transferred
    /// @param dstRecipient The recipient on destination chain
    /// @param proof ZK proof of execution (off-chain generated)
    function executeTransfer(
        bytes32 orderId,
        address dstToken,
        uint256 dstAmount,
        address dstRecipient,
        bytes32 proof
    ) external nonReentrant whenNotPaused {
        require(isSolver[msg.sender], "Not a solver");
        require(dstAmount > 0, "Invalid amount");
        require(dstRecipient != address(0), "Invalid recipient");

        Order storage order = orders[orderId];
        require(order.user != address(0), "Order not found");
        require(order.status == OrderStatus.Submitted, "Invalid order status");
        require(order.dstChainId == chainId, "Wrong chain");
        require(dstAmount >= order.minDstAmount, "Insufficient output");

        // Update order with execution details
        order.solver = msg.sender;
        order.executionTime = block.timestamp;
        order.dstTokenAddress = dstToken;
        order.dstAmount = dstAmount;
        order.executionProof = proof;
        order.status = OrderStatus.Executed;

        emit OrderExecuted(
            orderId,
            msg.sender,
            chainId,
            dstToken,
            dstAmount,
            dstRecipient,
            proof
        );
    }

    /* =================== Phase 3: Validators Verify and Settle ==================== */

    /// @notice Validator approves order settlement with multi-sig consensus
    /// @param orderId The order ID
    /// @param approved Whether to approve or reject
    function approveOrderSettlement(
        bytes32 orderId,
        bool approved
    ) external nonReentrant {
        require(isValidator[msg.sender], "Not a validator");
        require(validators[msg.sender].active, "Validator inactive");

        Order storage order = orders[orderId];
        require(order.user != address(0), "Order not found");
        require(order.status == OrderStatus.Executed, "Invalid order status");
        require(!hasApproved[orderId][msg.sender], "Already approved");

        hasApproved[orderId][msg.sender] = true;
        orderApprovals[orderId].push(msg.sender);

        emit OrderSettlement(
            orderId,
            msg.sender,
            orderApprovals[orderId].length,
            approved
        );

        // Check if we have enough approvals
        if (orderApprovals[orderId].length >= requiredValidators) {
            order.status = OrderStatus.Completed;
            order.validationTime = block.timestamp;
            order.approvalCount = orderApprovals[orderId].length;
        }
    }

    /// @notice Release funds once order is validated by multi-sig validators
    /// @param orderId The order ID
    function settleOrder(bytes32 orderId) external nonReentrant {
        Order storage order = orders[orderId];
        require(order.user != address(0), "Order not found");
        require(order.status == OrderStatus.Completed, "Cannot settle");
        require(!order.settled, "Already settled");

        order.settled = true;
        order.status = OrderStatus.Settled;

        // Calculate returns
        uint256 solverReward = (order.srcAmount * 5) / 100; // 5% solver reward from principal
        uint256 userRefund = order.srcAmount - solverReward;

        // Release to user (original chain)
        if (order.srcToken == NATIVE_TOKEN_ADDRESS) {
            (bool success, ) = payable(order.user).call{value: userRefund}("");
            require(success, "Transfer to user failed");
        } else {
            IERC20(order.srcToken).safeTransfer(order.user, userRefund);
        }

        // Release reward to solver (nominated recipient)
        if (order.srcToken == NATIVE_TOKEN_ADDRESS) {
            (bool success, ) = payable(solvers[order.solver].rewardRecipient)
                .call{value: solverReward}("");
            require(success, "Transfer to solver failed");
        } else {
            IERC20(order.srcToken).safeTransfer(
                solvers[order.solver].rewardRecipient,
                solverReward
            );
        }

        emit OrderSettled(orderId, userRefund, solverReward);
    }

    /// @notice Refund user if order fails or expires
    /// @param orderId The order ID
    function refundOrder(bytes32 orderId) external nonReentrant {
        Order storage order = orders[orderId];
        require(order.user != address(0), "Order not found");
        require(
            order.status == OrderStatus.Submitted ||
                order.status == OrderStatus.Executed,
            "Cannot refund"
        );
        require(
            block.timestamp > order.deadline || msg.sender == order.user,
            "Cannot refund yet"
        );

        order.status = OrderStatus.Refunded;

        // Refund full locked amount
        if (order.srcToken == NATIVE_TOKEN_ADDRESS) {
            (bool success, ) = payable(order.user).call{
                value: order.srcAmountWithFee
            }("");
            require(success, "Refund failed");
        } else {
            IERC20(order.srcToken).safeTransfer(
                order.user,
                order.srcAmountWithFee
            );
        }

        emit OrderRefunded(orderId, order.user, order.srcAmountWithFee);
    }

    /* =================== Query Functions ==================== */

    function getOrder(bytes32 orderId) external view returns (Order memory) {
        return orders[orderId];
    }

    function getUserOrders(
        address user
    ) external view returns (bytes32[] memory) {
        return userOrders[user];
    }

    function getOrderApprovals(
        bytes32 orderId
    ) external view returns (address[] memory) {
        return orderApprovals[orderId];
    }

    function getValidatorCount() external view returns (uint256) {
        return validatorList.length;
    }

    function getSolverCount() external view returns (uint256) {
        return solverList.length;
    }

    function isOrderCompleted(bytes32 orderId) external view returns (bool) {
        return orders[orderId].status == OrderStatus.Completed;
    }

    /* =================== Emergency Functions ==================== */

    function emergencyWithdraw(
        address token,
        uint256 amount,
        address recipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (recipient == address(0)) revert ErrInvalidAddress(recipient);
        if (amount == 0) revert ErrInvalidAmount(amount);

        if (token == NATIVE_TOKEN_ADDRESS) {
            uint256 balance = address(this).balance;
            if (balance < amount) {
                revert ErrInsufficientBalance({
                    token: token,
                    requested: amount,
                    available: balance
                });
            }

            (bool success, ) = payable(recipient).call{value: amount}("");
            if (!success) revert ErrTransferFailed();
        } else {
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance < amount) {
                revert ErrInsufficientBalance({
                    token: token,
                    requested: amount,
                    available: balance
                });
            }

            IERC20(token).safeTransfer(recipient, amount);
        }

        emit Withdrawn(token, recipient, amount);
    }

    function pause() public override(Core, IBridge) onlyOwnerOrRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause()
        public
        override(Core, IBridge)
        onlyOwnerOrRole(ADMIN_ROLE)
    {
        _unpause();
    }
}
