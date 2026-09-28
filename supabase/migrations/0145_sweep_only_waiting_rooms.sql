-- Jared: "Check again why I can't watch friends (or random real players)
-- that are having matches inside Watch section, please!"
--
-- Found something much bigger than a listing bug: `matches` and
-- `match_presence` are both completely EMPTY right now (0 rows), while
-- `match_results` -- the permanent history table -- still has 23 rows.
-- Live matches are not failing to show up in Watch. They are being
-- deleted outright, mid-game, by the sweep the Watch page itself runs.
--
-- sweep_matches() (0003) deletes ANY row in `matches` -- 'waiting',
-- 'deploying', 'active', even 'finished' -- the instant neither player
-- has sent a presence heartbeat in the last 45 seconds
-- (presence_grace()). Its own comment claims this "cannot hurt a live
-- game", on the assumption that a heartbeat every 10 seconds never
-- really stops while a match is live. That assumption doesn't hold: a
-- phone locking, a tab going to the background (browsers throttle or
-- fully pause JS timers there), a network blip -- any of those silences
-- BOTH players' heartbeats well past 45 seconds without the match being
-- abandoned at all. And Lobby.tsx's own Watch-page polling calls
-- sweep_matches() every 4 seconds for as long as that page is open --
-- so the very act of checking Watch for a friend's match can be the
-- thing that deletes it out from under them, mid-battle, no trace left
-- beyond match_results (which only exists for a match that had already
-- finished and been scored -- an active one just vanishes).
--
-- This schema already has the right tool for "a player has gone quiet
-- during a real match": the idle counter in advance_turn(), which
-- politely marks them away and eventually forfeits the match (through
-- finish_match(), preserving history) after they miss two turns in a
-- row. sweep_matches() bypassing all of that and just deleting the row
-- is both redundant with it and far more destructive.
--
-- Fix: sweep only ever removes 'waiting' rooms -- a room the host
-- opened that nobody ever joined, or that emptied out again before any
-- game began, which is the actual "abandoned room" this was built for
-- (see 0003's own header: "an abandoned one lived forever"). Once a
-- room reaches 'deploying' or later, there is a real game (and, for a
-- ranked or friend-LP match, a real rating swing) sitting in it, and no
-- amount of quiet is a reason to erase it out from under either player
-- or anyone trying to watch.
create or replace function public.sweep_matches()
 returns integer
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare n int;
begin
  with gone as (
    delete from public.matches m
     where m.status = 'waiting'
       and not exists (
         select 1 from public.match_presence p
          where p.match_id = m.id and p.seen_at > now() - presence_grace())
    returning 1)
  select count(*) into n from gone;
  return n;
end $function$;
