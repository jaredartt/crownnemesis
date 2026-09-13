-- The four things the new roster can do that the old one could not.
\set ON_ERROR_STOP on
\pset pager off

delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('11110000-0000-0000-0000-00000000000a','p@x.com','{"username":"pia"}'),
  ('22220000-0000-0000-0000-00000000000b','q@x.com','{"username":"quin"}');

select t_ok((select count(*) from public.cards where is_active) = 20, 'twenty cards in the roster');
-- Nine of the twenty have none: they arrived in 0031 and switched on in 0034,
-- and the art comes later. A missing picture draws as the unit's initial,
-- which is invisible rather than broken -- but the ELEVEN that have art must
-- keep it, so the assertion is scoped rather than dropped.
select t_ok((select count(*) from public.cards where is_active and art_url is null) = 9,
            'nine of them are still waiting for their picture');
select t_ok((select count(*) from public.cards
              where is_active and art_url is null and slug in (
                'dereo','dione-grifo','lium','mako','eva','himanta','fey','umiro',
                'sinie','wuzu','lumea')) = 0,
            'and not one of the eleven that had one has lost it');
select t_ok((select count(*) from public.cards where is_active and role = '') = 0,
            'and a class beside the name');

select set_config('app.uid','11110000-0000-0000-0000-00000000000a',false);
select public.set_deck(array['lumea','mako','umiro','wuzu','dereo']);
select set_config('app.uid','22220000-0000-0000-0000-00000000000b',false);
select public.set_deck(array['dione-grifo','dereo','fey','eva','umiro']);

select t_match('11110000-0000-0000-0000-00000000000a',
               '22220000-0000-0000-0000-00000000000b') as m \gset
select set_config('app.uid','11110000-0000-0000-0000-00000000000a',false);
select t_ok(t_get(:'m','h1','name') = 'Lumea', 'the deck you chose is the army you get');
select t_ok(t_get(:'m','h1','flies') = 'true', 'and the abilities came with it');

-- ---- FLIGHT IS NOT A PASS -------------------------------------------------
-- Until 0038 a flier asked only how far away a tile was and ignored everything
-- on the ground between it and there. Jared's rule: "Flying class shouldn't
-- jump over units/structures unless stated in their ability/passive", and
-- nothing states it. The old behaviour is asserted as GONE rather than
-- deleted, so that anybody who brings it back finds out here.
select t_trees(:'m', '[{"id":"t1","x":2,"y":4,"hp":30,"maxHp":30}]'::jsonb);
select t_place(:'m','h1',2,5);           -- Lumea, mov 3, tree directly ahead
select t_place(:'m','h2',2,3);           -- Mako, a body directly beyond it
select t_place(:'m','h3',0,5); select t_place(:'m','h4',5,5);
select t_place(:'m','g1',0,0); select t_place(:'m','g2',1,0);
select t_place(:'m','g3',2,0); select t_place(:'m','g4',3,0);

select t_raises(format('select public.submit_move(%L,''h1'',2,2)', :'m'),
                'cannot reach',
                'A FLIER NO LONGER CROSSES A TREE AND A BODY to land beyond');
select t_raises(format('select public.submit_move(%L,''h1'',2,3)', :'m'),
                'cannot reach', 'and it still cannot land on somebody');
select t_raises(format('select public.submit_move(%L,''h1'',2,4)', :'m'),
                'cannot reach', 'nor in a tree');
-- What it CAN do is go round, which is what everybody else has always done.
-- Three tiles of movement is three tiles of walking.
select public.submit_move(:'m','h1',1,3);
select t_ok(t_get(:'m','h1','x') = '1' and t_get(:'m','h1','y') = '3',
            'IT GOES ROUND — three steps, the long way, like anybody else');

-- And a walker with the same movement gets exactly the same answer, which is
-- the whole of the change: there is one walk now.
select t_reset(:'m'); select t_place(:'m','h1',5,0);   -- Lumea out of the way
select t_place(:'m','h2',2,5);                          -- Mako, mov 3, same lane
select t_raises(format('select public.submit_move(%L,''h2'',2,2)', :'m'),
                'cannot reach', 'Mako has to go round both, exactly as Lumea now does');

-- ---- Wuzu does not go over the wood either --------------------------------
-- It walked THROUGH it until 0031, felling it on the way; it flew OVER it
-- from 0031 until 0038; and now it walks round it. Both of the old rules are
-- asserted as gone.
select t_reset(:'m');
select t_trees(:'m', '[{"id":"t1","x":2,"y":4,"hp":30,"maxHp":30}]'::jsonb);
select t_place(:'m','h2',5,0);
select t_place(:'m','h4',2,5);                          -- Wuzu, mov 3, tree ahead
select t_raises(format('select public.submit_move(%L,''h4'',2,3)', :'m'),
                'cannot reach', 'WUZU DOES NOT FLY OVER THE TREE ANY MORE');
select t_raises(format('select public.submit_move(%L,''h4'',2,4)', :'m'),
                'cannot reach', 'and it cannot come down in one either');
select public.submit_move(:'m','h4',1,3);
select t_ok((select jsonb_array_length(state->'obstacles') from public.matches where id=:'m') = 1,
            'and the tree is still standing — nothing tramples any more');

-- ---- Mako is never answered ---------------------------------------------
select t_reset(:'m'); select t_trees(:'m', '[]'::jsonb);
select t_place(:'m','h2',2,3); select t_place(:'m','g1',2,2);   -- Mako vs Dione & Grifo
select t_hp(:'m','h2',60);
select public.submit_attack(:'m','h2','g1');
-- Mako could not be answered until 0033, from a card that read "Never takes a
-- blow in return" before 0023 replaced it with the spec's trap. The trap is
-- F4's; until then Mako is exactly what its numbers say, and takes the answer
-- like anybody.
select t_ok(t_get(:'m','h2','hp')::int < 60,
            'AND A THIEF IS ANSWERED LIKE ANYBODY NOW — sneaking was never in the spec');
select t_ok(t_fx(:'m','counter')::int > 0, 'and the counter is recorded like anybody else''s');

-- and they answer everybody else too
select t_reset(:'m'); select t_place(:'m','h4',2,3); select t_hp(:'m','h4',85);
select t_full(:'m','g1');   -- it has to survive to answer
select public.submit_attack(:'m','h4','g1');
select t_ok(t_get(:'m','h4','hp')::int < 85, 'Wuzu takes the answer too');

-- The pair used to answer from TWO tiles while striking at one -- a counter
-- reach of its own, which is the thing 0030 removed. "Range and reach IS THE
-- SAME thing": a unit answers what it could have struck and no further, so a
-- reach-1 pair does not reach a mage standing two away. The spec's ability for
-- Dione & Grifo ("Back to Back -- deals 15 to all nearby (Range 1) tiles")
-- never mentioned answering at two either; that was the engine's invention.
-- This is the old behaviour asserted as gone, deliberately, rather than
-- deleted -- so that anybody who brings it back finds out here.
select t_reset(:'m'); select t_place(:'m','g1',2,1); select t_place(:'m','h4',2,3);
select t_set(:'m','h4','rmax','2'::jsonb); select t_hp(:'m','h4',85);
select t_full(:'m','g1');
select public.submit_attack(:'m','h4','g1');
select t_ok(t_get(:'m','h4','hp')::int = 85,
            'AND NOT FROM TWO: since 0030 a unit answers only what it could have struck');

-- ---- NOTHING PUTS A FIRE OUT ANY MORE ------------------------------------
-- Umiro cured, and mended, because 0010 made him a Herbalist; the spec makes
-- him a Swamp Bringer and 0033 took both away. Jared's decision with it: burn
-- and poison are permanent until the unit dies. So this section, which used to
-- prove that a fire could be put out, proves that it cannot -- and that is a
-- rule somebody will want to find written down when they wonder why a unit
-- burned all match.
select t_reset(:'m');
select t_ok(t_get(:'m','h3','cures') = 'false', 'Umiro does not cure');
select t_ok((select count(*) from public.cards where is_active and cures) = 0,
            'AND NOTHING IN THE GAME DOES — a burn is permanent now, by decision');
select t_ok((select count(*) from public.cards where is_active and blooms) = 0,
            'nor does anything water the whole garden: Sinie aims now');

-- ---- Fey reaches three, and only another three answers -------------------
select t_reset(:'m'); select t_park(:'m', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);
-- Fey was 2-3, answering only at 3, which meant a mage with a sword at its
-- throat could neither strike back nor be answered. Since 0030 a range is one
-- number and it starts at 1: Fey reaches 1, 2 and 3, and answers across all
-- three.
select t_ok((select rmin=1 and rmax=3 and crmin=1 and crmax=3 and range=3
               from public.cards where slug='fey'),
            'FEY REACHES 1, 2 AND 3, and answers across all three');
select t_place(:'m','g3',2,2); select t_place(:'m','h4',2,5);   -- Fey vs Wuzu, three apart
select t_set(:'m','g3','rmax','3'::jsonb);
select set_config('app.uid','22220000-0000-0000-0000-00000000000b',false);
select t_raises(format('select public.submit_attack(%L,''g3'',''h4'')', :'m'),
                'not your turn', 'and it is still the host''s turn');

select set_config('app.uid','11110000-0000-0000-0000-00000000000a',false);
select t_raises(format('select public.submit_attack(%L,''h4'',''g3'')', :'m'),
                'out of range', 'Wuzu cannot reach three tiles to answer it');

-- ---- the bot inherits all of it -----------------------------------------
select set_config('app.uid','11110000-0000-0000-0000-00000000000a',false);
-- ---- Lium answers first -------------------------------------------------
select set_config('app.uid','11110000-0000-0000-0000-00000000000a',false);
select public.set_deck(array['lium','himanta','mako','wuzu','dereo']);
select set_config('app.uid','22220000-0000-0000-0000-00000000000b',false);
select public.set_deck(array['dione-grifo','dereo','eva','fey','umiro']);
select t_match('22220000-0000-0000-0000-00000000000b',
               '11110000-0000-0000-0000-00000000000a') as p \gset
select set_config('app.uid','22220000-0000-0000-0000-00000000000b',false);
select t_trees(:'p', '[]'::jsonb);
select t_park(:'p', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);
select t_ok(t_get(:'p','g1','name') = 'Lium', 'the guest fields Lium in slot 1');
-- `parries` is Quick Dagger -- "the answer lands BEFORE the blow it is
-- answering" -- and it sat on Lium from 0013 until 0034, which is the seventh
-- and last of the leftovers. The spec gives Quick Dagger to Dorme and gives
-- Lium the parry-all it does advertise.
select t_ok(t_get(:'p','g1','parries') = 'false',
            'AND IT NO LONGER ANSWERS FIRST — that was never on its card');
select t_ok(t_get(:'p','g1','parryAll') = 'true', 'it keeps the one it does advertise');
select t_ok((select parries from public.cards where slug = 'dorme'),
            'and Quick Dagger is Dorme''s now, which is whose it always was');

-- an attacker that survives the answer still lands its blow
select t_reset(:'p'); select t_place(:'p','h1',2,2); select t_place(:'p','g1',2,3);
select t_hp(:'p','h1',110); select t_full(:'p','g1');
select public.submit_attack(:'p','h1','g1');
select t_ok(t_get(:'p','g1','hp')::int < 80, 'a survivor still gets its hit in');
select t_ok(t_get(:'p','h1','hp')::int < 110, 'and still takes the answer');

-- Lium answered BEFORE the blow it was answering until 0034 -- Quick Dagger,
-- which the spec gives to Dorme. It answers in its turn now like everybody, so
-- an attacker it kills has already landed its own blow. The old behaviour is
-- asserted as gone rather than deleted.
select t_reset(:'p'); select t_place(:'p','h1',2,2); select t_place(:'p','g1',2,3);
select t_hp(:'p','h1',8); select t_full(:'p','g1');
select public.submit_attack(:'p','h1','g1');
select t_ok(not t_alive(:'p','h1'), 'Lium still kills the attacker with the answer');
select t_ok(t_get(:'p','g1','hp')::int < 85,
            'BUT THE BLOW IT WAS ANSWERING LANDS FIRST NOW — Quick Dagger is Dorme''s');
select t_ok(t_fx(:'p','dmg')::int > 0, 'and the damage it dealt is recorded, because it dealt some');
-- `parry` on the fx is Quick Dagger's flag -- "the counter landed first, so
-- the attack may never have happened" -- and Lium does not do that any more.
select t_ok(t_fx(:'p','parry') = 'false',
            'and NOT flagged as a parry, because nothing landed before anything');

-- ---- Himanta glides ------------------------------------------------------
select t_reset(:'p');
select public.end_turn(:'p');                       -- hand the turn to the guest
select set_config('app.uid','11110000-0000-0000-0000-00000000000a',false);
select t_park(:'p', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);
select t_ok(t_get(:'p','g2','name') = 'Himanta', 'the guest fields Himanta in slot 2');

-- Himanta flew until 0031 and this block asserted that it crossed trees and
-- bodies. The spec makes it a ROGUE -- flight belongs to the Flying class now
-- -- so it is on the ground with everybody else, and the old behaviour is
-- asserted as gone rather than deleted.
select t_trees(:'p', '[{"id":"t1","x":3,"y":4,"hp":30,"maxHp":30}]'::jsonb);
select t_place(:'p','g2',3,5);       -- Himanta, mov 2, a tree directly ahead
select t_place(:'p','g3',2,5);       -- and the only way round it blocked
select t_raises(format('select public.submit_move(%L,''g2'',3,3)', :'p'),
                'cannot reach', 'HIMANTA IS A ROGUE NOW, and walks: the tree is in its way');

select t_reset(:'p'); select t_place(:'p','g2',3,5); select t_place(:'p','g3',0,5);
select public.submit_move(:'p','g2',4,4);
select t_ok(t_get(:'p','g2','x') = '4' and t_get(:'p','g2','y') = '4',
            'and goes round it like anybody else when there is a way round');

select t_reset(:'p'); select t_place(:'p','g2',3,5);
select t_raises(format('select public.submit_move(%L,''g2'',3,4)', :'p'),
                'cannot reach', 'and still cannot stand in a tree');

-- Range 1 since 0031, where the live roster gave it two.
-- h1 is not on the board any more; it walked into the parry two tests ago
select t_reset(:'p'); select t_trees(:'p', '[]'::jsonb);
select t_place(:'p','g2',2,2); select t_place(:'p','h2',2,4);
select t_full(:'p','h2');
select t_raises(format('select public.submit_attack(%L,''g2'',''h2'')', :'p'),
                'out of range', 'and it no longer strikes from two tiles away');
select t_place(:'p','h2',2,3);
select public.submit_attack(:'p','g2','h2');
select t_ok(t_get(:'p','h2','hp')::int < t_get(:'p','h2','maxHp')::int,
            'but it strikes what is next to it');

select set_config('app.uid','11110000-0000-0000-0000-00000000000a',false);
-- ---- Sinie mends everyone at once ---------------------------------------
select set_config('app.uid','11110000-0000-0000-0000-00000000000a',false);
select public.set_deck(array['sinie','mako','wuzu','lumea','dereo']);
select set_config('app.uid','22220000-0000-0000-0000-00000000000b',false);
select public.set_deck(array['dione-grifo','dereo','eva','fey','umiro']);
select t_match('11110000-0000-0000-0000-00000000000a',
               '22220000-0000-0000-0000-00000000000b') as b \gset
select set_config('app.uid','11110000-0000-0000-0000-00000000000a',false);
select t_trees(:'b', '[]'::jsonb);
select t_park(:'b', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);
select t_ok(t_get(:'b','h1','name') = 'Sinie', 'the host fields Sinie in slot 1');

-- ---- THE BLOOM IS GONE, and mending is an ability ------------------------
-- Sinie watered every ally in reach off one roll, as a passive that fired when
-- she "attacked" a friend. The spec calls it Healing Petals -- 30 hit points,
-- to a target you point at -- and 0033 made it an ability. Everything the
-- bloom used to prove (one roll spent on everyone, a full ally skipped, wood
-- stopping it) was proving a rule that no longer exists. What is asserted here
-- is that it is gone; what replaced it is in 24_abilities.sql.
select t_ok(t_get(:'b','h1','blooms') = 'false', 'and she no longer carries the flag');
select t_ok(t_get(:'b','h1','abilityKind') = 'heal_any',
            'she carries an ABILITY instead, aimed rather than sprayed');
select t_reset(:'b');
select t_place(:'b','h1',0,0); select t_place(:'b','h2',0,1); select t_place(:'b','h3',1,1);
select t_hp(:'b','h2',10); select t_hp(:'b','h3',10);
-- Since 0038 pointing a blade at an ally is a blade. Sinie mends with her
-- ABILITY and only with her ability; the attack does what an attack does,
-- which is the old rule asserted from the other side rather than deleted.
-- h2 is standing on ten hit points, so the blow finishes it. Asserted as
-- GONE rather than as damaged: a unit that has been mended is on the board
-- and a unit that has been struck to nothing is not, and the difference
-- between the two is the whole of what this block is about.
select public.submit_attack(:'b','h1','h2');
select t_ok(not t_alive(:'b','h2'),
            'and attacking an ally HURTS it -- the mend is the ability, not the blade');
select t_ok(t_get(:'b','h3','hp')::int = 10,
            'so nobody standing near her is watered by accident any more');

select id as bm from public.create_bot_match(3) \gset
select public.set_ready(:'bm');
do $$
declare i int := 0; mid uuid := (select id from public.matches where bot is not null
                                  order by created_at desc limit 1); st text;
begin
  perform set_config('app.uid', '11110000-0000-0000-0000-00000000000a', false);
  loop
    select status into st from public.matches where id = mid;
    -- generous: the bot draws four at random, and a hand of herbalists takes
    -- a long time to finish somebody who is standing still
    exit when st <> 'active' or i > 2000;
    if (select state->>'turn' from public.matches where id = mid) = 'guest'
      then perform public.bot_step(mid);
      else perform public.end_turn(mid);
    end if;
    i := i + 1;
  end loop;
  raise notice 'PASS  RUTHLESS plays the new roster to a finish (% steps, %)', i, st;
end $$;
select t_ok((select status from public.matches where id=:'bm') = 'finished'
        and (select winner from public.matches where id=:'bm') = 'guest',
            'and it still wins against somebody who never moves');
select t_ok((select count(*) = 0 from public.matches m,
                  jsonb_array_elements(m.state->'units') u,
                  jsonb_array_elements(m.state->'obstacles') o
              where m.id=:'bm' and u->>'x'=o->>'x' and u->>'y'=o->>'y'),
            'and never left anybody standing inside a tree');

\echo '--- the roster and its abilities: all assertions passed ---'
