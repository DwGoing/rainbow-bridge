# Rainbow Bridge - Project Introduction

## 1. What This Project Is

Rainbow Bridge is an intent-driven cross-chain execution protocol and engineering framework.

It focuses on one core goal:
- let users submit a desired cross-chain outcome (`Intent`),
- let solvers execute on destination chains,
- let validators verify and settle with challenge protection.

Compared with simple token-transfer bridges, Rainbow Bridge is designed for **result delivery** rather than just asset movement.

## 2. Core Architecture

The project is organized as a monorepo and currently includes three layers:

1. Contracts Layer
- `contracts/evm`: Solidity contracts (Foundry)
- `contracts/sui`: Move package (Sui)

2. Service Layer
- `services/solver`: Solver service (Rust)
- `services/validator`: Validator service (Rust)

3. Shared Libraries
- `crates/types`: shared protocol data types
- `crates/chain-adapters`: chain abstraction and polling interfaces

## 3. Core Business Flow

1. User submits `Intent` on source chain (`EndPoint.submitIntent`).
2. Solver polls intent events and executes target-side flow.
3. Solver builds execution proof and proposes settlement.
4. Validator polls settlement proposals and decides:
- challenge invalid proposal, or
- finalize valid proposal after challenge window, or
- hold until window elapses.
5. If execution times out, user can request refund.

## 4. Current Implementation Status

### EVM Contracts
- Implemented intent lifecycle:
  - submit
  - execute marker
  - propose settlement
  - challenge
  - finalize
  - refund
- Foundry tests are green in current repo setup.

### Rust Services
- `solver` supports:
  - JSON-driven mode
  - chain polling mode
  - optional enriched event mode
  - Sui source-chain event polling (by package/module)
- `validator` supports:
  - decision planning (`Challenge / Finalize / Hold`)
  - ABI-encoded tx payload generation
  - tx execution modes:
    - `off`
    - `dry-run` (`estimate_gas`)
    - `send` (signed tx; optional receipt wait)
  - Sui source-chain execution in `dry-run/send` via `sui client call`

### Sui
- Move package scaffold exists in `contracts/sui`.
- Includes starter module and root-level build/test integration.

## 5. Monorepo Management (Root-Level)

This project is designed to be managed from repository root:

- Rust workspace: `Cargo.toml`
- EVM workspace redirect: `foundry.toml`
- Unified task entry: `Makefile`

Common commands:

```bash
make help
make check
make test
```

Targeted commands:

```bash
make rust-check
make rust-test
make evm-build
make evm-test
make sui-build
make sui-test
```

## 6. Environment and Runtime

Use root `.env.example` as reference for:
- solver source/destination chain config
- validator chain config
- validator tx mode and signing options

Important validator runtime knobs:
- `VALIDATOR_TX_MODE=off|dry-run|send`
- `VALIDATOR_TX_PRIVATE_KEY`
- `VALIDATOR_TX_WAIT_RECEIPT=true|false`
- `VALIDATOR_TX_RECEIPT_TIMEOUT_SECS`
- `VALIDATOR_SRC_PACKAGE_ID`
- `VALIDATOR_SRC_STATE_OBJECT_ID`
- `VALIDATOR_SUI_CLI_BIN`

Offline demo commands:
- `make demo-evm-sui`
- `make demo-sui-evm`

Real chain runtime commands:
- `make run-solver`
- `make run-validator`
- `make run-explorer`
- `make run-validator-off`
- `make run-validator-dry`
- `make run-validator-send`

## 7. Project Value

Rainbow Bridge is building a cross-chain execution network with:
- verifiable settlement,
- challenge-based risk control,
- modular multi-chain service architecture.

It is suitable as a foundation for:
- cross-chain swapping and settlement,
- wallet/aggregator integration,
- protocol-level cross-chain execution markets.

## 8. Next Milestones

1. complete production-grade settlement/challenge automation.
2. strengthen destination-chain execution and proof plumbing.
3. deepen Sui-side protocol implementation and end-to-end integration.
4. add deployment profiles and observability dashboards.
