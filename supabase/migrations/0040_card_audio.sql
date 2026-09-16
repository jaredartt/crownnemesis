-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE, so no "Potential issue detected" dialog.
--  Run 0039 first. The last statement prints a row of checks; every column
--  must say true.
-- ===========================================================================
--  0040 - a card can carry four sounds
--
--  sfx.ts has never shipped a single audio file -- every blow, footstep and
--  parry in the game is synthesised on the way out, on purpose, and that
--  stays true after this file: nothing here removes a synthesised sound or
--  makes one required. What this adds is a LAYER a card can optionally carry
--  on top of it -- an attack, an ability, a passive and a walking sound, each
--  just a URL -- so a specific unit can sound like itself without the whole
--  game switching to shipped audio. The client (see customAudio.ts) plays the
--  card's own sound alongside the synthesised one when a card has one set,
--  and plays nothing extra when it does not.
--
--  Same bucket shape as 0025's art: public to read, because a footstep is not
--  a secret and a signed URL per frame would be a lot of machinery to hide
--  one, and writable only by cn_is_super_admin() -- the tighter lock 0039
--  introduced, because uploading whatever anybody likes into a bucket every
--  player's browser fetches unprompted is exactly the kind of thing that
--  should need the harder check rather than is_admin alone.
--
--  One bucket, not two: 0041's music lives in the same 'audio' bucket, one
--  folder over, at music/<category>/<file> instead of cards/<slug>-<kind>.
--  A second bucket for a second folder is a second policy to keep in step
--  with the first for no reason a reader could find later.
-- ===========================================================================

alter table public.cards add column if not exists audio_attack_url  text;
alter table public.cards add column if not exists audio_ability_url text;
alter table public.cards add column if not exists audio_passive_url text;
alter table public.cards add column if not exists audio_walk_url   text;

-- ---------------------------------------------------------------------------
-- 1. cn_check_card learns four more columns
--
-- SPLICED FROM 0032, not rebuilt from memory -- see project_status.md's own
-- "things that have bitten before" on exactly this mistake. cn_check_card has
-- been redefined three times since 0025 (0030's single reach number, 0031's
-- class-and-power rewrite, 0032's default-a-missing-class repair); copying
-- 0025's body here would have silently thrown all three away the moment this
-- migration ran. The only change from 0032's version is the four
-- `audio_*_url` lines, trimmed to null exactly the way art_url already is --
-- an admin clearing the upload field should mean "no sound", not a
-- zero-length string that reads as one in JavaScript and as something in SQL.
-- ---------------------------------------------------------------------------
create or replace function public.cn_check_card()
returns trigger language plpgsql as $$
begin
  new.slug := nullif(lower(btrim(coalesce(new.slug, ''))), '');
  new.name := btrim(coalesce(new.name, ''));
  new.role := lower(btrim(coalesce(new.role, '')));
  new.accent := lower(btrim(coalesce(new.accent, '')));
  new.art_url := nullif(btrim(coalesce(new.art_url, '')), '');
  new.ability := btrim(coalesce(new.ability, ''));
  new.ability_es := nullif(btrim(coalesce(new.ability_es, '')), '');
  new.audio_attack_url  := nullif(btrim(coalesce(new.audio_attack_url, '')), '');
  new.audio_ability_url := nullif(btrim(coalesce(new.audio_ability_url, '')), '');
  new.audio_passive_url := nullif(btrim(coalesce(new.audio_passive_url, '')), '');
  new.audio_walk_url    := nullif(btrim(coalesce(new.audio_walk_url, '')), '');

  if new.is_active and new.slug is null then
    raise exception 'a card needs a slug';
  end if;
  if new.slug is not null and new.slug !~ '^[a-z][a-z0-9-]{1,39}$' then
    raise exception 'a slug is lower case letters, digits and dashes: %', new.slug;
  end if;
  if new.is_active and new.name = '' then
    raise exception 'a card needs a name';
  end if;

  if new.accent !~ '^#[0-9a-f]{6}$' then
    raise exception 'an accent is six hex digits, like #2f4bff -- got %', new.accent;
  end if;

  -- ---- the class ----------------------------------------------------------
  -- A wrong class is still refused: it is what the Royal auras match on, and a
  -- sixth one spelled by hand would be a card no resistance could ever see.
  if new.role <> '' and not (new.role = any(cn_classes())) then
    raise exception 'a class is one of %, got %',
      array_to_string(cn_classes(), ', '), new.role;
  end if;
  -- But an EMPTY one is filled in rather than refused, and for retired rows as
  -- well as live ones -- see 0032 for the six-migration gap this closed.
  if new.role = '' then new.role := 'knight'; end if;
  new.flies := (new.role = 'flying');
  new.royal := (new.role = 'royal');

  if new.mov < 0 or new.mov > 12 then
    raise exception 'a move is 0 to 12';
  end if;

  -- ---- one reach number, and it starts at 1 (0030) ------------------------
  new.range := coalesce(nullif(new.range, 0), nullif(new.rmax, 0), 1);
  if new.range < 1 or new.range > 12 then
    raise exception 'a range is 1 to 12 -- got %', new.range;
  end if;
  new.rmax  := new.range;
  new.rmin  := 1;
  new.crmin := 1;
  new.crmax := new.range;

  -- ---- and one damage number, with the dice around it (0031) --------------
  if new.power is not null then
    if new.power < 1 or new.power > 200 then
      raise exception 'a power is 1 to 200';
    end if;
    new.dmin := greatest(0, new.power - cn_spread());
    new.dmax := new.power + cn_spread();
    new.attack := new.power;
  end if;

  -- ---- the aura (0031) ----------------------------------------------------
  if new.aura_kind is not null then
    if not new.royal then
      raise exception 'only a Royal carries an aura -- % is a %', new.name, new.role;
    end if;
    if new.aura_kind in ('resist', 'bonus')
       and not (coalesce(new.aura_class, '') = any(cn_classes())) then
      raise exception 'an aura that names a class needs one of %, got %',
        array_to_string(cn_classes(), ', '), coalesce(new.aura_class, '(null)');
    end if;
    if coalesce(new.aura_pct, 0) <= 0 then
      raise exception 'an aura with no percentage does nothing';
    end if;
  end if;

  new.updated_at := now();
  return new;
end $$;

-- The trigger itself is unchanged (still cards_are_sane before insert/update),
-- so nothing below this needs to be dropped or recreated -- CREATE OR REPLACE
-- above already put the new body behind the existing trigger.

-- ---------------------------------------------------------------------------
-- 2. the bucket
-- ---------------------------------------------------------------------------
do $$ begin
  if not exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    raise notice 'no storage schema here -- skipping the audio bucket';
    return;
  end if;

  insert into storage.buckets (id, name, public)
  values ('audio', 'audio', true)
  on conflict (id) do update set public = true;

  execute $p$drop policy if exists "audio is readable by anyone" on storage.objects$p$;
  execute $p$create policy "audio is readable by anyone"
             on storage.objects for select
             using (bucket_id = 'audio')$p$;

  execute $p$drop policy if exists "super admin writes audio" on storage.objects$p$;
  execute $p$create policy "super admin writes audio"
             on storage.objects for all to authenticated
             using (bucket_id = 'audio' and public.cn_is_super_admin())
             with check (bucket_id = 'audio' and public.cn_is_super_admin())$p$;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Realtime for the roster
--
-- useCards.ts has cached the roster for one request per session since it was
-- written; this is what lets it also hear about the edit that just landed,
-- rather than a player needing to reload the page to see a retuned card or a
-- newly attached sound.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname='supabase_realtime' and schemaname='public' and tablename='cards') then
    alter publication supabase_realtime add table public.cards;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Did it work? All true means yes.
-- ---------------------------------------------------------------------------
-- The bucket check is deliberately NOT in this final select, the same way
-- 0025's own final select never checks the 'art' bucket it creates: a plain
-- SQL statement has to resolve every table it MENTIONS before it can even
-- look at a CASE condition, storage schema or not, so a bucket check here
-- would fail this whole select on the test harness (which has no storage
-- schema at all) rather than skip cleanly the way the DO block above does.
select
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='cards'
      and column_name in ('audio_attack_url','audio_ability_url','audio_passive_url','audio_walk_url')
  ) = 4                                                       as cards_have_four_sounds,
  pg_get_functiondef('public.cn_check_card()'::regprocedure) ilike '%audio_walk_url%'
                                                              as the_guard_cleans_them_too,
  (select count(*) from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='cards') = 1
                                                              as cards_are_realtime;
