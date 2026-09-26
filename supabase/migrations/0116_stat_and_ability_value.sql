-- 0116: "I want to know the value of each card, plus the value of each
-- ability, and the value of each attack point, and the value of each HP,
-- and the value for Range, and the value for movement (this can be figured
-- out with the extracted data)."
--
-- This fits a real linear regression -- win_rate ~ b0 + b1*power + b2*hp +
-- b3*range + b4*mov -- across every card's own simulated win rate (Train-
-- only data, per 0115, so it's never diluted by an untested candidate
-- brain). b1..b4 ARE the answer to "what is one point of attack/hp/range/
-- move worth": the change in win probability that one more point of that
-- stat buys, holding the other three stats fixed. Once that's solved, a
-- card's ABILITY value falls out for free: take the win rate its raw stats
-- alone would predict, and see how far the card's real, simulated win rate
-- is from that prediction. A card that overperforms what its numbers say it
-- should do is winning on its ability -- that gap, divided by the value of
-- one attack point, says exactly how many points of attack that ability is
-- worth. Everything here is solved from public.sim_unit_stats -- real
-- battles, nothing modelled or guessed -- exactly like every other number
-- in the Training tab.
--
-- Gaussian elimination is hand-written below (Postgres has no built-in
-- multivariate regression) rather than the built-in regr_slope/regr_intercept
-- pair, which only fit ONE predictor at a time and would silently confound
-- power with hp/range/mov whenever the roster's stats happen to correlate.
-- Because getting linear algebra wrong by hand is exactly the kind of thing
-- that quietly produces illegitimate numbers, the self-test below does not
-- just check it runs -- it hands the function a synthetic roster built from
-- a KNOWN formula (chosen coefficients, zero noise) and asserts the fitted
-- coefficients come back matching that formula to six decimal places.

create or replace function public.admin_stat_value_model(p_run uuid default null)
returns table (metric text, value numeric)
language plpgsql
stable
as $function$
declare
  r record;
  v_n int := 0;
  v_power double precision; v_hp double precision; v_range double precision;
  v_mov double precision; v_y double precision;
  s_1 double precision := 0; s_p double precision := 0; s_h double precision := 0;
  s_r double precision := 0; s_mv double precision := 0;
  s_pp double precision := 0; s_ph double precision := 0; s_pr double precision := 0; s_pmv double precision := 0;
  s_hh double precision := 0; s_hr double precision := 0; s_hmv double precision := 0;
  s_rr double precision := 0; s_rmv double precision := 0;
  s_mvmv double precision := 0;
  s_y double precision := 0; s_py double precision := 0; s_hy double precision := 0;
  s_ry double precision := 0; s_mvy double precision := 0;
  -- 5x6 augmented matrix for (X^T X) b = X^T y, stored row-major 1D so
  -- indexing never depends on Postgres's fiddlier 2D-array semantics.
  -- cell (row i, col j), both 1-based, lives at m[(i-1)*6 + j].
  m double precision[30];
  b double precision[5];
  i int; j int; k int; piv_row int; piv_val double precision; factor double precision; tmp double precision;
begin
  for r in
    select c.power::double precision as power, c.hp::double precision as hp,
           c.range::double precision as range, c.mov::double precision as mov,
           perf.win_rate::double precision as win_rate
    from public.admin_card_performance(p_run) perf
    join public.cards c on c.slug = perf.card_slug
    where c.power is not null and c.hp is not null and c.range is not null and c.mov is not null
  loop
    v_power := r.power; v_hp := r.hp; v_range := r.range; v_mov := r.mov; v_y := r.win_rate;
    v_n := v_n + 1;
    s_1 := s_1 + 1;
    s_p := s_p + v_power; s_h := s_h + v_hp; s_r := s_r + v_range; s_mv := s_mv + v_mov;
    s_pp := s_pp + v_power*v_power; s_ph := s_ph + v_power*v_hp;
    s_pr := s_pr + v_power*v_range; s_pmv := s_pmv + v_power*v_mov;
    s_hh := s_hh + v_hp*v_hp; s_hr := s_hr + v_hp*v_range; s_hmv := s_hmv + v_hp*v_mov;
    s_rr := s_rr + v_range*v_range; s_rmv := s_rmv + v_range*v_mov;
    s_mvmv := s_mvmv + v_mov*v_mov;
    s_y := s_y + v_y; s_py := s_py + v_power*v_y; s_hy := s_hy + v_hp*v_y;
    s_ry := s_ry + v_range*v_y; s_mvy := s_mvy + v_mov*v_y;
  end loop;

  -- 5 unknowns need at least 5 independent cards; below 8 the fit has too
  -- little slack left over to trust (a "regression" through 5 points and 5
  -- unknowns is a tautology, not evidence).
  if v_n < 8 then
    return query values ('insufficient_data', v_n::numeric);
    return;
  end if;

  m[1]:=s_1;  m[2]:=s_p;   m[3]:=s_h;   m[4]:=s_r;   m[5]:=s_mv;   m[6]:=s_y;
  m[7]:=s_p;  m[8]:=s_pp;  m[9]:=s_ph;  m[10]:=s_pr; m[11]:=s_pmv; m[12]:=s_py;
  m[13]:=s_h; m[14]:=s_ph; m[15]:=s_hh; m[16]:=s_hr; m[17]:=s_hmv; m[18]:=s_hy;
  m[19]:=s_r; m[20]:=s_pr; m[21]:=s_hr; m[22]:=s_rr; m[23]:=s_rmv; m[24]:=s_ry;
  m[25]:=s_mv;m[26]:=s_pmv;m[27]:=s_hmv;m[28]:=s_rmv;m[29]:=s_mvmv;m[30]:=s_mvy;

  -- Gaussian elimination with partial pivoting.
  for k in 1..5 loop
    piv_row := k; piv_val := abs(m[(k-1)*6+k]);
    for i in k+1..5 loop
      if abs(m[(i-1)*6+k]) > piv_val then piv_val := abs(m[(i-1)*6+k]); piv_row := i; end if;
    end loop;
    if piv_row <> k then
      for j in 1..6 loop
        tmp := m[(k-1)*6+j]; m[(k-1)*6+j] := m[(piv_row-1)*6+j]; m[(piv_row-1)*6+j] := tmp;
      end loop;
    end if;
    if abs(m[(k-1)*6+k]) < 1e-9 then
      raise exception 'admin_stat_value_model: singular matrix -- the roster''s stats do not vary independently enough to solve for all four at once';
    end if;
    for i in k+1..5 loop
      factor := m[(i-1)*6+k] / m[(k-1)*6+k];
      for j in k..6 loop
        m[(i-1)*6+j] := m[(i-1)*6+j] - factor * m[(k-1)*6+j];
      end loop;
    end loop;
  end loop;

  for i in reverse 5..1 loop
    b[i] := m[(i-1)*6+6];
    for j in i+1..5 loop
      b[i] := b[i] - m[(i-1)*6+j] * b[j];
    end loop;
    b[i] := b[i] / m[(i-1)*6+i];
  end loop;

  return query values
    ('intercept', b[1]::numeric),
    ('power_point', b[2]::numeric),
    ('hp_point', b[3]::numeric),
    ('range_point', b[4]::numeric),
    ('move_point', b[5]::numeric),
    ('sample_size', v_n::numeric);
end;
$function$;

-- Per-card value: its actual simulated win rate against what its raw stats
-- alone predict, in both win-rate points and "attack-point equivalents" (the
-- gap divided by the value of one attack point) so a design-review number
-- like "this ability is worth about 14 attack" is directly readable.
create or replace function public.admin_card_value(p_run uuid default null)
returns table (
  card_slug text, role text, royal boolean, games int,
  win_rate numeric, predicted_win_rate numeric,
  ability_value numeric, ability_value_power_equiv numeric,
  total_value_power_equiv numeric
)
language plpgsql
stable
as $function$
declare
  v_b0 numeric; v_bp numeric; v_bh numeric; v_br numeric; v_bm numeric; v_avg numeric;
begin
  select value into v_b0 from public.admin_stat_value_model(p_run) where metric = 'intercept';
  if v_b0 is null then
    return;
  end if;
  select value into v_bp from public.admin_stat_value_model(p_run) where metric = 'power_point';
  select value into v_bh from public.admin_stat_value_model(p_run) where metric = 'hp_point';
  select value into v_br from public.admin_stat_value_model(p_run) where metric = 'range_point';
  select value into v_bm from public.admin_stat_value_model(p_run) where metric = 'move_point';
  select avg(perf.win_rate) into v_avg from public.admin_card_performance(p_run) perf;

  return query
  select perf.card_slug, perf.role, perf.royal, perf.games, perf.win_rate,
    (v_b0 + v_bp*c.power + v_bh*c.hp + v_br*c.range + v_bm*c.mov)::numeric as predicted_win_rate,
    (perf.win_rate - (v_b0 + v_bp*c.power + v_bh*c.hp + v_br*c.range + v_bm*c.mov))::numeric as ability_value,
    case when abs(v_bp) > 0.0001
      then (perf.win_rate - (v_b0 + v_bp*c.power + v_bh*c.hp + v_br*c.range + v_bm*c.mov)) / v_bp
      else null end as ability_value_power_equiv,
    case when abs(v_bp) > 0.0001
      then (perf.win_rate - v_avg) / v_bp
      else null end as total_value_power_equiv
  from public.admin_card_performance(p_run) perf
  join public.cards c on c.slug = perf.card_slug
  order by ability_value desc;
end;
$function$;

-- Value of specific ability TYPES: for every boolean ability flag the roster
-- actually uses, the average ability-value gap between cards that carry it
-- and cards that don't -- only reported once at least two cards sit on each
-- side, since a single card either way is not a comparison.
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
  where cards_with >= 2 and cards_without >= 2
  order by avg_ability_value desc
$$;

-- Self-test: hand admin_stat_value_model a synthetic roster generated from
-- a KNOWN, chosen formula with zero noise -- y = 0.40 + 0.010*power +
-- 0.002*hp - 0.020*range + 0.030*mov -- and require the fitted coefficients
-- to match that formula to six decimal places. This is the only way to
-- trust hand-written Gaussian elimination rather than just watching it run
-- without error.
do $$
declare
  v_run uuid; v_game uuid; v_base uuid;
  -- 8 cards, not 6: admin_stat_value_model refuses to fit below 8 (see its
  -- own comment), so the "it fits correctly" test has to clear that floor,
  -- not just supply the bare minimum 5 unknowns need algebraically.
  v_cards text[] := array['zz0116a','zz0116b','zz0116c','zz0116d','zz0116e','zz0116f','zz0116g','zz0116h'];
  v_power int[]  := array[5, 15, 5, 5, 5, 10, 8, 12];
  v_hp int[]     := array[10, 10, 40, 10, 10, 25, 15, 20];
  v_range int[]  := array[1, 1, 1, 4, 1, 2, 3, 2];
  v_mov int[]    := array[2, 2, 2, 2, 6, 4, 5, 1];
  -- y computed by hand from the formula above for each row:
  -- 0.51, 0.61, 0.57, 0.45, 0.63, 0.63, 0.60, 0.55
  v_wins int[]   := array[51, 61, 57, 45, 63, 63, 60, 55]; -- out of 100 games each
  i int; v_metric text; v_val numeric;
  v_got_power numeric; v_got_hp numeric; v_got_range numeric; v_got_move numeric; v_got_intercept numeric; v_got_n numeric;
begin
  select id into v_base from public.bot_brains where level = 3 and is_live limit 1;
  insert into public.training_runs (kind, level, games_requested, baseline_brain_id)
    values ('train', 3, 1, v_base) returning id into v_run;

  for i in 1 .. 8 loop
    insert into public.cards (slug, name, role, power, hp, range, mov, is_active)
      values (v_cards[i], 'ZZ 0116 Test ' || i, 'knight', v_power[i], v_hp[i], v_range[i], v_mov[i], false);

    insert into public.sim_games (training_run_id, host_deck, guest_deck, host_brain_id, guest_brain_id, winner, turns)
      values (v_run, array[v_cards[i]], array[v_cards[i]], v_base, v_base, 'host', 5)
      returning id into v_game;

    -- v_wins[i] winning rows and (100 - v_wins[i]) losing rows for this card,
    -- so avg(won::int) comes out to exactly v_wins[i]/100.
    insert into public.sim_unit_stats
      (training_run_id, sim_game_id, unit_id, card_slug, role, royal, side, won, turns_alive,
       damage_dealt, damage_taken, healing_done, kills, deaths, final_hp, carried)
    select v_run, v_game, 'h' || gs, v_cards[i], 'knight', false, 'host', (gs <= v_wins[i]), 5,
           10, 5, 0, 0, 0, 20, false
    from generate_series(1, 100) gs;
  end loop;

  for v_metric, v_val in select metric, value from public.admin_stat_value_model(v_run) loop
    if v_metric = 'intercept' then v_got_intercept := v_val;
    elsif v_metric = 'power_point' then v_got_power := v_val;
    elsif v_metric = 'hp_point' then v_got_hp := v_val;
    elsif v_metric = 'range_point' then v_got_range := v_val;
    elsif v_metric = 'move_point' then v_got_move := v_val;
    elsif v_metric = 'sample_size' then v_got_n := v_val;
    end if;
  end loop;

  if v_got_n is distinct from 8 then
    raise exception '0116 self-test 1 FAILED: sample_size expected 8, got %', v_got_n;
  end if;
  if abs(v_got_intercept - 0.40) > 0.000001 then
    raise exception '0116 self-test 2 FAILED: intercept expected 0.40, got %', v_got_intercept;
  end if;
  if abs(v_got_power - 0.010) > 0.000001 then
    raise exception '0116 self-test 3 FAILED: power_point expected 0.010, got %', v_got_power;
  end if;
  if abs(v_got_hp - 0.002) > 0.000001 then
    raise exception '0116 self-test 4 FAILED: hp_point expected 0.002, got %', v_got_hp;
  end if;
  if abs(v_got_range - (-0.020)) > 0.000001 then
    raise exception '0116 self-test 5 FAILED: range_point expected -0.020, got %', v_got_range;
  end if;
  if abs(v_got_move - 0.030) > 0.000001 then
    raise exception '0116 self-test 6 FAILED: move_point expected 0.030, got %', v_got_move;
  end if;

  -- A card whose real win rate is exactly what its stats predict must show
  -- an ability_value of (near) zero -- confirms admin_card_value reads the
  -- fitted model correctly rather than some other number.
  if (select abs(ability_value) > 0.000001 from public.admin_card_value(v_run) where card_slug = 'zz0116a') then
    raise exception '0116 self-test 7 FAILED: a card built exactly from the formula should show ~0 ability_value';
  end if;

  -- cleanup
  delete from public.sim_unit_stats where training_run_id = v_run;
  delete from public.sim_games where training_run_id = v_run;
  delete from public.training_runs where id = v_run;
  delete from public.cards where slug = any(v_cards);

  raise notice '0116 self-test passed: the fitted stat-value model exactly recovers a known synthetic formula, and per-card ability value reads off it correctly.';
end $$;

-- Self-test: fewer than 8 cards worth of data must report 'insufficient_data'
-- rather than fabricate a fit, and admin_card_value must come back empty
-- (not error) in that case.
do $$
declare
  v_run uuid; v_base uuid; v_game uuid; v_n numeric; v_rows int;
begin
  select id into v_base from public.bot_brains where level = 3 and is_live limit 1;
  insert into public.training_runs (kind, level, games_requested, baseline_brain_id)
    values ('train', 3, 1, v_base) returning id into v_run;
  insert into public.cards (slug, name, role, power, hp, range, mov, is_active)
    values ('zz0116-solo', 'ZZ 0116 Solo', 'knight', 10, 20, 1, 3, false);
  insert into public.sim_games (training_run_id, host_deck, guest_deck, host_brain_id, guest_brain_id, winner, turns)
    values (v_run, array['zz0116-solo'], array['zz0116-solo'], v_base, v_base, 'host', 5) returning id into v_game;
  insert into public.sim_unit_stats
    (training_run_id, sim_game_id, unit_id, card_slug, role, royal, side, won, turns_alive,
     damage_dealt, damage_taken, healing_done, kills, deaths, final_hp, carried)
  values (v_run, v_game, 'h1', 'zz0116-solo', 'knight', false, 'host', true, 5, 10, 5, 0, 0, 0, 20, false);

  select value into v_n from public.admin_stat_value_model(v_run) where metric = 'insufficient_data';
  if v_n is distinct from 1 then
    raise exception '0116 self-test 8 FAILED: one-card run should report insufficient_data=1, got %', v_n;
  end if;

  select count(*) into v_rows from public.admin_card_value(v_run);
  if v_rows <> 0 then
    raise exception '0116 self-test 9 FAILED: admin_card_value should be empty when the model can''t be fit, got % rows', v_rows;
  end if;

  delete from public.sim_unit_stats where training_run_id = v_run;
  delete from public.sim_games where training_run_id = v_run;
  delete from public.training_runs where id = v_run;
  delete from public.cards where slug = 'zz0116-solo';

  raise notice '0116 self-test passed: too little data reports insufficient_data instead of a fake fit.';
end $$;
