// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title DigestLib
 * @dev Library for building execution digests
 */
library DigestLib {
    /**
     * @notice Build execution digest from order and execution details
     * @param executor The executor address (or contract address)
     * @param orderId The order ID
     * @param dstToken The destination token address
     * @param dstAmount The destination amount
     * @param dstRecipient The destination recipient
     * @param solver The solver address
     * @param nullifier The nullifier for replay protection
     * @return The computed digest
     */
    function buildExecutionDigest(
        address executor,
        bytes32 orderId,
        address dstToken,
        uint256 dstAmount,
        address dstRecipient,
        address solver,
        bytes32 nullifier
    ) internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    executor,
                    block.chainid,
                    orderId,
                    dstToken,
                    dstAmount,
                    dstRecipient,
                    solver,
                    nullifier
                )
            );
    }
}
