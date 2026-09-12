-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE, so no "Potential issue detected" dialog.
--  Run 0033 first, AND DEPLOY THE CLIENT WITH THIS ONE -- it adds two more
--  swing kinds for the cinematic to narrate. The last statement prints a row
--  of checks; every column must say true.
-- ===========================================================================
--  0034 - PHASE F2: BURN, POISON AND STUN, AND THE LAST NINE CARDS
--
--  The machinery, and everything that was waiting on it. After this migration
--  ALL TWENTY UNITS OF THE ROSTER SPEC ARE PLAYABLE, and the game finally is
--  the one section 6 describes.
--
--  THREE EFFECTS, ONE OBJECT. `burned` was a loose boolean on the unit, which
--  is fine for one effect and a mess for three. It becomes
--  `effects: {"burn": false, "poison": false, "stun": 0}`, so the fourth is a
--  key rather than a migration. Nothing is lost in the change: after 0033
--  nothing in the game applies a burn at all, so there is no match in flight
--  carrying one -- which makes this the last cheap moment to change the shape.
--
--    BURN    15% of MAX hit points whenever the unit swings or uses an
--            ability. Not its passive: a burning unit that stands still and
--            counters is still swinging, but Wuzu regenerating is not.
--            (The old rule was a flat 5, from before there was a spec.)
--    POISON  10% of max at the start of the unit's own side's turn.
--    STUN    the unit's go, taken away. It cannot strike and cannot use an
--            ability -- which are the same thing since 0033 -- and it can
--            still walk, because a cyclone knocks the sword out of your hand
--            rather than your feet out from under you.
--
--  PER CENT OF MAXIMUM, not of what is left, which Jared settled: a burn that
--  scaled with current health could never kill anybody.
--
--  NOTHING CURES. Also Jared's, and now it matters: an effect is permanent
--  until the unit dies. King Stelaris is the only answer to one, and he
--  halves it rather than lifting it.
--
--  THE NINE THAT WERE ONLY WORDS
--
--    Queen Miah      the team deals 20% more to Mages         (built in F1)
--    King Stelaris   the team takes 50% less burn and poison  (built in F1)
--    Dorme           Quick Dagger -- answers before the blow lands
--    Ashvar          Fireball -- two tiles in a line, 15 and alight
--    Velmor          Cursed Blade -- 10 and poisoned
--    Sarrave         poisons every adjacent tile at the start of its turn
--    Thalgrim        +25 against a poisoned target
--    Nyxara          Cursed Body -- heals for all the damage it deals
--    Zephyra         Cyclone -- stuns what it hits
--
--  AND A SEVENTH LEFTOVER, found on the way. `parries` -- the flag whose whole
--  meaning is "this unit's answer lands BEFORE the blow it is answering" -- has
--  been on LIUM since 0013. That is Quick Dagger, and the spec gives Quick
--  Dagger to Dorme. Lium's card says "Always Ready: slightly increased parry
--  and crit rates, parries all parries" and says nothing about answering
--  first. So the flag moves to the card it was always describing, and Lium
--  keeps the two things it does advertise. Six leftovers died in 0033 and this
--  is the last of them.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. what a card can carry
-- ---------------------------------------------------------------------------
alter table public.cards add column if not exists poisons_adjacent boolean not null default false;
alter table public.cards add column if not exists stuns            boolean not null default false;
alter table public.cards add column if not exists vs_poisoned      int not null default 0;
alter table public.cards add column if not exists lifesteal_pct    int not null default 0;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'cards_vs_poisoned_check') then
    alter table public.cards add constraint cards_vs_poisoned_check
      check (vs_poisoned between 0 and 200);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'cards_lifesteal_check') then
    alter table public.cards add constraint cards_lifesteal_check
      check (lifesteal_pct between 0 and 200);
  end if;
end $$;

alter table public.cards drop constraint if exists cards_ability_kind_check;
alter table public.cards add constraint cards_ability_kind_check
  check (ability_kind is null
         or ability_kind in ('aoe_adjacent', 'heal_any', 'mist', 'poison_hit', 'line_burn'));

-- ---------------------------------------------------------------------------
-- 2. the three effects
--
-- Read and written through functions rather than by hand at eleven call sites,
-- because `effects->>'burn'` spelled slightly wrong is a rule that silently
-- stops applying -- which is exactly how `burned` came to be checked in four
-- places and set in two.
-- ---------------------------------------------------------------------------
/** What a unit carries before anything has happened to it. One literal. */
create or replace function public.cn_no_effects()
returns jsonb language sql immutable as $$
  select '{"burn": false, "poison": false, "stun": 0}'::jsonb
$$;

create or replace function public.cn_has(p_unit jsonb, p_what text)
returns boolean language sql immutable as $$
  select coalesce((p_unit->'effects'->>p_what)::boolean, false)
$$;

create or replace function public.cn_stunned(p_unit jsonb)
returns boolean language sql immutable as $$
  select coalesce((p_unit->'effects'->>'stun')::int, 0) > 0
$$;

/** Put an effect on a unit, creating the object if the unit predates 0034. */
create or replace function public.cn_afflict(p_unit jsonb, p_what text, p_val jsonb)
returns jsonb language plpgsql immutable as $$
begin
  if p_unit->'effects' is null then
    -- jsonb_set's create_missing only creates the LAST step of a path, so a
    -- unit with no `effects` at all needs the object made first. 0033 lost an
    -- afternoon to exactly this with the mist.
    p_unit := jsonb_set(p_unit, '{effects}', cn_no_effects(), true);
  end if;
  return jsonb_set(p_unit, array['effects', p_what], p_val, true);
end $$;

/**
 * What an effect costs this unit, this tick.
 *
 * A percentage of MAXIMUM hit points, not of what is left: an effect that
 * scaled with current health would asymptote and never finish anybody. Then
 * King Stelaris takes his half off -- the only answer in the game to a burn,
 * and he does not lift it, he makes it hurt less.
 */
create or replace function public.cn_effect_dmg(p_state jsonb, p_unit jsonb, p_pct int)
returns int language plpgsql stable as $$
declare v_raw int; v jsonb; v_resist numeric := 0;
begin
  v_raw := greatest(1, round((p_unit->>'maxHp')::int * p_pct / 100.0)::int);
  v := cn_aura(p_state, p_unit->>'owner', 'resist_effects');
  if v is not null then
    v_resist := coalesce((v->>'auraPct')::numeric, 0) / 100;
  end if;
  return greatest(0, round(v_raw * (1 - v_resist))::int);
end $$;

create or replace function public.cn_burn_pct()   returns int language sql immutable as $$ select 15 $$;
create or replace function public.cn_poison_pct() returns int language sql immutable as $$ select 10 $$;

revoke execute on function public.cn_no_effects()                   from public, anon, authenticated;
revoke execute on function public.cn_has(jsonb, text)               from public, anon, authenticated;
revoke execute on function public.cn_stunned(jsonb)                 from public, anon, authenticated;
revoke execute on function public.cn_afflict(jsonb, text, jsonb)    from public, anon, authenticated;
revoke execute on function public.cn_effect_dmg(jsonb, jsonb, int)  from public, anon, authenticated;
revoke execute on function public.cn_burn_pct()                     from public, anon, authenticated;
revoke execute on function public.cn_poison_pct()                   from public, anon, authenticated;
-- -------------------------------------------------------------------------
-- 3. the snapshot carries the effects and the four new passives
-- -------------------------------------------------------------------------
create or replace function public.cn_army(p_state jsonb, p_side text, p_deck text[])
returns jsonb
language plpgsql as $$
declare
  v_w int := (p_state->'board'->>'w')::int;
  v_h int := (p_state->'board'->>'h')::int;
  v_taken text[] := '{}'; e jsonb; c public.cards;
  v_xs int[] := '{}'::int[]; v_ys int[] := '{}'::int[];
  i int; vx int; vy int; v_idx int := 0;
  v_units jsonb := '[]'::jsonb; v_done boolean;
begin
  for e in select * from jsonb_array_elements(coalesce(p_state->'obstacles', '[]'::jsonb)) loop
    v_taken := v_taken || ((e->>'x') || ',' || (e->>'y'));
  end loop;

  -- columns, odd ones first, so five units on a six-wide board do not end
  -- up shoulder to shoulder along the back rank
  for i in 0 .. (v_w - 1) / 2 loop
    if 2 * i + 1 < v_w then v_xs := v_xs || (2 * i + 1); end if;
  end loop;
  for i in 0 .. (v_w - 1) / 2 loop
    if 2 * i < v_w then v_xs := v_xs || (2 * i); end if;
  end loop;

  -- rows, back rank first. The host's home row is 0, the guest's is h-1,
  -- so the two armies start facing each other down the long axis.
  if p_side = 'host'
    then for i in 0 .. (v_h / 2 - 1)            loop v_ys := v_ys || i; end loop;
    else for i in reverse (v_h - 1) .. (v_h / 2) loop v_ys := v_ys || i; end loop;
  end if;

  for i in 1 .. deck_size() loop
    select * into c from public.cards where slug = p_deck[i];
    if c.id is null then raise exception 'unknown card %', p_deck[i]; end if;

    v_done := false;
    foreach vy in array v_ys loop
      foreach vx in array v_xs loop
        if not ((vx || ',' || vy) = any(v_taken)) then
          v_taken := v_taken || (vx || ',' || vy);
          v_done := true;
          exit;
        end if;
      end loop;
      exit when v_done;
    end loop;
    if not v_done then raise exception 'nowhere to deploy'; end if;

    v_idx := v_idx + 1;
    v_units := v_units || jsonb_build_object(
      'id', substr(p_side, 1, 1) || v_idx, 'owner', p_side,
      'cardId', c.id, 'slug', c.slug, 'name', c.name, 'role', c.role,
      'hp', c.hp, 'maxHp', c.hp, 'mov', c.mov,
      'rmin', c.rmin, 'rmax', c.rmax, 'crmin', c.crmin, 'crmax', c.crmax,
      'dmin', c.dmin, 'dmax', c.dmax, 'pow', c.power,
      'parryPct', c.parry_pct, 'critPct', c.crit_pct, 'parryAll', c.parry_all,
      'royal', c.royal,
      -- What this unit can DO, carried on the snapshot with everything else:
      -- a card retuned in the editor must not change a match in progress.
      'abilityKind', c.ability_kind, 'abilityN', c.ability_n,
      'abilityTurns', c.ability_turns,
      'slippery', c.slippery, 'twicePct', c.twice_pct, 'regenPct', c.regen_pct,
      'poisonsAdj', c.poisons_adjacent, 'stuns', c.stuns,
      'vsPoisoned', c.vs_poisoned, 'lifestealPct', c.lifesteal_pct,
      -- The aura travels with the unit, like every other stat, because a
      -- card retuned mid-match must not change a match already running.
      'auraKind', c.aura_kind, 'auraClass', c.aura_class, 'auraPct', c.aura_pct,
      'burns', c.burns, 'heals', c.heals,
      -- One object for three effects, so a fourth is a key rather than a
      -- migration. `burned` is gone: nothing has applied one since 0033,
      -- which made this the last cheap moment to change the shape.
      'effects', cn_no_effects(),
      'flies', c.flies, 'sneaks', c.sneaks, 'cures', c.cures, 'tramples', c.tramples,
      'parries', c.parries, 'blooms', c.blooms,
      'accent', c.accent, 'art', c.art_url, 'ability', c.ability,
      'x', vx, 'y', vy, 'moved', false, 'acted', false);
  end loop;
  return v_units;
end
$$;

create or replace function public.cn_gen_trees(p_w integer, p_h integer)
returns jsonb
language plpgsql as $$
declare
  v_try int; v_band int; v_lo int; v_hi int; v_n int;
  v_cand int[]; v_pick int[] := '{}'::int[]; v_ok boolean;
  i int; j int; v_x int; v_y int; v_px int; v_py int;
  v_out jsonb := '[]'::jsonb; v_k int := 0;
begin
  for v_try in 1..80 loop
    v_pick := '{}'::int[];
    for v_band in 0..1 loop
      if v_band = 0 then v_lo := 0; v_hi := p_h / 2 - 1;
                    else v_lo := p_h / 2; v_hi := p_h - 1; end if;

      -- Nothing in the row nearest either player's edge. That row is where
      -- the army stands up, and a tree in it costs somebody a starting
      -- square. The rule swallows the old no-corners one -- every corner
      -- sits in a home row -- so the corner clause below is now redundant
      -- and kept only so the intent survives a change to the board shape.
      select array_agg(t) into v_cand from (
        select gy.y * p_w + gx.x as t
          from generate_series(0, p_w - 1) as gx(x),
               generate_series(v_lo, v_hi) as gy(y)
         where gy.y <> 0 and gy.y <> p_h - 1
           and not ((gx.x = 0 or gx.x = p_w - 1) and (gy.y = 0 or gy.y = p_h - 1))
         order by random()) s;

      v_n := 0;
      foreach i in array v_cand loop
        exit when v_n = 4;
        v_x := i % p_w; v_y := i / p_w;
        v_ok := true;
        foreach j in array v_pick loop
          v_px := j % p_w; v_py := j / p_w;
          if cn_cheb(v_x, v_y, v_px, v_py) < 2 then v_ok := false; exit; end if;
        end loop;
        if v_ok then v_pick := v_pick || i; v_n := v_n + 1; end if;
      end loop;
      exit when v_n < 4;
    end loop;
    exit when coalesce(array_length(v_pick, 1), 0) = 8;
  end loop;

  -- Eighty shuffled goes is plenty, but a greedy pass can in principle paint
  -- itself into a corner. If every one failed, use a layout known to satisfy
  -- the rules rather than opening a room with no trees in it: one tree per
  -- half-column, staggered down the rows.
  if coalesce(array_length(v_pick, 1), 0) <> 8 then
    v_pick := array[ 1 * p_w + 0, 1 * p_w + 2, 1 * p_w + 4,
                     (p_h / 2 - 1) * p_w + 1,
                     (p_h - 2) * p_w + 1, (p_h - 2) * p_w + 3,
                     (p_h - 2) * p_w + 5, (p_h / 2) * p_w + 4 ];
  end if;

  foreach i in array v_pick loop
    v_k := v_k + 1;
    v_out := v_out || jsonb_build_object(
      'id', 't' || v_k, 'x', i % p_w, 'y', i / p_w, 'hp', 30, 'maxHp', 30);
  end loop;
  return v_out;
end
$$;

-- ---------------------------------------------------------------------------
-- 4. a taller board, and the two counters a turn is now kept in
--
-- 'acts' is how many activations the side to move has spent, and 'active' is
-- the unit part-way through one (it has moved but not yet struck). A match
-- already in flight when this lands has neither, so everything below reads
-- them through coalesce and treats a missing 'active' as nobody.
-- ---------------------------------------------------------------------------
create or replace function public.cn_fresh_map()
returns jsonb language plpgsql as $$
declare v_w int := 6; v_h int := 8;
begin
  return jsonb_build_object(
    'v', 3,
    'board', jsonb_build_object('w', v_w, 'h', v_h),
    'phase', 'deploy',
    'ready', jsonb_build_object('host', false, 'guest', false),
    'obstacles', cn_gen_trees(v_w, v_h),
    'units', '[]'::jsonb,
    'turn', 'host',
    'turnNumber', 0,
    'acts', 0,
    'active', null,
    'idle', jsonb_build_object('host', 0, 'guest', 0),
    'away', null,
    'log', '[]'::jsonb,
    'winner', null);
end $$;

-- -------------------------------------------------------------------------
-- 4. the exchange: a stun stops it, a poison sharpens it, a cyclone
--    follows it, a cursed body drinks from it, and a fire costs more
-- -------------------------------------------------------------------------
create or replace function public.cn_attack(p_match uuid, p_side text, p_unit text, p_target text)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare
  m public.matches; v_other text; v_st jsonb; u jsonb; e jsonb;
  v_atk jsonb; v_tgt jsonb; v_tree jsonb;
  v_out jsonb := '[]'::jsonb; v_rocks jsonb := '[]'::jsonb;
  v_dist int; v_dmg int := 0; v_heal int := 0;
  v_tgt_hp int; v_atk_hp int; v_counter int := 0; v_riposte int := 0;
  v_burn_atk int := 0; v_burn_tgt int := 0; v_new_burn boolean := false;
  v_cured boolean := false;
  v_answers boolean := false; v_parry boolean := false;
  v_reaches_back boolean := false; v_tgt_reaches boolean := false;
  v_hit_crit boolean := false;
  v_crit boolean := false; v_crit_counter boolean := false;
  v_chain int := 0; v_parries int := 0;
  v_swing_is_atk boolean := true; v_is_counter boolean := false;
  v_strk jsonb; v_recv jsonb; v_hit int; v_parried boolean;
  v_notes text[] := '{}';
  v_swings jsonb := '[]'::jsonb;
  v_bloom jsonb := '[]'::jsonb; v_d2 int; v_got int; v_heal_roll int := 0;
  v_killed_tgt boolean := false; v_killed_atk boolean := false;
  v_ally boolean := false; v_foes int := 0; v_mine int := 0; v_win text;
  v_crown text; v_note text;
  -- F3: a blow the mist ate, and Himanta's second swing.
  v_missed boolean := false; v_hit2 int; v_crit2 boolean;
  -- F2: what a burn costs the one swinging, and what a blow leaves behind.
  v_cost int; v_steal int;
begin
  select * into m from public.matches where id = p_match for update;
  v_other := case when p_side = 'host' then 'guest' else 'host' end;
  v_st := m.state;

  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit   then v_atk := u; end if;
    if u->>'id' = p_target then v_tgt := u; end if;
  end loop;
  for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
    if e->>'id' = p_target then v_tree := e; end if;
  end loop;

  if v_atk is null then raise exception 'no such unit'; end if;
  if v_tgt is null and v_tree is null then raise exception 'no such target'; end if;
  if v_atk->>'owner' <> p_side then raise exception 'that is not your unit'; end if;
  if (v_atk->>'acted')::boolean then raise exception 'that unit already acted'; end if;
  -- A cyclone knocks the sword out of your hand, not your feet out from
  -- under you: a stunned unit may still walk, and nothing here stops it.
  if cn_stunned(v_atk) then raise exception 'that unit is stunned'; end if;

  -- Striking spends an action whether or not this unit moved first. If it
  -- moved, it is already the active unit and this costs nothing further.
  v_st := cn_begin_act(v_st, p_side, p_unit);

  if v_tree is not null then
    v_dist := cn_cheb((v_atk->>'x')::int, (v_atk->>'y')::int,
                      (v_tree->>'x')::int, (v_tree->>'y')::int);
  else
    v_ally := (v_tgt->>'owner' = p_side);
    if v_ally and not (v_atk->>'heals')::boolean then raise exception 'no friendly fire'; end if;
    v_dist := cn_cheb((v_atk->>'x')::int, (v_atk->>'y')::int,
                      (v_tgt->>'x')::int, (v_tgt->>'y')::int);
  end if;

  if v_dist < (v_atk->>'rmin')::int then raise exception 'too close for that unit'; end if;
  if v_dist > (v_atk->>'rmax')::int then raise exception 'out of range'; end if;
  if not cn_los_clear(v_st, (v_atk->>'x')::int, (v_atk->>'y')::int,
                      coalesce((v_tgt->>'x')::int, (v_tree->>'x')::int),
                      coalesce((v_tgt->>'y')::int, (v_tree->>'y')::int)) then
    raise exception 'a tree is in the way';
  end if;

  v_atk_hp := (v_atk->>'hp')::int;

  if v_ally then
    -- Mending is not an exchange: no crit, no parry, no answer.
    v_heal_roll := cn_roll((v_atk->>'dmin')::int, (v_atk->>'dmax')::int);
    v_heal := v_heal_roll;
    v_tgt_hp := least((v_tgt->>'maxHp')::int, (v_tgt->>'hp')::int + v_heal);
    v_heal := v_tgt_hp - (v_tgt->>'hp')::int;
    v_cured := coalesce((v_atk->>'cures')::boolean, false)
               and cn_has(v_tgt, 'burn');
    if v_cured then v_tgt := cn_afflict(v_tgt, 'burn', 'false'::jsonb); end if;
    v_note := (v_atk->>'name') || ' mends ' || (v_tgt->>'name') || ' for ' || v_heal || '.';
    v_swings := v_swings || jsonb_build_object(
      'k', 'heal', 'by', p_unit, 'at', p_target, 'dmg', v_heal,
      'crit', false, 'counter', false, 'first', false, 'def', false,
      'why', 'mend');

    -- A flower does not choose who it grows for. One roll, spent on everyone
    -- standing in reach, so the answer to Sinie is to keep your line apart --
    -- which is the opposite of what every other unit wants of you.
    if coalesce((v_atk->>'blooms')::boolean, false) then
      for u in select * from jsonb_array_elements(v_st->'units') loop
        continue when u->>'id' = p_unit or u->>'id' = p_target;
        continue when u->>'owner' <> p_side;
        continue when (u->>'hp')::int >= (u->>'maxHp')::int;
        v_d2 := cn_cheb((v_atk->>'x')::int, (v_atk->>'y')::int,
                        (u->>'x')::int, (u->>'y')::int);
        continue when v_d2 < (v_atk->>'rmin')::int or v_d2 > (v_atk->>'rmax')::int;
        continue when not cn_los_clear(v_st, (v_atk->>'x')::int, (v_atk->>'y')::int,
                                       (u->>'x')::int, (u->>'y')::int);
        v_bloom := v_bloom || jsonb_build_array(u->>'id');
      end loop;
    end if;

  elsif v_tree is not null then
    -- A tree does not parry and does not answer, but a crit still fells it.
    v_crit := cn_chance((v_atk->>'critPct')::int, 'crit');
    v_dmg := cn_damage(cn_roll((v_atk->>'dmin')::int, (v_atk->>'dmax')::int), v_crit, false);
    v_tgt_hp := (v_tree->>'hp')::int - v_dmg;
    v_killed_tgt := v_tgt_hp <= 0;
    v_swings := v_swings || jsonb_build_object(
      'k', 'hit', 'by', p_unit, 'at', p_target, 'dmg', v_dmg,
      'crit', v_crit, 'counter', false, 'first', false, 'def', false,
      'why', 'tree');
    if v_killed_tgt then
      v_swings := v_swings || jsonb_build_object('k', 'down', 'by', p_target, 'at', p_target);
    end if;
    if cn_has(v_atk, 'burn') then
      v_burn_atk := cn_effect_dmg(v_st, v_atk, cn_burn_pct());
      v_atk_hp := v_atk_hp - v_burn_atk;
      v_swings := v_swings || jsonb_build_object(
        'k', 'burn', 'by', p_unit, 'at', p_unit, 'dmg', v_burn_atk);
    end if;
    v_killed_atk := v_atk_hp <= 0;
    v_note := (v_atk->>'name') || ' strikes a tree for ' || v_dmg
              || case when v_killed_tgt then ' -- it falls.' else '.' end;

  else
    v_tgt_hp := (v_tgt->>'hp')::int;

    -- A thief that trades blows is not a thief.
    v_answers := not coalesce((v_atk->>'sneaks')::boolean, false)
                 and v_dist >= (v_tgt->>'crmin')::int
                 and v_dist <= (v_tgt->>'crmax')::int;
    -- v_answers is the ORDINARY counter, and Quick Dagger spends it. Whether
    -- each side can physically reach the other is a separate, permanent fact,
    -- and it is the one a parry asks: a parrier answers only if the blow it
    -- caught came from somewhere it can reach.
    v_tgt_reaches  := v_answers;
    v_reaches_back := v_dist >= (v_atk->>'crmin')::int
                  and v_dist <= (v_atk->>'crmax')::int;

    -- Quick Dagger. The answer lands before the blow it is answering, and it
    -- is a passive, so nothing catches it. It spends the ordinary counter --
    -- you do not get to answer twice for one attack.
    if v_answers and coalesce((v_tgt->>'parries')::boolean, false) then
      v_crit_counter := not coalesce((v_atk->>'slippery')::boolean, false)
                        and cn_chance((v_tgt->>'critPct')::int, 'crit');
      v_counter := cn_damage(cn_roll((v_tgt->>'dmin')::int, (v_tgt->>'dmax')::int),
                             v_crit_counter, true,
                             cn_aura_bonus(v_st, v_tgt, v_atk),
                             cn_aura_resist(v_st, v_tgt, v_atk),
                             coalesce((v_atk->>'defending')::boolean, false));
      v_atk_hp := v_atk_hp - v_counter;
      if cn_has(v_tgt, 'burn') then
        v_burn_tgt := cn_effect_dmg(v_st, v_tgt, cn_burn_pct());
        v_tgt_hp := v_tgt_hp - v_burn_tgt;
      end if;
      v_killed_atk := v_atk_hp <= 0;
      v_killed_tgt := v_tgt_hp <= 0;
      v_parry   := true;          -- the clients draw this the same way
      v_answers := false;
      v_notes := v_notes || ((v_tgt->>'name') || ' answers first for ' || v_counter
                 || case when v_crit_counter then ' -- a critical hit.' else '.' end);
      -- 'first' is what tells the cinematic to play this BEFORE the lunge it
      -- is answering, which is the whole of Quick Dagger.
      v_swings := v_swings || jsonb_build_object(
        'k', 'hit', 'by', p_target, 'at', p_unit, 'dmg', v_counter,
        'crit', v_crit_counter, 'counter', true, 'first', true,
        'def', coalesce((v_atk->>'defending')::boolean, false),
        'why', 'quick');
    end if;

    -- The chain.
    while not v_killed_atk and not v_killed_tgt and v_chain < cn_parry_cap() loop
      v_chain := v_chain + 1;
      if v_swing_is_atk
        then v_strk := v_atk; v_recv := v_tgt;
        else v_strk := v_tgt; v_recv := v_atk;
      end if;

      -- Lium catches any answer-to-a-parry aimed at him. Everyone else rolls.
      -- Slippery. Nothing catches a blow of Himanta's -- not a roll, and not
      -- Lium, whose whole passive is catching answers. Checked on the
      -- SWINGER, because being hard to parry is a property of the one
      -- swinging and not of the one trying.
      v_parried := not coalesce((v_strk->>'slippery')::boolean, false)
                   and ((v_is_counter and coalesce((v_recv->>'parryAll')::boolean, false))
                        or cn_chance((v_recv->>'parryPct')::int, 'parry'));

      if v_parried then
        v_parries := v_parries + 1;
        if v_chain = 1 then v_parry := true; end if;
        v_notes := v_notes || ((v_recv->>'name') || ' parries '
                   || (v_strk->>'name') || '.');
        -- 'why' says which rule caught it. Lium catching an answer is not the
        -- same event as a 5% roll coming up, and a caption that calls both of
        -- them "parries" is not narrating, it is labelling.
        v_swings := v_swings || jsonb_build_object(
          'k', 'parry', 'by', v_recv->>'id', 'at', v_strk->>'id',
          'why', case when v_is_counter
                       and coalesce((v_recv->>'parryAll')::boolean, false)
                      then 'all' else 'roll' end);
        -- A parry answers only if the parrier can reach what it caught.
        exit when not case when v_swing_is_atk then v_tgt_reaches
                                               else v_reaches_back end;
        v_swing_is_atk := not v_swing_is_atk;
        v_is_counter := true;
        continue;
      end if;

      -- The blow lands.
      -- ...and nothing crits ONE. Checked on the receiver, for the mirror
      -- reason: it is a property of the one being hit.
      v_hit_crit := not coalesce((v_recv->>'slippery')::boolean, false)
                    and cn_chance((v_strk->>'critPct')::int, 'crit');
      v_hit := cn_damage(cn_roll((v_strk->>'dmin')::int, (v_strk->>'dmax')::int),
                         v_hit_crit, v_is_counter,
                         cn_aura_bonus(v_st, v_strk, v_recv),
                         cn_aura_resist(v_st, v_strk, v_recv),
                         coalesce((v_recv->>'defending')::boolean, false));
      -- THE MIST. Eva's, and it is the receiver's side that has it: a Rogue
      -- standing in it has a chance to be somewhere else when the blow
      -- arrives. Rolled per blow rather than per exchange, so a chain of
      -- four swings is four chances -- which is what makes two turns of it
      -- worth an activation.
      -- THALGRIM. Flat, and added after every multiplier: "an extra 25
      -- damage" is a sentence about the number that lands, not about the
      -- roll that started it.
      if cn_has(v_recv, 'poison') then
        v_hit := v_hit + coalesce((v_strk->>'vsPoisoned')::int, 0);
      end if;
      v_missed := cn_mist_dodge(v_st, v_recv);
      if v_missed then v_hit := 0; v_hit_crit := false; end if;
      if v_swing_is_atk then
        v_tgt_hp := v_tgt_hp - v_hit;
        if v_is_counter then v_riposte := v_riposte + v_hit;
        else v_dmg := v_hit; v_crit := v_hit_crit; end if;
      else
        v_atk_hp := v_atk_hp - v_hit;
        v_counter := v_counter + v_hit;
        v_crit_counter := v_crit_counter or v_hit_crit;
      end if;
      v_swings := v_swings || jsonb_build_object(
        'k', 'hit', 'by', v_strk->>'id', 'at', v_recv->>'id', 'dmg', v_hit,
        'crit', v_hit_crit, 'counter', v_is_counter, 'first', false,
        'def', coalesce((v_recv->>'defending')::boolean, false),
        'why', case when v_missed then 'mist'
                    when v_is_counter then 'counter' else 'strike' end);

      -- STRIKE TWICE. Not only on the attack: Jared's rule is "a second hit
      -- when Himanta attacks, counters or parries", and all three are the
      -- same thing here -- a swing in the chain -- which is the whole reason
      -- the chain was made uniform in 0020. A missed blow does not double:
      -- there is nothing to do twice.
      if not v_missed and coalesce((v_strk->>'twicePct')::int, 0) > 0
         and cn_chance((v_strk->>'twicePct')::int, 'twice') then
        v_crit2 := not coalesce((v_recv->>'slippery')::boolean, false)
                   and cn_chance((v_strk->>'critPct')::int, 'crit');
        v_hit2 := cn_damage(cn_roll((v_strk->>'dmin')::int, (v_strk->>'dmax')::int),
                            v_crit2, v_is_counter,
                            cn_aura_bonus(v_st, v_strk, v_recv),
                            cn_aura_resist(v_st, v_strk, v_recv),
                            coalesce((v_recv->>'defending')::boolean, false));
        if cn_mist_dodge(v_st, v_recv) then v_hit2 := 0; v_crit2 := false; end if;
        if v_swing_is_atk then
          v_tgt_hp := v_tgt_hp - v_hit2;
          if v_is_counter then v_riposte := v_riposte + v_hit2;
          else v_dmg := v_dmg + v_hit2; end if;
        else
          v_atk_hp := v_atk_hp - v_hit2;
          v_counter := v_counter + v_hit2;
        end if;
        v_swings := v_swings || jsonb_build_object(
          'k', 'hit', 'by', v_strk->>'id', 'at', v_recv->>'id', 'dmg', v_hit2,
          'crit', v_crit2, 'counter', v_is_counter, 'first', false,
          'def', coalesce((v_recv->>'defending')::boolean, false),
          'why', 'twice');
        v_notes := v_notes || ((v_strk->>'name') || ' strikes again for ' || v_hit2 || '.');
      end if;
      if v_is_counter then
        v_notes := v_notes || ((v_strk->>'name') || ' answers for ' || v_hit
                   || case when v_hit_crit then ' -- a critical hit.' else '.' end);
      end if;

      -- ZEPHYRA. The cyclone lands with the blow, on anything it hit.
      if not v_missed and v_hit > 0
         and coalesce((v_strk->>'stuns')::boolean, false) then
        if v_swing_is_atk then v_tgt := cn_afflict(v_tgt, 'stun', '1'::jsonb);
                          else v_atk := cn_afflict(v_atk, 'stun', '1'::jsonb); end if;
        v_notes := v_notes || ((v_recv->>'name') || ' is caught in the cyclone.');
      end if;

      -- NYXARA. Heals for what it dealt, capped at its own maximum -- and
      -- for what LANDED rather than what was rolled, so a guard and a
      -- resistance take the healing down with the damage.
      v_steal := round(v_hit * coalesce((v_strk->>'lifestealPct')::int, 0) / 100.0)::int;
      if v_steal > 0 then
        if v_swing_is_atk
          then v_atk_hp := least((v_atk->>'maxHp')::int, v_atk_hp + v_steal);
          else v_tgt_hp := least((v_tgt->>'maxHp')::int, v_tgt_hp + v_steal);
        end if;
        v_swings := v_swings || jsonb_build_object(
          'k', 'heal', 'by', v_strk->>'id', 'at', v_strk->>'id', 'dmg', v_steal,
          'why', 'steal');
      end if;

      -- Swinging while alight costs you, whichever end of the exchange you
      -- are -- and since 0034 it costs 15% of your maximum rather than a
      -- flat 5, which is the spec's number and scales with the unit.
      if cn_has(v_strk, 'burn') then
        v_cost := cn_effect_dmg(v_st, v_strk, cn_burn_pct());
        if v_swing_is_atk
          then v_burn_atk := v_cost; v_atk_hp := v_atk_hp - v_cost;
          else v_burn_tgt := v_cost; v_tgt_hp := v_tgt_hp - v_cost;
        end if;
        v_swings := v_swings || jsonb_build_object(
          'k', 'burn', 'by', v_strk->>'id', 'at', v_strk->>'id', 'dmg', v_cost);
      end if;
      v_killed_atk := v_atk_hp <= 0;
      v_killed_tgt := v_tgt_hp <= 0;
      -- Recorded HERE rather than counted up at the end, because the order is
      -- the whole point of the list: a cinematic has to know whether somebody
      -- fell before or after the blow that follows.
      if v_killed_tgt then
        v_swings := v_swings || jsonb_build_object('k', 'down', 'by', p_target, 'at', p_target);
      end if;
      if v_killed_atk then
        v_swings := v_swings || jsonb_build_object('k', 'down', 'by', p_unit, 'at', p_unit);
      end if;
      exit when v_killed_atk or v_killed_tgt;

      -- A blow that lands draws the ordinary counter. A counter that lands
      -- ends it -- otherwise the two of them never stop.
      exit when v_is_counter;
      exit when not v_answers;
      v_swing_is_atk := false;
      v_is_counter := true;
    end loop;

    v_new_burn := (v_atk->>'burns')::boolean and not v_killed_tgt and v_dmg > 0;
    if v_new_burn then v_tgt := cn_afflict(v_tgt, 'burn', 'true'::jsonb); end if;

    if v_dmg = 0 then
      v_note := (v_atk->>'name') || ' lunges at ' || (v_tgt->>'name') || '.';
    else
      v_note := (v_atk->>'name') || ' hits ' || (v_tgt->>'name') || ' for ' || v_dmg
                || case when v_killed_tgt and v_burn_tgt = 0 then ' -- destroyed.' else '.' end;
    end if;
  end if;

  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then
      if not v_killed_atk then
        u := jsonb_set(u, '{acted}', 'true'::jsonb);
        u := jsonb_set(u, '{moved}', 'true'::jsonb);
        u := jsonb_set(u, '{spent}', 'true'::jsonb);
        u := jsonb_set(u, '{hp}', to_jsonb(v_atk_hp));
        -- The exchange afflicts the LOCAL copies -- a cyclone caught on the
        -- counter lands on v_atk, not on the row in the state -- so the whole
        -- effects object is carried back here. Setting one key at a time is
        -- how `burned` came to be written in two places and read in four.
        u := jsonb_set(u, '{effects}',
                       coalesce(v_atk->'effects', cn_no_effects()), true);
        v_out := v_out || u;
      end if;
    elsif v_tree is null and u->>'id' = p_target then
      if v_ally then
        u := jsonb_set(u, '{hp}', to_jsonb(v_tgt_hp));
        u := jsonb_set(u, '{effects}',
                       coalesce(v_tgt->'effects', cn_no_effects()), true);
        v_out := v_out || u;
      elsif not v_killed_tgt then
        u := jsonb_set(u, '{hp}', to_jsonb(v_tgt_hp));
        u := jsonb_set(u, '{effects}',
                       coalesce(v_tgt->'effects', cn_no_effects()), true);
        v_out := v_out || u;
      end if;
    elsif v_bloom @> jsonb_build_array(u->>'id') then
      v_got := least((u->>'maxHp')::int - (u->>'hp')::int, v_heal_roll);
      u := jsonb_set(u, '{hp}', to_jsonb((u->>'hp')::int + v_got));
      if coalesce((v_atk->>'cures')::boolean, false) then
        u := cn_afflict(u, 'burn', 'false'::jsonb);
      end if;
      v_out := v_out || u;
    else
      v_out := v_out || u;
    end if;
  end loop;

  for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
    if v_tree is not null and e->>'id' = p_target then
      if not v_killed_tgt then v_rocks := v_rocks || jsonb_set(e, '{hp}', to_jsonb(v_tgt_hp)); end if;
    else
      v_rocks := v_rocks || e;
    end if;
  end loop;

  v_st := jsonb_set(v_st, '{units}', v_out);
  v_st := jsonb_set(v_st, '{obstacles}', v_rocks);
  -- Set on the state rather than through cn_end_act: an attacker killed by
  -- the counter has already been dropped from v_out, so there is no row
  -- left to flag, and the activation still has to end.
  v_st := jsonb_set(v_st, '{active}', 'null'::jsonb);
  v_st := jsonb_set(v_st, '{fx}', jsonb_build_object(
    'seq', coalesce((v_st->'fx'->>'seq')::int, 0) + 1,
    'atk', p_unit, 'tgt', p_target,
    'dmg', v_dmg, 'heal', v_heal,
    'killedTgt', v_killed_tgt, 'counter', v_counter, 'killedAtk', v_killed_atk,
    'burnAtk', v_burn_atk, 'burnTgt', v_burn_tgt, 'newBurn', v_new_burn,
    'cured', v_cured, 'parry', v_parry, 'bloom', v_bloom,
    'crit', v_crit, 'critCounter', v_crit_counter,
    'parries', v_parries, 'chain', v_chain, 'riposte', v_riposte,
    'swings', v_swings,
    'tree', (v_tree is not null)));

  v_st := state_log(v_st, v_note);
  if jsonb_array_length(v_bloom) > 0 then
    v_st := state_log(v_st, 'The bloom spreads -- '
      || jsonb_array_length(v_bloom) || ' more mended.');
  end if;
  if v_cured then v_st := state_log(v_st, (v_tgt->>'name') || ' stops burning.'); end if;
  if v_new_burn then v_st := state_log(v_st, (v_tgt->>'name') || ' is burning.'); end if;
  foreach v_note in array v_notes loop
    v_st := state_log(v_st, v_note);
  end loop;
  if v_killed_atk and v_burn_atk = 0 and v_counter > 0 then
    v_st := state_log(v_st, (v_atk->>'name') || ' is destroyed.');
  end if;
  if v_burn_tgt > 0 then
    v_st := state_log(v_st, (v_tgt->>'name') || ' burns for ' || v_burn_tgt
      || case when v_killed_tgt then ' -- destroyed.' else '.' end);
  end if;
  if v_burn_atk > 0 then
    v_st := state_log(v_st, (v_atk->>'name') || ' burns for ' || v_burn_atk
      || case when v_killed_atk then ' -- destroyed.' else '.' end);
  end if;

  -- ---- who has won -------------------------------------------------------
  -- A crown that falls takes the kingdom with it. Checked before the count of
  -- bodies, because a king can die while four of his units are still standing
  -- and that is still over. The defender is checked first: the attack resolved,
  -- so if both crowns fell in the one exchange the one that was struck fell
  -- first.
  if v_tree is null and v_killed_tgt and coalesce((v_tgt->>'royal')::boolean, false) then
    v_crown := v_tgt->>'owner';
  elsif v_killed_atk and coalesce((v_atk->>'royal')::boolean, false) then
    v_crown := v_atk->>'owner';
  end if;

  for u in select * from jsonb_array_elements(v_out) loop
    if u->>'owner' = p_side then v_mine := v_mine + 1; else v_foes := v_foes + 1; end if;
  end loop;

  if v_crown is not null and not exists (
       select 1 from jsonb_array_elements(v_out) q
        where q->>'owner' = v_crown and (q->>'royal')::boolean) then
    v_win := case when v_crown = 'host' then 'guest' else 'host' end;
    v_st := state_log(v_st, 'The crown has fallen.');
  elsif v_foes = 0 then v_win := p_side;
  elsif v_mine = 0 then v_win := v_other;
  end if;

  if v_win is not null then
    if m.ranked then perform finish_match(m.id, v_win, 'defeat'); end if;
    v_st := jsonb_set(v_st, '{winner}', to_jsonb(v_win));
    v_st := state_log(v_st,
      case when v_win = 'host' then m.host_name else m.guest_name end || ' wins.');
    update public.matches
       set state = v_st, status = 'finished', winner = v_win,
           turn_deadline = null, updated_at = now()
     where id = m.id returning * into m;
  else
    update public.matches set state = v_st, updated_at = now()
     where id = m.id returning * into m;
  end if;
  return m;
end
$$;

-- -------------------------------------------------------------------------
-- 5. and two more abilities
-- -------------------------------------------------------------------------
create or replace function public.cn_ability(p_match uuid, p_side text, p_unit text, p_target text)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare
  m public.matches; v_st jsonb; u jsonb; e jsonb;
  v_me jsonb; v_tgt jsonb; v_kind text; v_n int;
  v_out jsonb := '[]'::jsonb; v_rocks jsonb := '[]'::jsonb;
  v_hits jsonb := '[]'::jsonb; v_swings jsonb := '[]'::jsonb;
  v_dist int; v_got int; v_hp int; v_felled boolean := false;
  v_dx int; v_dy int;
  v_note text; v_seq int;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'active' then raise exception 'match is not running'; end if;
  v_st := m.state;
  if v_st->>'turn' <> p_side then raise exception 'not your turn'; end if;

  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then v_me := u; end if;
    if p_target is not null and u->>'id' = p_target then v_tgt := u; end if;
  end loop;
  if v_me is null then raise exception 'no such unit'; end if;
  if v_me->>'owner' <> p_side then raise exception 'that is not your unit'; end if;
  if (v_me->>'acted')::boolean then raise exception 'that unit already acted'; end if;
  -- An ability substitutes the attack, so a stun takes both.
  if cn_stunned(v_me) then raise exception 'that unit is stunned'; end if;

  v_kind := v_me->>'abilityKind';
  if v_kind is null then raise exception 'that unit has no ability'; end if;
  v_n := coalesce((v_me->>'abilityN')::int, 0);

  -- Same budget as a strike, because it IS the strike: an ability substitutes
  -- the attack inside one activation.
  v_st := cn_begin_act(v_st, p_side, p_unit);
  v_seq := coalesce((v_st->'fx'->>'seq')::int, 0) + 1;

  -- ---- every tile around you ----------------------------------------------
  if v_kind = 'aoe_adjacent' then
    for u in select * from jsonb_array_elements(v_st->'units') loop
      if u->>'id' <> p_unit
         and cn_cheb((v_me->>'x')::int, (v_me->>'y')::int,
                     (u->>'x')::int, (u->>'y')::int) = 1 then
        -- Friend and foe alike. "All nearby tiles" is what the card says and
        -- what it means: standing beside your own Knight is a decision.
        v_hp := (u->>'hp')::int - v_n;
        u := jsonb_set(u, '{hp}', to_jsonb(v_hp));
        v_hits := v_hits || jsonb_build_object('id', u->>'id', 'dmg', v_n);
        v_swings := v_swings || jsonb_build_object(
          'k', 'hit', 'by', p_unit, 'at', u->>'id', 'dmg', v_n,
          'crit', false, 'counter', false, 'first', false, 'def', false,
          'why', 'ability');
      end if;
      if (u->>'hp')::int > 0 then v_out := v_out || u; end if;
    end loop;
    -- A tree beside it comes down too, which is the same sentence applied
    -- honestly rather than an exception carved out for scenery.
    for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
      if cn_cheb((v_me->>'x')::int, (v_me->>'y')::int,
                 (e->>'x')::int, (e->>'y')::int) = 1 then
        e := jsonb_set(e, '{hp}', to_jsonb((e->>'hp')::int - v_n));
        v_felled := v_felled or (e->>'hp')::int <= 0;
      end if;
      if (e->>'hp')::int > 0 then v_rocks := v_rocks || e; end if;
    end loop;
    v_st := jsonb_set(v_st, '{obstacles}', v_rocks);
    v_note := (v_me->>'name') || ' strikes every tile around them for ' || v_n || '.';

  -- ---- thirty hit points, to whoever you point at -------------------------
  elsif v_kind = 'heal_any' then
    if v_tgt is null then raise exception 'that ability needs a target'; end if;
    v_dist := cn_cheb((v_me->>'x')::int, (v_me->>'y')::int,
                      (v_tgt->>'x')::int, (v_tgt->>'y')::int);
    if v_dist > (v_me->>'rmax')::int then raise exception 'out of range'; end if;
    if not cn_los_clear(v_st, (v_me->>'x')::int, (v_me->>'y')::int,
                        (v_tgt->>'x')::int, (v_tgt->>'y')::int) then
      raise exception 'a tree is in the way';
    end if;
    for u in select * from jsonb_array_elements(v_st->'units') loop
      if u->>'id' = p_target then
        v_got := least((u->>'maxHp')::int - (u->>'hp')::int, v_n);
        u := jsonb_set(u, '{hp}', to_jsonb((u->>'hp')::int + v_got));
      end if;
      v_out := v_out || u;
    end loop;
    v_hits := jsonb_build_array(jsonb_build_object('id', p_target, 'heal', v_got));
    v_swings := jsonb_build_array(jsonb_build_object(
      'k', 'heal', 'by', p_unit, 'at', p_target, 'dmg', v_got,
      'crit', false, 'counter', false, 'first', false, 'def', false,
      'why', 'mend'));
    v_note := (v_me->>'name') || ' mends ' || (v_tgt->>'name') || ' for ' || v_got || '.';

  -- ---- two turns of cover -------------------------------------------------
  elsif v_kind = 'mist' then
    -- The parent key first. jsonb_set's create_missing only creates the LAST
    -- step of a path: ['mist','host'] on a state with no 'mist' at all does
    -- nothing at all, silently, which is the worst way for a jsonb write to
    -- fail. A match begun before this migration has no 'mist' key.
    if v_st->'mist' is null then
      v_st := jsonb_set(v_st, '{mist}', '{}'::jsonb, true);
    end if;
    v_st := jsonb_set(
      v_st, array['mist', p_side],
      jsonb_build_object('t', coalesce((v_me->>'abilityTurns')::int, 1), 'pct', v_n),
      true);
    v_out := v_st->'units';
    v_note := (v_me->>'name') || ' calls up the mist.';

  -- ---- ten, and poisoned ---------------------------------------------------
  elsif v_kind = 'poison_hit' then
    if v_tgt is null then raise exception 'that ability needs a target'; end if;
    if v_tgt->>'owner' = p_side then raise exception 'no friendly fire'; end if;
    v_dist := cn_cheb((v_me->>'x')::int, (v_me->>'y')::int,
                      (v_tgt->>'x')::int, (v_tgt->>'y')::int);
    if v_dist > (v_me->>'rmax')::int then raise exception 'out of range'; end if;
    if not cn_los_clear(v_st, (v_me->>'x')::int, (v_me->>'y')::int,
                        (v_tgt->>'x')::int, (v_tgt->>'y')::int) then
      raise exception 'a tree is in the way';
    end if;
    for u in select * from jsonb_array_elements(v_st->'units') loop
      if u->>'id' = p_target then
        u := cn_afflict(u, 'poison', 'true'::jsonb);
        u := jsonb_set(u, '{hp}', to_jsonb((u->>'hp')::int - v_n));
        v_hits := v_hits || jsonb_build_object('id', u->>'id', 'dmg', v_n);
        v_swings := v_swings || jsonb_build_object(
          'k', 'hit', 'by', p_unit, 'at', u->>'id', 'dmg', v_n,
          'crit', false, 'counter', false, 'first', false, 'def', false,
          'why', 'poison');
      end if;
      if (u->>'hp')::int > 0 then v_out := v_out || u; end if;
    end loop;
    v_note := (v_me->>'name') || ' poisons ' || (v_tgt->>'name') || '.';

  -- ---- two tiles in a line, alight ----------------------------------------
  elsif v_kind = 'line_burn' then
    if v_tgt is null then raise exception 'that ability needs a target'; end if;
    v_dist := cn_cheb((v_me->>'x')::int, (v_me->>'y')::int,
                      (v_tgt->>'x')::int, (v_tgt->>'y')::int);
    if v_dist > (v_me->>'rmax')::int then raise exception 'out of range'; end if;
    -- The line runs from the caster THROUGH the target and one tile past.
    -- Two tiles, as the card says, and which two is decided by where you
    -- aim rather than by a compass direction nobody can see.
    v_dx := sign((v_tgt->>'x')::int - (v_me->>'x')::int);
    v_dy := sign((v_tgt->>'y')::int - (v_me->>'y')::int);
    for u in select * from jsonb_array_elements(v_st->'units') loop
      if ((u->>'x')::int = (v_tgt->>'x')::int and (u->>'y')::int = (v_tgt->>'y')::int)
         or ((u->>'x')::int = (v_tgt->>'x')::int + v_dx
             and (u->>'y')::int = (v_tgt->>'y')::int + v_dy) then
        u := cn_afflict(u, 'burn', 'true'::jsonb);
        u := jsonb_set(u, '{hp}', to_jsonb((u->>'hp')::int - v_n));
        v_hits := v_hits || jsonb_build_object('id', u->>'id', 'dmg', v_n);
        v_swings := v_swings || jsonb_build_object(
          'k', 'hit', 'by', p_unit, 'at', u->>'id', 'dmg', v_n,
          'crit', false, 'counter', false, 'first', false, 'def', false,
          'why', 'fire');
      end if;
      if (u->>'hp')::int > 0 then v_out := v_out || u; end if;
    end loop;
    v_note := (v_me->>'name') || ' sets two tiles alight for ' || v_n || '.';

  else
    raise exception 'that ability is not built yet: %', v_kind;
  end if;

  v_st := jsonb_set(v_st, '{units}', v_out);
  v_st := cn_end_act(v_st, p_unit);
  v_st := state_log(v_st, v_note);
  if v_felled then v_st := state_log(v_st, 'A tree comes down.'); end if;

  -- The board draws from `fx` the way it does after an exchange. `hits` is the
  -- shape an ability needs and an attack never did: one actor, any number of
  -- receivers. A client that does not know the field ignores it and draws the
  -- new board, which is the right thing for it to do.
  v_st := jsonb_set(v_st, '{fx}', jsonb_build_object(
    'seq', v_seq, 'kind', 'ability', 'atk', p_unit, 'tgt', p_target,
    'why', v_kind, 'hits', v_hits, 'swings', v_swings,
    'dmg', 0, 'heal', 0, 'counter', 0, 'burnAtk', 0, 'burnTgt', 0,
    'killedTgt', false, 'killedAtk', false, 'newBurn', false,
    'cured', false, 'parry', false, 'tree', false), true);

  update public.matches
     set state = v_st,
         turn_deadline = turn_deadline
           + (cn_cine_ms(v_swings) || ' milliseconds')::interval,
         updated_at = now()
   where id = m.id returning * into m;
  return m;
end $$;

-- -------------------------------------------------------------------------
-- 6. the turn: the swamp, the stun, the poison, then the mending
-- -------------------------------------------------------------------------
create or replace function public.advance_turn(p_match uuid, p_note text, p_timeout boolean)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare
  m public.matches; st jsonb; u jsonb; out_u jsonb := '[]'::jsonb;
  v_who text; v_next text; v_turn int; v_did boolean := false; v_n int;
  v_got int; v_hurt int; u2 jsonb; v_poisoned jsonb := '[]'::jsonb;
begin
  select * into m from public.matches where id = p_match for update;
  st := m.state;
  v_who  := st->>'turn';
  v_next := case when v_who = 'host' then 'guest' else 'host' end;
  v_turn := coalesce((st->>'turnNumber')::int, 1) + 1;

  -- Did the side whose turn is ending actually do anything with it?
  for u in select * from jsonb_array_elements(st->'units') loop
    if u->>'owner' = v_who and ((u->>'moved')::boolean or (u->>'acted')::boolean) then
      v_did := true;
    end if;
    u := jsonb_set(u, '{moved}', 'false'::jsonb);
    u := jsonb_set(u, '{acted}', 'false'::jsonb);
    u := jsonb_set(u, '{spent}', 'false'::jsonb);
    -- A guard is raised on your turn and has to survive the opponent's, so
    -- it lapses when its owner's next turn opens -- not when it is tested.
    if u->>'owner' = v_next then
      u := jsonb_set(u, '{defending}', 'false'::jsonb);
    end if;
    out_u := out_u || u;
  end loop;

  if st->'idle' is null then
    st := jsonb_set(st, '{idle}', jsonb_build_object('host', 0, 'guest', 0));
  end if;
  v_n := coalesce((st->'idle'->>v_who)::int, 0);
  if p_timeout and not v_did then v_n := v_n + 1; else v_n := 0; end if;
  st := jsonb_set(st, array['idle', v_who], to_jsonb(v_n));

  if v_n >= 3 then
    if coalesce(st->>'away', '') <> v_who then
      st := state_log(st,
        case when v_who = 'host' then m.host_name else m.guest_name end
        || ' has not acted for three turns.');
    end if;
    st := jsonb_set(st, '{away}', to_jsonb(v_who));
  elsif st->>'away' = v_who then
    st := jsonb_set(st, '{away}', 'null'::jsonb);
    st := state_log(st,
      case when v_who = 'host' then m.host_name else m.guest_name end || ' is back.');
  end if;

  st := jsonb_set(st, '{units}', out_u);

  -- THE MIST THINS. Counted down on the turn of the side that raised it,
  -- as that turn ENDS -- so "two turns" means this one and the next one,
  -- which is what somebody spending an activation on it expects to buy.
  v_n := coalesce((st->'mist'->v_who->>'t')::int, 0);
  if v_n > 0 then
    st := jsonb_set(st, array['mist', v_who, 't'], to_jsonb(v_n - 1));
    if v_n = 1 then
      st := state_log(st, 'The mist lifts.');
    end if;
  end if;

  -- SARRAVE. Every tile around it, at the start of its own side's turn,
  -- which is BEFORE the poison below bites -- so a unit poisoned this turn
  -- does not also pay for it this turn. Collected first and applied in the
  -- same pass as everything else, because a second walk over the units is
  -- a second chance to disagree about who is where.
  for u in select * from jsonb_array_elements(st->'units') loop
    if u->>'owner' = v_next and coalesce((u->>'poisonsAdj')::boolean, false)
       and (u->>'hp')::int > 0 then
      for u2 in select * from jsonb_array_elements(st->'units') loop
        if u2->>'id' <> u->>'id'
           and cn_cheb((u->>'x')::int, (u->>'y')::int,
                       (u2->>'x')::int, (u2->>'y')::int) = 1 then
          v_poisoned := v_poisoned || to_jsonb(u2->>'id');
        end if;
      end loop;
    end if;
  end loop;

  -- AND THE SLOW ONES MEND. Wuzu's regeneration, at the start of its own
  -- side's turn rather than at the end of the other's: a player should see
  -- it happen on the board they are about to act on.
  out_u := '[]'::jsonb;
  for u in select * from jsonb_array_elements(st->'units') loop
    -- The swamp first, so the new poison does not also tick this turn.
    if v_poisoned ? (u->>'id') then
      if not cn_has(u, 'poison') then
        st := state_log(st, (u->>'name') || ' is poisoned.');
      end if;
      u := cn_afflict(u, 'poison', 'true'::jsonb);
    end if;

    -- A stun is one go, and this is the go it costs.
    if u->>'owner' = v_next and cn_stunned(u) then
      u := cn_afflict(u, 'stun',
                      to_jsonb(greatest(0, (u->'effects'->>'stun')::int - 1)));
      if not cn_stunned(u) then
        st := state_log(st, (u->>'name') || ' shakes it off.');
      end if;
    end if;

    -- POISON bites at the start of its own side's turn, and it can kill.
    if u->>'owner' = v_next and cn_has(u, 'poison') and (u->>'hp')::int > 0 then
      v_hurt := cn_effect_dmg(st, u, cn_poison_pct());
      u := jsonb_set(u, '{hp}', to_jsonb((u->>'hp')::int - v_hurt));
      st := state_log(st, (u->>'name') || ' takes ' || v_hurt || ' from the poison.');
    end if;

    if u->>'owner' = v_next and coalesce((u->>'regenPct')::int, 0) > 0
       and (u->>'hp')::int > 0 and (u->>'hp')::int < (u->>'maxHp')::int then
      v_got := least((u->>'maxHp')::int - (u->>'hp')::int,
                     greatest(1, round((u->>'maxHp')::int
                              * coalesce((u->>'regenPct')::int, 0) / 100.0)::int));
      u := jsonb_set(u, '{hp}', to_jsonb((u->>'hp')::int + v_got));
      st := state_log(st, (u->>'name') || ' mends ' || v_got || '.');
    end if;
    -- A unit the poison finished leaves the board here, the same as one a
    -- blow finished. The win condition is checked by whoever reads the
    -- board next; what must not happen is a corpse standing on a tile.
    if (u->>'hp')::int > 0 then out_u := out_u || u; end if;
  end loop;
  st := jsonb_set(st, '{units}', out_u);

  st := jsonb_set(st, '{acts}', '0'::jsonb);
  st := jsonb_set(st, '{active}', 'null'::jsonb);
  st := jsonb_set(st, '{turn}', to_jsonb(v_next));
  st := jsonb_set(st, '{turnNumber}', to_jsonb(v_turn));
  if p_note is not null then st := state_log(st, p_note); end if;
  st := state_log(st, 'Turn ' || v_turn || ' — '
        || case when v_next = 'host' then m.host_name else m.guest_name end || ' to act.');

  update public.matches
     set state = st, turn_deadline = now() + interval '30 seconds', updated_at = now()
   where id = m.id returning * into m;
  return m;
end
$$;

-- ---------------------------------------------------------------------------
-- 7. THE SEVENTH LEFTOVER
--
-- `parries` means "this unit's answer lands BEFORE the blow it is answering".
-- That is Quick Dagger, and the spec gives Quick Dagger to Dorme. It has been
-- on Lium since 0013, where it arrived as flavour; Lium's card says "Always
-- Ready -- slightly increased parry and crit rates, parries all parries" and
-- says nothing whatever about answering first.
-- ---------------------------------------------------------------------------
update public.cards set parries = false where slug = 'lium';
update public.cards set parries = true  where slug = 'dorme';

-- ---------------------------------------------------------------------------
-- 8. and the nine become playable
-- ---------------------------------------------------------------------------
update public.cards set ability_kind = 'poison_hit', ability_n = 10 where slug = 'velmor';
update public.cards set ability_kind = 'line_burn',  ability_n = 15 where slug = 'ashvar';
update public.cards set poisons_adjacent = true                     where slug = 'sarrave';
update public.cards set vs_poisoned = 25                            where slug = 'thalgrim';
update public.cards set lifesteal_pct = 100                         where slug = 'nyxara';
update public.cards set stuns = true                                where slug = 'zephyra';

-- Miah and Stelaris carry the auras F1 built and nothing else; Dorme carries
-- the flag that just moved. All nine switch on together, because a roster that
-- arrives in instalments is a roster nobody can learn.
update public.cards set is_active = true
 where slug in ('miah','stelaris','dorme','ashvar','velmor','sarrave',
                'thalgrim','nyxara','zephyra');

-- ---------------------------------------------------------------------------
-- 9. AND THE DEFAULT DECK STOPS BEING ILLEGAL
--
-- Found by the suite the moment the nine switched on, and it would have
-- reached every account with nothing saved.
--
-- `default_deck()` has always been "the first five cards by sort". Until this
-- migration exactly one of those five was a Royal, because there WAS exactly
-- one; the spec's order puts King Dereo, Queen Miah and King Stelaris at 1, 2
-- and 3, so the default deck was about to contain three crowns -- and a
-- kingdom must hold exactly one. Every fallback deck in the game would have
-- been refused by the rule that has guarded them since 0018.
--
-- So the default takes the first Royal and then the first four of everybody
-- else. It is still "the top of the list", it simply knows what a kingdom is.
-- ---------------------------------------------------------------------------
create or replace function public.default_deck() returns text[]
language sql stable as $$
  select coalesce(array_agg(slug order by n), '{}'::text[]) from (
    (select slug, 0 as n from public.cards
      where is_active and slug is not null and royal
      order by sort limit 1)
    union all
    (select slug, sort as n from public.cards
      where is_active and slug is not null and not royal
      order by sort limit public.deck_size() - 1)
  ) picked
$$;

-- ---------------------------------------------------------------------------
-- Did it work? All true means yes.
-- ---------------------------------------------------------------------------
select
  (select count(*) from public.cards where is_active and slug is not null) = 20
                                                              as all_twenty_playable,
  (select count(*) from public.cards where is_active and royal) = 3
                                                              as three_crowns_to_choose_from,
  (select not parries from public.cards where slug = 'lium')  as lium_stops_answering_first,
  (select parries from public.cards where slug = 'dorme')     as and_dorme_starts,
  (select ability_kind = 'poison_hit' from public.cards where slug = 'velmor')
                                                              as cursed_blade,
  (select ability_kind = 'line_burn' from public.cards where slug = 'ashvar')
                                                              as fireball,
  (select stuns from public.cards where slug = 'zephyra')     as cyclone,
  (select lifesteal_pct = 100 from public.cards where slug = 'nyxara')
                                                              as cursed_body,
  (select vs_poisoned = 25 from public.cards where slug = 'thalgrim')
                                                              as thalgrim_hates_poison,
  (select poisons_adjacent from public.cards where slug = 'sarrave')
                                                              as and_sarrave_makes_it,
  public.cn_burn_pct() = 15 and public.cn_poison_pct() = 10    as the_two_numbers,
  public.deck_royals(public.default_deck()) = 1                as the_default_deck_is_legal,
  array_length(public.default_deck(), 1) = public.deck_size()  as and_still_five;
