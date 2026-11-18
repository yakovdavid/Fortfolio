"""Supabase client factory (service role).

The backend is a trusted middleware service: it uses the service-role key,
which bypasses RLS. The database triggers (zero-margin, append-only ledger,
sum-to-100 DNA) still apply to every write - the guardrails are enforced
by PostgreSQL itself, not by trust in this service.
"""
from functools import lru_cache

from supabase import Client, create_client

from .config import get_settings


@lru_cache
def get_supabase() -> Client:
    settings = get_settings()
    if not settings.supabase_url or not settings.supabase_service_role_key:
        raise RuntimeError(
            "SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set "
            "(see .env.example)"
        )
    return create_client(settings.supabase_url, settings.supabase_service_role_key)
