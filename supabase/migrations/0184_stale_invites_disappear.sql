-- 0184: an invitation to something that no longer exists disappears.
--
-- Jared: "if someone invited you to something (whatever), and they're not in that
-- room anymore, delete the notification of the invitation for the player that
-- received it, cause now that notification makes 0 sense."
--
-- An invite (notifications.type = 'match_invite') points at a 1v1 room
-- (payload.match_id), a Battle Royale room (payload.match_id, mode '4p') or the open
-- tournament (payload.tournament_id). It stops making sense when
--   * the room is deleted (the inviter left / nobody held it open),
--   * the room is no longer waiting (it started, or the match is over),
--   * the inviter is no longer seated in a Battle Royale room,
--   * the tournament is no longer open.
-- Row triggers delete those notifications on the spot, so the bell empties itself
-- through the realtime feed it already listens to; a one-off backfill clears what is
-- stale right now.

create or replace function public.cn_drop_invites(p_key text, p_id text, p_from uuid default null)
returns void language sql security definer set search_path = public as $$
  delete from public.notifications
   where type = 'match_invite'
     and payload->>p_key = p_id
     and (p_from is null or payload->>'from_id' = p_from::text);
$$;
revoke all on function public.cn_drop_invites(text, text, uuid) from public, anon, authenticated;

create or replace function public.cn_invites_room_gone() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.cn_drop_invites('match_id', old.id::text);
  return old;
end $$;

create or replace function public.cn_invites_room_started() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.cn_drop_invites('match_id', new.id::text);
  return new;
end $$;

create or replace function public.cn_invites_inviter_left() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.user_id is not null then
    perform public.cn_drop_invites('match_id', old.match_id::text, old.user_id);
  end if;
  return old;
end $$;

create or replace function public.cn_invites_tournament_closed() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.cn_drop_invites('tournament_id', new.id::text);
  return new;
end $$;

drop trigger if exists cn_invites_1v1_gone on public.matches;
create trigger cn_invites_1v1_gone after delete on public.matches
  for each row execute function public.cn_invites_room_gone();
drop trigger if exists cn_invites_1v1_started on public.matches;
create trigger cn_invites_1v1_started after update of status on public.matches
  for each row when (old.status = 'waiting' and new.status <> 'waiting')
  execute function public.cn_invites_room_started();

drop trigger if exists cn_invites_royale_gone on public.royale_matches;
create trigger cn_invites_royale_gone after delete on public.royale_matches
  for each row execute function public.cn_invites_room_gone();
drop trigger if exists cn_invites_royale_started on public.royale_matches;
create trigger cn_invites_royale_started after update of status on public.royale_matches
  for each row when (old.status = 'waiting' and new.status <> 'waiting')
  execute function public.cn_invites_room_started();
drop trigger if exists cn_invites_royale_left on public.royale_players;
create trigger cn_invites_royale_left after delete on public.royale_players
  for each row execute function public.cn_invites_inviter_left();

drop trigger if exists cn_invites_tournament_closed on public.tournaments;
create trigger cn_invites_tournament_closed after update of status on public.tournaments
  for each row when (old.status = 'open' and new.status <> 'open')
  execute function public.cn_invites_tournament_closed();

-- Backfill: whatever is stale right now.
delete from public.notifications n
 where n.type = 'match_invite'
   and (
     (n.payload->>'mode' = '1v1'
        and not exists (select 1 from public.matches m
                         where m.id::text = n.payload->>'match_id' and m.status = 'waiting'))
     or (n.payload->>'mode' = '4p'
        and not exists (select 1 from public.royale_matches r
                         where r.id::text = n.payload->>'match_id' and r.status = 'waiting'
                           and exists (select 1 from public.royale_players p
                                        where p.match_id = r.id
                                          and p.user_id::text = n.payload->>'from_id')))
     or (n.payload->>'mode' = 'tournament'
        and not exists (select 1 from public.tournaments t
                         where t.id::text = n.payload->>'tournament_id' and t.status = 'open'))
   );
