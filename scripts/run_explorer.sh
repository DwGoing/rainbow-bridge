#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [ -f ".env" ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

mkdir -p "$(dirname "${FLOW_EVENT_LOG_PATH:-data/flow-events.jsonl}")"

echo "[run] explorer (${EXPLORER_BIND:-127.0.0.1:8080})"
cargo run -q -p explorer
