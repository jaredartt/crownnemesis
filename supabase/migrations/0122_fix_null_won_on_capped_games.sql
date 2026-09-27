-- Caught this myself while sanity-checking 0121 against the live,
-- currently-stuck 500-game run before telling Jared it was fixed:
--
--   null value in column "won" of relation "sim_unit_stats" violates
--   not-null constraint
--
-- Root cause: `won` (and `carried`) were computed as
--   v_win in ('host', 'guest') and v_u->>'owner' = v_win
-- and
--   v_u->>'id' = v_carry_uid
-- Both are NOT NULL boolean columns, but both expressions evaluate to
-- SQL NULL -- not false -- whenever v_win is null, i.e. whenever a game
-- got cut off without a winner (capped by the turn cap, or now, after
-- 0121, cut off by the wall-clock deadline mid-game). That case used to
-- be rare enough (the old 3000-turn cap) that this never got exercised
-- in practice; 0121 deliberately makes capped games far more common (by
-- design -- that's what stops a slow game from blowing the timeout), so
-- this latent bug now fires reliably on any real batch.

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
  -- 0121: this same deadline is also passed INTO sim_play_one_game so one
  -- slow game can't blow past it by itself.
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
         -- 0122: coalesced to false -- both booleans must never be SQL
         -- NULL, which is exactly what these comparisons produce whenever
         -- a game was cut off without a winner (v_win/v_carry_uid null).
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

    -- Win/loss record on the brain rows themselves: kept for BOTH 'teach'
    -- and 'preview' (an admin watching a Simulate run should see the
    -- candidate actually accrue wins/losses) -- only the PROMOTION decision
    -- below stays exclusive to 'teach'.
    --
    -- sim_result_for_side() (0120) is what makes a draw (or an unresolved,
    -- cut-off game) a true no-op here.
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

-- Self-test --------------------------------------------------------------
do $$
declare
  v_admin uuid; v_level int := 3; v_base_id uuid; v_run public.training_runs;
  v_ms numeric; t0 timestamptz;
begin
  select id into v_admin from public.profiles where is_admin limit 1;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  select id into v_base_id from public.bot_brains where level = v_level and is_live limit 1;

  insert into public.training_runs
    (kind, level, games_requested, games_completed, status, candidate_brain_id, baseline_brain_id)
    values ('preview', v_level, 40, 0, 'pending', v_base_id, v_base_id)
    returning * into v_run;

  -- A batch big enough, against a database under no special load, to be
  -- very likely to run past admin_run_training_batch's own 3-second
  -- deadline mid-game at least once -- which is exactly the condition
  -- that used to hit the NOT NULL violation on `won`.
  t0 := clock_timestamp();
  select * into v_run from public.admin_run_training_batch(v_run.id, 40);
  v_ms := extract(epoch from (clock_timestamp() - t0)) * 1000;
  raise notice '0122 self-test: batch call took %ms, games_completed=%, status=%',
    round(v_ms), v_run.games_completed, v_run.status;

  -- The real assertion is simply that the call above didn't raise. This
  -- second query re-confirms no null crept into either boolean column for
  -- any game this run actually recorded, capped or not.
  if exists (
    select 1 from public.sim_unit_stats
    where training_run_id = v_run.id and (won is null or carried is null)
  ) then
    raise exception '0122 self-test FAILED: a null won/carried value made it into sim_unit_stats';
  end if;
  raise notice '0122 self-test passed: no null won/carried values, including for any capped game in this batch.';

  -- cleanup
  delete from public.match_deploy where match_id in (
    select id from public.matches where sim_run_id = v_run.id);
  delete from public.sim_unit_stats where training_run_id = v_run.id;
  delete from public.sim_games where training_run_id = v_run.id;
  delete from public.matches where sim_run_id = v_run.id;
  delete from public.training_runs where id = v_run.id;
end $$;
