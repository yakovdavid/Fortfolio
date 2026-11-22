# Fortfolio Backend (Phase 2.1 - Core Engines + SaaS Auth)

FastAPI middleware + DSVE (Data Sync & Valuation Engine).

## Architecture

```
Yahoo Finance ──► MarketDataService ──► DSVE ──► Supabase (raw prices + fx_rates)
                                                  │  (latch trigger: RECOVERY -> TRAILING)
   (yfinance)     (15-min TTL cache,              │
                   single-flight,                 ▼
                   429 backoff)          ui_pipeline_metrics VIEW
                                         (normalization, weights,
                                          defense statuses)
                                                  │
                                                  ▼
                                         FastAPI read endpoints
```

Division of responsibility: the backend writes **RAW** provider prices
(Agorot for TASE). All normalization (Agorot/100, calibration factor,
FX, weights, defense statuses) happens once, in the SQL view. The single
exception is `risk_profiles.peak_price`, stored normalized by the weekly
watermark job.

## Run

```bash
cd backend
python -m venv .venv && source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt
cp .env.example .env                                 # fill in Supabase credentials
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

## Auth model (Phase 2.1)

| Caller | Credential | Identity |
| --- | --- | --- |
| End user (Expo client) | `Authorization: Bearer <Supabase access token>` | `sub` claim of the verified JWT - never the URL |
| Internal jobs / admin | `X-API-Key` (`BACKEND_API_KEY`) | service |

* JWT verification: issuer `{SUPABASE_URL}/auth/v1`, audience `authenticated`,
  role `authenticated`, expiry. Asymmetric keys via JWKS (default); legacy
  HS256 only if `SUPABASE_JWT_SECRET` is set. `alg=none` is rejected.
* User reads go through a per-request Supabase client built from the
  publishable key + the user's JWT, so Row Level Security applies (defense in
  depth on top of the explicit `user_id` filter).
* The service-role client is used only by the DSVE sync and watermark jobs.
* `X-API-Key` fails closed when `BACKEND_API_KEY` is empty.

## Endpoints

| Method | Path | Auth | Purpose |
| --- | --- | --- | --- |
| GET | `/ping` | none | Health check / cold-start prevention |
| GET | `/me/metrics` | Bearer JWT | Per-asset rows from ui_pipeline_metrics |
| GET | `/me/summary` | Bearer JWT | Layers, drift, alerts, cash, buying power |
| GET | `/me/buying-power` | Bearer JWT | Golden Rule #1 read model |
| POST | `/internal/sync` | X-API-Key | Manual DSVE market-data sync |
| POST | `/internal/sync/watermarks?force=` | X-API-Key | Manual weekly watermark run (TRAILING positions only) |
| GET | `/internal/quotes/{symbol}` | X-API-Key | Debug quote (raw + normalized) |

Removed in 2.1: `/portfolio/{user_id}/*` (identity from the URL is not
acceptable in a multi-tenant system).

The scheduler runs a sync every `SYNC_INTERVAL_SECONDS` (default 15 min)
and attempts the weekly watermark job each cycle (executes only on
`WATERMARK_UPDATE_WEEKDAY`, skips watermarks already updated this week).

## Tests

```bash
pip install -r requirements.txt -r requirements-dev.txt
pytest -q                      # JWT verification suite
```

Database: `database/tests/` holds a local Supabase stub and the Phase 2.1
acceptance suite (run against a scratch PostgreSQL 15+, never against Supabase).
