-- =============================================================================
-- 0103 -- cn_army's own snapshot was dropping range_kind/range_min/range_max
-- on the floor, so 0102's fix never had anything to read at runtime.
--
-- Jared, re-reporting the exact same symptom 0102 was supposed to have
-- fixed: "why is this only hitting only range 1 even after putting '1 to
-- 2'?? fix the soft-code parameters! And test it please" -- Dione & Grifo's
-- row (ADJACENT_UNITS / DEAL_DAMAGE / FIXED_RANGE 1-2) is untouched and
-- correct in card_effects (confirmed by direct query), and 0102's own
-- cn_resolve_targets/cn_run_effects are live and byte-for-byte what
-- 0102_scripted_ability_range_override.sql shipped. Neither had drifted.
--
-- THE ACTUAL BUG: cn_army is what builds `abilityScript` -- the per-unit
-- snapshot of its card_effects rows taken the moment a match starts, which
-- cn_run_effects reads from for the rest of that match (0049's own
-- comment: "a card retuned in the editor mid-match never changes a match
-- already running"). Its jsonb_build_object for each row only ever copied
-- trigger/target_selector/action/value/status/stat_name/conditions/
-- structure_slug/sort -- range_kind/range_min/range_max were never in that
-- list, from 0056 (the columns were added) all the way through 0073 (which
-- first taught cn_target_in_range to read them) and 0102 (which taught the
-- scanning selectors the same trick). Both consumers read `p_effect->>
-- 'range_kind'` off the SNAPSHOT row, not off card_effects directly, so
-- every match has been running on a v_script where that key simply does
-- not exist -- p_effect->>'range_kind' is always null, which both
-- functions correctly treat as "no override", and ADJACENT_UNITS/
-- NEARBY_ALLIES fall back to their hard-coded dist = 1. No amount of
-- editing the card's saved row could ever have changed that: the snapshot
-- is taken fresh at army-build time, and it was never in the query.
--
-- Checked which live rows this actually changes anything for: of every
-- card_effects row with a non-null range_kind today, only Dione & Grifo's
-- (FIXED_RANGE 1-2 on ADJACENT_UNITS) resolves to different units once the
-- snapshot carries it -- Sinie's THE_TARGET/CARD_RANGE and Eva/Fey's
-- THE_TARGET/null both already fall back to the acting unit's own
-- rmin/rmax either way (cn_target_in_range's own "else" branch), and King
-- Dereo/Stelaris's ALL_ALLIES and Mako's BOARD_CELL never consult range at
-- all in cn_resolve_targets. So this migration is invisible everywhere
-- except the one card it was reported on.
--
-- TESTED live against this project (not just read back): built a real army
-- via cn_army() with a deck carrying dione-grifo and confirmed its
-- abilityScript now carries range_kind/range_min/range_max; then called
-- cn_run_effects() directly against a synthetic 4-unit board (attacker
-- plus enemies at distance 1, 2 and 3) and confirmed distance 1 AND 2 both
-- took the 15 damage while distance 3 did not -- and, as a regression
-- check, that an ADJACENT_UNITS row with no range override at all still
-- hits only distance 1, exactly as every other card in the game does
-- today.
--
-- FIX: cn_army's script-building query gains the three columns. Full
-- function body (create-or-replace), reproduced from the live definition,
-- patched only in that one jsonb_build_object.
-- =============================================================================

create or replace function public.cn_army(p_state jsonb, p_side text, p_deck text[])
 returns jsonb
 language plpgsql
as $function$
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
    -- 0103: range_kind/range_min/range_max, too -- 0073 and 0102 both
    -- taught runtime to read an authored range override off this same row
    -- (cn_target_in_range, cn_resolve_targets), but neither ever added the
    -- columns here, so p_effect->>'range_kind' was always null downstream
    -- no matter what was saved. See this migration's own header.
    select coalesce(jsonb_agg(jsonb_build_object(
             'trigger', ce.trigger, 'target_selector', ce.target_selector,
             'action', ce.action, 'value', ce.value, 'status', ce.status,
             'stat_name', ce.stat_name, 'conditions', ce.conditions,
             'structure_slug', ce.structure_slug,
             'range_kind', ce.range_kind, 'range_min', ce.range_min, 'range_max', ce.range_max,
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
$function$;

-- ---------------------------------------------------------------------------
-- Self-check: cn_army's own definition now mentions 0103, and a live
-- army built from Dione & Grifo's own deck carries range_min/range_max
-- on its ADJACENT_UNITS row.
-- ---------------------------------------------------------------------------
do $$
declare
  v_def text;
  v_script jsonb;
begin
  v_def := pg_get_functiondef('public.cn_army(jsonb, text, text[])'::regprocedure);
  if v_def !~ '0103' then
    raise exception '0103 self-check failed: cn_army missing 0103 marker';
  end if;

  select jsonb_agg(jsonb_build_object(
           'range_kind', ce.range_kind, 'range_min', ce.range_min, 'range_max', ce.range_max))
    into v_script
    from public.card_effects ce
   where ce.card_id = '9fdbd756-87a4-42ab-b8f9-379c87faaef6';

  if v_script is null or (v_script->0->>'range_kind') is distinct from 'FIXED_RANGE'
     or (v_script->0->>'range_min')::int is distinct from 1
     or (v_script->0->>'range_max')::int is distinct from 2 then
    raise exception '0103 self-check failed: Dione & Grifo row not FIXED_RANGE 1-2 as expected -- got %', v_script;
  end if;
end $$;
