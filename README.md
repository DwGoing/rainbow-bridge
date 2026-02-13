# Rainbow Bridge

Monorepo layout that manages:
- Rust services (`/services`) and shared crates (`/crates`)
- EVM Solidity contracts (`/contracts/evm`)
- Sui Move contracts (`/contracts/sui`)

## Directory Layout

```text
.
├── Cargo.toml                # Rust workspace root
├── Makefile                  # Root task entry (rust + evm + sui)
├── foundry.toml              # Root Foundry config (points to contracts/evm)
├── crates/
│   ├── chain-adapters
│   └── types
├── services/
│   ├── solver
│   └── validator
└── contracts/
    ├── evm
    │   ├── src
    │   └── test
    └── sui
        ├── Move.toml
        └── sources
```

## Root Commands

Use root-level commands so all environments are managed consistently:

```bash
make help
make check
make test
```

### Rust

```bash
make rust-check
make rust-test
make rust-fmt
```

### EVM (Foundry)

```bash
make evm-build
make evm-test
```

You can also run Foundry directly from repo root now:

```bash
forge build
forge test --offline
```

### Sui (Move)

```bash
make sui-build
make sui-test
```

If `sui` CLI is not installed, these targets are skipped with a message.
If Sui git dependencies cannot be fetched in restricted environments, targets continue by default.
Use strict mode to fail fast:

```bash
STRICT_SUI=1 make sui-build
STRICT_SUI=1 make sui-test
```

### Cross-chain demo

Run offline demo flows from repo root:

```bash
make demo-evm-sui
make demo-sui-evm
```

`demo-sui-evm` defaults to `VALIDATOR_TX_MODE=off`.  
To try Sui CLI execution path, set `VALIDATOR_TX_MODE=dry-run` or `send` and provide Sui CLI wallet context.

### Real chain run

1. Copy env template and fill RPC / addresses:

```bash
cp .env.example .env
```

Optional profiles:

```bash
cp .env.testnet.example .env
# or
cp .env.mainnet.example .env
```

2. Run services with env:

```bash
make run-solver
make run-validator
make run-explorer
```

Validator mode shortcuts:

```bash
make run-validator-off
make run-validator-dry
make run-validator-send
```

Explorer UI:

```bash
open http://127.0.0.1:8080
```

Explorer reads the shared event log (`FLOW_EVENT_LOG_PATH`, default `data/flow-events.jsonl`).

## Notes

- Rust workspace is still defined in root `Cargo.toml`.
- EVM source of truth remains in `contracts/evm`; root `foundry.toml` only redirects paths.
- Sui package lives in `contracts/sui` with its own `Move.toml`.
