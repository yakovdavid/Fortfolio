"""DSVE - Data Sync & Valuation Engine.

Background engine responsibilities (PRD section 6):
  1. sync_market_data      - poll Yahoo Finance (through the 15-min
                             single-flight cache), write RAW prices +
                             price_updated_at to portfolio_assets, and
                             refresh fx_rates. Valuation itself is then
                             computed by the ui_pipeline_metrics SQL view -
                             the single calculation engine.
  2. update_weekly_watermarks - on weekly close only: advance the
                             trailing-stop high-watermark (risk_profiles.
                             peak_price, stored NORMALIZED) for assets in
                             layers governed by a trailing stop.
  3. Read models           - portfolio metrics / summary / buying power,
                             all derived from the view and ledger functions
                             (never computed from UI-side state).
"""
import asyncio
import logging
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional

from .config import get_settings
from .market_data import is_tase_symbol, market_data, normalize_price
from .supabase_client import get_supabase

logger = logging.getLogger("fortfolio.dsve")


def _utcnow_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


async def _db(fn):
    """Run a synchronous supabase-py call off the event loop."""
    return await asyncio.to_thread(fn)


class DSVE:
    # ------------------------------------------------------------------ #
    # 1. MARKET DATA SYNC                                                #
    # ------------------------------------------------------------------ #
    async def sync_market_data(self) -> Dict[str, Any]:
        sb = get_supabase()

        assets: List[dict] = await _db(lambda: (
            sb.table("portfolio_assets")
              .select("asset_id,data_symbol,exchange,currency,calibration_factor")
              .eq("is_active", True)
              .execute().data
        ))

        report: Dict[str, Any] = {"synced": 0, "failed": [], "fx_updated": [], "started_at": _utcnow_iso()}
        if not assets:
            report["finished_at"] = _utcnow_iso()
            return report

        # --- Quotes: one fetch per distinct symbol (cache + single flight) ---
        symbols = sorted({a["data_symbol"] for a in assets})
        results = await asyncio.gather(
            *(market_data.get_quote(s) for s in symbols), return_exceptions=True
        )
        quotes = {}
        for symbol, result in zip(symbols, results):
            if isinstance(result, Exception):
                logger.error("Quote sync failed for %s: %s", symbol, result)
                report["failed"].append(symbol)
            else:
                quotes[symbol] = result

        # --- Write RAW prices back (normalization stays in the SQL view) ---
        now_iso = _utcnow_iso()
        for asset in assets:
            quote = quotes.get(asset["data_symbol"])
            if quote is None:
                continue
            payload = {
                "current_price": quote.price,          # RAW (Agorot for TASE)
                "price_updated_at": now_iso,           # freshness watermark (<15 min rule)
            }
            if quote.high_52w is not None:
                payload["high_52w"] = quote.high_52w   # RAW
            await _db(lambda a=asset, p=payload: (
                sb.table("portfolio_assets").update(p).eq("asset_id", a["asset_id"]).execute()
            ))
            report["synced"] += 1

        # --- FX: every (asset currency -> user base currency) pair in use ---
        settings_rows: List[dict] = await _db(lambda: (
            sb.table("user_settings").select("base_currency").execute().data
        ))
        base_currencies = {r["base_currency"] for r in settings_rows} or {"ILS"}
        asset_currencies = {a["currency"] for a in assets}
        pairs = {(ac, bc) for ac in asset_currencies for bc in base_currencies if ac != bc}

        for base, quote_ccy in sorted(pairs):
            try:
                rate = await market_data.get_fx_rate(base, quote_ccy)
                await _db(lambda b=base, q=quote_ccy, r=rate: (
                    sb.table("fx_rates").upsert({
                        "base_currency": b,
                        "quote_currency": q,
                        "rate": r,
                        "fetched_at": _utcnow_iso(),
                    }).execute()
                ))
                report["fx_updated"].append(f"{base}/{quote_ccy}={rate}")
            except Exception as err:
                logger.error("FX sync failed for %s/%s: %s", base, quote_ccy, err)
                report["failed"].append(f"{base}{quote_ccy}=X")

        report["finished_at"] = _utcnow_iso()
        logger.info("DSVE sync complete: %s", report)
        return report

    # ------------------------------------------------------------------ #
    # 2. WEEKLY TRAILING-STOP WATERMARK (Satellite protocol)             #
    # ------------------------------------------------------------------ #
    async def update_weekly_watermarks(self, force: bool = False) -> Dict[str, Any]:
        """Advance peak_price to max(current peak, last completed weekly
        close), NORMALIZED (Agorot/100 + calibration). Runs only on the
        configured weekday unless force=True. Idempotent: assets whose
        watermark was already updated in the last 6 days are skipped."""
        settings = get_settings()
        now = datetime.now(timezone.utc)
        report: Dict[str, Any] = {"updated": [], "skipped": 0, "failed": [], "ran": False}

        if not force and now.weekday() != settings.watermark_update_weekday:
            return report
        report["ran"] = True

        sb = get_supabase()
        assets: List[dict] = await _db(lambda: (
            sb.table("portfolio_assets")
              .select("asset_id,user_id,layer_code,data_symbol,exchange,calibration_factor")
              .eq("is_active", True)
              .execute().data
        ))
        layers: List[dict] = await _db(lambda: (
            sb.table("allocation_layers")
              .select("user_id,layer_code,trailing_stop_pct")
              .execute().data
        ))
        profiles: List[dict] = await _db(lambda: (
            sb.table("risk_profiles")
              .select("asset_id,peak_price,peak_updated_at,stop_override_pct,protection_state")
              .execute().data
        ))
        stop_by_layer = {(l["user_id"], l["layer_code"]): l["trailing_stop_pct"] for l in layers}
        profile_by_asset = {p["asset_id"]: p for p in profiles}
        freshness_floor = now - timedelta(days=6)

        for asset in assets:
            profile = profile_by_asset.get(asset["asset_id"], {})
            effective_stop = (
                profile.get("stop_override_pct")
                or stop_by_layer.get((asset["user_id"], asset["layer_code"]))
            )
            if effective_stop is None:
                continue  # layer has no trailing stop (Core / Quality)
            if profile.get("protection_state") != "TRAILING":
                # RECOVERY: the stop is locked at entry_price*(1-stop%) and the
                # peak is irrelevant until the breakout latch fires (DB trigger).
                continue

            updated_at = profile.get("peak_updated_at")
            if updated_at and not force:
                try:
                    if datetime.fromisoformat(updated_at) >= freshness_floor:
                        report["skipped"] += 1
                        continue  # already updated for this trading week
                except ValueError:
                    pass

            try:
                raw_close = await market_data.get_weekly_close(asset["data_symbol"])
                normalized_close = normalize_price(
                    raw_close,
                    tase=is_tase_symbol(asset["data_symbol"]),
                    calibration_factor=float(asset["calibration_factor"]),
                )
                previous_peak = float(profile.get("peak_price") or 0)
                new_peak = max(previous_peak, normalized_close)
                await _db(lambda a=asset, p=new_peak: (
                    sb.table("risk_profiles").upsert({
                        "asset_id": a["asset_id"],
                        "peak_price": p,
                        "peak_updated_at": _utcnow_iso(),
                    }).execute()
                ))
                report["updated"].append({
                    "symbol": asset["data_symbol"],
                    "weekly_close": round(normalized_close, 4),
                    "peak_price": round(new_peak, 4),
                })
            except Exception as err:
                logger.error("Watermark update failed for %s: %s", asset["data_symbol"], err)
                report["failed"].append(asset["data_symbol"])

        logger.info("Weekly watermark run: %s", report)
        return report

    # ------------------------------------------------------------------ #
    # 3. READ MODELS (valuation is computed by the SQL view)             #
    #    `sb` is the caller's RLS-scoped client (get_user_supabase); the  #
    #    explicit user_id filter is a second, independent guard.          #
    # ------------------------------------------------------------------ #
    async def get_metrics(self, sb, user_id: str) -> List[dict]:
        return await _db(lambda: (
            sb.table("ui_pipeline_metrics").select("*").eq("user_id", user_id).execute().data
        ))

    async def get_cash_balances(self, sb, user_id: str) -> Dict[str, float]:
        """Ledger-derived cash per currency (fn_cash_balance in PostgreSQL)."""
        rows: List[dict] = await _db(lambda: (
            sb.table("ops_log").select("currency,transaction_type,asset_symbol")
              .eq("user_id", user_id).execute().data
        ))
        currencies = {r["currency"] for r in rows}
        currencies |= {r["asset_symbol"] for r in rows
                       if r["transaction_type"] == "EXCHANGE"}  # target side
        balances: Dict[str, float] = {}
        for currency in sorted(currencies):
            value = await _db(lambda c=currency: (
                sb.rpc("fn_cash_balance", {"p_user": user_id, "p_currency": c}).execute().data
            ))
            balances[currency] = float(value or 0)
        return balances

    async def get_buying_power(self, sb, user_id: str) -> Dict[str, Any]:
        """GOLDEN RULE #1 read model: cash minus the emergency reserve
        (system liquidity constraint - configurable, never hardcoded).
        The authoritative enforcement remains the database trigger."""
        balances = await self.get_cash_balances(sb, user_id)
        settings_rows: List[dict] = await _db(lambda: (
            sb.table("user_settings")
              .select("emergency_reserve_amount,emergency_reserve_currency,operational_cash_buffer,base_currency")
              .eq("user_id", user_id).execute().data
        ))
        user_settings = settings_rows[0] if settings_rows else {
            "emergency_reserve_amount": 0, "emergency_reserve_currency": "ILS",
            "operational_cash_buffer": 0, "base_currency": "ILS",
        }
        reserve_ccy = user_settings["emergency_reserve_currency"]
        reserve = float(user_settings["emergency_reserve_amount"])
        buffer_floor = float(user_settings["operational_cash_buffer"])

        buying_power = {
            ccy: (balance - reserve if ccy == reserve_ccy else balance)
            for ccy, balance in balances.items()
        }
        reserve_ccy_cash = balances.get(reserve_ccy, 0.0)
        return {
            "cash_balances": balances,
            "buying_power": buying_power,
            "emergency_reserve": {"amount": reserve, "currency": reserve_ccy},
            "operational_cash_buffer": buffer_floor,
            # Cash Oxygen Level: buffer status is measured on buying power
            # (reserve already excluded), per the 1,500 buffer spec:
            "cash_oxygen_ok": (reserve_ccy_cash - reserve) >= buffer_floor,
        }

    async def get_summary(self, sb, user_id: str) -> Dict[str, Any]:
        """Dashboard aggregate: totals, per-layer weights/drift vs the
        generic DNA, defense alerts, cash and buying power.
        Weights use capital = invested + available cash (reserve excluded)."""
        metrics = await self.get_metrics(sb, user_id)
        cash = await self.get_buying_power(sb, user_id)

        layers: Dict[str, dict] = {}
        for row in metrics:
            layer = layers.setdefault(row["layer_code"], {
                "layer_code": row["layer_code"],
                "layer_name": row["layer_name"],
                "target_weight_pct": row["target_weight_pct"],
                "layer_weight_pct": row["layer_weight_pct"],
                "layer_drift_pct": row["layer_drift_pct"],
                "market_value_base": 0.0,
                "asset_count": 0,
            })
            layer["market_value_base"] += float(row["market_value_base"] or 0)
            layer["asset_count"] += 1

        alerts = [
            {
                "ticker": r["ticker"],
                "layer_code": r["layer_code"],
                "status": r["defense_status"],
                "protection_state": r.get("protection_state"),
                "stop_order_type": r.get("stop_order_type"),
                "stop_price": r.get("stop_price"),
                "alert_trigger_price": r.get("alert_trigger_price"),
            }
            for r in metrics if r["defense_status"] != "HOLD"
        ]
        first = metrics[0] if metrics else {}
        return {
            "user_id": user_id,
            "base_currency": first.get("base_currency"),
            # capital = invested + available cash (emergency reserve excluded):
            "portfolio_value_base": first.get("portfolio_value_base", 0),
            "invested_value_base": first.get("invested_value_base", 0),
            "available_cash_base": first.get("available_cash_base", 0),
            "cash_weight_pct": first.get("cash_weight_pct", 0),
            "layers": sorted(layers.values(), key=lambda l: -float(l["target_weight_pct"] or 0)),
            "defense_alerts": alerts,
            "stale_assets": [r["ticker"] for r in metrics if r["is_stale"]],
            **cash,
            "generated_at": _utcnow_iso(),
        }


dsve = DSVE()
