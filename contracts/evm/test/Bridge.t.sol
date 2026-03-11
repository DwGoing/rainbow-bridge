// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Bridge, IZKVerifier} from "../src/Bridge.sol";
import {IBridge} from "../src/interfaces/IBridge.sol";
import {NATIVE_TOKEN_ADDRESS, CHALLENGE_WINDOW, ADMIN_ROLE} from "../src/Constant.sol";
import {ErrUnauthorized, ErrInvalidAddress, ErrInvalidAmount, ErrInsufficientBalance, ErrTransferFailed, ErrFeeTooHigh, ErrPenaltyTooHigh, ErrInvalidValidatorCount, ErrInsufficientStake, ErrSlashExceedsStake, ErrAlreadyRegistered, ErrNotValidator, ErrNotSolver, ErrAlreadyInactive, ErrUnexpectedETH, ErrInvalidDestinationChain, ErrExpiredDeadline, ErrInvalidDestinationToken, ErrInvalidRecipientLength, ErrZeroRecipientBytes, ErrOrderNotFound, ErrInvalidOrderStatus, ErrWrongChain, ErrInsufficientOutput, ErrNullifierUsed, ErrExecutionReplayed, ErrInvalidSolverSignature, ErrInvalidZKProof, ErrSolverInactive, ErrValidatorInactive, ErrAlreadyApproved, ErrCannotSettle, ErrAlreadySettled, ErrChallengeWindowOpen, ErrCannotRefund, ErrCannotRefundYet, ErrNoRejectVotes, ErrValidatorDidNotVote} from "../src/Error.sol";
import {HashLib} from "../src/lib/HashLib.sol";
import {SignatureLib} from "../src/lib/SignatureLib.sol";
import {ValidatorLib} from "../src/lib/ValidatorLib.sol";

contract MockZKVerifier is IZKVerifier {
    bool public shouldPass = true;

    function setShouldPass(bool value) external {
        shouldPass = value;
    }

    function verify(
        bytes calldata,
        bytes32[] calldata
    ) external view returns (bool) {
        return shouldPass;
    }
}

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RevertingReceiver {
    receive() external payable {
        revert("reject eth");
    }
}

contract FalseReturnToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}

contract BridgeHarness is Bridge {
    function setOrderForTest(bytes32 orderId, Order calldata order) external {
        orders[orderId] = order;
    }

    function setSolverForTest(
        address solverAddr,
        SolverInfo calldata info,
        bool registered
    ) external {
        solvers[solverAddr] = info;
        isSolver[solverAddr] = registered;
    }

    function setUsedExecutionDigestForTest(bytes32 digest, bool used) external {
        usedExecutionDigests[digest] = used;
    }

    function setValidatorForTest(
        address validatorAddr,
        ValidatorInfo calldata info,
        bool registered
    ) external {
        validators[validatorAddr] = info;
        isValidator[validatorAddr] = registered;
    }
}

contract HashHarness {
    function hashViaLib(
        uint256 srcChainId,
        uint256 id,
        address token,
        uint256 amount,
        address recipient,
        bytes32 solver
    ) external pure returns (bytes32) {
        return
            HashLib.calculateProofHash(
                srcChainId,
                id,
                token,
                amount,
                recipient,
                solver
            );
    }
}

contract LibHarness {
    function recover(
        bytes32 digest,
        bytes calldata sig
    ) external pure returns (address) {
        return SignatureLib.recoverSigner(digest, sig);
    }

    function slashAmount(
        uint256 stake,
        uint256 amount
    ) external pure returns (uint256) {
        return ValidatorLib.calculateSlashAmount(stake, amount);
    }

    function deactivate(
        uint256 remainingStake,
        uint256 minStake
    ) external pure returns (bool) {
        return ValidatorLib.shouldDeactivate(remainingStake, minStake);
    }
}

contract UnauthorizedCaller {
    function attemptPause(address bridge) external returns (bool) {
        try Bridge(payable(bridge)).pause() {
            return true;
        } catch {
            return false;
        }
    }

    function attemptUpgrade(
        address bridge,
        address newImpl
    ) external returns (bool) {
        try Bridge(payable(bridge)).upgradeToAndCall(newImpl, "") {
            return true;
        } catch {
            return false;
        }
    }
}

contract ContractSolverExecutor {
    function swapAndExecute(
        IBridge bridge,
        address dstToken,
        address recipient,
        uint256 amount,
        bytes32 orderId,
        bytes calldata dstRecipient,
        IBridge.ZkExecution calldata zk
    ) external {
        ERC20(dstToken).transfer(recipient, amount);
        bridge.executeTransfer(orderId, dstToken, amount, dstRecipient, zk);
    }
}

contract BridgeTest is Test {
    BridgeHarness internal bridge;
    MockZKVerifier internal verifier;

    uint256 internal solverPk = 0xA11CE;
    address internal solver;
    address internal solverReward;
    address internal user;
    address internal validator1;
    address internal validator2;
    MockERC20 internal mockToken;
    HashHarness internal hashHarness;
    LibHarness internal libHarness;
    FalseReturnToken internal falseToken;

    function setUp() external {
        solver = vm.addr(solverPk);
        solverReward = makeAddr("solverReward");
        user = makeAddr("user");
        validator1 = makeAddr("validator1");
        validator2 = makeAddr("validator2");

        BridgeHarness impl = new BridgeHarness();
        bytes memory initData = abi.encodeCall(
            Bridge.initialize,
            (address(this), 137)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        bridge = BridgeHarness(payable(address(proxy)));

        verifier = new MockZKVerifier();
        bridge.setZkVerifier(address(verifier));

        bridge.setMinSolverStake(1 ether);
        bridge.setMinValidatorStake(1 ether);

        vm.deal(solver, 10 ether);
        vm.prank(solver);
        bridge.registerSolver{value: 1 ether}(solverReward);

        vm.deal(validator1, 10 ether);
        vm.deal(validator2, 10 ether);

        vm.prank(validator1);
        bridge.registerValidator{value: 1 ether}();

        vm.prank(validator2);
        bridge.registerValidator{value: 1 ether}();

        mockToken = new MockERC20();
        hashHarness = new HashHarness();
        libHarness = new LibHarness();
        falseToken = new FalseReturnToken();
    }

    function testInitializeRevertsZeroOwner() external {
        BridgeHarness impl = new BridgeHarness();
        bytes memory badInit = abi.encodeCall(
            Bridge.initialize,
            (address(0), 137)
        );

        vm.expectRevert(
            abi.encodeWithSelector(ErrInvalidAddress.selector, address(0))
        );
        new ERC1967Proxy(address(impl), badInit);
    }

    function testSubmitOrderNativeSuccess() external {
        vm.deal(user, 10 ether);

        uint256 srcAmount = 1 ether;
        uint256 fee = (srcAmount * 30) / 10000;
        uint256 total = srcAmount + fee;
        uint256 bridgeBefore = address(bridge).balance;

        vm.prank(user);
        bytes32 orderId = bridge.submitOrder{value: total}(
            NATIVE_TOKEN_ADDRESS,
            srcAmount,
            10,
            abi.encodePacked("USDC"),
            5e17,
            abi.encodePacked(user),
            block.timestamp + 1 days
        );

        IBridge.Order memory order = bridge.getOrder(orderId);
        assertEq(order.user, user);
        assertEq(order.srcAmount, srcAmount);
        assertEq(order.srcAmountWithFee, total);
        assertEq(order.dstChainId, 10);
        assertEq(uint256(order.status), uint256(IBridge.OrderStatus.Submitted));
        assertEq(address(bridge).balance - bridgeBefore, total);
    }

    function testRegisterValidatorRevertsInsufficientStake() external {
        address candidate = makeAddr("validator-candidate-insufficient");
        vm.deal(candidate, 1 ether);

        vm.prank(candidate);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrInsufficientStake.selector,
                0.5 ether,
                1 ether
            )
        );
        bridge.registerValidator{value: 0.5 ether}();
    }

    function testRegisterValidatorRevertsAlreadyRegistered() external {
        vm.prank(validator1);
        vm.expectRevert(
            abi.encodeWithSelector(ErrAlreadyRegistered.selector, validator1)
        );
        bridge.registerValidator{value: 1 ether}();
    }

    function testUnregisterValidatorSuccess() external {
        address candidate = makeAddr("validator-candidate-unregister");
        vm.deal(candidate, 5 ether);

        vm.prank(candidate);
        bridge.registerValidator{value: 1 ether}();

        uint256 before = candidate.balance;
        vm.prank(candidate);
        bridge.unregisterValidator();

        assertEq(candidate.balance, before + 1 ether);
        assertFalse(bridge.isValidator(candidate));
    }

    function testUnregisterValidatorRevertsNotValidator() external {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ErrNotValidator.selector, user));
        bridge.unregisterValidator();
    }

    function testUnregisterValidatorRevertsAlreadyInactive() external {
        IBridge.ValidatorInfo memory info = IBridge.ValidatorInfo({
            stake: 1 ether,
            active: false,
            joinTime: block.timestamp,
            slashCount: 0
        });
        bridge.setValidatorForTest(validator1, info, true);

        vm.prank(validator1);
        vm.expectRevert(
            abi.encodeWithSelector(ErrAlreadyInactive.selector, validator1)
        );
        bridge.unregisterValidator();
    }

    function testSubmitOrderERC20Success() external {
        vm.deal(user, 1 ether);
        uint256 srcAmount = 1 ether;
        uint256 fee = (srcAmount * 30) / 10000;
        uint256 total = srcAmount + fee;

        mockToken.mint(user, total);
        vm.startPrank(user);
        mockToken.approve(address(bridge), total);

        bytes32 orderId = bridge.submitOrder(
            address(mockToken),
            srcAmount,
            10,
            abi.encodePacked("ERC20_DST"),
            9e17,
            abi.encodePacked(user),
            block.timestamp + 1 days
        );
        vm.stopPrank();

        IBridge.Order memory order = bridge.getOrder(orderId);
        assertEq(order.srcToken, address(mockToken));
        assertEq(order.srcAmountWithFee, total);
        assertEq(mockToken.balanceOf(address(bridge)), total);
    }

    function testSubmitOrderRevertsInvalidDestinationChain() external {
        vm.deal(user, 10 ether);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(ErrInvalidDestinationChain.selector, 0)
        );
        bridge.submitOrder{value: 1 ether}(
            NATIVE_TOKEN_ADDRESS,
            1 ether,
            0,
            abi.encodePacked("USDC"),
            5e17,
            abi.encodePacked(user),
            block.timestamp + 1 days
        );

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(ErrInvalidDestinationChain.selector, 137)
        );
        bridge.submitOrder{value: 1 ether}(
            NATIVE_TOKEN_ADDRESS,
            1 ether,
            137,
            abi.encodePacked("USDC"),
            5e17,
            abi.encodePacked(user),
            block.timestamp + 1 days
        );
    }

    function testSubmitOrderRevertsInvalidAmount() external {
        vm.deal(user, 10 ether);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ErrInvalidAmount.selector, 0));
        bridge.submitOrder(
            NATIVE_TOKEN_ADDRESS,
            0,
            10,
            abi.encodePacked("USDC"),
            5e17,
            abi.encodePacked(user),
            block.timestamp + 1 days
        );
    }

    function testSubmitOrderRevertsInvalidRecipient() external {
        vm.deal(user, 10 ether);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(ErrInvalidRecipientLength.selector, 0)
        );
        bridge.submitOrder{value: 1 ether}(
            NATIVE_TOKEN_ADDRESS,
            1 ether,
            10,
            abi.encodePacked("USDC"),
            5e17,
            bytes(""),
            block.timestamp + 1 days
        );
    }

    function testSubmitOrderSupports32ByteRecipient() external {
        vm.deal(user, 10 ether);

        uint256 srcAmount = 1 ether;
        uint256 fee = (srcAmount * 30) / 10000;
        uint256 total = srcAmount + fee;
        bytes
            memory recipient = hex"1111111111111111111111111111111111111111111111111111111111111111";

        vm.prank(user);
        bytes32 orderId = bridge.submitOrder{value: total}(
            NATIVE_TOKEN_ADDRESS,
            srcAmount,
            10,
            abi.encodePacked("SUI"),
            5e17,
            recipient,
            block.timestamp + 1 days
        );

        bytes memory storedRecipient = bridge.getOrderRecipientBytes(orderId);
        IBridge.Order memory order = bridge.getOrder(orderId);

        assertEq(storedRecipient, recipient);
        assertEq(order.recipient, address(0));
        assertEq(uint256(order.status), uint256(IBridge.OrderStatus.Submitted));
    }

    function testSubmitOrderRevertsInvalidRecipientLength() external {
        vm.deal(user, 10 ether);

        bytes memory badRecipient = hex"010203";

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(ErrInvalidRecipientLength.selector, 3)
        );
        bridge.submitOrder{value: 1 ether}(
            NATIVE_TOKEN_ADDRESS,
            1 ether,
            10,
            abi.encodePacked("SOL"),
            5e17,
            badRecipient,
            block.timestamp + 1 days
        );
    }

    function testSubmitOrderRevertsExpiredDeadline() external {
        vm.deal(user, 10 ether);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(ErrExpiredDeadline.selector, block.timestamp)
        );
        bridge.submitOrder{value: 1 ether}(
            NATIVE_TOKEN_ADDRESS,
            1 ether,
            10,
            abi.encodePacked("USDC"),
            5e17,
            abi.encodePacked(user),
            block.timestamp
        );
    }

    function testSubmitOrderRevertsInvalidDestinationToken() external {
        vm.deal(user, 10 ether);

        vm.prank(user);
        vm.expectRevert(ErrInvalidDestinationToken.selector);
        bridge.submitOrder{value: 1 ether}(
            NATIVE_TOKEN_ADDRESS,
            1 ether,
            10,
            bytes(""),
            5e17,
            abi.encodePacked(user),
            block.timestamp + 1 days
        );
    }

    function testSubmitOrderRevertsUnexpectedEthForERC20() external {
        vm.deal(user, 10 ether);
        mockToken.mint(user, 1 ether);

        vm.startPrank(user);
        mockToken.approve(address(bridge), 1 ether);
        vm.expectRevert(ErrUnexpectedETH.selector);
        bridge.submitOrder{value: 1 wei}(
            address(mockToken),
            1 ether,
            10,
            abi.encodePacked("ERC20_DST"),
            9e17,
            abi.encodePacked(user),
            block.timestamp + 1 days
        );
        vm.stopPrank();
    }

    function testExecuteTransferRejectsInvalidSignature() external {
        bytes32 orderId = keccak256("order-invalid-sig");
        _setSubmittedOrder(orderId, 137, 1 ether);

        bytes32 nullifier = keccak256("nullifier-1");
        bytes32 digest = _executionDigest(
            orderId,
            makeAddr("dstToken"),
            1 ether,
            user,
            solver,
            nullifier
        );

        uint256 wrongPk = 0xB0B;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            wrongPk,
            _toEthSignedMessageHash(digest)
        );

        IBridge.ZkExecution memory zk = _buildZkExecution(
            orderId,
            user,
            1 ether,
            nullifier,
            abi.encodePacked(r, s, v)
        );

        vm.prank(solver);
        vm.expectRevert(ErrInvalidSolverSignature.selector);
        bridge.executeTransfer(
            orderId,
            makeAddr("dstToken"),
            1 ether,
            abi.encodePacked(user),
            zk
        );
    }

    function testExecuteTransferRevertsInvalidSignatureLength() external {
        bytes32 orderId = keccak256("order-invalid-sig-len");
        _setSubmittedOrder(orderId, 137, 1 ether);

        bytes32[] memory publicInputs = new bytes32[](4);
        publicInputs[0] = orderId;
        publicInputs[1] = keccak256(abi.encodePacked(user));
        publicInputs[2] = bytes32(uint256(1 ether));
        publicInputs[3] = keccak256("nullifier-sig-len");

        IBridge.ZkExecution memory zk = IBridge.ZkExecution({
            nullifier: publicInputs[3],
            zkProof: hex"1234",
            publicInputs: publicInputs,
            solverSignature: hex"1234"
        });

        vm.prank(solver);
        vm.expectRevert(ErrInvalidSolverSignature.selector);
        bridge.executeTransfer(
            orderId,
            makeAddr("dstTokenSigLen"),
            1 ether,
            abi.encodePacked(user),
            zk
        );
    }

    function testExecuteTransferPreventsReplayByNullifier() external {
        bytes32 orderId = keccak256("order-replay");
        address dstToken = makeAddr("dstToken");
        uint256 dstAmount = 1 ether;
        bytes32 nullifier = keccak256("nullifier-replay");
        _setSubmittedOrder(orderId, 137, dstAmount);

        IBridge.ZkExecution memory zk = _signedExecution(
            orderId,
            dstToken,
            dstAmount,
            user,
            nullifier
        );

        vm.prank(solver);
        bridge.executeTransfer(
            orderId,
            dstToken,
            dstAmount,
            abi.encodePacked(user),
            zk
        );

        bytes32 otherOrderId = keccak256("order-replay-2");
        _setSubmittedOrder(otherOrderId, 137, dstAmount);

        IBridge.ZkExecution memory replayZk = _signedExecution(
            otherOrderId,
            dstToken,
            dstAmount,
            user,
            nullifier
        );

        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrNullifierUsed.selector,
                replayZk.nullifier
            )
        );
        bridge.executeTransfer(
            otherOrderId,
            dstToken,
            dstAmount,
            abi.encodePacked(user),
            replayZk
        );
    }

    function testExecuteTransferRevertsWhenCallerNotSolver() external {
        bytes32 orderId = keccak256("order-not-solver");
        _setSubmittedOrder(orderId, 137, 1 ether);

        IBridge.ZkExecution memory zk = _signedExecution(
            orderId,
            makeAddr("dstTokenNotSolver"),
            1 ether,
            user,
            keccak256("nullifier-not-solver")
        );

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ErrNotSolver.selector, user));
        bridge.executeTransfer(
            orderId,
            makeAddr("dstTokenNotSolver"),
            1 ether,
            abi.encodePacked(user),
            zk
        );
    }

    function testExecuteTransferRevertsWhenSolverInactive() external {
        bytes32 orderId = keccak256("order-solver-inactive");
        _setSubmittedOrder(orderId, 137, 1 ether);

        IBridge.SolverInfo memory info = IBridge.SolverInfo({
            stake: 1 ether,
            active: false,
            joinTime: block.timestamp,
            rewardRecipient: solverReward
        });
        bridge.setSolverForTest(solver, info, true);

        IBridge.ZkExecution memory zk = _signedExecution(
            orderId,
            makeAddr("dstTokenInactive"),
            1 ether,
            user,
            keccak256("nullifier-inactive")
        );

        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(ErrSolverInactive.selector, solver)
        );
        bridge.executeTransfer(
            orderId,
            makeAddr("dstTokenInactive"),
            1 ether,
            abi.encodePacked(user),
            zk
        );
    }

    function testExecuteTransferRevertsInvalidAmount() external {
        bytes32 orderId = keccak256("order-invalid-amount");
        _setSubmittedOrder(orderId, 137, 1 ether);

        IBridge.ZkExecution memory zk = _signedExecution(
            orderId,
            makeAddr("dstTokenZero"),
            0,
            user,
            keccak256("nullifier-zero-amount")
        );

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(ErrInvalidAmount.selector, 0));
        bridge.executeTransfer(
            orderId,
            makeAddr("dstTokenZero"),
            0,
            abi.encodePacked(user),
            zk
        );
    }

    function testExecuteTransferRevertsInvalidRecipient() external {
        bytes32 orderId = keccak256("order-invalid-recipient");
        _setSubmittedOrder(orderId, 137, 1 ether);

        IBridge.ZkExecution memory zk = _signedExecution(
            orderId,
            makeAddr("dstTokenRecipient"),
            1 ether,
            user,
            keccak256("nullifier-invalid-recipient")
        );

        vm.prank(solver);
        vm.expectRevert(ErrZeroRecipientBytes.selector);
        bridge.executeTransfer(
            orderId,
            makeAddr("dstTokenRecipient"),
            1 ether,
            hex"0000000000000000000000000000000000000000",
            zk
        );
    }

    function testExecuteTransferSupports32ByteRecipient() external {
        bytes32 orderId = keccak256("order-v2-sol");
        _setSubmittedOrder(orderId, 137, 1 ether);

        bytes
            memory dstRecipient = hex"2222222222222222222222222222222222222222222222222222222222222222";
        bytes32 nullifier = keccak256("nullifier-v2-sol");

        IBridge.ZkExecution memory zk = _signedExecutionV2(
            orderId,
            makeAddr("dstTokenV2"),
            1 ether,
            dstRecipient,
            nullifier
        );

        vm.prank(solver);
        bridge.executeTransfer(
            orderId,
            makeAddr("dstTokenV2"),
            1 ether,
            dstRecipient,
            zk
        );

        bytes memory storedRecipient = bridge.getOrderRecipientBytes(orderId);
        IBridge.Order memory order = bridge.getOrder(orderId);
        assertEq(storedRecipient, dstRecipient);
        assertEq(uint256(order.status), uint256(IBridge.OrderStatus.Executed));
    }

    function testExecuteTransferBySolverContractAfterSwapToRecipient() external {
        bytes32 orderId = keccak256("order-contract-solver");
        uint256 dstAmount = 1 ether;
        address recipient = makeAddr("contract-solver-recipient");
        bytes memory recipientBytes = abi.encodePacked(recipient);

        _setSubmittedOrder(orderId, 137, dstAmount);

        ContractSolverExecutor impl = new ContractSolverExecutor();
        vm.etch(solver, address(impl).code);

        mockToken.mint(solver, dstAmount);

        IBridge.ZkExecution memory zk = _signedExecution(
            orderId,
            address(mockToken),
            dstAmount,
            recipient,
            keccak256("nullifier-contract-solver")
        );

        uint256 recipientBefore = mockToken.balanceOf(recipient);

        ContractSolverExecutor(solver).swapAndExecute(
            bridge,
            address(mockToken),
            recipient,
            dstAmount,
            orderId,
            recipientBytes,
            zk
        );

        IBridge.Order memory order = bridge.getOrder(orderId);
        assertEq(uint256(order.status), uint256(IBridge.OrderStatus.Executed));
        assertEq(order.solver, solver);
        assertEq(order.dstAmount, dstAmount);
        assertEq(mockToken.balanceOf(recipient), recipientBefore + dstAmount);
        assertEq(bridge.getOrderRecipientBytes(orderId), recipientBytes);
    }

    function testExecuteTransferRevertsExecutionReplayedDigest() external {
        bytes32 orderId = keccak256("order-digest-replayed");
        address dstToken = makeAddr("dstTokenReplayDigest");
        uint256 dstAmount = 1 ether;
        bytes32 nullifier = keccak256("nullifier-replay-digest");
        _setSubmittedOrder(orderId, 137, dstAmount);

        bytes32 digest = _executionDigest(
            orderId,
            dstToken,
            dstAmount,
            user,
            solver,
            nullifier
        );
        bridge.setUsedExecutionDigestForTest(digest, true);

        IBridge.ZkExecution memory zk = _signedExecution(
            orderId,
            dstToken,
            dstAmount,
            user,
            nullifier
        );

        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(ErrExecutionReplayed.selector, digest)
        );
        bridge.executeTransfer(
            orderId,
            dstToken,
            dstAmount,
            abi.encodePacked(user),
            zk
        );
    }

    function testExecuteTransferRevertsBadPublicInputLength() external {
        bytes32 orderId = keccak256("order-bad-input-len");
        address dstToken = makeAddr("dstTokenBadInputLen");
        uint256 dstAmount = 1 ether;
        bytes32 nullifier = keccak256("nullifier-bad-input-len");
        _setSubmittedOrder(orderId, 137, dstAmount);

        bytes32 digest = _executionDigest(
            orderId,
            dstToken,
            dstAmount,
            user,
            solver,
            nullifier
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            solverPk,
            _toEthSignedMessageHash(digest)
        );

        bytes32[] memory publicInputs = new bytes32[](3);
        publicInputs[0] = orderId;
        publicInputs[1] = bytes32(uint256(uint160(user)));
        publicInputs[2] = bytes32(dstAmount);

        IBridge.ZkExecution memory zk = IBridge.ZkExecution({
            nullifier: nullifier,
            zkProof: hex"1234",
            publicInputs: publicInputs,
            solverSignature: abi.encodePacked(r, s, v)
        });

        vm.prank(solver);
        vm.expectRevert(ErrInvalidZKProof.selector);
        bridge.executeTransfer(
            orderId,
            dstToken,
            dstAmount,
            abi.encodePacked(user),
            zk
        );
    }

    function testExecuteTransferRevertsPublicRecipientMismatch() external {
        bytes32 orderId = keccak256("order-public-recipient-mismatch");
        address dstToken = makeAddr("dstTokenRecipientMismatch");
        uint256 dstAmount = 1 ether;
        bytes32 nullifier = keccak256("nullifier-recipient-mismatch");
        _setSubmittedOrder(orderId, 137, dstAmount);

        bytes32 digest = _executionDigest(
            orderId,
            dstToken,
            dstAmount,
            user,
            solver,
            nullifier
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            solverPk,
            _toEthSignedMessageHash(digest)
        );

        bytes32[] memory publicInputs = new bytes32[](4);
        publicInputs[0] = orderId;
        publicInputs[1] = bytes32(uint256(uint160(makeAddr("otherRecipient"))));
        publicInputs[2] = bytes32(dstAmount);
        publicInputs[3] = nullifier;

        IBridge.ZkExecution memory zk = IBridge.ZkExecution({
            nullifier: nullifier,
            zkProof: hex"1234",
            publicInputs: publicInputs,
            solverSignature: abi.encodePacked(r, s, v)
        });

        vm.prank(solver);
        vm.expectRevert(ErrInvalidZKProof.selector);
        bridge.executeTransfer(
            orderId,
            dstToken,
            dstAmount,
            abi.encodePacked(user),
            zk
        );
    }

    function testExecuteTransferRevertsPublicOrderMismatch() external {
        bytes32 orderId = keccak256("order-public-order-mismatch");
        address dstToken = makeAddr("dstTokenOrderMismatch");
        uint256 dstAmount = 1 ether;
        bytes32 nullifier = keccak256("nullifier-order-mismatch");
        _setSubmittedOrder(orderId, 137, dstAmount);

        bytes32 digest = _executionDigest(
            orderId,
            dstToken,
            dstAmount,
            user,
            solver,
            nullifier
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            solverPk,
            _toEthSignedMessageHash(digest)
        );

        bytes32[] memory publicInputs = new bytes32[](4);
        publicInputs[0] = keccak256("different-order");
        publicInputs[1] = bytes32(uint256(uint160(user)));
        publicInputs[2] = bytes32(dstAmount);
        publicInputs[3] = nullifier;

        IBridge.ZkExecution memory zk = IBridge.ZkExecution({
            nullifier: nullifier,
            zkProof: hex"1234",
            publicInputs: publicInputs,
            solverSignature: abi.encodePacked(r, s, v)
        });

        vm.prank(solver);
        vm.expectRevert(ErrInvalidZKProof.selector);
        bridge.executeTransfer(
            orderId,
            dstToken,
            dstAmount,
            abi.encodePacked(user),
            zk
        );
    }

    function testExecuteTransferRevertsPublicAmountMismatch() external {
        bytes32 orderId = keccak256("order-public-amount-mismatch");
        address dstToken = makeAddr("dstTokenAmountMismatch");
        uint256 dstAmount = 1 ether;
        bytes32 nullifier = keccak256("nullifier-amount-mismatch");
        _setSubmittedOrder(orderId, 137, dstAmount);

        bytes32 digest = _executionDigest(
            orderId,
            dstToken,
            dstAmount,
            user,
            solver,
            nullifier
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            solverPk,
            _toEthSignedMessageHash(digest)
        );

        bytes32[] memory publicInputs = new bytes32[](4);
        publicInputs[0] = orderId;
        publicInputs[1] = bytes32(uint256(uint160(user)));
        publicInputs[2] = bytes32(uint256(2 ether));
        publicInputs[3] = nullifier;

        IBridge.ZkExecution memory zk = IBridge.ZkExecution({
            nullifier: nullifier,
            zkProof: hex"1234",
            publicInputs: publicInputs,
            solverSignature: abi.encodePacked(r, s, v)
        });

        vm.prank(solver);
        vm.expectRevert(ErrInvalidZKProof.selector);
        bridge.executeTransfer(
            orderId,
            dstToken,
            dstAmount,
            abi.encodePacked(user),
            zk
        );
    }

    function testExecuteTransferRevertsPublicNullifierMismatch() external {
        bytes32 orderId = keccak256("order-public-nullifier-mismatch");
        address dstToken = makeAddr("dstTokenNullifierMismatch");
        uint256 dstAmount = 1 ether;
        bytes32 nullifier = keccak256("nullifier-nullifier-mismatch");
        _setSubmittedOrder(orderId, 137, dstAmount);

        bytes32 digest = _executionDigest(
            orderId,
            dstToken,
            dstAmount,
            user,
            solver,
            nullifier
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            solverPk,
            _toEthSignedMessageHash(digest)
        );

        bytes32[] memory publicInputs = new bytes32[](4);
        publicInputs[0] = orderId;
        publicInputs[1] = bytes32(uint256(uint160(user)));
        publicInputs[2] = bytes32(dstAmount);
        publicInputs[3] = keccak256("different-nullifier");

        IBridge.ZkExecution memory zk = IBridge.ZkExecution({
            nullifier: nullifier,
            zkProof: hex"1234",
            publicInputs: publicInputs,
            solverSignature: abi.encodePacked(r, s, v)
        });

        vm.prank(solver);
        vm.expectRevert(ErrInvalidZKProof.selector);
        bridge.executeTransfer(
            orderId,
            dstToken,
            dstAmount,
            abi.encodePacked(user),
            zk
        );
    }

    function testExecuteTransferRevertsInvalidZkProof() external {
        bytes32 orderId = keccak256("order-invalid-zk-proof");
        address dstToken = makeAddr("dstTokenInvalidZk");
        uint256 dstAmount = 1 ether;
        bytes32 nullifier = keccak256("nullifier-invalid-zk");
        _setSubmittedOrder(orderId, 137, dstAmount);

        verifier.setShouldPass(false);
        IBridge.ZkExecution memory zk = _signedExecution(
            orderId,
            dstToken,
            dstAmount,
            user,
            nullifier
        );

        vm.prank(solver);
        vm.expectRevert(ErrInvalidZKProof.selector);
        bridge.executeTransfer(
            orderId,
            dstToken,
            dstAmount,
            abi.encodePacked(user),
            zk
        );
    }

    function testExecuteTransferRevertsOrderNotFound() external {
        bytes32 orderId = keccak256("order-not-found");
        address dstToken = makeAddr("dstTokenNotFound");
        uint256 dstAmount = 1 ether;
        bytes32 nullifier = keccak256("nullifier-not-found");

        IBridge.ZkExecution memory zk = _signedExecution(
            orderId,
            dstToken,
            dstAmount,
            user,
            nullifier
        );

        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(ErrOrderNotFound.selector, orderId)
        );
        bridge.executeTransfer(
            orderId,
            dstToken,
            dstAmount,
            abi.encodePacked(user),
            zk
        );
    }

    function testExecuteTransferRevertsWrongChain() external {
        bytes32 orderId = keccak256("order-wrong-chain");
        _setSubmittedOrder(orderId, 10, 1 ether);

        IBridge.ZkExecution memory zk = _signedExecution(
            orderId,
            makeAddr("dstTokenWrongChain"),
            1 ether,
            user,
            keccak256("nullifier-wrong-chain")
        );

        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(ErrWrongChain.selector, 10, 137)
        );
        bridge.executeTransfer(
            orderId,
            makeAddr("dstTokenWrongChain"),
            1 ether,
            abi.encodePacked(user),
            zk
        );
    }

    function testExecuteTransferRevertsInsufficientOutput() external {
        bytes32 orderId = keccak256("order-insufficient-output");
        _setSubmittedOrder(orderId, 137, 2 ether);

        IBridge.ZkExecution memory zk = _signedExecution(
            orderId,
            makeAddr("dstTokenLowOut"),
            1 ether,
            user,
            keccak256("nullifier-low-output")
        );

        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrInsufficientOutput.selector,
                1 ether,
                2 ether
            )
        );
        bridge.executeTransfer(
            orderId,
            makeAddr("dstTokenLowOut"),
            1 ether,
            abi.encodePacked(user),
            zk
        );
    }

    function testValidatorRejectGetsSlashed() external {
        bytes32 orderId = keccak256("order-slash");
        _setExecutedOrder(orderId, 137, 1 ether);

        (uint256 beforeStake, , , ) = bridge.validators(validator1);

        vm.prank(validator1);
        bridge.approveOrderSettlement(orderId, false);

        (uint256 afterStake, , , ) = bridge.validators(validator1);
        assertLt(afterStake, beforeStake);
    }

    function testApproveOrderSettlementRevertsNotValidator() external {
        bytes32 orderId = keccak256("order-approve-not-validator");
        _setExecutedOrder(orderId, 137, 1 ether);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ErrNotValidator.selector, user));
        bridge.approveOrderSettlement(orderId, true);
    }

    function testApproveOrderSettlementRevertsValidatorInactive() external {
        bytes32 orderId = keccak256("order-approve-inactive");
        _setExecutedOrder(orderId, 137, 1 ether);

        bridge.slashValidator(validator1, 1 ether);

        vm.prank(validator1);
        vm.expectRevert(
            abi.encodeWithSelector(ErrValidatorInactive.selector, validator1)
        );
        bridge.approveOrderSettlement(orderId, true);
    }

    function testApproveOrderSettlementRevertsAlreadyApproved() external {
        bytes32 orderId = keccak256("order-already-approved");
        _setExecutedOrder(orderId, 137, 1 ether);

        vm.prank(validator1);
        bridge.approveOrderSettlement(orderId, true);

        vm.prank(validator1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrAlreadyApproved.selector,
                validator1,
                orderId
            )
        );
        bridge.approveOrderSettlement(orderId, true);
    }

    function testSlashValidatorRevertsUnauthorized() external {
        vm.prank(user);
        vm.expectRevert();
        bridge.slashValidator(validator1, 1);
    }

    function testSlashValidatorRevertsExceedsStake() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrSlashExceedsStake.selector,
                2 ether,
                1 ether
            )
        );
        bridge.slashValidator(validator1, 2 ether);
    }

    function testSlashValidatorSuccess() external {
        (uint256 beforeStake, , , ) = bridge.validators(validator1);
        bridge.slashValidator(validator1, 0.1 ether);
        (uint256 afterStake, , , uint256 slashCount) = bridge.validators(
            validator1
        );

        assertEq(afterStake, beforeStake - 0.1 ether);
        assertEq(slashCount, 1);
    }

    function testApproveOrderSettlementRevertsOrderNotFound() external {
        vm.prank(validator1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrOrderNotFound.selector,
                keccak256("missing-order")
            )
        );
        bridge.approveOrderSettlement(keccak256("missing-order"), true);
    }

    function testApproveOrderSettlementRevertsInvalidOrderStatus() external {
        bytes32 orderId = keccak256("order-status-submitted");
        _setSubmittedOrder(orderId, 137, 1 ether);

        vm.prank(validator1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrInvalidOrderStatus.selector,
                uint8(IBridge.OrderStatus.Submitted)
            )
        );
        bridge.approveOrderSettlement(orderId, true);
    }

    function testSettleRequiresChallengeWindow() external {
        bridge.setRequiredValidators(1);

        bytes32 orderId = keccak256("order-window");
        _setExecutedOrder(orderId, 137, 1 ether);

        vm.deal(address(bridge), 1 ether);

        vm.prank(validator1);
        bridge.approveOrderSettlement(orderId, true);

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrChallengeWindowOpen.selector,
                block.timestamp + 600
            )
        );
        bridge.settleOrder(orderId);

        vm.warp(block.timestamp + CHALLENGE_WINDOW + 1);
        bridge.settleOrder(orderId);

        IBridge.Order memory order = bridge.getOrder(orderId);
        assertEq(uint256(order.status), uint256(IBridge.OrderStatus.Settled));
    }

    function testQueryFunctionsCoverage() external {
        bridge.setRequiredValidators(1);

        vm.deal(user, 10 ether);
        uint256 srcAmount = 1 ether;
        uint256 total = srcAmount + ((srcAmount * 30) / 10000);

        vm.prank(user);
        bytes32 submittedOrderId = bridge.submitOrder{value: total}(
            NATIVE_TOKEN_ADDRESS,
            srcAmount,
            10,
            abi.encodePacked("Q"),
            5e17,
            abi.encodePacked(user),
            block.timestamp + 1 days
        );

        bytes32[] memory userOrders = bridge.getUserOrders(user);
        assertTrue(userOrders.length > 0);
        assertEq(userOrders[userOrders.length - 1], submittedOrderId);

        bytes32 executedOrderId = keccak256("query-executed-order");
        _setExecutedOrder(executedOrderId, 137, 1 ether);

        vm.prank(validator1);
        bridge.approveOrderSettlement(executedOrderId, true);

        address[] memory approvals = bridge.getOrderApprovals(executedOrderId);
        assertEq(approvals.length, 1);
        assertEq(approvals[0], validator1);

        uint256 validatorCount = bridge.getValidatorCount();
        uint256 solverCount = bridge.getSolverCount();
        bool completed = bridge.isOrderCompleted(executedOrderId);

        assertEq(validatorCount, 2);
        assertEq(solverCount, 1);
        assertTrue(completed);
    }

    function testRefundOrderByUserBeforeDeadline() external {
        vm.deal(user, 10 ether);

        uint256 srcAmount = 1 ether;
        uint256 fee = (srcAmount * 30) / 10000;
        uint256 total = srcAmount + fee;

        vm.prank(user);
        bytes32 orderId = bridge.submitOrder{value: total}(
            NATIVE_TOKEN_ADDRESS,
            srcAmount,
            10,
            abi.encodePacked("USDC"),
            5e17,
            abi.encodePacked(user),
            block.timestamp + 1 days
        );

        uint256 before = user.balance;
        vm.prank(user);
        bridge.refundOrder(orderId);

        IBridge.Order memory order = bridge.getOrder(orderId);
        assertEq(uint256(order.status), uint256(IBridge.OrderStatus.Refunded));
        assertEq(user.balance, before + total);
    }

    function testRefundOrderRevertsCannotRefundYetForNonUser() external {
        vm.deal(user, 10 ether);

        uint256 srcAmount = 1 ether;
        uint256 fee = (srcAmount * 30) / 10000;
        uint256 total = srcAmount + fee;

        vm.prank(user);
        bytes32 orderId = bridge.submitOrder{value: total}(
            NATIVE_TOKEN_ADDRESS,
            srcAmount,
            10,
            abi.encodePacked("USDC"),
            5e17,
            abi.encodePacked(user),
            block.timestamp + 1 days
        );

        vm.prank(solver);
        uint256 deadline = block.timestamp + 1 days;
        vm.expectRevert(
            abi.encodeWithSelector(ErrCannotRefundYet.selector, deadline)
        );
        bridge.refundOrder(orderId);
    }

    function testRefundOrderRevertsCannotRefundForCompletedOrder() external {
        bridge.setRequiredValidators(1);
        bytes32 orderId = keccak256("order-refund-completed");
        _setExecutedOrder(orderId, 137, 1 ether);

        vm.prank(validator1);
        bridge.approveOrderSettlement(orderId, true);

        vm.expectRevert(ErrCannotRefund.selector);
        bridge.refundOrder(orderId);
    }

    function testChallengeSettlementRevertsWithoutRejectVotes() external {
        bytes32 orderId = keccak256("order-no-reject");
        _setExecutedOrder(orderId, 137, 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(ErrNoRejectVotes.selector, orderId)
        );
        bridge.challengeSettlement(orderId, validator1);
    }

    function testChallengeSettlementSlashesValidatorAfterReject() external {
        bytes32 orderId = keccak256("order-challenge-slash");
        _setExecutedOrder(orderId, 137, 1 ether);

        vm.prank(validator1);
        bridge.approveOrderSettlement(orderId, false);

        (uint256 beforeStake, , , ) = bridge.validators(validator1);
        bridge.challengeSettlement(orderId, validator1);
        (uint256 afterStake, , , ) = bridge.validators(validator1);

        assertLt(afterStake, beforeStake);
    }

    function testChallengeSettlementRevertsWhenValidatorDidNotVote() external {
        bytes32 orderId = keccak256("order-no-vote");
        _setExecutedOrder(orderId, 137, 1 ether);

        vm.prank(validator1);
        bridge.approveOrderSettlement(orderId, false);

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrValidatorDidNotVote.selector,
                validator2,
                orderId
            )
        );
        bridge.challengeSettlement(orderId, validator2);
    }

    function testChallengeSettlementRevertsNotValidator() external {
        bytes32 orderId = keccak256("order-challenge-not-validator");
        _setExecutedOrder(orderId, 137, 1 ether);

        vm.prank(validator1);
        bridge.approveOrderSettlement(orderId, false);

        vm.expectRevert(abi.encodeWithSelector(ErrNotValidator.selector, user));
        bridge.challengeSettlement(orderId, user);
    }

    function testSettleOrderRevertsCannotSettleWhenNotCompleted() external {
        bytes32 orderId = keccak256("order-not-completed");
        _setExecutedOrder(orderId, 137, 1 ether);

        vm.expectRevert(ErrCannotSettle.selector);
        bridge.settleOrder(orderId);
    }

    function testSettleOrderRevertsAlreadySettled() external {
        bytes32 orderId = keccak256("order-already-settled");
        _setExecutedOrder(orderId, 137, 1 ether);

        IBridge.Order memory order = bridge.getOrder(orderId);
        order.status = IBridge.OrderStatus.Completed;
        order.settled = true;
        bridge.setOrderForTest(orderId, order);

        vm.expectRevert(
            abi.encodeWithSelector(ErrAlreadySettled.selector, orderId)
        );
        bridge.settleOrder(orderId);
    }

    function testSettleOrderRevertsOrderNotFound() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrOrderNotFound.selector,
                keccak256("missing-settle-order")
            )
        );
        bridge.settleOrder(keccak256("missing-settle-order"));
    }

    function testPauseThenSubmitRevertsUntilUnpause() external {
        uint256 srcAmount = 1 ether;
        uint256 total = srcAmount + ((srcAmount * 30) / 10000);

        bridge.pause();

        vm.deal(user, 10 ether);
        vm.prank(user);
        vm.expectRevert();
        bridge.submitOrder{value: total}(
            NATIVE_TOKEN_ADDRESS,
            srcAmount,
            10,
            abi.encodePacked("USDC"),
            5e17,
            abi.encodePacked(user),
            block.timestamp + 1 days
        );

        bridge.unpause();

        vm.prank(user);
        bytes32 orderId = bridge.submitOrder{value: total}(
            NATIVE_TOKEN_ADDRESS,
            srcAmount,
            10,
            abi.encodePacked("USDC"),
            5e17,
            abi.encodePacked(user),
            block.timestamp + 1 days
        );
        assertTrue(orderId != bytes32(0));
    }

    function testPauseRevertsForUnauthorizedCaller() external {
        vm.prank(user);
        vm.expectRevert(ErrUnauthorized.selector);
        bridge.pause();
    }

    function testPauseAndUnpauseWorkForAdminRole() external {
        bridge.grantRole(ADMIN_ROLE, validator1);

        vm.prank(validator1);
        bridge.pause();

        vm.prank(validator1);
        bridge.unpause();
    }

    function testRegisterSolverRevertsInsufficientStake() external {
        address candidate = makeAddr("solver-insufficient");
        vm.deal(candidate, 1 ether);

        vm.prank(candidate);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrInsufficientStake.selector,
                0.5 ether,
                bridge.minSolverStake()
            )
        );
        bridge.registerSolver{value: 0.5 ether}(candidate);
    }

    function testRegisterSolverRevertsAlreadyRegistered() external {
        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(ErrAlreadyRegistered.selector, solver)
        );
        bridge.registerSolver{value: 1 ether}(solverReward);
    }

    function testRegisterSolverRevertsInvalidRecipient() external {
        address candidate = makeAddr("solver-invalid-recipient");
        vm.deal(candidate, 2 ether);

        vm.prank(candidate);
        vm.expectRevert(
            abi.encodeWithSelector(ErrInvalidAddress.selector, address(0))
        );
        bridge.registerSolver{value: 1 ether}(address(0));
    }

    function testUnregisterSolverSuccess() external {
        address candidate = makeAddr("solver-unregister");
        address rewardRecipient = makeAddr("solver-unregister-reward");
        vm.deal(candidate, 5 ether);

        vm.prank(candidate);
        bridge.registerSolver{value: 1 ether}(rewardRecipient);

        uint256 before = candidate.balance;
        vm.prank(candidate);
        bridge.unregisterSolver();

        assertEq(candidate.balance, before + 1 ether);
        assertFalse(bridge.isSolver(candidate));
    }

    function testUnregisterSolverRevertsNotSolver() external {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ErrNotSolver.selector, user));
        bridge.unregisterSolver();
    }

    function testUnregisterSolverRevertsAlreadyInactive() external {
        IBridge.SolverInfo memory info = IBridge.SolverInfo({
            stake: 1 ether,
            active: false,
            joinTime: block.timestamp,
            rewardRecipient: solverReward
        });
        bridge.setSolverForTest(solver, info, true);

        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(ErrAlreadyInactive.selector, solver)
        );
        bridge.unregisterSolver();
    }

    function testSetSolverRewardRecipientPaths() external {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ErrNotSolver.selector, user));
        bridge.setSolverRewardRecipient(makeAddr("r1"));

        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(ErrInvalidAddress.selector, address(0))
        );
        bridge.setSolverRewardRecipient(address(0));

        address newRecipient = makeAddr("solver-new-recipient");
        vm.prank(solver);
        bridge.setSolverRewardRecipient(newRecipient);

        (, , , address recordedRecipient) = bridge.solvers(solver);
        assertEq(recordedRecipient, newRecipient);
    }

    function testAdminSettersRevertInvalidValues() external {
        vm.expectRevert(abi.encodeWithSelector(ErrFeeTooHigh.selector, 10001));
        bridge.setProtocolFee(10001);

        vm.expectRevert(
            abi.encodeWithSelector(ErrPenaltyTooHigh.selector, 5001)
        );
        bridge.setValidatorPenaltyBps(5001);

        vm.expectRevert(
            abi.encodeWithSelector(ErrInvalidValidatorCount.selector, 0)
        );
        bridge.setRequiredValidators(0);
    }

    function testSetRequiredValidatorsRevertsAboveTotalValidators() external {
        vm.expectRevert(
            abi.encodeWithSelector(ErrInvalidValidatorCount.selector, 3)
        );
        bridge.setRequiredValidators(3);
    }

    function testSetZkVerifierRevertsZeroAddress() external {
        vm.expectRevert(
            abi.encodeWithSelector(ErrInvalidAddress.selector, address(0))
        );
        bridge.setZkVerifier(address(0));
    }

    function testRefundOrderRevertsOrderNotFound() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrOrderNotFound.selector,
                keccak256("missing-refund-order")
            )
        );
        bridge.refundOrder(keccak256("missing-refund-order"));
    }

    function testEmergencyWithdrawNativeSuccess() external {
        address recipient = makeAddr("withdrawRecipient");
        vm.deal(address(bridge), 5 ether);

        bridge.emergencyWithdraw(NATIVE_TOKEN_ADDRESS, 1 ether, recipient);
        assertEq(recipient.balance, 1 ether);
    }

    function testEmergencyWithdrawERC20Success() external {
        address recipient = makeAddr("withdrawRecipientErc20");
        mockToken.mint(address(bridge), 10 ether);

        bridge.emergencyWithdraw(address(mockToken), 2 ether, recipient);
        assertEq(mockToken.balanceOf(recipient), 2 ether);
    }

    function testEmergencyWithdrawRevertsInvalidRecipient() external {
        vm.expectRevert(
            abi.encodeWithSelector(ErrInvalidAddress.selector, address(0))
        );
        bridge.emergencyWithdraw(NATIVE_TOKEN_ADDRESS, 1 ether, address(0));
    }

    function testEmergencyWithdrawRevertsInvalidAmount() external {
        vm.expectRevert(abi.encodeWithSelector(ErrInvalidAmount.selector, 0));
        bridge.emergencyWithdraw(NATIVE_TOKEN_ADDRESS, 0, user);
    }

    function testEmergencyWithdrawRevertsInsufficientBalance() external {
        uint256 currentBalance = address(bridge).balance;
        uint256 requestAmount = currentBalance + 1 ether;

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrInsufficientBalance.selector,
                NATIVE_TOKEN_ADDRESS,
                requestAmount,
                currentBalance
            )
        );
        bridge.emergencyWithdraw(NATIVE_TOKEN_ADDRESS, requestAmount, user);
    }

    function testEmergencyWithdrawRevertsUnauthorizedCaller() external {
        vm.prank(user);
        vm.expectRevert(ErrUnauthorized.selector);
        bridge.emergencyWithdraw(NATIVE_TOKEN_ADDRESS, 1 ether, user);
    }

    function testEmergencyWithdrawRevertsNativeTransferFailure() external {
        RevertingReceiver receiver = new RevertingReceiver();
        vm.deal(address(bridge), 2 ether);

        vm.expectRevert(ErrTransferFailed.selector);
        bridge.emergencyWithdraw(
            NATIVE_TOKEN_ADDRESS,
            1 ether,
            address(receiver)
        );
    }

    function testEmergencyWithdrawRevertsErc20TransferFailure() external {
        falseToken.mint(address(bridge), 2 ether);

        vm.expectRevert(ErrTransferFailed.selector);
        bridge.emergencyWithdraw(address(falseToken), 1 ether, user);
    }

    function testHashLibDigestMatchesKeccakEncode() external view {
        uint256 srcChainId = 137;
        uint256 id = 42;
        address token = address(mockToken);
        uint256 amount = 123456;
        address recipient = user;
        bytes32 solverId = keccak256("solver-id");

        bytes32 viaLib = hashHarness.hashViaLib(
            srcChainId,
            id,
            token,
            amount,
            recipient,
            solverId
        );

        bytes32 expected = keccak256(
            abi.encode(srcChainId, id, token, amount, recipient, solverId)
        );

        assertEq(viaLib, expected);
    }

    function testSignatureLibRecoverSupportsNormalizedV() external view {
        bytes32 digest = keccak256("sig-normalized-v");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            solverPk,
            _toEthSignedMessageHash(digest)
        );

        bytes memory sig = abi.encodePacked(r, s, v);
        sig[64] = bytes1(uint8(v - 27));

        address recovered = libHarness.recover(digest, sig);
        assertEq(recovered, solver);
    }

    function testSignatureLibRecoverReturnsZeroForInvalidV() external view {
        bytes32 digest = keccak256("sig-invalid-v");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            solverPk,
            _toEthSignedMessageHash(digest)
        );

        bytes memory sig = abi.encodePacked(r, s, v);
        sig[64] = bytes1(uint8(29));

        address recovered = libHarness.recover(digest, sig);
        assertEq(recovered, address(0));
    }

    function testValidatorLibBranches() external view {
        uint256 capped = libHarness.slashAmount(10 ether, 15 ether);
        uint256 normal = libHarness.slashAmount(10 ether, 2 ether);
        bool deactivated = libHarness.deactivate(1 ether, 2 ether);
        bool active = libHarness.deactivate(2 ether, 2 ether);

        assertEq(capped, 10 ether);
        assertEq(normal, 2 ether);
        assertTrue(deactivated);
        assertFalse(active);
    }

    function testUpgradeToNewImplementation() external {
        BridgeHarness newImpl = new BridgeHarness();

        bridge.upgradeToAndCall(address(newImpl), "");

        assertEq(
            address(bridge),
            address(bridge),
            "Proxy address should remain same"
        );
    }

    function testUpgradeRevertsUnauthorized() external {
        BridgeHarness newImpl = new BridgeHarness();

        vm.prank(user);
        vm.expectRevert(ErrUnauthorized.selector);
        bridge.upgradeToAndCall(address(newImpl), "");
    }

    function testEmergencyWithdrawERC20InsufficientBalance() external {
        mockToken.mint(address(bridge), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrInsufficientBalance.selector,
                address(mockToken),
                2 ether,
                1 ether
            )
        );
        bridge.emergencyWithdraw(address(mockToken), 2 ether, user);
    }

    function testUnauthorizedCallerCannotPause() external {
        UnauthorizedCaller caller = new UnauthorizedCaller();
        bool success = caller.attemptPause(address(bridge));
        assertFalse(success, "Unauthorized caller should not be able to pause");
    }

    function testUnauthorizedCallerCannotUpgrade() external {
        UnauthorizedCaller caller = new UnauthorizedCaller();
        BridgeHarness newImpl = new BridgeHarness();
        bool success = caller.attemptUpgrade(address(bridge), address(newImpl));
        assertFalse(
            success,
            "Unauthorized caller should not be able to upgrade"
        );
    }

    function testOwnerCanPauseAndUnpause() external {
        assertFalse(bridge.paused(), "Should not be paused initially");

        bridge.pause();
        assertTrue(bridge.paused(), "Should be paused after owner pauses");

        bridge.unpause();
        assertFalse(
            bridge.paused(),
            "Should not be paused after owner unpauses"
        );
    }

    function testAdminRoleCanUnpauseAfterOwnerPause() external {
        bridge.grantRole(ADMIN_ROLE, validator1);

        bridge.pause();
        assertTrue(bridge.paused());

        vm.prank(validator1);
        bridge.unpause();
        assertFalse(bridge.paused());
    }

    function testNonAdminCannotUnpause() external {
        bridge.pause();

        vm.prank(user);
        vm.expectRevert(ErrUnauthorized.selector);
        bridge.unpause();
    }

    function _setSubmittedOrder(
        bytes32 orderId,
        uint256 dstChainId,
        uint256 minDstAmount
    ) internal {
        IBridge.Order memory order;
        order.user = user;
        order.srcChainId = 10;
        order.srcToken = NATIVE_TOKEN_ADDRESS;
        order.srcAmount = 1 ether;
        order.srcAmountWithFee = 1 ether;
        order.dstChainId = dstChainId;
        order.dstToken = abi.encodePacked("TOKEN");
        order.minDstAmount = minDstAmount;
        order.recipient = user;
        order.deadline = block.timestamp + 1 days;
        order.nonce = 1;
        order.status = IBridge.OrderStatus.Submitted;
        bridge.setOrderForTest(orderId, order);
    }

    function _setExecutedOrder(
        bytes32 orderId,
        uint256 dstChainId,
        uint256 dstAmount
    ) internal {
        _setSubmittedOrder(orderId, dstChainId, dstAmount);
        IBridge.Order memory order = bridge.getOrder(orderId);
        order.solver = solver;
        order.executionTime = block.timestamp;
        order.dstTokenAddress = makeAddr("dstTokenExecuted");
        order.dstAmount = dstAmount;
        order.executionProof = keccak256("proof");
        order.status = IBridge.OrderStatus.Executed;
        bridge.setOrderForTest(orderId, order);
    }

    function _signedExecution(
        bytes32 orderId,
        address dstToken,
        uint256 dstAmount,
        address dstRecipient,
        bytes32 nullifier
    ) internal view returns (IBridge.ZkExecution memory zk) {
        bytes32 digest = _executionDigest(
            orderId,
            dstToken,
            dstAmount,
            dstRecipient,
            solver,
            nullifier
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            solverPk,
            _toEthSignedMessageHash(digest)
        );

        zk = _buildZkExecution(
            orderId,
            dstRecipient,
            dstAmount,
            nullifier,
            abi.encodePacked(r, s, v)
        );
    }

    function _signedExecutionV2(
        bytes32 orderId,
        address dstToken,
        uint256 dstAmount,
        bytes memory dstRecipient,
        bytes32 nullifier
    ) internal view returns (IBridge.ZkExecution memory zk) {
        bytes32 digest = _executionDigestV2(
            orderId,
            dstToken,
            dstAmount,
            dstRecipient,
            solver,
            nullifier
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            solverPk,
            _toEthSignedMessageHash(digest)
        );

        zk = _buildZkExecutionV2(
            orderId,
            dstRecipient,
            dstAmount,
            nullifier,
            abi.encodePacked(r, s, v)
        );
    }

    function _buildZkExecution(
        bytes32 orderId,
        address dstRecipient,
        uint256 dstAmount,
        bytes32 nullifier,
        bytes memory sig
    ) internal pure returns (IBridge.ZkExecution memory zk) {
        bytes32[] memory publicInputs = new bytes32[](4);
        publicInputs[0] = orderId;
        publicInputs[1] = keccak256(abi.encodePacked(dstRecipient));
        publicInputs[2] = bytes32(dstAmount);
        publicInputs[3] = nullifier;

        zk = IBridge.ZkExecution({
            nullifier: nullifier,
            zkProof: hex"1234",
            publicInputs: publicInputs,
            solverSignature: sig
        });
    }

    function _buildZkExecutionV2(
        bytes32 orderId,
        bytes memory dstRecipient,
        uint256 dstAmount,
        bytes32 nullifier,
        bytes memory sig
    ) internal pure returns (IBridge.ZkExecution memory zk) {
        bytes32[] memory publicInputs = new bytes32[](4);
        publicInputs[0] = orderId;
        publicInputs[1] = keccak256(dstRecipient);
        publicInputs[2] = bytes32(dstAmount);
        publicInputs[3] = nullifier;

        zk = IBridge.ZkExecution({
            nullifier: nullifier,
            zkProof: hex"1234",
            publicInputs: publicInputs,
            solverSignature: sig
        });
    }

    function _executionDigest(
        bytes32 orderId,
        address dstToken,
        uint256 dstAmount,
        address dstRecipient,
        address solverAddr,
        bytes32 nullifier
    ) internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    address(bridge),
                    block.chainid,
                    orderId,
                    dstToken,
                    dstAmount,
                    abi.encodePacked(dstRecipient),
                    solverAddr,
                    nullifier
                )
            );
    }

    function _executionDigestV2(
        bytes32 orderId,
        address dstToken,
        uint256 dstAmount,
        bytes memory dstRecipient,
        address solverAddr,
        bytes32 nullifier
    ) internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    address(bridge),
                    block.chainid,
                    orderId,
                    dstToken,
                    dstAmount,
                    dstRecipient,
                    solverAddr,
                    nullifier
                )
            );
    }

    function _toEthSignedMessageHash(
        bytes32 digest
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked("\x19Ethereum Signed Message:\n32", digest)
            );
    }
}
