-- A passive's animation (ON_DAMAGED, ON_ATTACK, ON_PARRY, IS_PARRIED, ON_COUNTER,
-- ON_DEATH) was attached but never shown: only ON_ABILITY asked cn_run_effects to
-- report animations. cn_attack now asks for them on every passive trigger, takes
-- the report back out of state, and hands it to the board as fx.anims -- the same
-- field an ability's animations already travel in.
do $mig$
declare d text; d2 text;
begin
  d := pg_get_functiondef('public.cn_attack(uuid,text,text,text)'::regprocedure);
  d2 := regexp_replace(d, '(cn_run_effects\(v_st, ''[A-Z_]+'', [a-z_]+,\s*jsonb_build_object\()', E'\\1''collectAnims'', true, ', 'g');
  if d2 = d then raise exception 'cn_attack: no cn_run_effects calls found'; end if;
  d := d2;
  d2 := regexp_replace(d, E'declare\n', E'declare\n  v_pass_anims jsonb := ''[]''::jsonb;\n');
  if d2 = d then raise exception 'cn_attack: declare anchor not found'; end if;
  d := d2;
  d2 := replace(d,
    E'  v_st := jsonb_set(v_st, ''{fx}'', jsonb_build_object(\n    ''seq'', coalesce((v_st->''fx''->>''seq'')::int, 0) + 1,\n    ''atk'', p_unit, ''tgt'', p_target,',
    E'  v_pass_anims := coalesce(v_st->''animQueue'', ''[]''::jsonb);\n  v_st := v_st - ''animQueue'';\n  v_st := jsonb_set(v_st, ''{fx}'', jsonb_build_object(\n    ''seq'', coalesce((v_st->''fx''->>''seq'')::int, 0) + 1,\n    ''anims'', v_pass_anims,\n    ''atk'', p_unit, ''tgt'', p_target,');
  if d2 = d then raise exception 'cn_attack: fx anchor not found'; end if;
  execute d2;
end $mig$;
