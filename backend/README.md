# Fortfolio Backend (Phase 2 - Core Engines)

FastAPI middleware + DSVE (Data Sync & Valuation Engine).

## Architecture

```
Yahoo Finance ──► MarketDataService ──► DSVE ──► Supabase (raw prices + fx_rates)
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

## Endpoints

| Method | Path | Auth | Purpose |
| --- | --- | --- | --- |
| GET | `/ping` | none | Health check / cold-start prevention |
| POST | `/sync` | X-API-Key | Manual DSVE market-data sync |
| POST | `/sync/watermarks?force=` | X-API-Key | Manual weekly watermark run |
| GET | `/portfolio/{user_id}/metrics` | X-API-Key | Per-asset rows from ui_pipeline_metrics |
| GET | `/portfolio/{user_id}/summary` | X-API-Key | Layers, drift, alerts, cash, buying power |
| GET | `/portfolio/{user_id}/buying-power` | X-API-Key | Golden Rule #1 read model |
| GET | `/quotes/{symbol}` | X-API-Key | Debug quote (raw + normalized) |

The scheduler runs a sync every `SYNC_INTERVAL_SECONDS` (default 15 min)
and attempts the weekly watermark job each cycle (executes only on
`WATERMARK_UPDATE_WEEKDAY`, skips watermarks already updated this week).
