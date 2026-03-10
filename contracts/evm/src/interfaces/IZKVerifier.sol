// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IZKVerifier {
    /// @notice Verifies a zero-knowledge proof with the given public inputs
    /// @param proof The zero-knowledge proof to verify
    /// @param publicInputs The public inputs associated with the proof
    /// @return A boolean indicating whether the proof is valid
    function verify(
        bytes calldata proof,
        bytes32[] calldata publicInputs
    ) external view returns (bool);
}
