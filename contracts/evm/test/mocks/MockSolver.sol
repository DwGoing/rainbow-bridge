// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IRelay} from "../../src/interfaces/IRelay.sol";

contract MockSolver {
    IRelay public relay;

    constructor(address relayAddress) {
        relay = IRelay(relayAddress);
    }

    function executeSwapIntentWithTransfer(
        uint256 srcChainId,
        uint256 id,
        address token,
        uint256 amount,
        address receipient,
        bytes32 solver
    ) external payable {
        bytes32 proof = relay.executeSwapIntentByCall(
            srcChainId,
            id,
            token,
            amount,
            receipient,
            solver
        );
    }

    function executeSwapIntentWithSwap(
        uint256 srcChainId,
        uint256 id,
        address token,
        uint256 amount,
        address receipient,
        bytes32 solver
    ) external {
        bytes32 proof = relay.executeSwapIntentByCall(
            srcChainId,
            id,
            token,
            amount,
            receipient,
            solver
        );
    }
}
