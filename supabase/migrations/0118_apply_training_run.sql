-- Train no longer runs its own games. Jared's correction:
-- "Simulate obtains the data. Train applies the data obtained from
-- Simulate." So Train becomes a single, instant action: it takes the
-- most recent completed Simulate (kind='preview') run -- the very
-- candidate and the very games Simulate already played -- and, if that
-- candidate actually won more of those games than the live bot did,
-- promotes it live. No new mutation, no new games, no fixed game count.
-- If the candidate didn't win, Train applies nothing and says so.
--
-- The win/loss counts to decide on are already sitting in
-- training_runs.summary (candidate_wins/baseline_wins), written by
-- admin_run_training_batch (0117) for every completed preview run --
-- Train just reads them.

create or replace function public.admin_apply_training_run(p_run uuid)
returns public.training_runs
language plpgsql
security definer
set search_path = public
as $$
declare
  v_run public.training_runs;
  v_cand_wins int;
  v_base_wins int;
  v_promote boolean;
begin
  perform public.admin_require_admin();

  select * into v_run from public.training_runs where id = p_run for update;
  if v_run.id is null then
    raise exception 'training run not found';
  end if;
  if v_run.kind <> 'preview' then
    raise exception 'Train can only apply a Simulate matches run';
  end if;
  if v_run.status <> 'completed' then
    raise exception 'this Simulate run has not finished yet';
  end if;

  -- Idempotent: a run already promoted stays promoted, no re-decision.
  if v_run.promoted then
    return v_run;
  end if;

  v_cand_wins := coalesce((v_run.summary->>'candidate_wins')::int, 0);
  v_base_wins := coalesce((v_run.summary->>'baseline_wins')::int, 0);
  v_promote := v_cand_wins > v_base_wins;

  if v_promote then
    update public.bot_brains set is_live = false where level = v_run.level and is_live;
    update public.bot_brains set is_live = true where id = v_run.candidate_brain_id;
  end if;

  update public.training_runs
    set promoted = v_promote,
        summary = coalesce(summary, '{}'::jsonb)
          || jsonb_build_object('applied', true, 'promoted', v_promote)
    where id = p_run
    returning * into v_run;

  return v_run;
end;
$$;

grant execute on function public.admin_apply_training_run(uuid) to authenticated;

-- Self-tests -----------------------------------------------------------
do $$
declare
  v_admin uuid;
  v_level int := 3;
  v_base_id uuid;
  v_cand_id uuid;
  v_run public.training_runs;
  v_run_a_id uuid;
  v_result public.training_runs;
  v_live_after uuid;
begin
  select id into v_admin from public.profiles where is_admin limit 1;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);

  select id into v_base_id from public.bot_brains where level = v_level and is_live limit 1;

  -- Test A: a winning candidate gets promoted.
  insert into public.bot_brains (label, level, weights, is_live, parent_id, notes, created_by)
    select '0118 self-test candidate A', v_level, weights, false, id, 'self-test', created_by
    from public.bot_brains where id = v_base_id
    returning id into v_cand_id;

  insert into public.training_runs
    (kind, level, games_requested, games_completed, status, promoted,
     candidate_brain_id, baseline_brain_id, summary)
    values ('preview', v_level, 10, 10, 'completed', false,
            v_cand_id, v_base_id, jsonb_build_object('games', 10, 'candidate_wins', 7, 'baseline_wins', 3, 'promoted', false))
    returning * into v_run;
  v_run_a_id := v_run.id;

  select * into v_result from public.admin_apply_training_run(v_run.id);
  if v_result.promoted is not true then
    raise exception '0118 self-test A FAILED: winning candidate was not promoted';
  end if;
  select id into v_live_after from public.bot_brains where level = v_level and is_live limit 1;
  if v_live_after <> v_cand_id then
    raise exception '0118 self-test A FAILED: is_live did not switch to the winning candidate';
  end if;

  -- restore the real live brain before continuing
  update public.bot_brains set is_live = false where level = v_level and is_live;
  update public.bot_brains set is_live = true where id = v_base_id;
  raise notice '0118 self-test A passed: Train promoted the winning Simulate candidate.';

  -- Test B: a losing candidate is left alone.
  insert into public.bot_brains (label, level, weights, is_live, parent_id, notes, created_by)
    select '0118 self-test candidate B', v_level, weights, false, id, 'self-test', created_by
    from public.bot_brains where id = v_base_id
    returning id into v_cand_id;

  insert into public.training_runs
    (kind, level, games_requested, games_completed, status, promoted,
     candidate_brain_id, baseline_brain_id, summary)
    values ('preview', v_level, 10, 10, 'completed', false,
            v_cand_id, v_base_id, jsonb_build_object('games', 10, 'candidate_wins', 2, 'baseline_wins', 8, 'promoted', false))
    returning * into v_run;

  select * into v_result from public.admin_apply_training_run(v_run.id);
  if v_result.promoted is not false then
    raise exception '0118 self-test B FAILED: losing candidate was promoted';
  end if;
  select id into v_live_after from public.bot_brains where level = v_level and is_live limit 1;
  if v_live_after <> v_base_id then
    raise exception '0118 self-test B FAILED: is_live changed for a losing candidate';
  end if;
  raise notice '0118 self-test B passed: Train left a losing candidate alone.';

  -- Test C: applying an already-promoted run twice is a no-op, not an error.
  select * into v_result from public.admin_apply_training_run(v_run_a_id);
  if v_result.promoted is not true then
    raise exception '0118 self-test C FAILED: re-applying a promoted run changed its outcome';
  end if;
  raise notice '0118 self-test C passed: re-applying an already-promoted run is a safe no-op.';

  -- Test D: kind guard -- a 'teach' run cannot be applied via Train.
  insert into public.bot_brains (label, level, weights, is_live, parent_id, notes, created_by)
    select '0118 self-test candidate D', v_level, weights, false, id, 'self-test', created_by
    from public.bot_brains where id = v_base_id
    returning id into v_cand_id;
  insert into public.training_runs
    (kind, level, games_requested, games_completed, status, promoted,
     candidate_brain_id, baseline_brain_id, summary)
    values ('teach', v_level, 10, 10, 'completed', false,
            v_cand_id, v_base_id, jsonb_build_object('games', 10, 'candidate_wins', 9, 'baseline_wins', 1, 'promoted', false))
    returning * into v_run;

  begin
    perform public.admin_apply_training_run(v_run.id);
    raise exception '0118 self-test D FAILED: applying a non-preview run did not raise';
  exception when others then
    if sqlerrm not like '%only apply a Simulate%' then
      raise exception '0118 self-test D FAILED: wrong error (%)', sqlerrm;
    end if;
  end;
  raise notice '0118 self-test D passed: only a Simulate (preview) run can be applied.';

  -- cleanup
  delete from public.training_runs where candidate_brain_id in (
    select id from public.bot_brains
    where label in ('0118 self-test candidate A', '0118 self-test candidate B', '0118 self-test candidate D')
  );
  delete from public.bot_brains
    where label in ('0118 self-test candidate A', '0118 self-test candidate B', '0118 self-test candidate D');
end $$;
