-- 0112: accent stops being an admin-typed hex code and becomes derived.
--
-- Jared: "whats the accent thing in cards and structures? delete it, it
-- doesnt make any sense" -- then, once shown what it actually draws (the
-- big-card popup's tint, the Duel fight-scene backdrop behind each
-- fighter, the admin/roster colour swatches): "But the color should be
-- the class of the card. And for structures, let's use black."
--
-- So the FEATURE stays exactly as it was (every client read of `.accent`
-- -- BigCard.tsx, Duel.tsx, cine.ts, the admin swatches, roster tiles --
-- is untouched by this migration) -- what changes is where the value
-- comes from. A card's accent is no longer whatever hex an admin typed;
-- it is always its role's own established colour, the same five values
-- already painted all over styles.css for role-knight/-rogue/-mage/
-- -flying/-royal (.movearrow, .unit, .bigcard, .admin-swatch, .rtile --
-- see cn_role_color below for the exact hex-for-hex match). A structure's
-- accent is always black. Both are now enforced INSIDE the trigger, so
-- there is no longer any wrong value to type -- which is also why the
-- admin form's Accent field is being deleted client-side in the same
-- change that ships this (AdminCards.tsx/AdminStructures.tsx).
create or replace function public.cn_role_color(p_role text)
returns text
language sql
immutable
as $$
  select case p_role
    when 'royal'  then '#f2994a'
    when 'rogue'  then '#27ae60'
    when 'knight' then '#eb5757'
    when 'mage'   then '#9b51e0'
    when 'flying' then '#2f80ed'
    else '#eb5757'
  end
$$;

create or replace function public.cn_check_card()
returns trigger
language plpgsql
set search_path = 'public'
as $$
begin
  new.slug := nullif(lower(btrim(coalesce(new.slug, ''))), '');
  new.name := btrim(coalesce(new.name, ''));
  new.role := lower(btrim(coalesce(new.role, '')));
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

  -- 0112: accent is no longer admin-typed -- it always follows the class.
  new.accent := cn_role_color(new.role);

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

  -- ---- and one damage number, with the dice around it (0031, 0110) --------
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

create or replace function public.cn_touch_structures()
returns trigger
language plpgsql
set search_path = 'public'
as $$
begin
  -- 0112: a structure's accent is always black -- no longer admin-typed.
  new.accent := '#000000';
  new.updated_at := now();
  return new;
end
$$;

drop trigger if exists structures_touch on public.structures;
create trigger structures_touch
  before insert or update on public.structures
  for each row execute function cn_touch_structures();

do $$
declare v_src text;
begin
  select prosrc into v_src from pg_proc where proname = 'cn_role_color';
  if v_src is null then
    raise exception '0112 self-test FAILED: cn_role_color does not exist after migration';
  end if;
end $$;

-- Self-test 1: cn_role_color matches the exact five hex values already
-- painted throughout styles.css for role-knight/-rogue/-mage/-flying/-royal.
do $$
begin
  if cn_role_color('royal')  <> '#f2994a' then raise exception '0112 self-test 1 FAILED: royal'; end if;
  if cn_role_color('rogue')  <> '#27ae60' then raise exception '0112 self-test 1 FAILED: rogue'; end if;
  if cn_role_color('knight') <> '#eb5757' then raise exception '0112 self-test 1 FAILED: knight'; end if;
  if cn_role_color('mage')   <> '#9b51e0' then raise exception '0112 self-test 1 FAILED: mage'; end if;
  if cn_role_color('flying') <> '#2f80ed' then raise exception '0112 self-test 1 FAILED: flying'; end if;
  raise notice '0112 self-test 1 passed: cn_role_color matches styles.css for all five classes.';
end $$;

-- Self-test 2: a card's accent always follows its role, regardless of what
-- was submitted -- on insert, and on a role-changing update.
do $$
declare v_id uuid; v_row cards%rowtype;
begin
  insert into public.cards (slug, name, role, accent, power, is_active)
    values ('zz-test-accent-card', 'ZZ Test Accent', 'mage', '#123456', 10, false)
    returning id into v_id;
  select * into v_row from public.cards where id = v_id;
  if v_row.accent <> '#9b51e0' then
    raise exception '0112 self-test 2a FAILED: mage card got accent %, expected #9b51e0', v_row.accent;
  end if;

  update public.cards set role = 'flying', accent = '#654321' where id = v_id;
  select * into v_row from public.cards where id = v_id;
  if v_row.accent <> '#2f80ed' then
    raise exception '0112 self-test 2b FAILED: after role -> flying, got accent %, expected #2f80ed', v_row.accent;
  end if;

  delete from public.cards where id = v_id;
  raise notice '0112 self-test 2 passed: a card''s accent always follows its role, on insert and update.';
end $$;

-- Self-test 3: a structure's accent is always #000000, on insert and on an
-- update attempt to change it.
do $$
declare v_id uuid; v_accent text;
begin
  insert into public.structures (slug, name, accent)
    values ('zz-test-accent-struct', 'ZZ Test Accent Struct', '#ffffff')
    returning id, accent into v_id, v_accent;
  if v_accent <> '#000000' then
    raise exception '0112 self-test 3a FAILED: structure got accent %, expected #000000', v_accent;
  end if;

  update public.structures set accent = '#ffffff' where id = v_id;
  select accent into v_accent from public.structures where id = v_id;
  if v_accent <> '#000000' then
    raise exception '0112 self-test 3b FAILED: after update attempt, got accent %, expected #000000', v_accent;
  end if;

  delete from public.structures where id = v_id;
  raise notice '0112 self-test 3 passed: a structure''s accent is always #000000, on insert and update.';
end $$;
