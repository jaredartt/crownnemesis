-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice for the table/column/policy/trigger/publication
--  work; the one true DELETE in here is inside admin_delete_card(), a
--  function this file only (re)defines -- running this file never deletes a
--  row by itself. Run 0042 first. The last statement prints a row of checks;
--  every column must say true.
-- ===========================================================================
--  0046 -- admin content everywhere, and a real way to remove a card
--
--  PART ONE -- "edit all menu content, in both languages, from the panel"
--  -------------------------------------------------------------------------
--  Two mechanisms, not one, because the ask has two different shapes:
--
--  1. menu_sections (0042) grows four nullable columns: title_en, title_es,
--     subtitle_en, subtitle_es. NULL means exactly what an absent row already
--     means for `visible`/`sort` -- "nothing has been said, use the built-in
--     text" -- so a database that has run this migration and had nothing
--     touched in it renders identically to one that has not. Lobby.tsx reads
--     these ahead of its own dictionary keys for the tile's headline and its
--     one-line note, which is the piece of "everything inside them" that
--     lives on the tile itself rather than inside whatever page it opens.
--
--  2. menu_content_overrides is the general answer to the rest of the ask.
--     The alternative -- a bespoke column for every button and caption in
--     every screen the game has -- is a column added forever, one at a time,
--     for whichever string somebody happens to ask about next, and a project
--     that guessed wrong about which strings mattered would need a migration
--     to fix the guess. Every one of those strings already has a name: the
--     literal i18n key it is stored under in src/i18n/en.json and es.json
--     (see i18ncheck's own rule against constructing one). This table lets an
--     admin write a replacement value for any EXISTING key, in both
--     languages, and src/lib/i18n.ts's translate() is changed to look here
--     BEFORE it falls back to the bundled JSON. That makes "edit anything in
--     the game" true today, for every string already wired through t(),
--     without a second implementation of each screen -- at the cost of the
--     admin needing to know (or look up, via the key datalist the panel now
--     shows) which key labels which sentence. That trade is the deliberate
--     interpretation this migration makes of an open-ended ask: coverage and
--     safety over a hand-built editor per screen.
--
--     A row here is keyed by that literal key and carries both languages
--     because a caption that exists in English but not Spanish would be a
--     caption an admin re-broke for half the players the moment they touched
--     it -- unlike ability_es on cards, which is allowed to be null because
--     abilityText() falls back to English there on purpose, nothing here
--     should silently go English-in-Spanish just because the admin filled in
--     one box and not the other.
--
--  Both are gated by cn_is_super_admin(), the same gate 0042 put on
--  menu_sections, because both are Admin Mode's Menu tab, not the card
--  editor -- see PART TWO for why that one is different.
--
--  PART TWO -- admin_delete_card()
--  -------------------------------------------------------------------------
--  Every other place in this codebase "deletes" a card by retiring it
--  (is_active = false), because a slug is referenced by reference in three
--  places a hard DELETE cannot see and cannot fix up: profiles.deck,
--  profiles.kingdoms[].deck, and a running match's state->'units' snapshot.
--  The developer asked for a real delete anyway, for the rare test/mistake
--  row retiring was never meant to hide forever, so this function does
--  exactly that -- but only once every one of those three places has been
--  checked and come back empty, and only for a card that has ALREADY been
--  retired, because deleting a card still in play is a strictly worse version
--  of retiring it that this function has no reason to allow.
--
--  Gated by plain is_admin, not cn_is_super_admin() -- because that is what
--  "admins write cards" (0001) has always checked, unchanged since, for
--  every other write this table takes, and a delete RPC that started
--  checking a stricter gate than insert/update on the very same table would
--  be a second, higher door on a room that already has one.
--
--  Storage cleanup (the art/audio files under the slug) is NOT done here:
--  plpgsql cannot reach Supabase Storage, so the client calls
--  supabase.storage.from(...).remove(...) itself, after this function
--  returns. See AdminCards.tsx and the report for what that tradeoff means.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. menu_sections grows its four bilingual override columns.
-- ---------------------------------------------------------------------------
alter table public.menu_sections
  add column if not exists title_en text,
  add column if not exists title_es text,
  add column if not exists subtitle_en text,
  add column if not exists subtitle_es text;

-- Blank is the same as unset here, the same way a blank accent or ability
-- would be an odd thing to store literally -- an admin clearing a box with
-- the backspace key should get the same "gone, fall back" result as pressing
-- the Reset button does.
create or replace function public.cn_touch_menu_section()
returns trigger language plpgsql
set search_path = public
as $$
begin
  new.id := lower(btrim(coalesce(new.id, '')));
  if new.id = '' then raise exception 'a menu section needs an id'; end if;
  new.title_en    := nullif(btrim(coalesce(new.title_en, '')), '');
  new.title_es    := nullif(btrim(coalesce(new.title_es, '')), '');
  new.subtitle_en := nullif(btrim(coalesce(new.subtitle_en, '')), '');
  new.subtitle_es := nullif(btrim(coalesce(new.subtitle_es, '')), '');
  new.updated_at := now();
  return new;
end $$;

-- (trigger already exists from 0042 and points at this function by name;
-- replacing the function body is enough, but the create-if-missing below is
-- here so this file stands on its own if 0042 is ever re-run after it.)
drop trigger if exists menu_sections_touch on public.menu_sections;
create trigger menu_sections_touch
  before insert or update on public.menu_sections
  for each row execute function public.cn_touch_menu_section();

-- ---------------------------------------------------------------------------
-- 2. menu_content_overrides -- one row per overridden i18n key.
-- ---------------------------------------------------------------------------
create table if not exists public.menu_content_overrides (
  key        text primary key,
  value_en   text not null,
  value_es   text not null,
  updated_at timestamptz not null default now()
);

alter table public.menu_content_overrides enable row level security;

drop policy if exists "content overrides readable by authenticated" on public.menu_content_overrides;
create policy "content overrides readable by authenticated"
  on public.menu_content_overrides for select to authenticated using (true);

drop policy if exists "super admin writes content overrides" on public.menu_content_overrides;
create policy "super admin writes content overrides"
  on public.menu_content_overrides for all to authenticated
  using (public.cn_is_super_admin())
  with check (public.cn_is_super_admin());

create or replace function public.cn_touch_content_override()
returns trigger language plpgsql
set search_path = public
as $$
begin
  new.key := btrim(coalesce(new.key, ''));
  if new.key = '' then raise exception 'a content override needs a key -- the exact dotted name it overrides, like lobby.ranked'; end if;
  new.value_en := coalesce(new.value_en, '');
  new.value_es := coalesce(new.value_es, '');
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists menu_content_overrides_touch on public.menu_content_overrides;
create trigger menu_content_overrides_touch
  before insert or update on public.menu_content_overrides
  for each row execute function public.cn_touch_content_override();

do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname='supabase_realtime' and schemaname='public' and tablename='menu_content_overrides') then
    alter publication supabase_realtime add table public.menu_content_overrides;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. admin_delete_card(p_id) -- the real, checked delete.
-- ---------------------------------------------------------------------------
create or replace function public.admin_delete_card(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_slug   text;
  v_active boolean;
  v_name   text;
  v_who    text;
begin
  if not exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin) then
    raise exception 'only an admin can delete a card';
  end if;

  select c.slug, c.is_active, c.name into v_slug, v_active, v_name
    from public.cards c where c.id = p_id;
  if not found then
    raise exception 'no card with that id exists';
  end if;

  if v_active then
    raise exception '% must be retired (untick "In the game" and save) before it can be deleted permanently', v_name;
  end if;

  -- Everything below only means anything for a card that ever had a slug --
  -- the handful of pre-slug rows (retired long before 0005) were never
  -- referable by slug in the first place, so there is nothing to check.
  if v_slug is not null then
    select p.username into v_who
      from public.profiles p
      where p.deck @> array[v_slug]
      limit 1;
    if v_who is not null then
      raise exception '% is still in %''s selected deck -- it has to come out of that deck before the card can be deleted', v_name, v_who;
    end if;

    select p.username into v_who
      from public.profiles p
      where exists (
        select 1 from jsonb_array_elements(coalesce(p.kingdoms, '[]'::jsonb)) k
        where (k -> 'deck') ? v_slug
      )
      limit 1;
    if v_who is not null then
      raise exception '% is still in one of %''s saved kingdoms -- it has to come out of that deck before the card can be deleted', v_name, v_who;
    end if;

    if exists (
      select 1 from public.matches m
      where m.status <> 'finished'
        and position(('"slug":"' || v_slug || '"') in m.state::text) > 0
    ) then
      raise exception '% is on the board in a match that has not finished yet -- it cannot be deleted until that match ends', v_name;
    end if;
  end if;

  delete from public.cards where id = p_id;
end
$$;

revoke all on function public.admin_delete_card(uuid) from public;
grant execute on function public.admin_delete_card(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Did it work? All true means yes.
-- ---------------------------------------------------------------------------
select
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='menu_sections'
      and column_name in ('title_en','title_es','subtitle_en','subtitle_es')) = 4
                                                                as menu_sections_has_bilingual_columns,
  to_regclass('public.menu_content_overrides') is not null     as overrides_table_exists,
  (select count(*) from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='menu_content_overrides') = 1
                                                                as overrides_are_realtime,
  (select count(*) from pg_proc where proname = 'admin_delete_card') >= 1
                                                                as admin_delete_card_exists;
