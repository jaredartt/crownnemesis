-- 0129: the bot never places its own army -- it just inherits cn_army's
-- generic packer, and every unit that fits in one row (which every current
-- 5-card deck does, on a 6-wide board) piles onto that single row.
--
-- Jared: "the bot doesn't initially position their units on the map, they
-- always start with all its units in the first rows, that is a huge
-- advantage for the opponent. The Expert bot also needs to learn where to
-- position all their units initially."
--
-- cn_army was never meant to be anyone's FINAL placement -- it is the
-- starting default a human sees on entering the deploy phase, which they
-- then rearrange with deploy_unit before pressing Ready (cn_place is
-- nothing more than a fresh call to cn_army). The bot never calls
-- deploy_unit -- bot_step only runs once status = 'active', nothing runs
-- for it during 'deploying' -- so cn_army's scratch default is the only
-- placement it has ever had.
--
-- cn_bot_army gives the bot its own placement pass, keyed to bot level:
--   1 (Easy):   round-robins every unit across the WHOLE deploy zone
--               instead of packing one row -- no tactics, just not a
--               sitting duck for a single AOE hit any more.
--   2 (Medium): the same round-robin, except the king is always ranked
--               to the back row -- the one piece of formation sense that
--               matters most.
--   3 (Expert): a real (if simple) formation -- casters and the king kept
--               back, knights held on the front line, everything else in
--               between (cn_bot_role_rank). This also directly undoes the
--               "huge advantage" Jared flagged: a formation spread across
--               rows and columns is not a formation a single aoe_adjacent
--               swing (see 0128) can gut in one hit.
--
-- cn_bot_col_order spreads units within a row from the CENTER outward
-- (a simple bisection of the column range) rather than left-to-right, so
-- two units sharing a rank end up spaced apart instead of side by side.
create or replace function public.cn_bot_col_order(p_n int)
 RETURNS int[]
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
declare
  v_order int[] := '{}';
  v_lo int[] := array[0];
  v_hi int[] := array[p_n - 1];
  v_l int; v_h int; v_mid int; v_n int;
begin
  if p_n <= 0 then return v_order; end if;
  while coalesce(array_length(v_lo, 1), 0) > 0 loop
    v_n := array_length(v_lo, 1);
    v_l := v_lo[1]; v_h := v_hi[1];
    v_lo := v_lo[2:v_n]; v_hi := v_hi[2:v_n];
    if v_l > v_h then continue; end if;
    v_mid := (v_l + v_h) / 2;
    v_order := v_order || v_mid;
    if v_l <= v_mid - 1 then v_lo := v_lo || v_l; v_hi := v_hi || (v_mid - 1); end if;
    if v_mid + 1 <= v_h then v_lo := v_lo || (v_mid + 1); v_hi := v_hi || v_h; end if;
  end loop;
  return v_order;
end
$function$;

-- Back (0) to front (highest rank) role order for Expert's formation.
-- Royal and mage are the two kinds of unit a formation exists to protect
-- (the king because losing it loses the match outright -- see 0128 --
-- and a mage for the ordinary reason a squishy ranged unit stays behind
-- a body); knight is this roster's frontline melee class; rogue and
-- flying fall in between. Ties (two knights, say) are fine -- they share
-- a row and cn_bot_col_order spaces them apart within it.
create or replace function public.cn_bot_role_rank(p_role text, p_max_rank int)
 RETURNS int
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select least(p_max_rank, case p_role
    when 'royal'  then 0
    when 'mage'   then 0
    when 'rogue'  then 1
    when 'flying' then 2
    when 'knight' then 3
    else 1
  end)
$function$;

create or replace function public.cn_bot_army(p_state jsonb, p_side text, p_deck text[], p_level int DEFAULT 1)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
declare
  v_units jsonb := cn_army(p_state, p_side, p_deck);
  v_w int := (p_state->'board'->>'w')::int;
  v_h int := (p_state->'board'->>'h')::int;
  v_lvl int := greatest(1, least(3, coalesce(p_level, 1)));
  v_taken text[] := '{}';
  e jsonb; u jsonb;
  v_rows int[] := '{}';
  v_row_n int; v_cols int[]; v_col_n int;
  v_idx int := 0; v_rank int;
  v_x int; v_y int; v_key text; v_found boolean; c int; r int;
  v_out jsonb := '[]'::jsonb;
begin
  for e in select * from jsonb_array_elements(coalesce(p_state->'obstacles', '[]'::jsonb)) loop
    v_taken := v_taken || ((e->>'x') || ',' || (e->>'y'));
  end loop;

  -- Same back-to-front row convention cn_army's own packer uses -- row 1
  -- of this array is the safest tile in the zone, the last is the front
  -- line touching the opponent's half.
  if p_side = 'host' then
    for r in 0 .. (v_h / 2 - 1) loop v_rows := v_rows || r; end loop;
  else
    for r in reverse (v_h - 1) .. (v_h / 2) loop v_rows := v_rows || r; end loop;
  end if;
  v_row_n := array_length(v_rows, 1);
  v_cols := cn_bot_col_order(v_w);
  v_col_n := array_length(v_cols, 1);

  for u in select * from jsonb_array_elements(v_units) loop
    if v_lvl >= 3 then
      v_rank := cn_bot_role_rank(u->>'role', v_row_n - 1);
    elsif v_lvl = 2 then
      v_rank := case when coalesce((u->>'royal')::boolean, false)
                     then 0 else v_idx % v_row_n end;
    else
      v_rank := v_idx % v_row_n;
    end if;
    v_idx := v_idx + 1;

    -- Walk forward from the intended rank (then, failing that, every
    -- other row) looking for a free tile via the centre-out column
    -- order -- a tree or an already-placed unit this call just seated
    -- is the only thing that ever pushes a unit off its intended row,
    -- and even then it never has to look far on a board this open.
    v_found := false;
    for r in 0 .. v_row_n - 1 loop
      exit when v_found;
      v_y := v_rows[1 + ((v_rank + r) % v_row_n)];
      for c in 1 .. v_col_n loop
        v_x := v_cols[c];
        v_key := v_x || ',' || v_y;
        if not (v_key = any(v_taken)) then
          v_taken := v_taken || v_key;
          v_found := true;
          exit;
        end if;
      end loop;
    end loop;
    if not v_found then raise exception 'nowhere to deploy'; end if;

    v_out := v_out || jsonb_set(jsonb_set(u, '{x}', to_jsonb(v_x)), '{y}', to_jsonb(v_y));
  end loop;

  return v_out;
end
$function$;

-- cn_open_deploy: a bot guest (p_guest is null) now gets cn_bot_army
-- instead of cn_army's plain default -- p_bot_level threaded through
-- from whichever caller already knows it. A null level (every existing
-- call site until this migration edits them) still resolves to 1 inside
-- cn_bot_army, so this is additive: nothing changes until a caller
-- actually passes a level.
--
-- Adding a parameter is a NEW overload as far as Postgres is concerned,
-- not a replacement of the 5-arg version -- CREATE OR REPLACE only
-- replaces an identical signature. Drop the old one first so every
-- existing 5-arg call site (join_match, cn_tourney_spawn,
-- request_rematch) resolves to this one instead of quietly keeping the
-- stale copy around as a dead second overload.
drop function if exists public.cn_open_deploy(uuid, jsonb, uuid, uuid, text[]);
create or replace function public.cn_open_deploy(p_match uuid, p_state jsonb, p_host uuid, p_guest uuid, p_bot_deck text[], p_bot_level int DEFAULT NULL)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
begin
  insert into public.match_deploy (match_id, side, user_id, units) values
    (p_match, 'host',  p_host,
     cn_army(p_state, 'host',  deck_of(p_host))),
    (p_match, 'guest', p_guest,
     case when p_guest is null
          then cn_bot_army(p_state, 'guest', p_bot_deck, p_bot_level)
          else cn_army(p_state, 'guest', deck_of(p_guest))
     end)
  on conflict (match_id, side) do update set units = excluded.units, user_id = excluded.user_id;
end $function$;

-- The two places a bot's own level is known at deploy time -- everywhere
-- else that calls cn_open_deploy (join_match, cn_tourney_spawn,
-- request_rematch's human branch) is host-vs-host and never touches the
-- new parameter.
create or replace function public.create_bot_match(p_level integer)
 RETURNS matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  perform cn_open_deploy(m.id, m.state, v_uid, null, v_deck, v_lvl);
  insert into public.match_presence (match_id, user_id, side)
  values (m.id, v_uid, 'host') on conflict (match_id, user_id) do update set seen_at = now();
  return m;
end $function$;

create or replace function public.ranked_tick()
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
        (code, host_id, host_name, guest_id, guest_name, guest_avatar, guest_name_color, status, state,
         turn_deadline, bot, ranked, bot_rating)
      values
        (gen_match_code(), v_uid, v_name, null, v_bot.name, v_bot.avatar, v_bot.name_color,
         'deploying', v_st, now() + interval '90 seconds', v_lvl, true, v_bot_rating)
      returning * into m;

      perform cn_open_deploy(m.id, m.state, v_uid, null, v_deck, v_lvl);
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
