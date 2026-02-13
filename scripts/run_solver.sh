#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOAD_ENV=true

while [ $# -gt 0 ]; do
  case "$1" in
    --no-env)
      LOAD_ENV=false
      shift
      ;;
    *)
      echo "unknown argument: $1"
      echo "usage: ./scripts/run_solver.sh [--no-env]"
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

if [ "${SOLVER_USE_CHAIN_POLLING:-false}" = "true" ] || [ "${SOLVER_USE_CHAIN_POLLING:-0}" = "1" ]; then
  : "${SOLVER_SRC_CHAIN_KIND:?missing SOLVER_SRC_CHAIN_KIND}"
fi

echo "[run] solver"
cargo run -q -p solver
