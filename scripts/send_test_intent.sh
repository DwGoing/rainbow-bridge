#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/send_test_intent.sh [options]

Options:
  --rpc-url <url>             EVM RPC URL (default: TEST_INTENT_RPC_URL or http://127.0.0.1:8545)
  --private-key <hex>         Sender private key (default: TEST_INTENT_PRIVATE_KEY or EMV_PK)
  --endpoint <address>        EndPoint proxy address (default: TEST_INTENT_ENDPOINT_ADDRESS or infer from *_SRC_CHAINS_JSON)
  --dst-chain-id <id>         Destination chain id (default: TEST_INTENT_DST_CHAIN_ID or infer from *_DST_CHAINS_JSON or 101)
  --src-amount <wei>          Source amount in wei (default: 1000000000000000)
  --min-dst-amount <value>    Min destination amount (default: 1000)
  --deadline-secs <secs>      Deadline offset from now (default: 3600)
  --nonce <value>             Intent nonce (default: unix timestamp)
  --dst-token-bytes <hex>     Destination token bytes (default: 0x737569, "sui")
  --recipient <address>       Recipient address encoded into bytes (default: sender address)
  --no-env                    Do not load .env
  -h, --help                  Show this help

Example:
  ./scripts/send_test_intent.sh \
    --rpc-url http://127.0.0.1:8545 \
    --private-key 0xabc... \
    --endpoint 0x5FC8...5707
USAGE
}

LOAD_ENV=true
RPC_URL="${TEST_INTENT_RPC_URL:-http://127.0.0.1:8545}"
PRIVATE_KEY="${TEST_INTENT_PRIVATE_KEY:-${EMV_PK:-}}"
ENDPOINT="${TEST_INTENT_ENDPOINT_ADDRESS:-}"
DST_CHAIN_ID="${TEST_INTENT_DST_CHAIN_ID:-}"
SRC_AMOUNT="${TEST_INTENT_SRC_AMOUNT:-1000000000000000}"
MIN_DST_AMOUNT="${TEST_INTENT_MIN_DST_AMOUNT:-1000}"
DEADLINE_SECS="${TEST_INTENT_DEADLINE_SECS:-3600}"
NONCE="${TEST_INTENT_NONCE:-}"
DST_TOKEN_BYTES="${TEST_INTENT_DST_TOKEN_BYTES:-0x737569}"
RECIPIENT="${TEST_INTENT_RECIPIENT:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --rpc-url)
      RPC_URL="${2:-}"
      shift 2
      ;;
    --private-key)
      PRIVATE_KEY="${2:-}"
      shift 2
      ;;
    --endpoint)
      ENDPOINT="${2:-}"
      shift 2
      ;;
    --dst-chain-id)
      DST_CHAIN_ID="${2:-}"
      shift 2
      ;;
    --src-amount)
      SRC_AMOUNT="${2:-}"
      shift 2
      ;;
    --min-dst-amount)
      MIN_DST_AMOUNT="${2:-}"
      shift 2
      ;;
    --deadline-secs)
      DEADLINE_SECS="${2:-}"
      shift 2
      ;;
    --nonce)
      NONCE="${2:-}"
      shift 2
      ;;
    --dst-token-bytes)
      DST_TOKEN_BYTES="${2:-}"
      shift 2
      ;;
    --recipient)
      RECIPIENT="${2:-}"
      shift 2
      ;;
    --no-env)
      LOAD_ENV=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[send-test-intent] unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

if [ "$LOAD_ENV" = true ] && [ -f ".env" ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
  RPC_URL="${RPC_URL:-${TEST_INTENT_RPC_URL:-http://127.0.0.1:8545}}"
  PRIVATE_KEY="${PRIVATE_KEY:-${TEST_INTENT_PRIVATE_KEY:-${EMV_PK:-}}}"
  ENDPOINT="${ENDPOINT:-${TEST_INTENT_ENDPOINT_ADDRESS:-}}"
  DST_CHAIN_ID="${DST_CHAIN_ID:-${TEST_INTENT_DST_CHAIN_ID:-}}"
fi

command -v cast >/dev/null 2>&1 || { echo "[send-test-intent] error: cast not found"; exit 1; }

if [ -z "$ENDPOINT" ] && command -v jq >/dev/null 2>&1; then
  if [ -n "${SOLVER_SRC_CHAINS_JSON:-}" ]; then
    ENDPOINT="$(printf '%s' "$SOLVER_SRC_CHAINS_JSON" | jq -r '.[] | select(.chain_kind=="evm" and .endpoint_address!=null) | .endpoint_address' | head -n 1)"
  fi
  if [ -z "$ENDPOINT" ] && [ -n "${VALIDATOR_SRC_CHAINS_JSON:-}" ]; then
    ENDPOINT="$(printf '%s' "$VALIDATOR_SRC_CHAINS_JSON" | jq -r '.[] | select(.chain_kind=="evm" and .endpoint_address!=null) | .endpoint_address' | head -n 1)"
  fi
fi

if [ -z "$DST_CHAIN_ID" ] && command -v jq >/dev/null 2>&1; then
  if [ -n "${SOLVER_DST_CHAINS_JSON:-}" ]; then
    DST_CHAIN_ID="$(printf '%s' "$SOLVER_DST_CHAINS_JSON" | jq -r '.[] | select(.chain_id!=null) | .chain_id' | head -n 1)"
  fi
fi

[ -n "$PRIVATE_KEY" ] || { echo "[send-test-intent] missing --private-key (or TEST_INTENT_PRIVATE_KEY/EMV_PK)"; exit 1; }
[ -n "$ENDPOINT" ] || { echo "[send-test-intent] missing --endpoint (or TEST_INTENT_ENDPOINT_ADDRESS)"; exit 1; }
DST_CHAIN_ID="${DST_CHAIN_ID:-101}"

PROVIDER="$(cast wallet address --private-key "$PRIVATE_KEY")"
if [ -z "$RECIPIENT" ]; then
  RECIPIENT="$PROVIDER"
fi

if [ -z "$NONCE" ]; then
  NONCE="$(date +%s)"
fi

DEADLINE="$(( $(date +%s) + DEADLINE_SECS ))"
RECIPIENT_BYTES="0x${RECIPIENT#0x}"

echo "[send-test-intent] rpc: $RPC_URL"
echo "[send-test-intent] endpoint: $ENDPOINT"
echo "[send-test-intent] provider: $PROVIDER"
echo "[send-test-intent] dst_chain_id: $DST_CHAIN_ID"

TX_OUTPUT="$(cast send "$ENDPOINT" \
  "submitIntent((address,address,uint256,uint256,bytes,uint256,bytes,uint256,uint256,bytes))" \
  "($PROVIDER,0x0000000000000000000000000000000000000000,$SRC_AMOUNT,$DST_CHAIN_ID,$DST_TOKEN_BYTES,$MIN_DST_AMOUNT,$RECIPIENT_BYTES,$DEADLINE,$NONCE,0x)" \
  --value "$SRC_AMOUNT" \
  --private-key "$PRIVATE_KEY" \
  --rpc-url "$RPC_URL" \
  --json)"

if command -v jq >/dev/null 2>&1; then
  TX_HASH="$(printf '%s' "$TX_OUTPUT" | jq -r '.transactionHash // empty')"
else
  TX_HASH="$(printf '%s' "$TX_OUTPUT" | grep -Eo '0x[a-fA-F0-9]{64}' | head -n 1 || true)"
fi

[ -n "$TX_HASH" ] || { echo "[send-test-intent] failed to parse tx hash"; echo "$TX_OUTPUT"; exit 1; }

EVENT_SIG="$(cast keccak "IntentSubmitted(bytes32,address)")"
RECEIPT_JSON="$(cast receipt "$TX_HASH" --rpc-url "$RPC_URL" --json)"

if command -v jq >/dev/null 2>&1; then
  INTENT_HASH="$(printf '%s' "$RECEIPT_JSON" | jq -r --arg sig "$EVENT_SIG" '.logs[]? | select(.topics[0]==$sig) | .topics[1]' | head -n 1)"
else
  INTENT_HASH=""
fi

echo "[send-test-intent] tx_hash: $TX_HASH"
if [ -n "$INTENT_HASH" ]; then
  echo "[send-test-intent] intent_hash: $INTENT_HASH"
else
  echo "[send-test-intent] intent_hash: <not found in receipt logs>"
fi
