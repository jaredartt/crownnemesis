-- 0100: two asks from the same conversation about the tournament "cup" --
-- Jared: "I should be able to edit the 'won cups' number in that page" (the
-- admin Users screen) and "make it so that in order to win a cup, at least
-- 4 players should have participated, otherwise the 'won cups' number won't
-- go up (so like a just-for-fun tournament then, no rewards)."
--
-- profiles.tournaments IS the "won cups" number (see 0028's own comment on
-- cn_tourney_win: "THE CUP. The champion only"). Two changes, matching the
-- two asks one-for-one.

-- ---------------------------------------------------------------------------
-- 1. admin_update_profile(): one more optional field. A plain create-or-
--    replace does NOT do this -- Postgres resolves function identity by
--    (name, input argument TYPES), so appending p_tournaments would create a
--    second, 10-arg overload sitting next to the original 9-arg one rather
--    than actually replacing it. Same situation 0083 hit going the other
--    direction (dropping a param) and fixed the same way: drop the old
--    signature explicitly first.
-- ---------------------------------------------------------------------------
drop function if exists public.admin_update_profile(
  uuid, text, text, boolean, integer, integer, integer, integer, text[]
);

create or replace function public.admin_update_profile(
  p_user uuid, p_username text default null, p_avatar text default null,
  p_avatar_clear boolean default false,
  p_wins integer default null, p_losses integer default null,
  p_games integer default null, p_streak integer default null,
  p_achievements text[] default null,
  p_tournaments integer default null
)
returns profiles
language plpgsql security definer set search_path = public as $$
declare v_name text; v_ach text[]; v_out public.profiles;
begin
  if not cn_is_super_admin() then raise exception 'admin only'; end if;
  if p_user is null then raise exception 'no account given'; end if;

  if p_username is not null then
    v_name := btrim(p_username);
    if char_length(v_name) < 2 or char_length(v_name) > 20 then
      raise exception 'a name is between 2 and 20 characters';
    end if;
    if v_name !~ '^[A-Za-z0-9 _.-]+$' then
      raise exception 'letters, numbers, spaces, dots, dashes and underscores only';
    end if;
    begin
      update public.profiles set username = v_name where id = p_user;
    exception when unique_violation then
      raise exception 'that name is taken';
    end;
  end if;

  if p_avatar_clear then
    update public.profiles set avatar = null where id = p_user;
  elsif p_avatar is not null then
    if not exists (select 1 from public.cards where is_active and slug = p_avatar) then
      raise exception 'no such card';
    end if;
    update public.profiles set avatar = p_avatar where id = p_user;
  end if;

  -- Stats are typed for a reason a player never sees, and an admin can fat-
  -- finger a minus sign as easily as anybody -- clamped to zero rather than
  -- refused, same spirit as cn_clean_settings repairing a wild value instead
  -- of losing the whole patch over it.
  if p_wins is not null then update public.profiles set wins = greatest(0, p_wins) where id = p_user; end if;
  if p_losses is not null then update public.profiles set losses = greatest(0, p_losses) where id = p_user; end if;
  if p_games is not null then update public.profiles set games = greatest(0, p_games) where id = p_user; end if;
  if p_streak is not null then update public.profiles set streak = p_streak where id = p_user; end if;
  -- Jared: "I should be able to edit the 'won cups' number in that page."
  if p_tournaments is not null then
    update public.profiles set tournaments = greatest(0, p_tournaments) where id = p_user;
  end if;

  if p_achievements is not null then
    -- Trimmed, emptied of blanks, capped at twenty badges of forty characters
    -- each -- an achievements column is not the place for a paragraph, and a
    -- cap here is cheaper than a screen that has to scroll sideways for it.
    select array_agg(left(btrim(x), 40)) into v_ach
      from unnest(p_achievements) x
     where btrim(x) <> '';
    v_ach := coalesce(v_ach, '{}');
    if array_length(v_ach, 1) > 20 then
      raise exception 'twenty achievements at most';
    end if;
    update public.profiles set achievements = v_ach where id = p_user;
  end if;

  select * into v_out from public.profiles where id = p_user;
  if v_out.id is null then raise exception 'no such account'; end if;
  return v_out;
end $$;

-- ---------------------------------------------------------------------------
-- 2. cn_tourney_win(): the cup itself now checks its own attendance sheet.
--    A bracket of two that only ever had two people sign up is a real
--    tournament by every rule this system enforces -- but Jared doesn't want
--    it minting a cup. Four is the number he gave; below it, the final still
--    plays out and still crowns a winner (winner_id/winner_name, the "takes
--    the cup" copy, all of it -- nothing about the match or the bracket
--    changes), it just doesn't touch profiles.tournaments. The entrant count
--    comes from tournament_entries, not `size`/`rounds` -- those describe the
--    bracket's shape (padded to a power of two with byes), not how many
--    people actually showed up, which is the thing being asked about here.
--    tournament_entries rows are never deleted once a tournament is running
--    (tournament_leave only sets out_at on a forfeit; the delete branch is
--    open-status-only), so this count is stable by the time a final finishes.
-- ---------------------------------------------------------------------------
create or replace function public.cn_tourney_win(p_tm uuid, p_win uuid, p_name text)
returns void language plpgsql security definer set search_path = public as $$
declare
  tm public.tournament_matches; t public.tournaments;
  v_parent public.tournament_matches; v_slot int; v_entrants int;
begin
  select * into tm from public.tournament_matches where id = p_tm for update;
  if tm.id is null or tm.winner_id is not null then return; end if;  -- never twice
  if p_win is null then return; end if;

  update public.tournament_matches
     set winner_id = p_win, winner_name = p_name where id = p_tm;

  select * into t from public.tournaments where id = tm.tournament_id;

  -- The final. `round = rounds` rather than a flag, so a bracket of two and a
  -- bracket of thirty-two end in exactly the same line of code.
  if tm.round >= t.rounds then
    update public.tournaments
       set status = 'finished', finished_at = now(),
           winner_id = p_win, winner_name = p_name
     where id = t.id and status = 'running';
    -- THE CUP. The champion only -- and now the champion of a bracket that
    -- actually had four or more people in it. Fewer than that still ends in
    -- a winner, just not a cup: "so like a just-for-fun tournament then, no
    -- rewards" (Jared's own words for it).
    select count(*) into v_entrants from public.tournament_entries where tournament_id = t.id;
    if v_entrants >= 4 then
      update public.profiles set tournaments = tournaments + 1 where id = p_win;
    end if;
    return;
  end if;

  -- Upwards. Slot s of round r feeds slot s/2 of round r+1, on the left if s
  -- is even -- which is the same arithmetic the client draws the lines with.
  v_slot := tm.slot / 2;
  if tm.slot % 2 = 0 then
    update public.tournament_matches set a_id = p_win, a_name = p_name
     where tournament_id = t.id and round = tm.round + 1 and slot = v_slot;
  else
    update public.tournament_matches set b_id = p_win, b_name = p_name
     where tournament_id = t.id and round = tm.round + 1 and slot = v_slot;
  end if;

  select * into v_parent from public.tournament_matches
   where tournament_id = t.id and round = tm.round + 1 and slot = v_slot;
  if v_parent.a_id is not null and v_parent.b_id is not null then
    perform cn_tourney_spawn(v_parent.id);
  end if;
end $$;
