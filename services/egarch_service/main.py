"""
AdaptiveGuard Off-Chain EGARCH Service
======================================
Runs every hour:
  1. Fetch latest BTC prices
  2. Estimate EGARCH volatility
  3. Submit vol to VolatilityOracle
  4. Fetch system stats (SP depth, TCR) from MezoIntegrationAdapter
  5. Propose MCR update to AdaptiveMCREngine
  6. After 1-hour challenge window: apply the pending proposal

Usage:
    # Start the service (blocks indefinitely)
    python -m services.egarch_service.main

    # Single dry-run (no transactions sent)
    python -m services.egarch_service.main --dry-run

    # Single cycle then exit
    python -m services.egarch_service.main --once
"""

from __future__ import annotations

import argparse
import logging
import time
import sys

from . import config
from .price_fetcher import get_hourly_prices, prices_to_log_returns, current_btc_price_bps
from .volatility import estimate_vol_bps
from .chain import connect, get_oracle, get_engine, get_adapter, send_tx

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("adaptiveguard.service")


def run_cycle(dry_run: bool = False) -> dict:
    """Execute one full MCR proposal cycle. Returns a status dict."""
    status: dict = {}

    # ── 1. Price data + EGARCH ────────────────────────────────────────────────
    logger.info("=== AdaptiveGuard MCR Cycle ===")
    prices = get_hourly_prices(days=config.PRICE_HISTORY_DAYS)
    log_returns = prices_to_log_returns(prices)
    btc_price = current_btc_price_bps(prices)

    vol_bps = estimate_vol_bps(log_returns)
    status["vol_bps"]   = vol_bps
    status["btc_price"] = btc_price
    logger.info("Vol estimate: %d BPS (%.1f%%)  |  BTC price: $%s",
                vol_bps, vol_bps / 100, btc_price)

    if dry_run:
        logger.info("[DRY-RUN] Skipping on-chain transactions")
        status["dry_run"] = True
        return status

    # ── 2. Connect to chain ───────────────────────────────────────────────────
    if not config.PRIVATE_KEY:
        raise RuntimeError("PRIVATE_KEY env var not set")
    if not config.ORACLE_ADDRESS:
        raise RuntimeError("ORACLE_ADDRESS env var not set. Deploy contracts first.")

    w3      = connect()
    oracle  = get_oracle(w3)
    engine  = get_engine(w3)
    adapter = get_adapter(w3) if config.ADAPTER_ADDRESS else None

    # ── 3. Check oracle health before submitting ──────────────────────────────
    is_healthy = oracle.functions.isHealthy().call()
    logger.info("Oracle healthy: %s", is_healthy)

    # ── 4. Submit vol to VolatilityOracle ─────────────────────────────────────
    logger.info("Submitting vol %d BPS to oracle...", vol_bps)
    tx = send_tx(w3, oracle.functions.submitVolatility(vol_bps))
    status["oracle_tx"] = tx
    logger.info("Oracle updated: %s", tx)

    # ── 5. Get system stats ───────────────────────────────────────────────────
    sp_depth_bps = config.STATIC_SP_DEPTH_BPS
    tcr_bps      = config.STATIC_TCR_BPS

    if adapter is not None:
        try:
            tcr_bps, sp_depth_bps, _ = adapter.functions.getSystemStats().call()
            logger.info("Live stats — TCR: %d BPS, SP depth: %d BPS", tcr_bps, sp_depth_bps)
        except Exception as exc:
            logger.warning("Could not read adapter stats (%s); using defaults", exc)

    status["sp_depth_bps"] = sp_depth_bps
    status["tcr_bps"]      = tcr_bps

    # ── 6. Check if engine already has a pending proposal ────────────────────
    has_pending = engine.functions.hasPending().call()
    if has_pending:
        logger.info("Pending proposal already exists — attempting to apply it")
        try:
            tx = send_tx(w3, engine.functions.applyPendingProposal())
            status["apply_tx"] = tx
            logger.info("Applied pending proposal: %s", tx)
        except Exception as exc:
            logger.warning("Apply failed (window still open?): %s", exc)
        return status

    # ── 7. Propose MCR update ─────────────────────────────────────────────────
    current_mcr = engine.functions.currentMCR().call()
    logger.info("Current MCR: %.2f%%", current_mcr / 1e18 * 100)

    try:
        tx = send_tx(
            w3,
            engine.functions.proposeMCRUpdate(sp_depth_bps, tcr_bps, btc_price),
        )
        status["propose_tx"] = tx
        logger.info("Proposal submitted: %s", tx)
    except Exception as exc:
        logger.error("proposeMCRUpdate failed: %s", exc)
        status["error"] = str(exc)

    return status


def apply_if_ready(dry_run: bool = False) -> bool:
    """Try to apply a pending proposal. Returns True if applied."""
    if dry_run:
        return False
    try:
        w3     = connect()
        engine = get_engine(w3)
        if not engine.functions.hasPending().call():
            return False
        tx = send_tx(w3, engine.functions.applyPendingProposal())
        logger.info("Applied pending proposal: %s", tx)
        return True
    except Exception as exc:
        logger.debug("Apply not ready yet: %s", exc)
        return False


def main():
    parser = argparse.ArgumentParser(description="AdaptiveGuard EGARCH service")
    parser.add_argument("--dry-run", action="store_true",
                        help="Compute vol but skip on-chain transactions")
    parser.add_argument("--once", action="store_true",
                        help="Run a single cycle then exit")
    args = parser.parse_args()

    if args.once:
        result = run_cycle(dry_run=args.dry_run)
        logger.info("Cycle result: %s", result)
        return

    logger.info("Starting AdaptiveGuard EGARCH service (interval=%ds)",
                config.UPDATE_INTERVAL_SECONDS)

    # Track when the last proposal was made so we can attempt apply ~1h later
    last_propose_time: float = 0.0

    while True:
        try:
            now = time.time()

            # Try to apply a pending proposal if ~1h has passed
            if last_propose_time > 0 and now - last_propose_time >= config.APPLY_DELAY_SECONDS:
                applied = apply_if_ready(dry_run=args.dry_run)
                if applied:
                    last_propose_time = 0.0

            # Run the proposal cycle
            result = run_cycle(dry_run=args.dry_run)
            if "propose_tx" in result:
                last_propose_time = time.time()

        except KeyboardInterrupt:
            logger.info("Shutting down.")
            sys.exit(0)
        except Exception as exc:
            logger.error("Cycle error: %s", exc, exc_info=True)

        logger.info("Sleeping %ds until next cycle...", config.UPDATE_INTERVAL_SECONDS)
        time.sleep(config.UPDATE_INTERVAL_SECONDS)


if __name__ == "__main__":
    main()
