-- 0108: MODIFY_STAT POWER now actually changes what a unit rolls.
--
-- Jared: "I want to make it so that each start of turn this card's power
-- goes +5" -- built exactly that in the sentence builder (SELF, PASSIVE,
-- "the turn starts", modifies stat of 5 power) and asked whether it would
-- work.
--
-- It would not have. Unit.pow's own comment in lib/types.ts says it
-- plainly: "The single number a player reads. The roll is pow +/- 5, and
-- dmin/dmax are derived from it server-side -- they are the dice, this is
-- the stat." cn_check_card's BEFORE trigger honors that at authoring time
-- (dmin := power - cn_spread(), dmax := power + cn_spread()), and
-- cn_attack's own damage roll -- cn_roll(dmin, dmax) -- never reads `pow`
-- at all. But cn_effect_apply_action's MODIFY_STAT branch, before this
-- migration, moved only `pow` (via v_num_field_map's "POWER": "pow"
-- entry) and left dmin/dmax untouched. So a runtime POWER buff changed
-- the number the roster tile and unit bar print (unitPower() in
-- lib/types.ts reads u.pow first) without changing a single die on the
-- board -- worse than a no-op, since the player would have been shown a
-- bigger Power stat that hit exactly as hard as before.
--
-- The fix: POWER is no longer a v_num_field_map lookup. It gets its own
-- branch, ahead of the generic one, that shifts pow/dmin/dmax by the same
-- delta -- the same relationship cn_check_card already establishes
-- between them, just applied as a delta instead of recomputed from
-- scratch (there is no stored "spread" at runtime to recompute from, and
-- there does not need to be: shifting both ends by the same amount
-- preserves whatever spread the card was built with). Floored at 0, same
-- as cn_check_card's own dmin floor, so a large enough negative modifier
-- (a debuff, or a design mistake) cannot roll a negative die.
--
-- Every other stat_name in v_num_field_map (HP, MOV, RMIN, RMAX, CRMIN,
-- CRMAX, PARRY_PCT, CRIT_PCT, TWICE_PCT, LIFESTEAL_PCT, REGEN_PCT,
-- VS_POISONED_BONUS, EVASION_PCT) is read directly by cn_attack under
-- that exact field name already, so a runtime MODIFY_STAT against any of
-- those already did what it said on the tin -- POWER was the one name on
-- that list that didn't, because it is the only one of the nine with a
-- display-only stand-in field rather than a field combat math reads
-- directly. Nothing else in this function changes.
create or replace function public.cn_effect_apply_action(
  v_st jsonb, p_effect jsonb, p_unit jsonb, p_target_id text, p_context jsonb
) returns jsonb
language plpgsql
set search_path = 'public'
as $$
declare
  v_action text := p_effect->>'action';
  v_value int := coalesce((p_effect->>'value')::int, 0);
  v_status text := p_effect->>'status';
  v_stat text := p_effect->>'stat_name';
  v_self_id text := p_unit->>'id';
  v_self jsonb; v_target jsonb; v_out jsonb; u jsonb;
  v_tile int[]; v_dx int; v_dy int; v_nx int; v_ny int; v_occupied boolean;
  v_field text; v_copy_val jsonb;
  -- 0108: "POWER" removed from this map -- it now has its own branch
  -- below (ahead of this map's generic lookup) that moves pow/dmin/dmax
  -- together instead of pow alone. See this migration's own header.
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

  -- 0093: DESTROY_SELF removes the triggering structure/obstacle itself
  -- from state.obstacles. p_unit IS the invoking structure when called
  -- from the structures path (cn_run_structure_effects passes p_structure
  -- straight through as p_unit), so this always removes p_unit's own id
  -- from obstacles regardless of which target_selector produced this loop
  -- iteration -- SELF is the intended pairing, but this stays correct even
  -- if a designer picks a different one by mistake. Placed here, before
  -- the units-array lookup below, because the structure's own id is never
  -- found scanning v_st->'units' -- it would otherwise always hit the
  -- `v_target is null` bailout right after and never run. Naturally a
  -- no-op if p_unit isn't in obstacles at all (e.g. some future
  -- non-structure caller): the filter just keeps every entry that isn't a
  -- match.
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

    -- 0108: POWER moves the dice, not just the label -- see this
    -- migration's own header for why this has to touch all three fields.
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
$$;

do $$
declare v_src text;
begin
  select prosrc into v_src from pg_proc where proname = 'cn_effect_apply_action';
  if v_src !~ '0108' then
    raise exception 'cn_effect_apply_action does not mention 0108 -- migration did not apply as expected';
  end if;
end $$;

-- Self-test: a unit at pow 20 / dmin 15 / dmax 25 (spread 5, matching
-- cn_check_card's cn_spread()), MODIFY_STAT POWER value 5 fired against
-- itself once -- expect pow 25 / dmin 20 / dmax 30. Fired a second time --
-- expect pow 30 / dmin 25 / dmax 35, confirming this stacks with each
-- call the way a repeated START_OF_TURN trigger would across turns.
do $$
declare
  v_st jsonb; v_unit jsonb; v_effect jsonb; v_after jsonb; v_u jsonb;
begin
  v_unit := jsonb_build_object(
    'id', 'h1', 'owner', 'host', 'hp', 80, 'maxHp', 80,
    'pow', 20, 'dmin', 15, 'dmax', 25, 'x', 0, 'y', 0);
  v_st := jsonb_build_object('units', jsonb_build_array(v_unit));
  v_effect := jsonb_build_object('action', 'MODIFY_STAT', 'stat_name', 'POWER', 'value', 5);

  v_st := cn_effect_apply_action(v_st, v_effect, v_unit, 'h1', '{}'::jsonb);
  select u into v_u from jsonb_array_elements(v_st->'units') u where u->>'id' = 'h1';
  if (v_u->>'pow')::int <> 25 or (v_u->>'dmin')::int <> 20 or (v_u->>'dmax')::int <> 30 then
    raise exception 'first MODIFY_STAT POWER: expected pow 25/dmin 20/dmax 30, got pow % dmin % dmax %',
      v_u->>'pow', v_u->>'dmin', v_u->>'dmax';
  end if;

  -- Second turn: fires again against the ALREADY-modified unit, same as
  -- advance_turn calling this on every one of the owner's own turns.
  v_st := cn_effect_apply_action(v_st, v_effect, v_u, 'h1', '{}'::jsonb);
  select u into v_u from jsonb_array_elements(v_st->'units') u where u->>'id' = 'h1';
  if (v_u->>'pow')::int <> 30 or (v_u->>'dmin')::int <> 25 or (v_u->>'dmax')::int <> 35 then
    raise exception 'second MODIFY_STAT POWER: expected pow 30/dmin 25/dmax 35, got pow % dmin % dmax %',
      v_u->>'pow', v_u->>'dmin', v_u->>'dmax';
  end if;

  raise notice '0108 self-test passed: POWER now stacks onto dmin/dmax across repeated fires.';
end $$;

-- Floor check: a unit already near 0 does not roll negative dice off a
-- large debuff.
do $$
declare
  v_st jsonb; v_unit jsonb; v_effect jsonb; v_u jsonb;
begin
  v_unit := jsonb_build_object(
    'id', 'h1', 'owner', 'host', 'hp', 80, 'maxHp', 80,
    'pow', 5, 'dmin', 2, 'dmax', 8, 'x', 0, 'y', 0);
  v_st := jsonb_build_object('units', jsonb_build_array(v_unit));
  v_effect := jsonb_build_object('action', 'MODIFY_STAT', 'stat_name', 'POWER', 'value', -20);

  v_st := cn_effect_apply_action(v_st, v_effect, v_unit, 'h1', '{}'::jsonb);
  select u into v_u from jsonb_array_elements(v_st->'units') u where u->>'id' = 'h1';
  if (v_u->>'dmin')::int <> 0 or (v_u->>'dmax')::int <> 0 then
    raise exception 'floor check: expected dmin 0/dmax 0, got dmin % dmax %', v_u->>'dmin', v_u->>'dmax';
  end if;
  raise notice '0108 floor check passed: a large debuff floors at 0, never negative.';
end $$;
