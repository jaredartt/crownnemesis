-- Testing admin_activity_summary() against real data caught a real bug:
-- the three matchTypes buckets ('ranked', 'botPractice', 'casual') were not
-- mutually exclusive -- a "ranked fallback matched you against a bot"
-- match (ranked = true AND bot is not null, a real, shipped case) counted
-- in BOTH 'ranked' and 'botPractice', so the three numbers could sum to
-- more than totals.matches1v1 and read as self-contradictory on a
-- dashboard whose whole point is trustworthy numbers. 'vs a bot' now wins
-- that overlap (a bot opponent is the more informative fact -- ranked LP
-- still moved, but no other human was involved), and ranked/casual are
-- each restricted to a real opponent, so the three always sum to the
-- exact total.
do $$
declare def text; v_before text;
begin
  def := pg_get_functiondef('public.admin_activity_summary(integer)'::regprocedure);
  v_before := def;
  def := replace(def,
    $q$  select jsonb_build_object(
    'ranked', (select count(*) from public.matches where status = 'finished' and not is_sim and ranked),
    'botPractice', (select count(*) from public.matches
                      where status = 'finished' and not is_sim and (bot is not null or host_bot is not null)),
    'casual', (select count(*) from public.matches
                 where status = 'finished' and not is_sim and not ranked and bot is null and host_bot is null)
  ) into v_types;$q$,
    $q$  select jsonb_build_object(
    'ranked', (select count(*) from public.matches
                 where status = 'finished' and not is_sim and ranked and bot is null and host_bot is null),
    'botPractice', (select count(*) from public.matches
                      where status = 'finished' and not is_sim and (bot is not null or host_bot is not null)),
    'casual', (select count(*) from public.matches
                 where status = 'finished' and not is_sim and not ranked and bot is null and host_bot is null)
  ) into v_types;$q$);
  if def = v_before then raise exception 'admin_activity_summary -- matchTypes block not found'; end if;
  execute def;
end $$;
