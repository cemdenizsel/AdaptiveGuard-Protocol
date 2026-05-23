#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# AdaptiveGuard Protocol — Mezo Testnet Runner
# Connects to Mezo testnet, starts EGARCH service and frontend.
# Usage:
#   ./scripts/run_testnet.sh          # EGARCH runs every hour (live)
#   ./scripts/run_testnet.sh --dry-run # EGARCH runs once, no transactions
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

# ── Load env ──────────────────────────────────────────────────────────────────
if [[ ! -f .env.testnet ]]; then
  echo "ERROR: .env.testnet not found."
  echo "Copy .env.testnet.example → .env.testnet and fill in PRIVATE_KEY, DAO_ADDRESS,"
  echo "ORACLE_ADDRESS, ENGINE_ADDRESS, ADAPTER_ADDRESS."
  exit 1
fi
export $(grep -v '^#' .env.testnet | xargs)

# ── Validate required vars ────────────────────────────────────────────────────
missing=()
[[ -z "${PRIVATE_KEY:-}"    ]] && missing+=("PRIVATE_KEY")
[[ -z "${ORACLE_ADDRESS:-}" ]] && missing+=("ORACLE_ADDRESS")
[[ -z "${ENGINE_ADDRESS:-}" ]] && missing+=("ENGINE_ADDRESS")
[[ -z "${ADAPTER_ADDRESS:-}"]] && missing+=("ADAPTER_ADDRESS")

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: Missing required values in .env.testnet:"
  for v in "${missing[@]}"; do echo "  - $v"; done
  echo ""
  echo "Deploy contracts first with:"
  echo "  cd contracts && forge script script/Deploy.s.sol --rpc-url mezo_testnet --broadcast --private-key \$PRIVATE_KEY"
  exit 1
fi

# ── Write frontend env ────────────────────────────────────────────────────────
cat > frontend/.env.local <<EOF
VITE_RPC_URL=${RPC_URL}
VITE_CHAIN_ID=${CHAIN_ID}
VITE_ORACLE_ADDRESS=${ORACLE_ADDRESS}
VITE_ENGINE_ADDRESS=${ENGINE_ADDRESS}
VITE_ADAPTER_ADDRESS=${ADAPTER_ADDRESS}
VITE_MUSD_ADDRESS=${MEZO_MUSD:-}
VITE_BORROWER_OPERATIONS=${MEZO_BORROWER_OPERATIONS:-}
VITE_TROVE_MANAGER=${MEZO_TROVE_MANAGER:-}
VITE_PRICE_FEED=${MEZO_PRICE_FEED:-}
EOF

echo "=== AdaptiveGuard Testnet Mode ==="
echo ""
echo "  Network     : Mezo Testnet (chain ${CHAIN_ID})"
echo "  RPC         : ${RPC_URL}"
echo "  Oracle      : ${ORACLE_ADDRESS}"
echo "  Engine      : ${ENGINE_ADDRESS}"
echo "  Adapter     : ${ADAPTER_ADDRESS}"
echo "  MUSD Token  : ${MEZO_MUSD:-not set}"
echo ""

# ── Resolve StabilityPool address ─────────────────────────────────────────────
if command -v cast &>/dev/null && [[ -n "${MEZO_BORROWER_OPERATIONS:-}" ]]; then
  SP_ADDR=$(cast call "${MEZO_BORROWER_OPERATIONS}" \
    "stabilityPoolAddress()(address)" \
    --rpc-url "${RPC_URL}" 2>/dev/null || echo "")
  if [[ -n "$SP_ADDR" && "$SP_ADDR" != "0x0000000000000000000000000000000000000000" ]]; then
    echo "  StabilityPool: ${SP_ADDR} (resolved)"
    export STABILITY_POOL_ADDRESS="$SP_ADDR"
    echo "STABILITY_POOL_ADDRESS=${SP_ADDR}" >> frontend/.env.local
  fi
fi

echo ""

# ── Start EGARCH service ──────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
  echo "[1/2] Starting EGARCH service (dry-run, one shot)..."
  uv run python -m services.egarch_service.main --once --dry-run &
else
  echo "[1/2] Starting EGARCH service (live, runs every hour)..."
  uv run python -m services.egarch_service.main &
fi
SERVICE_PID=$!
trap "kill $SERVICE_PID 2>/dev/null; exit" INT TERM EXIT

# ── Start frontend ────────────────────────────────────────────────────────────
echo "[2/2] Starting frontend dev server..."
echo ""
echo "  ┌──────────────────────────────────────────────────────────────────┐"
echo "  │  AdaptiveGuard UI  → http://localhost:5173                       │"
echo "  │  Mezo Explorer     → https://explorer.test.mezo.org             │"
echo "  │  Press Ctrl+C to stop                                            │"
echo "  └──────────────────────────────────────────────────────────────────┘"
echo ""

(cd frontend && npm run dev) &
UI_PID=$!

wait $UI_PID
