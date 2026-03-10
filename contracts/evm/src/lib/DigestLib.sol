// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title DigestLib
 * @dev Library for building execution digests
 */
library DigestLib {
    /**
     * @notice Build execution digest where destination recipient is arbitrary bytes.
     * @dev Used by heterogeneous-chain recipient flow (EVM/Sui/Solana/etc).
     */
    function buildExecutionDigest(
        address executor,
        bytes32 orderId,
        address dstToken,
        uint256 dstAmount,
        bytes memory dstRecipient,
        address solver,
        bytes32 nullifier
    ) internal view returns (bytes32 digest) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            let recipientLen := mload(dstRecipient)
            let recipientPtr := add(dstRecipient, 0x20)
            let paddedRecipientLen := and(add(recipientLen, 0x1f), not(0x1f))

            // abi.encode(
            //   executor, block.chainid, orderId, dstToken, dstAmount,
            //   dstRecipient, solver, nullifier
            // )
            mstore(ptr, executor)
            mstore(add(ptr, 0x20), chainid())
            mstore(add(ptr, 0x40), orderId)
            mstore(add(ptr, 0x60), dstToken)
            mstore(add(ptr, 0x80), dstAmount)
            mstore(add(ptr, 0xa0), 0x100)
            mstore(add(ptr, 0xc0), solver)
            mstore(add(ptr, 0xe0), nullifier)

            let tailPtr := add(ptr, 0x100)
            mstore(tailPtr, recipientLen)

            let tailDataPtr := add(tailPtr, 0x20)
            for {
                let i := 0
            } lt(i, paddedRecipientLen) {
                i := add(i, 0x20)
            } {
                mstore(add(tailDataPtr, i), mload(add(recipientPtr, i)))
            }

            // Zero out trailing bytes in the final word to match abi.encode padding.
            let rem := and(recipientLen, 0x1f)
            if rem {
                let lastWordPtr := add(tailDataPtr, sub(recipientLen, rem))
                let shift := mul(sub(0x20, rem), 8)
                let cleaned := shl(shift, shr(shift, mload(lastWordPtr)))
                mstore(lastWordPtr, cleaned)
            }

            let totalLen := add(0x120, paddedRecipientLen)
            digest := keccak256(ptr, totalLen)
        }
    }
}
