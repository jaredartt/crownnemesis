-- Jared, looking at the finished Training panel: "can I see there the
-- number of draws, apart from who won?" -- right now a completed run's
-- summary only ever records candidate_wins/baseline_wins/promoted, so a
-- draw (0120) or a capped/cut-off game (0119/0121, unresolved -- ran out
-- of turns or wall-clock before a winner) both just vanish from the
-- numbers: games_completed can be bigger than candidate_wins+baseline_wins
-- and there was no way to see why.
--
-- sim_games already has everything needed (winner = 'draw' for a real
-- stalemate, winner is null + capped = true for a cut-off game) -- this
-- just also counts those into the same summary jsonb at completion time,
-- alongside the counts that were already being computed there.
--
-- Writing that self-test caught a second, more serious bug on the way in:
-- candidate_wins/baseline_wins were read straight off bot_brains.wins/
-- losses. That's fine for the CANDIDATE (a fresh brain is created for
-- every single preview/teach run, so its counters start at 0 every time)
-- but wrong for the BASELINE -- baseline_brain_id is the one persistent
-- live bot, reused across every run ever played against it, so its
-- wins/losses are an all-time cumulative total, not this run's own count.
-- "Current bot: 28" in a completed run's summary could be (and, per the
-- self-test below, WAS) mostly history from earlier runs, not this run's
-- 50 games. It also fed the 'teach' promotion decision, which compared a
-- run-scoped candidate count against that same inflated baseline total.
-- Both numbers are now counted directly off THIS run's own sim_games
-- instead, via sim_result_for_side() (0120) relative to whichever side the
-- candidate played each individual game.

create or replace function public.admin_run_training_batch(
  p_run uuid, p_batch integer default 20, p_deadline_seconds numeric default 3
)
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
  v_draws int; v_unresolved int;
begin
  perform admin_require_admin();
  select * into v_run from public.training_runs where id = p_run for update;
  if v_run.id is null then raise exception 'no such training run'; end if;
  if v_run.status in ('completed', 'cancelled', 'failed') then return v_run; end if;

  if v_run.status = 'pending' then
    update public.training_runs set status = 'running', started_at = now()
      where id = v_run.id returning * into v_run;
  end if;

  v_deadline := clock_timestamp() + make_interval(secs => greatest(0.5, coalesce(p_deadline_seconds, 3)));

  v_n := least(coalesce(p_batch, 20), v_run.games_requested - v_run.games_completed);
  for i in 1 .. greatest(v_n, 0) loop
    exit when clock_timestamp() >= v_deadline;

    v_host_deck := random_deck();
    v_guest_deck := random_deck();
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
         coalesce(v_win in ('host', 'guest') and v_u->>'owner' = v_win, false),
         coalesce((v_stats->(v_u->>'id')->>'turns_alive')::numeric, 0)::int,
         coalesce((v_stats->(v_u->>'id')->>'damage_dealt')::numeric, 0),
         coalesce((v_stats->(v_u->>'id')->>'damage_taken')::numeric, 0),
         coalesce((v_stats->(v_u->>'id')->>'healing_done')::numeric, 0),
         coalesce((v_stats->(v_u->>'id')->>'kills')::numeric, 0)::int,
         coalesce((v_stats->(v_u->>'id')->>'deaths')::numeric, 0)::int,
         greatest(0, coalesce((
           select (u2->>'hp')::int from jsonb_array_elements(v_game.state->'units') u2
           where u2->>'id' = v_u->>'id'), 0)),
         coalesce(v_u->>'id' = v_carry_uid, false));
    end loop;

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
      -- 'draw', or null (unresolved -- capped/cut off before a winner):
      -- no wins/losses change for either brain.
    end if;

    update public.training_runs set games_completed = games_completed + 1
      where id = v_run.id returning * into v_run;
  end loop;

  if v_run.games_completed >= v_run.games_requested then
    v_promote := false;

    -- 0124: all four numbers counted directly off THIS run's own
    -- sim_games rows, not off bot_brains' cumulative (all-time) counters --
    -- see the file header. sim_result_for_side() is evaluated relative to
    -- whichever side the candidate actually played each game (host/guest
    -- was randomised per game in the loop above).
    select
        count(*) filter (where public.sim_result_for_side(winner,
          case when host_brain_id = v_run.candidate_brain_id then 'host' else 'guest' end) = 'win'),
        count(*) filter (where public.sim_result_for_side(winner,
          case when host_brain_id = v_run.candidate_brain_id then 'host' else 'guest' end) = 'loss'),
        count(*) filter (where winner = 'draw'),
        count(*) filter (where winner is null)
      into v_cand_wins, v_base_wins, v_draws, v_unresolved
      from public.sim_games where training_run_id = v_run.id;

    if v_run.kind = 'teach' then
      v_promote := coalesce(v_cand_wins, 0) > coalesce(v_base_wins, 0);
      if v_promote then
        update public.bot_brains set is_live = false where level = v_run.level and is_live;
        update public.bot_brains set is_live = true where id = v_run.candidate_brain_id;
      end if;
    end if;

    update public.training_runs
      set status = 'completed', finished_at = now(), promoted = v_promote,
          summary = jsonb_build_object(
            'games', v_run.games_completed,
            'candidate_wins', v_cand_wins, 'baseline_wins', v_base_wins, 'promoted', v_promote,
            'draws', coalesce(v_draws, 0), 'unresolved', coalesce(v_unresolved, 0))
      where id = v_run.id returning * into v_run;
  end if;

  return v_run;
end
$function$;

-- Self-test -----------------------------------------------------------
do $$
declare
  v_admin uuid; v_level int := 3; v_base_id uuid; v_run public.training_runs;
  v_draws int; v_unresolved int; v_wins int; v_games int;
begin
  select id into v_admin from public.profiles where is_admin limit 1;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  select id into v_base_id from public.bot_brains where level = v_level and is_live limit 1;

  insert into public.training_runs
    (kind, level, games_requested, games_completed, status, candidate_brain_id, baseline_brain_id)
    values ('preview', v_level, 40, 0, 'pending', v_base_id, v_base_id)
    returning * into v_run;

  -- A short deadline per call, run to completion across several batches,
  -- is very likely to include at least one draw or capped game in 40
  -- tries -- exactly the case this migration adds visibility for.
  while v_run.status not in ('completed', 'failed', 'cancelled') loop
    select * into v_run from public.admin_run_training_batch(v_run.id, 40, 2);
  end loop;

  v_draws := (v_run.summary->>'draws')::int;
  v_unresolved := (v_run.summary->>'unresolved')::int;
  v_games := (v_run.summary->>'games')::int;
  v_wins := coalesce((v_run.summary->>'candidate_wins')::int, 0) + coalesce((v_run.summary->>'baseline_wins')::int, 0);

  if v_draws is null or v_unresolved is null then
    raise exception '0124 self-test FAILED: summary is missing draws/unresolved (summary=%)', v_run.summary;
  end if;
  -- The bug this migration also fixes: baseline_wins used to be the live
  -- bot's all-time cumulative total (which, on a bot that's played many
  -- runs before, is far bigger than this run's own game count -- this is
  -- literally how the first version of this self-test failed). Confirm it
  -- can no longer exceed this run's own total.
  if coalesce((v_run.summary->>'baseline_wins')::int, 0) > v_games then
    raise exception '0124 self-test FAILED: baseline_wins (%) exceeds this run''s own games (%) -- looks cumulative again',
      v_run.summary->>'baseline_wins', v_games;
  end if;
  if v_wins + v_draws + v_unresolved <> v_games then
    raise exception '0124 self-test FAILED: wins(%) + draws(%) + unresolved(%) != games(%)',
      v_wins, v_draws, v_unresolved, v_games;
  end if;
  raise notice '0124 self-test passed: games=%, wins=%, draws=%, unresolved=% (all accounted for).',
    v_games, v_wins, v_draws, v_unresolved;

  -- cleanup
  delete from public.match_deploy where match_id in (
    select id from public.matches where sim_run_id = v_run.id);
  delete from public.sim_unit_stats where training_run_id = v_run.id;
  delete from public.sim_games where training_run_id = v_run.id;
  delete from public.matches where sim_run_id = v_run.id;
  delete from public.training_runs where id = v_run.id;
end $$;
