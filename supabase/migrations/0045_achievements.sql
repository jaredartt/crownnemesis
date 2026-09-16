-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE, so no "Potential issue detected" dialog.
--  The last statement prints a row of checks; every column must say true.
-- ===========================================================================
--  0045 -- achievements
--
--  Four kinds of counter (bot wins, ranked wins, crits landed, parries
--  landed), each with the same seven tiers, plus four one-off "single-class
--  team" achievements that fire once when a side wins with exactly four
--  surviving non-royal units of one class. The catalog itself -- names,
--  icons, thresholds -- is a fixed TS constant, not a table: there is a
--  small, closed set of achievement KINDS and no admin screen has ever asked
--  to rename one. What the database owns is UNLOCK STATE, which is real,
--  per-player, and grows without a deploy.
--
--  ONE DECISION WORTH FLAGGING: `wins` on profiles has meant "ranked wins"
--  since 0004 -- finish_match is the only place that increments it, and
--  finish_match is only ever called on a ranked result. Renaming what `wins`
--  MEANS would be free in SQL and expensive everywhere else that already
--  reads it (the leaderboard view, admin_update_profile, the ladder screen).
--  So `wins` keeps doing exactly what it always did, and a NEW column,
--  `ranked_wins`, is backfilled from it and incremented alongside it from
--  here on -- purely as this migration's own counter to check achievement
--  tiers against. Two columns telling the same story is a smaller risk on a
--  live database with an active match in it than touching every reader of
--  the old one.
--
--  THE RISKIEST EDIT IN THIS FILE is the splice into cn_attack, which is
--  526 lines of extremely order-sensitive combat resolution. The rule this
--  project learned the hard way: fetch the live body with
--  pg_get_functiondef, paste it back verbatim, and change nothing above the
--  one block this migration adds. That block sits in exactly one place --
--  right after v_win is decided, before the `if v_win is not null` branch
--  that was already there -- so it runs whether or not this exchange ended
--  the match, which is what crits and parries need, and it runs exactly
--  once, which is what a single-class check and a bot-win credit need.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. new counters on profiles
--
-- All four are `security definer`-written only: nothing here grants a client
-- an UPDATE on profiles.crit_count and never has, RLS on this table has never
-- opened writes wider than that. `ranked_wins` is backfilled only while it is
-- still at its default of zero, so running this twice does not stomp a value
-- finish_match has since moved on from zero for a brand new player who
-- genuinely has zero.
-- ---------------------------------------------------------------------------
alter table public.profiles add column if not exists bot_wins    int not null default 0 check (bot_wins >= 0);
alter table public.profiles add column if not exists ranked_wins int not null default 0 check (ranked_wins >= 0);
alter table public.profiles add column if not exists crit_count  int not null default 0 check (crit_count >= 0);
alter table public.profiles add column if not exists parry_count int not null default 0 check (parry_count >= 0);

update public.profiles set ranked_wins = wins where ranked_wins = 0 and wins > 0;

-- Up to three, shown on the VS intro screen and the profile card. The check
-- is the belt to set_featured_achievements()'s own length guard below -- a
-- direct write from a service role or a future migration is held to the same
-- rule as the RPC is.
alter table public.profiles add column if not exists featured_achievements text[] not null default '{}';
alter table public.profiles drop constraint if exists profiles_featured_achievements_check;
alter table public.profiles add constraint profiles_featured_achievements_check
  check (array_length(featured_achievements, 1) is null or array_length(featured_achievements, 1) <= 3);

-- ---------------------------------------------------------------------------
-- 2. unlock state
--
-- `achievement_id` is not a foreign key into anything -- the catalog lives in
-- the client, on purpose (see the header) -- so this table is honest about
-- what it actually promises: this user unlocked a string, at this time. The
-- primary key is what makes every insert below idempotent; "have they already
-- got this" is never asked as a separate SELECT.
--
-- Readable by anyone signed in, the same as profiles.wins or profiles.lp --
-- an achievement is meant to be seen on someone else's card in the VS intro
-- screen, not only on your own. No insert/update/delete policy at all: every
-- write happens inside a `security definer` function, which runs as the
-- table owner and is not subject to RLS in the first place. What matters is
-- that nothing here is GRANTed to a client role, which the revokes below say
-- explicitly rather than leaving to Supabase's table-privilege default.
-- ---------------------------------------------------------------------------
create table if not exists public.player_achievements (
  user_id        uuid not null references public.profiles(id) on delete cascade,
  achievement_id text not null,
  unlocked_at    timestamptz not null default now(),
  primary key (user_id, achievement_id)
);

alter table public.player_achievements enable row level security;
drop policy if exists "achievements readable" on public.player_achievements;
create policy "achievements readable" on public.player_achievements
  for select to authenticated using (true);

grant select on public.player_achievements to authenticated;
revoke insert, update, delete on public.player_achievements from authenticated;

-- ---------------------------------------------------------------------------
-- 3. the unlock check
--
-- Cheap and idempotent by design: it re-reads the four counters and inserts
-- whatever tier they now clear that is not already unlocked, ON CONFLICT DO
-- NOTHING rather than a SELECT-then-INSERT. Called after every counter that
-- can move -- finish_match, cn_finish, cn_attack -- rather than trusted to
-- run once at exactly the right moment, so a counter that jumped by more than
-- one tier in a single call (a jump nothing here actually produces, but
-- nothing should have to assume it never will) still unlocks every tier it
-- passed through.
--
-- Internal: revoked from clients at the bottom of this file, same as
-- finish_match always has been.
-- ---------------------------------------------------------------------------
create or replace function public.cn_check_achievements(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  p public.profiles;
  v_tier int;
  v_tiers int[] := array[1, 10, 20, 100, 200, 500, 1000];
begin
  if p_user is null then return; end if;
  select * into p from public.profiles where id = p_user;
  if p.id is null then return; end if;

  foreach v_tier in array v_tiers loop
    if p.bot_wins >= v_tier then
      insert into public.player_achievements (user_id, achievement_id)
        values (p_user, 'bot_wins_' || v_tier) on conflict do nothing;
    end if;
    if p.ranked_wins >= v_tier then
      insert into public.player_achievements (user_id, achievement_id)
        values (p_user, 'ranked_wins_' || v_tier) on conflict do nothing;
    end if;
    if p.crit_count >= v_tier then
      insert into public.player_achievements (user_id, achievement_id)
        values (p_user, 'crits_' || v_tier) on conflict do nothing;
    end if;
    if p.parry_count >= v_tier then
      insert into public.player_achievements (user_id, achievement_id)
        values (p_user, 'parries_' || v_tier) on conflict do nothing;
    end if;
  end loop;
end $$;
revoke execute on function public.cn_check_achievements(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. featuring up to three
--
-- Own row only -- there is no p_user argument, on purpose, the same reason
-- set_avatar and set_username take none. "Can't feature something you
-- haven't unlocked" is checked against player_achievements rather than
-- trusted from the client, because the achievements grid is exactly the kind
-- of screen where a stale local list and a slow network make it easy to send
-- an id that used to be true.
-- ---------------------------------------------------------------------------
create or replace function public.set_featured_achievements(p_ids text[])
returns void language plpgsql security definer set search_path = public as $$
declare v_ids text[]; v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_ids := coalesce(p_ids, '{}');
  if array_length(v_ids, 1) > 3 then raise exception 'three featured achievements at most'; end if;

  if exists (
       select 1 from unnest(v_ids) x
        where not exists (
          select 1 from public.player_achievements pa
           where pa.user_id = v_uid and pa.achievement_id = x)) then
    raise exception 'you can only feature an achievement you have unlocked';
  end if;

  update public.profiles set featured_achievements = v_ids where id = v_uid;
end $$;
grant execute on function public.set_featured_achievements(text[]) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. finish_match -- spliced. Everything above the two new lines below is
-- pasted verbatim from `select pg_get_functiondef(oid) from pg_proc where
-- proname='finish_match'`, run against production immediately before writing
-- this file.
-- ---------------------------------------------------------------------------
create or replace function public.finish_match(p_match uuid, p_winner text, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  m public.matches;
  w_id uuid; l_id uuid; w_name text; l_name text;
  w_mmr int; l_mmr int; w_g int; l_g int;
  e_w numeric; swing int;
  w_lp int; l_lp int; w_floor int; l_floor int;
  w_lp_new int; l_lp_new int;
begin
  select * into m from public.matches where id = p_match;
  if m.id is null or m.guest_id is null then return; end if;
  if m.status = 'finished' then return; end if;   -- never rate a match twice

  if p_winner = 'host' then
    w_id := m.host_id;  l_id := m.guest_id; w_name := m.host_name;  l_name := m.guest_name;
  else
    w_id := m.guest_id; l_id := m.host_id;  w_name := m.guest_name; l_name := m.host_name;
  end if;
  if w_id = l_id then return; end if;

  insert into public.player_rating (user_id) values (w_id) on conflict (user_id) do nothing;
  insert into public.player_rating (user_id) values (l_id) on conflict (user_id) do nothing;
  select mmr, games into w_mmr, w_g from public.player_rating where user_id = w_id;
  select mmr, games into l_mmr, l_g from public.player_rating where user_id = l_id;

  e_w := expected_score(w_mmr, l_mmr);

  -- Hidden rating. K is larger while a player is still being placed, so a
  -- misjudged newcomer converges in a handful of games instead of fifty.
  update public.player_rating
     set mmr = round(w_mmr + (case when w_g < 10 then 40 else 20 end) * (1 - e_w)),
         games = games + 1, updated_at = now()
   where user_id = w_id;
  update public.player_rating
     set mmr = round(l_mmr - (case when l_g < 10 then 40 else 20 end) * (1 - e_w)),
         games = games + 1, updated_at = now()
   where user_id = l_id;

  -- Visible ladder. One number, applied to both, so LP is zero-sum before
  -- floors: 28 points scaled by how surprising the result was, clamped so no
  -- single game is meaningless or catastrophic.
  swing := greatest(4, least(40, round(28 * (1 - e_w))::int));

  select lp, floor_lp into w_lp, w_floor from public.profiles where id = w_id;
  select lp, floor_lp into l_lp, l_floor from public.profiles where id = l_id;

  w_lp_new := w_lp + swing;
  l_lp_new := greatest(l_floor, greatest(0, l_lp - swing));   -- the tier floor

  update public.profiles
     set lp = w_lp_new,
         floor_lp = greatest(w_floor, tier_floor(w_lp_new)),
         wins = wins + 1, ranked_wins = ranked_wins + 1, games = games + 1,
         streak = case when streak >= 0 then streak + 1 else 1 end
   where id = w_id;

  update public.profiles
     set lp = l_lp_new,
         losses = losses + 1, games = games + 1,
         streak = case when streak <= 0 then streak - 1 else -1 end
   where id = l_id;

  insert into public.match_results
    (code, season, winner_id, loser_id, winner_name, loser_name,
     winner_lp, loser_lp, reason)
  values
    (m.code, current_season(), w_id, l_id, w_name, l_name,
     swing, l_lp_new - l_lp, p_reason);

  -- 0045: a ranked win feeds the achievement catalog the same instant it
  -- feeds the ladder, so a milestone never lags the stat that earned it.
  perform cn_check_achievements(w_id);
end $$;

-- ---------------------------------------------------------------------------
-- 6. cn_finish -- spliced. Pasted verbatim from `select pg_get_functiondef
-- (oid) from pg_proc where proname='cn_finish'`, run immediately before
-- writing this file. This is the ending cn_move and cn_throw funnel through
-- for a trample-kill or a trap death; cn_attack (below) has its own inline
-- copy of the same ending for an ordinary combat kill, which is why the same
-- bot-win credit appears in both places rather than once here.
-- ---------------------------------------------------------------------------
create or replace function public.cn_finish(m matches, p_st jsonb, p_win text)
returns matches language plpgsql security definer set search_path = public as $$
declare v public.matches; v_bot_uid uuid;
begin
  if m.ranked then perform finish_match(m.id, p_win, 'defeat'); end if;

  -- 0045: a bot match has no rank on the line, but a win over the bot still
  -- counts toward the bot-wins tiers. The bot is always the guest -- bot_step
  -- never plays anything else -- so a human win here is always p_win='host',
  -- and the human is always m.host_id.
  if m.bot is not null and p_win = 'host' and m.host_id is not null then
    v_bot_uid := m.host_id;
    update public.profiles set bot_wins = bot_wins + 1 where id = v_bot_uid;
    perform cn_check_achievements(v_bot_uid);
  end if;

  p_st := jsonb_set(p_st, '{winner}', to_jsonb(p_win));
  p_st := state_log(p_st,
    case when p_win = 'host' then m.host_name else m.guest_name end || ' wins.');
  update public.matches
     set state = p_st, status = 'finished', winner = p_win,
         turn_deadline = null, updated_at = now()
   where id = m.id returning * into v;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- 7. cn_attack -- spliced. Everything in this function is pasted verbatim
-- from `select pg_get_functiondef(oid) from pg_proc where proname='cn_attack'`,
-- run immediately before writing this file, with two changes and nothing
-- else:
--
--   a) four new local variables, appended to the end of the existing declare
--      block (v_elem, v_by, v_by_owner, v_by_uid, v_win_uid, v_win_count,
--      v_win_roles) -- nothing already declared is touched.
--
--   b) one new block, inserted between the existing
--      `elsif v_mine = 0 then v_win := v_other; end if;` and the existing
--      `if v_win is not null then` that follows it. Not one line of the
--      526-line body above that point, or of the two branches below it, is
--      changed.
--
-- The new block does three things, in order:
--   - walks v_swings once and counts every crit and every parry against the
--     profile that owns the unit that swung or caught it. This runs whether
--     or not v_win ended up set, because a match-ending crit is still a crit.
--   - if v_win is set: checks the winning side's surviving non-royal units in
--     v_out for a single-class team (exactly four, one role, none of them
--     royal) and unlocks the matching one-off achievement, idempotently.
--   - if v_win is set and this is a bot match: credits the human's bot-wins
--     counter, mirroring cn_finish's own copy of the same rule above.
-- ---------------------------------------------------------------------------
create or replace function public.cn_attack(p_match uuid, p_side text, p_unit text, p_target text)
returns matches
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  m public.matches; v_other text; v_st jsonb; u jsonb; e jsonb;
  v_atk jsonb; v_tgt jsonb; v_tree jsonb;
  v_out jsonb := '[]'::jsonb; v_rocks jsonb := '[]'::jsonb;
  v_dist int; v_dmg int := 0; v_heal int := 0;
  v_tgt_hp int; v_atk_hp int; v_counter int := 0; v_riposte int := 0;
  v_burn_atk int := 0; v_burn_tgt int := 0; v_new_burn boolean := false;
  v_cured boolean := false;
  v_answers boolean := false; v_parry boolean := false;
  v_reaches_back boolean := false; v_tgt_reaches boolean := false;
  v_hit_crit boolean := false;
  v_crit boolean := false; v_crit_counter boolean := false;
  v_chain int := 0; v_parries int := 0;
  v_swing_is_atk boolean := true; v_is_counter boolean := false;
  v_strk jsonb; v_recv jsonb; v_hit int; v_parried boolean;
  v_notes text[] := '{}';
  v_swings jsonb := '[]'::jsonb;
  v_bloom jsonb := '[]'::jsonb; v_d2 int; v_got int; v_heal_roll int := 0;
  v_killed_tgt boolean := false; v_killed_atk boolean := false;
  v_ally boolean := false; v_foes int := 0; v_mine int := 0; v_win text;
  v_crown text; v_note text;
  -- F3: a blow the mist ate, and Himanta's second swing.
  v_missed boolean := false; v_hit2 int; v_crit2 boolean;
  -- F2: what a burn costs the one swinging, and what a blow leaves behind.
  v_cost int; v_steal int;
  -- 0045: crit/parry counters, single-class team check, and bot-win credit.
  v_elem jsonb; v_by text; v_by_owner text; v_by_uid uuid;
  v_win_uid uuid; v_win_count int; v_win_roles text[];
begin
  select * into m from public.matches where id = p_match for update;
  v_other := case when p_side = 'host' then 'guest' else 'host' end;
  v_st := m.state;

  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit   then v_atk := u; end if;
    if u->>'id' = p_target then v_tgt := u; end if;
  end loop;
  for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
    if e->>'id' = p_target then v_tree := e; end if;
  end loop;

  -- THE SWAMP, applied once, here. v_strk and v_recv are assigned from these
  -- two further down, so every rule in the exchange -- the parry, the second
  -- strike, the cyclone, the lifesteal, the bonus against poison -- reads a
  -- silenced fighter without any of them being told about silence.
  v_atk := cn_awake(v_st, v_atk);
  v_tgt := cn_awake(v_st, v_tgt);

  if v_atk is null then raise exception 'no such unit'; end if;
  if v_tgt is null and v_tree is null then raise exception 'no such target'; end if;
  if v_atk->>'owner' <> p_side then raise exception 'that is not your unit'; end if;
  if (v_atk->>'acted')::boolean then raise exception 'that unit already acted'; end if;
  -- A cyclone knocks the sword out of your hand, not your feet out from
  -- under you: a stunned unit may still walk, and nothing here stops it.
  if cn_stunned(v_atk) then raise exception 'that unit is stunned'; end if;

  -- Striking spends an action whether or not this unit moved first. If it
  -- moved, it is already the active unit and this costs nothing further.
  v_st := cn_begin_act(v_st, p_side, p_unit);

  if v_tree is not null then
    v_dist := cn_cheb((v_atk->>'x')::int, (v_atk->>'y')::int,
                      (v_tree->>'x')::int, (v_tree->>'y')::int);
  else
    -- FRIENDLY FIRE IS ALLOWED. The refusal that used to be here was total
    -- in practice -- since 0033 no card carries `heals` -- so "you may only
    -- point this at an ally if you mend" meant "you may never point this at
    -- an ally". Jared's rule is that you may.
    v_ally := (v_tgt->>'owner' = p_side);
    v_dist := cn_cheb((v_atk->>'x')::int, (v_atk->>'y')::int,
                      (v_tgt->>'x')::int, (v_tgt->>'y')::int);
  end if;

  if v_dist < (v_atk->>'rmin')::int then raise exception 'too close for that unit'; end if;
  if v_dist > (v_atk->>'rmax')::int then raise exception 'out of range'; end if;
  if not cn_los_clear(v_st, (v_atk->>'x')::int, (v_atk->>'y')::int,
                      coalesce((v_tgt->>'x')::int, (v_tree->>'x')::int),
                      coalesce((v_tgt->>'y')::int, (v_tree->>'y')::int)) then
    raise exception 'a tree is in the way';
  end if;

  v_atk_hp := (v_atk->>'hp')::int;

  -- A MEND is what happens when a healer points at an ally. A healer is the
  -- only thing this branch has ever been for, and since 0033 there is not one
  -- on the roster -- so this is kept, unreachable, rather than deleted: it is
  -- the whole of how mending works and the day a card carries `heals` again it
  -- has to work the same way it always did.
  if v_ally and coalesce((v_atk->>'heals')::boolean, false) then
    -- Mending is not an exchange: no crit, no parry, no answer.
    v_heal_roll := cn_roll((v_atk->>'dmin')::int, (v_atk->>'dmax')::int);
    v_heal := v_heal_roll;
    v_tgt_hp := least((v_tgt->>'maxHp')::int, (v_tgt->>'hp')::int + v_heal);
    v_heal := v_tgt_hp - (v_tgt->>'hp')::int;
    v_cured := coalesce((v_atk->>'cures')::boolean, false)
               and cn_has(v_tgt, 'burn');
    if v_cured then v_tgt := cn_afflict(v_tgt, 'burn', 'false'::jsonb); end if;
    v_note := (v_atk->>'name') || ' mends ' || (v_tgt->>'name') || ' for ' || v_heal || '.';
    v_swings := v_swings || jsonb_build_object(
      'k', 'heal', 'by', p_unit, 'at', p_target, 'dmg', v_heal,
      'crit', false, 'counter', false, 'first', false, 'def', false,
      'why', 'mend');

    -- A flower does not choose who it grows for. One roll, spent on everyone
    -- standing in reach, so the answer to Sinie is to keep your line apart --
    -- which is the opposite of what every other unit wants of you.
    if coalesce((v_atk->>'blooms')::boolean, false) then
      for u in select * from jsonb_array_elements(v_st->'units') loop
        continue when u->>'id' = p_unit or u->>'id' = p_target;
        continue when u->>'owner' <> p_side;
        continue when (u->>'hp')::int >= (u->>'maxHp')::int;
        v_d2 := cn_cheb((v_atk->>'x')::int, (v_atk->>'y')::int,
                        (u->>'x')::int, (u->>'y')::int);
        continue when v_d2 < (v_atk->>'rmin')::int or v_d2 > (v_atk->>'rmax')::int;
        continue when not cn_los_clear(v_st, (v_atk->>'x')::int, (v_atk->>'y')::int,
                                       (u->>'x')::int, (u->>'y')::int);
        v_bloom := v_bloom || jsonb_build_array(u->>'id');
      end loop;
    end if;

  elsif v_tree is not null then
    -- A tree does not parry and does not answer, but a crit still fells it.
    v_crit := cn_chance((v_atk->>'critPct')::int, 'crit');
    v_dmg := cn_damage(cn_roll((v_atk->>'dmin')::int, (v_atk->>'dmax')::int), v_crit, false);
    v_tgt_hp := (v_tree->>'hp')::int - v_dmg;
    v_killed_tgt := v_tgt_hp <= 0;
    v_swings := v_swings || jsonb_build_object(
      'k', 'hit', 'by', p_unit, 'at', p_target, 'dmg', v_dmg,
      'crit', v_crit, 'counter', false, 'first', false, 'def', false,
      'why', 'tree');
    if v_killed_tgt then
      v_swings := v_swings || jsonb_build_object('k', 'down', 'by', p_target, 'at', p_target);
    end if;
    if cn_has(v_atk, 'burn') then
      v_burn_atk := cn_effect_dmg(v_st, v_atk, cn_burn_pct());
      v_atk_hp := v_atk_hp - v_burn_atk;
      v_swings := v_swings || jsonb_build_object(
        'k', 'burn', 'by', p_unit, 'at', p_unit, 'dmg', v_burn_atk);
    end if;
    v_killed_atk := v_atk_hp <= 0;
    -- Since 0035 the thing being struck may be a wall or a trap, and a log
    -- line that calls a summoned wall a tree is the kind of small lie that
    -- makes a player distrust the rest of the log.
    v_note := (v_atk->>'name') || ' strikes ' || cn_obj_name(cn_obj_kind(v_tree))
              || ' for ' || v_dmg
              || case when v_killed_tgt then ' -- destroyed.' else '.' end;

  else
    v_tgt_hp := (v_tgt->>'hp')::int;

    -- A thief that trades blows is not a thief -- and neither does your own
    -- soldier draw on you. A counter is what somebody does when an ENEMY
    -- attacks them; gating it here rather than at each of the three places
    -- that read v_answers is what also takes the Quick Dagger off, which
    -- would otherwise answer its own side before the blow it was answering.
    v_answers := not v_ally
                 and not coalesce((v_atk->>'sneaks')::boolean, false)
                 and v_dist >= (v_tgt->>'crmin')::int
                 and v_dist <= (v_tgt->>'crmax')::int;
    -- v_answers is the ORDINARY counter, and Quick Dagger spends it. Whether
    -- each side can physically reach the other is a separate, permanent fact,
    -- and it is the one a parry asks: a parrier answers only if the blow it
    -- caught came from somewhere it can reach.
    v_tgt_reaches  := v_answers;
    v_reaches_back := v_dist >= (v_atk->>'crmin')::int
                  and v_dist <= (v_atk->>'crmax')::int;

    -- Quick Dagger. The answer lands before the blow it is answering, and it
    -- is a passive, so nothing catches it. It spends the ordinary counter --
    -- you do not get to answer twice for one attack.
    if v_answers and coalesce((v_tgt->>'parries')::boolean, false) then
      v_crit_counter := not coalesce((v_atk->>'slippery')::boolean, false)
                        and cn_chance((v_tgt->>'critPct')::int, 'crit');
      v_counter := cn_damage(cn_roll((v_tgt->>'dmin')::int, (v_tgt->>'dmax')::int),
                             v_crit_counter, true,
                             cn_aura_bonus(v_st, v_tgt, v_atk),
                             cn_aura_resist(v_st, v_tgt, v_atk),
                             coalesce((v_atk->>'defending')::boolean, false));
      v_atk_hp := v_atk_hp - v_counter;
      if cn_has(v_tgt, 'burn') then
        v_burn_tgt := cn_effect_dmg(v_st, v_tgt, cn_burn_pct());
        v_tgt_hp := v_tgt_hp - v_burn_tgt;
      end if;
      v_killed_atk := v_atk_hp <= 0;
      v_killed_tgt := v_tgt_hp <= 0;
      v_parry   := true;          -- the clients draw this the same way
      v_answers := false;
      v_notes := v_notes || ((v_tgt->>'name') || ' answers first for ' || v_counter
                 || case when v_crit_counter then ' -- a critical hit.' else '.' end);
      -- 'first' is what tells the cinematic to play this BEFORE the lunge it
      -- is answering, which is the whole of Quick Dagger.
      v_swings := v_swings || jsonb_build_object(
        'k', 'hit', 'by', p_target, 'at', p_unit, 'dmg', v_counter,
        'crit', v_crit_counter, 'counter', true, 'first', true,
        'def', coalesce((v_atk->>'defending')::boolean, false),
        'why', 'quick');
    end if;

    -- The chain.
    while not v_killed_atk and not v_killed_tgt and v_chain < cn_parry_cap() loop
      v_chain := v_chain + 1;
      if v_swing_is_atk
        then v_strk := v_atk; v_recv := v_tgt;
        else v_strk := v_tgt; v_recv := v_atk;
      end if;

      -- Lium catches any answer-to-a-parry aimed at him. Everyone else rolls.
      -- Slippery. Nothing catches a blow of Himanta's -- not a roll, and not
      -- Lium, whose whole passive is catching answers. Checked on the
      -- SWINGER, because being hard to parry is a property of the one
      -- swinging and not of the one trying.
      -- AND YOUR OWN SIDE DOES NOT CATCH YOUR BLADE EITHER. A parry is not
      -- only a block: it flips the swing, so the parrier strikes back. An
      -- ally that parried would therefore answer, which is the rule two lines
      -- up read backwards. One `not v_ally` at the roll takes the whole chain
      -- off, and a friendly blow becomes the single beat it should be.
      v_parried := not v_ally
                   and not coalesce((v_strk->>'slippery')::boolean, false)
                   and ((v_is_counter and coalesce((v_recv->>'parryAll')::boolean, false))
                        or cn_chance((v_recv->>'parryPct')::int, 'parry'));

      if v_parried then
        v_parries := v_parries + 1;
        if v_chain = 1 then v_parry := true; end if;
        v_notes := v_notes || ((v_recv->>'name') || ' parries '
                   || (v_strk->>'name') || '.');
        -- 'why' says which rule caught it. Lium catching an answer is not the
        -- same event as a 5% roll coming up, and a caption that calls both of
        -- them "parries" is not narrating, it is labelling.
        v_swings := v_swings || jsonb_build_object(
          'k', 'parry', 'by', v_recv->>'id', 'at', v_strk->>'id',
          'why', case when v_is_counter
                       and coalesce((v_recv->>'parryAll')::boolean, false)
                      then 'all' else 'roll' end);
        -- A parry answers only if the parrier can reach what it caught.
        exit when not case when v_swing_is_atk then v_tgt_reaches
                                               else v_reaches_back end;
        v_swing_is_atk := not v_swing_is_atk;
        v_is_counter := true;
        continue;
      end if;

      -- The blow lands.
      -- ...and nothing crits ONE. Checked on the receiver, for the mirror
      -- reason: it is a property of the one being hit.
      v_hit_crit := not coalesce((v_recv->>'slippery')::boolean, false)
                    and cn_chance((v_strk->>'critPct')::int, 'crit');
      v_hit := cn_damage(cn_roll((v_strk->>'dmin')::int, (v_strk->>'dmax')::int),
                         v_hit_crit, v_is_counter,
                         cn_aura_bonus(v_st, v_strk, v_recv),
                         cn_aura_resist(v_st, v_strk, v_recv),
                         coalesce((v_recv->>'defending')::boolean, false));
      -- THE MIST. Eva's, and it is the receiver's side that has it: a Rogue
      -- standing in it has a chance to be somewhere else when the blow
      -- arrives. Rolled per blow rather than per exchange, so a chain of
      -- four swings is four chances -- which is what makes two turns of it
      -- worth an activation.
      -- THALGRIM. Flat, and added after every multiplier: "an extra 25
      -- damage" is a sentence about the number that lands, not about the
      -- roll that started it.
      if cn_has(v_recv, 'poison') then
        v_hit := v_hit + coalesce((v_strk->>'vsPoisoned')::int, 0);
      end if;
      v_missed := cn_mist_dodge(v_st, v_recv);
      if v_missed then v_hit := 0; v_hit_crit := false; end if;
      if v_swing_is_atk then
        v_tgt_hp := v_tgt_hp - v_hit;
        if v_is_counter then v_riposte := v_riposte + v_hit;
        else v_dmg := v_hit; v_crit := v_hit_crit; end if;
      else
        v_atk_hp := v_atk_hp - v_hit;
        v_counter := v_counter + v_hit;
        v_crit_counter := v_crit_counter or v_hit_crit;
      end if;
      v_swings := v_swings || jsonb_build_object(
        'k', 'hit', 'by', v_strk->>'id', 'at', v_recv->>'id', 'dmg', v_hit,
        'crit', v_hit_crit, 'counter', v_is_counter, 'first', false,
        'def', coalesce((v_recv->>'defending')::boolean, false),
        'why', case when v_missed then 'mist'
                    when v_is_counter then 'counter' else 'strike' end);

      -- STRIKE TWICE. Not only on the attack: Jared's rule is "a second hit
      -- when Himanta attacks, counters or parries", and all three are the
      -- same thing here -- a swing in the chain -- which is the whole reason
      -- the chain was made uniform in 0020. A missed blow does not double:
      -- there is nothing to do twice.
      if not v_missed and coalesce((v_strk->>'twicePct')::int, 0) > 0
         and cn_chance((v_strk->>'twicePct')::int, 'twice') then
        v_crit2 := not coalesce((v_recv->>'slippery')::boolean, false)
                   and cn_chance((v_strk->>'critPct')::int, 'crit');
        v_hit2 := cn_damage(cn_roll((v_strk->>'dmin')::int, (v_strk->>'dmax')::int),
                            v_crit2, v_is_counter,
                            cn_aura_bonus(v_st, v_strk, v_recv),
                            cn_aura_resist(v_st, v_strk, v_recv),
                            coalesce((v_recv->>'defending')::boolean, false));
        if cn_mist_dodge(v_st, v_recv) then v_hit2 := 0; v_crit2 := false; end if;
        if v_swing_is_atk then
          v_tgt_hp := v_tgt_hp - v_hit2;
          if v_is_counter then v_riposte := v_riposte + v_hit2;
          else v_dmg := v_dmg + v_hit2; end if;
        else
          v_atk_hp := v_atk_hp - v_hit2;
          v_counter := v_counter + v_hit2;
        end if;
        v_swings := v_swings || jsonb_build_object(
          'k', 'hit', 'by', v_strk->>'id', 'at', v_recv->>'id', 'dmg', v_hit2,
          'crit', v_crit2, 'counter', v_is_counter, 'first', false,
          'def', coalesce((v_recv->>'defending')::boolean, false),
          'why', 'twice');
        v_notes := v_notes || ((v_strk->>'name') || ' strikes again for ' || v_hit2 || '.');
      end if;
      if v_is_counter then
        v_notes := v_notes || ((v_strk->>'name') || ' answers for ' || v_hit
                   || case when v_hit_crit then ' -- a critical hit.' else '.' end);
      end if;

      -- ZEPHYRA. The cyclone lands with the blow, on anything it hit.
      if not v_missed and v_hit > 0
         and coalesce((v_strk->>'stuns')::boolean, false) then
        if v_swing_is_atk then v_tgt := cn_afflict(v_tgt, 'stun', '1'::jsonb);
                          else v_atk := cn_afflict(v_atk, 'stun', '1'::jsonb); end if;
        v_notes := v_notes || ((v_recv->>'name') || ' is caught in the cyclone.');
      end if;

      -- NYXARA. Heals for what it dealt, capped at its own maximum -- and
      -- for what LANDED rather than what was rolled, so a guard and a
      -- resistance take the healing down with the damage.
      v_steal := round(v_hit * coalesce((v_strk->>'lifestealPct')::int, 0) / 100.0)::int;
      if v_steal > 0 then
        if v_swing_is_atk
          then v_atk_hp := least((v_atk->>'maxHp')::int, v_atk_hp + v_steal);
          else v_tgt_hp := least((v_tgt->>'maxHp')::int, v_tgt_hp + v_steal);
        end if;
        v_swings := v_swings || jsonb_build_object(
          'k', 'heal', 'by', v_strk->>'id', 'at', v_strk->>'id', 'dmg', v_steal,
          'why', 'steal');
      end if;

      -- Swinging while alight costs you, whichever end of the exchange you
      -- are -- and since 0034 it costs 15% of your maximum rather than a
      -- flat 5, which is the spec's number and scales with the unit.
      if cn_has(v_strk, 'burn') then
        v_cost := cn_effect_dmg(v_st, v_strk, cn_burn_pct());
        if v_swing_is_atk
          then v_burn_atk := v_cost; v_atk_hp := v_atk_hp - v_cost;
          else v_burn_tgt := v_cost; v_tgt_hp := v_tgt_hp - v_cost;
        end if;
        v_swings := v_swings || jsonb_build_object(
          'k', 'burn', 'by', v_strk->>'id', 'at', v_strk->>'id', 'dmg', v_cost);
      end if;
      v_killed_atk := v_atk_hp <= 0;
      v_killed_tgt := v_tgt_hp <= 0;
      -- Recorded HERE rather than counted up at the end, because the order is
      -- the whole point of the list: a cinematic has to know whether somebody
      -- fell before or after the blow that follows.
      if v_killed_tgt then
        v_swings := v_swings || jsonb_build_object('k', 'down', 'by', p_target, 'at', p_target);
      end if;
      if v_killed_atk then
        v_swings := v_swings || jsonb_build_object('k', 'down', 'by', p_unit, 'at', p_unit);
      end if;
      exit when v_killed_atk or v_killed_tgt;

      -- A blow that lands draws the ordinary counter. A counter that lands
      -- ends it -- otherwise the two of them never stop.
      exit when v_is_counter;
      exit when not v_answers;
      v_swing_is_atk := false;
      v_is_counter := true;
    end loop;

    v_new_burn := (v_atk->>'burns')::boolean and not v_killed_tgt and v_dmg > 0;
    if v_new_burn then v_tgt := cn_afflict(v_tgt, 'burn', 'true'::jsonb); end if;

    if v_dmg = 0 then
      v_note := (v_atk->>'name') || ' lunges at ' || (v_tgt->>'name') || '.';
    else
      v_note := (v_atk->>'name') || ' hits ' || (v_tgt->>'name') || ' for ' || v_dmg
                || case when v_killed_tgt and v_burn_tgt = 0 then ' -- destroyed.' else '.' end;
    end if;
  end if;

  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then
      if not v_killed_atk then
        u := jsonb_set(u, '{acted}', 'true'::jsonb);
        u := jsonb_set(u, '{moved}', 'true'::jsonb);
        u := jsonb_set(u, '{spent}', 'true'::jsonb);
        u := jsonb_set(u, '{hp}', to_jsonb(v_atk_hp));
        -- The exchange afflicts the LOCAL copies -- a cyclone caught on the
        -- counter lands on v_atk, not on the row in the state -- so the whole
        -- effects object is carried back here. Setting one key at a time is
        -- how `burned` came to be written in two places and read in four.
        u := jsonb_set(u, '{effects}',
                       coalesce(v_atk->'effects', cn_no_effects()), true);
        v_out := v_out || u;
      end if;
    elsif v_tree is null and u->>'id' = p_target then
      -- ONE BRANCH, not two. There used to be an `if v_ally` here that kept
      -- the target on the board whatever its health, because the only way to
      -- point this function at an ally was to MEND it and nobody has ever
      -- been mended to death. Since 0038 an ally can be struck, and an ally
      -- struck to nothing was staying on the board at minus thirty hit
      -- points -- so the crown never fell and the match never ended.
      --
      -- The two branches were already identical apart from that: 0034 folded
      -- the cure and the new burn into v_tgt's own effects object, so there
      -- is nothing left for a mend to do differently.
      if not v_killed_tgt then
        u := jsonb_set(u, '{hp}', to_jsonb(v_tgt_hp));
        u := jsonb_set(u, '{effects}',
                       coalesce(v_tgt->'effects', cn_no_effects()), true);
        v_out := v_out || u;
      end if;
    elsif v_bloom @> jsonb_build_array(u->>'id') then
      v_got := least((u->>'maxHp')::int - (u->>'hp')::int, v_heal_roll);
      u := jsonb_set(u, '{hp}', to_jsonb((u->>'hp')::int + v_got));
      if coalesce((v_atk->>'cures')::boolean, false) then
        u := cn_afflict(u, 'burn', 'false'::jsonb);
      end if;
      v_out := v_out || u;
    else
      v_out := v_out || u;
    end if;
  end loop;

  for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
    if v_tree is not null and e->>'id' = p_target then
      if not v_killed_tgt then v_rocks := v_rocks || jsonb_set(e, '{hp}', to_jsonb(v_tgt_hp)); end if;
    else
      v_rocks := v_rocks || e;
    end if;
  end loop;

  v_st := jsonb_set(v_st, '{units}', v_out);
  v_st := jsonb_set(v_st, '{obstacles}', v_rocks);
  -- Set on the state rather than through cn_end_act: an attacker killed by
  -- the counter has already been dropped from v_out, so there is no row
  -- left to flag, and the activation still has to end.
  v_st := jsonb_set(v_st, '{active}', 'null'::jsonb);
  v_st := jsonb_set(v_st, '{fx}', jsonb_build_object(
    'seq', coalesce((v_st->'fx'->>'seq')::int, 0) + 1,
    'atk', p_unit, 'tgt', p_target,
    'dmg', v_dmg, 'heal', v_heal,
    'killedTgt', v_killed_tgt, 'counter', v_counter, 'killedAtk', v_killed_atk,
    'burnAtk', v_burn_atk, 'burnTgt', v_burn_tgt, 'newBurn', v_new_burn,
    'cured', v_cured, 'parry', v_parry, 'bloom', v_bloom,
    'crit', v_crit, 'critCounter', v_crit_counter,
    'parries', v_parries, 'chain', v_chain, 'riposte', v_riposte,
    'swings', v_swings,
    'tree', (v_tree is not null)));

  v_st := state_log(v_st, v_note);
  if jsonb_array_length(v_bloom) > 0 then
    v_st := state_log(v_st, 'The bloom spreads -- '
      || jsonb_array_length(v_bloom) || ' more mended.');
  end if;
  if v_cured then v_st := state_log(v_st, (v_tgt->>'name') || ' stops burning.'); end if;
  if v_new_burn then v_st := state_log(v_st, (v_tgt->>'name') || ' is burning.'); end if;
  foreach v_note in array v_notes loop
    v_st := state_log(v_st, v_note);
  end loop;
  if v_killed_atk and v_burn_atk = 0 and v_counter > 0 then
    v_st := state_log(v_st, (v_atk->>'name') || ' is destroyed.');
  end if;
  if v_burn_tgt > 0 then
    v_st := state_log(v_st, (v_tgt->>'name') || ' burns for ' || v_burn_tgt
      || case when v_killed_tgt then ' -- destroyed.' else '.' end);
  end if;
  if v_burn_atk > 0 then
    v_st := state_log(v_st, (v_atk->>'name') || ' burns for ' || v_burn_atk
      || case when v_killed_atk then ' -- destroyed.' else '.' end);
  end if;

  -- ---- who has won -------------------------------------------------------
  -- A crown that falls takes the kingdom with it. Checked before the count of
  -- bodies, because a king can die while four of his units are still standing
  -- and that is still over. The defender is checked first: the attack resolved,
  -- so if both crowns fell in the one exchange the one that was struck fell
  -- first.
  if v_tree is null and v_killed_tgt and coalesce((v_tgt->>'royal')::boolean, false) then
    v_crown := v_tgt->>'owner';
  elsif v_killed_atk and coalesce((v_atk->>'royal')::boolean, false) then
    v_crown := v_atk->>'owner';
  end if;

  for u in select * from jsonb_array_elements(v_out) loop
    if u->>'owner' = p_side then v_mine := v_mine + 1; else v_foes := v_foes + 1; end if;
  end loop;

  if v_crown is not null and not exists (
       select 1 from jsonb_array_elements(v_out) q
        where q->>'owner' = v_crown and (q->>'royal')::boolean) then
    v_win := case when v_crown = 'host' then 'guest' else 'host' end;
    v_st := state_log(v_st, 'The crown has fallen.');
  elsif v_foes = 0 then v_win := p_side;
  elsif v_mine = 0 then v_win := v_other;
  end if;

  -- ===== 0045: crit/parry counters, single-class team check, bot-win credit
  -- Crits and parries are counted here, once, whatever v_win turns out to be
  -- below -- a match-ending crit is still a crit. Every element of v_swings
  -- names its actor as 'by', an id that is always p_unit or p_target -- the
  -- only two units this function ever touches -- so the owner lookup is a
  -- straight comparison against the two local unit copies rather than a scan
  -- of the board.
  for v_elem in select * from jsonb_array_elements(v_swings) loop
    v_by := v_elem->>'by';
    if v_by is null then continue; end if;
    if v_by = p_unit then v_by_owner := p_side;
    elsif v_by = p_target then v_by_owner := coalesce(v_tgt->>'owner', v_other);
    else continue; end if;
    v_by_uid := case when v_by_owner = 'host' then m.host_id else m.guest_id end;
    if v_by_uid is null then continue; end if;  -- the bot has no profile row

    if coalesce((v_elem->>'crit')::boolean, false) then
      update public.profiles set crit_count = crit_count + 1 where id = v_by_uid;
      perform cn_check_achievements(v_by_uid);
    end if;
    if v_elem->>'k' = 'parry' then
      update public.profiles set parry_count = parry_count + 1 where id = v_by_uid;
      perform cn_check_achievements(v_by_uid);
    end if;
  end loop;

  if v_win is not null then
    v_win_uid := case when v_win = 'host' then m.host_id else m.guest_id end;

    -- A single-class team win: exactly four surviving non-royal units on the
    -- winning side, all one role among knight/rogue/mage/flying. Checked
    -- against v_out, the post-combat roster, and unlocked at most once ever
    -- per player -- the primary key on player_achievements is what makes
    -- that true, not a flag read beforehand.
    if v_win_uid is not null then
      select count(*), array_agg(distinct u->>'role') into v_win_count, v_win_roles
        from jsonb_array_elements(v_out) u
       where u->>'owner' = v_win and not coalesce((u->>'royal')::boolean, false);
      if v_win_count = 4 and array_length(v_win_roles, 1) = 1
         and v_win_roles[1] in ('knight', 'rogue', 'mage', 'flying') then
        insert into public.player_achievements (user_id, achievement_id)
          values (v_win_uid, 'single_class_' || v_win_roles[1])
          on conflict do nothing;
      end if;
    end if;

    -- A bot match has no rank on the line, but a win over the bot still
    -- counts toward the bot-wins tiers. The bot is always the guest
    -- (bot_step never plays anything else), so a human win here is always
    -- v_win = 'host'. Mirrors cn_finish's own copy of the same rule, for the
    -- ending that happens there instead of here.
    if m.bot is not null and v_win = 'host' and m.host_id is not null then
      update public.profiles set bot_wins = bot_wins + 1 where id = m.host_id;
    end if;

    if v_win_uid is not null then perform cn_check_achievements(v_win_uid); end if;
  end if;
  -- ===== end 0045 ===========================================================

  if v_win is not null then
    if m.ranked then perform finish_match(m.id, v_win, 'defeat'); end if;
    v_st := jsonb_set(v_st, '{winner}', to_jsonb(v_win));
    v_st := state_log(v_st,
      case when v_win = 'host' then m.host_name else m.guest_name end || ' wins.');
    update public.matches
       set state = v_st, status = 'finished', winner = v_win,
           turn_deadline = null, updated_at = now()
     where id = m.id returning * into m;
  else
    update public.matches set state = v_st, updated_at = now()
     where id = m.id returning * into m;
  end if;
  return m;
end
$function$;

-- ---------------------------------------------------------------------------
-- Did it work? All true means yes.
-- ---------------------------------------------------------------------------
select
  (select count(*) from information_schema.columns
    where table_schema = 'public' and table_name = 'profiles'
      and column_name in ('bot_wins', 'ranked_wins', 'crit_count', 'parry_count',
                           'featured_achievements')) = 5
                                                              as profiles_have_five_new_columns,
  to_regclass('public.player_achievements') is not null       as achievements_table_exists,
  to_regprocedure('public.cn_check_achievements(uuid)') is not null
                                                              as checker_exists,
  to_regprocedure('public.set_featured_achievements(text[])') is not null
                                                              as featuring_rpc_exists,
  pg_get_functiondef('public.finish_match(uuid,text,text)'::regprocedure)
    ilike '%ranked_wins = ranked_wins + 1%'                   as finish_match_feeds_ranked_wins,
  pg_get_functiondef('public.finish_match(uuid,text,text)'::regprocedure)
    ilike '%cn_check_achievements(w_id)%'                     as finish_match_checks_achievements,
  pg_get_functiondef('public.cn_finish(matches,jsonb,text)'::regprocedure)
    ilike '%bot_wins = bot_wins + 1%'                         as cn_finish_credits_bot_wins,
  pg_get_functiondef('public.cn_attack(uuid,text,text,text)'::regprocedure)
    ilike '%crit_count = crit_count + 1%'                     as cn_attack_counts_crits,
  pg_get_functiondef('public.cn_attack(uuid,text,text,text)'::regprocedure)
    ilike '%parry_count = parry_count + 1%'                   as cn_attack_counts_parries,
  pg_get_functiondef('public.cn_attack(uuid,text,text,text)'::regprocedure)
    ilike '%single_class_%'                                   as cn_attack_checks_single_class,
  pg_get_functiondef('public.cn_attack(uuid,text,text,text)'::regprocedure)
    ilike '%v_swing_is_atk := true%'                          as cn_attack_original_body_intact;
