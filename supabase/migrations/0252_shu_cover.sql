-- 0252: Shu's tree cover (Jared).
--  * a counter-attack or a parry-answer that would land on Shu (when Shu is the one attacking) is
--    taken by an adjacent tree, exactly like a direct hit on Shu already was;
--  * when Shu stands beside more than one tree, the covering tree is picked at random
--    (it used to be the weakest one).
-- Swings carry 'via' = the tree's id, so the client replay does not take the HP off Shu.
do $mig$
declare d text; r text;
  procedure_sig regprocedure := 'public.cn_attack(uuid,text,text,text)'::regprocedure;
begin
  d := pg_get_functiondef(procedure_sig);
  if position('v_ashield' in d) > 0 then return; end if;

  -- helper: replace exactly one occurrence or fail loudly
  -- (done inline below with a check per step)
  d := replace(d, E'  v_shield jsonb; v_shield_for jsonb;\n',
                  E'  v_shield jsonb; v_shield_for jsonb;\n  v_ashield jsonb; v_ashield_hp int := 0; v_via text;\n');
  if position('v_ashield jsonb' in d) = 0 then raise exception 'shu: decl anchor'; end if;

  r := replace(d, E'  v_atk_hp := (v_atk->>''hp'')::int;\n',
    E'  v_atk_hp := (v_atk->>''hp'')::int;\n  -- 0252: Shu''s cover also stands in front of the answers that come back at it.\n  if v_tgt is not null and not v_ally then\n    v_ashield := cn_tree_shield(v_st, v_atk);\n    v_ashield_hp := coalesce((v_ashield->>''hp'')::int, 0);\n  end if;\n');
  if r = d then raise exception 'shu: hp anchor'; end if; d := r;

  r := replace(d, E'      v_atk_hp := v_atk_hp - v_counter;\n',
    E'      v_via := null;\n      if v_ashield_hp > 0 then v_via := v_ashield->>''id''; v_ashield_hp := v_ashield_hp - v_counter;\n      else v_atk_hp := v_atk_hp - v_counter; end if;\n');
  if r = d then raise exception 'shu: quick anchor'; end if; d := r;

  r := replace(d, $a$'k', 'hit', 'by', p_target, 'at', p_unit, 'dmg', v_counter,$a$,
                  $a$'k', 'hit', 'by', p_target, 'at', p_unit, 'via', v_via, 'dmg', v_counter,$a$);
  if r = d then raise exception 'shu: quick swing anchor'; end if; d := r;

  r := replace(d, E'      if v_swing_is_atk then\n        v_tgt_hp := v_tgt_hp - v_hit;\n',
                  E'      v_via := null;\n      if v_swing_is_atk then\n        v_tgt_hp := v_tgt_hp - v_hit;\n');
  if r = d then raise exception 'shu: hit anchor'; end if; d := r;

  r := replace(d, E'        v_atk_hp := v_atk_hp - v_hit;\n        v_counter := v_counter + v_hit;\n',
    E'        if v_ashield_hp > 0 then v_via := v_ashield->>''id''; v_ashield_hp := v_ashield_hp - v_hit;\n        else v_atk_hp := v_atk_hp - v_hit; end if;\n        v_counter := v_counter + v_hit;\n');
  if r = d then raise exception 'shu: hit2 anchor'; end if; d := r;

  r := replace(d, $a$'at', v_recv->>'id', 'dmg', v_hit,$a$, $a$'at', v_recv->>'id', 'via', v_via, 'dmg', v_hit,$a$);
  if r = d then raise exception 'shu: swing anchor'; end if; d := r;

  r := replace(d, E'        if v_swing_is_atk then\n          v_tgt_hp := v_tgt_hp - v_hit2;\n',
                  E'        v_via := null;\n        if v_swing_is_atk then\n          v_tgt_hp := v_tgt_hp - v_hit2;\n');
  if r = d then raise exception 'shu: twice anchor'; end if; d := r;

  r := replace(d, E'          v_atk_hp := v_atk_hp - v_hit2;\n          v_counter := v_counter + v_hit2;\n',
    E'          if v_ashield_hp > 0 then v_via := v_ashield->>''id''; v_ashield_hp := v_ashield_hp - v_hit2;\n          else v_atk_hp := v_atk_hp - v_hit2; end if;\n          v_counter := v_counter + v_hit2;\n');
  if r = d then raise exception 'shu: twice2 anchor'; end if; d := r;

  r := replace(d, $a$'at', v_recv->>'id', 'dmg', v_hit2,$a$, $a$'at', v_recv->>'id', 'via', v_via, 'dmg', v_hit2,$a$);
  if r = d then raise exception 'shu: twice swing anchor'; end if; d := r;

  r := replace(d, E'    else\n      v_rocks := v_rocks || e;\n',
    E'    elsif v_ashield is not null and e->>''id'' = v_ashield->>''id'' then\n      if v_ashield_hp > 0 then v_rocks := v_rocks || jsonb_set(e, ''{hp}'', to_jsonb(v_ashield_hp)); end if;\n    else\n      v_rocks := v_rocks || e;\n');
  if r = d then raise exception 'shu: rocks anchor'; end if; d := r;

  execute d;
end $mig$;

-- random tree when beside two (was: the weakest)
do $mig$
declare d text := pg_get_functiondef('public.cn_tree_shield(jsonb,jsonb)'::regprocedure); r text;
begin
  if position('order by random()' in d) > 0 then return; end if;
  r := replace(d, E'order by (o->>''hp'')::int, o->>''id''', 'order by random()');
  if r = d then raise exception 'shu: shield order anchor'; end if;
  d := r;
  r := replace(d, E' STABLE\n', E' VOLATILE\n');
  if r = d then raise exception 'shu: volatility anchor'; end if;
  execute r;
end $mig$;
