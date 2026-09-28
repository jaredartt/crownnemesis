-- Jared: "how many turns is the 14 seconds we said we gave to the simulated
-- games? Cause maybe we could have a rule of: if a match goes over 40 turns,
-- then it's a tie (when turn 40 is complete, then it's a tie)." Confirmed he
-- wants this as a real rule for every match, not just simulated training
-- games -- see below for why this lives in advance_turn() rather than only
-- in the sim path.
--
-- (For context, the honest answer to the literal question: the 14s isn't a
-- per-game or per-turn budget at all. It's a wall-clock budget shared by the
-- WHOLE batch of up to 60 games (admin_run_training_batch computes one
-- v_deadline before its loop and passes the same one to every game in that
-- batch), and it's checked once per bot_step call (one unit's move or
-- attack), not once per turn. So "how many turns fit in 14s" has no fixed
-- answer -- it depends on server load and how many games are ahead of a
-- given game in the batch. What's actually stable is turn count itself:
-- across the 2,666 sim games played since the timeout fix, decided games
-- average 23.7 turns (median 24), with 95% finishing by turn 35 and the
-- longest decided game so far at 48. Games that got cut off by the shared
-- deadline ("capped") average only 12 turns -- most of those aren't long
-- grinding games, they're just unlucky about where they landed in the
-- batch's time budget. A turn cap fixes exactly that: a deterministic,
-- per-game stopping point instead of a shared clock that can cut a game off
-- after 3 turns just because it went last in the batch.)
--
-- advance_turn() is the one function both live matches and every simulated
-- match already share (bot_step calls it too), and it already has a
-- precedent for exactly this shape of rule: staleRounds >= 5 (five full
-- rounds with no damage dealt) already ends a match in a draw, the same way
-- this does. This adds a second, turn-number-based version of that same
-- draw path. turnNumber here increments once per SIDE's turn (matching the
-- "turns" column already shown in the training data, and matching the
-- decided-game stats above), so "turn 40 is complete" is v_turn (the
-- about-to-start turn) going past 40, i.e. v_turn > 40 -- meaning it never
-- interferes with any decided game (max 48 turns observed, but the vast
-- majority resolve by turn 35), and only catches genuine stalemates that
-- would otherwise run indefinitely (or, in the sim path, just get cut off
-- wherever the batch's clock happened to run out).
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

    if u->>'owner' = v_next and cn_stunned(u) then
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
