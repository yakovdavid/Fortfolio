"""In-memory TTL cache with single-flight semantics.

Purpose (per PRD section 1): prevent Thundering Herd against Yahoo
Finance and HTTP 429 rate limits. Guarantees:
  * A value younger than the TTL is served from memory - zero upstream calls.
  * Concurrent requests for the same expired key trigger EXACTLY ONE
    upstream fetch (per-key asyncio.Lock); the rest await the result.
  * If an upstream fetch fails and a stale value exists, the stale value
    is served as a graceful fallback (the SQL view still flags DATA_STALE
    via price_updated_at, so Golden Rule #3 is preserved downstream).
"""
import asyncio
import time
from typing import Any, Awaitable, Callable, Dict, Tuple


class SingleFlightTTLCache:
    def __init__(self, ttl_seconds: float):
        self._ttl = ttl_seconds
        self._data: Dict[str, Tuple[Any, float]] = {}   # key -> (value, expires_at)
        self._locks: Dict[str, asyncio.Lock] = {}
        self._locks_guard = asyncio.Lock()

    def _get_fresh(self, key: str):
        item = self._data.get(key)
        if item is not None and time.monotonic() < item[1]:
            return item[0]
        return None

    async def _lock_for(self, key: str) -> asyncio.Lock:
        async with self._locks_guard:
            lock = self._locks.get(key)
            if lock is None:
                lock = asyncio.Lock()
                self._locks[key] = lock
            return lock

    async def get_or_fetch(self, key: str, fetcher: Callable[[], Awaitable[Any]]) -> Any:
        value = self._get_fresh(key)
        if value is not None:
            return value

        lock = await self._lock_for(key)
        async with lock:
            # Double-checked after acquiring the lock: another coroutine
            # may have completed the fetch while we waited (single flight).
            value = self._get_fresh(key)
            if value is not None:
                return value
            try:
                value = await fetcher()
            except Exception:
                stale = self._data.get(key)
                if stale is not None:
                    return stale[0]        # stale-on-error grace
                raise
            self._data[key] = (value, time.monotonic() + self._ttl)
            return value

    def invalidate(self, key: str | None = None) -> None:
        if key is None:
            self._data.clear()
        else:
            self._data.pop(key, None)
