-- Jared: "as an admin, I think it would be cool to know all the data that
-- is happening in the game... last connection of each player, how many
-- matches they have played, how many matches were played in each day,
-- statistics summaries by day, week, month. Also, any data that could be
-- cool to know so that I can improve the game." Two admin-only RPCs, same
-- SECURITY DEFINER + cn_is_super_admin() gate every other admin_* function
-- in this codebase already uses (see admin_list_banned() for the pattern).
--
-- admin_player_activity(): one row per real (not is_system) account, with
-- user_presence's own seen_at as "last connection" -- the exact same
-- column PlayerCard.tsx's friend-only last-seen already reads, just with
-- no friendship requirement here since the whole point of this screen is
-- seeing everyone. Match counts are computed fresh from `matches`/
-- `royale_players` rather than trusted off profiles.games, which is a
-- running counter that predates this feature and was never audited against
-- what this screen needs to show.
--
-- admin_activity_summary(days): the day-by-day series a chart needs (every
-- day in the window, zero-filled, not just the days something happened) plus
-- a totals block -- DAU/WAU/MAU read off user_presence's LATEST seen_at per
-- user (that table has no history, so these three numbers are always "as of
-- right now", not a reconstructed past trend -- the daily series below is
-- the only real trend line this data can support). Weekly/monthly rollups
-- are left to the client: summing groups of days out of one daily series is
-- simpler and just as correct as a second/third SQL grouping level, and it
-- means the client can re-bucket without another round trip.
create or replace function public.admin_player_activity()
returns table (
  id uuid,
  username text,
  avatar text,
  name_color text,
  is_admin boolean,
  is_banned boolean,
  created_at timestamptz,
  last_seen_at timestamptz,
  rating integer,
  wins integer,
  losses integer,
  games integer,
  streak integer,
  tournaments integer,
  matches_1v1 bigint,
  matches_royale bigint
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not cn_is_super_admin() then raise exception 'admin only'; end if;
  return query
  select
    p.id, p.username, p.avatar, p.name_color, p.is_admin, p.is_banned,
    p.created_at, up.seen_at,
    coalesce(r.rating, 1000), p.wins, p.losses, p.games, p.streak, p.tournaments,
    coalesce(m1.n, 0), coalesce(mr.n, 0)
  from public.profiles p
  left join public.user_presence up on up.user_id = p.id
  left join public.player_rating r on r.user_id = p.id
  left join lateral (
    select count(*) as n from public.matches mm
    where mm.status = 'finished' and not mm.is_sim
      and (mm.host_id = p.id or mm.guest_id = p.id)
  ) m1 on true
  left join lateral (
    select count(*) as n from public.royale_players rp
    join public.royale_matches rm on rm.id = rp.match_id
    where rm.status = 'finished' and rp.user_id = p.id
  ) mr on true
  where not p.is_system
  order by up.seen_at desc nulls last;
end $$;

grant execute on function public.admin_player_activity() to authenticated;

create or replace function public.admin_activity_summary(p_days integer default 30)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_days int := greatest(1, least(180, coalesce(p_days, 30)));
  v_totals jsonb;
  v_types jsonb;
  v_daily jsonb;
begin
  if not cn_is_super_admin() then raise exception 'admin only'; end if;

  select jsonb_build_object(
    'players', (select count(*) from public.profiles where not is_system),
    'matches1v1', (select count(*) from public.matches where status = 'finished' and not is_sim),
    'matchesRoyale', (select count(*) from public.royale_matches where status = 'finished'),
    'tournamentsFinished', (select count(*) from public.tournaments where status = 'finished'),
    'signupsToday', (select count(*) from public.profiles where not is_system and created_at >= date_trunc('day', now())),
    'signups7d', (select count(*) from public.profiles where not is_system and created_at >= now() - interval '7 days'),
    'signups30d', (select count(*) from public.profiles where not is_system and created_at >= now() - interval '30 days'),
    'dau', (select count(distinct up.user_id) from public.user_presence up
              join public.profiles p on p.id = up.user_id
              where not p.is_system and up.seen_at >= now() - interval '1 day'),
    'wau', (select count(distinct up.user_id) from public.user_presence up
              join public.profiles p on p.id = up.user_id
              where not p.is_system and up.seen_at >= now() - interval '7 days'),
    'mau', (select count(distinct up.user_id) from public.user_presence up
              join public.profiles p on p.id = up.user_id
              where not p.is_system and up.seen_at >= now() - interval '30 days'),
    'openFeedback', (select count(*) from public.feedback where not resolved)
  ) into v_totals;

  -- bot practice matches can have EITHER seat played by the house bot
  -- (host_bot for the "ranked fallback" case, bot for the original practice
  -- flow) -- see 0176's own header for why both columns exist. Best-effort
  -- classification, not a hard guarantee every edge case lands right.
  select jsonb_build_object(
    'ranked', (select count(*) from public.matches where status = 'finished' and not is_sim and ranked),
    'botPractice', (select count(*) from public.matches
                      where status = 'finished' and not is_sim and (bot is not null or host_bot is not null)),
    'casual', (select count(*) from public.matches
                 where status = 'finished' and not is_sim and not ranked and bot is null and host_bot is null)
  ) into v_types;

  select coalesce(jsonb_agg(jsonb_build_object(
    'date', to_char(d.day, 'YYYY-MM-DD'),
    'matches1v1', coalesce(m1.n, 0),
    'matchesRoyale', coalesce(mr.n, 0),
    'signups', coalesce(su.n, 0)
  ) order by d.day), '[]'::jsonb)
  into v_daily
  from generate_series(
    date_trunc('day', now()) - (v_days - 1) * interval '1 day',
    date_trunc('day', now()),
    interval '1 day'
  ) as d(day)
  left join lateral (
    select count(*) as n from public.matches mm
    where mm.status = 'finished' and not mm.is_sim
      and date_trunc('day', mm.updated_at) = d.day
  ) m1 on true
  left join lateral (
    select count(*) as n from public.royale_matches rm
    where rm.status = 'finished'
      and date_trunc('day', rm.updated_at) = d.day
  ) mr on true
  left join lateral (
    select count(*) as n from public.profiles p
    where not p.is_system
      and date_trunc('day', p.created_at) = d.day
  ) su on true;

  return jsonb_build_object('totals', v_totals, 'matchTypes', v_types, 'daily', v_daily);
end $$;

grant execute on function public.admin_activity_summary(integer) to authenticated;

-- Jared: "create a button inside settings to send feedback or report a
-- bug." Same shape as 0062_ban_appeals.sql throughout -- one small table,
-- RLS enabled with NO policies (every real access goes through a
-- SECURITY DEFINER RPC below, so a bare `select`/`insert` from a signed-in
-- client is refused outright), a submit_* RPC for the player, and an
-- admin_list_*/admin_resolve_* pair for the one account allowed to read it.
create table public.feedback (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('bug', 'feedback')),
  message text not null,
  resolved boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.feedback enable row level security;

create or replace function public.submit_feedback(p_kind text, p_message text)
returns public.feedback
language plpgsql
security definer
set search_path = public
as $$
declare v_row public.feedback;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if p_kind not in ('bug', 'feedback') then raise exception 'invalid kind'; end if;
  if length(btrim(coalesce(p_message, ''))) = 0 then raise exception 'say something first'; end if;
  if length(p_message) > 4000 then raise exception 'that is too long'; end if;

  insert into public.feedback (user_id, kind, message)
    values (auth.uid(), p_kind, btrim(p_message))
    returning * into v_row;
  return v_row;
end $$;

grant execute on function public.submit_feedback(text, text) to authenticated;

create or replace function public.admin_list_feedback()
returns table (
  id uuid,
  user_id uuid,
  username text,
  name_color text,
  kind text,
  message text,
  resolved boolean,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not cn_is_super_admin() then raise exception 'admin only'; end if;
  return query
  select f.id, f.user_id, p.username, p.name_color, f.kind, f.message, f.resolved, f.created_at
  from public.feedback f
  join public.profiles p on p.id = f.user_id
  order by f.resolved asc, f.created_at desc;
end $$;

grant execute on function public.admin_list_feedback() to authenticated;

create or replace function public.admin_resolve_feedback(p_id uuid, p_resolved boolean)
returns public.feedback
language plpgsql
security definer
set search_path = public
as $$
declare v_row public.feedback;
begin
  if not cn_is_super_admin() then raise exception 'admin only'; end if;
  update public.feedback set resolved = p_resolved where id = p_id returning * into v_row;
  if v_row.id is null then raise exception 'no such feedback'; end if;
  return v_row;
end $$;

grant execute on function public.admin_resolve_feedback(uuid, boolean) to authenticated;
