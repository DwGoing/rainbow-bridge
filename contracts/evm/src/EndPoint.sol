// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./Error.sol";
import "./Enum.sol";
import {IEndPoint} from "./interfaces/IEndPoint.sol";

contract EndPoint is
    IEndPoint,
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    address public constant NATIVE_TOKEN_ADDRESS = address(0);
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant CHALLENGE_WINDOW = 10 minutes;

    uint256 public chainId;
    uint256 public protocolFeeBps = 3; // 0.03%
    uint256 public minValidatorStake = 100 ether;
    mapping(bytes32 => SwapIntent) public intents;
    mapping(bytes32 => IntentRecord) public intentRecords;
    mapping(address => ValidatorInfo) public validators;
    mapping(bytes32 => PendingSettlement) public pendingSettlements;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    receive() external payable {}

    /// @notice Initializes the EndPoint contract
    /// @param owner The owner address
    /// @param chainId_ The chain ID of this EndPoint
    function initialize(address owner, uint256 chainId_) public initializer {
        __Pausable_init();
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, owner);
        _grantRole(ADMIN_ROLE, owner);
        chainId = chainId_;
        protocolFeeBps = 3;
        minValidatorStake = 100 ether;
    }

    /* =================== Internal Functions ==================== */

    /// @notice Authorizes contract upgrades
    /// @param newImplementation The new implementation address
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function _ensureIntentExists(bytes32 intentHash) internal view {
        if (intents[intentHash].provider == address(0)) {
            revert ErrIntentNotFound(intentHash);
        }
    }

    function _transferAsset(
        address token,
        address receiver,
        uint256 amount
    ) internal {
        if (token == NATIVE_TOKEN_ADDRESS) {
            (bool transferSuccess, ) = payable(receiver).call{value: amount}("");
            if (!transferSuccess) revert ErrTransferFailed();
            return;
        }

        bool erc20TransferSuccess = IERC20(token).trySafeTransfer(receiver, amount);
        if (!erc20TransferSuccess) revert ErrTransferFailed();
    }

    function _slashValidator(address validator, uint256 amount) internal {
        ValidatorInfo storage info = validators[validator];
        if (amount > info.stake) {
            amount = info.stake;
        }

        info.stake -= amount;
        if (info.stake < minValidatorStake) {
            info.active = false;
        }

        emit ValidatorSlashed(validator, amount);
    }

    /* =================== Public Functions ==================== */

    /// @notice Emergency withdraw function
    /// @param token The token address
    /// @param amount The amount to withdraw
    /// @param receipient The receipient address
    function emergencyWithdraw(
        address token,
        uint256 amount,
        address receipient
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (amount == 0) revert ErrInvalidAmount();
        if (receipient == address(0)) revert ErrInvalidRecepient();

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

        emit Withdrawn(token, amount, receipient);
    }

    /// @notice Pauses the contract
    function pause() external override onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpauses the contract
    function unpause() external override onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Submit a swap intent with optional ERC20Permit support
    /// @param intent The swap intent details (including optional permitData)
    /// @return intentHash The hash of the submitted intent
    function submitIntent(
        SwapIntent calldata intent
    ) external payable whenNotPaused nonReentrant returns (bytes32 intentHash) {
        if (intent.provider == address(0)) revert ErrInvalidProvider();
        if (intent.srcAmount == 0) revert ErrInvalidAmount();
        if (intent.dstChainId == 0) revert ErrInvalidChainId();
        if (intent.recipient.length == 0) revert ErrInvalidRecepient();
        if (intent.deadline <= block.timestamp)
            revert ErrInvalidDeadline(block.timestamp, intent.deadline);

        intentHash = keccak256(abi.encode(intent));
        if (intentRecords[intentHash].status != IntentStatus.None)
            revert ErrIntentExisted(intentHash);

        if (intent.srcToken == NATIVE_TOKEN_ADDRESS) {
            if (msg.value != intent.srcAmount)
                revert ErrDismatchAmount(intent.srcAmount, msg.value);
        } else {
            // Permit ERC20 if permitData is provided
            if (intent.permitData.length > 0) {
                (
                    uint256 value,
                    uint256 deadline,
                    uint8 v,
                    bytes32 r,
                    bytes32 s
                ) = abi.decode(
                        intent.permitData,
                        (uint256, uint256, uint8, bytes32, bytes32)
                    );

                try
                    IERC20Permit(intent.srcToken).permit(
                        intent.provider,
                        address(this),
                        value,
                        deadline,
                        v,
                        r,
                        s
                    )
                {} catch {}
            }

            // Check allowance
            uint256 allowance = IERC20(intent.srcToken).allowance(
                intent.provider,
                address(this)
            );
            if (allowance < intent.srcAmount)
                revert ErrInsufficientBalance({
                    token: intent.srcToken,
                    requested: intent.srcAmount,
                    available: allowance
                });

            // Transfer tokens
            IERC20(intent.srcToken).safeTransferFrom(
                intent.provider,
                address(this),
                intent.srcAmount
            );
        }

        intents[intentHash] = intent;
        intentRecords[intentHash] = IntentRecord({
            status: IntentStatus.Submitted,
            solver: address(0)
        });

        emit IntentSubmitted(intentHash, msg.sender);
    }

    function executeIntent(
        bytes32 intentHash,
        address solver
    ) external override whenNotPaused {
        _ensureIntentExists(intentHash);
        if (solver == address(0)) revert ErrInvalidSolver();

        IntentRecord storage record = intentRecords[intentHash];
        if (record.status != IntentStatus.Submitted) revert ErrInvalidIntentStatus();

        record.status = IntentStatus.Executed;
        record.solver = solver;

        emit IntentExecuted(intentHash, solver);
    }

    function registerValidator() external payable override whenNotPaused {
        if (msg.value < minValidatorStake) revert ErrInvalidAmount();

        ValidatorInfo storage info = validators[msg.sender];
        info.stake += msg.value;
        info.active = true;

        emit ValidatorRegistered(msg.sender, info.stake);
    }

    function proposeSettlement(
        bytes32 intentHash,
        uint256 amountOut
    ) external override whenNotPaused {
        _ensureIntentExists(intentHash);
        if (!validators[msg.sender].active) revert ErrValidatorNotActive(msg.sender);
        if (amountOut == 0) revert ErrInvalidAmount();

        IntentRecord storage record = intentRecords[intentHash];
        if (record.status != IntentStatus.Executed) revert ErrInvalidIntentStatus();

        pendingSettlements[intentHash] = PendingSettlement({
            validator: msg.sender,
            solver: record.solver,
            amountOut: amountOut,
            timestamp: block.timestamp
        });
        record.status = IntentStatus.PendingSettlement;

        emit SettlementProposed(intentHash, msg.sender, record.solver, amountOut);
    }

    function finalizeSettlement(bytes32 intentHash) external override whenNotPaused {
        _ensureIntentExists(intentHash);

        IntentRecord storage record = intentRecords[intentHash];
        if (record.status != IntentStatus.PendingSettlement) revert ErrInvalidIntentStatus();

        PendingSettlement memory pending = pendingSettlements[intentHash];
        uint256 required = pending.timestamp + CHALLENGE_WINDOW;
        if (block.timestamp < required) {
            revert ErrChallengeWindowNotElapsed(block.timestamp, required);
        }

        record.status = IntentStatus.Settled;
        emit SettlementFinalized(intentHash, pending.solver);
        delete pendingSettlements[intentHash];
    }

    function challengeSettlement(bytes32 intentHash) external override whenNotPaused {
        _ensureIntentExists(intentHash);

        IntentRecord storage record = intentRecords[intentHash];
        if (record.status != IntentStatus.PendingSettlement) revert ErrInvalidIntentStatus();

        PendingSettlement memory pending = pendingSettlements[intentHash];
        uint256 deadline = pending.timestamp + CHALLENGE_WINDOW;
        if (block.timestamp >= deadline) {
            revert ErrChallengeWindowElapsed(block.timestamp, deadline);
        }

        _slashValidator(pending.validator, validators[pending.validator].stake / 10);
        record.status = IntentStatus.Executed;
        emit SettlementChallenged(intentHash, msg.sender);
        delete pendingSettlements[intentHash];
    }

    function refundIntent(bytes32 intentHash) external override nonReentrant {
        _ensureIntentExists(intentHash);

        SwapIntent memory intent = intents[intentHash];
        if (msg.sender != intent.provider) revert ErrNotIntentProvider();

        IntentRecord storage record = intentRecords[intentHash];
        if (record.status != IntentStatus.Submitted) revert ErrInvalidIntentStatus();
        if (block.timestamp <= intent.deadline) {
            revert ErrInvalidDeadline(block.timestamp, intent.deadline);
        }

        record.status = IntentStatus.Refunded;
        _transferAsset(intent.srcToken, intent.provider, intent.srcAmount);
        emit IntentRefunded(intentHash);
    }
}
