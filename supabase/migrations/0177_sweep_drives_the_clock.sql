-- Jared: skipping two turns without acting is already a loss, so a player who
-- is disconnected / reconnecting simply loses on the existing AFK rule (two of
-- their own turns run out with no action -> advance_turn() forfeits them).
-- No separate presence timer (this supersedes 0175's 90-second heartbeat
-- forfeit in sweep_matches). What was missing is someone to run the clock when
-- NOBODY has the match open (force_timeout is otherwise only ever asked by a
-- client), so the sweep now does that: it expires any turn/deploy clock that
-- has run out. Deliberate leaving is still an immediate forfeit (leave_match).
create or replace function public.sweep_matches()
returns integer
language plpgsql security definer set search_path = public as $fn$
declare n int := 0; g int; r record;
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

  -- Live matches whose clock has run out: expire the turn exactly as a client
  -- would (force_timeout re-checks the deadline itself, so this is safe to run
  -- at any time and from anywhere).
  for r in
    select m.id, m.tournament_match_id, m.created_at from public.matches m
     where m.status in ('deploying', 'active') and not m.is_sim
       and m.turn_deadline is not null
       and m.turn_deadline < now() - interval '3 seconds'
  loop
    -- A tournament match nobody has entered yet is left alone: being slow to
    -- press Play is not being AFK.
    if r.tournament_match_id is not null and not exists (
         select 1 from public.match_presence p
          where p.match_id = r.id and p.seen_at > r.created_at + interval '5 seconds') then
      continue;
    end if;
    begin
      perform public.force_timeout(r.id);
      n := n + 1;
    exception when others then
      null;  -- one bad match must not stop the rest being swept
    end;
  end loop;

  return n;
end $fn$;

do $cron$
begin
  perform cron.unschedule(jobid) from cron.job where jobname = 'cn-sweep-matches';
  perform cron.schedule('cn-sweep-matches', '15 seconds', 'select public.sweep_matches()');
exception when others then
  raise notice 'pg_cron not available (%): relying on client-side sweeps', sqlerrm;
end $cron$;
