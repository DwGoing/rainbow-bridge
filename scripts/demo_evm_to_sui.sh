#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

INTENT_HASH="${INTENT_HASH:-0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
SOLVER_ADDR="${SOLVER_ADDR:-0xsolver000000000000000000000000000000000001}"
VALIDATOR_ADDR="${VALIDATOR_ADDR:-0xvalidator00000000000000000000000000000001}"

export SOLVER_SRC_SKIP_RPC=true
export SOLVER_DST_SKIP_RPC=true
export SOLVER_SRC_CHAIN_KIND=evm
export SOLVER_DST_CHAIN_KIND=sui
export SOLVER_SRC_ENDPOINT_ADDRESS="${SOLVER_SRC_ENDPOINT_ADDRESS:-0x1111111111111111111111111111111111111111}"
export SOLVER_ADDRESS="$SOLVER_ADDR"
export VALIDATOR_ADDRESS="$VALIDATOR_ADDR"
export SOLVER_INTENT_EVENT_JSON="$(cat <<JSON
{
  "intent": {
    "intent_hash": "$INTENT_HASH",
    "provider": "0xprovider0000000000000000000000000000000001",
    "src_chain_id": 1,
    "src_token": "0x0000000000000000000000000000000000000000",
    "src_amount": 1000000000000000000,
    "dst_chain_id": 784,
    "dst_token": "0x2::sui::SUI",
    "min_dst_amount": 900000000,
    "recipient": "0xrecipient0000000000000000000000000000000001",
    "deadline": 1900000000,
    "nonce": 1
  },
  "tx_hash": "0x1111111111111111111111111111111111111111111111111111111111111111",
  "block_number": 123456,
  "timestamp": 1700000000
}
JSON
)"

echo "[demo] solver: source=evm, destination=sui"
cargo run -q -p solver
