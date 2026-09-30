-- !!! NOT APPLIED to the live database yet -- the apply was blocked and is waiting on Jared (see project_status 77aa). !!!
-- 0196: abuse limits (security review follow-up to 0195).
--
--  * anon can no longer call ANY public function (the game never calls one
--    signed out); the bot/sweep/timeout RPCs are signed-in only, and the two
--    sweeps are throttled so a loop of calls costs one scan per 3 seconds.
--  * per-account limits on the things a script could spam: rooms, chat,
--    friend requests, feedback, tournament joins; notification inbox capped;
--    heartbeat writes that arrive too fast are dropped before they hit the
--    table (and so never reach Realtime).
--  * tournament sign-up needs one finished game first (Vs Bots counts), so
--    a throwaway account can't just join and never show.

-- ---- small tools ------------------------------------------------------------
create table if not exists public.cn_rate (
  user_id uuid not null, key text not null,
  win_start timestamptz not null default now(), n integer not null default 0,
  primary key (user_id, key));
alter table public.cn_rate enable row level security;
revoke all on public.cn_rate from anon, authenticated;

-- A fixed-window counter per (account, key). A refused call rolls back its own
-- increment, so the counter sits at the limit until the window ends.
create or replace function public.cn_hit(p_key text, p_limit integer, p_secs integer, p_msg text default 'slow down a little')
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := auth.uid(); v_n integer;
begin
  if v_uid is null then return; end if;
  insert into public.cn_rate (user_id, key, win_start, n) values (v_uid, p_key, now(), 1)
  on conflict (user_id, key) do update set
    win_start = case when public.cn_rate.win_start < now() - make_interval(secs => p_secs) then now() else public.cn_rate.win_start end,
    n         = case when public.cn_rate.win_start < now() - make_interval(secs => p_secs) then 1 else public.cn_rate.n + 1 end
  returning n into v_n;
  if v_n > p_limit then raise exception '%', p_msg; end if;
end $$;
revoke all on function public.cn_hit(text, integer, integer, text) from public, anon, authenticated;

create table if not exists public.cn_throttle (key text primary key, at timestamptz not null default now());
alter table public.cn_throttle enable row level security;
revoke all on public.cn_throttle from anon, authenticated;

-- true at most once per p_secs, site-wide.
create or replace function public.cn_throttle_ok(p_key text, p_secs numeric)
returns boolean language plpgsql security definer set search_path to 'public' as $$
declare v integer;
begin
  insert into public.cn_throttle (key, at) values (p_key, now())
  on conflict (key) do update set at = now()
    where public.cn_throttle.at < now() - make_interval(secs => p_secs);
  get diagnostics v = row_count;
  return v > 0;
end $$;
revoke all on function public.cn_throttle_ok(text, numeric) from public, anon, authenticated;

-- ---- the sweeps: same work, at most once per 3 seconds ----------------------
alter function public.sweep_matches() rename to cn_sweep_matches_impl;
alter function public.sweep_royale_matches() rename to cn_sweep_royale_matches_impl;
revoke all on function public.cn_sweep_matches_impl() from public, anon, authenticated;
revoke all on function public.cn_sweep_royale_matches_impl() from public, anon, authenticated;

create or replace function public.sweep_matches()
returns integer language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.cn_throttle_ok('sweep_matches', 3) then return 0; end if;
  return public.cn_sweep_matches_impl();
end $$;
create or replace function public.sweep_royale_matches()
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.cn_throttle_ok('sweep_royale_matches', 3) then return; end if;
  perform public.cn_sweep_royale_matches_impl();
end $$;

-- ---- per-account limits (triggers, so no engine function is touched) -------
create or replace function public.cn_trg_matches_rate() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null or new.host_id is distinct from v_uid or coalesce(new.is_sim, false) then return new; end if;
  perform public.cn_hit('match_create', 12, 60, 'you are creating matches too fast -- wait a moment');
  if new.status = 'waiting' and (select count(*) from public.matches where host_id = v_uid and status = 'waiting') >= 5 then
    raise exception 'you already have several open rooms -- close one first';
  end if;
  return new;
end $$;
drop trigger if exists cn_rate_matches on public.matches;
create trigger cn_rate_matches before insert on public.matches
  for each row execute function public.cn_trg_matches_rate();

create or replace function public.cn_trg_royale_rate() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is not null and new.seat = 0 and new.bot is null and new.user_id is not distinct from auth.uid() then
    perform public.cn_hit('royale_create', 8, 60, 'you are creating matches too fast -- wait a moment');
  end if;
  return new;
end $$;
drop trigger if exists cn_rate_royale on public.royale_players;
create trigger cn_rate_royale before insert on public.royale_players
  for each row execute function public.cn_trg_royale_rate();

create or replace function public.cn_trg_chat_rate() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is not null and new.user_id = auth.uid() then
    perform public.cn_hit('chat', 8, 10, 'you are sending messages too fast');
  end if;
  return new;
end $$;
drop trigger if exists cn_rate_chat on public.match_messages;
create trigger cn_rate_chat before insert on public.match_messages
  for each row execute function public.cn_trg_chat_rate();
drop trigger if exists cn_rate_chat on public.royale_messages;
create trigger cn_rate_chat before insert on public.royale_messages
  for each row execute function public.cn_trg_chat_rate();

create or replace function public.cn_trg_friendreq_rate() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is not null and new.from_id = auth.uid() then
    perform public.cn_hit('friend_req', 20, 3600, 'you have sent a lot of friend requests -- try again later');
  end if;
  return new;
end $$;
drop trigger if exists cn_rate_friendreq on public.friend_requests;
create trigger cn_rate_friendreq before insert on public.friend_requests
  for each row execute function public.cn_trg_friendreq_rate();

create or replace function public.cn_trg_feedback_rate() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is not null and new.user_id = auth.uid() then
    perform public.cn_hit('feedback', 5, 3600, 'you have sent a lot of feedback -- try again later');
  end if;
  return new;
end $$;
drop trigger if exists cn_rate_feedback on public.feedback;
create trigger cn_rate_feedback before insert on public.feedback
  for each row execute function public.cn_trg_feedback_rate();

-- An inbox holds the newest 100; a flood can't grow it without bound.
create or replace function public.cn_trg_notifications_trim() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  delete from public.notifications
   where id in (select id from public.notifications where user_id = new.user_id
                 order by created_at desc, id desc offset 100);
  return null;
end $$;
drop trigger if exists cn_trim_notifications on public.notifications;
create trigger cn_trim_notifications after insert on public.notifications
  for each row execute function public.cn_trg_notifications_trim();

-- Heartbeats that arrive faster than the app ever sends them are dropped
-- before they become a write (and a Realtime event).
create or replace function public.cn_trg_presence_throttle() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if old.seen_at is not null and new.seen_at < old.seen_at + interval '8 seconds' then return null; end if;
  return new;
end $$;
drop trigger if exists cn_throttle_presence on public.user_presence;
create trigger cn_throttle_presence before update on public.user_presence
  for each row execute function public.cn_trg_presence_throttle();

create or replace function public.cn_trg_match_presence_throttle() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if new.away_since is not distinct from old.away_since
     and old.seen_at is not null and new.seen_at < old.seen_at + interval '3 seconds' then return null; end if;
  return new;
end $$;
drop trigger if exists cn_throttle_match_presence on public.match_presence;
create trigger cn_throttle_match_presence before update on public.match_presence
  for each row execute function public.cn_trg_match_presence_throttle();

revoke all on function public.cn_trg_matches_rate(), public.cn_trg_royale_rate(), public.cn_trg_chat_rate(),
  public.cn_trg_friendreq_rate(), public.cn_trg_feedback_rate(), public.cn_trg_notifications_trim(),
  public.cn_trg_presence_throttle(), public.cn_trg_match_presence_throttle() from public, anon, authenticated;

-- ---- tournaments: one finished game first, and no join spam ----------------
create or replace function public.tournament_join()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_uid uuid := auth.uid(); v_name text; v_avatar text; v_rating int;
  v_t uuid; v_n int; v_locks timestamptz;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  perform public.cn_hit('tourney_join', 10, 60, 'slow down a little');
  select username, avatar into v_name, v_avatar
    from public.profiles where id = v_uid;
  if v_name is null then raise exception 'no profile'; end if;
  select rating into v_rating from public.player_rating where user_id = v_uid;
  v_rating := coalesce(v_rating, 1000);

  -- Already in one that is being played? Then that is your tournament, and
  -- joining the next one while you still owe somebody a match is exactly the
  -- thing a bracket cannot survive.
  select t.id into v_t from public.tournaments t
    join public.tournament_entries e on e.tournament_id = t.id
   where e.user_id = v_uid and t.status = 'running' and e.out_at is null
   limit 1;
  if v_t is not null then return public.tournament_state(v_t); end if;

  -- 0196: a brand-new account can't sign up and never show. One finished game
  -- (a Vs Bots game counts) first.
  if not exists (select 1 from public.profiles where id = v_uid and (games > 0 or bot_wins > 0))
     and not exists (select 1 from public.matches
                      where status = 'finished' and not coalesce(is_sim, false)
                        and (host_id = v_uid or guest_id = v_uid)) then
    raise exception 'finish one game first (a Vs Bots game counts) before joining a tournament';
  end if;

  v_t := cn_tourney_open();

  insert into public.tournament_entries
    (tournament_id, user_id, username, avatar, rating)
  values (v_t, v_uid, v_name, v_avatar, v_rating)
  on conflict (tournament_id, user_id) do update
    set seen_at = now(), username = excluded.username,
        avatar = excluded.avatar, rating = excluded.rating, out_at = null;

  -- THE THIRD ENTRANT STARTS THE CLOCK, and only the third: a countdown that
  -- restarted every time somebody joined would never run out on a busy night.
  select count(*) into v_n from public.tournament_entries
   where tournament_id = v_t and out_at is null;
  select locks_at into v_locks from public.tournaments where id = v_t;
  if v_n >= 3 and v_locks is null then
    update public.tournaments set locks_at = now() + cn_tourney_wait()
     where id = v_t and status = 'open';
  end if;

  return public.tournament_state(v_t);
end $$;

-- ---- who may call what -----------------------------------------------------
-- Keep signed-in access for any function that only had it through PUBLIC.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure::text as sig from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and p.prorettype <> 'trigger'::regtype
       and has_function_privilege('authenticated', p.oid, 'execute')
       and not exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                        where a.grantee = (select oid from pg_roles where rolname = 'authenticated')
                          and a.privilege_type = 'EXECUTE')
  loop
    execute 'grant execute on function ' || r.sig || ' to authenticated';
  end loop;
end $$;

-- Nothing in the game runs signed out.
revoke execute on all functions in schema public from public, anon;
grant execute on function public.sweep_matches(), public.sweep_royale_matches() to authenticated;
-- Only read inside other (SECURITY DEFINER) functions.
revoke execute on function public.selected_deck(uuid) from authenticated;
