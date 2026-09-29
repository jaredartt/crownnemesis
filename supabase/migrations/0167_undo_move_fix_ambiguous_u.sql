-- 0166 shipped with a bug caught by testing before this ever reached a
-- live match: the three new SELECTs inside cn_move that check whether a
-- move stayed "clean" used `u` as their jsonb_array_elements() alias --
-- but `u jsonb;` is already cn_move's own long-standing loop variable
-- (declared at the very top, used throughout the rest of the function),
-- so Postgres saw two things named `u` in scope and refused to guess which
-- one was meant ("column reference \"u\" is ambiguous"). Every clean move
-- would have raised that error instead of completing. Renamed the three
-- new aliases to `q`, which nothing else in this function uses.
do $$
declare def text; v_before text;
begin
  def := pg_get_functiondef('public.cn_move(uuid,text,text,int,int)'::regprocedure);
  v_before := def;

  def := replace(def,
    '    select (u - ''{x,y,moved,defending,defendedBy,defendedSelf}''::text[]) into v_mover_post
      from jsonb_array_elements(v_st->''units'') u where u->>''id'' = p_unit;',
    '    select (q - ''{x,y,moved,defending,defendedBy,defendedSelf}''::text[]) into v_mover_post
      from jsonb_array_elements(v_st->''units'') q where q->>''id'' = p_unit;');
  if def = v_before then raise exception '0166b: cn_move -- mover_post target not found'; end if;
  v_before := def;

  def := replace(def,
    '    select coalesce(jsonb_agg(u), ''[]''::jsonb) into v_others_post
      from jsonb_array_elements(v_st->''units'') u where u->>''id'' <> p_unit;
    select coalesce(jsonb_agg(u), ''[]''::jsonb) into v_others_pre
      from jsonb_array_elements(v_pre_units) u where u->>''id'' <> p_unit;',
    '    select coalesce(jsonb_agg(q), ''[]''::jsonb) into v_others_post
      from jsonb_array_elements(v_st->''units'') q where q->>''id'' <> p_unit;
    select coalesce(jsonb_agg(q), ''[]''::jsonb) into v_others_pre
      from jsonb_array_elements(v_pre_units) q where q->>''id'' <> p_unit;');
  if def = v_before then raise exception '0166b: cn_move -- others target not found'; end if;
  execute def;
end $$;

select (position('jsonb_array_elements(v_st->''units'') q where q->>''id'' = p_unit' in
  pg_get_functiondef('public.cn_move(uuid,text,text,int,int)'::regprocedure)) > 0) as fixed;
