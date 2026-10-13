-- 0250: the expert bot thinks one reply ahead ("engine": "b4").
--   * cn_b4_eval   position evaluator: material, king safety, the opponent's best two-act reply (exposure), my own
--                  next-turn threat, burn/poison value, tree-shield cover, power auras, bombs/walls, late-game push
--   * bot4_step    the same candidate generator as bot_step, but the best few candidates are PLAYED on a scratch copy
--                  (savepoint, then rolled back) and judged by cn_b4_eval; Caela-style pair swaps are searched too
--   * cn_b4_place  deployment: every unit gets a position for a reason (king guarded, tanks on the line, ranged one row
--                  behind, aura beside the damage dealers, shield units beside trees), picked by a randomised search
--   * a brain whose weights say  "engine": "b4"  uses all of this; any other brain plays exactly as before. Every number
--     lives in that brain's weights (nothing hard-coded). If bot4_step ever errors, bot_step falls back to the classic scorer.
CREATE OR REPLACE FUNCTION public.cn_b4_los(ox integer[], oy integer[], ax integer, ay integer, bx integer, by integer)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
declare i int; v_den float; v_num float;
begin
  if ox is null or array_length(ox,1) is null then return true; end if;
  v_den := sqrt((bx - ax)::float ^ 2 + (by - ay)::float ^ 2);
  if v_den = 0 then return true; end if;
  for i in 1..array_length(ox,1) loop
    if (ox[i] <> ax or oy[i] <> ay) and (ox[i] <> bx or oy[i] <> by)
       and ox[i] between least(ax, bx) and greatest(ax, bx)
       and oy[i] between least(ay, by) and greatest(ay, by) then
      v_num := abs((bx - ax)::float * (ay - oy[i])::float - (ax - ox[i])::float * (by - ay)::float);
      if v_num / v_den < 0.5 then return false; end if;
    end if;
  end loop;
  return true;
end $function$
;

CREATE OR REPLACE FUNCTION public.cn_b4_w(w jsonb, p_key text, p_def numeric)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$ select coalesce((w->>p_key)::numeric, p_def) $function$
;

CREATE OR REPLACE FUNCTION public.cn_b4_eval(st jsonb, me text, w jsonb)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  opp text := case when me = 'host' then 'guest' else 'host' end;
  n int := 0; i int; j int; k int; s int; a int; b int; v int; v2 int; t int;
  u jsonb;
  ox int[] := '{}'; oy int[] := '{}';       -- solid objects (line of sight)
  trx int[] := '{}'; try int[] := '{}';     -- live trees (tree shield)
  e jsonb; v_bd int := 0;
  -- per unit
  uid text[]; uo text[]; ux int[]; uy int[]; uhp int[]; umx int[]; uavg numeric[]; ulo int[]; uhi int[];
  uroyal boolean[]; ucap int[]; uburn boolean[]; upois boolean[]; ushield boolean[]; ustun boolean[];
  uhw numeric[]; uout numeric[]; ujs jsonb[]; ucov boolean[]; ucnrg int[];
  ucond_st text[]; ucond_d numeric[]; uapp_st text[];
  tile_from int[]; tile_to int[]; tx int[] := '{}'; ty int[] := '{}';
  r text[]; tl text;
  -- weights
  w_out numeric := cn_b4_w(w,'out_mult',6); w_rng numeric := cn_b4_w(w,'range_bonus',0.12);
  w_king_hw numeric := cn_b4_w(w,'king_hw',1.5); w_king_out numeric := cn_b4_w(w,'king_out',150);
  w_burn numeric := cn_b4_w(w,'burn_acts',2.5); w_pois numeric := cn_b4_w(w,'poison_turns',3.5);
  w_setup numeric := cn_b4_w(w,'status_setup',12);
  w_expo numeric := cn_b4_w(w,'expo',0.85); w_off numeric := cn_b4_w(w,'off',0.45);
  w_lethal numeric := cn_b4_w(w,'lethal',100000);
  w_approach numeric := cn_b4_w(w,'approach',0.5); w_near numeric := cn_b4_w(w,'near',0.15);
  w_cover numeric := cn_b4_w(w,'tree_cover',25); w_aura numeric := cn_b4_w(w,'aura',6);
  w_kconv numeric := cn_b4_w(w,'king_conv',200);
  w_late0 numeric := cn_b4_w(w,'late_start',0.5); w_late_a numeric := cn_b4_w(w,'late_aggr',0.7);
  w_bomb numeric := cn_b4_w(w,'bomb_val',22); w_wall numeric := cn_b4_w(w,'wall_val',10);
  w_okm numeric := cn_b4_w(w,'opp_king_mult',1); w_pur numeric := cn_b4_w(w,'pursue',0.6); v_dk int; w_kd numeric := cn_b4_w(w,'king_danger',1.0); w_kdo numeric := cn_b4_w(w,'king_danger_opp',0.5); umv int[]; t1 numeric; t2 numeric; kdsum numeric := 0;
  v_cap int := cn_turn_cap(); v_tf numeric; v_by text; v_own text; v_sidebonus numeric := 0;
  w_acts int := coalesce((select acts_per_turn from public.app_settings where id), 2);
  -- results
  mat numeric := 0; pos numeric := 0; expo numeric := 0; off numeric := 0; res numeric;
  king_me int := 0; king_opp int := 0;
  -- threat scratch
  hitv numeric[]; hitd numeric[]; canhit boolean[];
  best1 numeric; vv numeric; dd numeric; tot numeric; thr numeric; lethal boolean;
  d int; ok boolean; avg numeric; np int; capv int; sa int; sv int;
  near_e int; ideal int; pr jsonb; sc jsonb; cfg record;
  nearp numeric;
begin
  -- ---- parse -------------------------------------------------------------------------------------------------
  for e in select * from jsonb_array_elements(coalesce(st->'obstacles','[]'::jsonb)) loop
    if cn_obj_solid(cn_obj_kind(e)) then ox := ox || (e->>'x')::int; oy := oy || (e->>'y')::int; end if;
    if cn_obj_kind(e) = 'tree' and coalesce((e->>'hp')::int,0) > 0 then trx := trx || (e->>'x')::int; try := try || (e->>'y')::int; end if;
  end loop;

  for u in select * from jsonb_array_elements(st->'units') loop
    continue when (u->>'hp')::int <= 0;
    n := n + 1;
    uid[n] := u->>'id'; uo[n] := u->>'owner'; ux[n] := (u->>'x')::int; uy[n] := (u->>'y')::int;
    uhp[n] := (u->>'hp')::int; umx[n] := (u->>'maxHp')::int; ulo[n] := (u->>'rmin')::int; uhi[n] := (u->>'rmax')::int;
    ucnrg[n] := (u->>'crmax')::int; umv[n] := (u->>'mov')::int;
    uroyal[n] := coalesce((u->>'royal')::boolean,false);
    ucap[n] := coalesce(cn_hit_limit(u), 0);
    uburn[n] := cn_has(u,'burn'); upois[n] := cn_has(u,'poison'); ustun[n] := cn_stunned(u);
    ushield[n] := cn_tree_shield(st, u) is not null;
    uavg[n] := ((u->>'dmin')::int + (u->>'dmax')::int) / 2.0 + cn_near_power(st, u);
    uhw[n] := case when uroyal[n] then w_king_hw else 1 end;
    uout[n] := w_out * ((u->>'dmin')::int + (u->>'dmax')::int) / 2.0 * (1 + w_rng * ((u->>'rmax')::int - 1))
               + case when uroyal[n] then w_king_out else 0 end;
    ujs[n] := u;
    -- conditional-damage / status-apply abilities, read from the unit's own script (nothing card-specific here)
    ucond_st[n] := null; ucond_d[n] := 0; uapp_st[n] := null;
    if u->>'abilityKind' = 'scripted' then
      for pr in select * from jsonb_array_elements(coalesce(u->'abilityScript','[]'::jsonb)) loop
        if pr->>'trigger' = 'ON_ABILITY' and pr->>'target_selector' = 'THE_TARGET' then
          if pr->>'action' = 'DEAL_DAMAGE' then
            for sc in select * from jsonb_array_elements(coalesce(pr->'conditions','[]'::jsonb)) loop
              if sc->>'field' = 'target.has_status' and sc->>'op' = '=' then
                ucond_st[n] := case sc->>'value' when 'BURNING' then 'burn' when 'POISON' then 'poison' else null end;
                ucond_d[n] := coalesce((pr->>'value')::numeric, 0);
              end if;
            end loop;
          elsif pr->>'action' = 'APPLY_STATUS' then
            uapp_st[n] := case pr->>'status' when 'BURNING' then 'burn' when 'POISON' then 'poison' else null end;
          end if;
        end if;
      end loop;
    end if;
    -- reach tiles (current tile first)
    tile_from[n] := coalesce(array_length(tx,1),0) + 1;
    tx := tx || ux[n]; ty := ty || uy[n];
    if not ustun[n] then
      r := cn_reach(st, u);
      if r is not null then
        foreach tl in array r loop
          tx := tx || split_part(tl,',',1)::int; ty := ty || split_part(tl,',',2)::int;
        end loop;
      end if;
    end if;
    tile_to[n] := array_length(tx,1);
    if uo[n] = me and uroyal[n] then king_me := king_me + 1; end if;
    if uo[n] = opp and uroyal[n] then king_opp := king_opp + 1; end if;
  end loop;

  if w_okm <> 1 then
    for i in 1..n loop
      if uo[i] = opp and uroyal[i] then uhw[i] := uhw[i] * w_okm; uout[i] := uout[i] * w_okm; end if;
    end loop;
  end if;

  -- ---- terminal ----------------------------------------------------------------------------------------------
  if n = 0 then return 0; end if;
  if exists (select 1 from jsonb_array_elements(st->'units') q where coalesce((q->>'royal')::boolean,false)) then
    if king_me = 0 then return -1000000; end if;
    if king_opp = 0 then return 1000000; end if;
  end if;
  if not exists (select 1 from unnest(uo) x where x = me) then return -1000000; end if;
  if not exists (select 1 from unnest(uo) x where x = opp) then return 1000000; end if;

  -- ---- material ----------------------------------------------------------------------------------------------
  for i in 1..n loop
    vv := uhw[i] * uhp[i] + uout[i];
    if uburn[i] then vv := vv - 0.15 * umx[i] * w_burn; end if;
    if upois[i] then vv := vv - 0.10 * umx[i] * w_pois; end if;
    if ustun[i] then vv := vv - uout[i] * 0.3; end if;
    mat := mat + case when uo[i] = me then vv else -vv end;
  end loop;

  -- ---- threats: side s attacks side (other). s=1: opp attacks me (exposure); s=2: me attacks opp (offence) ------
  for s in 1..2 loop
    thr := 0; lethal := false;
    -- value of the best act of attacker a on victim v
    hitv := array_fill(0::numeric, array[n*n]); hitd := array_fill(0::numeric, array[n*n]);
    for a in 1..n loop
      continue when uo[a] <> case when s = 1 then opp else me end;
      for v in 1..n loop
        continue when uo[v] = uo[a];
        -- any reachable tile of a that hits v?
        ok := false;
        for t in tile_from[a]..tile_to[a] loop
          d := greatest(abs(tx[t] - ux[v]), abs(ty[t] - uy[v]));
          continue when d < ulo[a] or d > uhi[a];
          if d >= 2 and not cn_b4_los(ox, oy, tx[t], ty[t], ux[v], uy[v]) then continue; end if;
          ok := true; exit;
        end loop;
        continue when not ok;
        continue when cn_immune(ujs[v], ujs[a]);
        -- a unit standing beside a tree is hit through the tree
        continue when ushield[v];
        avg := uavg[a];
        dd := avg;
        if ucond_st[a] is not null and ((ucond_st[a] = 'burn' and uburn[v]) or (ucond_st[a] = 'poison' and upois[v])) then
          dd := greatest(dd, ucond_d[a]);
        end if;
        vv := least(dd, uhp[v]) * uhw[v] + case when dd >= uhp[v] then uout[v] else 0 end;
        -- applying a status instead of hitting
        if uapp_st[a] is not null and ((uapp_st[a] = 'burn' and not uburn[v]) or (uapp_st[a] = 'poison' and not upois[v])) then
          vv := greatest(vv, case uapp_st[a] when 'burn' then 0.15 * umx[v] * w_burn else 0.10 * umx[v] * w_pois end + w_setup);
        end if;
        if uburn[a] then vv := vv - 0.15 * umx[a]; end if;
        if ustun[a] then vv := vv * 0.3; end if;
        hitv[(a-1)*n+v] := vv; hitd[(a-1)*n+v] := dd;
      end loop;
    end loop;
    -- best two acts (two different attackers); same victim = focus fire (a unit that can be hit once per turn takes one hit)
    for a in 1..n loop
      continue when uo[a] <> case when s = 1 then opp else me end;
      for v in 1..n loop
        continue when hitd[(a-1)*n+v] <= 0 and hitv[(a-1)*n+v] <= 0;
        thr := greatest(thr, hitv[(a-1)*n+v]);
        if uroyal[v] and hitd[(a-1)*n+v] >= uhp[v] then lethal := true; end if;
        if w_acts >= 2 then
          for b in a+1..n loop
            continue when uo[b] <> uo[a];
            for v2 in 1..n loop
              continue when hitd[(b-1)*n+v2] <= 0 and hitv[(b-1)*n+v2] <= 0;
              if v2 = v then
                capv := ucap[v];
                if capv = 1 then
                  tot := greatest(hitd[(a-1)*n+v], hitd[(b-1)*n+v]);
                else
                  tot := hitd[(a-1)*n+v] + hitd[(b-1)*n+v];
                end if;
                vv := least(tot, uhp[v]) * uhw[v] + case when tot >= uhp[v] then uout[v] else 0 end;
                -- a status-applying act has no hp in it: take the better of the two single acts if that is higher
                vv := greatest(vv, hitv[(a-1)*n+v], hitv[(b-1)*n+v]);
                if uroyal[v] and tot >= uhp[v] then lethal := true; end if;
              else
                vv := hitv[(a-1)*n+v] + hitv[(b-1)*n+v2];
              end if;
              thr := greatest(thr, vv);
            end loop;
          end loop;
        end if;
      end loop;
    end loop;
    if s = 1 then
      expo := thr + case when lethal then w_lethal else 0 end;
    else
      off := thr + case when lethal then w_lethal * 0.5 else 0 end;
    end if;
  end loop;

  -- ---- position / purpose terms ------------------------------------------------------------------------------
  for i in 1..n loop
    pr := ujs[i];
    near_e := 99;
    for j in 1..n loop
      continue when uo[j] = uo[i];
      near_e := least(near_e, greatest(abs(ux[i]-ux[j]), abs(uy[i]-uy[j])));
    end loop;
    vv := 0;
    if not uroyal[i] and uavg[i] > 3 then
      ideal := uhi[i];
      vv := vv - w_approach * abs(near_e - ideal) - w_near * near_e;
    end if;
    -- pursuit: damage dealers lean toward the enemy king (the win condition), so a lead gets converted
    if w_pur > 0 and not uroyal[i] and uavg[i] > 3 then
      v_dk := 99;
      for j in 1..n loop
        if uo[j] <> uo[i] and uroyal[j] then v_dk := least(v_dk, greatest(abs(ux[i]-ux[j]), abs(uy[i]-uy[j]))); end if;
      end loop;
      if v_dk < 99 then vv := vv + w_pur * greatest(0, 10 - v_dk); end if;
    end if;
    -- cover: a shield-type unit beside a living tree
    if ushield[i] then vv := vv + w_cover; end if;
    -- aura: allies standing inside a power aura
    nearp := cn_near_power(st, pr);
    if nearp > 0 then vv := vv + w_aura * nearp; end if;
    pos := pos + case when uo[i] = me then vv else -vv end;
  end loop;

  -- king danger: a terrain-blind look at whether two enemies could get to a king even if its guards fall first
  if w_kd > 0 or w_kdo > 0 then
    for i in 1..n loop
      continue when not uroyal[i];
      t1 := 0; t2 := 0;
      for a in 1..n loop
        continue when uo[a] = uo[i] or ustun[a];
        continue when greatest(abs(ux[a]-ux[i]), abs(uy[a]-uy[i])) > umv[a] + uhi[a];
        continue when cn_immune(ujs[i], ujs[a]);
        dd := greatest(uavg[a], ucond_d[a]);
        if dd > t1 then t2 := t1; t1 := dd; elsif dd > t2 then t2 := dd; end if;
      end loop;
      vv := greatest(0, t1 + t2 - uhp[i]) + 0.25 * least(t1 + t2, uhp[i]);
      kdsum := kdsum + case when uo[i] = me then -w_kd * vv else w_kdo * vv end;
    end loop;
    pos := pos + kdsum;
  end if;

  -- king damage is worse than its hp alone: a convex penalty for the lower fractions
  for i in 1..n loop
    continue when not uroyal[i];
    vv := w_kconv * power(1 - uhp[i]::numeric / umx[i], 2);
    mat := mat + case when uo[i] = me then -vv else vv end;
  end loop;

  -- the clock: a draw at the turn limit is worth nothing to the side that is ahead, and a lot to the one that is behind
  v_tf := greatest(0, least(1, (coalesce((st->>'turnNumber')::int, 1) - w_late0 * v_cap) / greatest(1, (1 - w_late0) * v_cap)));
  if v_tf > 0 then
    if mat > 0 then
      w_expo := w_expo * (1 - v_tf * w_late_a); w_off := w_off * (1 + v_tf); pos := pos * (1 + 2 * v_tf);
    else
      w_expo := w_expo * (1 + v_tf * 0.5);
    end if;
  end if;

  -- standing structures: a bomb of mine is a tile the enemy must walk round, one of theirs is the opposite;
  -- a wall of mine covers me.
  for e in select * from jsonb_array_elements(coalesce(st->'obstacles','[]'::jsonb)) loop
    continue when cn_obj_kind(e) not in ('bomb','wall');
    v_by := e->>'by'; v_own := null;
    for i in 1..n loop if uid[i] = v_by then v_own := uo[i]; end if; end loop;
    continue when v_own is null;
    v_sidebonus := v_sidebonus + case when v_own = me then 1 else -1 end *
                   case cn_obj_kind(e) when 'bomb' then w_bomb else w_wall end;
  end loop;
  pos := pos + v_sidebonus;

  res := mat + pos - w_expo * expo + w_off * off;
  return res;
end $function$
;

CREATE OR REPLACE FUNCTION public.cn_b4_place(p_state jsonb, p_side text, p_deck text[], w jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  v_units jsonb := cn_army(p_state, p_side, p_deck);
  bw int := (p_state->'board'->>'w')::int; bh int := (p_state->'board'->>'h')::int;
  n int := 0; i int; j int; k int; it int;
  u jsonb; e jsonb;
  zx int[] := '{}'; zy int[] := '{}'; zn int := 0;         -- zone tiles
  ox int[] := '{}'; oy int[] := '{}'; tx_ int[] := '{}'; ty_ int[] := '{}';  -- solid objects / trees
  -- per unit
  uroyal boolean[]; urmax int[]; urmin int[]; uhp int[]; uavg numeric[]; umov int[]; urole text[]; ushield boolean[]; unp int[]; ucap boolean[];
  ufront boolean[]; urng boolean[]; ucarry boolean[];
  px int[]; py int[]; pd int[]; occ boolean[];                -- current formation (x,y,depth per unit)
  fbx int[]; fby int[]; bs numeric := -1e18; s numeric; cx int[]; cy int[]; cs numeric;
  arch jsonb; ws jsonb; archs jsonb;
  v_out jsonb := '[]'::jsonb; ti int; tj int; pick int[];
  front_d int; tmp int; ok boolean; free int[];
  nrand int; nhill int; temp numeric;
begin
  -- the archetype: one of a handful of weight sets, chosen at random so a human cannot read the deployment off the deck
  archs := coalesce(w->'place_archetypes', '[{}]'::jsonb);
  arch := archs -> (floor(random() * jsonb_array_length(archs)))::int;
  ws := coalesce(w->'place', '{}'::jsonb) || coalesce(arch, '{}'::jsonb);

  for e in select * from jsonb_array_elements(coalesce(p_state->'obstacles','[]'::jsonb)) loop
    if cn_obj_solid(cn_obj_kind(e)) then ox := ox || (e->>'x')::int; oy := oy || (e->>'y')::int; end if;
    if cn_obj_kind(e) = 'tree' then tx_ := tx_ || (e->>'x')::int; ty_ := ty_ || (e->>'y')::int; end if;
  end loop;
  -- my zone: the half of the board on my side
  for j in 0 .. (bh / 2 - 1) loop
    for i in 0 .. bw - 1 loop
      continue when exists (select 1 from jsonb_array_elements(coalesce(p_state->'obstacles','[]'::jsonb)) q
                             where (q->>'x')::int = i and (q->>'y')::int = case when p_side = 'host' then j else bh - 1 - j end);
      zn := zn + 1; zx[zn] := i; zy[zn] := case when p_side = 'host' then j else bh - 1 - j end;
    end loop;
  end loop;
  front_d := bh / 2 - 1;

  for u in select * from jsonb_array_elements(v_units) loop
    n := n + 1;
    uroyal[n] := coalesce((u->>'royal')::boolean, false); urmax[n] := (u->>'rmax')::int; urmin[n] := (u->>'rmin')::int;
    uhp[n] := (u->>'maxHp')::int; uavg[n] := ((u->>'dmin')::int + (u->>'dmax')::int) / 2.0; umov[n] := (u->>'mov')::int;
    urole[n] := u->>'role';
    ushield[n] := exists (select 1 from jsonb_array_elements(coalesce(u->'abilityScript','[]'::jsonb)) r where r->>'stat_name' = 'TREE_SHIELD');
    unp[n] := coalesce((select max((r->>'value')::numeric)::int from jsonb_array_elements(coalesce(u->'abilityScript','[]'::jsonb)) r where r->>'stat_name' = 'NEARBY_POWER'), 0);
    ucap[n] := cn_hit_limit(u) is not null;
    urng[n] := urmax[n] >= 2 and not uroyal[n];                                  -- hits from a distance
    ufront[n] := not uroyal[n] and urmax[n] = 1 and uhp[n] >= cn_b4_w(ws,'front_hp',70);   -- takes the first blow
    ucarry[n] := not uroyal[n] and urmax[n] = 1 and not ufront[n];               -- fast, fragile damage dealers
  end loop;

  nrand := cn_b4_w(ws,'n_rand',80)::int; nhill := cn_b4_w(ws,'n_hill',200)::int;
  fbx := array_fill(0, array[n]); fby := array_fill(0, array[n]);

  -- score of the formation (px,py) -------------------------------------------------------------------------
  -- written as a loop body twice (random starts and hill-climb), via a local helper block
  for it in 1 .. (nrand + nhill) loop
    if it <= nrand then
      pick := array(select g from generate_series(1, zn) g order by random());
      for i in 1..n loop px[i] := zx[pick[i]]; py[i] := zy[pick[i]]; end loop;
    else
      px := cx; py := cy;                                     -- (cx,cy) = current best of the climb
      if random() < 0.5 then                                  -- swap two units
        i := 1 + floor(random() * n)::int; j := 1 + floor(random() * n)::int;
        tmp := px[i]; px[i] := px[j]; px[j] := tmp; tmp := py[i]; py[i] := py[j]; py[j] := tmp;
      else                                                    -- move one unit to a free tile
        i := 1 + floor(random() * n)::int; tj := 1 + floor(random() * zn)::int;
        ok := true;
        for k in 1..n loop if px[k] = zx[tj] and py[k] = zy[tj] then ok := false; end if; end loop;
        if ok then px[i] := zx[tj]; py[i] := zy[tj]; end if;
      end if;
    end if;

    s := 0;
    for i in 1..n loop
      pd[i] := case when p_side = 'host' then py[i] else bh - 1 - py[i] end;     -- 0 = back row ... front_d = front line
    end loop;
    for i in 1..n loop
      declare
        v_adj_ally int := 0; v_adj_open int := 0; v_cover int := 0; v_tree int := 0; v_cov numeric := 0;
        v_nearest int := 99; v_d int; a int; dx int; dy int; free_t boolean; v_ally2 int := 0; v_front_ahead int := 0;
      begin
        -- neighbours
        for dx in -1..1 loop
          for dy in -1..1 loop
            continue when dx = 0 and dy = 0;
            declare nx int := px[i] + dx; ny int := py[i] + dy; occupied boolean := false; isobj boolean := false;
            begin
              continue when nx < 0 or ny < 0 or nx >= bw or ny >= bh;
              for a in 1..n loop if a <> i and px[a] = nx and py[a] = ny then occupied := true; v_adj_ally := v_adj_ally + 1;
                  if ufront[a] and ((p_side = 'host' and dy > 0) or (p_side = 'guest' and dy < 0)) then v_front_ahead := v_front_ahead + 1; end if; end if; end loop;
              for a in 1..coalesce(array_length(ox,1),0) loop if ox[a] = nx and oy[a] = ny then isobj := true; end if; end loop;
              for a in 1..coalesce(array_length(tx_,1),0) loop if tx_[a] = nx and ty_[a] = ny then v_tree := v_tree + 1; end if; end loop;
              if not occupied and not isobj then v_adj_open := v_adj_open + 1; end if;
            end;
          end loop;
        end loop;
        for a in 1..n loop
          continue when a = i;
          v_d := greatest(abs(px[a]-px[i]), abs(py[a]-py[i]));
          if v_d <= 2 then v_ally2 := v_ally2 + 1; end if;
        end loop;

        for a in 1..n loop
          if a <> i and ufront[a] and abs(px[a]-px[i]) <= 1 and pd[a] = pd[i] + 1 then v_cover := 1; end if;
        end loop;
        if uroyal[i] then
          -- the king sits back, guarded: allies around him, few open flanks, a tree beside him
          s := s + cn_b4_w(ws,'king_back',14) * (front_d - pd[i]) * (case when front_d - pd[i] > 2 then 0.3 else 1 end);
          s := s + cn_b4_w(ws,'king_guard',16) * least(v_adj_ally, 3);
          s := s - cn_b4_w(ws,'king_open',9) * v_adj_open;
          s := s + cn_b4_w(ws,'king_tree',10) * least(v_tree, 2);
          s := s + cn_b4_w(ws,'king_front_cover',22) * least(v_front_ahead, 1);
        elsif ufront[i] then
          -- tanks take the front line, spread across the lanes
          s := s + cn_b4_w(ws,'front_depth',26) * (case when pd[i] = front_d then 1 else -0.7 * (front_d - pd[i]) end);
          s := s + cn_b4_w(ws,'front_tree',6) * least(v_tree,1);
          for a in 1..n loop
            continue when a = i or not ufront[a];
            v_d := abs(px[a] - px[i]);
            s := s + cn_b4_w(ws,'front_spread',5) * least(v_d, 3) / 2.0;     -- (counted twice per pair) lanes covered
          end loop;
        elsif urng[i] then
          -- ranged: one row behind the line, with a body in front of it, reach over the approach row
          s := s + cn_b4_w(ws,'rng_depth',16) * (case when pd[i] = front_d - 1 then 1 when pd[i] = front_d then 0.2 else -0.5 * abs(front_d - 1 - pd[i]) end);
          s := s + cn_b4_w(ws,'rng_cover',18) * v_cover;
          s := s + cn_b4_w(ws,'rng_reach',3) * least(urmax[i], 4);
          s := s + cn_b4_w(ws,'rng_tree',4) * least(v_tree, 1);
        else
          -- fast carries: flanks, close to the line, ready to dive
          s := s + cn_b4_w(ws,'carry_depth',12) * (case when pd[i] >= front_d - 1 then 1 else -0.5 end);
          s := s + cn_b4_w(ws,'carry_flank',9) * (case when px[i] <= 1 or px[i] >= bw - 2 then 1 else 0 end);
        end if;
        -- purpose from the unit's own script
        if ushield[i] then
          s := s + cn_b4_w(ws,'shield_tree',34) * least(v_tree, 1) + cn_b4_w(ws,'shield_depth',8) * (case when pd[i] >= front_d - 1 then 1 else 0 end);
        end if;
        if unp[i] > 0 then
          -- an aura unit stands where it touches the most damage dealers while staying behind them
          for a in 1..n loop
            continue when a = i;
            if greatest(abs(px[a]-px[i]), abs(py[a]-py[i])) = 1 and uavg[a] >= 10 then
              s := s + cn_b4_w(ws,'aura_adj',9) * unp[i] / 5.0;
            end if;
          end loop;
          s := s + cn_b4_w(ws,'aura_back',7) * (case when pd[i] <= front_d - 1 then 1 else 0 end);
        end if;
        if ucap[i] then
          s := s + cn_b4_w(ws,'cap_front',10) * (case when pd[i] = front_d then 1 else 0 end);  -- can only be hit once a turn: a spearhead
        end if;
        -- nobody alone
        s := s + cn_b4_w(ws,'cohesion',6) * least(v_ally2, 2) - cn_b4_w(ws,'isolated',14) * (case when v_ally2 = 0 then 1 else 0 end);
      end;
    end loop;
    s := s + random() * cn_b4_w(ws,'jitter',10);

    if it <= nrand then
      if s > bs then bs := s; fbx := px; fby := py; end if;
      if it = nrand then cx := fbx; cy := fby; cs := bs; end if;
    else
      if s > cs then cs := s; cx := px; cy := py; if s > bs then bs := s; fbx := px; fby := py; end if; end if;
    end if;
  end loop;

  i := 0;
  for u in select * from jsonb_array_elements(v_units) loop
    i := i + 1;
    v_out := v_out || jsonb_set(jsonb_set(u, '{x}', to_jsonb(fbx[i])), '{y}', to_jsonb(fby[i]));
  end loop;
  return v_out;
end $function$
;

CREATE OR REPLACE FUNCTION public.bot4_step(p_match uuid, p_side text DEFAULT 'guest'::text)
 RETURNS matches
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  m public.matches; st jsonb; v_lvl int; v_noise numeric; v_w jsonb; v_brain_id uuid;
  v_noise_scale numeric; v_opp text;
  u jsonb; t jsonb;
  v_tiles text[]; v_tile text; vx int; vy int; v_first boolean;
  v_best numeric := 0; v_bu text; v_bx int; v_by int; v_bt text;
  v_fb numeric := -1e9; v_fu text; v_fbx int; v_fby int; v_ft text;
  v_pos numeric; v_base numeric; v_act numeric; v_step_s numeric;
  v_d int; v_dmg numeric; v_ctr numeric; v_near int; v_thr int; v_ally_near int;
  v_answers boolean; v_parry boolean;
  v_ab_kind text; v_ab_ready boolean; v_ab_max_uses int; v_ab_cooldown int;
  v_ab_used int; v_ab_last_used int; v_ab_turn_no int; v_ab_n int;
  v_ab_score numeric; v_ab_needs_target boolean; v_ab_needs_tile boolean;
  v_ab_tiles text[]; v_ab_tile text; v_dx int; v_dy int; t2 jsonb;
  v_bkind text; v_fkind text; v_strat numeric;
  v_trap_dmg int;
  v_cs numeric[] := '{}'; v_cu text[] := '{}'; v_cx int[] := '{}'; v_cy int[] := '{}'; v_ct text[] := '{}'; v_ck text[] := '{}';
  v_lvl4 int; v_i int; v_n int; v_short int[]; v_idx int; v_val numeric; v_bestval numeric := -1e18; v_bi int;
  v_ok boolean; m2 public.matches; v_w2 jsonb; v_cap int; v_left int; v_pass numeric; v_sc numeric;
  v_k_all int; v_k_ab int; v_k_mv int; v_k_atk int; v_dbg boolean; v_mix numeric; v_nz numeric; v_expo_mid numeric;
  v_seen text[] := '{}'; v_key text; v_sw record; v_base_eval numeric;
  v_qj jsonb; v_ja jsonb; v_jb jsonb; v_tiles2 text[]; v_t2 text; v_cx2 int; v_cy2 int; v_ns int; v_nsw int; v_swn int;
  v_sw_best numeric := -1e18; v_sw_u text; v_sw_x int; v_sw_y int; v_sw_t text; v_ux int; v_uy int; v_after_left int; v_cur_active text;
  v_rmin2 int; v_rmax2 int; v_rany boolean; v_t0 timestamptz := clock_timestamp(); v_budget numeric;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null then return m; end if;
  v_opp := case when p_side = 'host' then 'guest' else 'host' end;
  v_lvl := case when p_side = 'guest' then m.bot else m.host_bot end;
  if v_lvl is null then return m; end if;
  if m.status <> 'active' then return m; end if;

  -- See this migration's header. A throw decision can be open for this
  -- side while state.turn still names the other one, so it has to be
  -- handled before the turn check just below, not after it.
  declare
    v_throw_p jsonb; v_throw_u jsonb; v_cx int; v_cy int;
    v_cand_x int; v_cand_y int; v_cand_best int; v_best_ally_d int;
    v_cand_trap int; v_cand_ally_d int; v_tvx int; v_tvy int; v_td int;
  begin
    v_throw_p := cn_pending(m.state);
    if v_throw_p is not null and v_throw_p->>'kind' = 'throw'
       and v_throw_p->>'side' = p_side then
      v_throw_u := null;
      for u in select * from jsonb_array_elements(m.state->'units') loop
        if u->>'id' = v_throw_p->>'unit' then v_throw_u := u; end if;
      end loop;

      v_cand_x := null; v_cand_y := null; v_cand_best := -1; v_best_ally_d := 99;
      if v_throw_u is not null then
        v_cx := (v_throw_u->>'x')::int;
        v_cy := (v_throw_u->>'y')::int;
        for v_tvx in v_cx - cn_throw_reach() .. v_cx + cn_throw_reach() loop
          for v_tvy in v_cy - cn_throw_reach() .. v_cy + cn_throw_reach() loop
            continue when v_tvx < 0 or v_tvy < 0
                      or v_tvx >= (m.state->'board'->>'w')::int
                      or v_tvy >= (m.state->'board'->>'h')::int;
            v_td := greatest(abs(v_tvx - v_cx), abs(v_tvy - v_cy));
            continue when v_td < 1 or v_td > cn_throw_reach();
            continue when exists (
              select 1 from jsonb_array_elements(m.state->'units') q
              where (q->>'x')::int = v_tvx and (q->>'y')::int = v_tvy
            );
            continue when exists (
              select 1 from jsonb_array_elements(coalesce(m.state->'obstacles', '[]'::jsonb)) e
              where (e->>'x')::int = v_tvx and (e->>'y')::int = v_tvy
                and cn_obj_solid(cn_obj_kind(e))
            );
            v_cand_trap := cn_bot_trap_threat(m.state, v_tvx, v_tvy);
            v_cand_ally_d := 99;
            for t in select * from jsonb_array_elements(m.state->'units') loop
              continue when t->>'owner' <> p_side;
              v_cand_ally_d := least(v_cand_ally_d, cn_cheb(v_tvx, v_tvy, (t->>'x')::int, (t->>'y')::int));
            end loop;
            if v_cand_trap > v_cand_best
               or (v_cand_trap = v_cand_best and v_cand_ally_d < v_best_ally_d) then
              v_cand_best := v_cand_trap;
              v_best_ally_d := v_cand_ally_d;
              v_cand_x := v_tvx; v_cand_y := v_tvy;
            end if;
          end loop;
        end loop;
      end if;

      if v_cand_x is not null then
        return cn_throw(p_match, p_side, '@' || v_cand_x || ',' || v_cand_y);
      else
        return cn_throw(p_match, p_side, null);
      end if;
    end if;
  end;

  if m.state->>'turn' <> p_side then return m; end if;

  st := m.state;

  v_brain_id := case when p_side = 'guest' then m.guest_brain_id else m.host_brain_id end;
  if v_brain_id is not null then
    select weights into v_w from public.bot_brains where id = v_brain_id;
  end if;
  if v_w is null then
    select weights into v_w from public.bot_brains where level = v_lvl and is_live limit 1;
  end if;
  v_w := coalesce(v_w, '{}'::jsonb);
  v_lvl4 := v_lvl; v_lvl := 3;
  v_noise_scale := coalesce((v_w->>'noise_scale')::numeric,
    case v_lvl when 1 then 220 when 2 then 90 else 15 end);

  for u in select * from jsonb_array_elements(st->'units') loop
    continue when u->>'owner' <> p_side;
    continue when (u->>'moved')::boolean and (u->>'acted')::boolean;
    continue when coalesce((u->>'spent')::boolean, false);
    continue when coalesce((u->>'attackOnly')::boolean, false);
    continue when coalesce((st->>'acts')::int, 0) >= cn_acts_cap(st)
              and nullif(st->>'active', '') is distinct from u->>'id';

    v_tiles := array[(u->>'x') || ',' || (u->>'y')];
    if not (u->>'moved')::boolean and (not cn_stunned(u) or not cn_stun_blocks('move')) then
      v_tiles := v_tiles || cn_reach(st, u);
    end if;
    v_first := true;

    foreach v_tile in array v_tiles loop
      vx := split_part(v_tile, ',', 1)::int;
      vy := split_part(v_tile, ',', 2)::int;

      v_near := 99; v_thr := 0;
      for t in select * from jsonb_array_elements(st->'units') loop
        continue when t->>'owner' = p_side;
        v_d := cn_cheb(vx, vy, (t->>'x')::int, (t->>'y')::int);
        v_near := least(v_near, v_d);
        if v_d <= (t->>'mov')::int + (t->>'rmax')::int then v_thr := v_thr + 1; end if;
      end loop;
      v_pos := - abs(v_near - (u->>'rmax')::int) * coalesce((v_w->>'pos_dist_mult')::numeric, 5.0)
               - v_near * coalesce((v_w->>'pos_near_mult')::numeric, 2.0);

      if v_lvl = 3 then
        v_ally_near := 99;
        for t2 in select * from jsonb_array_elements(st->'units') loop
          continue when t2->>'owner' <> p_side or t2->>'id' = u->>'id' or (t2->>'hp')::int <= 0;
          v_d := cn_cheb(vx, vy, (t2->>'x')::int, (t2->>'y')::int);
          if v_d < v_ally_near then v_ally_near := v_d; end if;
        end loop;
        v_pos := v_pos - greatest(0, coalesce((v_w->>'ally_spacing_ideal')::numeric, 2) - v_ally_near)
                          * coalesce((v_w->>'ally_spacing_mult')::numeric, 6.0);
      end if;

      if vx <> (u->>'x')::int or vy <> (u->>'y')::int then
        v_trap_dmg := cn_bot_trap_threat(st, vx, vy);
        if v_trap_dmg > 0 then
          v_pos := v_pos - v_trap_dmg * coalesce((v_w->>'trap_dmg_mult')::numeric, 12.0);
          if v_trap_dmg >= (u->>'hp')::int then
            v_pos := v_pos - coalesce((v_w->>'lethal_trap_penalty_flat')::numeric, 500) - (u->>'maxHp')::int;
          end if;
        end if;
      end if;

      if v_first then v_base := v_pos; v_first := false; end if;

      if vx <> (u->>'x')::int or vy <> (u->>'y')::int then
        v_noise := random() * v_noise_scale;
        v_strat := case when v_lvl = 3 then cn_bot_strategy_bonus(st, p_side, u, 'move', vx, vy, null) else 0 end;
        v_step_s := v_pos - v_base + v_noise + v_strat
          - v_thr * coalesce((v_w->>'threat_mult')::numeric, case when v_lvl >= 3 then 4.0 else 0 end);
        v_cs := array_append(v_cs, (v_step_s)::numeric); v_cu := array_append(v_cu, (u->>'id')::text); v_cx := array_append(v_cx, (vx)::int); v_cy := array_append(v_cy, (vy)::int); v_ct := array_append(v_ct, (null)::text); v_ck := array_append(v_ck, coalesce((null)::text,'move'));
        if v_step_s > v_fb then
          v_fb := v_step_s;
          v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := null; v_fkind := null;
        end if;
      end if;

      continue when (u->>'acted')::boolean;

      if not cn_stunned(u) or not cn_stun_blocks('attack') then
      for t in select * from jsonb_array_elements(st->'units') loop
        continue when t->>'id' = u->>'id';
        v_d := cn_cheb(vx, vy, (t->>'x')::int, (t->>'y')::int);
        continue when v_d < (u->>'rmin')::int or v_d > (u->>'rmax')::int;
        continue when not cn_los_clear(st, vx, vy, (t->>'x')::int, (t->>'y')::int);

        v_dmg := ((u->>'dmin')::int + (u->>'dmax')::int) / 2.0 + cn_near_power_at(st, u, vx, vy);
        continue when t->>'owner' <> p_side and cn_immune(t, u);
        continue when cn_hit_capped(st, t);

        if t->>'owner' = p_side then
          continue when not (u->>'heals')::boolean;
          v_act := case when (t->>'maxHp')::int - (t->>'hp')::int <= 0
                        then coalesce((v_w->>'heal_full_penalty')::numeric, -150)
                        else least(v_dmg, (t->>'maxHp')::int - (t->>'hp')::int)
                             * coalesce((v_w->>'heal_mult')::numeric, 9.0) end;
        else
          v_answers := not coalesce((u->>'sneaks')::boolean, false)
                       and v_d >= (t->>'crmin')::int and v_d <= (t->>'crmax')::int;
          v_parry := v_answers and coalesce((t->>'parries')::boolean, false);

          v_act := least(v_dmg, (t->>'hp')::int) * coalesce((v_w->>'atk_mult')::numeric, 10.0);
          if v_dmg >= (t->>'hp')::int then
            v_act := v_act + coalesce((v_w->>'kill_bonus_flat')::numeric, 400) + (t->>'maxHp')::int;
          elsif (u->>'burns')::boolean and not (t->>'burned')::boolean then
            v_act := v_act + coalesce((v_w->>'burn_bonus')::numeric, 25);
          end if;

          if v_answers and (v_parry or v_dmg < (t->>'hp')::int) then
            v_ctr := case when cn_immune(u, t) then 0 else ((t->>'dmin')::int + (t->>'dmax')::int) / 2.0 + cn_near_power(st, t) end;
            v_act := v_act - v_ctr * coalesce((v_w->>'ctr_mult')::numeric,
                       case v_lvl when 1 then 3.0 else 8.0 end);
            if v_ctr >= (u->>'hp')::int then
              v_act := v_act - coalesce((v_w->>'lethal_ctr_penalty_flat')::numeric, 500) - (u->>'maxHp')::int
                       - case when v_parry
                              then coalesce((v_w->>'lethal_parry_extra_flat')::numeric, 400) + (t->>'maxHp')::int
                              else 0 end;
            end if;
          end if;
        end if;

        if cn_has(u, 'burn') then
          v_act := v_act - cn_effect_dmg(st, u, cn_burn_pct()) * coalesce((v_w->>'atk_mult')::numeric, 10.0);
          if cn_effect_dmg(st, u, cn_burn_pct()) >= (u->>'hp')::int then
            v_act := v_act - coalesce((v_w->>'lethal_ctr_penalty_flat')::numeric, 500) - (u->>'maxHp')::int;
          end if;
        end if;
        v_noise := random() * v_noise_scale;
        v_strat := case when v_lvl = 3 then cn_bot_strategy_bonus(st, p_side, u, 'attack', vx, vy, t->>'id') else 0 end;
        v_cs := array_append(v_cs, (v_pos + v_act - v_base + v_noise + v_strat)::numeric); v_cu := array_append(v_cu, (u->>'id')::text); v_cx := array_append(v_cx, (vx)::int); v_cy := array_append(v_cy, (vy)::int); v_ct := array_append(v_ct, (t->>'id')::text); v_ck := array_append(v_ck, coalesce(('attack')::text,'move'));
        if v_pos + v_act - v_base + v_noise + v_strat > v_fb then
          v_fb := v_pos + v_act - v_base + v_noise + v_strat;
          v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := t->>'id'; v_fkind := 'attack';
        end if;
      end loop;
      end if;

      if vx = (u->>'x')::int and vy = (u->>'y')::int
         and not (u->>'acted')::boolean
         and u->>'abilityKind' is not null
         and (not cn_stunned(u) or not cn_stun_blocks('ability')) and not cn_swamped(st, u)
      then
        v_ab_turn_no := coalesce((st->>'turnNumber')::int, 1);
        v_ab_max_uses := nullif(u->>'abilityMaxUses', '')::int;
        v_ab_cooldown := coalesce(nullif(u->>'abilityCooldownTurns', '')::int, 0);
        v_ab_used := coalesce((u->>'abilityUses')::int, 0);
        v_ab_last_used := nullif(u->>'abilityLastUsedTurn', '')::int;
        v_ab_ready := (v_ab_max_uses is null or v_ab_used < v_ab_max_uses)
          and (v_ab_cooldown <= 0 or v_ab_last_used is null
               or v_ab_turn_no - v_ab_last_used > v_ab_cooldown);

        if v_ab_ready then
          v_ab_kind := u->>'abilityKind';
          v_ab_n := coalesce((u->>'abilityN')::int, 0);

          if v_ab_kind = 'scripted' then
            v_ab_needs_target := exists (
              select 1 from jsonb_array_elements(coalesce(u->'abilityScript', '[]'::jsonb)) r
               where r->>'trigger' = 'ON_ABILITY' and r->>'target_selector' = 'THE_TARGET');
            v_ab_needs_tile := exists (
              select 1 from jsonb_array_elements(coalesce(u->'abilityScript', '[]'::jsonb)) r
               where r->>'trigger' = 'ON_ABILITY' and r->>'target_selector' = 'BOARD_CELL');

            v_ab_score := cn_bot_score_ability(st, p_side, u, null, v_w);
            -- 0212: an ability that nets out harmful (burning or poisoning its own
            -- unit, say) is never played, not even as the fallback when nothing
            -- else scores.
            if v_ab_score is not null and v_ab_score >= 0 then
              v_strat := case when v_lvl = 3 then cn_bot_strategy_bonus(st, p_side, u, 'ability', vx, vy, null) else 0 end;
              v_step_s := v_pos + v_ab_score - v_base + random() * v_noise_scale + v_strat;
              v_cs := array_append(v_cs, (v_step_s)::numeric); v_cu := array_append(v_cu, (u->>'id')::text); v_cx := array_append(v_cx, (vx)::int); v_cy := array_append(v_cy, (vy)::int); v_ct := array_append(v_ct, (null)::text); v_ck := array_append(v_ck, coalesce(('ability')::text,'move'));
              if v_step_s > v_fb then
                v_fb := v_step_s;
                v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := null; v_fkind := 'ability';
              end if;
            end if;

            if v_ab_needs_target then
              for t2 in select * from jsonb_array_elements(st->'units') loop
                continue when (t2->>'hp')::int <= 0;
                v_ab_score := cn_bot_score_ability(st, p_side, u, t2->>'id', v_w);
                -- 0212: same rule for a targeted ability -- Fey does not burn her own Caela.
                if v_ab_score is not null and v_ab_score >= 0 then
                  v_strat := case when v_lvl = 3 then cn_bot_strategy_bonus(st, p_side, u, 'ability', vx, vy, t2->>'id') else 0 end;
                  v_step_s := v_pos + v_ab_score - v_base + random() * v_noise_scale + v_strat;
                  v_cs := array_append(v_cs, (v_step_s)::numeric); v_cu := array_append(v_cu, (u->>'id')::text); v_cx := array_append(v_cx, (vx)::int); v_cy := array_append(v_cy, (vy)::int); v_ct := array_append(v_ct, (t2->>'id')::text); v_ck := array_append(v_ck, coalesce(('ability')::text,'move'));
                  if v_step_s > v_fb then
                    v_fb := v_step_s;
                    v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := t2->>'id'; v_fkind := 'ability';
                  end if;
                end if;
              end loop;
            end if;

            if v_ab_needs_tile then
              v_ab_tiles := cn_bot_ability_tiles(st, u);
              foreach v_ab_tile in array v_ab_tiles loop
                v_ab_score := cn_bot_score_ability(st, p_side, u, v_ab_tile, v_w);
                if v_ab_score is not null then
                  v_strat := case when v_lvl = 3 then cn_bot_strategy_bonus(st, p_side, u, 'ability', vx, vy, v_ab_tile)
                                 when v_lvl = 2 and u->>'slug' = 'mako' then 0.6 * cn_bot_bomb_tile_bonus(st, p_side, u, v_ab_tile)
                                 else 0 end;
                  v_step_s := v_pos + v_ab_score - v_base + random() * v_noise_scale + v_strat;
                  v_cs := array_append(v_cs, (v_step_s)::numeric); v_cu := array_append(v_cu, (u->>'id')::text); v_cx := array_append(v_cx, (vx)::int); v_cy := array_append(v_cy, (vy)::int); v_ct := array_append(v_ct, (v_ab_tile)::text); v_ck := array_append(v_ck, coalesce(('ability')::text,'move'));
                  if v_step_s > v_fb then
                    v_fb := v_step_s;
                    v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := v_ab_tile; v_fkind := 'ability';
                  end if;
                end if;
              end loop;
            end if;

          elsif v_ab_kind = 'aoe_adjacent' then
            v_ab_score := 0;
            for t2 in select * from jsonb_array_elements(st->'units') loop
              continue when t2->>'id' = u->>'id';
              continue when cn_cheb((u->>'x')::int, (u->>'y')::int, (t2->>'x')::int, (t2->>'y')::int) <> 1;
              if t2->>'owner' <> p_side then
                v_ab_score := v_ab_score + least(v_ab_n, (t2->>'hp')::int) * coalesce((v_w->>'atk_mult')::numeric, 10.0);
                if v_ab_n >= (t2->>'hp')::int then
                  v_ab_score := v_ab_score + coalesce((v_w->>'kill_bonus_flat')::numeric, 400) + (t2->>'maxHp')::int;
                end if;
              else
                v_ab_score := v_ab_score - least(v_ab_n, (t2->>'hp')::int) * coalesce((v_w->>'atk_mult')::numeric, 10.0);
                if v_ab_n >= (t2->>'hp')::int then
                  v_ab_score := v_ab_score - coalesce((v_w->>'kill_bonus_flat')::numeric, 400) - (t2->>'maxHp')::int;
                end if;
              end if;
            end loop;
            if v_ab_score <> 0 then
              v_step_s := v_pos + v_ab_score - v_base + random() * v_noise_scale;
              v_cs := array_append(v_cs, (v_step_s)::numeric); v_cu := array_append(v_cu, (u->>'id')::text); v_cx := array_append(v_cx, (vx)::int); v_cy := array_append(v_cy, (vy)::int); v_ct := array_append(v_ct, (null)::text); v_ck := array_append(v_ck, coalesce(('ability')::text,'move'));
              if v_step_s > v_fb then
                v_fb := v_step_s;
                v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := null; v_fkind := 'ability';
              end if;
            end if;

          elsif v_ab_kind = 'heal_any' then
            for t2 in select * from jsonb_array_elements(st->'units') loop
              continue when t2->>'owner' <> p_side;
              continue when (t2->>'hp')::int >= (t2->>'maxHp')::int;
              v_d := cn_cheb((u->>'x')::int, (u->>'y')::int, (t2->>'x')::int, (t2->>'y')::int);
              continue when v_d > (u->>'rmax')::int;
              continue when not cn_los_clear(st, (u->>'x')::int, (u->>'y')::int, (t2->>'x')::int, (t2->>'y')::int);
              v_ab_score := least(v_ab_n, (t2->>'maxHp')::int - (t2->>'hp')::int) * coalesce((v_w->>'heal_mult')::numeric, 9.0);
              v_step_s := v_pos + v_ab_score - v_base + random() * v_noise_scale;
              v_cs := array_append(v_cs, (v_step_s)::numeric); v_cu := array_append(v_cu, (u->>'id')::text); v_cx := array_append(v_cx, (vx)::int); v_cy := array_append(v_cy, (vy)::int); v_ct := array_append(v_ct, (t2->>'id')::text); v_ck := array_append(v_ck, coalesce(('ability')::text,'move'));
              if v_step_s > v_fb then
                v_fb := v_step_s;
                v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := t2->>'id'; v_fkind := 'ability';
              end if;
            end loop;

          elsif v_ab_kind = 'poison_hit' then
            for t2 in select * from jsonb_array_elements(st->'units') loop
              continue when t2->>'owner' = p_side;
              v_d := cn_cheb((u->>'x')::int, (u->>'y')::int, (t2->>'x')::int, (t2->>'y')::int);
              continue when v_d > (u->>'rmax')::int;
              continue when not cn_los_clear(st, (u->>'x')::int, (u->>'y')::int, (t2->>'x')::int, (t2->>'y')::int);
              v_ab_score := least(v_ab_n, (t2->>'hp')::int) * coalesce((v_w->>'atk_mult')::numeric, 10.0);
              if v_ab_n >= (t2->>'hp')::int then
                v_ab_score := v_ab_score + coalesce((v_w->>'kill_bonus_flat')::numeric, 400) + (t2->>'maxHp')::int;
              elsif not cn_has(t2, 'poison') then
                v_ab_score := v_ab_score + coalesce((v_w->>'poison_bonus')::numeric, 25);
              end if;
              v_step_s := v_pos + v_ab_score - v_base + random() * v_noise_scale;
              v_cs := array_append(v_cs, (v_step_s)::numeric); v_cu := array_append(v_cu, (u->>'id')::text); v_cx := array_append(v_cx, (vx)::int); v_cy := array_append(v_cy, (vy)::int); v_ct := array_append(v_ct, (t2->>'id')::text); v_ck := array_append(v_ck, coalesce(('ability')::text,'move'));
              if v_step_s > v_fb then
                v_fb := v_step_s;
                v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := t2->>'id'; v_fkind := 'ability';
              end if;
            end loop;

          elsif v_ab_kind = 'line_burn' then
            for t2 in select * from jsonb_array_elements(st->'units') loop
              continue when t2->>'owner' = p_side;
              v_d := cn_cheb((u->>'x')::int, (u->>'y')::int, (t2->>'x')::int, (t2->>'y')::int);
              continue when v_d > (u->>'rmax')::int;
              v_dx := sign((t2->>'x')::int - (u->>'x')::int);
              v_dy := sign((t2->>'y')::int - (u->>'y')::int);
              v_ab_score := least(v_ab_n, (t2->>'hp')::int) * coalesce((v_w->>'atk_mult')::numeric, 10.0);
              if v_ab_n >= (t2->>'hp')::int then
                v_ab_score := v_ab_score + coalesce((v_w->>'kill_bonus_flat')::numeric, 400) + (t2->>'maxHp')::int;
              elsif not cn_has(t2, 'burn') then
                v_ab_score := v_ab_score + coalesce((v_w->>'burn_bonus')::numeric, 25);
              end if;
              for t in select * from jsonb_array_elements(st->'units') loop
                continue when (t->>'x')::int <> (t2->>'x')::int + v_dx or (t->>'y')::int <> (t2->>'y')::int + v_dy;
                if t->>'owner' <> p_side then
                  v_ab_score := v_ab_score + least(v_ab_n, (t->>'hp')::int) * coalesce((v_w->>'atk_mult')::numeric, 10.0);
                  if v_ab_n >= (t->>'hp')::int then
                    v_ab_score := v_ab_score + coalesce((v_w->>'kill_bonus_flat')::numeric, 400) + (t->>'maxHp')::int;
                  end if;
                else
                  v_ab_score := v_ab_score - least(v_ab_n, (t->>'hp')::int) * coalesce((v_w->>'atk_mult')::numeric, 10.0);
                end if;
              end loop;
              v_step_s := v_pos + v_ab_score - v_base + random() * v_noise_scale;
              v_cs := array_append(v_cs, (v_step_s)::numeric); v_cu := array_append(v_cu, (u->>'id')::text); v_cx := array_append(v_cx, (vx)::int); v_cy := array_append(v_cy, (vy)::int); v_ct := array_append(v_ct, (t2->>'id')::text); v_ck := array_append(v_ck, coalesce(('ability')::text,'move'));
              if v_step_s > v_fb then
                v_fb := v_step_s;
                v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := t2->>'id'; v_fkind := 'ability';
              end if;
            end loop;

          elsif v_ab_kind = 'mist' then
            v_ab_score := 0;
            for t2 in select * from jsonb_array_elements(st->'units') loop
              if t2->>'owner' = p_side and t2->>'role' = 'rogue' then
                v_ab_score := v_ab_score + coalesce((v_w->>'mist_bonus_per_rogue')::numeric, 15) * v_ab_n / 20.0;
              end if;
            end loop;
            if v_ab_score > 0 then
              v_step_s := v_pos + v_ab_score - v_base + random() * v_noise_scale;
              v_cs := array_append(v_cs, (v_step_s)::numeric); v_cu := array_append(v_cu, (u->>'id')::text); v_cx := array_append(v_cx, (vx)::int); v_cy := array_append(v_cy, (vy)::int); v_ct := array_append(v_ct, (null)::text); v_ck := array_append(v_ck, coalesce(('ability')::text,'move'));
              if v_step_s > v_fb then
                v_fb := v_step_s;
                v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := null; v_fkind := 'ability';
              end if;
            end if;

          elsif v_ab_kind = 'summon' then
            if v_near <= (u->>'rmax')::int + 2 then
              v_ab_tiles := cn_bot_ability_tiles(st, u);
              foreach v_ab_tile in array v_ab_tiles loop
                v_ab_score := coalesce((v_w->>'ability_structure_flat')::numeric, 40);
                v_step_s := v_pos + v_ab_score - v_base + random() * v_noise_scale;
                v_cs := array_append(v_cs, (v_step_s)::numeric); v_cu := array_append(v_cu, (u->>'id')::text); v_cx := array_append(v_cx, (vx)::int); v_cy := array_append(v_cy, (vy)::int); v_ct := array_append(v_ct, (v_ab_tile)::text); v_ck := array_append(v_ck, coalesce(('ability')::text,'move'));
                if v_step_s > v_fb then
                  v_fb := v_step_s;
                  v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := v_ab_tile; v_fkind := 'ability';
                end if;
              end loop;
            end if;
          end if;
        end if;
      end if;
    end loop;
  end loop;

  -- ===== LEVEL 4: look one reply ahead ====================================================================
  v_k_all := cn_b4_w(v_w,'k_all',10)::int; v_k_ab := cn_b4_w(v_w,'k_ab',4)::int;
  v_k_mv := cn_b4_w(v_w,'k_mv',6)::int; v_k_atk := cn_b4_w(v_w,'k_atk',8)::int;
  v_mix := cn_b4_w(v_w,'static_mix',0.05); v_nz := cn_b4_w(v_w,'b4_noise',3);
  v_expo_mid := cn_b4_w(v_w,'expo_mid',0.6); v_swn := cn_b4_w(v_w,'swap_evals',60)::int;
  v_dbg := coalesce((v_w->>'debug')::boolean, false); v_budget := cn_b4_w(v_w,'budget_ms',1800);
  v_cap := cn_acts_cap(st);
  v_cur_active := nullif(st->>'active','');
  v_n := coalesce(array_length(v_cs,1),0);

  -- the position as it stands, used as the "end the turn here" option
  v_pass := cn_b4_eval(st, p_side, v_w) - cn_b4_w(v_w,'pass_pen',8);
  v_bestval := v_pass; v_bi := 0;  -- 0 = pass

  if v_n > 0 then
    select array_agg(idx order by v_cs[idx] desc) into v_short from (select distinct idx from (
      (select i as idx from unnest(v_cs) with ordinality t(s,i) order by s desc limit v_k_all)
      union
      (select i from unnest(v_cs, v_ck) with ordinality t(s,k,i) where k = 'ability' order by s desc limit v_k_ab)
      union
      (select i from unnest(v_cs, v_ck) with ordinality t(s,k,i) where k = 'move' order by s desc limit v_k_mv)
      union
      (select i from unnest(v_cs, v_ck) with ordinality t(s,k,i) where k = 'attack' order by s desc limit v_k_atk)
      union
      (select distinct on (u2) i from unnest(v_cs, v_cu) with ordinality t(s,u2,i) order by u2, s desc)
    ) z0) z;

    foreach v_idx in array v_short loop
      exit when extract(milliseconds from clock_timestamp() - v_t0) > v_budget;
      v_val := null;
      v_after_left := v_cap - coalesce((st->>'acts')::int, 0) - case when v_cur_active is not distinct from v_cu[v_idx] then 0 else 1 end;
      v_w2 := case when v_after_left > 0
                   then v_w || jsonb_build_object('expo', cn_b4_w(v_w,'expo',0.85) * v_expo_mid) else v_w end;
      v_ux := null; v_uy := null;
      select (q->>'x')::int, (q->>'y')::int into v_ux, v_uy
        from jsonb_array_elements(st->'units') q where q->>'id' = v_cu[v_idx];
      begin
        m2 := null;
        if v_cx[v_idx] <> v_ux or v_cy[v_idx] <> v_uy then
          m2 := cn_move(p_match, p_side, v_cu[v_idx], v_cx[v_idx], v_cy[v_idx]);
        end if;
        if v_ck[v_idx] = 'attack' then
          m2 := cn_attack(p_match, p_side, v_cu[v_idx], v_ct[v_idx]);
        elsif v_ck[v_idx] = 'ability' then
          m2 := cn_ability(p_match, p_side, v_cu[v_idx], v_ct[v_idx]);
        end if;
        if m2.id is null then
          v_val := null;
        elsif m2.status <> 'active' then
          v_val := case when m2.winner = p_side then 10000000 else -10000000 end;
        else
          v_val := cn_b4_eval(m2.state, p_side, v_w2);
        end if;
        raise exception 'b4 rollout' using errcode = 'P0B4X';
      exception when others then
        if sqlstate <> 'P0B4X' then v_val := null; end if;
      end;
      continue when v_val is null;
      v_sc := v_val + v_mix * v_cs[v_idx] + random() * v_nz;
      if v_dbg then raise notice 'b4 cand % %->(%,%) % % static=% eval=% final=%', v_cu[v_idx], v_ux||','||v_uy, v_cx[v_idx], v_cy[v_idx], v_ck[v_idx], v_ct[v_idx], round(v_cs[v_idx],1), round(v_val,1), round(v_sc,1); end if;
      if v_sc > v_bestval then v_bestval := v_sc; v_bi := v_idx; end if;
    end loop;
  end if;

  -- pair swaps (Caela-type abilities: two chosen units trade places) are scored on an edited copy of the board
  v_nsw := 0; v_sw_u := null;
  for v_qj in select * from jsonb_array_elements(st->'units') loop
    exit when v_nsw >= v_swn or extract(milliseconds from clock_timestamp() - v_t0) > v_budget * 1.3;
    continue when v_qj->>'owner' <> p_side or (v_qj->>'hp')::int <= 0 or (v_qj->>'acted')::boolean;
    continue when coalesce((v_qj->>'spent')::boolean,false) or coalesce((v_qj->>'attackOnly')::boolean,false);
    continue when v_qj->>'abilityKind' is distinct from 'scripted';
    continue when not exists (select 1 from jsonb_array_elements(coalesce(v_qj->'abilityScript','[]'::jsonb)) r
                               where r->>'trigger' = 'ON_ABILITY' and r->>'target_selector' = 'TWO_CHOSEN_UNITS');
    continue when cn_stunned(v_qj) and cn_stun_blocks('ability');
    continue when cn_swamped(st, v_qj);
    continue when coalesce((st->>'acts')::int, 0) >= v_cap and v_cur_active is distinct from v_qj->>'id';
    v_ab_turn_no := coalesce((st->>'turnNumber')::int, 1);
    v_ab_max_uses := nullif(v_qj->>'abilityMaxUses','')::int;
    v_ab_cooldown := coalesce(nullif(v_qj->>'abilityCooldownTurns','')::int, 0);
    v_ab_used := coalesce((v_qj->>'abilityUses')::int, 0);
    v_ab_last_used := nullif(v_qj->>'abilityLastUsedTurn','')::int;
    continue when not ((v_ab_max_uses is null or v_ab_used < v_ab_max_uses)
                       and (v_ab_cooldown <= 0 or v_ab_last_used is null or v_ab_turn_no - v_ab_last_used > v_ab_cooldown));
    select coalesce(r.rmin,1), coalesce(r.rmax,(v_qj->>'rmax')::int), r.rk = 'ANYWHERE'
      into v_rmin2, v_rmax2, v_rany
      from (select (r->>'range_min')::int rmin, (r->>'range_max')::int rmax, r->>'range_kind' rk
              from jsonb_array_elements(v_qj->'abilityScript') r
             where r->>'trigger' = 'ON_ABILITY' and r->>'target_selector' = 'TWO_CHOSEN_UNITS' limit 1) r;
    v_tiles2 := array[(v_qj->>'x') || ',' || (v_qj->>'y')];
    if not (v_qj->>'moved')::boolean and (not cn_stunned(v_qj) or not cn_stun_blocks('move')) then
      v_tiles2 := v_tiles2 || cn_reach(st, v_qj);
    end if;
    foreach v_t2 in array v_tiles2 loop
      exit when v_nsw >= v_swn;
      v_cx2 := split_part(v_t2,',',1)::int; v_cy2 := split_part(v_t2,',',2)::int;
      for v_ja in select * from jsonb_array_elements(st->'units') loop
        continue when (v_ja->>'hp')::int <= 0 or v_ja->>'id' = v_qj->>'id';
        continue when not (v_rany or cn_cheb(v_cx2, v_cy2, (v_ja->>'x')::int, (v_ja->>'y')::int) between v_rmin2 and v_rmax2);
        for v_jb in select * from jsonb_array_elements(st->'units') loop
          continue when (v_jb->>'hp')::int <= 0 or v_jb->>'id' = v_qj->>'id' or v_jb->>'id' <= v_ja->>'id';
          continue when not (v_rany or cn_cheb(v_cx2, v_cy2, (v_jb->>'x')::int, (v_jb->>'y')::int) between v_rmin2 and v_rmax2);
          -- swapping two of the same side's neighbours, or two units already side by side, changes nothing worth a turn
          continue when v_ja->>'owner' = v_jb->>'owner' and cn_cheb((v_ja->>'x')::int,(v_ja->>'y')::int,(v_jb->>'x')::int,(v_jb->>'y')::int) <= 1;
          exit when v_nsw >= v_swn;
          v_nsw := v_nsw + 1;
          v_after_left := v_cap - coalesce((st->>'acts')::int, 0) - case when v_cur_active is not distinct from v_qj->>'id' then 0 else 1 end;
          v_w2 := case when v_after_left > 0 then v_w || jsonb_build_object('expo', cn_b4_w(v_w,'expo',0.85) * v_expo_mid) else v_w end;
          v_val := cn_b4_eval(
            jsonb_set(st, '{units}', (
              select jsonb_agg(
                case when q->>'id' = v_qj->>'id' then q || jsonb_build_object('x', v_cx2, 'y', v_cy2, 'moved', true, 'acted', true)
                     when q->>'id' = v_ja->>'id' then q || jsonb_build_object('x', (v_jb->>'x')::int, 'y', (v_jb->>'y')::int)
                     when q->>'id' = v_jb->>'id' then q || jsonb_build_object('x', (v_ja->>'x')::int, 'y', (v_ja->>'y')::int)
                     else q end order by ord)
                from jsonb_array_elements(st->'units') with ordinality t(q, ord))),
            p_side, v_w2);
          v_sc := v_val + random() * v_nz - cn_b4_w(v_w,'swap_pen',3);
          if v_dbg then raise notice 'b4 swap % via (%,%) % <-> % = %', v_qj->>'id', v_cx2, v_cy2, v_ja->>'id', v_jb->>'id', round(v_val,1); end if;
          if v_sc > v_bestval then
            v_bestval := v_sc; v_bi := -1;
            v_sw_u := v_qj->>'id'; v_sw_x := v_cx2; v_sw_y := v_cy2; v_sw_t := (v_ja->>'id') || '&' || (v_jb->>'id');
          end if;
        end loop;
      end loop;
    end loop;
  end loop;

  if v_bi > 0 then
    v_bu := v_cu[v_bi]; v_bx := v_cx[v_bi]; v_by := v_cy[v_bi]; v_bt := v_ct[v_bi];
    v_bkind := case v_ck[v_bi] when 'move' then null else v_ck[v_bi] end;
  elsif v_bi = -1 then
    v_bu := v_sw_u; v_bx := v_sw_x; v_by := v_sw_y; v_bt := v_sw_t; v_bkind := 'ability';
  else
    v_bu := null;   -- ending the turn here is the best option
  end if;
  v_fu := null;

  if v_bu is null and v_fu is not null and v_lvl4 is null then
    v_bu := v_fu; v_bx := v_fbx; v_by := v_fby; v_bt := v_ft; v_bkind := v_fkind;
  end if;
  if v_bu is null then
    m := advance_turn(p_match, null, false);
    if m.is_sim then
      update public.matches set state = jsonb_set(coalesce(m.state, '{}'::jsonb), '{lastBotAction}',
        jsonb_build_object('side', p_side, 'unit', null, 'target', null, 'kind', 'pass'))
      where id = m.id returning * into m;
    end if;
    return m;
  end if;

  for u in select * from jsonb_array_elements(st->'units') loop
    if u->>'id' = v_bu and ((u->>'x')::int <> v_bx or (u->>'y')::int <> v_by) then
      m := cn_move(p_match, p_side, v_bu, v_bx, v_by);
      if m.is_sim then
        update public.matches set state = jsonb_set(coalesce(m.state, '{}'::jsonb), '{lastBotAction}',
          jsonb_build_object('side', p_side, 'unit', v_bu, 'target', null, 'kind', 'move'))
        where id = m.id returning * into m;
      end if;
      return m;
    end if;
  end loop;

  if v_bkind = 'ability' then
    m := cn_ability(p_match, p_side, v_bu, v_bt);
    if m.is_sim then
      update public.matches set state = jsonb_set(coalesce(m.state, '{}'::jsonb), '{lastBotAction}',
        jsonb_build_object('side', p_side, 'unit', v_bu, 'target', v_bt, 'kind', 'ability'))
      where id = m.id returning * into m;
    end if;
    return m;
  end if;

  if v_bt is not null then
    m := cn_attack(p_match, p_side, v_bu, v_bt);
    if m.is_sim then
      update public.matches set state = jsonb_set(coalesce(m.state, '{}'::jsonb), '{lastBotAction}',
        jsonb_build_object('side', p_side, 'unit', v_bu, 'target', v_bt, 'kind', 'attack'))
      where id = m.id returning * into m;
    end if;
    return m;
  end if;

  m := advance_turn(p_match, null, false);
  if m.is_sim then
    update public.matches set state = jsonb_set(coalesce(m.state, '{}'::jsonb), '{lastBotAction}',
      jsonb_build_object('side', p_side, 'unit', null, 'target', null, 'kind', 'pass'))
    where id = m.id returning * into m;
  end if;
  return m;
end

$function$
;


-- bot_step hands over to bot4_step for a "b4" brain (and falls back to itself on any error)
do $mig$
declare d text := pg_get_functiondef('public.bot_step(uuid,text)'::regprocedure);
  a constant text := E'  v_w := coalesce(v_w, ''{}''::jsonb);\n';
  n constant text := E'  v_w := coalesce(v_w, ''{}''::jsonb);\n  if v_w->>''engine'' = ''b4'' then\n    begin\n      return public.bot4_step(p_match, p_side);\n    exception when others then null;   -- anything unforeseen: fall back to the classic scorer below\n    end;\n  end if;\n';
begin
  if position('bot4_step' in d) > 0 then return; end if;
  if position(a in d) = 0 then raise exception 'bot_step anchor not found'; end if;
  execute replace(d, a, n);
end $mig$;

-- the bot's deployment follows the live expert brain when that brain asks for it ("place": "b4")
do $mig$
declare d text := pg_get_functiondef('public.cn_bot_army(jsonb,text,text[],integer)'::regprocedure);
  a constant text := E'begin\n  for e in select * from jsonb_array_elements(coalesce(p_state->''obstacles'', ''[]''::jsonb)) loop\n    v_taken := v_taken || ((e->>''x'') || '','' || (e->>''y''));\n  end loop;\n';
  n constant text := E'begin\n  if coalesce(p_level, 1) >= 3 and (select weights->>''place'' from public.bot_brains where level = 3 and is_live limit 1) = ''b4'' then\n    return public.cn_b4_place(p_state, p_side, p_deck, (select weights from public.bot_brains where level = 3 and is_live limit 1));\n  end if;\n  for e in select * from jsonb_array_elements(coalesce(p_state->''obstacles'', ''[]''::jsonb)) loop\n    v_taken := v_taken || ((e->>''x'') || '','' || (e->>''y''));\n  end loop;\n';
begin
  if position('cn_b4_place' in d) > 0 then return; end if;
  if position(a in d) = 0 then raise exception 'cn_bot_army anchor not found'; end if;
  execute replace(d, a, n);
end $mig$;

-- a refused tornado throw is declined instead of leaving the match waiting on the bot
do $mig$
declare d text := pg_get_functiondef('public.bot_step(uuid,text)'::regprocedure);
  a constant text := E'        return cn_throw(p_match, p_side, ''@'' || v_cand_x || '','' || v_cand_y);\n';
  n constant text := E'        begin\n          return cn_throw(p_match, p_side, ''@'' || v_cand_x || '','' || v_cand_y);\n        exception when others then\n          return cn_throw(p_match, p_side, null);   -- a throw the engine refuses is declined, never a stalled match\n        end;\n';
begin
  if position('a throw the engine refuses' in d) > 0 then return; end if;
  if position(a in d) = 0 then raise exception 'bot_step throw anchor not found'; end if;
  execute replace(d, a, n);
end $mig$;
