#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# AdaptiveGuard Protocol — Local Demo Runner
# Starts Anvil, deploys contracts, seeds simulated data, runs the UI.
# Usage: ./scripts/run_local.sh
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Load env
if [[ -f .env ]]; then
  export $(grep -v '^#' .env | xargs)
fi

ANVIL_PORT=8545
FORGE="${HOME}/.foundry/bin/forge"
ANVIL="${HOME}/.foundry/bin/anvil"

echo "=== AdaptiveGuard Local Demo ==="

# ── 1. Start Anvil ─────────────────────────────────────────────────────────
echo "[1/4] Starting Anvil on port $ANVIL_PORT..."
$ANVIL --port $ANVIL_PORT --block-time 2 &
ANVIL_PID=$!
trap "kill $ANVIL_PID 2>/dev/null; exit" INT TERM EXIT
sleep 1

# ── 2. Deploy contracts ───────────────────────────────────────────────────
echo "[2/4] Deploying contracts..."
DEPLOY_OUT=$(
  cd contracts && \
  PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}" \
  DAO_ADDRESS="${DAO_ADDRESS:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}" \
  INIT_VOL_BPS=4500 \
  "$FORGE" script script/Deploy.s.sol \
    --rpc-url "http://127.0.0.1:$ANVIL_PORT" \
    --broadcast \
    --private-key "${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}" \
    2>&1
)
echo "$DEPLOY_OUT"

# Extract deployed addresses from forge output
ORACLE_ADDR=$(echo "$DEPLOY_OUT"  | grep "VolatilityOracle" | grep -oE '0x[a-fA-F0-9]{40}' | tail -1)
ENGINE_ADDR=$(echo "$DEPLOY_OUT"  | grep "AdaptiveMCREngine" | grep -oE '0x[a-fA-F0-9]{40}' | tail -1)
ADAPTER_ADDR=$(echo "$DEPLOY_OUT" | grep "MezoAdapter" | grep -oE '0x[a-fA-F0-9]{40}' | tail -1)

if [[ -z "$ORACLE_ADDR" ]]; then
  echo "ERROR: Could not extract contract addresses from deploy output."
  echo "Check the contracts compiled correctly with: cd contracts && forge build"
  exit 1
fi

echo ""
echo "Deployed:"
echo "  VolatilityOracle : $ORACLE_ADDR"
echo "  AdaptiveMCREngine: $ENGINE_ADDR"
echo "  MezoAdapter      : $ADAPTER_ADDR"

# Write addresses to .env and frontend/.env.local
cat > .env.local <<EOF
RPC_URL=http://127.0.0.1:$ANVIL_PORT
CHAIN_ID=31337
PRIVATE_KEY=${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}
ORACLE_ADDRESS=$ORACLE_ADDR
ENGINE_ADDRESS=$ENGINE_ADDR
ADAPTER_ADDRESS=$ADAPTER_ADDR
EOF

cat > frontend/.env.local <<EOF
VITE_RPC_URL=http://127.0.0.1:$ANVIL_PORT
VITE_ORACLE_ADDRESS=$ORACLE_ADDR
VITE_ENGINE_ADDRESS=$ENGINE_ADDR
VITE_ADAPTER_ADDRESS=$ADAPTER_ADDR
EOF

echo ""
echo "[3/4] Starting off-chain EGARCH service (dry-run)..."
(
  cd "$REPO_ROOT" && \
  pip install -q -r services/requirements.txt 2>/dev/null || true && \
  set -a && source .env.local && set +a && \
  python -m services.egarch_service.main --once --dry-run
) &
SERVICE_PID=$!

echo ""
echo "[4/4] Starting frontend dev server..."
echo ""
echo "  ┌──────────────────────────────────────────────────────────────────┐"
echo "  │  AdaptiveGuard UI → http://localhost:5173                        │"
echo "  │  Anvil RPC        → http://localhost:$ANVIL_PORT                      │"
echo "  │  Press Ctrl+C to stop                                            │"
echo "  └──────────────────────────────────────────────────────────────────┘"
echo ""

(cd frontend && npm run dev) &
UI_PID=$!

wait $UI_PID
