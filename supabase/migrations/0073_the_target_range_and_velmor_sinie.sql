-- =============================================================================
-- 0073 -- THE_TARGET gets real range/LOS enforcement, a new `target.is_enemy`
-- condition field, and Sinie/Velmor move off cn_ability's legacy hard-coded
-- 'heal_any'/'poison_hit' branches onto the generic card_effects engine.
--
-- WHY: cn_resolve_targets' THE_TARGET branch just echoes back whatever unit
-- id the caller put in ctx.target (Board.tsx, via cn_ability's 'scripted'
-- branch) -- it does not check distance, rmin/rmax, or line of sight the
-- way ENEMY_IN_RANGE and friends do inline, or the way cn_attack enforces
-- for a basic strike. That's fine for effects that only ever run in
-- response to something ELSE (ON_ATTACK's THE_ATTACKER, say), but it means
-- any scripted ON_ABILITY effect that targets THE_TARGET -- exactly the
-- shape a player-aimed ability like Sinie's or Velmor's needs -- has no
-- server-side range gate at all today. A malicious or buggy client could
-- send any unit id on the board.
--
-- FIX: cn_target_in_range(v_st, p_effect, p_unit, p_target_id) reads the
-- effect row's own range_kind/range_min/range_max (CARD_RANGE = the acting
-- unit's own rmin/rmax, FIXED_RANGE = the row's range_min/range_max,
-- ANYWHERE = no check) plus cn_los_clear, and cn_run_effects calls it right
-- where it resolves a THE_TARGET id, before dispatching the action -- an
-- out-of-range/blocked target is silently skipped, the same "silent no-op"
-- convention CREATE_STRUCTURE's own guards already use (see 0064's header).
-- Every other selector is untouched: BOARD_CELL, THE_ATTACKER and the
-- scanning selectors either already carry their own range logic or don't
-- need one.
--
-- Sinie's healing has never restricted who it can land on (the old
-- heal_any branch applied HEAL with no owner check at all), so her single
-- HEAL row carries no condition. Velmor's old poison_hit branch DID refuse
-- an ally target with a hard exception ('no friendly fire') -- the
-- scripted equivalent can't raise mid-script the way a hard-coded branch
-- can, so it's expressed as a `target.is_enemy` condition on both of his
-- rows instead: a friendly-fire attempt becomes a silent no-op that still
-- spends the activation, matching every other scripted guard failure.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. target.is_enemy -- mirrors the existing is_royal_target pattern.
-- ---------------------------------------------------------------------------
create or replace function public.cn_effect_condition_met(p_cond jsonb, p_ctx jsonb)
 returns boolean
 language plpgsql
 set search_path to 'public'
as $function$
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

  -- 0073: is the chosen target on the other side? Mirrors is_royal_target
  -- immediately above -- true only when both self.owner and target.owner
  -- are present and differ, so a malformed/missing context reads as "not
  -- an enemy" rather than accidentally passing.
  elsif v_field = 'target.is_enemy' then
    v_bool := p_ctx->'target'->>'owner' is not null
              and p_ctx->'self'->>'owner' is not null
              and (p_ctx->'target'->>'owner') is distinct from (p_ctx->'self'->>'owner');
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
$function$;

-- ---------------------------------------------------------------------------
-- 2. cn_target_in_range -- the range/LOS gate THE_TARGET never had.
-- ---------------------------------------------------------------------------
create or replace function public.cn_target_in_range(v_st jsonb, p_effect jsonb, p_unit jsonb, p_target_id text)
 returns boolean
 language plpgsql
 set search_path to 'public'
as $function$
declare
  v_kind text := p_effect->>'range_kind';
  v_min int; v_max int;
  v_tgt jsonb; u jsonb;
  v_ux int; v_uy int; v_tx int; v_ty int; v_dist int;
begin
  if v_kind = 'ANYWHERE' then return true; end if;

  for u in select * from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) loop
    if u->>'id' = p_target_id then v_tgt := u; end if;
  end loop;
  if v_tgt is null then return false; end if;

  if v_kind = 'FIXED_RANGE' then
    v_min := coalesce((p_effect->>'range_min')::int, 1);
    v_max := coalesce((p_effect->>'range_max')::int, 1);
  else
    -- CARD_RANGE, and the default (null) -- the acting unit's own rmin/rmax,
    -- the same fallback cn_resolve_targets' own comment already promised.
    v_min := coalesce((p_unit->>'rmin')::int, 1);
    v_max := coalesce((p_unit->>'rmax')::int, 1);
  end if;

  v_ux := (p_unit->>'x')::int; v_uy := (p_unit->>'y')::int;
  v_tx := (v_tgt->>'x')::int;  v_ty := (v_tgt->>'y')::int;
  v_dist := cn_cheb(v_ux, v_uy, v_tx, v_ty);

  return v_dist >= v_min and v_dist <= v_max
     and cn_los_clear(v_st, v_ux, v_uy, v_tx, v_ty);
end
$function$;

-- ---------------------------------------------------------------------------
-- 3. cn_run_effects -- call the new gate for THE_TARGET, and only for it.
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

    v_targets := cn_resolve_targets(v_st, v_row->>'target_selector', v_self_cur, v_ctx);
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
-- 4. Sinie -- Healing Petals. One HEAL row, THE_TARGET, no restriction
--    (matches the old heal_any branch's total lack of an owner check).
--    range_kind CARD_RANGE reproduces the old "dist > rmax" check via
--    Sinie's own rmin(1)/rmax(3) -- rmin was never enforced by heal_any,
--    but board geometry makes rmin=1 unreachable to violate anyway (no two
--    units share a tile), so this is behaviourally identical, not just
--    close.
-- ---------------------------------------------------------------------------
update public.cards set ability_kind = 'scripted' where slug = 'sinie';

insert into public.card_effects (card_id, sort, trigger, target_selector, action, value, range_kind)
select id, 0, 'ON_ABILITY', 'THE_TARGET', 'HEAL', 30, 'CARD_RANGE'
  from public.cards where slug = 'sinie';

-- ---------------------------------------------------------------------------
-- 5. Velmor -- Cursed Blade. Poison + 10 damage, THE_TARGET, both rows
--    gated on target.is_enemy (the old branch's hard 'no friendly fire'
--    exception, expressed as a silent-skip condition instead -- see this
--    migration's header for why it can't stay a hard exception here).
--    range_kind CARD_RANGE reproduces the old rmax(2) check the same way.
-- ---------------------------------------------------------------------------
update public.cards set ability_kind = 'scripted' where slug = 'velmor';

insert into public.card_effects
  (card_id, sort, trigger, target_selector, action, status, range_kind, conditions)
select id, 0, 'ON_ABILITY', 'THE_TARGET', 'APPLY_STATUS', 'POISON', 'CARD_RANGE',
       '[{"field": "target.is_enemy", "op": "=", "value": "true"}]'::jsonb
  from public.cards where slug = 'velmor';

insert into public.card_effects
  (card_id, sort, trigger, target_selector, action, value, range_kind, conditions)
select id, 1, 'ON_ABILITY', 'THE_TARGET', 'DEAL_DAMAGE', 10, 'CARD_RANGE',
       '[{"field": "target.is_enemy", "op": "=", "value": "true"}]'::jsonb
  from public.cards where slug = 'velmor';

-- ---------------------------------------------------------------------------
-- Did it work?
-- ---------------------------------------------------------------------------
select
  (select count(*) from public.cards where slug in ('sinie','velmor') and ability_kind = 'scripted') = 2
    as sinie_velmor_scripted,
  (select count(*) from public.card_effects ce join public.cards c on c.id = ce.card_id
     where c.slug = 'sinie' and ce.action = 'HEAL' and ce.value = 30) = 1
    as sinie_heal_row,
  (select count(*) from public.card_effects ce join public.cards c on c.id = ce.card_id
     where c.slug = 'velmor' and ce.action in ('APPLY_STATUS', 'DEAL_DAMAGE')) = 2
    as velmor_rows,
  cn_effect_condition_met(
    '{"field": "target.is_enemy", "op": "="}'::jsonb,
    '{"self": {"owner": "host"}, "target": {"owner": "guest"}}'::jsonb) = true
    as is_enemy_true_case,
  cn_effect_condition_met(
    '{"field": "target.is_enemy", "op": "="}'::jsonb,
    '{"self": {"owner": "host"}, "target": {"owner": "host"}}'::jsonb) = false
    as is_enemy_false_case;
