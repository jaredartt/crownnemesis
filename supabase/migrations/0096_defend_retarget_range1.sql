-- 0096: rebuild the defend mechanic -- Jared: "you can select if you want
-- to defend yourself, or defend anything, of course including itself. (it
-- can be an ally, a structure, or even an enemy ... This applies to any
-- unit, any movement or range they may have, it's all ignored: if you want
-- to defend anything, it needs to be in range 1)."
--
-- Previously cn_defend only ever set `defending=true` on the ACTING unit
-- itself (submit_defend(p_match, p_unit) -- no target at all). This adds an
-- explicit p_target: any unit (self, ally, or enemy) or any obstacle/
-- structure, as long as it sits at cn_cheb distance <= 1 of the defender --
-- the defender's own rmin/rmax/mov are never consulted, unlike a strike or
-- a scripted ability. The 50%-damage-reduction math itself (cn_damage's own
-- p_defending flag) is UNCHANGED -- "the same rules of defending will
-- apply" -- this migration only makes it retargetable and range-gated.
--
-- Every old call site keeps working: cn_defend/cn_defend_royale/
-- submit_defend/submit_royale_defend each keep their original arity as a
-- thin SQL wrapper delegating to the new signature with p_target = p_unit
-- (self), the same overload idiom advance_turn's own p_timeout parameter
-- already uses in this codebase.
--
-- defendedBy (new field, alongside `defending`, on a unit OR an obstacle)
-- records WHO raised the guard -- not who owns the defended thing, which
-- may now differ (an enemy or a neutral structure can be defended too).
-- advance_turn/advance_turn_royale key their clearing off defendedBy
-- instead of the defended thing's own `owner`, which preserves the exact
-- original duration ("still up while the opponent is swinging, lapses when
-- the raiser's own next turn opens") regardless of who or what was
-- defended. Obstacles never carried a defending flag before this; the new
-- clearing loop over `obstacles` is a no-op for a match with no structures.
--
-- cn_attack's tree/wall/bomb/tornado-strike branch never read `defending`
-- at all (only unit-vs-unit swings did) -- now it passes the struck
-- obstacle's own `defending` through to cn_damage, same as every other
-- damage roll in that function already does for its target.
--
-- Client side (same commit): SentenceBuilder-style target-picking mode
-- ('defend', alongside 'move'/'attack'/'ability' in Board.tsx's own Mode
-- type) lets the defender's own controls pick self/ally/enemy/structure
-- within the same is-target highlighting attack/ability already use;
-- clicking an enemy or any obstacle asks for confirmation first (ally and
-- self do not), and a unit gaining `defending` plays the same notorious
-- green pulse every other status now gets (StatusBurst's `guard` kind).
--
-- Applied directly via mcp__Supabase__apply_migration/execute_sql before
-- this file was written; reproduced here for the migration history. The
-- cn_attack change is applied as a targeted find-and-replace against its
-- own live definition (via pg_get_functiondef), the same as this
-- session's earlier stale-card-flags migration used cn_compile_card_effects
-- -- safer than hand-transcribing a 300-line function, and it fails loudly
-- (raises an exception) if the anchor text it expects to find is gone.

-- ===== cn_defend: now takes an explicit target. =====
CREATE OR REPLACE FUNCTION public.cn_defend(p_match uuid, p_side text, p_unit text, p_target text)
 RETURNS matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  m public.matches; v_st jsonb; u jsonb; e jsonb;
  v_me jsonb; v_tgt_unit jsonb; v_tgt_obj jsonb;
  v_target_id text; v_tx int; v_ty int; v_dist int;
  v_out jsonb := '[]'::jsonb; v_rocks jsonb := '[]'::jsonb;
  v_note text;
begin
  select * into m from public.matches where id = p_match for update;
  v_st := m.state;
  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then v_me := u; end if;
  end loop;
  if v_me is null then raise exception 'no such unit'; end if;
  if v_me->>'owner' <> p_side then raise exception 'that is not your unit'; end if;
  if (v_me->>'acted')::boolean then raise exception 'that unit already acted'; end if;

  v_target_id := coalesce(nullif(p_target, ''), p_unit);

  if v_target_id = p_unit then
    v_tx := (v_me->>'x')::int; v_ty := (v_me->>'y')::int;
  else
    for u in select * from jsonb_array_elements(v_st->'units') loop
      if u->>'id' = v_target_id then v_tgt_unit := u; end if;
    end loop;
    if v_tgt_unit is null then
      for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
        if e->>'id' = v_target_id then v_tgt_obj := e; end if;
      end loop;
    end if;
    if v_tgt_unit is null and v_tgt_obj is null then raise exception 'no such target'; end if;
    v_tx := coalesce((v_tgt_unit->>'x')::int, (v_tgt_obj->>'x')::int);
    v_ty := coalesce((v_tgt_unit->>'y')::int, (v_tgt_obj->>'y')::int);
  end if;

  -- RANGE 1, ALWAYS. Jared: "This applies to any unit, any movement or
  -- range they may have, it's all ignored: if you want to defend anything,
  -- it needs to be in range 1." Reads cn_cheb directly rather than the
  -- defender's own rmin/rmax the way a strike or a scripted ability would.
  v_dist := cn_cheb((v_me->>'x')::int, (v_me->>'y')::int, v_tx, v_ty);
  if v_dist > 1 then raise exception 'too far to defend'; end if;

  v_st := cn_begin_act(v_st, p_side, p_unit);

  v_out := '[]'::jsonb;
  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then
      u := jsonb_set(u, '{acted}', 'true'::jsonb);
    end if;
    -- defendedBy records WHO raised this guard (not who owns the target,
    -- which may now differ) -- advance_turn/advance_turn_royale read it to
    -- decide whose next turn lapses it, exactly the same window the old
    -- self-only guard always had.
    if u->>'id' = v_target_id then
      u := jsonb_set(u, '{defending}', 'true'::jsonb);
      u := jsonb_set(u, '{defendedBy}', to_jsonb(p_side));
    end if;
    v_out := v_out || u;
  end loop;
  v_st := jsonb_set(v_st, '{units}', v_out);

  if v_tgt_obj is not null then
    v_rocks := '[]'::jsonb;
    for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
      if e->>'id' = v_target_id then
        e := jsonb_set(e, '{defending}', 'true'::jsonb);
        e := jsonb_set(e, '{defendedBy}', to_jsonb(p_side));
      end if;
      v_rocks := v_rocks || e;
    end loop;
    v_st := jsonb_set(v_st, '{obstacles}', v_rocks);
  end if;

  v_st := cn_end_act(v_st, p_unit);

  v_note := case
    when v_target_id = p_unit then (v_me->>'name') || ' raises a guard.'
    when v_tgt_unit is not null then (v_me->>'name') || ' guards ' || (v_tgt_unit->>'name') || '.'
    else (v_me->>'name') || ' guards ' || cn_obj_name(cn_obj_kind(v_tgt_obj)) || '.'
  end;
  v_st := state_log(v_st, v_note);

  update public.matches set state = v_st, updated_at = now()
   where id = m.id returning * into m;
  return m;
end $function$;

-- Backward-compatible self-defend wrapper -- same idiom advance_turn's own
-- two overloads already use in this codebase.
CREATE OR REPLACE FUNCTION public.cn_defend(p_match uuid, p_side text, p_unit text)
 RETURNS matches
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select public.cn_defend(p_match, p_side, p_unit, p_unit)
$function$;

CREATE OR REPLACE FUNCTION public.submit_defend(p_match uuid, p_unit text, p_target text)
 RETURNS matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare m public.matches; v_side text;
begin
  select * into m from public.matches where id = p_match;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'active' then raise exception 'match is not running'; end if;
  v_side := side_of(m, auth.uid());
  if v_side is null then raise exception 'you are spectating this match'; end if;
  if m.state->>'turn' <> v_side then raise exception 'not your turn'; end if;
  if now() > m.turn_deadline + interval '2 seconds' then raise exception 'your time ran out'; end if;
  return cn_defend(p_match, v_side, p_unit, p_target);
end $function$;

CREATE OR REPLACE FUNCTION public.submit_defend(p_match uuid, p_unit text)
 RETURNS matches
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select public.submit_defend(p_match, p_unit, p_unit)
$function$;

-- ===== Royale mirror. Royale has no obstacles array anywhere in its own
-- functions, so this stays unit-only (self, ally, or enemy unit -- all
-- within cn_cheb distance 1). =====
CREATE OR REPLACE FUNCTION public.cn_defend_royale(p_match uuid, p_seat integer, p_unit text, p_target text)
 RETURNS royale_matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  m public.royale_matches; v_st jsonb; u jsonb; v_me jsonb; v_tgt jsonb;
  v_target_id text; v_dist int; v_out jsonb := '[]'::jsonb;
begin
  select * into m from public.royale_matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  v_st := m.state;
  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then v_me := u; end if;
  end loop;
  if v_me is null then raise exception 'no such unit'; end if;
  if (v_me->>'owner')::int <> p_seat then raise exception 'that is not your unit'; end if;
  if (v_me->>'acted')::boolean then raise exception 'that unit already acted'; end if;

  v_target_id := coalesce(nullif(p_target, ''), p_unit);
  if v_target_id <> p_unit then
    for u in select * from jsonb_array_elements(v_st->'units') loop
      if u->>'id' = v_target_id then v_tgt := u; end if;
    end loop;
    if v_tgt is null then raise exception 'no such target'; end if;
    v_dist := cn_cheb((v_me->>'x')::int, (v_me->>'y')::int, (v_tgt->>'x')::int, (v_tgt->>'y')::int);
  else
    v_dist := 0;
  end if;
  if v_dist > 1 then raise exception 'too far to defend'; end if;

  v_st := cn_begin_act_royale(v_st, p_seat, p_unit);

  v_out := '[]'::jsonb;
  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then u := jsonb_set(u, '{acted}', 'true'::jsonb); end if;
    if u->>'id' = v_target_id then
      u := jsonb_set(u, '{defending}', 'true'::jsonb);
      u := jsonb_set(u, '{defendedBy}', to_jsonb(p_seat));
    end if;
    v_out := v_out || u;
  end loop;
  v_st := jsonb_set(v_st, '{units}', v_out);
  v_st := cn_end_act_royale(v_st, p_unit);
  v_st := state_log(v_st, (v_me->>'name') ||
    case when v_target_id = p_unit then ' raises a guard.'
         else ' guards ' || (v_tgt->>'name') || '.' end);

  update public.royale_matches set state = v_st, updated_at = now()
   where id = m.id returning * into m;
  return m;
end $function$;

CREATE OR REPLACE FUNCTION public.cn_defend_royale(p_match uuid, p_seat integer, p_unit text)
 RETURNS royale_matches
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select public.cn_defend_royale(p_match, p_seat, p_unit, p_unit)
$function$;

CREATE OR REPLACE FUNCTION public.submit_royale_defend(p_match uuid, p_unit text, p_target text)
 RETURNS royale_matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare m public.royale_matches; v_seat int;
begin
  select * into m from public.royale_matches where id = p_match;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'active' then raise exception 'match is not running'; end if;
  v_seat := royale_side_of(p_match);
  if v_seat is null then raise exception 'you are spectating this match'; end if;
  if coalesce((m.state->>'turn')::int, -1) <> v_seat then raise exception 'not your turn'; end if;
  if now() > m.turn_deadline + interval '2 seconds' then raise exception 'your time ran out'; end if;
  update public.royale_players set last_acted_turn = (m.state->>'turnNumber')::int
   where match_id = p_match and seat = v_seat;
  return cn_defend_royale(p_match, v_seat, p_unit, p_target);
end $function$;

CREATE OR REPLACE FUNCTION public.submit_royale_defend(p_match uuid, p_unit text)
 RETURNS royale_matches
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select public.submit_royale_defend(p_match, p_unit, p_unit)
$function$;

-- ===== advance_turn: clear guard by WHO RAISED IT (defendedBy), not by
-- the defended thing's own owner -- those can now differ. Also clears any
-- defended obstacle. =====
CREATE OR REPLACE FUNCTION public.advance_turn(p_match uuid, p_note text, p_timeout boolean)
 RETURNS matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  m public.matches; st jsonb; u jsonb; out_u jsonb := '[]'::jsonb;
  v_who text; v_next text; v_turn int; v_did boolean := false; v_n int;
  v_got int; v_hurt int; u2 jsonb; v_poisoned jsonb := '[]'::jsonb;
  v_obs_out jsonb; e2 jsonb;
begin
  select * into m from public.matches where id = p_match for update;
  st := m.state;
  v_who  := st->>'turn';
  v_next := case when v_who = 'host' then 'guest' else 'host' end;
  v_turn := coalesce((st->>'turnNumber')::int, 1) + 1;

  for u in select * from jsonb_array_elements(st->'units') loop
    if u->>'owner' = v_who and ((u->>'moved')::boolean or (u->>'acted')::boolean) then
      v_did := true;
    end if;
    u := jsonb_set(u, '{moved}', 'false'::jsonb);
    u := jsonb_set(u, '{acted}', 'false'::jsonb);
    u := jsonb_set(u, '{spent}', 'false'::jsonb);
    -- A guard is raised on the RAISER's turn and has to survive the
    -- opponent's, so it lapses when the RAISER's next turn opens -- keyed
    -- on defendedBy (who raised it), not on the defended unit's own owner,
    -- since a defend can now be pointed at an enemy or a neutral structure
    -- and those two are no longer always the same side.
    if u->>'defendedBy' = v_next then
      u := jsonb_set(u, '{defending}', 'false'::jsonb);
      u := jsonb_set(u, '{defendedBy}', 'null'::jsonb);
    end if;
    out_u := out_u || u;
  end loop;

  if st->'idle' is null then
    st := jsonb_set(st, '{idle}', jsonb_build_object('host', 0, 'guest', 0));
  end if;
  v_n := coalesce((st->'idle'->>v_who)::int, 0);
  if p_timeout and not v_did and not (m.bot is not null and v_who = 'guest') then
    v_n := v_n + 1;
  else
    v_n := 0;
  end if;
  st := jsonb_set(st, array['idle', v_who], to_jsonb(v_n));

  if p_timeout and v_n >= 2 then
    st := jsonb_set(st, '{units}', out_u);
    st := jsonb_set(st, '{winner}', to_jsonb(v_next));
    st := jsonb_set(st, '{forfeitedBy}', to_jsonb(v_who));
    st := state_log(st,
      (case when v_who = 'host' then m.host_name else m.guest_name end)
      || ' has forfeited by inactivity.');
    if m.ranked or (m.bot is null and cn_friend_tournament_lp_enabled()) then
      perform finish_match(m.id, v_next, 'abandon');
    end if;
    update public.matches
       set state = st, status = 'finished', winner = v_next,
           turn_deadline = null, updated_at = now()
     where id = m.id returning * into m;
    return m;
  end if;

  if v_n >= 3 then
    if coalesce(st->>'away', '') <> v_who then
      st := state_log(st,
        case when v_who = 'host' then m.host_name else m.guest_name end
        || ' has not acted for three turns.');
    end if;
    st := jsonb_set(st, '{away}', to_jsonb(v_who));
  elsif st->>'away' = v_who then
    st := jsonb_set(st, '{away}', 'null'::jsonb);
    st := state_log(st,
      case when v_who = 'host' then m.host_name else m.guest_name end || ' is back.');
  end if;

  st := jsonb_set(st, '{units}', out_u);

  -- Any defended obstacle/structure lapses the same way, on the raiser's
  -- own next turn -- new with retargetable defend (0096); obstacles never
  -- carried a defending flag before this, so this is a no-op for a match
  -- with no structures.
  v_obs_out := '[]'::jsonb;
  for e2 in select * from jsonb_array_elements(coalesce(st->'obstacles', '[]'::jsonb)) loop
    if e2->>'defendedBy' = v_next then
      e2 := jsonb_set(e2, '{defending}', 'false'::jsonb);
      e2 := jsonb_set(e2, '{defendedBy}', 'null'::jsonb);
    end if;
    v_obs_out := v_obs_out || e2;
  end loop;
  st := jsonb_set(st, '{obstacles}', v_obs_out);

  v_n := coalesce((st->'mist'->v_who->>'t')::int, 0);
  if v_n > 0 then
    st := jsonb_set(st, array['mist', v_who, 't'], to_jsonb(v_n - 1));
    if v_n = 1 then
      st := state_log(st, 'The mist lifts.');
    end if;
  end if;

  for u in select * from jsonb_array_elements(st->'units') loop
    if u->>'owner' = v_next
       and coalesce((cn_awake(st, u)->>'poisonsAdj')::boolean, false)
       and (u->>'hp')::int > 0 then
      for u2 in select * from jsonb_array_elements(st->'units') loop
        if u2->>'id' <> u->>'id'
           and cn_cheb((u->>'x')::int, (u->>'y')::int,
                       (u2->>'x')::int, (u2->>'y')::int) = 1 then
          v_poisoned := v_poisoned || to_jsonb(u2->>'id');
        end if;
      end loop;
    end if;
  end loop;

  out_u := '[]'::jsonb;
  for u in select * from jsonb_array_elements(st->'units') loop
    if v_poisoned ? (u->>'id') then
      if not cn_has(u, 'poison') then
        st := state_log(st, (u->>'name') || ' is poisoned.');
      end if;
      u := cn_afflict(u, 'poison', 'true'::jsonb);
    end if;

    if u->>'owner' = v_next and cn_stunned(u) then
      u := cn_afflict(u, 'stun',
                      to_jsonb(greatest(0, (u->'effects'->>'stun')::int - 1)));
      if not cn_stunned(u) then
        st := state_log(st, (u->>'name') || ' shakes it off.');
      end if;
    end if;

    if u->>'owner' = v_next and cn_has(u, 'poison') and (u->>'hp')::int > 0 then
      v_hurt := cn_effect_dmg(st, u, cn_poison_pct());
      u := jsonb_set(u, '{hp}', to_jsonb((u->>'hp')::int - v_hurt));
      st := state_log(st, (u->>'name') || ' takes ' || v_hurt || ' from the poison.');
    end if;

    if u->>'owner' = v_next and coalesce((cn_awake(st, u)->>'regenPct')::int, 0) > 0
       and (u->>'hp')::int > 0 and (u->>'hp')::int < (u->>'maxHp')::int then
      v_got := least((u->>'maxHp')::int - (u->>'hp')::int,
                     greatest(1, round((u->>'maxHp')::int
                              * coalesce((cn_awake(st, u)->>'regenPct')::int, 0)
                              / 100.0)::int));
      u := jsonb_set(u, '{hp}', to_jsonb((u->>'hp')::int + v_got));
      st := state_log(st, (u->>'name') || ' mends ' || v_got || '.');
    end if;
    if (u->>'hp')::int > 0 then out_u := out_u || u; end if;
  end loop;
  st := jsonb_set(st, '{units}', out_u);

  st := jsonb_set(st, '{acts}', '0'::jsonb);

  if v_next = 'host' then
    if coalesce((st->>'roundDmg')::boolean, false) then
      st := jsonb_set(st, '{staleRounds}', '0'::jsonb);
    else
      st := jsonb_set(st, '{staleRounds}',
        to_jsonb(coalesce((st->>'staleRounds')::int, 0) + 1));
    end if;
    st := jsonb_set(st, '{roundDmg}', 'false'::jsonb);

    if coalesce((st->>'staleRounds')::int, 0) >= 5 then
      st := jsonb_set(st, '{winner}', to_jsonb('draw'::text));
      st := state_log(st, 'Stalemate -- no damage dealt for five rounds. The match is a draw.');
      update public.matches
         set state = st, status = 'finished', winner = 'draw',
             turn_deadline = null, updated_at = now()
       where id = m.id returning * into m;
      return m;
    end if;
  end if;

  for u in select * from jsonb_array_elements(coalesce(st->'units', '[]'::jsonb)) loop
    if u->>'owner' = v_who and jsonb_typeof(u->'abilityScript') = 'array'
       and jsonb_array_length(u->'abilityScript') > 0 then
      st := cn_run_effects(st, 'END_OF_TURN', u, jsonb_build_object('turnNumber', v_turn));
    end if;
  end loop;
  for u in select * from jsonb_array_elements(coalesce(st->'units', '[]'::jsonb)) loop
    if u->>'owner' = v_next and jsonb_typeof(u->'abilityScript') = 'array'
       and jsonb_array_length(u->'abilityScript') > 0 then
      st := cn_run_effects(st, 'START_OF_TURN', u, jsonb_build_object('turnNumber', v_turn));
    end if;
  end loop;

  st := jsonb_set(st, '{active}', 'null'::jsonb);
  st := jsonb_set(st, '{turn}', to_jsonb(v_next));
  st := jsonb_set(st, '{turnNumber}', to_jsonb(v_turn));
  if p_note is not null then st := state_log(st, p_note); end if;
  st := state_log(st, 'Turn ' || v_turn || ' — '
        || case when v_next = 'host' then m.host_name else m.guest_name end || ' to act.');

  update public.matches
     set state = st, turn_deadline = now() + interval '30 seconds', updated_at = now()
   where id = m.id returning * into m;
  return m;
end
$function$;

-- ===== advance_turn_royale: same defendedBy-keyed clearing (seat is an
-- int here, so the comparison needs a null guard before the cast). Royale
-- has no obstacles array anywhere else in its own functions, so nothing
-- to clear there. =====
CREATE OR REPLACE FUNCTION public.advance_turn_royale(p_match uuid, p_note text, p_timeout boolean DEFAULT false)
 RETURNS royale_matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  m public.royale_matches; st jsonb; u jsonb; out_u jsonb := '[]'::jsonb;
  v_who int; v_next int; v_turn int; v_seats int[]; v_tries int := 0; v_name text;
  v_cur_turn int; v_did boolean; v_idle int; v_seat_name text;
  v_alive_seats int[]; v_win_seat int;
  v_who_bot int;
begin
  select * into m from public.royale_matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  st := m.state;
  v_who := coalesce((st->>'turn')::int, 0);
  v_cur_turn := coalesce((st->>'turnNumber')::int, 1);
  v_turn := v_cur_turn + 1;

  select array_agg(seat order by seat) into v_seats
    from public.royale_players where match_id = p_match and not eliminated;
  if coalesce(array_length(v_seats, 1), 0) = 0 then return m; end if;

  select bot into v_who_bot from public.royale_players
   where match_id = p_match and seat = v_who;

  if v_who = any(v_seats) and v_who_bot is null then
    select (last_acted_turn = v_cur_turn) into v_did
      from public.royale_players where match_id = p_match and seat = v_who;
    v_did := coalesce(v_did, false);

    if p_timeout and not v_did then
      update public.royale_players set idle_streak = idle_streak + 1
       where match_id = p_match and seat = v_who
       returning idle_streak into v_idle;
    else
      update public.royale_players set idle_streak = 0
       where match_id = p_match and seat = v_who
       returning idle_streak into v_idle;
    end if;

    if p_timeout and coalesce(v_idle, 0) >= 2 then
      out_u := (select coalesce(jsonb_agg(q), '[]'::jsonb)
                  from jsonb_array_elements(st->'units') q
                 where (q->>'owner')::int <> v_who);
      st := jsonb_set(st, '{units}', out_u);
      select username into v_seat_name from public.royale_players
       where match_id = p_match and seat = v_who;
      update public.royale_players set eliminated = true, eliminated_at = now()
       where match_id = p_match and seat = v_who;
      st := state_log(st, coalesce(v_seat_name, 'Seat ' || v_who)
            || ' has forfeited by inactivity.');

      select array_agg(seat order by seat) into v_alive_seats
        from public.royale_players where match_id = p_match and not eliminated;

      if coalesce(array_length(v_alive_seats, 1), 0) <= 1 then
        v_win_seat := v_alive_seats[1];
        if v_win_seat is not null then
          select username into v_seat_name from public.royale_players
           where match_id = p_match and seat = v_win_seat;
          st := jsonb_set(st, '{winnerSeat}', to_jsonb(v_win_seat));
          st := state_log(st, coalesce(v_seat_name, 'Seat ' || v_win_seat)
                || ' wins the battle royale.');
        end if;
        update public.royale_matches
           set state = st, status = 'finished', winner_seat = v_win_seat,
               turn_deadline = null, updated_at = now()
         where id = m.id returning * into m;
        return m;
      end if;

      v_seats := v_alive_seats;
    end if;
  end if;

  v_next := v_who;
  loop
    v_next := (v_next + 1) % 4;
    v_tries := v_tries + 1;
    exit when v_next = any(v_seats) or v_tries > 4;
  end loop;
  if v_tries > 4 then v_next := v_seats[1]; end if;

  out_u := '[]'::jsonb;
  for u in select * from jsonb_array_elements(st->'units') loop
    u := jsonb_set(u, '{moved}', 'false'::jsonb);
    u := jsonb_set(u, '{acted}', 'false'::jsonb);
    u := jsonb_set(u, '{spent}', 'false'::jsonb);
    if coalesce(u->>'defendedBy', '') <> '' and (u->>'defendedBy')::int = v_next then
      u := jsonb_set(u, '{defending}', 'false'::jsonb);
      u := jsonb_set(u, '{defendedBy}', 'null'::jsonb);
    end if;
    out_u := out_u || u;
  end loop;
  st := jsonb_set(st, '{units}', out_u);

  st := jsonb_set(st, '{acts}', '0'::jsonb);

  if array_length(v_seats, 1) > 0 and v_next = v_seats[1] then
    if coalesce((st->>'roundDmg')::boolean, false) then
      st := jsonb_set(st, '{staleRounds}', '0'::jsonb);
    else
      st := jsonb_set(st, '{staleRounds}',
        to_jsonb(coalesce((st->>'staleRounds')::int, 0) + 1));
    end if;
    st := jsonb_set(st, '{roundDmg}', 'false'::jsonb);

    if coalesce((st->>'staleRounds')::int, 0) >= 5 then
      st := state_log(st, 'Stalemate -- no damage dealt for five rounds. The match is a draw.');
      update public.royale_matches
         set state = st, status = 'finished', winner_seat = null, draw = true,
             turn_deadline = null, updated_at = now()
       where id = m.id returning * into m;
      return m;
    end if;
  end if;

  st := jsonb_set(st, '{active}', 'null'::jsonb);
  st := jsonb_set(st, '{turn}', to_jsonb(v_next));
  st := jsonb_set(st, '{turnNumber}', to_jsonb(v_turn));
  if p_note is not null then st := state_log(st, p_note); end if;
  select username into v_name from public.royale_players
   where match_id = p_match and seat = v_next;
  st := state_log(st, 'Turn ' || v_turn || ' -- ' || coalesce(v_name, 'seat ' || v_next)
        || ' to act.');

  update public.royale_matches
     set state = st, turn_deadline = now() + interval '30 seconds', updated_at = now()
   where id = m.id returning * into m;
  return m;
end
$function$;

-- ===== cn_attack: pass the struck obstacle's own `defending` through to
-- cn_damage, same as every unit-vs-unit swing in this function already
-- does. Applied as a find-and-replace against the function's own live
-- definition rather than a full CREATE OR REPLACE, so this migration can't
-- silently drift from whatever the rest of cn_attack looks like by the
-- time it runs; it raises if the exact line it expects is gone. =====
DO $$
DECLARE
  v_def text;
  v_new text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def
  FROM pg_proc WHERE proname = 'cn_attack' AND pronamespace = 'public'::regnamespace;

  v_new := replace(
    v_def,
    'v_dmg := cn_damage(cn_roll((v_atk->>''dmin'')::int, (v_atk->>''dmax'')::int), v_crit, false);',
    'v_dmg := cn_damage(cn_roll((v_atk->>''dmin'')::int, (v_atk->>''dmax'')::int), v_crit, false, 0, 0, coalesce((v_tree->>''defending'')::boolean, false));'
  );

  IF v_new = v_def THEN
    RAISE EXCEPTION 'cn_attack: expected tree-strike cn_damage call not found, aborting';
  END IF;

  EXECUTE v_new;
END $$;
