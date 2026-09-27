-- 0127: the admin-view rebuild Jared asked for, backend half.
--
-- Jared, on the four stat tiles: "From now on, the value should be based on
-- 1 HP = 1 value point (VP), instead of 1 attack point = 1 value point."
-- admin_stat_value_model (0116) already fits and returns hp_point alongside
-- power_point/range_point/move_point -- the anchor switch itself is a
-- client-side change (AdminTraining.tsx divides by hp_point instead of
-- power_point from here on). Nothing here needed for that half.
--
-- What DOES need backend work is Jared's real complaint about "Ability
-- value": "Yes, all cards have abilities, some burn or even poison. Do
-- check this please, they actually do stuff in battle right now... I want
-- to see EVERYTHING here (burn, poison, stun, heal, parrying, doing crits,
-- and anything else)." He's right and 0126 was chasing the wrong data.
-- admin_ability_value has only ever looked at 11 legacy boolean columns on
-- `cards` (heals/burns/stuns/...), and of the 13 active cards only Dorme
-- (parries) and Lium (parry_all) have ANY of those set to true. But every
-- one of the other 11 has a real ability, wired into actual combat through
-- 0049's card_effects engine (Fey burns, Sinie poisons, Eva and Umiro heal,
-- Mako/Lumea summon structures, Dereo/Stelaris grant team auras, Wuzu scales
-- its own power) -- the booleans were simply never the mechanism these
-- cards use. admin_ability_tags below reads the REAL mechanism -- card_effects'
-- trigger/action/status/target_selector, plus the handful of genuine
-- percentage columns (crit_pct, twice_pct, lifesteal_pct, regen_pct,
-- evasion_pct, vs_poisoned) that also bypass the boolean flags -- so
-- admin_ability_value groups cards by what they ACTUALLY do, not by which of
-- 11 old checkboxes happens to be ticked.
--
-- One honest exception found along the way, left as-is (game-engine work,
-- not an admin-dashboard concern): Himanta's card_effects row is a PASSIVE
-- APPLY_STATUS(STUN) targeted at THE_TARGET, a target_selector 0049's own
-- header says is "only meaningful from ON_ATTACK/ON_PARRY/ON_DEATH's own
-- context" -- not PASSIVE. Its `ability` text is also literally "Placeholder"
-- in both languages. It's counted as 'stuns' below because the row is real
-- data, but it's flagged here for Jared rather than silently smoothed over.
--
-- Second half: "I want ... how much it increased or decreased in comparison
-- with the last batch of simulated games." Nothing before this migration
-- ever stored a point-in-time value -- every dashboard here is computed
-- live from the full pooled history, with no prior snapshot to diff
-- against. admin_value_snapshots is a one-row-per-card table holding the
-- pooled win_rate as it stood immediately BEFORE the most recently
-- completed Simulate batch; AdminTraining.tsx calls
-- admin_snapshot_pre_batch_values() at the very start of onSimulate (before
-- that batch's own games exist), freezing "value before this batch" until
-- the NEXT click overwrites it. admin_card_value_deltas then just reports
-- current win_rate minus that frozen snapshot -- the client converts the
-- raw delta into HP-point units with the exact same toPoints() used
-- everywhere else, so a value that got worse shows a real minus sign.

-- =====================================================================
-- 1. Ability tags, read from what actually happens in combat.
-- =====================================================================
create or replace function public.admin_ability_tags()
returns table (card_slug text, tag text)
language sql
stable
as $$
  with ce_tags as (
    -- `status` and `stat_name` are only meaningful for the action they pair
    -- with (see card_effects_status_action_needs_status /
    -- card_effects_modify_stat_needs_name) -- a HEAL row can carry a stray
    -- non-null status (Eva's does, a leftover 'BURNING' with no bearing on
    -- what the row does), so every branch below checks `action` first and
    -- only then looks at status/stat_name, never the other way around.
    -- The nine "ordinary stat boxes" (HP/MOV/RMIN/RMAX/CRMIN/CRMAX/POWER/
    -- PARRY_PCT/CRIT_PCT) are runtime numeric nudges (Wuzu's own power
    -- growing every turn); the other MODIFY_STAT stat_names (PARRIES,
    -- PARRY_ALL, ...) are Layer 2's compiled passive-flag representation --
    -- already read precisely off the resulting `cards` columns in col_tags
    -- below, so they're deliberately excluded here to avoid double-tagging
    -- Dorme/Lium as a generic "self_buff" on top of their real tag.
    select c.slug,
      case
        when ce.action = 'APPLY_STATUS' and ce.status = 'BURNING' then 'burns'
        when ce.action = 'APPLY_STATUS' and ce.status = 'POISON' then 'poisons'
        when ce.action = 'APPLY_STATUS' and ce.status = 'STUN' then 'stuns'
        when ce.action = 'HEAL' then 'heals'
        when ce.action = 'CREATE_STRUCTURE' then 'summons'
        when ce.action = 'MODIFY_STAT' and ce.stat_name like 'AURA_%' then 'team_aura'
        when ce.action = 'MODIFY_STAT'
             and ce.stat_name in ('HP', 'MOV', 'RMIN', 'RMAX', 'CRMIN', 'CRMAX', 'POWER', 'PARRY_PCT', 'CRIT_PCT')
             and ce.target_selector = 'SELF' then 'self_buff'
        when ce.action = 'MODIFY_STAT'
             and ce.stat_name in ('HP', 'MOV', 'RMIN', 'RMAX', 'CRMIN', 'CRMAX', 'POWER', 'PARRY_PCT', 'CRIT_PCT')
             and ce.target_selector in ('ALL_ALLIES', 'NEARBY_ALLIES') then 'team_buff'
        when ce.action = 'DEAL_DAMAGE' and ce.target_selector in ('ADJACENT_UNITS', 'ALL_ENEMIES', 'ENEMIES_IN_LINE') then 'aoe_damage'
        else null
      end as tag
    from public.card_effects ce
    join public.cards c on c.id = ce.card_id
  ),
  col_tags as (
    select slug, unnest(array[
      case when parries then 'parries' end,
      case when parry_all then 'parries_all' end,
      case when crit_pct is not null and crit_pct > 5 then 'crit_boost' end,
      case when twice_pct is not null and twice_pct > 0 then 'double_attack' end,
      case when lifesteal_pct is not null and lifesteal_pct > 0 then 'lifesteal' end,
      case when regen_pct is not null and regen_pct > 0 then 'regen' end,
      case when evasion_pct is not null and evasion_pct > 0 then 'evasion' end,
      case when vs_poisoned is not null and vs_poisoned <> 0 then 'anti_poison' end
    ]) as tag
    from public.cards
  )
  select slug as card_slug, tag from ce_tags where tag is not null
  union
  select slug as card_slug, tag from col_tags where tag is not null
$$;

-- Same shape as 0126's admin_ability_value (safe to CREATE OR REPLACE, no
-- signature change), same >=1/>=1 threshold and reasoning for it -- just
-- grouped by the tags above instead of the 11 legacy booleans.
create or replace function public.admin_ability_value(p_run uuid default null)
returns table (ability text, cards_with int, cards_without int, avg_ability_value numeric)
language sql
stable
as $$
  with v as (select * from public.admin_card_value(p_run)),
  tags as (select distinct tag from public.admin_ability_tags()),
  membership as (
    select v.card_slug as slug, t.tag, (tg.card_slug is not null) as has_tag
    from v
    cross join tags t
    left join public.admin_ability_tags() tg on tg.card_slug = v.card_slug and tg.tag = t.tag
  )
  select m.tag as ability,
    count(*) filter (where m.has_tag)::int as cards_with,
    count(*) filter (where not m.has_tag)::int as cards_without,
    (avg(vv.ability_value) filter (where m.has_tag) - avg(vv.ability_value) filter (where not m.has_tag))::numeric as avg_ability_value
  from membership m
  join v vv on vv.card_slug = m.slug
  group by m.tag
  having count(*) filter (where m.has_tag) >= 1 and count(*) filter (where not m.has_tag) >= 1
  order by avg_ability_value desc
$$;

-- =====================================================================
-- 2. Value snapshots, for "vs. the last batch of simulated games".
-- =====================================================================
create table public.admin_value_snapshots (
  card_slug text primary key references public.cards(slug) on delete cascade,
  win_rate numeric not null,
  ability_value numeric not null,
  snapshotted_at timestamptz not null default now()
);

alter table public.admin_value_snapshots enable row level security;

create policy "admins read value snapshots" on public.admin_value_snapshots
  for select to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin));

-- Freezes the CURRENT pooled per-card value as "before this batch", called
-- once at the top of onSimulate, before that batch's own games exist. Admin
-- only, like every other write path here (admin_require_admin, same helper
-- admin_spot_check_team already uses).
create or replace function public.admin_snapshot_pre_batch_values()
returns void
language plpgsql
security definer
set search_path = 'public'
as $function$
begin
  perform admin_require_admin();
  insert into public.admin_value_snapshots (card_slug, win_rate, ability_value, snapshotted_at)
  select card_slug, win_rate, ability_value, now()
  from public.admin_card_value(null)
  on conflict (card_slug) do update
    set win_rate = excluded.win_rate,
        ability_value = excluded.ability_value,
        snapshotted_at = excluded.snapshotted_at;
end;
$function$;

-- Raw win-rate delta only -- the client converts it into HP-point units
-- itself (toPoints(delta)), using the SAME current hp_point coefficient it
-- uses for every other number on the page, so "current value" and "delta"
-- are always expressed on the same ruler even as the model keeps refitting
-- on more data.
create or replace function public.admin_card_value_deltas(p_run uuid default null)
returns table (card_slug text, delta_win_rate numeric, has_snapshot boolean)
language sql
stable
as $$
  select v.card_slug,
    case when s.card_slug is not null then v.win_rate - s.win_rate else null end as delta_win_rate,
    (s.card_slug is not null) as has_snapshot
  from public.admin_card_value(p_run) v
  left join public.admin_value_snapshots s on s.card_slug = v.card_slug
$$;

-- =====================================================================
-- Self-tests
-- =====================================================================

-- admin_ability_tags/admin_ability_value must find a real ability from
-- card_effects (burns, via APPLY_STATUS/BURNING) even though the legacy
-- `burns` boolean column is left false -- this is the actual bug being
-- fixed: 0126 could never have shown this card at all.
do $$
declare
  v_run uuid; v_base uuid; v_game uuid; v_n int; i int; v_card_id uuid;
  v_cards text[] := array['zz0127a','zz0127b','zz0127c','zz0127d','zz0127e','zz0127f','zz0127g','zz0127h'];
  v_power int[] := array[5, 15, 5, 5, 5, 10, 8, 12];
  v_hp int[]    := array[10, 10, 40, 10, 10, 25, 15, 20];
  v_range int[] := array[1, 1, 1, 4, 1, 2, 3, 2];
  v_mov int[]   := array[2, 2, 2, 2, 6, 4, 5, 1];
  v_wins int[]  := array[51, 61, 57, 45, 63, 63, 60, 55];
begin
  select id into v_base from public.bot_brains where level = 3 and is_live limit 1;
  insert into public.training_runs (kind, level, games_requested, baseline_brain_id)
    values ('train', 3, 1, v_base) returning id into v_run;

  for i in 1 .. 8 loop
    insert into public.cards (slug, name, role, power, hp, range, mov, is_active, burns)
      values (v_cards[i], 'ZZ 0127 Test ' || i, 'knight', v_power[i], v_hp[i], v_range[i], v_mov[i], false, false)
      returning id into v_card_id;
    if i = 1 then
      insert into public.card_effects (card_id, trigger, target_selector, action, status)
        values (v_card_id, 'ON_ABILITY', 'THE_TARGET', 'APPLY_STATUS', 'BURNING');
    end if;
    insert into public.sim_games (training_run_id, host_deck, guest_deck, host_brain_id, guest_brain_id, winner, turns)
      values (v_run, array[v_cards[i]], array[v_cards[i]], v_base, v_base, 'host', 5)
      returning id into v_game;
    insert into public.sim_unit_stats
      (training_run_id, sim_game_id, unit_id, card_slug, role, royal, side, won, turns_alive,
       damage_dealt, damage_taken, healing_done, kills, deaths, final_hp, carried)
    select v_run, v_game, 'h' || gs, v_cards[i], 'knight', false, 'host',
           (gs <= v_wins[i]), 5, 10, 5, 0, 0, 0, 20, false
    from generate_series(1, 100) gs;
  end loop;

  select count(*) into v_n from public.admin_ability_value(v_run) where ability = 'burns';
  if v_n <> 1 then
    raise exception '0127 self-test 1 FAILED: a card with a BURNING card_effects row (legacy `burns` column left false) should produce a burns row (got % rows)', v_n;
  end if;

  raise notice '0127 self-test 1 passed: ability values are read from card_effects, not the legacy booleans.';

  delete from public.sim_unit_stats where training_run_id = v_run;
  delete from public.sim_games where training_run_id = v_run;
  delete from public.card_effects where card_id in (select id from public.cards where slug = any(v_cards));
  delete from public.training_runs where id = v_run;
  delete from public.cards where slug = any(v_cards);
end $$;

-- Snapshot + delta: before any snapshot exists, has_snapshot is false and
-- delta is null; after admin_snapshot_pre_batch_values() runs, a later
-- change in a card's win rate must show up as a nonzero delta with the
-- correct sign.
do $$
declare
  v_admin uuid;
  v_run1 uuid; v_run2 uuid; v_base uuid; v_game uuid;
  v_slug text := 'zz0127snap';
  v_before boolean; v_delta1 numeric; v_delta2 numeric;
begin
  select id into v_admin from public.profiles where is_admin limit 1;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  select id into v_base from public.bot_brains where level = 3 and is_live limit 1;

  insert into public.cards (slug, name, role, power, hp, range, mov, is_active)
    values (v_slug, 'ZZ 0127 Snap', 'knight', 20, 60, 1, 2, false);

  insert into public.training_runs (kind, level, games_requested, baseline_brain_id)
    values ('train', 3, 1, v_base) returning id into v_run1;
  insert into public.sim_games (training_run_id, host_deck, guest_deck, host_brain_id, guest_brain_id, winner, turns)
    values (v_run1, array[v_slug], array[v_slug], v_base, v_base, 'host', 5) returning id into v_game;
  insert into public.sim_unit_stats
    (training_run_id, sim_game_id, unit_id, card_slug, role, royal, side, won, turns_alive,
     damage_dealt, damage_taken, healing_done, kills, deaths, final_hp, carried)
  select v_run1, v_game, 'h' || gs, v_slug, 'knight', false, 'host', (gs <= 50), 5, 10, 5, 0, 0, 0, 20, false
  from generate_series(1, 100) gs;

  -- p_run = null throughout this test, not v_run1: admin_stat_value_model
  -- refuses to fit below 8 distinct cards (see 0116), and this synthetic
  -- run only ever has this one card in it -- the real production roster
  -- pooled in via null easily clears that floor, and none of those real
  -- cards share this test's made-up slug, so the delta stays exactly this
  -- card's own before/after story.
  select has_snapshot into v_before from public.admin_card_value_deltas(null) where card_slug = v_slug;
  if v_before is distinct from false then
    raise exception '0127 self-test 2 FAILED: a card with no snapshot yet should report has_snapshot = false';
  end if;

  perform public.admin_snapshot_pre_batch_values();

  select delta_win_rate into v_delta1 from public.admin_card_value_deltas(null) where card_slug = v_slug;
  if v_delta1 is null or abs(v_delta1) > 0.000001 then
    raise exception '0127 self-test 3 FAILED: delta right after snapshotting the current value should be ~0, got %', v_delta1;
  end if;

  -- A second batch, won more often this time -- the snapshot above must
  -- stay frozen at the first batch's value, so the delta now reflects
  -- exactly what changed in this second batch.
  insert into public.training_runs (kind, level, games_requested, baseline_brain_id)
    values ('train', 3, 1, v_base) returning id into v_run2;
  insert into public.sim_games (training_run_id, host_deck, guest_deck, host_brain_id, guest_brain_id, winner, turns)
    values (v_run2, array[v_slug], array[v_slug], v_base, v_base, 'host', 5) returning id into v_game;
  insert into public.sim_unit_stats
    (training_run_id, sim_game_id, unit_id, card_slug, role, royal, side, won, turns_alive,
     damage_dealt, damage_taken, healing_done, kills, deaths, final_hp, carried)
  select v_run2, v_game, 'h' || gs, v_slug, 'knight', false, 'host', (gs <= 90), 5, 10, 5, 0, 0, 0, 20, false
  from generate_series(1, 100) gs;

  -- pooled across both runs now: (50 + 90) / 200 = 0.70, vs the frozen
  -- snapshot's 0.50 -- delta should be +0.20.
  select delta_win_rate into v_delta2 from public.admin_card_value_deltas(null) where card_slug = v_slug;
  if v_delta2 is null or abs(v_delta2 - 0.20) > 0.000001 then
    raise exception '0127 self-test 4 FAILED: delta after a stronger second batch expected ~+0.20, got %', v_delta2;
  end if;

  raise notice '0127 self-test 2-4 passed: a fresh card has no snapshot, snapshotting freezes the current value, and a later batch''s delta is measured against that frozen value.';

  delete from public.sim_unit_stats where training_run_id in (v_run1, v_run2);
  delete from public.sim_games where training_run_id in (v_run1, v_run2);
  delete from public.training_runs where id in (v_run1, v_run2);
  delete from public.admin_value_snapshots where card_slug = v_slug;
  delete from public.cards where slug = v_slug;
end $$;
