"""Application settings.

All values are environment-driven (12-factor). Nothing financial is
hardcoded here: allocation DNA, liquidity rules and reserve amounts live
in the database (user_settings / allocation_layers), never in the backend.
"""
from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # --- Supabase (service role bypasses RLS; backend is a trusted service) ---
    supabase_url: str = ""
    supabase_service_role_key: str = ""

    # --- API protection for mutating/data endpoints (X-API-Key header) ---
    backend_api_key: str = "change-me"

    # --- Market data / DSVE ---
    market_data_ttl_minutes: int = 15      # Golden Rule #3: freshness window
    sync_interval_seconds: int = 900       # background DSVE cycle (15 min)
    quote_concurrency: int = 4             # parallel Yahoo requests (429 protection)
    yahoo_max_retries: int = 3             # exponential backoff on failures

    # --- Weekly trailing-stop watermark job ---
    # Python weekday: Monday=0 ... Saturday=5. Saturday is after both the
    # TASE weekly close (Thursday) and the US weekly close (Friday).
    watermark_update_weekday: int = 5


@lru_cache
def get_settings() -> Settings:
    return Settings()
