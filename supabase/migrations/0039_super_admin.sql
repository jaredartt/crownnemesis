-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE, so no "Potential issue detected" dialog.
--  Run 0038 first. The last statement prints a row of checks; every column
--  must say true.
-- ===========================================================================
--  0039 - the Admin Mode tab, and a second lock on its door
--
--  `profiles.is_admin` has done the actual work since 0001: it is what "admins
--  write cards" checks, it is what the Lobby uses to show the Cards tile, and
--  nobody can grant it to themselves (0001's trigger sees to that). In
--  practice it has only ever been true on one row, Jared's, because there is
--  deliberately no button anywhere that sets it -- 0025 says as much.
--
--  So why a second check here. Because "Admin Mode" is about to grow past
--  card numbers into things that can hurt a real player in real time -- typing
--  a stranger's stats over their own, or ending their session mid-match -- and
--  a flag that is *usually* only true for one person is not the same
--  statement as a check that names the person. cn_is_super_admin() says both:
--  is_admin, AND the signed-in email is jaredartt@gmail.com. Every new table
--  and every new function below this line is behind that function, not behind
--  is_admin alone. The card roster and its art bucket keep the check 0001 and
--  0025 already gave them -- they are unchanged by this file, on purpose, so
--  a working policy is not rewritten for a rule it already satisfies in
--  practice.
--
--  Two more things live here because there was nowhere better for them to go:
--  a ban flag, and the achievements column the profile editor needs to have
--  anything to edit. Neither is exciting; both are just columns.
-- ===========================================================================

alter table public.profiles add column if not exists is_banned boolean not null default false;
alter table public.profiles add column if not exists achievements text[] not null default '{}';

-- ---------------------------------------------------------------------------
-- 1. the second lock
--
-- `language sql stable`, not `immutable`: it reads profiles and the request's
-- own JWT, both of which can change from one call to the next, and marking it
-- immutable would be a lie the planner is allowed to act on.
--
-- The email comes off the request's JWT the same defensive way 0001 reads the
-- role claim in protect_admin_flag -- parsed by hand rather than through
-- auth.email(), so this does not assume a helper that a given project's auth
-- schema may not carry.
-- ---------------------------------------------------------------------------
create or replace function public.cn_is_super_admin()
returns boolean language sql stable as $$
  select
    exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin)
    and lower(coalesce(
          nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email', ''
        )) = 'jaredartt@gmail.com'
$$;

-- ---------------------------------------------------------------------------
-- 2. the belt: an RLS policy, so a direct write from the client is held to
-- the same rule as the RPCs below rather than only to whatever the RPCs
-- remember to check. `is_admin` itself is untouched by this -- 0001's
-- protect_admin_flag trigger fires on every path into this row, this one
-- included, and silently keeps the old value unless the write is carrying the
-- service role.
-- ---------------------------------------------------------------------------
drop policy if exists "super admin writes any profile" on public.profiles;
create policy "super admin writes any profile"
  on public.profiles for update to authenticated
  using (public.cn_is_super_admin())
  with check (public.cn_is_super_admin());

-- ---------------------------------------------------------------------------
-- 3. the profile editor
--
-- One function for the whole form rather than one per field, because a save
-- button in the admin screen should mean one round trip, not five. Every
-- argument defaults to null, and null means "leave this alone" -- so calling
-- it to change just a username does not require sending someone else's stats
-- back at them unchanged.
--
-- The username and avatar rules are copied from set_username (0001/0016)
-- rather than called through them, because those two are `security definer`
-- functions that update auth.uid()'s OWN row -- exactly the row this function
-- must be free to not be.
-- ---------------------------------------------------------------------------
create or replace function public.admin_update_profile(
  p_user uuid,
  p_username text default null,
  p_avatar text default null,
  p_avatar_clear boolean default false,
  p_lp int default null,
  p_wins int default null,
  p_losses int default null,
  p_games int default null,
  p_streak int default null,
  p_achievements text[] default null
)
returns public.profiles
language plpgsql security definer set search_path = public as $$
declare v_name text; v_ach text[]; v_out public.profiles;
begin
  if not cn_is_super_admin() then raise exception 'admin only'; end if;
  if p_user is null then raise exception 'no account given'; end if;

  if p_username is not null then
    v_name := btrim(p_username);
    if char_length(v_name) < 2 or char_length(v_name) > 20 then
      raise exception 'a name is between 2 and 20 characters';
    end if;
    if v_name !~ '^[A-Za-z0-9 _.-]+$' then
      raise exception 'letters, numbers, spaces, dots, dashes and underscores only';
    end if;
    begin
      update public.profiles set username = v_name where id = p_user;
    exception when unique_violation then
      raise exception 'that name is taken';
    end;
  end if;

  if p_avatar_clear then
    update public.profiles set avatar = null where id = p_user;
  elsif p_avatar is not null then
    if not exists (select 1 from public.cards where is_active and slug = p_avatar) then
      raise exception 'no such card';
    end if;
    update public.profiles set avatar = p_avatar where id = p_user;
  end if;

  -- Stats are typed for a reason a player never sees, and an admin can fat-
  -- finger a minus sign as easily as anybody -- clamped to zero rather than
  -- refused, same spirit as cn_clean_settings repairing a wild value instead
  -- of losing the whole patch over it.
  if p_lp is not null then update public.profiles set lp = greatest(0, p_lp) where id = p_user; end if;
  if p_wins is not null then update public.profiles set wins = greatest(0, p_wins) where id = p_user; end if;
  if p_losses is not null then update public.profiles set losses = greatest(0, p_losses) where id = p_user; end if;
  if p_games is not null then update public.profiles set games = greatest(0, p_games) where id = p_user; end if;
  if p_streak is not null then update public.profiles set streak = p_streak where id = p_user; end if;

  if p_achievements is not null then
    -- Trimmed, emptied of blanks, capped at twenty badges of forty characters
    -- each -- an achievements column is not the place for a paragraph, and a
    -- cap here is cheaper than a screen that has to scroll sideways for it.
    select array_agg(left(btrim(x), 40)) into v_ach
      from unnest(p_achievements) x
     where btrim(x) <> '';
    v_ach := coalesce(v_ach, '{}');
    if array_length(v_ach, 1) > 20 then
      raise exception 'twenty achievements at most';
    end if;
    update public.profiles set achievements = v_ach where id = p_user;
  end if;

  select * into v_out from public.profiles where id = p_user;
  if v_out.id is null then raise exception 'no such account'; end if;
  return v_out;
end $$;
grant execute on function public.admin_update_profile(
  uuid, text, text, boolean, int, int, int, int, int, text[]
) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. the ban switch
--
-- What this can promise and what it cannot, said plainly rather than implied:
-- it flips one column, and every screen in this app that reads `is_banned`
-- reacts to it. A banned player's own client is watching its own profile row
-- over Realtime (see useAuth.ts) and signs itself out within about a second of
-- this running -- and side_of(), below, stops a banned account from landing a
-- move even in the window before that happens, in every match in the game,
-- because every combat function asks side_of() who is acting. What it does
-- NOT do is revoke the JWT already in that browser's memory or touch
-- anything outside this database -- there is no service-role key on this
-- client to do that with, and there does not need to be one for "kicked to
-- the login screen within a second or two" to be true in practice.
-- ---------------------------------------------------------------------------
create or replace function public.admin_set_banned(p_user uuid, p_banned boolean)
returns public.profiles
language plpgsql security definer set search_path = public as $$
declare v_out public.profiles;
begin
  if not cn_is_super_admin() then raise exception 'admin only'; end if;
  if p_user = auth.uid() then raise exception 'cannot ban your own account'; end if;
  update public.profiles set is_banned = coalesce(p_banned, false) where id = p_user
    returning * into v_out;
  if v_out.id is null then raise exception 'no such account'; end if;
  return v_out;
end $$;
grant execute on function public.admin_set_banned(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. side_of() learns one more answer
--
-- Every submit_* function and end_turn asks this who is acting, so this is
-- the one place a ban has to be taught rather than thirty. A banned account
-- gets the same null a pure spectator gets, which is already turned into "you
-- are spectating this match" wherever side_of() is called -- so this is a
-- one-line change with the same wide reach 0001 already gave the function it
-- is changing.
-- ---------------------------------------------------------------------------
create or replace function public.side_of(p_match public.matches, p_user uuid)
returns text language sql stable as $$
  select case
    when exists (select 1 from public.profiles pr where pr.id = p_user and pr.is_banned) then null
    when p_match.host_id  = p_user then 'host'
    when p_match.guest_id = p_user then 'guest'
    else null end
$$;

-- ---------------------------------------------------------------------------
-- 6. Realtime, so a ban is heard rather than polled for
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname='supabase_realtime' and schemaname='public' and tablename='profiles') then
    alter publication supabase_realtime add table public.profiles;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Did it work? All true means yes.
--
-- the_lock_needs_both_things and jareds_account_would_pass are read straight
-- off cn_is_super_admin()'s SQL text rather than by calling it -- calling it
-- here would ask whether *this migration script* is signed in as Jared, which
-- is a question about the SQL Editor's own session, not about the function.
-- ---------------------------------------------------------------------------
select
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='profiles' and column_name='is_banned') = 1
                                                              as profiles_have_is_banned,
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='profiles' and column_name='achievements') = 1
                                                              as profiles_have_achievements,
  to_regprocedure('public.cn_is_super_admin()') is not null    as super_admin_check_exists,
  pg_get_functiondef('public.cn_is_super_admin()'::regprocedure) ilike '%is_admin%'
                                                              as the_lock_needs_both_things,
  pg_get_functiondef('public.cn_is_super_admin()'::regprocedure) ilike '%jaredartt@gmail.com%'
                                                              as jareds_account_would_pass,
  to_regprocedure('public.admin_update_profile(uuid,text,text,boolean,int,int,int,int,int,text[])')
    is not null                                              as profile_editor_exists,
  to_regprocedure('public.admin_set_banned(uuid,boolean)') is not null
                                                              as ban_switch_exists,
  pg_get_functiondef('public.side_of(public.matches,uuid)'::regprocedure) ilike '%is_banned%'
                                                              as side_of_checks_the_ban;
