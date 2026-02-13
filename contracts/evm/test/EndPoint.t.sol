// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {EndPoint} from "../src/EndPoint.sol";
import {IEndPoint} from "../src/interfaces/IEndPoint.sol";
import {IntentStatus} from "../src/Enum.sol";
import "../src/Error.sol";

contract EndPointTest is Test {
    EndPoint public implementation;
    EndPoint public endpoint;
    ERC20Mock public token;

    address public owner = address(0x1000);
    address public user = address(0x2000);
    address public validator = address(0x3000);
    address public solver = address(0x4000);
    address public challenger = address(0x5000);
    uint256 public constant CHAIN_ID = 1;

    function setUp() public {
        token = new ERC20Mock();
        token.mint(user, 1_000 ether);
        vm.deal(user, 1_000 ether);
        vm.deal(validator, 1_000 ether);

        implementation = new EndPoint();
        bytes memory initData = abi.encodeCall(
            EndPoint.initialize,
            (owner, CHAIN_ID)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        endpoint = EndPoint(payable(address(proxy)));
    }

    function _submitNativeIntent(uint256 amount) internal returns (bytes32) {
        IEndPoint.SwapIntent memory intent = _baseIntent(address(0), amount);
        vm.prank(user);
        return endpoint.submitIntent{value: amount}(intent);
    }

    function _baseIntent(
        address srcToken,
        uint256 srcAmount
    ) internal view returns (IEndPoint.SwapIntent memory intent) {
        intent = IEndPoint.SwapIntent({
            provider: user,
            srcToken: srcToken,
            srcAmount: srcAmount,
            dstChainId: 2,
            dstToken: abi.encodePacked("dst-token"),
            minDstAmount: 1,
            recipient: abi.encodePacked("dst-recipient"),
            deadline: block.timestamp + 1 hours,
            nonce: 1,
            permitData: bytes("")
        });
    }

    function testInitialize() public view {
        assertEq(endpoint.chainId(), CHAIN_ID);
        assertTrue(endpoint.hasRole(endpoint.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(endpoint.hasRole(endpoint.ADMIN_ROLE(), owner));
    }

    function testSubmitIntentNative_Success() public {
        IEndPoint.SwapIntent memory intent = _baseIntent(address(0), 1 ether);
        bytes32 expectedHash = keccak256(abi.encode(intent));

        vm.prank(user);
        bytes32 intentHash = endpoint.submitIntent{value: 1 ether}(intent);

        assertEq(intentHash, expectedHash);
        (IntentStatus status, address recordSolver) = endpoint.intentRecords(intentHash);
        assertEq(uint256(status), uint256(IntentStatus.Submitted));
        assertEq(recordSolver, address(0));
    }

    function testSubmitIntentERC20_Success() public {
        IEndPoint.SwapIntent memory intent = _baseIntent(address(token), 100 ether);

        vm.startPrank(user);
        token.approve(address(endpoint), intent.srcAmount);
        endpoint.submitIntent(intent);
        vm.stopPrank();

        assertEq(token.balanceOf(address(endpoint)), intent.srcAmount);
    }

    function testSubmitIntent_RevertOnDuplicate() public {
        IEndPoint.SwapIntent memory intent = _baseIntent(address(0), 1 ether);
        bytes32 intentHash = keccak256(abi.encode(intent));

        vm.prank(user);
        endpoint.submitIntent{value: 1 ether}(intent);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ErrIntentExisted.selector, intentHash));
        endpoint.submitIntent{value: 1 ether}(intent);
    }

    function testSubmitIntent_RevertOnExpiredDeadline() public {
        IEndPoint.SwapIntent memory intent = _baseIntent(address(0), 1 ether);
        intent.deadline = block.timestamp;

        vm.prank(user);
        vm.expectRevert();
        endpoint.submitIntent{value: 1 ether}(intent);
    }

    function testSubmitIntent_RevertWhenPaused() public {
        vm.prank(owner);
        endpoint.pause();

        IEndPoint.SwapIntent memory intent = _baseIntent(address(0), 1 ether);
        vm.prank(user);
        vm.expectRevert();
        endpoint.submitIntent{value: 1 ether}(intent);
    }

    function testExecuteIntent_Success() public {
        bytes32 intentHash = _submitNativeIntent(1 ether);

        endpoint.executeIntent(intentHash, solver);
        (IntentStatus status, address recordSolver) = endpoint.intentRecords(intentHash);

        assertEq(uint256(status), uint256(IntentStatus.Executed));
        assertEq(recordSolver, solver);
    }

    function testSettlement_ProposeAndFinalize_Success() public {
        bytes32 intentHash = _submitNativeIntent(1 ether);
        endpoint.executeIntent(intentHash, solver);

        uint256 stake = endpoint.minValidatorStake();
        vm.prank(validator);
        endpoint.registerValidator{value: stake}();

        vm.prank(validator);
        endpoint.proposeSettlement(intentHash, 900_000);
        (IntentStatus pendingStatus, ) = endpoint.intentRecords(intentHash);
        assertEq(uint256(pendingStatus), uint256(IntentStatus.PendingSettlement));

        vm.warp(block.timestamp + endpoint.CHALLENGE_WINDOW() + 1);
        endpoint.finalizeSettlement(intentHash);

        (IntentStatus settledStatus, ) = endpoint.intentRecords(intentHash);
        assertEq(uint256(settledStatus), uint256(IntentStatus.Settled));
    }

    function testSettlement_Challenge_SlashesValidator() public {
        bytes32 intentHash = _submitNativeIntent(1 ether);
        endpoint.executeIntent(intentHash, solver);

        uint256 stake = endpoint.minValidatorStake();
        vm.prank(validator);
        endpoint.registerValidator{value: stake}();

        vm.prank(validator);
        endpoint.proposeSettlement(intentHash, 900_000);

        vm.prank(challenger);
        endpoint.challengeSettlement(intentHash);

        (IntentStatus statusAfterChallenge, ) = endpoint.intentRecords(intentHash);
        assertEq(uint256(statusAfterChallenge), uint256(IntentStatus.Executed));

        (uint256 validatorStake, bool active) = endpoint.validators(validator);
        assertEq(validatorStake, 90 ether);
        assertFalse(active);
    }

    function testRefundIntent_AfterDeadline() public {
        IEndPoint.SwapIntent memory intent = _baseIntent(address(0), 1 ether);
        intent.deadline = block.timestamp + 60;
        uint256 userBefore = user.balance;

        vm.prank(user);
        bytes32 intentHash = endpoint.submitIntent{value: intent.srcAmount}(intent);

        assertEq(address(endpoint).balance, intent.srcAmount);
        vm.warp(intent.deadline + 1);

        vm.prank(user);
        endpoint.refundIntent(intentHash);

        (IntentStatus status, ) = endpoint.intentRecords(intentHash);
        assertEq(uint256(status), uint256(IntentStatus.Refunded));
        assertEq(address(endpoint).balance, 0);
        assertEq(user.balance, userBefore);
    }
}
