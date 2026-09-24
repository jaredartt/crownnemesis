-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice: every alter is `if not exists`, and the trigger
--  function is `create or replace`. Run 0042 and 0046 first (this table's
--  own visible/sort/bilingual-text columns). The last statement prints a
--  row of checks; every column must say true.
-- ===========================================================================
--  0087 -- admin control over where a tile's picture sits and how big it is
--
--  Jared, screenshot of Admin Mode -> Menu -> Tiles: "make it so that I can
--  change the picture and/or crop them as I want, because maybe I want to
--  move them a little to the right, left, up or down." Then, mid-turn:
--  "Or zooming them or unzooming them."
--
--  Three more nullable columns on menu_sections, same shape as 0046's four
--  bilingual ones and for the same reason: NULL means "nothing has been
--  said here, use whatever Lobby.tsx's own TILES/hBias() would have drawn
--  anyway" -- so a database that has run this migration and had nothing
--  touched in it renders every tile identically to before. An admin who
--  only ever nudges ONE tile leaves every other tile's crop exactly as
--  today's hand-tuned hBias()/focus values already have it.
--
--  art_x / art_y -- the horizontal/vertical anchor of the picture inside
--  its tile, 0-100, the same percentage scale CSS background-position
--  already uses (and the same scale hBias()/`focus` in Lobby.tsx already
--  store their own numbers on, just as literal strings today). Clamped to
--  [0, 100] rather than rejected outright -- an admin dragging a slider
--  past an end should land AT the end, not get an error dialog for a
--  crop that was never going to mean anything past it anyway.
--
--  art_zoom -- how much bigger than normal the picture renders, as a
--  percentage where 100 is "whatever that tile already draws at today"
--  (Play/Ranked/etc.'s shared 1 -> 1.09 resting/hover scale, or My
--  Kingdom's own smaller 0.86 -> 0.94 -- see .mtile-art/.mt-team .mtile-art
--  in styles.css). The client multiplies its own existing scale by
--  art_zoom/100 rather than replacing it, so 100 (or NULL) is always a
--  no-op and even a zoomed tile keeps each tile's own crop-safety tuning
--  (the overscan that stops a skewed corner from showing empty tile).
--  Clamped to [50, 400] -- under half-size or past 4x is never a crop
--  anybody meant to land on, it is a slipped decimal on the way there.
-- ---------------------------------------------------------------------------
alter table public.menu_sections
  add column if not exists art_x    real,
  add column if not exists art_y    real,
  add column if not exists art_zoom real;

-- Same trigger function 0042/0046 already point menu_sections_touch at --
-- replacing its body is enough to pick up the new columns, since the
-- trigger itself is unchanged. Clamped with greatest/least rather than a
-- check constraint so a slider that overshoots by float rounding still
-- saves (at the clamped value) instead of bouncing the whole row's update.
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
  if new.art_x is not null then new.art_x := greatest(0, least(100, new.art_x)); end if;
  if new.art_y is not null then new.art_y := greatest(0, least(100, new.art_y)); end if;
  if new.art_zoom is not null then new.art_zoom := greatest(50, least(400, new.art_zoom)); end if;
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
-- Did it work? All true means yes.
-- ---------------------------------------------------------------------------
select
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='menu_sections'
      and column_name in ('art_x','art_y','art_zoom')) = 3
                                                                as menu_sections_has_art_columns,
  (select count(*) from pg_proc where proname = 'cn_touch_menu_section') >= 1
                                                                as touch_function_exists;
