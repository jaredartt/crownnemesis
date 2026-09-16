-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE of anything but a caller's own rows, so
--  no "Potential issue detected" dialog.
--  Run 0044 first -- send_friend_request and send_match_invite below insert
--  into public.notifications directly. The last statement prints a row of
--  checks; every column must say true.
-- ===========================================================================
--  0043 - friends, and asking one to play
--
--  THREE TABLES. friend_requests is the handshake, one row per direction,
--  never both at once for the same pair (see below). friends is the result,
--  and it is stored TWICE -- a row for A->B and a row for B->A -- so "my
--  friends" is `where user_id = auth.uid()` on both ends instead of an OR
--  across two columns everywhere it is read. user_presence is neither: it is
--  not about a relationship, it is one timestamp per account, the same shape
--  match_presence already uses for "is anybody still looking at this match",
--  just asked about the whole app instead of one room.
--
--  WHY THE HANDSHAKE ISN'T A CLIENT INSERT ALONE. send_friend_request does
--  three things a bare `insert` cannot: refuses a self-request, refuses one
--  to somebody you are already friends with, and -- the one worth explaining
--  -- if the OTHER side already asked YOU, it accepts that instead of filing
--  a second row nobody would ever see (the unique index is keyed on
--  direction, so A->B and B->A do not conflict with each other, which means
--  two people who both hit "add" on each other's names would otherwise end
--  up with two forever-pending requests and no friendship). The RLS insert
--  policy stays on the table too, matching what 0044 did for `read` on
--  notifications: belt over the RPC's suspenders, not a second way in.
--
--  user_presence HAS NO WRITE POLICIES AT ALL, same as match_presence -- with
--  one deliberate departure from that pattern for reads, spelled out where
--  the policy would have gone. Nothing else about it is new: touch_presence()
--  is the only door in, exactly the shape create_match()/touch_match() use.
--
--  list_friends(): NOT an RPC. `friends` and `profiles` are both readable by
--  any authenticated user already (`profiles` since 0001, `friends` below,
--  own rows only) -- a client that wants its friends' names and faces reads
--  `friends` for the ids and `profiles` for the rest, same as the ladder
--  already reads `leaderboard`. A table function here would only be a second
--  name for the same two queries.
--
--  THE '4P' INVITE MODE IS A STUB. Battle Royale's schema is a concurrent
--  migration's (0048-0050), not this one's, and does not exist on this
--  database yet. send_match_invite raises a plain exception for '4p' rather
--  than guessing at a table name that would collide with that work. See the
--  TODO on it below.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. the tables
-- ---------------------------------------------------------------------------
create table if not exists public.friend_requests (
  id         uuid primary key default gen_random_uuid(),
  from_id    uuid not null references public.profiles(id) on delete cascade,
  to_id      uuid not null references public.profiles(id) on delete cascade,
  status     text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint friend_requests_not_yourself check (from_id <> to_id),
  unique (from_id, to_id)
);

create index if not exists friend_requests_to_pending_idx
  on public.friend_requests(to_id) where status = 'pending';

alter table public.friend_requests enable row level security;

drop policy if exists "friend requests readable by either side" on public.friend_requests;
create policy "friend requests readable by either side"
  on public.friend_requests for select to authenticated
  using (from_id = auth.uid() or to_id = auth.uid());

drop policy if exists "friend requests sent by yourself" on public.friend_requests;
create policy "friend requests sent by yourself"
  on public.friend_requests for insert to authenticated
  with check (from_id = auth.uid());

-- No update policy. Accepting or declining changes a row that is half
-- somebody ELSE's business (the other side of the handshake reads it too),
-- so it goes through respond_friend_request() rather than through a policy
-- that would have to reinvent that function's checks to be safe.

create table if not exists public.friends (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  friend_id  uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, friend_id)
);

alter table public.friends enable row level security;

drop policy if exists "friends readable by owner" on public.friends;
create policy "friends readable by owner"
  on public.friends for select to authenticated
  using (user_id = auth.uid());

-- No write policy at all. Every row here is created and destroyed in pairs
-- by respond_friend_request() / remove_friend(), and a client that could
-- insert its own half would produce a friendship only it can see.

create table if not exists public.user_presence (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  seen_at timestamptz not null default now()
);

alter table public.user_presence enable row level security;

-- DEPARTURE FROM "no policies at all": a table with zero SELECT policies
-- cannot be read by realtime either -- Realtime authorises each row it sends
-- against the subscriber's own SELECT privilege, so match_presence's actual
-- pattern (no policy, read only from inside other SECURITY DEFINER
-- functions, never by the client) would make the green dot this table exists
-- for simply never light up. The narrower thing that still stops the
-- snooping the "no policies" note was guarding against -- a stranger cannot
-- watch this table for every account's comings and goings -- is a SELECT
-- policy scoped to yourself and your own friends, which is exactly who the
-- Friends list needs a dot for and no wider.
drop policy if exists "presence readable by self and friends" on public.user_presence;
create policy "presence readable by self and friends"
  on public.user_presence for select to authenticated
  using (
    user_id = auth.uid()
    or exists (
      select 1 from public.friends f
       where f.user_id = auth.uid() and f.friend_id = user_presence.user_id
    )
  );

-- No write policy. touch_presence() is the only door in, same as
-- touch_match() is for match_presence.

-- ---------------------------------------------------------------------------
-- 2. the handshake
-- ---------------------------------------------------------------------------
create or replace function public.respond_friend_request(p_id uuid, p_accept boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  r public.friend_requests;
begin
  if v_uid is null then raise exception 'not signed in'; end if;

  select * into r from public.friend_requests where id = p_id for update;
  if r.id is null then raise exception 'that request no longer exists'; end if;
  if r.to_id <> v_uid then raise exception 'that request is not yours to answer'; end if;
  if r.status <> 'pending' then raise exception 'that request was already answered'; end if;

  if p_accept then
    update public.friend_requests set status = 'accepted', updated_at = now() where id = p_id;
    insert into public.friends (user_id, friend_id) values (r.from_id, r.to_id)
      on conflict (user_id, friend_id) do nothing;
    insert into public.friends (user_id, friend_id) values (r.to_id, r.from_id)
      on conflict (user_id, friend_id) do nothing;
    perform public.cn_notify(r.from_id, 'friend_accepted', jsonb_build_object(
      'by_id', v_uid,
      'by_username', (select username from public.profiles where id = v_uid)
    ));
  else
    update public.friend_requests set status = 'declined', updated_at = now() where id = p_id;
  end if;
end $$;

create or replace function public.send_friend_request(p_to uuid)
returns public.friend_requests
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_reverse public.friend_requests;
  v_row public.friend_requests;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if p_to is null then raise exception 'no such player'; end if;
  if p_to = v_uid then raise exception 'you cannot add yourself'; end if;
  if not exists (select 1 from public.profiles where id = p_to) then
    raise exception 'no such player';
  end if;
  if exists (select 1 from public.friends where user_id = v_uid and friend_id = p_to) then
    raise exception 'you are already friends';
  end if;

  -- They got there first: accept their pending request rather than filing a
  -- second one going the other way.
  select * into v_reverse from public.friend_requests
   where from_id = p_to and to_id = v_uid and status = 'pending';
  if v_reverse.id is not null then
    perform public.respond_friend_request(v_reverse.id, true);
    select * into v_row from public.friend_requests where id = v_reverse.id;
    return v_row;
  end if;

  -- Upsert rather than a bare insert: two people who tried each other before,
  -- one of them declined, and now want to try again should not be stuck
  -- behind the unique index forever.
  insert into public.friend_requests (from_id, to_id, status, updated_at)
  values (v_uid, p_to, 'pending', now())
  on conflict (from_id, to_id) do update
    set status = 'pending', updated_at = now()
    where public.friend_requests.status = 'declined'
  returning * into v_row;

  if v_row.id is null then
    raise exception 'you already sent this player a request';
  end if;

  perform public.cn_notify(p_to, 'friend_request', jsonb_build_object(
    'request_id', v_row.id,
    'from_id', v_uid,
    'from_username', (select username from public.profiles where id = v_uid)
  ));

  return v_row;
end $$;

create or replace function public.remove_friend(p_friend uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not signed in'; end if;

  delete from public.friends
   where (user_id = v_uid and friend_id = p_friend)
      or (user_id = p_friend and friend_id = v_uid);

  -- Clear the paper trail too, so these two can send each other a fresh
  -- request later instead of tripping over an old accepted row forever.
  delete from public.friend_requests
   where (from_id = v_uid and to_id = p_friend) or (from_id = p_friend and to_id = v_uid);
end $$;

-- ---------------------------------------------------------------------------
-- 3. presence: "is this account anywhere in the app right now"
-- ---------------------------------------------------------------------------
create or replace function public.touch_presence()
returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  insert into public.user_presence (user_id, seen_at) values (v_uid, now())
    on conflict (user_id) do update set seen_at = now();
end $$;

-- ---------------------------------------------------------------------------
-- 4. asking a friend to play
-- ---------------------------------------------------------------------------
create or replace function public.send_match_invite(p_to uuid, p_mode text)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_name text;
  m public.matches;
  v_t uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if p_to is null or p_to = v_uid then raise exception 'no such player'; end if;
  if p_mode not in ('1v1', '4p', 'tournament') then raise exception 'unknown match type'; end if;
  if not exists (select 1 from public.friends where user_id = v_uid and friend_id = p_to) then
    raise exception 'you can only invite a friend';
  end if;

  select username into v_name from public.profiles where id = v_uid;

  if p_mode = '1v1' then
    -- Same room create_match() already opens for "Open a room" -- the invite
    -- is just that code, handed over as a notification instead of by text
    -- message.
    m := public.create_match();
    perform public.cn_notify(p_to, 'match_invite', jsonb_build_object(
      'from_id', v_uid, 'from_username', v_name,
      'mode', '1v1', 'match_id', m.id, 'code', m.code
    ));
    return m.code;

  elsif p_mode = 'tournament' then
    -- Not a private match -- there is only ever one bracket open at a time
    -- (0028's partial unique index) -- so this just points a friend at it.
    select id into v_t from public.tournaments where status = 'open';
    if v_t is null then raise exception 'there is no open tournament right now'; end if;
    perform public.cn_notify(p_to, 'match_invite', jsonb_build_object(
      'from_id', v_uid, 'from_username', v_name,
      'mode', 'tournament', 'tournament_id', v_t
    ));
    return 'tournament';

  else
    -- TODO(battle-royale): wire this up once the 4-Player schema (owned by
    -- migrations 0048-0050, not this one) exists. Raising here rather than
    -- guessing at a table name keeps this migration from colliding with
    -- that work.
    raise exception 'battle royale invites are not wired up yet';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. realtime -- friend_requests deliberately excluded, so nobody watching
-- this publication can see who is asking whom; a `friend_request`
-- notification already reaches the person who needs to know.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname='supabase_realtime' and schemaname='public' and tablename='friends') then
    alter publication supabase_realtime add table public.friends;
  end if;
  if not exists (select 1 from pg_publication_tables
                  where pubname='supabase_realtime' and schemaname='public' and tablename='user_presence') then
    alter publication supabase_realtime add table public.user_presence;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 6. who may call what
-- ---------------------------------------------------------------------------
grant execute on function public.send_friend_request(uuid)      to authenticated;
grant execute on function public.respond_friend_request(uuid, boolean) to authenticated;
grant execute on function public.remove_friend(uuid)             to authenticated;
grant execute on function public.touch_presence()                to authenticated;
grant execute on function public.send_match_invite(uuid, text)   to authenticated;

-- ---------------------------------------------------------------------------
-- Did it work? All true means yes.
-- ---------------------------------------------------------------------------
select
  to_regclass('public.friend_requests') is not null                    as friend_requests_exists,
  to_regclass('public.friends') is not null                            as friends_exists,
  to_regclass('public.user_presence') is not null                      as user_presence_exists,
  to_regprocedure('public.send_friend_request(uuid)') is not null      as send_request_exists,
  to_regprocedure('public.respond_friend_request(uuid,boolean)') is not null
                                                                        as respond_request_exists,
  to_regprocedure('public.remove_friend(uuid)') is not null            as remove_friend_exists,
  to_regprocedure('public.touch_presence()') is not null               as touch_presence_exists,
  to_regprocedure('public.send_match_invite(uuid,text)') is not null   as send_invite_exists,
  (select count(*) from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public'
      and tablename in ('friends','user_presence')) = 2                as friends_are_realtime,
  (select count(*) from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='friend_requests') = 0
                                                                        as requests_stay_private;
