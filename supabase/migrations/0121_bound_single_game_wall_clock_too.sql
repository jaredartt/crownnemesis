-- Simulate matches is STILL timing out ("canceling statement due to
-- statement timeout", Postgres code 57014) after 0119. Confirmed live in
-- the logs: admin_run_training_batch was killed at 09:32:11, ~18s after
-- the previous call returned successfully at 09:31:53 -- far past the
-- 4-second wall-clock deadline 0119 added.
--
-- Root cause: 0119's deadline is only checked BETWEEN games (at the top
-- of admin_run_training_batch's for-loop). Once a single call to
-- sim_play_one_game starts, nothing stops it until it either finishes
-- the match or hits its own 300-turn cap -- and this session's earlier
-- timing tests already showed real games varying wildly in cost (a
-- 25-game batch once took 60+ seconds, ~2.4s/game average with some
-- games clearly costing much more than others). One expensive game
-- starting just under the deadline can all by itself run the call well
-- past the 8-second authenticated statement_timeout, exactly like this
-- morning's failure.
--
-- Fix: give sim_play_one_game the SAME deadline admin_run_training_batch
-- already computes, and check it on every turn of its own inner loop --
-- not just once per game. A pathological game now gets cut off after at
-- most one more turn, not run to its 300-turn cap. A capped/cut-off game
-- (m.status still 'active') already inserts into sim_games as
-- winner = null, capped = true -- 0120 didn't need to change any of that.

create or replace function public.sim_play_one_game(
  p_run uuid, p_level integer, p_host_deck text[], p_guest_deck text[],
  p_host_brain uuid, p_guest_brain uuid, p_deadline timestamptz default null
)
 RETURNS TABLE(game matches, stats jsonb, roster jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  m public.matches; v_turn text; v_i int := 0; v_cap int := 300;
  v_stats jsonb := '{}'::jsonb; v_before jsonb; v_after jsonb;
  v_uid text; bu jsonb; au jsonb; v_delta numeric;
  v_action jsonb; v_actor text; v_target text; v_kind text;
  v_turnnum_before int; v_turnnum_after int;
  v_host_units jsonb; v_guest_units jsonb; v_roster jsonb;
begin
  insert into public.matches
    (code, host_id, host_name, guest_id, guest_name, status, state,
     bot, host_bot, ranked, is_sim, sim_run_id, host_brain_id, guest_brain_id)
  values
    (gen_match_code(), cn_sim_profile_id(), 'Sim Host', null, 'Sim Guest',
     'deploying', cn_fresh_map(), p_level, p_level, false, true, p_run, p_host_brain, p_guest_brain)
  returning * into m;

  -- The initial roster, captured now and returned as-is at the end -- some
  -- engine paths drop a unit from state.units entirely once it dies, so
  -- this (not the final state) is the only reliable "every unit that ever
  -- took part" list a caller can build sim_unit_stats rows from.
  v_host_units := cn_army(m.state, 'host', p_host_deck);
  v_guest_units := cn_army(m.state, 'guest', p_guest_deck);
  v_roster := v_host_units || v_guest_units;

  insert into public.match_deploy (match_id, side, user_id, units) values
    (m.id, 'host',  m.host_id, v_host_units),
    (m.id, 'guest', null,      v_guest_units);

  perform cn_set_ready(m.id, 'host', false);
  m := cn_set_ready(m.id, 'guest', false);

  loop
    exit when m.status <> 'active';
    v_i := v_i + 1;
    exit when v_i > v_cap;
    -- 0121: the same wall-clock deadline the caller is bound by, checked
    -- every turn -- not just once per game. This is what actually keeps a
    -- single expensive game from blowing the batch's whole time budget.
    exit when p_deadline is not null and clock_timestamp() >= p_deadline;

    v_before := m.state->'units';
    v_turn := m.state->>'turn';
    v_turnnum_before := coalesce((m.state->>'turnNumber')::int, 1);

    m := bot_step(m.id, v_turn);

    v_action := m.state->'lastBotAction';
    v_kind := v_action->>'kind';
    v_actor := v_action->>'unit';
    v_target := v_action->>'target';
    v_after := m.state->'units';
    v_turnnum_after := coalesce((m.state->>'turnNumber')::int, 1);

    -- turns_alive: every unit still standing gets credit for the turn that
    -- just elapsed, whenever advance_turn actually moved the counter.
    if v_turnnum_after > v_turnnum_before then
      for bu in select * from jsonb_array_elements(v_before) loop
        if coalesce((bu->>'hp')::numeric, 0) > 0 then
          v_stats := sim_bump(v_stats, bu->>'id', 'turns_alive', 1);
        end if;
      end loop;
    end if;

    if v_kind = 'attack' and v_actor is not null then
      -- hp deltas on the actor and/or the declared target -- an ordinary
      -- hit only changes the target; a countered or parried hit changes
      -- both, and the non-actor side of that pair is always the one whose
      -- own counter dealt the actor's damage, never the other way round.
      foreach v_uid in array array[v_actor, v_target] loop
        continue when v_uid is null;
        select value into bu from jsonb_array_elements(v_before) value where value->>'id' = v_uid;
        select value into au from jsonb_array_elements(v_after)  value where value->>'id' = v_uid;
        if bu is null or au is null then continue; end if;
        v_delta := coalesce((bu->>'hp')::numeric, 0) - coalesce((au->>'hp')::numeric, 0);
        if v_delta > 0 then
          v_stats := sim_bump(v_stats, v_uid, 'damage_taken', v_delta);
          v_stats := sim_bump(v_stats,
            case when v_uid = v_actor then v_target else v_actor end, 'damage_dealt', v_delta);
          if coalesce((au->>'hp')::numeric, 0) <= 0 and coalesce((bu->>'hp')::numeric, 0) > 0 then
            v_stats := sim_bump(v_stats, v_uid, 'deaths', 1);
            v_stats := sim_bump(v_stats,
              case when v_uid = v_actor then v_target else v_actor end, 'kills', 1);
          end if;
        elsif v_delta < 0 and v_uid = v_target then
          -- the actor healed its target (heals only ever target an ally)
          v_stats := sim_bump(v_stats, v_actor, 'healing_done', -v_delta);
        end if;
      end loop;
    end if;
  end loop;

  return query select m, v_stats, v_roster;
end
$function$;

-- admin_run_training_batch now passes its own deadline straight through.
-- Trimmed from 4s to 3s too, for extra headroom against the 8s
-- authenticated statement_timeout on top of the per-turn check above.
create or replace function public.admin_run_training_batch(p_run uuid, p_batch integer DEFAULT 20)
 RETURNS training_runs
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_run public.training_runs; v_n int; i int; v_deadline timestamptz;
  v_host_deck text[]; v_guest_deck text[]; v_host_brain uuid; v_guest_brain uuid;
  v_result record; v_game public.matches; v_stats jsonb; v_roster jsonb; v_sim_game_id uuid;
  v_u jsonb; v_win text; v_carry_uid text; v_carry_score numeric;
  v_side text; v_side_result text; v_cand_wins int; v_base_wins int; v_promote boolean;
begin
  perform admin_require_admin();
  select * into v_run from public.training_runs where id = p_run for update;
  if v_run.id is null then raise exception 'no such training run'; end if;
  if v_run.status in ('completed', 'cancelled', 'failed') then return v_run; end if;

  if v_run.status = 'pending' then
    update public.training_runs set status = 'running', started_at = now()
      where id = v_run.id returning * into v_run;
  end if;

  -- p_batch is an upper ceiling, not the real limit -- real per-game cost
  -- varies (and this database isn't always this quiet), so the loop below
  -- also bails out on wall-clock time. Either limit hitting first just
  -- means the caller's existing polling loop calls this again.
  --
  -- 0121: this same deadline is now also passed INTO sim_play_one_game
  -- (see that migration's header) so one slow game can't blow past it by
  -- itself -- the earlier version only checked between games.
  v_deadline := clock_timestamp() + interval '3 seconds';

  v_n := least(coalesce(p_batch, 20), v_run.games_requested - v_run.games_completed);
  for i in 1 .. greatest(v_n, 0) loop
    exit when clock_timestamp() >= v_deadline;

    v_host_deck := random_deck();
    v_guest_deck := random_deck();
    -- 'preview' plays candidate-vs-live for real, same as 'teach' --
    -- "Simulate matches" has to show what the mutation actually does.
    if v_run.kind in ('teach', 'preview') and random() < 0.5 then
      v_host_brain := v_run.candidate_brain_id; v_guest_brain := v_run.baseline_brain_id;
    else
      v_host_brain := v_run.baseline_brain_id;
      v_guest_brain := case when v_run.kind in ('teach', 'preview') then v_run.candidate_brain_id else v_run.baseline_brain_id end;
    end if;

    select * into v_result from sim_play_one_game(
      v_run.id, v_run.level, v_host_deck, v_guest_deck, v_host_brain, v_guest_brain, v_deadline);
    v_game := v_result.game;
    v_stats := v_result.stats;
    v_roster := v_result.roster;
    v_win := v_game.state->>'winner';

    insert into public.sim_games
      (training_run_id, match_id, host_deck, guest_deck, host_brain_id, guest_brain_id,
       winner, turns, capped)
    values
      (v_run.id, v_game.id, v_host_deck, v_guest_deck, v_host_brain, v_guest_brain,
       nullif(v_win, ''), coalesce((v_game.state->>'turnNumber')::int, 0), v_win is null)
    returning id into v_sim_game_id;

    v_carry_uid := null; v_carry_score := -1;
    if v_win in ('host', 'guest') then
      for v_u in select * from jsonb_array_elements(v_roster) loop
        if v_u->>'owner' = v_win then
          declare v_sc numeric := coalesce((v_stats->(v_u->>'id')->>'damage_dealt')::numeric, 0)
                                 + coalesce((v_stats->(v_u->>'id')->>'healing_done')::numeric, 0)
                                 + coalesce((v_stats->(v_u->>'id')->>'kills')::numeric, 0) * 50;
          begin
            if v_sc > v_carry_score then v_carry_score := v_sc; v_carry_uid := v_u->>'id'; end if;
          end;
        end if;
      end loop;
    end if;

    for v_u in select * from jsonb_array_elements(v_roster) loop
      insert into public.sim_unit_stats
        (sim_game_id, training_run_id, unit_id, card_slug, role, royal, side, won,
         turns_alive, damage_dealt, damage_taken, healing_done, kills, deaths, final_hp, carried)
      values
        (v_sim_game_id, v_run.id, v_u->>'id', v_u->>'slug', v_u->>'role',
         coalesce((v_u->>'royal')::boolean, false), v_u->>'owner',
         v_win in ('host', 'guest') and v_u->>'owner' = v_win,
         coalesce((v_stats->(v_u->>'id')->>'turns_alive')::numeric, 0)::int,
         coalesce((v_stats->(v_u->>'id')->>'damage_dealt')::numeric, 0),
         coalesce((v_stats->(v_u->>'id')->>'damage_taken')::numeric, 0),
         coalesce((v_stats->(v_u->>'id')->>'healing_done')::numeric, 0),
         coalesce((v_stats->(v_u->>'id')->>'kills')::numeric, 0)::int,
         coalesce((v_stats->(v_u->>'id')->>'deaths')::numeric, 0)::int,
         greatest(0, coalesce((
           select (u2->>'hp')::int from jsonb_array_elements(v_game.state->'units') u2
           where u2->>'id' = v_u->>'id'), 0)),
         v_u->>'id' = v_carry_uid);
    end loop;

    -- Win/loss record on the brain rows themselves: kept for BOTH 'teach'
    -- and 'preview' (an admin watching a Simulate run should see the
    -- candidate actually accrue wins/losses) -- only the PROMOTION decision
    -- below stays exclusive to 'teach'.
    --
    -- sim_result_for_side() (0120) is what makes a draw a true no-op here.
    if v_run.kind in ('teach', 'preview') then
      v_side := case when v_host_brain = v_run.candidate_brain_id then 'host' else 'guest' end;
      v_side_result := public.sim_result_for_side(v_win, v_side);
      if v_side_result = 'win' then
        update public.bot_brains set games_played = games_played + 1, wins = wins + 1
          where id = v_run.candidate_brain_id;
        update public.bot_brains set games_played = games_played + 1, losses = losses + 1
          where id = v_run.baseline_brain_id;
      elsif v_side_result = 'loss' then
        update public.bot_brains set games_played = games_played + 1, losses = losses + 1
          where id = v_run.candidate_brain_id;
        update public.bot_brains set games_played = games_played + 1, wins = wins + 1
          where id = v_run.baseline_brain_id;
      end if;
      -- 'draw', or null: no wins/losses change for either brain.
    end if;

    update public.training_runs set games_completed = games_completed + 1
      where id = v_run.id returning * into v_run;
  end loop;

  if v_run.games_completed >= v_run.games_requested then
    v_promote := false;
    -- Promotion stays exclusive to 'teach' ("Train" updates the live bot in
    -- real-time). 'preview' ("Simulate matches") reads the very same
    -- candidate_wins/baseline_wins for display purposes but this if-branch
    -- never runs for it, so is_live can never flip from a Simulate click,
    -- no matter how lopsided the result.
    if v_run.kind = 'teach' then
      select wins, losses into v_cand_wins, v_base_wins from public.bot_brains where id = v_run.candidate_brain_id;
      v_promote := coalesce(v_cand_wins, 0) > coalesce(v_base_wins, 0);
      if v_promote then
        update public.bot_brains set is_live = false where level = v_run.level and is_live;
        update public.bot_brains set is_live = true where id = v_run.candidate_brain_id;
      end if;
    else
      select wins, losses into v_cand_wins, v_base_wins from public.bot_brains where id = v_run.candidate_brain_id;
    end if;
    update public.training_runs
      set status = 'completed', finished_at = now(), promoted = v_promote,
          summary = jsonb_build_object(
            'games', v_run.games_completed,
            'candidate_wins', v_cand_wins, 'baseline_wins', v_base_wins, 'promoted', v_promote)
      where id = v_run.id returning * into v_run;
  end if;

  return v_run;
end
$function$;

-- Self-tests -----------------------------------------------------------
do $$
declare
  v_admin uuid;
  v_level int := 3;
  v_base_id uuid;
  v_scaffold_run uuid;
  t0 timestamptz;
  v_elapsed_ms numeric;
  v_result record;
begin
  select id into v_admin from public.profiles where is_admin limit 1;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  select id into v_base_id from public.bot_brains where level = v_level and is_live limit 1;

  -- sim_play_one_game's p_run is a real FK into training_runs (matches.sim_run_id
  -- references it), so it needs a real, if throwaway, row to point at.
  insert into public.training_runs
    (kind, level, games_requested, games_completed, status, candidate_brain_id, baseline_brain_id)
    values ('preview', v_level, 1, 0, 'running', v_base_id, v_base_id)
    returning id into v_scaffold_run;

  -- Test A: a deadline in the past cuts a game off almost immediately --
  -- proof the per-turn check inside sim_play_one_game actually fires,
  -- rather than only being reachable after 300 turns.
  t0 := clock_timestamp();
  select * into v_result from public.sim_play_one_game(
    v_scaffold_run, v_level, random_deck(), random_deck(), v_base_id, v_base_id,
    clock_timestamp() - interval '1 second');
  v_elapsed_ms := extract(epoch from (clock_timestamp() - t0)) * 1000;
  if v_elapsed_ms > 2000 then
    raise exception '0121 self-test A FAILED: a past deadline should cut the game off almost instantly, took %ms', v_elapsed_ms;
  end if;
  if (v_result.game).status <> 'active' then
    raise exception '0121 self-test A FAILED: a deadline-cut game should be left unfinished (status active), got %', (v_result.game).status;
  end if;
  raise notice '0121 self-test A passed: an already-past deadline stops a game almost immediately (%ms), leaving it unfinished.', round(v_elapsed_ms);

  -- Test B: with a generous deadline, a normal game still plays out and
  -- finishes exactly as before (this migration must not break ordinary
  -- play, only bound the pathological case).
  t0 := clock_timestamp();
  select * into v_result from public.sim_play_one_game(
    v_scaffold_run, v_level, random_deck(), random_deck(), v_base_id, v_base_id,
    clock_timestamp() + interval '20 seconds');
  v_elapsed_ms := extract(epoch from (clock_timestamp() - t0)) * 1000;
  if (v_result.game).status <> 'finished' then
    raise exception '0121 self-test B FAILED: a game with a generous deadline should finish normally, got status %', (v_result.game).status;
  end if;
  raise notice '0121 self-test B passed: a normal game still finishes on its own in %ms with a generous deadline.', round(v_elapsed_ms);

  -- cleanup
  delete from public.match_deploy where match_id in (
    select id from public.matches where sim_run_id = v_scaffold_run);
  delete from public.sim_unit_stats where training_run_id = v_scaffold_run;
  delete from public.sim_games where training_run_id = v_scaffold_run;
  delete from public.matches where sim_run_id = v_scaffold_run;
  delete from public.training_runs where id = v_scaffold_run;
end $$;
