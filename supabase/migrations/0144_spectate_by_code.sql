-- Jared: "I cant watch my friend playing a ranked match against a bot!!
-- I want to!"
--
-- A ranked match that fell back to a bot opponent is a real match, playing
-- out right now -- it just isn't advertised on the "Live Matches" page,
-- which deliberately leaves bot rooms off the list (see Lobby.tsx's own
-- comment: "Practice is not a spectacle... the room still exists and its
-- code still works, so a friend you hand it to can walk in and watch. It
-- is simply not advertised."). That comment describes a fallback that was
-- never actually true: join_match() throws 'that room is already full'
-- for ANYONE who isn't already the host or guest the moment status is no
-- longer 'waiting' -- which for a bot match is almost immediately, since
-- the bot fills the guest seat the instant the room is created. There was
-- never a working way in for a third person, by code or otherwise, once
-- the match had actually started -- for a bot match OR a human one.
--
-- Fix: past 'waiting', someone who isn't already a player just gets the
-- match row back, unchanged -- the same thing clicking straight into an
-- already-active room from the Live Matches list already does for a
-- human match. Nothing about them joins, nothing about the room changes;
-- they're simply allowed to look, exactly like the comment above always
-- claimed. Jared's friend can hand him the room code off the header pill
-- (rendered for every match, bot or not) and he types it into the same
-- "join a friend's room" box.
create or replace function public.join_match(p_code text)
 returns matches
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_uid uuid := auth.uid(); v_name text; m public.matches; v_st jsonb;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select username into v_name from public.profiles where id = v_uid;

  select * into m from public.matches where code = upper(trim(p_code)) for update;
  if m.id is null then raise exception 'no room with that code'; end if;
  if m.host_id = v_uid or m.guest_id = v_uid then return m; end if;

  -- 0144: watch, don't join, once the room already has its two sides.
  if m.status <> 'waiting' then return m; end if;

  v_st := state_log(m.state, v_name || ' entered the arena.');
  v_st := state_log(v_st, 'Place your units, then press Ready.');

  update public.matches
     set guest_id = v_uid, guest_name = v_name, status = 'deploying',
         state = v_st, turn_deadline = now() + interval '90 seconds', updated_at = now()
   where id = m.id returning * into m;

  perform cn_open_deploy(m.id, m.state, m.host_id, v_uid, null);
  insert into public.match_presence (match_id, user_id, side)
  values (m.id, v_uid, 'guest') on conflict (match_id, user_id) do update set seen_at = now();
  return m;
end $function$;
