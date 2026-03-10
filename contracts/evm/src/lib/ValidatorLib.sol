// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ValidatorLib
 * @dev Library for validator management operations
 */
library ValidatorLib {
    /**
     * @notice Calculate the effective slash amount for a validator
     * @param stake The validator's current stake
     * @param amount The amount to slash
     * @return effectiveSlash The actual amount to slash (capped by stake)
     */
    function calculateSlashAmount(uint256 stake, uint256 amount) internal pure returns (uint256 effectiveSlash) {
        if (amount > stake) return stake;
        return amount;
    }

    /**
     * @notice Check if validator should become inactive after slash
     * @param remainingStake The remaining stake after slash
     * @param minValidatorStake Minimum stake to remain active
     * @return shouldDeactivate True if validator should be deactivated
     */
    function shouldDeactivate(uint256 remainingStake, uint256 minValidatorStake) internal pure returns (bool) {
        return remainingStake < minValidatorStake;
    }
}
