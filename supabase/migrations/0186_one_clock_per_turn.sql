-- 0186: ONE 30-second clock per turn -- nothing reloads it.
--
-- Jared: "Each player has 30 seconds for each turn. It's impossible that the 30
-- seconds can be reloaded somehow. It's 30 seconds." (After 0163/0182/0183 made the
-- clock per GO, moving -- even moving and cancelling -- dealt a fresh clock.)
--
--   * the turn's clock is dealt exactly once, when the turn starts (advance_turn,
--     advance_turn_royale, cn_set_ready, cn_royale_mark_ready), from
--     cn_action_seconds() = 30;
--   * cn_hold_turn_clock (BEFORE UPDATE, matches + royale_matches) makes that a rule
--     of the database rather than a habit of the functions: inside one turn the
--     deadline can only stay or move earlier. That also cancels the small
--     animation-time nudges cn_attack/cn_ability used to add. The one deliberate
--     exception is a pending tornado throw, which pauses and then resumes the SAME
--     remaining time (cn_move parks it, cn_throw restores it);
--   * running the clock out ends the whole turn again (force_timeout -> advance_turn
--     with p_timeout, so the two-turns-idle AFK rule still counts a turn with no
--     action) -- the go-by-go expiry of 0183 is gone.

drop trigger if exists matches_refresh_action_clock on public.matches;
drop function if exists public.cn_refresh_action_clock();

create or replace function public.cn_hold_turn_clock() returns trigger
language plpgsql set search_path = public as $$
begin
  if old.status = 'active' and new.status = 'active'
     and old.turn_deadline is not null and new.turn_deadline is not null
     and new.turn_deadline > old.turn_deadline
     and old.state->>'turn' is not distinct from new.state->>'turn'
     and old.state->>'turnNumber' is not distinct from new.state->>'turnNumber'
     and public.cn_pending(old.state) is null
     and public.cn_pending(new.state) is null
  then
    new.turn_deadline := old.turn_deadline;
  end if;
  return new;
end $$;

drop trigger if exists matches_hold_turn_clock on public.matches;
create trigger matches_hold_turn_clock before update on public.matches
  for each row execute function public.cn_hold_turn_clock();
drop trigger if exists royale_matches_hold_turn_clock on public.royale_matches;
create trigger royale_matches_hold_turn_clock before update on public.royale_matches
  for each row execute function public.cn_hold_turn_clock();

create or replace function public.force_timeout(p_match uuid)
 returns matches
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare m public.matches; v_loser text;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.turn_deadline is null then return m; end if;
  if now() <= m.turn_deadline + interval '1 second' then return m; end if;

  if m.status = 'deploying' then return cn_set_ready(p_match, null, true); end if;
  if m.status <> 'active' then return m; end if;

  -- A pending decision owns the clock while it is open, so an expired clock
  -- here is the DECISION expiring and not the turn (default: nothing).
  if cn_pending(m.state) is not null then
    return cn_throw(p_match, cn_pending(m.state)->>'side', null);
  end if;

  v_loser := case when m.state->>'turn' = 'host' then m.host_name else m.guest_name end;
  return advance_turn(p_match, v_loser || ' ran out of time.', true);
end $function$;
