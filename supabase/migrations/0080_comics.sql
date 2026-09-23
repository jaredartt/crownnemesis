-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE, so no "Potential issue detected" dialog.
--  The last statement prints a row of checks; every column must say true.
-- ===========================================================================
--  0080 - comics, live instead of static
--
--  Comics.tsx used to read public/comics/index.json -- a file checked into
--  the repo, alongside the page images themselves, so "adding a chapter"
--  meant dropping files in and a deploy. Jared: an admin tab that can
--  upload pages itself, reorder them, retitle a chapter, write its
--  description, and give it its own thumbnail. None of that works against
--  a file baked into the build, so this is the same move 0040/0041 already
--  made for card art and music: a table for the metadata, a public
--  'comics' bucket for the pictures, gated by cn_is_super_admin() the way
--  every admin-only write in this app already is.
--
--  Two tables, not one JSONB column on a chapter row: a chapter's pages are
--  A LIST OF THINGS a reader scrolls through in order, and 0041's own
--  header already made this exact case for a table over a blob. `sort` is
--  the reading order on both tables, moved by swapping two rows' values
--  (AdminMusic.tsx's `move()`) rather than renumbering the whole list.
--
--  `thumbnail` is optional: Comics.tsx already falls back to a chapter's
--  own first page as its cover when nothing else is set, so most chapters
--  never need one uploaded at all.
-- ===========================================================================

create table if not exists public.comic_chapters (
  id         uuid primary key default gen_random_uuid(),
  title      text not null default '',
  -- The short line under the title in the chapter list -- Comics.tsx's own
  -- `note`, not renamed, so the reader component needs no changes at all.
  note       text not null default '',
  thumbnail  text,
  sort       int  not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists comic_chapters_sort_idx on public.comic_chapters(sort);

create table if not exists public.comic_pages (
  id         uuid primary key default gen_random_uuid(),
  chapter_id uuid not null references public.comic_chapters(id) on delete cascade,
  url        text not null,
  sort       int  not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists comic_pages_chapter_idx on public.comic_pages(chapter_id, sort);

alter table public.comic_chapters enable row level security;
alter table public.comic_pages enable row level security;

drop policy if exists "comic chapters readable by authenticated" on public.comic_chapters;
create policy "comic chapters readable by authenticated"
  on public.comic_chapters for select to authenticated using (true);

drop policy if exists "super admin writes comic chapters" on public.comic_chapters;
create policy "super admin writes comic chapters"
  on public.comic_chapters for all to authenticated
  using (public.cn_is_super_admin())
  with check (public.cn_is_super_admin());

drop policy if exists "comic pages readable by authenticated" on public.comic_pages;
create policy "comic pages readable by authenticated"
  on public.comic_pages for select to authenticated using (true);

drop policy if exists "super admin writes comic pages" on public.comic_pages;
create policy "super admin writes comic pages"
  on public.comic_pages for all to authenticated
  using (public.cn_is_super_admin())
  with check (public.cn_is_super_admin());

-- Keeps updated_at honest and blanks trimmed, same as cn_touch_music_track.
create or replace function public.cn_touch_comic_chapter()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  new.title := btrim(coalesce(new.title, ''));
  new.note := btrim(coalesce(new.note, ''));
  return new;
end $$;

drop trigger if exists comic_chapters_touch on public.comic_chapters;
create trigger comic_chapters_touch
  before insert or update on public.comic_chapters
  for each row execute function public.cn_touch_comic_chapter();

-- ---------------------------------------------------------------------------
-- the bucket -- same shape as 0040's 'audio' bucket.
-- ---------------------------------------------------------------------------
do $$ begin
  if not exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    raise notice 'no storage schema here -- skipping the comics bucket';
    return;
  end if;

  insert into storage.buckets (id, name, public)
  values ('comics', 'comics', true)
  on conflict (id) do update set public = true;

  execute $p$drop policy if exists "comics is readable by anyone" on storage.objects$p$;
  execute $p$create policy "comics is readable by anyone"
             on storage.objects for select
             using (bucket_id = 'comics')$p$;

  execute $p$drop policy if exists "super admin writes comics" on storage.objects$p$;
  execute $p$create policy "super admin writes comics"
             on storage.objects for all to authenticated
             using (bucket_id = 'comics' and public.cn_is_super_admin())
             with check (bucket_id = 'comics' and public.cn_is_super_admin())$p$;
end $$;

-- ===========================================================================
-- checks
-- ===========================================================================
select
  exists (select 1 from pg_tables where schemaname = 'public' and tablename = 'comic_chapters')
    as chapters_table_exists,
  exists (select 1 from pg_tables where schemaname = 'public' and tablename = 'comic_pages')
    as pages_table_exists,
  (select count(*) from pg_policies where schemaname = 'public' and tablename = 'comic_chapters') = 2
    as chapters_policy_count_ok,
  (select count(*) from pg_policies where schemaname = 'public' and tablename = 'comic_pages') = 2
    as pages_policy_count_ok,
  exists (select 1 from storage.buckets where id = 'comics' and public) as bucket_ok;
