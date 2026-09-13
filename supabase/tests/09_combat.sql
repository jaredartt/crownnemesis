-- Phase A: the combat core. Counters at half, the 5% parry and its chain, the
-- 5% crit, one number plus or minus five, and the crown that ends a match.
--
-- Parry and crit are dice, so every assertion here pins them. _helpers.sql
-- turns both OFF for the whole test database; a section that wants one turns
-- it on for as long as it needs and resets it after, so a forgotten `set`
-- cannot leak into the section below.
\set ON_ERROR_STOP on
\pset pager off

delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('cccc0000-0000-0000-0000-00000000000c','c@x.com','{"username":"cass"}'),
  ('dddd0000-0000-0000-0000-00000000000d','d@x.com','{"username":"dev"}');

-- ---- the arithmetic, before any board -----------------------------------
-- base -> crit -> counter -> bonus -> resist -> defending -> round
select t_ok(public.cn_damage(40, false, false) = 40, 'a plain blow is its roll');
select t_ok(public.cn_damage(40, true,  false) = 60, 'a crit is half again');
select t_ok(public.cn_damage(40, false, true ) = 20, 'a counter is half');
select t_ok(public.cn_damage(40, true,  true ) = 30, 'a critical counter is both');
select t_ok(public.cn_damage(40, false, false, 0.2)      = 48, 'a bonus multiplies up');
select t_ok(public.cn_damage(40, false, false, 0,   0.2) = 32, 'a resist multiplies down');
select t_ok(public.cn_damage(40, false, false, 0.2, 0.2) = 38,
            'and a bonus and an equal resist do not cancel -- bonus first, then resist');
select t_ok(public.cn_damage(40, false, false, 0, 0, true) = 20, 'defending halves it');
select t_ok(public.cn_damage(40, true, true, 0, 0, true) = 15,
            'all three at once, in that order');
select t_ok(public.cn_damage(1, false, true) = 1,
            'half of a rounding edge is never less than nothing');

select t_ok(public.cn_parry_cap() = 8, 'the parry chain is capped at eight');
select t_ok(public.cn_spread() = 5, 'a power is plus or minus five');

-- the forcing hatch itself, or none of the rest of this file proves anything
set cn.force_parry = 'always';
select t_ok(public.cn_chance(5, 'parry'), 'a forced roll always succeeds');
select t_ok(not public.cn_chance(0, 'parry'),
            'but a certainty is not a roll -- 0% still never catches anything');
set cn.force_parry = 'never';
select t_ok(not public.cn_chance(5, 'parry'), 'a suppressed roll always fails');
select t_ok(public.cn_chance(100, 'parry'), 'and 100% still catches everything');
reset cn.force_parry;

-- ---- one number, plus or minus five --------------------------------------
select t_ok((select count(*) = 0 from public.cards
              where is_active and (dmin <> power - cn_spread() or dmax <> power + cn_spread())),
            'every card''s band is exactly its power plus or minus five');
select t_ok((select min(r) = 15 and max(r) = 25 from (
               select public.cn_roll(15, 25) as r from generate_series(1, 400)) s),
            'and a 20-power unit rolls the whole 15-25 and nothing outside it');

-- ---- a kingdom needs its crown -------------------------------------------
select t_ok(public.deck_royals(array['dione-grifo','dereo','mako','wuzu','eva']) = 1,
            'a deck with Dereo holds one royal');
select t_ok(public.deck_royals(array['dione-grifo','lium','mako','wuzu','eva']) = 0,
            'and one without him holds none');

select set_config('app.uid','cccc0000-0000-0000-0000-00000000000c',false);
select t_raises('select public.set_deck(array[''dione-grifo'',''lium'',''mako'',''wuzu'',''eva''])',
                'needs a royal', 'a crownless kingdom cannot be saved');
select public.set_deck(array['dione-grifo','dereo','mako','wuzu','eva']);

-- A deck saved before 0018 existed, or one whose royal was retired since, is
-- not an army -- it is a match that could never end. It falls back instead.
--
-- The kingdoms list is emptied alongside the column because since 0024 that
-- list is where the truth lives and profiles.deck is a mirror of it. A profile
-- carrying a deck and no kingdoms is not a contrivance to make this line pass:
-- it is EXACTLY the account this assertion is about -- one saved before any of
-- this existed. (0024's own file covers the other half, a crownless kingdom
-- that is selected.)
update public.profiles
   set deck = array['dione-grifo','lium','mako','wuzu','eva'],
       kingdoms = '[]'::jsonb
 where id = 'cccc0000-0000-0000-0000-00000000000c';
select t_ok(public.deck_of('cccc0000-0000-0000-0000-00000000000c') = public.default_deck(),
            'a crownless saved deck falls back to the default');
select t_ok(public.deck_royals(public.default_deck()) = 1,
            'and the default itself holds exactly one');
select public.set_deck(array['dione-grifo','dereo','mako','wuzu','eva']);

select t_ok((select bool_and(public.deck_royals(public.random_deck()) = 1)
               from generate_series(1, 30)),
            'the bot draws under the same rule, every time');

select set_config('app.uid','dddd0000-0000-0000-0000-00000000000d',false);
select public.set_deck(array['dereo','umiro','lumea','fey','sinie']);

-- ---- the board -----------------------------------------------------------
select t_match('cccc0000-0000-0000-0000-00000000000c',
               'dddd0000-0000-0000-0000-00000000000d') as m \gset
select set_config('app.uid','cccc0000-0000-0000-0000-00000000000c',false);
select t_trees(:'m', '[]'::jsonb);
select t_park(:'m', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);
select t_ok(t_get(:'m','h1','name') = 'Dione & Grifo', 'the host leads with the pair');
select t_ok(t_get(:'m','g3','name') = 'Lumea', 'and the guest fields Lumea in slot 3');
select t_ok(t_get(:'m','h2','royal') = 'true', 'the crown came onto the board flagged');
-- 30 since 0031: the spec's number for the pair, where the live roster had 22.
select t_ok(t_get(:'m','h1','pow')::int = 30, 'and every unit carries its single number');
select t_ok(t_get(:'m','h1','parryPct')::int = 5 and t_get(:'m','h1','critPct')::int = 5,
            'with the two rates beside it');
select t_ok(t_get(:'m','g1','parryPct')::int = 5, 'Lium is the only one better at it');

-- Stand the two of them a tile apart and fix both to 40, so every number
-- below is exact rather than a band.
create or replace function t_duel(p_m uuid) returns void language sql as $$
  select t_reset(p_m), t_noauras(p_m),
         t_place(p_m,'h1',2,2), t_place(p_m,'g3',2,3),
         t_full(p_m,'h1'), t_full(p_m,'g3'),
         t_dmg(p_m,'h1',40), t_dmg(p_m,'g3',40),
         t_set(p_m,'h1','rmin','1'::jsonb), t_set(p_m,'h1','rmax','1'::jsonb),
         t_set(p_m,'h1','crmin','1'::jsonb), t_set(p_m,'h1','crmax','1'::jsonb),
         t_set(p_m,'g3','rmin','1'::jsonb), t_set(p_m,'g3','rmax','1'::jsonb),
         t_set(p_m,'g3','crmin','1'::jsonb), t_set(p_m,'g3','crmax','1'::jsonb),
         t_hp(p_m,'h1',110), t_hp(p_m,'g3',110), t_set(p_m,'g3','maxHp','110'::jsonb),
         -- the rates and the passive go back to ordinary too: a section that
         -- zeroed one of them must not be the reason the next section passes
         t_set(p_m,'h1','parryPct','5'::jsonb), t_set(p_m,'g3','parryPct','5'::jsonb),
         t_set(p_m,'h1','critPct','5'::jsonb),  t_set(p_m,'g3','critPct','5'::jsonb),
         t_set(p_m,'h1','parries','false'::jsonb), t_set(p_m,'g3','parries','false'::jsonb);
$$;

-- ---- the counter is always, and it is half -------------------------------
set cn.force_parry = 'never'; set cn.force_crit = 'never';

select t_duel(:'m');
select public.submit_attack(:'m','h1','g3');
select t_ok(t_get(:'m','g3','hp')::int = 70, 'the blow lands in full');
select t_ok(t_get(:'m','h1','hp')::int = 90,
            'and the answer comes back for exactly half -- 20, not 40');
select t_ok(t_fx(:'m','counter')::int = 20, 'the clients are told the same number');

-- A dead defender does not answer. This is the one case where the counter is
-- not automatic, and it is the reason to swing first.
-- Fey takes this one, not Lumea: a killed unit leaves the board for good, and
-- every section below still needs Lumea standing.
select t_duel(:'m'); select t_place(:'m','g3',5,5);
select t_place(:'m','g4',2,3); select t_hp(:'m','g4',30); select t_dmg(:'m','g4',40);
select t_set(:'m','g4','crmin','1'::jsonb); select t_set(:'m','g4','crmax','1'::jsonb);
select public.submit_attack(:'m','h1','g4');
select t_ok(not t_alive(:'m','g4'), 'a 40 through 30 hit points kills');
select t_ok(t_get(:'m','h1','hp')::int = 110, 'and the dead do not answer');

-- Out of the defender's counter reach, nothing comes back.
select t_duel(:'m');
select t_set(:'m','h1','rmax','2'::jsonb); select t_place(:'m','h1',2,1);
select public.submit_attack(:'m','h1','g3');
select t_ok(t_get(:'m','g3','hp')::int = 70, 'a mage two tiles out still hits');
select t_ok(t_get(:'m','h1','hp')::int = 110, 'and takes nothing back');

-- ---- the crit -------------------------------------------------------------
set cn.force_crit = 'always';
select t_duel(:'m');
select public.submit_attack(:'m','h1','g3');
select t_ok(t_get(:'m','g3','hp')::int = 50, 'a critical blow is 60, not 40');
select t_ok(t_get(:'m','h1','hp')::int = 80,
            'and a critical answer is 30 -- half of half-again, not half-again of half');
select t_ok(t_fx(:'m','crit') = 'true' and t_fx(:'m','critCounter') = 'true',
            'both are flagged for the cinematic');
set cn.force_crit = 'never';

-- ---- the parry ------------------------------------------------------------
set cn.force_parry = 'always';

select t_duel(:'m');
select t_set(:'m','h1','parryPct','0'::jsonb);   -- only the defender catches it
select public.submit_attack(:'m','h1','g3');
select t_ok(t_get(:'m','g3','hp')::int = 110, 'a parry blocks the blow completely');
select t_ok(t_fx(:'m','dmg')::int = 0, 'recorded as no damage dealt');
select t_ok(t_fx(:'m','parry') = 'true', 'and flagged as a parry');
select t_ok(t_get(:'m','h1','hp')::int = 90, 'the parrier answers for half');
select t_ok(t_fx(:'m','chain')::int = 2, 'two swings: the caught one and the answer');

-- A parry from somewhere it cannot reach back to blocks, and that is all.
select t_duel(:'m');
select t_set(:'m','h1','parryPct','0'::jsonb);
select t_set(:'m','h1','rmax','2'::jsonb); select t_place(:'m','h1',2,1);
select public.submit_attack(:'m','h1','g3');
select t_ok(t_get(:'m','g3','hp')::int = 110, 'it still blocks at two tiles');
select t_ok(t_get(:'m','h1','hp')::int = 110, 'but a parry it cannot reach answers nothing');
select t_ok(t_fx(:'m','chain')::int = 1, 'one swing, and the exchange is over');

-- Both of them catching everything is the case that could run forever.
select t_duel(:'m');
select public.submit_attack(:'m','h1','g3');
select t_ok(t_fx(:'m','chain')::int = public.cn_parry_cap(),
            'two perfect parriers stop at the cap, not at the heat death of the universe');
select t_ok(t_fx(:'m','parries')::int = public.cn_parry_cap(), 'every swing of it caught');
select t_ok(t_get(:'m','h1','hp')::int = 110 and t_get(:'m','g3','hp')::int = 110,
            'and nobody is touched by any of it');

-- A thief is never answered, and a parry is an answer.
select t_duel(:'m'); select t_place(:'m','h3',2,2); select t_place(:'m','g3',2,3);
select t_dmg(:'m','h3',40); select t_set(:'m','h3','parryPct','0'::jsonb);
select public.submit_attack(:'m','h3','g3');
select t_ok(t_get(:'m','g3','hp')::int = 110, 'Mako''s blow is caught like anyone else''s');
select t_ok(t_get(:'m','h3','hp')::int < 60,
            'and the parry answers it, because nothing sneaks any more');

-- A passive is not a blow, so nothing catches it. Quick Dagger answers first
-- THROUGH an attacker who parries absolutely everything.
set cn.force_parry = 'never';
select t_duel(:'m');
select t_set(:'m','g3','parries','true'::jsonb);   -- Quick Dagger on the defender
select t_set(:'m','h1','parryPct','100'::jsonb);
set cn.force_parry = 'always';
select public.submit_attack(:'m','h1','g3');
select t_ok(t_get(:'m','h1','hp')::int < 110,
            'the answer-first is a passive, so the attacker cannot parry it');
reset cn.force_parry;

-- ---- mending is not an exchange, and is not an attack either -------------
-- This section used to mend by ATTACKING an ally, which is how Eva, Umiro and
-- Sinie worked until 0033. Healing is an ability now and lives in
-- 24_abilities.sql; what is left here is the rule that replaced it.
-- Since 0038 an ally CAN be attacked, and the rule worth pinning is the one
-- that comes with it: your own soldier does not answer. A counter is what
-- somebody does when an ENEMY attacks them.
select t_reset(:'m'); select t_noauras(:'m');
select t_place(:'m','h5',2,2); select t_place(:'m','h1',2,3);
select t_full(:'m','h1'); select t_full(:'m','h5');
select t_dmg(:'m','h5',20); select t_dmg(:'m','h1',20);
select public.submit_attack(:'m','h5','h1');
select t_ok(t_get(:'m','h1','hp')::int = t_get(:'m','h1','maxHp')::int - 20,
            'YOU MAY STRIKE YOUR OWN, for the ordinary twenty');
select t_ok(t_get(:'m','h5','hp')::int = t_get(:'m','h5','maxHp')::int,
            'AND IT DOES NOT ANSWER — nobody counters their own side');
select t_ok(t_fx(:'m','counter')::int = 0, 'which the old field agrees with');

-- ---- the crown ------------------------------------------------------------
-- Its own match: the one above has to survive the assertions after it.
select set_config('app.uid','cccc0000-0000-0000-0000-00000000000c',false);
select t_match('cccc0000-0000-0000-0000-00000000000c',
               'dddd0000-0000-0000-0000-00000000000d') as k \gset
select set_config('app.uid','cccc0000-0000-0000-0000-00000000000c',false);
select t_trees(:'k', '[]'::jsonb);
select t_park(:'k', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);
set cn.force_parry = 'never'; set cn.force_crit = 'never';

select t_ok(t_get(:'k','g1','name') = 'King Dereo' and t_get(:'k','g1','royal') = 'true',
            'the guest''s crown is g1');
select t_reset(:'k');
select t_place(:'k','h1',2,2); select t_place(:'k','g1',2,3);
select t_set(:'k','h1','rmin','1'::jsonb); select t_set(:'k','h1','rmax','1'::jsonb);
select t_dmg(:'k','h1',400);
select public.submit_attack(:'k','h1','g1');

select t_ok((select status from public.matches where id=:'k') = 'finished',
            'the crown falls and the match is over');
select t_ok((select winner from public.matches where id=:'k') = 'host',
            'the other side wins it');
select t_ok((select jsonb_array_length(state->'units') from public.matches where id=:'k') = 9,
            'with four of the loser''s units still standing');
select t_ok((select count(*) from jsonb_array_elements(
               (select state->'log' from public.matches where id=:'k')) l
              where l->>'text' like '%crown has fallen%') = 1,
            'and the log says why');
reset cn.force_parry; reset cn.force_crit;
