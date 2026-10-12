-- The deploy clock starts when the "Deploying phase" banner has gone, not when
-- the match row is created (Get Ready + VS intro + landing + banner used to
-- eat ~12s of it). The creators of a deploying match still stamp the usual
-- deadline, which is now just a fallback; the first player whose banner
-- finishes calls this and the clock restarts from the full deploy_seconds.
-- state.deployClock makes it once-only, so the second player's call (and any
-- reload) does nothing.
create or replace function public.start_deploy_clock(p_match uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare m public.matches;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null or m.status <> 'deploying' then return; end if;
  if side_of(m, auth.uid()) is null then return; end if;
  if coalesce((m.state->>'deployClock')::boolean, false) then return; end if;
  update public.matches
     set turn_deadline = now() + make_interval(secs => cn_deploy_seconds()),
         state = m.state || jsonb_build_object('deployClock', true),
         updated_at = now()
   where id = p_match;
end $$;
grant execute on function public.start_deploy_clock(uuid) to authenticated;
