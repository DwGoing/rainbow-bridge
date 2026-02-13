#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

INTENT_HASH="${INTENT_HASH:-0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}"
STATE_ID="${SOLVER_SRC_STATE_OBJECT_ID:-0x2222222222222222222222222222222222222222222222222222222222222222}"
PKG_ID="${SOLVER_SRC_PACKAGE_ID:-0x3333333333333333333333333333333333333333333333333333333333333333}"
MODE="${VALIDATOR_TX_MODE:-off}"

export SOLVER_SRC_SKIP_RPC=true
export SOLVER_DST_SKIP_RPC=true
export SOLVER_SRC_CHAIN_KIND=sui
export SOLVER_DST_CHAIN_KIND=evm
export SOLVER_SRC_PACKAGE_ID="$PKG_ID"
export SOLVER_SRC_STATE_OBJECT_ID="$STATE_ID"
export SOLVER_SRC_MODULE="${SOLVER_SRC_MODULE:-bridge}"
export SOLVER_ADDRESS="${SOLVER_ADDRESS:-0xsolver000000000000000000000000000000000001}"
export VALIDATOR_ADDRESS="${VALIDATOR_ADDRESS:-0xvalidator00000000000000000000000000000001}"
export SOLVER_INTENT_EVENT_JSON="$(cat <<JSON
{
  "intent": {
    "intent_hash": "$INTENT_HASH",
    "provider": "0xprovider0000000000000000000000000000000001",
    "src_chain_id": 784,
    "src_token": "0x2::sui::SUI",
    "src_amount": 1000000000,
    "dst_chain_id": 1,
    "dst_token": "0x0000000000000000000000000000000000000000",
    "min_dst_amount": 100000000000000000,
    "recipient": "0xreceiver0000000000000000000000000000000001",
    "deadline": 1900000000,
    "nonce": 1
  },
  "tx_hash": "0x2222222222222222222222222222222222222222222222222222222222222222",
  "block_number": 987654,
  "timestamp": 1700000100
}
JSON
)"

echo "[demo] solver: source=sui, destination=evm"
cargo run -q -p solver

export VALIDATOR_SRC_SKIP_RPC=true
export VALIDATOR_DST_SKIP_RPC=true
export VALIDATOR_SRC_CHAIN_KIND=sui
export VALIDATOR_DST_CHAIN_KIND=evm
export VALIDATOR_USE_CHAIN_POLLING=true
export VALIDATOR_TX_MODE="$MODE"
export VALIDATOR_SRC_PACKAGE_ID="$PKG_ID"
export VALIDATOR_SRC_STATE_OBJECT_ID="$STATE_ID"
export VALIDATOR_SRC_MODULE="${VALIDATOR_SRC_MODULE:-bridge}"
export VALIDATOR_POLLED_PROPOSALS_JSON="$(cat <<JSON
[
  {
    "intent_hash": "$INTENT_HASH",
    "validator": "0xvalidator00000000000000000000000000000001",
    "solver": "0xsolver000000000000000000000000000000000001",
    "amount_out": 100000000000000000,
    "tx_hash": "0x3333333333333333333333333333333333333333333333333333333333333333",
    "block_number": 990001,
    "timestamp": 1700000000
  }
]
JSON
)"

echo "[demo] validator: source=sui, destination=evm, tx_mode=$MODE"
cargo run -q -p validator
