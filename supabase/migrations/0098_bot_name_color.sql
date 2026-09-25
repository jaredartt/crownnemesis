-- ===========================================================================
--  HOW TO RUN THIS
--  Already applied live (via the Supabase MCP, migration name
--  `bot_name_color`) -- this file exists so the change has a normal
--  migration history entry in the repo. If you ever DO need to run it by
--  hand: Supabase dashboard -> SQL Editor -> New query -> paste this whole
--  file -> Run. Safe to run twice -- it only adds columns (if not exists)
--  and replaces function bodies.
-- ===========================================================================
--  bot_name_color
--
--  Jared: "let's make it so that bots also have a random color name (from
--  the color palette that currently players can choose from, of course)."
--
--  0060 gave every real player a name_color (one of the same nine swatches
--  NAME_COLORS lists client-side: red/orange/green/sky/blue/purple/black/
--  gray/brown), read live off profiles.name_color wherever a name shows.
--  A bot has no profiles row for that to key on -- exactly the same gap
--  0090 hit for a bot's AVATAR, and fixed the same way: bot_identity()
--  already hands back a random name/avatar for every bot, shared by all
--  three places a bot gets created (create_bot_match's practice Vs Bots,
--  ranked_tick's ranked fallback, add_royale_bot's Battle Royale seat).
--  This adds a third field to that same function -- a random name_color --
--  and threads it through the same three call sites the same way avatar
--  already goes: a frozen column on the row itself (matches.guest_avatar/
--  royale_players.avatar's own pattern), since a bot has nothing live to
--  join against.
--
--  matches.guest_name_color mirrors guest_avatar exactly (Match.tsx/
--  VsIntro.tsx's own "avatar ?? guest_avatar" fallback gets a "color ??
--  guest_name_color" twin, client-side, in the same change).
--
--  royale_players.name_color is new -- that table never had one, because
--  0060's own comment says every royale seat is "safe to join live" against
--  profiles(name_color) instead (useRoyalePlayers already does). That join
--  is still exactly right for a HUMAN seat; a bot seat's user_id is null,
--  so the join returns null and the client now falls back to this column,
--  same shape as royale_players.avatar/bot already work.
-- ===========================================================================

-- ---- 1. New columns, both nullable, both no-ops for a real player's own
--         row (their color keeps coming from the live join/lookup it
--         already used) ---------------------------------------------------
alter table public.matches
  add column if not exists guest_name_color text;
alter table public.royale_players
  add column if not exists name_color text;

-- ---- 2. bot_identity(): one more random pick, same nine values the check
--         constraint on profiles.name_color enforces for a real player
--         (see 0060_name_color.sql) -- kept in the exact same order so a
--         diff against that constraint is trivial to eyeball. ------------
-- CREATE OR REPLACE cannot change an existing function's return type
-- (adding name_color to the TABLE(...) shape) -- drop first.
drop function if exists public.bot_identity();
create or replace function public.bot_identity()
returns table(name text, avatar text, name_color text)
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
    )[1 + floor(random() * 13)::int] as avatar,
    (array['red','orange','green','sky','blue','purple','black','gray','brown']
    )[1 + floor(random() * 9)::int] as name_color
$$;

-- ---- 3. create_bot_match(): practice Vs Bots -- store the pick alongside
--         the existing guest_avatar write, nothing else changed. ---------
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
    (code, host_id, host_name, guest_id, guest_name, guest_avatar, guest_name_color, status, state,
     turn_deadline, bot, ranked)
  values
    (gen_match_code(), v_uid, v_name, null, v_bot.name, v_bot.avatar, v_bot.name_color,
     'deploying', v_st, now() + interval '90 seconds', v_lvl, false)
  returning * into m;

  perform cn_open_deploy(m.id, m.state, v_uid, null, v_deck);
  insert into public.match_presence (match_id, user_id, side)
  values (m.id, v_uid, 'host') on conflict (match_id, user_id) do update set seen_at = now();
  return m;
end $$;

-- ---- 4. ranked_tick(): the ranked bot-fallback branch -- same addition,
--         full function body (create-or-replace) so the file matches what
--         actually runs, not a diff (0092's own precedent). --------------
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
      v_st := jsonb_set(v_st, '{ready,guest}', 'true'::jsonb);
      v_st := state_log(v_st, 'No opponent found -- pairing you with ' || v_bot.name || '.');
      v_st := state_log(v_st, 'Place your units, then press Ready.');

      insert into public.matches
        (code, host_id, host_name, guest_id, guest_name, guest_avatar, guest_name_color, status, state,
         turn_deadline, bot, ranked, bot_rating)
      values
        (gen_match_code(), v_uid, v_name, null, v_bot.name, v_bot.avatar, v_bot.name_color,
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

-- ---- 5. add_royale_bot(): the third and last call site -- royale_players
--         gets its own name_color column written (see header). ----------
create or replace function public.add_royale_bot(p_match uuid, p_seat int, p_level int)
returns royale_matches language plpgsql security definer set search_path to 'public' as $$
declare
  m public.royale_matches; v_uid uuid := auth.uid();
  v_lvl int := greatest(1, least(3, coalesce(p_level, 2)));
  v_st jsonb; v_bot record;
begin
  select * into m from public.royale_matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'waiting' then raise exception 'you can only add a bot before the match starts'; end if;

  if not exists (
    select 1 from public.royale_players
     where match_id = p_match and seat = 0 and user_id = v_uid) then
    raise exception 'only the host can add a bot';
  end if;

  if p_seat < 1 or p_seat > 3 then raise exception 'no such seat'; end if;

  if exists (select 1 from public.royale_players where match_id = p_match and seat = p_seat) then
    raise exception 'that seat is already taken';
  end if;

  select * into v_bot from public.bot_identity();
  insert into public.royale_players (match_id, seat, user_id, username, avatar, name_color, bot)
  values (p_match, p_seat, null, v_bot.name, v_bot.avatar, v_bot.name_color, v_lvl);

  v_st := state_log(m.state, v_bot.name || ' joins the arena.');
  update public.royale_matches set state = v_st, updated_at = now()
   where id = m.id returning * into m;
  return m;
end
$$;

-- ---------------------------------------------------------------------------
-- Did it work?
-- ---------------------------------------------------------------------------
-- select proname from pg_proc
--  where proname in ('bot_identity','create_bot_match','ranked_tick','add_royale_bot');
-- select column_name from information_schema.columns
--  where table_name in ('matches','royale_players') and column_name like '%name_color%';
-- A freshly created bot match/seat should show a non-null color:
-- select guest_name, guest_name_color from matches where bot is not null
--   order by created_at desc limit 5;
-- select username, name_color from royale_players where bot is not null
--   order by created_at desc limit 5;
