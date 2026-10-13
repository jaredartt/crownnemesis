-- 0253: expert bot: bomb sense + king guard + king ring (see project_status §77fo)
do $mig$
declare d text; r text;
begin
  d := pg_get_functiondef('public.cn_b4_eval(jsonb,text,jsonb)'::regprocedure);
  if position('w_brange' in d) = 0 then
    r := replace(d, E'w_bomb numeric := cn_b4_w(w,''bomb_val'',22);',
      E'w_bomb numeric := cn_b4_w(w,''bomb_val'',14); w_brange numeric := cn_b4_w(w,''bomb_range'',3); w_bdet numeric := cn_b4_w(w,''bomb_det'',0.6); v_breach numeric; v_det numeric;');
    if r = d then raise exception 'bomb: decl anchor'; end if; d := r;
    r := replace(d, E'    continue when v_own is null;\n    v_sidebonus := v_sidebonus + case when v_own = me then 1 else -1 end *\n                   case cn_obj_kind(e) when ''bomb'' then w_bomb else w_wall end;\n',
      E'    continue when v_own is null;\n    if cn_obj_kind(e) = ''bomb'' then\n      v_breach := 0; v_det := 0;\n      for i in 1..n loop\n        d := cn_cheb(ux[i], uy[i], (e->>''x'')::int, (e->>''y'')::int);\n        if uo[i] <> v_own then\n          v_breach := greatest(v_breach, greatest(0, 1 - greatest(0, d - umv[i])::numeric / w_brange));\n          if d <= 1 then v_det := v_det + 0.15 * umx[i] * w_burn * uhw[i]; end if;\n        elsif d <= 1 then\n          v_det := v_det - 0.15 * umx[i] * w_burn * uhw[i];\n        end if;\n      end loop;\n      v_sidebonus := v_sidebonus + case when v_own = me then 1 else -1 end * (w_bomb * v_breach + w_bdet * v_det);\n    else\n      v_sidebonus := v_sidebonus + case when v_own = me then 1 else -1 end * w_wall;\n    end if;\n');
    if r = d then raise exception 'bomb: loop anchor'; end if; d := r;
    execute d;
  end if;

  d := pg_get_functiondef('public.bot4_step(uuid,text)'::regprocedure);
  if position('bomb_tile_w' in d) = 0 then
    r := replace(d, E'v_ab_score := coalesce((v_w->>''ability_structure_flat'')::numeric, 40);',
      E'v_ab_score := coalesce((v_w->>''ability_structure_flat'')::numeric, 40) + cn_b4_w(v_w,''bomb_tile_w'',0.6) * cn_bot_bomb_tile_bonus(st, p_side, u, v_ab_tile);');
    if r = d then raise exception 'bomb: tile anchor'; end if;
    execute r;
  end if;
end $mig$;
do $mig$
declare d text; r text;
begin
  d := pg_get_functiondef('public.bot4_step(uuid,text)'::regprocedure);
  if position('v_kthreat' in d) > 0 then return; end if;

  r := replace(d, E'  v_k_all int; v_k_ab int;',
                  E'  v_kid text; v_kx int; v_ky int; v_kthreat boolean := false; v_kthr text[] := ''{}'';\n  v_k_all int; v_k_ab int;');
  if r = d then raise exception 'king: decl anchor'; end if; d := r;

  r := replace(d, E'  v_cap := cn_acts_cap(st);\n',
    E'  v_cap := cn_acts_cap(st);\n  for t in select * from jsonb_array_elements(st->''units'') loop\n    if t->>''owner'' = p_side and coalesce((t->>''royal'')::boolean, false) and (t->>''hp'')::int > 0 then\n      v_kid := t->>''id''; v_kx := (t->>''x'')::int; v_ky := (t->>''y'')::int;\n    end if;\n  end loop;\n  if v_kid is not null then\n    for t in select * from jsonb_array_elements(st->''units'') loop\n      continue when t->>''owner'' = p_side or (t->>''hp'')::int <= 0;\n      if cn_cheb((t->>''x'')::int, (t->>''y'')::int, v_kx, v_ky) <= (t->>''mov'')::int + (t->>''rmax'')::int + 1 then\n        v_kthr := v_kthr || (t->>''id'');\n      end if;\n    end loop;\n    v_kthreat := coalesce(array_length(v_kthr, 1), 0) > 0;\n  end if;\n');
  if r = d then raise exception 'king: compute anchor'; end if; d := r;

  r := replace(d, E'select array_agg(idx order by v_cs[idx] desc) into v_short from (select distinct idx from (',
    E'select array_agg(idx order by pr desc, v_cs[idx] desc) into v_short from (select idx, case when v_kthreat and v_cu[idx] = v_kid and v_ck[idx] = ''move'' then 1 else 0 end as pr from (select distinct idx from (');
  if r = d then raise exception 'king: head anchor'; end if; d := r;

  r := replace(d, E'    ) z0) z;',
    E'      union\n      (select i from unnest(v_cs, v_cu, v_ck) with ordinality t(s,u2,k,i) where v_kthreat and u2 = v_kid and k = ''move'')\n      union\n      (select i from unnest(v_cs, v_cu, v_ck, v_cx, v_cy) with ordinality t(s,u2,k,cx,cy,i) where v_kthreat and u2 <> v_kid and k = ''move'' and cn_cheb(cx, cy, v_kx, v_ky) <= 1)\n      union\n      (select i from unnest(v_cs, v_ck, v_ct) with ordinality t(s,k,tg,i) where v_kthreat and k = ''attack'' and tg = any(v_kthr))\n    ) z0) z1) z;');
  if r = d then raise exception 'king: tail anchor'; end if; d := r;

  execute d;
end $mig$;
do $mig$
declare d text; r text;
begin
  d := pg_get_functiondef('public.cn_b4_eval(jsonb,text,jsonb)'::regprocedure);
  if position('w_kring' in d) > 0 then return; end if;
  r := replace(d, E'v_dk int; w_kd numeric', E'v_dk int; w_kring numeric := cn_b4_w(w,''king_ring'',0.5); w_kring_o numeric := cn_b4_w(w,''king_ring_opp'',0.5); w_kd numeric');
  if r = d then raise exception 'ring: decl anchor'; end if; d := r;
  r := replace(d, E'  -- king damage is worse than its hp alone: a convex penalty for the lower fractions\n',
    E'  -- 0255: king ring -- who could be at the king within two moves, and how hurt it is\n  if w_kring > 0 then\n    for i in 1..n loop\n      continue when not uroyal[i];\n      vv := 0;\n      for a in 1..n loop\n        continue when uo[a] = uo[i] or ustun[a];\n        dd := umv[a] + uhi[a] + 2;\n        d := greatest(abs(ux[a]-ux[i]), abs(uy[a]-uy[i]));\n        if d < dd then vv := vv + greatest(uavg[a], ucond_d[a]) * (dd - d) / dd; end if;\n      end loop;\n      vv := vv * (1 + 3 * power(1 - uhp[i]::numeric / umx[i], 2));\n      pos := pos + case when uo[i] = me then -w_kring * vv else w_kring * w_kring_o * vv end;\n    end loop;\n  end if;\n\n  -- king damage is worse than its hp alone: a convex penalty for the lower fractions\n');
  if r = d then raise exception 'ring: block anchor'; end if; d := r;
  execute d;
end $mig$;
