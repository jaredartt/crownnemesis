-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice.
-- ===========================================================================
--  0052 -- Bots in Battle Royale
--
--  Two entry points, per the developer's ask:
--   (a) a host in a Vs-Friends royale room can fill empty seats with bots
--       before starting (add_royale_bot / remove_royale_bot);
--   (b) a new "4-Player Battle Royale" option under the existing Vs Bots
--       menu, seating the caller against 1-3 bots at once
--       (create_royale_bot_match).
--
--  A bot seat is a royale_players row with user_id = null (already nullable
--  since 0048 -- no schema change needed there) and a new `bot int` column,
--  reusing the EXACT same difficulty encoding as matches.bot / BOT_LEVELS
--  (1 = CALM, 2 = SHARP, 3 = RUTHLESS, via the existing bot_name()).
--
--  royale_bot_step is the royale sibling of the 1v1 bot_step(): same
--  decision logic, copied line-for-line and generalised from the hardcoded
--  'guest' owner to an int seat, calling cn_move_royale/cn_attack_royale in
--  place of cn_move/cn_attack and advance_turn_royale in place of
--  advance_turn. bot_step plays exactly ONE action per call (confirmed by
--  reading its body and Match.tsx's driving useEffect, which re-fires on a
--  650ms delay keyed off match.updated_at) -- royale_bot_step does the same,
--  so the client drives it the same way, once per bot turn-tick, for
--  whichever seat currently holds the turn (only one seat ever has the turn
--  at a time, even with up to three bots seated, so there is no
--  simultaneous-bots problem to solve here).
--
--  bot_step itself never calls cn_defend/cn_ability -- it only ever
--  moves or attacks, falling through to advance_turn when nothing scores
--  above standing still. royale_bot_step is a faithful, deliberate port of
--  that same, narrower behaviour: a royale bot does not defend or use
--  abilities either, exactly matching what the 1v1 bot has always done.
--
--  A GENUINE PRE-EXISTING BUG, FOUND AND FIXED IN PASSING: 0051 added
--  advance_turn_royale(p_match, p_note, p_timeout boolean default false)
--  but never dropped the original 2-argument advance_turn_royale(p_match,
--  p_note) from 0048 -- Postgres treats those as two different overloaded
--  functions, not one replacing the other. submit_royale_end_turn (the
--  ordinary "End turn" button every human player uses) still calls the
--  2-argument overload, which has NONE of 0051's AFK-forfeit or stalemate
--  tracking. Only force_timeout_royale's 3-argument call ever exercised the
--  real one. Left alone, a mixed human/bot match would track staleRounds
--  and idle_streak inconsistently depending on whether a turn ended via a
--  human's button or a bot's step -- so the dead 2-argument overload is
--  dropped here and submit_royale_end_turn is repointed at the real one
--  (with p_timeout = false, i.e. a voluntary end, exactly as before).
--
--  advance_turn_royale also gets one small addition of its own: a bot seat
--  is now excluded from ever being AFK-forfeited by the clock, the same way
--  1v1's advance_turn already excludes `m.bot is not null and v_who =
--  'guest'`. Without it, a bot seat whose royale_bot_step call is ever
--  slightly slower than the 30-second turn clock could be forfeited by
--  force_timeout_royale for a delay that was never its "fault".
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Schema: a bot seat is user_id = null (already nullable) plus a level.
-- ---------------------------------------------------------------------------

alter table public.royale_players add column if not exists bot int;

-- ---------------------------------------------------------------------------
-- start_royale_match: a bot seat has no deck_of(user) to read (its user_id
-- is null) -- give it a fresh random kingdom instead, mirroring
-- create_bot_match's own random_deck() call for the 1v1 bot's army. Then,
-- since a bot's pending army is already fully placed by cn_royale_army
-- (every unit gets a real x/y the instant it is built) and a bot has no
-- auth.uid() to call set_royale_ready with, mark every bot seat ready the
-- moment deployment opens -- through the exact same fold-or-wait path a
-- human's Ready button uses (see cn_royale_mark_ready below).
-- ---------------------------------------------------------------------------

create or replace function public.start_royale_match(p_match uuid)
returns royale_matches language plpgsql security definer set search_path to 'public' as $$
declare
  m public.royale_matches; v_uid uuid := auth.uid(); v_st jsonb;
  rp record; v_deck text[]; v_army jsonb; v_pending jsonb := '{}'::jsonb; v_count int;
begin
  select * into m from public.royale_matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'waiting' then raise exception 'this match has already started'; end if;

  if not exists (
    select 1 from public.royale_players
     where match_id = p_match and seat = 0 and user_id = v_uid) then
    raise exception 'only the host can start the match';
  end if;

  select count(*) into v_count from public.royale_players where match_id = p_match;
  if v_count < 2 then raise exception 'wait for at least one more player'; end if;

  v_st := m.state;
  for rp in select * from public.royale_players where match_id = p_match order by seat loop
    v_deck := case when rp.bot is not null then random_deck() else deck_of(rp.user_id) end;
    v_army := cn_royale_army(v_st, rp.seat, v_deck);
    v_pending := v_pending || jsonb_build_object(rp.seat::text, v_army);
  end loop;

  v_st := jsonb_set(v_st, '{pendingUnits}', v_pending, true);
  v_st := jsonb_set(v_st, '{phase}', '"deploy"'::jsonb, true);
  v_st := state_log(v_st, 'Place your units, then press Ready.');

  update public.royale_matches
     set state = v_st, status = 'deploying',
         turn_deadline = now() + interval '90 seconds', updated_at = now()
   where id = m.id returning * into m;

  for rp in select * from public.royale_players
             where match_id = p_match and bot is not null order by seat loop
    m := cn_royale_mark_ready(p_match, rp.seat, rp.username);
  end loop;

  return m;
end
$$;

-- ---------------------------------------------------------------------------
-- cn_royale_mark_ready: the back half of set_royale_ready, extracted so a
-- bot seat can be marked ready the same way a human's Ready button does,
-- without a second, drifting copy of the fold-into-battle logic. Byte-for-
-- byte the same statements set_royale_ready already ran after finding its
-- caller's own seat -- only the "how do I know which seat" part moved out.
-- ---------------------------------------------------------------------------

create or replace function public.cn_royale_mark_ready(p_match uuid, p_seat int, p_name text)
returns royale_matches language plpgsql security definer set search_path to 'public' as $$
declare
  m public.royale_matches; v_st jsonb; v_all_ready boolean;
  rp record; v_units jsonb; v_first int; v_first_name text;
begin
  select * into m from public.royale_matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'deploying' then raise exception 'deployment is over'; end if;

  update public.royale_players set ready = true
   where match_id = p_match and seat = p_seat;
  v_st := state_log(m.state, p_name || ' is ready.');

  select bool_and(ready) into v_all_ready from public.royale_players where match_id = p_match;
  if not coalesce(v_all_ready, false) then
    update public.royale_matches set state = v_st, updated_at = now()
     where id = m.id returning * into m;
    return m;
  end if;

  v_units := '[]'::jsonb;
  for rp in select * from public.royale_players where match_id = p_match order by seat loop
    v_units := v_units || coalesce(v_st->'pendingUnits'->rp.seat::text, '[]'::jsonb);
  end loop;
  v_st := jsonb_set(v_st, '{units}', v_units);
  v_st := v_st - 'pendingUnits';
  v_st := jsonb_set(v_st, '{phase}', '"battle"'::jsonb);

  select seat into v_first from public.royale_players
   where match_id = p_match order by random() limit 1;
  select username into v_first_name from public.royale_players
   where match_id = p_match and seat = v_first;
  v_st := jsonb_set(v_st, '{turn}', to_jsonb(v_first));
  v_st := jsonb_set(v_st, '{turnNumber}', '1'::jsonb);
  v_st := state_log(v_st, 'Turn 1 -- ' || v_first_name || ' to act.');

  update public.royale_matches
     set state = v_st, status = 'active',
         turn_deadline = now() + interval '30 seconds', updated_at = now()
   where id = m.id returning * into m;
  return m;
end
$$;

-- set_royale_ready now just resolves "which seat is this" from auth.uid()
-- and delegates. Behaviour for a human caller is unchanged.
create or replace function public.set_royale_ready(p_match uuid)
returns royale_matches language plpgsql security definer set search_path to 'public' as $$
declare m public.royale_matches; v_seat int; v_name text;
begin
  select * into m from public.royale_matches where id = p_match;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'deploying' then raise exception 'deployment is over'; end if;

  select seat, username into v_seat, v_name from public.royale_players
   where match_id = p_match and user_id = auth.uid();
  if v_seat is null then raise exception 'you are not seated in this match'; end if;

  return cn_royale_mark_ready(p_match, v_seat, v_name);
end
$$;

-- ---------------------------------------------------------------------------
-- add_royale_bot / remove_royale_bot -- host-only (seat 0, same check
-- start_royale_match uses), only while the room is still 'waiting', only on
-- an empty (or, to remove, a bot) seat 1-3. A bot's username is bot_name()
-- -- the same word 1v1 already shows for CALM/SHARP/RUTHLESS.
-- ---------------------------------------------------------------------------

create or replace function public.add_royale_bot(p_match uuid, p_seat int, p_level int)
returns royale_matches language plpgsql security definer set search_path to 'public' as $$
declare
  m public.royale_matches; v_uid uuid := auth.uid();
  v_lvl int := greatest(1, least(3, coalesce(p_level, 2)));
  v_name text; v_st jsonb;
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

  v_name := bot_name(v_lvl);
  insert into public.royale_players (match_id, seat, user_id, username, avatar, bot)
  values (p_match, p_seat, null, v_name, null, v_lvl);

  v_st := state_log(m.state, v_name || ' joins the arena.');
  update public.royale_matches set state = v_st, updated_at = now()
   where id = m.id returning * into m;
  return m;
end
$$;

create or replace function public.remove_royale_bot(p_match uuid, p_seat int)
returns royale_matches language plpgsql security definer set search_path to 'public' as $$
declare m public.royale_matches; v_uid uuid := auth.uid(); v_name text; v_st jsonb;
begin
  select * into m from public.royale_matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'waiting' then raise exception 'you can only remove a bot before the match starts'; end if;

  if not exists (
    select 1 from public.royale_players
     where match_id = p_match and seat = 0 and user_id = v_uid) then
    raise exception 'only the host can remove a bot';
  end if;

  select username into v_name from public.royale_players
   where match_id = p_match and seat = p_seat and bot is not null;
  if v_name is null then raise exception 'that seat is not a bot'; end if;

  delete from public.royale_players where match_id = p_match and seat = p_seat;

  v_st := state_log(m.state, v_name || ' leaves the arena.');
  update public.royale_matches set state = v_st, updated_at = now()
   where id = m.id returning * into m;
  return m;
end
$$;

-- ---------------------------------------------------------------------------
-- create_royale_bot_match -- the Vs Bots entry point. Seats the caller at
-- seat 0 (via the existing create_royale_match()), fills seats 1..N with
-- bots at the given levels (N = array_length(p_levels), 1-3 -- the caller's
-- choice, never forced to exactly three), and starts the match the same way
-- the host's own "Start match" button does.
-- ---------------------------------------------------------------------------

create or replace function public.create_royale_bot_match(p_levels int[])
returns royale_matches language plpgsql security definer set search_path to 'public' as $$
declare m public.royale_matches; v_n int := coalesce(array_length(p_levels, 1), 0); i int;
begin
  if v_n < 1 or v_n > 3 then
    raise exception 'choose between one and three bot opponents';
  end if;

  m := create_royale_match();

  for i in 1 .. v_n loop
    m := add_royale_bot(m.id, i, p_levels[i]);
  end loop;

  m := start_royale_match(m.id);
  return m;
end
$$;

-- ---------------------------------------------------------------------------
-- royale_bot_step -- direct port of bot_step's decision logic (fetched
-- fresh from production immediately before writing this), 'guest' owner
-- generalised to an int seat, cn_move/cn_attack -> cn_move_royale/
-- cn_attack_royale, advance_turn -> advance_turn_royale. Plays exactly one
-- action per call, same as bot_step -- the client drives it on the same
-- delay/poll idiom Match.tsx already uses for the 1v1 bot.
-- ---------------------------------------------------------------------------

create or replace function public.royale_bot_step(p_match uuid, p_seat integer)
returns royale_matches
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  m public.royale_matches; st jsonb; v_lvl int; v_noise numeric;
  u jsonb; t jsonb;
  v_tiles text[]; v_tile text; vx int; vy int; v_first boolean;
  v_best numeric := 0; v_bu text; v_bx int; v_by int; v_bt text;
  v_fb numeric := -1e9; v_fu text; v_fbx int; v_fby int; v_ft text;
  v_pos numeric; v_base numeric; v_act numeric; v_step_s numeric;
  v_d int; v_dmg numeric; v_ctr numeric; v_near int; v_thr int;
  v_answers boolean; v_parry boolean;
begin
  select * into m from public.royale_matches where id = p_match for update;
  if m.id is null then return m; end if;
  if m.status <> 'active' then return m; end if;
  if coalesce((m.state->>'turn')::int, -1) <> p_seat then return m; end if;

  select bot into v_lvl from public.royale_players
   where match_id = p_match and seat = p_seat and not eliminated;
  if v_lvl is null then return m; end if;

  st := m.state;

  for u in select * from jsonb_array_elements(st->'units') loop
    continue when (u->>'owner')::int <> p_seat;
    continue when (u->>'moved')::boolean and (u->>'acted')::boolean;
    continue when coalesce((u->>'spent')::boolean, false);
    continue when coalesce((st->>'acts')::int, 0) >= cn_acts_cap(st)
              and nullif(st->>'active', '') is distinct from u->>'id';

    v_tiles := array[(u->>'x') || ',' || (u->>'y')];
    if not (u->>'moved')::boolean then
      v_tiles := v_tiles || cn_reach(st, u);
    end if;
    v_first := true;

    foreach v_tile in array v_tiles loop
      vx := split_part(v_tile, ',', 1)::int;
      vy := split_part(v_tile, ',', 2)::int;

      v_near := 99; v_thr := 0;
      for t in select * from jsonb_array_elements(st->'units') loop
        continue when (t->>'owner')::int = p_seat;
        v_d := cn_cheb(vx, vy, (t->>'x')::int, (t->>'y')::int);
        v_near := least(v_near, v_d);
        if v_d <= (t->>'mov')::int + (t->>'rmax')::int then v_thr := v_thr + 1; end if;
      end loop;
      v_pos := - abs(v_near - (u->>'rmax')::int) * 5.0 - v_near * 2.0;

      if v_first then v_base := v_pos; v_first := false; end if;

      if vx <> (u->>'x')::int or vy <> (u->>'y')::int then
        v_noise := random() * (case v_lvl when 1 then 220 when 2 then 90 else 15 end);
        v_step_s := v_pos - v_base + v_noise;
        if v_lvl >= 3 then v_step_s := v_step_s - v_thr * 4.0; end if;
        if v_step_s > v_best then
          v_best := v_step_s;
          v_bu := u->>'id'; v_bx := vx; v_by := vy; v_bt := null;
        end if;
        if v_step_s > v_fb then
          v_fb := v_step_s;
          v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := null;
        end if;
      end if;

      continue when (u->>'acted')::boolean;

      for t in select * from jsonb_array_elements(st->'units') loop
        continue when t->>'id' = u->>'id';
        v_d := cn_cheb(vx, vy, (t->>'x')::int, (t->>'y')::int);
        continue when v_d < (u->>'rmin')::int or v_d > (u->>'rmax')::int;
        continue when not cn_los_clear(st, vx, vy, (t->>'x')::int, (t->>'y')::int);

        v_dmg := ((u->>'dmin')::int + (u->>'dmax')::int) / 2.0;

        if (t->>'owner')::int = p_seat then
          continue when not (u->>'heals')::boolean;
          v_act := case when (t->>'maxHp')::int - (t->>'hp')::int <= 0 then -150
                        else least(v_dmg, (t->>'maxHp')::int - (t->>'hp')::int) * 9.0 end;
        else
          v_answers := not coalesce((u->>'sneaks')::boolean, false)
                       and v_d >= (t->>'crmin')::int and v_d <= (t->>'crmax')::int;
          v_parry := v_answers and coalesce((t->>'parries')::boolean, false);

          v_act := least(v_dmg, (t->>'hp')::int) * 10.0;
          if v_dmg >= (t->>'hp')::int then
            v_act := v_act + 400 + (t->>'maxHp')::int;
          elsif (u->>'burns')::boolean and not (t->>'burned')::boolean then
            v_act := v_act + 25;
          end if;

          if v_answers and (v_parry or v_dmg < (t->>'hp')::int) then
            v_ctr := ((t->>'dmin')::int + (t->>'dmax')::int) / 2.0;
            v_act := v_act - v_ctr * (case v_lvl when 1 then 3.0 else 8.0 end);
            if v_ctr >= (u->>'hp')::int then
              v_act := v_act - 500 - (u->>'maxHp')::int
                       - case when v_parry then 400 + (t->>'maxHp')::int else 0 end;
            end if;
          end if;
        end if;

        v_noise := random() * (case v_lvl when 1 then 220 when 2 then 90 else 15 end);
        if v_pos + v_act - v_base + v_noise > v_best then
          v_best := v_pos + v_act - v_base + v_noise;
          v_bu := u->>'id'; v_bx := vx; v_by := vy; v_bt := t->>'id';
        end if;
        if v_pos + v_act - v_base + v_noise > v_fb then
          v_fb := v_pos + v_act - v_base + v_noise;
          v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := t->>'id';
        end if;
      end loop;
    end loop;
  end loop;

  if v_bu is null and v_fu is not null then
    v_bu := v_fu; v_bx := v_fbx; v_by := v_fby; v_bt := v_ft;
  end if;
  if v_bu is null then return advance_turn_royale(p_match, null, false); end if;

  for u in select * from jsonb_array_elements(st->'units') loop
    if u->>'id' = v_bu and ((u->>'x')::int <> v_bx or (u->>'y')::int <> v_by) then
      return cn_move_royale(p_match, p_seat, v_bu, v_bx, v_by);
    end if;
  end loop;

  if v_bt is not null then return cn_attack_royale(p_match, p_seat, v_bu, v_bt); end if;
  return advance_turn_royale(p_match, null, false);
end
$function$;

-- ---------------------------------------------------------------------------
-- advance_turn_royale: exclude a bot seat from ever being AFK-forfeited by
-- the clock, mirroring 1v1's own `not (m.bot is not null and v_who =
-- 'guest')` guard in advance_turn. Fetched fresh (the live 3-argument
-- version 0051 added) and spliced with exactly one extra declared variable
-- and one extra condition on the existing `if v_who = any(v_seats) then`
-- line -- nothing else in the function's body is touched.
-- ---------------------------------------------------------------------------

create or replace function public.advance_turn_royale(p_match uuid, p_note text, p_timeout boolean default false)
returns royale_matches
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  m public.royale_matches; st jsonb; u jsonb; out_u jsonb := '[]'::jsonb;
  v_who int; v_next int; v_turn int; v_seats int[]; v_tries int := 0; v_name text;
  v_cur_turn int; v_did boolean; v_idle int; v_seat_name text;
  v_alive_seats int[]; v_win_seat int;
  -- 0052: a bot seat is never blamed for the clock running out on it.
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

  -- ===== 0051: AFK FORFEIT ===================================================
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
  -- ===== end 0051 AFK forfeit ================================================

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
    if (u->>'owner')::int = v_next then
      u := jsonb_set(u, '{defending}', 'false'::jsonb);
    end if;
    out_u := out_u || u;
  end loop;
  st := jsonb_set(st, '{units}', out_u);

  st := jsonb_set(st, '{acts}', '0'::jsonb);

  -- ===== 0051: STALEMATE =====================================================
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
  -- ===== end 0051 stalemate ==================================================

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

-- Drop the dead 2-argument overload (see the header note above) now that
-- nothing calls it -- and repoint submit_royale_end_turn at the real one.
drop function if exists public.advance_turn_royale(uuid, text);

create or replace function public.submit_royale_end_turn(p_match uuid)
returns royale_matches language plpgsql security definer set search_path to 'public' as $$
declare m public.royale_matches; v_seat int;
begin
  select * into m from public.royale_matches where id = p_match;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'active' then raise exception 'match is not running'; end if;
  v_seat := royale_side_of(p_match);
  if v_seat is null then raise exception 'you are spectating this match'; end if;
  if coalesce((m.state->>'turn')::int, -1) <> v_seat then raise exception 'not your turn'; end if;
  update public.royale_players set last_acted_turn = (m.state->>'turnNumber')::int
   where match_id = p_match and seat = v_seat;
  return advance_turn_royale(p_match, null, false);
end
$$;
