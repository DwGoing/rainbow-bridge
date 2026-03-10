// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {ADMIN_ROLE} from "./Constant.sol";
import {ErrUnauthorized, ErrInvalidAddress} from "./Error.sol";

abstract contract Core is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable
{
    uint256[50] private __gap; // Reserved storage space for future upgrades

    /// @notice Admin role for managing the contract
    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    /// @notice Internal function to check if the caller is the owner
    function _onlyOwner() internal view {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert ErrUnauthorized();
        }
    }

    /// @notice Modifier to restrict access to either the owner or a specific role
    modifier onlyOwnerOrRole(bytes32 role) {
        _onlyOwnerOrRole(role);
        _;
    }

    /// @notice Internal function to check if the caller is the owner or has a specific role
    function _onlyOwnerOrRole(bytes32 role) internal view {
        if (
            !hasRole(DEFAULT_ADMIN_ROLE, msg.sender) &&
            !hasRole(role, msg.sender)
        ) {
            revert ErrUnauthorized();
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Authorizes an upgrade to a new implementation
    /// @param newImplementation The address of the new implementation
    function _authorizeUpgrade(
        address newImplementation
    ) internal virtual override onlyOwner {}

    /// @notice Initializes the Core contract
    /// @param owner The owner address
    function __Core_init(address owner) internal onlyInitializing {
        if (owner == address(0)) revert ErrInvalidAddress(owner);

        __Pausable_init();
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, owner);
    }

    /// @notice Pauses the contract
    function pause() public virtual onlyOwnerOrRole(ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpauses the contract
    function unpause() public virtual onlyOwnerOrRole(ADMIN_ROLE) {
        _unpause();
    }
}
