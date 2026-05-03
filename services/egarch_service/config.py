"""Configuration — loaded from environment variables with sensible demo defaults."""

import os
from pathlib import Path


# ── Chain / RPC ────────────────────────────────────────────────────────────────
RPC_URL          = os.getenv("RPC_URL", "http://127.0.0.1:8545")
CHAIN_ID         = int(os.getenv("CHAIN_ID", "31337"))   # 31337 = Anvil
PRIVATE_KEY      = os.getenv("PRIVATE_KEY", "")           # Deployer / service key

# ── Contract Addresses (populated after deployment) ───────────────────────────
ORACLE_ADDRESS   = os.getenv("ORACLE_ADDRESS",  "")
ENGINE_ADDRESS   = os.getenv("ENGINE_ADDRESS",  "")
ADAPTER_ADDRESS  = os.getenv("ADAPTER_ADDRESS", "")

# ── ABIs (resolved relative to repo root) ────────────────────────────────────
REPO_ROOT = Path(__file__).resolve().parents[2]
OUT_DIR   = REPO_ROOT / "contracts" / "out"

# ── EGARCH Parameters ─────────────────────────────────────────────────────────
EGARCH_WINDOW_HOURS = int(os.getenv("EGARCH_WINDOW_HOURS", "720"))   # 30 days
EGARCH_EMA_ALPHA    = float(os.getenv("EGARCH_EMA_ALPHA",  "0.1"))
EGARCH_MIN_OBS      = int(os.getenv("EGARCH_MIN_OBS",      "168"))   # 1 week

# ── Service Schedule ──────────────────────────────────────────────────────────
UPDATE_INTERVAL_SECONDS  = int(os.getenv("UPDATE_INTERVAL_SECONDS",  "3600"))  # 1 hour
APPLY_DELAY_SECONDS      = int(os.getenv("APPLY_DELAY_SECONDS",      "3660"))  # 1h + 1 min

# ── Price Data ────────────────────────────────────────────────────────────────
PRICE_API_URL = os.getenv(
    "PRICE_API_URL",
    "https://api.coingecko.com/api/v3/coins/bitcoin/market_chart"
)
PRICE_HISTORY_DAYS = int(os.getenv("PRICE_HISTORY_DAYS", "31"))

# ── On-chain parameter overrides (passed to proposeMCRUpdate) ─────────────────
#    Set to 0 to read live from the adapter contract instead.
STATIC_SP_DEPTH_BPS = int(os.getenv("STATIC_SP_DEPTH_BPS", "3000"))   # 30% default
STATIC_TCR_BPS      = int(os.getenv("STATIC_TCR_BPS",      "25000"))  # 250% default
