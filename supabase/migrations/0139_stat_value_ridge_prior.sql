-- Jared, after seeing the Card Value panel still showing raw win-rate
-- percentages: "You know what? You win, get your freaking percentages...
-- I think I want [to] delete this whole feature." Then, told the real fix
-- (using what the calibration run proved) was solvable: "If it's solvable,
-- then do it."
--
-- The calibration run (0137) proved a well-designed, uncorrelated dataset
-- produces a stable, correctly-signed model: power_point, hp_point,
-- range_point and move_point all positive. But that was 65 purpose-built
-- cards -- it never touched the REAL 13-card model admin_stat_value_model
-- actually fits for the live dashboard, which still has only 13 cards and
-- the same real correlation problem (power vs. range -0.69, power vs.
-- move -0.59). Verified live just now: on the current roster, BOTH
-- power_point (-0.0000324) and hp_point (-0.0000832) are negative --
-- backwards. That's the actual, still-open bug behind Jared's frustration.
--
-- Fix: ridge regression shrunk toward the calibration run's own
-- coefficients, instead of a plain unconstrained fit. Concretely, the
-- four slope coefficients (not the intercept -- that's the roster-wide
-- baseline win rate, not a per-stat slope, and isn't what collinearity
-- destabilizes) get a ridge penalty pulling them toward
-- public.stat_value_priors, weighted as if P_KAPPA additional
-- "pseudo-cards" of clean, prior-matching data had been observed
-- alongside the v_n real ones. This is the standard closed-form ridge-
-- to-a-nonzero-prior solution: (X^T X + lambda_j) b_j = X^T y + lambda_j
-- * prior_j, where lambda_j = kappa/v_n * (that column's own sum of
-- squares) -- scaling lambda per-column by the column's own sum of
-- squares is what makes one shared kappa comparable across power/hp
-- (large natural scale) and range/move (small natural scale) instead of
-- over- or under-regularizing whichever stat happens to have smaller
-- numbers.
--
-- P_KAPPA = 20 was picked by sweeping the real 13-card data by hand
-- (kappa in 0,2,5,8,13,20,30,50,80,130,300) against the calibration
-- prior: even kappa=2 is enough to flip both signs back positive, and
-- the fit is already within a few percent of its kappa=300 (fully
-- prior-dominated) value by kappa=20 -- meaning the real roster's own 13
-- cards, on their own, just don't carry enough independent signal to
-- meaningfully contest a well-powered prior on power/hp specifically.
-- kappa=20 is a bit more than a full "extra roster" of confidence (the
-- real data is 13 cards) while still visibly moving with real results --
-- verified: Dorme (the highest real win rate) still comes out clearly
-- ahead at ~+24 total points, Himanta/Dione-grifo clearly behind, and
-- Wuzu -- the card with power=0 whose 0058-era "-511 points" example
-- is what kept this whole feature off in the first place -- now lands at
-- a sane +8, not a nonsense negative number.
create table if not exists public.stat_value_priors (
  metric text primary key,
  value numeric not null,
  source_run uuid,
  note text,
  created_at timestamptz not null default now()
);

insert into public.stat_value_priors (metric, value, source_run, note) values
  ('power_point', 0.0035655568619752,   'd64bcab5-b741-4fb7-ae89-9981d275a492', 'From the 65-card, 3000-game orthogonal calibration run (0137/0138).'),
  ('hp_point',    0.000197840053471327, 'd64bcab5-b741-4fb7-ae89-9981d275a492', 'From the 65-card, 3000-game orthogonal calibration run (0137/0138).'),
  ('range_point', 0.0312826173261396,   'd64bcab5-b741-4fb7-ae89-9981d275a492', 'From the 65-card, 3000-game orthogonal calibration run (0137/0138).'),
  ('move_point',  0.0601520086925309,   'd64bcab5-b741-4fb7-ae89-9981d275a492', 'From the 65-card, 3000-game orthogonal calibration run (0137/0138).')
on conflict (metric) do update set
  value = excluded.value, source_run = excluded.source_run, note = excluded.note, created_at = now();

create or replace function public.admin_stat_value_model(p_run uuid default null::uuid)
 returns TABLE(metric text, value numeric)
 language plpgsql
 set search_path to 'public'
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
  -- 0139: ridge-to-prior regularization (see this migration's header).
  v_kappa constant double precision := 20;
  v_pp0 double precision; v_hp0 double precision; v_r0 double precision; v_mv0 double precision;
  v_lam_p double precision; v_lam_h double precision; v_lam_r double precision; v_lam_mv double precision;
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

  -- 0139: pull power_point/hp_point/range_point/move_point toward the
  -- calibration prior, weighted as v_kappa pseudo-cards' worth of clean
  -- data. Silently skipped (falls back to the plain, unregularized fit)
  -- if the priors table is empty -- so this is safe to ship even before
  -- 0137's calibration run has been recorded there.
  -- Every column of stat_value_priors is qualified with the table name:
  -- this function's own OUT parameters are ALSO named `metric` and
  -- `value` (returns TABLE(metric text, value numeric)), so a bare
  -- `metric`/`value` here is ambiguous with those OUT variables -- caught
  -- live on first apply, twice (once per column, one at a time).
  select stat_value_priors.value into v_pp0 from public.stat_value_priors where stat_value_priors.metric = 'power_point';
  select stat_value_priors.value into v_hp0 from public.stat_value_priors where stat_value_priors.metric = 'hp_point';
  select stat_value_priors.value into v_r0  from public.stat_value_priors where stat_value_priors.metric = 'range_point';
  select stat_value_priors.value into v_mv0 from public.stat_value_priors where stat_value_priors.metric = 'move_point';
  if v_pp0 is not null and v_hp0 is not null and v_r0 is not null and v_mv0 is not null then
    v_lam_p  := v_kappa / v_n * s_pp;
    v_lam_h  := v_kappa / v_n * s_hh;
    v_lam_r  := v_kappa / v_n * s_rr;
    v_lam_mv := v_kappa / v_n * s_mvmv;
    m[8]  := m[8]  + v_lam_p;   m[12] := m[12] + v_lam_p  * v_pp0;
    m[15] := m[15] + v_lam_h;   m[18] := m[18] + v_lam_h  * v_hp0;
    m[22] := m[22] + v_lam_r;   m[24] := m[24] + v_lam_r  * v_r0;
    m[29] := m[29] + v_lam_mv;  m[30] := m[30] + v_lam_mv * v_mv0;
  end if;

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
