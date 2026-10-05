#!/usr/bin/env bash
#
# Deploy the LEGACY escrow pair ONLY — EscrowContract + EscrowContractFactory —
# signing with a named Foundry keystore instead of a raw private key.
#
# Stamps the deployed bytecode with the current commit (GIT_COMMIT), and so
# refuses to run from a dirty tree: the recorded SHA must be the code deployed.
#
# One-time keystore setup (if not done already):
#   cast wallet import relayer --interactive
#
# Usage:
#   ./script/deploy-escrow-keystore.sh
#
# Reads config from .env (NETWORK, CHAIN_ID, NETWORK_RPC_URL,
# DEFAULT_ARBITER_ADDRESS, optional FEE_RECIPIENT_ADDRESS /
# FEE_SPLIT_SIGNER_ADDRESS, and — for
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

if [ -n "$(git status --porcelain)" ]; then
  echo "Refusing to deploy: working tree is dirty. GIT_COMMIT must match the deployed code." >&2
  git status --short >&2
  exit 1
fi
GIT_COMMIT="0x$(git rev-parse HEAD)"
export GIT_COMMIT
echo "Deploying commit: $GIT_COMMIT"

ACCOUNT="${ACCOUNT:-relayer}"
VERIFY="${VERIFY:-1}"

: "${CHAIN_ID:?set CHAIN_ID (e.g. in .env)}"
: "${NETWORK:?set NETWORK (e.g. in .env)}"
: "${NETWORK_RPC_URL:?set NETWORK_RPC_URL (e.g. in .env)}"
: "${DEFAULT_ARBITER_ADDRESS:?set DEFAULT_ARBITER_ADDRESS (e.g. in .env)}"

# The keystore holds the key; derive its address so the script's env checks and
# the factory OWNER match the actual signer.
RELAYER_ADDRESS="$(cast wallet address --account "$ACCOUNT")"
export RELAYER_ADDRESS
echo "Signer (keystore '$ACCOUNT'): $RELAYER_ADDRESS"

cmd=(forge script
  script/DeployEscrowKeystore.s.sol:DeployEscrowKeystore
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
