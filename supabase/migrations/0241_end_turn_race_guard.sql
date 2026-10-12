-- 0241: turns no longer get skipped.
--
-- end_turn read the match WITHOUT a lock, checked "is it my turn?" on that stale
-- copy, and only then asked advance_turn (which locks) to flip the turn. Two
-- end-turn calls that overlapped -- the client auto-end firing together with a
-- click, a double click, or an auto-end landing as the clock expired
-- (force_timeout) -- both passed the check and the second ended the OTHER
-- player's turn too: "Turn 11 -- A to act." straight into "Turn 12 -- B to act."
--
-- Now end_turn(match, turn) locks the row first, and when the caller says which
-- turn it meant to end (state.turnNumber) a call for a turn that is already over
-- is a no-op. end_turn(match) keeps working for old clients (now locked, so a
-- late duplicate gets "not your turn"). force_timeout_royale also locks first.
create or replace function public.end_turn(p_match uuid, p_turn int)
returns matches language plpgsql security definer set search_path = public as $$
declare m public.matches; side text;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'active' then raise exception 'match is not running'; end if;
  side := side_of(m, auth.uid());
  if side is null then raise exception 'you are spectating this match'; end if;
  if p_turn is not null and coalesce((m.state->>'turnNumber')::int, 1) <> p_turn then
    return m;
  end if;
  if m.state->>'turn' <> side then raise exception 'not your turn'; end if;
  if cn_pending(m.state) is not null then raise exception 'a throw is pending'; end if;
  return advance_turn(p_match, null);
end $$;

create or replace function public.end_turn(p_match uuid)
returns matches language sql security definer set search_path = public as $$
  select * from public.end_turn(p_match, null::int)
$$;
grant execute on function public.end_turn(uuid, int) to authenticated;

-- force_timeout_royale: identical to before except `for update` on the first select.
