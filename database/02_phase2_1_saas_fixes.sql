-- ============================================================================
-- FORTFOLIO 2.0 - PHASE 2.1: PHASE 1 FIXES + SAAS HARDENING
-- Target: Supabase (PostgreSQL 15+). Apply AFTER 01_phase1_foundation.sql.
-- ============================================================================
-- Fixes (approved in Fortfolio_Claude_Phase2_1_Approval):
--   F1. Zero-weight layers: allocation_layers accepted only weights > 0, which
--       made the 80/0/20 (Hyper-Quality) and 100/0/0 (Absolute Passive)
--       templates impossible to store. Now 0 <= weight <= 100.
--   F2. Cash in the denominator: layer/asset weights were computed from
--       invested capital only (the "Allocation Denominator Bug"). Weights are
--       now value / (invested value + available cash), where available cash
--       is ledger cash converted to base currency MINUS the emergency reserve
--       (Golden Rule #1 - the reserve never counts as capital).
--   F3. Recovery State + one-way latch (Satellite trailing-stop protocol):
--         * On opening a position (first BUY, or re-entry after a full exit)
--           the 52-week high at that moment is captured as entry_hwm.
--         * While price < entry_hwm  -> RECOVERY: Stop Market locked at
--           entry_price * (1 - stop%). It never moves.
--         * When price >= entry_hwm  -> TRAILING (one-way latch, never back
--           to RECOVERY within the same position cycle). The trailing peak
--           starts at the breakout price and is then advanced by the weekly
--           watermark job.
--         * Re-entry after a full exit starts a new cycle.
-- SaaS hardening:
--   S1. ui_pipeline_metrics runs with security_invoker = true, so RLS applies
--       to whoever queries it (a default view runs as its owner and would
--       bypass RLS - a cross-tenant leak).
--   S2. Market data and defense state are server-owned: authenticated users
--       can no longer write prices (current_price / high_52w /
--       price_updated_at) or protection state. Otherwise a user could fake a
--       price to flip the latch or silence a SELL_TRIGGERED.
--   S3. ops_log rows may only reference the inserting user's own assets.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- F1. Allow 0% layers
-- ----------------------------------------------------------------------------
alter table allocation_layers
  drop constraint if exists allocation_layers_target_weight_pct_check;

alter table allocation_layers
  add constraint allocation_layers_target_weight_pct_check
  check (target_weight_pct >= 0 and target_weight_pct <= 100);

-- ----------------------------------------------------------------------------
-- F3. Protection state columns (per asset, per position cycle)
-- ----------------------------------------------------------------------------
-- Price convention: entry_price comes from ops_log.price_per_unit, which is
-- the real execution price in the trade currency (major units - ILS, not
-- Agorot). entry_hwm and peak_price are NORMALIZED provider prices
-- (calibration applied, Agorot/100 for TASE) - the same scale as
-- ui_pipeline_metrics.normalized_price.
alter table risk_profiles
  add column if not exists protection_state   text
    check (protection_state in ('RECOVERY', 'TRAILING')),
  add column if not exists entry_price        numeric(18, 6)
    check (entry_price is null or entry_price > 0),
  add column if not exists entry_hwm          numeric(18, 6)
    check (entry_hwm is null or entry_hwm > 0),
  add column if not exists position_opened_at timestamptz,
  add column if not exists breakout_at        timestamptz;

comment on column risk_profiles.protection_state is
  'RECOVERY = Stop Market locked at entry_price*(1-stop%) until price >= entry_hwm; TRAILING = trailing stop from peak_price. One-way latch per position cycle.';
comment on column risk_profiles.entry_hwm is
  'Normalized 52-week high captured when the position cycle opened (the breakout target).';
comment on column risk_profiles.peak_price is
  'Normalized trailing watermark. Meaningful only in TRAILING state; set at breakout, advanced weekly by the DSVE watermark job.';

-- Normalized 52w high of an asset right now (helper, mirrors the view formula).
create or replace function fn_normalized_high_52w(p_asset uuid)
returns numeric
language sql
stable
as $$
  select case when pa.exchange = 'TASE'
              then (pa.high_52w * pa.calibration_factor) / 100.0
              else  pa.high_52w * pa.calibration_factor
         end
  from portfolio_assets pa
  where pa.asset_id = p_asset;
$$;

-- --- F3a. Open / re-open a position cycle on BUY ----------------------------
-- SECURITY DEFINER: users cannot write risk_profiles directly (S2), so the
-- ledger trigger writes it on their behalf. It only ever touches NEW.asset_id.
create or replace function fn_open_position_cycle()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_units_before numeric;
  v_hwm          numeric;
  v_state        text;
begin
  if new.transaction_type <> 'BUY' then
    return null;
  end if;

  -- AFTER INSERT: the ledger already includes NEW, so subtract it.
  v_units_before := fn_units_held(new.user_id, new.asset_id) - new.quantity;

  if v_units_before > 0 then
    return null;  -- add-on buy inside an open cycle: protection state untouched
  end if;

  v_hwm := fn_normalized_high_52w(new.asset_id);

  -- Bought at or above the 52w high => nothing to recover, trail immediately.
  -- Unknown 52w high (asset not priced yet) => RECOVERY; the first price sync
  -- fills entry_hwm (see fn_advance_protection_latch).
  if v_hwm is not null and new.price_per_unit >= v_hwm then
    v_state := 'TRAILING';
  else
    v_state := 'RECOVERY';
  end if;

  insert into risk_profiles as rp
    (asset_id, protection_state, entry_price, entry_hwm,
     position_opened_at, breakout_at, peak_price, peak_updated_at)
  values
    (new.asset_id, v_state, new.price_per_unit, v_hwm,
     new.executed_at,
     case when v_state = 'TRAILING' then new.executed_at end,
     case when v_state = 'TRAILING' then new.price_per_unit end,
     case when v_state = 'TRAILING' then now() end)
  on conflict (asset_id) do update set
    protection_state   = excluded.protection_state,
    entry_price        = excluded.entry_price,
    entry_hwm          = excluded.entry_hwm,
    position_opened_at = excluded.position_opened_at,
    breakout_at        = excluded.breakout_at,
    peak_price         = excluded.peak_price,
    peak_updated_at    = excluded.peak_updated_at;
    -- order_type / stop_override_pct (user preferences) are preserved.

  return null;
end;
$$;

drop trigger if exists trg_ops_log_open_position_cycle on ops_log;
create trigger trg_ops_log_open_position_cycle
  after insert on ops_log
  for each row execute function fn_open_position_cycle();

-- --- F3b. One-way latch on every market-data update --------------------------
-- Fires when the DSVE writes a new price. RECOVERY -> TRAILING once the
-- normalized price reaches entry_hwm. Never the other way.
create or replace function fn_advance_protection_latch()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_price numeric;
  v_hwm   numeric;
begin
  if new.current_price is null then
    return null;
  end if;

  v_price := case when new.exchange = 'TASE'
                  then (new.current_price * new.calibration_factor) / 100.0
                  else  new.current_price * new.calibration_factor
             end;
  v_hwm := case when new.exchange = 'TASE'
                then (new.high_52w * new.calibration_factor) / 100.0
                else  new.high_52w * new.calibration_factor
           end;

  -- Late fill: the cycle opened before the asset was ever priced.
  update risk_profiles
     set entry_hwm = v_hwm
   where asset_id = new.asset_id
     and protection_state = 'RECOVERY'
     and entry_hwm is null
     and v_hwm is not null;

  -- The latch.
  update risk_profiles
     set protection_state = 'TRAILING',
         breakout_at      = now(),
         peak_price       = greatest(v_price, entry_hwm),
         peak_updated_at  = now()
   where asset_id = new.asset_id
     and protection_state = 'RECOVERY'
     and entry_hwm is not null
     and v_price >= entry_hwm;

  return null;
end;
$$;

drop trigger if exists trg_portfolio_assets_latch on portfolio_assets;
create trigger trg_portfolio_assets_latch
  after update of current_price, high_52w on portfolio_assets
  for each row execute function fn_advance_protection_latch();

-- ----------------------------------------------------------------------------
-- S3. Ledger rows may only reference the user's own assets
-- ----------------------------------------------------------------------------
create or replace function fn_ops_log_asset_ownership()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.asset_id is not null and not exists (
       select 1 from portfolio_assets pa
       where pa.asset_id = new.asset_id and pa.user_id = new.user_id) then
    raise exception 'ASSET_OWNERSHIP_VIOLATION: asset % does not belong to user %',
      new.asset_id, new.user_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_ops_log_asset_ownership on ops_log;
create trigger trg_ops_log_asset_ownership
  before insert on ops_log
  for each row execute function fn_ops_log_asset_ownership();

-- ----------------------------------------------------------------------------
-- S2. Server-owned market data and defense state
-- ----------------------------------------------------------------------------
-- portfolio_assets: users manage the registry, never the market snapshot.
revoke insert, update on portfolio_assets from authenticated, anon;
grant  insert (user_id, ticker, exchange, layer_code, currency, calibration_factor, is_active)
  on portfolio_assets to authenticated;
grant  update (layer_code, calibration_factor, is_active)
  on portfolio_assets to authenticated;

-- risk_profiles: read own rows; only user preferences are writable.
drop policy if exists p_risk_profiles_own on risk_profiles;
drop policy if exists p_risk_profiles_select_own on risk_profiles;
drop policy if exists p_risk_profiles_update_own on risk_profiles;

create policy p_risk_profiles_select_own on risk_profiles
  for select using (exists (select 1 from portfolio_assets pa
                            where pa.asset_id = risk_profiles.asset_id
                              and pa.user_id = auth.uid()));
create policy p_risk_profiles_update_own on risk_profiles
  for update using (exists (select 1 from portfolio_assets pa
                            where pa.asset_id = risk_profiles.asset_id
                              and pa.user_id = auth.uid()))
  with check   (exists (select 1 from portfolio_assets pa
                            where pa.asset_id = risk_profiles.asset_id
                              and pa.user_id = auth.uid()));

revoke insert, update, delete on risk_profiles from authenticated, anon;
grant  update (order_type, stop_override_pct) on risk_profiles to authenticated;

-- ----------------------------------------------------------------------------
-- F2 + F3 + S1. UI_PIPELINE_METRICS v2.1
-- ----------------------------------------------------------------------------
-- Column changes vs Phase 1 (drop + create, since columns are added/reordered):
--   + invested_value_base, available_cash_base, cash_weight_pct
--   ~ portfolio_value_base now = invested + available cash (F2)
--   ~ current_weight_pct / layer_weight_pct / layer_drift_pct use that denominator
--   + protection_state, entry_price, entry_hwm, stop_price, stop_order_type,
--     alert_trigger_price (F3)
--   ~ SELL_TRIGGERED now compares against stop_price (Recovery or Trailing)
drop view if exists ui_pipeline_metrics;

create view ui_pipeline_metrics
with (security_invoker = true)
as
with holdings as (
  select
    o.user_id,
    o.asset_id,
    sum(case o.transaction_type
          when 'BUY'  then  o.quantity
          when 'SELL' then -o.quantity
          else 0
        end)                                            as units_held,
    sum(case when o.transaction_type = 'BUY'
             then o.total_amount + o.fee else 0 end)    as gross_invested,
    min(o.executed_at) filter
        (where o.transaction_type = 'BUY')              as first_buy_at
  from ops_log o
  where o.asset_id is not null
    and o.transaction_type in ('BUY', 'SELL')
  group by o.user_id, o.asset_id
  having sum(case o.transaction_type
               when 'BUY'  then  o.quantity
               when 'SELL' then -o.quantity
               else 0
             end) > 0                                   -- GOLDEN RULE #2
),
-- Every currency a user's ledger touches (incl. EXCHANGE target side):
cash_currencies as (
  select distinct o.user_id, o.currency as ccy from ops_log o
  union
  select distinct o.user_id, o.asset_symbol::char(3)
  from ops_log o where o.transaction_type = 'EXCHANGE'
),
-- F2: available cash in base currency, emergency reserve excluded.
cash as (
  select
    c.user_id,
    sum(fn_cash_balance(c.user_id, c.ccy) *
        case when c.ccy = coalesce(s.base_currency, 'ILS') then 1.0 else fx.rate end)
                                                        as cash_base,
    max(coalesce(s.emergency_reserve_amount, 0) *
        case when coalesce(s.emergency_reserve_currency, 'ILS') = coalesce(s.base_currency, 'ILS')
             then 1.0 else rfx.rate end)                as reserve_base
  from cash_currencies c
  left join user_settings s on s.user_id = c.user_id
  left join fx_rates fx  on fx.base_currency  = c.ccy
                        and fx.quote_currency = coalesce(s.base_currency, 'ILS')
  left join fx_rates rfx on rfx.base_currency  = coalesce(s.emergency_reserve_currency, 'ILS')
                        and rfx.quote_currency = coalesce(s.base_currency, 'ILS')
  group by c.user_id
),
priced as (
  select
    h.user_id,
    h.asset_id,
    h.units_held,
    h.gross_invested,
    h.first_buy_at,
    pa.ticker,
    pa.data_symbol,
    pa.exchange,
    pa.layer_code,
    pa.currency                                         as asset_currency,
    pa.price_updated_at,
    -- GOLDEN RULE #3: TASE Agorot -> ILS normalization + auto-calibration:
    case when pa.exchange = 'TASE'
         then (pa.current_price * pa.calibration_factor) / 100.0
         else  pa.current_price * pa.calibration_factor
    end                                                 as normalized_price,
    case when pa.exchange = 'TASE'
         then (pa.high_52w * pa.calibration_factor) / 100.0
         else  pa.high_52w * pa.calibration_factor
    end                                                 as normalized_high_52w,
    coalesce(s.base_currency, 'ILS')                    as base_currency,
    coalesce(s.market_data_ttl_minutes, 15)             as ttl_minutes,
    al.display_name                                     as layer_name,
    al.target_weight_pct,
    coalesce(rp.stop_override_pct, al.trailing_stop_pct) as effective_stop_pct,
    al.audit_drawdown_pct,
    rp.peak_price,
    rp.protection_state,
    rp.entry_price,
    rp.entry_hwm
  from holdings h
  join portfolio_assets pa on pa.asset_id = h.asset_id
  join allocation_layers al on al.user_id = pa.user_id
                           and al.layer_code = pa.layer_code
  left join user_settings s on s.user_id = h.user_id
  left join risk_profiles rp on rp.asset_id = h.asset_id
),
valued as (
  select
    p.*,
    (p.price_updated_at is null
     or p.price_updated_at < now() - make_interval(mins => p.ttl_minutes))
                                                        as is_stale,
    p.units_held * p.normalized_price                   as market_value_local,
    p.units_held * p.normalized_price *
      case when p.asset_currency = p.base_currency then 1.0
           else fx.rate
      end                                               as market_value_base,
    greatest(coalesce(c.cash_base, 0) - coalesce(c.reserve_base, 0), 0)
                                                        as available_cash_base,
    -- F3: the stop only exists for layers governed by a trailing stop.
    case
      when p.effective_stop_pct is null then null
      when p.protection_state = 'TRAILING' and p.peak_price > 0
        then p.peak_price  * (1 - p.effective_stop_pct / 100.0)
      when p.protection_state = 'RECOVERY' and p.entry_price > 0
        then p.entry_price * (1 - p.effective_stop_pct / 100.0)
    end                                                 as stop_price
  from priced p
  left join fx_rates fx on fx.base_currency  = p.asset_currency
                       and fx.quote_currency = p.base_currency
  left join cash c on c.user_id = p.user_id
),
totals as (
  select
    v.*,
    sum(v.market_value_base) over w_user                as invested_value_base,
    sum(v.market_value_base) over w_user
      + v.available_cash_base                           as total_capital_base,
    sum(v.market_value_base) over w_layer               as layer_value_base
  from valued v
  window
    w_user  as (partition by v.user_id),
    w_layer as (partition by v.user_id, v.layer_code)
)
select
  t.user_id,
  t.asset_id,
  t.ticker,
  t.data_symbol,
  t.exchange,
  t.layer_code,
  t.layer_name,
  t.asset_currency,
  t.base_currency,
  t.units_held,
  round(t.normalized_price,    4)                       as normalized_price,
  round(t.normalized_high_52w, 4)                       as normalized_high_52w,
  round(t.market_value_local,  2)                       as market_value_local,
  round(t.market_value_base,   2)                       as market_value_base,

  -- F2: capital = invested + available cash (reserve excluded):
  round(t.invested_value_base, 2)                       as invested_value_base,
  round(t.available_cash_base, 2)                       as available_cash_base,
  round(t.total_capital_base,  2)                       as portfolio_value_base,
  round((t.available_cash_base
         / nullif(t.total_capital_base, 0)) * 100, 2)   as cash_weight_pct,
  round((t.market_value_base
         / nullif(t.total_capital_base, 0)) * 100, 2)   as current_weight_pct,
  round((t.layer_value_base
         / nullif(t.total_capital_base, 0)) * 100, 2)   as layer_weight_pct,
  t.target_weight_pct,
  round(((t.layer_value_base
          / nullif(t.total_capital_base, 0)) * 100)
        - t.target_weight_pct, 2)                       as layer_drift_pct,

  -- UI indicators:
  case when t.normalized_high_52w > 0
       then round((1 - t.normalized_price / t.normalized_high_52w) * 100, 2)
  end                                                   as drawdown_52w_pct,
  case when t.stop_price > 0
       then round(((t.normalized_price - t.stop_price) / t.stop_price) * 100, 2)
  end                                                   as distance_to_stop_pct,

  -- F3: protection state (Satellite-type layers only):
  case when t.effective_stop_pct is not null then t.protection_state end
                                                        as protection_state,
  round(t.entry_price, 4)                               as entry_price,
  round(t.entry_hwm,   4)                               as entry_hwm,
  round(t.stop_price,  4)                               as stop_price,
  case when t.effective_stop_pct is null then null
       when t.protection_state = 'TRAILING' then 'TRAILING_STOP'
       else 'STOP_MARKET'
  end                                                   as stop_order_type,
  -- Recovery: the price at which the user replaces the Stop Market with a
  -- trailing stop at the broker (the breakout target).
  case when t.effective_stop_pct is not null and t.protection_state = 'RECOVERY'
       then round(t.entry_hwm, 4)
  end                                                   as alert_trigger_price,
  t.peak_price,
  t.price_updated_at,
  t.is_stale,

  -- Defense status (precedence unchanged): DATA_STALE > SELL_TRIGGERED >
  -- FUNDAMENTAL_AUDIT_REQUIRED > HOLD.
  case
    when t.is_stale
      then 'DATA_STALE'
    when t.stop_price is not null
         and t.normalized_price <= t.stop_price
      then 'SELL_TRIGGERED'
    when t.audit_drawdown_pct is not null
         and t.normalized_high_52w > 0
         and (1 - t.normalized_price / t.normalized_high_52w) * 100 >= t.audit_drawdown_pct
      then 'FUNDAMENTAL_AUDIT_REQUIRED'
    else 'HOLD'
  end                                                   as defense_status
from totals t;

grant select on ui_pipeline_metrics to authenticated;

-- ============================================================================
-- END OF PHASE 2.1
-- ============================================================================
