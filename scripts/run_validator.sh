#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOAD_ENV=true
FORCE_MODE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --mode)
      FORCE_MODE="${2:-}"
      shift 2
      ;;
    --no-env)
      LOAD_ENV=false
      shift
      ;;
    *)
      echo "unknown argument: $1"
      echo "usage: ./scripts/run_validator.sh [--mode off|dry-run|send] [--no-env]"
      exit 1
      ;;
  esac
done

if [ "$LOAD_ENV" = true ] && [ -f ".env" ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

MODE="${VALIDATOR_TX_MODE:-off}"
if [ -n "$FORCE_MODE" ]; then
  MODE="$FORCE_MODE"
  export VALIDATOR_TX_MODE="$FORCE_MODE"
fi

if [ "$MODE" = "send" ] && [ "${VALIDATOR_SRC_CHAIN_KIND:-evm}" = "evm" ]; then
  : "${VALIDATOR_TX_PRIVATE_KEY:?missing VALIDATOR_TX_PRIVATE_KEY for evm send mode}"
fi

echo "[run] validator (mode=$MODE)"
cargo run -q -p validator
