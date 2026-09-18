-- 0074_not_built_yet_actions.sql
--
-- Builds every action in the soft-code card/structure builder that was
-- still labelled "(not built yet)": REVIVE, REFLECT_DAMAGE_PCT,
-- SUMMON_OBJECT, and TRIGGER_PARRY for cards, plus COUNTER_ATTACK_PCT for
-- structures. Drops DRAW_CARD and cards' own COUNTER_ATTACK_PCT from the
-- OFFERED vocabulary (client-side only, see AdminCards.tsx) rather than
-- building them -- per Jared, directly: this game has no in-match hand/
-- deck-draw mechanic for DRAW_CARD to mean anything, and a unit already
-- counter-attacks unconditionally whenever it is in range, which is what
-- made an authored COUNTER_ATTACK_PCT redundant on a CARD specifically (a
-- structure has no such automatic retaliation, so it keeps the action and
-- gets it built for real here).
--
-- Also adds a per-condition "and not" negate flag to the sentence builder's
-- if-chain (client request, folded in alongside), and closes a real,
-- pre-existing gap found while building REVIVE: a unit killed by a scripted
-- action (cn_effect_apply_action's own DEAL_DAMAGE/REFLECT_DAMAGE_PCT/
-- COUNTER_ATTACK_PCT branches, not just cn_attack's swing loop) was
-- silently dropped from the board with no ON_DEATH firing and nothing
-- recording that it ever existed -- see cn_bury below.
--
-- WHAT EACH ONE ACTUALLY DOES:
--
-- TRIGGER_PARRY -- sets a one-shot forcedParry flag on the resolved target.
-- cn_attack's swing-loop parry roll (v_parried) now reads it: a unit
-- carrying the flag catches its very next incoming blow for certain, the
-- same as a natural roll landing, and the flag is consumed the instant it
-- does. Scoped to 1v1's cn_attack only -- royale has no ability engine at
-- all yet (a pre-existing, already-documented gap, not new here).
--
-- REFLECT_DAMAGE_PCT / COUNTER_ATTACK_PCT -- literally the same math
-- (value% of a 'damage' figure carried on the trigger's own context, dealt
-- to the resolved target) under two names for two different kinds of
-- thing. REFLECT_DAMAGE_PCT is a card's own new ON_DAMAGED hookpoint
-- (cn_attack fires it, additively, right where ON_ATTACK/ON_PARRY/ON_DEATH
-- already fire, for whichever side took real damage from the OTHER side's
-- own blows this exchange -- burn cost is deliberately excluded, since
-- nobody dealt that damage TO you). COUNTER_ATTACK_PCT is a structure's
-- existing ON_DESTROYED trigger, which now also carries 'damage' (the exact
-- blow that destroyed it) for the same math to read.
--
-- SUMMON_OBJECT -- turned out, on inspection with Jared, to already BE
-- CREATE_STRUCTURE (0057): both read the row's own structure_slug and place
-- that catalog structure. cn_effect_apply_action now dispatches both
-- action names to the same cn_create_structure call. The builder had no UI
-- control to actually PICK a structure_slug for either one before this
-- migration -- a real, separate gap, fixed client-side alongside this file
-- (see SentenceBuilder.tsx/AdminCards.tsx's own diffs).
--
-- REVIVE -- Jared asked for the broader version (any dead ally, not just a
-- card reviving itself) rather than the narrower one. New per-side
-- graveyard on match state (state.graveyard.host/guest, an array of dead
-- unit snapshots, capped at the 8 most recent -- see cn_bury), populated
-- every time a unit dies, in cn_attack's own two death branches AND in
-- cn_effect_apply_action's death filter (so a scripted kill buries too, not
-- only a swing-loop one). A new target_selector, LAST_DEAD_ALLY, resolves
-- to a synthetic '#<id>' reference into the acting unit's own side's
-- graveyard -- the graveyard's equivalent of the '@x,y' tile convention
-- TELEPORT_SELF/CREATE_STRUCTURE already use. cn_revive pulls that snapshot
-- back onto an empty tile adjacent to the reviving unit, at value% of its
-- own max HP (a required 1-100 value, enforced by a new check constraint),
-- with a clean status slate and a fresh turn. No room next to the reviver
-- -- REVIVE silently no-ops, the same "no room, nothing happens" convention
-- CREATE_STRUCTURE/cn_revive-adjacent code already uses throughout this
-- engine. LAST_DEAD_ALLY correctly means "myself, just now" for a
-- trigger=ON_DEATH/target=SELF-style self-revive too: a side's own
-- graveyard can only ever have gained the unit whose own ON_DEATH script is
-- now running, in the very same cn_attack call.
--
-- "and not" -- a per-condition negate flag folded into the SAME open
-- conditions jsonb every row already had (no schema/column change:
-- {field,op,value} was never a closed shape). cn_effect_conditions_met
-- flips one condition's result when its row carries {"negate": true}; every
-- other condition in the AND-chain is untouched. Client: SentenceBuilder's
-- "if"/"and" connector word becomes a two-option pill ("if"/"if not",
-- "and"/"and not").
--
-- Every splice into cn_attack/cn_effect_apply_action/cn_resolve_targets/
-- cn_effect_conditions_met below was fetched fresh via pg_get_functiondef
-- from a local replay of 0001-0073 (byte-identical to the live project,
-- confirmed against list_migrations before writing this file) and applied
-- with str.replace() against a unique anchor, verified programmatically --
-- this project's own established discipline for touching cn_attack, the
-- single most order-sensitive function in the codebase.

-- ============================================================================
-- 1. SCHEMA
-- ============================================================================

alter table public.card_effects drop constraint card_effects_target_selector_check;
alter table public.card_effects add constraint card_effects_target_selector_check
  check (target_selector = any (array[
    'SELF', 'NEARBY_ALLIES', 'ALL_ALLIES', 'ENEMY_IN_RANGE', 'LOWEST_HP_ENEMY',
    'BOARD_CELL', 'ALL_ENEMIES', 'NEAREST_ENEMY', 'HIGHEST_HP_ENEMY',
    'LOWEST_HP_ALLY', 'HIGHEST_HP_ALLY', 'RANDOM_ENEMY_IN_RANGE', 'RANDOM_ALLY',
    'ALLIES_IN_LINE', 'ENEMIES_IN_LINE', 'THE_ATTACKER', 'THE_TARGET',
    'ADJACENT_UNITS',
    -- 0074: REVIVE's own selector -- see cn_resolve_targets below.
    'LAST_DEAD_ALLY'
  ]));

-- 0074: REVIVE's value is not optional flavor text the way DEAL_DAMAGE's
-- is -- it is what % of max HP the revived unit comes back with, and
-- cn_revive has no sane default to fall back on the way a flat-damage
-- action might. Mirrors card_effects_counter_attack_pct_check's own shape.
alter table public.card_effects add constraint card_effects_revive_value_check
  check (action <> 'REVIVE' or (value is not null and value between 1 and 100));

-- 0074: SUMMON_OBJECT is now CREATE_STRUCTURE under a second name (see
-- cn_effect_apply_action below) and needs a structure_slug for exactly the
-- same reason CREATE_STRUCTURE already does -- without one,
-- cn_create_structure silently no-ops (v_slug is null there) and the row
-- looks saved but never places anything. Widening the EXISTING constraint
-- rather than adding a second one, so there is one place this rule lives.
alter table public.card_effects drop constraint card_effects_create_structure_needs_slug;
alter table public.card_effects add constraint card_effects_create_structure_needs_slug
  check (action not in ('CREATE_STRUCTURE', 'SUMMON_OBJECT') or structure_slug is not null);

-- 0074: structures' COUNTER_ATTACK_PCT strikes back at THE_ATTACKER (the
-- unit that just destroyed it) -- see cn_resolve_structure_targets, which
-- already falls through to cn_resolve_targets for any selector it doesn't
-- special-case itself, and cn_resolve_targets already knows THE_ATTACKER.
-- Structures never offered it before because nothing here needed it before
-- COUNTER_ATTACK_PCT was real.
alter table public.structure_effects drop constraint structure_effects_target_selector_check;
alter table public.structure_effects add constraint structure_effects_target_selector_check
  check (target_selector = any (array[
    'INVOKER', 'WHOEVER_STEPPED', 'ALL_ALLIES', 'ALL_ENEMIES', 'NEARBY_ALLIES',
    'ADJACENT_UNITS', 'NEAREST_ENEMY', 'LOWEST_HP_ENEMY', 'HIGHEST_HP_ENEMY',
    'LOWEST_HP_ALLY', 'HIGHEST_HP_ALLY', 'RANDOM_ENEMY_IN_RANGE', 'RANDOM_ALLY',
    'ALLIES_IN_LINE', 'ENEMIES_IN_LINE',
    'THE_ATTACKER'
  ]));

-- ============================================================================
-- 2. NEW FUNCTIONS -- the graveyard
-- ============================================================================

-- Appends a unit snapshot to its own side's graveyard on match state,
-- capping it at the 8 most recent so a long match can't grow this without
-- bound. Called from every place a unit is removed from v_st.units for
-- dying: cn_attack's own two death branches, and cn_effect_apply_action's
-- shared death filter (so a scripted kill -- REFLECT_DAMAGE_PCT,
-- COUNTER_ATTACK_PCT, a future DEAL_DAMAGE effect -- buries too, not only a
-- swing-loop one). Deliberately NOT called from wherever poison/burn ticks
-- kill a unit in advance_turn -- a real, stated gap, not silently missed:
-- see this migration's own header.
create or replace function public.cn_bury(v_st jsonb, u jsonb)
returns jsonb
language plpgsql
set search_path to 'public'
as $function$
declare
  v_owner text := u->>'owner';
  v_arr jsonb;
begin
  if v_owner is null or v_owner not in ('host', 'guest') then return v_st; end if;
  v_st := jsonb_set(v_st, '{graveyard}', coalesce(v_st->'graveyard', '{}'::jsonb), true);
  v_arr := coalesce(v_st->'graveyard'->v_owner, '[]'::jsonb) || jsonb_build_array(u);
  if jsonb_array_length(v_arr) > 8 then
    v_arr := v_arr - 0;
  end if;
  return jsonb_set(v_st, array['graveyard', v_owner], v_arr, true);
end
$function$;

-- REVIVE's own worker, called from cn_effect_apply_action's '#' branch.
-- p_dead_id is a graveyard entry's own unit id (the '#' prefix already
-- stripped by the caller). Finds it in whichever side's graveyard holds it,
-- places it on an empty, in-bounds, unblocked tile adjacent to the
-- reviving unit (p_unit) at p_effect's own value% of its max HP, with a
-- clean status slate and a fresh turn -- and silently no-ops, the unit
-- staying gone, if there is no such tile or no such dead unit. That silent-
-- failure shape matches every other placement guard already in this engine
-- (cn_create_structure, TELEPORT_SELF's occupancy check, PUSH_BACK's own).
create or replace function public.cn_revive(v_st jsonb, p_effect jsonb, p_unit jsonb, p_dead_id text)
returns jsonb
language plpgsql
set search_path to 'public'
as $function$
declare
  v_pct int := greatest(1, least(100, coalesce((p_effect->>'value')::int, 50)));
  v_side text; v_arr jsonb; v_found jsonb; v_i int;
  v_ox int := (p_unit->>'x')::int; v_oy int := (p_unit->>'y')::int;
  v_w int := coalesce((v_st->'board'->>'w')::int, 0);
  v_h int := coalesce((v_st->'board'->>'h')::int, 0);
  v_dx int; v_dy int; v_nx int; v_ny int; v_tile_ok boolean := false;
  v_new jsonb;
begin
  foreach v_side in array array['host', 'guest'] loop
    v_arr := coalesce(v_st->'graveyard'->v_side, '[]'::jsonb);
    for v_i in 0 .. jsonb_array_length(v_arr) - 1 loop
      if v_arr->v_i->>'id' = p_dead_id then
        v_found := v_arr->v_i;
        v_st := jsonb_set(v_st, array['graveyard', v_side], v_arr - v_i);
        exit;
      end if;
    end loop;
    exit when v_found is not null;
  end loop;
  if v_found is null then return v_st; end if;

  <<search>>
  for v_dy in -1..1 loop
    for v_dx in -1..1 loop
      continue when v_dx = 0 and v_dy = 0;
      v_nx := v_ox + v_dx;
      v_ny := v_oy + v_dy;
      continue when v_nx < 0 or v_ny < 0 or v_nx >= v_w or v_ny >= v_h;
      continue when exists (select 1 from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) q
                              where (q->>'x')::int = v_nx and (q->>'y')::int = v_ny);
      continue when exists (select 1 from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) q
                              where (q->>'x')::int = v_nx and (q->>'y')::int = v_ny
                                and cn_obj_solid(cn_obj_kind(q)));
      v_tile_ok := true;
      v_new := jsonb_set(jsonb_set(v_found, '{x}', to_jsonb(v_nx)), '{y}', to_jsonb(v_ny));
      exit search;
    end loop;
  end loop search;
  if not v_tile_ok then return v_st; end if;

  v_new := jsonb_set(v_new, '{hp}',
    to_jsonb(greatest(1, round((v_new->>'maxHp')::numeric * v_pct / 100.0)::int)));
  v_new := jsonb_set(v_new, '{acted}', 'false'::jsonb);
  v_new := jsonb_set(v_new, '{moved}', 'false'::jsonb);
  v_new := jsonb_set(v_new, '{spent}', 'false'::jsonb);
  v_new := jsonb_set(v_new, '{forcedParry}', 'false'::jsonb);
  v_new := jsonb_set(v_new, '{effects}', cn_no_effects(), true);

  v_st := jsonb_set(v_st, '{units}', coalesce(v_st->'units', '[]'::jsonb) || jsonb_build_array(v_new));
  v_st := state_log(v_st, (v_new->>'name') || ' returns to the battle.');
  return v_st;
end
$function$;

-- ============================================================================
-- 3. SPLICED FUNCTIONS -- fetched fresh, edited additively, see header
-- ============================================================================

-- cn_resolve_targets: LAST_DEAD_ALLY
CREATE OR REPLACE FUNCTION public.cn_resolve_targets(v_st jsonb, p_selector text, p_unit jsonb, p_context jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  v_out jsonb := '[]'::jsonb;
  v_candidates jsonb := '[]'::jsonb;
  u jsonb; v_owner text; v_dist int; v_ux int; v_uy int;
  v_best_id text; v_best_val int; v_count int; v_idx int;
begin
  v_owner := p_unit->>'owner';
  v_ux := (p_unit->>'x')::int;
  v_uy := (p_unit->>'y')::int;

  if p_selector = 'SELF' then
    return jsonb_build_array(p_unit->>'id');
  elsif p_selector = 'THE_ATTACKER' then
    return case when p_context->'attacker'->>'id' is not null
                then jsonb_build_array(p_context->'attacker'->>'id') else '[]'::jsonb end;
  elsif p_selector = 'THE_TARGET' then
    return case when p_context->'target'->>'id' is not null
                then jsonb_build_array(p_context->'target'->>'id') else '[]'::jsonb end;
  elsif p_selector = 'BOARD_CELL' then
    -- The one selector with no unit id: the caller supplies the tile
    -- reference directly (the same '@x,y' form cn_tile_target reads), and
    -- only TELEPORT_SELF knows what to do with it -- see
    -- cn_effect_apply_action.
    return case when coalesce(p_context->>'tile', '') <> ''
                then jsonb_build_array(p_context->>'tile') else '[]'::jsonb end;
  elsif p_selector = 'LAST_DEAD_ALLY' then
    -- 0074: REVIVE's own selector -- the most recently dead unit on the
    -- acting unit's own side, read straight from the graveyard cn_bury
    -- maintains rather than scanned for on the (live-units-only) board
    -- below. Returns a '#<id>' synthetic target, the graveyard's own
    -- equivalent of the '@x,y' tile convention just above -- see
    -- cn_effect_apply_action's '#' branch for what happens with it. Works
    -- for both an ally-revive effect and a self-revive-on-death one: a
    -- side's own graveyard can only ever have gained the dying unit itself
    -- in the same cn_attack call that is now dispatching its ON_DEATH
    -- script, so "the last ally who died" and "me, just now" are the same
    -- entry when they coincide.
    return case when jsonb_array_length(coalesce(v_st->'graveyard'->v_owner, '[]'::jsonb)) > 0
                then jsonb_build_array('#' ||
                  (v_st->'graveyard'->v_owner->(jsonb_array_length(v_st->'graveyard'->v_owner) - 1)->>'id'))
                else '[]'::jsonb end;
  end if;

  for u in select * from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) loop
    continue when (u->>'hp')::int <= 0;
    v_dist := cn_cheb(v_ux, v_uy, (u->>'x')::int, (u->>'y')::int);

    if p_selector = 'NEARBY_ALLIES' then
      if u->>'owner' = v_owner and u->>'id' <> p_unit->>'id' and v_dist = 1 then
        v_out := v_out || to_jsonb(u->>'id');
      end if;
    elsif p_selector = 'ALL_ALLIES' then
      if u->>'owner' = v_owner then v_out := v_out || to_jsonb(u->>'id'); end if;
    elsif p_selector = 'ALL_ENEMIES' then
      if u->>'owner' <> v_owner then v_out := v_out || to_jsonb(u->>'id'); end if;
    elsif p_selector = 'ADJACENT_UNITS' then
      if u->>'id' <> p_unit->>'id' and v_dist = 1 then v_out := v_out || to_jsonb(u->>'id'); end if;
    elsif p_selector = 'ENEMY_IN_RANGE' then
      if u->>'owner' <> v_owner and v_dist >= coalesce((p_unit->>'rmin')::int, 1)
         and v_dist <= coalesce((p_unit->>'rmax')::int, 1) then
        v_out := v_out || to_jsonb(u->>'id');
      end if;
    elsif p_selector = 'RANDOM_ENEMY_IN_RANGE' then
      if u->>'owner' <> v_owner and v_dist >= coalesce((p_unit->>'rmin')::int, 1)
         and v_dist <= coalesce((p_unit->>'rmax')::int, 1) then
        v_candidates := v_candidates || to_jsonb(u->>'id');
      end if;
    elsif p_selector = 'RANDOM_ALLY' then
      if u->>'owner' = v_owner and u->>'id' <> p_unit->>'id' then
        v_candidates := v_candidates || to_jsonb(u->>'id');
      end if;
    elsif p_selector in ('LOWEST_HP_ENEMY', 'HIGHEST_HP_ENEMY') then
      if u->>'owner' <> v_owner then
        if v_best_id is null
           or (p_selector = 'LOWEST_HP_ENEMY' and (u->>'hp')::int < v_best_val)
           or (p_selector = 'HIGHEST_HP_ENEMY' and (u->>'hp')::int > v_best_val) then
          v_best_id := u->>'id'; v_best_val := (u->>'hp')::int;
        end if;
      end if;
    elsif p_selector in ('LOWEST_HP_ALLY', 'HIGHEST_HP_ALLY') then
      if u->>'owner' = v_owner and u->>'id' <> p_unit->>'id' then
        if v_best_id is null
           or (p_selector = 'LOWEST_HP_ALLY' and (u->>'hp')::int < v_best_val)
           or (p_selector = 'HIGHEST_HP_ALLY' and (u->>'hp')::int > v_best_val) then
          v_best_id := u->>'id'; v_best_val := (u->>'hp')::int;
        end if;
      end if;
    elsif p_selector = 'NEAREST_ENEMY' then
      if u->>'owner' <> v_owner then
        if v_best_id is null or v_dist < v_best_val then
          v_best_id := u->>'id'; v_best_val := v_dist;
        end if;
      end if;
    elsif p_selector = 'ALLIES_IN_LINE' then
      if u->>'owner' = v_owner and u->>'id' <> p_unit->>'id'
         and ((u->>'x')::int = v_ux or (u->>'y')::int = v_uy
              or abs((u->>'x')::int - v_ux) = abs((u->>'y')::int - v_uy)) then
        v_out := v_out || to_jsonb(u->>'id');
      end if;
    elsif p_selector = 'ENEMIES_IN_LINE' then
      if u->>'owner' <> v_owner
         and ((u->>'x')::int = v_ux or (u->>'y')::int = v_uy
              or abs((u->>'x')::int - v_ux) = abs((u->>'y')::int - v_uy)) then
        v_out := v_out || to_jsonb(u->>'id');
      end if;
    end if;
  end loop;

  if p_selector in ('LOWEST_HP_ENEMY', 'HIGHEST_HP_ENEMY', 'LOWEST_HP_ALLY',
                     'HIGHEST_HP_ALLY', 'NEAREST_ENEMY') and v_best_id is not null then
    v_out := jsonb_build_array(v_best_id);
  elsif p_selector in ('RANDOM_ENEMY_IN_RANGE', 'RANDOM_ALLY') then
    v_count := jsonb_array_length(v_candidates);
    if v_count > 0 then
      v_idx := floor(random() * v_count)::int;
      v_out := jsonb_build_array(v_candidates->v_idx);
    end if;
  end if;

  return v_out;
end
$function$;

-- cn_effect_conditions_met: "and not"
CREATE OR REPLACE FUNCTION public.cn_effect_conditions_met(p_conditions jsonb, p_ctx jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare v_cond jsonb; v_result boolean;
begin
  if p_conditions is null or jsonb_typeof(p_conditions) <> 'array' then return true; end if;
  for v_cond in select * from jsonb_array_elements(p_conditions) loop
    v_result := cn_effect_condition_met(v_cond, p_ctx);
    -- 0074: "and not" -- a per-condition negate flag living in the same
    -- open conditions jsonb every row already had (no new column: 'field'/
    -- 'op'/'value' were never the whole schema, just the whole vocabulary
    -- until now). Flips this ONE condition's result; every other condition
    -- in the AND-chain is untouched.
    if coalesce((v_cond->>'negate')::boolean, false) then
      v_result := not v_result;
    end if;
    if not v_result then return false; end if;
  end loop;
  return true;
end
$function$;

-- cn_effect_apply_action: TRIGGER_PARRY, REFLECT_DAMAGE_PCT/COUNTER_ATTACK_PCT,
-- SUMMON_OBJECT==CREATE_STRUCTURE, REVIVE's '#' branch, DRAW_CARD-only no-op,
-- burial on death.
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

-- cn_attack: forced-parry roll+consume, forcedParry/graveyard carried through
-- the rebuild loop, ON_DAMAGED, ON_DESTROYED's 'damage'.
CREATE OR REPLACE FUNCTION public.cn_attack(p_match uuid, p_side text, p_unit text, p_target text)
 RETURNS matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  -- 0045: crit/parry counters, single-class team check, and bot-win credit.
  v_elem jsonb; v_by text; v_by_owner text; v_by_uid uuid;
  v_win_uid uuid; v_win_count int; v_win_roles text[];
  -- 0049: new-engine attack hooks.
  v_ce_unit jsonb; v_ce_id text;
  -- 0058: PARRY VOCABULARY -- IS_PARRIED's own unit/id (the mirror of
  -- v_ce_unit/v_ce_id above: whoever's blow got caught, not whoever caught
  -- it), and ON_COUNTER's own unit/id (whoever landed a counter-hit).
  v_pd_unit jsonb; v_pd_id text; v_co_unit jsonb; v_co_id text;
  -- 0059: EVASION -- rolled once, before the exchange starts. See
  -- 0059_evasion.sql's header for why this is a single roll rather than a
  -- per-swing check like the Mist's cn_mist_dodge.
  v_evaded boolean := false;
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

  -- THE SWAMP, applied once, here. v_strk and v_recv are assigned from these
  -- two further down, so every rule in the exchange -- the parry, the second
  -- strike, the cyclone, the lifesteal, the bonus against poison -- reads a
  -- silenced fighter without any of them being told about silence.
  v_atk := cn_awake(v_st, v_atk);
  v_tgt := cn_awake(v_st, v_tgt);

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
    -- FRIENDLY FIRE IS ALLOWED. The refusal that used to be here was total
    -- in practice -- since 0033 no card carries `heals` -- so "you may only
    -- point this at an ally if you mend" meant "you may never point this at
    -- an ally". Jared's rule is that you may.
    v_ally := (v_tgt->>'owner' = p_side);
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

  -- A MEND is what happens when a healer points at an ally. A healer is the
  -- only thing this branch has ever been for, and since 0033 there is not one
  -- on the roster -- so this is kept, unreachable, rather than deleted: it is
  -- the whole of how mending works and the day a card carries `heals` again it
  -- has to work the same way it always did.
  if v_ally and coalesce((v_atk->>'heals')::boolean, false) then
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
    -- Since 0035 the thing being struck may be a wall or a trap, and a log
    -- line that calls a summoned wall a tree is the kind of small lie that
    -- makes a player distrust the rest of the log.
    v_note := (v_atk->>'name') || ' strikes ' || cn_obj_name(cn_obj_kind(v_tree))
              || ' for ' || v_dmg
              || case when v_killed_tgt then ' -- destroyed.' else '.' end;

  else
    v_tgt_hp := (v_tgt->>'hp')::int;

    -- 0059: EVASION. Rolled on the DEFENDER, once, before anything else in
    -- this exchange -- unlike a parry (which catches the blow and answers
    -- it) an evaded blow simply never connects: no damage, no burn
    -- transfer, no ordinary counter, no Quick Dagger, no chain. Both gates
    -- below (Quick Dagger's `if`, the chain's `while`) read v_evaded so
    -- nothing past this point has to change shape.
    v_evaded := cn_chance((v_tgt->>'evasionPct')::int, 'evasion');
    if v_evaded then
      v_swings := v_swings || jsonb_build_object(
        'k', 'hit', 'by', p_unit, 'at', p_target, 'dmg', 0,
        'crit', false, 'counter', false, 'first', false, 'def', false,
        'why', 'evade');
    end if;

    -- A thief that trades blows is not a thief -- and neither does your own
    -- soldier draw on you. A counter is what somebody does when an ENEMY
    -- attacks them; gating it here rather than at each of the three places
    -- that read v_answers is what also takes the Quick Dagger off, which
    -- would otherwise answer its own side before the blow it was answering.
    v_answers := not v_ally
                 and not coalesce((v_atk->>'sneaks')::boolean, false)
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
    if not v_evaded and v_answers and coalesce((v_tgt->>'parries')::boolean, false) then
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

    -- The chain. 0059: v_evaded skips it entirely -- zero iterations, not a
    -- special case inside it.
    while not v_evaded and not v_killed_atk and not v_killed_tgt and v_chain < cn_parry_cap() loop
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
      -- AND YOUR OWN SIDE DOES NOT CATCH YOUR BLADE EITHER. A parry is not
      -- only a block: it flips the swing, so the parrier strikes back. An
      -- ally that parried would therefore answer, which is the rule two lines
      -- up read backwards. One `not v_ally` at the roll takes the whole chain
      -- off, and a friendly blow becomes the single beat it should be.
      -- 0074: TRIGGER_PARRY -- a forced parry (cn_effect_apply_action's
      -- TRIGGER_PARRY branch sets forcedParry on the receiving unit) always
      -- catches the blow, the same as a natural roll landing, subject to
      -- the same not-an-ally/not-slippery gates everything else here reads.
      v_parried := not v_ally
                   and not coalesce((v_strk->>'slippery')::boolean, false)
                   and (coalesce((v_recv->>'forcedParry')::boolean, false)
                        or (v_is_counter and coalesce((v_recv->>'parryAll')::boolean, false))
                        or cn_chance((v_recv->>'parryPct')::int, 'parry'));

      if v_parried then
        -- 0074: consumed the instant it catches a blow -- a second forced
        -- parry needs a second TRIGGER_PARRY effect. Cleared on whichever
        -- local copy is actually receiving this swing; v_recv itself is
        -- reassigned from v_atk/v_tgt at the top of every loop iteration,
        -- so the next iteration reads the cleared flag for free.
        if v_swing_is_atk then
          if coalesce((v_tgt->>'forcedParry')::boolean, false) then
            v_tgt := jsonb_set(v_tgt, '{forcedParry}', 'false'::jsonb);
          end if;
        else
          if coalesce((v_atk->>'forcedParry')::boolean, false) then
            v_atk := jsonb_set(v_atk, '{forcedParry}', 'false'::jsonb);
          end if;
        end if;
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

    if v_evaded then
      v_note := (v_tgt->>'name') || ' evades ' || (v_atk->>'name') || '''s attack.';
    elsif v_dmg = 0 then
      v_note := (v_atk->>'name') || ' lunges at ' || (v_tgt->>'name') || '.';
    else
      v_note := (v_atk->>'name') || ' hits ' || (v_tgt->>'name') || ' for ' || v_dmg
                || case when v_killed_tgt and v_burn_tgt = 0 then ' -- destroyed.' else '.' end;
    end if;
  end if;

  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then
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
      -- 0074: forcedParry (TRIGGER_PARRY) rides the same local-copy-carries
      -- -the-truth path 'effects' already uses, just above.
      u := jsonb_set(u, '{forcedParry}',
                     coalesce(v_atk->'forcedParry', 'false'::jsonb), true);
      if not v_killed_atk then
        v_out := v_out || u;
      else
        -- 0074: REVIVE's graveyard -- see cn_bury's own header. u already
        -- carries this unit's final hp/effects/forcedParry, exactly as it
        -- would have if it had lived.
        v_st := cn_bury(v_st, u);
      end if;
    elsif v_tree is null and u->>'id' = p_target then
      -- ONE BRANCH, not two. There used to be an `if v_ally` here that kept
      -- the target on the board whatever its health, because the only way to
      -- point this function at an ally was to MEND it and nobody has ever
      -- been mended to death. Since 0038 an ally can be struck, and an ally
      -- struck to nothing was staying on the board at minus thirty hit
      -- points -- so the crown never fell and the match never ended.
      --
      -- The two branches were already identical apart from that: 0034 folded
      -- the cure and the new burn into v_tgt's own effects object, so there
      -- is nothing left for a mend to do differently.
      u := jsonb_set(u, '{hp}', to_jsonb(v_tgt_hp));
      u := jsonb_set(u, '{effects}',
                     coalesce(v_tgt->'effects', cn_no_effects()), true);
      u := jsonb_set(u, '{forcedParry}',
                     coalesce(v_tgt->'forcedParry', 'false'::jsonb), true);
      if not v_killed_tgt then
        v_out := v_out || u;
      else
        v_st := cn_bury(v_st, u);
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

  -- ===== 0049: new-engine attack hooks (additive) -- ON_ATTACK, ON_PARRY,
  -- ON_DEATH. Deliberately fired ONCE HERE, after v_st already carries the
  -- exchange's final hp/effects/positions (not interleaved inside the
  -- swing loop above): that loop tracks damage in the local scalars
  -- v_atk_hp/v_tgt_hp, flushed into v_st only in the two unit-rebuild
  -- loops just above, so a generic effect that touched v_st mid-loop would
  -- be silently overwritten the moment those scalars are flushed. Firing
  -- after the flush means every hook sees, and only ever touches, the one
  -- true copy of the board -- a deliberate interpretation of "additively
  -- inside the loop" rather than a literal one; see the migration report.
  -- Skipped entirely for a tree/wall/bomb/tornado strike (v_tree is not
  -- null): scenery has no abilityScript and cannot parry or die in the
  -- sense these three triggers mean. Also skipped for the (currently
  -- dead-code, since no active card carries `heals`) mend branch: a mend
  -- is not an attack, and ON_ATTACK should not fire when a healer points
  -- at an ally to bandage them.
  if v_tree is null and not (v_ally and coalesce((v_atk->>'heals')::boolean, false)) then
    if not v_killed_atk then
      v_st := cn_run_effects(v_st, 'ON_ATTACK', v_atk,
        jsonb_build_object('target', v_tgt, 'turnNumber', coalesce((v_st->>'turnNumber')::int, 1)));
    end if;
    for v_elem in select * from jsonb_array_elements(v_swings) loop
      if v_elem->>'k' = 'parry' then
        v_ce_id := v_elem->>'by';
        v_ce_unit := null;
        for u in select * from jsonb_array_elements(v_st->'units') loop
          if u->>'id' = v_ce_id then v_ce_unit := u; end if;
        end loop;
        if v_ce_unit is not null then
          v_st := cn_run_effects(v_st, 'ON_PARRY', v_ce_unit,
            jsonb_build_object(
              'target', case when v_ce_id = p_unit then v_tgt else v_atk end,
              'turnNumber', coalesce((v_st->>'turnNumber')::int, 1)));
        end if;
        -- 0058: IS_PARRIED, the other half of the same swing -- fired on
        -- whichever unit's OWN blow got caught (v_elem->>'at'), not on the
        -- one that caught it. Re-scans v_st fresh, same as v_ce_unit just
        -- above, since ON_PARRY may already have mutated it this iteration.
        v_pd_id := v_elem->>'at';
        v_pd_unit := null;
        for u in select * from jsonb_array_elements(v_st->'units') loop
          if u->>'id' = v_pd_id then v_pd_unit := u; end if;
        end loop;
        if v_pd_unit is not null then
          v_st := cn_run_effects(v_st, 'IS_PARRIED', v_pd_unit,
            jsonb_build_object(
              'target', case when v_pd_id = p_unit then v_tgt else v_atk end,
              'turnNumber', coalesce((v_st->>'turnNumber')::int, 1)));
        end if;
      end if;
      -- 0058: ON_COUNTER -- fired once per counter-hit swing element, on
      -- whichever unit landed it. Covers both Quick Dagger's synthetic
      -- first-strike swing (marked 'counter': true where it is built,
      -- above) and every alternating chain hit built with
      -- 'counter', v_is_counter -- the only two places v_swings ever sets
      -- that key true.
      if v_elem->>'k' = 'hit' and coalesce((v_elem->>'counter')::boolean, false) then
        v_co_id := v_elem->>'by';
        v_co_unit := null;
        for u in select * from jsonb_array_elements(v_st->'units') loop
          if u->>'id' = v_co_id then v_co_unit := u; end if;
        end loop;
        if v_co_unit is not null then
          v_st := cn_run_effects(v_st, 'ON_COUNTER', v_co_unit,
            jsonb_build_object(
              'target', case when v_co_id = p_unit then v_tgt else v_atk end,
              'turnNumber', coalesce((v_st->>'turnNumber')::int, 1)));
        end if;
      end if;
    end loop;
    -- ===== 0074: ON_DAMAGED (additive) -- REFLECT_DAMAGE_PCT's hookpoint.
    -- Fired for whichever side actually took real damage from the OTHER
    -- unit's own blows this exchange: v_dmg (the attacker's swing(s) on the
    -- defender) and v_counter+v_riposte (the defender's counter-hits, and
    -- any riposte on top of those, landing back on the attacker) are
    -- exactly those two numbers, already computed by the swing loop above.
    -- Burn cost is deliberately excluded -- it is self-inflicted while
    -- swinging, not damage an opponent dealt, so there is nothing honest to
    -- "reflect" it at. Gated on the receiving unit having survived, same as
    -- ON_ATTACK above: a unit that died this exchange already fired
    -- ON_DEATH instead and has no current row in v_st to look up.
    if not v_killed_tgt and v_dmg > 0 then
      v_ce_unit := null;
      for u in select * from jsonb_array_elements(v_st->'units') loop
        if u->>'id' = p_target then v_ce_unit := u; end if;
      end loop;
      if v_ce_unit is not null then
        v_st := cn_run_effects(v_st, 'ON_DAMAGED', v_ce_unit,
          jsonb_build_object('attacker', v_atk, 'damage', v_dmg,
            'turnNumber', coalesce((v_st->>'turnNumber')::int, 1)));
      end if;
    end if;
    if not v_killed_atk and (v_counter + v_riposte) > 0 then
      v_ce_unit := null;
      for u in select * from jsonb_array_elements(v_st->'units') loop
        if u->>'id' = p_unit then v_ce_unit := u; end if;
      end loop;
      if v_ce_unit is not null then
        v_st := cn_run_effects(v_st, 'ON_DAMAGED', v_ce_unit,
          jsonb_build_object('attacker', v_tgt, 'damage', v_counter + v_riposte,
            'turnNumber', coalesce((v_st->>'turnNumber')::int, 1)));
      end if;
    end if;
    -- ===== end 0074 (ON_DAMAGED) ============================================
    if v_killed_tgt then
      v_st := cn_run_effects(v_st, 'ON_DEATH', v_tgt,
        jsonb_build_object('attacker', v_atk, 'turnNumber', coalesce((v_st->>'turnNumber')::int, 1)));
    end if;
    if v_killed_atk then
      v_st := cn_run_effects(v_st, 'ON_DEATH', v_atk,
        jsonb_build_object('attacker', v_tgt, 'turnNumber', coalesce((v_st->>'turnNumber')::int, 1)));
    end if;
  end if;
  -- ===== end 0049 =============================================================
  -- ===== 0057: STRUCTURES -- ON_DESTROYED (additive) ======================
  -- Fired for exactly the same reason 0049 fires ON_ATTACK/ON_PARRY/ON_DEATH
  -- above, and at the same kind of moment: after v_st already carries the
  -- exchange's final obstacles array (the rebuild loop just above this one
  -- has already dropped the destroyed obstacle from v_rocks), never inside
  -- the tree/wall/bomb/tornado-strike branch itself. v_tree is the LOCAL
  -- copy captured before the exchange -- its hp is stale, which is fine:
  -- only kind/x/y/owner/by are read (kind to find a matching structures
  -- row at all; owner/by so INVOKER resolves to whoever placed it). A tree
  -- or a legacy summon (bomb/wall/tornado) has no row in `structures`, so
  -- cn_run_structure_effects finds nothing and this is a no-op for every
  -- strike that predates 0057 -- see that function's own header.
  if v_tree is not null and v_killed_tgt then
    -- 0074: 'damage' added -- COUNTER_ATTACK_PCT's hookpoint, the exact
    -- damage that destroyed this structure (v_dmg, computed in the
    -- tree/wall/bomb/tornado-strike branch above).
    v_st := cn_run_structure_effects(v_st, 'ON_DESTROYED', v_tree,
      jsonb_build_object('attacker', v_atk, 'damage', v_dmg,
        'turnNumber', coalesce((v_st->>'turnNumber')::int, 1)));
  end if;
  -- ===== end 0057 ===========================================================
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

  -- ===== 0051: STALEMATE TRACKING (additive) ================================
  -- Any real damage dealt in this exchange -- the primary blow, a counter,
  -- a riposte (a counter-to-a-counter), or burn cost paid by either side --
  -- resets advance_turn's rounds-since-damage streak. A heal, lifesteal, or
  -- a swing that misses/is parried for nothing does not count, which is
  -- what "0 total damage dealt" means. A tree/wall strike's damage lands in
  -- v_dmg the same as any other, so it is covered for free.
  if (v_dmg + v_counter + v_riposte + v_burn_atk + v_burn_tgt) > 0 then
    v_st := jsonb_set(v_st, '{roundDmg}', 'true'::jsonb);
  end if;
  -- ===== end 0051 ============================================================

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

  -- ===== 0045: crit/parry counters, single-class team check, bot-win credit
  -- Crits and parries are counted here, once, whatever v_win turns out to be
  -- below -- a match-ending crit is still a crit. Every element of v_swings
  -- names its actor as 'by', an id that is always p_unit or p_target -- the
  -- only two units this function ever touches -- so the owner lookup is a
  -- straight comparison against the two local unit copies rather than a scan
  -- of the board.
  for v_elem in select * from jsonb_array_elements(v_swings) loop
    v_by := v_elem->>'by';
    if v_by is null then continue; end if;
    if v_by = p_unit then v_by_owner := p_side;
    elsif v_by = p_target then v_by_owner := coalesce(v_tgt->>'owner', v_other);
    else continue; end if;
    v_by_uid := case when v_by_owner = 'host' then m.host_id else m.guest_id end;
    if v_by_uid is null then continue; end if;  -- the bot has no profile row

    if coalesce((v_elem->>'crit')::boolean, false) then
      update public.profiles set crit_count = crit_count + 1 where id = v_by_uid;
      perform cn_check_achievements(v_by_uid);
    end if;
    if v_elem->>'k' = 'parry' then
      update public.profiles set parry_count = parry_count + 1 where id = v_by_uid;
      perform cn_check_achievements(v_by_uid);
    end if;
  end loop;

  if v_win is not null then
    v_win_uid := case when v_win = 'host' then m.host_id else m.guest_id end;

    -- A single-class team win: exactly four surviving non-royal units on the
    -- winning side, all one role among knight/rogue/mage/flying. Checked
    -- against v_out, the post-combat roster, and unlocked at most once ever
    -- per player -- the primary key on player_achievements is what makes
    -- that true, not a flag read beforehand.
    --
    -- 0063: `uu`, not `u` -- see this migration's header. `u` is also this
    -- function's own loop variable, and under plpgsql.variable_conflict =
    -- 'error' (confirmed live on this project) a FROM-clause alias of the
    -- same name that is then referenced inside the query text (uu->>'role'
    -- etc.) is a hard "column reference is ambiguous" error the moment this
    -- statement runs -- every other `for u in select ...` loop in this
    -- function is fine because none of them reference `u` as a column
    -- inside their own query text, only as the implicit loop target.
    if v_win_uid is not null then
      select count(*), array_agg(distinct uu->>'role') into v_win_count, v_win_roles
        from jsonb_array_elements(v_out) uu
       where uu->>'owner' = v_win and not coalesce((uu->>'royal')::boolean, false);
      if v_win_count = 4 and array_length(v_win_roles, 1) = 1
         and v_win_roles[1] in ('knight', 'rogue', 'mage', 'flying') then
        insert into public.player_achievements (user_id, achievement_id)
          values (v_win_uid, 'single_class_' || v_win_roles[1])
          on conflict do nothing;
      end if;
    end if;

    -- A bot match has no rank on the line, but a win over the bot still
    -- counts toward the bot-wins tiers. The bot is always the guest
    -- (bot_step never plays anything else), so a human win here is always
    -- v_win = 'host'. Mirrors cn_finish's own copy of the same rule, for the
    -- ending that happens there instead of here.
    if m.bot is not null and v_win = 'host' and m.host_id is not null then
      update public.profiles set bot_wins = bot_wins + 1 where id = m.host_id;
    end if;

    if v_win_uid is not null then perform cn_check_achievements(v_win_uid); end if;
  end if;
  -- ===== end 0045 ===========================================================

  if v_win is not null then
    -- 0067: this used to be `if m.ranked then` alone -- see this migration's
    -- header for why that missed 0066's whole point for the most common way
    -- a match actually ends.
    if m.ranked or (m.bot is null and cn_friend_tournament_lp_enabled()) then
      perform finish_match(m.id, v_win, 'defeat');
    end if;
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
$function$;
