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

## Notes

- Rust workspace is still defined in root `Cargo.toml`.
- EVM source of truth remains in `contracts/evm`; root `foundry.toml` only redirects paths.
- Sui package lives in `contracts/sui` with its own `Move.toml`.
