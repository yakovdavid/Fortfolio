"""Fortfolio 2.0 - FastAPI middleware server.

Endpoints:
  GET  /ping                            health check (cold-start prevention, no auth)

  End user (Authorization: Bearer <Supabase access token>; identity = JWT sub):
  GET  /me/metrics                      ui_pipeline_metrics rows (per asset)
  GET  /me/summary                      dashboard aggregate (layers, drift, alerts, cash)
  GET  /me/buying-power                 Golden Rule #1 read model

  Internal (X-API-Key, service-to-service only - never from the client):
  POST /internal/sync                   manual DSVE market-data sync
  POST /internal/sync/watermarks        manual weekly watermark run (?force=)
  GET  /internal/quotes/{symbol}        debug quote (raw + normalized display value)

The background scheduler runs the DSVE sync every SYNC_INTERVAL_SECONDS and
attempts the weekly watermark job each cycle (self-guarded: it only executes
on the configured weekday and skips fresh watermarks).
"""
import asyncio
import hmac
import logging
from contextlib import asynccontextmanager
from typing import Optional

from fastapi import Depends, FastAPI, Header, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware

from .auth import AuthenticatedUser, AuthError, authenticate
from .config import get_settings
from .dsve import dsve
from .market_data import is_tase_symbol, market_data, normalize_price
from .supabase_client import get_user_supabase

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
logger = logging.getLogger("fortfolio.main")


# --------------------------------------------------------------------------- #
# Auth                                                                        #
# --------------------------------------------------------------------------- #
def require_api_key(x_api_key: str = Header(default="")) -> None:
    """Internal service-to-service guard. Fails closed if no key is configured."""
    expected = get_settings().backend_api_key
    if not expected or not hmac.compare_digest(x_api_key.encode(), expected.encode()):
        raise HTTPException(status_code=401, detail="Invalid or missing X-API-Key")


async def current_user(authorization: Optional[str] = Header(default=None)) -> AuthenticatedUser:
    """End-user guard: verified Supabase JWT. The user_id comes from the token only."""
    settings = get_settings()
    try:
        # JWKS lookup may hit the network on a cold key cache - keep it off the loop.
        return await asyncio.to_thread(
            authenticate,
            authorization,
            supabase_url=settings.supabase_url,
            jwt_secret=settings.supabase_jwt_secret,
        )
    except AuthError as err:
        raise HTTPException(
            status_code=401, detail=str(err), headers={"WWW-Authenticate": "Bearer"}
        ) from err


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


app = FastAPI(title="Fortfolio Backend", version="2.1.0", lifespan=lifespan)

if get_settings().cors_origins:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=get_settings().cors_origins,
        allow_methods=["GET", "POST"],
        allow_headers=["Authorization", "Content-Type"],
    )


# --------------------------------------------------------------------------- #
# Health (cold-start prevention - keep unauthenticated and cheap)             #
# --------------------------------------------------------------------------- #
@app.get("/ping")
async def ping() -> dict:
    return {"status": "ok", "service": "fortfolio-backend", "version": "2.1.0"}


# --------------------------------------------------------------------------- #
# End-user read models (JWT; RLS-scoped Supabase client)                      #
# --------------------------------------------------------------------------- #
@app.get("/me/metrics")
async def my_metrics(user: AuthenticatedUser = Depends(current_user)) -> list:
    return await dsve.get_metrics(get_user_supabase(user.access_token), user.user_id)


@app.get("/me/summary")
async def my_summary(user: AuthenticatedUser = Depends(current_user)) -> dict:
    return await dsve.get_summary(get_user_supabase(user.access_token), user.user_id)


@app.get("/me/buying-power")
async def my_buying_power(user: AuthenticatedUser = Depends(current_user)) -> dict:
    return await dsve.get_buying_power(get_user_supabase(user.access_token), user.user_id)


# --------------------------------------------------------------------------- #
# Internal controls (X-API-Key, service-to-service only)                      #
# --------------------------------------------------------------------------- #
@app.post("/internal/sync", dependencies=[Depends(require_api_key)])
async def trigger_sync() -> dict:
    return await dsve.sync_market_data()


@app.post("/internal/sync/watermarks", dependencies=[Depends(require_api_key)])
async def trigger_watermarks(force: bool = Query(default=False)) -> dict:
    return await dsve.update_weekly_watermarks(force=force)


@app.get("/internal/quotes/{symbol}", dependencies=[Depends(require_api_key)])
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
