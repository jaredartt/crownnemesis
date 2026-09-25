-- 0110: a card's power can be set to 0 in the admin page.
--
-- Jared: "Also make it so that I can set a card's power to 0 in the admin
-- page." The admin form itself (AdminCards.tsx's NUMBERS grid) never
-- stopped anyone typing 0 into Power -- Save just always failed, because
-- cn_check_card (the BEFORE INSERT/UPDATE trigger on `cards`, present
-- since 0025 and last touched for this rule at 0040) has always rejected
-- it server-side:
--
--   if new.power < 1 or new.power > 200 then
--     raise exception 'a power is 1 to 200';
--   end if;
--
-- The underlying column check (0018: `power is null or (power >= 0 and
-- power <= 999)`) already allowed 0 -- only this trigger's own floor was
-- ever the blocker. Dropping the floor from 1 to 0 is safe downstream:
-- dmin/dmax are derived right below as `greatest(0, power - cn_spread())`
-- / `power + cn_spread()`, so a power-0 card gets dmin 0 / dmax
-- cn_spread() (0 to 2 today) -- a valid, if toothless, damage roll, not a
-- divide-by-zero or a negative range. Nothing elsewhere in the engine
-- assumes power > 0: unitPower() (lib/types.ts) reads `pow ?? power`,
-- which treats 0 as a real value, not "unset", exactly as it should for a
-- card built to start at 0 and climb via a START_OF_TURN MODIFY_STAT
-- (0108) -- the very feature that makes a power-0 starting point useful
-- rather than just a curiosity.
create or replace function public.cn_check_card()
returns trigger
language plpgsql
set search_path = 'public'
as $$
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
  -- 0110: floor dropped from 1 to 0 -- see this migration's own header.
  if new.power is not null then
    if new.power < 0 or new.power > 200 then
      raise exception 'a power is 0 to 200';
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
end
$$;

do $$
declare v_src text;
begin
  select prosrc into v_src from pg_proc where proname = 'cn_check_card';
  if v_src !~ '0110' then
    raise exception 'cn_check_card does not mention 0110 -- migration did not apply as expected';
  end if;
end $$;

-- Self-test 1: power = 0 is now accepted, and derives dmin 0 / dmax
-- cn_spread() (2 today) / attack 0 -- not rejected, not left null.
do $$
declare v_id uuid; v_row cards%rowtype;
begin
  insert into public.cards (slug, name, role, accent, power, is_active)
    values ('zz-test-power-zero', 'ZZ Test Power Zero', 'knight', '#2f4bff', 0, false)
    returning id into v_id;
  select * into v_row from public.cards where id = v_id;
  if v_row.power <> 0 or v_row.dmin <> 0 or v_row.dmax <> 2 or v_row.attack <> 0 then
    raise exception '0110 self-test 1 FAILED: power 0 -> got power % dmin % dmax % attack %',
      v_row.power, v_row.dmin, v_row.dmax, v_row.attack;
  end if;
  delete from public.cards where id = v_id;
  raise notice '0110 self-test 1 passed: power 0 is accepted and derives dmin 0 / dmax 2 / attack 0.';
end $$;

-- Self-test 2: power = -1 is still rejected (the floor moved from 1 to 0,
-- not removed).
do $$
declare v_id uuid; v_raised boolean := false;
begin
  begin
    insert into public.cards (slug, name, role, accent, power, is_active)
      values ('zz-test-power-neg', 'ZZ Test Power Neg', 'knight', '#2f4bff', -1, false)
      returning id into v_id;
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    delete from public.cards where id = v_id;
    raise exception '0110 self-test 2 FAILED: power -1 was accepted, should have been rejected';
  end if;
  raise notice '0110 self-test 2 passed: power -1 is still rejected.';
end $$;

-- Self-test 3: power = 201 is still rejected (the ceiling is untouched).
do $$
declare v_id uuid; v_raised boolean := false;
begin
  begin
    insert into public.cards (slug, name, role, accent, power, is_active)
      values ('zz-test-power-over', 'ZZ Test Power Over', 'knight', '#2f4bff', 201, false)
      returning id into v_id;
  exception when others then
    v_raised := true;
  end;
  if not v_raised then
    delete from public.cards where id = v_id;
    raise exception '0110 self-test 3 FAILED: power 201 was accepted, should have been rejected';
  end if;
  raise notice '0110 self-test 3 passed: power 201 is still rejected.';
end $$;

-- Self-test 4: an ordinary positive power still derives the same dice it
-- always did -- this migration only moved the floor, nothing else.
do $$
declare v_id uuid; v_row cards%rowtype;
begin
  insert into public.cards (slug, name, role, accent, power, is_active)
    values ('zz-test-power-normal', 'ZZ Test Power Normal', 'knight', '#2f4bff', 20, false)
    returning id into v_id;
  select * into v_row from public.cards where id = v_id;
  if v_row.dmin <> 18 or v_row.dmax <> 22 or v_row.attack <> 20 then
    raise exception '0110 self-test 4 FAILED: power 20 -> got dmin % dmax % attack %',
      v_row.dmin, v_row.dmax, v_row.attack;
  end if;
  delete from public.cards where id = v_id;
  raise notice '0110 self-test 4 passed: an ordinary positive power is unaffected.';
end $$;
