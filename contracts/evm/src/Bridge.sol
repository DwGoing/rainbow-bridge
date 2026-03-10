// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBridge} from "./interfaces/IBridge.sol";
import {Core} from "./Core.sol";
import {Withdrawable} from "./Withdrawable.sol";
import {SignatureLib} from "./lib/SignatureLib.sol";
import {DigestLib} from "./lib/DigestLib.sol";
import {ValidatorLib} from "./lib/ValidatorLib.sol";
import "./Constant.sol";
import "./Error.sol";
import "./interfaces/IZKVerifier.sol";

contract Bridge is IBridge, Withdrawable {
    using SafeERC20 for IERC20;
    using SignatureLib for bytes;
    using DigestLib for *;

    /* =================== State Variables ==================== */

    uint256 public chainId;
    uint256 public protocolFeeBps = 30; // 0.3%
    uint256 public minValidatorStake = 100 ether;
    uint256 public minSolverStake = 10 ether;
    uint256 public requiredValidators = 3; // M-of-N signatures required
    uint256 public totalValidators = 0;
    uint256 public validatorPenaltyBps = 500; // 5% stake penalty for malicious vote
    address public zkVerifier;

    // Order management
    mapping(bytes32 => Order) internal orders;
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
    mapping(bytes32 => uint256) public orderApproveCount;
    mapping(bytes32 => uint256) public orderRejectCount;
    mapping(bytes32 => uint256) public settlementReadyAt;

    // Replay protection
    mapping(bytes32 => bool) public usedNullifiers;
    mapping(bytes32 => bool) public usedExecutionDigests;

    struct ExecutionContext {
        bytes32 orderId;
        address dstToken;
        uint256 dstAmount;
        address dstRecipient;
        address solver;
    }

    struct SubmitContext {
        address user;
        address srcToken;
        uint256 srcAmount;
        uint256 dstChainId;
        bytes dstToken;
        uint256 minDstAmount;
        address recipient;
        uint256 deadline;
    }

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
        validatorPenaltyBps = 500;
    }

    /* =================== Admin Functions ==================== */

    /// @notice Set protocol fee in basis points (bps)
    /// @param feeBps The new protocol fee in bps (max 10000)
    function setProtocolFee(uint256 feeBps) external onlyOwner {
        require(feeBps <= 10000, "Fee too high");
        protocolFeeBps = feeBps;
    }

    /// @notice Set minimum stake for validators
    /// @param amount The new minimum stake amount in wei
    function setMinValidatorStake(uint256 amount) external onlyOwner {
        minValidatorStake = amount;
    }

    /// @notice Set minimum stake for solvers
    /// @param amount The new minimum stake amount in wei
    function setMinSolverStake(uint256 amount) external onlyOwner {
        minSolverStake = amount;
    }

    /// @notice Set the number of required validator approvals for settlement
    /// @param count The new required validator count
    function setRequiredValidators(uint256 count) external onlyOwner {
        require(
            count > 0 && count <= totalValidators,
            "Invalid validator count"
        );
        requiredValidators = count;
    }

    /// @notice Set the validator penalty in basis points (bps)
    /// @param penaltyBps The new validator penalty in bps (max 5000)
    function setValidatorPenaltyBps(uint256 penaltyBps) external onlyOwner {
        require(penaltyBps <= 5000, "Penalty too high");
        validatorPenaltyBps = penaltyBps;
    }

    /// @notice Set the zero-knowledge verifier contract address
    /// @param verifier The new verifier contract address
    function setZKVerifier(address verifier) external onlyOwner {
        if (verifier == address(0)) revert ErrInvalidAddress(verifier);
        zkVerifier = verifier;
        emit ZKVerifierUpdated(verifier);
    }

    function emergencyWithdraw(
        address token,
        uint256 amount,
        address recipient
    ) public override(IBridge, Withdrawable) {
        super.emergencyWithdraw(token, amount, recipient);
    }

    function pause() public override(IBridge, Core) {
        super.pause();
    }

    function unpause() public override(IBridge, Core) {
        super.unpause();
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

    /// @notice Internal function to lock assets for order
    /// @param srcToken Token address to lock
    /// @param srcAmount Amount of token
    /// @return srcAmountWithFee Amount including protocol fee
    function _lockOrderAssets(
        address srcToken,
        uint256 srcAmount
    ) internal returns (uint256 srcAmountWithFee) {
        // Calculate protocol fee
        uint256 fee = (srcAmount * protocolFeeBps) / 10000;
        srcAmountWithFee = srcAmount + fee;

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
    }

    function _validateSubmitOrderInputs(
        SubmitContext memory ctx
    ) internal view {
        require(ctx.srcAmount > 0, "Invalid amount");
        require(
            ctx.dstChainId != 0 && ctx.dstChainId != chainId,
            "Invalid destination chain"
        );
        require(ctx.recipient != address(0), "Invalid recipient");
        require(ctx.deadline > block.timestamp, "Expired deadline");
        require(ctx.dstToken.length > 0, "Invalid destination token");
    }

    function _createSubmittedOrder(
        SubmitContext memory ctx,
        uint256 srcAmountWithFee
    ) internal returns (bytes32 orderId) {
        uint256 nonce = userOrderCount[ctx.user]++;
        orderId = keccak256(
            abi.encode(ctx.user, chainId, nonce, block.timestamp)
        );

        Order storage order = orders[orderId];
        order.user = ctx.user;
        order.srcChainId = chainId;
        order.srcToken = ctx.srcToken;
        order.srcAmount = ctx.srcAmount;
        order.srcAmountWithFee = srcAmountWithFee;
        order.dstChainId = ctx.dstChainId;
        order.dstToken = ctx.dstToken;
        order.minDstAmount = ctx.minDstAmount;
        order.recipient = ctx.recipient;
        order.deadline = ctx.deadline;
        order.nonce = nonce;
        order.status = OrderStatus.Submitted;

        userOrders[ctx.user].push(orderId);

        emit OrderCreated(
            orderId,
            ctx.user,
            chainId,
            ctx.srcToken,
            ctx.srcAmount,
            ctx.dstChainId,
            ctx.dstToken,
            ctx.minDstAmount,
            ctx.recipient,
            ctx.deadline
        );
    }

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
        SubmitContext memory ctx = SubmitContext({
            user: msg.sender,
            srcToken: srcToken,
            srcAmount: srcAmount,
            dstChainId: dstChainId,
            dstToken: dstToken,
            minDstAmount: minDstAmount,
            recipient: recipient,
            deadline: deadline
        });

        _validateSubmitOrderInputs(ctx);

        uint256 srcAmountWithFee = _lockOrderAssets(ctx.srcToken, ctx.srcAmount);
        orderId = _createSubmittedOrder(ctx, srcAmountWithFee);

        return orderId;
    }

    function _handleRejectedSettlement(
        bytes32 orderId,
        address validator
    ) internal {
        orderRejectCount[orderId] += 1;

        // Rejecting a zk-verified execution is considered malicious behavior.
        uint256 penalty = (validators[validator].stake * validatorPenaltyBps) /
            10000;

        // Slash validator stake
        ValidatorInfo storage info = validators[validator];
        uint256 slashAmount = ValidatorLib.calculateSlashAmount(
            info.stake,
            penalty
        );
        if (slashAmount > 0) {
            info.stake -= slashAmount;
            info.slashCount++;
            if (ValidatorLib.shouldDeactivate(info.stake, minValidatorStake)) {
                info.active = false;
            }
            emit ValidatorSlashed(validator, slashAmount);
        }

        emit SettlementChallenged(orderId, validator, validator, penalty);
    }

    function _finalizeIfReady(bytes32 orderId, Order storage order) internal {
        if (
            orderApproveCount[orderId] >= requiredValidators &&
            orderRejectCount[orderId] == 0
        ) {
            order.status = OrderStatus.Completed;
            order.validationTime = block.timestamp;
            order.approvalCount = orderApproveCount[orderId];
            settlementReadyAt[orderId] = block.timestamp + CHALLENGE_WINDOW;
        }
    }

    function _releaseSettledFunds(
        Order storage order,
        uint256 userRefund,
        uint256 solverReward
    ) internal {
        if (order.srcToken == NATIVE_TOKEN_ADDRESS) {
            (bool userOk, ) = payable(order.user).call{value: userRefund}("");
            require(userOk, "Transfer to user failed");

            address rewardRecipient = solvers[order.solver].rewardRecipient;
            (bool solverOk, ) = payable(rewardRecipient).call{
                value: solverReward
            }("");
            require(solverOk, "Transfer to solver failed");
            return;
        }

        IERC20(order.srcToken).safeTransfer(order.user, userRefund);
        IERC20(order.srcToken).safeTransfer(
            solvers[order.solver].rewardRecipient,
            solverReward
        );
    }

    function _validatePublicInputs(
        bytes32 orderId,
        address dstRecipient,
        uint256 dstAmount,
        ZKExecution calldata zk
    ) internal pure {
        require(zk.publicInputs.length >= 4, "Bad public input length");
        require(zk.publicInputs[0] == orderId, "Public order mismatch");
        require(
            zk.publicInputs[1] == bytes32(uint256(uint160(dstRecipient))),
            "Public recipient mismatch"
        );
        require(
            zk.publicInputs[2] == bytes32(dstAmount),
            "Public amount mismatch"
        );
        require(
            zk.publicInputs[3] == zk.nullifier,
            "Public nullifier mismatch"
        );
    }

    function _validateExecutionProof(
        ExecutionContext memory ctx,
        ZKExecution calldata zk
    ) internal view returns (bytes32 digest) {
        require(zkVerifier != address(0), "Verifier not set");
        require(!usedNullifiers[zk.nullifier], "Nullifier used");

        digest = DigestLib.buildExecutionDigest(
            address(this),
            ctx.orderId,
            ctx.dstToken,
            ctx.dstAmount,
            ctx.dstRecipient,
            ctx.solver,
            zk.nullifier
        );

        require(!usedExecutionDigests[digest], "Execution replayed");
        require(
            SignatureLib.recoverSigner(digest, zk.solverSignature) == ctx.solver,
            "Invalid solver signature"
        );

        // Bind proof public inputs to order core fields.
        _validatePublicInputs(
            ctx.orderId,
            ctx.dstRecipient,
            ctx.dstAmount,
            zk
        );
    }

    /* =================== Phase 2: Solver Executes Transfer ==================== */

    /// @notice Internal function to validate and update order execution details
    /// @param ctx Execution context for this transfer
    function _validateAndUpdateExecutionOrder(
        ExecutionContext memory ctx
    ) internal {
        Order storage order = orders[ctx.orderId];
        require(order.user != address(0), "Order not found");
        require(order.status == OrderStatus.Submitted, "Invalid order status");
        require(order.dstChainId == chainId, "Wrong chain");
        require(ctx.dstAmount >= order.minDstAmount, "Insufficient output");

        // Update order with execution details
        order.solver = ctx.solver;
        order.executionTime = block.timestamp;
        order.dstTokenAddress = ctx.dstToken;
        order.dstAmount = ctx.dstAmount;
        order.status = OrderStatus.Executed;
    }

    /// @notice Solver executes transfer on destination chain
    /// @param orderId The order ID from source chain
    /// @param dstToken The token address on destination chain
    /// @param dstAmount The amount actually transferred
    /// @param dstRecipient The recipient on destination chain
    /// @param zk Structured execution proof and solver signature
    function executeTransfer(
        bytes32 orderId,
        address dstToken,
        uint256 dstAmount,
        address dstRecipient,
        ZKExecution calldata zk
    ) external nonReentrant whenNotPaused {
        address solver = msg.sender;
        require(isSolver[solver], "Not a solver");
        require(solvers[solver].active, "Solver inactive");
        require(dstAmount > 0, "Invalid amount");
        require(dstRecipient != address(0), "Invalid recipient");

        ExecutionContext memory ctx = ExecutionContext({
            orderId: orderId,
            dstToken: dstToken,
            dstAmount: dstAmount,
            dstRecipient: dstRecipient,
            solver: solver
        });

        bytes32 digest = _validateExecutionProof(ctx, zk);

        bool valid = IZKVerifier(zkVerifier).verify(zk.zkProof, zk.publicInputs);
        require(valid, "Invalid zk proof");

        usedNullifiers[zk.nullifier] = true;
        usedExecutionDigests[digest] = true;

        _validateAndUpdateExecutionOrder(ctx);
        orders[orderId].executionProof = digest;

        emit SolverExecutionVerified(orderId, solver, zk.nullifier, digest);
        emit OrderExecuted(
            orderId,
            solver,
            chainId,
            dstToken,
            dstAmount,
            dstRecipient,
            digest
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
        address validator = msg.sender;
        require(isValidator[validator], "Not a validator");
        require(validators[validator].active, "Validator inactive");

        Order storage order = orders[orderId];
        require(order.user != address(0), "Order not found");
        require(order.status == OrderStatus.Executed, "Invalid order status");
        require(!hasApproved[orderId][validator], "Already approved");

        hasApproved[orderId][validator] = true;

        if (approved) {
            orderApprovals[orderId].push(validator);
            orderApproveCount[orderId] += 1;
        } else {
            _handleRejectedSettlement(orderId, validator);
        }

        emit OrderSettlement(
            orderId,
            validator,
            orderApproveCount[orderId],
            approved
        );

        _finalizeIfReady(orderId, order);
    }

    /// @notice Release funds once order is validated by multi-sig validators
    /// @param orderId The order ID
    function settleOrder(bytes32 orderId) external nonReentrant {
        Order storage order = orders[orderId];
        require(order.user != address(0), "Order not found");
        require(order.status == OrderStatus.Completed, "Cannot settle");
        require(!order.settled, "Already settled");
        require(
            block.timestamp >= settlementReadyAt[orderId],
            "Challenge window open"
        );

        order.settled = true;
        order.status = OrderStatus.Settled;

        // Calculate returns
        uint256 solverReward = (order.srcAmount * 5) / 100; // 5% solver reward from principal
        uint256 userRefund = order.srcAmount - solverReward;

        _releaseSettledFunds(order, userRefund, solverReward);

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

    function challengeSettlement(
        bytes32 orderId,
        address validator
    ) external nonReentrant {
        require(orderRejectCount[orderId] > 0, "No reject votes");
        require(isValidator[validator], "Not a validator");
        require(hasApproved[orderId][validator], "Validator did not vote");

        uint256 penalty = (validators[validator].stake * validatorPenaltyBps) /
            10000;
        
        // Slash validator stake
        ValidatorInfo storage info = validators[validator];
        uint256 slashAmount = ValidatorLib.calculateSlashAmount(info.stake, penalty);
        if (slashAmount > 0) {
            info.stake -= slashAmount;
            info.slashCount++;
            if (ValidatorLib.shouldDeactivate(info.stake, minValidatorStake)) {
                info.active = false;
            }
            emit ValidatorSlashed(validator, slashAmount);
        }

        emit SettlementChallenged(orderId, msg.sender, validator, penalty);
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
}
