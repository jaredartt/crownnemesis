-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice -- it only adds a column (if not exists) and
--  replaces two function bodies.
-- ===========================================================================
--  0097 -- rematches now count for rating, just for less each time, instead
--  of never counting at all.
--
--  0009's own comment on request_rematch put it plainly: "A rematch is
--  never ranked, whoever you are playing. You picked this opponent, and two
--  people who like each other could otherwise trade wins all afternoon."
--  Jared, now: "in Smash Ultimate and chess.com you can rematch for RP (or
--  elo), then we should have something similar. So let's make it so that
--  each match you rematch, the winner and the loser wins or loses half of
--  the points each time they rematch (with a minimum of 1 point won/lost),
--  and from the fourth rematch, no points will be won or lost." Same
--  anti-farming instinct as 0009 (nobody should be able to trade wins for
--  free RP all afternoon), just a decaying allowance instead of a flat ban.
--
--  New column: rematch_depth, 0 for an ordinary match, N for the Nth
--  rematch in a chain (walked forward from the match being rematched --
--  request_rematch already has that row in hand, so no backward walk over
--  next_match_id is needed). finish_match reads it straight off the match
--  row and halves the usual Elo swing once per depth, floored at 1 point
--  either way; request_rematch stops marking a chain `ranked` at all past
--  the third rematch, which is what makes the fourth (and every one after
--  it) worth nothing -- finish_match's decay math never even runs for
--  those, same as any other unranked match today.
-- ---------------------------------------------------------------------------

alter table public.matches
  add column if not exists rematch_depth int not null default 0;

-- ---------------------------------------------------------------------------
-- request_rematch -- now carries rematch_depth forward and decides ranked-
-- ness from it, instead of hardcoding ranked = false. A chain that was
-- never ranked to begin with (a friend room, a practice match) stays
-- unranked through every rematch, exactly as before.
-- ---------------------------------------------------------------------------
create or replace function public.request_rematch(p_match uuid)
returns uuid language plpgsql security definer set search_path = public as $$
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
    select id into v_new from public.create_bot_match(m.bot);
    update public.matches set next_match_id = v_new where id = p_match;
    return v_new;
  end if;

  if v_side = 'host'
    then update public.matches set rematch_host  = true, rematch_declined = false where id = p_match;
    else update public.matches set rematch_guest = true, rematch_declined = false where id = p_match;
  end if;

  select * into m from public.matches where id = p_match;
  if not (m.rematch_host and m.rematch_guest) then return null; end if;

  -- Depth 1 for the first rematch of an ordinary match (rematch_depth = 0),
  -- 2 for a rematch of THAT, and so on. Ranked only through the third --
  -- see finish_match for what each depth is actually worth.
  v_depth := coalesce(m.rematch_depth, 0) + 1;
  v_ranked := m.ranked and v_depth <= 3;

  -- Sides swap, so nobody keeps the first-move advantage two games running.
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
end $$;

-- ---------------------------------------------------------------------------
-- finish_match -- unchanged for an ordinary match (rematch_depth = 0: same
-- round(w_rating + k_w*(1-e_w)) result as before, just computed as
-- w_rating + round(k_w*(1-e_w)) instead -- adding an integer never changes
-- which side of .5 a fraction rounds to, so this is not a behaviour
-- change). For rematch_depth > 0, halves the usual swing once per depth
-- and floors the magnitude at 1 point on each side independently (a
-- placement-K player and an established-K player can still end up with
-- different floors, same as they can with different swings today).
-- ---------------------------------------------------------------------------
create or replace function public.finish_match(p_match uuid, p_winner text, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  m public.matches;
  w_id uuid; l_id uuid; w_name text; l_name text;
  w_rating int; l_rating int; w_g int; l_g int;
  e_w numeric; k_w int; k_l int;
  w_rating_new int; l_rating_new int;
  v_decay numeric; w_delta int; l_delta int;
begin
  select * into m from public.matches where id = p_match;
  if m.id is null then return; end if;
  if m.status = 'finished' then return; end if;

  if m.guest_id is null then
    if m.ranked and m.bot is not null then
      perform finish_ranked_bot_match(m, p_winner, p_reason);
    end if;
    return;
  end if;

  if p_winner = 'host' then
    w_id := m.host_id;  l_id := m.guest_id; w_name := m.host_name;  l_name := m.guest_name;
  else
    w_id := m.guest_id; l_id := m.host_id;  w_name := m.guest_name; l_name := m.host_name;
  end if;
  if w_id = l_id then return; end if;

  insert into public.player_rating (user_id) values (w_id) on conflict (user_id) do nothing;
  insert into public.player_rating (user_id) values (l_id) on conflict (user_id) do nothing;
  select rating, games into w_rating, w_g from public.player_rating where user_id = w_id;
  select rating, games into l_rating, l_g from public.player_rating where user_id = l_id;

  e_w := expected_score(w_rating, l_rating);
  k_w := cn_elo_k(w_g);
  k_l := cn_elo_k(l_g);

  -- Jared: "each match you rematch, the winner and the loser wins or
  -- loses half of the points each time they rematch (with a minimum of 1
  -- point won/lost), and from the fourth rematch, no points will be won
  -- or lost." v_decay is 1 at depth 0 (an ordinary match -- unchanged),
  -- 0.5/0.25/0.125 at depth 1/2/3. Depth 4+ never reaches this function at
  -- all: request_rematch stops marking that chain `ranked`, so every call
  -- site's own `if m.ranked or ...` guard already skips finish_match
  -- entirely, same as any other unranked match.
  v_decay := power(0.5::numeric, m.rematch_depth);
  if m.rematch_depth > 0 then
    w_delta := greatest(1, round(k_w * (1 - e_w) * v_decay));
    l_delta := greatest(1, round(k_l * (1 - e_w) * v_decay));
  else
    w_delta := round(k_w * (1 - e_w));
    l_delta := round(k_l * (1 - e_w));
  end if;

  w_rating_new := w_rating + w_delta;
  l_rating_new := l_rating - l_delta;

  update public.player_rating
     set rating = w_rating_new, games = games + 1, updated_at = now()
   where user_id = w_id;
  update public.player_rating
     set rating = l_rating_new, games = games + 1, updated_at = now()
   where user_id = l_id;

  update public.profiles
     set wins = wins + 1, ranked_wins = ranked_wins + 1, games = games + 1,
         streak = case when streak >= 0 then streak + 1 else 1 end
   where id = w_id;

  update public.profiles
     set losses = losses + 1, games = games + 1,
         streak = case when streak <= 0 then streak - 1 else -1 end
   where id = l_id;

  insert into public.match_results
    (code, season, winner_id, loser_id, winner_name, loser_name,
     winner_lp, loser_lp,
     winner_rating_before, winner_rating_after, loser_rating_before, loser_rating_after,
     reason)
  values
    (m.code, current_season(), w_id, l_id, w_name, l_name,
     w_rating_new - w_rating, l_rating_new - l_rating,
     w_rating, w_rating_new, l_rating, l_rating_new,
     p_reason);

  perform cn_check_achievements(w_id);
end $$;
