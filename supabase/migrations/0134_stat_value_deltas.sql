-- Jared: "remove the + sign here [the stat-value tiles]... below it, do the
-- same as with the other cards: showing if there was an increment or
-- decrement in comparison with the previous batch of simulated games (with
-- + or - respectively)"
--
-- Mirrors the existing per-card delta pattern (admin_value_snapshots /
-- admin_card_value_deltas) for the top-of-page stat-value tiles (1 HP / 1
-- Attack point / 1 Range point / 1 Move point). A new snapshot table stores
-- the regression coefficients from admin_stat_value_model() at the moment
-- of the last Simulate batch (admin_snapshot_pre_batch_values(), already
-- called client-side right before every Simulate run, is extended to also
-- populate this table), and a new admin_stat_value_deltas() RPC diffs the
-- CURRENT model against that snapshot the same way admin_card_value_deltas()
-- already does for cards.

create table public.admin_stat_value_snapshots (
  metric text primary key,
  value numeric not null,
  snapshotted_at timestamptz not null default now()
);

alter table public.admin_stat_value_snapshots enable row level security;

create policy "admins read stat value snapshots" on public.admin_stat_value_snapshots
  for select to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin));

create or replace function public.admin_snapshot_pre_batch_values()
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  perform admin_require_admin();
  insert into public.admin_value_snapshots (card_slug, win_rate, ability_value, snapshotted_at)
  select card_slug, win_rate, ability_value, now()
  from public.admin_card_value(null)
  on conflict (card_slug) do update
    set win_rate = excluded.win_rate,
        ability_value = excluded.ability_value,
        snapshotted_at = excluded.snapshotted_at;

  insert into public.admin_stat_value_snapshots (metric, value, snapshotted_at)
  select metric, value, now()
  from public.admin_stat_value_model(null)
  where metric in ('intercept', 'power_point', 'hp_point', 'range_point', 'move_point')
  on conflict (metric) do update
    set value = excluded.value,
        snapshotted_at = excluded.snapshotted_at;
end;
$function$;

create or replace function public.admin_stat_value_deltas(p_run uuid default null::uuid)
 returns table(metric text, delta_value numeric, has_snapshot boolean)
 language sql
 stable
as $function$
  select v.metric,
    case when s.metric is not null then v.value - s.value else null end as delta_value,
    (s.metric is not null) as has_snapshot
  from public.admin_stat_value_model(p_run) v
  left join public.admin_stat_value_snapshots s on s.metric = v.metric
  where v.metric in ('intercept', 'power_point', 'hp_point', 'range_point', 'move_point')
$function$;

-- No explicit grants needed: default Postgres privileges on a table/function
-- created by the postgres/service role already extend to anon/authenticated/
-- service_role the same way they do for admin_value_snapshots and
-- admin_card_value_deltas -- verified directly against pg_catalog after
-- applying this migration (information_schema.table_privileges /
-- has_function_privilege() for all 4 roles all matched the existing,
-- working objects with no extra grant statements run).
