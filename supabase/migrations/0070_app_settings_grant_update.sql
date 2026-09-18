-- =============================================================================
-- 0070 -- HOTFIX: grant UPDATE on app_settings to authenticated.
--
-- WHY: 0066 added the "super admin writes app settings" RLS UPDATE policy
-- (qual/with_check: cn_is_super_admin()) but never granted the base table
-- privilege alongside it. A GRANT is checked BEFORE RLS -- a correct RLS
-- policy on a table with no UPDATE grant still fails every write with a
-- hard "permission denied for table app_settings", which is exactly what
-- Jared hit live clicking the admin Ladder-points toggle. RLS still does
-- the real gating (only cn_is_super_admin() passes with_check); this grant
-- only clears the privilege floor RLS sits on top of. `anon` is included
-- for symmetry with the table's own SELECT policy (readable by
-- `authenticated` only, in fact -- but the grant matches this project's
-- existing convention of granting anon+authenticated together and letting
-- RLS do the real work) -- and because a future SELECT-only anon policy on
-- this table should not additionally require a follow-up grant migration.
-- =============================================================================
grant update on public.app_settings to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Did it work?
-- ---------------------------------------------------------------------------
select
  has_table_privilege('authenticated', 'public.app_settings', 'UPDATE')
    as authenticated_can_now_update_app_settings;
