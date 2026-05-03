"""
Fetches hourly BTC/USD price history.

Primary source:  CoinGecko free API (no key required, 30-day limit per call)
Fallback source: local CSV cache written by code/data/btc_data_generator.py
"""

from __future__ import annotations

import time
import logging
from pathlib import Path
from typing import Optional

import numpy as np
import pandas as pd
import requests

from . import config

logger = logging.getLogger(__name__)


def fetch_coingecko(days: int = 31) -> Optional[pd.Series]:
    """Return hourly BTC/USD close prices as a pd.Series indexed by timestamp."""
    params = {"vs_currency": "usd", "days": str(days), "interval": "hourly"}
    try:
        resp = requests.get(config.PRICE_API_URL, params=params, timeout=15)
        resp.raise_for_status()
        data = resp.json()
        prices = data.get("prices", [])
        if not prices:
            return None
        ts   = [p[0] / 1000 for p in prices]   # ms → s
        vals = [p[1]         for p in prices]
        series = pd.Series(vals, index=pd.to_datetime(ts, unit="s"), dtype=float)
        series.sort_index(inplace=True)
        logger.info("Fetched %d hourly prices from CoinGecko", len(series))
        return series
    except Exception as exc:
        logger.warning("CoinGecko fetch failed: %s", exc)
        return None


def load_local_cache() -> Optional[pd.Series]:
    """Fall back to the synthetic CSV produced by btc_data_generator.py."""
    candidates = [
        config.REPO_ROOT / "code" / "data" / "btc_hourly_2019_2025.csv",
        config.REPO_ROOT / "data" / "btc_prices.csv",
    ]
    for path in candidates:
        if path.exists():
            try:
                df = pd.read_csv(path, parse_dates=["timestamp"], index_col="timestamp")
                col = next((c for c in ["close", "price"] if c in df.columns), None)
                if col:
                    series = df[col].dropna().sort_index()
                    logger.info("Loaded %d rows from local cache: %s", len(series), path)
                    return series
            except Exception as exc:
                logger.warning("Local cache load failed (%s): %s", path, exc)
    return None


def get_hourly_prices(days: int = 31) -> pd.Series:
    """Return recent hourly BTC prices, trying live API then local fallback."""
    series = fetch_coingecko(days)
    if series is not None and len(series) >= 168:
        return series

    series = load_local_cache()
    if series is not None and len(series) >= 168:
        # Return only the tail corresponding to requested days
        cutoff = series.index[-1] - pd.Timedelta(days=days)
        return series[series.index >= cutoff]

    raise RuntimeError(
        "Unable to obtain BTC price history from any source. "
        "Run code/data/btc_data_generator.py to create a local cache."
    )


def prices_to_log_returns(prices: pd.Series) -> np.ndarray:
    """Convert price series to log returns."""
    return np.log(prices / prices.shift(1)).dropna().values


def current_btc_price_bps(prices: pd.Series) -> int:
    """
    Return latest BTC price in BPS-compatible format.
    Convention: raw USD price * 100 / 1e8 → same scale as Chainlink 8-dec.
    For simplicity in simulated mode we just pass the raw integer price.
    """
    return int(prices.iloc[-1])
