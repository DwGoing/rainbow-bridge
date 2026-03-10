# Rainbow Bridge - 跨链桥协议

## 项目概述

Rainbow Bridge 是一个基于**零知识证明（ZK）** 技术的去中心化跨链桥协议，提供安全、高效的资产跨链转移解决方案。

## 核心设计

### 1. 系统架构

Rainbow Bridge 采用**三角色模型**：
- **用户（User）**：在源链发起跨链订单
- **求解器（Solver）**：监听订单并在目标链执行转账
- **验证器（Validator）**：验证订单完成事件并释放资金

### 2. 跨链流程

#### Phase 1: 用户在源链发起订单
```
User -> Source Chain Contract
├─ Lock Assets（锁定资产）
├─ Create Order（创建订单）
│  ├─ From Token
│  ├─ To Token
│  ├─ Amount
│  ├─ Destination Chain
│  └─ Recipient Address
└─ Emit Order Event
```

#### Phase 2: Solver 监听并中继转账
```
Solver (Off-chain Monitor)
├─ Listen to Source Chain Events
├─ Extract Order Details
├─ Execute Transfer on Destination Chain
│  ├─ Call Destination Contract
│  ├─ Transfer Assets to Recipient
│  └─ Emit Completion Event with Proof
└─ Report Status
```

#### Phase 3: Validator 验证并释放资金
```
Multiple Validators (Multi-node Verification)
├─ Monitor Destination Chain Events
├─ Collect Completion Proofs
├─ Verify ZK Proofs
├─ Reach Consensus (M-of-N signature)
└─ Release Source Chain Funds
   ├─ Transfer Principal to Recipient
   └─ Transfer Solver Reward to Solver's Address
```

### 3. 零知识证明（ZK）应用

- **位置**：Solver 提交完成证明时
- **作用**：证明在目标链上确实完成了转账，无需披露具体交易细节
- **验证**：Validator 节点聚合验证，确保转账真实性

### 4. 关键特性

| 特性 | 描述 |
|------|------|
| **去中心化** | 多个 Validator 节点共同验证，无单点故障 |
| **隐私性** | 基于 ZK 证明，交易细节对链外保密 |
| **原子性** | 源链和目标链资金同步释放或回滚 |
| **激励机制** | Solver 因转账成功获得奖励 |
| **安全性** | 多重签名确保资金安全 |

### 5. 合约模块

```
contracts/evm/src/
├── Core.sol                  # 权限、升级、暂停等基础能力
├── Bridge.sol                # 唯一核心业务合约（订单/执行/验证/结算）
├── interfaces/IBridge.sol    # Bridge 对外接口
├── Constant.sol              # 常量定义
└── Error.sol                 # 自定义错误定义
```

说明：当前 EVM 设计采用单合约架构，旧的 EndPoint/Relay 逻辑已合并到 `Bridge.sol`。

### 6. 交互流程图

```
┌─────────────────────────────────────────────────────────────┐
│                    SOURCE CHAIN                              │
│  ┌──────────────┐                                            │
│  │  User sends  │ Lock + Order                               │
│  │  Order       ├─────────────────────────────────┐          │
│  └──────────────┘                                 │          │
│                                                   ▼          │
│                                          ┌──────────────────┐│
│                                          │ Bridge Contract  ││
│                                          │ ├─ Order Queue   ││
│                                          │ └─ Fund Vault    ││
│                                          └──────────────────┘│
└─────────────────────────────────────────────────────────────┘
                              │
                              │ Order Event
                              ▼
         ┌────────────────────────────────────────┐
         │   SOLVER MONITORING SERVICE            │
         │   (Off-chain Relayer)                  │
         │   Listen → Extract → Execute           │
         └────────────────────────────────────────┘
                              │
                              │ Transfer on Dst Chain
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    DESTINATION CHAIN                         │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ Bridge Contract receives Solver's TX                │   │
│  │ ├─ Validate Solver                                 │   │
│  │ ├─ Transfer to Recipient                           │   │
│  │ └─ Emit Completion Event + ZK Proof                │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ Completion Proof
                              ▼
         ┌────────────────────────────────────────┐
         │   VALIDATOR NETWORK                    │
         │   (Multi-node Verification)            │
         │   ├─ Monitor Events                    │
         │   ├─ Verify ZK Proofs                  │
         │   ├─ Sign Approval (M-of-N)            │
         │   └─ Submit Consensus                  │
         └────────────────────────────────────────┘
                              │
                              │ Multi-sig on Source
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    SOURCE CHAIN                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ Release Funds to User & Solver                       │   │
│  │ ├─ Transfer Principal + Fee to User                 │   │
│  │ ├─ Transfer Reward to Solver's Recipient            │   │
│  │ └─ Mark Order Complete                              │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 7. 安全考量

- ✅ 多签验证（M-of-N Validator）
- ✅ ZK 证明的加密保障
- ✅ 重放攻击防护（Nonce + ChainID）
- ✅ 紧急提现机制（Emergency Withdraw）
- ✅ Solver 抵押机制（防恶意行为）

---

## 开发指南

### 环境要求
- Solidity ^0.8.20
- Foundry
- OpenZeppelin Contracts v5.6.1

### 编译
```bash
cd contracts/evm
forge build
```

### 测试
```bash
forge test -vvv
```

---

**最后更新**：2026年3月9日