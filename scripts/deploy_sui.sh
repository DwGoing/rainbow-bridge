#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/deploy_sui.sh [options]

Options:
  --package-path <path>      Move package path (default: contracts/sui)
  --gas-budget <mist>        Gas budget (default: 100000000)
  --rpc-url <url>            Sui fullnode RPC URL (parameter-driven deploy)
  --ws-url <url>             Optional Sui fullnode WS URL
  --private-key <key>        Deployer private key or mnemonic (required with --rpc-url)
  --key-scheme <scheme>      Key scheme for import: ed25519|secp256k1|secp256r1 (default: ed25519)
  --client-env <alias>       Temp env alias for parameter-driven deploy (default: cli)
  --sender <address>         Optional sender
  --build-env <env>          Used by test-publish; auto-selected when RPC is localhost/127.0.0.1
  --pubfile-path <path>      Optional publication file for test-publish
  --dry-run <true|false>     Dry run publish (default: false)
  -h, --help                 Show this help

Examples:
  ./scripts/deploy_sui.sh --build-env localnet --rpc-url http://127.0.0.1:9000 --private-key 'suiprivkey...'
  ./scripts/deploy_sui.sh --rpc-url https://fullnode.testnet.sui.io:443 --sender 0xabc... --gas-budget 200000000
USAGE
}

DEPLOY_SUI_PACKAGE_PATH="${DEPLOY_SUI_PACKAGE_PATH:-contracts/sui}"
DEPLOY_SUI_GAS_BUDGET="${DEPLOY_SUI_GAS_BUDGET:-100000000}"
DEPLOY_SUI_RPC_URL="${DEPLOY_SUI_RPC_URL:-}"
DEPLOY_SUI_WS_URL="${DEPLOY_SUI_WS_URL:-}"
DEPLOY_SUI_PRIVATE_KEY="${DEPLOY_SUI_PRIVATE_KEY:-}"
DEPLOY_SUI_KEY_SCHEME="${DEPLOY_SUI_KEY_SCHEME:-ed25519}"
DEPLOY_SUI_CLIENT_ENV="${DEPLOY_SUI_CLIENT_ENV:-cli}"
DEPLOY_SUI_SKIP_FETCH="${DEPLOY_SUI_SKIP_FETCH:-true}"
DEPLOY_SUI_DRY_RUN="${DEPLOY_SUI_DRY_RUN:-false}"
DEPLOY_SUI_BUILD_ENV="${DEPLOY_SUI_BUILD_ENV:-}"
DEPLOY_SUI_PUBFILE_PATH="${DEPLOY_SUI_PUBFILE_PATH:-}"
DEPLOY_SUI_SENDER="${DEPLOY_SUI_SENDER:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --package-path)
      DEPLOY_SUI_PACKAGE_PATH="${2:-}"
      shift 2
      ;;
    --gas-budget)
      DEPLOY_SUI_GAS_BUDGET="${2:-}"
      shift 2
      ;;
    --rpc-url)
      DEPLOY_SUI_RPC_URL="${2:-}"
      shift 2
      ;;
    --ws-url)
      DEPLOY_SUI_WS_URL="${2:-}"
      shift 2
      ;;
    --private-key)
      DEPLOY_SUI_PRIVATE_KEY="${2:-}"
      shift 2
      ;;
    --key-scheme)
      DEPLOY_SUI_KEY_SCHEME="${2:-}"
      shift 2
      ;;
    --client-env)
      DEPLOY_SUI_CLIENT_ENV="${2:-}"
      shift 2
      ;;
    --sender)
      DEPLOY_SUI_SENDER="${2:-}"
      shift 2
      ;;
    --build-env)
      DEPLOY_SUI_BUILD_ENV="${2:-}"
      shift 2
      ;;
    --pubfile-path)
      DEPLOY_SUI_PUBFILE_PATH="${2:-}"
      shift 2
      ;;
    --skip-fetch)
      DEPLOY_SUI_SKIP_FETCH="${2:-}"
      shift 2
      ;;
    --dry-run)
      DEPLOY_SUI_DRY_RUN="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[deploy-sui] unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

mkdir -p data/deploy

if ! command -v sui >/dev/null 2>&1; then
  echo "[deploy-sui] error: sui CLI not found"
  exit 1
fi

SUI_CLIENT_ARGS=()
ACTIVE_ENV=""
TEMP_SUI_DIR=""
TEMP_PUB_DIR=""

cleanup() {
  if [ -n "${TEMP_SUI_DIR:-}" ] && [ -d "$TEMP_SUI_DIR" ]; then
    rm -rf "$TEMP_SUI_DIR"
  fi
  if [ -n "${TEMP_PUB_DIR:-}" ] && [ -d "$TEMP_PUB_DIR" ]; then
    rm -rf "$TEMP_PUB_DIR"
  fi
}
trap cleanup EXIT

if [ -n "$DEPLOY_SUI_RPC_URL" ]; then
  if [ -z "$DEPLOY_SUI_PRIVATE_KEY" ]; then
    echo "[deploy-sui] error: --private-key is required when --rpc-url is provided"
    exit 1
  fi

  TEMP_SUI_DIR="$(mktemp -d /tmp/rainbow-sui-client.XXXXXX)"
  TEMP_KEYSTORE="$TEMP_SUI_DIR/sui.keystore"
  TEMP_IMPORT_JSON="$TEMP_SUI_DIR/import.json"
  TEMP_CLIENT_CONFIG="$TEMP_SUI_DIR/client.yaml"

  if ! sui keytool --keystore-path "$TEMP_KEYSTORE" import "$DEPLOY_SUI_PRIVATE_KEY" "$DEPLOY_SUI_KEY_SCHEME" --alias deployer --json > "$TEMP_IMPORT_JSON"; then
    echo "[deploy-sui] error: failed to import private key (check key format and key scheme)"
    exit 1
  fi

  if command -v jq >/dev/null 2>&1; then
    IMPORTED_SENDER="$(jq -r '.suiAddress // empty' "$TEMP_IMPORT_JSON")"
  else
    IMPORTED_SENDER="$(sed -n 's/.*"suiAddress"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$TEMP_IMPORT_JSON" | head -n 1)"
  fi

  if [ -z "$IMPORTED_SENDER" ]; then
    echo "[deploy-sui] error: cannot parse sender address from imported private key"
    exit 1
  fi

  if [ -z "${DEPLOY_SUI_SENDER:-}" ]; then
    DEPLOY_SUI_SENDER="$IMPORTED_SENDER"
  fi

  WS_LINE="~"
  if [ -n "$DEPLOY_SUI_WS_URL" ]; then
    WS_LINE="\"$DEPLOY_SUI_WS_URL\""
  fi

  cat > "$TEMP_CLIENT_CONFIG" <<EOF
---
keystore:
  File: $TEMP_KEYSTORE
external_keys: ~
envs:
  - alias: $DEPLOY_SUI_CLIENT_ENV
    rpc: "$DEPLOY_SUI_RPC_URL"
    ws: $WS_LINE
    basic_auth: ~
active_env: $DEPLOY_SUI_CLIENT_ENV
active_address: "$DEPLOY_SUI_SENDER"
EOF

  SUI_CLIENT_ARGS=(--client.config "$TEMP_CLIENT_CONFIG" --client.env "$DEPLOY_SUI_CLIENT_ENV")
  ACTIVE_ENV="$DEPLOY_SUI_CLIENT_ENV"
else
  ACTIVE_ENV="$(sui client active-env 2>/dev/null || true)"
fi

PUBLISH_SUBCOMMAND="publish"
IS_LOCAL_RPC="0"

if [ -n "$DEPLOY_SUI_RPC_URL" ]; then
  case "$DEPLOY_SUI_RPC_URL" in
    http://localhost:*|http://127.0.0.1:*|https://localhost:*|https://127.0.0.1:*|localhost:*|127.0.0.1:*)
      IS_LOCAL_RPC="1"
      ;;
  esac
else
  if [ "$ACTIVE_ENV" = "localnet" ]; then
    IS_LOCAL_RPC="1"
  fi
fi

if [ "$IS_LOCAL_RPC" = "1" ]; then
    PUBLISH_SUBCOMMAND="test-publish"
fi

CMD=(sui client "${SUI_CLIENT_ARGS[@]}" "$PUBLISH_SUBCOMMAND" "$DEPLOY_SUI_PACKAGE_PATH" --gas-budget "$DEPLOY_SUI_GAS_BUDGET" --json)

if [ "$PUBLISH_SUBCOMMAND" = "test-publish" ]; then
  BUILD_ENV="$DEPLOY_SUI_BUILD_ENV"
  if [ -z "$BUILD_ENV" ]; then
    if [ "$IS_LOCAL_RPC" = "1" ]; then
      BUILD_ENV="localnet"
    else
      BUILD_ENV="${ACTIVE_ENV:-mainnet}"
    fi
  fi
  CMD+=(--build-env "$BUILD_ENV")
  if [ -n "$DEPLOY_SUI_PUBFILE_PATH" ]; then
    CMD+=(--pubfile-path "$DEPLOY_SUI_PUBFILE_PATH")
  else
    TEMP_PUB_DIR="$(mktemp -d /tmp/rainbow-pub.${BUILD_ENV}.XXXXXX)"
    TEMP_PUBFILE_PATH="$TEMP_PUB_DIR/Publications.toml"
    CMD+=(--pubfile-path "$TEMP_PUBFILE_PATH")
  fi
fi

if [ "$DEPLOY_SUI_SKIP_FETCH" = "true" ] || [ "$DEPLOY_SUI_SKIP_FETCH" = "1" ]; then
  if [ "$PUBLISH_SUBCOMMAND" = "publish" ] && sui client publish --help | grep -q -- "--skip-fetch-latest-git-deps"; then
    CMD+=(--skip-fetch-latest-git-deps)
  elif [ "$PUBLISH_SUBCOMMAND" = "test-publish" ]; then
    echo "[deploy-sui] info: test-publish mode selected; skip-fetch flag not applicable"
  else
    echo "[deploy-sui] warn: current sui CLI does not support --skip-fetch-latest-git-deps, continue without it"
  fi
fi

if [ "$PUBLISH_SUBCOMMAND" = "publish" ] && [ -n "$DEPLOY_SUI_BUILD_ENV" ]; then
  echo "[deploy-sui] info: --build-env is only used by test-publish; ignored in publish mode"
fi

if [ -n "${DEPLOY_SUI_SENDER:-}" ]; then
  CMD+=(--sender "$DEPLOY_SUI_SENDER")
fi

if [ "$DEPLOY_SUI_DRY_RUN" = "true" ] || [ "$DEPLOY_SUI_DRY_RUN" = "1" ]; then
  CMD+=(--dry-run)
fi

echo "[deploy-sui] package: $DEPLOY_SUI_PACKAGE_PATH"
echo "[deploy-sui] gas budget: $DEPLOY_SUI_GAS_BUDGET"
echo "[deploy-sui] active env: ${ACTIVE_ENV:-unknown}"
echo "[deploy-sui] mode: $PUBLISH_SUBCOMMAND"
if [ "$PUBLISH_SUBCOMMAND" = "test-publish" ]; then
  echo "[deploy-sui] build env: ${BUILD_ENV:-unknown}"
  if [ -n "${DEPLOY_SUI_PUBFILE_PATH:-}" ]; then
    echo "[deploy-sui] pubfile: $DEPLOY_SUI_PUBFILE_PATH"
  elif [ -n "${TEMP_PUBFILE_PATH:-}" ]; then
    echo "[deploy-sui] pubfile: $TEMP_PUBFILE_PATH"
  fi
fi
if [ -n "${DEPLOY_SUI_SENDER:-}" ]; then
  echo "[deploy-sui] sender: $DEPLOY_SUI_SENDER"
fi

set +e
OUTPUT="$("${CMD[@]}")"
RC=$?
set -e

if [ "$RC" -ne 0 ]; then
  echo "[deploy-sui] error: publish failed (exit=$RC)"
  echo "[deploy-sui] command: ${CMD[*]}"
  if [ -n "${OUTPUT:-}" ]; then
    echo "$OUTPUT"
  fi
  echo "[deploy-sui] hint: check active address, gas coins, RPC network, and package dependencies."
  exit "$RC"
fi

echo "$OUTPUT" > data/deploy/sui.latest.json

if command -v jq >/dev/null 2>&1; then
  PACKAGE_ID="$(echo "$OUTPUT" | jq -r '.objectChanges[]? | select(.type=="published") | .packageId' | head -n 1)"
else
  PACKAGE_ID=""
fi

if [ -n "${PACKAGE_ID:-}" ] && [ "$PACKAGE_ID" != "null" ]; then
  echo "[deploy-sui] package id: $PACKAGE_ID"
else
  echo "[deploy-sui] package id not found in output (check data/deploy/sui.latest.json)"
fi

echo "[deploy-sui] deployment result: data/deploy/sui.latest.json"
