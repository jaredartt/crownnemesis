-- ===========================================================================
--  HOW TO RUN THIS
--  Already applied live (via the Supabase MCP, migration name
--  `structure_self_destruct`) -- this file exists so the change has a
--  normal migration history entry in the repo. If you ever DO need to run
--  it by hand: Supabase dashboard -> SQL Editor -> New query -> paste this
--  whole file -> Run. Safe to run twice -- the ALTER TABLE blocks drop
--  their own constraint before re-adding it, and the CREATE OR REPLACE
--  FUNCTION blocks just replace a function body.
-- ===========================================================================
--  structure_self_destruct
--
--  Jared built a custom "Bomb" structure (deal 30 damage + apply Burning on
--  ON_STEPPED_ON) and noticed it never goes away -- it's a permanent
--  re-triggering hazard, not a one-shot mine, because the structure-effects
--  builder had no action that removes the structure itself. He wasn't
--  bothered by Bomb specifically staying that way, but asked, directly, for
--  the underlying capability to exist: "Yes, build it."
--
--  Adds two new pieces of Mad-Libs vocabulary to structure_effects, mirroring
--  the shape of the existing INVOKER/WHOEVER_STEPPED target and TRIGGER_PARRY
--  action (see 0074's header for that one -- a pure verb, no extra fields):
--
--  SELF (target_selector, label "it") -- resolves to the triggering
--  structure's own id. Handled in cn_resolve_structure_targets exactly like
--  its INVOKER/WHOEVER_STEPPED neighbours, before falling through to the
--  generic fake-unit resolver.
--
--  DESTROY_SELF (action, label "destroys itself") -- removes the structure
--  from state.obstacles. Authored together on a structure's ON_STEPPED_ON
--  effect this reads "When is stepped on then it destroys itself", addable
--  as a third "and" clause after the existing damage/status rows -- turning
--  a structure like Bomb into a true one-shot trap, if and when Jared wants
--  that (this migration does NOT touch Bomb's own live effect rows -- it
--  only adds the capability to the builder; verified against a hand-built
--  scratch board and against Bomb's own real effect rows fed through
--  cn_run_structure_effects, then rolled back -- see "Did it work?" below).
--
--  cn_effect_apply_action's DESTROY_SELF branch is placed BEFORE the
--  units-array lookup (the `if v_target is null then return v_st; end if;`
--  bailout): the structure's own id is never going to be found scanning
--  v_st->'units', so without this the branch would always hit that bailout
--  first and never run. It filters p_unit (== the invoking structure when
--  called from the structures path -- cn_run_structure_effects passes
--  p_structure straight through as p_unit) out of v_st->'obstacles' by id,
--  using the same rebuild-and-filter idiom the legacy cn_spring trap and
--  cn_attack's own destruction path already use. It ignores p_target_id
--  entirely and always removes p_unit's own id, so it stays correct even if
--  a designer picks a different target_selector by mistake -- SELF is just
--  the one that actually makes sense to pair it with. Naturally a no-op if
--  p_unit isn't in obstacles at all (e.g. some future non-structure caller):
--  the filter just keeps every entry that isn't a match.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Schema: extend the two check constraints, preserving every existing
--    allowed value exactly.
-- ---------------------------------------------------------------------------
alter table public.structure_effects drop constraint structure_effects_target_selector_check;
alter table public.structure_effects add constraint structure_effects_target_selector_check
  check (target_selector = ANY (ARRAY[
    'INVOKER', 'WHOEVER_STEPPED', 'ALL_ALLIES', 'ALL_ENEMIES', 'NEARBY_ALLIES',
    'ADJACENT_UNITS', 'NEAREST_ENEMY', 'LOWEST_HP_ENEMY', 'HIGHEST_HP_ENEMY',
    'LOWEST_HP_ALLY', 'HIGHEST_HP_ALLY', 'RANDOM_ENEMY_IN_RANGE', 'RANDOM_ALLY',
    'ALLIES_IN_LINE', 'ENEMIES_IN_LINE', 'THE_ATTACKER',
    'SELF'
  ]));

alter table public.structure_effects drop constraint structure_effects_action_check;
alter table public.structure_effects add constraint structure_effects_action_check
  check (action = ANY (ARRAY[
    'DEAL_DAMAGE', 'HEAL', 'APPLY_STATUS', 'MODIFY_STAT', 'PUSH_BACK',
    'REMOVE_STATUS', 'GRANT_EXTRA_ACTIVATION', 'COUNTER_ATTACK_PCT',
    'DESTROY_SELF'
  ]));

-- ---------------------------------------------------------------------------
-- 2. cn_resolve_structure_targets -- add the SELF branch.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cn_resolve_structure_targets(v_st jsonb, p_selector text, p_structure jsonb, p_context jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  v_owner text := p_structure->>'owner';
  v_fake_unit jsonb;
begin
  if p_selector = 'INVOKER' then
    return case when exists (
             select 1 from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) u
              where u->>'id' = p_structure->>'by')
           then jsonb_build_array(p_structure->>'by') else '[]'::jsonb end;
  elsif p_selector = 'WHOEVER_STEPPED' then
    return case when p_context->'unit'->>'id' is not null
                then jsonb_build_array(p_context->'unit'->>'id') else '[]'::jsonb end;
  elsif p_selector = 'SELF' then
    -- 0093: the triggering structure's own id -- what DESTROY_SELF (and any
    -- future self-targeting structure action) resolves against. See
    -- cn_effect_apply_action's own DESTROY_SELF branch.
    return jsonb_build_array(p_structure->>'id');
  end if;

  -- Every other selector this table offers is one cn_resolve_targets
  -- already knows how to answer for a UNIT standing at a given x/y with a
  -- given owner -- which is exactly what a structure is, for this
  -- purpose. Building a one-field-used fake unit is less code and less
  -- risk than a second copy of eleven target-selector branches that would
  -- only ever drift from the real ones.
  v_fake_unit := jsonb_build_object(
    'id', p_structure->>'id', 'owner', coalesce(v_owner, ''),
    'x', p_structure->'x', 'y', p_structure->'y');
  return cn_resolve_targets(v_st, p_selector, v_fake_unit, p_context);
end
$function$;

-- ---------------------------------------------------------------------------
-- 3. cn_effect_apply_action -- add the DESTROY_SELF branch, before the
--    units-array lookup. Full body (create-or-replace), not a diff.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cn_effect_apply_action(v_st jsonb, p_effect jsonb, p_unit jsonb, p_target_id text, p_context jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  v_action text := p_effect->>'action';
  v_value int := coalesce((p_effect->>'value')::int, 0);
  v_status text := p_effect->>'status';
  v_stat text := p_effect->>'stat_name';
  v_self_id text := p_unit->>'id';
  v_self jsonb; v_target jsonb; v_out jsonb; u jsonb;
  v_tile int[]; v_dx int; v_dy int; v_nx int; v_ny int; v_occupied boolean;
  v_field text; v_copy_val jsonb;
  v_num_field_map jsonb := '{
    "HP": "hp", "MOV": "mov", "RMIN": "rmin", "RMAX": "rmax",
    "CRMIN": "crmin", "CRMAX": "crmax", "POWER": "pow",
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
    -- 0057: CREATE_STRUCTURE reads a tile like TELEPORT_SELF always has,
    -- but does something else with it entirely -- see cn_create_structure
    -- for the tile/occupancy checks and what actually gets placed.
    -- 0074: SUMMON_OBJECT is CREATE_STRUCTURE under a second name -- both
    -- read the row's own structure_slug and place that catalog structure;
    -- see the client-side vocabulary for why two words exist for one
    -- mechanic.
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

  -- 0074: REVIVE reads a graveyard reference ('#<dead unit id>', the same
  -- kind of synthetic id the '@x,y' tile convention above already is for a
  -- different family of targets) rather than a live board unit id -- see
  -- cn_resolve_targets' LAST_DEAD_ALLY branch for where the '#' prefix is
  -- built, and cn_revive's own header for what happens with it.
  if left(p_target_id, 1) = '#' then
    if v_action <> 'REVIVE' then return v_st; end if;
    return cn_revive(v_st, p_effect, p_unit, substr(p_target_id, 2));
  end if;

  -- DRAW_CARD is a documented no-op -- there is no in-match hand or
  -- deck-draw mechanic anywhere in this game (a kingdom's whole army
  -- deploys once, at the start of a match), and Jared asked for it dropped
  -- from the builder's offered vocabulary rather than have a card-drawing
  -- feature invented to give it something to do. Left accepted by the
  -- schema for backward compatibility only -- see card_effects.action's own
  -- column comment.
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

    -- 0074: TRIGGER_PARRY -- sets a one-shot flag cn_attack's own swing loop
    -- reads and consumes the next time this unit is the one receiving a
    -- blow. No numeric value; see SentenceBuilder's NO_VALUE_ACTIONS.
    elsif u->>'id' = p_target_id and v_action = 'TRIGGER_PARRY' then
      u := jsonb_set(u, '{forcedParry}', 'true'::jsonb);

    -- 0074: REFLECT_DAMAGE_PCT (a card giving back a share of the damage it
    -- just received, fired from ON_DAMAGED) and COUNTER_ATTACK_PCT (the
    -- same math for a structure striking back at whoever just destroyed it,
    -- fired from ON_DESTROYED) are the same mechanic under two names for
    -- two different kinds of thing -- both read p_context->>'damage' (set
    -- by whichever caller dispatched this trigger) and deal value% of it to
    -- the resolved target.
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
-- Did it work?
-- ---------------------------------------------------------------------------
-- select conname, pg_get_constraintdef(oid) from pg_constraint
--  where conrelid = 'public.structure_effects'::regclass and contype = 'c'
--    and conname in ('structure_effects_target_selector_check', 'structure_effects_action_check');
-- Both defs should list every value they listed before, plus 'SELF' /
-- 'DESTROY_SELF' respectively.
--
-- Proven two ways when this migration was written (both against scratch/
-- disposable state, never against a real match):
--
-- 1. A hand-built scratch state, isolated:
--   select cn_effect_apply_action(
--     '{"obstacles":[{"id":"s1","x":0,"y":0}],"units":[]}'::jsonb,
--     '{"action":"DESTROY_SELF"}'::jsonb,
--     '{"id":"s1","x":0,"y":0}'::jsonb,
--     's1', '{}'::jsonb
--   ) -> 'obstacles';
-- Returns '[]'.
--
-- 2. End-to-end, against Bomb's own real effect rows (a temporary third
--    ON_STEPPED_ON row -- SELF/DESTROY_SELF -- was inserted into Bomb's
--    existing group_id, exercised, then deleted again -- Bomb's live
--    effects are unchanged by this migration):
--   select cn_run_structure_effects(
--     '{"units":[{"id":"u1","owner":"guest","x":0,"y":1,"hp":50,"maxHp":50}],
--       "obstacles":[{"id":"bomb1","kind":"bomb","x":0,"y":0}],
--       "board":{"w":5,"h":5}}'::jsonb,
--     'ON_STEPPED_ON',
--     '{"id":"bomb1","kind":"bomb","x":0,"y":0}'::jsonb,
--     '{"unit":{"id":"u1"}}'::jsonb
--   );
-- Returned u1 at 20 hp (30 damage) with burn:true, and an EMPTY obstacles
-- array -- the bomb destroyed itself on the same step that hurt whoever
-- triggered it.
