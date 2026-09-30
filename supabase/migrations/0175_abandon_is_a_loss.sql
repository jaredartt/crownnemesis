-- 0175: any kind of abandonment is a loss.
--
-- Jared: "I abandoned a match but the match continued running instead of
-- marking that match as a loss to me. The opponent should see a victory screen,
-- the same one that's already in use... please make it so that any type of
-- abandonment counts as a loss, otherwise the match/room will be running
-- forever."
--
-- What was wrong: leave_match() only dropped the leaver's presence row (and
-- deleted the room if that emptied it), and sweep_matches() only ever swept
-- WAITING rooms. So a player who walked out of a live match -- or closed the
-- tab -- left the other one playing against nobody, and the row itself stayed
-- 'deploying'/'active' forever.
--
-- Now:
--   * cn_forfeit()     the one place an abandonment is resolved: the leaver
--                      loses, the other side wins, rated exactly like a resign
--                      (finish_match on ranked / LP-enabled matches, reason
--                      'abandon'), state.forfeitedBy set so the results screen
--                      can say who left.
--   * leave_match()    a deliberate exit from a live match forfeits it.
--   * sweep_matches()  also forfeits a live match whose player has not sent a
--                      heartbeat for abandon_grace() (closed tab, dropped
--                      connection, crashed browser). A practice game against a
--                      bot has nothing at stake, so it is just cleaned up
--                      (after a longer idle) instead of being rated.
--   * pg_cron          calls sweep_matches() every 30 seconds, so this holds
--                      even when nobody at all has the game open.

-- Longer than presence_grace() (45s, which decides whether a WAITING room is
-- empty): a backgrounded tab throttles its timers, and forfeiting a player
-- who merely switched tabs would be a worse bug than the one being fixed.
create or replace function public.abandon_grace()
returns interval language sql immutable as $$ select interval '90 seconds' $$;

create or replace function public.cn_forfeit(p_match uuid, p_side text, p_reason text)
returns public.matches
language plpgsql security definer set search_path = public as $fn$
declare m public.matches; v_win text; v_st jsonb; v_name text; v_winner_name text;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status not in ('deploying', 'active') then return m; end if;
  if p_side not in ('host', 'guest') then raise exception 'bad side'; end if;

  v_win := case when p_side = 'host' then 'guest' else 'host' end;
  if m.ranked or (m.bot is null and cn_friend_tournament_lp_enabled()) then
    perform finish_match(m.id, v_win, p_reason);
  end if;

  v_name := case when p_side = 'host' then m.host_name else m.guest_name end;
  v_winner_name := case when v_win = 'host' then m.host_name else m.guest_name end;
  v_st := state_log(m.state, v_name || ' left the match. ' || v_winner_name || ' wins.');
  v_st := jsonb_set(v_st, '{winner}', to_jsonb(v_win));
  v_st := jsonb_set(v_st, '{forfeitedBy}', to_jsonb(p_side));
  -- Tells the results screen this was somebody leaving, not the AFK rule
  -- (which also sets forfeitedBy, and has its own wording).
  v_st := jsonb_set(v_st, '{forfeitReason}', to_jsonb('abandon'::text));

  update public.matches
     set state = v_st, status = 'finished', winner = v_win,
         turn_deadline = null, updated_at = now()
   where id = m.id returning * into m;
  return m;
end $fn$;
revoke all on function public.cn_forfeit(uuid, text, text) from public, anon, authenticated;

create or replace function public.leave_match(p_match uuid)
returns void
language plpgsql security definer set search_path = public as $fn$
declare m public.matches; v_side text;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null then return; end if;

  v_side := side_of(m, auth.uid());
  -- Walking out of a live match is abandoning it. (A practice game against a
  -- bot has no rating and nobody to show a result to; it just falls through to
  -- the "empty room" cleanup below, as it always did.)
  if v_side is not null and m.status in ('deploying', 'active')
     and (m.bot is null or m.ranked) then
    perform cn_forfeit(m.id, v_side, 'abandon');
  end if;

  delete from public.match_presence
   where match_id = p_match and user_id = auth.uid();

  -- Never delete a match that has JUST finished: the other player (and any
  -- spectators) still have to see the result screen. The room goes when the
  -- last of them leaves, or is cleaned up later.
  delete from public.matches mm
   where mm.id = p_match
     and (mm.status <> 'finished' or mm.updated_at < now() - interval '5 minutes')
     and not exists (
       select 1 from public.match_presence p
        where p.match_id = mm.id and p.seen_at > now() - presence_grace());
end $fn$;

create or replace function public.sweep_matches()
returns integer
language plpgsql security definer set search_path = public as $fn$
declare n int := 0; g int; r record; v_h timestamptz; v_g timestamptz;
  v_hgone boolean; v_ggone boolean; v_side text; v_ten interval := interval '10 minutes';
begin
  -- Waiting rooms nobody is holding open (unchanged).
  with gone as (
    delete from public.matches m
     where m.status = 'waiting'
       and not exists (
         select 1 from public.match_presence p
          where p.match_id = m.id and p.seen_at > now() - presence_grace())
    returning 1)
  select count(*) into g from gone;
  n := n + g;

  -- 0175: live matches somebody has walked away from without saying so.
  for r in
    select m.* from public.matches m
     where m.status in ('deploying', 'active') and not m.is_sim
  loop
    select max(p.seen_at) into v_h from public.match_presence p
     where p.match_id = r.id and p.user_id = r.host_id;
    v_h := coalesce(v_h, r.created_at);
    -- A tournament match is spawned for two players who may still be on the
    -- bracket page: until somebody has actually shown up (their presence row
    -- is still the one written at spawn time) they get ten minutes, not
    -- ninety seconds -- being slow to press Play is not abandoning.
    v_hgone := v_h < now() - case
      when r.tournament_match_id is not null and v_h <= r.created_at + interval '5 seconds'
      then v_ten else abandon_grace() end;

    if r.guest_id is null then
      -- Against a bot: only the host can leave.
      if v_hgone then
        if r.ranked then
          perform cn_forfeit(r.id, 'host', 'abandon'); n := n + 1;
        elsif v_h < now() - interval '30 minutes' then
          -- Practice: nothing at stake, just stop it lingering forever.
          delete from public.matches where id = r.id; n := n + 1;
        end if;
      end if;
      continue;
    end if;

    select max(p.seen_at) into v_g from public.match_presence p
     where p.match_id = r.id and p.user_id = r.guest_id;
    v_g := coalesce(v_g, r.created_at);
    v_ggone := v_g < now() - case
      when r.tournament_match_id is not null and v_g <= r.created_at + interval '5 seconds'
      then v_ten else abandon_grace() end;

    if v_hgone and v_ggone then
      -- Both gone: whoever went quiet first loses (a tie goes against the guest).
      v_side := case when v_h < v_g then 'host' else 'guest' end;
    elsif v_hgone then v_side := 'host';
    elsif v_ggone then v_side := 'guest';
    else continue;
    end if;
    perform cn_forfeit(r.id, v_side, 'abandon'); n := n + 1;
  end loop;

  return n;
end $fn$;

-- The server-side clock behind all of the above: sweep every 30 seconds, so a
-- player who vanished is dealt with even if nobody at all has the game open.
-- (Clients also call sweep_matches() as a fast path, from the Watch list and
-- from any open match.) Guarded so the migration still applies on a database
-- without pg_cron.
do $cron$
begin
  create extension if not exists pg_cron with schema pg_catalog;
  perform cron.unschedule(jobid) from cron.job where jobname = 'cn-sweep-matches';
  perform cron.schedule('cn-sweep-matches', '30 seconds', 'select public.sweep_matches()');
exception when others then
  raise notice 'pg_cron not available (%): relying on client-side sweeps', sqlerrm;
end $cron$;
