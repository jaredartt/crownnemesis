-- ===========================================================================
--  HOW TO RUN THIS
--  Already applied live (via the Supabase MCP, migration name
--  `royale_bot_identity`) -- this file exists so the change has a normal
--  migration history entry in the repo. If you ever DO need to run it by
--  hand: Supabase dashboard -> SQL Editor -> New query -> paste this whole
--  file -> Run. Safe to run twice -- it only replaces a function body.
-- ===========================================================================
--  royale_bot_identity
--
--  Battle Royale's own "Add bot" button (RoyaleLobby.tsx, host-only, any
--  empty seat before the match starts) was still calling the OLD placeholder
--  identity this migration set out to retire everywhere: `bot_name(v_lvl)`,
--  which hands back a plain difficulty word -- 'CALM'/'SHARP'/'RUTHLESS' --
--  and left `royale_players.avatar` permanently null, so a bot's seat in
--  the lobby list and at the table drew Avatar.tsx's own first-letter-circle
--  fallback instead of a face. 0090 already fixed this for the OTHER two
--  bot paths (practice Vs Bots' create_bot_match(), and ranked's bot
--  fallback in ranked_tick()) by having both call the shared
--  `bot_identity()` function that migration introduced (50 names, 13 real
--  card-art slugs as avatars) -- this migration is the third and last call
--  site, add_royale_bot(), so every bot in the game now looks the same way
--  wherever one shows up.
--
--  Two changes to add_royale_bot(p_match, p_seat, p_level), nothing else in
--  it touched:
--   1. `select bot_name(v_lvl) into v_name` -> `select * into v_bot from
--      bot_identity()`, same as 0090's own create_bot_match()/ranked_tick()
--      rewrites.
--   2. The `royale_players` insert's `avatar` column, always `null` before,
--      now gets `v_bot.avatar` -- the column already existed and was simply
--      never populated for a bot seat.
--
--  Client side: nothing to change. RoyaleLobby.tsx and TurnBand.tsx already
--  render `p.avatar` through the existing `Avatar` component (it has taken
--  a plain slug string since 0090), so once this column is no longer null
--  for a bot row, it just works.
--
--  Rating: royale never touches it, before or after this change -- a Battle
--  Royale match has no `ranked` column and nothing here goes near
--  `player_rating` or `profiles`.
-- ===========================================================================

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
  insert into public.royale_players (match_id, seat, user_id, username, avatar, bot)
  values (p_match, p_seat, null, v_bot.name, v_bot.avatar, v_lvl);

  v_st := state_log(m.state, v_bot.name || ' joins the arena.');
  update public.royale_matches set state = v_st, updated_at = now()
   where id = m.id returning * into m;
  return m;
end
$$;

-- ---------------------------------------------------------------------------
-- Did it work?
-- ---------------------------------------------------------------------------
-- select proname from pg_proc where proname = 'add_royale_bot';
-- A bot seat added after this should show a real name (not CALM/SHARP/
-- RUTHLESS) and a non-null avatar slug:
-- select username, avatar, bot from royale_players where bot is not null
--   order by created_at desc limit 5;
