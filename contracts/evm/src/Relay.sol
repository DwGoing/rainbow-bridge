// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IRelay} from "./interfaces/IRelay.sol";
import "./Error.sol";
import "./Enum.sol";
import "./lib/util.sol";

contract Relay is
    IRelay,
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    address public constant NATIVE_TOKEN_ADDRESS = address(0);
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    uint256 public chainId;
    mapping(uint256 => mapping(uint256 => bytes32)) public executedSwapIntents;

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
    }

    /* =================== Internal Functions ==================== */

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function _executeSwapIntent(
        uint256 srcChainId,
        uint256 id,
        address token,
        uint256 amount,
        address receipient,
        bytes32 solver
    ) internal returns (bytes32 proof) {
        if (amount == 0) revert ErrInvalidAmount();
        if (receipient == address(0)) revert ErrInvalidRecepient();
        if (srcChainId == 0) revert ErrInvalidChainId();
        if (executedSwapIntents[srcChainId][id] != bytes32(0)) {
            revert ErrSwapIntentExecuted(srcChainId, id);
        }

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

        proof = Util.culculateProofHash(
            srcChainId,
            id,
            token,
            amount,
            receipient,
            solver
        );
        executedSwapIntents[srcChainId][id] = proof;

        emit SwapIntentExecuted(
            srcChainId,
            id,
            token,
            amount,
            receipient,
            proof
        );
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

    function executeSwapIntentByTransfer(
        uint256 srcChainId,
        uint256 id,
        address token,
        uint256 amount,
        address receipient,
        bytes32 solver
    )
        external
        payable
        override
        whenNotPaused
        nonReentrant
        returns (bytes32 proof)
    {
        if (amount == 0) revert ErrInvalidAmount();

        if (token == NATIVE_TOKEN_ADDRESS) {
            if (msg.value != amount) revert ErrInvalidAmount();
            if (msg.value < amount)
                revert ErrInsufficientBalance({
                    token: token,
                    requested: amount,
                    available: msg.value
                });
        } else {
            uint256 allowance = IERC20(token).allowance(
                msg.sender,
                address(this)
            );
            if (allowance < amount)
                revert ErrInsufficientBalance({
                    token: token,
                    requested: amount,
                    available: allowance
                });
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }

        proof = _executeSwapIntent(
            srcChainId,
            id,
            token,
            amount,
            receipient,
            solver
        );
    }

    function executeSwapIntentByCall(
        uint256 srcChainId,
        uint256 id,
        address token,
        uint256 amount,
        address receipient,
        bytes32 solver
    ) external override whenNotPaused nonReentrant returns (bytes32 proof) {
        if (msg.sender.code.length == 0) revert ErrInvalidCaller(msg.sender);

        proof = _executeSwapIntent(
            srcChainId,
            id,
            token,
            amount,
            receipient,
            solver
        );
    }
}
