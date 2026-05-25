"""
EGARCH(1,1) Volatility Estimator
Uses the arch library for EGARCH estimation on hourly BTC returns.
Compares against EWMA (lambda=0.94) and rolling realized volatility.
Applies EMA smoothing (alpha=0.1) to suppress transient spikes.
"""

import numpy as np
import pandas as pd
from arch import arch_model
import warnings
warnings.filterwarnings('ignore')


class EGARCHEstimator:
    """
    EGARCH(1,1) volatility estimator with rolling window.

    Model: EGARCH(1,1) on hourly log returns
    - Captures volatility clustering and leverage effects
    - Rolling 30-day (720 hour) window for regime adaptation
    - EMA smoothing (alpha=0.1) on output to suppress spikes
    """

    def __init__(
        self,
        window_hours: int = 720,     # 30-day rolling window
        ema_alpha: float = 0.1,      # EMA smoothing factor
        min_obs: int = 168,          # Minimum observations (1 week)
        rescale_factor: float = 100  # Rescale returns to percentages
    ):
        self.window_hours = window_hours
        self.ema_alpha = ema_alpha
        self.min_obs = min_obs
        self.rescale_factor = rescale_factor

    def fit_egarch_window(self, returns: np.ndarray) -> float:
        """
        Fit EGARCH(1,1) to a window of returns and return
        the 1-step-ahead conditional volatility forecast (annualized).
        """
        if len(returns) < self.min_obs:
            return np.nan

        # Scale returns to percentages for numerical stability
        scaled = returns * self.rescale_factor

        try:
            model = arch_model(
                scaled,
                vol='EGARCH',
                p=1,
                q=1,
                dist='Normal',
                mean='Zero',
                rescale=False
            )
            result = model.fit(
                disp='off',
                show_warning=False,
                options={'maxiter': 200}
            )
            # Get conditional variance (in percentage^2)
            cond_var = result.conditional_volatility[-1]  # Already in % units
            # Convert to annualized: scale back from % and annualize
            hourly_vol = (cond_var / self.rescale_factor)
            annual_vol = hourly_vol * np.sqrt(365 * 24)
            return float(np.clip(annual_vol, 0.05, 10.0))
        except Exception:
            # Fallback to realized vol if EGARCH fails
            hourly_vol = np.std(returns)
            return float(np.clip(hourly_vol * np.sqrt(365 * 24), 0.05, 10.0))

    def compute_rolling_egarch(
        self,
        price_series: pd.Series,
        step: int = 24  # Refit every 24 hours for efficiency
    ) -> pd.Series:
        """
        Compute rolling EGARCH conditional volatility estimates.

        For efficiency, refits every `step` hours and interpolates between.
        """
        returns = price_series.pct_change().dropna()
        n = len(returns)
        vol_estimates = pd.Series(index=returns.index, dtype=float)

        print(f"  Computing EGARCH on {n} observations with {self.window_hours}h window...")

        # Compute at step intervals
        refit_points = list(range(self.window_hours, n, step))
        refit_vols = {}

        for i, idx in enumerate(refit_points):
            window = returns.iloc[idx - self.window_hours:idx].values
            vol = self.fit_egarch_window(window)
            refit_vols[idx] = vol
            if i % 50 == 0:
                print(f"    EGARCH progress: {i}/{len(refit_points)} ({100*i/len(refit_points):.0f}%)")

        # Fill in estimates by forward-filling between refit points
        indices = sorted(refit_vols.keys())
        for j, idx in enumerate(indices):
            start = idx
            end = indices[j+1] if j+1 < len(indices) else n
            vol_val = refit_vols[idx]
            for k in range(start, min(end, n)):
                vol_estimates.iloc[k] = vol_val

        # Apply EMA smoothing to suppress transient spikes
        vol_estimates = vol_estimates.ffill().bfill()
        vol_smoothed = vol_estimates.ewm(alpha=self.ema_alpha, adjust=False).mean()

        return vol_smoothed


class EWMAEstimator:
    """
    EWMA (RiskMetrics-style) volatility estimator.
    λ=0.94 for daily, adjusted for hourly frequency.
    """

    def __init__(self, lambda_param: float = 0.94):
        # Adjust lambda for hourly frequency
        # Daily lambda: 0.94 → hourly equivalent
        # λ_hourly = λ_daily^(1/24)
        self.lambda_daily = lambda_param
        self.lambda_hourly = lambda_param ** (1/24)

    def compute(self, price_series: pd.Series) -> pd.Series:
        """Compute EWMA variance and return annualized vol."""
        returns = price_series.pct_change().dropna()

        # Compute EWMA variance
        ewma_var = returns.ewm(
            alpha=1 - self.lambda_hourly,
            adjust=False
        ).var()

        # Annualize
        ewma_vol = np.sqrt(ewma_var * 365 * 24)
        return ewma_vol.clip(0.05, 10.0)


class RollingRealizedVol:
    """
    Rolling Realized Volatility from high-frequency returns.
    Uses 30-day (720h) window, annualized.
    """

    def __init__(self, window_hours: int = 720):
        self.window_hours = window_hours

    def compute(self, price_series: pd.Series) -> pd.Series:
        """Compute rolling realized volatility (annualized)."""
        returns = price_series.pct_change().dropna()
        rv = returns.rolling(window=self.window_hours, min_periods=24).std()
        rv_annual = rv * np.sqrt(365 * 24)
        return rv_annual.clip(0.05, 10.0)


class VolatilitySignalComparison:
    """
    Compare EGARCH, EWMA, and Realized Vol signals.
    Computes correlation, tracking error, and regime agreement.
    """

    def __init__(self):
        self.egarch = EGARCHEstimator()
        self.ewma = EWMAEstimator()
        self.rv = RollingRealizedVol()

    def compute_all_signals(
        self,
        df: pd.DataFrame,
        egarch_step: int = 48  # Refit EGARCH every 48h for speed
    ) -> pd.DataFrame:
        """Compute all volatility signals and return comparison DataFrame."""
        print("Computing EWMA volatility...")
        ewma_vol = self.ewma.compute(df['close'])

        print("Computing Realized Volatility...")
        rv_vol = self.rv.compute(df['close'])

        print("Computing EGARCH(1,1) volatility (this takes a few minutes)...")
        egarch_vol = self.egarch.compute_rolling_egarch(df['close'], step=egarch_step)

        signals = pd.DataFrame({
            'egarch': egarch_vol,
            'ewma': ewma_vol,
            'realized_vol': rv_vol,
            'close': df['close'],
        }).dropna()

        return signals

    def compute_signal_quality(self, signals: pd.DataFrame) -> dict:
        """Compute signal quality metrics."""
        valid = signals.dropna()

        corr_egarch_rv = valid['egarch'].corr(valid['realized_vol'])
        corr_ewma_rv = valid['ewma'].corr(valid['realized_vol'])
        corr_egarch_ewma = valid['egarch'].corr(valid['ewma'])

        # Regime agreement (% of time all three agree on high/low vol)
        threshold = valid['realized_vol'].median()
        regime_rv = (valid['realized_vol'] > threshold).astype(int)
        regime_eg = (valid['egarch'] > threshold).astype(int)
        regime_ew = (valid['ewma'] > threshold).astype(int)

        agreement = (regime_rv == regime_eg) & (regime_rv == regime_ew)

        return {
            'corr_egarch_rv': corr_egarch_rv,
            'corr_ewma_rv': corr_ewma_rv,
            'corr_egarch_ewma': corr_egarch_ewma,
            'regime_agreement': agreement.mean(),
            'egarch_mean': valid['egarch'].mean(),
            'ewma_mean': valid['ewma'].mean(),
            'rv_mean': valid['realized_vol'].mean(),
        }


def run_fast_egarch(price_series: pd.Series, window_hours: int = 720, step: int = 72) -> pd.Series:
    """
    Fast EGARCH computation for backtesting.
    Uses larger step size for speed, with interpolation.
    """
    estimator = EGARCHEstimator(window_hours=window_hours)
    return estimator.compute_rolling_egarch(price_series, step=step)
