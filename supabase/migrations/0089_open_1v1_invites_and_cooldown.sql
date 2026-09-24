-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice -- it only replaces a function body. Run 0043
--  first (this is that migration's send_match_invite, revised).
-- ===========================================================================
--  0089 -- a 1v1 invite no longer requires being friends first, and a
--  10-minute cooldown between repeat invites to the same person.
--
--  Jared, on the new Ladder profile popup: "the ability to send them an
--  invite to play 1 vs 1" -- from the LADDER, where most rows are strangers,
--  not friends. 0043's send_match_invite raised 'you can only invite a
--  friend' before even looking at which mode was asked for, which made that
--  button impossible to honour as asked. The check moves inside the '4p' and
--  'tournament' branches (both still friends-only -- neither of those has
--  anywhere on screen a stranger could reach them from) and simply never
--  runs for '1v1', which is exactly what an open room's own five-letter
--  code already lets any stranger join anyway; this just skips typing it.
--
--  Jared: "You can only send one invitation to the same person twice in a
--  row. Then, every there's a cooldown of 10 minutes." Read as: at most one
--  invite to somebody, then a 10-minute wait before the next one. Checked
--  against this account's own sent notifications rather than a new table --
--  every invite already writes one (cn_notify, 3 lines below), so "when did
--  I last invite this person" is just the newest matching row's timestamp.
--  Applies to every mode, including 4p/tournament, not only the now-open
--  1v1 path -- a friend can still be pestered exactly the way a stranger
--  now can be invited at all.
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

  if p_mode in ('4p', 'tournament')
     and not exists (select 1 from public.friends where user_id = v_uid and friend_id = p_to) then
    raise exception 'you can only invite a friend';
  end if;

  if exists (
    select 1 from public.notifications
     where user_id = p_to and type = 'match_invite'
       and (payload->>'from_id')::uuid = v_uid
       and created_at > now() - interval '10 minutes'
  ) then
    raise exception 'wait a few minutes before inviting them again';
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

grant execute on function public.send_match_invite(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Did it work? True means yes.
-- ---------------------------------------------------------------------------
select to_regprocedure('public.send_match_invite(uuid,text)') is not null as send_invite_exists;
