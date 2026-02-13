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
make check-rust
make test-rust
make fmt-rust
```

### EVM (Foundry)

```bash
make build-evm
make test-evm
```

You can also run Foundry directly from repo root now:

```bash
forge build
forge test --offline
```

Deploy contracts:

```bash
make deploy-evm ARGS="--rpc-url http://127.0.0.1:8545 --private-key 0x..."
```

### Sui (Move)

```bash
make build-sui
make test-sui
```

If `sui` CLI is not installed, these targets are skipped with a message.
If Sui git dependencies cannot be fetched in restricted environments, targets continue by default.
Use strict mode to fail fast:

```bash
STRICT_SUI=1 make build-sui
STRICT_SUI=1 make test-sui
```

Publish Move package:

```bash
make deploy-sui ARGS="--rpc-url https://fullnode.testnet.sui.io:443 --private-key suiprivkey... --gas-budget 200000000"
```

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
