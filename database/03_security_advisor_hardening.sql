-- ============================================================================
-- FORTFOLIO 2.0 - 03: SECURITY ADVISOR HARDENING (2026-11-22)
-- Target: Supabase. Apply AFTER 02_phase2_1_saas_fixes.sql.
-- Resolves every Supabase Security Advisor finding after 01 + 02.
-- ============================================================================

-- (1) Trigger functions must never be callable as RPC endpoints
--     (lints 0028 / 0029: SECURITY DEFINER executable by anon/authenticated).
revoke execute on function public.fn_open_position_cycle()       from public, anon, authenticated;
revoke execute on function public.fn_advance_protection_latch()  from public, anon, authenticated;
revoke execute on function public.fn_ops_log_asset_ownership()   from public, anon, authenticated;
revoke execute on function public.fn_validate_allocation_sum()   from public, anon, authenticated;
revoke execute on function public.fn_ops_log_immutable()         from public, anon, authenticated;
revoke execute on function public.fn_enforce_golden_rules()      from public, anon, authenticated;

-- (2) Pin search_path on every function (lint 0011).
alter function public.fn_validate_allocation_sum()        set search_path = public;
alter function public.fn_ops_log_immutable()              set search_path = public;
alter function public.fn_cash_balance(uuid, char)         set search_path = public;
alter function public.fn_units_held(uuid, uuid)           set search_path = public;
alter function public.fn_enforce_golden_rules()           set search_path = public;
alter function public.fn_normalized_high_52w(uuid)        set search_path = public;

-- (3) TRUNCATE bypasses RLS and row-level triggers (incl. the append-only
--     ledger guard). API roles never need it.
revoke truncate on all tables in schema public from anon, authenticated;
