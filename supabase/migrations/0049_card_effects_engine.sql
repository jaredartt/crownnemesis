-- 0049_card_effects_engine.sql
--
-- THE SOFT-CODED ABILITY ENGINE.
--
-- Jared asked for one editor that can build any card's ability or passive out
-- of dropdowns -- trigger, target, action, a number, a status, a stat name --
-- with conditionals, replacing both the free-form ability text's hidden
-- mechanics and the raw checkboxes admin never had a screen for (slippery,
-- twice_pct, lifesteal_pct, parry_all, regen_pct, poisons_adjacent,
-- vs_poisoned, cures, blooms, sneaks, tramples, parries, burns, heals --
-- today these are set by hand in SQL, if they are set at all).
--
-- TWO LAYERS, on purpose, and this is a deliberate architectural choice
-- rather than a shortcut:
--
-- LAYER 1 -- a generic executor (cn_run_effects/cn_resolve_targets/
-- cn_effect_apply_action below) for genuinely NEW hookpoints: ON_PLAY (a
-- unit entering the battlefield -- did not exist before), ON_ABILITY (the
-- activated-ability slot, dispatched to from cn_ability alongside its
-- existing hard-coded kinds), ON_ATTACK/ON_DEATH/ON_PARRY (spliced
-- additively into cn_attack) and START_OF_TURN/END_OF_TURN (spliced
-- additively into advance_turn). cn_attack's 500-line swing-resolution loop
-- is NOT reimplemented as a generic interpreter -- that was explicitly ruled
-- out as too risky for a live game with real matches in progress. The new
-- hooks fire ONCE, after that loop has already flushed its result into
-- v_st, rather than interleaved swing-by-swing -- see the comment at each
-- splice site for why.
--
-- LAYER 2 -- a compiler (cn_compile_card_effects) for the passive stat
-- modifiers cn_attack's swing loop already reads directly as named columns
-- (slippery, twice_pct, lifesteal_pct, parry_all, regen_pct, poisons_adjacent,
-- stuns, vs_poisoned, cures, blooms, sneaks, flies, tramples, parries, burns,
-- heals, the aura fields, swamps). That loop's precise order of operations is
-- NOT touched. Instead, a PASSIVE/MODIFY_STAT row in card_effects is compiled
-- down to the matching `cards` column by a trigger on card_effects, and
-- cn_attack keeps reading the exact same columns it always has, unaware
-- anything changed upstream. The admin's new "Abilities & Passives" tab is
-- the only way to set these going forward -- see AdminCards.tsx/
-- AbilityEditor.tsx, which removes the raw checkboxes this replaces.
--
-- SNAPSHOT INTEGRITY: a unit's effect rows are copied onto it as
-- `abilityScript` the moment its army is built (cn_army, the "only door
-- every army in the game comes through") -- never re-read from `cards` mid
-- match, for the same reason every other stat is snapshotted: a card retuned
-- in the editor must not change a match already running. `abilityScript`
-- does NOT collide with the unit's existing `effects` field, which already
-- means "what is currently ON this unit" (burn/poison/stun) -- this is
-- "what this unit's card CAN DO", a different question entirely.
--
-- MIGRATION 0050 ports every active card's existing ability/passive columns
-- into card_effects rows and verifies, card by card, that the compiler
-- reproduces the exact values the card already had.

-- =====================================================================
-- 1. THE TABLE
-- =====================================================================

create table public.card_effects (
  id uuid primary key default gen_random_uuid(),
  card_id uuid not null references public.cards(id) on delete cascade,
  sort int not null default 0,

  -- ON_PLAY/ON_ABILITY/ON_ATTACK/ON_DEATH/START_OF_TURN/END_OF_TURN/ON_PARRY
  -- and PASSIVE are the developer's own list plus PASSIVE (Layer 2's always-
  -- on trigger, see above). The five after that are ours, each earning its
  -- place:
  --   ON_COUNTER        -- "when THIS unit lands the ordinary counter" is a
  --                         different moment from ON_ATTACK (which fires for
  --                         the unit that opened the exchange) and from
  --                         ON_PARRY (a parry, not an ordinary counter) --
  --                         a card that rewards counter-attacking needs it.
  --   ON_KILL           -- "when this unit's blow finishes something" is not
  --                         the same event as ON_DEATH, which fires on the
  --                         dying unit's OWN script. A vampiric-on-kill card
  --                         needs its own script to see the kill.
  --   ON_HEALED         -- lets a card react to RECEIVING a mend (its own or
  --                         an ally's), which nothing above covers.
  --   ON_DAMAGED        -- lets a card react to being hit at all, independent
  --                         of ON_PARRY/ON_DEATH -- e.g. "gain armour when
  --                         struck". A natural, frequently-asked-for hook.
  --   ON_STATUS_APPLIED -- lets a card react to a burn/poison/stun landing on
  --                         it, separate from ON_DAMAGED (a status can land
  --                         with zero damage, e.g. Zephyra's stun).
  -- ON_COUNTER/ON_HEALED/ON_DAMAGED/ON_STATUS_APPLIED are accepted by the
  -- schema and by cn_run_effects, but nothing in 0049 dispatches them yet --
  -- wiring them into cn_attack's swing loop safely needs the same care as
  -- ON_ATTACK/ON_PARRY did and was left out of this pass to keep the splice
  -- surface small. See the migration report for this gap named plainly.
  trigger text not null check (trigger in (
    'ON_PLAY', 'ON_ABILITY', 'ON_ATTACK', 'ON_DEATH', 'START_OF_TURN',
    'END_OF_TURN', 'ON_PARRY', 'PASSIVE',
    'ON_COUNTER', 'ON_KILL', 'ON_HEALED', 'ON_DAMAGED', 'ON_STATUS_APPLIED'
  )),

  -- The developer's six plus eleven more, so a card can reach every shape of
  -- target a tactics game actually needs: the opposite end of every pair he
  -- named (ALL_ENEMIES to mirror ALL_ALLIES, HIGHEST_HP_* to mirror LOWEST_HP_*),
  -- NEAREST_ENEMY (a lunger's natural target), RANDOM_* (a chaotic card),
  -- *_IN_LINE (Ashvar-style beams), THE_ATTACKER/THE_TARGET (only meaningful
  -- from ON_ATTACK/ON_PARRY/ON_DEATH's own context -- "whoever just hit me"),
  -- and ADJACENT_UNITS (Dione & Grifo's own "friend and foe alike").
  target_selector text not null check (target_selector in (
    'SELF', 'NEARBY_ALLIES', 'ALL_ALLIES', 'ENEMY_IN_RANGE', 'LOWEST_HP_ENEMY',
    'BOARD_CELL',
    'ALL_ENEMIES', 'NEAREST_ENEMY', 'HIGHEST_HP_ENEMY', 'LOWEST_HP_ALLY',
    'HIGHEST_HP_ALLY', 'RANDOM_ENEMY_IN_RANGE', 'RANDOM_ALLY',
    'ALLIES_IN_LINE', 'ENEMIES_IN_LINE', 'THE_ATTACKER', 'THE_TARGET',
    'ADJACENT_UNITS'
  )),

  -- The developer's six plus eight more. REMOVE_STATUS mirrors APPLY_STATUS
  -- (curing is as real a card idea as afflicting). GRANT_EXTRA_ACTIVATION,
  -- TELEPORT_SELF and SWAP_POSITIONS are new mobility/tempo primitives no
  -- existing card has but a soft-coded editor should be able to build.
  -- SUMMON_OBJECT, REVIVE, COPY_STAT_FROM_TARGET and REFLECT_DAMAGE_PCT are
  -- accepted by the schema for a complete authoring vocabulary, but are
  -- documented no-ops in cn_effect_apply_action for now -- each would need
  -- either a faithful copy of cn_ability's summon plumbing (SUMMON_OBJECT),
  -- a corpse buffer that does not exist today (REVIVE), or a live-damage
  -- context this executor is never called with (REFLECT_DAMAGE_PCT). Named
  -- explicitly in the final report rather than silently half-built.
  action text not null check (action in (
    'DEAL_DAMAGE', 'HEAL', 'APPLY_STATUS', 'MODIFY_STAT', 'PUSH_BACK', 'DRAW_CARD',
    'REMOVE_STATUS', 'GRANT_EXTRA_ACTIVATION', 'SUMMON_OBJECT', 'TELEPORT_SELF',
    'SWAP_POSITIONS', 'REVIVE', 'COPY_STAT_FROM_TARGET', 'REFLECT_DAMAGE_PCT'
  )),

  value int,
  status text check (status in ('NONE', 'BURNING', 'STUN', 'POISON', 'ANY', 'ALL')),

  -- The full legacy-column list Layer 2 can compile to, plus the ordinary
  -- stat boxes (HP/MOV/RMIN/RMAX/CRMIN/CRMAX/POWER/PARRY_PCT/CRIT_PCT) for
  -- RUNTIME use only (MODIFY_STAT fired from ON_ABILITY/ON_ATTACK/etc, which
  -- patches a live unit snapshot in a running match) -- the PASSIVE compiler
  -- deliberately ignores those nine, see cn_compile_card_effects's own
  -- comment for why writing them from the compiler would be unsafe. SWAMPS
  -- and the eight AURA_* names complete the legacy-column list the prompt
  -- asked for "in full": Umiro's swamp and the three royals' auras are real
  -- active-card passives with nowhere else to live in this schema, since
  -- aura_kind/aura_class/aura_pct are three columns forming one idea and this
  -- table has no free-text value column to carry a class name safely.
  stat_name text check (stat_name is null or stat_name in (
    'SLIPPERY', 'TWICE_PCT', 'LIFESTEAL_PCT', 'PARRY_ALL', 'REGEN_PCT',
    'STUNS_ON_HIT', 'POISONS_ADJACENT', 'VS_POISONED_BONUS', 'CURES_BURN',
    'BLOOMS', 'SNEAKS', 'FLIES', 'TRAMPLES', 'PARRIES', 'BURNS', 'HEALS',
    'SWAMPS',
    'AURA_RESIST_KNIGHT', 'AURA_RESIST_ROGUE', 'AURA_RESIST_MAGE', 'AURA_RESIST_FLYING',
    'AURA_BONUS_KNIGHT', 'AURA_BONUS_ROGUE', 'AURA_BONUS_MAGE', 'AURA_BONUS_FLYING',
    'AURA_RESIST_EFFECTS',
    'HP', 'MOV', 'RMIN', 'RMAX', 'CRMIN', 'CRMAX', 'POWER', 'PARRY_PCT', 'CRIT_PCT'
  )),

  -- An array of {field, op, value}, ALL of which must hold (AND). See
  -- cn_effect_condition_met for the enumerated fields/ops this evaluates.
  conditions jsonb not null default '[]'::jsonb,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint card_effects_modify_stat_needs_name check (
    action not in ('MODIFY_STAT', 'COPY_STAT_FROM_TARGET') or stat_name is not null
  ),
  constraint card_effects_status_action_needs_status check (
    action not in ('APPLY_STATUS', 'REMOVE_STATUS') or status is not null
  )
);

create index card_effects_card_id_idx on public.card_effects (card_id, sort);

comment on table public.card_effects is
  'The soft-coded ability/passive engine, since 0049. One row is one effect: '
  'trigger + target + action (+ value/status/stat_name) + conditions. See '
  '0049_card_effects_engine.sql''s header for the two-layer design.';

-- =====================================================================
-- 2. RLS -- the exact same gate as `cards` itself, not a new one.
-- =====================================================================

alter table public.card_effects enable row level security;

create policy "admins write card effects" on public.card_effects
  for all to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin))
  with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin));

create policy "card effects readable by authenticated" on public.card_effects
  for select to authenticated
  using (true);

create or replace function public.cn_touch_card_effects()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end
$$;

create trigger card_effects_touch
  before update on public.card_effects
  for each row execute function public.cn_touch_card_effects();

-- =====================================================================
-- 3. `ability_kind` grows one more value: 'scripted'.
--
-- A card whose ability is authored through the new engine (as opposed to
-- one of the six hard-coded kinds cn_ability already knew) carries this so
-- cn_ability knows to dispatch to cn_run_effects instead. See migration
-- 0050 for exactly which existing cards are switched to it and why the
-- 'summon' and 'mist' kinds are deliberately left alone.
-- =====================================================================

alter table public.cards drop constraint cards_ability_kind_check;
alter table public.cards add constraint cards_ability_kind_check check (
  ability_kind is null or ability_kind = any (array[
    'aoe_adjacent', 'heal_any', 'mist', 'poison_hit', 'line_burn', 'summon',
    'scripted'
  ])
);

-- =====================================================================
-- 4. CONDITIONALS
-- =====================================================================

-- p_ctx is built by the caller and always carries 'self' (the acting unit's
-- CURRENT row, re-read from the live state -- see cn_run_effects) and,
-- where relevant, 'target' (the full unit row an ability/attack/parry/death
-- names) and 'attacker' (from ON_DEATH/ON_PARRY's point of view). Volatile,
-- not stable: 'roll_pct' calls random().
create or replace function public.cn_effect_condition_met(p_cond jsonb, p_ctx jsonb)
returns boolean
language plpgsql
set search_path = public
as $$
declare
  v_field text := p_cond->>'field';
  v_op text := coalesce(p_cond->>'op', '=');
  v_val text := p_cond->>'value';
  v_side text; v_num numeric; v_cmp numeric; v_txt text; v_bool boolean;
begin
  if v_field is null then return true; end if;

  if v_field in ('self.hp_pct', 'target.hp_pct') then
    v_side := split_part(v_field, '.', 1);
    v_num := round(100.0 * coalesce((p_ctx->v_side->>'hp')::numeric, 0)
                   / greatest(1, coalesce((p_ctx->v_side->>'maxHp')::numeric, 1)));
    v_cmp := nullif(v_val, '')::numeric;
    return case v_op
      when '=' then v_num = v_cmp when '!=' then v_num <> v_cmp
      when '<' then v_num < v_cmp when '<=' then v_num <= v_cmp
      when '>' then v_num > v_cmp when '>=' then v_num >= v_cmp
      else false end;

  elsif v_field in ('self.role', 'target.role') then
    v_side := split_part(v_field, '.', 1);
    v_txt := p_ctx->v_side->>'role';
    if v_op = 'in' then return v_txt = any(string_to_array(v_val, ','));
    elsif v_op = '!=' then return v_txt is distinct from v_val;
    else return v_txt = v_val; end if;

  elsif v_field in ('self.has_status', 'target.has_status') then
    v_side := split_part(v_field, '.', 1);
    v_bool := case v_val
      when 'BURNING' then coalesce((p_ctx->v_side->'effects'->>'burn')::boolean, false)
      when 'POISON'  then coalesce((p_ctx->v_side->'effects'->>'poison')::boolean, false)
      when 'STUN'    then coalesce((p_ctx->v_side->'effects'->>'stun')::int, 0) > 0
      when 'ANY'     then coalesce((p_ctx->v_side->'effects'->>'burn')::boolean, false)
                        or coalesce((p_ctx->v_side->'effects'->>'poison')::boolean, false)
                        or coalesce((p_ctx->v_side->'effects'->>'stun')::int, 0) > 0
      else false end;
    return case when v_op = '!=' then not v_bool else v_bool end;

  elsif v_field = 'roll_pct' then
    return (random() * 100) < nullif(v_val, '')::numeric;

  elsif v_field = 'turn_number' then
    v_num := coalesce((p_ctx->>'turnNumber')::numeric, 0);
    v_cmp := nullif(v_val, '')::numeric;
    return case v_op
      when '=' then v_num = v_cmp when '!=' then v_num <> v_cmp
      when '<' then v_num < v_cmp when '<=' then v_num <= v_cmp
      when '>' then v_num > v_cmp when '>=' then v_num >= v_cmp
      else false end;

  elsif v_field = 'is_royal_target' then
    v_bool := coalesce((p_ctx->'target'->>'royal')::boolean, false);
    return case when v_op = '!=' then not v_bool else v_bool end;

  elsif v_field = 'units_adjacent_count' then
    v_num := coalesce((p_ctx->>'adjacentCount')::numeric, 0);
    v_cmp := nullif(v_val, '')::numeric;
    return case v_op
      when '=' then v_num = v_cmp when '!=' then v_num <> v_cmp
      when '<' then v_num < v_cmp when '<=' then v_num <= v_cmp
      when '>' then v_num > v_cmp when '>=' then v_num >= v_cmp
      else false end;
  end if;

  return true;
end
$$;

create or replace function public.cn_effect_conditions_met(p_conditions jsonb, p_ctx jsonb)
returns boolean
language plpgsql
set search_path = public
as $$
declare v_cond jsonb;
begin
  if p_conditions is null or jsonb_typeof(p_conditions) <> 'array' then return true; end if;
  for v_cond in select * from jsonb_array_elements(p_conditions) loop
    if not cn_effect_condition_met(v_cond, p_ctx) then return false; end if;
  end loop;
  return true;
end
$$;

-- =====================================================================
-- 5. TARGET RESOLUTION
-- =====================================================================

create or replace function public.cn_resolve_targets(
  v_st jsonb, p_selector text, p_unit jsonb, p_context jsonb
) returns jsonb
language plpgsql
set search_path = public
as $$
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
$$;

-- =====================================================================
-- 6. APPLYING ONE ACTION TO ONE TARGET
-- =====================================================================

create or replace function public.cn_effect_apply_action(
  v_st jsonb, p_effect jsonb, p_unit jsonb, p_target_id text, p_context jsonb
) returns jsonb
language plpgsql
set search_path = public
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
  v_num_field_map jsonb := '{
    "HP": "hp", "MOV": "mov", "RMIN": "rmin", "RMAX": "rmax",
    "CRMIN": "crmin", "CRMAX": "crmax", "POWER": "pow",
    "PARRY_PCT": "parryPct", "CRIT_PCT": "critPct", "TWICE_PCT": "twicePct",
    "LIFESTEAL_PCT": "lifestealPct", "REGEN_PCT": "regenPct",
    "VS_POISONED_BONUS": "vsPoisoned"
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

  -- REVIVE, REFLECT_DAMAGE_PCT, SUMMON_OBJECT and DRAW_CARD are documented
  -- no-ops -- see this migration's header and the card_effects.action
  -- column comment for exactly why each one is left unbuilt rather than
  -- guessed at.
  if v_action in ('REVIVE', 'REFLECT_DAMAGE_PCT', 'SUMMON_OBJECT', 'DRAW_CARD') then
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
    end if;

    if (u->>'hp')::int > 0 then v_out := v_out || u; end if;
  end loop;
  v_st := jsonb_set(v_st, '{units}', v_out);

  if v_action = 'GRANT_EXTRA_ACTIVATION' and p_target_id = v_self_id then
    v_st := jsonb_set(v_st, '{acts}',
      to_jsonb(greatest(0, coalesce((v_st->>'acts')::int, 0) - greatest(1, v_value))));
  end if;

  return v_st;
end
$$;

-- =====================================================================
-- 7. THE GENERIC EXECUTOR
-- =====================================================================

create or replace function public.cn_run_effects(
  v_st jsonb, p_trigger text, p_unit jsonb, p_context jsonb
) returns jsonb
language plpgsql
set search_path = public
as $$
declare
  v_script jsonb := coalesce(p_unit->'abilityScript', '[]'::jsonb);
  v_row jsonb; v_ctx jsonb; v_targets jsonb; v_tid text;
  v_self_cur jsonb; u jsonb; v_adjacent int;
begin
  if jsonb_typeof(v_script) <> 'array' or jsonb_array_length(v_script) = 0 then
    return v_st;
  end if;

  for v_row in
    select el from jsonb_array_elements(v_script) as t(el)
     order by coalesce((el->>'sort')::int, 0)
  loop
    continue when v_row->>'trigger' <> p_trigger;

    -- Re-read the acting unit's CURRENT row -- an earlier row in this same
    -- script may already have changed its hp or position this same trigger.
    v_self_cur := null;
    for u in select * from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) loop
      if u->>'id' = p_unit->>'id' then v_self_cur := u; end if;
    end loop;
    if v_self_cur is null then v_self_cur := p_unit; end if;

    select count(*) into v_adjacent from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) q
     where q->>'id' <> p_unit->>'id'
       and cn_cheb((v_self_cur->>'x')::int, (v_self_cur->>'y')::int,
                   (q->>'x')::int, (q->>'y')::int) = 1;

    v_ctx := coalesce(p_context, '{}'::jsonb)
             || jsonb_build_object('self', v_self_cur, 'adjacentCount', v_adjacent);

    if not cn_effect_conditions_met(coalesce(v_row->'conditions', '[]'::jsonb), v_ctx) then
      continue;
    end if;

    v_targets := cn_resolve_targets(v_st, v_row->>'target_selector', v_self_cur, v_ctx);
    for v_tid in select * from jsonb_array_elements_text(coalesce(v_targets, '[]'::jsonb)) loop
      v_st := cn_effect_apply_action(v_st, v_row, v_self_cur, v_tid, v_ctx);
    end loop;
  end loop;

  return v_st;
end
$$;

-- =====================================================================
-- 8. THE COMPILER -- Layer 2
-- =====================================================================

create or replace function public.cn_compile_card_effects(p_card uuid)
returns void
language plpgsql
set search_path = public
as $$
declare r record;
begin
  -- Reset every legacy passive column this compiler owns before re-deriving.
  -- A row that used to grant slippery and was since deleted must make the
  -- card STOP being slippery, not merely fail to re-set it. `flies` resets
  -- to its role-derived default (cn_check_card overrides it from role on
  -- every write regardless, so this is cosmetic consistency, not a new
  -- source of truth).
  --
  -- HP/MOV/RMIN/RMAX/CRMIN/CRMAX/POWER/PARRY_PCT/CRIT_PCT are deliberately
  -- NOT reset or written here even though they are valid MODIFY_STAT
  -- stat_names -- those are the card's ordinary Stats-tab fields, and
  -- cn_check_card's own BEFORE trigger recomputes rmin/rmax/crmin/crmax/
  -- dmin/dmax/attack from range/power on every single write to `cards`, so
  -- a compiler-driven write here would be silently clobbered by that same
  -- trigger before the row ever committed. Worse, parry_pct/crit_pct are
  -- NOT recomputed that way, which means a compiler that added a delta to
  -- them every time it ran would double-count on every unrelated edit to
  -- the same card's effects, with no base value on record to add the delta
  -- to. Those nine stat_names are therefore meaningful only as a RUNTIME
  -- MODIFY_STAT (patching a live match's unit snapshot), never as a
  -- PASSIVE compiled default -- see the report for this named plainly.
  update public.cards set
    slippery = false, twice_pct = 0, regen_pct = 0,
    poisons_adjacent = false, stuns = false, vs_poisoned = 0, lifesteal_pct = 0,
    parry_all = false, parries = false, burns = false, heals = false,
    cures = false, blooms = false, sneaks = false, tramples = false,
    swamps = false, aura_kind = null, aura_class = null, aura_pct = null
   where id = p_card;

  for r in
    select * from public.card_effects
     where card_id = p_card and trigger = 'PASSIVE' and action = 'MODIFY_STAT'
     order by sort
  loop
    case r.stat_name
      when 'SLIPPERY'          then update public.cards set slippery = true where id = p_card;
      when 'PARRY_ALL'         then update public.cards set parry_all = true where id = p_card;
      when 'PARRIES'           then update public.cards set parries = true where id = p_card;
      when 'STUNS_ON_HIT'      then update public.cards set stuns = true where id = p_card;
      when 'POISONS_ADJACENT'  then update public.cards set poisons_adjacent = true where id = p_card;
      when 'CURES_BURN'        then update public.cards set cures = true where id = p_card;
      when 'BLOOMS'            then update public.cards set blooms = true where id = p_card;
      when 'SNEAKS'            then update public.cards set sneaks = true where id = p_card;
      when 'FLIES'             then update public.cards set flies = true where id = p_card;
      when 'TRAMPLES'          then update public.cards set tramples = true where id = p_card;
      when 'BURNS'             then update public.cards set burns = true where id = p_card;
      when 'HEALS'             then update public.cards set heals = true where id = p_card;
      when 'SWAMPS'            then update public.cards set swamps = true where id = p_card;
      when 'TWICE_PCT'         then update public.cards set twice_pct = coalesce(r.value, 0) where id = p_card;
      when 'REGEN_PCT'         then update public.cards set regen_pct = coalesce(r.value, 0) where id = p_card;
      when 'VS_POISONED_BONUS' then update public.cards set vs_poisoned = coalesce(r.value, 0) where id = p_card;
      when 'LIFESTEAL_PCT'     then update public.cards set lifesteal_pct = coalesce(r.value, 0) where id = p_card;
      when 'AURA_RESIST_KNIGHT' then update public.cards set aura_kind = 'resist', aura_class = 'knight', aura_pct = coalesce(r.value, 0) where id = p_card;
      when 'AURA_RESIST_ROGUE'  then update public.cards set aura_kind = 'resist', aura_class = 'rogue',  aura_pct = coalesce(r.value, 0) where id = p_card;
      when 'AURA_RESIST_MAGE'   then update public.cards set aura_kind = 'resist', aura_class = 'mage',   aura_pct = coalesce(r.value, 0) where id = p_card;
      when 'AURA_RESIST_FLYING' then update public.cards set aura_kind = 'resist', aura_class = 'flying', aura_pct = coalesce(r.value, 0) where id = p_card;
      when 'AURA_BONUS_KNIGHT'  then update public.cards set aura_kind = 'bonus',  aura_class = 'knight', aura_pct = coalesce(r.value, 0) where id = p_card;
      when 'AURA_BONUS_ROGUE'   then update public.cards set aura_kind = 'bonus',  aura_class = 'rogue',  aura_pct = coalesce(r.value, 0) where id = p_card;
      when 'AURA_BONUS_MAGE'    then update public.cards set aura_kind = 'bonus',  aura_class = 'mage',   aura_pct = coalesce(r.value, 0) where id = p_card;
      when 'AURA_BONUS_FLYING'  then update public.cards set aura_kind = 'bonus',  aura_class = 'flying', aura_pct = coalesce(r.value, 0) where id = p_card;
      when 'AURA_RESIST_EFFECTS' then update public.cards set aura_kind = 'resist_effects', aura_class = null, aura_pct = coalesce(r.value, 0) where id = p_card;
      else null; -- HP/MOV/RMIN/RMAX/CRMIN/CRMAX/POWER/PARRY_PCT/CRIT_PCT: see header.
    end case;
  end loop;
end
$$;

create or replace function public.cn_compile_card_effects_trg()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  perform public.cn_compile_card_effects(coalesce(new.card_id, old.card_id));
  return coalesce(new, old);
end
$$;

create trigger card_effects_compile_aiud
  after insert or update or delete on public.card_effects
  for each row execute function public.cn_compile_card_effects_trg();

-- =====================================================================
-- 9. THE SPLICES -- cn_army, cn_set_ready, advance_turn, cn_ability,
--    cn_attack. Each is the function fetched fresh via pg_get_functiondef
--    immediately before writing this migration, with additive block(s)
--    inserted (marked '0049:' in a comment) and verified programmatically
--    (a Python round-trip: removing the inserted text reproduces the
--    fetched original byte-for-byte) before being pasted below. See the
--    migration report for the exact anchor/insertion pair used for each.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.cn_army(p_state jsonb, p_side text, p_deck text[])
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
declare
  v_w int := (p_state->'board'->>'w')::int;
  v_h int := (p_state->'board'->>'h')::int;
  v_taken text[] := '{}'; e jsonb; c public.cards;
  v_xs int[] := '{}'::int[]; v_ys int[] := '{}'::int[];
  i int; vx int; vy int; v_idx int := 0;
  v_units jsonb := '[]'::jsonb; v_done boolean;
  -- 0049: this unit's card_effects rows, snapshotted alongside every
  -- other stat -- see 0049_card_effects_engine.sql's header.
  v_script jsonb;
begin
  -- ONE CROWN, NO EXCEPTIONS. This is the only door every army in the game
  -- comes through, which is the whole reason the rule is here and not in the
  -- four functions that build decks. It should never fire: set_deck refuses,
  -- deck_of repairs, random_deck picks one. An invariant that never fires is
  -- an invariant doing its job.
  if deck_royals(p_deck) <> 1 then
    raise exception 'a kingdom is exactly one royal and % others, not %',
      deck_size() - 1, deck_royals(p_deck);
  end if;

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

    -- 0049: THE SNAPSHOT. Copied onto the unit the moment its army is
    -- built -- the same instant every other stat is copied -- so a card
    -- retuned in the editor mid-match never changes a game already
    -- running. Runtime (cn_run_effects) reads this and never re-joins
    -- `card_effects` once a match exists.
    select coalesce(jsonb_agg(jsonb_build_object(
             'trigger', ce.trigger, 'target_selector', ce.target_selector,
             'action', ce.action, 'value', ce.value, 'status', ce.status,
             'stat_name', ce.stat_name, 'conditions', ce.conditions,
             'sort', ce.sort) order by ce.sort), '[]'::jsonb)
      into v_script
      from public.card_effects ce where ce.card_id = c.id;

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
    -- The parenthesis matters: `||` is left-associative, so without it the
    -- second object below would be appended to the ARRAY as a unit of its
    -- own rather than merged into the one being built.
    v_units := v_units || (jsonb_build_object(
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
      'abilityTurns', c.ability_turns, 'summonKind', c.summon_kind,
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
      'x', vx, 'y', vy, 'moved', false, 'acted', false)
      -- A SECOND OBJECT, and not a fiftieth pair in the first one.
      -- jsonb_build_object takes at most a hundred arguments and the unit
      -- snapshot had reached exactly a hundred, so 0037 pushed it over and
      -- every match in the suite died with 'cannot pass more than 100
      -- arguments to a function'. Concatenating is the same value, the same
      -- one statement, and it has room for the next twenty.
      || jsonb_build_object('swamps', c.swamps, 'abilityScript', v_script));
  end loop;
  return v_units;
end
$function$
;
CREATE OR REPLACE FUNCTION public.cn_set_ready(p_match uuid, p_side text, p_force boolean)
 RETURNS matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare m public.matches; v_st jsonb; v_host jsonb; v_guest jsonb; v_first text;
begin
  select * into m from public.matches where id = p_match for update;
  if m.status <> 'deploying' then return m; end if;

  v_st := m.state;
  if p_force then
    v_st := jsonb_set(v_st, '{ready}', jsonb_build_object('host', true, 'guest', true));
    v_st := state_log(v_st, 'Deployment time ran out.');
  else
    v_st := jsonb_set(v_st, array['ready', p_side], 'true'::jsonb);
    v_st := state_log(v_st,
      case when p_side = 'host' then m.host_name else m.guest_name end || ' is ready.');
  end if;

  if not ((v_st->'ready'->>'host')::boolean and (v_st->'ready'->>'guest')::boolean) then
    update public.matches set state = v_st, updated_at = now()
     where id = m.id returning * into m;
    return m;
  end if;

  -- Both ready: this is the first moment either of you may see the other, so
  -- this is where the two halves become one board.
  select units into v_host  from public.match_deploy where match_id = p_match and side = 'host';
  select units into v_guest from public.match_deploy where match_id = p_match and side = 'guest';
  if v_host is not null and v_guest is not null then
    v_st := jsonb_set(v_st, '{units}', v_host || v_guest);
  end if;

  -- 0049: ON_PLAY. Fired here, and not in deploy_unit, because this IS
  -- "the first moment either of you may see the other" per the comment
  -- just above -- deploy_unit only repositions a unit within one side's
  -- own hidden staging area, before the other army even exists on this
  -- board, which is not a meaningful moment for a trigger that might
  -- target an enemy. Every unit gets one pass, additively; a unit with no
  -- ON_PLAY rows in its abilityScript costs cn_run_effects one cheap
  -- early-out and nothing else.
  if v_st->'units' is not null then
    declare v_u jsonb;
    begin
      for v_u in select * from jsonb_array_elements(v_st->'units') loop
        v_st := cn_run_effects(v_st, 'ON_PLAY', v_u, jsonb_build_object('turnNumber', 1));
      end loop;
    end;
  end if;

  -- Who opens is a coin, not a seat. Before this the host moved first in every
  -- mode -- and the host is whoever pressed the button: the human in practice,
  -- the one who made the room among friends. Ranked already flipped a coin for
  -- the SEAT (0012), which sorted ranked and nothing else. Flipping here sorts
  -- all of them at once, because every mode arrives at this line, and it flips
  -- at the start of the battle rather than at creation so deployment is
  -- untouched.
  --
  -- cn.first_side is the tests' way in. A suite that cannot predict who acts
  -- first fails one run in two, and neither a random test nor a rigged game is
  -- worth having.
  v_first := nullif(current_setting('cn.first_side', true), '');
  if v_first is null or v_first not in ('host', 'guest') then
    v_first := case when random() < 0.5 then 'host' else 'guest' end;
  end if;

  v_st := jsonb_set(v_st, '{phase}', '"battle"'::jsonb);
  v_st := jsonb_set(v_st, '{turn}', to_jsonb(v_first));
  v_st := jsonb_set(v_st, '{turnNumber}', '1'::jsonb);
  v_st := state_log(v_st, 'Turn 1 — ' ||
    case when v_first = 'host' then m.host_name else m.guest_name end || ' to act.');

  update public.matches
     set state = v_st, status = 'active',
         turn_deadline = now() + interval '30 seconds', updated_at = now()
   where id = m.id returning * into m;
  return m;
end $function$
;
CREATE OR REPLACE FUNCTION public.advance_turn(p_match uuid, p_note text, p_timeout boolean)
 RETURNS matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    -- Read through cn_awake, not off u: a Sarrave standing next to Umiro
    -- poisons nothing. u itself is left alone because this loop's whole job
    -- is to hand the untouched rows to the next one.
    if u->>'owner' = v_next
       and coalesce((cn_awake(st, u)->>'poisonsAdj')::boolean, false)
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

    -- Same again for Wuzu. Note `st` and not the half-rebuilt out_u: the
    -- swamp is a fact about where everybody is standing, and everybody is
    -- standing where this turn found them.
    if u->>'owner' = v_next and coalesce((cn_awake(st, u)->>'regenPct')::int, 0) > 0
       and (u->>'hp')::int > 0 and (u->>'hp')::int < (u->>'maxHp')::int then
      v_got := least((u->>'maxHp')::int - (u->>'hp')::int,
                     greatest(1, round((u->>'maxHp')::int
                              * coalesce((cn_awake(st, u)->>'regenPct')::int, 0)
                              / 100.0)::int));
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

  -- 0049: END_OF_TURN (the side whose turn just ended) then START_OF_TURN
  -- (the side about to act), fired once each per eligible unit, right
  -- where turn ownership is about to flip below -- additive, and after
  -- every other end-of-turn bookkeeping above (idle count, mist, Sarrave's
  -- poison, Wuzu's regen) so a scripted effect sees the board exactly as
  -- the next player will.
  for u in select * from jsonb_array_elements(coalesce(st->'units', '[]'::jsonb)) loop
    if u->>'owner' = v_who and jsonb_typeof(u->'abilityScript') = 'array'
       and jsonb_array_length(u->'abilityScript') > 0 then
      st := cn_run_effects(st, 'END_OF_TURN', u, jsonb_build_object('turnNumber', v_turn));
    end if;
  end loop;
  for u in select * from jsonb_array_elements(coalesce(st->'units', '[]'::jsonb)) loop
    if u->>'owner' = v_next and jsonb_typeof(u->'abilityScript') = 'array'
       and jsonb_array_length(u->'abilityScript') > 0 then
      st := cn_run_effects(st, 'START_OF_TURN', u, jsonb_build_object('turnNumber', v_turn));
    end if;
  end loop;

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
$function$
;
CREATE OR REPLACE FUNCTION public.cn_ability(p_match uuid, p_side text, p_unit text, p_target text)
 RETURNS matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  m public.matches; v_st jsonb; u jsonb; e jsonb;
  v_me jsonb; v_tgt jsonb; v_kind text; v_n int;
  v_out jsonb := '[]'::jsonb; v_rocks jsonb := '[]'::jsonb;
  v_hits jsonb := '[]'::jsonb; v_swings jsonb := '[]'::jsonb;
  v_dist int; v_got int; v_hp int; v_felled boolean := false;
  v_dx int; v_dy int; v_what text; v_tile int[];
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

  -- Said out loud rather than left to fall through cn_awake into 'that unit
  -- has no ability'. "Not this card" and "not while you are standing there"
  -- are different news, and a player who cannot tell them apart will think
  -- the game is broken rather than that they are being beaten.
  if cn_swamped(v_st, v_me) then raise exception 'that unit is in the swamp'; end if;
  v_me := cn_awake(v_st, v_me);

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

  -- ---- putting something on the board -------------------------------------
  -- One branch for all three summoners. What appears is the card's
  -- `summonKind`, how hard it is to remove is cn_obj_hp's business, and what
  -- it does when trodden on is cn_move's -- so Fey, Mako and Lumea differ by
  -- one column and nothing else, and F5 changes the tornado without coming
  -- back here.
  elsif v_kind = 'summon' then
    v_what := v_me->>'summonKind';
    if v_what is null then raise exception 'that unit summons nothing'; end if;

    -- ONE ALIVE AT A TIME, asked before anything else so the refusal names
    -- the real reason rather than whatever the chosen tile happens to be.
    for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
      if e->>'by' = p_unit then raise exception 'that summon is still standing'; end if;
    end loop;

    v_tile := cn_tile_target(p_target);
    if v_tile is null then raise exception 'that ability needs a tile'; end if;
    if v_tile[1] < 0 or v_tile[2] < 0
       or v_tile[1] >= (v_st->'board'->>'w')::int
       or v_tile[2] >= (v_st->'board'->>'h')::int then
      raise exception 'that tile is not on the board';
    end if;
    v_dist := cn_cheb((v_me->>'x')::int, (v_me->>'y')::int, v_tile[1], v_tile[2]);
    if v_dist < 1 or v_dist > (v_me->>'rmax')::int then
      raise exception 'out of range';
    end if;
    if not cn_los_clear(v_st, (v_me->>'x')::int, (v_me->>'y')::int,
                        v_tile[1], v_tile[2]) then
      raise exception 'a tree is in the way';
    end if;

    for u in select * from jsonb_array_elements(v_st->'units') loop
      if (u->>'x')::int = v_tile[1] and (u->>'y')::int = v_tile[2] then
        raise exception 'that tile is taken';
      end if;
      v_out := v_out || u;
    end loop;
    for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
      if (e->>'x')::int = v_tile[1] and (e->>'y')::int = v_tile[2] then
        raise exception 'that tile is taken';
      end if;
      v_rocks := v_rocks || e;
    end loop;

    -- The damage rides on the OBJECT rather than being looked up from the
    -- summoner when somebody treads on it: Mako can be long dead by then.
    v_rocks := v_rocks || jsonb_build_object(
      'id', 's' || v_seq || ':' || p_unit, 'kind', v_what,
      'x', v_tile[1], 'y', v_tile[2],
      'hp', cn_obj_hp(v_what), 'maxHp', cn_obj_hp(v_what),
      'owner', p_side, 'by', p_unit, 'dmg', v_n);
    v_st := jsonb_set(v_st, '{obstacles}', v_rocks);
    v_note := (v_me->>'name') || ' sets down ' || cn_obj_name(v_what) || '.';


  -- ---- 0049: soft-coded, through the new engine --------------------------
  elsif v_kind = 'scripted' then
    declare v_ctx jsonb := jsonb_build_object('turnNumber', coalesce((v_st->>'turnNumber')::int, 1));
    begin
      if v_tgt is not null then v_ctx := v_ctx || jsonb_build_object('target', v_tgt); end if;
      if p_target is not null and left(p_target, 1) = '@' then
        v_ctx := v_ctx || jsonb_build_object('tile', p_target);
      end if;
      v_st := cn_run_effects(v_st, 'ON_ABILITY', v_me, v_ctx);
    end;
    v_out := v_st->'units';
    v_note := (v_me->>'name') || ' uses ' ||
      coalesce(nullif(btrim(split_part(v_me->>'ability', '—', 1)), ''), 'an ability') || '.';
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
end $function$
;
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
      -- AND YOUR OWN SIDE DOES NOT CATCH YOUR BLADE EITHER. A parry is not
      -- only a block: it flips the swing, so the parrier strikes back. An
      -- ally that parried would therefore answer, which is the rule two lines
      -- up read backwards. One `not v_ally` at the roll takes the whole chain
      -- off, and a friendly blow becomes the single beat it should be.
      v_parried := not v_ally
                   and not coalesce((v_strk->>'slippery')::boolean, false)
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
      if not v_killed_tgt then
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
      end if;
    end loop;
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
    if v_win_uid is not null then
      select count(*), array_agg(distinct u->>'role') into v_win_count, v_win_roles
        from jsonb_array_elements(v_out) u
       where u->>'owner' = v_win and not coalesce((u->>'royal')::boolean, false);
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
$function$
;
