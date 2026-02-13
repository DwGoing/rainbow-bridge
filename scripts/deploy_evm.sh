#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/deploy_evm.sh --rpc-url <url> --private-key <hex> [--owner <address>] [--chain-id <id>]

Example:
  ./scripts/deploy_evm.sh \
    --rpc-url http://127.0.0.1:8545 \
    --private-key 0xabc...
USAGE
}

DEPLOY_EVM_RPC_URL=""
DEPLOYER_PRIVATE_KEY=""
DEPLOY_OWNER="${DEPLOY_OWNER:-}"
DEPLOY_CHAIN_ID="${DEPLOY_CHAIN_ID:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --rpc-url)
      DEPLOY_EVM_RPC_URL="${2:-}"
      shift 2
      ;;
    --private-key)
      DEPLOYER_PRIVATE_KEY="${2:-}"
      shift 2
      ;;
    --owner)
      DEPLOY_OWNER="${2:-}"
      shift 2
      ;;
    --chain-id)
      DEPLOY_CHAIN_ID="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[deploy-evm] unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

[ -n "$DEPLOY_EVM_RPC_URL" ] || { echo "[deploy-evm] missing --rpc-url"; usage; exit 1; }
[ -n "$DEPLOYER_PRIVATE_KEY" ] || { echo "[deploy-evm] missing --private-key"; usage; exit 1; }

if [ -z "$DEPLOY_OWNER" ]; then
  DEPLOY_OWNER="$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")"
fi

if [ -z "$DEPLOY_CHAIN_ID" ]; then
  DEPLOY_CHAIN_ID="$(cast chain-id --rpc-url "$DEPLOY_EVM_RPC_URL")"
fi

mkdir -p data/deploy

echo "[deploy-evm] rpc: $DEPLOY_EVM_RPC_URL"
echo "[deploy-evm] owner: $DEPLOY_OWNER"
echo "[deploy-evm] chain id: $DEPLOY_CHAIN_ID"

export DEPLOYER_PRIVATE_KEY DEPLOY_OWNER DEPLOY_CHAIN_ID

forge script contracts/evm/script/DeployCore.s.sol:DeployCore \
  --rpc-url "$DEPLOY_EVM_RPC_URL" \
  --broadcast \
  -vv

echo "[deploy-evm] deployment result: data/deploy/evm.latest.json"
