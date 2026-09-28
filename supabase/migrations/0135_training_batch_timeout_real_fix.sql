-- Jared: "Still not being able to run even 50 matches... this sucks as it
-- is right now." Two prior attempts at this (0131, 0132) had zero
-- measurable effect -- every failure kept happening at ~8.1s regardless.
-- Root cause finally confirmed with hard evidence, not guessed:
--
-- Added a temporary diagnostic (RAISE WARNING at entry/each loop
-- iteration/loop end, applied to admin_run_training_batch) and triggered a
-- real "Simulate matches" run through the actual admin UI. postgrest_logs
-- for that request showed the true failure:
--   {"code":"57014","details":null,"hint":null,
--    "message":"canceling statement due to statement timeout"}
-- at 8.658s after the request began -- even though the diagnostic's own
-- current_setting('statement_timeout') printed "25s" at every single
-- iteration, proving the GUC value itself WAS being changed, but that
-- change had no effect on enforcement.
--
-- Why: Postgres arms the statement_timeout timer for a top-level
-- statement ONCE, using whatever value is in effect the moment that
-- statement starts executing. A set_config('statement_timeout', ...)
-- call made FROM INSIDE that same already-running statement (however
-- deep -- even from the very first line of the function the statement
-- calls) cannot retroactively push out a deadline that was already
-- armed before that line ever ran. Per Supabase's own docs
-- (supabase.com/docs/guides/database/postgres/timeouts#role-level):
-- "service_role: none (defaults to the authenticator role's 8s timeout
-- if unset)" -- and this project's service_role has never had its own
-- override (confirmed via pg_roles.rolconfig), so every RPC call made as
-- service_role -- including the train-driver Edge Function's own calls --
-- has silently been running under authenticator's 8s the whole time.
--
-- The other half of the bug: 0131/0132 both changed statement_timeout on
-- admin_run_training_batch -- but that is not the function PostgREST
-- actually calls. postgrest_logs shows the real RPC target is
-- admin_run_training_batch_as (the SECURITY DEFINER wrapper that
-- impersonates p_admin and then calls admin_run_training_batch
-- internally) -- confirmed via select pg_get_functiondef(oid). A
-- function-level SET statement_timeout only takes effect for the
-- function it's declared on; putting it on the INNER function it calls
-- is exactly as ineffective as putting it in the function body, for the
-- same underlying reason -- the outer statement's timer was already
-- armed before the inner function's SET clause is ever reached.
--
-- The fix: set it directly on the function PostgREST actually invokes.
-- (A role-level `alter role service_role set statement_timeout = '30s'`
-- plus `notify pgrst, 'reload config'` would be belt-and-suspenders
-- defense for every OTHER service_role call in the project too, but that
-- specific pair of statements was held back by a permission check on this
-- session as a system-wide change outside this migration's scope --
-- flagged to Jared separately. Not needed for THIS bug: retested through
-- the real admin UI after just the change below and watched a run pass
-- 60+ seconds and 50+ games with no failure, so the function-level fix
-- alone is confirmed sufficient.)
alter function public.admin_run_training_batch_as(uuid, uuid, integer, numeric)
  set statement_timeout = '30s';

-- Clean up the temporary diagnostic and the now-confirmed-ineffective
-- set_config call from admin_run_training_batch, restoring it to its
-- pre-0131 shape (its own timeout is no longer this function's job --
-- the wrapper above now covers the whole call).
create or replace function public.admin_run_training_batch(p_run uuid, p_batch integer DEFAULT 20, p_deadline_seconds numeric DEFAULT 3)
 returns training_runs
 language plpgsql
 set search_path to 'public'
as $function$
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
    end if;

    update public.training_runs set games_completed = games_completed + 1
      where id = v_run.id returning * into v_run;
  end loop;

  if v_run.games_completed >= v_run.games_requested then
    v_promote := false;

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
