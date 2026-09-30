-- 0179: Battle Royale runs the SAME rules as 1v1, generated from them.
--
-- Jared: "make sure the structures work correctly in battle royale -- trees,
-- bombs and all -- and the animations. Make everything work like in 1 vs 1,
-- don't miss anything." and "can't you just make it so that whatever is applied
-- to 1 vs 1 gets automatically updated into battle royale?"
--
-- What was wrong: Battle Royale's rules (cn_move_royale, cn_attack_royale,
-- cn_ability_royale, cn_defend_royale, advance_turn_royale, cn_royale_army) were
-- hand-copied from an early version of 1v1's and never kept up. So there were no
-- summons (bombs, walls, tornadoes), no traps, no structures, no card-effect
-- scripts, no ability limits/cooldowns, no undo, no poison/regen/stun/mist
-- upkeep, no revive graveyard, no evasion...
--
-- What this does: cn_derive_royale() rebuilds those functions FROM THE LIVE 1v1
-- FUNCTIONS by text patches (seat numbers instead of host/guest, royale_matches
-- instead of matches, elimination instead of a single winner). An event trigger
-- runs it whenever any of the 1v1 source functions is created or replaced, so a
-- change to 1v1's rules reaches Battle Royale in the same transaction. Every
-- patch names the text it expects; if a 1v1 change makes a patch stop matching,
-- the 1v1 change still goes through, Battle Royale keeps its previous (working)
-- version, and the failure is written to royale_engine_log.
--
-- What is deliberately NOT copied: one activation per turn (0061), the 30 s turn
-- clock, the deploy zones/placement, no rating, and the AFK rule (2 missed turns
-- = out, tracked in royale_players.idle_streak).
--
-- Turn-by-turn elimination lives in the hand-written helpers below
-- (cn_royale_settle_state / cn_royale_commit): after any action, a seat with no
-- crown (or no units) left is out, its army leaves the board, and the last seat
-- standing wins.

-- ---------------------------------------------------------------------------
-- Shared helpers made seat-aware (harmless to 1v1: they only ever accepted the
-- two side names before).
-- ---------------------------------------------------------------------------
create or replace function public.cn_royale_patch(p_src text, p_old text, p_new text, p_label text)
returns text language plpgsql immutable as $fn$
begin
  if position(p_old in p_src) = 0 then
    -- Already applied (the shared helpers are patched in place)?
    if position(p_new in p_src) > 0 then return p_src; end if;
    raise exception 'royale engine: anchor "%" not found -- the 1v1 function changed shape; update 0179''s patch', p_label;
  end if;
  return replace(p_src, p_old, p_new);
end $fn$;

-- Replace the text from p_from (inclusive) up to p_to (exclusive).
create or replace function public.cn_royale_cut(p_src text, p_from text, p_to text, p_new text, p_label text)
returns text language plpgsql immutable as $fn$
declare a int; b int;
begin
  a := position(p_from in p_src);
  if a = 0 then raise exception 'royale engine: start anchor "%" not found', p_label; end if;
  b := position(p_to in substr(p_src, a + length(p_from)));
  if b = 0 then raise exception 'royale engine: end anchor "%" not found', p_label; end if;
  b := a + length(p_from) + b - 1;
  return substr(p_src, 1, a - 1) || p_new || substr(p_src, b);
end $fn$;

-- The patches every derived function gets.
create or replace function public.cn_royale_common(p_src text)
returns text language plpgsql immutable as $fn$
declare v text := p_src; a int;
begin
  v := replace(v, 'RETURNS matches', 'RETURNS royale_matches');
  v := replace(v, 'm public.matches', 'm public.royale_matches');
  v := replace(v, 'from public.matches where id = p_match', 'from public.royale_matches where id = p_match');
  v := replace(v, 'update public.matches', 'update public.royale_matches');
  v := replace(v, 'cn_begin_act(v_st, p_side, p_unit)', 'cn_begin_act_royale(v_st, p_seat, p_unit)');
  -- The seat number is the parameter; the old text side name is kept as a local
  -- so every `owner = p_side` comparison in the 1v1 text still reads naturally.
  a := position(E'declare\n' in v);
  if a = 0 then raise exception 'royale engine: no declare block'; end if;
  v := substr(v, 1, a + 7) || E'  p_side text := p_seat::text;\n' || substr(v, a + 8);
  return v;
end $fn$;

-- cn_bury / cn_revive key the graveyard by side. Seats are '0'..'3'.
do $s$
declare v text;
begin
  v := pg_get_functiondef('public.cn_bury(jsonb,jsonb)'::regprocedure);
  v := public.cn_royale_patch(v, $a$v_owner not in ('host', 'guest')$a$,
                                 $a$v_owner not in ('host', 'guest', '0', '1', '2', '3')$a$, 'bury owner');
  execute v;
  v := pg_get_functiondef('public.cn_revive(jsonb,jsonb,jsonb,text)'::regprocedure);
  v := public.cn_royale_patch(v, $a$array['host', 'guest'] loop$a$,
                                 $a$array['host', 'guest', '0', '1', '2', '3'] loop$a$, 'revive graveyards');
  execute v;
end $s$;

-- ---------------------------------------------------------------------------
-- Elimination (Battle Royale's version of "who has won").
-- ---------------------------------------------------------------------------
create or replace function public.cn_royale_settle_state(p_match uuid, p_st jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare r record; v_st jsonb := p_st; v_royal boolean; v_units boolean; v_pend jsonb;
begin
  for r in select seat, username from public.royale_players
            where match_id = p_match and not eliminated order by seat loop
    select exists (select 1 from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) q
                    where (q->>'owner')::int = r.seat and coalesce((q->>'royal')::boolean, false)),
           exists (select 1 from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) q
                    where (q->>'owner')::int = r.seat)
      into v_royal, v_units;
    continue when v_royal and v_units;

    -- The crown fell (or nobody is left): the rest of the army goes with it.
    v_st := jsonb_set(v_st, '{units}', coalesce((
      select jsonb_agg(q) from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) q
       where (q->>'owner')::int <> r.seat), '[]'::jsonb));
    update public.royale_players set eliminated = true, eliminated_at = now()
     where match_id = p_match and seat = r.seat;
    v_st := state_log(v_st,
      case when v_units then 'The crown falls. ' else '' end
      || coalesce(r.username, 'Seat ' || r.seat) || ' is eliminated.');
  end loop;

  -- A decision (the tornado's throw) held by a seat that is out just closes.
  v_pend := cn_pending(v_st);
  if v_pend is not null and exists (
       select 1 from public.royale_players
        where match_id = p_match and eliminated and seat = (v_pend->>'side')::int) then
    v_st := v_st - 'pending';
  end if;
  return v_st;
end $fn$;

-- After any action: apply eliminations, finish the match if one seat is left,
-- and hand the turn on if the seat holding it just went out.
create or replace function public.cn_royale_commit(p_match uuid)
returns public.royale_matches
language plpgsql security definer set search_path = public as $fn$
declare m public.royale_matches; st jsonb; v_alive int[]; v_win int; v_wname text;
begin
  select * into m from public.royale_matches where id = p_match for update;
  if m.id is null or m.status <> 'active' then return m; end if;

  st := cn_royale_settle_state(p_match, m.state);
  select array_agg(seat order by seat) into v_alive
    from public.royale_players where match_id = p_match and not eliminated;

  if coalesce(array_length(v_alive, 1), 0) <= 1 then
    v_win := v_alive[1];
    if v_win is not null then
      select username into v_wname from public.royale_players where match_id = p_match and seat = v_win;
      st := jsonb_set(st, '{winnerSeat}', to_jsonb(v_win));
      st := state_log(st, coalesce(v_wname, 'Seat ' || v_win) || ' wins the battle royale.');
    end if;
    update public.royale_matches
       set state = st, status = 'finished', winner_seat = v_win,
           turn_deadline = null, updated_at = now()
     where id = m.id returning * into m;
    return m;
  end if;

  if st is distinct from m.state then
    update public.royale_matches set state = st, updated_at = now()
     where id = m.id returning * into m;
  end if;

  if not (coalesce((m.state->>'turn')::int, -1) = any(v_alive)) then
    m := advance_turn_royale(p_match, null, false);
  end if;
  return m;
end $fn$;

-- ---------------------------------------------------------------------------
-- The generator.
-- ---------------------------------------------------------------------------
create or replace function public.cn_derive_royale()
returns void
language plpgsql security definer set search_path = public as $gen$
declare v text; a int; r record;
begin
  ----------------------------------------------------------------------- begin_act
  v := pg_get_functiondef('public.cn_begin_act(jsonb,text,text)'::regprocedure);
  v := cn_royale_patch(v, 'public.cn_begin_act(p_st jsonb, p_side text, p_unit text)',
                          'public.cn_begin_act_royale(p_st jsonb, p_seat integer, p_unit text)', 'begin_act head');
  v := cn_royale_common(v);
  -- One activation per turn in Battle Royale (0061).
  v := cn_royale_patch(v, 'v_cap    := cn_acts_cap(p_st);', 'v_cap    := 1;', 'begin_act cap');
  execute v;

  ----------------------------------------------------------------------- move
  v := pg_get_functiondef('public.cn_move(uuid,text,text,integer,integer)'::regprocedure);
  v := cn_royale_patch(v, 'public.cn_move(p_match uuid, p_side text, p_unit text, p_x integer, p_y integer)',
                          'public.cn_move_royale(p_match uuid, p_seat integer, p_unit text, p_x integer, p_y integer)', 'move head');
  v := cn_royale_common(v);
  v := cn_royale_patch(v, E'    v_win := cn_win_after_death(v_st, v_me);\n    v_gale := null;', E'    v_gale := null;', 'move win');
  v := cn_royale_patch(v, E'  if v_win is not null then return cn_finish(m, v_st, v_win); end if;\n', '', 'move finish');
  v := cn_royale_patch(v, $a$'side', v_gale->>'owner',$a$, $a$'side', (v_gale->>'owner')::int,$a$, 'move gale side');
  execute v;

  ----------------------------------------------------------------------- attack
  v := pg_get_functiondef('public.cn_attack(uuid,text,text,text)'::regprocedure);
  v := cn_royale_patch(v, 'public.cn_attack(p_match uuid, p_side text, p_unit text, p_target text)',
                          'public.cn_attack_royale(p_match uuid, p_seat integer, p_unit text, p_target text)', 'attack head');
  v := cn_royale_common(v);
  -- Everything from "who has won" on is 1v1's ending: a single winner, rating,
  -- bot-win credit. Battle Royale's ending is the elimination pass that runs
  -- after the action (cn_royale_commit); only the crit/parry counters stay.
  v := cn_royale_cut(v, '  -- ---- who has won', E'end\n$function$', $t$
  -- Crits and parries are counted per player, whoever swung.
  for v_elem in select * from jsonb_array_elements(v_swings) loop
    v_by := v_elem->>'by';
    if v_by is null then continue; end if;
    if v_by = p_unit then v_by_owner := p_side;
    elsif v_by = p_target then v_by_owner := coalesce(v_tgt->>'owner', p_side);
    else continue; end if;
    select user_id into v_by_uid from public.royale_players
     where match_id = p_match and seat = v_by_owner::int and bot is null;
    if v_by_uid is null then continue; end if;
    if coalesce((v_elem->>'crit')::boolean, false) then
      update public.profiles set crit_count = crit_count + 1 where id = v_by_uid;
      perform cn_check_achievements(v_by_uid);
    end if;
    if v_elem->>'k' = 'parry' then
      update public.profiles set parry_count = parry_count + 1 where id = v_by_uid;
      perform cn_check_achievements(v_by_uid);
    end if;
  end loop;

  update public.royale_matches set state = v_st, updated_at = now()
   where id = m.id returning * into m;
  return m;
$t$, 'attack tail');
  execute v;

  ----------------------------------------------------------------------- ability
  v := pg_get_functiondef('public.cn_ability(uuid,text,text,text)'::regprocedure);
  v := cn_royale_patch(v, 'public.cn_ability(p_match uuid, p_side text, p_unit text, p_target text)',
                          'public.cn_ability_royale(p_match uuid, p_seat integer, p_unit text, p_target text)', 'ability head');
  v := cn_royale_common(v);
  v := cn_royale_patch(v, $a$'owner', p_side, 'by', p_unit, 'dmg', v_n);$a$,
                          $a$'owner', p_seat, 'by', p_unit, 'dmg', v_n);$a$, 'ability summon owner');
  v := cn_royale_cut(v, '  for u in select * from jsonb_array_elements(v_before_units) loop',
                        E'  update public.royale_matches\n     set state = v_st, updated_at = now()', '', 'ability win');
  execute v;

  ----------------------------------------------------------------------- defend
  v := pg_get_functiondef('public.cn_defend(uuid,text,text,text)'::regprocedure);
  v := cn_royale_patch(v, 'public.cn_defend(p_match uuid, p_side text, p_unit text, p_target text)',
                          'public.cn_defend_royale(p_match uuid, p_seat integer, p_unit text, p_target text)', 'defend head');
  v := cn_royale_common(v);
  v := cn_royale_patch(v, 'to_jsonb(p_side)', 'to_jsonb(p_seat)', 'defend by');
  execute v;

  ----------------------------------------------------------------------- throw
  v := pg_get_functiondef('public.cn_throw(uuid,text,text)'::regprocedure);
  v := cn_royale_patch(v, 'public.cn_throw(p_match uuid, p_side text, p_target text)',
                          'public.cn_throw_royale(p_match uuid, p_seat integer, p_target text)', 'throw head');
  v := cn_royale_common(v);
  v := cn_royale_patch(v, E'      v_win := cn_win_after_death(v_st, v_me);\n', '', 'throw win');
  v := cn_royale_patch(v, E'  if v_win is not null then return cn_finish(m, v_st, v_win); end if;\n', '', 'throw finish');
  execute v;

  ----------------------------------------------------------------------- army
  v := pg_get_functiondef('public.cn_army(jsonb,text,text[])'::regprocedure);
  v := cn_royale_patch(v, 'public.cn_army(p_state jsonb, p_side text, p_deck text[])',
                          'public.cn_royale_army(p_state jsonb, p_seat integer, p_deck text[])', 'army head');
  a := position(E'declare\n' in v);
  v := substr(v, 1, a + 7) || E'  p_side text := p_seat::text; v_zone int[] := cn_royale_zone(p_seat);\n' || substr(v, a + 8);
  v := cn_royale_cut(v, '  for i in 0 .. (v_w - 1) / 2 loop', E'  for i in 1 .. deck_size() loop', $t$
  if v_zone is null then raise exception 'no such seat %', p_seat; end if;
  for i in v_zone[1] .. v_zone[2] loop v_xs := v_xs || i; end loop;
  if v_zone[3] = 0 then
    for i in v_zone[3] .. v_zone[4] loop v_ys := v_ys || i; end loop;
  else
    for i in reverse v_zone[4] .. v_zone[3] loop v_ys := v_ys || i; end loop;
  end if;

$t$, 'army zone');
  v := cn_royale_patch(v, $a$'id', substr(p_side, 1, 1) || v_idx, 'owner', p_side,$a$,
                          $a$'id', 'r' || p_seat || 'u' || v_idx, 'owner', p_seat,$a$, 'army id');
  execute v;

  ----------------------------------------------------------------------- advance_turn
  v := pg_get_functiondef('public.advance_turn(uuid,text,boolean)'::regprocedure);
  v := cn_royale_patch(v, 'public.advance_turn(p_match uuid, p_note text, p_timeout boolean)',
                          'public.advance_turn_royale(p_match uuid, p_note text, p_timeout boolean DEFAULT false)', 'advance head');
  v := replace(v, 'RETURNS matches', 'RETURNS royale_matches');
  v := replace(v, 'm public.matches', 'm public.royale_matches');
  v := replace(v, 'from public.matches where id = p_match', 'from public.royale_matches where id = p_match');
  v := cn_royale_patch(v, E'  v_who text; v_next text; v_turn int; v_did boolean := false; v_n int;',
    E'  v_who int; v_next int; v_turn int; v_did boolean := false; v_n int;\n  v_seats int[]; v_tries int := 0; v_who_bot int; v_alive int[]; v_win_seat int; v_name text;', 'advance decl');
  -- Who acted, the AFK rule, who is next, and the per-turn reset: Battle Royale's
  -- own (seats rotate among those still in; two expired turns in a row with no
  -- action eliminates a seat -- 0051).
  v := cn_royale_cut(v, E'  v_who  := st->>\'turn\';', E'  v_obs_out := \'[]\'::jsonb;', $t$
  v_who  := coalesce((st->>'turn')::int, 0);
  v_turn := coalesce((st->>'turnNumber')::int, 1) + 1;

  select array_agg(seat order by seat) into v_seats
    from public.royale_players where match_id = p_match and not eliminated;
  if coalesce(array_length(v_seats, 1), 0) = 0 then return m; end if;

  select bot into v_who_bot from public.royale_players
   where match_id = p_match and seat = v_who;

  if v_who = any(v_seats) and v_who_bot is null then
    select (last_acted_turn = v_turn - 1) into v_did
      from public.royale_players where match_id = p_match and seat = v_who;
    v_did := coalesce(v_did, false);
    if p_timeout and not v_did then
      update public.royale_players set idle_streak = idle_streak + 1
       where match_id = p_match and seat = v_who returning idle_streak into v_n;
    else
      update public.royale_players set idle_streak = 0
       where match_id = p_match and seat = v_who returning idle_streak into v_n;
    end if;

    if p_timeout and coalesce(v_n, 0) >= 2 then
      st := jsonb_set(st, '{units}', coalesce((
        select jsonb_agg(q) from jsonb_array_elements(coalesce(st->'units', '[]'::jsonb)) q
         where (q->>'owner')::int <> v_who), '[]'::jsonb));
      select username into v_name from public.royale_players where match_id = p_match and seat = v_who;
      update public.royale_players set eliminated = true, eliminated_at = now()
       where match_id = p_match and seat = v_who;
      st := state_log(st, coalesce(v_name, 'Seat ' || v_who) || ' has forfeited by inactivity.');

      select array_agg(seat order by seat) into v_alive
        from public.royale_players where match_id = p_match and not eliminated;
      if coalesce(array_length(v_alive, 1), 0) <= 1 then
        v_win_seat := v_alive[1];
        if v_win_seat is not null then
          select username into v_name from public.royale_players where match_id = p_match and seat = v_win_seat;
          st := jsonb_set(st, '{winnerSeat}', to_jsonb(v_win_seat));
          st := state_log(st, coalesce(v_name, 'Seat ' || v_win_seat) || ' wins the battle royale.');
        end if;
        update public.royale_matches
           set state = st, status = 'finished', winner_seat = v_win_seat,
               turn_deadline = null, updated_at = now()
         where id = m.id returning * into m;
        return m;
      end if;
      v_seats := v_alive;
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
  for u in select * from jsonb_array_elements(coalesce(st->'units', '[]'::jsonb)) loop
    u := jsonb_set(u, '{moved}', 'false'::jsonb);
    u := jsonb_set(u, '{acted}', 'false'::jsonb);
    u := jsonb_set(u, '{spent}', 'false'::jsonb);
    if (u->>'defendedBy')::int = v_next then
      u := jsonb_set(u, '{defending}', 'false'::jsonb);
      u := jsonb_set(u, '{defendedBy}', 'null'::jsonb);
    end if;
    out_u := out_u || u;
  end loop;
  st := jsonb_set(st, '{units}', out_u);

$t$, 'advance turn head');
  v := cn_royale_patch(v, $a$e2->>'defendedBy' = v_next$a$, $a$(e2->>'defendedBy')::int = v_next$a$, 'advance obstacle guard');
  v := cn_royale_patch(v, $a$st->'mist'->v_who->>'t'$a$, $a$st->'mist'->(v_who::text)->>'t'$a$, 'advance mist read');
  v := cn_royale_patch(v, $a$array['mist', v_who, 't']$a$, $a$array['mist', v_who::text, 't']$a$, 'advance mist write');
  v := cn_royale_patch(v, $a$u->>'owner' = v_next$a$, $a$(u->>'owner')::int = v_next$a$, 'advance owner next');
  v := cn_royale_patch(v, $a$u->>'owner' = v_who$a$, $a$(u->>'owner')::int = v_who$a$, 'advance owner who');
  v := cn_royale_patch(v, $a$if v_next = 'host' then$a$, $a$if v_next = v_seats[1] then$a$, 'advance round wrap');
  v := cn_royale_patch(v, E'      st := jsonb_set(st, \'{winner}\', to_jsonb(\'draw\'::text));\n      st := state_log(st, \'Stalemate',
                          E'      st := state_log(st, \'Stalemate', 'advance stalemate log');
  v := cn_royale_patch(v, E'         set state = st, status = \'finished\', winner = \'draw\',\n             turn_deadline = null, updated_at = now()\n       where id = m.id returning * into m;\n      return m;',
                          E'         set state = st, status = \'finished\', winner_seat = null, draw = true,\n             turn_deadline = null, updated_at = now()\n       where id = m.id returning * into m;\n      return m;', 'advance stalemate end');
  v := cn_royale_cut(v, E'  st := jsonb_set(st, \'{active}\', \'null\'::jsonb);\n  st := jsonb_set(st, \'{turn}\'', E'end\n$function$', $t$
  -- Poison, burn and start/end-of-turn effects can take a crown: settle first.
  st := cn_royale_settle_state(p_match, st);
  select array_agg(seat order by seat) into v_alive
    from public.royale_players where match_id = p_match and not eliminated;
  if coalesce(array_length(v_alive, 1), 0) <= 1 then
    v_win_seat := v_alive[1];
    if v_win_seat is not null then
      select username into v_name from public.royale_players where match_id = p_match and seat = v_win_seat;
      st := jsonb_set(st, '{winnerSeat}', to_jsonb(v_win_seat));
      st := state_log(st, coalesce(v_name, 'Seat ' || v_win_seat) || ' wins the battle royale.');
    end if;
    update public.royale_matches
       set state = st, status = 'finished', winner_seat = v_win_seat,
           turn_deadline = null, updated_at = now()
     where id = m.id returning * into m;
    return m;
  end if;
  if not (v_next = any(v_alive)) then
    -- The seat about to act was knocked out by its own start-of-turn damage:
    -- the turn goes to the next seat still in.
    v_next := (select min(s) from unnest(v_alive) s where s > v_who);
    if v_next is null then v_next := v_alive[1]; end if;
  end if;

  st := jsonb_set(st, '{active}', 'null'::jsonb);
  st := jsonb_set(st, '{turn}', to_jsonb(v_next));
  st := jsonb_set(st, '{turnNumber}', to_jsonb(v_turn));
  if p_note is not null then st := state_log(st, p_note); end if;
  select username into v_name from public.royale_players where match_id = p_match and seat = v_next;
  st := state_log(st, 'Turn ' || v_turn || ' -- ' || coalesce(v_name, 'seat ' || v_next) || ' to act.');

  update public.royale_matches
     set state = st, turn_deadline = now() + interval '30 seconds', updated_at = now()
   where id = m.id returning * into m;
  return m;
$t$, 'advance tail');
  execute v;
  ----------------------------------------------------------------------- end_act
  v := pg_get_functiondef('public.cn_end_act(jsonb,text)'::regprocedure);
  v := cn_royale_patch(v, 'public.cn_end_act(p_st jsonb, p_unit text)',
                          'public.cn_end_act_royale(p_st jsonb, p_unit text)', 'end_act head');
  execute v;

  -- Only the public entry points (submit_*, royale_bot_step, force_timeout_royale)
  -- are callable from the API; the rule functions themselves are not.
  for r in select p.oid::regprocedure as sig from pg_proc p
            where p.pronamespace = 'public'::regnamespace
              and p.proname in ('cn_move_royale', 'cn_attack_royale', 'cn_ability_royale',
                                'cn_defend_royale', 'cn_throw_royale', 'cn_begin_act_royale',
                                'cn_end_act_royale', 'cn_royale_army', 'advance_turn_royale',
                                'cn_royale_settle_state', 'cn_royale_commit', 'cn_royale_gate',
                                'cn_royale_patch', 'cn_royale_cut', 'cn_royale_common',
                                'cn_derive_royale', 'cn_royale_ddl_watch') loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
  end loop;
end $gen$;

-- The 1v1 functions the generator reads. Changing any of these (in any
-- migration) regenerates Battle Royale's rules straight away.
create table if not exists public.royale_engine_log (
  id bigserial primary key,
  at timestamptz not null default now(),
  ok boolean not null,
  note text
);
alter table public.royale_engine_log enable row level security;

create or replace function public.cn_royale_ddl_watch()
returns event_trigger
language plpgsql security definer set search_path = public as $fn$
declare r record; v_hit text;
begin
  for r in select object_identity from pg_event_trigger_ddl_commands()
            where object_type = 'function' loop
    if r.object_identity ~ '^public\.(cn_move|cn_attack|cn_ability|cn_defend|cn_throw|cn_begin_act|cn_end_act|cn_army|advance_turn)\(' then
      v_hit := r.object_identity;
    end if;
  end loop;
  if v_hit is null then return; end if;
  begin
    perform public.cn_derive_royale();
    insert into public.royale_engine_log (ok, note) values (true, 'regenerated after ' || v_hit);
  exception when others then
    -- Never block the 1v1 change that triggered this. Battle Royale keeps its
    -- previous rules until the patch is updated.
    insert into public.royale_engine_log (ok, note)
      values (false, 'FAILED after ' || v_hit || ': ' || sqlerrm);
    raise warning 'Battle Royale rules were NOT regenerated after %: % (see royale_engine_log)', v_hit, sqlerrm;
  end;
end $fn$;

drop event trigger if exists cn_royale_follow_1v1;
create event trigger cn_royale_follow_1v1 on ddl_command_end
  when tag in ('CREATE FUNCTION', 'ALTER FUNCTION')
  execute function public.cn_royale_ddl_watch();

-- ---------------------------------------------------------------------------
-- The seat-facing entry points.
-- ---------------------------------------------------------------------------
-- One gate for all of them: the match exists and is running, the caller holds a
-- seat, it is that seat's turn, the clock has not run out (2 s of slack, as in
-- 1v1). p_mark records that the seat acted this turn (the AFK rule).
create or replace function public.cn_royale_gate(p_match uuid, p_clock boolean, p_mark boolean,
                                                 out m public.royale_matches, out v_seat int)
language plpgsql security definer set search_path = public as $fn$
begin
  select * into m from public.royale_matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'active' then raise exception 'match is not running'; end if;
  v_seat := royale_side_of(p_match);
  if v_seat is null then raise exception 'you are spectating this match'; end if;
  if coalesce((m.state->>'turn')::int, -1) <> v_seat then raise exception 'not your turn'; end if;
  if p_clock and now() > m.turn_deadline + interval '2 seconds' then
    raise exception 'your time ran out';
  end if;
  if p_mark then
    update public.royale_players set last_acted_turn = (m.state->>'turnNumber')::int
     where match_id = p_match and seat = v_seat;
  end if;
end $fn$;

create or replace function public.submit_royale_move(p_match uuid, p_unit text, p_x integer, p_y integer)
returns public.royale_matches
language plpgsql security definer set search_path = public as $fn$
declare v_seat int;
begin
  v_seat := (cn_royale_gate(p_match, true, true)).v_seat;
  perform cn_move_royale(p_match, v_seat, p_unit, p_x, p_y);
  return cn_royale_commit(p_match);
end $fn$;

create or replace function public.submit_royale_attack(p_match uuid, p_unit text, p_target text)
returns public.royale_matches
language plpgsql security definer set search_path = public as $fn$
declare v_seat int; m public.royale_matches;
begin
  v_seat := (cn_royale_gate(p_match, true, true)).v_seat;
  perform cn_attack_royale(p_match, v_seat, p_unit, p_target);
  m := cn_royale_commit(p_match);
  -- The exchange plays out on everybody's screen: it is not the mover's time.
  if m.status = 'active' and m.turn_deadline is not null then
    update public.royale_matches
       set turn_deadline = turn_deadline
             + (cn_cine_ms(m.state->'fx'->'swings') || ' milliseconds')::interval,
           state = m.state            -- keeps the state column in the change feed
     where id = m.id returning * into m;
  end if;
  return m;
end $fn$;

create or replace function public.submit_royale_ability(p_match uuid, p_unit text, p_target text)
returns public.royale_matches
language plpgsql security definer set search_path = public as $fn$
declare v_seat int;
begin
  v_seat := (cn_royale_gate(p_match, true, true)).v_seat;
  perform cn_ability_royale(p_match, v_seat, p_unit, p_target);
  return cn_royale_commit(p_match);
end $fn$;

create or replace function public.submit_royale_defend(p_match uuid, p_unit text, p_target text)
returns public.royale_matches
language plpgsql security definer set search_path = public as $fn$
declare v_seat int;
begin
  v_seat := (cn_royale_gate(p_match, true, true)).v_seat;
  perform cn_defend_royale(p_match, v_seat, p_unit, p_target);
  return cn_royale_commit(p_match);
end $fn$;

create or replace function public.submit_royale_wait(p_match uuid)
returns public.royale_matches
language plpgsql security definer set search_path = public as $fn$
declare m public.royale_matches; v_st jsonb; v_active text;
begin
  m := (cn_royale_gate(p_match, true, true)).m;
  v_st := m.state - 'undo';                     -- waiting commits to the move before it
  if cn_pending(v_st) is not null then raise exception 'a throw is pending'; end if;
  v_active := nullif(v_st->>'active', '');
  if v_active is null then return m; end if;
  v_st := cn_end_act_royale(v_st, v_active);
  update public.royale_matches set state = v_st, updated_at = now()
   where id = m.id returning * into m;
  return m;
end $fn$;

create or replace function public.submit_royale_end_turn(p_match uuid)
returns public.royale_matches
language plpgsql security definer set search_path = public as $fn$
declare m public.royale_matches;
begin
  m := (cn_royale_gate(p_match, false, true)).m;
  if cn_pending(m.state) is not null then raise exception 'a throw is pending'; end if;
  return advance_turn_royale(p_match, null, false);
end $fn$;

-- The tornado's decision belongs to whoever raised the tornado, on anyone's turn.
create or replace function public.submit_royale_throw(p_match uuid, p_target text)
returns public.royale_matches
language plpgsql security definer set search_path = public as $fn$
declare m public.royale_matches; v_seat int;
begin
  select * into m from public.royale_matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'active' then raise exception 'match is not running'; end if;
  v_seat := royale_side_of(p_match);
  if v_seat is null then raise exception 'you are spectating this match'; end if;
  if now() > m.turn_deadline + interval '2 seconds' then raise exception 'your time ran out'; end if;
  perform cn_throw_royale(p_match, v_seat, p_target);
  return cn_royale_commit(p_match);
end $fn$;

create or replace function public.submit_royale_undo_move(p_match uuid)
returns public.royale_matches
language plpgsql security definer set search_path = public as $fn$
declare
  m public.royale_matches; v_seat int; v_st jsonb; v_undo jsonb; v_unit text;
  v_orig_deadline timestamptz; v_name text;
begin
  select * into m from public.royale_matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'active' then raise exception 'match is not running'; end if;
  v_seat := royale_side_of(p_match);
  if v_seat is null then raise exception 'you are spectating this match'; end if;
  if coalesce((m.state->>'turn')::int, -1) <> v_seat then raise exception 'not your turn'; end if;
  if now() > m.turn_deadline + interval '2 seconds' then raise exception 'your time ran out'; end if;

  v_st := m.state;
  if cn_pending(v_st) is not null then raise exception 'a throw is pending'; end if;
  v_undo := v_st->'undo';
  if v_undo is null then raise exception 'nothing to undo'; end if;
  v_unit := v_undo->>'unit';
  if nullif(v_st->>'active', '') is distinct from v_unit then
    raise exception 'nothing to undo';
  end if;
  v_orig_deadline := m.turn_deadline;

  select u->>'name' into v_name
    from jsonb_array_elements(v_undo->'units') u where u->>'id' = v_unit;

  v_st := jsonb_set(v_st, '{units}', v_undo->'units');
  v_st := jsonb_set(v_st, '{obstacles}', v_undo->'obstacles');
  v_st := jsonb_set(v_st, '{active}', coalesce(v_undo->'active', 'null'::jsonb));
  v_st := jsonb_set(v_st, '{acts}', v_undo->'acts');
  v_st := v_st - 'undo';
  v_st := state_log(v_st, coalesce(v_name, 'The unit') || ' pulls back.');

  update public.royale_matches
     set state = v_st, turn_deadline = v_orig_deadline, updated_at = now()
   where id = m.id returning * into m;
  return m;
end $fn$;
revoke all on function public.submit_royale_throw(uuid, text) from public, anon;
revoke all on function public.submit_royale_undo_move(uuid) from public, anon;
grant execute on function public.submit_royale_throw(uuid, text) to authenticated;
grant execute on function public.submit_royale_undo_move(uuid) to authenticated;

-- A pending decision owns the clock, so an expired clock while one is open is the
-- DECISION expiring, not the turn (same rule as 1v1's force_timeout).
create or replace function public.force_timeout_royale(p_match uuid)
returns public.royale_matches
language plpgsql security definer set search_path = public as $fn$
declare m public.royale_matches; v_who int; v_name text; v_p jsonb;
begin
  select * into m from public.royale_matches where id = p_match;
  if m.id is null then raise exception 'no such match'; end if;
  if m.turn_deadline is null then return m; end if;
  if now() <= m.turn_deadline + interval '2 seconds' then return m; end if;
  if m.status <> 'active' then return m; end if;

  v_p := cn_pending(m.state);
  if v_p is not null then
    perform cn_throw_royale(p_match, (v_p->>'side')::int, null);
    return cn_royale_commit(p_match);
  end if;

  v_who := coalesce((m.state->>'turn')::int, -1);
  select username into v_name from public.royale_players
   where match_id = p_match and seat = v_who;
  return advance_turn_royale(p_match, coalesce(v_name, 'Seat ' || v_who) || ' ran out of time.', true);
end $fn$;

-- The bots: one activation per turn, settle eliminations after every action,
-- and close a decision they own. (Idempotent.)
do $b$
declare v text;
begin
  v := pg_get_functiondef('public.royale_bot_step(uuid,integer)'::regprocedure);
  if position('cn_royale_commit' in v) = 0 then
    v := public.cn_royale_patch(v, 'cn_acts_cap(st)', '1', 'bot cap');
    v := public.cn_royale_patch(v, 'return cn_move_royale(p_match, p_seat, v_bu, v_bx, v_by);',
      E'perform cn_move_royale(p_match, p_seat, v_bu, v_bx, v_by);\n      return cn_royale_commit(p_match);', 'bot move');
    v := public.cn_royale_patch(v, 'if v_bt is not null then return cn_attack_royale(p_match, p_seat, v_bu, v_bt); end if;',
      E'if v_bt is not null then\n    perform cn_attack_royale(p_match, p_seat, v_bu, v_bt);\n    return cn_royale_commit(p_match);\n  end if;', 'bot attack');
    v := public.cn_royale_patch(v, E'  st := m.state;\n',
      E'  st := m.state;\n  if cn_pending(st) is not null then\n    if (cn_pending(st)->>''side'')::int = p_seat then\n      perform cn_throw_royale(p_match, p_seat, null);\n      return cn_royale_commit(p_match);\n    end if;\n    return m;\n  end if;\n', 'bot pending');
    execute v;
  end if;
end $b$;

select public.cn_derive_royale();
