-- =============================================================================
-- 0071 -- HOTFIX: add app_settings to the supabase_realtime publication.
--
-- WHY: after 0070 fixed the write itself, the admin Ladder-points toggle
-- updated the DB correctly but the checkbox didn't reflect it anywhere
-- else (or even back in the same tab) without a manual reload. A Postgres
-- table can have entirely correct RLS and grants and still never emit a
-- `postgres_changes` realtime event if it was never added to the
-- `supabase_realtime` publication -- a separate, easy-to-forget opt-in per
-- table. `useAppSettings.ts`'s realtime subscription was therefore
-- correctly wired and simply never fired.
-- =============================================================================
alter publication supabase_realtime add table public.app_settings;

-- ---------------------------------------------------------------------------
-- Did it work?
-- ---------------------------------------------------------------------------
select
  exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and tablename = 'app_settings'
  ) as app_settings_now_in_realtime_publication;
