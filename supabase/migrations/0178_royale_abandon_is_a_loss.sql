-- 0178: Battle Royale gets the same abandonment rules 1v1 got in 0175-0177.
--
-- Jared: "Do all the same thing for battle royale."
--
-- What was wrong: leave_royale_match() on a live match only aged the leaver's
-- heartbeat -- their army stayed on the board, their turns kept coming round
-- and running out, and if every human walked away nothing ever ended the room.
-- Also nothing ran the turn clock unless somebody's tab was open.
--
-- Now:
--   * cn_royale_forfeit()   the one place a walk-out is resolved: the seat is
--                           eliminated, its army leaves the board, the turn
--                           moves on if it was theirs, and if that leaves one
--                           seat standing that seat wins. Works in deployment
--                           too (the seat counts as ready with no units, and if
--                           it was the last one everybody was waiting for the
--                           battle begins).
--   * leave_royale_match()  a deliberate exit from a live match forfeits the
--                           seat. A practice room with no other human is simply
--                           deleted.
--   * sweep_royale_matches()  drives expired turn clocks (so the existing
--                           two-missed-turns rule resolves a vanished player
--                           even if nobody has the game open), forfeits a seat
--                           that never readied and is gone, and ends a room with
--                           no human left in it or watching it.
--   * royale_link() / royale_going_away()  the "Reconnecting..." notice, same
--                           idea as match_link(): per human seat, seconds since
--                           the last heartbeat and whether they said goodbye.
--   * pg_cron               the existing 15-second job now sweeps both games.

alter table public.royale_players add column if not exists away_since timestamptz;

create or replace function public.touch_royale_match(p_match uuid)
returns void language plpgsql security definer set search_path = public as $fn$
begin
  update public.royale_players set seen_at = now(), away_since = null
   where match_id = p_match and user_id = auth.uid();
end $fn$;

create or replace function public.royale_going_away(p_match uuid)
returns void language sql security definer set search_path = public as $fn$
  update public.royale_players set away_since = now()
   where match_id = p_match and user_id = auth.uid();
$fn$;

create or replace function public.royale_link(p_match uuid)
returns table(seat integer, age numeric, away boolean)
language sql stable security definer set search_path = public as $fn$
  select p.seat, extract(epoch from (now() - p.seen_at))::numeric, p.away_since is not null
    from public.royale_players p
   where p.match_id = p_match and p.bot is null and p.user_id is not null and not p.eliminated;
$fn$;

revoke all on function public.royale_going_away(uuid) from public, anon;
revoke all on function public.royale_link(uuid) from public, anon;
grant execute on function public.royale_going_away(uuid) to authenticated;
grant execute on function public.royale_link(uuid) to authenticated;

-- Same as before, except: a null name skips the "is ready" log line (used when
-- a walk-out is what completes the ready check) and the opening turn is never
-- handed to an eliminated seat.
create or replace function public.cn_royale_mark_ready(p_match uuid, p_seat integer, p_name text)
returns public.royale_matches
language plpgsql security definer set search_path = public as $fn$
declare
  m public.royale_matches; v_st jsonb; v_all_ready boolean;
  rp record; v_seat_units jsonb; v_units jsonb; v_first int; v_first_name text;
begin
  select * into m from public.royale_matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'deploying' then raise exception 'deployment is over'; end if;

  update public.royale_players set ready = true
   where match_id = p_match and seat = p_seat;
  v_st := case when p_name is null then m.state else state_log(m.state, p_name || ' is ready.') end;

  select bool_and(ready) into v_all_ready from public.royale_players where match_id = p_match;
  if not coalesce(v_all_ready, false) then
    update public.royale_matches set state = v_st, updated_at = now()
     where id = m.id returning * into m;
    return m;
  end if;

  v_units := '[]'::jsonb;
  for rp in select * from public.royale_players where match_id = p_match order by seat loop
    select units into v_seat_units from public.royale_deploy
     where match_id = p_match and seat = rp.seat;
    v_units := v_units || coalesce(v_seat_units, '[]'::jsonb);
  end loop;
  v_st := jsonb_set(v_st, '{units}', v_units);
  v_st := v_st - 'pendingUnits';
  v_st := jsonb_set(v_st, '{phase}', '"battle"'::jsonb);

  select seat into v_first from public.royale_players
   where match_id = p_match and not eliminated order by random() limit 1;
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
end $fn$;

create or replace function public.cn_royale_forfeit(p_match uuid, p_seat integer, p_reason text)
returns public.royale_matches
language plpgsql security definer set search_path = public as $fn$
declare
  m public.royale_matches; st jsonb; v_name text; v_units jsonb;
  v_alive int[]; v_win int; v_wname text; v_was_turn boolean; v_all_ready boolean;
begin
  select * into m from public.royale_matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status not in ('deploying', 'active') then return m; end if;
  if not exists (
    select 1 from public.royale_players
     where match_id = p_match and seat = p_seat and not eliminated and bot is null) then
    return m;
  end if;

  select username into v_name from public.royale_players
   where match_id = p_match and seat = p_seat;
  st := m.state;
  v_was_turn := m.status = 'active' and coalesce((st->>'turn')::int, -1) = p_seat;

  -- Their army leaves the board with them.
  v_units := coalesce((
    select jsonb_agg(q) from jsonb_array_elements(coalesce(st->'units', '[]'::jsonb)) q
     where (q->>'owner')::int <> p_seat), '[]'::jsonb);
  st := jsonb_set(st, '{units}', v_units);
  update public.royale_players
     set eliminated = true, eliminated_at = now(), ready = true
   where match_id = p_match and seat = p_seat;
  if m.status = 'deploying' then
    update public.royale_deploy set units = '[]'::jsonb
     where match_id = p_match and seat = p_seat;
  end if;
  st := state_log(st, coalesce(v_name, 'Seat ' || p_seat) || ' left the match.');

  select array_agg(seat order by seat) into v_alive
    from public.royale_players where match_id = p_match and not eliminated;

  if coalesce(array_length(v_alive, 1), 0) <= 1 then
    v_win := v_alive[1];
    if v_win is not null then
      select username into v_wname from public.royale_players
       where match_id = p_match and seat = v_win;
      st := jsonb_set(st, '{winnerSeat}', to_jsonb(v_win));
      st := state_log(st, coalesce(v_wname, 'Seat ' || v_win) || ' wins the battle royale.');
    end if;
    update public.royale_matches
       set state = st, status = 'finished', winner_seat = v_win,
           turn_deadline = null, updated_at = now()
     where id = m.id returning * into m;
    return m;
  end if;

  update public.royale_matches set state = st, updated_at = now()
   where id = m.id returning * into m;

  if v_was_turn then
    -- The turn was theirs: hand it on (advance_turn_royale skips a seat that is
    -- no longer in the game, and resets the clock).
    m := advance_turn_royale(p_match, null, false);
  elsif m.status = 'deploying' then
    select bool_and(ready) into v_all_ready from public.royale_players where match_id = p_match;
    if coalesce(v_all_ready, false) then
      m := cn_royale_mark_ready(p_match, p_seat, null);
    end if;
  end if;
  return m;
end $fn$;
revoke all on function public.cn_royale_forfeit(uuid, integer, text) from public, anon, authenticated;

create or replace function public.leave_royale_match(p_match uuid)
returns void
language plpgsql security definer set search_path = public as $fn$
declare v_uid uuid := auth.uid(); v_status text; v_seat int;
begin
  select status into v_status from public.royale_matches where id = p_match;
  if v_status is null then return; end if;

  if v_status = 'waiting' then
    delete from public.royale_players where match_id = p_match and user_id = v_uid;
    if not exists (select 1 from public.royale_players where match_id = p_match) then
      delete from public.royale_matches where id = p_match;
    end if;
    return;
  end if;

  -- A practice room (bots and nobody else): nothing at stake, nobody to show a
  -- result to -- it goes with the player.
  if not exists (
    select 1 from public.royale_players
     where match_id = p_match and user_id is not null and user_id <> v_uid) then
    delete from public.royale_matches where id = p_match;
    return;
  end if;

  -- Stop counting this seat as present first, so the sweep can tell the room
  -- has emptied if this was the last human.
  update public.royale_players set seen_at = now() - interval '1 hour'
   where match_id = p_match and user_id = v_uid;

  -- Walking out of a live match is abandoning it: the seat is out.
  select seat into v_seat from public.royale_players
   where match_id = p_match and user_id = v_uid and not eliminated;
  if v_seat is not null and v_status in ('deploying', 'active') then
    perform cn_royale_forfeit(p_match, v_seat, 'leave');
  end if;
end $fn$;

create or replace function public.sweep_royale_matches()
returns void
language plpgsql security definer set search_path = public as $fn$
declare r record; st jsonb; v_alive int[]; v_win int; v_wname text;
begin
  -- Waiting rooms nobody is holding open (unchanged).
  delete from public.royale_matches m
   where m.status = 'waiting'
     and not exists (
       select 1 from public.royale_players p
        where p.match_id = m.id and p.seen_at > now() - presence_grace());

  -- Finished rooms nobody has touched for a while.
  delete from public.royale_matches m
   where m.status = 'finished' and m.updated_at < now() - interval '30 minutes'
     and not exists (
       select 1 from public.royale_players p
        where p.match_id = m.id and p.bot is null and p.seen_at > now() - presence_grace());

  -- A live room with no human still playing AND nobody of them still watching
  -- (an eliminated player keeps a heartbeat, and the bots can play on for
  -- them): nothing left to run, so end it.
  for r in
    select m.* from public.royale_matches m
     where m.status in ('deploying', 'active')
       and not exists (select 1 from public.royale_players p
                        where p.match_id = m.id and not p.eliminated and p.bot is null)
       and not exists (select 1 from public.royale_players p
                        where p.match_id = m.id and p.bot is null
                          and p.seen_at > now() - presence_grace())
  loop
    begin
      select array_agg(seat order by seat) into v_alive
        from public.royale_players where match_id = r.id and not eliminated;
      st := state_log(r.state, 'No players are left. The match is over.');
      v_win := case when coalesce(array_length(v_alive, 1), 0) = 1 then v_alive[1] end;
      if v_win is not null then
        select username into v_wname from public.royale_players where match_id = r.id and seat = v_win;
        st := jsonb_set(st, '{winnerSeat}', to_jsonb(v_win));
        st := state_log(st, coalesce(v_wname, 'Seat ' || v_win) || ' wins the battle royale.');
      end if;
      update public.royale_matches
         set state = st, status = 'finished', winner_seat = v_win,
             turn_deadline = null, updated_at = now()
       where id = r.id;
    exception when others then null;
    end;
  end loop;

  -- Deployment: a human who never pressed Ready and has gone quiet, well past
  -- the placement clock, is out -- otherwise everybody else waits forever.
  for r in
    select m.id, p.seat from public.royale_matches m
      join public.royale_players p on p.match_id = m.id
     where m.status = 'deploying'
       and m.turn_deadline < now() - interval '30 seconds'
       and not p.ready and not p.eliminated and p.bot is null
       and p.seen_at < now() - presence_grace()
  loop
    begin
      perform cn_royale_forfeit(r.id, r.seat, 'away');
    exception when others then null;
    end;
  end loop;

  -- The server-side turn clock: expire any turn whose deadline is well past,
  -- so the two-missed-turns rule resolves a vanished player even when nobody
  -- has the game open. force_timeout_royale re-checks the deadline itself.
  for r in
    select m.id from public.royale_matches m
     where m.status = 'active' and m.turn_deadline < now() - interval '3 seconds'
  loop
    begin
      perform force_timeout_royale(r.id);
    exception when others then null;
    end;
  end loop;
end $fn$;

do $cron$
begin
  perform cron.unschedule(jobid) from cron.job where jobname = 'cn-sweep-matches';
  perform cron.schedule('cn-sweep-matches', '15 seconds',
    'select public.sweep_matches(); select public.sweep_royale_matches()');
exception when others then
  raise notice 'pg_cron not available (%): relying on client-side sweeps', sqlerrm;
end $cron$;
