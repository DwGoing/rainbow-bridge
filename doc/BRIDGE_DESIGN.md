# Bridge 合约设计文档

## 概述

`Bridge.sol` 是 Rainbow Bridge 在 EVM 侧的唯一核心合约，统一承载订单创建、Solver 执行回执、Validator 多节点验证、资金结算与退款流程。

本设计采用单合约状态机，避免多合约状态同步复杂度，核心目标是：
- 降低跨模块调用复杂度
- 提高跨链订单可追踪性
- 统一权限与风控边界

## 角色与职责

| 角色 | 职责 | 链上动作 |
|------|------|----------|
| User | 发起跨链订单并锁定源链资产 | `submitOrder` |
| Solver | 监听订单并在目标链完成转账 | `executeTransfer` |
| Validator | 对执行结果进行多节点签名确认 | `approveOrderSettlement` |
| Admin | 风险控制与参数治理 | `set*` / `pause` / `emergencyWithdraw` |

## 订单生命周期

```solidity
enum OrderStatus {
    None,
    Submitted,
    Executed,
    Completed,
    Settled,
    Refunded
}
```

状态流转如下：
1. `None -> Submitted`：用户提交订单并锁仓
2. `Submitted -> Executed`：Solver 提交执行证明
3. `Executed -> Completed`：Validator 达到阈值签名
4. `Completed -> Settled`：释放用户资金与 Solver 奖励
5. `Submitted/Executed -> Refunded`：超时或失败退款

## 三阶段主流程

### Phase 1: 订单创建与锁仓

函数：`submitOrder(address srcToken, uint256 srcAmount, uint256 dstChainId, bytes dstToken, uint256 minDstAmount, bytes recipient, uint256 deadline)`

逻辑：
- 校验目标链、截止时间、最小金额、目标链接收地址格式等参数
- 计算协议费：`srcAmount * protocolFeeBps / 10000`
- 锁定 `srcAmount + fee`
- 写入 `orders[orderId]`
- 事件：`OrderCreated`

### Phase 2: Solver 执行回执

函数：`executeTransfer(bytes32 orderId, address dstToken, uint256 dstAmount, bytes dstRecipient, ZKExecution zk)`

其中 `ZKExecution` 包含：
- `nullifier`：唯一防重放标识
- `zkProof`：零知识证明本体
- `publicInputs`：公开输入（至少绑定 `orderId/recipient/amount/nullifier`）
- `solverSignature`：Solver 对执行摘要的签名

逻辑：
- 校验 `msg.sender` 为活跃 Solver
- 生成执行摘要 `digest = H(contract, chainId, orderId, token, amount, recipientBytes, solver, nullifier)`
- 对 `solverSignature` 执行 `ecrecover` 验签，确保签名人就是提交者
- 校验 `usedNullifiers[nullifier] == false` 与 `usedExecutionDigests[digest] == false`
- 调用 `IZKVerifier.verify(zkProof, publicInputs)`
- 验证成功后写入执行状态并标记 nullifier/digest 已使用
- 状态置为 `Executed`
- 事件：`SolverExecutionVerified` / `OrderExecuted`

### Phase 3: 多签验证与结算

函数：
- `approveOrderSettlement(bytes32 orderId, bool approved)`
- `challengeSettlement(bytes32 orderId, address validator)`
- `settleOrder(bytes32 orderId)`

逻辑：
- Validator 对 `Executed` 订单投票
- `approved = true` 计入通过票
- `approved = false` 视为恶意拒绝（针对已 zk 验证通过的执行），立即按 `validatorPenaltyBps` 扣罚质押
- 当 `approveCount >= requiredValidators` 且 `rejectCount == 0` 时，订单进入 `Completed`
- 进入 `Completed` 后需等待 `CHALLENGE_WINDOW` 才可结算
- 执行结算：
  - 用户返还：`srcAmount - solverReward`
  - Solver 奖励：`srcAmount * 5%`
- 事件：`OrderSettlement` / `SettlementChallenged` / `OrderSettled`

## 退款路径

函数：`refundOrder(bytes32 orderId)`

触发条件：
- 订单过期（`block.timestamp > deadline`）
- 或调用者为订单用户

行为：
- 状态置为 `Refunded`
- 按锁仓金额原路退回（含协议费）
- 事件：`OrderRefunded`

## 质押与惩罚机制

### Validator
- 注册：`registerValidator()`，最低质押 `minValidatorStake`
- 注销：`unregisterValidator()`，退回质押
- 惩罚：`slashValidator(address validator, uint256 amount)`

### Solver
- 注册：`registerSolver(address rewardRecipient)`，最低质押 `minSolverStake`
- 注销：`unregisterSolver()`
- 更新奖励地址：`setSolverRewardRecipient(address)`

## 异构链接收地址规范

目标链接收地址统一使用 `bytes recipient` 表示，不再限制为 EVM `address`。

编码建议：
- EVM：20 字节原始地址（`abi.encodePacked(address)`）
- Sui：32 字节地址（去掉 `0x` 后按 hex 解析）
- Solana：32 字节公钥（base58 解码后的原始字节）

校验规则：
- `recipient.length > 0`
- 按 `dstChainId` 匹配允许长度（EVM=20，Sui=32，Solana=32）
- 不允许全 0 地址（对应链标准下的空地址）

接口策略：
- 直接将原接口的 `recipient/dstRecipient` 参数改为 `bytes`
- 对 EVM 地址使用 20 字节编码（`abi.encodePacked(address)`）
- 对 Sui/Solana 使用 32 字节原始地址字节

## 管理与应急能力

- 参数治理：
  - `setProtocolFee`
  - `setMinValidatorStake`
  - `setMinSolverStake`
  - `setRequiredValidators`
- 运行时控制：
  - `pause`
  - `unpause`
- 应急资金处置：
  - `emergencyWithdraw`

## 核心存储结构

- `mapping(bytes32 => Order) orders`
- `mapping(address => ValidatorInfo) validators`
- `mapping(address => SolverInfo) solvers`
- `mapping(bytes32 => address[]) orderApprovals`
- `mapping(bytes32 => mapping(address => bool)) hasApproved`

## 关键事件

- `OrderCreated`
- `OrderExecuted`
- `OrderSettlement`
- `OrderSettled`
- `OrderRefunded`
- `ValidatorRegistered` / `ValidatorSlashed`
- `SolverStaked` / `SolverUnstaked`
- `Withdrawn`

## 安全设计

- `nonReentrant`：关键资产路径防重入
- `whenNotPaused`：可在异常情况下快速停机
- RBAC：通过 `DEFAULT_ADMIN_ROLE` 和 `ADMIN_ROLE` 分层控制
- Solver 验签：执行摘要必须由 Solver 私钥签名
- 防重放：`nullifier` 与 `executionDigest` 双重去重
- ZK 验证：链上 `IZKVerifier` 强制校验证明与公开输入绑定
- Validator 反作恶：恶意拒绝触发质押扣罚，可通过 `challengeSettlement` 追加惩罚
- 挑战窗口：`Completed` 后必须等待 `CHALLENGE_WINDOW` 才能 `settle`
- 最小质押约束：增加作恶成本
- 多签阈值：降低单点验证风险

## 参数建议

| 参数 | 默认值 | 建议 |
|------|--------|------|
| `protocolFeeBps` | 30 (0.3%) | 建议 10-50，视流动性策略动态调整 |
| `minValidatorStake` | 100 ether | 与验证节点信誉体系绑定 |
| `minSolverStake` | 10 ether | 与执行失败惩罚策略配套 |
| `requiredValidators` | 3 | 建议 `>= 3` 且不超过活跃验证节点数 |

## 测试重点

1. 正常路径：`submit -> execute -> approve -> settle`
2. 退款路径：超时退款、执行后退款权限
3. 安全路径：重入、重复审批、重复结算
4. 参数边界：阈值变更、质押不足、地址非法
5. 资产路径：ETH/ERC20 双路径一致性

## 后续增强

1. 将 `bytes32 proof` 扩展为可验证的 ZK proof 结构并引入 verifier
2. 引入挑战窗口与异议期（fraud proof）
3. 将结算奖励从固定 5% 改为治理可配参数
4. 增加链外签名聚合提交，降低链上验证 gas

---

最后更新：2026-03-10
