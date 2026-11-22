"""Application settings.

All values are environment-driven (12-factor). Nothing financial is
hardcoded here: allocation DNA, liquidity rules and reserve amounts live
in the database (user_settings / allocation_layers), never in the backend.
"""
from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # --- Supabase ---
    supabase_url: str = ""
    # Service role: used ONLY by internal jobs (DSVE sync, watermarks). Bypasses RLS.
    supabase_service_role_key: str = ""
    # Publishable (anon) key: used for end-user reads, combined with the
    # user's own JWT so Row Level Security applies (defense in depth).
    supabase_anon_key: str = ""
    # Optional. Set ONLY if the project still signs tokens with the legacy
    # HS256 shared secret. Projects on asymmetric signing keys verify via JWKS.
    supabase_jwt_secret: str = ""

    # --- Internal service-to-service auth (X-API-Key). Never ship to clients. ---
    backend_api_key: str = ""

    # --- CORS (Expo web / dev). Comma-separated origins; empty = no browser access. ---
    cors_allowed_origins: str = ""

    # --- Market data / DSVE ---
    market_data_ttl_minutes: int = 15      # Golden Rule #3: freshness window
    sync_interval_seconds: int = 900       # background DSVE cycle (15 min)
    quote_concurrency: int = 4             # parallel Yahoo requests (429 protection)
    yahoo_max_retries: int = 3             # exponential backoff on failures

    # --- Weekly trailing-stop watermark job ---
    # Python weekday: Monday=0 ... Saturday=5. Saturday is after both the
    # TASE weekly close (Thursday) and the US weekly close (Friday).
    watermark_update_weekday: int = 5


    @property
    def cors_origins(self) -> list[str]:
        return [o.strip() for o in self.cors_allowed_origins.split(",") if o.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()
