-- Jared, on Wuzu's own power-growing passive: "I want wuzu tu have a power
-- limit, cause it increments its attack by 4 each turn, and I want a limit
-- of turns that he can do that, can you fix this?" -- caught trying to
-- type 9 into the sentence builder's "for a number of turns" box on that
-- exact row and getting bounced by "Value must be less than or equal to 5".
--
-- What's actually going on is bigger than a UI cap. Wuzu's row is:
--   trigger=START_OF_TURN, action=MODIFY_STAT, stat=POWER, value=6,
--   duration_kind=FOR_TURNS, duration_turns=5
-- and it has ALREADY been saved with duration_turns=5 -- the field takes a
-- value today. It just does nothing with it. `duration_kind`/`duration_turns`
-- were added in 0056 as pure authoring metadata ("Mad-Libs" categories the
-- 0049 engine had no columns for at all) and 0056 said so plainly: real
-- enforcement was partial, and MODIFY_STAT was never on the partial list --
-- only APPLY_STATUS/STUN was ever claimed to read anything durationish, and
-- even that is really `value` (the stun's own turn count), not
-- `duration_turns`. Confirmed live: no function in this database's public
-- schema has ever referenced `duration_turns` (`select proname from pg_proc
-- where prosrc ilike '%duration_turn%'` returns zero rows), and cn_army's
-- own jsonb_build_object for a unit's abilityScript never even COPIED
-- duration_kind/duration_turns onto the runtime snapshot in the first
-- place -- so the number saved next to "for a number of turns" has never
-- once reached a live match, for any card, ever. Wuzu's power has been
-- climbing by 6 every single turn, forever, with no limit at all, the
-- entire time that field said "5".
--
-- Also confirmed live: Wuzu is the ONLY card in the database with
-- duration_kind set to FOR_TURNS at all (nine other rows use UNTIL_REMOVED,
-- which this migration never touches). So this is free to actually build
-- real enforcement for FOR_TURNS on a repeating trigger without any risk of
-- quietly nerfing something else that happened to have a number sitting in
-- an inert field.
--
-- The fix, in three parts:
--
--   1. cn_army now carries `id` (the card_effects row's own uuid) and
--      `duration_kind`/`duration_turns` onto each abilityScript row, and
--      gives every freshly-deployed unit a new `effectFires` counter
--      ({} to start) -- a jsonb map from effect id to how many times that
--      row has fired ON THIS UNIT so far this match.
--
--   2. cn_run_effects, which already loops every abilityScript row on
--      every matching trigger, now checks that counter for any row whose
--      duration_kind = 'FOR_TURNS': once effectFires[id] reaches
--      duration_turns, the row is skipped outright (same as a trigger or
--      condition mismatch) -- Wuzu's power simply stops climbing, wherever
--      it landed. A row's counter increments once per trigger occurrence
--      it actually ran for (right after its target loop, in the new
--      cn_bump_effect_fire helper), not once per target -- Wuzu's own
--      SELF-targeted row has exactly one target anyway, but this keeps a
--      multi-target FOR_TURNS row (should one ever exist) spending one of
--      its N turns per activation, not one per unit it happened to hit.
--      A row with duration_kind left at THIS_TURN/UNTIL_REMOVED/null, or
--      no duration_turns, is completely unaffected and keeps firing every
--      time it always did -- this is additive, not a behaviour change for
--      the other nine cards above.
--
--      A unit already deployed in a match still running when this ships
--      has an OLD abilityScript snapshot with no `id`/`duration_kind` on
--      its rows and no `effectFires` at all -- the new check reads those as
--      null/absent and simply never trips, so an in-flight game keeps
--      today's uncapped behaviour rather than having a cap sprung on it
--      mid-match. Only newly-deployed units (matches created after this
--      migration) get the real limit.
--
--   3. The UI/DB ceiling on "for a number of turns" moves from 5 to 20 --
--      both `card_effects_duration_turns_check` and the equivalent
--      structure_effects constraint, kept in step since SentenceBuilder.tsx
--      is the one shared control for both editors. 5 was never a
--      deliberate balance choice for a REPEATING passive cap (it predates
--      this cap existing at all -- it was picked in 0056 back when the
--      field was pure authoring metadata for a short one-off buff, and
--      never revisited for what it would mean once something actually read
--      it). 20 comfortably covers what Jared was already trying to type
--      (9) with real headroom, while still being a genuine limit rather
--      than "effectively unlimited" -- a very long match is still well
--      short of 20 of Wuzu's own turns.
--
-- Scope note, in the same spirit as 0056's own: structures have their own
-- structure_effects table and the same duration_kind/duration_turns
-- columns, raised here for consistency, but no structure currently sets
-- duration_kind at all and structures have no cn_run_effects-equivalent
-- runtime loop today -- so this migration does NOT add FOR_TURNS
-- enforcement for structures. That is a real, separate follow-up if one
-- ever needs it, not silently assumed here.

-- ---------------------------------------------------------------------------
-- 1. Raise the ceiling on "for a number of turns" from 5 to 20.
-- ---------------------------------------------------------------------------

alter table public.card_effects drop constraint if exists card_effects_duration_turns_check;
alter table public.card_effects add constraint card_effects_duration_turns_check
  check (duration_turns is null or duration_turns between 2 and 20);

alter table public.structure_effects drop constraint if exists structure_effects_duration_turns_check;
alter table public.structure_effects add constraint structure_effects_duration_turns_check
  check (duration_turns is null or duration_turns between 2 and 20);

-- ---------------------------------------------------------------------------
-- 2. cn_army: carry id/duration_kind/duration_turns onto abilityScript rows,
--    and give every freshly-deployed unit a fresh effectFires counter.
-- ---------------------------------------------------------------------------

do $$
declare def text; v_before text;
begin
  def := pg_get_functiondef('public.cn_army(jsonb,text,text[])'::regprocedure);
  v_before := def;
  def := replace(def,
    $rep$    select coalesce(jsonb_agg(jsonb_build_object(
             'trigger', ce.trigger, 'target_selector', ce.target_selector,
             'action', ce.action, 'value', ce.value, 'status', ce.status,
             'stat_name', ce.stat_name, 'conditions', ce.conditions,
             'structure_slug', ce.structure_slug,
             'range_kind', ce.range_kind, 'range_min', ce.range_min, 'range_max', ce.range_max,
             'sort', ce.sort) order by ce.sort), '[]'::jsonb)
      into v_script
      from public.card_effects ce where ce.card_id = c.id;$rep$,
    $rep$    select coalesce(jsonb_agg(jsonb_build_object(
             'id', ce.id,
             'trigger', ce.trigger, 'target_selector', ce.target_selector,
             'action', ce.action, 'value', ce.value, 'status', ce.status,
             'stat_name', ce.stat_name, 'conditions', ce.conditions,
             'structure_slug', ce.structure_slug,
             'range_kind', ce.range_kind, 'range_min', ce.range_min, 'range_max', ce.range_max,
             'duration_kind', ce.duration_kind, 'duration_turns', ce.duration_turns,
             'sort', ce.sort) order by ce.sort), '[]'::jsonb)
      into v_script
      from public.card_effects ce where ce.card_id = c.id;$rep$);
  if def = v_before then raise exception '0147: cn_army -- v_script build target text not found'; end if;
  v_before := def;

  def := replace(def,
    $rep$      || jsonb_build_object('swamps', c.swamps, 'abilityScript', v_script, 'evasionPct', c.evasion_pct)$rep$,
    $rep$      || jsonb_build_object('swamps', c.swamps, 'abilityScript', v_script, 'evasionPct', c.evasion_pct,
                             'effectFires', '{}'::jsonb)$rep$);
  if def = v_before then raise exception '0147: cn_army -- unit effectFires target text not found'; end if;
  execute def;
end $$;

-- ---------------------------------------------------------------------------
-- 3. cn_bump_effect_fire: the one place that increments a unit's per-effect
--    fire counter. Kept as its own tiny function (mirrors cn_bury/cn_afflict
--    -- a single-purpose unit-list rewrite) rather than inlined twice.
-- ---------------------------------------------------------------------------

create or replace function public.cn_bump_effect_fire(v_st jsonb, p_unit_id text, p_effect_id text)
 returns jsonb
 language plpgsql
as $function$
declare v_out jsonb := '[]'::jsonb; u jsonb; v_fires jsonb; v_cur int;
begin
  for u in select * from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) loop
    if u->>'id' = p_unit_id then
      v_fires := coalesce(u->'effectFires', '{}'::jsonb);
      v_cur := coalesce((v_fires->>p_effect_id)::int, 0);
      u := jsonb_set(u, '{effectFires}', jsonb_set(v_fires, array[p_effect_id], to_jsonb(v_cur + 1), true));
    end if;
    v_out := v_out || u;
  end loop;
  return jsonb_set(v_st, '{units}', v_out);
end
$function$;

-- ---------------------------------------------------------------------------
-- 4. cn_run_effects: skip a spent FOR_TURNS row instead of firing it again,
--    and count each row it does run for.
-- ---------------------------------------------------------------------------

do $$
declare def text; v_before text;
begin
  def := pg_get_functiondef('public.cn_run_effects(jsonb,text,jsonb,jsonb)'::regprocedure);
  v_before := def;

  def := replace(def,
    $rep$  v_self_cur jsonb; u jsonb; v_adjacent int;
begin$rep$,
    $rep$  v_self_cur jsonb; u jsonb; v_adjacent int;
  -- 0147: for-turns cap bookkeeping -- see this migration's header.
  v_effect_id text; v_fire_count int; v_for_turns_limit int;
begin$rep$);
  if def = v_before then raise exception '0147: cn_run_effects -- declare target text not found'; end if;
  v_before := def;

  def := replace(def,
    $rep$    if not cn_effect_conditions_met(coalesce(v_row->'conditions', '[]'::jsonb), v_ctx) then
      continue;
    end if;

    -- 0102: v_row (this effect) now passed through as p_effect, so the$rep$,
    $rep$    if not cn_effect_conditions_met(coalesce(v_row->'conditions', '[]'::jsonb), v_ctx) then
      continue;
    end if;

    -- 0147: a FOR_TURNS row only fires duration_turns times, ever, on the
    -- unit whose script owns it -- tracked per-effect (by its stable
    -- card_effects id, carried onto abilityScript by cn_army) in that
    -- unit's own effectFires counter. Untouched for any other duration_kind
    -- (or none), and for an old pre-0147 snapshot with no id on its rows.
    v_effect_id := v_row->>'id';
    if v_row->>'duration_kind' = 'FOR_TURNS' and v_row->>'duration_turns' is not null and v_effect_id is not null then
      v_for_turns_limit := (v_row->>'duration_turns')::int;
      v_fire_count := coalesce((v_self_cur->'effectFires'->>v_effect_id)::int, 0);
      if v_fire_count >= v_for_turns_limit then
        continue;
      end if;
    end if;

    -- 0102: v_row (this effect) now passed through as p_effect, so the$rep$);
  if def = v_before then raise exception '0147: cn_run_effects -- cap-check insertion target text not found'; end if;
  v_before := def;

  def := replace(def,
    $rep$      v_st := cn_effect_apply_action(v_st, v_row, v_self_cur, v_tid, v_ctx);
    end loop;
  end loop;

  return v_st;$rep$,
    $rep$      v_st := cn_effect_apply_action(v_st, v_row, v_self_cur, v_tid, v_ctx);
    end loop;

    -- 0147: this row got its turn -- count it once per trigger occurrence,
    -- not once per target, so a SELF row like Wuzu's own always counts
    -- cleanly and a row with a transient empty target list still spends
    -- one of its N turns rather than getting a free pass.
    if v_effect_id is not null and v_row->>'duration_kind' = 'FOR_TURNS' and v_row->>'duration_turns' is not null then
      v_st := cn_bump_effect_fire(v_st, p_unit->>'id', v_effect_id);
    end if;
  end loop;

  return v_st;$rep$);
  if def = v_before then raise exception '0147: cn_run_effects -- increment insertion target text not found'; end if;
  execute def;
end $$;
