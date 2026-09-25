-- 0109: SET_STAT -- an explicit absolute counterpart to MODIFY_STAT.
--
-- Jared built "each start of turn this card's power goes +5" (SELF,
-- PASSIVE-tab, "the turn starts", modifies stat of 5, power) exactly as
-- 0108 was written to support, then reported it still wasn't
-- incrementing and suggested splitting the single ambiguous action into
-- "set stat to" (assign) and "change stat by" (delta).
--
-- The immediate bug turned out to be a data problem on the one test card
-- (Wuzu) that already had this ability, fixed at the bottom of this
-- migration: its saved row had trigger = 'PASSIVE' ("is on the field"),
-- not 'START_OF_TURN' ("the turn starts") -- two different real triggers
-- in the same dropdown. 'PASSIVE' is not an event cn_run_effects is ever
-- called with (advance_turn only fires START_OF_TURN/END_OF_TURN;
-- cn_attack only fires ON_ATTACK/ON_PARRY/ON_COUNTER/ON_DAMAGED/ON_DEATH/
-- IS_PARRIED); it means "compile this into a permanent card attribute"
-- instead, via cn_compile_card_effects -- and that compiler explicitly
-- does not compile POWER (see its own header: POWER is one of nine
-- stat_names "meaningful only as a RUNTIME MODIFY_STAT"). So the row
-- neither compiled nor ever dispatched -- it did nothing at all, additive
-- or not.
--
-- The requested split is worth having anyway: MODIFY_STAT has always
-- been a delta (it read the field's current value and added `value` to
-- it) without ever saying so, and there was no way to author "set this
-- to exactly N" at all. This migration:
--   1. Renames MODIFY_STAT's own client label to "changes stat by" (no
--      server change -- it was already additive; see AdminCards.tsx/
--      AdminStructures.tsx's ACTION_LABELS, shipped alongside this).
--   2. Adds SET_STAT: reads the same stat_name vocabulary (numeric fields,
--      boolean flags, and POWER's own pow/dmin/dmax trio) but ASSIGNS
--      `value` instead of adding it. For POWER specifically, it preserves
--      the card's current roll spread (half of dmax-dmin) around the new
--      absolute number, the same relationship cn_check_card establishes
--      at authoring time -- "sets power to 40" on a card with a 5-wide
--      spread becomes dmin 35/dmax 45, not a flat dmin=dmax=40.
--   3. Extends both action check constraints (card_effects,
--      structure_effects) to allow it, and both modify-stat-needs-name
--      constraints to require stat_name for it too.
--   4. Fixes Wuzu's own PASSIVE -> START_OF_TURN row so the ability the
--      screenshot showed actually runs.

alter table public.card_effects drop constraint card_effects_action_check;
alter table public.card_effects add constraint card_effects_action_check
  check (action = any (array[
    'DEAL_DAMAGE', 'HEAL', 'APPLY_STATUS', 'MODIFY_STAT', 'SET_STAT', 'PUSH_BACK',
    'DRAW_CARD', 'REMOVE_STATUS', 'GRANT_EXTRA_ACTIVATION', 'SUMMON_OBJECT',
    'TELEPORT_SELF', 'SWAP_POSITIONS', 'REVIVE', 'COPY_STAT_FROM_TARGET',
    'REFLECT_DAMAGE_PCT', 'CREATE_STRUCTURE', 'TRIGGER_PARRY', 'COUNTER_ATTACK_PCT'
  ]));

alter table public.card_effects drop constraint card_effects_modify_stat_needs_name;
alter table public.card_effects add constraint card_effects_modify_stat_needs_name
  check (action <> all (array['MODIFY_STAT', 'SET_STAT', 'COPY_STAT_FROM_TARGET'])
         or stat_name is not null);

alter table public.structure_effects drop constraint structure_effects_action_check;
alter table public.structure_effects add constraint structure_effects_action_check
  check (action = any (array[
    'DEAL_DAMAGE', 'HEAL', 'APPLY_STATUS', 'MODIFY_STAT', 'SET_STAT', 'PUSH_BACK',
    'REMOVE_STATUS', 'GRANT_EXTRA_ACTIVATION', 'COUNTER_ATTACK_PCT', 'DESTROY_SELF'
  ]));

alter table public.structure_effects drop constraint structure_effects_modify_stat_needs_name;
alter table public.structure_effects add constraint structure_effects_modify_stat_needs_name
  check (action <> all (array['MODIFY_STAT', 'SET_STAT']) or stat_name is not null);

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
  v_field text; v_copy_val jsonb; v_half int;
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
$$;

do $$
declare v_src text;
begin
  select prosrc into v_src from pg_proc where proname = 'cn_effect_apply_action';
  if v_src !~ '0109' then
    raise exception 'cn_effect_apply_action does not mention 0109 -- migration did not apply as expected';
  end if;
end $$;

-- Self-test 1: SET_STAT POWER assigns an absolute number and preserves
-- the card's existing spread (10 wide: dmin 15/dmax 25 -> half 5).
do $$
declare
  v_st jsonb; v_unit jsonb; v_effect jsonb; v_u jsonb;
begin
  v_unit := jsonb_build_object(
    'id', 'h1', 'owner', 'host', 'hp', 80, 'maxHp', 80,
    'pow', 20, 'dmin', 15, 'dmax', 25, 'x', 0, 'y', 0);
  v_st := jsonb_build_object('units', jsonb_build_array(v_unit));
  v_effect := jsonb_build_object('action', 'SET_STAT', 'stat_name', 'POWER', 'value', 40);

  v_st := cn_effect_apply_action(v_st, v_effect, v_unit, 'h1', '{}'::jsonb);
  select u into v_u from jsonb_array_elements(v_st->'units') u where u->>'id' = 'h1';
  if (v_u->>'pow')::int <> 40 or (v_u->>'dmin')::int <> 35 or (v_u->>'dmax')::int <> 45 then
    raise exception 'SET_STAT POWER: expected pow 40/dmin 35/dmax 45, got pow % dmin % dmax %',
      v_u->>'pow', v_u->>'dmin', v_u->>'dmax';
  end if;

  -- Firing it again with the SAME value must land on the SAME numbers --
  -- proof this assigns rather than accumulates, unlike MODIFY_STAT.
  v_st := cn_effect_apply_action(v_st, v_effect, v_u, 'h1', '{}'::jsonb);
  select u into v_u from jsonb_array_elements(v_st->'units') u where u->>'id' = 'h1';
  if (v_u->>'pow')::int <> 40 or (v_u->>'dmin')::int <> 35 or (v_u->>'dmax')::int <> 45 then
    raise exception 'SET_STAT POWER (repeat): expected still pow 40/dmin 35/dmax 45, got pow % dmin % dmax %',
      v_u->>'pow', v_u->>'dmin', v_u->>'dmax';
  end if;
  raise notice '0109 self-test 1 passed: SET_STAT POWER assigns and does not stack on repeat.';
end $$;

-- Self-test 2: SET_STAT on a generic numeric field (RMAX) assigns
-- regardless of the current value; MODIFY_STAT on the same field still
-- adds, unaffected by this migration.
do $$
declare
  v_st jsonb; v_unit jsonb; v_u jsonb;
begin
  v_unit := jsonb_build_object(
    'id', 'h1', 'owner', 'host', 'hp', 80, 'maxHp', 80, 'rmax', 1, 'x', 0, 'y', 0);
  v_st := jsonb_build_object('units', jsonb_build_array(v_unit));

  v_st := cn_effect_apply_action(v_st,
    jsonb_build_object('action', 'SET_STAT', 'stat_name', 'RMAX', 'value', 3),
    v_unit, 'h1', '{}'::jsonb);
  select u into v_u from jsonb_array_elements(v_st->'units') u where u->>'id' = 'h1';
  if (v_u->>'rmax')::int <> 3 then
    raise exception 'SET_STAT RMAX: expected 3, got %', v_u->>'rmax';
  end if;

  v_st := cn_effect_apply_action(v_st,
    jsonb_build_object('action', 'MODIFY_STAT', 'stat_name', 'RMAX', 'value', 2),
    v_u, 'h1', '{}'::jsonb);
  select u into v_u from jsonb_array_elements(v_st->'units') u where u->>'id' = 'h1';
  if (v_u->>'rmax')::int <> 5 then
    raise exception 'MODIFY_STAT RMAX after SET_STAT: expected 5 (3+2), got %', v_u->>'rmax';
  end if;
  raise notice '0109 self-test 2 passed: SET_STAT assigns, MODIFY_STAT still adds, on the same field.';
end $$;

-- Self-test 3: SET_STAT on a boolean flag (SLIPPERY) assigns the flag.
do $$
declare
  v_st jsonb; v_unit jsonb; v_u jsonb;
begin
  v_unit := jsonb_build_object(
    'id', 'h1', 'owner', 'host', 'hp', 80, 'maxHp', 80, 'slippery', false, 'x', 0, 'y', 0);
  v_st := jsonb_build_object('units', jsonb_build_array(v_unit));

  v_st := cn_effect_apply_action(v_st,
    jsonb_build_object('action', 'SET_STAT', 'stat_name', 'SLIPPERY', 'value', 1),
    v_unit, 'h1', '{}'::jsonb);
  select u into v_u from jsonb_array_elements(v_st->'units') u where u->>'id' = 'h1';
  if (v_u->>'slippery')::boolean <> true then
    raise exception 'SET_STAT SLIPPERY: expected true, got %', v_u->>'slippery';
  end if;
  raise notice '0109 self-test 3 passed: SET_STAT assigns a boolean flag.';
end $$;

-- Data fix: Wuzu's own row -- "the turn starts" (START_OF_TURN), not
-- "is on the field" (PASSIVE), which is what actually made 0108's fix
-- invisible: the row never dispatched at all under the wrong trigger.
update public.card_effects
   set trigger = 'START_OF_TURN'
 where id = '3a0f6365-7083-4126-b4d4-ea9789a6411f'
   and trigger = 'PASSIVE' and action = 'MODIFY_STAT' and stat_name = 'POWER';

do $$
declare v_trigger text;
begin
  select trigger into v_trigger from public.card_effects
   where id = '3a0f6365-7083-4126-b4d4-ea9789a6411f';
  if v_trigger <> 'START_OF_TURN' then
    raise exception 'Wuzu''s POWER row is still % -- data fix did not apply', v_trigger;
  end if;
  raise notice '0109 data fix confirmed: Wuzu''s POWER passive now fires on START_OF_TURN.';
end $$;
