-- 0083: FINISH THE JOB 0082 STARTED. Jared, after learning 0082 had left
-- profiles.lp/floor_lp and tier_of()/tier_floor() sitting around unused:
-- "just remove everything that is not going to be used then!"
--
-- Auditing what actually still touched them turned up a real bug, not just
-- housekeeping: tournament seeding (cn_tourney_lock, via tournament_join's
-- snapshot into tournament_entries.lp) was STILL reading profiles.lp --
-- which 0082's finish_match() rewrite stopped updating entirely. Every
-- tournament since 0082 shipped has been seeding players by a frozen,
-- disconnected number instead of their actual rating. That gets fixed here
-- alongside the cleanup, not left for later.

-- ---- 1. Tournaments: seed by rating, not a frozen lp snapshot -----------
alter table public.tournament_entries rename column lp to rating;
alter table public.tournament_entries alter column rating set default 1000;

create or replace function public.tournament_join()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_name text; v_avatar text; v_rating int;
  v_t uuid; v_n int; v_locks timestamptz;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
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

create or replace function public.cn_tourney_lock(p_t uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  t public.tournaments; v_n int; v_size int; v_rounds int; v_ord int[];
  r int; s int; v_a public.tournament_entries; v_b public.tournament_entries;
  tm public.tournament_matches;
begin
  select * into t from public.tournaments where id = p_t for update;
  if t.id is null or t.status <> 'open' then return; end if;

  select count(*) into v_n from public.tournament_entries
   where tournament_id = p_t and out_at is null;
  -- Everyone left during the countdown. Not an error and not a tournament:
  -- clear the clock and go on taking sign-ups.
  if v_n < 2 then
    update public.tournaments set locks_at = null where id = p_t;
    return;
  end if;

  -- SEEDS. Rating first (0083 -- was the frozen lp snapshot), and the
  -- earlier sign-up ahead on a tie, which is the only tiebreak that cannot
  -- be gamed by refreshing.
  with sd as (
    select user_id, row_number() over (order by rating desc, joined_at, user_id) rn
      from public.tournament_entries
     where tournament_id = p_t and out_at is null)
  update public.tournament_entries e set seed = sd.rn
    from sd where sd.user_id = e.user_id and e.tournament_id = p_t;

  v_size   := cn_tourney_size(v_n);
  v_rounds := cn_tourney_rounds(v_size);
  v_ord    := cn_bracket_order(v_size);

  -- EVERY SLOT OF EVERY ROUND UP FRONT, empty ones included, so the client can
  -- draw the whole bracket the instant it locks instead of watching it grow.
  for r in 1..v_rounds loop
    for s in 0..(v_size / (2 ^ r)::int) - 1 loop
      insert into public.tournament_matches (tournament_id, round, slot)
      values (p_t, r, s) on conflict (tournament_id, round, slot) do nothing;
    end loop;
  end loop;

  for s in 0..(v_size / 2) - 1 loop
    select * into v_a from public.tournament_entries
     where tournament_id = p_t and seed = v_ord[2 * s + 1];
    select * into v_b from public.tournament_entries
     where tournament_id = p_t and seed = v_ord[2 * s + 2];
    update public.tournament_matches
       set a_id = v_a.user_id, a_name = v_a.username,
           b_id = v_b.user_id, b_name = v_b.username
     where tournament_id = p_t and round = 1 and slot = s;
  end loop;

  update public.tournaments
     set status = 'running', size = v_size, rounds = v_rounds,
         started_at = now(), locks_at = null
   where id = p_t;

  -- Byes are wins that have already happened, so they are recorded now and
  -- travel the ordinary road. Only then are the real first-round matches
  -- built, so that a bye's parent slot already knows half of itself.
  for tm in select * from public.tournament_matches
             where tournament_id = p_t and round = 1 order by slot loop
    if tm.a_id is null and tm.b_id is null then
      -- Cannot happen: see cn_bracket_order. Recorded rather than assumed.
      raise exception 'bracket slot % of tournament % has nobody in it', tm.slot, p_t;
    elsif tm.b_id is null then
      update public.tournament_matches set bye = true where id = tm.id;
      perform cn_tourney_win(tm.id, tm.a_id, tm.a_name);
    elsif tm.a_id is null then
      update public.tournament_matches set bye = true where id = tm.id;
      perform cn_tourney_win(tm.id, tm.b_id, tm.b_name);
    end if;
  end loop;

  for tm in select * from public.tournament_matches
             where tournament_id = p_t and round = 1 and winner_id is null
             order by slot loop
    perform cn_tourney_spawn(tm.id);
  end loop;
end $$;

create or replace function public.tournament_state(p_t uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare t public.tournaments; v_uid uuid := auth.uid(); v jsonb;
begin
  select * into t from public.tournaments where id = p_t;
  if t.id is null then return null; end if;

  v := jsonb_build_object(
    'id', t.id, 'status', t.status,
    'locksAt', t.locks_at, 'startedAt', t.started_at, 'finishedAt', t.finished_at,
    'size', t.size, 'rounds', t.rounds,
    'winnerId', t.winner_id, 'winnerName', t.winner_name,
    'now', now(),
    'entries', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', e.user_id, 'name', e.username, 'avatar', e.avatar,
               'rating', e.rating, 'seed', e.seed, 'out', e.out_at is not null)
             order by coalesce(e.seed, 9999), e.joined_at)
        from public.tournament_entries e where e.tournament_id = t.id), '[]'::jsonb),
    'bracket', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', b.id, 'round', b.round, 'slot', b.slot,
               'aId', b.a_id, 'aName', b.a_name,
               'bId', b.b_id, 'bName', b.b_name,
               'match', b.match_id, 'winnerId', b.winner_id,
               'winnerName', b.winner_name, 'bye', b.bye)
             order by b.round, b.slot)
        from public.tournament_matches b where b.tournament_id = t.id), '[]'::jsonb));

  -- "Where am I" answered by the server, because the client working it out of
  -- the bracket means the client working it out of the bracket twice.
  return jsonb_set(v, '{me}', jsonb_build_object(
    'in', exists (select 1 from public.tournament_entries
                   where tournament_id = t.id and user_id = v_uid and out_at is null),
    'out', exists (select 1 from public.tournament_entries
                    where tournament_id = t.id and user_id = v_uid and out_at is not null),
    'seed', (select seed from public.tournament_entries
              where tournament_id = t.id and user_id = v_uid),
    'match', (select b.match_id from public.tournament_matches b
               where b.tournament_id = t.id and b.winner_id is null
                 and b.match_id is not null
                 and (b.a_id = v_uid or b.b_id = v_uid) limit 1)));
end $$;

-- ---- 2. Season reset: actually resets the thing that matters now --------
-- Used to zero profiles.lp/floor_lp -- both dead now. A "new season" that
-- doesn't touch anyone's rating isn't a new season, so this resets
-- player_rating instead: everyone back to 1000, placement games restart.
create or replace function public.start_new_season()
returns int language plpgsql security definer set search_path = public as $$
declare s int;
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and is_admin) then
    raise exception 'admins only';
  end if;
  update public.app_settings set season = season + 1 where id returning season into s;
  update public.profiles set streak = 0, season = s;
  update public.player_rating set rating = 1000, games = 0, updated_at = now();
  return s;
end $$;

-- ---- 3. admin_update_profile(): drop the dead p_lp param ------------------
-- Overloading rather than replacing in place if left as create-or-replace
-- with a shorter parameter list, so the old signature is dropped explicitly
-- first.
drop function if exists public.admin_update_profile(
  uuid, text, text, boolean, integer, integer, integer, integer, integer, text[]
);

create or replace function public.admin_update_profile(
  p_user uuid, p_username text default null, p_avatar text default null,
  p_avatar_clear boolean default false,
  p_wins integer default null, p_losses integer default null,
  p_games integer default null, p_streak integer default null,
  p_achievements text[] default null
)
returns profiles
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

-- ---- 4. Drop what's genuinely dead now -----------------------------------
-- tier_of()/tier_floor(): nothing calls either any more -- the leaderboard
-- view stopped in 0082, and step 1 above was tournament seeding's last use
-- of the concept.
drop function if exists public.tier_of(integer);
drop function if exists public.tier_floor(integer);

-- profiles.lp/floor_lp: dead since 0082's finish_match() rewrite stopped
-- writing them, and nothing still reads them as of step 1/3 above. Dropping
-- the column also drops profiles_lp_idx, the index that existed only to
-- support the old leaderboard's "order by lp desc" -- gone since 0082 too.
alter table public.profiles drop column if exists lp;
alter table public.profiles drop column if exists floor_lp;
