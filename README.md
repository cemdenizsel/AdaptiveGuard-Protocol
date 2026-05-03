# AdaptiveGuard Protocol

> EGARCH(1,1)-driven adaptive Minimum Collateral Ratio (MCR) for MUSD — Mezo Hackathon 2025 (Bitcoin Track)

AdaptiveGuard replaces the static 110% MCR used in most Bitcoin-backed stablecoin systems with a volatility-responsive ratio that rises ahead of market crashes and relaxes during calm periods. The result: fewer liquidation cascades, a deeper Stability Pool, and a more resilient peg.

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Off-chain EGARCH service (Python)                       │
│  ┌──────────────────────┐                               │
│  │ EGARCH(1,1) estimator │  → submitVolatility()        │
│  └──────────────────────┘          │                    │
└─────────────────────────────────────┼───────────────────┘
                                      ▼
┌─────────────────────────────────────────────────────────┐
│  On-chain (Solidity / Foundry)                           │
│                                                          │
│  VolatilityOracle ──────────► AdaptiveMCREngine          │
│  • EMA smoothing (α=0.1)      • Four-regime MCR mapping  │
│  • Chainlink RV / DVOL feeds  • ±5pp rate limiter        │
│  • Outlier rejection          • 4h decrease cooldown     │
│                               • 12h circuit breaker      │
│                               • 1h challenge window      │
│                                      │                   │
│                        MezoIntegrationAdapter            │
│                        • Simulated CDP system            │
│                        • Batch liquidation               │
│                        • Position health checks          │
└─────────────────────────────────────────────────────────┘
                                      ▲
┌─────────────────────────────────────┼───────────────────┐
│  React Dashboard (Vite + Tailwind)   │                   │
│  • Live MCR / vol display            │                   │
│  • CDP Manager (open / close troves) │                   │
│  • Stress test simulator             │                   │
└─────────────────────────────────────────────────────────┘
```

## MCR Mapping (Four Regimes)

| Annualized Vol | Base MCR         |
|---------------|-----------------|
| < 30%          | 110%             |
| 30–60%         | 110% → 125% (linear) |
| 60–90%         | 125% → 140% (linear) |
| ≥ 90%          | 140% → 160% (linear) |

Composite adjustments on top:
- **Stability Pool depth** < 10% → +5pp; < 20% → +2pp
- **TCR near CCR (150%)** → up to +10pp
- **Rate limiter**: ±5pp per epoch, 4h cooldown between decreases
- **Circuit breaker**: >10% price drop in 12h → freeze MCR for 48h

---

## Quickstart (Local Demo)

### Prerequisites
- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node 18+ / npm
- Python 3.10+

```bash
# 1. Clone
git clone <this-repo> && cd AdaptiveGuard-Protocol

# 2. Install Foundry dependencies
cd contracts && forge install && cd ..

# 3. Install frontend dependencies
cd frontend && npm install && cd ..

# 4. Install Python service dependencies
pip install -r services/requirements.txt

# 5. One-command local demo
./scripts/run_local.sh
```

The script:
1. Starts a local Anvil chain
2. Deploys all 3 contracts
3. Writes addresses to `.env.local` and `frontend/.env.local`
4. Runs a dry-run of the EGARCH service
5. Launches the React dashboard at **http://localhost:5173**

---

## Manual Workflow

### Deploy

```bash
cd contracts

# Copy and configure
cp ../.env.example ../.env
# Edit .env: set PRIVATE_KEY, DAO_ADDRESS

# Deploy to Anvil
forge script script/Deploy.s.sol --rpc-url anvil --broadcast

# Deploy to Mezo testnet
forge script script/Deploy.s.sol \
  --rpc-url mezo_testnet \
  --broadcast \
  --verify \
  --private-key $PRIVATE_KEY
```

### Run Tests

```bash
cd contracts
forge test -v          # all 92 tests
forge test --summary   # summary table
```

### Run EGARCH Service

```bash
# Set env vars first
export ORACLE_ADDRESS=0x...
export ENGINE_ADDRESS=0x...
export PRIVATE_KEY=0x...
export RPC_URL=http://127.0.0.1:8545

# Dry run (no transactions)
python -m services.egarch_service.main --dry-run --once

# Start scheduler (runs every hour)
python -m services.egarch_service.main
```

### Run Frontend

```bash
cp frontend/.env.example frontend/.env.local
# Fill in contract addresses

cd frontend
npm run dev     # dev server at http://localhost:5173
npm run build   # production build
```

---

## Contract Overview

| Contract | Description |
|---|---|
| `VolatilityOracle.sol` | Accepts EGARCH vol submissions, applies EMA, validates vs Chainlink feeds |
| `AdaptiveMCREngine.sol` | Computes composite MCR, enforces rate limits, optimistic proposal/challenge |
| `MezoIntegrationAdapter.sol` | Simulated CDP system for demo; production path delegates to live Mezo contracts |
| `RiskStewardsContract.sol` | Alternative governance implementation with packed regime storage |

---

## Test Coverage (92 tests, 0 failures)

```
AdaptiveMCREngineTest      27/27  ✓
MezoIntegrationAdapterTest 16/16  ✓
RiskStewardsContractTest   32/32  ✓
VolatilityOracleTest       17/17  ✓
```

---

## Research

The volatility model and protocol design are documented in `paper_draft.pdf`.
Key findings from the backtester:
- During Black Thursday (−50% in 24h): MCR rose from 110% to ~140%, reducing cascade liquidations by ~60% vs static baseline
- During May 2021 (−40% in 48h): Pre-buffer conditioning forced 23% of at-risk positions to top-up before the crash
- During FTX collapse (−30% in 72h): Circuit breaker engaged, MCR frozen at 135% for 48h, preventing premature loosening
