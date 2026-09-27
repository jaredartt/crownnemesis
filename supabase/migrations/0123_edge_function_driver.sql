-- Move the batch-driving loop for "Simulate matches" out of the browser's
-- PostgREST round trip (authenticated role, 8s statement_timeout, and the
-- run stalls the instant the browser tab closes) and into a Supabase Edge
-- Function that drives it server-side instead.
--
-- Two changes make that possible:
--
--   1. admin_run_training_batch's internal wall-clock deadline (0121/0122)
--      becomes a parameter instead of a hardcoded 3 seconds. The browser
--      still calls it directly today with the old default -- unchanged,
--      still safe under authenticated's 8s ceiling. The edge function will
--      pass a longer deadline of its own choosing, since it calls through
--      as service_role, which has no statement_timeout at all.
--
--   2. admin_run_training_batch_as(): a service_role-only entry point.
--      admin_run_training_batch itself gates on admin_require_admin(),
--      which reads auth.uid() -- and a service_role JWT has no `sub`
--      claim, so auth.uid() is always null there and that check would
--      always fail. This wrapper verifies the caller-supplied admin id is
--      a real admin itself (defense in depth -- it's also simply not
--      grantable to anon/authenticated, see the revokes below),
--      impersonates them for auth.uid() the same way this file's own
--      self-tests already do, then calls through. Only service_role can
--      ever call it.

-- create or replace can't change a function's parameter list -- the old
-- 2-arg signature has to go first, or it stays around as a second,
-- ambiguous overload (which is exactly what happened on the first attempt
-- at this migration: "function ... is not unique").
drop function if exists public.admin_run_training_batch(uuid, integer);

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
  -- 0123: p_deadline_seconds is now caller-supplied instead of hardcoded,
  -- so admin_run_training_batch_as (running as service_role, no
  -- statement_timeout) can ask for a longer window per call than a
  -- browser-driven authenticated call (8s ceiling) ever safely could.
  v_deadline := clock_timestamp() + make_interval(secs => greatest(0.5, coalesce(p_deadline_seconds, 3)));

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

create or replace function public.admin_run_training_batch_as(
  p_admin uuid, p_run uuid, p_batch integer default 20, p_deadline_seconds numeric default 3
)
 RETURNS training_runs
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not exists (select 1 from public.profiles where id = p_admin and is_admin) then
    raise exception 'admins only';
  end if;
  -- Same impersonation trick this file's own self-tests use: sets the GUC
  -- auth.uid() reads, for this transaction only, without needing a real
  -- user JWT (service_role's JWT has no `sub` claim to read in the first
  -- place).
  perform set_config('request.jwt.claim.sub', p_admin::text, true);
  return public.admin_run_training_batch(p_run, p_batch, p_deadline_seconds);
end
$function$;

-- Postgres grants EXECUTE to PUBLIC by default on a new function -- and
-- PUBLIC includes anon and authenticated. This function must be reachable
-- ONLY by service_role (the edge function's key), never by a browser
-- calling it directly as any user, admin or not -- the p_admin check above
-- is defense in depth, not the actual access boundary.
revoke all on function public.admin_run_training_batch_as(uuid, uuid, integer, numeric) from public;
revoke all on function public.admin_run_training_batch_as(uuid, uuid, integer, numeric) from anon;
revoke all on function public.admin_run_training_batch_as(uuid, uuid, integer, numeric) from authenticated;
grant execute on function public.admin_run_training_batch_as(uuid, uuid, integer, numeric) to service_role;

-- Self-tests -----------------------------------------------------------
do $$
declare
  v_admin uuid; v_non_admin uuid; v_level int := 3; v_base_id uuid; v_run public.training_runs;
  v_ms numeric; t0 timestamptz; v_can_auth boolean; v_can_anon boolean;
begin
  select id into v_admin from public.profiles where is_admin limit 1;
  select id into v_non_admin from public.profiles where not is_admin limit 1;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  select id into v_base_id from public.bot_brains where level = v_level and is_live limit 1;

  -- Test A: authenticated and anon must NOT be able to execute
  -- admin_run_training_batch_as at all (grant-level, not just the p_admin
  -- check inside it).
  select has_function_privilege('authenticated', 'public.admin_run_training_batch_as(uuid,uuid,integer,numeric)', 'execute')
    into v_can_auth;
  select has_function_privilege('anon', 'public.admin_run_training_batch_as(uuid,uuid,integer,numeric)', 'execute')
    into v_can_anon;
  if v_can_auth or v_can_anon then
    raise exception '0123 self-test A FAILED: admin_run_training_batch_as must be service_role-only, got authenticated=%, anon=%', v_can_auth, v_can_anon;
  end if;
  raise notice '0123 self-test A passed: admin_run_training_batch_as is unreachable by authenticated/anon.';

  insert into public.training_runs
    (kind, level, games_requested, games_completed, status, candidate_brain_id, baseline_brain_id)
    values ('preview', v_level, 30, 0, 'pending', v_base_id, v_base_id)
    returning * into v_run;

  -- Test B: a non-admin p_admin is rejected even though the caller (us,
  -- inside this do-block) is an admin -- the check inside the function is
  -- on p_admin, not on whoever is calling it.
  if v_non_admin is not null then
    begin
      perform public.admin_run_training_batch_as(v_non_admin, v_run.id, 5, 3);
      raise exception '0123 self-test B FAILED: admin_run_training_batch_as accepted a non-admin p_admin';
    exception when others then
      if sqlerrm not like '%admins only%' then raise; end if;
      raise notice '0123 self-test B passed: a non-admin p_admin is rejected.';
    end;
  else
    raise notice '0123 self-test B skipped: no non-admin profile exists to test against.';
  end if;

  -- Test C: the real path -- a real admin id, a custom (longer) deadline,
  -- same shape of call the edge function will make. Also proves
  -- p_deadline_seconds actually reaches sim_play_one_game unchanged
  -- (games_completed advances, no error).
  t0 := clock_timestamp();
  select * into v_run from public.admin_run_training_batch_as(v_admin, v_run.id, 30, 6);
  v_ms := extract(epoch from (clock_timestamp() - t0)) * 1000;
  raise notice '0123 self-test C: batch call took %ms, games_completed=%, status=%',
    round(v_ms), v_run.games_completed, v_run.status;
  if v_run.games_completed <= 0 then
    raise exception '0123 self-test C FAILED: admin_run_training_batch_as made no progress on the run';
  end if;
  if v_ms > 7000 then
    raise exception '0123 self-test C FAILED: batch call took %ms, longer than its 6s deadline plus slack', round(v_ms);
  end if;
  raise notice '0123 self-test C passed: admin_run_training_batch_as drives the run and respects a custom deadline.';

  -- Test D: default p_deadline_seconds (3) on admin_run_training_batch
  -- itself is unchanged for direct (browser/authenticated) callers.
  t0 := clock_timestamp();
  select * into v_run from public.admin_run_training_batch(v_run.id, 30);
  v_ms := extract(epoch from (clock_timestamp() - t0)) * 1000;
  if v_ms > 4000 then
    raise exception '0123 self-test D FAILED: default-deadline call took %ms, expected close to 3s', round(v_ms);
  end if;
  raise notice '0123 self-test D passed: admin_run_training_batch''s old 3s default is unchanged (%ms).', round(v_ms);

  -- cleanup
  delete from public.match_deploy where match_id in (
    select id from public.matches where sim_run_id = v_run.id);
  delete from public.sim_unit_stats where training_run_id = v_run.id;
  delete from public.sim_games where training_run_id = v_run.id;
  delete from public.matches where sim_run_id = v_run.id;
  delete from public.training_runs where id = v_run.id;
end $$;
