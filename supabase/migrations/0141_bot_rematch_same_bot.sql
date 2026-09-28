-- Jared: "rematching a bot should mean the same bot I just played
-- against (same profile, same name color, same name, same team)."
--
-- request_rematch()'s bot branch called create_bot_match(m.bot), and
-- create_bot_match always called bot_identity() (a uniform random pick
-- across 50 names / 13 avatars / 9 colors) and random_deck() (a fresh
-- random 5-card kingdom) on every single call, rematches included --
-- there was never any reuse. The finished match row already keeps the
-- bot's name/avatar/name_color (guest_name/guest_avatar/guest_name_color),
-- but its 5-card deck was never stored as its own column.
--
-- Fix: create_bot_match gets an optional p_source_match uuid. When
-- request_rematch's bot branch passes the just-finished match's own id:
--   - identity is read straight off that match row instead of rerolled
--   - the deck is reconstructed from every card slug that match's bot
--     (guest) ever fielded -- units still alive in state.units, plus
--     anything that died, in state.graveyard.guest (that array caps at
--     8 entries, but a deck is only 5 cards, so it's never at risk of
--     being crowded out for this)
-- and only if that reconstruction comes back to a legal kingdom (exactly
-- 5 distinct cards, exactly 1 of them royal -- cn_army's own requirement)
-- does it get used; otherwise this falls back to the original
-- bot_identity()/random_deck() behaviour, same as if no source match had
-- been given at all. That fallback matters because a card from that old
-- deck could have been retired from the roster since, which would make
-- deck_royals() (it only counts is_active cards) come back wrong even
-- though the original deck was legal when it was played.
--
-- Every other caller of create_bot_match (the frontend's plain "Simulate
-- a bot" flow, and the SQL test suite) keeps passing just the level, so
-- p_source_match defaults to null and behaves exactly as before.
create or replace function public.create_bot_match(p_level integer, p_source_match uuid default null)
 returns matches
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid(); v_name text; v_st jsonb; m public.matches;
  v_deck text[]; v_lvl int := greatest(1, least(3, coalesce(p_level, 2)));
  v_bot_name text; v_bot_avatar text; v_bot_color text;
  v_src public.matches;
  v_recon text[];
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select username into v_name from public.profiles where id = v_uid;
  if v_name is null then raise exception 'no profile'; end if;

  if p_source_match is not null then
    select * into v_src from public.matches where id = p_source_match;
    if v_src.id is not null and v_src.bot is not null and v_src.guest_name is not null then
      v_bot_name := v_src.guest_name;
      v_bot_avatar := v_src.guest_avatar;
      v_bot_color := v_src.guest_name_color;

      select array_agg(distinct slug) into v_recon
        from (
          select u->>'slug' as slug
            from jsonb_array_elements(coalesce(v_src.state->'units', '[]'::jsonb)) u
           where u->>'owner' = 'guest'
          union
          select u->>'slug' as slug
            from jsonb_array_elements(coalesce(v_src.state->'graveyard'->'guest', '[]'::jsonb)) u
        ) s
       where slug is not null;

      if coalesce(array_length(v_recon, 1), 0) <> deck_size() or deck_royals(v_recon) <> 1 then
        v_recon := null;
      end if;
    end if;
  end if;

  if v_bot_name is null then
    select name, avatar, name_color into v_bot_name, v_bot_avatar, v_bot_color
      from public.bot_identity();
  end if;
  v_deck := coalesce(v_recon, random_deck());

  v_st := cn_fresh_map();
  v_st := jsonb_set(v_st, '{ready,guest}', 'true'::jsonb);
  v_st := state_log(v_st, v_name || ' spars with ' || v_bot_name || '.');
  v_st := state_log(v_st, 'Place your units, then press Ready.');

  insert into public.matches
    (code, host_id, host_name, guest_id, guest_name, guest_avatar, guest_name_color, status, state,
     turn_deadline, bot, ranked)
  values
    (gen_match_code(), v_uid, v_name, null, v_bot_name, v_bot_avatar, v_bot_color,
     'deploying', v_st, now() + interval '90 seconds', v_lvl, false)
  returning * into m;

  perform cn_open_deploy(m.id, m.state, v_uid, null, v_deck, v_lvl);
  insert into public.match_presence (match_id, user_id, side)
  values (m.id, v_uid, 'host') on conflict (match_id, user_id) do update set seen_at = now();
  return m;
end $function$;

-- request_rematch's bot branch now passes the finished match's own id
-- through as the source to reuse.
create or replace function public.request_rematch(p_match uuid)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  m public.matches; v_side text; v_st jsonb; nm public.matches; v_new uuid;
  v_depth int; v_ranked boolean;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'finished' then raise exception 'that match is still running'; end if;
  v_side := side_of(m, auth.uid());
  if v_side is null then raise exception 'you are spectating this match'; end if;
  if m.next_match_id is not null then return m.next_match_id; end if;

  if m.bot is not null then
    select id into v_new from public.create_bot_match(m.bot, m.id);
    update public.matches set next_match_id = v_new where id = p_match;
    return v_new;
  end if;

  if v_side = 'host'
    then update public.matches set rematch_host  = true, rematch_declined = false where id = p_match;
    else update public.matches set rematch_guest = true, rematch_declined = false where id = p_match;
  end if;

  select * into m from public.matches where id = p_match;
  if not (m.rematch_host and m.rematch_guest) then return null; end if;

  v_depth := coalesce(m.rematch_depth, 0) + 1;
  v_ranked := m.ranked and v_depth <= 3;

  v_st := cn_fresh_map();
  v_st := state_log(v_st, 'Rematch on new ground. ' || m.guest_name || ' moves first.');
  v_st := state_log(v_st, 'Place your units, then press Ready.');

  insert into public.matches
    (code, host_id, host_name, guest_id, guest_name, status, state, turn_deadline,
     ranked, rematch_depth)
  values
    (gen_match_code(), m.guest_id, m.guest_name, m.host_id, m.host_name,
     'deploying', v_st, now() + interval '90 seconds', v_ranked, v_depth)
  returning * into nm;

  perform cn_open_deploy(nm.id, nm.state, nm.host_id, nm.guest_id, null);
  insert into public.match_presence (match_id, user_id, side) values
    (nm.id, nm.host_id, 'host'), (nm.id, nm.guest_id, 'guest')
  on conflict (match_id, user_id) do update set seen_at = now();

  update public.matches set next_match_id = nm.id where id = p_match;
  return nm.id;
end $function$;
