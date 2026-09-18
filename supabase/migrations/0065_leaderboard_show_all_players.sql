-- =============================================================================
-- 0065 -- the Ladder shows everyone, not just players with games > 0.
--
-- WHY: `leaderboard` filtered `where p.games > 0`, so a brand-new profile
-- (or anyone who hasn't finished a ranked match yet) never appeared on the
-- Ladder at all -- and per Jared, the Ladder should show ALL players
-- regardless of ladder points, each with an add-friend button. Dropping the
-- filter is the whole of the server-side change; the client's own
-- `.limit(50)` (Lobby.tsx) and the per-row add-friend button are a
-- client-only change tracked separately, not in this migration.
-- =============================================================================
create or replace view public.leaderboard as
select
  id, username, avatar, name_color, lp, tier_of(lp) as tier,
  wins, losses, games, streak, tournaments
from public.profiles p;

-- ---------------------------------------------------------------------------
-- Did it work?
-- ---------------------------------------------------------------------------
select
  (select count(*) from public.leaderboard) >= (select count(*) from public.profiles)
    as leaderboard_no_longer_filters_zero_game_players;
