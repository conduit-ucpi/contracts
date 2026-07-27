#!/usr/bin/env bash
#
# Deploy the COMPLETION (fan-out) escrow pair — implementation + factory —
# signing with a named Foundry keystore instead of a raw private key.
#
# One-time keystore setup (if not done already):
#   cast wallet import relayer --interactive
#
# Usage:
#   ./script/deploy-completion-keystore.sh
#
# Reads config from .env (NETWORK, CHAIN_ID, NETWORK_RPC_URL, and — for
# verification — VERIFIER_API_KEY / VERIFIER_URL). Override the keystore name
# with ACCOUNT=<name>. Set VERIFY=0 to skip verification.
set -euo pipefail

cd "$(dirname "$0")/.."

# Load .env if present (does not override values already in the environment).
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

ACCOUNT="${ACCOUNT:-relayer}"
VERIFY="${VERIFY:-1}"

: "${CHAIN_ID:?set CHAIN_ID (e.g. in .env)}"
: "${NETWORK:?set NETWORK (e.g. in .env)}"
: "${NETWORK_RPC_URL:?set NETWORK_RPC_URL (e.g. in .env)}"

# The keystore holds the key; derive its address so the script's env checks and
# the factory OWNER match the actual signer.
RELAYER_ADDRESS="$(cast wallet address --account "$ACCOUNT")"
export RELAYER_ADDRESS
echo "Signer (keystore '$ACCOUNT'): $RELAYER_ADDRESS"

cmd=(forge script
  script/DeployCompletionEscrowKeystore.s.sol:DeployCompletionEscrowKeystore
  --rpc-url "$NETWORK_RPC_URL"
  --account "$ACCOUNT"
  --sender "$RELAYER_ADDRESS"
  --broadcast)

if [ "$VERIFY" = "1" ]; then
  : "${VERIFIER_API_KEY:?set VERIFIER_API_KEY, or run with VERIFY=0}"
  : "${VERIFIER_URL:?set VERIFIER_URL, or run with VERIFY=0}"
  cmd+=(--verify --etherscan-api-key "$VERIFIER_API_KEY" --verifier-url "$VERIFIER_URL")
fi

echo "Running: ${cmd[*]}"
"${cmd[@]}"
