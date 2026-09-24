-- ===========================================================================
--  HOW TO RUN THIS
--  Already applied live (via the Supabase MCP, migration name
--  `fix_ranked_bot_fallback_never_readies`) -- this file exists so the
--  change has a normal migration history entry in the repo. If you ever DO
--  need to run it by hand: Supabase dashboard -> SQL Editor -> New query ->
--  paste this whole file -> Run. Safe to run twice -- it only replaces a
--  function body.
-- ===========================================================================
--  fix_ranked_bot_never_readies
--
--  Jared's report: "why is the bot thinking for so long? it's a bot, it's
--  just letting its turn's time pass by!"
--
--  What was actually wrong had nothing to do with a slow combat turn --
--  the match never got that far. A ranked match that falls back to a bot
--  opponent (nobody else in queue after `ranked_bot_after_seconds`) never
--  left the deployment screen: the player sat on "WAITING FOR YOUR
--  OPPONENT" watching the 90s deployment timer count all the way down to
--  0, because the match's `deploying` status ends only once BOTH sides are
--  marked ready, and the bot's side never was.
--
--  0090 (bot_identity_and_ranked_fallback.sql) introduced this bot-fallback
--  branch inside ranked_tick(), building the new match's starting `state`
--  with `cn_fresh_map()` and then going straight to the `state_log()` calls
--  and the `insert into matches`. It never set the bot's `ready` flag. The
--  OLDER practice-mode path, `create_bot_match()`, has always done this --
--  right after its own `cn_fresh_map()` call it has:
--    v_st := jsonb_set(v_st, '{ready,guest}', 'true'::jsonb);
--  ranked_tick()'s bot-fallback branch was simply missing the equivalent
--  line, so the bot (always the guest side here) stayed permanently
--  not-ready and the match could never advance out of `deploying`.
--
--  Fix: add that one line to ranked_tick()'s bot-fallback branch, in the
--  same spot create_bot_match() has it -- right after `cn_fresh_map()`,
--  before the `state_log()` calls. Nothing else in the function changed;
--  this is the full function body (create-or-replace) so the file matches
--  what actually runs, not a diff.
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.ranked_tick()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$;

-- ---------------------------------------------------------------------------
-- Did it work?
-- ---------------------------------------------------------------------------
-- select prosrc from pg_proc where proname = 'ranked_tick';
-- Should contain, right after the bot-fallback branch's `cn_fresh_map()`:
--   v_st := jsonb_set(v_st, '{ready,guest}', 'true'::jsonb);
-- A ranked match that falls back to a bot opponent should now leave
-- `deploying` as soon as the human player readies up, instead of sitting on
-- "WAITING FOR YOUR OPPONENT" until the 90s deployment timer runs out:
-- select id, status, bot, (state->'ready') as ready
--   from matches where ranked and bot is not null
--   order by created_at desc limit 5;
