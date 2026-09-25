-- 0113: an authored range override for "a chosen tile" (BOARD_CELL) abilities.
--
-- Jared, after asking why the Range pill doesn't appear for "a chosen tile"
-- like it does for the four scanning selectors: "Add that option then lol."
--
-- Why it didn't exist: BOARD_CELL never scans the board for candidates the
-- way NEARBY_ALLIES/ADJACENT_UNITS/ENEMY_IN_RANGE/RANDOM_ENEMY_IN_RANGE do
-- (0102 gave those four an authored FIXED_RANGE/CARD_RANGE/ANYWHERE
-- override) -- cn_resolve_targets' own BOARD_CELL branch just hands back
-- whatever tile the player clicked. "Which tiles can the player click" was
-- instead hard-coded in two separate places, both fixed at the acting
-- card's own rmax with no way to override it:
--   - client-side, Board.tsx's scriptTiles: `d < 1 || d > selected.rmax`,
--     which lights up the clickable tiles for the player.
--   - server-side, cn_create_structure's own comment (b): "range: 1 <=
--     distance <= this unit's own rmax" -- but ONLY for the
--     CREATE_STRUCTURE/SUMMON_OBJECT actions. TELEPORT_SELF's branch in
--     cn_effect_apply_action carried no range check AT ALL -- no live
--     card used TELEPORT_SELF at the time (0064's own note), so nothing
--     ever exercised the gap, but a modified client could always have
--     teleported a unit anywhere on the board with this action.
--
-- This migration gives BOARD_CELL the same FIXED_RANGE/CARD_RANGE/
-- ANYWHERE vocabulary 0102 gave the scanning selectors -- both server
-- functions that ever place a unit or object on a clicked tile
-- (cn_create_structure, and now cn_effect_apply_action's TELEPORT_SELF
-- branch) read the SAME p_effect->>'range_kind'/'range_min'/'range_max'
-- already sitting on the card_effects row, exactly like every other
-- range-aware selector. Every row from before this migration has
-- range_kind null, which keeps behaving exactly as it always did (the
-- unit's own 1..rmax) -- this is purely additive. TELEPORT_SELF gains
-- real enforcement for the first time as a direct consequence of reusing
-- this same range-checking shape rather than a special-cased no-op --
-- see its own comment below.
--
-- Client-side (AdminCards.tsx, Board.tsx) is updated in the same change
-- that ships this: BOARD_CELL joins RANGE_TARGETS so the sentence
-- builder offers the Range pill for it, and scriptTiles reads the row's
-- range_kind/range_min/range_max instead of always using selected.rmax,
-- so the tiles that light up on the board match what the server will
-- actually accept.

-- ---------------------------------------------------------------------------
-- 1. cn_create_structure -- section (b)'s hard-coded 1..rmax becomes an
--    override-aware check, same shape 0102 gave the scanning selectors.
-- ---------------------------------------------------------------------------
create or replace function public.cn_create_structure(v_st jsonb, p_effect jsonb, p_unit jsonb, p_target_id text)
returns jsonb
language plpgsql
set search_path to 'public'
as $function$
declare
  v_slug text := p_effect->>'structure_slug';
  v_row public.structures;
  v_tile int[]; v_rocks jsonb := '[]'::jsonb; e jsonb;
  v_dist int;
  -- 0113: an authored range override for BOARD_CELL. Null (every row
  -- before this migration, and CARD_RANGE/PLAYER_CHOOSES today, which
  -- aren't wired to anything different) falls through to the same
  -- 1 <= distance <= this unit's own rmax section (b) always enforced.
  v_rkind text; v_rmin int; v_rmax int;
begin
  if v_slug is null then return v_st; end if;
  select * into v_row from public.structures where slug = v_slug and is_active;
  if v_row.id is null then return v_st; end if;

  -- (a) one live structure per unit at a time.
  for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
    if e->>'by' = p_unit->>'id' then return v_st; end if;
  end loop;

  v_tile := cn_tile_target(p_target_id);
  if v_tile is null then return v_st; end if;
  if v_tile[1] < 0 or v_tile[2] < 0
     or v_tile[1] >= coalesce((v_st->'board'->>'w')::int, 0)
     or v_tile[2] >= coalesce((v_st->'board'->>'h')::int, 0) then
    return v_st;
  end if;

  -- (b) range: 0113 -- an authored FIXED_RANGE/ANYWHERE override on this
  -- effect row, or (unset, CARD_RANGE, PLAYER_CHOOSES) the same
  -- 1 <= distance <= this unit's own rmax this always enforced.
  v_dist := cn_cheb((p_unit->>'x')::int, (p_unit->>'y')::int, v_tile[1], v_tile[2]);
  v_rkind := p_effect->>'range_kind';
  if v_rkind = 'FIXED_RANGE' then
    v_rmin := coalesce((p_effect->>'range_min')::int, 1);
    v_rmax := coalesce((p_effect->>'range_max')::int, 1);
    if v_dist < v_rmin or v_dist > v_rmax then return v_st; end if;
  elsif v_rkind = 'ANYWHERE' then
    null; -- no distance check at all
  else
    if v_dist < 1 or v_dist > coalesce((p_unit->>'rmax')::int, 0) then return v_st; end if;
  end if;

  -- (c) line of sight.
  if not cn_los_clear(v_st, (p_unit->>'x')::int, (p_unit->>'y')::int, v_tile[1], v_tile[2]) then
    return v_st;
  end if;

  if exists (select 1 from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) u
              where (u->>'x')::int = v_tile[1] and (u->>'y')::int = v_tile[2])
     or exists (select 1 from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) o
              where (o->>'x')::int = v_tile[1] and (o->>'y')::int = v_tile[2]) then
    return v_st;
  end if;

  for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
    v_rocks := v_rocks || e;
  end loop;
  v_rocks := v_rocks || jsonb_build_object(
    'id', gen_random_uuid()::text, 'kind', v_slug,
    'x', v_tile[1], 'y', v_tile[2],
    'hp', v_row.hp, 'maxHp', v_row.hp,
    'owner', p_unit->>'owner', 'by', p_unit->>'id');
  v_st := jsonb_set(v_st, '{obstacles}', v_rocks);
  v_st := state_log(v_st, (p_unit->>'name') || ' sets down ' || cn_obj_name(v_slug) || '.');

  v_st := cn_run_structure_effects(v_st, 'ON_PLACE',
    v_rocks->(jsonb_array_length(v_rocks) - 1),
    jsonb_build_object('placedBy', p_unit->>'id'));
  return v_st;
end
$function$;

-- ---------------------------------------------------------------------------
-- 2. cn_effect_apply_action -- TELEPORT_SELF gains the same bounds/range/
--    LOS/occupied checks CREATE_STRUCTURE/SUMMON_OBJECT already made,
--    which it never had at all before this migration (see header).
--    Full body reproduced (create-or-replace, not a diff) -- everything
--    below the TELEPORT_SELF branch is byte-for-byte unchanged.
-- ---------------------------------------------------------------------------
create or replace function public.cn_effect_apply_action(v_st jsonb, p_effect jsonb, p_unit jsonb, p_target_id text, p_context jsonb)
returns jsonb
language plpgsql
set search_path to 'public'
as $function$
declare
  v_action text := p_effect->>'action';
  v_value int := coalesce((p_effect->>'value')::int, 0);
  v_status text := p_effect->>'status';
  v_stat text := p_effect->>'stat_name';
  v_self_id text := p_unit->>'id';
  v_self jsonb; v_target jsonb; v_out jsonb; u jsonb;
  v_tile int[]; v_dx int; v_dy int; v_nx int; v_ny int; v_occupied boolean;
  v_field text; v_copy_val jsonb; v_half int;
  -- 0113: TELEPORT_SELF's own bounds/range/LOS check -- see this
  -- migration's header for why it never had one before.
  v_dist int; v_rkind text; v_rmin int; v_rmax int;
  v_num_field_map jsonb := '{
    "HP": "hp", "MOV": "mov", "RMIN": "rmin", "RMAX": "rmax",
    "CRMIN": "crmin", "CRMAX": "crmax",
    "PARRY_PCT": "parryPct", "CRIT_PCT": "critPct", "TWICE_PCT": "twicePct",
    "LIFESTEAL_PCT": "lifestealPct", "REGEN_PCT": "regenPct",
    "VS_POISONED_BONUS": "vsPoisoned", "EVASION_PCT": "evasionPct"
  }'::jsonb;
  v_bool_field_map jsonb := '{
    "SLIPPERY": "slippery", "PARRY_ALL": "parryAll", "STUNS_ON_HIT": "stuns",
    "POISONS_ADJACENT": "poisonsAdj", "CURES_BURN": "cures", "BLOOMS": "blooms",
    "SNEAKS": "sneaks", "FLIES": "flies", "TRAMPLES": "tramples",
    "PARRIES": "parries", "BURNS": "burns", "HEALS": "heals"
  }'::jsonb;
begin
  if p_target_id is null or p_target_id = '' then return v_st; end if;

  if left(p_target_id, 1) = '@' then
    if v_action in ('CREATE_STRUCTURE', 'SUMMON_OBJECT') then
      return cn_create_structure(v_st, p_effect, p_unit, p_target_id);
    end if;
    if v_action <> 'TELEPORT_SELF' then return v_st; end if;
    v_tile := cn_tile_target(p_target_id);
    if v_tile is null then return v_st; end if;

    -- 0113: bounds.
    if v_tile[1] < 0 or v_tile[2] < 0
       or v_tile[1] >= coalesce((v_st->'board'->>'w')::int, 0)
       or v_tile[2] >= coalesce((v_st->'board'->>'h')::int, 0) then
      return v_st;
    end if;

    -- 0113: range -- same FIXED_RANGE/ANYWHERE override, or the unit's
    -- own 1..rmax, cn_create_structure's section (b) uses.
    v_dist := cn_cheb((p_unit->>'x')::int, (p_unit->>'y')::int, v_tile[1], v_tile[2]);
    v_rkind := p_effect->>'range_kind';
    if v_rkind = 'FIXED_RANGE' then
      v_rmin := coalesce((p_effect->>'range_min')::int, 1);
      v_rmax := coalesce((p_effect->>'range_max')::int, 1);
      if v_dist < v_rmin or v_dist > v_rmax then return v_st; end if;
    elsif v_rkind = 'ANYWHERE' then
      null; -- no distance check at all
    else
      if v_dist < 1 or v_dist > coalesce((p_unit->>'rmax')::int, 0) then return v_st; end if;
    end if;

    -- 0113: line of sight.
    if not cn_los_clear(v_st, (p_unit->>'x')::int, (p_unit->>'y')::int, v_tile[1], v_tile[2]) then
      return v_st;
    end if;

    -- 0113: the tile must be empty -- teleporting onto an occupied one
    -- silently no-ops, same as every other illegal target in this
    -- function.
    if exists (select 1 from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) q
                where (q->>'x')::int = v_tile[1] and (q->>'y')::int = v_tile[2])
       or exists (select 1 from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) q
                where (q->>'x')::int = v_tile[1] and (q->>'y')::int = v_tile[2]) then
      return v_st;
    end if;

    v_out := '[]'::jsonb;
    for u in select * from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) loop
      if u->>'id' = v_self_id then
        u := jsonb_set(jsonb_set(u, '{x}', to_jsonb(v_tile[1])), '{y}', to_jsonb(v_tile[2]));
      end if;
      v_out := v_out || u;
    end loop;
    return jsonb_set(v_st, '{units}', v_out);
  end if;

  if left(p_target_id, 1) = '#' then
    if v_action <> 'REVIVE' then return v_st; end if;
    return cn_revive(v_st, p_effect, p_unit, substr(p_target_id, 2));
  end if;

  if v_action = 'DRAW_CARD' then
    return v_st;
  end if;

  if v_action = 'DESTROY_SELF' then
    v_out := '[]'::jsonb;
    for u in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
      if u->>'id' <> v_self_id then v_out := v_out || u; end if;
    end loop;
    return jsonb_set(v_st, '{obstacles}', v_out);
  end if;

  for u in select * from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) loop
    if u->>'id' = v_self_id then v_self := u; end if;
    if u->>'id' = p_target_id then v_target := u; end if;
  end loop;
  if v_target is null then return v_st; end if;

  if v_action = 'COPY_STAT_FROM_TARGET' and v_stat is not null then
    if v_num_field_map ? v_stat then
      v_field := v_num_field_map->>v_stat;
      v_copy_val := coalesce(v_target->v_field, to_jsonb(0));
    elsif v_bool_field_map ? v_stat then
      v_field := v_bool_field_map->>v_stat;
      v_copy_val := coalesce(v_target->v_field, to_jsonb(false));
    end if;
  end if;

  v_out := '[]'::jsonb;
  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_target_id and v_action = 'DEAL_DAMAGE' then
      u := jsonb_set(u, '{hp}', to_jsonb((u->>'hp')::int - v_value));

    elsif u->>'id' = p_target_id and v_action = 'HEAL' then
      u := jsonb_set(u, '{hp}', to_jsonb(least((u->>'maxHp')::int, (u->>'hp')::int + v_value)));

    elsif u->>'id' = p_target_id and v_action = 'APPLY_STATUS' then
      if v_status = 'BURNING' then u := cn_afflict(u, 'burn', 'true'::jsonb);
      elsif v_status = 'POISON' then u := cn_afflict(u, 'poison', 'true'::jsonb);
      elsif v_status = 'STUN' then u := cn_afflict(u, 'stun', to_jsonb(greatest(1, v_value)));
      end if;

    elsif u->>'id' = p_target_id and v_action = 'REMOVE_STATUS' then
      if v_status in ('BURNING', 'ALL') then u := cn_afflict(u, 'burn', 'false'::jsonb); end if;
      if v_status in ('POISON', 'ALL') then u := cn_afflict(u, 'poison', 'false'::jsonb); end if;
      if v_status in ('STUN', 'ALL') then u := cn_afflict(u, 'stun', '0'::jsonb); end if;

    -- 0108: POWER moves the dice, not just the label -- delta form.
    elsif u->>'id' = p_target_id and v_action = 'MODIFY_STAT' and v_stat = 'POWER' then
      u := jsonb_set(u, '{pow}', to_jsonb(coalesce((u->>'pow')::int, 0) + v_value));
      u := jsonb_set(u, '{dmin}', to_jsonb(greatest(0, (u->>'dmin')::int + v_value)));
      u := jsonb_set(u, '{dmax}', to_jsonb(greatest(0, (u->>'dmax')::int + v_value)));

    elsif u->>'id' = p_target_id and v_action = 'MODIFY_STAT' and v_stat is not null then
      if v_num_field_map ? v_stat then
        v_field := v_num_field_map->>v_stat;
        u := jsonb_set(u, array[v_field], to_jsonb(coalesce((u->>v_field)::int, 0) + v_value));
      elsif v_bool_field_map ? v_stat then
        v_field := v_bool_field_map->>v_stat;
        u := jsonb_set(u, array[v_field], to_jsonb(v_value <> 0));
      end if;

    -- 0109: SET_STAT's own POWER branch -- assigns rather than shifts.
    -- v_half preserves whatever roll-width this unit currently has
    -- (dmax-dmin), which stays constant under repeated MODIFY_STAT
    -- POWER deltas -- the same width cn_check_card gave the card at
    -- authoring time, half on each side of the new absolute number.
    elsif u->>'id' = p_target_id and v_action = 'SET_STAT' and v_stat = 'POWER' then
      v_half := round((((u->>'dmax')::int - (u->>'dmin')::int) / 2.0))::int;
      u := jsonb_set(u, '{pow}', to_jsonb(v_value));
      u := jsonb_set(u, '{dmin}', to_jsonb(greatest(0, v_value - v_half)));
      u := jsonb_set(u, '{dmax}', to_jsonb(greatest(0, v_value + v_half)));

    -- 0109: SET_STAT's generic branch -- same field maps MODIFY_STAT
    -- reads, but ASSIGNS v_value instead of adding it. For a boolean
    -- field this reads identically to MODIFY_STAT's own boolean case
    -- (both were always "set the flag from value<>0"), kept here too so
    -- SET_STAT alone is a complete vocabulary and nothing has to fall
    -- back to MODIFY_STAT just to flip a flag.
    elsif u->>'id' = p_target_id and v_action = 'SET_STAT' and v_stat is not null then
      if v_num_field_map ? v_stat then
        v_field := v_num_field_map->>v_stat;
        u := jsonb_set(u, array[v_field], to_jsonb(v_value));
      elsif v_bool_field_map ? v_stat then
        v_field := v_bool_field_map->>v_stat;
        u := jsonb_set(u, array[v_field], to_jsonb(v_value <> 0));
      end if;

    elsif u->>'id' = p_target_id and v_action = 'COPY_STAT_FROM_TARGET' and v_field is not null then
      u := jsonb_set(u, array[v_field], v_copy_val);

    elsif u->>'id' = p_target_id and v_action = 'PUSH_BACK' then
      v_dx := sign((u->>'x')::int - (p_unit->>'x')::int);
      v_dy := sign((u->>'y')::int - (p_unit->>'y')::int);
      if v_dx = 0 and v_dy = 0 then v_dx := 1; end if;
      v_nx := (u->>'x')::int + v_dx;
      v_ny := (u->>'y')::int + v_dy;
      v_occupied := v_nx < 0 or v_ny < 0
        or v_nx >= (v_st->'board'->>'w')::int or v_ny >= (v_st->'board'->>'h')::int
        or exists (select 1 from jsonb_array_elements(v_st->'units') q
                     where (q->>'x')::int = v_nx and (q->>'y')::int = v_ny)
        or exists (select 1 from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) q
                     where (q->>'x')::int = v_nx and (q->>'y')::int = v_ny);
      if not v_occupied then
        u := jsonb_set(jsonb_set(u, '{x}', to_jsonb(v_nx)), '{y}', to_jsonb(v_ny));
      end if;

    elsif (u->>'id' = v_self_id or u->>'id' = p_target_id) and v_action = 'SWAP_POSITIONS' then
      if u->>'id' = v_self_id then
        u := jsonb_set(jsonb_set(u, '{x}', v_target->'x'), '{y}', v_target->'y');
      else
        u := jsonb_set(jsonb_set(u, '{x}', v_self->'x'), '{y}', v_self->'y');
      end if;

    elsif u->>'id' = p_target_id and v_action = 'TRIGGER_PARRY' then
      u := jsonb_set(u, '{forcedParry}', 'true'::jsonb);

    elsif u->>'id' = p_target_id and v_action in ('REFLECT_DAMAGE_PCT', 'COUNTER_ATTACK_PCT') then
      u := jsonb_set(u, '{hp}', to_jsonb((u->>'hp')::int
        - round(coalesce((p_context->>'damage')::numeric, 0) * v_value / 100.0)::int));
    end if;

    if (u->>'hp')::int > 0 then v_out := v_out || u;
    else v_st := cn_bury(v_st, u); end if;
  end loop;
  v_st := jsonb_set(v_st, '{units}', v_out);

  if v_action = 'GRANT_EXTRA_ACTIVATION' and p_target_id = v_self_id then
    v_st := jsonb_set(v_st, '{acts}',
      to_jsonb(greatest(0, coalesce((v_st->>'acts')::int, 0) - greatest(1, v_value))));
  end if;

  return v_st;
end
$function$;

-- ---------------------------------------------------------------------------
-- 3. Self-tests.
-- ---------------------------------------------------------------------------
do $$
declare v_src text;
begin
  select prosrc into v_src from pg_proc where proname = 'cn_create_structure';
  if v_src !~ '0113' then
    raise exception '0113 self-test FAILED: cn_create_structure does not mention 0113';
  end if;
  select prosrc into v_src from pg_proc where proname = 'cn_effect_apply_action';
  if v_src !~ '0113' then
    raise exception '0113 self-test FAILED: cn_effect_apply_action does not mention 0113';
  end if;
end $$;

-- Self-test 1: FIXED_RANGE lets a unit place a structure FARTHER than its
-- own rmax -- the exact gap Jared asked to close. Unit at (3,3), rmax 1;
-- effect range 2-2; tile (5,3) is distance 2 -- allowed.
do $$
declare
  v_st jsonb; v_unit jsonb; v_effect jsonb; v_result jsonb;
begin
  v_st := jsonb_build_object(
    'board', jsonb_build_object('w', 8, 'h', 8),
    'units', jsonb_build_array(jsonb_build_object(
      'id', 'u1', 'owner', 'p1', 'x', 3, 'y', 3, 'hp', 10, 'maxHp', 10,
      'rmin', 1, 'rmax', 1, 'name', 'Test Unit')),
    'obstacles', '[]'::jsonb);
  v_unit := v_st->'units'->0;
  v_effect := jsonb_build_object('structure_slug', 'tornado',
    'range_kind', 'FIXED_RANGE', 'range_min', 2, 'range_max', 2);
  v_result := cn_create_structure(v_st, v_effect, v_unit, '@5,3');
  if jsonb_array_length(coalesce(v_result->'obstacles', '[]'::jsonb)) <> 1
     or (v_result->'obstacles'->0->>'x')::int <> 5 then
    raise exception '0113 self-test 1 FAILED: FIXED_RANGE 2-2 should let a distance-2 placement through beyond rmax 1, got %', v_result->'obstacles';
  end if;
  raise notice '0113 self-test 1 passed: FIXED_RANGE overrides the card''s own rmax for a farther placement.';
end $$;

-- Self-test 2: that same FIXED_RANGE 2-2 override still refuses a tile
-- that is too CLOSE (distance 1) -- an override constrains both ways, it
-- is not just "at least".
do $$
declare
  v_st jsonb; v_unit jsonb; v_effect jsonb; v_result jsonb;
begin
  v_st := jsonb_build_object(
    'board', jsonb_build_object('w', 8, 'h', 8),
    'units', jsonb_build_array(jsonb_build_object(
      'id', 'u1', 'owner', 'p1', 'x', 3, 'y', 3, 'hp', 10, 'maxHp', 10,
      'rmin', 1, 'rmax', 1, 'name', 'Test Unit')),
    'obstacles', '[]'::jsonb);
  v_unit := v_st->'units'->0;
  v_effect := jsonb_build_object('structure_slug', 'tornado',
    'range_kind', 'FIXED_RANGE', 'range_min', 2, 'range_max', 2);
  v_result := cn_create_structure(v_st, v_effect, v_unit, '@4,3');
  if jsonb_array_length(coalesce(v_result->'obstacles', '[]'::jsonb)) <> 0 then
    raise exception '0113 self-test 2 FAILED: FIXED_RANGE 2-2 should refuse a distance-1 placement, got %', v_result->'obstacles';
  end if;
  raise notice '0113 self-test 2 passed: FIXED_RANGE still refuses a tile outside its own bounds.';
end $$;

-- Self-test 3: no range_kind at all (every row before this migration)
-- behaves EXACTLY as before -- 1 <= distance <= the unit's own rmax.
do $$
declare
  v_st jsonb; v_unit jsonb; v_effect jsonb; v_result jsonb;
begin
  v_st := jsonb_build_object(
    'board', jsonb_build_object('w', 8, 'h', 8),
    'units', jsonb_build_array(jsonb_build_object(
      'id', 'u1', 'owner', 'p1', 'x', 3, 'y', 3, 'hp', 10, 'maxHp', 10,
      'rmin', 1, 'rmax', 1, 'name', 'Test Unit')),
    'obstacles', '[]'::jsonb);
  v_unit := v_st->'units'->0;
  v_effect := jsonb_build_object('structure_slug', 'tornado');

  v_result := cn_create_structure(v_st, v_effect, v_unit, '@4,3');
  if jsonb_array_length(coalesce(v_result->'obstacles', '[]'::jsonb)) <> 1 then
    raise exception '0113 self-test 3a FAILED: unset range_kind should still allow distance 1 (within rmax 1), got %', v_result->'obstacles';
  end if;

  v_result := cn_create_structure(v_st, v_effect, v_unit, '@5,3');
  if jsonb_array_length(coalesce(v_result->'obstacles', '[]'::jsonb)) <> 0 then
    raise exception '0113 self-test 3b FAILED: unset range_kind should still refuse distance 2 (beyond rmax 1), got %', v_result->'obstacles';
  end if;
  raise notice '0113 self-test 3 passed: unset range_kind is unchanged -- 1..rmax, exactly as before this migration.';
end $$;

-- Self-test 4: ANYWHERE skips the distance check but NOT the board-bounds
-- or occupied-tile checks.
do $$
declare
  v_st jsonb; v_unit jsonb; v_effect jsonb; v_result jsonb;
begin
  v_st := jsonb_build_object(
    'board', jsonb_build_object('w', 8, 'h', 8),
    'units', jsonb_build_array(
      jsonb_build_object('id', 'u1', 'owner', 'p1', 'x', 0, 'y', 0, 'hp', 10, 'maxHp', 10,
        'rmin', 1, 'rmax', 1, 'name', 'Test Unit'),
      jsonb_build_object('id', 'u2', 'owner', 'p2', 'x', 7, 'y', 7, 'hp', 10, 'maxHp', 10,
        'rmin', 1, 'rmax', 1, 'name', 'Occupant')),
    'obstacles', '[]'::jsonb);
  v_unit := v_st->'units'->0;
  v_effect := jsonb_build_object('structure_slug', 'tornado', 'range_kind', 'ANYWHERE');

  -- far away, empty -- allowed.
  v_result := cn_create_structure(v_st, v_effect, v_unit, '@6,7');
  if jsonb_array_length(coalesce(v_result->'obstacles', '[]'::jsonb)) <> 1 then
    raise exception '0113 self-test 4a FAILED: ANYWHERE should allow a far placement, got %', v_result->'obstacles';
  end if;

  -- far away, but occupied by u2 -- still refused.
  v_result := cn_create_structure(v_st, v_effect, v_unit, '@7,7');
  if jsonb_array_length(coalesce(v_result->'obstacles', '[]'::jsonb)) <> 0 then
    raise exception '0113 self-test 4b FAILED: ANYWHERE should not bypass the occupied-tile check, got %', v_result->'obstacles';
  end if;

  -- off the board entirely -- still refused.
  v_result := cn_create_structure(v_st, v_effect, v_unit, '@9,9');
  if jsonb_array_length(coalesce(v_result->'obstacles', '[]'::jsonb)) <> 0 then
    raise exception '0113 self-test 4c FAILED: ANYWHERE should not bypass the board-bounds check, got %', v_result->'obstacles';
  end if;
  raise notice '0113 self-test 4 passed: ANYWHERE skips distance only -- bounds and occupancy still apply.';
end $$;

-- Self-test 5: TELEPORT_SELF, which had NO server-side check at all
-- before this migration, now honours a FIXED_RANGE override the same way
-- CREATE_STRUCTURE/SUMMON_OBJECT do.
do $$
declare
  v_st jsonb; v_unit jsonb; v_effect jsonb; v_result jsonb; v_after jsonb;
begin
  v_st := jsonb_build_object(
    'board', jsonb_build_object('w', 8, 'h', 8),
    'units', jsonb_build_array(jsonb_build_object(
      'id', 'u1', 'owner', 'p1', 'x', 3, 'y', 3, 'hp', 10, 'maxHp', 10,
      'rmin', 1, 'rmax', 1, 'name', 'Test Unit')),
    'obstacles', '[]'::jsonb);
  v_unit := v_st->'units'->0;
  v_effect := jsonb_build_object('action', 'TELEPORT_SELF',
    'range_kind', 'FIXED_RANGE', 'range_min', 2, 'range_max', 2);

  -- distance 2 -- within the FIXED_RANGE override -- allowed.
  v_result := cn_effect_apply_action(v_st, v_effect, v_unit, '@5,3', '{}'::jsonb);
  select u into v_after from jsonb_array_elements(v_result->'units') u where u->>'id' = 'u1';
  if (v_after->>'x')::int <> 5 or (v_after->>'y')::int <> 3 then
    raise exception '0113 self-test 5a FAILED: TELEPORT_SELF with FIXED_RANGE 2-2 should reach distance 2, unit is at %,%',
      v_after->>'x', v_after->>'y';
  end if;

  -- distance 1 -- outside that same FIXED_RANGE 2-2 -- refused, unit stays put.
  v_result := cn_effect_apply_action(v_st, v_effect, v_unit, '@4,3', '{}'::jsonb);
  select u into v_after from jsonb_array_elements(v_result->'units') u where u->>'id' = 'u1';
  if (v_after->>'x')::int <> 3 or (v_after->>'y')::int <> 3 then
    raise exception '0113 self-test 5b FAILED: TELEPORT_SELF with FIXED_RANGE 2-2 should refuse distance 1, unit is at %,%',
      v_after->>'x', v_after->>'y';
  end if;

  -- no range_kind, rmax 1 -- distance 2 now refused (this is the newly
  -- CLOSED gap: before this migration TELEPORT_SELF would have allowed
  -- this unconditionally).
  v_effect := jsonb_build_object('action', 'TELEPORT_SELF');
  v_result := cn_effect_apply_action(v_st, v_effect, v_unit, '@5,3', '{}'::jsonb);
  select u into v_after from jsonb_array_elements(v_result->'units') u where u->>'id' = 'u1';
  if (v_after->>'x')::int <> 3 or (v_after->>'y')::int <> 3 then
    raise exception '0113 self-test 5c FAILED: TELEPORT_SELF with no range_kind and rmax 1 should refuse distance 2, unit is at %,%',
      v_after->>'x', v_after->>'y';
  end if;
  raise notice '0113 self-test 5 passed: TELEPORT_SELF is now range-checked, including the unset-range_kind default it never had before.';
end $$;
