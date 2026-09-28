-- Jared: "maybe to solve this, we could have (as a test) run 3000 games
-- with invented cards, some with same HP but different attack, or same
-- range but different movement, or some being able to attack normally and
-- some other to burn and attack... It will just be one time in the history
-- of Crown Nemesis, but it will make sure that there's some substantial
-- initial data to start working with it, and then we will go with the
-- actual cards of the game and train with them."
--
-- This is exactly the right fix, and a better one than anything I'd
-- proposed (ridge regression only papers over the symptom; this fixes the
-- actual cause). The reason the stat-value regression is unstable isn't
-- too little data -- each of the 13 real cards already has 1,850-2,684
-- games -- it's that the real roster's own design correlates Attack with
-- Range (-0.69) and Attack with Move (-0.59): tanky melee bruisers vs.
-- nimble low-power units. With only 13 cards, the model can't cleanly
-- tell which correlated stat is actually driving a card's win rate. A
-- purpose-built test roster where every stat varies independently of
-- every other one removes that problem by construction, not by shrinkage.
--
-- 65 synthetic "calib-*" cards: a full 2^4 factorial over
-- {Attack, HP, Range, Move} at two levels each (Attack 10/30, HP 60/110,
-- Range 1/3, Move 1/3) -- 16 stat combinations, each appearing exactly
-- once, which by construction has ZERO pairwise correlation between all
-- four stats (unlike the real roster's -0.69/-0.59). Each of those 16 is
-- replicated across 4 ability treatments (none / burns / poisons adjacent
-- units / stuns), so ability value is measured on the SAME 16-point stat
-- spread each time, matched rather than confounded with any particular
-- stat line. One extra royal "center point" card (Attack 20, HP 85,
-- Range 2, Move 2, no ability) satisfies "exactly one royal" per deck.
-- Damage (dmin/dmax) follows the same +/-2 spread the real cards use
-- around their own power value; range/counter-range mirror rmax the same
-- way real cards do; parry/crit stay at the real-card default (5%) so
-- combat math outside the four tested stats stays neutral. (Slugs use
-- dashes, not underscores -- cn_check_card()'s trigger enforces
-- ^[a-z][a-z0-9-]{1,39}$, no underscores allowed, caught on first apply
-- attempt.)
--
-- Isolation from the real game, in both directions:
--  * is_test_card (new column, default false on every existing/future
--    real card) lets random_deck() -- the deck-builder every REAL match
--    and every real training/preview batch already uses, several of
--    which are running RIGHT NOW -- keep excluding these cards with a
--    one-line, purely additive change. They still need is_active = true
--    (cn_army/deck_royals both gate on it), so this is the only thing
--    standing between them and contaminating live data.
--  * A dedicated random_deck_from(pool) and admin_run_calibration_batch()
--    (a trimmed copy of admin_run_training_batch: same sim_play_one_game
--    call, same sim_games/sim_unit_stats bookkeeping, no candidate/
--    baseline promotion logic, since that's not what this run is for)
--    build decks ONLY from this synthetic pool, so calibration games
--    never draw a real card either.
--  * The run itself gets a new training_runs.kind ('calibration'), a
--    small additive widening of the existing CHECK constraint. Every
--    admin dashboard aggregate (admin_card_performance, admin_stat_value_
--    model, etc.) defaults to kind in ('train', 'preview') when no
--    specific run is given, so a calibration run never shows up in
--    Jared's regular numbers unless its own run id is asked for by name.
--
-- Live-verified after running the full 3000-game batch (run id
-- d64bcab5-b741-4fb7-ae89-9981d275a492, all 65 cards at 326-413 games
-- each, the royal at 6000 since it's in every deck): admin_stat_value_
-- model(p_run) came back with sample_size = 65 (vs. 13 on the real
-- roster) and all four coefficients positive and correctly signed --
-- including hp_point, which is negative and wrong-signed on the real
-- roster today. See migration 0138 for a related gap this run also
-- surfaced in admin_ability_tags().
alter table public.cards add column if not exists is_test_card boolean not null default false;

create or replace function public.random_deck()
 returns text[]
 language sql
 security definer
 set search_path to 'public'
as $function$
  select array_agg(slug) from (
    (select slug from public.cards
      where is_active and not is_test_card and slug is not null and royal
      order by random() limit 1)
    union all
    (select slug from public.cards
      where is_active and not is_test_card and slug is not null and not royal
      order by random() limit (deck_size() - 1))
  ) s
$function$;

alter table public.training_runs drop constraint training_runs_kind_check;
alter table public.training_runs add constraint training_runs_kind_check
  check (kind = any (array['train'::text, 'teach'::text, 'preview'::text, 'calibration'::text]));

insert into public.cards (slug, name, hp, attack, power, move, mov, range, rmin, rmax, crmin, crmax, dmin, dmax, burns, heals, poisons_adjacent, stuns, parries, parry_all, tramples, sneaks, flies, cures, blooms, swamps, role, is_active, is_test_card, ability, accent, sort) values
('calib-0000-none', 'Calib #1 P10H60R1M1 none', 60, 10, 10, 1, 1, 1, 1, 1, 1, 1, 8, 12, false, false, false, false, false, false, false, false, false, false, false, false, 'knight', true, true, 'Calibration test card -- no special ability.', '#94a3b8', 9001),
('calib-0000-burn', 'Calib #2 P10H60R1M1 burn', 60, 10, 10, 1, 1, 1, 1, 1, 1, 1, 8, 12, true, false, false, false, false, false, false, false, false, false, false, false, 'knight', true, true, 'Calibration test card -- burns on hit.', '#94a3b8', 9002),
('calib-0000-poison', 'Calib #3 P10H60R1M1 poison', 60, 10, 10, 1, 1, 1, 1, 1, 1, 1, 8, 12, false, false, true, false, false, false, false, false, false, false, false, false, 'knight', true, true, 'Calibration test card -- poisons adjacent units.', '#94a3b8', 9003),
('calib-0000-stun', 'Calib #4 P10H60R1M1 stun', 60, 10, 10, 1, 1, 1, 1, 1, 1, 1, 8, 12, false, false, false, true, false, false, false, false, false, false, false, false, 'knight', true, true, 'Calibration test card -- stuns on hit.', '#94a3b8', 9004),
('calib-0001-none', 'Calib #5 P10H60R1M3 none', 60, 10, 10, 3, 3, 1, 1, 1, 1, 1, 8, 12, false, false, false, false, false, false, false, false, false, false, false, false, 'knight', true, true, 'Calibration test card -- no special ability.', '#94a3b8', 9005),
('calib-0001-burn', 'Calib #6 P10H60R1M3 burn', 60, 10, 10, 3, 3, 1, 1, 1, 1, 1, 8, 12, true, false, false, false, false, false, false, false, false, false, false, false, 'knight', true, true, 'Calibration test card -- burns on hit.', '#94a3b8', 9006),
('calib-0001-poison', 'Calib #7 P10H60R1M3 poison', 60, 10, 10, 3, 3, 1, 1, 1, 1, 1, 8, 12, false, false, true, false, false, false, false, false, false, false, false, false, 'knight', true, true, 'Calibration test card -- poisons adjacent units.', '#94a3b8', 9007),
('calib-0001-stun', 'Calib #8 P10H60R1M3 stun', 60, 10, 10, 3, 3, 1, 1, 1, 1, 1, 8, 12, false, false, false, true, false, false, false, false, false, false, false, false, 'knight', true, true, 'Calibration test card -- stuns on hit.', '#94a3b8', 9008),
('calib-0010-none', 'Calib #9 P10H60R3M1 none', 60, 10, 10, 1, 1, 3, 1, 3, 1, 3, 8, 12, false, false, false, false, false, false, false, false, false, false, false, false, 'mage', true, true, 'Calibration test card -- no special ability.', '#94a3b8', 9009),
('calib-0010-burn', 'Calib #10 P10H60R3M1 burn', 60, 10, 10, 1, 1, 3, 1, 3, 1, 3, 8, 12, true, false, false, false, false, false, false, false, false, false, false, false, 'mage', true, true, 'Calibration test card -- burns on hit.', '#94a3b8', 9010),
('calib-0010-poison', 'Calib #11 P10H60R3M1 poison', 60, 10, 10, 1, 1, 3, 1, 3, 1, 3, 8, 12, false, false, true, false, false, false, false, false, false, false, false, false, 'mage', true, true, 'Calibration test card -- poisons adjacent units.', '#94a3b8', 9011),
('calib-0010-stun', 'Calib #12 P10H60R3M1 stun', 60, 10, 10, 1, 1, 3, 1, 3, 1, 3, 8, 12, false, false, false, true, false, false, false, false, false, false, false, false, 'mage', true, true, 'Calibration test card -- stuns on hit.', '#94a3b8', 9012),
('calib-0011-none', 'Calib #13 P10H60R3M3 none', 60, 10, 10, 3, 3, 3, 1, 3, 1, 3, 8, 12, false, false, false, false, false, false, false, false, false, false, false, false, 'mage', true, true, 'Calibration test card -- no special ability.', '#94a3b8', 9013),
('calib-0011-burn', 'Calib #14 P10H60R3M3 burn', 60, 10, 10, 3, 3, 3, 1, 3, 1, 3, 8, 12, true, false, false, false, false, false, false, false, false, false, false, false, 'mage', true, true, 'Calibration test card -- burns on hit.', '#94a3b8', 9014),
('calib-0011-poison', 'Calib #15 P10H60R3M3 poison', 60, 10, 10, 3, 3, 3, 1, 3, 1, 3, 8, 12, false, false, true, false, false, false, false, false, false, false, false, false, 'mage', true, true, 'Calibration test card -- poisons adjacent units.', '#94a3b8', 9015),
('calib-0011-stun', 'Calib #16 P10H60R3M3 stun', 60, 10, 10, 3, 3, 3, 1, 3, 1, 3, 8, 12, false, false, false, true, false, false, false, false, false, false, false, false, 'mage', true, true, 'Calibration test card -- stuns on hit.', '#94a3b8', 9016),
('calib-0100-none', 'Calib #17 P10H110R1M1 none', 110, 10, 10, 1, 1, 1, 1, 1, 1, 1, 8, 12, false, false, false, false, false, false, false, false, false, false, false, false, 'knight', true, true, 'Calibration test card -- no special ability.', '#94a3b8', 9017),
('calib-0100-burn', 'Calib #18 P10H110R1M1 burn', 110, 10, 10, 1, 1, 1, 1, 1, 1, 1, 8, 12, true, false, false, false, false, false, false, false, false, false, false, false, 'knight', true, true, 'Calibration test card -- burns on hit.', '#94a3b8', 9018),
('calib-0100-poison', 'Calib #19 P10H110R1M1 poison', 110, 10, 10, 1, 1, 1, 1, 1, 1, 1, 8, 12, false, false, true, false, false, false, false, false, false, false, false, false, 'knight', true, true, 'Calibration test card -- poisons adjacent units.', '#94a3b8', 9019),
('calib-0100-stun', 'Calib #20 P10H110R1M1 stun', 110, 10, 10, 1, 1, 1, 1, 1, 1, 1, 8, 12, false, false, false, true, false, false, false, false, false, false, false, false, 'knight', true, true, 'Calibration test card -- stuns on hit.', '#94a3b8', 9020),
('calib-0101-none', 'Calib #21 P10H110R1M3 none', 110, 10, 10, 3, 3, 1, 1, 1, 1, 1, 8, 12, false, false, false, false, false, false, false, false, false, false, false, false, 'knight', true, true, 'Calibration test card -- no special ability.', '#94a3b8', 9021),
('calib-0101-burn', 'Calib #22 P10H110R1M3 burn', 110, 10, 10, 3, 3, 1, 1, 1, 1, 1, 8, 12, true, false, false, false, false, false, false, false, false, false, false, false, 'knight', true, true, 'Calibration test card -- burns on hit.', '#94a3b8', 9022),
('calib-0101-poison', 'Calib #23 P10H110R1M3 poison', 110, 10, 10, 3, 3, 1, 1, 1, 1, 1, 8, 12, false, false, true, false, false, false, false, false, false, false, false, false, 'knight', true, true, 'Calibration test card -- poisons adjacent units.', '#94a3b8', 9023),
('calib-0101-stun', 'Calib #24 P10H110R1M3 stun', 110, 10, 10, 3, 3, 1, 1, 1, 1, 1, 8, 12, false, false, false, true, false, false, false, false, false, false, false, false, 'knight', true, true, 'Calibration test card -- stuns on hit.', '#94a3b8', 9024),
('calib-0110-none', 'Calib #25 P10H110R3M1 none', 110, 10, 10, 1, 1, 3, 1, 3, 1, 3, 8, 12, false, false, false, false, false, false, false, false, false, false, false, false, 'mage', true, true, 'Calibration test card -- no special ability.', '#94a3b8', 9025),
('calib-0110-burn', 'Calib #26 P10H110R3M1 burn', 110, 10, 10, 1, 1, 3, 1, 3, 1, 3, 8, 12, true, false, false, false, false, false, false, false, false, false, false, false, 'mage', true, true, 'Calibration test card -- burns on hit.', '#94a3b8', 9026),
('calib-0110-poison', 'Calib #27 P10H110R3M1 poison', 110, 10, 10, 1, 1, 3, 1, 3, 1, 3, 8, 12, false, false, true, false, false, false, false, false, false, false, false, false, 'mage', true, true, 'Calibration test card -- poisons adjacent units.', '#94a3b8', 9027),
('calib-0110-stun', 'Calib #28 P10H110R3M1 stun', 110, 10, 10, 1, 1, 3, 1, 3, 1, 3, 8, 12, false, false, false, true, false, false, false, false, false, false, false, false, 'mage', true, true, 'Calibration test card -- stuns on hit.', '#94a3b8', 9028),
('calib-0111-none', 'Calib #29 P10H110R3M3 none', 110, 10, 10, 3, 3, 3, 1, 3, 1, 3, 8, 12, false, false, false, false, false, false, false, false, false, false, false, false, 'mage', true, true, 'Calibration test card -- no special ability.', '#94a3b8', 9029),
('calib-0111-burn', 'Calib #30 P10H110R3M3 burn', 110, 10, 10, 3, 3, 3, 1, 3, 1, 3, 8, 12, true, false, false, false, false, false, false, false, false, false, false, false, 'mage', true, true, 'Calibration test card -- burns on hit.', '#94a3b8', 9030),
('calib-0111-poison', 'Calib #31 P10H110R3M3 poison', 110, 10, 10, 3, 3, 3, 1, 3, 1, 3, 8, 12, false, false, true, false, false, false, false, false, false, false, false, false, 'mage', true, true, 'Calibration test card -- poisons adjacent units.', '#94a3b8', 9031),
('calib-0111-stun', 'Calib #32 P10H110R3M3 stun', 110, 10, 10, 3, 3, 3, 1, 3, 1, 3, 8, 12, false, false, false, true, false, false, false, false, false, false, false, false, 'mage', true, true, 'Calibration test card -- stuns on hit.', '#94a3b8', 9032),
('calib-1000-none', 'Calib #33 P30H60R1M1 none', 60, 30, 30, 1, 1, 1, 1, 1, 1, 1, 28, 32, false, false, false, false, false, false, false, false, false, false, false, false, 'knight', true, true, 'Calibration test card -- no special ability.', '#94a3b8', 9033),
('calib-1000-burn', 'Calib #34 P30H60R1M1 burn', 60, 30, 30, 1, 1, 1, 1, 1, 1, 1, 28, 32, true, false, false, false, false, false, false, false, false, false, false, false, 'knight', true, true, 'Calibration test card -- burns on hit.', '#94a3b8', 9034),
('calib-1000-poison', 'Calib #35 P30H60R1M1 poison', 60, 30, 30, 1, 1, 1, 1, 1, 1, 1, 28, 32, false, false, true, false, false, false, false, false, false, false, false, false, 'knight', true, true, 'Calibration test card -- poisons adjacent units.', '#94a3b8', 9035),
('calib-1000-stun', 'Calib #36 P30H60R1M1 stun', 60, 30, 30, 1, 1, 1, 1, 1, 1, 1, 28, 32, false, false, false, true, false, false, false, false, false, false, false, false, 'knight', true, true, 'Calibration test card -- stuns on hit.', '#94a3b8', 9036),
('calib-1001-none', 'Calib #37 P30H60R1M3 none', 60, 30, 30, 3, 3, 1, 1, 1, 1, 1, 28, 32, false, false, false, false, false, false, false, false, false, false, false, false, 'knight', true, true, 'Calibration test card -- no special ability.', '#94a3b8', 9037),
('calib-1001-burn', 'Calib #38 P30H60R1M3 burn', 60, 30, 30, 3, 3, 1, 1, 1, 1, 1, 28, 32, true, false, false, false, false, false, false, false, false, false, false, false, 'knight', true, true, 'Calibration test card -- burns on hit.', '#94a3b8', 9038),
('calib-1001-poison', 'Calib #39 P30H60R1M3 poison', 60, 30, 30, 3, 3, 1, 1, 1, 1, 1, 28, 32, false, false, true, false, false, false, false, false, false, false, false, false, 'knight', true, true, 'Calibration test card -- poisons adjacent units.', '#94a3b8', 9039),
('calib-1001-stun', 'Calib #40 P30H60R1M3 stun', 60, 30, 30, 3, 3, 1, 1, 1, 1, 1, 28, 32, false, false, false, true, false, false, false, false, false, false, false, false, 'knight', true, true, 'Calibration test card -- stuns on hit.', '#94a3b8', 9040),
('calib-1010-none', 'Calib #41 P30H60R3M1 none', 60, 30, 30, 1, 1, 3, 1, 3, 1, 3, 28, 32, false, false, false, false, false, false, false, false, false, false, false, false, 'mage', true, true, 'Calibration test card -- no special ability.', '#94a3b8', 9041),
('calib-1010-burn', 'Calib #42 P30H60R3M1 burn', 60, 30, 30, 1, 1, 3, 1, 3, 1, 3, 28, 32, true, false, false, false, false, false, false, false, false, false, false, false, 'mage', true, true, 'Calibration test card -- burns on hit.', '#94a3b8', 9042),
('calib-1010-poison', 'Calib #43 P30H60R3M1 poison', 60, 30, 30, 1, 1, 3, 1, 3, 1, 3, 28, 32, false, false, true, false, false, false, false, false, false, false, false, false, 'mage', true, true, 'Calibration test card -- poisons adjacent units.', '#94a3b8', 9043),
('calib-1010-stun', 'Calib #44 P30H60R3M1 stun', 60, 30, 30, 1, 1, 3, 1, 3, 1, 3, 28, 32, false, false, false, true, false, false, false, false, false, false, false, false, 'mage', true, true, 'Calibration test card -- stuns on hit.', '#94a3b8', 9044),
('calib-1011-none', 'Calib #45 P30H60R3M3 none', 60, 30, 30, 3, 3, 3, 1, 3, 1, 3, 28, 32, false, false, false, false, false, false, false, false, false, false, false, false, 'mage', true, true, 'Calibration test card -- no special ability.', '#94a3b8', 9045),
('calib-1011-burn', 'Calib #46 P30H60R3M3 burn', 60, 30, 30, 3, 3, 3, 1, 3, 1, 3, 28, 32, true, false, false, false, false, false, false, false, false, false, false, false, 'mage', true, true, 'Calibration test card -- burns on hit.', '#94a3b8', 9046),
('calib-1011-poison', 'Calib #47 P30H60R3M3 poison', 60, 30, 30, 3, 3, 3, 1, 3, 1, 3, 28, 32, false, false, true, false, false, false, false, false, false, false, false, false, 'mage', true, true, 'Calibration test card -- poisons adjacent units.', '#94a3b8', 9047),
('calib-1011-stun', 'Calib #48 P30H60R3M3 stun', 60, 30, 30, 3, 3, 3, 1, 3, 1, 3, 28, 32, false, false, false, true, false, false, false, false, false, false, false, false, 'mage', true, true, 'Calibration test card -- stuns on hit.', '#94a3b8', 9048),
('calib-1100-none', 'Calib #49 P30H110R1M1 none', 110, 30, 30, 1, 1, 1, 1, 1, 1, 1, 28, 32, false, false, false, false, false, false, false, false, false, false, false, false, 'knight', true, true, 'Calibration test card -- no special ability.', '#94a3b8', 9049),
('calib-1100-burn', 'Calib #50 P30H110R1M1 burn', 110, 30, 30, 1, 1, 1, 1, 1, 1, 1, 28, 32, true, false, false, false, false, false, false, false, false, false, false, false, 'knight', true, true, 'Calibration test card -- burns on hit.', '#94a3b8', 9050),
('calib-1100-poison', 'Calib #51 P30H110R1M1 poison', 110, 30, 30, 1, 1, 1, 1, 1, 1, 1, 28, 32, false, false, true, false, false, false, false, false, false, false, false, false, 'knight', true, true, 'Calibration test card -- poisons adjacent units.', '#94a3b8', 9051),
('calib-1100-stun', 'Calib #52 P30H110R1M1 stun', 110, 30, 30, 1, 1, 1, 1, 1, 1, 1, 28, 32, false, false, false, true, false, false, false, false, false, false, false, false, 'knight', true, true, 'Calibration test card -- stuns on hit.', '#94a3b8', 9052),
('calib-1101-none', 'Calib #53 P30H110R1M3 none', 110, 30, 30, 3, 3, 1, 1, 1, 1, 1, 28, 32, false, false, false, false, false, false, false, false, false, false, false, false, 'knight', true, true, 'Calibration test card -- no special ability.', '#94a3b8', 9053),
('calib-1101-burn', 'Calib #54 P30H110R1M3 burn', 110, 30, 30, 3, 3, 1, 1, 1, 1, 1, 28, 32, true, false, false, false, false, false, false, false, false, false, false, false, 'knight', true, true, 'Calibration test card -- burns on hit.', '#94a3b8', 9054),
('calib-1101-poison', 'Calib #55 P30H110R1M3 poison', 110, 30, 30, 3, 3, 1, 1, 1, 1, 1, 28, 32, false, false, true, false, false, false, false, false, false, false, false, false, 'knight', true, true, 'Calibration test card -- poisons adjacent units.', '#94a3b8', 9055),
('calib-1101-stun', 'Calib #56 P30H110R1M3 stun', 110, 30, 30, 3, 3, 1, 1, 1, 1, 1, 28, 32, false, false, false, true, false, false, false, false, false, false, false, false, 'knight', true, true, 'Calibration test card -- stuns on hit.', '#94a3b8', 9056),
('calib-1110-none', 'Calib #57 P30H110R3M1 none', 110, 30, 30, 1, 1, 3, 1, 3, 1, 3, 28, 32, false, false, false, false, false, false, false, false, false, false, false, false, 'mage', true, true, 'Calibration test card -- no special ability.', '#94a3b8', 9057),
('calib-1110-burn', 'Calib #58 P30H110R3M1 burn', 110, 30, 30, 1, 1, 3, 1, 3, 1, 3, 28, 32, true, false, false, false, false, false, false, false, false, false, false, false, 'mage', true, true, 'Calibration test card -- burns on hit.', '#94a3b8', 9058),
('calib-1110-poison', 'Calib #59 P30H110R3M1 poison', 110, 30, 30, 1, 1, 3, 1, 3, 1, 3, 28, 32, false, false, true, false, false, false, false, false, false, false, false, false, 'mage', true, true, 'Calibration test card -- poisons adjacent units.', '#94a3b8', 9059),
('calib-1110-stun', 'Calib #60 P30H110R3M1 stun', 110, 30, 30, 1, 1, 3, 1, 3, 1, 3, 28, 32, false, false, false, true, false, false, false, false, false, false, false, false, 'mage', true, true, 'Calibration test card -- stuns on hit.', '#94a3b8', 9060),
('calib-1111-none', 'Calib #61 P30H110R3M3 none', 110, 30, 30, 3, 3, 3, 1, 3, 1, 3, 28, 32, false, false, false, false, false, false, false, false, false, false, false, false, 'mage', true, true, 'Calibration test card -- no special ability.', '#94a3b8', 9061),
('calib-1111-burn', 'Calib #62 P30H110R3M3 burn', 110, 30, 30, 3, 3, 3, 1, 3, 1, 3, 28, 32, true, false, false, false, false, false, false, false, false, false, false, false, 'mage', true, true, 'Calibration test card -- burns on hit.', '#94a3b8', 9062),
('calib-1111-poison', 'Calib #63 P30H110R3M3 poison', 110, 30, 30, 3, 3, 3, 1, 3, 1, 3, 28, 32, false, false, true, false, false, false, false, false, false, false, false, false, 'mage', true, true, 'Calibration test card -- poisons adjacent units.', '#94a3b8', 9063),
('calib-1111-stun', 'Calib #64 P30H110R3M3 stun', 110, 30, 30, 3, 3, 3, 1, 3, 1, 3, 28, 32, false, false, false, true, false, false, false, false, false, false, false, false, 'mage', true, true, 'Calibration test card -- stuns on hit.', '#94a3b8', 9064),
('calib-royal', 'Calib Royal Center', 85, 20, 20, 2, 2, 2, 1, 2, 1, 2, 18, 22, false, false, false, false, false, false, false, false, true, false, false, false, 'royal', true, true, 'Calibration test card -- royal center point, no special ability.', '#94a3b8', 9999);

create or replace function public.random_deck_from(p_pool text[])
 returns text[]
 language sql
 security definer
 set search_path to 'public'
as $function$
  select array_agg(slug) from (
    (select slug from public.cards
      where is_active and slug is not null and royal and slug = any(p_pool)
      order by random() limit 1)
    union all
    (select slug from public.cards
      where is_active and slug is not null and not royal and slug = any(p_pool)
      order by random() limit (deck_size() - 1))
  ) s
$function$;

-- Trimmed copy of admin_run_training_batch: same per-game bookkeeping
-- (sim_games / sim_unit_stats), no promotion logic (not what this run is
-- for), decks drawn from a caller-supplied pool instead of the live
-- roster, and both sides played by the SAME fixed brain (this is about
-- measuring what stats/abilities are worth in a fair fight, not pitting
-- one bot brain against another).
create or replace function public.admin_run_calibration_batch(
  p_run uuid, p_pool text[], p_brain uuid,
  p_batch integer default 30, p_deadline_seconds numeric default 12
)
 returns training_runs
 language plpgsql
 set search_path to 'public'
as $function$
declare
  v_run public.training_runs; v_n int; i int; v_deadline timestamptz;
  v_host_deck text[]; v_guest_deck text[];
  v_result record; v_game public.matches; v_stats jsonb; v_roster jsonb; v_sim_game_id uuid;
  v_u jsonb; v_win text; v_carry_uid text; v_carry_score numeric;
begin
  perform admin_require_admin();

  select * into v_run from public.training_runs where id = p_run for update;
  if v_run.id is null then raise exception 'no such training run'; end if;
  if v_run.status in ('completed', 'cancelled', 'failed') then return v_run; end if;

  if v_run.status = 'pending' then
    update public.training_runs set status = 'running', started_at = now()
      where id = v_run.id returning * into v_run;
  end if;

  v_deadline := clock_timestamp() + make_interval(secs => greatest(0.5, coalesce(p_deadline_seconds, 12)));

  v_n := least(coalesce(p_batch, 30), v_run.games_requested - v_run.games_completed);
  for i in 1 .. greatest(v_n, 0) loop
    exit when clock_timestamp() >= v_deadline;

    v_host_deck := random_deck_from(p_pool);
    v_guest_deck := random_deck_from(p_pool);

    select * into v_result from sim_play_one_game(
      v_run.id, v_run.level, v_host_deck, v_guest_deck, p_brain, p_brain, v_deadline);
    v_game := v_result.game;
    v_stats := v_result.stats;
    v_roster := v_result.roster;
    v_win := v_game.state->>'winner';

    insert into public.sim_games
      (training_run_id, match_id, host_deck, guest_deck, host_brain_id, guest_brain_id,
       winner, turns, capped)
    values
      (v_run.id, v_game.id, v_host_deck, v_guest_deck, p_brain, p_brain,
       nullif(v_win, ''), coalesce((v_game.state->>'turnNumber')::int, 0), v_win is null)
    returning id into v_sim_game_id;

    v_carry_uid := null; v_carry_score := -1;
    if v_win in ('host', 'guest') then
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
         coalesce(v_win in ('host', 'guest') and v_u->>'owner' = v_win, false),
         coalesce((v_stats->(v_u->>'id')->>'turns_alive')::numeric, 0)::int,
         coalesce((v_stats->(v_u->>'id')->>'damage_dealt')::numeric, 0),
         coalesce((v_stats->(v_u->>'id')->>'damage_taken')::numeric, 0),
         coalesce((v_stats->(v_u->>'id')->>'healing_done')::numeric, 0),
         coalesce((v_stats->(v_u->>'id')->>'kills')::numeric, 0)::int,
         coalesce((v_stats->(v_u->>'id')->>'deaths')::numeric, 0)::int,
         greatest(0, coalesce((
           select (u2->>'hp')::int from jsonb_array_elements(v_game.state->'units') u2
           where u2->>'id' = v_u->>'id'), 0)),
         coalesce(v_u->>'id' = v_carry_uid, false));
    end loop;

    update public.training_runs set games_completed = games_completed + 1
      where id = v_run.id returning * into v_run;
  end loop;

  if v_run.games_completed >= v_run.games_requested then
    update public.training_runs
      set status = 'completed', finished_at = now()
      where id = v_run.id returning * into v_run;
  end if;

  return v_run;
end
$function$;
