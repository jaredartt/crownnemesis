-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE, so no "Potential issue detected" dialog.
--  Run 0040 first. The last statement prints a row of checks; every column
--  must say true.
-- ===========================================================================
--  0041 - two playlists
--
--  settings.music has had a slider since 0022 and nothing behind it to turn
--  down -- "Nothing to play yet" says so right there in en.json. This gives it
--  something: a menu playlist and a battle playlist, each an ordered list of
--  rows pointing at files in the 'audio' bucket 0040 already opened, each
--  playable on shuffle or in order, and each editable live from the Music tab
--  of Admin Mode.
--
--  A table, not a jsonb blob on a settings row: a playlist is a LIST OF
--  THINGS, plural, and a table is what a list of things is. `sort` is the
--  order for when shuffle is off; `is_active` is how a track is taken out of
--  rotation without losing the row (the same retire-not-delete choice 0025
--  made for cards, and for the same reason -- a track a client had already
--  queued should not 404 mid-song because someone unchecked a box).
--
--  Ordinary table writes, gated by cn_is_super_admin() the way 0039 gates
--  everything new -- there is no function here to wrap them in, because there
--  is no rule to enforce beyond "only the one account may write". Reading is
--  open to anyone signed in, same as cards: a playlist is not a secret.
-- ===========================================================================

create table if not exists public.music_tracks (
  id         uuid primary key default gen_random_uuid(),
  category   text not null check (category in ('menu', 'battle')),
  title      text not null default '',
  url        text not null,
  sort       int  not null default 0,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists music_tracks_category_idx
  on public.music_tracks(category, sort);

alter table public.music_tracks enable row level security;

drop policy if exists "music readable by authenticated" on public.music_tracks;
create policy "music readable by authenticated"
  on public.music_tracks for select to authenticated using (true);

drop policy if exists "super admin writes music" on public.music_tracks;
create policy "super admin writes music"
  on public.music_tracks for all to authenticated
  using (public.cn_is_super_admin())
  with check (public.cn_is_super_admin());

-- Keeps updated_at honest the same way cards.updated_at is kept honest, so a
-- client caching by timestamp (the way useMatch.ts already does for matches)
-- has one to trust.
create or replace function public.cn_touch_music_track()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  new.title := btrim(coalesce(new.title, ''));
  new.url := btrim(coalesce(new.url, ''));
  if new.url = '' then raise exception 'a track needs a file'; end if;
  return new;
end $$;

drop trigger if exists music_tracks_touch on public.music_tracks;
create trigger music_tracks_touch
  before insert or update on public.music_tracks
  for each row execute function public.cn_touch_music_track();

-- ---------------------------------------------------------------------------
-- One row, not a column on some other table -- a shuffle toggle is a fact
-- about the playlists, not about a card or a profile, and it needed
-- somewhere of its own to live. `id boolean primary key default true check
-- (id)` is the standard trick for "this table may only ever hold one row":
-- the primary key can only be true, and true is the only value ever inserted.
-- ---------------------------------------------------------------------------
create table if not exists public.music_settings (
  id            boolean primary key default true check (id),
  menu_shuffle  boolean not null default true,
  battle_shuffle boolean not null default true,
  updated_at    timestamptz not null default now()
);
insert into public.music_settings (id) values (true) on conflict (id) do nothing;

alter table public.music_settings enable row level security;

drop policy if exists "music settings readable by authenticated" on public.music_settings;
create policy "music settings readable by authenticated"
  on public.music_settings for select to authenticated using (true);

drop policy if exists "super admin writes music settings" on public.music_settings;
create policy "super admin writes music settings"
  on public.music_settings for update to authenticated
  using (public.cn_is_super_admin())
  with check (public.cn_is_super_admin());

-- ---------------------------------------------------------------------------
-- Realtime, so a track added in the Music tab reaches an open lobby or an
-- open match without anybody refreshing.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname='supabase_realtime' and schemaname='public' and tablename='music_tracks') then
    alter publication supabase_realtime add table public.music_tracks;
  end if;
  if not exists (select 1 from pg_publication_tables
                  where pubname='supabase_realtime' and schemaname='public' and tablename='music_settings') then
    alter publication supabase_realtime add table public.music_settings;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Did it work? All true means yes.
-- ---------------------------------------------------------------------------
select
  to_regclass('public.music_tracks') is not null                as music_tracks_exists,
  to_regclass('public.music_settings') is not null               as music_settings_exists,
  (select count(*) from public.music_settings) = 1                as exactly_one_settings_row,
  (select count(*) from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public'
      and tablename in ('music_tracks','music_settings')) = 2     as music_is_realtime;
