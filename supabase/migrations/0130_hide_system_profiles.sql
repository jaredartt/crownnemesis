-- Jared: "who the heck is training engine and why is it in ladder? it
-- makes no sense." TrainingEngine (public.cn_sim_profile_id()) is the
-- dedicated hidden profile 0114 (Bot Training Data Center) plays every
-- self-play simulation match through -- that migration's own header says
-- it should "never touch the ladder, player_rating, or the public room
-- list", and the room list already filters `bot is null` for that reason.
-- But the `leaderboard` VIEW (public.leaderboard, read by both the Ladder
-- screen and PlayerCard) is a bare join over every row in `profiles` with
-- no such filter -- and neither is Friends.tsx's own username search,
-- which would surface it too under a search for "train". TrainingEngine
-- has played 700+ sim games (bot_wins) but zero real ranked games, so it
-- shows up with the same default rating (1000) any brand-new player gets.
--
-- General fix, not a hardcoded id/username check in either place: a
-- reusable `is_system` flag on profiles (false for every real player),
-- set true for the one row that exists today (the sim profile) via the
-- same cn_sim_profile_id() accessor everything else already uses to name
-- it, so any future system/service profile only has to flip this same
-- flag to stay off both the ladder and search -- nothing to remember to
-- update in two places by hand.
alter table public.profiles
  add column if not exists is_system boolean not null default false;

update public.profiles set is_system = true where id = cn_sim_profile_id();

-- leaderboard: exclude system profiles at the view level, so every reader
-- (Ladder, PlayerCard, anything else that queries it later) is covered
-- for free.
create or replace view public.leaderboard as
 SELECT p.id,
    p.username,
    p.avatar,
    p.name_color,
    COALESCE(r.rating, 1000) AS rating,
    p.wins,
    p.losses,
    p.games,
    p.streak,
    p.tournaments
   FROM profiles p
     LEFT JOIN player_rating r ON r.user_id = p.id
   WHERE NOT p.is_system;

-- Client side (same commit): Profile gains an optional `is_system` field
-- (src/lib/types.ts), and Friends.tsx's own username search excludes it
-- the same way, instead of a second hardcoded check.
