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
import {IZKVerifier} from "./interfaces/IZKVerifier.sol";
import {NATIVE_TOKEN_ADDRESS, CHALLENGE_WINDOW} from "./Constant.sol";
import {ErrInvalidAddress, ErrVerifierNotSet, ErrInvalidAmount, ErrTransferFailed, ErrFeeTooHigh, ErrPenaltyTooHigh, ErrInvalidValidatorCount, ErrInsufficientStake, ErrSlashExceedsStake, ErrAlreadyRegistered, ErrNotValidator, ErrNotSolver, ErrAlreadyInactive, ErrInsufficientETH, ErrUnexpectedETH, ErrInvalidDestinationChain, ErrExpiredDeadline, ErrInvalidDestinationToken, ErrInvalidRecipientLength, ErrZeroRecipientBytes, ErrOrderNotFound, ErrInvalidOrderStatus, ErrWrongChain, ErrInsufficientOutput, ErrNullifierUsed, ErrExecutionReplayed, ErrInvalidSolverSignature, ErrInvalidZKProof, ErrSolverInactive, ErrValidatorInactive, ErrAlreadyApproved, ErrCannotSettle, ErrAlreadySettled, ErrChallengeWindowOpen, ErrCannotRefund, ErrCannotRefundYet, ErrNoRejectVotes, ErrValidatorDidNotVote} from "../src/Error.sol";

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
    mapping(bytes32 => bytes) internal orderRecipientBytes;
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
        bytes dstRecipient;
        address solver;
    }

    struct SubmitContext {
        address user;
        address srcToken;
        uint256 srcAmount;
        uint256 dstChainId;
        bytes dstToken;
        uint256 minDstAmount;
        bytes recipient;
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
        if (feeBps > 10000) revert ErrFeeTooHigh(feeBps);
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
        if (count == 0 || count > totalValidators)
            revert ErrInvalidValidatorCount(count);
        requiredValidators = count;
    }

    /// @notice Set the validator penalty in basis points (bps)
    /// @param penaltyBps The new validator penalty in bps (max 5000)
    function setValidatorPenaltyBps(uint256 penaltyBps) external onlyOwner {
        if (penaltyBps > 5000) revert ErrPenaltyTooHigh(penaltyBps);
        validatorPenaltyBps = penaltyBps;
    }

    /// @notice Backward-compatible alias to satisfy interface naming.
    function setZkVerifier(address verifier) external onlyOwner {
        if (verifier == address(0)) revert ErrInvalidAddress(verifier);
        zkVerifier = verifier;
        emit ZkVerifierUpdated(verifier);
    }

    /// @notice Emergency withdraw tokens from the contract
    /// @param token The token address
    /// @param amount The amount to withdraw
    /// @param recipient The recipient address
    function emergencyWithdraw(
        address token,
        uint256 amount,
        address recipient
    ) public override(IBridge, Withdrawable) {
        super.emergencyWithdraw(token, amount, recipient);
    }

    /// @notice Pause the contract (disables critical functions)
    function pause() public override(IBridge, Core) {
        super.pause();
    }

    /// @notice Unpause the contract (enables critical functions)
    function unpause() public override(IBridge, Core) {
        super.unpause();
    }

    /* =================== Validator Management ==================== */

    /// @notice Register as a validator with ETH stake
    function registerValidator() external payable nonReentrant {
        if (msg.value < minValidatorStake)
            revert ErrInsufficientStake(msg.value, minValidatorStake);
        if (isValidator[msg.sender]) revert ErrAlreadyRegistered(msg.sender);

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
        if (!isValidator[msg.sender]) revert ErrNotValidator(msg.sender);
        ValidatorInfo storage info = validators[msg.sender];
        if (!info.active) revert ErrAlreadyInactive(msg.sender);

        uint256 stakeAmount = info.stake;
        info.active = false;
        isValidator[msg.sender] = false;
        totalValidators--;

        (bool success, ) = payable(msg.sender).call{value: stakeAmount}("");
        if (!success) revert ErrTransferFailed();

        emit ValidatorUnregistered(msg.sender, stakeAmount);
    }

    /// @notice Slash a validator for misbehavior
    function slashValidator(
        address validator,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!isValidator[validator]) revert ErrNotValidator(validator);
        ValidatorInfo storage info = validators[validator];
        if (amount > info.stake)
            revert ErrSlashExceedsStake(amount, info.stake);

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
        if (msg.value < minSolverStake)
            revert ErrInsufficientStake(msg.value, minSolverStake);
        if (isSolver[msg.sender]) revert ErrAlreadyRegistered(msg.sender);
        if (rewardRecipient == address(0))
            revert ErrInvalidAddress(rewardRecipient);

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
        if (!isSolver[msg.sender]) revert ErrNotSolver(msg.sender);
        SolverInfo storage info = solvers[msg.sender];
        if (!info.active) revert ErrAlreadyInactive(msg.sender);

        uint256 stakeAmount = info.stake;
        info.active = false;
        isSolver[msg.sender] = false;

        (bool success, ) = payable(msg.sender).call{value: stakeAmount}("");
        if (!success) revert ErrTransferFailed();

        emit SolverUnstaked(msg.sender, stakeAmount);
    }

    /// @notice Update solver reward recipient
    function setSolverRewardRecipient(address newRecipient) external {
        if (!isSolver[msg.sender]) revert ErrNotSolver(msg.sender);
        if (newRecipient == address(0)) revert ErrInvalidAddress(newRecipient);
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
            if (msg.value != srcAmountWithFee)
                revert ErrInsufficientETH(msg.value, srcAmountWithFee);
        } else {
            if (msg.value != 0) revert ErrUnexpectedETH();
            IERC20(srcToken).safeTransferFrom(
                msg.sender,
                address(this),
                srcAmountWithFee
            );
        }
    }

    /// @notice Internal function to validate submitOrder inputs
    /// @param ctx The submit context containing order parameters
    function _validateSubmitOrderInputs(
        SubmitContext memory ctx
    ) internal view {
        if (ctx.srcAmount == 0) revert ErrInvalidAmount(ctx.srcAmount);
        if (ctx.dstChainId == 0 || ctx.dstChainId == chainId)
            revert ErrInvalidDestinationChain(ctx.dstChainId);
        if (!_isRecipientLengthSupported(ctx.recipient.length))
            revert ErrInvalidRecipientLength(ctx.recipient.length);
        if (_isZeroBytes(ctx.recipient)) revert ErrZeroRecipientBytes();
        if (ctx.deadline <= block.timestamp)
            revert ErrExpiredDeadline(ctx.deadline);
        if (ctx.dstToken.length == 0) revert ErrInvalidDestinationToken();
    }

    /// @notice Internal function to check if recipient length is supported (20 or 32 bytes)
    /// @param length The length of the recipient bytes
    /// @return True if the length is supported, false otherwise
    function _isRecipientLengthSupported(
        uint256 length
    ) internal pure returns (bool) {
        return length == 20 || length == 32;
    }

    /// @notice Internal function to check if bytes array is all zeros
    /// @param data The bytes array to check
    /// @return True if all bytes are zero, false otherwise
    function _isZeroBytes(bytes memory data) internal pure returns (bool) {
        for (uint256 i = 0; i < data.length; ++i) {
            if (data[i] != 0) {
                return false;
            }
        }
        return true;
    }

    /// @notice Internal function to convert bytes to address
    /// @param recipient The bytes representation of the recipient
    /// @return addr The address extracted from bytes
    function _bytesToAddress(
        bytes memory recipient
    ) internal pure returns (address addr) {
        if (recipient.length != 20) return address(0);
        assembly {
            addr := shr(96, mload(add(recipient, 32)))
        }
    }

    /// @notice Internal function to create a new order and emit event
    /// @param ctx The submit context containing order parameters
    /// @param srcAmountWithFee The total amount including protocol fee
    /// @return orderId The ID of the created order
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
        order.recipient = _bytesToAddress(ctx.recipient);
        order.deadline = ctx.deadline;
        order.nonce = nonce;
        order.status = OrderStatus.Submitted;

        orderRecipientBytes[orderId] = ctx.recipient;

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
            order.recipient,
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
        bytes calldata recipient,
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

        uint256 srcAmountWithFee = _lockOrderAssets(
            ctx.srcToken,
            ctx.srcAmount
        );
        orderId = _createSubmittedOrder(ctx, srcAmountWithFee);

        return orderId;
    }

    /// @notice Internal function to handle rejected settlement votes and apply penalties
    /// @param orderId The ID of the order being voted on
    /// @param validator The address of the validator who rejected the settlement
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

    /// @notice Internal function to check if settlement can be finalized and update order status
    /// @param orderId The ID of the order being finalized
    /// @param order The order struct to update
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

    /// @notice Internal function to release settled funds to user and solver
    /// @param order The order struct containing settlement details
    /// @param userRefund The amount to refund to the user
    /// @param solverReward The amount to reward the solver
    function _releaseSettledFunds(
        Order storage order,
        uint256 userRefund,
        uint256 solverReward
    ) internal {
        if (order.srcToken == NATIVE_TOKEN_ADDRESS) {
            (bool userOk, ) = payable(order.user).call{value: userRefund}("");
            if (!userOk) revert ErrTransferFailed();

            address rewardRecipient = solvers[order.solver].rewardRecipient;
            (bool solverOk, ) = payable(rewardRecipient).call{
                value: solverReward
            }("");
            if (!solverOk) revert ErrTransferFailed();
            return;
        }

        IERC20(order.srcToken).safeTransfer(order.user, userRefund);
        IERC20(order.srcToken).safeTransfer(
            solvers[order.solver].rewardRecipient,
            solverReward
        );
    }

    /// @notice Internal function to validate public inputs of a zk proof
    /// @param orderId The ID of the order being validated
    /// @param dstRecipient The recipient address on the destination chain
    /// @param dstAmount The amount being transferred
    /// @param zk The zk execution proof
    function _validatePublicInputs(
        bytes32 orderId,
        bytes memory dstRecipient,
        uint256 dstAmount,
        ZkExecution calldata zk
    ) internal pure {
        if (zk.publicInputs.length < 4) revert ErrInvalidZKProof();
        if (zk.publicInputs[0] != orderId) revert ErrInvalidZKProof();
        if (zk.publicInputs[1] != keccak256(dstRecipient))
            revert ErrInvalidZKProof();
        if (zk.publicInputs[2] != bytes32(dstAmount))
            revert ErrInvalidZKProof();
        if (zk.publicInputs[3] != zk.nullifier) revert ErrInvalidZKProof();
    }

    /// @notice Internal function to validate execution proof and prevent replay attacks
    /// @param ctx Execution context for this transfer
    /// @param zk The zk execution proof and solver signature
    /// @return digest The digest of the execution proof for replay protection
    function _validateExecutionProof(
        ExecutionContext memory ctx,
        ZkExecution calldata zk
    ) internal view returns (bytes32 digest) {
        if (zkVerifier == address(0)) revert ErrVerifierNotSet();
        if (usedNullifiers[zk.nullifier]) revert ErrNullifierUsed(zk.nullifier);

        digest = DigestLib.buildExecutionDigest(
            address(this),
            ctx.orderId,
            ctx.dstToken,
            ctx.dstAmount,
            ctx.dstRecipient,
            ctx.solver,
            zk.nullifier
        );

        if (usedExecutionDigests[digest]) revert ErrExecutionReplayed(digest);
        if (
            SignatureLib.recoverSigner(digest, zk.solverSignature) != ctx.solver
        ) revert ErrInvalidSolverSignature();

        // Bind proof public inputs to order core fields.
        _validatePublicInputs(ctx.orderId, ctx.dstRecipient, ctx.dstAmount, zk);
    }

    /* =================== Phase 2: Solver Executes Transfer ==================== */

    /// @notice Internal function to validate and update order execution details
    /// @param ctx Execution context for this transfer
    function _validateAndUpdateExecutionOrder(
        ExecutionContext memory ctx
    ) internal {
        Order storage order = orders[ctx.orderId];
        if (order.user == address(0)) revert ErrOrderNotFound(ctx.orderId);
        if (order.status != OrderStatus.Submitted)
            revert ErrInvalidOrderStatus(uint8(order.status));
        if (order.dstChainId != chainId)
            revert ErrWrongChain(order.dstChainId, chainId);
        if (ctx.dstAmount < order.minDstAmount)
            revert ErrInsufficientOutput(ctx.dstAmount, order.minDstAmount);

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
        bytes calldata dstRecipient,
        ZkExecution calldata zk
    ) external nonReentrant whenNotPaused {
        address solver = msg.sender;
        if (!isSolver[solver]) revert ErrNotSolver(solver);
        if (!solvers[solver].active) revert ErrSolverInactive(solver);
        if (dstAmount == 0) revert ErrInvalidAmount(dstAmount);
        if (!_isRecipientLengthSupported(dstRecipient.length))
            revert ErrInvalidRecipientLength(dstRecipient.length);
        if (_isZeroBytes(dstRecipient)) revert ErrZeroRecipientBytes();

        ExecutionContext memory ctx = ExecutionContext({
            orderId: orderId,
            dstToken: dstToken,
            dstAmount: dstAmount,
            dstRecipient: dstRecipient,
            solver: solver
        });

        bytes32 digest = _validateExecutionProof(ctx, zk);

        bool valid = IZKVerifier(zkVerifier).verify(
            zk.zkProof,
            zk.publicInputs
        );
        if (!valid) revert ErrInvalidZKProof();

        usedNullifiers[zk.nullifier] = true;
        usedExecutionDigests[digest] = true;

        _validateAndUpdateExecutionOrder(ctx);
        orders[orderId].executionProof = digest;
        orderRecipientBytes[orderId] = dstRecipient;

        emit SolverExecutionVerified(orderId, solver, zk.nullifier, digest);
        emit OrderExecuted(
            orderId,
            solver,
            chainId,
            dstToken,
            dstAmount,
            _bytesToAddress(dstRecipient),
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
        if (!isValidator[validator]) revert ErrNotValidator(validator);
        if (!validators[validator].active)
            revert ErrValidatorInactive(validator);

        Order storage order = orders[orderId];
        if (order.user == address(0)) revert ErrOrderNotFound(orderId);
        if (order.status != OrderStatus.Executed)
            revert ErrInvalidOrderStatus(uint8(order.status));
        if (hasApproved[orderId][validator])
            revert ErrAlreadyApproved(validator, orderId);

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
        if (order.user == address(0)) revert ErrOrderNotFound(orderId);
        if (order.status != OrderStatus.Completed) revert ErrCannotSettle();
        if (order.settled) revert ErrAlreadySettled(orderId);
        if (block.timestamp < settlementReadyAt[orderId])
            revert ErrChallengeWindowOpen(settlementReadyAt[orderId]);

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
        if (order.user == address(0)) revert ErrOrderNotFound(orderId);
        if (
            order.status != OrderStatus.Submitted &&
            order.status != OrderStatus.Executed
        ) revert ErrCannotRefund();
        if (block.timestamp <= order.deadline && msg.sender != order.user)
            revert ErrCannotRefundYet(order.deadline);

        order.status = OrderStatus.Refunded;

        // Refund full locked amount
        if (order.srcToken == NATIVE_TOKEN_ADDRESS) {
            (bool success, ) = payable(order.user).call{
                value: order.srcAmountWithFee
            }("");
            if (!success) revert ErrTransferFailed();
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
        if (orderRejectCount[orderId] == 0) revert ErrNoRejectVotes(orderId);
        if (!isValidator[validator]) revert ErrNotValidator(validator);
        if (!hasApproved[orderId][validator])
            revert ErrValidatorDidNotVote(validator, orderId);

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

        emit SettlementChallenged(orderId, msg.sender, validator, penalty);
    }

    /* =================== Query Functions ==================== */

    /// @notice Get order details by ID
    /// @param orderId The order ID
    /// @return The Order struct associated with the given ID
    function getOrder(bytes32 orderId) external view returns (Order memory) {
        return orders[orderId];
    }

    /// @notice Get list of order IDs for a user
    /// @param user The user address
    /// @return An array of order IDs associated with the user
    function getUserOrders(
        address user
    ) external view returns (bytes32[] memory) {
        return userOrders[user];
    }

    /// @notice Get list of validator approvals for an order
    /// @param orderId The order ID
    /// @return An array of validator addresses who approved the order
    function getOrderApprovals(
        bytes32 orderId
    ) external view returns (address[] memory) {
        return orderApprovals[orderId];
    }

    /// @notice Get the original recipient bytes for an order
    /// @param orderId The order ID
    /// @return The original recipient bytes provided in the order
    function getOrderRecipientBytes(
        bytes32 orderId
    ) external view returns (bytes memory) {
        return orderRecipientBytes[orderId];
    }

    /// @notice Get total number of registered validators
    /// @return The count of registered validators
    function getValidatorCount() external view returns (uint256) {
        return validatorList.length;
    }

    /// @notice Get total number of registered solvers
    /// @return The count of registered solvers
    function getSolverCount() external view returns (uint256) {
        return solverList.length;
    }

    /// @notice Check if an order is completed
    /// @param orderId The order ID
    /// @return True if the order is completed, false otherwise
    function isOrderCompleted(bytes32 orderId) external view returns (bool) {
        return orders[orderId].status == OrderStatus.Completed;
    }
}
