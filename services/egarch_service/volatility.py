"""
Compute EGARCH(1,1) volatility and convert to BPS for on-chain submission.

Wraps code/models/egarch_estimator.py with the extra logic needed by the
service: BPS conversion, fallback to EWMA when EGARCH diverges, and the
same EMA smoothing that the on-chain VolatilityOracle applies (so the
service can predict what the smoothed value will be after submission).
"""

from __future__ import annotations

import sys
import logging
from pathlib import Path

import numpy as np

# Make code/ importable when running from services/
_code_path = Path(__file__).resolve().parents[2] / "code"
if str(_code_path) not in sys.path:
    sys.path.insert(0, str(_code_path))

from models.egarch_estimator import EGARCHEstimator, EWMAEstimator  # noqa: E402
from . import config  # noqa: E402

logger = logging.getLogger(__name__)

VOL_MIN_BPS = 500
VOL_MAX_BPS = 50_000
EMA_ALPHA   = 1000   # same as on-chain: alpha = 1000/10000 = 0.1
EMA_DENOM   = 10_000


def annual_vol_to_bps(annual_vol: float) -> int:
    """Convert fractional annualized vol (e.g. 0.45) to BPS (4500)."""
    bps = int(round(annual_vol * 10_000))
    return max(VOL_MIN_BPS, min(VOL_MAX_BPS, bps))


def estimate_vol_bps(log_returns: np.ndarray) -> int:
    """
    Run EGARCH(1,1) on log_returns; fall back to EWMA if EGARCH fails.
    Returns vol in BPS, clamped to [VOL_MIN_BPS, VOL_MAX_BPS].
    """
    estimator = EGARCHEstimator(
        window_hours=config.EGARCH_WINDOW_HOURS,
        ema_alpha=config.EGARCH_EMA_ALPHA,
        min_obs=config.EGARCH_MIN_OBS,
    )

    # Use the last window_hours of data
    window = log_returns[-config.EGARCH_WINDOW_HOURS:]

    try:
        annual_vol = estimator.fit_egarch_window(window)
        if np.isnan(annual_vol) or annual_vol <= 0:
            raise ValueError("EGARCH returned nan/negative vol")
        logger.info("EGARCH vol estimate: %.2f%%", annual_vol * 100)
        return annual_vol_to_bps(annual_vol)
    except Exception as exc:
        logger.warning("EGARCH failed (%s), falling back to EWMA", exc)

    # EWMA fallback
    ewma = EWMAEstimator(lambda_=0.94)
    try:
        ewma_vol = ewma.compute_ewma_vol(window)
        if isinstance(ewma_vol, np.ndarray):
            ewma_vol = float(ewma_vol[-1])
        # EWMA gives hourly vol; annualize
        annual_ewma = float(ewma_vol) * np.sqrt(365 * 24)
        logger.info("EWMA fallback vol: %.2f%%", annual_ewma * 100)
        return annual_vol_to_bps(annual_ewma)
    except Exception as exc2:
        logger.error("EWMA also failed (%s); using realized vol", exc2)

    # Last resort: rolling std
    rv = float(np.std(window[-168:])) * np.sqrt(365 * 24)
    return annual_vol_to_bps(rv)


def predict_smoothed(current_smoothed_bps: int, new_raw_bps: int) -> int:
    """
    Predict what the on-chain smoothedVolBPS will be after submitVolatility.
    Mirrors the VolatilityOracle EMA formula exactly.
    """
    raw_clamped = max(VOL_MIN_BPS, min(VOL_MAX_BPS, new_raw_bps))
    predicted = (raw_clamped * EMA_ALPHA + current_smoothed_bps * (EMA_DENOM - EMA_ALPHA)) // EMA_DENOM
    return predicted
