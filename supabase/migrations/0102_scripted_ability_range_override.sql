-- =============================================================================
-- 0102 -- an ability's own range overrides the card's, for the scanning
-- selectors too.
--
-- Jared: "what doesn't work now is the range of the ability, it doesn't
-- matter what numbers I put there, nothing happens. I put that I want the
-- damage to happen between a range of 1 and 2 ... but regardless, it only
-- happens always in range 1, maybe because that card's max range is 1.
-- Let's fix this! An ability's range should override the card's."
--
-- Dione & Grifo's own row is ADJACENT_UNITS / DEAL_DAMAGE / FIXED_RANGE
-- 2-2 (the sentence builder screenshot showed 1-2, since edited) -- a
-- fixed-range override on a scanning selector the range plumbing was
-- never wired into.
--
-- WHY it did nothing: range_kind/range_min/range_max have existed on
-- card_effects since 0056, but 0073 wired them into exactly one place --
-- cn_target_in_range, called from cn_run_effects only for the THE_TARGET
-- selector. 0073's own header said so explicitly: "Every other selector
-- is untouched: BOARD_CELL, THE_ATTACKER and the scanning selectors
-- either already carry their own range logic or don't need one." That
-- assumption doesn't hold for ADJACENT_UNITS (hard-coded to
-- Chebyshev distance = 1) or the other distance-gated scanning selectors,
-- which is exactly what Dione & Grifo's row needs.
--
-- FIX: cn_resolve_targets gains a fifth argument, p_effect (the
-- card_effects row, default null so every existing 4-arg call site --
-- the structures path included, which has no range_kind concept at all
-- -- keeps its exact current behaviour unchanged). The four selectors
-- that already enforce a hard-coded distance rule (ADJACENT_UNITS,
-- NEARBY_ALLIES: dist = 1; ENEMY_IN_RANGE, RANDOM_ENEMY_IN_RANGE: the
-- acting unit's own rmin/rmax) now check p_effect's range_kind first:
--   - FIXED_RANGE: p_effect's own range_min/range_max, exactly like
--     cn_target_in_range's own FIXED_RANGE branch.
--   - ANYWHERE: no distance check at all.
--   - CARD_RANGE, or range_kind not set: unchanged -- the selector's
--     existing hard-coded rule (dist = 1, or the unit's rmin/rmax), so
--     every other card in play (range_kind is null on every row that
--     isn't Dione & Grifo, Sinie or Velmor) behaves exactly as it does
--     today.
-- Postgres treats an added parameter as a new signature even with a
-- default, so the old 4-arg function is dropped first -- the same
-- "drop, then create" 0100 already used for admin_update_profile.
--
-- cn_run_effects (the only caller that ever has a real card_effects row
-- in hand) is updated to pass it. The structures path
-- (cn_resolve_structure_targets, called from cn_run_structure_effects)
-- keeps calling the 4-arg-equivalent (p_effect defaults to null) --
-- structure_effects has no range_kind column, so there is nothing to
-- pass, and its behaviour is unchanged by this migration.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. cn_resolve_targets -- new p_effect parameter, range-aware
--    ADJACENT_UNITS / NEARBY_ALLIES / ENEMY_IN_RANGE / RANDOM_ENEMY_IN_RANGE.
--    Full body (create-or-replace), not a diff -- same fidelity discipline
--    0101 used: reproduced from 0074's definition, patched only where noted.
-- ---------------------------------------------------------------------------
drop function if exists public.cn_resolve_targets(jsonb, text, jsonb, jsonb);

create or replace function public.cn_resolve_targets(
  v_st jsonb, p_selector text, p_unit jsonb, p_context jsonb, p_effect jsonb default null
)
 returns jsonb
 language plpgsql
 set search_path to 'public'
as $function$
declare
  v_out jsonb := '[]'::jsonb;
  v_candidates jsonb := '[]'::jsonb;
  u jsonb; v_owner text; v_dist int; v_ux int; v_uy int;
  v_best_id text; v_best_val int; v_count int; v_idx int;
  -- 0102: an authored range override for the distance-gated scanning
  -- selectors below. v_rmin/v_rmax null means "no override configured --
  -- use this selector's own hard-coded rule", exactly as before this
  -- migration.
  v_rkind text := p_effect->>'range_kind';
  v_rmin int; v_rmax int; v_ranywhere boolean := false;
begin
  v_owner := p_unit->>'owner';
  v_ux := (p_unit->>'x')::int;
  v_uy := (p_unit->>'y')::int;

  if v_rkind = 'FIXED_RANGE' then
    v_rmin := coalesce((p_effect->>'range_min')::int, 1);
    v_rmax := coalesce((p_effect->>'range_max')::int, 1);
  elsif v_rkind = 'CARD_RANGE' then
    v_rmin := coalesce((p_unit->>'rmin')::int, 1);
    v_rmax := coalesce((p_unit->>'rmax')::int, 1);
  elsif v_rkind = 'ANYWHERE' then
    v_ranywhere := true;
  end if;

  if p_selector = 'SELF' then
    return jsonb_build_array(p_unit->>'id');
  elsif p_selector = 'THE_ATTACKER' then
    return case when p_context->'attacker'->>'id' is not null
                then jsonb_build_array(p_context->'attacker'->>'id') else '[]'::jsonb end;
  elsif p_selector = 'THE_TARGET' then
    return case when p_context->'target'->>'id' is not null
                then jsonb_build_array(p_context->'target'->>'id') else '[]'::jsonb end;
  elsif p_selector = 'BOARD_CELL' then
    return case when coalesce(p_context->>'tile', '') <> ''
                then jsonb_build_array(p_context->>'tile') else '[]'::jsonb end;
  elsif p_selector = 'LAST_DEAD_ALLY' then
    return case when jsonb_array_length(coalesce(v_st->'graveyard'->v_owner, '[]'::jsonb)) > 0
                then jsonb_build_array('#' ||
                  (v_st->'graveyard'->v_owner->(jsonb_array_length(v_st->'graveyard'->v_owner) - 1)->>'id'))
                else '[]'::jsonb end;
  end if;

  for u in select * from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) loop
    continue when (u->>'hp')::int <= 0;
    v_dist := cn_cheb(v_ux, v_uy, (u->>'x')::int, (u->>'y')::int);

    if p_selector = 'NEARBY_ALLIES' then
      if u->>'owner' = v_owner and u->>'id' <> p_unit->>'id'
         and (v_ranywhere
              or (v_rmin is not null and v_dist >= v_rmin and v_dist <= v_rmax)
              or (v_rmin is null and v_dist = 1)) then
        v_out := v_out || to_jsonb(u->>'id');
      end if;
    elsif p_selector = 'ALL_ALLIES' then
      if u->>'owner' = v_owner then v_out := v_out || to_jsonb(u->>'id'); end if;
    elsif p_selector = 'ALL_ENEMIES' then
      if u->>'owner' <> v_owner then v_out := v_out || to_jsonb(u->>'id'); end if;
    elsif p_selector = 'ADJACENT_UNITS' then
      if u->>'id' <> p_unit->>'id'
         and (v_ranywhere
              or (v_rmin is not null and v_dist >= v_rmin and v_dist <= v_rmax)
              or (v_rmin is null and v_dist = 1)) then
        v_out := v_out || to_jsonb(u->>'id');
      end if;
    elsif p_selector = 'ENEMY_IN_RANGE' then
      if u->>'owner' <> v_owner
         and (v_ranywhere
              or (v_rmin is not null and v_dist >= v_rmin and v_dist <= v_rmax)
              or (v_rmin is null and v_dist >= coalesce((p_unit->>'rmin')::int, 1)
                                 and v_dist <= coalesce((p_unit->>'rmax')::int, 1))) then
        v_out := v_out || to_jsonb(u->>'id');
      end if;
    elsif p_selector = 'RANDOM_ENEMY_IN_RANGE' then
      if u->>'owner' <> v_owner
         and (v_ranywhere
              or (v_rmin is not null and v_dist >= v_rmin and v_dist <= v_rmax)
              or (v_rmin is null and v_dist >= coalesce((p_unit->>'rmin')::int, 1)
                                 and v_dist <= coalesce((p_unit->>'rmax')::int, 1))) then
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

-- ---------------------------------------------------------------------------
-- 2. cn_run_effects -- pass the effect row through so cn_resolve_targets
--    can see it. Everything else here is byte-for-byte 0073's version.
-- ---------------------------------------------------------------------------
create or replace function public.cn_run_effects(v_st jsonb, p_trigger text, p_unit jsonb, p_context jsonb)
 returns jsonb
 language plpgsql
 set search_path to 'public'
as $function$
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

    -- 0102: v_row (this effect) now passed through as p_effect, so the
    -- distance-gated scanning selectors (ADJACENT_UNITS etc.) can honour
    -- an authored range_kind/range_min/range_max override the same way
    -- THE_TARGET already does via cn_target_in_range below.
    v_targets := cn_resolve_targets(v_st, v_row->>'target_selector', v_self_cur, v_ctx, v_row);
    for v_tid in select * from jsonb_array_elements_text(coalesce(v_targets, '[]'::jsonb)) loop
      -- 0073: THE_TARGET carries no built-in range/LOS check -- see this
      -- migration's header. Every other selector either scans with its own
      -- distance logic already (ENEMY_IN_RANGE etc.) or targets something
      -- range doesn't apply to (SELF, BOARD_CELL, THE_ATTACKER), so the
      -- gate is scoped to THE_TARGET alone.
      if v_row->>'target_selector' = 'THE_TARGET'
         and not cn_target_in_range(v_st, v_row, v_self_cur, v_tid) then
        continue;
      end if;
      v_st := cn_effect_apply_action(v_st, v_row, v_self_cur, v_tid, v_ctx);
    end loop;
  end loop;

  return v_st;
end
$function$;

-- ---------------------------------------------------------------------------
-- 3. Self-check.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_proc
     where proname = 'cn_resolve_targets'
       and pronargs = 5
  ) then
    raise exception '0102 self-check failed: 5-arg cn_resolve_targets not found';
  end if;
  if exists (
    select 1 from pg_proc
     where proname = 'cn_resolve_targets'
       and pronargs = 4
  ) then
    raise exception '0102 self-check failed: old 4-arg cn_resolve_targets still present';
  end if;
  if (pg_get_functiondef('public.cn_run_effects(jsonb,text,jsonb,jsonb)'::regprocedure) !~ '0102') then
    raise exception '0102 self-check failed: cn_run_effects missing 0102 marker';
  end if;
end $$;
