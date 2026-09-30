-- 0181: Battle Royale bots are always Expert, and they get their own 4-player brain.
--
-- Jared: "remove the ability to change the bot's difficulty in battle royale, it
-- will only and always be Expert mode for all bot seats. Make a separate brain
-- for the Expert battle royale bot ... adapt it to 4 players ... make it that
-- they also use the abilities ... deeply strategically."
--
--   * add_royale_bot()      ignores p_level: every bot seat is level 3 (Expert).
--   * cn_rb_*               the 4-player brain. It reuses the 1v1 Expert weights
--                           (bot_brains level 3 is merged over the defaults) and the
--                           1v1 helpers (cn_run_effects scratch runs, cn_bot_trap_threat,
--                           cn_los_clear ...), but reads the whole table:
--       cn_rb_ctx           who is alive, per-rival priority (crown HP, how close
--                           their army is, how dangerous they are to me, how weak
--                           they are, whether others are already about to kill
--                           them / I could steal the kill), and a posture:
--                           defend / balanced / hunt.
--       cn_rb_score_ability / cn_rb_ability_options / cn_rb_ability_tiles /
--       cn_rb_combo / cn_rb_structure_value / cn_rb_throw_tile
--                           abilities: every scripted ability is scored by a scratch
--                           run of the real effects (damage, heals, kills, burn/poison
--                           value, combos, structures on approach roads, tornado
--                           throws), so nothing is hard-coded per card except
--                           cn_rb_strategy_bonus (see the note there).
--       royale_bot_step     the turn: top-4 tiles x (move, attack | ability), exposure
--                           split across the rivals' target choices, crown passivity
--                           while 3+ crowns live.
--   * cn_derive_royale()    hotfix for 0179: the stalemate branch wrote winner_seat
--                           to `matches` instead of `royale_matches`.
--
-- Note for the future: cn_rb_strategy_bonus holds per-card knowledge that is NOT
-- derived from 1v1; add new cards there. Only abilityKind = 'scripted' is used.

create or replace function public.add_royale_bot(p_match uuid, p_seat integer, p_level integer)
 returns royale_matches
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  m public.royale_matches; v_uid uuid := auth.uid();
  v_lvl int := 3; -- 0181: Battle Royale bots are always Expert; p_level is ignored
  v_st jsonb; v_bot record;
begin
  select * into m from public.royale_matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'waiting' then raise exception 'you can only add a bot before the match starts'; end if;

  if not exists (
    select 1 from public.royale_players
     where match_id = p_match and seat = 0 and user_id = v_uid) then
    raise exception 'only the host can add a bot';
  end if;

  if p_seat < 1 or p_seat > 3 then raise exception 'no such seat'; end if;

  if exists (select 1 from public.royale_players where match_id = p_match and seat = p_seat) then
    raise exception 'that seat is already taken';
  end if;

  select * into v_bot from public.bot_identity();
  insert into public.royale_players (match_id, seat, user_id, username, avatar, name_color, bot)
  values (p_match, p_seat, null, v_bot.name, v_bot.avatar, v_bot.name_color, v_lvl);

  v_st := state_log(m.state, v_bot.name || ' joins the arena.');
  update public.royale_matches set state = v_st, updated_at = now()
   where id = m.id returning * into m;
  return m;
end
$function$;

create or replace function public.cn_rb_weights()
 returns jsonb
 language sql
 stable
 set search_path to 'public'
as $function$
  select jsonb_build_object(
      'crown_kill_flat', 1500, 'crown_dmg_bonus', 9, 'crown_heal_mult', 0.8, 'crown_loss_mult', 1.2,
      'crown_expo_mult', 7, 'crown_lethal_flat', 700, 'crown_ideal_d', 3,
      'unit_lethal_expo_mult', 1.2, 'guard_move_mult', 7, 'guard_atk_mult', 7,
      'bomb_self_pen', 220, 'bomb_approach', 70, 'tornado_approach', 55,
      'last_use_min', 140, 'stun_bonus', 60, 'ability_structure_flat', 25,
      'ally_spacing_ideal', 2, 'ally_spacing_mult', 6, 'trap_dmg_mult', 12,
      'lethal_trap_penalty_flat', 500, 'tornado_step_pen', 30,
      'atk_mult', 9, 'ctr_mult', 8, 'heal_mult', 12, 'burn_bonus', 21, 'poison_bonus', 25,
      'noise_scale', 15, 'threat_mult', 3, 'pos_dist_mult', 7, 'pos_near_mult', 2.5,
      'kill_bonus_flat', 450, 'heal_full_penalty', -190,
      'lethal_ctr_penalty_flat', 700, 'lethal_parry_extra_flat', 550)
    || coalesce((select b.weights from public.bot_brains b where b.level = 3 and b.is_live limit 1),
                '{}'::jsonb);
$function$;

create or replace function public.cn_rb_ability_tiles(p_st jsonb, p_unit jsonb)
 returns text[]
 language plpgsql
 stable
 set search_path to 'public'
as $function$
declare
  v_out text[] := '{}';
  ux int := (p_unit->>'x')::int; uy int := (p_unit->>'y')::int;
  rm int := coalesce((p_unit->>'rmax')::int, 1);
  bw int := coalesce((p_st->'board'->>'w')::int, 0); bh int := coalesce((p_st->'board'->>'h')::int, 0);
  nx int; ny int; d int;
begin
  for nx in ux - rm .. ux + rm loop
    for ny in uy - rm .. uy + rm loop
      continue when nx < 0 or ny < 0 or nx >= bw or ny >= bh;
      d := (abs(nx - ux) + abs(ny - uy));
      continue when d < 1 or d > rm;
      continue when exists (select 1 from jsonb_array_elements(coalesce(p_st->'units', '[]'::jsonb)) qu
                             where (qu->>'x')::int = nx and (qu->>'y')::int = ny);
      continue when exists (select 1 from jsonb_array_elements(coalesce(p_st->'obstacles', '[]'::jsonb)) qo
                             where (qo->>'x')::int = nx and (qo->>'y')::int = ny);
      continue when not cn_los_clear(p_st, ux, uy, nx, ny);
      v_out := v_out || ('@' || nx || ',' || ny);
    end loop;
  end loop;
  return v_out;
end $function$;

create or replace function public.cn_rb_combo(p_unit jsonb, p_status text)
 returns numeric
 language sql
 stable
 set search_path to 'public'
as $function$
  select coalesce(max((r->>'value')::numeric), 0)
         - ((p_unit->>'dmin')::numeric + (p_unit->>'dmax')::numeric) / 2
    from jsonb_array_elements(coalesce(p_unit->'abilityScript', '[]'::jsonb)) r
   where r->>'action' = 'DEAL_DAMAGE' and r->>'value' is not null
     and exists (select 1 from jsonb_array_elements(coalesce(r->'conditions', '[]'::jsonb)) c
                  where c->>'field' = 'target.has_status' and c->>'op' = '='
                    and c->>'value' = p_status)
$function$;

create or replace function public.cn_rb_ctx(p_st jsonb, p_seat integer, w jsonb)
 returns jsonb
 language plpgsql
 stable
 set search_path to 'public'
as $function$
declare
  id_ text[]; own int[]; x int[]; y int[]; hp int[]; mhp int[]; avg_ numeric[];
  mov int[]; rmax int[]; roy boolean[];
  n int; i int; j int; ci int; mi int; d int; s int;
  alive boolean[] := array[false, false, false, false];
  str numeric[] := array[0, 0, 0, 0];
  cidx int[] := array[0, 0, 0, 0];
  d_army numeric[] := array[99, 99, 99, 99];
  thr numeric[] := array[0, 0, 0, 0];
  steal numeric[] := array[0, 0, 0, 0];
  mypot numeric[] := array[0, 0, 0, 0];
  pri numeric[] := array[1, 1, 1, 1];
  alive_n int := 0; my_str numeric := 0; max_str numeric := 1; en_avg numeric := 0; en_n int := 0;
  my_hp numeric := 1; my_mhp numeric := 1; my_frac numeric := 1; thr_all numeric := 0;
  crown_frac numeric; thr_r numeric; prox numeric; weak numeric; stl numeric; mine numeric; p numeric;
  posture text := 'balanced'; expo numeric := 1; guard numeric := 1;
  fs int := -1; fbest numeric := -1e9; sc numeric;
  t_i int := 0; t_best numeric := 1e9; t_sc numeric;
begin
  select array_agg(q->>'id' order by o), array_agg((q->>'owner')::int order by o),
         array_agg((q->>'x')::int order by o), array_agg((q->>'y')::int order by o),
         array_agg((q->>'hp')::int order by o), array_agg((q->>'maxHp')::int order by o),
         array_agg(((q->>'dmin')::int + (q->>'dmax')::int) / 2.0 order by o),
         array_agg((q->>'mov')::int order by o), array_agg((q->>'rmax')::int order by o),
         array_agg(coalesce((q->>'royal')::boolean, false) order by o)
    into id_, own, x, y, hp, mhp, avg_, mov, rmax, roy
    from jsonb_array_elements(coalesce(p_st->'units', '[]'::jsonb)) with ordinality t(q, o)
   where (q->>'hp')::int > 0;
  n := coalesce(array_length(id_, 1), 0);
  if n = 0 then return '{}'::jsonb; end if;

  for i in 1 .. n loop
    continue when own[i] not between 0 and 3;
    str[own[i] + 1] := str[own[i] + 1] + hp[i];
    if roy[i] then alive[own[i] + 1] := true; cidx[own[i] + 1] := i; end if;
  end loop;
  mi := cidx[p_seat + 1];
  if mi = 0 then return '{}'::jsonb; end if;
  my_hp := hp[mi]; my_mhp := greatest(mhp[mi], 1);

  for i in 1 .. n loop
    continue when own[i] = p_seat or own[i] not between 0 and 3;
    d := (abs(x[i] - x[mi]) + abs(y[i] - y[mi]));
    if d <= mov[i] + rmax[i] then thr[own[i] + 1] := thr[own[i] + 1] + avg_[i]; end if;
    for j in 1 .. n loop
      continue when own[j] <> p_seat;
      d := (abs(x[i] - x[j]) + abs(y[i] - y[j]));
      if d < d_army[own[i] + 1] then d_army[own[i] + 1] := d; end if;
    end loop;
  end loop;

  for s in 0 .. 3 loop
    continue when s = p_seat or not alive[s + 1];
    ci := cidx[s + 1];
    for i in 1 .. n loop
      continue when own[i] not between 0 and 3 or own[i] = s;
      d := (abs(x[i] - x[ci]) + abs(y[i] - y[ci]));
      if d <= mov[i] + rmax[i] then
        if own[i] = p_seat then mypot[s + 1] := mypot[s + 1] + avg_[i];
        else steal[s + 1] := steal[s + 1] + avg_[i]; end if;
      end if;
    end loop;
  end loop;

  my_str := str[p_seat + 1];
  for s in 0 .. 3 loop
    if alive[s + 1] then alive_n := alive_n + 1; end if;
    if s <> p_seat and alive[s + 1] then
      en_n := en_n + 1; en_avg := en_avg + str[s + 1];
      max_str := greatest(max_str, str[s + 1]);
      thr_all := thr_all + thr[s + 1];
    end if;
  end loop;
  en_avg := en_avg / greatest(en_n, 1);

  for s in 0 .. 3 loop
    continue when s = p_seat or not alive[s + 1];
    ci := cidx[s + 1];
    crown_frac := hp[ci]::numeric / greatest(mhp[ci], 1);
    thr_r := least(1, thr[s + 1] / greatest(my_hp, 1));
    prox := greatest(0, 1 - d_army[s + 1] / 8.0);
    weak := 1 - str[s + 1] / greatest(max_str, 1);
    stl := least(1, steal[s + 1] / greatest(hp[ci], 1));
    mine := least(1, mypot[s + 1] / greatest(hp[ci], 1));
    p := 1 + 0.6 * (1 - crown_frac) + 1.0 * thr_r + 0.7 * prox + 0.4 * weak + 0.3 * stl + 0.9 * mine;
    if str[s + 1] > 1.6 * my_str and thr_r < 0.3 then p := p * 0.8; end if;
    pri[s + 1] := greatest(0.6, least(3.2, p));
    if alive_n <= 2 then pri[s + 1] := 1; end if;
  end loop;

  my_frac := my_hp / my_mhp;
  if my_frac < 0.5 or (en_n > 0 and my_str < 0.55 * en_avg) or thr_all >= my_hp then
    posture := 'defend'; expo := 1.6; guard := 1.5;
  elsif en_n > 0 and my_str > 1.35 * en_avg and my_frac >= 0.7 then
    posture := 'hunt'; expo := 0.8; guard := 0.6;
  end if;
  if alive_n <= 2 then expo := least(expo, 1.0); end if;

  for s in 0 .. 3 loop
    continue when s = p_seat or not alive[s + 1];
    ci := cidx[s + 1];
    sc := pri[s + 1] * (1 - 0.04 * least(12, (abs(x[ci] - x[mi]) + abs(y[ci] - y[mi]))));
    if sc > fbest then fbest := sc; fs := s; end if;
  end loop;

  for i in 1 .. n loop
    continue when own[i] = p_seat or own[i] not between 0 and 3;
    d := (abs(x[i] - x[mi]) + abs(y[i] - y[mi]));
    t_sc := d - (mov[i] + rmax[i]) - avg_[i] / 100.0;
    if t_sc < t_best then t_best := t_sc; t_i := i; end if;
  end loop;

  return jsonb_build_object(
    'alive_n', alive_n, 'pri', to_jsonb(pri), 'alive', to_jsonb(alive),
    'my_crown', jsonb_build_object('id', id_[mi], 'x', x[mi], 'y', y[mi], 'hp', hp[mi], 'mhp', mhp[mi]),
    'my_str', my_str, 'en_avg', en_avg, 'posture', posture, 'expo_mult', expo, 'guard_mult', guard,
    'focus', case when fs >= 0 then jsonb_build_object('seat', fs, 'x', x[cidx[fs + 1]], 'y', y[cidx[fs + 1]]) else null end,
    'threat', case when t_i > 0 then jsonb_build_object(
        'id', id_[t_i], 'x', x[t_i], 'y', y[t_i], 'owner', own[t_i],
        'd', (abs(x[t_i] - x[mi]) + abs(y[t_i] - y[mi]))) else null end);
end $function$;

create or replace function public.cn_rb_structure_value(p_st jsonb, p_seat integer, p_kind text, p_x integer, p_y integer, w jsonb, ctx jsonb, p_caster text default null::text)
 returns numeric
 language plpgsql
 stable
 set search_path to 'public'
as $function$
declare
  v_val numeric := 0; v_own_pen numeric := 0; q jsonb; m jsonb; nearest jsonb;
  cx int; cy int; bw int; bh int; base numeric; pri numeric; approach numeric;
  d_et int; d_em int; d_tm int; d_tc int; best_d int; choke int := 0; dx int; dy int; nx int; ny int;
begin
  if ctx is null or ctx->'my_crown' is null or p_kind not in ('bomb', 'tornado') then
    return coalesce((w->>'ability_structure_flat')::numeric, 25);
  end if;
  cx := (ctx->'my_crown'->>'x')::int; cy := (ctx->'my_crown'->>'y')::int;
  bw := coalesce((p_st->'board'->>'w')::int, 6); bh := coalesce((p_st->'board'->>'h')::int, 8);
  base := case p_kind when 'bomb' then (w->>'bomb_approach')::numeric
                      else (w->>'tornado_approach')::numeric end;
  d_tc := (abs(p_x - cx) + abs(p_y - cy));

  for q in select * from jsonb_array_elements(coalesce(p_st->'units', '[]'::jsonb)) loop
    continue when (q->>'hp')::int <= 0;
    if (q->>'owner')::int = p_seat then
      if q->>'id' is not distinct from p_caster then
        if p_kind = 'bomb' and (abs((q->>'x')::int - p_x) + abs((q->>'y')::int - p_y)) <= 1 then
          v_own_pen := v_own_pen + 60;
        end if;
        continue;
      end if;
      d_et := (abs((q->>'x')::int - p_x) + abs((q->>'y')::int - p_y));
      if d_et <= 1 then
        v_own_pen := v_own_pen + case p_kind
          when 'bomb' then (w->>'bomb_self_pen')::numeric + (q->>'maxHp')::int * 0.5
          else 45 end;
      end if;
      if p_kind = 'bomb' and coalesce((q->>'royal')::boolean, false) and d_et <= 2 then
        v_own_pen := v_own_pen + 300;
      end if;
      continue;
    end if;

    best_d := 99; nearest := null;
    for m in select * from jsonb_array_elements(p_st->'units') loop
      continue when (m->>'owner')::int <> p_seat or (m->>'hp')::int <= 0;
      d_em := (abs((q->>'x')::int - (m->>'x')::int) + abs((q->>'y')::int - (m->>'y')::int));
      if d_em < best_d then best_d := d_em; nearest := m; end if;
    end loop;
    continue when nearest is null;

    d_et := (abs((q->>'x')::int - p_x) + abs((q->>'y')::int - p_y));
    d_tm := (abs(p_x - (nearest->>'x')::int) + abs(p_y - (nearest->>'y')::int));
    if d_et >= 1 and d_et <= (q->>'mov')::int + 4 and d_et + d_tm <= best_d + 1 and d_tm >= 1 then
      pri := coalesce((ctx->'pri'->>((q->>'owner')::int))::numeric, 1);
      approach := base * pri
                  * case when (q->>'rmax')::int <= 1 then 1.3 else 0.75 end
                  * least(1.0, 4.0 / greatest(d_et, 1));
      v_val := v_val + approach;
    end if;
  end loop;

  for dx in -1 .. 1 loop
    for dy in -1 .. 1 loop
      continue when abs(dx) + abs(dy) <> 1;
      nx := p_x + dx; ny := p_y + dy;
      if nx < 0 or ny < 0 or nx >= bw or ny >= bh then choke := choke + 1; continue; end if;
      if exists (select 1 from jsonb_array_elements(coalesce(p_st->'obstacles', '[]'::jsonb)) o
                  where (o->>'x')::int = nx and (o->>'y')::int = ny
                    and cn_obj_solid(cn_obj_kind(o))) then
        choke := choke + 1;
      end if;
    end loop;
  end loop;
  v_val := v_val * (1 + 0.12 * choke);

  v_val := v_val + greatest(0, 4 - (abs(p_x - bw / 2) + abs(p_y - bh / 2))) * 7
                 + greatest(0, 5 - d_tc) * 5;
  if ctx->>'posture' = 'defend' then v_val := v_val * 1.3; end if;
  return v_val - v_own_pen;
end $function$;

create or replace function public.cn_rb_throw_tile(p_st jsonb, p_seat integer)
 returns text
 language plpgsql
 stable
 set search_path to 'public'
as $function$
declare
  v_p jsonb := cn_pending(p_st); v_u jsonb; q jsonb; v_reach int := cn_throw_reach();
  w jsonb := cn_rb_weights(); ctx jsonb; crown jsonb;
  cx int; cy int; tx int; ty int; d int; bw int; bh int; mine boolean;
  best_s numeric := -1e9; best text := null; sc numeric; trap int;
  d_c_old int; d_c_new int; iso int; e_expo numeric; near_others int; kx int; ky int;
begin
  if v_p is null then return null; end if;
  select qq into v_u from jsonb_array_elements(p_st->'units') qq where qq->>'id' = v_p->>'unit';
  if v_u is null then return null; end if;
  ctx := cn_rb_ctx(p_st, p_seat, w);
  crown := ctx->'my_crown';
  mine := (v_u->>'owner')::int = p_seat;
  cx := (v_u->>'x')::int; cy := (v_u->>'y')::int;
  bw := (p_st->'board'->>'w')::int; bh := (p_st->'board'->>'h')::int;
  kx := coalesce((crown->>'x')::int, cx); ky := coalesce((crown->>'y')::int, cy);
  d_c_old := (abs(cx - kx) + abs(cy - ky));

  for tx in cx - v_reach .. cx + v_reach loop
    for ty in cy - v_reach .. cy + v_reach loop
      continue when tx < 0 or ty < 0 or tx >= bw or ty >= bh;
      d := (abs(tx - cx) + abs(ty - cy));
      continue when d < 1 or d > v_reach;
      continue when exists (select 1 from jsonb_array_elements(p_st->'units') qu
                             where (qu->>'x')::int = tx and (qu->>'y')::int = ty);
      continue when exists (select 1 from jsonb_array_elements(coalesce(p_st->'obstacles', '[]'::jsonb)) e
                             where (e->>'x')::int = tx and (e->>'y')::int = ty
                               and cn_obj_solid(cn_obj_kind(e)));
      trap := cn_bot_trap_threat(p_st, tx, ty);
      d_c_new := (abs(tx - kx) + abs(ty - ky));
      if mine then
        e_expo := 0;
        for q in select * from jsonb_array_elements(p_st->'units') loop
          continue when (q->>'owner')::int = p_seat or (q->>'hp')::int <= 0;
          if (abs((q->>'x')::int - tx) + abs((q->>'y')::int - ty))
             <= (q->>'mov')::int + (q->>'rmax')::int then e_expo := e_expo + 1; end if;
        end loop;
        sc := - trap * 40 - e_expo * 25 + (d_c_old - d_c_new) * 6;
      else
        iso := 99; near_others := 0;
        for q in select * from jsonb_array_elements(p_st->'units') loop
          continue when (q->>'hp')::int <= 0 or q->>'id' = v_u->>'id';
          if (q->>'owner')::int = (v_u->>'owner')::int then
            iso := least(iso, (abs((q->>'x')::int - tx) + abs((q->>'y')::int - ty)));
          elsif (q->>'owner')::int <> p_seat
                and (abs((q->>'x')::int - tx) + abs((q->>'y')::int - ty)) <= 2 then
            near_others := near_others + 1;
          end if;
        end loop;
        sc := trap * case when trap >= (v_u->>'hp')::int then 60 else 14 end
              + (d_c_new - d_c_old) * 12
              + least(iso, 5) * 4
              + near_others * 6
              - case when d_c_new <= (v_u->>'mov')::int + (v_u->>'rmax')::int then 220 else 0 end;
      end if;
      if sc > best_s then best_s := sc; best := '@' || tx || ',' || ty; end if;
    end loop;
  end loop;
  return best;
end $function$;

create or replace function public.cn_rb_score_ability(p_st jsonb, p_seat integer, p_unit jsonb, p_target text, w jsonb, ctx jsonb)
 returns numeric
 language plpgsql
 stable
 set search_path to 'public'
as $function$
declare
  v_ctx jsonb; v_scratch jsonb; v_score numeric := 0; v_tgt jsonb;
  u_old jsonb; u_new jsonb; o_new jsonb;
  v_owner int; v_old_hp int; v_new_hp int; v_max_hp int; v_died boolean; v_delta int;
  v_pri numeric; v_roy boolean; v_thr boolean;
  atk numeric := coalesce((w->>'atk_mult')::numeric, 9);
  kill numeric := coalesce((w->>'kill_bonus_flat')::numeric, 450);
  heal numeric := coalesce((w->>'heal_mult')::numeric, 12);
  crown_kill numeric := coalesce((w->>'crown_kill_flat')::numeric, 1500);
  crown_dmg numeric := coalesce((w->>'crown_dmg_bonus')::numeric, 9);
  crown_heal numeric := coalesce((w->>'crown_heal_mult')::numeric, 0.8);
  crown_loss numeric := coalesce((w->>'crown_loss_mult')::numeric, 1.2);
  burn_b numeric := coalesce((w->>'burn_bonus')::numeric, 21);
  pois_b numeric := coalesce((w->>'poison_bonus')::numeric, 25);
  stun_b numeric := coalesce((w->>'stun_bonus')::numeric, 60);
  ticks numeric := coalesce((w->>'status_ticks')::numeric, 3);
  disc numeric := coalesce((w->>'status_disc')::numeric, 0.6);
begin
  if p_target is not null then
    if left(p_target, 1) = '@' then
      v_ctx := jsonb_build_object('turnNumber', coalesce((p_st->>'turnNumber')::int, 1), 'tile', p_target);
    else
      select q into v_tgt from jsonb_array_elements(p_st->'units') q where q->>'id' = p_target;
      if v_tgt is null then return null; end if;
      v_ctx := jsonb_build_object('turnNumber', coalesce((p_st->>'turnNumber')::int, 1), 'target', v_tgt);
    end if;
  else
    v_ctx := jsonb_build_object('turnNumber', coalesce((p_st->>'turnNumber')::int, 1));
  end if;

  v_scratch := cn_run_effects(p_st, 'ON_ABILITY', p_unit, v_ctx);
  if v_scratch->'units' = p_st->'units'
     and coalesce(v_scratch->'obstacles', '[]'::jsonb) = coalesce(p_st->'obstacles', '[]'::jsonb) then
    return null;
  end if;

  for u_old in select * from jsonb_array_elements(p_st->'units') loop
    v_owner := (u_old->>'owner')::int;
    v_old_hp := (u_old->>'hp')::int;
    v_max_hp := (u_old->>'maxHp')::int;
    v_roy := coalesce((u_old->>'royal')::boolean, false);
    u_new := null;
    select q into u_new from jsonb_array_elements(v_scratch->'units') q where q->>'id' = u_old->>'id';
    v_died := u_new is null or (u_new->>'hp')::int <= 0;
    v_new_hp := case when v_died then 0 else (u_new->>'hp')::int end;
    v_delta := v_old_hp - v_new_hp;

    if v_owner <> p_seat then
      v_pri := coalesce((ctx->'pri'->>v_owner)::numeric, 1);
      if v_delta > 0 then
        v_score := v_score + least(v_delta, v_old_hp) * atk * v_pri;
        if v_died then
          v_score := v_score + (kill + v_max_hp) * v_pri;
          if v_roy then v_score := v_score + crown_kill; end if;
        elsif v_roy then
          v_score := v_score + crown_dmg * v_delta * v_pri
                     * (1 + (1 - v_new_hp::numeric / greatest(v_max_hp, 1)));
        end if;
      elsif v_delta < 0 then
        v_score := v_score - abs(v_delta) * heal * v_pri;
      end if;
      if not v_died then
        if not cn_has(u_old, 'burn') and cn_has(u_new, 'burn') then v_score := v_score + 0.15 * v_max_hp * ticks * atk * disc * v_pri + greatest(0, cn_rb_combo(p_unit, 'BURNING')) * atk * 0.5 * v_pri; end if;
        if not cn_has(u_old, 'poison') and cn_has(u_new, 'poison') then v_score := v_score + 0.10 * v_max_hp * ticks * atk * disc * v_pri + greatest(0, cn_rb_combo(p_unit, 'POISON')) * atk * 0.5 * v_pri; end if;
        if coalesce((u_new->'effects'->>'stun')::int, 0) > coalesce((u_old->'effects'->>'stun')::int, 0) then
          v_score := v_score + stun_b * v_pri;
        end if;
      end if;
    else
      if v_delta < 0 then
        v_thr := exists (
          select 1 from jsonb_array_elements(p_st->'units') e
           where (e->>'owner')::int <> p_seat and (e->>'hp')::int > 0
             and (abs((e->>'x')::int - (u_old->>'x')::int) + abs((e->>'y')::int - (u_old->>'y')::int))
                 <= (e->>'mov')::int + (e->>'rmax')::int);
        v_score := v_score + least(abs(v_delta), v_max_hp) * heal
                   * case when v_roy then 1 + crown_heal else 1 end
                   * case when v_thr then 1.25 else 1 end;
      elsif v_delta > 0 then
        v_score := v_score - v_delta * atk * case when v_roy then 1 + crown_loss else 1 end;
        if v_died then
          v_score := v_score - kill - v_max_hp;
          if v_roy then v_score := v_score - crown_kill * 2; end if;
        end if;
      end if;
      if not v_died then
        if not cn_has(u_old, 'burn') and cn_has(u_new, 'burn') then v_score := v_score - 0.15 * v_max_hp * ticks * atk * disc; end if;
        if not cn_has(u_old, 'poison') and cn_has(u_new, 'poison') then v_score := v_score - 0.10 * v_max_hp * ticks * atk * disc; end if;
        if coalesce((u_new->'effects'->>'stun')::int, 0) > coalesce((u_old->'effects'->>'stun')::int, 0) then
          v_score := v_score - stun_b;
        end if;
      end if;
    end if;
  end loop;

  for o_new in select * from jsonb_array_elements(coalesce(v_scratch->'obstacles', '[]'::jsonb)) loop
    if not exists (select 1 from jsonb_array_elements(coalesce(p_st->'obstacles', '[]'::jsonb)) o
                    where o->>'id' = o_new->>'id') then
      v_score := v_score + cn_rb_structure_value(
        p_st, p_seat, cn_obj_kind(o_new), (o_new->>'x')::int, (o_new->>'y')::int, w, ctx, p_unit->>'id');
    end if;
  end loop;

  return v_score;
end $function$;

create or replace function public.cn_rb_ability_options(p_st jsonb, p_seat integer, p_unit jsonb, w jsonb, ctx jsonb)
 returns jsonb
 language plpgsql
 stable
 set search_path to 'public'
as $function$
declare
  v_out jsonb := '[]'::jsonb; v_script jsonb := coalesce(p_unit->'abilityScript', '[]'::jsonb);
  v_turn int := coalesce((p_st->>'turnNumber')::int, 1);
  v_max int := nullif(p_unit->>'abilityMaxUses', '')::int;
  v_cd int := coalesce(nullif(p_unit->>'abilityCooldownTurns', '')::int, 0);
  v_used int := coalesce((p_unit->>'abilityUses')::int, 0);
  v_last int := nullif(p_unit->>'abilityLastUsedTurn', '')::int;
  v_needs_target boolean; v_needs_tile boolean; v_hostile boolean; v_friendly boolean;
  v_score numeric; t2 jsonb; v_tile text; v_d int; v_min numeric;
  v_ux int := (p_unit->>'x')::int; v_uy int := (p_unit->>'y')::int;
  v_rmax int := coalesce((p_unit->>'rmax')::int, 1);
begin
  if p_unit->>'abilityKind' is distinct from 'scripted' then return v_out; end if;
  if v_max is not null and v_used >= v_max then return v_out; end if;
  if v_cd > 0 and v_last is not null and v_turn - v_last <= v_cd then return v_out; end if;

  v_needs_target := exists (select 1 from jsonb_array_elements(v_script) r
                             where r->>'trigger' = 'ON_ABILITY' and r->>'target_selector' = 'THE_TARGET');
  v_needs_tile := exists (select 1 from jsonb_array_elements(v_script) r
                           where r->>'trigger' = 'ON_ABILITY' and r->>'target_selector' = 'BOARD_CELL');
  v_hostile := exists (select 1 from jsonb_array_elements(v_script) r
                        where r->>'trigger' = 'ON_ABILITY' and r->>'target_selector' = 'THE_TARGET'
                          and r->>'action' <> 'HEAL');
  v_friendly := exists (select 1 from jsonb_array_elements(v_script) r
                         where r->>'trigger' = 'ON_ABILITY' and r->>'target_selector' = 'THE_TARGET'
                           and r->>'action' = 'HEAL');

  if not v_needs_target and not v_needs_tile then
    v_score := cn_rb_score_ability(p_st, p_seat, p_unit, null, w, ctx);
    if v_score is not null then v_out := v_out || jsonb_build_object('t', null, 's', v_score); end if;
  end if;

  if v_needs_target then
    for t2 in select * from jsonb_array_elements(p_st->'units') loop
      continue when (t2->>'hp')::int <= 0;
      if v_friendly and not v_hostile then
        continue when (t2->>'owner')::int <> p_seat;
        continue when (t2->>'hp')::int >= (t2->>'maxHp')::int;
      elsif v_hostile and not v_friendly then
        continue when (t2->>'owner')::int = p_seat;
      end if;
      v_d := (abs((t2->>'x')::int - v_ux) + abs((t2->>'y')::int - v_uy));
      continue when v_d > v_rmax;
      v_score := cn_rb_score_ability(p_st, p_seat, p_unit, t2->>'id', w, ctx);
      if v_score is not null then
        v_out := v_out || jsonb_build_object('t', t2->>'id', 's', v_score);
      end if;
    end loop;
  end if;

  if v_needs_tile then
    foreach v_tile in array cn_rb_ability_tiles(p_st, p_unit) loop
      v_score := cn_rb_score_ability(p_st, p_seat, p_unit, v_tile, w, ctx);
      if v_score is not null then
        v_out := v_out || jsonb_build_object('t', v_tile, 's', v_score);
      end if;
    end loop;
  end if;

  if v_max is not null and v_used + 1 >= v_max then
    v_min := coalesce((w->>'last_use_min')::numeric, 140);
    select coalesce(jsonb_agg(o), '[]'::jsonb) into v_out
      from jsonb_array_elements(v_out) o where (o->>'s')::numeric >= v_min;
  end if;
  return v_out;
end $function$;

-- Per-card knowledge that is NOT derived from the 1v1 rules: what each card is
-- for. Update this when a new card is added.
create or replace function public.cn_rb_strategy_bonus(p_st jsonb, p_seat integer, u jsonb, p_kind text, p_vx integer, p_vy integer, p_target text, ctx jsonb)
 returns numeric
 language plpgsql
 stable
 set search_path to 'public'
as $function$
declare
  v_slug text := u->>'slug';
  v_bonus numeric := 0; v_near int := 99; v_support int := 0; v_depth int;
  v_ckx int; v_cky int; v_fx int; v_fy int; v_has_focus boolean;
  q jsonb; v_d int; v_avg numeric; v_target jsonb;
begin
  if v_slug is null or v_slug not in ('wuzu', 'eva', 'umiro', 'lumea', 'dione-grifo', 'dorme', 'himanta')
     or ctx->'my_crown' is null then
    return 0;
  end if;
  v_ckx := (ctx->'my_crown'->>'x')::int; v_cky := (ctx->'my_crown'->>'y')::int;
  v_has_focus := ctx->'focus' is not null and jsonb_typeof(ctx->'focus') = 'object';
  if v_has_focus then v_fx := (ctx->'focus'->>'x')::int; v_fy := (ctx->'focus'->>'y')::int; end if;

  for q in select * from jsonb_array_elements(coalesce(p_st->'units', '[]'::jsonb)) loop
    continue when (q->>'hp')::int <= 0;
    if (q->>'owner')::int <> p_seat then
      v_d := (abs(p_vx - (q->>'x')::int) + abs(p_vy - (q->>'y')::int));
      if v_d < v_near then v_near := v_d; end if;
    elsif q->>'id' <> u->>'id' and not coalesce((q->>'royal')::boolean, false) then
      v_support := v_support + 1;
    end if;
  end loop;
  v_depth := (abs(p_vx - v_ckx) + abs(p_vy - v_cky));

  if p_target is not null and left(p_target, 1) <> '@' then
    select qt into v_target from jsonb_array_elements(p_st->'units') qt where qt->>'id' = p_target;
  end if;

  if v_slug = 'wuzu' then
    v_avg := ((u->>'dmin')::int + (u->>'dmax')::int) / 2.0;
    if v_avg < 25 then
      if p_kind = 'move' then v_bonus := v_bonus + least(v_near, 6) * 18;
      elsif p_kind = 'attack' then v_bonus := v_bonus - 260; end if;
    else
      if p_kind = 'move' and v_has_focus then
        v_bonus := v_bonus + (10 - least((abs(p_vx - v_fx) + abs(p_vy - v_fy)), 10)) * 12;
      elsif p_kind = 'attack' and v_target is not null and v_has_focus then
        if coalesce((v_target->>'royal')::boolean, false)
           or (abs((v_target->>'x')::int - v_fx) + abs((v_target->>'y')::int - v_fy)) <= 2 then
          v_bonus := v_bonus + 260;
        else
          v_bonus := v_bonus - 40;
        end if;
      end if;
    end if;

  elsif v_slug = 'eva' then
    if p_kind = 'move' then
      v_bonus := v_bonus + least(v_near, 5) * 8;
      for q in select * from jsonb_array_elements(p_st->'units') loop
        if (q->>'owner')::int = p_seat and q->>'slug' in ('fey', 'sinie', 'lium') and (q->>'hp')::int > 0 then
          v_d := (abs(p_vx - (q->>'x')::int) + abs(p_vy - (q->>'y')::int));
          if (q->>'hp')::int < (q->>'maxHp')::int
             or exists (select 1 from jsonb_array_elements(p_st->'units') e
                         where (e->>'owner')::int <> p_seat and (e->>'hp')::int > 0
                           and (abs((e->>'x')::int - (q->>'x')::int) + abs((e->>'y')::int - (q->>'y')::int)) <= 2) then
            v_bonus := v_bonus + greatest(0, 6 - v_d) * 12;
          end if;
        end if;
      end loop;
    elsif p_kind = 'ability' and v_target is not null and v_target->>'slug' in ('fey', 'sinie', 'lium') then
      v_bonus := v_bonus + 40;
    end if;

  elsif v_slug = 'umiro' and p_kind = 'move' then
    v_bonus := v_bonus + least(v_depth, 3) * 5;

  elsif v_slug = 'lumea' then
    if coalesce((u->>'abilityUses')::int, 0) > 0 and p_kind = 'move' then
      v_bonus := v_bonus + (8 - least(v_near, 8)) * 10;
    end if;

  elsif v_slug = 'dione-grifo' then
    if p_kind = 'move' then
      v_bonus := v_bonus + least(v_depth, 4) * 12;
      for q in select * from jsonb_array_elements(p_st->'units') loop
        if (q->>'owner')::int <> p_seat and (q->>'hp')::int > 0
           and (abs(p_vx - (q->>'x')::int) + abs(p_vy - (q->>'y')::int)) <= 2 then
          v_bonus := v_bonus + 20;
        end if;
      end loop;
      v_bonus := v_bonus + greatest(0, 3 - v_near) * 15;
    elsif p_kind = 'ability' then
      v_bonus := v_bonus + 30;
    end if;

  elsif v_slug = 'dorme' then
    if v_support > 1 then
      if p_kind = 'move' then
        v_bonus := v_bonus + (6 - least(v_depth, 6)) * 10;
      elsif p_kind in ('attack', 'ability') then
        v_bonus := v_bonus - 150;
      end if;
    else
      if p_kind = 'move' then v_bonus := v_bonus + (8 - least(v_near, 8)) * 14;
      elsif p_kind = 'attack' then v_bonus := v_bonus + 80; end if;
    end if;

  elsif v_slug = 'himanta' then
    if p_kind = 'attack' and v_target is not null then
      v_bonus := v_bonus + greatest(0, 6 - (abs((v_target->>'x')::int - v_ckx) + abs((v_target->>'y')::int - v_cky))) * 25;
    elsif p_kind = 'move' then
      v_bonus := v_bonus + (6 - least(v_depth, 6)) * 8;
    end if;
  end if;

  return v_bonus;
end $function$;

-- The Expert Battle Royale turn. Everything a 1v1 Expert weighs (damage, kills,
-- counter-attacks, parry, traps, status value, guarding the crown, spacing) is here,
-- generalised to N rivals: each rival seat has a priority (cn_rb_ctx), exposure is
-- split by how many targets an enemy could choose from, and the crown hides behind
-- its army while 3+ crowns are alive.
create or replace function public.royale_bot_step(p_match uuid, p_seat integer)
 returns royale_matches
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  m public.royale_matches; st jsonb; st_v jsonb; w jsonb; ctx jsonb; v_lvl int;
  u jsonb; u_v jsonb; v_opt jsonb; v_tiles text[]; v_tile text; vx int; vy int;
  e_id text[]; e_own int[]; e_x int[]; e_y int[]; e_hp int[]; e_mhp int[]; e_avg numeric[];
  e_rmin int[]; e_rmax int[]; e_mov int[]; e_crmin int[]; e_crmax int[]; e_roy boolean[];
  e_par boolean[]; e_burn boolean[]; e_reach int[];
  n int; i int; j int; k int; kk int; ii int; bi int; v_first boolean;
  o_x int[]; o_y int[]; o_trap int[]; o_torn boolean[]; on_ int;
  atk numeric; kill numeric; heal numeric; ctr_m numeric; burn_b numeric; stun_b numeric;
  pos_dist numeric; pos_near numeric; thr_m numeric; noise_s numeric; ally_ideal numeric; ally_mult numeric;
  trap_m numeric; trap_lethal numeric; lethal_ctr numeric; lethal_par numeric; heal_full numeric;
  crown_kill numeric; crown_dmg numeric; crown_heal numeric; crown_expo numeric; crown_lethal numeric;
  crown_ideal numeric; unit_lethal numeric; guard_move numeric; guard_atk numeric; torn_pen numeric;
  v_pri numeric[]; expo_m numeric; guard_m numeric; mcx int; mcy int; v_threat jsonb; thr_d int;
  u_dmg numeric; u_rmin int; u_rmax int; u_hp int; u_mhp int; u_roy boolean; u_heals boolean;
  u_burns boolean; u_sneaks boolean; u_stuns boolean; u_id text; ux int; uy int;
  can_move boolean; can_attack boolean; can_ability boolean;
  v_near_raw int; v_near_w numeric; v_d int; v_expo numeric; v_pot numeric; v_pot_split numeric;
  v_ally_near int; v_pos numeric; v_pos_total numeric; v_base numeric; v_trap int; v_torn boolean;
  v_guard numeric; v_step numeric; v_noise numeric; v_act numeric; v_ctr numeric; pri_t numeric;
  v_answers boolean; v_parry boolean; v_strat numeric;
  ct_x int[]; ct_y int[]; ct_pos numeric[]; v_used_idx int[]; v_sel int[]; bs numeric;
  v_best numeric := 0; v_bu text; v_bx int; v_by int; v_bt text; v_bkind text;
  v_fb numeric := -1e9; v_fu text; v_fbx int; v_fby int; v_ft text; v_fkind text;
  v_tgt text; v_pu jsonb; crown_passive boolean; my_cnt int; cm numeric;
begin
  select * into m from public.royale_matches where id = p_match for update;
  if m.id is null then return m; end if;
  if m.status <> 'active' then return m; end if;

  if cn_pending(m.state) is not null and (cn_pending(m.state)->>'side')::int = p_seat
     and exists (select 1 from public.royale_players
                  where match_id = p_match and seat = p_seat and bot is not null and not eliminated) then
    perform cn_throw_royale(p_match, p_seat, cn_rb_throw_tile(m.state, p_seat));
    return cn_royale_commit(p_match);
  end if;
  if coalesce((m.state->>'turn')::int, -1) <> p_seat then return m; end if;

  select bot into v_lvl from public.royale_players
   where match_id = p_match and seat = p_seat and not eliminated;
  if v_lvl is null then return m; end if;
  st := m.state;
  if cn_pending(st) is not null then return m; end if;

  begin
    w := cn_rb_weights();
    ctx := cn_rb_ctx(st, p_seat, w);
    if ctx->'my_crown' is null then return advance_turn_royale(p_match, null, false); end if;

    atk := (w->>'atk_mult')::numeric; kill := (w->>'kill_bonus_flat')::numeric;
    heal := (w->>'heal_mult')::numeric; ctr_m := (w->>'ctr_mult')::numeric;
    burn_b := (w->>'burn_bonus')::numeric; stun_b := (w->>'stun_bonus')::numeric;
    pos_dist := (w->>'pos_dist_mult')::numeric; pos_near := (w->>'pos_near_mult')::numeric;
    thr_m := (w->>'threat_mult')::numeric; noise_s := (w->>'noise_scale')::numeric;
    ally_ideal := (w->>'ally_spacing_ideal')::numeric; ally_mult := (w->>'ally_spacing_mult')::numeric;
    trap_m := (w->>'trap_dmg_mult')::numeric; trap_lethal := (w->>'lethal_trap_penalty_flat')::numeric;
    lethal_ctr := (w->>'lethal_ctr_penalty_flat')::numeric; lethal_par := (w->>'lethal_parry_extra_flat')::numeric;
    heal_full := (w->>'heal_full_penalty')::numeric;
    crown_kill := (w->>'crown_kill_flat')::numeric; crown_dmg := (w->>'crown_dmg_bonus')::numeric;
    crown_heal := (w->>'crown_heal_mult')::numeric; crown_expo := (w->>'crown_expo_mult')::numeric;
    crown_lethal := (w->>'crown_lethal_flat')::numeric; crown_ideal := (w->>'crown_ideal_d')::numeric;
    unit_lethal := (w->>'unit_lethal_expo_mult')::numeric;
    guard_move := (w->>'guard_move_mult')::numeric; guard_atk := (w->>'guard_atk_mult')::numeric;
    torn_pen := (w->>'tornado_step_pen')::numeric;

    select array_agg(x::numeric order by o) into v_pri
      from jsonb_array_elements_text(ctx->'pri') with ordinality t(x, o);
    expo_m := (ctx->>'expo_mult')::numeric; guard_m := (ctx->>'guard_mult')::numeric;
    mcx := (ctx->'my_crown'->>'x')::int; mcy := (ctx->'my_crown'->>'y')::int;
    v_threat := case when jsonb_typeof(ctx->'threat') = 'object' then ctx->'threat' else null end;
    thr_d := coalesce((v_threat->>'d')::int, 99);

    select array_agg(q->>'id' order by o), array_agg((q->>'owner')::int order by o),
           array_agg((q->>'x')::int order by o), array_agg((q->>'y')::int order by o),
           array_agg((q->>'hp')::int order by o), array_agg((q->>'maxHp')::int order by o),
           array_agg(((q->>'dmin')::int + (q->>'dmax')::int) / 2.0 order by o),
           array_agg((q->>'rmin')::int order by o), array_agg((q->>'rmax')::int order by o),
           array_agg((q->>'mov')::int order by o),
           array_agg((q->>'crmin')::int order by o), array_agg((q->>'crmax')::int order by o),
           array_agg(coalesce((q->>'royal')::boolean, false) order by o),
           array_agg(coalesce((q->>'parries')::boolean, false) order by o),
           array_agg(cn_has(q, 'burn') order by o)
      into e_id, e_own, e_x, e_y, e_hp, e_mhp, e_avg, e_rmin, e_rmax, e_mov, e_crmin, e_crmax,
           e_roy, e_par, e_burn
      from jsonb_array_elements(st->'units') with ordinality t(q, o)
     where (q->>'hp')::int > 0;
    n := coalesce(array_length(e_id, 1), 0);
    e_reach := array_fill(0, array[greatest(n, 1)]);
    for i in 1 .. n loop
      for j in 1 .. n loop
        continue when e_own[j] = e_own[i];
        if (abs(e_x[i] - e_x[j]) + abs(e_y[i] - e_y[j])) <= e_mov[i] + e_rmax[i] then
          e_reach[i] := e_reach[i] + 1;
        end if;
      end loop;
    end loop;

    my_cnt := 0;
    for i in 1 .. n loop if e_own[i] = p_seat then my_cnt := my_cnt + 1; end if; end loop;
    -- the crown hides behind its army; on its own (or one-on-one) it fights like any unit
    crown_passive := coalesce((ctx->>'alive_n')::int, 4) > 2 and my_cnt >= 3;
    cm := case when crown_passive then 1 else 0.35 end;
    o_x := '{}'; o_y := '{}'; o_trap := '{}'; o_torn := '{}';
    for u in select * from jsonb_array_elements(coalesce(st->'obstacles', '[]'::jsonb)) loop
      o_x := o_x || (u->>'x')::int; o_y := o_y || (u->>'y')::int;
      o_trap := o_trap || cn_bot_trap_threat(st, (u->>'x')::int, (u->>'y')::int);
      o_torn := o_torn || (cn_obj_kind(u) = 'tornado');
    end loop;
    on_ := coalesce(array_length(o_x, 1), 0);

    for u in select * from jsonb_array_elements(st->'units') loop
      continue when (u->>'owner')::int <> p_seat;
      continue when (u->>'moved')::boolean and (u->>'acted')::boolean;
      continue when coalesce((u->>'spent')::boolean, false);
      continue when coalesce((st->>'acts')::int, 0) >= 1
                and nullif(st->>'active', '') is distinct from u->>'id';
      u_id := u->>'id';
      k := array_position(e_id, u_id);
      continue when k is null;

      ux := (u->>'x')::int; uy := (u->>'y')::int;
      u_dmg := e_avg[k]; u_rmin := e_rmin[k]; u_rmax := e_rmax[k];
      u_hp := e_hp[k]; u_mhp := e_mhp[k]; u_roy := e_roy[k];
      u_heals := coalesce((u->>'heals')::boolean, false);
      u_burns := coalesce((u->>'burns')::boolean, false);
      u_sneaks := coalesce((u->>'sneaks')::boolean, false);
      u_stuns := coalesce((u->>'stuns')::boolean, false);
      can_move := not (u->>'moved')::boolean and (not cn_stunned(u) or not cn_stun_blocks('move'));
      can_attack := not (u->>'acted')::boolean and (not cn_stunned(u) or not cn_stun_blocks('attack'));
      can_ability := not (u->>'acted')::boolean and u->>'abilityKind' is not null
                     and (not cn_stunned(u) or not cn_stun_blocks('ability')) and not cn_swamped(st, u);

      v_tiles := array[ux || ',' || uy];
      if can_move then v_tiles := v_tiles || cn_reach(st, u); end if;
      v_first := true;
      ct_x := '{}'; ct_y := '{}'; ct_pos := '{}';

      foreach v_tile in array v_tiles loop
        vx := split_part(v_tile, ',', 1)::int;
        vy := split_part(v_tile, ',', 2)::int;

        v_near_raw := 99; v_near_w := 99; v_expo := 0; v_pot := 0; v_pot_split := 0;
        for j in 1 .. n loop
          continue when e_own[j] = p_seat;
          v_d := (abs(vx - e_x[j]) + abs(vy - e_y[j]));
          v_near_raw := least(v_near_raw, v_d);
          v_near_w := least(v_near_w, v_d - (v_pri[e_own[j] + 1] - 1) * 1.2);
          if v_d <= e_mov[j] + e_rmax[j] then
            v_expo := v_expo + 1.0 / greatest(1, e_reach[j]);
            v_pot := v_pot + e_avg[j];
            v_pot_split := v_pot_split + e_avg[j] / greatest(1, e_reach[j]);
          end if;
        end loop;
        v_near_w := greatest(v_near_w, 0);

        v_ally_near := 99;
        for j in 1 .. n loop
          continue when e_own[j] <> p_seat or e_id[j] = u_id;
          v_ally_near := least(v_ally_near, (abs(vx - e_x[j]) + abs(vy - e_y[j])));
        end loop;

        if u_roy and crown_passive then
          v_pos := - abs(v_near_raw - crown_ideal) * pos_dist * 0.6
                   - greatest(0, least(v_ally_near, 9) - 2) * 8;
        else
          v_pos := - abs(v_near_w - u_rmax) * pos_dist - v_near_w * pos_near
                   - greatest(0, ally_ideal - v_ally_near) * ally_mult;
        end if;

        if vx <> ux or vy <> uy then
          v_trap := 0; v_torn := false;
          for j in 1 .. on_ loop
            if o_x[j] = vx and o_y[j] = vy then
              v_trap := v_trap + o_trap[j];
              if o_torn[j] then v_torn := true; end if;
            end if;
          end loop;
          if v_trap > 0 then
            v_pos := v_pos - v_trap * trap_m;
            if v_trap >= u_hp then v_pos := v_pos - trap_lethal - u_mhp; end if;
          end if;
          if v_torn then v_pos := v_pos - torn_pen; end if;
        end if;

        if not u_roy and v_threat is not null and thr_d <= 5 then
          v_guard := guard_m * guard_move
                     * greatest(0, 6 - (abs(vx - (v_threat->>'x')::int) + abs(vy - (v_threat->>'y')::int)))
                     * case when (abs(vx - mcx) + abs(vy - mcy)) <= thr_d + 1 then 1.0 else 0.3 end;
          v_pos := v_pos + v_guard;
        end if;

        if u_roy then
          v_pos := v_pos - (v_expo * thr_m * crown_expo * expo_m
                         + v_pot / greatest(u_hp, 1) * 120) * cm;
          if v_pot >= u_hp then v_pos := v_pos - crown_lethal * cm; end if;
        else
          v_pos := v_pos - v_expo * thr_m * expo_m;
          if v_pot_split >= u_hp then v_pos := v_pos - unit_lethal * u_mhp; end if;
        end if;
        v_pos_total := v_pos;

        if v_first then v_base := v_pos_total; v_first := false; end if;
        ct_x := ct_x || vx; ct_y := ct_y || vy; ct_pos := ct_pos || v_pos_total;

        if vx <> ux or vy <> uy then
          v_noise := random() * noise_s;
          v_strat := cn_rb_strategy_bonus(st, p_seat, u, 'move', vx, vy, null, ctx);
          v_step := v_pos_total - v_base + v_noise + v_strat;
          if v_step > v_best then
            v_best := v_step; v_bu := u_id; v_bx := vx; v_by := vy; v_bt := null; v_bkind := null;
          end if;
          if v_step > v_fb then
            v_fb := v_step; v_fu := u_id; v_fbx := vx; v_fby := vy; v_ft := null; v_fkind := null;
          end if;
        end if;

        if can_attack then
          for j in 1 .. n loop
            continue when e_id[j] = u_id;
            v_d := (abs(vx - e_x[j]) + abs(vy - e_y[j]));
            continue when v_d < u_rmin or v_d > u_rmax;
            continue when not cn_los_clear(st, vx, vy, e_x[j], e_y[j]);

            if e_own[j] = p_seat then
              continue when not u_heals;
              v_act := case when e_mhp[j] - e_hp[j] <= 0 then heal_full
                            else least(u_dmg, e_mhp[j] - e_hp[j]) * heal
                                 * case when e_roy[j] then 1 + crown_heal else 1 end end;
            else
              pri_t := v_pri[e_own[j] + 1];
              v_answers := not u_sneaks and v_d >= e_crmin[j] and v_d <= e_crmax[j];
              v_parry := v_answers and e_par[j];
              v_act := least(u_dmg, e_hp[j]) * atk * pri_t;
              if u_dmg >= e_hp[j] then
                v_act := v_act + (kill + e_mhp[j]) * pri_t;
                if e_roy[j] then v_act := v_act + crown_kill; end if;
              else
                if u_burns and not e_burn[j] then v_act := v_act + 0.15 * e_mhp[j] * 3 * atk * 0.6 * pri_t; end if;
                if e_roy[j] then
                  v_act := v_act + crown_dmg * least(u_dmg, e_hp[j]) * pri_t
                           * (1 + (1 - (e_hp[j] - u_dmg) / greatest(e_mhp[j], 1)));
                end if;
                if u_stuns then v_act := v_act + stun_b * pri_t * 0.5; end if;
              end if;
              if v_answers and (v_parry or u_dmg < e_hp[j]) then
                v_ctr := e_avg[j];
                v_act := v_act - v_ctr * ctr_m * case when u_roy then 1.5 else 1 end;
                if v_ctr >= u_hp then
                  v_act := v_act - lethal_ctr - u_mhp
                           - case when v_parry then lethal_par + e_mhp[j] else 0 end
                           - case when u_roy then crown_kill else 0 end;
                end if;
              end if;
              if v_threat is not null and thr_d <= 5 and not u_roy then
                v_act := v_act + guard_m * guard_atk
                         * greatest(0, 5 - (abs(e_x[j] - mcx) + abs(e_y[j] - mcy)));
              end if;
            end if;

            v_noise := random() * noise_s;
            v_strat := cn_rb_strategy_bonus(st, p_seat, u, 'attack', vx, vy, e_id[j], ctx);
            v_step := v_pos_total + v_act - v_base + v_noise + v_strat;
            if v_step > v_best then
              v_best := v_step; v_bu := u_id; v_bx := vx; v_by := vy; v_bt := e_id[j]; v_bkind := 'attack';
            end if;
            if v_step > v_fb then
              v_fb := v_step; v_fu := u_id; v_fbx := vx; v_fby := vy; v_ft := e_id[j]; v_fkind := 'attack';
            end if;
          end loop;
        end if;
      end loop;

      if can_ability then
        v_used_idx := '{}';
        for kk in 1 .. 4 loop
          bi := null; bs := -1e9;
          for ii in 2 .. coalesce(array_length(ct_x, 1), 1) loop
            continue when ii = any(v_used_idx);
            continue when ct_pos[ii] - v_base < -150;
            if ct_pos[ii] > bs then bs := ct_pos[ii]; bi := ii; end if;
          end loop;
          exit when bi is null;
          v_used_idx := v_used_idx || bi;
        end loop;
        v_sel := array[1] || v_used_idx;

        foreach ii in array v_sel loop
          vx := ct_x[ii]; vy := ct_y[ii];
          if vx = ux and vy = uy then
            st_v := st; u_v := u;
          else
            st_v := jsonb_set(st, '{units}', (
              select jsonb_agg(case when q->>'id' = u_id
                                    then q || jsonb_build_object('x', vx, 'y', vy) else q end order by o)
                from jsonb_array_elements(st->'units') with ordinality t(q, o)));
            u_v := u || jsonb_build_object('x', vx, 'y', vy);
          end if;
          v_pu := cn_rb_ability_options(st_v, p_seat, u_v, w, ctx);
          for v_opt in select * from jsonb_array_elements(v_pu) loop
            v_tgt := v_opt->>'t';
            v_strat := cn_rb_strategy_bonus(st_v, p_seat, u, 'ability', vx, vy, v_tgt, ctx);
            v_step := ct_pos[ii] + (v_opt->>'s')::numeric - v_base + random() * noise_s + v_strat;
            if v_step > v_best then
              v_best := v_step; v_bu := u_id; v_bx := vx; v_by := vy; v_bt := v_tgt; v_bkind := 'ability';
            end if;
            if v_step > v_fb then
              v_fb := v_step; v_fu := u_id; v_fbx := vx; v_fby := vy; v_ft := v_tgt; v_fkind := 'ability';
            end if;
          end loop;
        end loop;
      end if;
    end loop;

    if v_bu is null and v_fu is not null then
      v_bu := v_fu; v_bx := v_fbx; v_by := v_fby; v_bt := v_ft; v_bkind := v_fkind;
    end if;
    if v_bu is null then return advance_turn_royale(p_match, null, false); end if;

    for u in select * from jsonb_array_elements(st->'units') loop
      if u->>'id' = v_bu and ((u->>'x')::int <> v_bx or (u->>'y')::int <> v_by) then
        perform cn_move_royale(p_match, p_seat, v_bu, v_bx, v_by);
        return cn_royale_commit(p_match);
      end if;
    end loop;

    if v_bkind = 'ability' then
      perform cn_ability_royale(p_match, p_seat, v_bu, v_bt);
      return cn_royale_commit(p_match);
    end if;
    if v_bt is not null then
      perform cn_attack_royale(p_match, p_seat, v_bu, v_bt);
      return cn_royale_commit(p_match);
    end if;
    return advance_turn_royale(p_match, null, false);
  exception when others then
    insert into public.royale_engine_log (ok, note)
    values (false, format('royale_bot_step seat %s: %s [unit=%s kind=%s tgt=%s at=%s,%s]', p_seat, sqlerrm, v_bu, v_bkind, v_bt, v_bx, v_by));
    return advance_turn_royale(p_match, null, false);
  end;
end $function$;

-- Hotfix for 0179: the derived advance_turn_royale() still wrote the stalemate
-- draw to public.matches (column winner_seat does not exist there). Teach
-- cn_derive_royale() to rewrite every remaining `update public.matches`, then
-- regenerate. Idempotent: databases that already have the line are left alone.
do $fix$
declare v text;
begin
  v := pg_get_functiondef('public.cn_derive_royale()'::regprocedure);
  if position('replace(v, ''update public.matches''' in v) = 0 then
    v := replace(v, E'''advance tail'');\n',
      E'''advance tail'');\n  v := replace(v, ''update public.matches'', ''update public.royale_matches'');\n');
    execute v;
  end if;
  perform public.cn_derive_royale();
end $fix$;
