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

: "${DEPLOY_EVM_RPC_URL:?missing DEPLOY_EVM_RPC_URL}"
: "${DEPLOYER_PRIVATE_KEY:?missing DEPLOYER_PRIVATE_KEY}"

if [ -z "${DEPLOY_OWNER:-}" ]; then
  DEPLOY_OWNER="$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")"
  export DEPLOY_OWNER
fi

if [ -z "${DEPLOY_CHAIN_ID:-}" ]; then
  DEPLOY_CHAIN_ID="$(cast chain-id --rpc-url "$DEPLOY_EVM_RPC_URL")"
  export DEPLOY_CHAIN_ID
fi

mkdir -p data/deploy

echo "[deploy-evm] rpc: $DEPLOY_EVM_RPC_URL"
echo "[deploy-evm] owner: $DEPLOY_OWNER"
echo "[deploy-evm] chain id: $DEPLOY_CHAIN_ID"

forge script contracts/evm/script/DeployCore.s.sol:DeployCore \
  --rpc-url "$DEPLOY_EVM_RPC_URL" \
  --broadcast \
  -vv

echo "[deploy-evm] deployment result: data/deploy/evm.latest.json"
