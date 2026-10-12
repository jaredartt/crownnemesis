-- 0232 -- DEAL_ATTACK_PCT: Keidos, "if parried, breaks through with double damage".
-- Soft-code had IS_PARRIED (fires on the unit whose blow got caught, with the
-- parrier as THE_TARGET) but DEAL_DAMAGE takes a flat number, so "double MY
-- damage" could not be written. New action: the acting unit rolls its own
-- damage (dmin..dmax), scales it by value % (200 = double), and lands it on the
-- target through the same cn_damage() the fight uses (class auras, the target's
-- Defend), no crit and no counter halving.  Keidos: IS_PARRIED / THE_TARGET /
-- DEAL_ATTACK_PCT / 200.

alter table public.card_effects drop constraint if exists card_effects_action_check;
alter table public.card_effects add constraint card_effects_action_check check (action = any (array[
  'DEAL_DAMAGE','HEAL','APPLY_STATUS','MODIFY_STAT','SET_STAT','PUSH_BACK','DRAW_CARD','REMOVE_STATUS',
  'GRANT_EXTRA_ACTIVATION','SUMMON_OBJECT','TELEPORT_SELF','SWAP_POSITIONS','REVIVE','COPY_STAT_FROM_TARGET',
  'REFLECT_DAMAGE_PCT','CREATE_STRUCTURE','TRIGGER_PARRY','COUNTER_ATTACK_PCT','GRANT_EXTRA_ATTACK','DEAL_ATTACK_PCT'
]::text[]));

do $mig$
declare v_def text; v_new text;
begin
  v_def := pg_get_functiondef('public.cn_effect_apply_action(jsonb,jsonb,jsonb,text,jsonb)'::regprocedure);
  v_new := replace(v_def, '    elsif u->>''id'' = p_target_id and v_action = ''GRANT_EXTRA_ATTACK'' then',
$x$    elsif u->>'id' = p_target_id and v_action = 'DEAL_ATTACK_PCT' then
      u := jsonb_set(u, '{hp}', to_jsonb((u->>'hp')::int - cn_damage(
        greatest(0, round(cn_roll(coalesce((p_unit->>'dmin')::int, 0), coalesce((p_unit->>'dmax')::int, 0))
                          * v_value / 100.0)::int),
        false, false,
        cn_aura_bonus(v_st, p_unit, u), cn_aura_resist(v_st, p_unit, u),
        coalesce((u->>'defending')::boolean, false))));

    elsif u->>'id' = p_target_id and v_action = 'GRANT_EXTRA_ATTACK' then$x$);
  if v_new = v_def then raise exception 'cn_effect_apply_action was not changed'; end if;
  execute v_new;
end $mig$;
