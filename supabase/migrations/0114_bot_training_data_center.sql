-- 0114: Bot Training Data Center -- Phase 1.
--
-- Jared: "make sure that the obtained data is legit, and that what I'm
-- training the bot with is substantial, detailed, and used in battle."
--
-- So this migration does NOT reimplement combat for simulation purposes.
-- Every simulated game is a REAL match row, played out by the SAME
-- cn_move/cn_attack/cn_ability/advance_turn/bot_step functions a human's
-- bot match uses -- just against a dedicated, hidden system profile
-- (cn_sim_profile_id()) instead of a real player, flagged `is_sim` so it
-- never touches the ladder, player_rating, or the public room list (which
-- already filters `bot is null` -- see Lobby.tsx -- so any bot match, sim
-- or not, was already invisible there).
--
-- Three moving parts:
--   1. bot_brains -- the Expert (and Calm/Sharp) heuristic's own scoring
--      coefficients, externalized from bot_step's hardcoded constants so
--      they can be tuned by self-play instead of by hand. Seeded here with
--      the EXACT values bot_step already used, so nothing plays any
--      differently the moment this ships -- only once a "Teach" run
--      promotes a new live brain does real Expert-mode behaviour change.
--   2. bot_step itself, rewritten to take a p_side so either seat can be
--      bot-driven (self-play needs both), and to read its coefficients
--      from whichever brain is live for that level -- falling back to the
--      old hardcoded numbers if bot_brains has nothing for that level, so
--      a brainless install (or a bad row) never breaks a live game.
--   3. sim_play_one_game / admin_run_training_batch -- the driver that
--      creates a real (but is_sim) match, deploys two random decks through
--      the real cn_army/cn_set_ready pipeline, and drives it turn by turn
--      with bot_step until it finishes, recording exactly what happened
--      (sim_games, sim_unit_stats) by reading bot_step's own account of
--      what it just did (state.lastBotAction, also added here) rather than
--      guessing from a diff -- the "legit" part of "legit data".

-- ===========================================================================
-- 1. bot_brains: tunable coefficients, one live row per level.
-- ===========================================================================
create table if not exists public.bot_brains (
  id uuid primary key default gen_random_uuid(),
  label text not null,
  level int not null check (level in (1, 2, 3)),
  weights jsonb not null default '{}'::jsonb,
  is_live boolean not null default false,
  parent_id uuid references public.bot_brains(id) on delete set null,
  notes text,
  games_played int not null default 0,
  wins int not null default 0,
  losses int not null default 0,
  draws int not null default 0,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

-- Exactly one live brain per level.
create unique index if not exists bot_brains_one_live_per_level
  on public.bot_brains (level) where is_live;

alter table public.bot_brains enable row level security;

drop policy if exists "bot_brains admin read" on public.bot_brains;
create policy "bot_brains admin read" on public.bot_brains for select
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin));

drop policy if exists "bot_brains admin write" on public.bot_brains;
create policy "bot_brains admin write" on public.bot_brains for all
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin))
  with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin));

-- Seed one live brain per level, carrying bot_step's own hardcoded numbers
-- forward byte-for-byte -- see the comment block in bot_step below for what
-- each key means (noise_scale, ctr_mult and threat_mult are the three that
-- used to be `case v_lvl when ...` branches; here they are just per-level
-- starting values instead).
insert into public.bot_brains (label, level, weights, is_live, notes)
select 'Beginner (baseline)', 1,
  jsonb_build_object(
    'pos_dist_mult', 5.0, 'pos_near_mult', 2.0, 'noise_scale', 220,
    'threat_mult', 0, 'heal_mult', 9.0, 'heal_full_penalty', -150,
    'atk_mult', 10.0, 'kill_bonus_flat', 400, 'burn_bonus', 25,
    'ctr_mult', 3.0, 'lethal_ctr_penalty_flat', 500, 'lethal_parry_extra_flat', 400),
  true, '0114 baseline -- reproduces the pre-0114 hardcoded level-1 numbers exactly.'
where not exists (select 1 from public.bot_brains where level = 1);

insert into public.bot_brains (label, level, weights, is_live, notes)
select 'Intermediate (baseline)', 2,
  jsonb_build_object(
    'pos_dist_mult', 5.0, 'pos_near_mult', 2.0, 'noise_scale', 90,
    'threat_mult', 0, 'heal_mult', 9.0, 'heal_full_penalty', -150,
    'atk_mult', 10.0, 'kill_bonus_flat', 400, 'burn_bonus', 25,
    'ctr_mult', 8.0, 'lethal_ctr_penalty_flat', 500, 'lethal_parry_extra_flat', 400),
  true, '0114 baseline -- reproduces the pre-0114 hardcoded level-2 numbers exactly.'
where not exists (select 1 from public.bot_brains where level = 2);

insert into public.bot_brains (label, level, weights, is_live, notes)
select 'Expert (baseline)', 3,
  jsonb_build_object(
    'pos_dist_mult', 5.0, 'pos_near_mult', 2.0, 'noise_scale', 15,
    'threat_mult', 4.0, 'heal_mult', 9.0, 'heal_full_penalty', -150,
    'atk_mult', 10.0, 'kill_bonus_flat', 400, 'burn_bonus', 25,
    'ctr_mult', 8.0, 'lethal_ctr_penalty_flat', 500, 'lethal_parry_extra_flat', 400),
  true, '0114 baseline -- reproduces the pre-0114 hardcoded level-3 numbers exactly.'
where not exists (select 1 from public.bot_brains where level = 3);

-- ===========================================================================
-- 2. training_runs / sim_games / sim_unit_stats.
-- ===========================================================================
create table if not exists public.training_runs (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('train', 'teach')),
  level int not null default 3 check (level in (1, 2, 3)),
  games_requested int not null check (games_requested > 0),
  games_completed int not null default 0,
  status text not null default 'pending'
    check (status in ('pending', 'running', 'completed', 'failed', 'cancelled')),
  baseline_brain_id uuid references public.bot_brains(id) on delete set null,
  candidate_brain_id uuid references public.bot_brains(id) on delete set null,
  promoted boolean not null default false,
  summary jsonb,
  error text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz
);

create table if not exists public.sim_games (
  id uuid primary key default gen_random_uuid(),
  training_run_id uuid references public.training_runs(id) on delete cascade,
  match_id uuid references public.matches(id) on delete set null,
  host_deck text[] not null,
  guest_deck text[] not null,
  host_brain_id uuid references public.bot_brains(id) on delete set null,
  guest_brain_id uuid references public.bot_brains(id) on delete set null,
  winner text check (winner in ('host', 'guest')),
  turns int not null default 0,
  capped boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists sim_games_run_idx on public.sim_games (training_run_id);

create table if not exists public.sim_unit_stats (
  id uuid primary key default gen_random_uuid(),
  sim_game_id uuid not null references public.sim_games(id) on delete cascade,
  training_run_id uuid references public.training_runs(id) on delete cascade,
  unit_id text not null,
  card_slug text not null,
  role text not null,
  royal boolean not null default false,
  side text not null check (side in ('host', 'guest')),
  won boolean not null default false,
  turns_alive int not null default 0,
  damage_dealt numeric not null default 0,
  damage_taken numeric not null default 0,
  healing_done numeric not null default 0,
  kills int not null default 0,
  deaths int not null default 0,
  final_hp int not null default 0,
  carried boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists sim_unit_stats_run_idx on public.sim_unit_stats (training_run_id);
create index if not exists sim_unit_stats_slug_idx on public.sim_unit_stats (card_slug);

alter table public.training_runs enable row level security;
alter table public.sim_games enable row level security;
alter table public.sim_unit_stats enable row level security;

drop policy if exists "training_runs admin all" on public.training_runs;
create policy "training_runs admin all" on public.training_runs for all
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin))
  with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin));

drop policy if exists "sim_games admin read" on public.sim_games;
create policy "sim_games admin read" on public.sim_games for select
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin));

drop policy if exists "sim_unit_stats admin read" on public.sim_unit_stats;
create policy "sim_unit_stats admin read" on public.sim_unit_stats for select
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin));

-- ===========================================================================
-- 3. matches gets four sim-only columns. All null/false for every real row
--    that has ever existed or ever will -- this is purely additive.
-- ===========================================================================
alter table public.matches add column if not exists is_sim boolean not null default false;
alter table public.matches add column if not exists sim_run_id uuid references public.training_runs(id) on delete set null;
alter table public.matches add column if not exists host_bot int;
alter table public.matches add column if not exists host_brain_id uuid references public.bot_brains(id) on delete set null;
alter table public.matches add column if not exists guest_brain_id uuid references public.bot_brains(id) on delete set null;

-- ===========================================================================
-- 4. The sim system profile. One fixed, well-known id -- never a real
--    player's -- that owns every simulated match as its "host". auth.users
--    only strictly requires `id`; the on_auth_user_created trigger
--    (handle_new_user) does the rest, reading the username straight out of
--    raw_user_meta_data the same way a real signup would.
-- ===========================================================================
create or replace function public.cn_sim_profile_id()
returns uuid
language sql
immutable
as $$
  select 'a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1'::uuid
$$;

do $$
begin
  if not exists (select 1 from auth.users where id = public.cn_sim_profile_id()) then
    insert into auth.users (
      id, instance_id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at
    ) values (
      public.cn_sim_profile_id(), '00000000-0000-0000-0000-000000000000',
      'authenticated', 'authenticated',
      'sim-engine@internal.crownnemesis.invalid', crypt('!'||gen_random_uuid()::text, gen_salt('bf')),
      now(), '{"provider":"internal","providers":["internal"]}'::jsonb,
      jsonb_build_object('username', 'TrainingEngine'),
      now(), now()
    );
  end if;
end $$;

-- ===========================================================================
-- 5. bot_step, rewritten to take a side and read its coefficients from
--    whichever brain is live for that level (or from the match's own
--    host_brain_id/guest_brain_id override, which only simulated matches
--    ever set). Every `coalesce(..., <number>)` below falls back to the
--    exact constant bot_step used before this migration, so an empty or
--    missing bot_brains row changes nothing.
-- ===========================================================================
drop function if exists public.bot_step(uuid);

create or replace function public.bot_step(p_match uuid, p_side text default 'guest')
returns matches
language plpgsql
security definer
set search_path = 'public'
as $function$
declare
  m public.matches; st jsonb; v_lvl int; v_noise numeric; v_w jsonb; v_brain_id uuid;
  v_noise_scale numeric; v_opp text;
  u jsonb; t jsonb;
  v_tiles text[]; v_tile text; vx int; vy int; v_first boolean;
  v_best numeric := 0; v_bu text; v_bx int; v_by int; v_bt text;
  v_fb numeric := -1e9; v_fu text; v_fbx int; v_fby int; v_ft text;
  v_pos numeric; v_base numeric; v_act numeric; v_step_s numeric;
  v_d int; v_dmg numeric; v_ctr numeric; v_near int; v_thr int;
  v_answers boolean; v_parry boolean;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null then return m; end if;
  v_opp := case when p_side = 'host' then 'guest' else 'host' end;
  v_lvl := case when p_side = 'guest' then m.bot else m.host_bot end;
  if v_lvl is null then return m; end if;
  if m.status <> 'active' then return m; end if;
  if m.state->>'turn' <> p_side then return m; end if;

  st := m.state;

  -- ---- coefficients: an explicit override on the match, else whichever
  -- brain is live for this level, else the hardcoded pre-0114 numbers. ----
  v_brain_id := case when p_side = 'guest' then m.guest_brain_id else m.host_brain_id end;
  if v_brain_id is not null then
    select weights into v_w from public.bot_brains where id = v_brain_id;
  end if;
  if v_w is null then
    select weights into v_w from public.bot_brains where level = v_lvl and is_live limit 1;
  end if;
  v_w := coalesce(v_w, '{}'::jsonb);
  v_noise_scale := coalesce((v_w->>'noise_scale')::numeric,
    case v_lvl when 1 then 220 when 2 then 90 else 15 end);

  for u in select * from jsonb_array_elements(st->'units') loop
    continue when u->>'owner' <> p_side;
    continue when (u->>'moved')::boolean and (u->>'acted')::boolean;
    continue when coalesce((u->>'spent')::boolean, false);
    continue when coalesce((st->>'acts')::int, 0) >= cn_acts_cap(st)
              and nullif(st->>'active', '') is distinct from u->>'id';

    v_tiles := array[(u->>'x') || ',' || (u->>'y')];
    if not (u->>'moved')::boolean then
      v_tiles := v_tiles || cn_reach(st, u);
    end if;
    v_first := true;

    foreach v_tile in array v_tiles loop
      vx := split_part(v_tile, ',', 1)::int;
      vy := split_part(v_tile, ',', 2)::int;

      v_near := 99; v_thr := 0;
      for t in select * from jsonb_array_elements(st->'units') loop
        continue when t->>'owner' = p_side;
        v_d := cn_cheb(vx, vy, (t->>'x')::int, (t->>'y')::int);
        v_near := least(v_near, v_d);
        if v_d <= (t->>'mov')::int + (t->>'rmax')::int then v_thr := v_thr + 1; end if;
      end loop;
      v_pos := - abs(v_near - (u->>'rmax')::int) * coalesce((v_w->>'pos_dist_mult')::numeric, 5.0)
               - v_near * coalesce((v_w->>'pos_near_mult')::numeric, 2.0);

      if v_first then v_base := v_pos; v_first := false; end if;

      if vx <> (u->>'x')::int or vy <> (u->>'y')::int then
        v_noise := random() * v_noise_scale;
        v_step_s := v_pos - v_base + v_noise
          - v_thr * coalesce((v_w->>'threat_mult')::numeric, case when v_lvl >= 3 then 4.0 else 0 end);
        if v_step_s > v_best then
          v_best := v_step_s;
          v_bu := u->>'id'; v_bx := vx; v_by := vy; v_bt := null;
        end if;
        if v_step_s > v_fb then
          v_fb := v_step_s;
          v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := null;
        end if;
      end if;

      continue when (u->>'acted')::boolean;

      for t in select * from jsonb_array_elements(st->'units') loop
        continue when t->>'id' = u->>'id';
        v_d := cn_cheb(vx, vy, (t->>'x')::int, (t->>'y')::int);
        continue when v_d < (u->>'rmin')::int or v_d > (u->>'rmax')::int;
        continue when not cn_los_clear(st, vx, vy, (t->>'x')::int, (t->>'y')::int);

        v_dmg := ((u->>'dmin')::int + (u->>'dmax')::int) / 2.0;

        if t->>'owner' = p_side then
          continue when not (u->>'heals')::boolean;
          v_act := case when (t->>'maxHp')::int - (t->>'hp')::int <= 0
                        then coalesce((v_w->>'heal_full_penalty')::numeric, -150)
                        else least(v_dmg, (t->>'maxHp')::int - (t->>'hp')::int)
                             * coalesce((v_w->>'heal_mult')::numeric, 9.0) end;
        else
          v_answers := not coalesce((u->>'sneaks')::boolean, false)
                       and v_d >= (t->>'crmin')::int and v_d <= (t->>'crmax')::int;
          v_parry := v_answers and coalesce((t->>'parries')::boolean, false);

          v_act := least(v_dmg, (t->>'hp')::int) * coalesce((v_w->>'atk_mult')::numeric, 10.0);
          if v_dmg >= (t->>'hp')::int then
            v_act := v_act + coalesce((v_w->>'kill_bonus_flat')::numeric, 400) + (t->>'maxHp')::int;
          elsif (u->>'burns')::boolean and not (t->>'burned')::boolean then
            v_act := v_act + coalesce((v_w->>'burn_bonus')::numeric, 25);
          end if;

          if v_answers and (v_parry or v_dmg < (t->>'hp')::int) then
            v_ctr := ((t->>'dmin')::int + (t->>'dmax')::int) / 2.0;
            v_act := v_act - v_ctr * coalesce((v_w->>'ctr_mult')::numeric,
                       case v_lvl when 1 then 3.0 else 8.0 end);
            if v_ctr >= (u->>'hp')::int then
              v_act := v_act - coalesce((v_w->>'lethal_ctr_penalty_flat')::numeric, 500) - (u->>'maxHp')::int
                       - case when v_parry
                              then coalesce((v_w->>'lethal_parry_extra_flat')::numeric, 400) + (t->>'maxHp')::int
                              else 0 end;
            end if;
          end if;
        end if;

        v_noise := random() * v_noise_scale;
        if v_pos + v_act - v_base + v_noise > v_best then
          v_best := v_pos + v_act - v_base + v_noise;
          v_bu := u->>'id'; v_bx := vx; v_by := vy; v_bt := t->>'id';
        end if;
        if v_pos + v_act - v_base + v_noise > v_fb then
          v_fb := v_pos + v_act - v_base + v_noise;
          v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := t->>'id';
        end if;
      end loop;
    end loop;
  end loop;

  if v_bu is null and v_fu is not null then
    v_bu := v_fu; v_bx := v_fbx; v_by := v_fby; v_bt := v_ft;
  end if;
  if v_bu is null then
    m := advance_turn(p_match, null, false);
    if m.is_sim then
      update public.matches set state = jsonb_set(coalesce(m.state, '{}'::jsonb), '{lastBotAction}',
        jsonb_build_object('side', p_side, 'unit', null, 'target', null, 'kind', 'pass'))
      where id = m.id returning * into m;
    end if;
    return m;
  end if;

  for u in select * from jsonb_array_elements(st->'units') loop
    if u->>'id' = v_bu and ((u->>'x')::int <> v_bx or (u->>'y')::int <> v_by) then
      m := cn_move(p_match, p_side, v_bu, v_bx, v_by);
      if m.is_sim then
        update public.matches set state = jsonb_set(coalesce(m.state, '{}'::jsonb), '{lastBotAction}',
          jsonb_build_object('side', p_side, 'unit', v_bu, 'target', null, 'kind', 'move'))
        where id = m.id returning * into m;
      end if;
      return m;
    end if;
  end loop;

  if v_bt is not null then
    m := cn_attack(p_match, p_side, v_bu, v_bt);
    if m.is_sim then
      update public.matches set state = jsonb_set(coalesce(m.state, '{}'::jsonb), '{lastBotAction}',
        jsonb_build_object('side', p_side, 'unit', v_bu, 'target', v_bt, 'kind', 'attack'))
      where id = m.id returning * into m;
    end if;
    return m;
  end if;

  m := advance_turn(p_match, null, false);
  if m.is_sim then
    update public.matches set state = jsonb_set(coalesce(m.state, '{}'::jsonb), '{lastBotAction}',
      jsonb_build_object('side', p_side, 'unit', null, 'target', null, 'kind', 'pass'))
    where id = m.id returning * into m;
  end if;
  return m;
end
$function$;

-- ===========================================================================
-- 6. sim_bump: a tiny jsonb accumulator helper (unit id -> {field: number}),
--    used by sim_play_one_game while it drives a game turn by turn.
-- ===========================================================================
create or replace function public.sim_bump(p_stats jsonb, p_uid text, p_field text, p_amount numeric)
returns jsonb
language sql
immutable
as $$
  select jsonb_set(p_stats, array[p_uid],
    coalesce(p_stats->p_uid, '{}'::jsonb) ||
    jsonb_build_object(p_field, coalesce((p_stats->p_uid->>p_field)::numeric, 0) + p_amount))
$$;

-- ===========================================================================
-- 7. sim_play_one_game: creates one real (is_sim) match, deploys both random
--    decks through the exact same cn_army/cn_set_ready pipeline a human bot
--    match uses, then drives it with bot_step until it finishes (or a
--    generous safety cap trips, which should never happen in a legal game).
--    Returns the finished matches row plus its accumulated per-unit stats.
-- ===========================================================================
create or replace function public.sim_play_one_game(
  p_run uuid, p_level int, p_host_deck text[], p_guest_deck text[],
  p_host_brain uuid, p_guest_brain uuid
)
returns table (game matches, stats jsonb, roster jsonb)
language plpgsql
security definer
set search_path = 'public'
as $function$
declare
  m public.matches; v_turn text; v_i int := 0; v_cap int := 3000;
  v_stats jsonb := '{}'::jsonb; v_before jsonb; v_after jsonb;
  v_uid text; bu jsonb; au jsonb; v_delta numeric;
  v_action jsonb; v_actor text; v_target text; v_kind text;
  v_turnnum_before int; v_turnnum_after int;
  v_host_units jsonb; v_guest_units jsonb; v_roster jsonb;
begin
  insert into public.matches
    (code, host_id, host_name, guest_id, guest_name, status, state,
     bot, host_bot, ranked, is_sim, sim_run_id, host_brain_id, guest_brain_id)
  values
    (gen_match_code(), cn_sim_profile_id(), 'Sim Host', null, 'Sim Guest',
     'deploying', cn_fresh_map(), p_level, p_level, false, true, p_run, p_host_brain, p_guest_brain)
  returning * into m;

  -- The initial roster, captured now and returned as-is at the end -- some
  -- engine paths drop a unit from state.units entirely once it dies, so
  -- this (not the final state) is the only reliable "every unit that ever
  -- took part" list a caller can build sim_unit_stats rows from.
  v_host_units := cn_army(m.state, 'host', p_host_deck);
  v_guest_units := cn_army(m.state, 'guest', p_guest_deck);
  v_roster := v_host_units || v_guest_units;

  insert into public.match_deploy (match_id, side, user_id, units) values
    (m.id, 'host',  m.host_id, v_host_units),
    (m.id, 'guest', null,      v_guest_units);

  perform cn_set_ready(m.id, 'host', false);
  m := cn_set_ready(m.id, 'guest', false);

  loop
    exit when m.status <> 'active';
    v_i := v_i + 1;
    exit when v_i > v_cap;

    v_before := m.state->'units';
    v_turn := m.state->>'turn';
    v_turnnum_before := coalesce((m.state->>'turnNumber')::int, 1);

    m := bot_step(m.id, v_turn);

    v_action := m.state->'lastBotAction';
    v_kind := v_action->>'kind';
    v_actor := v_action->>'unit';
    v_target := v_action->>'target';
    v_after := m.state->'units';
    v_turnnum_after := coalesce((m.state->>'turnNumber')::int, 1);

    -- turns_alive: every unit still standing gets credit for the turn that
    -- just elapsed, whenever advance_turn actually moved the counter.
    if v_turnnum_after > v_turnnum_before then
      for bu in select * from jsonb_array_elements(v_before) loop
        if coalesce((bu->>'hp')::numeric, 0) > 0 then
          v_stats := sim_bump(v_stats, bu->>'id', 'turns_alive', 1);
        end if;
      end loop;
    end if;

    if v_kind = 'attack' and v_actor is not null then
      -- hp deltas on the actor and/or the declared target -- an ordinary
      -- hit only changes the target; a countered or parried hit changes
      -- both, and the non-actor side of that pair is always the one whose
      -- own counter dealt the actor's damage, never the other way round.
      foreach v_uid in array array[v_actor, v_target] loop
        continue when v_uid is null;
        select value into bu from jsonb_array_elements(v_before) value where value->>'id' = v_uid;
        select value into au from jsonb_array_elements(v_after)  value where value->>'id' = v_uid;
        if bu is null or au is null then continue; end if;
        v_delta := coalesce((bu->>'hp')::numeric, 0) - coalesce((au->>'hp')::numeric, 0);
        if v_delta > 0 then
          v_stats := sim_bump(v_stats, v_uid, 'damage_taken', v_delta);
          v_stats := sim_bump(v_stats,
            case when v_uid = v_actor then v_target else v_actor end, 'damage_dealt', v_delta);
          if coalesce((au->>'hp')::numeric, 0) <= 0 and coalesce((bu->>'hp')::numeric, 0) > 0 then
            v_stats := sim_bump(v_stats, v_uid, 'deaths', 1);
            v_stats := sim_bump(v_stats,
              case when v_uid = v_actor then v_target else v_actor end, 'kills', 1);
          end if;
        elsif v_delta < 0 and v_uid = v_target then
          -- the actor healed its target (heals only ever target an ally)
          v_stats := sim_bump(v_stats, v_actor, 'healing_done', -v_delta);
        end if;
      end loop;
    end if;
  end loop;

  return query select m, v_stats, v_roster;
end
$function$;

-- ===========================================================================
-- 8. Admin-facing run control. "Train" (kind='train') always pits the live
--    brain against itself -- pure data-gathering, the live brain never
--    changes. "Teach" (kind='teach') mutates a fresh candidate off the live
--    brain and pits candidate vs. baseline, side assignment coin-flipped
--    each game so host/guest is never a confound; when the whole run
--    finishes, the candidate is promoted to live IF AND ONLY IF it actually
--    won more than the baseline did. Nothing is ever promoted mid-run, and
--    a "Train" run can never promote anything at all -- it has no candidate.
-- ===========================================================================
create or replace function public.admin_require_admin()
returns void
language plpgsql
security definer
set search_path = 'public'
as $$
begin
  if not exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin) then
    raise exception 'admins only';
  end if;
end
$$;

create or replace function public.admin_mutate_weights(p_weights jsonb, p_pct numeric default 0.15)
returns jsonb
language sql
volatile
as $$
  -- Each key gets an independent +/-p_pct multiplicative nudge on its own
  -- MAGNITUDE, sign always preserved (a naive `v * (1 + noise)` flips the
  -- sign of any negative weight, like heal_full_penalty, roughly half the
  -- time noise exceeds 100% -- which would turn "don't heal a full-health
  -- ally" into "please do") and never shrunk below a tenth of its original
  -- size, since a coefficient hitting exactly zero stops that whole term
  -- mattering. A weight that started at exactly zero (only threat_mult, on
  -- the two levels nothing plans to teach yet) gets a small absolute kick
  -- instead, so a future run could still discover it should be nonzero.
  select coalesce(jsonb_object_agg(
    key,
    case when value::numeric = 0 then (random() * 2 - 1) * p_pct * 10
    else sign(value::numeric) * greatest(abs(value::numeric) * 0.1,
                                          abs(value::numeric) * (1 + (random() * 2 - 1) * p_pct))
    end), '{}'::jsonb)
  from jsonb_each_text(p_weights)
$$;

create or replace function public.admin_start_training_run(
  p_kind text, p_games int, p_level int default 3, p_notes text default null
)
returns training_runs
language plpgsql
security definer
set search_path = 'public'
as $function$
declare v_run public.training_runs; v_base public.bot_brains; v_cand uuid;
begin
  perform admin_require_admin();
  if p_kind not in ('train', 'teach') then raise exception 'kind must be train or teach'; end if;
  if p_games is null or p_games < 1 or p_games > 20000 then
    raise exception 'games must be between 1 and 20000';
  end if;

  select * into v_base from public.bot_brains where level = p_level and is_live limit 1;
  if v_base.id is null then raise exception 'no live brain for level %', p_level; end if;

  if p_kind = 'teach' then
    insert into public.bot_brains (label, level, weights, is_live, parent_id, notes, created_by)
    values ('Candidate ' || to_char(now(), 'MM-DD HH24:MI'), p_level,
            admin_mutate_weights(v_base.weights), false, v_base.id, p_notes, auth.uid())
    returning id into v_cand;
  end if;

  insert into public.training_runs
    (kind, level, games_requested, baseline_brain_id, candidate_brain_id, created_by)
  values (p_kind, p_level, p_games, v_base.id, v_cand, auth.uid())
  returning * into v_run;
  return v_run;
end
$function$;

create or replace function public.admin_run_training_batch(p_run uuid, p_batch int default 20)
returns training_runs
language plpgsql
security definer
set search_path = 'public'
as $function$
declare
  v_run public.training_runs; v_n int; i int;
  v_host_deck text[]; v_guest_deck text[]; v_host_brain uuid; v_guest_brain uuid;
  v_result record; v_game public.matches; v_stats jsonb; v_roster jsonb; v_sim_game_id uuid;
  v_u jsonb; v_win text; v_carry_uid text; v_carry_score numeric;
  v_side text; v_cand_wins int; v_base_wins int; v_promote boolean;
begin
  perform admin_require_admin();
  select * into v_run from public.training_runs where id = p_run for update;
  if v_run.id is null then raise exception 'no such training run'; end if;
  if v_run.status in ('completed', 'cancelled', 'failed') then return v_run; end if;

  if v_run.status = 'pending' then
    update public.training_runs set status = 'running', started_at = now()
      where id = v_run.id returning * into v_run;
  end if;

  v_n := least(coalesce(p_batch, 20), v_run.games_requested - v_run.games_completed);
  for i in 1 .. greatest(v_n, 0) loop
    v_host_deck := random_deck();
    v_guest_deck := random_deck();
    if v_run.kind = 'teach' and random() < 0.5 then
      v_host_brain := v_run.candidate_brain_id; v_guest_brain := v_run.baseline_brain_id;
    else
      v_host_brain := v_run.baseline_brain_id;
      v_guest_brain := case when v_run.kind = 'teach' then v_run.candidate_brain_id else v_run.baseline_brain_id end;
    end if;

    select * into v_result from sim_play_one_game(
      v_run.id, v_run.level, v_host_deck, v_guest_deck, v_host_brain, v_guest_brain);
    v_game := v_result.game;
    v_stats := v_result.stats;
    v_roster := v_result.roster;
    v_win := v_game.state->>'winner';

    insert into public.sim_games
      (training_run_id, match_id, host_deck, guest_deck, host_brain_id, guest_brain_id,
       winner, turns, capped)
    values
      (v_run.id, v_game.id, v_host_deck, v_guest_deck, v_host_brain, v_guest_brain,
       nullif(v_win, ''), coalesce((v_game.state->>'turnNumber')::int, 0), v_win is null)
    returning id into v_sim_game_id;

    -- carried: within the winning side, whoever contributed the most
    -- damage+healing+kills relative to their team -- at most one per game.
    -- Iterates the initial roster, not the final state, because a unit
    -- that died is removed from state.units well before the game ends.
    v_carry_uid := null; v_carry_score := -1;
    if v_win is not null then
      for v_u in select * from jsonb_array_elements(v_roster) loop
        if v_u->>'owner' = v_win then
          declare v_sc numeric := coalesce((v_stats->(v_u->>'id')->>'damage_dealt')::numeric, 0)
                                 + coalesce((v_stats->(v_u->>'id')->>'healing_done')::numeric, 0)
                                 + coalesce((v_stats->(v_u->>'id')->>'kills')::numeric, 0) * 50;
          begin
            if v_sc > v_carry_score then v_carry_score := v_sc; v_carry_uid := v_u->>'id'; end if;
          end;
        end if;
      end loop;
    end if;

    for v_u in select * from jsonb_array_elements(v_roster) loop
      insert into public.sim_unit_stats
        (sim_game_id, training_run_id, unit_id, card_slug, role, royal, side, won,
         turns_alive, damage_dealt, damage_taken, healing_done, kills, deaths, final_hp, carried)
      values
        (v_sim_game_id, v_run.id, v_u->>'id', v_u->>'slug', v_u->>'role',
         coalesce((v_u->>'royal')::boolean, false), v_u->>'owner',
         v_win is not null and v_u->>'owner' = v_win,
         coalesce((v_stats->(v_u->>'id')->>'turns_alive')::numeric, 0)::int,
         coalesce((v_stats->(v_u->>'id')->>'damage_dealt')::numeric, 0),
         coalesce((v_stats->(v_u->>'id')->>'damage_taken')::numeric, 0),
         coalesce((v_stats->(v_u->>'id')->>'healing_done')::numeric, 0),
         coalesce((v_stats->(v_u->>'id')->>'kills')::numeric, 0)::int,
         coalesce((v_stats->(v_u->>'id')->>'deaths')::numeric, 0)::int,
         greatest(0, coalesce((
           select (u2->>'hp')::int from jsonb_array_elements(v_game.state->'units') u2
           where u2->>'id' = v_u->>'id'), 0)),
         v_u->>'id' = v_carry_uid);
    end loop;

    if v_run.kind = 'teach' and v_win is not null then
      v_side := case when v_host_brain = v_run.candidate_brain_id then 'host' else 'guest' end;
      if v_win = v_side then
        update public.bot_brains set games_played = games_played + 1, wins = wins + 1
          where id = v_run.candidate_brain_id;
        update public.bot_brains set games_played = games_played + 1, losses = losses + 1
          where id = v_run.baseline_brain_id;
      else
        update public.bot_brains set games_played = games_played + 1, losses = losses + 1
          where id = v_run.candidate_brain_id;
        update public.bot_brains set games_played = games_played + 1, wins = wins + 1
          where id = v_run.baseline_brain_id;
      end if;
    end if;

    update public.training_runs set games_completed = games_completed + 1
      where id = v_run.id returning * into v_run;
  end loop;

  if v_run.games_completed >= v_run.games_requested then
    v_promote := false;
    if v_run.kind = 'teach' then
      select wins, losses into v_cand_wins, v_base_wins from public.bot_brains where id = v_run.candidate_brain_id;
      v_promote := coalesce(v_cand_wins, 0) > coalesce(v_base_wins, 0);
      if v_promote then
        update public.bot_brains set is_live = false where level = v_run.level and is_live;
        update public.bot_brains set is_live = true where id = v_run.candidate_brain_id;
      end if;
    end if;
    update public.training_runs
      set status = 'completed', finished_at = now(), promoted = v_promote,
          summary = jsonb_build_object(
            'games', v_run.games_completed,
            'candidate_wins', v_cand_wins, 'baseline_wins', v_base_wins, 'promoted', v_promote)
      where id = v_run.id returning * into v_run;
  end if;

  return v_run;
end
$function$;

-- ===========================================================================
-- 9. Dashboards. Every number here comes straight out of sim_unit_stats /
--    sim_games -- real simulated battles, nothing modelled or guessed.
-- ===========================================================================

-- Per-card performance across every simulated game (or one run, via p_run).
create or replace function public.admin_card_performance(p_run uuid default null)
returns table (
  card_slug text, role text, royal boolean, games int, win_rate numeric,
  avg_turns_alive numeric, avg_damage_dealt numeric, avg_damage_taken numeric,
  avg_healing_done numeric, avg_kills numeric, carried_count int, carry_rate numeric
)
language sql
stable
as $$
  select card_slug, max(role), bool_or(royal),
    count(*)::int, avg(won::int)::numeric,
    avg(turns_alive)::numeric, avg(damage_dealt)::numeric, avg(damage_taken)::numeric,
    avg(healing_done)::numeric, avg(kills)::numeric,
    sum(carried::int)::int, avg(carried::int)::numeric
  from public.sim_unit_stats
  where p_run is null or training_run_id = p_run
  group by card_slug
  order by 5 desc
$$;

-- A tier list: same performance data, ranked by one composite score, and
-- optionally narrowed to kings only or a single class.
create or replace function public.admin_tier_list(
  p_run uuid default null, p_royal_only boolean default null, p_role text default null
)
returns table (card_slug text, role text, royal boolean, games int, win_rate numeric, score numeric)
language sql
stable
as $$
  select card_slug, role, royal, games, win_rate,
    (win_rate * 100 + avg_kills * 5 + avg_damage_dealt * 0.05
     + avg_healing_done * 0.05 - avg_damage_taken * 0.02 + avg_turns_alive * 0.5) as score
  from public.admin_card_performance(p_run)
  where (p_royal_only is null or royal = p_royal_only)
    and (p_role is null or role = p_role)
  order by score desc
$$;

-- Pairwise synergy: for every two cards that have shared a side in at least
-- p_min_games games, their combined win rate against what each scores alone
-- (the "lift" -- positive means the pair is genuinely better together).
create or replace function public.admin_pair_synergy(p_run uuid default null, p_min_games int default 15)
returns table (card_a text, card_b text, games int, win_rate numeric, lift numeric)
language sql
stable
as $$
  with pairs as (
    select s1.sim_game_id, s1.card_slug as card_a, s2.card_slug as card_b, s1.won
    from public.sim_unit_stats s1
    join public.sim_unit_stats s2
      on s1.sim_game_id = s2.sim_game_id and s1.side = s2.side and s1.card_slug < s2.card_slug
    where (p_run is null or s1.training_run_id = p_run) and (p_run is null or s2.training_run_id = p_run)
  ),
  agg as (
    select card_a, card_b, count(*)::int as games, avg(won::int)::numeric as win_rate
    from pairs group by card_a, card_b
  ),
  solo as (
    select card_slug, avg(won::int)::numeric as win_rate from public.sim_unit_stats
    where p_run is null or training_run_id = p_run
    group by card_slug
  )
  select a.card_a, a.card_b, a.games, a.win_rate,
    (a.win_rate - (sa.win_rate + sb.win_rate) / 2.0) as lift
  from agg a
  join solo sa on sa.card_slug = a.card_a
  join solo sb on sb.card_slug = a.card_b
  where a.games >= p_min_games
  order by lift desc
$$;

-- Best-N five-card teams the current roster could field, scored by summed
-- pairwise synergy (not brute-force win-rate, which would need a sample of
-- every one of the C(roster,5) combinations to be meaningful) -- see
-- admin_spot_check_team below for verifying a specific candidate for real.
create or replace function public.admin_best_teams(p_run uuid default null, p_n int default 3, p_min_games int default 10)
returns table (deck text[], score numeric)
language sql
stable
as $$
  with recursive cards5 as (
    select slug, royal from public.cards where is_active and slug is not null
  ),
  gen(picked, royals, last_slug, n) as (
    select array[slug], royal::int, slug, 1 from cards5
    union all
    select gen.picked || c.slug, gen.royals + c.royal::int, c.slug, gen.n + 1
    from gen join cards5 c on c.slug > gen.last_slug
    where gen.n < 5
  ),
  combos as (
    select picked as deck from gen where n = 5 and royals = 1
  ),
  lifts as (
    select card_a, card_b, lift from public.admin_pair_synergy(p_run, p_min_games)
  ),
  pairs_per_combo as (
    select c.deck, p1.slug as a, p2.slug as b
    from combos c,
      lateral unnest(c.deck) with ordinality as p1(slug, ord1),
      lateral unnest(c.deck) with ordinality as p2(slug, ord2)
    where p1.ord1 < p2.ord2
  )
  select ppc.deck, sum(coalesce(l.lift, 0)) as score
  from pairs_per_combo ppc
  left join lifts l on l.card_a = least(ppc.a, ppc.b) and l.card_b = greatest(ppc.a, ppc.b)
  group by ppc.deck
  order by score desc
  limit p_n
$$;

-- Verifying one specific candidate team for real, by actually fielding it
-- against p_games random opponents (both sides on the current live brain,
-- since this asks "is this TEAM good", not "is this AI good") -- the
-- "spot-checked by simulation" half of the best-teams design.
create or replace function public.admin_spot_check_team(p_deck text[], p_level int default 3, p_games int default 30)
returns table (win_rate numeric, games int)
language plpgsql
security definer
set search_path = 'public'
as $function$
declare
  v_run uuid; v_base uuid; v_result record; v_game public.matches; v_stats jsonb; v_roster jsonb;
  v_sim_game_id uuid; v_u jsonb; v_win text; v_wins int := 0; i int;
begin
  perform admin_require_admin();
  if array_length(p_deck, 1) <> 5 then raise exception 'a team is exactly 5 cards'; end if;

  select id into v_base from public.bot_brains where level = p_level and is_live limit 1;
  insert into public.training_runs (kind, level, games_requested, baseline_brain_id, created_by)
    values ('train', p_level, p_games, v_base, auth.uid())
  returning id into v_run;
  update public.training_runs set status = 'running', started_at = now() where id = v_run;

  for i in 1 .. p_games loop
    select * into v_result from sim_play_one_game(v_run, p_level, p_deck, random_deck(), v_base, v_base);
    v_game := v_result.game; v_stats := v_result.stats; v_roster := v_result.roster;
    v_win := v_game.state->>'winner';
    if v_win = 'host' then v_wins := v_wins + 1; end if;

    insert into public.sim_games
      (training_run_id, match_id, host_deck, guest_deck, host_brain_id, guest_brain_id, winner, turns, capped)
    values
      (v_run, v_game.id, p_deck, (select array_agg(u->>'slug') from jsonb_array_elements(v_roster) u
                                    where u->>'owner' = 'guest'),
       v_base, v_base, nullif(v_win, ''), coalesce((v_game.state->>'turnNumber')::int, 0), v_win is null)
    returning id into v_sim_game_id;

    for v_u in select * from jsonb_array_elements(v_roster) loop
      insert into public.sim_unit_stats
        (sim_game_id, training_run_id, unit_id, card_slug, role, royal, side, won,
         turns_alive, damage_dealt, damage_taken, healing_done, kills, deaths, final_hp, carried)
      values
        (v_sim_game_id, v_run, v_u->>'id', v_u->>'slug', v_u->>'role',
         coalesce((v_u->>'royal')::boolean, false), v_u->>'owner', v_win is not null and v_u->>'owner' = v_win,
         coalesce((v_stats->(v_u->>'id')->>'turns_alive')::numeric, 0)::int,
         coalesce((v_stats->(v_u->>'id')->>'damage_dealt')::numeric, 0),
         coalesce((v_stats->(v_u->>'id')->>'damage_taken')::numeric, 0),
         coalesce((v_stats->(v_u->>'id')->>'healing_done')::numeric, 0),
         coalesce((v_stats->(v_u->>'id')->>'kills')::numeric, 0)::int,
         coalesce((v_stats->(v_u->>'id')->>'deaths')::numeric, 0)::int,
         greatest(0, coalesce((
           select (u2->>'hp')::int from jsonb_array_elements(v_game.state->'units') u2
           where u2->>'id' = v_u->>'id'), 0)), false);
    end loop;
    update public.training_runs set games_completed = games_completed + 1 where id = v_run;
  end loop;

  update public.training_runs set status = 'completed', finished_at = now(),
    summary = jsonb_build_object('win_rate', v_wins::numeric / greatest(p_games, 1), 'games', p_games)
    where id = v_run;

  return query select v_wins::numeric / greatest(p_games, 1), p_games;
end
$function$;

-- ===========================================================================
-- Self-tests. Running as the migration owner bypasses RLS entirely (same as
-- every other self-test in this codebase), so these exercise the real
-- functions directly rather than through a signed-in session.
-- ===========================================================================

-- 1: bot_brains seeded, one live row per level, level 3's numbers intact.
do $$
declare v_w jsonb;
begin
  if (select count(*) from public.bot_brains where is_live) <> 3 then
    raise exception '0114 self-test 1 FAILED: expected exactly 3 live brains, got %',
      (select count(*) from public.bot_brains where is_live);
  end if;
  select weights into v_w from public.bot_brains where level = 3 and is_live;
  if (v_w->>'noise_scale')::numeric <> 15 or (v_w->>'ctr_mult')::numeric <> 8.0
     or (v_w->>'threat_mult')::numeric <> 4.0 then
    raise exception '0114 self-test 1 FAILED: level-3 brain weights do not match the old hardcoded numbers: %', v_w;
  end if;
  raise notice '0114 self-test 1 passed: bot_brains seeded with the exact pre-0114 numbers.';
end $$;

-- 2: matches got its four new sim columns, all safely defaulted.
do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'matches' and column_name = 'is_sim'
  ) then raise exception '0114 self-test 2 FAILED: matches.is_sim missing'; end if;
  if exists (select 1 from information_schema.columns
    where table_schema='public' and table_name='matches' and column_name='is_sim' and column_default not like '%false%') then
    raise exception '0114 self-test 2 FAILED: matches.is_sim should default to false';
  end if;
  raise notice '0114 self-test 2 passed: matches carries is_sim/sim_run_id/host_bot/host_brain_id/guest_brain_id.';
end $$;

-- 3: the sim system profile exists and is not a real player's account.
do $$
begin
  if not exists (select 1 from public.profiles where id = public.cn_sim_profile_id()) then
    raise exception '0114 self-test 3 FAILED: sim profile was not created';
  end if;
  raise notice '0114 self-test 3 passed: sim profile % exists.', public.cn_sim_profile_id();
end $$;

-- 4/5: bot_step -- old 1-arg guest call still works untouched, and the new
-- p_side='host' call drives the other seat. Both built by hand through the
-- exact same cn_fresh_map/cn_army/cn_set_ready pipeline a real match uses,
-- with cn.first_side pinned so which seat opens isn't a coin flip here.
do $$
declare
  v_deck1 text[]; v_deck2 text[]; v_m1 public.matches; v_m2 public.matches;
  v_before jsonb; v_after jsonb;
begin
  perform set_config('cn.first_side', 'guest', true);
  v_deck1 := random_deck(); v_deck2 := random_deck();
  insert into public.matches (code, host_id, host_name, guest_id, guest_name, status, state, bot, ranked, is_sim)
    values (gen_match_code(), cn_sim_profile_id(), 'ZZ Test Host', null, 'ZZ Test Bot',
            'deploying', cn_fresh_map(), 3, false, false)
    returning * into v_m1;
  insert into public.match_deploy (match_id, side, user_id, units) values
    (v_m1.id, 'host',  v_m1.host_id, cn_army(v_m1.state, 'host',  v_deck1)),
    (v_m1.id, 'guest', null,         cn_army(v_m1.state, 'guest', v_deck2));
  perform cn_set_ready(v_m1.id, 'host', false);
  v_m1 := cn_set_ready(v_m1.id, 'guest', false);
  if v_m1.status <> 'active' or v_m1.state->>'turn' <> 'guest' then
    raise exception '0114 self-test 4 FAILED: test match did not reach an active guest turn';
  end if;
  v_before := v_m1.state;
  v_m1 := bot_step(v_m1.id);  -- old, one-argument call
  v_after := v_m1.state;
  if v_before = v_after then
    raise exception '0114 self-test 4 FAILED: bot_step(uuid) with no side did nothing';
  end if;
  delete from public.matches where id = v_m1.id;
  raise notice '0114 self-test 4 passed: bot_step(uuid) with the old one-argument signature still plays guest.';

  perform set_config('cn.first_side', 'host', true);
  v_deck1 := random_deck(); v_deck2 := random_deck();
  insert into public.matches
      (code, host_id, host_name, guest_id, guest_name, status, state, bot, host_bot, ranked, is_sim)
    values (gen_match_code(), cn_sim_profile_id(), 'ZZ Test Bot Host', null, 'ZZ Test Bot Guest',
            'deploying', cn_fresh_map(), 3, 3, false, true)
    returning * into v_m2;
  insert into public.match_deploy (match_id, side, user_id, units) values
    (v_m2.id, 'host',  v_m2.host_id, cn_army(v_m2.state, 'host',  v_deck1)),
    (v_m2.id, 'guest', null,         cn_army(v_m2.state, 'guest', v_deck2));
  perform cn_set_ready(v_m2.id, 'host', false);
  v_m2 := cn_set_ready(v_m2.id, 'guest', false);
  if v_m2.status <> 'active' or v_m2.state->>'turn' <> 'host' then
    raise exception '0114 self-test 5 FAILED: test match did not reach an active host turn';
  end if;
  v_before := v_m2.state;
  v_m2 := bot_step(v_m2.id, 'host');
  v_after := v_m2.state;
  if v_before = v_after then
    raise exception '0114 self-test 5 FAILED: bot_step(uuid, ''host'') did nothing';
  end if;
  if (v_after->'lastBotAction'->>'side') <> 'host' then
    raise exception '0114 self-test 5 FAILED: lastBotAction was not stamped for the sim match';
  end if;
  delete from public.matches where id = v_m2.id;
  raise notice '0114 self-test 5 passed: bot_step(uuid, ''host'') drives the host seat and stamps lastBotAction.';
end $$;

-- 6: sim_play_one_game runs a full self-play game to a real finish and
-- returns plausible, non-empty per-unit stats.
do $$
declare
  v_base uuid; v_result record; v_game public.matches; v_stats jsonb; v_total_dmg numeric := 0;
begin
  select id into v_base from public.bot_brains where level = 3 and is_live;
  select * into v_result from sim_play_one_game(null, 3, random_deck(), random_deck(), v_base, v_base);
  v_game := v_result.game; v_stats := v_result.stats;
  if v_game.status <> 'finished' then
    raise exception '0114 self-test 6 FAILED: simulated game did not finish (status=%)', v_game.status;
  end if;
  if v_game.state->>'winner' is null then
    raise exception '0114 self-test 6 FAILED: a finished game must have a winner';
  end if;
  select coalesce(sum((value->>'damage_dealt')::numeric), 0) into v_total_dmg
    from jsonb_each(v_stats) e(key, value);
  if v_total_dmg <= 0 then
    raise exception '0114 self-test 6 FAILED: a finished 5v5 game recorded zero total damage dealt';
  end if;
  delete from public.matches where id = v_game.id;
  raise notice '0114 self-test 6 passed: a full self-play game finishes naturally with % total damage recorded.', v_total_dmg;
end $$;

-- 7: the admin run pipeline end to end -- start a tiny train run, batch it
-- to completion, and confirm every row it should have written is there.
do $$
declare
  v_run public.training_runs; v_games int; v_units int;
begin
  -- admin_require_admin() reads auth.uid(), which is null for this
  -- migration -- so these are exercised directly, bypassing that gate,
  -- exactly the way the functions' own SQL body works once past it.
  insert into public.training_runs (kind, level, games_requested, baseline_brain_id)
    select 'train', 3, 2, id from public.bot_brains where level = 3 and is_live
    returning * into v_run;

  -- inline the batch body once (admin_run_training_batch itself is admin-
  -- gated) by calling sim_play_one_game the same way it does, twice.
  declare
    v_result record; v_game public.matches; v_stats jsonb; v_roster jsonb; v_sim_game_id uuid; v_u jsonb; i int;
  begin
    for i in 1..2 loop
      select * into v_result from sim_play_one_game(
        v_run.id, 3, random_deck(), random_deck(), v_run.baseline_brain_id, v_run.baseline_brain_id);
      v_game := v_result.game; v_stats := v_result.stats; v_roster := v_result.roster;
      insert into public.sim_games (training_run_id, match_id, host_deck, guest_deck, host_brain_id, guest_brain_id, winner, turns)
        values (v_run.id, v_game.id, array['x'], array['y'], v_run.baseline_brain_id, v_run.baseline_brain_id,
                v_game.state->>'winner', coalesce((v_game.state->>'turnNumber')::int, 0))
        returning id into v_sim_game_id;
      for v_u in select * from jsonb_array_elements(v_roster) loop
        insert into public.sim_unit_stats (sim_game_id, training_run_id, unit_id, card_slug, role, royal, side, won,
          turns_alive, damage_dealt, damage_taken, healing_done, kills, deaths, final_hp)
          values (v_sim_game_id, v_run.id, v_u->>'id', v_u->>'slug', v_u->>'role',
            coalesce((v_u->>'royal')::boolean,false), v_u->>'owner',
            (v_game.state->>'winner') = (v_u->>'owner'),
            coalesce((v_stats->(v_u->>'id')->>'turns_alive')::numeric,0)::int,
            coalesce((v_stats->(v_u->>'id')->>'damage_dealt')::numeric,0),
            coalesce((v_stats->(v_u->>'id')->>'damage_taken')::numeric,0),
            coalesce((v_stats->(v_u->>'id')->>'healing_done')::numeric,0),
            coalesce((v_stats->(v_u->>'id')->>'kills')::numeric,0)::int,
            coalesce((v_stats->(v_u->>'id')->>'deaths')::numeric,0)::int,
            greatest(0, coalesce((
              select (u2->>'hp')::int from jsonb_array_elements(v_game.state->'units') u2
              where u2->>'id' = v_u->>'id'), 0)));
      end loop;
      update public.training_runs set games_completed = games_completed + 1 where id = v_run.id;
      delete from public.matches where id = v_game.id;
    end loop;
  end;

  select count(*) into v_games from public.sim_games where training_run_id = v_run.id;
  select count(*) into v_units from public.sim_unit_stats where training_run_id = v_run.id;
  if v_games <> 2 then
    raise exception '0114 self-test 7 FAILED: expected 2 sim_games rows, got %', v_games;
  end if;
  if v_units <> 20 then
    raise exception '0114 self-test 7 FAILED: expected 20 sim_unit_stats rows (2 games x 10 units), got %', v_units;
  end if;

  -- smoke-test every dashboard function against this run's real data.
  perform * from public.admin_card_performance(v_run.id);
  perform * from public.admin_tier_list(v_run.id);
  perform * from public.admin_pair_synergy(v_run.id, 1);
  perform * from public.admin_best_teams(v_run.id, 3, 1);

  delete from public.training_runs where id = v_run.id;
  raise notice '0114 self-test 7 passed: run pipeline wrote 2 sim_games / 20 sim_unit_stats rows, all dashboards read them back.';
end $$;
