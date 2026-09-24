-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice -- it only adds columns (if not exists) and
--  replaces function bodies.
-- ===========================================================================
--  bot_identity_and_ranked_fallback
--
--  Three asks from Jared, in order:
--
--   1. "If it can't find a real opponent to match you up with in ranked
--      within [some time], go ahead and pair the player up with a bot
--      instead" -- with 50 random bot names, random profile pictures, and a
--      random RP near the player's own, and "have that match count for real
--      rating, wins, and losses" but only "a third of the normal Elo swing".
--   2. "make it so that I can adjust how many seconds a player needs to
--      wait without not finding a real player so that they fight a bot,
--      give me the control from the admin page" -- not hardcoded.
--   3. The existing "Vs Bots" 1v1 practice mode (all three difficulty
--      levels) should show these same random bot names/avatars too, instead
--      of its current placeholder ("CALM"/"SHARP"/"RUTHLESS" text and a
--      first-letter circle).
--
--  All three share one identity source (bot_identity(), below): a bot is a
--  random name from a 50-name array and a random avatar from the 13 real
--  card slugs already shipped with the game. Both create_bot_match()
--  (practice Vs Bots) and ranked_tick()'s new fallback branch (ranked) call
--  it, so a bot looks the same wherever one appears.
--
--  The rating side only matters for the ranked fallback -- a practice Vs
--  Bots match is `ranked = false` and never touches rating at all, exactly
--  as before. finish_match()'s existing guard
--  (`if m.id is null or m.guest_id is null then return; end if;`) already
--  short-circuited on a bot opponent (guest_id is always null for one) --
--  it's rewired here to instead call the new finish_ranked_bot_match() when
--  the match was ranked, and still return (no-op) otherwise. That means
--  every existing `if m.ranked then perform finish_match(...)` call site
--  across the codebase (advance_turn / cn_attack / resign / abandon /
--  stalemate, ~30 places across many migrations) needed zero changes --
--  finish_match is still the one entry point they all already call.
--
--  finish_ranked_bot_match() applies a standard Elo update
--  (k/3 * (actual - expected)) to the human (host) side only, using
--  matches.bot_rating (the synthetic opponent rating ranked_tick() picked)
--  as the other side's rating, then updates profiles.wins/losses/games/
--  streak and inserts a match_results row exactly like a real match, and
--  runs achievement checks -- same shape as finish_match()'s own real-match
--  branch, just with one side that has no player_rating/profiles row to
--  touch.
-- ===========================================================================

-- ---- 1. New columns: a bot's identity and synthetic rating on the match --
alter table public.matches
  add column if not exists guest_avatar text,
  add column if not exists bot_rating int;

-- ---- 2. Admin-configurable wait, not hardcoded ----------------------------
-- Same singleton row useAppSettings.ts already reads (elo_k_placement etc,
-- see 0082) -- AdminLadder.tsx gets a fourth field, live, no redeploy.
alter table public.app_settings
  add column if not exists ranked_bot_after_seconds int not null default 60;

alter table public.app_settings
  drop constraint if exists app_settings_ranked_bot_after_seconds_check;
alter table public.app_settings
  add constraint app_settings_ranked_bot_after_seconds_check
  check (ranked_bot_after_seconds >= 10 and ranked_bot_after_seconds <= 600);

-- ---- 3. One shared bot identity for every bot in the game -----------------
-- 50 names, 13 avatars -- the avatars are exactly the real card slugs this
-- game ships with (dereo, dione-grifo, dorme, eva, fey, himanta, lium,
-- lumea, mako, sinie, stelaris, umiro, wuzu), so Avatar.tsx renders one with
-- zero changes of its own: it already takes a plain slug string.
create or replace function public.bot_identity()
returns table(name text, avatar text)
language sql as $$
  select
    (array[
      'Shadowfang','Nightshade','Ironclad','Voidwalker','Emberclaw','Frostbite','Ravenwing',
      'Stormcaller','Duskblade','Ashen Wolf','Crimson Fang','Silverstrike','Obsidian','Thornback',
      'Grimhold','Wraithborn','Solaris','Nova Ghost','Hollowmoon','Steel Fang','Bramblewick',
      'Cinderfall','Northwind','Direwolf','Ghostlight','Rustblade','Windrunner','Mournhollow',
      'Sable Claw','Ironvein','Wolfsbane','Crowfeather','Duststorm','Nightfall','Bonecrusher',
      'Whisperwind','Thornbite','Blacksail','Grimoire','Pale Rider','Onyx Fang','Stormbreaker',
      'Vex','Talon','Rook','Cipher','Marrow','Tundra','Vesper','Zephyr'
    ])[1 + floor(random() * 50)::int] as name,
    (array['dereo','dione-grifo','dorme','eva','fey','himanta','lium','lumea','mako','sinie',
           'stelaris','umiro','wuzu']
    )[1 + floor(random() * 13)::int] as avatar
$$;

-- ---- 4. Vs Bots practice: swap the old bot_name(level) placeholder -------
-- ("CALM"/"SHARP"/"RUTHLESS" + a first-letter circle) for bot_identity().
-- Everything else about this function (deck, fresh map, the deploy/ready
-- flow) is unchanged.
create or replace function public.create_bot_match(p_level int)
returns matches
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_name text; v_st jsonb; m public.matches;
  v_deck text[]; v_lvl int := greatest(1, least(3, coalesce(p_level, 2)));
  v_bot record;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select username into v_name from public.profiles where id = v_uid;
  if v_name is null then raise exception 'no profile'; end if;

  v_deck := random_deck();
  select * into v_bot from public.bot_identity();

  v_st := cn_fresh_map();
  v_st := jsonb_set(v_st, '{ready,guest}', 'true'::jsonb);
  v_st := state_log(v_st, v_name || ' spars with ' || v_bot.name || '.');
  v_st := state_log(v_st, 'Place your units, then press Ready.');

  insert into public.matches
    (code, host_id, host_name, guest_id, guest_name, guest_avatar, status, state,
     turn_deadline, bot, ranked)
  values
    (gen_match_code(), v_uid, v_name, null, v_bot.name, v_bot.avatar,
     'deploying', v_st, now() + interval '90 seconds', v_lvl, false)
  returning * into m;

  perform cn_open_deploy(m.id, m.state, v_uid, null, v_deck);
  insert into public.match_presence (match_id, user_id, side)
  values (m.id, v_uid, 'host') on conflict (match_id, user_id) do update set seen_at = now();
  return m;
end $$;

-- ---- 5. finish_match(): route a ranked bot-fallback match to its own -----
--         Elo path instead of just returning.
create or replace function public.finish_match(p_match uuid, p_winner text, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  m public.matches;
  w_id uuid; l_id uuid; w_name text; l_name text;
  w_rating int; l_rating int; w_g int; l_g int;
  e_w numeric; k_w int; k_l int;
  w_rating_new int; l_rating_new int;
begin
  select * into m from public.matches where id = p_match;
  if m.id is null then return; end if;
  if m.status = 'finished' then return; end if;

  if m.guest_id is null then
    if m.ranked and m.bot is not null then
      perform finish_ranked_bot_match(m, p_winner, p_reason);
    end if;
    return;
  end if;

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

-- ---- 6. The only place a ranked bot-fallback match touches rating --------
-- Standard Elo, k/3, applied to the host only -- m.bot_rating stands in for
-- the (nonexistent) opponent side. Same profiles/match_results/achievements
-- bookkeeping as a real match's win/loss branch, just one-sided.
create or replace function public.finish_ranked_bot_match(m matches, p_winner text, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  h_rating int; h_g int; e_h numeric; k_h int; h_rating_new int; v_won boolean;
begin
  insert into public.player_rating (user_id) values (m.host_id) on conflict (user_id) do nothing;
  select rating, games into h_rating, h_g from public.player_rating where user_id = m.host_id;

  v_won := (p_winner = 'host');
  e_h := expected_score(h_rating, coalesce(m.bot_rating, h_rating));
  k_h := cn_elo_k(h_g);

  h_rating_new := round(h_rating + (k_h::numeric / 3) * ((case when v_won then 1 else 0 end) - e_h));

  update public.player_rating set rating = h_rating_new, games = games + 1, updated_at = now()
   where user_id = m.host_id;

  if v_won then
    update public.profiles set wins = wins + 1, ranked_wins = ranked_wins + 1, games = games + 1,
      streak = case when streak >= 0 then streak + 1 else 1 end
     where id = m.host_id;
  else
    update public.profiles set losses = losses + 1, games = games + 1,
      streak = case when streak <= 0 then streak - 1 else -1 end
     where id = m.host_id;
  end if;

  insert into public.match_results
    (code, season, winner_id, loser_id, winner_name, loser_name,
     winner_lp, loser_lp,
     winner_rating_before, winner_rating_after, loser_rating_before, loser_rating_after,
     reason)
  values (
    m.code, current_season(),
    case when v_won then m.host_id else null end,
    case when v_won then null else m.host_id end,
    case when v_won then m.host_name else m.guest_name end,
    case when v_won then m.guest_name else m.host_name end,
    case when v_won then h_rating_new - h_rating else 0 end,
    case when v_won then 0 else h_rating_new - h_rating end,
    h_rating, h_rating_new, h_rating, h_rating_new,
    p_reason
  );

  if v_won then perform cn_check_achievements(m.host_id); end if;
end $$;

-- ---- 7. ranked_tick(): fall back to a bot when nobody real is found ------
-- Unchanged above the fallback branch: still tries to find a real opponent
-- first, same queue-window logic as before. Only new behaviour is what
-- happens when v_them.user_id is null -- instead of always just returning
-- {match: null, waiting: N}, it now checks how long THIS player has been
-- queued against app_settings.ranked_bot_after_seconds and, once past it,
-- creates a ranked bot-fallback match: guest_id = null, bot = a level
-- picked from the player's own rating band, bot_rating = the player's
-- rating +/- up to 150 (never negative) -- and returns {match: <id>,
-- waiting: 0}, the exact same shape the client already expects for "match
-- found".
create or replace function public.ranked_tick()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_name text; v_rating int; v_joined timestamptz;
  v_them public.ranked_queue; m public.matches; v_st jsonb;
  v_found uuid; v_waiting int; v_host uuid; v_hname text; v_guest uuid; v_gname text;
  v_bot_after int; v_bot record; v_bot_rating int; v_lvl int; v_deck text[];
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
    select coalesce(ranked_bot_after_seconds, 60) into v_bot_after
      from public.app_settings where id;
    v_bot_after := coalesce(v_bot_after, 60);

    if now() - v_joined >= make_interval(secs => v_bot_after) then
      select * into v_bot from public.bot_identity();
      v_bot_rating := greatest(0, v_rating + (floor(random() * 301)::int - 150));
      v_lvl := case when v_rating < 900 then 1 when v_rating < 1300 then 2 else 3 end;
      v_deck := random_deck();

      v_st := cn_fresh_map();
      v_st := state_log(v_st, 'No opponent found -- pairing you with ' || v_bot.name || '.');
      v_st := state_log(v_st, 'Place your units, then press Ready.');

      insert into public.matches
        (code, host_id, host_name, guest_id, guest_name, guest_avatar, status, state,
         turn_deadline, bot, ranked, bot_rating)
      values
        (gen_match_code(), v_uid, v_name, null, v_bot.name, v_bot.avatar,
         'deploying', v_st, now() + interval '90 seconds', v_lvl, true, v_bot_rating)
      returning * into m;

      perform cn_open_deploy(m.id, m.state, v_uid, null, v_deck);
      update public.ranked_queue set active = false where user_id = v_uid;
      insert into public.match_presence (match_id, user_id, side)
      values (m.id, v_uid, 'host') on conflict (match_id, user_id) do update set seen_at = now();

      return jsonb_build_object('match', m.id, 'waiting', 0);
    end if;

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

-- ---------------------------------------------------------------------------
-- Did it work?
-- ---------------------------------------------------------------------------
-- select proname from pg_proc where proname in
--   ('bot_identity','create_bot_match','ranked_tick','finish_ranked_bot_match','finish_match');
-- select column_name from information_schema.columns where table_name = 'matches'
--   and column_name in ('guest_avatar','bot_rating');
-- select ranked_bot_after_seconds from app_settings;
