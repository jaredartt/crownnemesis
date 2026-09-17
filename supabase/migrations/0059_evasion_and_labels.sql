-- =============================================================================
-- 0059 -- EVASION, and the two other pieces of Jared's UI-cleanup pass this
-- migration's own half covers: flat-HP condition fields, and clearing SLIPPERY/
-- FLIES out of the passive-stat AUTHORING list without touching either column
-- or any existing card's saved data.
--
-- Jared's ask, after the Mad-Libs labelling pass: "Remove 'Slippery', I don't
-- think it makes sense to include a unit's ability in there. But do include
-- evasion as a property inside the Mad Libs thing." Asked directly whether
-- this should be a relabel of the existing Slippery mechanic (safe, zero
-- engine risk) or a real new dodge-chance stat, Jared chose the real thing:
-- EVASION_PCT is a genuine new roll in cn_attack, not a rename.
--
-- WHAT THIS MIGRATION DOES NOT TOUCH, on purpose:
--   - `cards.slippery` and `cards.flies` stay exactly as they are -- both
--     columns, `cn_check_card`'s `flies`-from-`role` derivation, and
--     `cn_compile_card_effects`'s SLIPPERY case are all untouched. Himanta's
--     existing `card_effects` row (stat_name='SLIPPERY') keeps compiling and
--     keeps working at runtime, unchanged. `card_effects_stat_name_check`
--     keeps BOTH values in its allowed list for exactly that reason -- this
--     migration only removes them from AdminCards.tsx's OFFERED list (see
--     that file's own diff), which is a client-side authoring-vocabulary cut,
--     not a schema or engine change. A card that already picked either one
--     is not retroactively touched.
--   - Nothing about `role='flying'` or its two auras
--     (`AURA_RESIST_FLYING`/`AURA_BONUS_FLYING`) changes. Those key off
--     `role`/`aura_class`, never off the `flies` boolean, which is why
--     removing `flies` from the builder cannot touch them.
--
-- WHAT IS GENUINELY NEW:
--   - `cards.evasion_pct` (0-100, default 0) -- a new PASSIVE-compilable AND
--     runtime-patchable percentage, the same dual shape `PARRY_PCT`/
--     `CRIT_PCT` already have (see `cn_compile_card_effects`'s own header on
--     why those nine are runtime-only and this one is not: evasion has no
--     `cn_check_card`-recomputed base value to double-count against, so a
--     PASSIVE default is safe here the way it is for `TWICE_PCT`/
--     `REGEN_PCT`).
--   - `cn_attack` rolls it ONCE per attack, on the DEFENDER, before the
--     Quick Dagger check and before the swing/chain loop even starts --
--     deliberately NOT a per-swing check like the Mist's `cn_mist_dodge`
--     (Eva's ability, a temporary per-match cloud) or like the parry roll
--     inside the chain (which still lets the parrier answer). Evasion is
--     categorical: "this blow never connects; nothing about it happened at
--     all" -- no damage, no burn transfer, no ordinary counter, no Quick
--     Dagger, no chain, exactly what Jared asked for ("no damage, no
--     counter"). Reuses `cn_chance()` exactly as parry/crit/twice/mist
--     already do, which means `cn.force_evasion` (a GUC nobody has to add --
--     `cn_chance` builds the setting name from whatever `p_kind` it is
--     given) is already available to tests for free, and every EXISTING
--     card is unaffected without a single other test file's `SET`
--     statement needing to change: `evasion_pct` defaults to 0, and
--     `cn_chance(0, ...)` returns false before it ever reads a force
--     setting -- see that function's own short-circuit.
--   - `self.hp`/`target.hp` -- flat-value siblings of the existing
--     `self.hp_pct`/`target.hp_pct` condition fields, so a passive can read
--     "< 20" as much as "< 50%". Structurally identical branch to the
--     `_pct` one in `cn_effect_condition_met`, minus the percentage
--     normalisation.
-- =============================================================================

-- -----------------------------------------------------------------------
-- 1. cards.evasion_pct
-- -----------------------------------------------------------------------
alter table public.cards add column if not exists evasion_pct integer not null default 0;
alter table public.cards drop constraint if exists cards_evasion_pct_check;
alter table public.cards add constraint cards_evasion_pct_check
  check (evasion_pct >= 0 and evasion_pct <= 100);

-- -----------------------------------------------------------------------
-- 2. card_effects.stat_name gains EVASION_PCT. SLIPPERY and FLIES are left
--    exactly where they are -- see this migration's header.
-- -----------------------------------------------------------------------
alter table public.card_effects drop constraint if exists card_effects_stat_name_check;
alter table public.card_effects add constraint card_effects_stat_name_check
  check (stat_name is null or stat_name = any (array[
    'SLIPPERY', 'TWICE_PCT', 'LIFESTEAL_PCT', 'PARRY_ALL', 'REGEN_PCT',
    'STUNS_ON_HIT', 'POISONS_ADJACENT', 'VS_POISONED_BONUS', 'CURES_BURN',
    'BLOOMS', 'SNEAKS', 'FLIES', 'TRAMPLES', 'PARRIES', 'BURNS', 'HEALS',
    'SWAMPS',
    'AURA_RESIST_KNIGHT', 'AURA_RESIST_ROGUE', 'AURA_RESIST_MAGE', 'AURA_RESIST_FLYING',
    'AURA_BONUS_KNIGHT', 'AURA_BONUS_ROGUE', 'AURA_BONUS_MAGE', 'AURA_BONUS_FLYING',
    'AURA_RESIST_EFFECTS',
    'HP', 'MOV', 'RMIN', 'RMAX', 'CRMIN', 'CRMAX', 'POWER', 'PARRY_PCT', 'CRIT_PCT',
    -- 0059
    'EVASION_PCT'
  ]));

-- -----------------------------------------------------------------------
-- 3. THE SPLICES -- cn_compile_card_effects, cn_army, cn_royale_army,
--    cn_effect_apply_action, cn_attack, cn_effect_condition_met. All
--    fetched fresh via pg_get_functiondef from this exact checkout
--    (0001-0058 applied) immediately before writing this file, and every
--    edit below round-trip-verified before being pasted in. Additive/
--    changed lines marked '0059' below.
-- -----------------------------------------------------------------------


CREATE OR REPLACE FUNCTION public.cn_compile_card_effects(p_card uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
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
    swamps = false, aura_kind = null, aura_class = null, aura_pct = null,
    evasion_pct = 0  -- 0059
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
      when 'EVASION_PCT'       then update public.cards set evasion_pct = coalesce(r.value, 0) where id = p_card;  -- 0059
      else null; -- HP/MOV/RMIN/RMAX/CRMIN/CRMAX/POWER/PARRY_PCT/CRIT_PCT: see header.
    end case;
  end loop;
end
$function$
;

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
  -- 0056: this unit's one Active sentence's cost, if it has one -- see this
  -- migration's header on why these three ride the snapshot like every
  -- other stat rather than being read live from card_ability_meta mid-match.
  v_meta record;
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
    -- 0057: structure_slug rides along too -- CREATE_STRUCTURE is the only
    -- action that reads it (cn_effect_apply_action), and every other action
    -- simply carries a null it never looks at.
    select coalesce(jsonb_agg(jsonb_build_object(
             'trigger', ce.trigger, 'target_selector', ce.target_selector,
             'action', ce.action, 'value', ce.value, 'status', ce.status,
             'stat_name', ce.stat_name, 'conditions', ce.conditions,
             'structure_slug', ce.structure_slug,
             'sort', ce.sort) order by ce.sort), '[]'::jsonb)
      into v_script
      from public.card_effects ce where ce.card_id = c.id;

    -- 0056: the one Active sentence's cost, if this card has one. Left
    -- null/false when it does not -- cn_ability's own splice treats a null
    -- abilityMaxUses/abilityCooldownTurns as "no limit", which is exactly
    -- today's unlimited-use behaviour for every card that predates this.
    select ability_type, max_uses, cooldown_turns into v_meta
      from public.card_ability_meta
     where card_id = c.id and ability_type = 'active'
     limit 1;

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
      || jsonb_build_object('swamps', c.swamps, 'abilityScript', v_script, 'evasionPct', c.evasion_pct)  -- 0059
      -- 0056: the Active sentence's cost, if any -- see cn_ability's own
      -- splice for how abilityUses/abilityLastUsedTurn (the RUNTIME
      -- counters, absent here on purpose) read these two.
      || jsonb_build_object(
           'abilityMaxUses', v_meta.max_uses,
           'abilityCooldownTurns', coalesce(v_meta.cooldown_turns, 0)));
  end loop;
  return v_units;
end
$function$
;

CREATE OR REPLACE FUNCTION public.cn_royale_army(p_state jsonb, p_seat integer, p_deck text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  v_zone int[] := cn_royale_zone(p_seat);
  v_taken text[] := '{}'; e jsonb; c public.cards;
  v_xs int[] := '{}'::int[]; v_ys int[] := '{}'::int[];
  i int; vx int; vy int; v_idx int := 0; v_units jsonb := '[]'::jsonb; v_done boolean;
begin
  if v_zone is null then raise exception 'no such seat %', p_seat; end if;

  if deck_royals(p_deck) <> 1 then
    raise exception 'a kingdom is exactly one royal and % others, not %',
      deck_size() - 1, deck_royals(p_deck);
  end if;

  for e in select * from jsonb_array_elements(coalesce(p_state->'obstacles', '[]'::jsonb)) loop
    v_taken := v_taken || ((e->>'x') || ',' || (e->>'y'));
  end loop;

  for i in v_zone[1] .. v_zone[2] loop v_xs := v_xs || i; end loop;

  if v_zone[3] = 0 then
    for i in v_zone[3] .. v_zone[4] loop v_ys := v_ys || i; end loop;
  else
    for i in reverse v_zone[4] .. v_zone[3] loop v_ys := v_ys || i; end loop;
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
    v_units := v_units || (jsonb_build_object(
      'id', 'r' || p_seat || 'u' || v_idx, 'owner', p_seat,
      'cardId', c.id, 'slug', c.slug, 'name', c.name, 'role', c.role,
      'hp', c.hp, 'maxHp', c.hp, 'mov', c.mov,
      'rmin', c.rmin, 'rmax', c.rmax, 'crmin', c.crmin, 'crmax', c.crmax,
      'dmin', c.dmin, 'dmax', c.dmax, 'pow', c.power,
      'parryPct', c.parry_pct, 'critPct', c.crit_pct, 'parryAll', c.parry_all,
      'royal', c.royal,
      'abilityKind', c.ability_kind, 'abilityN', c.ability_n,
      'abilityTurns', c.ability_turns, 'summonKind', c.summon_kind,
      'slippery', c.slippery, 'twicePct', c.twice_pct, 'regenPct', c.regen_pct,
      'poisonsAdj', c.poisons_adjacent, 'stuns', c.stuns,
      'vsPoisoned', c.vs_poisoned, 'lifestealPct', c.lifesteal_pct,
      'auraKind', c.aura_kind, 'auraClass', c.aura_class, 'auraPct', c.aura_pct,
      'burns', c.burns, 'heals', c.heals,
      'effects', cn_no_effects(),
      'flies', c.flies, 'sneaks', c.sneaks, 'cures', c.cures, 'tramples', c.tramples,
      'parries', c.parries, 'blooms', c.blooms,
      'accent', c.accent, 'art', c.art_url, 'ability', c.ability,
      'x', vx, 'y', vy, 'moved', false, 'acted', false)
      || jsonb_build_object('swamps', c.swamps, 'evasionPct', c.evasion_pct));  -- 0059
  end loop;
  return v_units;
end
$function$
;

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
    if v_action = 'CREATE_STRUCTURE' then
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

  -- REVIVE, REFLECT_DAMAGE_PCT, SUMMON_OBJECT and DRAW_CARD are documented
  -- no-ops -- see this migration's header and the card_effects.action
  -- column comment for exactly why each one is left unbuilt rather than
  -- guessed at. 0058 adds TRIGGER_PARRY and COUNTER_ATTACK_PCT to the same
  -- bucket for the same reason -- see 0058_parry_vocabulary.sql's header:
  -- forcing a guaranteed parry, or landing an authored percentage
  -- counter-strike, both mean new state inside cn_attack's swing loop, not
  -- something a generic target/action dispatch can do from out here.
  if v_action in ('REVIVE', 'REFLECT_DAMAGE_PCT', 'SUMMON_OBJECT', 'DRAW_CARD',
                   'TRIGGER_PARRY', 'COUNTER_ATTACK_PCT') then
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
$function$
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
    v_st := cn_run_structure_effects(v_st, 'ON_DESTROYED', v_tree,
      jsonb_build_object('attacker', v_atk, 'turnNumber', coalesce((v_st->>'turnNumber')::int, 1)));
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

CREATE OR REPLACE FUNCTION public.cn_effect_condition_met(p_cond jsonb, p_ctx jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
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

  -- 0059: the flat sibling of the _pct pair above -- same fields, same
  -- comparison table, no maxHp normalisation.
  elsif v_field in ('self.hp', 'target.hp') then
    v_side := split_part(v_field, '.', 1);
    v_num := coalesce((p_ctx->v_side->>'hp')::numeric, 0);
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
$function$
;


-- -----------------------------------------------------------------------
-- 4. Verification.
-- -----------------------------------------------------------------------
select
  (select count(*) = 1 from information_schema.columns
     where table_schema='public' and table_name='cards' and column_name='evasion_pct') as has_evasion_col,
  (select pg_get_constraintdef(oid) from pg_constraint
     where conrelid = 'public.card_effects'::regclass and conname = 'card_effects_stat_name_check')
    like '%EVASION_PCT%' as stat_check_has_evasion,
  (select pg_get_constraintdef(oid) from pg_constraint
     where conrelid = 'public.card_effects'::regclass and conname = 'card_effects_stat_name_check')
    like '%SLIPPERY%' as stat_check_still_has_slippery,
  (select pg_get_constraintdef(oid) from pg_constraint
     where conrelid = 'public.card_effects'::regclass and conname = 'card_effects_stat_name_check')
    like '%FLIES%' as stat_check_still_has_flies,
  (select count(*) = 1 from pg_proc where proname = 'cn_attack') as cn_attack_exists,
  (select count(*) = 1 from pg_proc where proname = 'cn_effect_condition_met') as cn_cond_exists;
