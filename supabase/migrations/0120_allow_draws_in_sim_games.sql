-- Production bug: "canceling statement due to statement timeout" is fixed
-- (0119), but Simulate matches can now fail a different way:
--
--   new row for relation "sim_games" violates check constraint
--   "sim_games_winner_check"
--
-- Root cause: a match can legitimately end in a draw. advance_turn()'s
-- stalemate rule (5 consecutive rounds with no damage dealt) sets
-- state.winner = 'draw' and matches.winner = 'draw', status = 'finished'
-- -- a perfectly normal, resolved game. But sim_games_winner_check only
-- ever allowed winner in ('host', 'guest'), so admin_run_training_batch's
-- insert into sim_games blows up the instant one simulated game actually
-- draws. This has nothing to do with 0119's turn-cap change -- a
-- stalemate can happen at any point in a game -- it was just a matter of
-- enough games being simulated in one run (Jared's 200-game / 500-game
-- batches) to finally hit one.
--
-- Two fixes:
--   1. sim_games_winner_check now also allows 'draw'.
--   2. admin_run_training_batch's win/loss bookkeeping on bot_brains used
--      to test only `v_win is not null`, so a draw ('draw' <> the
--      candidate's side) fell through to the *else* branch and was
--      silently recorded as a loss for whichever side happened to be
--      checked first -- wrong on both sides. That decision is pulled out
--      into sim_result_for_side(), a tiny pure function, so it can be
--      tested directly instead of only by observation in production.

alter table public.sim_games drop constraint sim_games_winner_check;
alter table public.sim_games add constraint sim_games_winner_check
  check (winner = any (array['host', 'guest', 'draw']));

create or replace function public.sim_result_for_side(p_win text, p_side text)
returns text
language sql
immutable
as $$
  select case
    when p_win is null then null              -- game not yet resolved
    when p_win not in ('host', 'guest') then 'draw'  -- e.g. a stalemate
    when p_win = p_side then 'win'
    else 'loss'
  end
$$;

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
  v_deadline := clock_timestamp() + interval '4 seconds';

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
      v_run.id, v_run.level, v_host_deck, v_guest_deck, v_host_brain, v_guest_brain);
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
    -- sim_result_for_side() is what makes a draw a true no-op here: it
    -- returns 'draw' (not 'win'/'loss') whenever v_win isn't the
    -- candidate's own side literally 'host'/'guest', so a stalemate no
    -- longer gets counted as a loss for whichever side this happened to
    -- check first.
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
      -- 'draw', or null (shouldn't happen here -- this game just finished):
      -- no wins/losses change for either brain.
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
begin
  select id into v_admin from public.profiles where is_admin limit 1;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);

  -- Test A: sim_result_for_side is correct for every case that matters,
  -- including the one that used to be miscounted.
  if public.sim_result_for_side('host', 'host') <> 'win' then
    raise exception '0120 self-test A FAILED: host winning as host should be a win';
  end if;
  if public.sim_result_for_side('guest', 'host') <> 'loss' then
    raise exception '0120 self-test A FAILED: guest winning while checked as host should be a loss';
  end if;
  if public.sim_result_for_side('draw', 'host') <> 'draw' then
    raise exception '0120 self-test A FAILED: a draw must not be scored as a win or a loss';
  end if;
  if public.sim_result_for_side('draw', 'guest') <> 'draw' then
    raise exception '0120 self-test A FAILED: a draw must not be scored as a win or a loss (guest side)';
  end if;
  if public.sim_result_for_side(null, 'host') is not null then
    raise exception '0120 self-test A FAILED: an unresolved game must not be scored at all';
  end if;
  raise notice '0120 self-test A passed: sim_result_for_side scores win/loss/draw/unresolved correctly.';

  -- Test B: the sim_games check constraint now accepts a draw, and still
  -- rejects garbage.
  begin
    insert into public.sim_games (training_run_id, match_id, host_deck, guest_deck, winner, turns, capped)
      values (null, null, '{}', '{}', 'draw', 42, false);
    delete from public.sim_games where match_id is null and winner = 'draw' and turns = 42;
    raise notice '0120 self-test B passed: sim_games now accepts winner = ''draw''.';
  exception when check_violation then
    raise exception '0120 self-test B FAILED: sim_games still rejects a legitimate draw';
  end;

  begin
    insert into public.sim_games (training_run_id, match_id, host_deck, guest_deck, winner, turns, capped)
      values (null, null, '{}', '{}', 'timeout', 42, false);
    delete from public.sim_games where match_id is null and winner = 'timeout' and turns = 42;
    raise exception '0120 self-test B FAILED: sim_games accepted a garbage winner value';
  exception when check_violation then
    raise notice '0120 self-test B passed: sim_games still rejects an invalid winner value.';
  end;
end $$;
