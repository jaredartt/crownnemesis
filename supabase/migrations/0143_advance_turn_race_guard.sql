-- Jared: "If I reload the page I lose against a friend but the match
-- continues for him, so I lose points but he continues playing like
-- waiting for my turn??"
--
-- Dug into an actual match this caused (code 5SN9V, 2026-09-25). The log
-- ended with the SAME line twice:
--   "jaredartt has forfeited by inactivity."
--   "jaredartt has forfeited by inactivity."
-- and state.idle.guest was left at 3, even though the forfeit rule fires
-- at 2 missed turns in a row -- it should never be able to reach 3.
--
-- Root cause: advance_turn() is called by whichever client notices the
-- turn clock has run out (force_timeout(), from either player's browser,
-- or a spectator's), and by end_turn()/bot_step(). Every one of those
-- callers checks `status = 'active'` with a plain, lock-free SELECT
-- before calling advance_turn -- classic check-then-act. If two clients
-- both notice the same expired deadline at the same moment (exactly what
-- happens when your own browser reconnects after a reload and immediately
-- checks the clock, at the same time the still-open friend on the other
-- side is independently doing the same), BOTH pass that check while the
-- match is still 'active', and both go on to call advance_turn.
--
-- advance_turn() itself takes a real row lock (`for update`), so the two
-- calls don't corrupt anything -- but it never re-checked status once it
-- had that lock. So the first call runs the forfeit branch, marks the
-- match finished, and (since this was a friend match with the LP toggle
-- on) charges the rating change through finish_match(). The SECOND call
-- then unblocks, sees the row finish_match() itself now guards against
-- reprocessing (`if m.status = 'finished' then return`), so no LP was
-- double-charged -- but advance_turn() has no such guard, so it reran the
-- whole forfeit branch a second time anyway: a second identical log line,
-- and the idle counter incremented one extra time (2 -> 3) because the
-- units' moved/acted flags were already reset by the first pass.
--
-- This is the actual mechanism behind "I lose but he's still waiting for
-- my turn": the finished match briefly existed in a half-settled state
-- (one race winner's UPDATE landing, then a second one landing right after
-- it, both fighting over the same row) right as you reconnected, which is
-- exactly the moment confusion about whose screen has caught up is most
-- likely. The forfeit-after-2-missed-turns rule itself did what it's
-- designed to do here -- both sides had gone quiet for several turns in a
-- row (see the log: "ThisIsAtest ran out of time" three times too) and
-- yours crossed the line first.
--
-- Fix: the same guard every other status-sensitive path in this schema
-- uses -- re-check status AFTER taking the row lock, not before, so
-- whichever caller wins the lock is the only one whose work sticks. Every
-- current caller (end_turn, force_timeout, bot_step) only ever calls this
-- expecting status = 'active', so a stale/losing call now just returns the
-- already-finished row untouched instead of reprocessing it.
create or replace function public.advance_turn(p_match uuid, p_note text, p_timeout boolean)
 returns matches
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  m public.matches; st jsonb; u jsonb; out_u jsonb := '[]'::jsonb;
  v_who text; v_next text; v_turn int; v_did boolean := false; v_n int;
  v_got int; v_hurt int; u2 jsonb; v_poisoned jsonb := '[]'::jsonb;
  v_obs_out jsonb; e2 jsonb;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;

  -- 0143: someone else's call already settled this match while we were
  -- waiting on the row lock -- return the settled row as-is rather than
  -- reprocessing a turn/forfeit that already happened.
  if m.status <> 'active' then
    return m;
  end if;

  st := m.state;
  v_who  := st->>'turn';
  v_next := case when v_who = 'host' then 'guest' else 'host' end;
  v_turn := coalesce((st->>'turnNumber')::int, 1) + 1;

  -- Turn cap -> tie. Checked immediately, before anything else, so a
  -- capped match can't first get flagged as a forfeit/stale-round draw
  -- via some other path -- it's always this one, cleanly, the instant
  -- turn 40 finishes.
  if v_turn > 40 then
    st := state_log(st, 'Turn limit reached (40 turns) -- no decisive winner. The match is a draw.');
    st := jsonb_set(st, '{winner}', to_jsonb('draw'::text));
    update public.matches
       set state = st, status = 'finished', winner = 'draw',
           turn_deadline = null, updated_at = now()
     where id = m.id returning * into m;
    return m;
  end if;

  -- Did the side whose turn is ending actually do anything with it?
  for u in select * from jsonb_array_elements(st->'units') loop
    if u->>'owner' = v_who and ((u->>'moved')::boolean or (u->>'acted')::boolean) then
      v_did := true;
    end if;
    u := jsonb_set(u, '{moved}', 'false'::jsonb);
    u := jsonb_set(u, '{acted}', 'false'::jsonb);
    u := jsonb_set(u, '{spent}', 'false'::jsonb);
    -- A guard is raised on the RAISER's turn and has to survive the
    -- opponent's, so it lapses when the RAISER's next turn opens -- keyed
    -- on defendedBy (who raised it), not on the defended unit's own owner,
    -- since a defend can now be pointed at an enemy or a neutral structure
    -- and those two are no longer always the same side.
    if u->>'defendedBy' = v_next then
      u := jsonb_set(u, '{defending}', 'false'::jsonb);
      u := jsonb_set(u, '{defendedBy}', 'null'::jsonb);
    end if;
    out_u := out_u || u;
  end loop;

  if st->'idle' is null then
    st := jsonb_set(st, '{idle}', jsonb_build_object('host', 0, 'guest', 0));
  end if;
  v_n := coalesce((st->'idle'->>v_who)::int, 0);
  if p_timeout and not v_did and not (m.bot is not null and v_who = 'guest') then
    v_n := v_n + 1;
  else
    v_n := 0;
  end if;
  st := jsonb_set(st, array['idle', v_who], to_jsonb(v_n));

  if p_timeout and v_n >= 2 then
    st := jsonb_set(st, '{units}', out_u);
    st := jsonb_set(st, '{winner}', to_jsonb(v_next));
    st := jsonb_set(st, '{forfeitedBy}', to_jsonb(v_who));
    st := state_log(st,
      (case when v_who = 'host' then m.host_name else m.guest_name end)
      || ' has forfeited by inactivity.');
    if m.ranked or (m.bot is null and cn_friend_tournament_lp_enabled()) then
      perform finish_match(m.id, v_next, 'abandon');
    end if;
    update public.matches
       set state = st, status = 'finished', winner = v_next,
           turn_deadline = null, updated_at = now()
     where id = m.id returning * into m;
    return m;
  end if;

  if v_n >= 3 then
    if coalesce(st->>'away', '') <> v_who then
      st := state_log(st,
        case when v_who = 'host' then m.host_name else m.guest_name end
        || ' has not acted for three turns.');
    end if;
    st := jsonb_set(st, '{away}', to_jsonb(v_who));
  elsif st->>'away' = v_who then
    st := jsonb_set(st, '{away}', 'null'::jsonb);
    st := state_log(st,
      case when v_who = 'host' then m.host_name else m.guest_name end || ' is back.');
  end if;

  st := jsonb_set(st, '{units}', out_u);

  -- Any defended obstacle/structure lapses the same way, on the raiser's
  -- own next turn -- new with retargetable defend (0096); obstacles never
  -- carried a defending flag before this, so this is a no-op for a match
  -- with no structures.
  v_obs_out := '[]'::jsonb;
  for e2 in select * from jsonb_array_elements(coalesce(st->'obstacles', '[]'::jsonb)) loop
    if e2->>'defendedBy' = v_next then
      e2 := jsonb_set(e2, '{defending}', 'false'::jsonb);
      e2 := jsonb_set(e2, '{defendedBy}', 'null'::jsonb);
    end if;
    v_obs_out := v_obs_out || e2;
  end loop;
  st := jsonb_set(st, '{obstacles}', v_obs_out);

  v_n := coalesce((st->'mist'->v_who->>'t')::int, 0);
  if v_n > 0 then
    st := jsonb_set(st, array['mist', v_who, 't'], to_jsonb(v_n - 1));
    if v_n = 1 then
      st := state_log(st, 'The mist lifts.');
    end if;
  end if;

  for u in select * from jsonb_array_elements(st->'units') loop
    if u->>'owner' = v_next
       and coalesce((cn_awake(st, u)->>'poisonsAdj')::boolean, false)
       and (u->>'hp')::int > 0 then
      for u2 in select * from jsonb_array_elements(st->'units') loop
        if u2->>'id' <> u->>'id'
           and cn_cheb((u->>'x')::int, (u->>'y')::int,
                       (u2->>'x')::int, (u2->>'y')::int) = 1 then
          v_poisoned := v_poisoned || to_jsonb(u2->>'id');
        end if;
      end loop;
    end if;
  end loop;

  out_u := '[]'::jsonb;
  for u in select * from jsonb_array_elements(st->'units') loop
    if v_poisoned ? (u->>'id') then
      if not cn_has(u, 'poison') then
        st := state_log(st, (u->>'name') || ' is poisoned.');
      end if;
      u := cn_afflict(u, 'poison', 'true'::jsonb);
    end if;

    if u->>'owner' = v_who and cn_stunned(u) then
      u := cn_afflict(u, 'stun',
                      to_jsonb(greatest(0, (u->'effects'->>'stun')::int - 1)));
      if not cn_stunned(u) then
        st := state_log(st, (u->>'name') || ' shakes it off.');
      end if;
    end if;

    if u->>'owner' = v_next and cn_has(u, 'poison') and (u->>'hp')::int > 0 then
      v_hurt := cn_effect_dmg(st, u, cn_poison_pct());
      u := jsonb_set(u, '{hp}', to_jsonb((u->>'hp')::int - v_hurt));
      st := state_log(st, (u->>'name') || ' takes ' || v_hurt || ' from the poison.');
    end if;

    if u->>'owner' = v_next and coalesce((cn_awake(st, u)->>'regenPct')::int, 0) > 0
       and (u->>'hp')::int > 0 and (u->>'hp')::int < (u->>'maxHp')::int then
      v_got := least((u->>'maxHp')::int - (u->>'hp')::int,
                     greatest(1, round((u->>'maxHp')::int
                              * coalesce((cn_awake(st, u)->>'regenPct')::int, 0)
                              / 100.0)::int));
      u := jsonb_set(u, '{hp}', to_jsonb((u->>'hp')::int + v_got));
      st := state_log(st, (u->>'name') || ' mends ' || v_got || '.');
    end if;
    if (u->>'hp')::int > 0 then out_u := out_u || u; end if;
  end loop;
  st := jsonb_set(st, '{units}', out_u);

  st := jsonb_set(st, '{acts}', '0'::jsonb);

  if v_next = 'host' then
    if coalesce((st->>'roundDmg')::boolean, false) then
      st := jsonb_set(st, '{staleRounds}', '0'::jsonb);
    else
      st := jsonb_set(st, '{staleRounds}',
        to_jsonb(coalesce((st->>'staleRounds')::int, 0) + 1));
    end if;
    st := jsonb_set(st, '{roundDmg}', 'false'::jsonb);

    if coalesce((st->>'staleRounds')::int, 0) >= 5 then
      st := jsonb_set(st, '{winner}', to_jsonb('draw'::text));
      st := state_log(st, 'Stalemate -- no damage dealt for five rounds. The match is a draw.');
      update public.matches
         set state = st, status = 'finished', winner = 'draw',
             turn_deadline = null, updated_at = now()
       where id = m.id returning * into m;
      return m;
    end if;
  end if;

  for u in select * from jsonb_array_elements(coalesce(st->'units', '[]'::jsonb)) loop
    if u->>'owner' = v_who and jsonb_typeof(u->'abilityScript') = 'array'
       and jsonb_array_length(u->'abilityScript') > 0 then
      st := cn_run_effects(st, 'END_OF_TURN', u, jsonb_build_object('turnNumber', v_turn));
    end if;
  end loop;
  for u in select * from jsonb_array_elements(coalesce(st->'units', '[]'::jsonb)) loop
    if u->>'owner' = v_next and jsonb_typeof(u->'abilityScript') = 'array'
       and jsonb_array_length(u->'abilityScript') > 0 then
      st := cn_run_effects(st, 'START_OF_TURN', u, jsonb_build_object('turnNumber', v_turn));
    end if;
  end loop;

  st := jsonb_set(st, '{active}', 'null'::jsonb);
  st := jsonb_set(st, '{turn}', to_jsonb(v_next));
  st := jsonb_set(st, '{turnNumber}', to_jsonb(v_turn));
  if p_note is not null then st := state_log(st, p_note); end if;
  st := state_log(st, 'Turn ' || v_turn || ' — '
        || case when v_next = 'host' then m.host_name else m.guest_name end || ' to act.');

  update public.matches
     set state = st, turn_deadline = now() + interval '30 seconds', updated_at = now()
   where id = m.id returning * into m;
  return m;
end
$function$;
