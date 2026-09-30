-- "Reconnecting with opponent..." (Jared): the other player's screen needs to
-- know a player has dropped, reloaded or closed the tab -- without saying which.
--   * away_since  set by a best-effort beacon from a closing/reloading page and
--                 cleared by the next heartbeat, so the notice shows within
--                 seconds instead of after a missed heartbeat.
--   * match_link  what the clients poll: per seat, seconds since the last
--                 heartbeat (server clock, so no skew) and whether it said
--                 goodbye. Readable by anyone in the match, spectators too.
alter table public.match_presence add column if not exists away_since timestamptz;

create or replace function public.touch_match(p_match uuid)
returns void
language plpgsql security definer set search_path = public as $fn$
declare m public.matches; s text;
begin
  select * into m from public.matches where id = p_match;
  if m.id is null then return; end if;
  s := side_of(m, auth.uid());
  if s is null then return; end if;
  insert into public.match_presence (match_id, user_id, side, seen_at, away_since)
  values (p_match, auth.uid(), s, now(), null)
  on conflict (match_id, user_id) do update set seen_at = now(), away_since = null;
end $fn$;

create or replace function public.match_going_away(p_match uuid)
returns void
language sql security definer set search_path = public as $fn$
  update public.match_presence set away_since = now()
   where match_id = p_match and user_id = auth.uid();
$fn$;

create or replace function public.match_link(p_match uuid)
returns table (side text, age numeric, away boolean)
language sql stable security definer set search_path = public as $fn$
  select p.side, extract(epoch from (now() - p.seen_at))::numeric, p.away_since is not null
    from public.match_presence p
   where p.match_id = p_match;
$fn$;

revoke all on function public.match_going_away(uuid) from public, anon;
revoke all on function public.match_link(uuid) from public, anon;
grant execute on function public.match_going_away(uuid) to authenticated;
grant execute on function public.match_link(uuid) to authenticated;
