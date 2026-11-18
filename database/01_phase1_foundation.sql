-- ============================================================================
-- FORTFOLIO 2.0 - PHASE 1: FOUNDATION (DATA & STATE)
-- Target: Supabase (PostgreSQL 15+)
-- ============================================================================
-- Design principles enforced natively in this schema:
--   1. ZERO MARGIN / 30K LIQUIDITY LOCK - enforced by a BEFORE INSERT trigger
--      on ops_log. The emergency reserve is a per-user setting (generic,
--      defaults to 30,000 ILS per config.json), never hardcoded in logic.
--   2. NO GHOST ASSETS - portfolio_assets intentionally has NO quantity
--      column. Units held are derived EXCLUSIVELY from executed BUY/SELL
--      rows in ops_log. The ui_pipeline_metrics view inner-joins on that
--      aggregation with HAVING units > 0, so an asset without an executed
--      BUY record can never be rendered or priced.
--   3. REAL-TIME DATA INTEGRITY - TASE symbol handling (.TA suffix) is a
--      GENERATED column; Agorot->ILS (/100) normalization lives in the SQL
--      view; freshness (<15 min) is computed as is_stale and overrides all
--      defense statuses (never trigger a SELL off stale data).
--   4. GENERIC ALLOCATION DNA - layers, target weights, trailing-stop % and
--      audit-drawdown % are per-user rows in allocation_layers (sum-to-100
--      enforced by a deferred constraint trigger). 70/20/10 is a preset,
--      not a schema assumption.
-- ============================================================================

create extension if not exists "pgcrypto";

-- ----------------------------------------------------------------------------
-- 0. ENUMS
-- ----------------------------------------------------------------------------
-- NOTE: WITHDRAWAL is included per the PDF functional logic (Deposit and
-- Withdrawal Logic, section 1) even though the PRD enum list omits it.
create type transaction_type as enum
  ('DEPOSIT', 'WITHDRAWAL', 'EXCHANGE', 'BUY', 'SELL', 'DIVIDEND');

-- TASE drives both the .TA suffix and the Agorot/100 normalization.
create type exchange_code as enum
  ('TASE', 'NYSE', 'NASDAQ', 'ARCA', 'LSE', 'OTHER');

-- ----------------------------------------------------------------------------
-- 1. USER SETTINGS (liquidity rules - generic, seeded from config.json)
-- ----------------------------------------------------------------------------
create table user_settings (
  user_id                     uuid primary key references auth.users (id) on delete cascade,
  base_currency               char(3)        not null default 'ILS',
  emergency_reserve_amount    numeric(14, 2) not null default 30000.00
                              check (emergency_reserve_amount >= 0),
  emergency_reserve_currency  char(3)        not null default 'ILS',
  operational_cash_buffer     numeric(14, 2) not null default 1500.00
                              check (operational_cash_buffer >= 0),
  -- GOLDEN RULE #1: margin trading is structurally impossible to enable.
  margin_trading_allowed      boolean        not null default false
                              check (margin_trading_allowed = false),
  drift_threshold_pct         numeric(5, 2)  not null default 2.50,
  core_shield_trigger_pct     numeric(5, 2)  not null default -5.00,
  market_data_ttl_minutes     integer        not null default 15
                              check (market_data_ttl_minutes > 0),
  created_at                  timestamptz    not null default now(),
  updated_at                  timestamptz    not null default now()
);

-- ----------------------------------------------------------------------------
-- 2. ALLOCATION LAYERS (the generic DNA - user-defined, sum must equal 100)
-- ----------------------------------------------------------------------------
create table allocation_layers (
  user_id             uuid          not null references auth.users (id) on delete cascade,
  layer_code          text          not null,            -- e.g. 'CORE', 'SATELLITE', 'QUALITY' or any custom code
  display_name        text          not null,
  target_weight_pct   numeric(5, 2) not null check (target_weight_pct > 0 and target_weight_pct <= 100),
  strategy            text,                              -- e.g. 'Buy and Hold', 'Macro Trends', 'Value and Moat'
  -- Defense DNA (all nullable => layer has no such mechanism):
  trailing_stop_pct   numeric(5, 2) check (trailing_stop_pct is null or (trailing_stop_pct > 0 and trailing_stop_pct < 100)),
  stop_evaluation     text          not null default 'WEEKLY_CLOSE'
                      check (stop_evaluation in ('WEEKLY_CLOSE', 'DAILY_CLOSE')),
  audit_drawdown_pct  numeric(5, 2) check (audit_drawdown_pct is null or (audit_drawdown_pct > 0 and audit_drawdown_pct < 100)),
  sort_order          integer       not null default 0,
  primary key (user_id, layer_code)
);

-- Sum-to-100 guardrail, checked at COMMIT so multi-row DNA edits are atomic.
create or replace function fn_validate_allocation_sum()
returns trigger
language plpgsql
as $$
declare
  v_user uuid;
  v_sum  numeric;
begin
  v_user := coalesce(new.user_id, old.user_id);
  select sum(target_weight_pct) into v_sum
  from allocation_layers
  where user_id = v_user;

  if v_sum is not null and v_sum <> 100.00 then
    raise exception 'ALLOCATION_DNA_INVALID: layer weights for user % sum to % - must equal exactly 100.00', v_user, v_sum;
  end if;
  return null;
end;
$$;

create constraint trigger trg_allocation_sum_100
  after insert or update or delete on allocation_layers
  deferrable initially deferred
  for each row execute function fn_validate_allocation_sum();

-- ----------------------------------------------------------------------------
-- 3. FX RATES (sampled by the FastAPI backend, e.g. USD/ILS)
-- ----------------------------------------------------------------------------
create table fx_rates (
  base_currency   char(3)        not null,   -- currency being converted FROM
  quote_currency  char(3)        not null,   -- currency being converted TO
  rate            numeric(14, 6) not null check (rate > 0),
  fetched_at      timestamptz    not null default now(),
  primary key (base_currency, quote_currency)
);

-- ----------------------------------------------------------------------------
-- 4. PORTFOLIO_ASSETS (asset registry + market-data cache)
-- ----------------------------------------------------------------------------
-- DELIBERATE DESIGN DECISION (Golden Rule #2 - No Ghost Assets):
-- This table holds NO unit quantity and NO market value. It is a registry of
-- known instruments plus the latest raw market snapshot. Holdings exist ONLY
-- as the aggregation of executed ops_log rows, computed in the view.
create table portfolio_assets (
  asset_id            uuid           primary key default gen_random_uuid(),
  user_id             uuid           not null references auth.users (id) on delete cascade,
  ticker              text           not null,   -- raw ticker WITHOUT venue suffix (e.g. 'VOO', '1159250')
  exchange            exchange_code  not null default 'OTHER',
  -- GOLDEN RULE #3: .TA suffix is appended automatically and immutably.
  data_symbol         text           generated always as
                        (case when exchange = 'TASE' then ticker || '.TA' else ticker end) stored,
  layer_code          text           not null,
  currency            char(3)        not null,   -- trading currency of the instrument (TASE raw prices are Agorot)
  current_price       numeric(18, 6) check (current_price is null or current_price >= 0),  -- RAW provider price (Agorot for TASE)
  high_52w            numeric(18, 6) check (high_52w is null or high_52w >= 0),            -- RAW provider price
  calibration_factor  numeric(14, 6) not null default 1.0 check (calibration_factor > 0),  -- Auto-Calibration mechanism
  price_updated_at    timestamptz,               -- freshness watermark for the <15 min rule
  is_active           boolean        not null default true,
  created_at          timestamptz    not null default now(),
  unique (user_id, ticker, exchange),
  foreign key (user_id, layer_code)
    references allocation_layers (user_id, layer_code)
);

create index idx_portfolio_assets_user on portfolio_assets (user_id);

-- ----------------------------------------------------------------------------
-- 5. RISK_PROFILES (per-asset defense state: trailing-stop watermark)
-- ----------------------------------------------------------------------------
-- peak_price is the NORMALIZED weekly-close high-watermark (post calibration,
-- post Agorot/100), maintained by the DSVE on weekly close only - never by
-- intraday noise (per the Satellite protocol).
create table risk_profiles (
  asset_id           uuid           primary key references portfolio_assets (asset_id) on delete cascade,
  peak_price         numeric(18, 6) check (peak_price is null or peak_price > 0),
  peak_updated_at    timestamptz,
  order_type         text           not null default 'MARKET'
                     check (order_type in ('MARKET', 'LIMIT')),
  stop_override_pct  numeric(5, 2)  check (stop_override_pct is null or (stop_override_pct > 0 and stop_override_pct < 100))
);

-- ----------------------------------------------------------------------------
-- 6. OPS_LOG (Single Source of Truth - append-only ledger)
-- ----------------------------------------------------------------------------
-- EXCHANGE convention: currency = SOURCE currency, asset_symbol = TARGET
-- currency code, total_amount = gross SOURCE amount, credited target amount
-- = total_amount * fx_rate. fx_rate is mandatory for EXCHANGE.
create table ops_log (
  entry_id          uuid             primary key default gen_random_uuid(),
  user_id           uuid             not null references auth.users (id) on delete cascade,
  executed_at       timestamptz      not null default now(),        -- ISO 8601 with timezone
  transaction_type  transaction_type not null,
  asset_symbol      text             not null,                      -- ticker for trades/dividends; currency code for cash ops
  asset_id          uuid             references portfolio_assets (asset_id),
  quantity          numeric(18, 6)   check (quantity is null or quantity > 0),
  price_per_unit    numeric(18, 6)   check (price_per_unit is null or price_per_unit >= 0),
  total_amount      numeric(14, 2)   not null check (total_amount > 0),
  currency          char(3)          not null,
  fx_rate           numeric(14, 6)   check (fx_rate is null or fx_rate > 0),
  fee               numeric(14, 2)   not null default 0 check (fee >= 0),
  memo              text,                                           -- user reasoning ("Reflect")
  created_at        timestamptz      not null default now(),

  -- Trades must reference a registered asset with quantity and price:
  constraint chk_trade_fields check (
    transaction_type not in ('BUY', 'SELL')
    or (asset_id is not null and quantity is not null and price_per_unit is not null)
  ),
  -- FX rate is mandatory for currency exchanges:
  constraint chk_exchange_fx check (
    transaction_type <> 'EXCHANGE' or fx_rate is not null
  ),
  -- Dividends must reference a registered asset:
  constraint chk_dividend_asset check (
    transaction_type <> 'DIVIDEND' or asset_id is not null
  )
);

create index idx_ops_log_user_time  on ops_log (user_id, executed_at);
create index idx_ops_log_user_asset on ops_log (user_id, asset_id)
  where asset_id is not null;

-- --- 6.1 Append-only enforcement (ledger immutability) -----------------------
create or replace function fn_ops_log_immutable()
returns trigger
language plpgsql
as $$
begin
  raise exception 'OPS_LOG_APPEND_ONLY: the ledger is immutable. Post a compensating (reversal) entry instead of % on entry %',
    tg_op, old.entry_id;
end;
$$;

create trigger trg_ops_log_no_mutation
  before update or delete on ops_log
  for each row execute function fn_ops_log_immutable();

-- --- 6.2 Cash balance derivation (pure ledger arithmetic) --------------------
create or replace function fn_cash_balance(p_user uuid, p_currency char(3))
returns numeric
language sql
stable
as $$
  select coalesce(sum(
    case
      when o.currency = p_currency then
        case o.transaction_type
          when 'DEPOSIT'    then  o.total_amount - o.fee
          when 'DIVIDEND'   then  o.total_amount - o.fee
          when 'SELL'       then  o.total_amount - o.fee
          when 'WITHDRAWAL' then -(o.total_amount + o.fee)
          when 'BUY'        then -(o.total_amount + o.fee)
          when 'EXCHANGE'   then -(o.total_amount + o.fee)   -- source side
        end
      -- target side of an EXCHANGE credits the target currency:
      when o.transaction_type = 'EXCHANGE' and o.asset_symbol = p_currency
        then o.total_amount * o.fx_rate
      else 0
    end), 0)
  from ops_log o
  where o.user_id = p_user;
$$;

-- --- 6.3 Units held derivation (Golden Rule #2 helper) -----------------------
create or replace function fn_units_held(p_user uuid, p_asset uuid)
returns numeric
language sql
stable
as $$
  select coalesce(sum(
    case o.transaction_type
      when 'BUY'  then  o.quantity
      when 'SELL' then -o.quantity
      else 0
    end), 0)
  from ops_log o
  where o.user_id = p_user
    and o.asset_id = p_asset;
$$;

-- --- 6.4 GOLDEN RULE #1: Zero-Margin / 30K Liquidity Lock --------------------
create or replace function fn_enforce_golden_rules()
returns trigger
language plpgsql
as $$
declare
  v_settings   user_settings%rowtype;
  v_reserve    numeric := 0;
  v_available  numeric;
  v_held       numeric;
begin
  -- (A) ZERO-MARGIN VALIDATION for every cash-consuming transaction.
  if new.transaction_type in ('BUY', 'WITHDRAWAL', 'EXCHANGE') then
    select * into v_settings from user_settings where user_id = new.user_id;

    if found and new.currency = v_settings.emergency_reserve_currency then
      v_reserve := v_settings.emergency_reserve_amount;   -- the 30K Liquidity Lock (generic, per user)
    end if;

    v_available := fn_cash_balance(new.user_id, new.currency) - v_reserve;

    if (new.total_amount + new.fee) > v_available then
      raise exception
        'ZERO_MARGIN_VIOLATION: transaction requires % % but available buying power is % % (emergency reserve of % is excluded and locked)',
        (new.total_amount + new.fee), new.currency, greatest(v_available, 0), new.currency, v_reserve;
    end if;
  end if;

  -- (B) NO SHORT SELLING / NO GHOST SELLS: cannot sell what the ledger
  --     does not prove you hold.
  if new.transaction_type = 'SELL' then
    v_held := fn_units_held(new.user_id, new.asset_id);
    if new.quantity > v_held then
      raise exception
        'NO_GHOST_ASSETS_VIOLATION: attempting to sell % units but ops_log proves only % units held',
        new.quantity, v_held;
    end if;
  end if;

  return new;
end;
$$;

create trigger trg_ops_log_golden_rules
  before insert on ops_log
  for each row execute function fn_enforce_golden_rules();

-- ----------------------------------------------------------------------------
-- 7. UI_PIPELINE_METRICS (the central calculation engine)
-- ----------------------------------------------------------------------------
-- One row per (user, held asset). Computes, in order:
--   1. Holdings purely from ops_log (HAVING units > 0 -> no ghost assets).
--   2. Price normalization: (current_price * calibration_factor) / 100 for TASE.
--   3. Base-currency conversion via fx_rates.
--   4. Window functions: asset weight, layer weight, layer drift vs DNA target.
--   5. Defense statuses: DATA_STALE > SELL_TRIGGERED > FUNDAMENTAL_AUDIT_REQUIRED > HOLD.
--      DATA_STALE deliberately ranks first: no defense decision may be made
--      on data older than the user's TTL (Golden Rule #3).
create or replace view ui_pipeline_metrics as
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
    rp.peak_price
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
    case when p.asset_currency = p.base_currency then 1.0
         else fx.rate
    end                                                 as fx_to_base,
    p.units_held * p.normalized_price                   as market_value_local,
    p.units_held * p.normalized_price *
      case when p.asset_currency = p.base_currency then 1.0
           else fx.rate
      end                                               as market_value_base
  from priced p
  left join fx_rates fx on fx.base_currency  = p.asset_currency
                       and fx.quote_currency = p.base_currency
)
select
  v.user_id,
  v.asset_id,
  v.ticker,
  v.data_symbol,
  v.exchange,
  v.layer_code,
  v.layer_name,
  v.asset_currency,
  v.base_currency,
  v.units_held,
  round(v.normalized_price,    4)                       as normalized_price,
  round(v.normalized_high_52w, 4)                       as normalized_high_52w,
  round(v.market_value_local,  2)                       as market_value_local,
  round(v.market_value_base,   2)                       as market_value_base,
  round(sum(v.market_value_base) over w_user, 2)        as portfolio_value_base,

  -- Window functions (asset weight, layer weight, drift vs generic DNA):
  round((v.market_value_base
         / nullif(sum(v.market_value_base) over w_user, 0)) * 100, 2)
                                                        as current_weight_pct,
  round((sum(v.market_value_base) over w_layer
         / nullif(sum(v.market_value_base) over w_user, 0)) * 100, 2)
                                                        as layer_weight_pct,
  v.target_weight_pct,
  round(((sum(v.market_value_base) over w_layer
          / nullif(sum(v.market_value_base) over w_user, 0)) * 100)
        - v.target_weight_pct, 2)                       as layer_drift_pct,

  -- UI indicators:
  case when v.normalized_high_52w > 0
       then round((1 - v.normalized_price / v.normalized_high_52w) * 100, 2)
  end                                                   as drawdown_52w_pct,
  case when v.effective_stop_pct is not null and v.peak_price > 0
       then round(((v.normalized_price
                    - v.peak_price * (1 - v.effective_stop_pct / 100.0))
                   / v.peak_price) * 100, 2)
  end                                                   as distance_to_stop_pct,
  v.peak_price,
  v.price_updated_at,
  v.is_stale,

  -- Defense status generation (layer-generic, DNA-driven):
  case
    when v.is_stale
      then 'DATA_STALE'
    when v.effective_stop_pct is not null
         and v.peak_price > 0
         and v.normalized_price <= v.peak_price * (1 - v.effective_stop_pct / 100.0)
      then 'SELL_TRIGGERED'
    when v.audit_drawdown_pct is not null
         and v.normalized_high_52w > 0
         and (1 - v.normalized_price / v.normalized_high_52w) * 100 >= v.audit_drawdown_pct
      then 'FUNDAMENTAL_AUDIT_REQUIRED'
    else 'HOLD'
  end                                                   as defense_status
from valued v
window
  w_user  as (partition by v.user_id),
  w_layer as (partition by v.user_id, v.layer_code);

-- ----------------------------------------------------------------------------
-- 8. ROW LEVEL SECURITY (Supabase)
-- ----------------------------------------------------------------------------
alter table user_settings     enable row level security;
alter table allocation_layers enable row level security;
alter table portfolio_assets  enable row level security;
alter table risk_profiles     enable row level security;
alter table ops_log           enable row level security;
alter table fx_rates          enable row level security;

create policy p_user_settings_own on user_settings
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy p_allocation_layers_own on allocation_layers
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy p_portfolio_assets_own on portfolio_assets
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy p_risk_profiles_own on risk_profiles
  for all using (exists (select 1 from portfolio_assets pa
                         where pa.asset_id = risk_profiles.asset_id
                           and pa.user_id = auth.uid()))
  with check   (exists (select 1 from portfolio_assets pa
                         where pa.asset_id = risk_profiles.asset_id
                           and pa.user_id = auth.uid()));

-- Ledger: users may INSERT and SELECT their own rows. No UPDATE/DELETE
-- policies exist at all - combined with the immutability trigger this makes
-- the ledger append-only at two independent layers.
create policy p_ops_log_select_own on ops_log
  for select using (user_id = auth.uid());
create policy p_ops_log_insert_own on ops_log
  for insert with check (user_id = auth.uid());

-- FX rates are global read-only reference data (written by the backend
-- service role, which bypasses RLS):
create policy p_fx_rates_read on fx_rates
  for select using (true);

-- ============================================================================
-- END OF PHASE 1 FOUNDATION
-- ============================================================================
