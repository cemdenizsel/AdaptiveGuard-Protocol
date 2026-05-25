# AdaptiveGuard Protocol

> EGARCH(1,1)-driven adaptive Minimum Collateral Ratio (MCR) for MUSD — Mezo Hackathon 2025 (Bitcoin Track)

> **This implementation is the direct realization of a scientific research paper.** The volatility model, four-regime MCR mapping, composite risk adjustments, and backtesting methodology are all formally documented in [`paper_draft.pdf`](paper_draft.pdf) in this repository. Every design decision in the code — the EGARCH(1,1) estimator, the EMA smoothing with α=0.1, the ±5pp rate limiter, the 15%/12h circuit breaker trigger — derives from the model described in the paper. Read the paper first if you want to understand why the protocol is designed the way it is.

AdaptiveGuard replaces the static 110% MCR used in Bitcoin-backed stablecoin systems with a volatility-responsive ratio that rises ahead of market crashes and relaxes during calm periods. The result: fewer liquidation cascades, a deeper Stability Pool, and a more resilient peg.

**Live on Mezo Testnet (chain 31611)** — contracts are deployed and running. No deployment needed to test.

---

## Live Deployed Contracts

| Contract | Address | Explorer |
|---|---|---|
| VolatilityOracle | `0xe3896186c616675E6cc527539001342Fae0Bb9B5` | [view](https://explorer.test.mezo.org/address/0xe3896186c616675E6cc527539001342Fae0Bb9B5) |
| AdaptiveMCREngine | `0x3D03ba16776C69d23452397bfc841824a06EF691` | [view](https://explorer.test.mezo.org/address/0x3D03ba16776C69d23452397bfc841824a06EF691) |
| MezoIntegrationAdapter | `0x112B2F5135CE6C8BaF83571971171b2Af0B752Bc` | [view](https://explorer.test.mezo.org/address/0x112B2F5135CE6C8BaF83571971171b2Af0B752Bc) |

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Off-chain EGARCH service (Python, runs every hour)      │
│  • Fetches BTC price history from CoinGecko              │
│  • Fits EGARCH(1,1) → annualized vol in BPS              │
│  • Submits vol to VolatilityOracle                       │
│  • Pushes BTC price to MezoIntegrationAdapter            │
│  • Proposes MCR update to AdaptiveMCREngine              │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│  On-chain (Solidity, Mezo testnet)                       │
│                                                          │
│  VolatilityOracle ──────────► AdaptiveMCREngine          │
│  • EMA smoothing (α=0.1)      • Four-regime MCR mapping  │
│  • Outlier rejection          • ±5pp rate limiter        │
│                               • 4h decrease cooldown     │
│                               • 12h circuit breaker      │
│                               • 1h challenge window      │
│                                      │                   │
│                        MezoIntegrationAdapter            │
│                        • Reads live TCR from TroveManager│
│                        • Reads live SP depth from SP     │
│                        • Bridges AdaptiveGuard ↔ Mezo   │
└─────────────────────────────────────────────────────────┘
                          ▲
┌─────────────────────────────────────────────────────────┐
│  React Dashboard (Vite + Tailwind + ethers.js)           │
│  • Live MCR / vol / TCR / SP depth display               │
│  • CDP Manager — open real troves, mint testnet MUSD     │
│  • Calls Mezo BorrowerOperations directly from wallet    │
│  • Adaptive MCR enforced at the UI level                 │
└─────────────────────────────────────────────────────────┘
```

## MCR Mapping (Four Regimes)

| Annualized Vol | MCR |
|---|---|
| < 30% | 110% |
| 30–60% | linear 110% → 125% |
| 60–90% | linear 125% → 140% |
| ≥ 90% | 140% → 160% |

Composite adjustments on top:
- **SP depth** < 10% → +5pp; < 20% → +2pp
- **TCR near CCR (150%)** → up to +10pp
- **Rate limiter**: ±5pp per epoch, 4h cooldown between decreases
- **Circuit breaker**: >15% BTC drop in 12h → freeze MCR for 48h

---

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node 18+ / npm
- Python 3.10+
- [uv](https://docs.astral.sh/uv/getting-started/installation/)
- MetaMask (for testnet UI)

---

## Quickstart — Mezo Testnet (recommended)

Contracts are already deployed. You only need a wallet with testnet BTC.

**1. Add Mezo Testnet to MetaMask**

| Field | Value |
|---|---|
| Network name | Mezo Testnet |
| RPC URL | `https://rpc.test.mezo.org` |
| Chain ID | `31611` |
| Currency symbol | `BTC` |
| Block explorer | `https://explorer.test.mezo.org` |

**2. Get testnet BTC**

Visit [faucet.test.mezo.org](https://faucet.test.mezo.org) and request testnet BTC for your wallet.

**3. Configure environment**

```bash
cp .env.testnet.example .env.testnet
# Edit .env.testnet — fill in PRIVATE_KEY and DAO_ADDRESS with your wallet
# All contract addresses are pre-filled and ready to use
```

**4. Install dependencies**

```bash
# Frontend
cd frontend && npm install && cd ..

# Python (uv handles this automatically on first run)
uv sync
```

**5. Run**

```bash
# Start UI + EGARCH dry-run (no transactions)
./scripts/run_testnet.sh --dry-run

# Start UI + live EGARCH service (submits vol every hour)
./scripts/run_testnet.sh
```

Open **http://localhost:5173** — navigate to CDP Manager to open a real trove and mint testnet MUSD.

---

## Quickstart — Local Demo (Anvil)

No testnet BTC needed. Uses a local chain with simulated positions.

```bash
# Install Foundry deps
cd contracts && forge install && forge build && cd ..

# Install frontend deps
cd frontend && npm install && cd ..

# One command: starts Anvil, deploys contracts, runs EGARCH dry-run, opens UI
./scripts/run_local.sh
```

Open **http://localhost:5173**.

---

## Manual Workflows

### Run Tests

```bash
cd contracts
forge test -v         # all tests with output
forge test --summary  # pass/fail table
```

### Deploy Contracts (only needed if redeploying)

```bash
cd contracts

# To Mezo testnet
forge script script/Deploy.s.sol \
  --rpc-url https://rpc.test.mezo.org \
  --broadcast \
  --private-key 0x<your_key>

# Redeploy adapter only (wires live Mezo contracts)
forge script script/DeployAdapter.s.sol \
  --rpc-url https://rpc.test.mezo.org \
  --broadcast \
  --private-key 0x<your_key>
```

### Run EGARCH Service Manually

```bash
# Single cycle, no transactions
uv run python -m services.egarch_service.main --dry-run --once

# Single live cycle (sends transactions)
source .env.testnet && PRIVATE_KEY="0x${PRIVATE_KEY}" \
  uv run python -m services.egarch_service.main --once

# Continuous (every hour)
uv run python -m services.egarch_service.main
```

### Run Frontend Only

```bash
cd frontend
npm run dev    # http://localhost:5173
npm run build  # production build → dist/
```

---

## How Real MUSD Minting Works

The CDP Manager connects directly to Mezo's `BorrowerOperations` contract from the user's wallet. The flow:

1. User enters BTC collateral amount and MUSD to borrow
2. Frontend computes sorted-list hints via `HintHelpers` + `SortedTroves`
3. User's wallet calls `BorrowerOperations.openTrove(maxFee, musdAmount, upperHint, lowerHint)` with BTC as `msg.value`
4. Mezo protocol mints MUSD directly to the user's wallet
5. AdaptiveGuard reads the resulting TCR and SP depth to inform the next MCR proposal

Minimum: **1800 MUSD** borrowed (Mezo adds 200 MUSD gas compensation automatically).

---

## Contract Overview

| Contract | Description |
|---|---|
| `VolatilityOracle.sol` | Accepts EGARCH vol submissions, applies EMA smoothing (α=0.1), supports optional Chainlink RV/DVOL validation |
| `AdaptiveMCREngine.sol` | Maps smoothed vol to MCR regime, enforces rate limiter + circuit breaker, optimistic 1h challenge window |
| `MezoIntegrationAdapter.sol` | Reads live TCR/SP from Mezo TroveManager/StabilityPool; caches BTC price; bridges AdaptiveGuard ↔ Mezo |
| `RiskStewardsContract.sol` | Alternative governance implementation with packed regime storage and steward voting |

---

## Test Coverage

```
AdaptiveMCREngineTest         ✓
MezoIntegrationAdapterTest    ✓
RiskStewardsContractTest      ✓
VolatilityOracleTest          ✓
```

Run `forge test --summary` for the full pass/fail table.

---

## Research

The volatility model and protocol design are documented in `paper_draft.pdf`.

Key backtesting results vs static 110% MCR baseline:
- **Black Thursday** (−51.6% drawdown): bad debt −72.6%, cascade depth −59.1%
- **May 2021** (−48.0% drawdown): bad debt −67.6%, cascade depth −58.3%
- **FTX collapse** (−27.1% drawdown): bad debt eliminated entirely (−100%), cascade depth −80.0%
