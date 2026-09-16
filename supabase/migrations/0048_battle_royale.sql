-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice.
-- ===========================================================================
--  0048 -- Battle Royale: a 4-seat sibling of the 1v1 combat engine
--
--  Nothing here touches `matches`, `match_deploy`, `match_messages`, or any
--  of the 1v1 `cn_*`/`submit_*` functions. Everything lives in three new
--  tables (royale_matches, royale_players, royale_messages) and a parallel
--  set of `cn_*_royale` / `submit_royale_*` functions, most of them direct
--  ports of the 1v1 ones with 'host'/'guest' generalised to an int seat
--  (0-3) and the two-side win check replaced with elimination + last-seat-
--  standing. Every unit-generic helper (cn_damage, cn_chance, cn_roll,
--  cn_cheb, cn_los_clear, cn_afflict, cn_has, cn_stunned, cn_awake,
--  cn_mist_dodge, cn_effect_dmg, cn_obj_hp/kind/name/solid, cn_burn_pct,
--  cn_aura_bonus, cn_aura_resist, cn_parry_cap, state_log, cn_no_effects,
--  cn_acts_cap, cn_reach, cn_cine_ms, gen_match_code, deck_of, deck_size,
--  deck_royals, presence_grace) is called unchanged.
--
--  What is NOT built, on purpose, and why:
--  - Ranked/ELO: royale never touches player_rating, match_results,
--    profiles.lp, or finish_match(). No rank is on the line here.
--  - The achievement counters 0045 added (crit_count, parry_count,
--    bot_wins, single_class_*): those are ranked/bot-specific and out of
--    scope. A royale crit does not tick the ladder's crit counter.
--  - Mist and summons (walls/bombs/tornadoes/the throw): cn_ability_royale
--    supports aoe_adjacent, heal_any, poison_hit and line_burn, and raises
--    a plain refusal for 'mist' and 'summon'. See that function's comment.
--  - Idle/away tracking and the poison/regen/mist turn-tick that
--    advance_turn does for 1v1: advance_turn_royale does not carry it.
--    Poison from poison_hit still applies once when the ability lands; it
--    just does not keep biting turn over turn. A documented gap, not an
--    oversight -- see the report this migration shipped with.
--  - Deployment hiding: 1v1 hides each side's half behind match_deploy
--    until both are ready. Royale skips that -- every seat's placement is
--    visible in the shared match row as soon as it is made. Acceptable for
--    a friends-only v1; a real hidden-deploy scheme would need one
--    match_deploy-style row per seat.
--  - AFK forfeiture: royale_players.last_acted_turn is kept up to date
--    (see the submit_royale_* wrappers) so a follow-up migration can build
--    a forfeit rule on it. Nothing forfeits anyone yet.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------

create table if not exists public.royale_matches (
  id            uuid primary key default gen_random_uuid(),
  code          text unique,
  status        text not null default 'waiting'
                  check (status in ('waiting', 'deploying', 'active', 'finished')),
  state         jsonb not null,
  turn_deadline timestamptz,
  winner_seat   int,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create table if not exists public.royale_players (
  match_id         uuid not null references public.royale_matches(id) on delete cascade,
  seat             int not null check (seat between 0 and 3),
  user_id          uuid references public.profiles(id),
  username         text not null,
  avatar           text,
  eliminated       boolean not null default false,
  eliminated_at    timestamptz,
  ready            boolean not null default false,
  -- A hook for the separate AFK-rule work that comes after this migration.
  -- Kept current by the submit_royale_* wrappers; nothing reads it yet.
  last_acted_turn  int,
  -- This seat's own heartbeat, in place of a shared match_presence row --
  -- touch_royale_match / leave_royale_match / sweep_royale_matches below.
  seen_at          timestamptz not null default now(),
  joined_at        timestamptz not null default now(),
  primary key (match_id, seat)
);

create table if not exists public.royale_messages (
  id         bigint generated always as identity primary key,
  match_id   uuid not null references public.royale_matches(id) on delete cascade,
  user_id    uuid references public.profiles(id),
  username   text not null,
  body       text not null,
  created_at timestamptz not null default now()
);

alter table public.royale_matches  enable row level security;
alter table public.royale_players  enable row level security;
alter table public.royale_messages enable row level security;

-- No write policy on royale_matches/royale_players -- RPCs only, matching
-- how `matches` itself has zero write policy.
drop policy if exists "royale matches readable by authenticated" on public.royale_matches;
create policy "royale matches readable by authenticated" on public.royale_matches
  for select to authenticated using (true);

drop policy if exists "royale players readable by authenticated" on public.royale_players;
create policy "royale players readable by authenticated" on public.royale_players
  for select to authenticated using (true);

-- Mirrors match_messages' own two policies exactly: readable by anybody
-- signed in (so an eliminated player keeps spectator chat, same as a
-- 1v1 spectator does), post-as-self with no participant check at the
-- database layer -- the client is what points a message at one match_id.
drop policy if exists "royale messages readable by authenticated" on public.royale_messages;
create policy "royale messages readable by authenticated" on public.royale_messages
  for select to authenticated using (true);
drop policy if exists "royale messages post as self" on public.royale_messages;
create policy "royale messages post as self" on public.royale_messages
  for insert to authenticated with check (user_id = auth.uid());

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public'
       and tablename = 'royale_matches') then
    alter publication supabase_realtime add table public.royale_matches;
  end if;
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public'
       and tablename = 'royale_players') then
    alter publication supabase_realtime add table public.royale_players;
  end if;
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public'
       and tablename = 'royale_messages') then
    alter publication supabase_realtime add table public.royale_messages;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Board & zones -- the existing 6x8 board, split into four 3x4 quadrants.
-- ---------------------------------------------------------------------------

create or replace function public.cn_royale_zone(p_seat int)
returns int[] language sql immutable as $$
  -- [x0, x1, y0, y1], inclusive.
  select case p_seat
    when 0 then array[0, 2, 0, 3]
    when 1 then array[3, 5, 0, 3]
    when 2 then array[0, 2, 4, 7]
    when 3 then array[3, 5, 4, 7]
    else null
  end
$$;

create or replace function public.cn_own_royale(p_x int, p_y int, p_seat int)
returns boolean language sql immutable as $$
  select (cn_royale_zone(p_seat)) is not null
     and p_x between (cn_royale_zone(p_seat))[1] and (cn_royale_zone(p_seat))[2]
     and p_y between (cn_royale_zone(p_seat))[3] and (cn_royale_zone(p_seat))[4]
$$;

-- A small scatter of its own rather than cn_gen_trees(): that one keeps
-- every tree out of the row nearest either 1v1 EDGE, which on this board
-- would still let one land on row 3 or row 4 -- the row of a quadrant
-- nearest the board's CENTRE, i.e. its front line. Royale's rule is the
-- other way round: avoid the four zones' innermost rows (3 and 4) so
-- nobody's front line opens with a tree in it, and let the scatter fall
-- anywhere else, same minimum spacing cn_gen_trees uses.
create or replace function public.cn_royale_gen_trees(p_w int, p_h int)
returns jsonb language plpgsql as $$
declare
  v_cand int[]; v_pick int[] := '{}'::int[];
  i int; j int; v_x int; v_y int; v_px int; v_py int;
  v_ok boolean; v_out jsonb := '[]'::jsonb; v_k int := 0; v_n int := 0;
begin
  select array_agg(t) into v_cand from (
    select gy.y * p_w + gx.x as t
      from generate_series(0, p_w - 1) as gx(x),
           generate_series(0, p_h - 1) as gy(y)
     where gy.y not in (3, 4)
     order by random()) s;

  foreach i in array coalesce(v_cand, '{}'::int[]) loop
    exit when v_n = 6;
    v_x := i % p_w; v_y := i / p_w;
    v_ok := true;
    foreach j in array v_pick loop
      v_px := j % p_w; v_py := j / p_w;
      if cn_cheb(v_x, v_y, v_px, v_py) < 2 then v_ok := false; exit; end if;
    end loop;
    if v_ok then v_pick := v_pick || i; v_n := v_n + 1; end if;
  end loop;

  foreach i in array v_pick loop
    v_k := v_k + 1;
    v_out := v_out || jsonb_build_object(
      'id', 'rt' || v_k, 'kind', 'tree', 'x', i % p_w, 'y', i / p_w,
      'hp', cn_obj_hp('tree'), 'maxHp', cn_obj_hp('tree'));
  end loop;
  return v_out;
end
$$;

create or replace function public.cn_royale_fresh_map()
returns jsonb language plpgsql as $$
declare v_w int := 6; v_h int := 8;
begin
  return jsonb_build_object(
    'v', 1,
    'board', jsonb_build_object('w', v_w, 'h', v_h),
    'phase', 'lobby',
    'obstacles', cn_royale_gen_trees(v_w, v_h),
    'units', '[]'::jsonb,
    'pendingUnits', '{}'::jsonb,
    'turn', null,
    'turnNumber', 0,
    'acts', 0,
    'active', null,
    'log', '[]'::jsonb,
    'winnerSeat', null);
end
$$;

-- Builds one seat's five units and places them inside its own quadrant,
-- back rank first (the row of the zone farthest from the board's centre).
-- A direct port of cn_army(), with p_side/'host'/'guest' generalised to an
-- int seat and a quadrant in place of a half.
create or replace function public.cn_royale_army(p_state jsonb, p_seat int, p_deck text[])
returns jsonb language plpgsql as $$
declare
  v_zone int[] := cn_royale_zone(p_seat);
  v_taken text[] := '{}'; e jsonb; c public.cards;
  v_xs int[] := '{}'::int[]; v_ys int[] := '{}'::int[];
  i int; vx int; vy int; v_idx int := 0; v_units jsonb := '[]'::jsonb; v_done boolean;
begin
  if v_zone is null then raise exception 'no such seat %', p_seat; end if;

  if deck_royals(p_deck) <> 1 then
    raise exception 'a kingdom is exactly one royal and % others, not %',
      deck_size() - 1, deck_royals(p_deck);
  end if;

  for e in select * from jsonb_array_elements(coalesce(p_state->'obstacles', '[]'::jsonb)) loop
    v_taken := v_taken || ((e->>'x') || ',' || (e->>'y'));
  end loop;

  for i in v_zone[1] .. v_zone[2] loop v_xs := v_xs || i; end loop;

  if v_zone[3] = 0 then
    for i in v_zone[3] .. v_zone[4] loop v_ys := v_ys || i; end loop;
  else
    for i in reverse v_zone[4] .. v_zone[3] loop v_ys := v_ys || i; end loop;
  end if;

  for i in 1 .. deck_size() loop
    select * into c from public.cards where slug = p_deck[i];
    if c.id is null then raise exception 'unknown card %', p_deck[i]; end if;

    v_done := false;
    foreach vy in array v_ys loop
      foreach vx in array v_xs loop
        if not ((vx || ',' || vy) = any(v_taken)) then
          v_taken := v_taken || (vx || ',' || vy);
          v_done := true;
          exit;
        end if;
      end loop;
      exit when v_done;
    end loop;
    if not v_done then raise exception 'nowhere to deploy'; end if;

    v_idx := v_idx + 1;
    v_units := v_units || (jsonb_build_object(
      'id', 'r' || p_seat || 'u' || v_idx, 'owner', p_seat,
      'cardId', c.id, 'slug', c.slug, 'name', c.name, 'role', c.role,
      'hp', c.hp, 'maxHp', c.hp, 'mov', c.mov,
      'rmin', c.rmin, 'rmax', c.rmax, 'crmin', c.crmin, 'crmax', c.crmax,
      'dmin', c.dmin, 'dmax', c.dmax, 'pow', c.power,
      'parryPct', c.parry_pct, 'critPct', c.crit_pct, 'parryAll', c.parry_all,
      'royal', c.royal,
      'abilityKind', c.ability_kind, 'abilityN', c.ability_n,
      'abilityTurns', c.ability_turns, 'summonKind', c.summon_kind,
      'slippery', c.slippery, 'twicePct', c.twice_pct, 'regenPct', c.regen_pct,
      'poisonsAdj', c.poisons_adjacent, 'stuns', c.stuns,
      'vsPoisoned', c.vs_poisoned, 'lifestealPct', c.lifesteal_pct,
      'auraKind', c.aura_kind, 'auraClass', c.aura_class, 'auraPct', c.aura_pct,
      'burns', c.burns, 'heals', c.heals,
      'effects', cn_no_effects(),
      'flies', c.flies, 'sneaks', c.sneaks, 'cures', c.cures, 'tramples', c.tramples,
      'parries', c.parries, 'blooms', c.blooms,
      'accent', c.accent, 'art', c.art_url, 'ability', c.ability,
      'x', vx, 'y', vy, 'moved', false, 'acted', false)
      || jsonb_build_object('swamps', c.swamps));
  end loop;
  return v_units;
end
$$;

-- ---------------------------------------------------------------------------
-- Who you are
-- ---------------------------------------------------------------------------

create or replace function public.royale_side_of(p_match uuid)
returns int language sql stable as $$
  select rp.seat
    from public.royale_players rp
   where rp.match_id = p_match and rp.user_id = auth.uid() and not rp.eliminated
     and not exists (
       select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_banned)
$$;

-- ---------------------------------------------------------------------------
-- Room lifecycle
-- ---------------------------------------------------------------------------

create or replace function public.create_royale_match()
returns royale_matches language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := auth.uid(); v_name text; v_avatar text; m public.royale_matches;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select username, avatar into v_name, v_avatar from public.profiles where id = v_uid;
  if v_name is null then raise exception 'no profile'; end if;

  insert into public.royale_matches (code, status, state)
  values (gen_match_code(), 'waiting',
          state_log(cn_royale_fresh_map(), v_name || ' opened a battle royale.'))
  returning * into m;

  insert into public.royale_players (match_id, seat, user_id, username, avatar)
  values (m.id, 0, v_uid, v_name, v_avatar);

  return m;
end
$$;

create or replace function public.join_royale_match(p_code text)
returns royale_matches language plpgsql security definer set search_path to 'public' as $$
declare
  v_uid uuid := auth.uid(); v_name text; v_avatar text; m public.royale_matches;
  v_seat int; v_taken int[]; v_st jsonb; i int;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select username, avatar into v_name, v_avatar from public.profiles where id = v_uid;
  if v_name is null then raise exception 'no profile'; end if;

  select * into m from public.royale_matches where code = upper(trim(p_code)) for update;
  if m.id is null then raise exception 'no room with that code'; end if;

  select seat into v_seat from public.royale_players
   where match_id = m.id and user_id = v_uid;
  if v_seat is not null then return m; end if;

  if m.status not in ('waiting', 'deploying') then
    raise exception 'that match has already started';
  end if;

  select array_agg(seat) into v_taken from public.royale_players where match_id = m.id;
  v_seat := null;
  for i in 0 .. 3 loop
    if not (i = any(coalesce(v_taken, '{}'::int[]))) then v_seat := i; exit; end if;
  end loop;
  if v_seat is null then raise exception 'that room is already full'; end if;

  insert into public.royale_players (match_id, seat, user_id, username, avatar)
  values (m.id, v_seat, v_uid, v_name, v_avatar);

  v_st := state_log(m.state, v_name || ' entered the arena.');
  update public.royale_matches set state = v_st, updated_at = now()
   where id = m.id returning * into m;
  return m;
end
$$;

-- Host-only (seat 0). Deliberately allows starting with as few as two
-- seated -- real friend groups will not always have four online -- and
-- builds an army only for whoever is actually seated.
create or replace function public.start_royale_match(p_match uuid)
returns royale_matches language plpgsql security definer set search_path to 'public' as $$
declare
  m public.royale_matches; v_uid uuid := auth.uid(); v_st jsonb;
  rp record; v_deck text[]; v_army jsonb; v_pending jsonb := '{}'::jsonb; v_count int;
begin
  select * into m from public.royale_matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'waiting' then raise exception 'this match has already started'; end if;

  if not exists (
    select 1 from public.royale_players
     where match_id = p_match and seat = 0 and user_id = v_uid) then
    raise exception 'only the host can start the match';
  end if;

  select count(*) into v_count from public.royale_players where match_id = p_match;
  if v_count < 2 then raise exception 'wait for at least one more player'; end if;

  v_st := m.state;
  for rp in select * from public.royale_players where match_id = p_match order by seat loop
    v_deck := deck_of(rp.user_id);
    v_army := cn_royale_army(v_st, rp.seat, v_deck);
    v_pending := v_pending || jsonb_build_object(rp.seat::text, v_army);
  end loop;

  v_st := jsonb_set(v_st, '{pendingUnits}', v_pending, true);
  v_st := jsonb_set(v_st, '{phase}', '"deploy"'::jsonb, true);
  v_st := state_log(v_st, 'Place your units, then press Ready.');

  update public.royale_matches
     set state = v_st, status = 'deploying',
         turn_deadline = now() + interval '90 seconds', updated_at = now()
   where id = m.id returning * into m;
  return m;
end
$$;

-- Reposition a unit inside your own pending army, before Ready -- a direct
-- port of deploy_unit()'s swap behaviour, minus the hidden-half table:
-- royale keeps each seat's still-unplaced army in state->pendingUnits
-- rather than in a second table, since there is no fog to keep here (see
-- the migration header's "deployment hiding" note).
create or replace function public.deploy_royale_unit(p_match uuid, p_unit_id text, p_x int, p_y int)
returns royale_matches language plpgsql security definer set search_path to 'public' as $$
declare
  m public.royale_matches; v_seat int; v_ready boolean; v_st jsonb; v_units jsonb;
  u jsonb; e jsonb; v_me jsonb; v_swap jsonb; v_out jsonb := '[]'::jsonb; v_w int; v_h int;
begin
  select * into m from public.royale_matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'deploying' then raise exception 'deployment is over'; end if;

  select seat, ready into v_seat, v_ready from public.royale_players
   where match_id = p_match and user_id = auth.uid();
  if v_seat is null then raise exception 'you are not seated in this match'; end if;
  if v_ready then raise exception 'you are already ready'; end if;

  v_st := m.state;
  v_w := (v_st->'board'->>'w')::int;
  v_h := (v_st->'board'->>'h')::int;
  v_units := v_st->'pendingUnits'->v_seat::text;
  if v_units is null then raise exception 'nothing to deploy'; end if;

  for u in select * from jsonb_array_elements(v_units) loop
    if u->>'id' = p_unit_id then v_me := u; end if;
    if (u->>'x')::int = p_x and (u->>'y')::int = p_y then v_swap := u; end if;
  end loop;
  if v_me is null then raise exception 'that is not your unit'; end if;

  if p_x < 0 or p_y < 0 or p_x >= v_w or p_y >= v_h then raise exception 'off the board'; end if;
  if not cn_own_royale(p_x, p_y, v_seat) then raise exception 'that is not your zone'; end if;

  for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
    if (e->>'x')::int = p_x and (e->>'y')::int = p_y then
      raise exception 'there is a tree there';
    end if;
  end loop;

  for u in select * from jsonb_array_elements(v_units) loop
    if u->>'id' = p_unit_id then
      u := jsonb_set(jsonb_set(u, '{x}', to_jsonb(p_x)), '{y}', to_jsonb(p_y));
    elsif v_swap is not null and u->>'id' = v_swap->>'id' then
      u := jsonb_set(jsonb_set(u, '{x}', v_me->'x'), '{y}', v_me->'y');
    end if;
    v_out := v_out || u;
  end loop;

  v_st := jsonb_set(v_st, array['pendingUnits', v_seat::text], v_out);
  update public.royale_matches set state = v_st, updated_at = now()
   where id = p_match returning * into m;
  return m;
end
$$;

-- Once every seated player is ready, folds every pending army onto the
-- board at once and opens the battle -- a direct parallel of cn_set_ready.
create or replace function public.set_royale_ready(p_match uuid)
returns royale_matches language plpgsql security definer set search_path to 'public' as $$
declare
  m public.royale_matches; v_seat int; v_name text; v_st jsonb; v_all_ready boolean;
  rp record; v_units jsonb; v_first int; v_first_name text;
begin
  select * into m from public.royale_matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'deploying' then raise exception 'deployment is over'; end if;

  select seat, username into v_seat, v_name from public.royale_players
   where match_id = p_match and user_id = auth.uid();
  if v_seat is null then raise exception 'you are not seated in this match'; end if;

  update public.royale_players set ready = true
   where match_id = p_match and seat = v_seat;
  v_st := state_log(m.state, v_name || ' is ready.');

  select bool_and(ready) into v_all_ready from public.royale_players where match_id = p_match;
  if not coalesce(v_all_ready, false) then
    update public.royale_matches set state = v_st, updated_at = now()
     where id = m.id returning * into m;
    return m;
  end if;

  v_units := '[]'::jsonb;
  for rp in select * from public.royale_players where match_id = p_match order by seat loop
    v_units := v_units || coalesce(v_st->'pendingUnits'->rp.seat::text, '[]'::jsonb);
  end loop;
  v_st := jsonb_set(v_st, '{units}', v_units);
  v_st := v_st - 'pendingUnits';
  v_st := jsonb_set(v_st, '{phase}', '"battle"'::jsonb);

  select seat into v_first from public.royale_players
   where match_id = p_match order by random() limit 1;
  select username into v_first_name from public.royale_players
   where match_id = p_match and seat = v_first;
  v_st := jsonb_set(v_st, '{turn}', to_jsonb(v_first));
  v_st := jsonb_set(v_st, '{turnNumber}', '1'::jsonb);
  v_st := state_log(v_st, 'Turn 1 -- ' || v_first_name || ' to act.');

  update public.royale_matches
     set state = v_st, status = 'active',
         turn_deadline = now() + interval '30 seconds', updated_at = now()
   where id = m.id returning * into m;
  return m;
end
$$;

-- ---------------------------------------------------------------------------
-- Turn engine -- cn_begin_act_royale / cn_end_act_royale mirror the 1v1
-- pair with p_side generalised to an int seat. cn_acts_cap() is called
-- unchanged: it reads only turnNumber, nothing side-specific.
-- ---------------------------------------------------------------------------

create or replace function public.cn_begin_act_royale(p_st jsonb, p_seat int, p_unit text)
returns jsonb language plpgsql as $$
declare
  v_active text; v_acts int; v_cap int; u jsonb; v_me jsonb; v_out jsonb := '[]'::jsonb;
begin
  for u in select * from jsonb_array_elements(p_st->'units') loop
    if u->>'id' = p_unit then v_me := u; end if;
  end loop;
  if v_me is null then raise exception 'no such unit'; end if;
  if (v_me->>'owner')::int <> p_seat then raise exception 'that is not your unit'; end if;
  if coalesce((v_me->>'spent')::boolean, false) then
    raise exception 'that unit has already had its go this turn';
  end if;

  v_active := nullif(p_st->>'active', '');
  v_acts   := coalesce((p_st->>'acts')::int, 0);
  v_cap    := cn_acts_cap(p_st);

  if v_active is not distinct from p_unit then return p_st; end if;
  if v_acts >= v_cap then raise exception 'no actions left this turn'; end if;

  if v_active is not null then
    for u in select * from jsonb_array_elements(p_st->'units') loop
      if u->>'id' = v_active then u := jsonb_set(u, '{spent}', 'true'::jsonb); end if;
      v_out := v_out || u;
    end loop;
    p_st := jsonb_set(p_st, '{units}', v_out);
  end if;

  p_st := jsonb_set(p_st, '{acts}', to_jsonb(v_acts + 1));
  p_st := jsonb_set(p_st, '{active}', to_jsonb(p_unit));
  return p_st;
end
$$;

create or replace function public.cn_end_act_royale(p_st jsonb, p_unit text)
returns jsonb language plpgsql as $$
declare u jsonb; v_out jsonb := '[]'::jsonb;
begin
  for u in select * from jsonb_array_elements(p_st->'units') loop
    if u->>'id' = p_unit then u := jsonb_set(u, '{spent}', 'true'::jsonb); end if;
    v_out := v_out || u;
  end loop;
  return jsonb_set(jsonb_set(p_st, '{units}', v_out), '{active}', 'null'::jsonb);
end
$$;

create or replace function public.cn_move_royale(
  p_match uuid, p_seat int, p_unit text, p_x int, p_y int
)
returns royale_matches language plpgsql security definer set search_path to 'public' as $$
declare
  m public.royale_matches; v_st jsonb; u jsonb; e jsonb; v_me jsonb;
  v_out jsonb := '[]'::jsonb; v_rocks jsonb := '[]'::jsonb;
  v_reach text[]; v_felled boolean := false;
begin
  select * into m from public.royale_matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  v_st := m.state;
  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then v_me := u; end if;
  end loop;
  if v_me is null then raise exception 'no such unit'; end if;
  if (v_me->>'owner')::int <> p_seat then raise exception 'that is not your unit'; end if;
  if (v_me->>'moved')::boolean then raise exception 'that unit already moved'; end if;

  v_st := cn_begin_act_royale(v_st, p_seat, p_unit);

  v_reach := cn_reach(v_st, v_me);
  if not ((p_x || ',' || p_y) = any(v_reach)) then
    raise exception 'that unit cannot reach that tile';
  end if;

  -- Royale v1 has no summons -- see the header -- so an obstacle here is
  -- always a tree.
  for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
    if (e->>'x')::int = p_x and (e->>'y')::int = p_y and cn_obj_kind(e) = 'tree' then
      v_felled := true;
    else
      v_rocks := v_rocks || e;
    end if;
  end loop;

  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then
      u := jsonb_set(jsonb_set(u, '{x}', to_jsonb(p_x)), '{y}', to_jsonb(p_y));
      u := jsonb_set(u, '{moved}', 'true'::jsonb);
    end if;
    v_out := v_out || u;
  end loop;

  v_st := jsonb_set(v_st, '{units}', v_out);
  v_st := jsonb_set(v_st, '{obstacles}', v_rocks);
  v_st := state_log(v_st, (v_me->>'name') || ' advances.');
  if v_felled then
    v_st := state_log(v_st, (v_me->>'name') || ' walks through a tree. It comes down.');
  end if;

  update public.royale_matches set state = v_st, updated_at = now()
   where id = m.id returning * into m;
  return m;
end
$$;

create or replace function public.cn_defend_royale(p_match uuid, p_seat int, p_unit text)
returns royale_matches language plpgsql security definer set search_path to 'public' as $$
declare m public.royale_matches; v_st jsonb; u jsonb; v_me jsonb; v_out jsonb := '[]'::jsonb;
begin
  select * into m from public.royale_matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  v_st := m.state;
  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then v_me := u; end if;
  end loop;
  if v_me is null then raise exception 'no such unit'; end if;
  if (v_me->>'owner')::int <> p_seat then raise exception 'that is not your unit'; end if;
  if (v_me->>'acted')::boolean then raise exception 'that unit already acted'; end if;

  v_st := cn_begin_act_royale(v_st, p_seat, p_unit);

  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then
      u := jsonb_set(u, '{defending}', 'true'::jsonb);
      u := jsonb_set(u, '{acted}', 'true'::jsonb);
    end if;
    v_out := v_out || u;
  end loop;
  v_st := jsonb_set(v_st, '{units}', v_out);
  v_st := cn_end_act_royale(v_st, p_unit);
  v_st := state_log(v_st, (v_me->>'name') || ' raises a guard.');

  update public.royale_matches set state = v_st, updated_at = now()
   where id = m.id returning * into m;
  return m;
end
$$;

-- Round robin over whichever seats are not eliminated. No idle/away
-- tracking and no mist/poison/regen tick here -- see the header.
create or replace function public.advance_turn_royale(p_match uuid, p_note text)
returns royale_matches language plpgsql security definer set search_path to 'public' as $$
declare
  m public.royale_matches; st jsonb; u jsonb; out_u jsonb := '[]'::jsonb;
  v_who int; v_next int; v_turn int; v_seats int[]; v_tries int := 0; v_name text;
begin
  select * into m from public.royale_matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  st := m.state;
  v_who := coalesce((st->>'turn')::int, 0);
  v_turn := coalesce((st->>'turnNumber')::int, 1) + 1;

  select array_agg(seat order by seat) into v_seats
    from public.royale_players where match_id = p_match and not eliminated;
  if coalesce(array_length(v_seats, 1), 0) = 0 then return m; end if;

  v_next := v_who;
  loop
    v_next := (v_next + 1) % 4;
    v_tries := v_tries + 1;
    exit when v_next = any(v_seats) or v_tries > 4;
  end loop;
  if v_tries > 4 then v_next := v_seats[1]; end if;

  for u in select * from jsonb_array_elements(st->'units') loop
    u := jsonb_set(u, '{moved}', 'false'::jsonb);
    u := jsonb_set(u, '{acted}', 'false'::jsonb);
    u := jsonb_set(u, '{spent}', 'false'::jsonb);
    if (u->>'owner')::int = v_next then
      u := jsonb_set(u, '{defending}', 'false'::jsonb);
    end if;
    out_u := out_u || u;
  end loop;
  st := jsonb_set(st, '{units}', out_u);

  st := jsonb_set(st, '{acts}', '0'::jsonb);
  st := jsonb_set(st, '{active}', 'null'::jsonb);
  st := jsonb_set(st, '{turn}', to_jsonb(v_next));
  st := jsonb_set(st, '{turnNumber}', to_jsonb(v_turn));
  if p_note is not null then st := state_log(st, p_note); end if;
  select username into v_name from public.royale_players
   where match_id = p_match and seat = v_next;
  st := state_log(st, 'Turn ' || v_turn || ' -- ' || coalesce(v_name, 'seat ' || v_next)
        || ' to act.');

  update public.royale_matches
     set state = st, turn_deadline = now() + interval '30 seconds', updated_at = now()
   where id = m.id returning * into m;
  return m;
end
$$;

-- ---------------------------------------------------------------------------
-- cn_attack_royale -- a direct port of cn_attack, with:
--  * p_side text -> p_seat int, and every `->>'owner' = p_side` comparison
--    cast to int against p_seat instead of compared as text;
--  * the whole 0045 achievements/ranked/bot-win tail removed (out of
--    scope -- see the header);
--  * the two-side "crown fell" / "no foes left" / "no units left" win
--    check replaced with: a dead royal wipes the rest of that seat's army
--    and eliminates the seat; a seat that hits zero units any other way is
--    eliminated too (the safety net the spec asks for); the match ends the
--    moment exactly one seat is left standing.
-- Every unit-generic helper below (cn_awake, cn_stunned, cn_cheb,
-- cn_los_clear, cn_chance, cn_roll, cn_damage, cn_afflict, cn_has,
-- cn_effect_dmg, cn_burn_pct, cn_mist_dodge, cn_aura_bonus, cn_aura_resist,
-- cn_parry_cap, cn_obj_name, cn_obj_kind, cn_no_effects, state_log) is
-- called exactly as cn_attack calls it.
-- ---------------------------------------------------------------------------

create or replace function public.cn_attack_royale(
  p_match uuid, p_seat int, p_unit text, p_target text
)
returns royale_matches language plpgsql security definer set search_path to 'public' as $$
declare
  m public.royale_matches; v_st jsonb; u jsonb; e jsonb;
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
  v_ally boolean := false; v_note text;
  v_missed boolean := false; v_hit2 int; v_crit2 boolean;
  v_cost int; v_steal int;
  -- royale-only: who might have just been eliminated, and who is left.
  v_check_seats int[] := '{}'::int[]; v_seat int; v_royal_dead boolean;
  v_has_units boolean; v_alive_seats int[]; v_win_seat int; v_seat_name text;
begin
  select * into m from public.royale_matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  v_st := m.state;

  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit   then v_atk := u; end if;
    if u->>'id' = p_target then v_tgt := u; end if;
  end loop;
  for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
    if e->>'id' = p_target then v_tree := e; end if;
  end loop;

  v_atk := cn_awake(v_st, v_atk);
  v_tgt := cn_awake(v_st, v_tgt);

  if v_atk is null then raise exception 'no such unit'; end if;
  if v_tgt is null and v_tree is null then raise exception 'no such target'; end if;
  if (v_atk->>'owner')::int <> p_seat then raise exception 'that is not your unit'; end if;
  if (v_atk->>'acted')::boolean then raise exception 'that unit already acted'; end if;
  if cn_stunned(v_atk) then raise exception 'that unit is stunned'; end if;

  v_st := cn_begin_act_royale(v_st, p_seat, p_unit);

  if v_tree is not null then
    v_dist := cn_cheb((v_atk->>'x')::int, (v_atk->>'y')::int,
                      (v_tree->>'x')::int, (v_tree->>'y')::int);
  else
    v_ally := ((v_tgt->>'owner')::int = p_seat);
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

  if v_ally and coalesce((v_atk->>'heals')::boolean, false) then
    v_heal_roll := cn_roll((v_atk->>'dmin')::int, (v_atk->>'dmax')::int);
    v_heal := v_heal_roll;
    v_tgt_hp := least((v_tgt->>'maxHp')::int, (v_tgt->>'hp')::int + v_heal);
    v_heal := v_tgt_hp - (v_tgt->>'hp')::int;
    v_cured := coalesce((v_atk->>'cures')::boolean, false) and cn_has(v_tgt, 'burn');
    if v_cured then v_tgt := cn_afflict(v_tgt, 'burn', 'false'::jsonb); end if;
    v_note := (v_atk->>'name') || ' mends ' || (v_tgt->>'name') || ' for ' || v_heal || '.';
    v_swings := v_swings || jsonb_build_object(
      'k', 'heal', 'by', p_unit, 'at', p_target, 'dmg', v_heal,
      'crit', false, 'counter', false, 'first', false, 'def', false, 'why', 'mend');

    if coalesce((v_atk->>'blooms')::boolean, false) then
      for u in select * from jsonb_array_elements(v_st->'units') loop
        continue when u->>'id' = p_unit or u->>'id' = p_target;
        continue when (u->>'owner')::int <> p_seat;
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
    v_crit := cn_chance((v_atk->>'critPct')::int, 'crit');
    v_dmg := cn_damage(cn_roll((v_atk->>'dmin')::int, (v_atk->>'dmax')::int), v_crit, false);
    v_tgt_hp := (v_tree->>'hp')::int - v_dmg;
    v_killed_tgt := v_tgt_hp <= 0;
    v_swings := v_swings || jsonb_build_object(
      'k', 'hit', 'by', p_unit, 'at', p_target, 'dmg', v_dmg,
      'crit', v_crit, 'counter', false, 'first', false, 'def', false, 'why', 'tree');
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
    v_note := (v_atk->>'name') || ' strikes ' || cn_obj_name(cn_obj_kind(v_tree))
              || ' for ' || v_dmg
              || case when v_killed_tgt then ' -- destroyed.' else '.' end;

  else
    v_tgt_hp := (v_tgt->>'hp')::int;

    v_answers := not v_ally
                 and not coalesce((v_atk->>'sneaks')::boolean, false)
                 and v_dist >= (v_tgt->>'crmin')::int
                 and v_dist <= (v_tgt->>'crmax')::int;
    v_tgt_reaches  := v_answers;
    v_reaches_back := v_dist >= (v_atk->>'crmin')::int
                  and v_dist <= (v_atk->>'crmax')::int;

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
      v_parry   := true;
      v_answers := false;
      v_notes := v_notes || ((v_tgt->>'name') || ' answers first for ' || v_counter
                 || case when v_crit_counter then ' -- a critical hit.' else '.' end);
      v_swings := v_swings || jsonb_build_object(
        'k', 'hit', 'by', p_target, 'at', p_unit, 'dmg', v_counter,
        'crit', v_crit_counter, 'counter', true, 'first', true,
        'def', coalesce((v_atk->>'defending')::boolean, false), 'why', 'quick');
    end if;

    while not v_killed_atk and not v_killed_tgt and v_chain < cn_parry_cap() loop
      v_chain := v_chain + 1;
      if v_swing_is_atk
        then v_strk := v_atk; v_recv := v_tgt;
        else v_strk := v_tgt; v_recv := v_atk;
      end if;

      v_parried := not v_ally
                   and not coalesce((v_strk->>'slippery')::boolean, false)
                   and ((v_is_counter and coalesce((v_recv->>'parryAll')::boolean, false))
                        or cn_chance((v_recv->>'parryPct')::int, 'parry'));

      if v_parried then
        v_parries := v_parries + 1;
        if v_chain = 1 then v_parry := true; end if;
        v_notes := v_notes || ((v_recv->>'name') || ' parries ' || (v_strk->>'name') || '.');
        v_swings := v_swings || jsonb_build_object(
          'k', 'parry', 'by', v_recv->>'id', 'at', v_strk->>'id',
          'why', case when v_is_counter
                       and coalesce((v_recv->>'parryAll')::boolean, false)
                      then 'all' else 'roll' end);
        exit when not case when v_swing_is_atk then v_tgt_reaches else v_reaches_back end;
        v_swing_is_atk := not v_swing_is_atk;
        v_is_counter := true;
        continue;
      end if;

      v_hit_crit := not coalesce((v_recv->>'slippery')::boolean, false)
                    and cn_chance((v_strk->>'critPct')::int, 'crit');
      v_hit := cn_damage(cn_roll((v_strk->>'dmin')::int, (v_strk->>'dmax')::int),
                         v_hit_crit, v_is_counter,
                         cn_aura_bonus(v_st, v_strk, v_recv),
                         cn_aura_resist(v_st, v_strk, v_recv),
                         coalesce((v_recv->>'defending')::boolean, false));
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
        'why', case when v_missed then 'mist' when v_is_counter then 'counter'
                    else 'strike' end);

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
          'def', coalesce((v_recv->>'defending')::boolean, false), 'why', 'twice');
        v_notes := v_notes || ((v_strk->>'name') || ' strikes again for ' || v_hit2 || '.');
      end if;
      if v_is_counter then
        v_notes := v_notes || ((v_strk->>'name') || ' answers for ' || v_hit
                   || case when v_hit_crit then ' -- a critical hit.' else '.' end);
      end if;

      if not v_missed and v_hit > 0 and coalesce((v_strk->>'stuns')::boolean, false) then
        if v_swing_is_atk then v_tgt := cn_afflict(v_tgt, 'stun', '1'::jsonb);
                          else v_atk := cn_afflict(v_atk, 'stun', '1'::jsonb); end if;
        v_notes := v_notes || ((v_recv->>'name') || ' is caught in the cyclone.');
      end if;

      v_steal := round(v_hit * coalesce((v_strk->>'lifestealPct')::int, 0) / 100.0)::int;
      if v_steal > 0 then
        if v_swing_is_atk
          then v_atk_hp := least((v_atk->>'maxHp')::int, v_atk_hp + v_steal);
          else v_tgt_hp := least((v_tgt->>'maxHp')::int, v_tgt_hp + v_steal);
        end if;
        v_swings := v_swings || jsonb_build_object(
          'k', 'heal', 'by', v_strk->>'id', 'at', v_strk->>'id', 'dmg', v_steal, 'why', 'steal');
      end if;

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
      if v_killed_tgt then
        v_swings := v_swings || jsonb_build_object('k', 'down', 'by', p_target, 'at', p_target);
      end if;
      if v_killed_atk then
        v_swings := v_swings || jsonb_build_object('k', 'down', 'by', p_unit, 'at', p_unit);
      end if;
      exit when v_killed_atk or v_killed_tgt;

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
        u := jsonb_set(u, '{effects}', coalesce(v_atk->'effects', cn_no_effects()), true);
        v_out := v_out || u;
      end if;
    elsif v_tree is null and u->>'id' = p_target then
      if not v_killed_tgt then
        u := jsonb_set(u, '{hp}', to_jsonb(v_tgt_hp));
        u := jsonb_set(u, '{effects}', coalesce(v_tgt->'effects', cn_no_effects()), true);
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
    v_st := state_log(v_st, 'The bloom spreads -- ' || jsonb_array_length(v_bloom) || ' more mended.');
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

  -- ---- royale elimination + last-seat-standing --------------------------
  -- Only the two units this exchange touched can have changed a seat's
  -- unit count, so only their owners need checking.
  if v_tree is null and v_killed_tgt then
    v_check_seats := v_check_seats || (v_tgt->>'owner')::int;
  end if;
  if v_killed_atk then
    v_check_seats := v_check_seats || (v_atk->>'owner')::int;
  end if;

  foreach v_seat in array v_check_seats loop
    continue when v_seat is null;
    continue when exists (
      select 1 from public.royale_players
       where match_id = p_match and seat = v_seat and eliminated);

    v_royal_dead :=
      (v_tree is null and v_killed_tgt and (v_tgt->>'owner')::int = v_seat
       and coalesce((v_tgt->>'royal')::boolean, false))
      or (v_killed_atk and (v_atk->>'owner')::int = v_seat
          and coalesce((v_atk->>'royal')::boolean, false));
    v_has_units := exists (
      select 1 from jsonb_array_elements(v_out) q where (q->>'owner')::int = v_seat);

    if v_royal_dead or not v_has_units then
      if v_royal_dead and v_has_units then
        -- The crown fell: the rest of this seat's army disappears with it.
        v_out := (select coalesce(jsonb_agg(q), '[]'::jsonb)
                    from jsonb_array_elements(v_out) q
                   where (q->>'owner')::int <> v_seat);
        v_st := jsonb_set(v_st, '{units}', v_out);
      end if;
      select username into v_seat_name from public.royale_players
       where match_id = p_match and seat = v_seat;
      update public.royale_players set eliminated = true, eliminated_at = now()
       where match_id = p_match and seat = v_seat;
      v_st := state_log(v_st,
        case when v_royal_dead then 'The crown falls. ' else '' end
        || coalesce(v_seat_name, 'Seat ' || v_seat) || ' is eliminated.');
    end if;
  end loop;

  select array_agg(seat) into v_alive_seats
    from public.royale_players where match_id = p_match and not eliminated;
  if coalesce(array_length(v_alive_seats, 1), 0) = 1 then
    v_win_seat := v_alive_seats[1];
  end if;

  if v_win_seat is not null then
    select username into v_seat_name from public.royale_players
     where match_id = p_match and seat = v_win_seat;
    v_st := jsonb_set(v_st, '{winnerSeat}', to_jsonb(v_win_seat));
    v_st := state_log(v_st, coalesce(v_seat_name, 'Seat ' || v_win_seat) || ' wins the battle royale.');
    update public.royale_matches
       set state = v_st, status = 'finished', winner_seat = v_win_seat,
           turn_deadline = null, updated_at = now()
     where id = m.id returning * into m;
  else
    update public.royale_matches set state = v_st, updated_at = now()
     where id = m.id returning * into m;
  end if;
  return m;
end
$$;

-- ---------------------------------------------------------------------------
-- cn_ability_royale -- supports the four ability kinds that are not
-- owner-pair-specific: aoe_adjacent, heal_any, poison_hit, line_burn.
-- 'mist' (per-side keyed state) and 'summon' (one-alive-at-a-time objects,
-- the throw) are not built for royale v1 -- see the migration header.
-- ---------------------------------------------------------------------------

create or replace function public.cn_ability_royale(
  p_match uuid, p_seat int, p_unit text, p_target text
)
returns royale_matches language plpgsql security definer set search_path to 'public' as $$
declare
  m public.royale_matches; v_st jsonb; u jsonb; e jsonb;
  v_me jsonb; v_tgt jsonb; v_kind text; v_n int;
  v_out jsonb := '[]'::jsonb; v_rocks jsonb := '[]'::jsonb;
  v_hits jsonb := '[]'::jsonb; v_swings jsonb := '[]'::jsonb;
  v_dist int; v_got int; v_felled boolean := false;
  v_dx int; v_dy int; v_note text; v_seq int;
  -- royale-only: {seat, royal} for every unit this ability's blast dropped
  -- to zero, captured BEFORE it is filtered out of v_out -- 'royal' has to
  -- be read off the unit while it is still there to read.
  v_check_pairs jsonb := '[]'::jsonb; v_pair jsonb; v_pi int;
  v_seat int; v_royal_dead boolean;
  v_has_units boolean; v_alive_seats int[]; v_win_seat int; v_seat_name text;
begin
  select * into m from public.royale_matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'active' then raise exception 'match is not running'; end if;
  v_st := m.state;
  if coalesce((v_st->>'turn')::int, -1) <> p_seat then raise exception 'not your turn'; end if;

  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then v_me := u; end if;
    if p_target is not null and u->>'id' = p_target then v_tgt := u; end if;
  end loop;
  if v_me is null then raise exception 'no such unit'; end if;
  if (v_me->>'owner')::int <> p_seat then raise exception 'that is not your unit'; end if;
  if (v_me->>'acted')::boolean then raise exception 'that unit already acted'; end if;
  if cn_stunned(v_me) then raise exception 'that unit is stunned'; end if;
  if cn_swamped(v_st, v_me) then raise exception 'that unit is in the swamp'; end if;
  v_me := cn_awake(v_st, v_me);

  v_kind := v_me->>'abilityKind';
  if v_kind is null then raise exception 'that unit has no ability'; end if;
  if v_kind in ('mist', 'summon') then
    raise exception 'that ability is not available in battle royale yet';
  end if;
  v_n := coalesce((v_me->>'abilityN')::int, 0);

  v_st := cn_begin_act_royale(v_st, p_seat, p_unit);
  v_seq := coalesce((v_st->'fx'->>'seq')::int, 0) + 1;

  if v_kind = 'aoe_adjacent' then
    for u in select * from jsonb_array_elements(v_st->'units') loop
      if u->>'id' <> p_unit
         and cn_cheb((v_me->>'x')::int, (v_me->>'y')::int,
                     (u->>'x')::int, (u->>'y')::int) = 1 then
        u := jsonb_set(u, '{hp}', to_jsonb((u->>'hp')::int - v_n));
        v_hits := v_hits || jsonb_build_object('id', u->>'id', 'dmg', v_n);
        v_swings := v_swings || jsonb_build_object(
          'k', 'hit', 'by', p_unit, 'at', u->>'id', 'dmg', v_n,
          'crit', false, 'counter', false, 'first', false, 'def', false, 'why', 'ability');
        if (u->>'hp')::int <= 0 then
          v_check_pairs := v_check_pairs || jsonb_build_object(
            'seat', (u->>'owner')::int, 'royal', coalesce((u->>'royal')::boolean, false));
        end if;
      end if;
      if (u->>'hp')::int > 0 then v_out := v_out || u; end if;
    end loop;
    for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
      if cn_cheb((v_me->>'x')::int, (v_me->>'y')::int, (e->>'x')::int, (e->>'y')::int) = 1 then
        e := jsonb_set(e, '{hp}', to_jsonb((e->>'hp')::int - v_n));
        v_felled := v_felled or (e->>'hp')::int <= 0;
      end if;
      if (e->>'hp')::int > 0 then v_rocks := v_rocks || e; end if;
    end loop;
    v_st := jsonb_set(v_st, '{obstacles}', v_rocks);
    v_note := (v_me->>'name') || ' strikes every tile around them for ' || v_n || '.';

  elsif v_kind = 'heal_any' then
    if v_tgt is null then raise exception 'that ability needs a target'; end if;
    v_dist := cn_cheb((v_me->>'x')::int, (v_me->>'y')::int, (v_tgt->>'x')::int, (v_tgt->>'y')::int);
    if v_dist > (v_me->>'rmax')::int then raise exception 'out of range'; end if;
    if not cn_los_clear(v_st, (v_me->>'x')::int, (v_me->>'y')::int,
                        (v_tgt->>'x')::int, (v_tgt->>'y')::int) then
      raise exception 'a tree is in the way';
    end if;
    for u in select * from jsonb_array_elements(v_st->'units') loop
      if u->>'id' = p_target then
        v_got := least((u->>'maxHp')::int - (u->>'hp')::int, v_n);
        u := jsonb_set(u, '{hp}', to_jsonb((u->>'hp')::int + v_got));
      end if;
      v_out := v_out || u;
    end loop;
    v_hits := jsonb_build_array(jsonb_build_object('id', p_target, 'heal', v_got));
    v_swings := jsonb_build_array(jsonb_build_object(
      'k', 'heal', 'by', p_unit, 'at', p_target, 'dmg', v_got,
      'crit', false, 'counter', false, 'first', false, 'def', false, 'why', 'mend'));
    v_note := (v_me->>'name') || ' mends ' || (v_tgt->>'name') || ' for ' || v_got || '.';

  elsif v_kind = 'poison_hit' then
    if v_tgt is null then raise exception 'that ability needs a target'; end if;
    if (v_tgt->>'owner')::int = p_seat then raise exception 'no friendly fire'; end if;
    v_dist := cn_cheb((v_me->>'x')::int, (v_me->>'y')::int, (v_tgt->>'x')::int, (v_tgt->>'y')::int);
    if v_dist > (v_me->>'rmax')::int then raise exception 'out of range'; end if;
    if not cn_los_clear(v_st, (v_me->>'x')::int, (v_me->>'y')::int,
                        (v_tgt->>'x')::int, (v_tgt->>'y')::int) then
      raise exception 'a tree is in the way';
    end if;
    for u in select * from jsonb_array_elements(v_st->'units') loop
      if u->>'id' = p_target then
        u := cn_afflict(u, 'poison', 'true'::jsonb);
        u := jsonb_set(u, '{hp}', to_jsonb((u->>'hp')::int - v_n));
        v_hits := v_hits || jsonb_build_object('id', u->>'id', 'dmg', v_n);
        v_swings := v_swings || jsonb_build_object(
          'k', 'hit', 'by', p_unit, 'at', u->>'id', 'dmg', v_n,
          'crit', false, 'counter', false, 'first', false, 'def', false, 'why', 'poison');
        if (u->>'hp')::int <= 0 then
          v_check_pairs := v_check_pairs || jsonb_build_object(
            'seat', (u->>'owner')::int, 'royal', coalesce((u->>'royal')::boolean, false));
        end if;
      end if;
      if (u->>'hp')::int > 0 then v_out := v_out || u; end if;
    end loop;
    v_note := (v_me->>'name') || ' poisons ' || (v_tgt->>'name') || '.';

  elsif v_kind = 'line_burn' then
    if v_tgt is null then raise exception 'that ability needs a target'; end if;
    v_dist := cn_cheb((v_me->>'x')::int, (v_me->>'y')::int, (v_tgt->>'x')::int, (v_tgt->>'y')::int);
    if v_dist > (v_me->>'rmax')::int then raise exception 'out of range'; end if;
    v_dx := sign((v_tgt->>'x')::int - (v_me->>'x')::int);
    v_dy := sign((v_tgt->>'y')::int - (v_me->>'y')::int);
    for u in select * from jsonb_array_elements(v_st->'units') loop
      if ((u->>'x')::int = (v_tgt->>'x')::int and (u->>'y')::int = (v_tgt->>'y')::int)
         or ((u->>'x')::int = (v_tgt->>'x')::int + v_dx
             and (u->>'y')::int = (v_tgt->>'y')::int + v_dy) then
        u := cn_afflict(u, 'burn', 'true'::jsonb);
        u := jsonb_set(u, '{hp}', to_jsonb((u->>'hp')::int - v_n));
        v_hits := v_hits || jsonb_build_object('id', u->>'id', 'dmg', v_n);
        v_swings := v_swings || jsonb_build_object(
          'k', 'hit', 'by', p_unit, 'at', u->>'id', 'dmg', v_n,
          'crit', false, 'counter', false, 'first', false, 'def', false, 'why', 'fire');
        if (u->>'hp')::int <= 0 then
          v_check_pairs := v_check_pairs || jsonb_build_object(
            'seat', (u->>'owner')::int, 'royal', coalesce((u->>'royal')::boolean, false));
        end if;
      end if;
      if (u->>'hp')::int > 0 then v_out := v_out || u; end if;
    end loop;
    v_note := (v_me->>'name') || ' sets two tiles alight for ' || v_n || '.';

  else
    raise exception 'that ability is not built yet: %', v_kind;
  end if;

  v_st := jsonb_set(v_st, '{units}', v_out);
  v_st := cn_end_act_royale(v_st, p_unit);
  v_st := state_log(v_st, v_note);
  if v_felled then v_st := state_log(v_st, 'A tree comes down.'); end if;

  v_st := jsonb_set(v_st, '{fx}', jsonb_build_object(
    'seq', v_seq, 'kind', 'ability', 'atk', p_unit, 'tgt', p_target,
    'why', v_kind, 'hits', v_hits, 'swings', v_swings,
    'dmg', 0, 'heal', 0, 'counter', 0, 'burnAtk', 0, 'burnTgt', 0,
    'killedTgt', false, 'killedAtk', false, 'newBurn', false,
    'cured', false, 'parry', false, 'tree', false), true);

  -- Same elimination + last-seat-standing check cn_attack_royale runs,
  -- checked against every unit an ability's blast dropped to zero rather
  -- than only two.
  for v_pi in 0 .. jsonb_array_length(v_check_pairs) - 1 loop
    v_pair := v_check_pairs -> v_pi;
    v_seat := (v_pair->>'seat')::int;
    continue when v_seat is null;
    continue when exists (
      select 1 from public.royale_players
       where match_id = p_match and seat = v_seat and eliminated);

    v_royal_dead := coalesce((v_pair->>'royal')::boolean, false);
    v_has_units := exists (
      select 1 from jsonb_array_elements(v_st->'units') q where (q->>'owner')::int = v_seat);

    if v_royal_dead or not v_has_units then
      if v_royal_dead and v_has_units then
        -- The crown fell: the rest of this seat's army disappears with it.
        v_st := jsonb_set(v_st, '{units}', (
          select coalesce(jsonb_agg(q), '[]'::jsonb)
            from jsonb_array_elements(v_st->'units') q
           where (q->>'owner')::int <> v_seat));
      end if;
      select username into v_seat_name from public.royale_players
       where match_id = p_match and seat = v_seat;
      update public.royale_players set eliminated = true, eliminated_at = now()
       where match_id = p_match and seat = v_seat;
      v_st := state_log(v_st,
        case when v_royal_dead then 'The crown falls. ' else '' end
        || coalesce(v_seat_name, 'Seat ' || v_seat) || ' is eliminated.');
    end if;
  end loop;

  select array_agg(seat) into v_alive_seats
    from public.royale_players where match_id = p_match and not eliminated;
  if coalesce(array_length(v_alive_seats, 1), 0) = 1 then
    v_win_seat := v_alive_seats[1];
    select username into v_seat_name from public.royale_players
     where match_id = p_match and seat = v_win_seat;
    v_st := jsonb_set(v_st, '{winnerSeat}', to_jsonb(v_win_seat));
    v_st := state_log(v_st, coalesce(v_seat_name, 'Seat ' || v_win_seat) || ' wins the battle royale.');
    update public.royale_matches
       set state = v_st, status = 'finished', winner_seat = v_win_seat,
           turn_deadline = null, updated_at = now()
     where id = m.id returning * into m;
    return m;
  end if;

  update public.royale_matches
     set state = v_st,
         turn_deadline = turn_deadline + (cn_cine_ms(v_swings) || ' milliseconds')::interval,
         updated_at = now()
   where id = m.id returning * into m;
  return m;
end
$$;

-- ---------------------------------------------------------------------------
-- submit_royale_* -- thin shells, exactly like the 1v1 submit_* family:
-- work out who you are, check the turn and the clock, delegate.
-- ---------------------------------------------------------------------------

create or replace function public.submit_royale_move(p_match uuid, p_unit text, p_x int, p_y int)
returns royale_matches language plpgsql security definer set search_path to 'public' as $$
declare m public.royale_matches; v_seat int;
begin
  select * into m from public.royale_matches where id = p_match;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'active' then raise exception 'match is not running'; end if;
  v_seat := royale_side_of(p_match);
  if v_seat is null then raise exception 'you are spectating this match'; end if;
  if coalesce((m.state->>'turn')::int, -1) <> v_seat then raise exception 'not your turn'; end if;
  if now() > m.turn_deadline + interval '2 seconds' then raise exception 'your time ran out'; end if;
  update public.royale_players set last_acted_turn = (m.state->>'turnNumber')::int
   where match_id = p_match and seat = v_seat;
  return cn_move_royale(p_match, v_seat, p_unit, p_x, p_y);
end
$$;

create or replace function public.submit_royale_attack(p_match uuid, p_unit text, p_target text)
returns royale_matches language plpgsql security definer set search_path to 'public' as $$
declare m public.royale_matches; v_seat int;
begin
  select * into m from public.royale_matches where id = p_match;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'active' then raise exception 'match is not running'; end if;
  v_seat := royale_side_of(p_match);
  if v_seat is null then raise exception 'you are spectating this match'; end if;
  if coalesce((m.state->>'turn')::int, -1) <> v_seat then raise exception 'not your turn'; end if;
  if now() > m.turn_deadline + interval '2 seconds' then raise exception 'your time ran out'; end if;
  update public.royale_players set last_acted_turn = (m.state->>'turnNumber')::int
   where match_id = p_match and seat = v_seat;

  m := cn_attack_royale(p_match, v_seat, p_unit, p_target);

  if m.status = 'active' and m.turn_deadline is not null then
    update public.royale_matches
       set turn_deadline = turn_deadline
             + (cn_cine_ms(m.state->'fx'->'swings') || ' milliseconds')::interval,
           state = m.state
     where id = m.id
     returning * into m;
  end if;
  return m;
end
$$;

create or replace function public.submit_royale_defend(p_match uuid, p_unit text)
returns royale_matches language plpgsql security definer set search_path to 'public' as $$
declare m public.royale_matches; v_seat int;
begin
  select * into m from public.royale_matches where id = p_match;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'active' then raise exception 'match is not running'; end if;
  v_seat := royale_side_of(p_match);
  if v_seat is null then raise exception 'you are spectating this match'; end if;
  if coalesce((m.state->>'turn')::int, -1) <> v_seat then raise exception 'not your turn'; end if;
  if now() > m.turn_deadline + interval '2 seconds' then raise exception 'your time ran out'; end if;
  update public.royale_players set last_acted_turn = (m.state->>'turnNumber')::int
   where match_id = p_match and seat = v_seat;
  return cn_defend_royale(p_match, v_seat, p_unit);
end
$$;

create or replace function public.submit_royale_ability(p_match uuid, p_unit text, p_target text)
returns royale_matches language plpgsql security definer set search_path to 'public' as $$
declare m public.royale_matches; v_seat int;
begin
  select * into m from public.royale_matches where id = p_match;
  if m.id is null then raise exception 'no such match'; end if;
  v_seat := royale_side_of(p_match);
  if v_seat is null then raise exception 'you are spectating this match'; end if;
  if now() > m.turn_deadline + interval '2 seconds' then raise exception 'your time ran out'; end if;
  update public.royale_players set last_acted_turn = (m.state->>'turnNumber')::int
   where match_id = p_match and seat = v_seat;
  return cn_ability_royale(p_match, v_seat, p_unit, p_target);
end
$$;

create or replace function public.submit_royale_wait(p_match uuid)
returns royale_matches language plpgsql security definer set search_path to 'public' as $$
declare m public.royale_matches; v_seat int; v_st jsonb; v_active text;
begin
  select * into m from public.royale_matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'active' then raise exception 'match is not running'; end if;
  v_seat := royale_side_of(p_match);
  if v_seat is null then raise exception 'you are spectating this match'; end if;
  if coalesce((m.state->>'turn')::int, -1) <> v_seat then raise exception 'not your turn'; end if;

  v_st := m.state;
  v_active := nullif(v_st->>'active', '');
  if v_active is null then return m; end if;
  v_st := cn_end_act_royale(v_st, v_active);
  update public.royale_matches set state = v_st, updated_at = now()
   where id = m.id returning * into m;
  return m;
end
$$;

create or replace function public.submit_royale_end_turn(p_match uuid)
returns royale_matches language plpgsql security definer set search_path to 'public' as $$
declare m public.royale_matches; v_seat int;
begin
  select * into m from public.royale_matches where id = p_match;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'active' then raise exception 'match is not running'; end if;
  v_seat := royale_side_of(p_match);
  if v_seat is null then raise exception 'you are spectating this match'; end if;
  if coalesce((m.state->>'turn')::int, -1) <> v_seat then raise exception 'not your turn'; end if;
  update public.royale_players set last_acted_turn = (m.state->>'turnNumber')::int
   where match_id = p_match and seat = v_seat;
  return advance_turn_royale(p_match, null);
end
$$;

-- ---------------------------------------------------------------------------
-- Chat, presence, cleanup
-- ---------------------------------------------------------------------------

create or replace function public.send_royale_message(p_match uuid, p_body text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := auth.uid(); v_name text;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select username into v_name from public.profiles where id = v_uid;
  if v_name is null then raise exception 'no profile'; end if;
  insert into public.royale_messages (match_id, user_id, username, body)
  values (p_match, v_uid, v_name, left(coalesce(p_body, ''), 500));
end
$$;

create or replace function public.touch_royale_match(p_match uuid)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  update public.royale_players set seen_at = now()
   where match_id = p_match and user_id = auth.uid();
end
$$;

create or replace function public.leave_royale_match(p_match uuid)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := auth.uid(); v_status text;
begin
  select status into v_status from public.royale_matches where id = p_match;
  if v_status is null then return; end if;
  if v_status = 'waiting' then
    delete from public.royale_players where match_id = p_match and user_id = v_uid;
    if not exists (select 1 from public.royale_players where match_id = p_match) then
      delete from public.royale_matches where id = p_match;
    end if;
  else
    -- Deployed or in battle: leaving does not forfeit a seat -- that is
    -- the separate AFK-rule work. Just stop counting this seat toward
    -- "still in the room" so a stale room can be swept later.
    update public.royale_players set seen_at = now() - interval '1 hour'
     where match_id = p_match and user_id = v_uid;
  end if;
end
$$;

create or replace function public.sweep_royale_matches()
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  delete from public.royale_matches m
   where m.status = 'waiting'
     and not exists (
       select 1 from public.royale_players p
        where p.match_id = m.id and p.seen_at > now() - presence_grace());
end
$$;

-- ---------------------------------------------------------------------------
-- Splice send_match_invite's '4p' branch, now that the royale schema
-- exists. Fetched fresh from production immediately before this migration
-- was written and spliced onto that exact body -- only the 'else' branch's
-- contents changed; everything else here is byte-for-byte what is already
-- live.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.send_match_invite(p_to uuid, p_mode text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_name text;
  m public.matches;
  v_t uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if p_to is null or p_to = v_uid then raise exception 'no such player'; end if;
  if p_mode not in ('1v1', '4p', 'tournament') then raise exception 'unknown match type'; end if;
  if not exists (select 1 from public.friends where user_id = v_uid and friend_id = p_to) then
    raise exception 'you can only invite a friend';
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
    -- 0048: the royale schema now exists. Same shape as the 1v1 branch
    -- above -- open a room, hand the code over as a notification -- except
    -- the room is a royale_matches row and the inviter is seated at 0 by
    -- create_royale_match() itself.
    declare
      v_rm public.royale_matches;
    begin
      v_rm := public.create_royale_match();
      perform public.cn_notify(p_to, 'match_invite', jsonb_build_object(
        'from_id', v_uid, 'from_username', v_name,
        'mode', '4p', 'match_id', v_rm.id, 'code', v_rm.code
      ));
      return v_rm.code;
    end;
  end if;
end $function$
;
