// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {Relay} from "../src/Relay.sol";
import "../src/Error.sol";

contract MockSolver {
    Relay public relay;

    constructor(address relay_) {
        relay = Relay(payable(relay_));
    }

    receive() external payable {}

    function executeWithNative(
        uint256 srcChainId,
        uint256 id,
        uint256 amount,
        address recipient,
        bytes32 solver
    ) external payable returns (bytes32) {
        (bool ok, ) = payable(address(relay)).call{value: amount}("");
        require(ok, "fund relay failed");
        return
            relay.executeSwapIntentByCall(
                srcChainId,
                id,
                address(0),
                amount,
                recipient,
                solver
            );
    }
}

contract RelayTest is Test {
    Relay public implementation;
    Relay public relay;
    ERC20Mock public token;
    MockSolver public solverContract;

    address public owner = address(0x1000);
    address public user = address(0x2000);
    address public eoaSolver = address(0x3000);

    uint256 public constant SRC_CHAIN_ID = 1;
    uint256 public constant SWAP_ID = 7;
    uint256 public constant AMOUNT = 10 ether;
    bytes32 public constant SOLVER_ID = keccak256("solver-1");

    function setUp() public {
        token = new ERC20Mock();
        token.mint(eoaSolver, 1_000 ether);

        implementation = new Relay();
        bytes memory initData = abi.encodeCall(Relay.initialize, (owner, 2));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        relay = Relay(payable(address(proxy)));
        solverContract = new MockSolver(address(relay));

        vm.deal(eoaSolver, 100 ether);
        vm.deal(address(solverContract), 100 ether);
    }

    function testExecuteByTransfer_Native_Success() public {
        uint256 beforeUser = user.balance;

        vm.prank(eoaSolver);
        bytes32 proof = relay.executeSwapIntentByTransfer{value: AMOUNT}(
            SRC_CHAIN_ID,
            SWAP_ID,
            address(0),
            AMOUNT,
            user,
            SOLVER_ID
        );

        bytes32 expected = keccak256(
            abi.encodePacked(
                SRC_CHAIN_ID,
                SWAP_ID,
                address(0),
                AMOUNT,
                user,
                SOLVER_ID
            )
        );

        assertEq(user.balance, beforeUser + AMOUNT);
        assertEq(proof, expected);
        assertEq(relay.executedSwapIntents(SRC_CHAIN_ID, SWAP_ID), expected);
    }

    function testExecuteByTransfer_ERC20_Success() public {
        vm.startPrank(eoaSolver);
        token.approve(address(relay), AMOUNT);
        relay.executeSwapIntentByTransfer(
            SRC_CHAIN_ID,
            SWAP_ID,
            address(token),
            AMOUNT,
            user,
            SOLVER_ID
        );
        vm.stopPrank();

        assertEq(token.balanceOf(user), AMOUNT);
    }

    function testExecuteByTransfer_RevertOnDuplicate() public {
        vm.prank(eoaSolver);
        relay.executeSwapIntentByTransfer{value: AMOUNT}(
            SRC_CHAIN_ID,
            SWAP_ID,
            address(0),
            AMOUNT,
            user,
            SOLVER_ID
        );

        vm.prank(eoaSolver);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrSwapIntentExecuted.selector,
                SRC_CHAIN_ID,
                SWAP_ID
            )
        );
        relay.executeSwapIntentByTransfer{value: AMOUNT}(
            SRC_CHAIN_ID,
            SWAP_ID,
            address(0),
            AMOUNT,
            user,
            SOLVER_ID
        );
    }

    function testExecuteByCall_RevertWhenEOA() public {
        vm.prank(eoaSolver);
        vm.expectRevert(
            abi.encodeWithSelector(ErrInvalidCaller.selector, eoaSolver)
        );
        relay.executeSwapIntentByCall(
            SRC_CHAIN_ID,
            SWAP_ID,
            address(0),
            AMOUNT,
            user,
            SOLVER_ID
        );
    }

    function testExecuteByCall_SuccessWithContract() public {
        uint256 beforeUser = user.balance;

        bytes32 proof = solverContract.executeWithNative{value: AMOUNT}(
            SRC_CHAIN_ID,
            SWAP_ID,
            AMOUNT,
            user,
            SOLVER_ID
        );

        assertTrue(proof != bytes32(0));
        assertEq(user.balance, beforeUser + AMOUNT);
    }

    function testExecute_RevertWhenPaused() public {
        vm.prank(owner);
        relay.pause();

        vm.prank(eoaSolver);
        vm.expectRevert();
        relay.executeSwapIntentByTransfer{value: AMOUNT}(
            SRC_CHAIN_ID,
            SWAP_ID,
            address(0),
            AMOUNT,
            user,
            SOLVER_ID
        );
    }
}
