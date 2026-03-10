// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title HashLib
 * @dev Library for cryptographic hash operations
 */
library HashLib {
    /**
     * @notice Calculates the proof hash for cross-chain swap intent
     * @param srcChainId The source chain ID
     * @param id The intent ID
     * @param token The token address
     * @param amount The amount
     * @param recipient The recipient address
     * @param solver The solver identifier
     * @return The keccak256 hash of the packed parameters
     */
    function calculateProofHash(
        uint256 srcChainId,
        uint256 id,
        address token,
        uint256 amount,
        address recipient,
        bytes32 solver
    ) internal pure returns (bytes32) {
        bytes32 result;
        assembly {
            let freeMemPtr := mload(0x40)
            mstore(freeMemPtr, srcChainId)
            mstore(add(freeMemPtr, 0x20), id)
            mstore(add(freeMemPtr, 0x40), token)
            mstore(add(freeMemPtr, 0x60), amount)
            mstore(add(freeMemPtr, 0x80), recipient)
            mstore(add(freeMemPtr, 0xa0), solver)
            result := keccak256(freeMemPtr, 0xc0)
        }
        return result;
    }
}
