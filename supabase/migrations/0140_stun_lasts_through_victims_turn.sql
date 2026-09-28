-- Jared: "Stun isn't working as expected. When Himanta stuns someone, it
-- appears stunned only in Himanta's turn, but the stunned target should
-- also be stunned in its turn (right after Himanta's turn)."
--
-- Root cause: advance_turn's stun-decrement block was keyed on v_next --
-- the side whose turn is about to START. So the sequence was:
--   1. Himanta's turn: he lands a stun, setting effects.stun = 1 on the
--      target (via cn_attack -> cn_afflict, unrelated to this function).
--   2. Himanta's turn ends -> advance_turn runs with v_who = Himanta's
--      side, v_next = the target's side.
--   3. The stun-decrement block fired on `u->>'owner' = v_next`, i.e. the
--      side about to act -- which is the target. It immediately
--      decremented the freshly-applied stun (1 -> 0) and logged "shakes
--      it off", clearing the effect before the target's own turn ever
--      began. The target was only ever stunned during Himanta's turn,
--      when it couldn't have acted anyway.
--
-- Fix: decrement stun for v_who (the side whose turn is ENDING), not
-- v_next. Traced step by step:
--   - End of Himanta's turn (v_who = Himanta's side): the target belongs
--     to v_next, so it's untouched here -- stun stays at 1 going into the
--     target's own turn, where cn_stunned() blocks it from acting.
--   - End of the target's turn (v_who = target's side, now that their
--     stunned turn has passed): the decrement fires for real, stun goes
--     1 -> 0, "shakes it off" logs, and they're free from their next turn
--     on.
-- That gives exactly one full turn of enforced stun, immediately after
-- the turn it was applied on -- what Jared described.
--
-- Poison and regen are deliberately left on v_next -- those are standard
-- start-of-turn effects (poison ticks at the start of the poisoned
-- side's own turn, regen heals at the start of the healing side's own
-- turn), and that part was never in question.
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

    -- 0140: was `u->>'owner' = v_next` -- decremented the victim's stun
    -- the instant their own turn was about to start, wiping it out before
    -- it could ever block them. Now keyed on v_who (the turn that's
    -- ending), so the decrement happens one full turn later -- see this
    -- migration's header for the full trace.
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
