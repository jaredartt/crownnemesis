-- 0126: Jared, impatient: "I want to see the abilitieeees I'm impatient,
-- let me seeeee" -- but "Ability value" was empty no matter how many games
-- got simulated. The real cause: of the 13 active cards, only two have ANY
-- of the 11 tracked ability flags at all -- Dorme (parries) and Lium
-- (parry_all), one card each. 0116's threshold (cards_with >= 2 and
-- cards_without >= 2) needs at least two cards sharing an ability before it
-- will show anything, as a real comparison rather than one card's own
-- number pretending to be an average. With the current roster that gate
-- can never open -- no amount of simulating fixes it, since it's a content
-- gap (not enough cards share an ability yet), not a sample-size gap.
--
-- Lowering the gate to >= 1 on each side lets Dorme's and Lium's own
-- ability_value residual show through -- their card's real win rate minus
-- what its raw stats alone predict, same number that already powers "Card
-- value" above it, just grouped by the one ability that explains it. That
-- residual is still a real, regression-backed number even for a single
-- card (the regression already stripped out power/hp/range/move; what's
-- left over is attributable to whatever else makes the card different,
-- which for these two is the ability) -- it just isn't an AVERAGE across
-- multiple cards anymore, so it's one card's evidence, not a pattern. Doing
-- this honestly means AdminTraining.tsx (same change as this migration)
-- needs to show cards_with next to each row, so a "based on 1 card" ability
-- reads differently from a "based on 4 cards" one -- it's still exactly the
-- distinction 0116's own comment cared about, just surfaced instead of
-- used to hide the row entirely.
create or replace function public.admin_ability_value(p_run uuid default null)
returns table (ability text, cards_with int, cards_without int, avg_ability_value numeric)
language sql
stable
as $$
  with v as (select * from public.admin_card_value(p_run)),
  c as (
    select slug, heals, burns, stuns, parries, tramples, cures, poisons_adjacent,
           slippery, parry_all, blooms, sneaks
    from public.cards
  ),
  raw as (
    select 'heals'::text as ability, count(*) filter (where c.heals)::int as cards_with,
      count(*) filter (where not c.heals)::int as cards_without,
      (avg(v.ability_value) filter (where c.heals) - avg(v.ability_value) filter (where not c.heals))::numeric as avg_ability_value
    from v join c on c.slug = v.card_slug
    union all
    select 'burns', count(*) filter (where c.burns)::int, count(*) filter (where not c.burns)::int,
      (avg(v.ability_value) filter (where c.burns) - avg(v.ability_value) filter (where not c.burns))::numeric
    from v join c on c.slug = v.card_slug
    union all
    select 'stuns', count(*) filter (where c.stuns)::int, count(*) filter (where not c.stuns)::int,
      (avg(v.ability_value) filter (where c.stuns) - avg(v.ability_value) filter (where not c.stuns))::numeric
    from v join c on c.slug = v.card_slug
    union all
    select 'parries', count(*) filter (where c.parries)::int, count(*) filter (where not c.parries)::int,
      (avg(v.ability_value) filter (where c.parries) - avg(v.ability_value) filter (where not c.parries))::numeric
    from v join c on c.slug = v.card_slug
    union all
    select 'tramples', count(*) filter (where c.tramples)::int, count(*) filter (where not c.tramples)::int,
      (avg(v.ability_value) filter (where c.tramples) - avg(v.ability_value) filter (where not c.tramples))::numeric
    from v join c on c.slug = v.card_slug
    union all
    select 'cures', count(*) filter (where c.cures)::int, count(*) filter (where not c.cures)::int,
      (avg(v.ability_value) filter (where c.cures) - avg(v.ability_value) filter (where not c.cures))::numeric
    from v join c on c.slug = v.card_slug
    union all
    select 'poisons_adjacent', count(*) filter (where c.poisons_adjacent)::int, count(*) filter (where not c.poisons_adjacent)::int,
      (avg(v.ability_value) filter (where c.poisons_adjacent) - avg(v.ability_value) filter (where not c.poisons_adjacent))::numeric
    from v join c on c.slug = v.card_slug
    union all
    select 'slippery', count(*) filter (where c.slippery)::int, count(*) filter (where not c.slippery)::int,
      (avg(v.ability_value) filter (where c.slippery) - avg(v.ability_value) filter (where not c.slippery))::numeric
    from v join c on c.slug = v.card_slug
    union all
    select 'parry_all', count(*) filter (where c.parry_all)::int, count(*) filter (where not c.parry_all)::int,
      (avg(v.ability_value) filter (where c.parry_all) - avg(v.ability_value) filter (where not c.parry_all))::numeric
    from v join c on c.slug = v.card_slug
    union all
    select 'blooms', count(*) filter (where c.blooms)::int, count(*) filter (where not c.blooms)::int,
      (avg(v.ability_value) filter (where c.blooms) - avg(v.ability_value) filter (where not c.blooms))::numeric
    from v join c on c.slug = v.card_slug
    union all
    select 'sneaks', count(*) filter (where c.sneaks)::int, count(*) filter (where not c.sneaks)::int,
      (avg(v.ability_value) filter (where c.sneaks) - avg(v.ability_value) filter (where not c.sneaks))::numeric
    from v join c on c.slug = v.card_slug
  )
  select ability, cards_with, cards_without, avg_ability_value
  from raw
  where cards_with >= 1 and cards_without >= 1
  order by avg_ability_value desc
$$;

-- Self-test: a synthetic roster with exactly ONE card carrying 'heals' must
-- now show a 'heals' row (0116's own threshold would have hidden it).
do $$
declare
  v_run uuid; v_base uuid; v_game uuid; v_n int; i int;
  v_cards text[] := array['zz0126a','zz0126b','zz0126c','zz0126d','zz0126e','zz0126f','zz0126g','zz0126h'];
  -- Same non-collinear stat spread as 0116's own self-test (deliberately
  -- varied, not a linear formula in i) -- a power/hp/range/mov set that's
  -- all perfectly correlated with each other makes the regression matrix
  -- singular and admin_stat_value_model raises rather than fits.
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
    insert into public.cards (slug, name, role, power, hp, range, mov, is_active, heals)
      values (v_cards[i], 'ZZ 0126 Test ' || i, 'knight', v_power[i], v_hp[i], v_range[i], v_mov[i], false, i = 1);
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

  select count(*) into v_n from public.admin_ability_value(v_run) where ability = 'heals';
  if v_n <> 1 then
    raise exception '0126 self-test FAILED: a single card with heals=true should now produce a ''heals'' row (got % rows)', v_n;
  end if;

  raise notice '0126 self-test passed: a single-card ability now surfaces instead of being hidden.';

  -- cleanup
  delete from public.sim_unit_stats where training_run_id = v_run;
  delete from public.sim_games where training_run_id = v_run;
  delete from public.training_runs where id = v_run;
  delete from public.cards where slug = any(v_cards);
end $$;
