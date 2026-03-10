// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title SignatureLib
 * @dev Library for cryptographic signature operations
 */
library SignatureLib {
    /**
     * @notice Convert digest to EIP-191 signed message hash
     * @param digest The original digest
     * @return The message hash
     */
    function toEthSignedMessageHash(bytes32 digest) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
    }

    /**
     * @notice Recover signer address from signature
     * @param digest The original digest
     * @param sig The signature bytes (must be 65 bytes: r, s, v)
     * @return signer The recovered signer address, or address(0) if invalid
     */
    function recoverSigner(bytes32 digest, bytes calldata sig) internal pure returns (address signer) {
        if (sig.length != 65) return address(0);

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }

        if (v < 27) v += 27;
        if (v != 27 && v != 28) return address(0);

        signer = ecrecover(toEthSignedMessageHash(digest), v, r, s);
    }
}
