"""Supabase client factories.

Two trust levels:
  * get_supabase()                - SERVICE ROLE, bypasses RLS. Internal jobs
                                    only (DSVE market-data sync, watermarks).
                                    The DB triggers (zero-margin, append-only
                                    ledger, sum-to-100 DNA, latch) still apply.
  * get_user_supabase(token)      - publishable key + the end user's JWT.
                                    Every query runs under Row Level Security
                                    as that user, so even a bug in a filter
                                    cannot return another tenant's data.
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


def get_user_supabase(access_token: str) -> Client:
    """Per-request client scoped to the authenticated user (RLS enforced)."""
    settings = get_settings()
    if not settings.supabase_url or not settings.supabase_anon_key:
        raise RuntimeError(
            "SUPABASE_URL and SUPABASE_ANON_KEY must be set (see .env.example)"
        )
    client = create_client(settings.supabase_url, settings.supabase_anon_key)
    client.postgrest.auth(access_token)  # PostgREST now runs as this user
    return client
