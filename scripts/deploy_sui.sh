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

DEPLOY_SUI_PACKAGE_PATH="${DEPLOY_SUI_PACKAGE_PATH:-contracts/sui}"
DEPLOY_SUI_GAS_BUDGET="${DEPLOY_SUI_GAS_BUDGET:-100000000}"
DEPLOY_SUI_SKIP_FETCH="${DEPLOY_SUI_SKIP_FETCH:-true}"
DEPLOY_SUI_DRY_RUN="${DEPLOY_SUI_DRY_RUN:-false}"
DEPLOY_SUI_MODE="${DEPLOY_SUI_MODE:-auto}" # auto | publish | test-publish
DEPLOY_SUI_BUILD_ENV="${DEPLOY_SUI_BUILD_ENV:-}"
DEPLOY_SUI_PUBFILE_PATH="${DEPLOY_SUI_PUBFILE_PATH:-}"

mkdir -p data/deploy

ACTIVE_ENV="$(sui client active-env 2>/dev/null || true)"
PUBLISH_SUBCOMMAND="publish"

if [ "$DEPLOY_SUI_MODE" = "test-publish" ]; then
  PUBLISH_SUBCOMMAND="test-publish"
elif [ "$DEPLOY_SUI_MODE" = "publish" ]; then
  PUBLISH_SUBCOMMAND="publish"
elif [ "$DEPLOY_SUI_MODE" = "auto" ]; then
  if [ "$ACTIVE_ENV" = "localnet" ]; then
    PUBLISH_SUBCOMMAND="test-publish"
  fi
else
  echo "[deploy-sui] error: invalid DEPLOY_SUI_MODE '$DEPLOY_SUI_MODE' (expected auto|publish|test-publish)"
  exit 1
fi

CMD=(sui client "$PUBLISH_SUBCOMMAND" "$DEPLOY_SUI_PACKAGE_PATH" --gas-budget "$DEPLOY_SUI_GAS_BUDGET" --json)

if [ "$PUBLISH_SUBCOMMAND" = "test-publish" ]; then
  BUILD_ENV="$DEPLOY_SUI_BUILD_ENV"
  if [ -z "$BUILD_ENV" ]; then
    BUILD_ENV="${ACTIVE_ENV:-localnet}"
  fi
  CMD+=(--build-env "$BUILD_ENV")
  if [ -n "$DEPLOY_SUI_PUBFILE_PATH" ]; then
    CMD+=(--pubfile-path "$DEPLOY_SUI_PUBFILE_PATH")
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
  fi
fi
if [ -n "${DEPLOY_SUI_SENDER:-}" ]; then
  echo "[deploy-sui] sender: $DEPLOY_SUI_SENDER"
fi

if ! command -v sui >/dev/null 2>&1; then
  echo "[deploy-sui] error: sui CLI not found"
  exit 1
fi

STDOUT_FILE="data/deploy/sui.latest.stdout.json"
STDERR_FILE="data/deploy/sui.latest.stderr.log"

set +e
"${CMD[@]}" >"$STDOUT_FILE" 2>"$STDERR_FILE"
RC=$?
set -e

if [ "$RC" -ne 0 ]; then
  echo "[deploy-sui] error: publish failed (exit=$RC)"
  echo "[deploy-sui] command: ${CMD[*]}"
  echo "[deploy-sui] stderr:"
  cat "$STDERR_FILE"
  if [ -s "$STDOUT_FILE" ]; then
    echo "[deploy-sui] stdout:"
    cat "$STDOUT_FILE"
  fi
  echo "[deploy-sui] hint: check active address, gas coins, RPC network, and package dependencies."
  exit "$RC"
fi

cp "$STDOUT_FILE" data/deploy/sui.latest.json
OUTPUT="$(cat "$STDOUT_FILE")"

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
