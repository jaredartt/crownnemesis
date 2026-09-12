-- 0035: things you put on the board.
--
-- `obstacles` stopped meaning "trees". Everything below is really one
-- question asked four ways: WHICH of the four kinds does this rule apply to?
-- A rule that was written for trees and now silently applies to a trap is
-- exactly the bug this file exists to catch, which is why nearly every
-- assertion has a negative twin beside it.
\set ON_ERROR_STOP on
\pset pager off

set cn.force_parry = 'never'; set cn.force_crit = 'never';
set cn.force_twice = 'never'; set cn.force_mist = 'never';

delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('55660000-0000-0000-0000-000000005566','s1@x.com','{"username":"one"}'),
  ('77880000-0000-0000-0000-000000007788','s2@x.com','{"username":"two"}');

-- ---- the three summoners, as rows ------------------------------------------
select t_ok((select ability_kind from public.cards where slug = 'mako') = 'summon'
        and (select summon_kind from public.cards where slug = 'mako') = 'bomb'
        and (select ability_n   from public.cards where slug = 'mako') = 15,
            'MAKO PLANTS A TRAP that deals fifteen');
select t_ok((select summon_kind from public.cards where slug = 'fey') = 'wall',
            'FEY SUMMONS A WALL');
select t_ok((select summon_kind from public.cards where slug = 'lumea') = 'tornado',
            'LUMEA SUMMONS A TORNADO');
select t_ok((select count(*) from public.cards where ability_kind = 'summon') = 3,
            'and nobody else summons anything');
-- The two columns are tied together by a constraint, so a card cannot be a
-- summoner with nothing to summon -- which would raise at the table rather
-- than in the editor.
select t_raises($$update public.cards set ability_kind = 'summon', summon_kind = null
                   where slug = 'mako'$$,
                'cards_summon_needs_kind',
                'a summoner with nothing to summon is refused by the table');

-- ---- the vocabulary --------------------------------------------------------
select t_ok(cn_obj_kind('{"id":"t1"}'::jsonb) = 'tree',
            'AN OBJECT WITH NO KIND IS A TREE — every row written before 0035');
select t_ok(cn_obj_kind('{"kind":"wall"}'::jsonb) = 'wall',
            'and one that says what it is, is that');
select t_ok(cn_obj_solid('tree') and cn_obj_solid('wall')
        and not cn_obj_solid('bomb') and not cn_obj_solid('tornado'),
            'TREES AND WALLS ARE SOLID; TRAPS AND TORNADOES ARE NOT');
select t_ok(cn_obj_hp('tree') = 30 and cn_obj_hp('wall') = 20
        and cn_obj_hp('bomb') = 15 and cn_obj_hp('tornado') = 25,
            'and each kind stands up with its own health');
select t_ok(cn_tile_target('@3,4') = array[3,4] and cn_tile_target('@0,0') = array[0,0],
            'A TARGET THAT BEGINS WITH @ IS A TILE');
select t_ok(cn_tile_target('h1') is null and cn_tile_target(null) is null,
            'and a unit id is not one');
-- '2,3' is how cn_reach has spelled a tile since 0005, and it is NOT the wire
-- format: the '@' is the whole of what separates the two. Without this the
-- guard could be deleted and nothing would notice, because no unit id happens
-- to contain a comma.
select t_ok(cn_tile_target('2,3') is null,
            'AND NEITHER IS A BARE REACH KEY — the @ is the whole distinction');
select t_raises($$select cn_tile_target('@x,y')$$, 'not a tile',
                'and a tile that is not a tile raises rather than being read as a unit');
select t_ok(cn_tile_key(3,4) = '@3,4', 'and the writer agrees with the parser');

-- ---- a live board ----------------------------------------------------------
select set_config('app.uid','55660000-0000-0000-0000-000000005566',false);
select public.set_deck(array['dereo','mako','fey','lumea','wuzu']);
select set_config('app.uid','77880000-0000-0000-0000-000000007788',false);
select public.set_deck(array['stelaris','lium','himanta','sinie','zephyra']);
select t_match('55660000-0000-0000-0000-000000005566',
               '77880000-0000-0000-0000-000000007788') as m \gset
select set_config('app.uid','55660000-0000-0000-0000-000000005566',false);
select t_trees(:'m','[]'::jsonb);
select t_park(:'m', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);
select t_ok(t_get(:'m','h2','name') = 'Mako' and t_get(:'m','h3','name') = 'Fey'
        and t_get(:'m','h4','name') = 'Lumea',
            'the board has all three summoners on the host side');
select t_ok(t_get(:'m','h2','summonKind') = 'bomb',
            'AND THE SNAPSHOT CARRIES WHAT EACH ONE SUMMONS');

-- ---- planting ---------------------------------------------------------------
select t_reset(:'m');
select t_place(:'m','h2',2,2);
select public.submit_ability(:'m','h2','@2,3');
select t_ok(t_nobj(:'m','bomb') = 1, 'MAKO PLANTS A TRAP ON A TILE');
select t_ok(t_obj_at(:'m',2,3,'dmg')::int = 15
        and t_obj_at(:'m',2,3,'hp')::int = 15
        and t_obj_at(:'m',2,3,'by') = 'h2'
        and t_obj_at(:'m',2,3,'owner') = 'host',
            'and it carries its damage, its health, and who made it');
-- The damage is on the OBJECT rather than looked up from the summoner when
-- somebody treads on it, because the summoner can be dead by then.
-- `spent` and not `acted`: cn_end_act sets the first, and the first is what
-- cn_begin_act refuses on. An ability has never set `acted`, which is worth
-- knowing before writing a rule that reads it.
select t_ok(t_get(:'m','h2','spent') = 'true',
            'and planting spends the go, the way every ability does');
select t_raises(format($$select public.submit_ability(%L,'h2','@1,2')$$, :'m'),
                'already had its go',
                'so a second plant in the same go is refused');

-- One alive at a time, which is what "can plant another if destroyed" means.
select t_reset(:'m');
select t_raises(format($$select public.submit_ability(%L,'h2','@2,1')$$, :'m'),
                'still standing',
                'ONE AT A TIME — a second trap is refused while the first stands');
select t_ok(t_nobj(:'m','bomb') = 1, 'and no second one appeared');

-- ...and a different summoner is not blocked by it.
select t_place(:'m','h3',4,2);
select public.submit_ability(:'m','h3','@4,3');
select t_ok(t_nobj(:'m','wall') = 1 and t_obj_at(:'m',4,3,'hp')::int = 20,
            'FEY''S WALL IS ITS OWN SLOT — and stands up with twenty');

-- ---- where you may put one --------------------------------------------------
select t_reset(:'m'); select t_trees(:'m','[]'::jsonb);
select t_place(:'m','h4',1,1);
select t_raises(format($$select public.submit_ability(%L,'h4','@5,5')$$, :'m'),
                'out of range', 'a tile out of reach is refused');
select t_raises(format($$select public.submit_ability(%L,'h4','@1,1')$$, :'m'),
                'out of range', 'and so is the tile you are standing on');
select t_raises(format($$select public.submit_ability(%L,'h4','@-1,1')$$, :'m'),
                'not on the board', 'and so is a tile off the edge');
select t_place(:'m','g5',1,2);
select t_raises(format($$select public.submit_ability(%L,'h4','@1,2')$$, :'m'),
                'tile is taken', 'and a tile with somebody standing on it');
select t_place(:'m','g5',7,7);
select t_trees(:'m','[{"id":"t1","kind":"tree","x":1,"y":2,"hp":30,"maxHp":30}]'::jsonb);
select t_raises(format($$select public.submit_ability(%L,'h4','@1,2')$$, :'m'),
                'tile is taken', 'and a tile with something already on it');
select t_raises(format($$select public.submit_ability(%L,'h4','h1')$$, :'m'),
                'needs a tile', 'and a UNIT is not a tile');

-- ---- solidity ---------------------------------------------------------------
-- The three rules that used to say "tree" and now say "solid". Each is
-- asserted twice: once that a wall behaves like a trunk, once that a trap
-- does not -- because the failure mode here is a rule quietly applying to
-- all four kinds.
select t_reset(:'m'); select t_place(:'m','h1',2,2); select t_place(:'m','g1',2,4);
select t_trees(:'m','[{"id":"w1","kind":"wall","x":2,"y":3,"hp":20,"maxHp":20}]'::jsonb);
select t_ok(not cn_los_clear((select state from public.matches where id = :'m'), 2,2,2,4),
            'A WALL STOPS AN ARROW, the way a trunk does');
select t_trees(:'m','[{"id":"b1","kind":"bomb","x":2,"y":3,"hp":15,"maxHp":15,"dmg":15}]'::jsonb);
select t_ok(cn_los_clear((select state from public.matches where id = :'m'), 2,2,2,4),
            'AND A TRAP STOPS NOTHING — you shoot straight over it');
select t_trees(:'m','[{"id":"z1","kind":"tornado","x":2,"y":3,"hp":25,"maxHp":25}]'::jsonb);
select t_ok(cn_los_clear((select state from public.matches where id = :'m'), 2,2,2,4),
            'nor does a tornado');

select t_reset(:'m'); select t_place(:'m','h1',2,2);
select t_park(:'m', array['h2','h3','h4','h5','g1','g2','g3','g4','g5']);
select t_trees(:'m','[{"id":"w1","kind":"wall","x":2,"y":3,"hp":20,"maxHp":20}]'::jsonb);
select t_ok(not ('2,3' = any(cn_reach((select state from public.matches where id = :'m'),
                                      (select u from public.matches m,
                                        jsonb_array_elements(m.state->'units') u
                                        where m.id = :'m' and u->>'id' = 'h1')))),
            'A WALL STOPS FEET');
select t_trees(:'m','[{"id":"b1","kind":"bomb","x":2,"y":3,"hp":15,"maxHp":15,"dmg":15}]'::jsonb);
select t_ok('2,3' = any(cn_reach((select state from public.matches where id = :'m'),
                                 (select u from public.matches m,
                                   jsonb_array_elements(m.state->'units') u
                                   where m.id = :'m' and u->>'id' = 'h1'))),
            'AND A TRAP DOES NOT — you are meant to be able to step on it');

-- Trample is a rule about TREES and not about everything in the way. A wall
-- summoned to stop somebody would be no wall at all if Wuzu walked through it.
-- Fey and not Wuzu: Wuzu FLIES, and flight is a different branch of cn_reach
-- that never consults trample at all. Rigging `tramples` onto a flier tests
-- nothing, which is the kind of green that is worse than a red.
select t_reset(:'m'); select t_place(:'m','h3',2,2);
select t_set(:'m','h3','tramples','true'::jsonb);
select t_trees(:'m','[{"id":"t1","kind":"tree","x":2,"y":3,"hp":30,"maxHp":30}]'::jsonb);
select t_ok('2,3' = any(cn_reach((select state from public.matches where id = :'m'),
                                 (select u from public.matches m,
                                   jsonb_array_elements(m.state->'units') u
                                   where m.id = :'m' and u->>'id' = 'h3'))),
            'A TRAMPLER WALKS THROUGH A TREE');
select t_trees(:'m','[{"id":"w1","kind":"wall","x":2,"y":3,"hp":20,"maxHp":20}]'::jsonb);
select t_ok(not ('2,3' = any(cn_reach((select state from public.matches where id = :'m'),
                                      (select u from public.matches m,
                                        jsonb_array_elements(m.state->'units') u
                                        where m.id = :'m' and u->>'id' = 'h3')))),
            'AND NOT THROUGH A WALL');
select t_set(:'m','h3','tramples','false'::jsonb);

-- Flight is its own branch and had to be looked at separately: it asks only
-- how far away the tile is and whether the tile is free. A trap is free.
select t_reset(:'m'); select t_place(:'m','h5',2,2);
select t_trees(:'m','[{"id":"b1","kind":"bomb","x":2,"y":3,"hp":15,"maxHp":15,"dmg":15}]'::jsonb);
select t_ok('2,3' = any(cn_reach((select state from public.matches where id = :'m'),
                                 (select u from public.matches m,
                                   jsonb_array_elements(m.state->'units') u
                                   where m.id = :'m' and u->>'id' = 'h5'))),
            'A FLIER CAN LAND ON A TRAP');
select t_trees(:'m','[{"id":"w1","kind":"wall","x":2,"y":3,"hp":20,"maxHp":20}]'::jsonb);
select t_ok(not ('2,3' = any(cn_reach((select state from public.matches where id = :'m'),
                                      (select u from public.matches m,
                                        jsonb_array_elements(m.state->'units') u
                                        where m.id = :'m' and u->>'id' = 'h5')))),
            'AND NOT ON A WALL — it is standing in the way, not lying on the ground');

-- ---- stepping on a trap ------------------------------------------------------
select t_reset(:'m'); select t_place(:'m','h1',2,2); select t_full(:'m','h1');
select t_park(:'m', array['h2','h3','h4','h5','g1','g2','g3','g4','g5']);
select t_place(:'m','h1',2,2);
select t_trees(:'m','[{"id":"b1","kind":"bomb","x":2,"y":3,"hp":15,"maxHp":15,"dmg":15,"by":"g9","owner":"guest"}]'::jsonb);
select public.submit_move(:'m','h1',2,3);
select t_ok(t_get(:'m','h1','hp')::int = 110 - 15,
            'A TRAP TAKES ITS DAMAGE OFF WHOEVER STEPS ON IT');
select t_ok(t_nobj(:'m','bomb') = 0, 'and it is spent — there is nothing left to step on');
select t_ok(t_get(:'m','h1','x')::int = 2 and t_get(:'m','h1','y')::int = 3,
            'and the unit finishes the move it was making');
select t_ok(t_fx(:'m','why') = 'trap' and t_fx(:'m','dmg')::int = 15
        and t_fx(:'m','atk') is null,
            'and the board is told, by nobody in particular');

-- A tornado is stood IN, not stepped on: it stays, and it costs nothing.
select t_reset(:'m'); select t_place(:'m','h1',2,2); select t_full(:'m','h1');
select t_trees(:'m','[{"id":"z1","kind":"tornado","x":2,"y":3,"hp":25,"maxHp":25}]'::jsonb);
select public.submit_move(:'m','h1',2,3);
select t_ok(t_get(:'m','h1','hp')::int = 110 and t_nobj(:'m','tornado') = 1,
            'A TORNADO IS STOOD IN — it costs nothing yet, and it stays');

-- ---- a trap can finish a unit, and a crown ------------------------------------
-- h1 is standing on 2,3 from the tornado above, and a tile with a body on it
-- is not reachable -- which would fail this as 'cannot reach that tile' and
-- say nothing at all about traps.
select t_reset(:'m'); select t_park(:'m', array['h1','h2','h3','h4','g1','g2','g3','g4','g5']);
select t_place(:'m','h5',2,2); select t_hp(:'m','h5',10);
select t_trees(:'m','[{"id":"b1","kind":"bomb","x":2,"y":3,"hp":15,"maxHp":15,"dmg":15}]'::jsonb);
select public.submit_move(:'m','h5',2,3);
select t_ok(not t_alive(:'m','h5'),
            'A TRAP CAN FINISH A UNIT — and it leaves the board');
select t_ok((select winner from public.matches where id = :'m') is null,
            'and an ordinary unit falling does not end the match');

-- The crown is the one that does. cn_move has never before been a place a
-- unit could die, so this is the assertion that says the ending was wired up
-- rather than assumed.
select t_reset(:'m'); select t_place(:'m','h1',2,2); select t_hp(:'m','h1',10);
select t_trees(:'m','[{"id":"b1","kind":"bomb","x":2,"y":3,"hp":15,"maxHp":15,"dmg":15}]'::jsonb);
select public.submit_move(:'m','h1',2,3);
select t_ok((select winner from public.matches where id = :'m') = 'guest'
        and (select status from public.matches where id = :'m') = 'finished',
            'A CROWN THAT WALKS ONTO A TRAP LOSES THE MATCH');
