"""Yahoo Finance market-data adapter.

Responsibilities:
  * Fetch quotes (last price, 52-week high, currency) with retry/backoff.
  * Fetch FX rates (e.g. USDILS=X) for multi-currency normalization.
  * Fetch weekly closes for the trailing-stop watermark (Satellites).

IMPORTANT - division of responsibility (Golden Rule #3):
  The database stores RAW provider prices. For TASE symbols (.TA) Yahoo
  quotes in Agorot; the Agorot->ILS division by 100 and the calibration
  factor are applied in ONE canonical place: the ui_pipeline_metrics SQL
  view. This module only mirrors that formula (normalize_price) where the
  backend itself needs a normalized number - i.e. the weekly watermark,
  which is stored normalized in risk_profiles.peak_price.
"""
import asyncio
import logging
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Optional

import yfinance as yf

from .cache import SingleFlightTTLCache
from .config import get_settings

logger = logging.getLogger("fortfolio.market_data")

TASE_SUFFIX = ".TA"
AGOROT_DIVISOR = 100.0


@dataclass(frozen=True)
class Quote:
    symbol: str
    price: float                 # RAW provider price (Agorot for .TA symbols)
    high_52w: Optional[float]    # RAW provider price
    currency: Optional[str]      # 'ILA' = Agorot on TASE
    fetched_at: str              # ISO 8601 UTC


def is_tase_symbol(symbol: str) -> bool:
    return symbol.upper().endswith(TASE_SUFFIX)


def normalize_price(raw_price: float, *, tase: bool, calibration_factor: float = 1.0) -> float:
    """Mirror of the SQL view formula:
    TASE:  (raw * calibration_factor) / 100  -> clean ILS
    other:  raw * calibration_factor
    """
    value = raw_price * calibration_factor
    return value / AGOROT_DIVISOR if tase else value


def _fast_info_get(fast_info, *names):
    """fast_info exposes values as attributes and/or dict keys depending on
    the yfinance version - try both forms defensively."""
    for name in names:
        try:
            value = getattr(fast_info, name)
            if value is not None:
                return value
        except Exception:
            pass
        try:
            value = fast_info[name]
            if value is not None:
                return value
        except Exception:
            pass
    return None


def _with_retries(fn, symbol: str):
    """Run a synchronous Yahoo call with exponential backoff (429 protection)."""
    settings = get_settings()
    last_err: Exception | None = None
    for attempt in range(settings.yahoo_max_retries):
        try:
            return fn()
        except Exception as err:  # includes HTTP 429 / transient network errors
            last_err = err
            wait = 2 ** attempt
            logger.warning("Yahoo fetch failed for %s (attempt %d): %s - retrying in %ss",
                           symbol, attempt + 1, err, wait)
            time.sleep(wait)
    raise RuntimeError(f"Yahoo Finance fetch failed for {symbol}: {last_err}")


def _fetch_quote_sync(symbol: str) -> Quote:
    def _do() -> Quote:
        ticker = yf.Ticker(symbol)
        fi = ticker.fast_info
        price = _fast_info_get(fi, "last_price", "lastPrice")
        high = _fast_info_get(fi, "year_high", "yearHigh")
        currency = _fast_info_get(fi, "currency")

        if price is None or float(price) <= 0:
            # Fallback path for instruments with broken fast_info:
            hist = ticker.history(period="5d")["Close"].dropna()
            if hist.empty:
                raise ValueError(f"No price data returned for {symbol}")
            price = float(hist.iloc[-1])
        if high is None:
            hist_1y = ticker.history(period="1y")["High"].dropna()
            high = float(hist_1y.max()) if not hist_1y.empty else None

        return Quote(
            symbol=symbol,
            price=float(price),
            high_52w=float(high) if high is not None else None,
            currency=str(currency) if currency else None,
            fetched_at=datetime.now(timezone.utc).isoformat(),
        )

    return _with_retries(_do, symbol)


def _fetch_weekly_close_sync(symbol: str) -> float:
    """Latest weekly close. The DSVE scheduler only calls this on the
    configured watermark day (default Saturday), after both the TASE
    (Thursday) and US (Friday) weekly closes - so the last weekly bar is a
    COMPLETED week, never an intraday value (Satellite protocol: weekly
    close only, no short-term noise)."""
    def _do() -> float:
        closes = yf.Ticker(symbol).history(period="3mo", interval="1wk")["Close"].dropna()
        if closes.empty:
            raise ValueError(f"No weekly data returned for {symbol}")
        return float(closes.iloc[-1])

    return _with_retries(_do, symbol)


class MarketDataService:
    def __init__(self) -> None:
        settings = get_settings()
        self._cache = SingleFlightTTLCache(ttl_seconds=settings.market_data_ttl_minutes * 60)
        self._semaphore = asyncio.Semaphore(settings.quote_concurrency)

    async def get_quote(self, symbol: str) -> Quote:
        async def fetch() -> Quote:
            async with self._semaphore:
                return await asyncio.to_thread(_fetch_quote_sync, symbol)
        return await self._cache.get_or_fetch(f"quote:{symbol}", fetch)

    async def get_fx_rate(self, base: str, quote: str) -> float:
        """Rate converting 1 unit of `base` into `quote` (e.g. USD->ILS)."""
        base, quote = base.upper(), quote.upper()
        if base == quote:
            return 1.0
        symbol = f"{base}{quote}=X"

        async def fetch() -> float:
            async with self._semaphore:
                q = await asyncio.to_thread(_fetch_quote_sync, symbol)
                return q.price
        return await self._cache.get_or_fetch(f"fx:{symbol}", fetch)

    async def get_weekly_close(self, symbol: str) -> float:
        async with self._semaphore:
            return await asyncio.to_thread(_fetch_weekly_close_sync, symbol)

    def invalidate_cache(self) -> None:
        self._cache.invalidate()


market_data = MarketDataService()
