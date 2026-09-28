-- 0131's ALTER FUNCTION ... SET statement_timeout = '25s' did NOT fix it --
-- "Simulate matches" is still hitting "canceling statement due to statement
-- timeout" at the same ~8s mark (confirmed live in the logs after 0131 was
-- applied). A function's proconfig SET is documented to restore the PRIOR
-- value on exit, but evidently is not reliably re-arming the ALREADY-ACTIVE
-- statement-timeout deadline the way an explicit SET LOCAL inside the
-- function body does -- the belt-and-suspenders fix used everywhere else
-- (including this project's own SECURITY DEFINER admin functions) is an
-- explicit `perform set_config('statement_timeout', ..., true)` as the
-- FIRST statement in the function body, which is guaranteed to run through
-- the normal SET-command GUC assign-hook path and re-arm the timer for the
-- rest of this transaction. Keeping 0131's proconfig too (harmless,
-- belt-and-suspenders); this is the actual fix.
create or replace function public.admin_run_training_batch(p_run uuid, p_batch integer DEFAULT 20, p_deadline_seconds numeric DEFAULT 3)
 RETURNS training_runs
 LANGUAGE plpgsql
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
  -- See this migration's own header: 0131's function-level proconfig SET
  -- alone was not enough. An explicit SET LOCAL (via set_config's own
  -- is_local=true) is the well-documented, reliable way to lift the
  -- authenticator role's inherited statement_timeout=8s for the rest of
  -- THIS transaction, well above the ~14-15s batch window the caller
  -- (train-driver Edge Function) is designed to use.
  perform set_config('statement_timeout', '25000', true);

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
