-- 0117: Jared's exact, final spec for the Training tab -- quoted verbatim
-- because it is the whole reason this migration exists:
--
--   "* Button called "Simulate matches"
--    * Next to it, field for a number of matches THAT I DECIDE, between
--      current bot vs mutated.
--    * A lot of data is shown underneath, the data I asked for above...
--    * Another button called "Train", which will train the current Expert
--      bot, and will update its skills to be used anywhere in Crown
--      Nemesis, in real-time."
--
-- Those are two DIFFERENT operations that 0114 did not have a clean way to
-- tell apart:
--   - Simulate matches = candidate (mutated) vs the current live brain, for
--     however many games the admin types in, and it must NEVER promote --
--     it's a preview, the admin is just watching two brains play.
--   - Train = the same candidate-vs-live contest, but at a fixed internal
--     game count the admin doesn't touch, and it DOES promote the moment it
--     finishes if the candidate won more -- "update its skills... in
--     real-time" is exactly 0114's existing promotion block.
--
-- 0114 only had one kind that plays candidate-vs-live AND always considers
-- promoting: 'teach'. This adds a second kind, 'preview', that plays the
-- exact same candidate-vs-live contest (so "Simulate matches" gets real
-- data about the real mutation, not a self-play placeholder) but is wired
-- to skip the promotion decision entirely, no matter the result. 'teach'
-- itself is untouched, so the existing "Train" behaviour (fixed count,
-- always tests-and-promotes) needs no changes at all -- AdminTraining.tsx
-- just stops exposing a number box for it.
--
-- Every dashboard/value function (admin_card_performance, admin_tier_list,
-- admin_pair_synergy, admin_best_teams, admin_stat_value_model,
-- admin_card_value, admin_ability_value) already takes an explicit p_run
-- and returns exactly that run's data regardless of kind (0114/0115) -- so
-- the new UI can point every one of them at the latest 'preview' run's id
-- with zero changes to any of those seven functions.

alter table public.training_runs drop constraint training_runs_kind_check;
alter table public.training_runs add constraint training_runs_kind_check
  check (kind in ('train', 'teach', 'preview'));

create or replace function public.admin_start_training_run(
  p_kind text, p_games int, p_level int default 3, p_notes text default null
)
returns training_runs
language plpgsql
security definer
set search_path = 'public'
as $function$
declare v_run public.training_runs; v_base public.bot_brains; v_cand uuid;
begin
  perform admin_require_admin();
  if p_kind not in ('train', 'teach', 'preview') then
    raise exception 'kind must be train, teach or preview';
  end if;
  if p_games is null or p_games < 1 or p_games > 20000 then
    raise exception 'games must be between 1 and 20000';
  end if;

  select * into v_base from public.bot_brains where level = p_level and is_live limit 1;
  if v_base.id is null then raise exception 'no live brain for level %', p_level; end if;

  -- 'preview' needs a freshly mutated candidate exactly like 'teach' does --
  -- "Simulate matches" is asking what THIS mutation does, not self-play.
  if p_kind in ('teach', 'preview') then
    insert into public.bot_brains (label, level, weights, is_live, parent_id, notes, created_by)
    values ('Candidate ' || to_char(now(), 'MM-DD HH24:MI'), p_level,
            admin_mutate_weights(v_base.weights), false, v_base.id, p_notes, auth.uid())
    returning id into v_cand;
  end if;

  insert into public.training_runs
    (kind, level, games_requested, baseline_brain_id, candidate_brain_id, created_by)
  values (p_kind, p_level, p_games, v_base.id, v_cand, auth.uid())
  returning * into v_run;
  return v_run;
end
$function$;

create or replace function public.admin_run_training_batch(p_run uuid, p_batch int default 20)
returns training_runs
language plpgsql
security definer
set search_path = 'public'
as $function$
declare
  v_run public.training_runs; v_n int; i int;
  v_host_deck text[]; v_guest_deck text[]; v_host_brain uuid; v_guest_brain uuid;
  v_result record; v_game public.matches; v_stats jsonb; v_roster jsonb; v_sim_game_id uuid;
  v_u jsonb; v_win text; v_carry_uid text; v_carry_score numeric;
  v_side text; v_cand_wins int; v_base_wins int; v_promote boolean;
begin
  perform admin_require_admin();
  select * into v_run from public.training_runs where id = p_run for update;
  if v_run.id is null then raise exception 'no such training run'; end if;
  if v_run.status in ('completed', 'cancelled', 'failed') then return v_run; end if;

  if v_run.status = 'pending' then
    update public.training_runs set status = 'running', started_at = now()
      where id = v_run.id returning * into v_run;
  end if;

  v_n := least(coalesce(p_batch, 20), v_run.games_requested - v_run.games_completed);
  for i in 1 .. greatest(v_n, 0) loop
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
    if v_win is not null then
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
         v_win is not null and v_u->>'owner' = v_win,
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
    if v_run.kind in ('teach', 'preview') and v_win is not null then
      v_side := case when v_host_brain = v_run.candidate_brain_id then 'host' else 'guest' end;
      if v_win = v_side then
        update public.bot_brains set games_played = games_played + 1, wins = wins + 1
          where id = v_run.candidate_brain_id;
        update public.bot_brains set games_played = games_played + 1, losses = losses + 1
          where id = v_run.baseline_brain_id;
      else
        update public.bot_brains set games_played = games_played + 1, losses = losses + 1
          where id = v_run.candidate_brain_id;
        update public.bot_brains set games_played = games_played + 1, wins = wins + 1
          where id = v_run.baseline_brain_id;
      end if;
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

-- Self-test A: a 'preview' run whose candidate has an overwhelming, forced
-- win record must still finish with promoted = false and must NOT touch
-- which brain is_live -- proving the promotion branch really is exclusive
-- to 'teach' now that 'preview' shares the rest of the code path with it.
-- games_completed is forced up to games_requested so the very next batch
-- call hits the completion branch immediately, with no dependency on the
-- game engine or random outcomes.
do $$
declare
  v_base_id uuid; v_run public.training_runs; v_after public.training_runs;
  v_live_after uuid;
begin
  -- admin_start_training_run/admin_run_training_batch are admin-gated
  -- (admin_require_admin(), which reads auth.uid()); this migration runs
  -- with no JWT, so impersonate a real admin profile for this transaction,
  -- the same way an actual admin's logged-in client would look to auth.uid().
  perform set_config('request.jwt.claim.sub', (select id::text from public.profiles where is_admin limit 1), true);

  select id into v_base_id from public.bot_brains where level = 3 and is_live limit 1;

  select * into v_run from public.admin_start_training_run('preview', 1, 3, '0117 self-test A');
  update public.bot_brains set wins = 999, losses = 0 where id = v_run.candidate_brain_id;
  update public.training_runs set games_completed = games_requested where id = v_run.id;

  select * into v_after from public.admin_run_training_batch(v_run.id, 5);

  if v_after.promoted then
    raise exception '0117 self-test A FAILED: a preview run promoted despite the promotion branch being teach-only';
  end if;
  select id into v_live_after from public.bot_brains where level = 3 and is_live limit 1;
  if v_live_after <> v_base_id then
    raise exception '0117 self-test A FAILED: is_live changed for a preview run (was %, now %)', v_base_id, v_live_after;
  end if;

  delete from public.training_runs where id = v_run.id;
  delete from public.bot_brains where id = v_run.candidate_brain_id;
  raise notice '0117 self-test A passed: preview run with a 999-0 candidate record still did not promote or touch is_live.';
end $$;

-- Self-test B: the exact same forced-win setup, but kind = 'teach', must
-- still promote -- proving 0114's original "Train" behaviour survives this
-- change untouched. The live brain is restored to its original id
-- immediately after the assertion so this test never leaves production's
-- live Expert brain pointed at a throwaway test candidate.
do $$
declare
  v_base_id uuid; v_run public.training_runs; v_after public.training_runs;
  v_live_after uuid;
begin
  perform set_config('request.jwt.claim.sub', (select id::text from public.profiles where is_admin limit 1), true);

  select id into v_base_id from public.bot_brains where level = 3 and is_live limit 1;

  select * into v_run from public.admin_start_training_run('teach', 1, 3, '0117 self-test B');
  update public.bot_brains set wins = 999, losses = 0 where id = v_run.candidate_brain_id;
  update public.training_runs set games_completed = games_requested where id = v_run.id;

  select * into v_after from public.admin_run_training_batch(v_run.id, 5);

  if not v_after.promoted then
    raise exception '0117 self-test B FAILED: a teach run with a 999-0 candidate record did not promote';
  end if;
  select id into v_live_after from public.bot_brains where level = 3 and is_live limit 1;
  if v_live_after <> v_run.candidate_brain_id then
    raise exception '0117 self-test B FAILED: is_live did not switch to the winning teach candidate';
  end if;

  -- restore production's real live brain before cleanup
  update public.bot_brains set is_live = false where level = 3 and is_live;
  update public.bot_brains set is_live = true where id = v_base_id;

  delete from public.training_runs where id = v_run.id;
  delete from public.bot_brains where id = v_run.candidate_brain_id;
  raise notice '0117 self-test B passed: teach run with a 999-0 candidate record promoted exactly as before, and the live brain was restored.';
end $$;

-- Self-test C: a real, small, end-to-end 'preview' run (actual games played
-- through sim_play_one_game, not the games_requested=0 shortcut above)
-- must (1) actually put the candidate brain on the board -- at least one
-- sim_games row referencing the candidate id -- and (2) never promote,
-- whatever the random outcome. This is the part self-tests A/B skip past.
do $$
declare
  v_base_id uuid; v_run public.training_runs; v_after public.training_runs;
  v_cand_appearances int; v_live_after uuid;
begin
  perform set_config('request.jwt.claim.sub', (select id::text from public.profiles where is_admin limit 1), true);

  select id into v_base_id from public.bot_brains where level = 3 and is_live limit 1;

  select * into v_run from public.admin_start_training_run('preview', 4, 3, '0117 self-test C');
  select * into v_after from public.admin_run_training_batch(v_run.id, 4);

  if v_after.games_completed <> 4 then
    raise exception '0117 self-test C FAILED: expected 4 games completed, got %', v_after.games_completed;
  end if;
  select count(*) into v_cand_appearances from public.sim_games
    where training_run_id = v_run.id
      and (host_brain_id = v_run.candidate_brain_id or guest_brain_id = v_run.candidate_brain_id);
  if v_cand_appearances <> 4 then
    raise exception '0117 self-test C FAILED: candidate brain should appear in all 4 games, appeared in %', v_cand_appearances;
  end if;
  if v_after.promoted then
    raise exception '0117 self-test C FAILED: a real preview run promoted';
  end if;
  select id into v_live_after from public.bot_brains where level = 3 and is_live limit 1;
  if v_live_after <> v_base_id then
    raise exception '0117 self-test C FAILED: is_live changed after a real preview run';
  end if;

  -- explicit p_run dashboards must read this preview run's own data back,
  -- exactly like they already do for 'teach'/'train' (0115) -- this is the
  -- wiring "Simulate matches" depends on to show real data with no changes
  -- to any of the seven dashboard/value functions.
  perform * from public.admin_card_performance(v_run.id);
  perform * from public.admin_card_value(v_run.id);

  delete from public.sim_unit_stats where training_run_id = v_run.id;
  delete from public.sim_games where training_run_id = v_run.id;
  delete from public.training_runs where id = v_run.id;
  delete from public.bot_brains where id = v_run.candidate_brain_id;
  raise notice '0117 self-test C passed: a real preview run plays the candidate for real, never promotes, and its data reads back through the existing dashboards.';
end $$;
