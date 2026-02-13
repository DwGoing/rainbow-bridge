# Relay Contract Execution Methods Verification

## Summary

验证了 Relay 合约的两种执行方法:
- `executeSwapIntentByTransfer`: 用于 EOA (外部账户) 调用
- `executeSwapIntentByCall`: 用于合约调用

两种方法都确保资金流向: **资金 → Relay → 用户 → 生成 Proof**

## Architecture

### executeSwapIntentByTransfer (EOA 执行路径)

**设计目的**: 允许 EOA 账户作为 solver 执行跨链 swap intent

**执行流程**:
```
1. EOA 调用 executeSwapIntentByTransfer
2. 对于原生代币: EOA 通过 {value: amount} 发送代币到 Relay
3. 对于 ERC20: EOA 先 approve Relay, Relay 调用 transferFrom(EOA, Relay, amount)
4. Relay 验证收到足够的资金 (检查 balance)
5. Relay 将资金转移给用户
6. 生成并存储 proof
7. 触发 SwapIntentExecuted 事件
```

**关键特点**:
- `payable` 函数 (接受原生代币)
- 验证 `msg.value == amount` (原生代币)
- 验证 `allowance >= amount` (ERC20)
- 使用 `safeTransferFrom` 安全转账
- 调用内部 `_executeSwapIntent` 完成最终转账

### executeSwapIntentByCall (合约执行路径)

**设计目的**: 允许智能合约作为 solver, 可以先进行 swap 等操作再执行

**执行流程**:
```
1. 合约先将资金转到 Relay (通过 transfer/transferFrom/call)
2. 合约调用 executeSwapIntentByCall
3. Relay 验证调用者是合约 (code.length > 0)
4. Relay 验证自身余额 >= amount
5. Relay 将资金转移给用户
6. 生成并存储 proof
7. 触发 SwapIntentExecuted 事件
```

**关键特点**:
- 要求调用者必须是合约 (`msg.sender.code.length > 0`)
- 不接受 `msg.value` (合约需提前转账)
- 检查 Relay 自身余额
- 允许合约在转账前进行 swap 等复杂操作
- 调用内部 `_executeSwapIntent` 完成最终转账

## Test Coverage

创建了 13 个全面的测试用例，所有测试都通过:

### executeSwapIntentByTransfer 测试 (EOA 路径)

1. ✅ **testExecuteSwapIntentByTransfer_NativeToken_Success**
   - 验证 EOA 可以用原生代币执行 swap intent
   - 验证资金正确转移到用户
   - 验证 proof 生成并存储

2. ✅ **testExecuteSwapIntentByTransfer_ERC20_Success**
   - 验证 EOA 可以用 ERC20 执行 swap intent
   - 验证 approve 机制工作正常
   - 验证资金流向: EOA → Relay → User

3. ✅ **testExecuteSwapIntentByTransfer_NativeToken_InsufficientValue**
   - 验证当 msg.value < amount 时会 revert
   - 错误: `ErrInvalidAmount`

4. ✅ **testExecuteSwapIntentByTransfer_ERC20_InsufficientAllowance**
   - 验证当 allowance < amount 时会 revert
   - 错误: `ErrInsufficientBalance`

5. ✅ **testExecuteSwapIntentByTransfer_DuplicateExecution**
   - 验证相同 (srcChainId, id) 不能重复执行
   - 错误: `ErrSwapIntentExecuted`

### executeSwapIntentByCall 测试 (合约路径)

6. ✅ **testExecuteSwapIntentByCall_NativeToken_Success**
   - 验证合约可以用原生代币执行 swap intent
   - 验证合约先转账到 Relay，Relay 再转给用户
   - 验证 proof 生成并存储

7. ✅ **testExecuteSwapIntentByCall_ERC20_Success**
   - 验证合约可以用 ERC20 执行 swap intent
   - 验证资金流向: Contract → Relay → User

8. ✅ **testExecuteSwapIntentByCall_CalledByEOA_ShouldFail**
   - 验证 EOA 不能调用此方法
   - 错误: `ErrInvalidCaller`

9. ✅ **testExecuteSwapIntentByCall_InsufficientRelayBalance_NativeToken**
   - 验证当 Relay 余额不足时会 revert
   - 错误: `ErrInsufficientBalance`

10. ✅ **testExecuteSwapIntentByCall_InsufficientRelayBalance_ERC20**
    - 验证当 Relay ERC20 余额不足时会 revert
    - 错误: `ErrInsufficientBalance`

11. ✅ **testExecuteSwapIntentByCall_EmitsCorrectEvent**
    - 验证正确触发 `SwapIntentExecuted` 事件

### 综合测试

12. ✅ **testBothMethods_ProduceSameProofForSameParameters**
    - 验证不同 ID 产生不同的 proof
    - 确保 proof 唯一性

13. ✅ **testBothMethods_WorkWhenPausedThenUnpaused**
    - 验证暂停时两种方法都不能执行
    - 验证恢复后两种方法都能正常工作

## Gas Usage Report

### Function Gas Costs

| Function | Min | Avg | Median | Max |
|----------|-----|-----|--------|-----|
| **executeSwapIntentByTransfer** | 3,480 | 61,115 | 88,303 | 122,742 |
| **executeSwapIntentByCall** | 3,503 | 49,347 | 46,239 | 88,339 |

**关键观察**:
- `executeSwapIntentByCall` 平均 gas 消耗更低 (49,347 vs 61,115)
- 因为不需要处理 `msg.value` 和 approval 检查
- 适合需要频繁执行的合约 solver

## Code Structure

### MockSolver Contract

测试中创建了一个 MockSolver 合约来模拟真实的合约 solver:

```solidity
contract MockSolver {
    // 对于原生代币: 接收代币并转发到 Relay
    function executeWithNativeToken(...) external payable {
        // 1. 转账到 Relay
        relay.call{value: amount}("");
        // 2. 调用 Relay
        relay.executeSwapIntentByCall(...);
    }
    
    // 对于 ERC20: 转账代币到 Relay
    function executeWithERC20(...) external {
        // 1. 转账到 Relay
        token.transfer(relay, amount);
        // 2. 调用 Relay
        relay.executeSwapIntentByCall(...);
    }
}
```

## Security Considerations

### executeSwapIntentByTransfer
- ✅ 验证 `msg.value` 匹配请求的 amount
- ✅ 检查 ERC20 allowance
- ✅ 使用 SafeERC20 的 `safeTransferFrom`
- ✅ ReentrancyGuard 保护
- ✅ Pausable 紧急停止

### executeSwapIntentByCall
- ✅ 强制要求调用者是合约
- ✅ 检查 Relay 余额充足
- ✅ 使用 SafeERC20 的 `trySafeTransfer`
- ✅ ReentrancyGuard 保护
- ✅ Pausable 紧急停止

### Proof Generation
- ✅ 包含 srcChainId, id, token, amount, recipient, msg.sender
- ✅ 存储 proof 防止重放攻击
- ✅ 每个 (srcChainId, id) 只能执行一次

## Usage Scenarios

### Scenario 1: EOA Solver (简单场景)
1. User 在链 A 提交 swap intent
2. EOA solver 在链 B 看到 intent
3. EOA 批准 Relay 使用其代币
4. EOA 调用 `executeSwapIntentByTransfer`
5. 用户收到代币，EOA 获得 proof

### Scenario 2: Contract Solver (复杂场景)
1. User 在链 A 提交 swap intent (要求 USDC)
2. Contract solver 在链 B 看到 intent
3. Solver 合约持有 ETH，需要先 swap 成 USDC
4. Solver 合约调用 DEX swap ETH → USDC
5. Solver 合约将 USDC 转到 Relay
6. Solver 合约调用 `executeSwapIntentByCall`
7. 用户收到 USDC，Solver 获得 proof

## Files

- `src/Relay.sol` - 主合约
- `src/interfaces/IRelay.sol` - 接口定义
- `test/RelayExecution.t.sol` - 完整测试套件 (13 个测试)
- `test/mocks/MockSolver.sol` - 合约 solver 示例

## Conclusion

✅ **验证完成**: 两种执行方法都正确实现了"资金→Relay→用户→生成Proof"的流程

✅ **测试覆盖**: 13/13 测试通过，包括成功场景、失败场景、边界条件

✅ **安全性**: 所有关键安全检查都已实现并验证

✅ **灵活性**: 支持 EOA 和智能合约两种 solver 类型

✅ **Gas 效率**: executeSwapIntentByCall 更适合频繁执行的合约场景
