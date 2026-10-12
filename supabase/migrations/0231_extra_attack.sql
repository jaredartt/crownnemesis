-- 0231 -- GRANT_EXTRA_ATTACK: Staccata's "can attack twice", soft-coded.
-- Jared: after her first attack the player may choose the next target; if they
-- attack, that's it (either she attacks again or just waits -- no move, defend
-- or ability); and if the first attack leaves her stunned she can't continue.
--
-- Engine:
--  * new action GRANT_EXTRA_ATTACK (value = extra attacks per go, min 1), used
--    as  ON_ATTACK / SELF / GRANT_EXTRA_ATTACK / 1.  Fires after the exchange
--    (cn_attack's own ON_ATTACK hook), which is why it can see the final state:
--    attacker alive and not stunned -> her go is re-opened: acted=false,
--    spent=false, moved=true, attackOnly=true, bonusLeft=N, state.active = her.
--    On the extra attack ON_ATTACK fires again: bonusLeft-1; at 0 the go simply
--    stays closed (cn_attack already marked her spent). Dead or stunned -> no.
--  * cn_guard_attack_only(): cn_move / cn_defend / cn_ability (+royale) refuse a
--    unit that is mid-go with attackOnly set. Wait (submit_wait) and picking
--    another unit already close a go, so "just wait" needs nothing new.
--  * cn_begin_act(_royale): starting a FRESH go clears attackOnly/bonusLeft.
--  * bots skip an attackOnly unit (they never take the second swing, and never
--    get stuck on a refusal).

alter table public.card_effects drop constraint if exists card_effects_action_check;
alter table public.card_effects add constraint card_effects_action_check check (action = any (array[
  'DEAL_DAMAGE','HEAL','APPLY_STATUS','MODIFY_STAT','SET_STAT','PUSH_BACK','DRAW_CARD','REMOVE_STATUS',
  'GRANT_EXTRA_ACTIVATION','SUMMON_OBJECT','TELEPORT_SELF','SWAP_POSITIONS','REVIVE','COPY_STAT_FROM_TARGET',
  'REFLECT_DAMAGE_PCT','CREATE_STRUCTURE','TRIGGER_PARRY','COUNTER_ATTACK_PCT','GRANT_EXTRA_ATTACK'
]::text[]));

create or replace function public.cn_guard_attack_only(v_st jsonb, p_unit text)
returns void language plpgsql set search_path to 'public' as $$
declare u jsonb;
begin
  if nullif(v_st->>'active', '') is distinct from p_unit then return; end if;
  for u in select * from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) loop
    if u->>'id' = p_unit and coalesce((u->>'attackOnly')::boolean, false) then
      raise exception 'only another attack is left for that unit';
    end if;
  end loop;
end $$;

do $mig$
declare v_def text; v_new text; v_fn text;
begin
  -- 1. the action itself
  v_def := pg_get_functiondef('public.cn_effect_apply_action(jsonb,jsonb,jsonb,text,jsonb)'::regprocedure);
  v_new := replace(v_def, '  v_field text; v_copy_val jsonb; v_half int;',
                   '  v_field text; v_copy_val jsonb; v_half int; v_left int; v_regrant boolean := false;');
  v_new := replace(v_new, '    elsif u->>''id'' = p_target_id and v_action in (''REFLECT_DAMAGE_PCT'', ''COUNTER_ATTACK_PCT'') then',
$x$    elsif u->>'id' = p_target_id and v_action = 'GRANT_EXTRA_ATTACK' then
      if u->>'id' = v_self_id and (u->>'hp')::int > 0 and not cn_stunned(u) then
        v_left := case when coalesce((u->>'attackOnly')::boolean, false)
                       then coalesce((u->>'bonusLeft')::int, 0) - 1
                       else greatest(1, v_value) end;
        if v_left > 0 then
          u := jsonb_set(u, '{acted}', 'false'::jsonb);
          u := jsonb_set(u, '{spent}', 'false'::jsonb);
          u := jsonb_set(u, '{moved}', 'true'::jsonb);
          u := jsonb_set(u, '{attackOnly}', 'true'::jsonb);
          u := jsonb_set(u, '{bonusLeft}', to_jsonb(v_left));
          v_regrant := true;
        else
          u := (u - 'attackOnly') - 'bonusLeft';
        end if;
      elsif u->>'id' = v_self_id then
        u := (u - 'attackOnly') - 'bonusLeft';
      end if;

    elsif u->>'id' = p_target_id and v_action in ('REFLECT_DAMAGE_PCT', 'COUNTER_ATTACK_PCT') then$x$);
  v_new := replace(v_new, '  if v_action = ''GRANT_EXTRA_ACTIVATION'' and p_target_id = v_self_id then',
$x$  if v_regrant then
    v_st := jsonb_set(v_st, '{active}', to_jsonb(v_self_id));
  end if;

  if v_action = 'GRANT_EXTRA_ACTIVATION' and p_target_id = v_self_id then$x$);
  if v_new = v_def or position('v_regrant then' in v_new) = 0 or position('GRANT_EXTRA_ATTACK'' then' in v_new) = 0 then
    raise exception 'cn_effect_apply_action was not changed';
  end if;
  execute v_new;

  -- 2. a new go clears the flag
  foreach v_fn in array array['public.cn_begin_act(jsonb,text,text)', 'public.cn_begin_act_royale(jsonb,integer,text)'] loop
    v_def := pg_get_functiondef(v_fn::regprocedure);
    v_new := replace(v_def, '  p_st := jsonb_set(p_st, ''{acts}'', to_jsonb(v_acts + 1));',
$x$  v_out := '[]'::jsonb;
  for u in select * from jsonb_array_elements(p_st->'units') loop
    if u->>'id' = p_unit then u := (u - 'attackOnly') - 'bonusLeft'; end if;
    v_out := v_out || u;
  end loop;
  p_st := jsonb_set(p_st, '{units}', v_out);
  p_st := jsonb_set(p_st, '{acts}', to_jsonb(v_acts + 1));$x$);
    if v_new = v_def then raise exception '% was not changed', v_fn; end if;
    execute v_new;
  end loop;

  -- 3. move / defend / ability refuse an attack-only unit
  foreach v_fn in array array[
    'public.cn_move(uuid,text,text,integer,integer)', 'public.cn_defend(uuid,text,text,text)',
    'public.cn_ability(uuid,text,text,text)'] loop
    v_def := pg_get_functiondef(v_fn::regprocedure);
    v_new := replace(v_def, 'v_st := cn_begin_act(v_st, p_side, p_unit);',
      'perform cn_guard_attack_only(v_st, p_unit);' || chr(10) || '  v_st := cn_begin_act(v_st, p_side, p_unit);');
    if v_new = v_def then raise exception '% was not changed', v_fn; end if;
    execute v_new;
  end loop;
  foreach v_fn in array array[
    'public.cn_move_royale(uuid,integer,text,integer,integer)', 'public.cn_defend_royale(uuid,integer,text,text)',
    'public.cn_ability_royale(uuid,integer,text,text)'] loop
    v_def := pg_get_functiondef(v_fn::regprocedure);
    v_new := replace(v_def, 'v_st := cn_begin_act_royale(v_st, p_seat, p_unit);',
      'perform cn_guard_attack_only(v_st, p_unit);' || chr(10) || '  v_st := cn_begin_act_royale(v_st, p_seat, p_unit);');
    if v_new = v_def then raise exception '% was not changed', v_fn; end if;
    execute v_new;
  end loop;

  -- 4. bots never pick an attack-only unit
  foreach v_fn in array array['public.bot_step(uuid,text)', 'public.royale_bot_step(uuid,integer)'] loop
    v_def := pg_get_functiondef(v_fn::regprocedure);
    v_new := replace(v_def, '    continue when coalesce((u->>''spent'')::boolean, false);',
      '    continue when coalesce((u->>''spent'')::boolean, false);' || chr(10) || '    continue when coalesce((u->>''attackOnly'')::boolean, false);');
    if v_new = v_def then raise exception '% was not changed', v_fn; end if;
    execute v_new;
  end loop;
end $mig$;
