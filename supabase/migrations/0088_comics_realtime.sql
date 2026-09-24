-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice -- every add is guarded by an existence check.
--  Run 0080 first (this is the table this migration is about).
-- ===========================================================================
--  0088 -- HOTFIX: add comic_chapters/comic_pages to the supabase_realtime
--  publication.
--
--  Jared: "when I click the upload comic thing, I see nothing happening."
--  Every other admin-editable table in this project gets added to
--  `supabase_realtime` in its own migration (0040 for cards, 0041 for
--  music_tracks, 0042 for menu_sections, 0046 for menu_content_overrides,
--  ...) -- 0080_comics.sql is the one table that shipped without that line.
--  useComics.ts's own module-level cache (the same shape useCards.ts and
--  useMusic.ts already use) subscribes to exactly this publication to know
--  when to refetch; without being in it, a write from AdminComics.tsx goes
--  straight into the table and just... never comes back out to the screen
--  that made it, which is indistinguishable from the click doing nothing at
--  all. Six identical "New chapter" rows from six identical-looking clicks
--  is what that actually looked like from the inside.
--
--  Same hotfix shape as 0071 (app_settings' own turn missing this).
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname='supabase_realtime' and schemaname='public' and tablename='comic_chapters') then
    alter publication supabase_realtime add table public.comic_chapters;
  end if;
  if not exists (select 1 from pg_publication_tables
                  where pubname='supabase_realtime' and schemaname='public' and tablename='comic_pages') then
    alter publication supabase_realtime add table public.comic_pages;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Did it work? Both true means yes.
-- ---------------------------------------------------------------------------
select
  (select count(*) from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='comic_chapters') = 1
                                                                as comic_chapters_is_realtime,
  (select count(*) from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='comic_pages') = 1
                                                                as comic_pages_is_realtime;
