-- Phase 2.1 acceptance tests (local PostgreSQL 16 + 00_supabase_stub.sql). TEST ONLY.
\set ON_ERROR_STOP 1
\set QUIET 1
create or replace function pg_temp.assert(cond boolean, label text) returns void language plpgsql as $$
begin
  if cond is not true then raise exception 'FAIL: %', label; end if;
  raise notice 'PASS: %', label;
end $$;
-- helper to act as a Supabase end user
create or replace function pg_temp.act_as(u uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', u::text, false);
  execute 'set role authenticated';
end $$;

insert into auth.users values ('aaaaaaaa-0000-0000-0000-000000000001'), ('bbbbbbbb-0000-0000-0000-000000000002');
insert into fx_rates values ('USD','ILS',3.7, now());

-- ===================== USER A: Tactical Momentum 70/20/10 =====================
select pg_temp.act_as('aaaaaaaa-0000-0000-0000-000000000001');
insert into user_settings (user_id) values (auth.uid());
begin;
insert into allocation_layers (user_id, layer_code, display_name, target_weight_pct, trailing_stop_pct, audit_drawdown_pct) values
  (auth.uid(),'CORE','Core',70,null,null),
  (auth.uid(),'SATELLITE','Satellite',20,12,null),
  (auth.uid(),'QUALITY','Quality',10,null,15);
commit;
insert into portfolio_assets (user_id, ticker, exchange, layer_code, currency) values
  (auth.uid(),'VOO','ARCA','CORE','USD'),
  (auth.uid(),'SMH','NASDAQ','SATELLITE','USD'),
  (auth.uid(),'COPX','ARCA','SATELLITE','USD');
insert into ops_log (user_id, transaction_type, asset_symbol, total_amount, currency)
  values (auth.uid(),'DEPOSIT','ILS',100000,'ILS');
insert into ops_log (user_id, transaction_type, asset_symbol, total_amount, currency, fx_rate)
  values (auth.uid(),'EXCHANGE','USD',37000,'ILS',0.27027027);
reset role;

-- DSVE (service side) writes market data
update portfolio_assets set current_price=500, high_52w=520, price_updated_at=now() where ticker='VOO';
update portfolio_assets set current_price=70,  high_52w=100, price_updated_at=now() where ticker='SMH';
update portfolio_assets set current_price=50,  high_52w=48,  price_updated_at=now() where ticker='COPX';

select pg_temp.act_as('aaaaaaaa-0000-0000-0000-000000000001');
insert into ops_log (user_id, transaction_type, asset_symbol, asset_id, quantity, price_per_unit, total_amount, currency)
  select auth.uid(),'BUY','VOO',asset_id,10,500,5000,'USD' from portfolio_assets where ticker='VOO';
insert into ops_log (user_id, transaction_type, asset_symbol, asset_id, quantity, price_per_unit, total_amount, currency)
  select auth.uid(),'BUY','SMH',asset_id,20,70,1400,'USD' from portfolio_assets where ticker='SMH';
insert into ops_log (user_id, transaction_type, asset_symbol, asset_id, quantity, price_per_unit, total_amount, currency)
  select auth.uid(),'BUY','COPX',asset_id,10,50,500,'USD' from portfolio_assets where ticker='COPX';

-- ---- F3: cycle opening ----
select pg_temp.assert((select protection_state='RECOVERY' and entry_price=70 and entry_hwm=100
  from risk_profiles rp join portfolio_assets pa using (asset_id) where pa.ticker='SMH'),
  'F3 dip buy opens RECOVERY with entry_hwm = 52w high');
select pg_temp.assert((select stop_price=61.6 and stop_order_type='STOP_MARKET' and alert_trigger_price=100
  from ui_pipeline_metrics where ticker='SMH'), 'F3 RECOVERY stop = entry*0.88 = 61.6, alert at HWM 100');
select pg_temp.assert((select protection_state='TRAILING' and stop_price=44
  from ui_pipeline_metrics where ticker='COPX'), 'F3 buy above 52w high -> TRAILING immediately');
select pg_temp.assert((select protection_state is null and stop_price is null and defense_status='HOLD'
  from ui_pipeline_metrics where ticker='VOO'), 'Core has no protection state / stop');

-- ---- F2: cash in denominator ----
-- invested: VOO 5000*3.7=18500, SMH 1400*3.7=5180, COPX 500*3.7=1850 -> 25530
-- cash: ILS 63000 + USD (10000-6900)=3100*3.7=11470 -> 74470 - reserve 30000 = 44470
-- capital = 70000
select pg_temp.assert((select abs(invested_value_base-25530)<0.1 and abs(available_cash_base-44470)<0.1
  and abs(portfolio_value_base-70000)<0.1 from ui_pipeline_metrics where ticker='VOO'),
  'F2 capital = invested 25530 + available cash 44470 (reserve excluded) = 70000');
select pg_temp.assert((select abs(current_weight_pct-26.43)<0.01 and abs(layer_drift_pct-(26.43-70))<0.01
  from ui_pipeline_metrics where ticker='VOO'), 'F2 VOO weight 26.43% of capital, not of invested');
select pg_temp.assert((select abs(sum(distinct layer_weight_pct)+max(cash_weight_pct)-100)<0.05
  from ui_pipeline_metrics), 'F2 layer weights + cash weight = 100%');
reset role;

-- ---- F3: latch ----
update portfolio_assets set current_price=85, price_updated_at=now() where ticker='SMH';
select pg_temp.assert((select protection_state='RECOVERY' and stop_price=61.6 from ui_pipeline_metrics where ticker='SMH'),
  'F3 price 85 < HWM: still RECOVERY, stop does not move');
update portfolio_assets set current_price=101, high_52w=101, price_updated_at=now() where ticker='SMH';
select pg_temp.assert((select protection_state='TRAILING' and peak_price=101 and stop_price=88.88 and stop_order_type='TRAILING_STOP'
  from ui_pipeline_metrics where ticker='SMH'), 'F3 breakout 101 -> TRAILING, peak 101, stop 88.88');
update portfolio_assets set current_price=95, price_updated_at=now() where ticker='SMH';
select pg_temp.assert((select protection_state='TRAILING' and defense_status='HOLD' from ui_pipeline_metrics where ticker='SMH'),
  'F3 one-way latch: back below HWM stays TRAILING');
update portfolio_assets set current_price=88, price_updated_at=now() where ticker='SMH';
select pg_temp.assert((select defense_status='SELL_TRIGGERED' from ui_pipeline_metrics where ticker='SMH'),
  'F3 88 <= 88.88 -> SELL_TRIGGERED');

-- ---- F3: re-entry resets the cycle ----
select pg_temp.act_as('aaaaaaaa-0000-0000-0000-000000000001');
insert into ops_log (user_id, transaction_type, asset_symbol, asset_id, quantity, price_per_unit, total_amount, currency)
  select auth.uid(),'SELL','SMH',asset_id,20,88,1760,'USD' from portfolio_assets where ticker='SMH';
reset role;
update portfolio_assets set current_price=80, price_updated_at=now() where ticker='SMH';
select pg_temp.act_as('aaaaaaaa-0000-0000-0000-000000000001');
insert into ops_log (user_id, transaction_type, asset_symbol, asset_id, quantity, price_per_unit, total_amount, currency)
  select auth.uid(),'BUY','SMH',asset_id,5,80,400,'USD' from portfolio_assets where ticker='SMH';
select pg_temp.assert((select protection_state='RECOVERY' and entry_price=80 and entry_hwm=101 and stop_price=70.4
  from ui_pipeline_metrics where ticker='SMH'), 'F3 re-entry after full exit: new RECOVERY cycle (80, HWM 101, stop 70.4)');
insert into ops_log (user_id, transaction_type, asset_symbol, asset_id, quantity, price_per_unit, total_amount, currency)
  select auth.uid(),'BUY','SMH',asset_id,5,78,390,'USD' from portfolio_assets where ticker='SMH';
select pg_temp.assert((select entry_price=80 from ui_pipeline_metrics where ticker='SMH'),
  'F3 add-on buy inside open cycle leaves protection state untouched');

-- ---- S2: server-owned market data & defense state ----
do $$ begin
  update portfolio_assets set current_price = 999 where ticker='SMH';
  raise exception 'FAIL: user could write prices';
exception when insufficient_privilege then raise notice 'PASS: S2 user cannot write current_price';
end $$;
do $$ begin
  update risk_profiles set protection_state = 'TRAILING';
  raise exception 'FAIL: user could write protection_state';
exception when insufficient_privilege then raise notice 'PASS: S2 user cannot write protection_state';
end $$;
update risk_profiles set stop_override_pct = 15
  where asset_id = (select asset_id from portfolio_assets where ticker='SMH');
select pg_temp.assert((select stop_override_pct=15 from risk_profiles rp join portfolio_assets pa using (asset_id) where pa.ticker='SMH'),
  'S2 user can still set own stop_override_pct preference');
reset role;

-- ===================== USER B: Hyper-Quality 80/0/20 =====================
select pg_temp.act_as('bbbbbbbb-0000-0000-0000-000000000002');
insert into user_settings (user_id) values (auth.uid());
begin;
insert into allocation_layers (user_id, layer_code, display_name, target_weight_pct, trailing_stop_pct, audit_drawdown_pct) values
  (auth.uid(),'CORE','Core',80,null,null),
  (auth.uid(),'SATELLITE','Satellite',0,12,null),
  (auth.uid(),'QUALITY','Quality',20,null,15);
commit;
select pg_temp.assert((select count(*)=3 and sum(target_weight_pct)=100 from allocation_layers),
  'F1 80/0/20 template stored (0% layer accepted)');

-- ---- S1: tenant isolation through the view ----
select pg_temp.assert((select count(*)=0 from ui_pipeline_metrics),
  'S1 user B sees none of user A rows in ui_pipeline_metrics (security_invoker)');
select pg_temp.assert((select count(*)=0 from risk_profiles), 'S1 user B sees none of user A risk_profiles');

-- ---- S3: cannot reference another user's asset ----
insert into ops_log (user_id, transaction_type, asset_symbol, total_amount, currency)
  values (auth.uid(),'DEPOSIT','ILS',50000,'ILS');
do $$ begin
  insert into ops_log (user_id, transaction_type, asset_symbol, asset_id, total_amount, currency)
    values (auth.uid(),'DIVIDEND','SMH','00000000-0000-0000-0000-000000000000'::uuid, 10,'USD');
exception when others then null; end $$;
do $$
declare v uuid;
begin
  reset role;
  select asset_id into v from portfolio_assets where ticker='SMH';
  perform set_config('request.jwt.claim.sub','bbbbbbbb-0000-0000-0000-000000000002', false);
  set role authenticated;
  insert into ops_log (user_id, transaction_type, asset_symbol, asset_id, total_amount, currency)
    values (auth.uid(),'DIVIDEND','SMH', v, 10,'USD');
  raise exception 'FAIL: cross-tenant asset reference accepted';
exception when raise_exception then
  if sqlerrm like 'ASSET_OWNERSHIP_VIOLATION%' then raise notice 'PASS: S3 cross-tenant asset reference rejected';
  else raise; end if;
end $$;
reset role;

-- ---- Golden rules still intact ----
select pg_temp.act_as('bbbbbbbb-0000-0000-0000-000000000002');
do $$ begin
  insert into ops_log (user_id, transaction_type, asset_symbol, total_amount, currency)
    values (auth.uid(),'WITHDRAWAL','ILS',25000,'ILS');
  raise exception 'FAIL: reserve breached';
exception when raise_exception then
  if sqlerrm like 'ZERO_MARGIN_VIOLATION%' then raise notice 'PASS: Golden Rule #1 still blocks dipping into the 30K reserve';
  else raise; end if;
end $$;
reset role;
\echo ALL TESTS COMPLETED
