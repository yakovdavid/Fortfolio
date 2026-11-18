"""Fortfolio 2.0 - FastAPI middleware server.

Endpoints:
  GET  /ping                            health check (cold-start prevention, no auth)
  POST /sync                            manual DSVE market-data sync
  POST /sync/watermarks?force=false     manual weekly watermark run
  GET  /portfolio/{user_id}/metrics     ui_pipeline_metrics rows (per asset)
  GET  /portfolio/{user_id}/summary     dashboard aggregate (layers, drift, alerts, cash)
  GET  /portfolio/{user_id}/buying-power  Golden Rule #1 read model
  GET  /quotes/{symbol}                 debug quote (raw + normalized display value)

The background scheduler runs the DSVE sync every SYNC_INTERVAL_SECONDS and
attempts the weekly watermark job each cycle (self-guarded: it only executes
on the configured weekday and skips fresh watermarks).
"""
import asyncio
import logging
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, Header, HTTPException, Query

from .config import get_settings
from .dsve import dsve
from .market_data import is_tase_symbol, market_data, normalize_price

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
logger = logging.getLogger("fortfolio.main")


# --------------------------------------------------------------------------- #
# Auth (simple service-to-service API key)                                    #
# --------------------------------------------------------------------------- #
def require_api_key(x_api_key: str = Header(default="")) -> None:
    if x_api_key != get_settings().backend_api_key:
        raise HTTPException(status_code=401, detail="Invalid or missing X-API-Key")


# --------------------------------------------------------------------------- #
# Background scheduler                                                        #
# --------------------------------------------------------------------------- #
async def _scheduler_loop() -> None:
    settings = get_settings()
    while True:
        try:
            await dsve.sync_market_data()
        except Exception as err:
            logger.error("Scheduled DSVE sync failed: %s", err)
        try:
            await dsve.update_weekly_watermarks()  # self-guarded (weekday + freshness)
        except Exception as err:
            logger.error("Scheduled watermark run failed: %s", err)
        await asyncio.sleep(settings.sync_interval_seconds)


@asynccontextmanager
async def lifespan(app: FastAPI):
    task = asyncio.create_task(_scheduler_loop())
    logger.info("DSVE scheduler started (interval=%ss)", get_settings().sync_interval_seconds)
    try:
        yield
    finally:
        task.cancel()


app = FastAPI(title="Fortfolio Backend", version="2.0.0", lifespan=lifespan)


# --------------------------------------------------------------------------- #
# Health (cold-start prevention - keep unauthenticated and cheap)             #
# --------------------------------------------------------------------------- #
@app.get("/ping")
async def ping() -> dict:
    return {"status": "ok", "service": "fortfolio-backend", "version": "2.0.0"}


# --------------------------------------------------------------------------- #
# DSVE controls                                                               #
# --------------------------------------------------------------------------- #
@app.post("/sync", dependencies=[Depends(require_api_key)])
async def trigger_sync() -> dict:
    return await dsve.sync_market_data()


@app.post("/sync/watermarks", dependencies=[Depends(require_api_key)])
async def trigger_watermarks(force: bool = Query(default=False)) -> dict:
    return await dsve.update_weekly_watermarks(force=force)


# --------------------------------------------------------------------------- #
# Portfolio read models                                                       #
# --------------------------------------------------------------------------- #
@app.get("/portfolio/{user_id}/metrics", dependencies=[Depends(require_api_key)])
async def portfolio_metrics(user_id: str) -> list:
    return await dsve.get_metrics(user_id)


@app.get("/portfolio/{user_id}/summary", dependencies=[Depends(require_api_key)])
async def portfolio_summary(user_id: str) -> dict:
    return await dsve.get_summary(user_id)


@app.get("/portfolio/{user_id}/buying-power", dependencies=[Depends(require_api_key)])
async def portfolio_buying_power(user_id: str) -> dict:
    return await dsve.get_buying_power(user_id)


# --------------------------------------------------------------------------- #
# Debug quote endpoint                                                        #
# --------------------------------------------------------------------------- #
@app.get("/quotes/{symbol}", dependencies=[Depends(require_api_key)])
async def quote(symbol: str) -> dict:
    q = await market_data.get_quote(symbol)
    tase = is_tase_symbol(symbol)
    return {
        "symbol": q.symbol,
        "raw_price": q.price,
        "display_price": normalize_price(q.price, tase=tase),  # calibration applies per-asset in the view
        "high_52w_raw": q.high_52w,
        "currency": q.currency,
        "is_tase": tase,
        "fetched_at": q.fetched_at,
    }
