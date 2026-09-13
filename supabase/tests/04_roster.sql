-- Combat, terrain and the two distances -- played with the real roster.
-- The abilities that are unique to one card live in 07_abilities.sql.
\set ON_ERROR_STOP on
\pset pager off

delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'a@x.com', '{"username":"ann"}'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'b@x.com', '{"username":"ben"}');

-- ---- THE ROSTER IS THE SPEC'S, unit by unit -----------------------------
--
-- Every row of section 6 of project_status.md, asserted one card at a time.
-- This block has always existed and has always been pinned to whatever the
-- database happened to hold, on purpose: "a migration named for one rule
-- cannot quietly retune a card on its way past". 0031 is the migration that is
-- ALLOWED to retune them, because retuning them to the spec is the whole of
-- what it does -- so the pins move here, once, and go back to being a guard.
--
-- The derived columns are asserted too, and that is the point of asserting
-- them: nothing below sets rmin, rmax, crmin, crmax, dmin, dmax, flies or
-- royal. All eight come out of the card trigger, and a card that arrived any
-- other way would show up here.
select t_ok((select name='King Dereo' and role='royal' and hp=110 and power=30 and mov=1
               and range=1 and rmin=1 and rmax=1 and crmin=1 and crmax=1
               and dmin=25 and dmax=35 and flies=false and royal=true
               from public.cards where slug='dereo'), 'King Dereo');
select t_ok((select name='Queen Miah' and role='royal' and hp=110 and power=25 and mov=1
               and range=1 and rmin=1 and rmax=1 and crmin=1 and crmax=1
               and dmin=20 and dmax=30 and flies=false and royal=true
               from public.cards where slug='miah'), 'Queen Miah');
select t_ok((select name='King Stelaris' and role='royal' and hp=120 and power=30 and mov=1
               and range=1 and rmin=1 and rmax=1 and crmin=1 and crmax=1
               and dmin=25 and dmax=35 and flies=false and royal=true
               from public.cards where slug='stelaris'), 'King Stelaris');
select t_ok((select name='Dione & Grifo' and role='knight' and hp=95 and power=30 and mov=1
               and range=1 and rmin=1 and rmax=1 and crmin=1 and crmax=1
               and dmin=25 and dmax=35 and flies=false and royal=false
               from public.cards where slug='dione-grifo'), 'Dione & Grifo');
select t_ok((select name='Lium' and role='knight' and hp=85 and power=35 and mov=1
               and range=1 and rmin=1 and rmax=1 and crmin=1 and crmax=1
               and dmin=30 and dmax=40 and flies=false and royal=false
               from public.cards where slug='lium'), 'Lium');
select t_ok((select name='Mako' and role='rogue' and hp=60 and power=35 and mov=2
               and range=1 and rmin=1 and rmax=1 and crmin=1 and crmax=1
               and dmin=30 and dmax=40 and flies=false and royal=false
               from public.cards where slug='mako'), 'Mako');
select t_ok((select name='Eva' and role='rogue' and hp=80 and power=20 and mov=2
               and range=2 and rmin=1 and rmax=2 and crmin=1 and crmax=2
               and dmin=15 and dmax=25 and flies=false and royal=false
               from public.cards where slug='eva'), 'Eva');
select t_ok((select name='Himanta' and role='rogue' and hp=70 and power=25 and mov=2
               and range=1 and rmin=1 and rmax=1 and crmin=1 and crmax=1
               and dmin=20 and dmax=30 and flies=false and royal=false
               from public.cards where slug='himanta'), 'Himanta');
select t_ok((select name='Dorme' and role='rogue' and hp=65 and power=30 and mov=2
               and range=2 and rmin=1 and rmax=2 and crmin=1 and crmax=2
               and dmin=25 and dmax=35 and flies=false and royal=false
               from public.cards where slug='dorme'), 'Dorme');
select t_ok((select name='Fey' and role='mage' and hp=85 and power=15 and mov=2
               and range=3 and rmin=1 and rmax=3 and crmin=1 and crmax=3
               and dmin=10 and dmax=20 and flies=false and royal=false
               from public.cards where slug='fey'), 'Fey');
select t_ok((select name='Umiro' and role='mage' and hp=75 and power=25 and mov=1
               and range=2 and rmin=1 and rmax=2 and crmin=1 and crmax=2
               and dmin=20 and dmax=30 and flies=false and royal=false
               from public.cards where slug='umiro'), 'Umiro');
select t_ok((select name='Sinie' and role='mage' and hp=65 and power=30 and mov=2
               and range=3 and rmin=1 and rmax=3 and crmin=1 and crmax=3
               and dmin=25 and dmax=35 and flies=false and royal=false
               from public.cards where slug='sinie'), 'Sinie');
select t_ok((select name='Ashvar' and role='mage' and hp=70 and power=20 and mov=2
               and range=2 and rmin=1 and rmax=2 and crmin=1 and crmax=2
               and dmin=15 and dmax=25 and flies=false and royal=false
               from public.cards where slug='ashvar'), 'Ashvar');
select t_ok((select name='Velmor' and role='mage' and hp=70 and power=35 and mov=2
               and range=2 and rmin=1 and rmax=2 and crmin=1 and crmax=2
               and dmin=30 and dmax=40 and flies=false and royal=false
               from public.cards where slug='velmor'), 'Velmor');
select t_ok((select name='Sarrave' and role='mage' and hp=80 and power=15 and mov=1
               and range=1 and rmin=1 and rmax=1 and crmin=1 and crmax=1
               and dmin=10 and dmax=20 and flies=false and royal=false
               from public.cards where slug='sarrave'), 'Sarrave');
select t_ok((select name='Thalgrim' and role='mage' and hp=80 and power=15 and mov=1
               and range=1 and rmin=1 and rmax=1 and crmin=1 and crmax=1
               and dmin=10 and dmax=20 and flies=false and royal=false
               from public.cards where slug='thalgrim'), 'Thalgrim');
select t_ok((select name='Nyxara' and role='mage' and hp=65 and power=15 and mov=2
               and range=2 and rmin=1 and rmax=2 and crmin=1 and crmax=2
               and dmin=10 and dmax=20 and flies=false and royal=false
               from public.cards where slug='nyxara'), 'Nyxara');
select t_ok((select name='Wuzu' and role='flying' and hp=85 and power=25 and mov=3
               and range=2 and rmin=1 and rmax=2 and crmin=1 and crmax=2
               and dmin=20 and dmax=30 and flies=true and royal=false
               from public.cards where slug='wuzu'), 'Wuzu');
select t_ok((select name='Lumea' and role='flying' and hp=75 and power=20 and mov=4
               and range=2 and rmin=1 and rmax=2 and crmin=1 and crmax=2
               and dmin=15 and dmax=25 and flies=true and royal=false
               from public.cards where slug='lumea'), 'Lumea');
select t_ok((select name='Zephyra' and role='flying' and hp=65 and power=20 and mov=4
               and range=1 and rmin=1 and rmax=1 and crmin=1 and crmax=1
               and dmin=15 and dmax=25 and flies=true and royal=false
               from public.cards where slug='zephyra'), 'Zephyra');

-- Twenty exist; eleven can be fielded. The nine that arrived with 0031 are
-- inactive until the ability their sentence describes exists.
-- Scoped to the twenty by name rather than counting the table: earlier files
-- in this suite add cards of their own, and a bare count would make this
-- assertion about whichever test ran first.
select t_ok((select count(*) from public.cards where slug in (
              'dereo','miah','stelaris','dione-grifo','lium','mako','eva','himanta',
              'dorme','fey','umiro','sinie','ashvar','velmor','sarrave','thalgrim',
              'nyxara','wuzu','lumea','zephyra')) = 20,
            'all twenty units of the spec are in the game');
-- All nine switched on in 0034, which is the migration that gave them the
-- burn, poison and stun their sentences needed.
select t_ok((select count(*) from public.cards where is_active and slug in (
              'miah','stelaris','dorme','ashvar','velmor','sarrave','thalgrim',
              'nyxara','zephyra')) = 9,
            'AND ALL NINE ARE PLAYABLE — the roster is the spec, at last');
-- THREE crowns since 0034, which is the first time the one-royal rule has had
-- anything to choose between: every kingdom still holds exactly one, but which
-- one is now a decision rather than a formality.
select t_ok((select count(*) from public.cards where royal and is_active) = 3,
            'THREE playable crowns, and a kingdom still takes exactly one');
select t_ok(public.deck_royals(public.default_deck()) = 1,
            'AND THE DEFAULT DECK IS STILL LEGAL — the first five by sort are now three crowns');
select t_ok((select count(*) from public.cards where tramples) = 0,
            'and nothing tramples any more — trampling is nowhere in the spec');

select set_config('app.uid', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select public.set_deck(array['dione-grifo','dereo','mako','wuzu','eva']);
select set_config('app.uid', 'bbbbbbbb-0000-0000-0000-000000000002', false);
select public.set_deck(array['dereo','eva','umiro','lumea','mako']);

select t_match('aaaaaaaa-0000-0000-0000-000000000001',
               'bbbbbbbb-0000-0000-0000-000000000002') as mid \gset
select set_config('app.uid', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select t_trees(:'mid', '[]'::jsonb);
select t_park(:'mid', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);

-- ---- movement is orthogonal; reach counts diagonals ---------------------
-- h2 rather than h4: Wuzu was the slow one until 0031 and is now a flier with
-- three tiles of movement. The spec's slowest walkers are the Royals, so the
-- crown is what cannot cover a diagonal in one step.
select t_reset(:'mid'); select t_place(:'mid','h2',2,5);       -- King Dereo, mov 1
select t_raises(format('select public.submit_move(%L,''h2'',3,4)', :'mid'),
                'cannot reach', 'one move does not cover a diagonal');
select public.submit_move(:'mid','h2',2,4);
select t_ok(t_get(:'mid','h2','y')='4', 'the crown moves its one tile');

-- Column 3, not column 0: t_park stacks five down the back column now, so
-- column 0 is a wall rather than a corridor.
select t_reset(:'mid'); select t_place(:'mid','h3',3,5);       -- Mako, mov 2
select public.submit_move(:'mid','h3',3,3);
select t_ok(t_get(:'mid','h3','y')='3', 'Mako crosses two tiles');

-- ---- one to two, and who can answer it ----------------------------------
-- Until 0030 this asserted that a range-2 unit could not strike the thing in
-- its face -- the engine's invention, not the design's. And until 0031 that
-- unit was Dereo, who the spec makes a range-1 Royal; Wuzu is the range-2 one
-- on this side now.
select t_reset(:'mid'); select t_park(:'mid', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);
select t_noauras(:'mid');
select t_place(:'mid','h4',0,3);          -- Wuzu, range 2, so one tile or two
select t_place(:'mid','g4',0,2);          -- Lumea, one tile away
select t_hp(:'mid','g4',75);
select public.submit_attack(:'mid','h4','g4');
select t_ok(t_get(:'mid','g4','hp')::int < 75,
            'A RANGE-2 UNIT CAN STRIKE THE THING IN ITS FACE — a range of 2 is 1 and 2');
select t_reset(:'mid'); select t_park(:'mid', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);
select t_place(:'mid','h4',0,3);
select t_place(:'mid','g4',0,0);
select t_raises(format('select public.submit_attack(%L,''h4'',''g4'')', :'mid'),
                'out of range', 'but not three tiles off — the number is still the number');

-- Who answers is decided by the RECEIVER's own range, which is the whole
-- point of collapsing the four reach numbers into one. Mako reaches a single
-- tile, so a blow from two tiles away is one it cannot answer.
select t_reset(:'mid'); select t_park(:'mid', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);
select t_noauras(:'mid');
select t_place(:'mid','h4',0,3); select t_hp(:'mid','h4',85);   -- Wuzu, range 2
select t_place(:'mid','g5',0,1); select t_hp(:'mid','g5',60);   -- Mako, range 1
select public.submit_attack(:'mid','h4','g5');
select t_ok(t_get(:'mid','h4','hp')::int = 85,
            'Mako answers at one tile, so it cannot answer at two');
select t_ok(t_get(:'mid','g5','hp')::int between 30 and 40, 'and Wuzu rolled its 20-30');
select t_ok(t_fx(:'mid','counter')::int = 0, 'with no counter recorded at all');

-- And a receiver that DOES reach two answers from two.
select t_reset(:'mid'); select t_noauras(:'mid');
select t_place(:'mid','h4',0,3); select t_hp(:'mid','h4',85);   -- Wuzu, range 2
select t_place(:'mid','g4',0,1); select t_hp(:'mid','g4',75);   -- Lumea, range 2
select public.submit_attack(:'mid','h4','g4');
select t_ok(t_get(:'mid','h4','hp')::int < 85,
            'while Lumea, which reaches two, ANSWERS from two');

-- ---- melee reaches diagonally -------------------------------------------
select t_reset(:'mid'); select t_park(:'mid', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);
select t_place(:'mid','h1',1,3); select t_place(:'mid','g4',2,2);
select t_hp(:'mid','g4',70);
select public.submit_attack(:'mid','h1','g4');   -- Dione & Grifo, diagonally
select t_ok(t_get(:'mid','g4','hp')::int < 70, 'Dione & Grifo hit diagonally');
select t_ok(t_get(:'mid','h1','hp')::int < 110, 'and are answered diagonally');

-- ---- burn -----------------------------------------------------------------
select t_reset(:'mid'); select t_park(:'mid', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);
-- Nose to nose: the spec's King Dereo has a range of one, where the live
-- roster's Dereo reached two. Two tiles apart is out of range now.
select t_place(:'mid','h2',2,2); select t_place(:'mid','g1',2,1);
select t_hp(:'mid','h2',70); select t_hp(:'mid','g1',70);
-- Dereo set that Dereo alight two assertions ago; put it out first, or this
-- section measures the previous test's fire rather than its own.
select t_set(:'mid','g1','burned','false'::jsonb);
select t_dmg(:'mid','h2',10);
select public.submit_attack(:'mid','h2','g1');
-- Dereo set things alight until 0033, and it was never in the spec: his
-- passive is the aura F1 gave him. Asserted as GONE rather than deleted, so
-- that the day somebody gives a card `burns` again it is a decision.
select t_ok(t_get(:'mid','g1','burned') = 'false',
            'KING DEREO NO LONGER SETS ANYTHING ALIGHT — his passive is his aura');
select t_ok(t_get(:'mid','g1','hp')::int = 60, 'and costs nothing in the exchange that lit it');

-- Nothing applies a burn any more -- Ashvar's fireball is F2's -- so the fire
-- is lit by hand here. The RULE is unchanged and still worth asserting: a unit
-- that swings while alight pays for it.
select t_reset(:'mid'); select t_hp(:'mid','g1',60); select t_hp(:'mid','h2',70);
select t_burn(:'mid','g1');
select t_dmg(:'mid','h2',10);
select public.submit_attack(:'mid','h2','g1');
-- 15% of a MAXIMUM since 0034, not a flat 5: g1 is King Dereo at 110, so the
-- fire costs 17. Per cent of maximum rather than of what is left, because a
-- burn that scaled with current health could never finish anybody.
select t_ok(t_fx(:'mid','burnTgt')::int = 17,
            'A BURNED UNIT THAT COUNTERS PAYS 15% OF ITS MAXIMUM');
select t_ok(t_get(:'mid','g1','hp')::int = 33, '60 - 10 hit - 17 burn');

-- g1 is a crown, and a burn of 17 on top of a blow can finish one -- which
-- ENDS THE MATCH and makes every assertion after this file's midpoint fail
-- with "match is not running". Topped up before the exchange, deliberately.
select t_reset(:'mid'); select t_burn(:'mid','h1');
select t_hp(:'mid','h1',95); select t_full(:'mid','g1');
select t_place(:'mid','h1',2,2); select t_place(:'mid','g1',2,1);
select public.submit_attack(:'mid','h1','g1');
-- h1 is Dione & Grifo at 95, so 15% of a maximum is 14. The rule is the same
-- at either end of the exchange; only the number it reads is the unit's own.
select t_ok(t_fx(:'mid','burnAtk')::int = 14, 'a burned ATTACKER pays the same 15% too');
select t_clear(:'mid','h1');

-- ---- mending is an ABILITY now ---------------------------------------------
-- Eva and Umiro mended because 0010 made them Herbalists; 0033 took it away,
-- because neither card has ever said so. Healing by ATTACKING an ally is
-- therefore gone -- and since 0038 pointing a blade at an ally does the
-- obvious thing instead. Asserted as a HIT rather than as a refusal, which is
-- the same assertion inverted rather than deleted.
select t_reset(:'mid'); select t_park(:'mid', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);
select t_place(:'mid','h1',2,2); select t_place(:'mid','h2',2,3);
select t_full(:'mid','h2'); select t_clear(:'mid','h1');
select public.submit_attack(:'mid','h1','h2');
select t_ok(t_get(:'mid','h2','hp')::int < t_get(:'mid','h2','maxHp')::int,
            'ATTACKING AN ALLY HURTS IT — it does not mend it');
select t_ok((select count(*) from public.cards where is_active and heals) = 0,
            'and no playable card heals as a passive at all');

-- Eva fights like anything else, at one tile and at two. The second match
-- this block used to need went with the mending.
select t_reset(:'mid'); select t_noauras(:'mid');
select t_place(:'mid','h5',1,3); select t_place(:'mid','g1',1,1);
select t_full(:'mid','g1');
select public.submit_attack(:'mid','h5','g1');
select t_ok(t_get(:'mid','g1','hp')::int < 110, 'Eva hits at two tiles');
select t_reset(:'mid'); select t_place(:'mid','g1',1,2); select t_full(:'mid','g1');
select public.submit_attack(:'mid','h5','g1');
select t_ok(t_get(:'mid','g1','hp')::int < 110, 'and at one');

-- ---- trees ----------------------------------------------------------------
select set_config('app.uid', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select t_reset(:'mid'); select t_park(:'mid', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);

select t_trees(:'mid', '[{"id":"t1","x":0,"y":4,"hp":30,"maxHp":30}]'::jsonb);
select t_place(:'mid','h1',3,5); select t_place(:'mid','h2',4,5); select t_place(:'mid','h4',5,5);
select t_place(:'mid','h3',0,5);      -- Mako, mov 2 since 0031
select t_raises(format('select public.submit_move(%L,''h3'',0,3)', :'mid'),
                'cannot reach', 'a tree makes a walker go around it');
select public.submit_move(:'mid','h3',1,4);
select t_ok(t_get(:'mid','h3','x')='1' and t_get(:'mid','h3','y')='4',
            'two steps around the tree is fine');
select t_reset(:'mid');
select t_raises(format('select public.submit_move(%L,''h3'',0,4)', :'mid'),
                'cannot reach', 'and you cannot stand in it');

-- h4 rather than h2: the shot needs a unit that reaches two tiles, and since
-- 0031 the crown reaches one. Wuzu is the range-2 card on this side.
select t_reset(:'mid');
select t_trees(:'mid', '[{"id":"t1","x":2,"y":2,"hp":30,"maxHp":30}]'::jsonb);
select t_place(:'mid','h4',2,3); select t_place(:'mid','g1',2,1);
select t_full(:'mid','g1');
select t_raises(format('select public.submit_attack(%L,''h4'',''g1'')', :'mid'),
                'tree is in the way', 'a tree in the line stops the shot');
select t_trees(:'mid', '[{"id":"t1","x":0,"y":2,"hp":30,"maxHp":30}]'::jsonb);
select public.submit_attack(:'mid','h4','g1');
select t_ok(t_get(:'mid','g1','hp')::int < t_get(:'mid','g1','maxHp')::int,
            'a tree off the line does not');

select t_reset(:'mid');
select t_trees(:'mid', '[{"id":"t1","x":2,"y":2,"hp":30,"maxHp":30}]'::jsonb);
select t_place(:'mid','h1',1,3); select t_place(:'mid','g4',1,2);
select t_hp(:'mid','g4',70);          -- it has been shot at all file; stand it back up
select public.submit_attack(:'mid','h1','g4');
select t_ok(t_get(:'mid','g4','hp')::int < 70, 'a neighbouring tree does not block a melee hit');

-- Wuzu hits for 20-30 since 0031, where the live roster had it on 31-41 --
-- so felling a 30-point tree is no longer a certainty and the blow is pinned
-- rather than rolled. A test that passes four times in five is worse than no
-- test: it teaches you to re-run it.
select t_reset(:'mid'); select t_hp(:'mid','h4',85);
select t_place(:'mid','h4',2,3);      -- Wuzu beside the tree
select t_ok(t_tree_hp(:'mid','t1') = 30, 'a tree has 30 HP');
select t_dmg(:'mid','h4',20);
select public.submit_attack(:'mid','h4','t1');
select t_ok(t_tree_hp(:'mid','t1') = 10, 'a 20-point blow takes a tree to 10');
select t_reset(:'mid'); select t_dmg(:'mid','h4',30);
select public.submit_attack(:'mid','h4','t1');
select t_ok((select jsonb_array_length(state->'obstacles') from public.matches where id=:'mid') = 0,
            'and the next one fells it');
select t_ok(t_get(:'mid','h4','hp')::int = 85, 'a tree does not counter');

-- ---- decks fall back when the roster changes underneath them ------------
select t_ok(public.deck_of('bbbbbbbb-0000-0000-0000-000000000002')
            = array['dereo','eva','umiro','lumea','mako'], 'a saved team is used');
-- Eva rather than Dereo, and the change is the point rather than a
-- workaround: Dereo is the roster's only royal, and since 0025 retiring the
-- last royal is refused outright. A match needs a crown to be able to end, so
-- "what happens when the last one is retired" is not a state this test gets to
-- set up any more -- 16_admin.sql asserts the refusal instead.
update public.cards set is_active = false where slug = 'eva';
select t_ok(public.deck_of('bbbbbbbb-0000-0000-0000-000000000002') = public.default_deck(),
            'a deck holding a retired card falls back to the default');
update public.cards set is_active = true where slug = 'eva';

\echo '--- combat, terrain and distance: all assertions passed ---'
