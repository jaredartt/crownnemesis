-- =============================================================================
-- 0068 -- advance_turn's AFK-forfeit branch (0051: two consecutive turns
-- idle ends the match) gets the same friend/tournament LP gate as
-- claim_win/cn_finish/resign_match (0066) and cn_attack (0067).
--
-- WHY A SEPARATE MIGRATION FROM 0066: advance_turn is a large function
-- edited on its own, same reasoning as 0067's own separate file for
-- cn_attack -- a full-function splice is easier to read (and to diff
-- against the previous live definition) as its own migration than folded
-- into 0066's multi-function batch.
--
-- Unlike cn_attack (0067), this function already carried `SECURITY
-- DEFINER` before this migration and keeps it here -- there is no
-- regression to track for this one.
-- =============================================================================
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
begin
  select * into m from public.matches where id = p_match for update;
  st := m.state;
  v_who  := st->>'turn';
  v_next := case when v_who = 'host' then 'guest' else 'host' end;
  v_turn := coalesce((st->>'turnNumber')::int, 1) + 1;

  -- Did the side whose turn is ending actually do anything with it?
  for u in select * from jsonb_array_elements(st->'units') loop
    if u->>'owner' = v_who and ((u->>'moved')::boolean or (u->>'acted')::boolean) then
      v_did := true;
    end if;
    u := jsonb_set(u, '{moved}', 'false'::jsonb);
    u := jsonb_set(u, '{acted}', 'false'::jsonb);
    u := jsonb_set(u, '{spent}', 'false'::jsonb);
    -- A guard is raised on your turn and has to survive the opponent's, so
    -- it lapses when its owner's next turn opens -- not when it is tested.
    if u->>'owner' = v_next then
      u := jsonb_set(u, '{defending}', 'false'::jsonb);
    end if;
    out_u := out_u || u;
  end loop;

  if st->'idle' is null then
    st := jsonb_set(st, '{idle}', jsonb_build_object('host', 0, 'guest', 0));
  end if;
  v_n := coalesce((st->'idle'->>v_who)::int, 0);
  -- 0051: never counted for a bot's own turn. bot_step always drives its
  -- turn to a real move or strike before ending it with p_timeout=false, so
  -- this guard should never actually matter -- but a slow/delayed bot_step
  -- leaving the clock to run out is exactly the edge case that must not be
  -- able to forfeit the bot, and this is the one place both the increment
  -- and (two lines further down) the forfeit itself are gated on it.
  if p_timeout and not v_did and not (m.bot is not null and v_who = 'guest') then
    v_n := v_n + 1;
  else
    v_n := 0;
  end if;
  st := jsonb_set(st, array['idle', v_who], to_jsonb(v_n));

  -- ===== 0051: AFK FORFEIT ===================================================
  -- Two consecutive turns this side's clock ran out with nobody touching a
  -- unit -- v_n counts exactly that, the same counter the pre-existing
  -- "away" notice below already kept, just read at a stricter threshold (2,
  -- not 3) with a real consequence instead of a cosmetic one. Once this
  -- fires the match is finished, so the away-flag branch below it can never
  -- be reached by a NEW match again -- left in place rather than deleted,
  -- per this project's convention, since claim_win() (a manual "they went
  -- away" resign-for-them path gated on the same idle>=3/6 counter) still
  -- reads it and old in-flight matches may already be sitting at idle=1 or
  -- 2 the moment this migration lands.
  if p_timeout and v_n >= 2 then
    st := jsonb_set(st, '{units}', out_u);
    st := jsonb_set(st, '{winner}', to_jsonb(v_next));
    st := jsonb_set(st, '{forfeitedBy}', to_jsonb(v_who));
    st := state_log(st,
      (case when v_who = 'host' then m.host_name else m.guest_name end)
      || ' has forfeited by inactivity.');
    -- Rated the same as any other loss (reusing 'abandon', the reason
    -- claim_win already uses for this same kind of ending -- no schema
    -- change needed for a new reason string).
    -- 0068: was `if m.ranked then` alone -- see this migration's header.
    if m.ranked or (m.bot is null and cn_friend_tournament_lp_enabled()) then
      perform finish_match(m.id, v_next, 'abandon');
    end if;
    update public.matches
       set state = st, status = 'finished', winner = v_next,
           turn_deadline = null, updated_at = now()
     where id = m.id returning * into m;
    return m;
  end if;
  -- ===== end 0051 AFK forfeit ================================================

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

  -- THE MIST THINS. Counted down on the turn of the side that raised it,
  -- as that turn ENDS -- so "two turns" means this one and the next one,
  -- which is what somebody spending an activation on it expects to buy.
  v_n := coalesce((st->'mist'->v_who->>'t')::int, 0);
  if v_n > 0 then
    st := jsonb_set(st, array['mist', v_who, 't'], to_jsonb(v_n - 1));
    if v_n = 1 then
      st := state_log(st, 'The mist lifts.');
    end if;
  end if;

  -- SARRAVE. Every tile around it, at the start of its own side's turn,
  -- which is BEFORE the poison below bites -- so a unit poisoned this turn
  -- does not also pay for it this turn. Collected first and applied in the
  -- same pass as everything else, because a second walk over the units is
  -- a second chance to disagree about who is where.
  for u in select * from jsonb_array_elements(st->'units') loop
    -- Read through cn_awake, not off u: a Sarrave standing next to Umiro
    -- poisons nothing. u itself is left alone because this loop's whole job
    -- is to hand the untouched rows to the next one.
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

  -- AND THE SLOW ONES MEND. Wuzu's regeneration, at the start of its own
  -- side's turn rather than at the end of the other's: a player should see
  -- it happen on the board they are about to act on.
  out_u := '[]'::jsonb;
  for u in select * from jsonb_array_elements(st->'units') loop
    -- The swamp first, so the new poison does not also tick this turn.
    if v_poisoned ? (u->>'id') then
      if not cn_has(u, 'poison') then
        st := state_log(st, (u->>'name') || ' is poisoned.');
      end if;
      u := cn_afflict(u, 'poison', 'true'::jsonb);
    end if;

    -- A stun is one go, and this is the go it costs.
    if u->>'owner' = v_next and cn_stunned(u) then
      u := cn_afflict(u, 'stun',
                      to_jsonb(greatest(0, (u->'effects'->>'stun')::int - 1)));
      if not cn_stunned(u) then
        st := state_log(st, (u->>'name') || ' shakes it off.');
      end if;
    end if;

    -- POISON bites at the start of its own side's turn, and it can kill.
    if u->>'owner' = v_next and cn_has(u, 'poison') and (u->>'hp')::int > 0 then
      v_hurt := cn_effect_dmg(st, u, cn_poison_pct());
      u := jsonb_set(u, '{hp}', to_jsonb((u->>'hp')::int - v_hurt));
      st := state_log(st, (u->>'name') || ' takes ' || v_hurt || ' from the poison.');
    end if;

    -- Same again for Wuzu. Note `st` and not the half-rebuilt out_u: the
    -- swamp is a fact about where everybody is standing, and everybody is
    -- standing where this turn found them.
    if u->>'owner' = v_next and coalesce((cn_awake(st, u)->>'regenPct')::int, 0) > 0
       and (u->>'hp')::int > 0 and (u->>'hp')::int < (u->>'maxHp')::int then
      v_got := least((u->>'maxHp')::int - (u->>'hp')::int,
                     greatest(1, round((u->>'maxHp')::int
                              * coalesce((cn_awake(st, u)->>'regenPct')::int, 0)
                              / 100.0)::int));
      u := jsonb_set(u, '{hp}', to_jsonb((u->>'hp')::int + v_got));
      st := state_log(st, (u->>'name') || ' mends ' || v_got || '.');
    end if;
    -- A unit the poison finished leaves the board here, the same as one a
    -- blow finished. The win condition is checked by whoever reads the
    -- board next; what must not happen is a corpse standing on a tile.
    if (u->>'hp')::int > 0 then out_u := out_u || u; end if;
  end loop;
  st := jsonb_set(st, '{units}', out_u);

  st := jsonb_set(st, '{acts}', '0'::jsonb);

  -- ===== 0051: STALEMATE =====================================================
  -- A round is one turn from each side, so it completes the moment control
  -- returns to 'host' -- host always opens the very first turn (turnNumber
  -- 1), so host and guest strictly alternate forever after, and "back to
  -- host" is exactly "a full round has passed" for as long as the match has
  -- two sides taking normal turns. roundDmg is set true by cn_attack/
  -- cn_ability the instant either lands any real damage on anybody
  -- (including self-inflicted burn) -- nothing here re-derives it from the
  -- log.
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
      -- Deliberately bypasses finish_match entirely: a draw is not a result,
      -- so no LP moves either direction for a ranked match. See the
      -- migration report.
      update public.matches
         set state = st, status = 'finished', winner = 'draw',
             turn_deadline = null, updated_at = now()
       where id = m.id returning * into m;
      return m;
    end if;
  end if;
  -- ===== end 0051 stalemate ==================================================

  -- 0049: END_OF_TURN (the side whose turn just ended) then START_OF_TURN
  -- (the side about to act), fired once each per eligible unit, right
  -- where turn ownership is about to flip below -- additive, and after
  -- every other end-of-turn bookkeeping above (idle count, mist, Sarrave's
  -- poison, Wuzu's regen) so a scripted effect sees the board exactly as
  -- the next player will.
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

-- ---------------------------------------------------------------------------
-- Did it work?
-- ---------------------------------------------------------------------------
select prosecdef from pg_proc where proname = 'advance_turn'
  and pg_get_function_identity_arguments(oid) = 'p_match uuid, p_note text, p_timeout boolean';
