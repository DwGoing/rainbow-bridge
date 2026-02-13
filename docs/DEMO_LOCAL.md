# Rainbow Bridge 本地部署与完整测试流程（DEMO_LOCAL）

本文档用于在本地完成一套可复现的端到端演示：
- 运行 `solver` 与 `validator`
- 产出完整流程事件日志
- 使用 `explorer` 查看流程数据
- 切换到真实链模式（testnet/mainnet）进行 dry-run/send

## 1. 目标与范围

本地演示覆盖以下链路：
1. `Intent` 进入系统（模拟或轮询）
2. `solver` 生成结算提案
3. `validator` 生成决策与执行结果
4. `explorer` 聚合并展示同一个 `intent_hash` 的完整时间线

当前支持两类演示：
1. 离线演示（推荐先跑通）
2. 真实链演示（基于 `.env` 配置 RPC 和地址）

## 2. 前置依赖

请先确保本机可用以下工具：
1. `rustup` + `cargo`
2. `forge`（Foundry）
3. `sui` CLI
4. `jq`（用于 JSON 快速查看，非必须）

在仓库根目录执行：

```bash
make help
```

## 3. 一次性编译与测试

建议先执行全量检查，确认环境正常：

```bash
make test
```

预期：
1. Rust tests 全通过
2. Foundry tests 全通过
3. Sui Move tests 全通过

## 4. 离线完整流程演示（推荐）

该流程不依赖真实 RPC，适合本地快速验证全链路与 Explorer。

### 4.1 清理旧日志

```bash
rm -f data/flow-events.jsonl
```

### 4.2 启动 Explorer

新开终端 A：

```bash
make run-explorer
```

默认监听：
- `http://127.0.0.1:8080`

### 4.3 运行跨链流程 Demo

新开终端 B，执行任一或全部：

```bash
make demo-sui-evm
make demo-evm-sui
```

说明：
1. `demo-sui-evm` 会同时跑 `solver` + `validator`
2. `demo-evm-sui` 主要演示 `solver` 提案输出
3. 两者都会往 `FLOW_EVENT_LOG_PATH` 写事件（默认 `data/flow-events.jsonl`）

### 4.4 查看 Explorer 页面

浏览器打开：

```bash
http://127.0.0.1:8080
```

页面能力：
1. 左侧 `Flows`：按 `intent_hash` 聚合列表
2. 右侧 `Flow Detail`：完整 timeline、proposal、validator decision、execution results

### 4.5 API 验证（可选）

```bash
curl -s http://127.0.0.1:8080/api/health | jq
curl -s http://127.0.0.1:8080/api/flows | jq
```

取第一条 flow 并查看详情：

```bash
INTENT_HASH=$(curl -s http://127.0.0.1:8080/api/flows | jq -r '.[0].intent_hash')
curl -s "http://127.0.0.1:8080/api/flows/${INTENT_HASH}" | jq
```

## 5. 真实链模式（testnet/mainnet）

### 5.1 选择配置模板

测试网：

```bash
cp .env.testnet.example .env
```

主网：

```bash
cp .env.mainnet.example .env
```

或通用模板：

```bash
cp .env.example .env
```

### 5.2 必填项

请至少填写：
1. `SOLVER_SRC_RPC_URL` / `SOLVER_DST_RPC_URL`
2. `VALIDATOR_SRC_RPC_URL` / `VALIDATOR_DST_RPC_URL`
3. `*_ENDPOINT_ADDRESS`（EVM）或 `*_PACKAGE_ID` + `*_STATE_OBJECT_ID`（Sui）
4. `FLOW_EVENT_LOG_PATH`（建议保留默认）
5. `EXPLORER_BIND`（默认 `127.0.0.1:8080`）

### 5.3 启动服务

建议三个终端：

终端 A：
```bash
make run-explorer
```

终端 B：
```bash
make run-solver
```

终端 C：
```bash
make run-validator
```

### 5.4 Validator 执行模式

可用快捷命令：

```bash
make run-validator-off
make run-validator-dry
make run-validator-send
```

说明：
1. `off`：仅输出推荐交易，不执行
2. `dry-run`：模拟执行（EVM 用 gas estimate，Sui 用 `sui client call --dry-run`）
3. `send`：真实发送交易

当 `send` 且源链为 EVM 时，必须配置：

```bash
VALIDATOR_TX_PRIVATE_KEY=...
```

## 6. 关键数据文件与接口

### 6.1 事件日志文件

默认路径：

```bash
data/flow-events.jsonl
```

每一行是一条 JSON 事件，核心字段：
1. `kind`
2. `intent_hash`
3. `timestamp`
4. `source`（`solver` 或 `validator`）
5. `payload`

### 6.2 Explorer API

1. `GET /api/health`
2. `GET /api/events`
3. `GET /api/flows`
4. `GET /api/flows/:intent_hash`

## 7. 验收清单

完成本地演示时，至少确认：
1. `make test` 全通过
2. `data/flow-events.jsonl` 有新增数据
3. `GET /api/flows` 返回至少 1 条 flow
4. `GET /api/flows/:intent_hash` 中 timeline 包含：
- `intent_submitted`
- `settlement_proposed`
- `validator_decision`
5. Explorer 页面可看到 flow 列表和 detail

## 8. 常见问题

### Q1: Explorer 启动失败，提示端口占用

修改 `.env`：

```bash
EXPLORER_BIND=127.0.0.1:18080
```

然后重启：

```bash
make run-explorer
```

### Q2: `sui` 命令不存在

安装 Sui CLI 或先用离线 demo：

```bash
make demo-sui-evm
```

### Q3: 没有 flow 数据

按顺序检查：
1. 是否执行过 demo 或 run-solver/run-validator
2. `FLOW_EVENT_LOG_PATH` 是否一致
3. 日志文件是否可写：

```bash
ls -l data/flow-events.jsonl
tail -n 20 data/flow-events.jsonl
```

### Q4: Validator send 模式报私钥缺失

请设置：

```bash
VALIDATOR_TX_PRIVATE_KEY=0x...
```

并确认链类型与地址参数匹配。
