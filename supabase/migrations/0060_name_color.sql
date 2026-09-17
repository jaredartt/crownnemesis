-- 0060: a player picks a color for their own name in Profile, and it shows
-- wherever their name shows to somebody else -- a live 1v1 match's
-- nameplates, Battle Royale's seat list, the ladder, friends, admin, and
-- both games' chat rails. Nine fixed swatches, the developer's own list:
-- red, orange, green, sky blue, (normal) blue, purple, black, gray, brown.
--
-- ONE COLUMN IS THE TRUTH: `profiles.name_color`. Everywhere that already
-- reads a live `profiles`/`leaderboard` row (ladder, friends, admin, your
-- own "who am I") gets it for free once the view is widened below -- no
-- other server change needed there.
--
-- Two places do NOT read `profiles` live, by existing design, and needed
-- their own column instead of a join:
--   * `match_messages`/`royale_messages` already denormalize `username`
--     onto the message row at send time (so a name change doesn't rewrite
--     history, and so a realtime INSERT payload -- which never carries a
--     join -- still has a name to show). `name_color` rides along the same
--     way, for the same reason: a join here would show the RIGHT color on
--     the first page load and NO color on every message that arrives
--     afterwards over realtime, since `useMessages`/`useRoyaleMessages`
--     merge `payload.new` directly rather than re-querying.
--   * `royale_players`, by contrast, IS safe to join live: its own realtime
--     handler (`useRoyalePlayers`) re-runs the full `select` on every
--     change rather than merging a bare payload (see `useRoyaleMatch.ts`),
--     so a nested `profiles(name_color)` embed is added to that query
--     client-side in this same change, needing no new column and no
--     splice here at all.
--   * `matches.host_name`/`guest_name` are the same kind of frozen
--     snapshot, but Match.tsx/VsIntro.tsx already have a precedent for a
--     LIVE (not frozen) extra field alongside them -- `getMatchIntroProfiles`
--     (0045), fetched by host_id/guest_id. `name_color` is added to that
--     same call rather than a new `matches` column, which has the added
--     benefit that a color change shows up in a match already in progress,
--     the same turn it's changed.

-- ---------------------------------------------------------------------------
-- 1. the color itself
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column if not exists name_color text not null default 'blue';
alter table public.profiles drop constraint if exists profiles_name_color_check;
alter table public.profiles add constraint profiles_name_color_check
  check (name_color in ('red', 'orange', 'green', 'sky', 'blue', 'purple', 'black', 'gray', 'brown'));
-- No trigger needed the way `avatar` needed `cn_check_avatar`: a bad value
-- here can't ever be "a real card that used to exist" -- it's either one of
-- the nine or it's rejected outright, by the CHECK itself, on every write
-- path (the RPC below AND the direct "own profile updatable" RLS path).

create or replace function public.set_name_color(p_color text)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if p_color not in ('red', 'orange', 'green', 'sky', 'blue', 'purple', 'black', 'gray', 'brown') then
    raise exception 'not one of the nine name colors';
  end if;
  update public.profiles set name_color = p_color where id = v_uid;
  return p_color;
end $$;
grant execute on function public.set_name_color(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. the ladder shows it too -- same drop/recreate 0016 and 0026 both used
--    to widen this exact view.
-- ---------------------------------------------------------------------------
drop view if exists public.leaderboard;
create view public.leaderboard
with (security_invoker = true) as
  select p.id, p.username, p.avatar, p.name_color, p.lp, tier_of(p.lp) as tier,
         p.wins, p.losses, p.games, p.streak, p.tournaments
    from public.profiles p
   where p.games > 0;
grant select on public.leaderboard to authenticated;

-- ---------------------------------------------------------------------------
-- 3. chat: denormalized the same way `username` already is, and for the
--    same realtime reason (see header). Old rows backfill to the same
--    'blue' default everyone starts with, rather than a null a renderer
--    would have to special-case.
-- ---------------------------------------------------------------------------
alter table public.match_messages
  add column if not exists name_color text not null default 'blue';
alter table public.match_messages drop constraint if exists match_messages_name_color_check;
alter table public.match_messages add constraint match_messages_name_color_check
  check (name_color in ('red', 'orange', 'green', 'sky', 'blue', 'purple', 'black', 'gray', 'brown'));

alter table public.royale_messages
  add column if not exists name_color text not null default 'blue';
alter table public.royale_messages drop constraint if exists royale_messages_name_color_check;
alter table public.royale_messages add constraint royale_messages_name_color_check
  check (name_color in ('red', 'orange', 'green', 'sky', 'blue', 'purple', 'black', 'gray', 'brown'));

-- `match_messages` is inserted directly by the client (Chat.tsx already
-- sends `username` itself the same way) so no function splice is needed
-- there. `royale_messages` goes through `send_royale_message` -- which
-- already looks up the sender's `username` server-side -- so that's the one
-- function actually spliced by this migration.
create or replace function public.send_royale_message(p_match uuid, p_body text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := auth.uid(); v_name text; v_color text;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select username, name_color into v_name, v_color from public.profiles where id = v_uid;
  if v_name is null then raise exception 'no profile'; end if;
  insert into public.royale_messages (match_id, user_id, username, name_color, body)
  values (p_match, v_uid, v_name, coalesce(v_color, 'blue'), left(coalesce(p_body, ''), 500));
end
$$;

-- ---------------------------------------------------------------------------
-- Did it work? All true means yes.
-- ---------------------------------------------------------------------------
select
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='profiles' and column_name='name_color') = 1
                                                                    as profiles_have_a_color,
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='leaderboard' and column_name='name_color') = 1
                                                                    as and_the_ladder_shows_it,
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='match_messages' and column_name='name_color') = 1
                                                                    as chat_carries_it,
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='royale_messages' and column_name='name_color') = 1
                                                                    as royale_chat_carries_it,
  to_regprocedure('public.set_name_color(text)') is not null       as set_name_color_exists;
