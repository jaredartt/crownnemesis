-- 0082: RAW, VISIBLE RATING. Jared's call after seeing the dormant mmr/lp
-- split this project already had: player_rating.mmr was a hidden Elo number
-- nothing in src/ ever read, while profiles.lp was a separate,
-- floor-protected, tiered number the ladder actually showed. That split
-- existed because there was no real matchmaking -- friends could farm each
-- other over room codes, so the visible number needed a floor to protect it.
-- Now there IS real matchmaking (ranked_tick, unchanged by this migration),
-- so the split's whole reason is gone. This migration retires it: the ladder
-- shows the raw Elo number directly, tiers and floors are dropped from the
-- ranked path entirely, and matchmaking's queue radius is Jared's exact
-- numbers (±50 immediately, ±150 at 5s, ±300 at 10s, open at 15s).
--
-- profiles.lp/floor_lp and tier_of()/tier_floor() are left in place,
-- untouched and unused by the ranked path from here on -- friend-room and
-- tournament LP (the friend_and_tournament_lp_enabled toggle) still exists
-- as a separate, deliberately un-migrated concept; this migration only
-- touches the ranked rating.

-- ---- 1. Elo K-factor, admin-configurable, not hardcoded ------------------
-- Jared: "so I can easily update it later from the admin mode page without
-- redeploying the app." Same singleton row useAppSettings.ts already reads.
alter table public.app_settings
  add column if not exists elo_k_placement int not null default 40,
  add column if not exists elo_k_established int not null default 20,
  add column if not exists elo_placement_games int not null default 10;

create or replace function public.cn_elo_k(p_games int)
returns int language sql stable set search_path = public as $$
  select case
    when p_games < coalesce((select elo_placement_games from public.app_settings where id), 10)
      then coalesce((select elo_k_placement from public.app_settings where id), 40)
    else coalesce((select elo_k_established from public.app_settings where id), 20)
  end
$$;

-- ---- 2. player_rating: mmr -> rating, and made publicly readable ---------
-- It was "own rating readable" only because it used to be a hidden number
-- nobody but you (and the matchmaker) needed to see. A visible ladder reads
-- everyone's.
alter table public.player_rating rename column mmr to rating;

drop policy if exists "own rating readable" on public.player_rating;
create policy "rating readable" on public.player_rating
  for select using (true);

-- ---- 3. ranked_queue: mmr -> rating (stays fully locked, functions only) -
alter table public.ranked_queue rename column mmr to rating;

-- ---- 4. Expanding queue radius, Jared's exact numbers ---------------------
create or replace function public.cn_queue_window(p_joined timestamptz)
returns int language sql stable as $$
  select case
    when now() - p_joined < interval '5 seconds'  then 50
    when now() - p_joined < interval '10 seconds' then 150
    when now() - p_joined < interval '15 seconds' then 300
    else 999999
  end
$$;

-- ranked_tick(), straight mmr -> rating rename throughout. Matching logic
-- (greatest of both players' own windows, closest-rating-first, stale after
-- queue_stale()) is untouched.
create or replace function public.ranked_tick()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_name text; v_rating int; v_joined timestamptz;
  v_them public.ranked_queue; m public.matches; v_st jsonb;
  v_found uuid; v_waiting int; v_host uuid; v_hname text; v_guest uuid; v_gname text;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select username into v_name from public.profiles where id = v_uid;
  if v_name is null then raise exception 'no profile'; end if;

  select id into v_found from public.matches
   where ranked and status in ('deploying', 'active')
     and (host_id = v_uid or guest_id = v_uid)
     and created_at > now() - interval '3 minutes'
   order by created_at desc limit 1;
  if v_found is not null then
    update public.ranked_queue set active = false where user_id = v_uid;
    return jsonb_build_object('match', v_found, 'waiting', 0);
  end if;

  select coalesce(rating, 1000) into v_rating from public.player_rating where user_id = v_uid;
  v_rating := coalesce(v_rating, 1000);

  insert into public.ranked_queue (user_id, username, rating, active, joined_at, seen_at)
  values (v_uid, v_name, v_rating, true, now(), now())
  on conflict (user_id) do update
    set seen_at = now(), active = true, username = excluded.username, rating = excluded.rating,
        joined_at = case when public.ranked_queue.active
                          and public.ranked_queue.seen_at > now() - queue_stale()
                         then public.ranked_queue.joined_at else now() end
  returning joined_at into v_joined;

  select * into v_them from public.ranked_queue q
   where q.user_id <> v_uid and q.active and q.seen_at > now() - queue_stale()
     and abs(q.rating - v_rating) <= greatest(cn_queue_window(v_joined),
                                        cn_queue_window(q.joined_at))
   order by abs(q.rating - v_rating), q.joined_at
   limit 1 for update skip locked;

  select count(*) into v_waiting from public.ranked_queue q
   where q.active and q.seen_at > now() - queue_stale();

  if v_them.user_id is null then
    return jsonb_build_object('match', null, 'waiting', v_waiting);
  end if;

  if random() < 0.5 then
    v_host := v_them.user_id; v_hname := v_them.username; v_guest := v_uid;  v_gname := v_name;
  else
    v_host := v_uid;          v_hname := v_name;          v_guest := v_them.user_id;
    v_gname := v_them.username;
  end if;

  v_st := cn_fresh_map();
  v_st := state_log(v_st, 'Ranked match found.');
  v_st := state_log(v_st, 'Place your units, then press Ready.');

  insert into public.matches
    (code, host_id, host_name, guest_id, guest_name, status, state, turn_deadline, ranked)
  values (gen_match_code(), v_host, v_hname, v_guest, v_gname,
          'deploying', v_st, now() + interval '90 seconds', true)
  returning * into m;

  perform cn_open_deploy(m.id, m.state, m.host_id, m.guest_id, null);

  update public.ranked_queue set active = false where user_id in (v_uid, v_them.user_id);
  insert into public.match_presence (match_id, user_id, side) values
    (m.id, m.host_id, 'host'), (m.id, m.guest_id, 'guest')
  on conflict (match_id, user_id) do update set seen_at = now();

  return jsonb_build_object('match', m.id, 'waiting', 0);
end $$;

-- ---- 5. match_results: absolute before/after, alongside the old delta ----
-- winner_lp/loser_lp are kept (NOT NULL, and still the swing -- see
-- finish_match below) so nothing that already reads them breaks; these four
-- are what let the post-game screen say "1200 -> 1215" instead of just "+15".
alter table public.match_results
  add column if not exists winner_rating_before int,
  add column if not exists winner_rating_after int,
  add column if not exists loser_rating_before int,
  add column if not exists loser_rating_after int;

-- ---- 6. finish_match(): one Elo update, no tier/floor math ---------------
-- Same signature, same callers (advance_turn, claim_win, resign_match,
-- cn_attack, cn_finish -- none of them change), same ranked_wins/achievement
-- side effects. The only thing gone is the dual mmr+lp/floor_lp update: now
-- there is exactly one rating per player, and it moves by a highly volatile
-- Elo swing sized for a small pool (K=40 while "placing", the first
-- elo_placement_games games; K=20 after -- both admin-configurable, see
-- cn_elo_k() above).
create or replace function public.finish_match(p_match uuid, p_winner text, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  m public.matches;
  w_id uuid; l_id uuid; w_name text; l_name text;
  w_rating int; l_rating int; w_g int; l_g int;
  e_w numeric; k_w int; k_l int;
  w_rating_new int; l_rating_new int;
begin
  select * into m from public.matches where id = p_match;
  if m.id is null or m.guest_id is null then return; end if;
  if m.status = 'finished' then return; end if;

  if p_winner = 'host' then
    w_id := m.host_id;  l_id := m.guest_id; w_name := m.host_name;  l_name := m.guest_name;
  else
    w_id := m.guest_id; l_id := m.host_id;  w_name := m.guest_name; l_name := m.host_name;
  end if;
  if w_id = l_id then return; end if;

  insert into public.player_rating (user_id) values (w_id) on conflict (user_id) do nothing;
  insert into public.player_rating (user_id) values (l_id) on conflict (user_id) do nothing;
  select rating, games into w_rating, w_g from public.player_rating where user_id = w_id;
  select rating, games into l_rating, l_g from public.player_rating where user_id = l_id;

  e_w := expected_score(w_rating, l_rating);
  k_w := cn_elo_k(w_g);
  k_l := cn_elo_k(l_g);

  w_rating_new := round(w_rating + k_w * (1 - e_w));
  l_rating_new := round(l_rating - k_l * (1 - e_w));

  update public.player_rating
     set rating = w_rating_new, games = games + 1, updated_at = now()
   where user_id = w_id;
  update public.player_rating
     set rating = l_rating_new, games = games + 1, updated_at = now()
   where user_id = l_id;

  update public.profiles
     set wins = wins + 1, ranked_wins = ranked_wins + 1, games = games + 1,
         streak = case when streak >= 0 then streak + 1 else 1 end
   where id = w_id;

  update public.profiles
     set losses = losses + 1, games = games + 1,
         streak = case when streak <= 0 then streak - 1 else -1 end
   where id = l_id;

  insert into public.match_results
    (code, season, winner_id, loser_id, winner_name, loser_name,
     winner_lp, loser_lp,
     winner_rating_before, winner_rating_after, loser_rating_before, loser_rating_after,
     reason)
  values
    (m.code, current_season(), w_id, l_id, w_name, l_name,
     w_rating_new - w_rating, l_rating_new - l_rating,
     w_rating, w_rating_new, l_rating, l_rating_new,
     p_reason);

  perform cn_check_achievements(w_id);
end $$;

-- ---- 7. The ladder itself -------------------------------------------------
-- Same columns as before minus tier (there is no tier anymore), lp renamed
-- to rating and sourced from player_rating instead of profiles. A player who
-- has never finished a rated game has no player_rating row yet -- shown at
-- the same 1000 everyone starts from, same default ranked_tick() already
-- used for a first-timer landing in queue.
-- create-or-replace can't drop a column (tier is gone here), so the old
-- shape is dropped first.
drop view if exists public.leaderboard;
create view public.leaderboard as
select
  p.id, p.username, p.avatar, p.name_color,
  coalesce(r.rating, 1000) as rating,
  p.wins, p.losses, p.games, p.streak, p.tournaments
from public.profiles p
left join public.player_rating r on r.user_id = p.id;

-- ---- 8. Admin: set a player's raw rating directly -------------------------
-- The admin panel used to edit profiles.lp through admin_update_profile();
-- rating lives in a different table now, so it gets its own tiny setter
-- rather than bolting a ninth optional param onto a function that returns a
-- `profiles` row and has no rating column to put it in.
create or replace function public.admin_set_rating(p_user uuid, p_rating int)
returns int language plpgsql security definer set search_path = public as $$
declare v_rating int;
begin
  if not cn_is_super_admin() then raise exception 'admin only'; end if;
  if p_user is null then raise exception 'no account given'; end if;
  v_rating := greatest(0, coalesce(p_rating, 1000));
  insert into public.player_rating (user_id, rating) values (p_user, v_rating)
  on conflict (user_id) do update set rating = v_rating, updated_at = now();
  return v_rating;
end $$;
