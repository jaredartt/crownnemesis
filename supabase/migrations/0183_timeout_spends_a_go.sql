-- 0183: running the clock out spends ONE go, not the whole turn.
--
-- Jared: "You should be able to see one square get spent when the first 20 seconds
-- have passed, even if you didn't move."
--
-- Until now an expired clock ended the player's whole turn (advance_turn(..., true)),
-- which was fine while one clock covered the turn, but with 20 seconds per unit's go
-- (0182) the clock belongs to a GO:
--   * a unit is mid-go (it moved, hasn't struck) when its 20 s run out: that go ends
--     (the unit is spent), and if the turn still has a go left the next 20 s start;
--   * nobody has started a go: one activation is burnt (state.acts + 1 -- the pip
--     turns grey -- and cn_refresh_action_clock hands out the next 20 s);
--   * no go left -> the turn ends exactly as before (advance_turn with p_timeout, so
--     the two-turns-running AFK forfeit counts a turn in which nothing was done).
-- So an idle player loses a pip at 20 s and the turn at 40 s (opening turn: 20 s).
-- The slack before the server believes the clock is 1 s (was 2) so the pip drops
-- when the timer reads 0.

create or replace function public.force_timeout(p_match uuid)
 returns matches
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  m public.matches; st jsonb; u jsonb; v_out jsonb := '[]'::jsonb; v_name text;
  v_cap int; v_acts int; v_act text;
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

  v_name := case when m.state->>'turn' = 'host' then m.host_name else m.guest_name end;
  st     := m.state;
  v_cap  := cn_acts_cap(st);
  v_acts := coalesce((st->>'acts')::int, 0);
  v_act  := nullif(st->>'active', '');

  if v_act is not null then
    -- The unit in the middle of its go ran out of time: that was its go.
    for u in select * from jsonb_array_elements(st->'units') loop
      if u->>'id' = v_act then u := jsonb_set(u, '{spent}', 'true'::jsonb); end if;
      v_out := v_out || u;
    end loop;
    st := jsonb_set(jsonb_set(st, '{units}', v_out), '{active}', 'null'::jsonb);
    if v_acts < v_cap then
      st := state_log(st, v_name || ' ran out of time on that go.');
      update public.matches
         set state = st, turn_deadline = now() + make_interval(secs => cn_action_seconds()),
             updated_at = now()
       where id = m.id returning * into m;
      return m;
    end if;
  elsif v_acts + 1 < v_cap then
    -- Nobody started a go: burn one activation; the clock trigger deals the next 20 s.
    st := jsonb_set(st, '{acts}', to_jsonb(v_acts + 1));
    st := state_log(st, v_name || ' ran out of time -- a go is lost.');
    update public.matches set state = st, updated_at = now()
     where id = m.id returning * into m;
    return m;
  end if;

  return advance_turn(p_match, v_name || ' ran out of time.', true);
end $function$;
