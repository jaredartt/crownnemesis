-- 0217: report a player, from their profile card. Players write; only the super
-- admin reads and updates (Admin Mode -> Reports). report_user() is the only way
-- in: it refuses yourself and system accounts, a second report of the same
-- player within 24 hours, and more than 10 reports a day.
create table if not exists public.user_reports (
  id          uuid primary key default gen_random_uuid(),
  reporter_id uuid not null,
  reported_id uuid not null,
  reason      text not null check (reason in ('cheating','offensive_name','offensive_profile','harassment','spam','other')),
  details     text not null default '' check (char_length(details) <= 500),
  match_id    uuid,
  status      text not null default 'open' check (status in ('open','actioned','dismissed')),
  admin_note  text,
  created_at  timestamptz not null default now(),
  resolved_at timestamptz
);
create index if not exists user_reports_status_created on public.user_reports (status, created_at desc);
create index if not exists user_reports_reported on public.user_reports (reported_id);
alter table public.user_reports enable row level security;
create policy "super admin reads reports"   on public.user_reports for select using (cn_is_super_admin());
create policy "super admin updates reports" on public.user_reports for update using (cn_is_super_admin());

create or replace function public.report_user(p_user uuid, p_reason text, p_details text default '', p_match uuid default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_me uuid := auth.uid();
begin
  if v_me is null then raise exception 'sign in first'; end if;
  if p_user is null or p_user = v_me then raise exception 'you cannot report yourself'; end if;
  if not exists (select 1 from public.profiles where id = p_user and not coalesce(is_system, false)) then
    raise exception 'that account cannot be reported';
  end if;
  if exists (select 1 from public.user_reports where reporter_id = v_me and reported_id = p_user
               and created_at > now() - interval '24 hours') then
    raise exception 'you already reported this player today';
  end if;
  if (select count(*) from public.user_reports where reporter_id = v_me and created_at > now() - interval '24 hours') >= 10 then
    raise exception 'you have sent too many reports today';
  end if;
  insert into public.user_reports (reporter_id, reported_id, reason, details, match_id)
  values (v_me, p_user, p_reason, left(coalesce(p_details, ''), 500), p_match);
end $$;

create or replace function public.admin_reports(p_status text default 'open')
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v jsonb;
begin
  if not cn_is_super_admin() then raise exception 'admin only'; end if;
  select coalesce(jsonb_agg(x order by (x->>'created_at') desc), '[]'::jsonb) into v from (
    select jsonb_build_object(
      'id', r.id, 'reason', r.reason, 'details', r.details, 'status', r.status, 'note', r.admin_note,
      'created_at', r.created_at, 'resolved_at', r.resolved_at, 'match_id', r.match_id,
      'reporter_id', r.reporter_id, 'reporter', rp.username,
      'reported_id', r.reported_id, 'reported', dp.username, 'reported_banned', coalesce(dp.is_banned, false),
      'reports_30d', (select count(*) from public.user_reports o where o.reported_id = r.reported_id and o.created_at > now() - interval '30 days')
    ) x
    from public.user_reports r
    left join public.profiles rp on rp.id = r.reporter_id
    left join public.profiles dp on dp.id = r.reported_id
    where p_status = 'all' or r.status = p_status
    limit 200) s;
  return v;
end $$;

create or replace function public.admin_resolve_report(p_id uuid, p_status text, p_note text default null)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not cn_is_super_admin() then raise exception 'admin only'; end if;
  if p_status not in ('open','actioned','dismissed') then raise exception 'bad status'; end if;
  update public.user_reports set status = p_status, admin_note = p_note,
         resolved_at = case when p_status = 'open' then null else now() end where id = p_id;
end $$;

revoke all on function public.report_user(uuid,text,text,uuid), public.admin_reports(text), public.admin_resolve_report(uuid,text,text) from public, anon;
grant execute on function public.report_user(uuid,text,text,uuid), public.admin_reports(text), public.admin_resolve_report(uuid,text,text) to authenticated;
