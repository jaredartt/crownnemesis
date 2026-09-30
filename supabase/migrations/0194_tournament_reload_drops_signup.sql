-- 0194: reloading or closing the game takes you off the tournament sign-up.
--
-- Jared: "If I reloaded the page or closed the game, I shouldn't be registered
-- in a tournament anymore." 0192 only flagged a goodbye and waited 12s for a
-- heartbeat to cancel it -- which a reload always sends, so a reload kept the
-- sign-up. Now the goodbye is final: it removes the caller's entry from any
-- OPEN tournament immediately (a running bracket is untouched -- leaving that
-- is a forfeit and has its own rules), and stops the countdown if the count
-- drops under three. The client also calls it once on every fresh page load
-- as a safety net for a goodbye that never arrived (keepalive can be dropped).

create or replace function public.tournament_going_away()
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is null then return; end if;
  delete from public.tournament_entries e
   where e.user_id = auth.uid()
     and e.tournament_id in (select id from public.tournaments where status = 'open');
  update public.tournaments t set locks_at = null
   where t.status = 'open' and t.locks_at is not null
     and (select count(*) from public.tournament_entries x
           where x.tournament_id = t.id and x.out_at is null) < 3;
end $$;
revoke all on function public.tournament_going_away() from public, anon;
grant execute on function public.tournament_going_away() to authenticated;
