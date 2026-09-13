-- 0038: three rules Jared changed.
--
-- Every one of them is a rule being REMOVED, which is the hardest kind to
-- test: "it no longer refuses" passes just as well on an engine that refuses
-- nothing. So each block here pairs the new permission with the thing that
-- did NOT change alongside it -- your ally takes the blow but does not answer,
-- the flier walks but still cannot land on a body, the crown check fires on a
-- bad deck and stays quiet on every good one.
\set ON_ERROR_STOP on
\pset pager off

set cn.force_parry = 'never'; set cn.force_crit = 'never';
set cn.force_twice = 'never'; set cn.force_mist = 'never';

delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('12340000-0000-0000-0000-000000001234','a1@x.com','{"username":"one"}'),
  ('56780000-0000-0000-0000-000000005678','a2@x.com','{"username":"two"}');

-- ---- every kingdom has exactly one crown -----------------------------------
-- cn_army is the one door every army in this game comes through: the bot's,
-- the ranked pair's, the tournament's, the rematch's. Asserting the rule
-- there is asserting it for all of them at once.
select t_raises($$select public.cn_army(public.cn_fresh_map(), 'host',
                     array['mako','eva','himanta','dorme','lium'])$$,
                'exactly one royal',
                'AN ARMY WITH NO CROWN IS REFUSED');
select t_raises($$select public.cn_army(public.cn_fresh_map(), 'host',
                     array['dereo','miah','himanta','dorme','lium'])$$,
                'exactly one royal',
                'AND SO IS ONE WITH TWO');
select t_ok(jsonb_array_length(public.cn_army(public.cn_fresh_map(), 'host',
              array['dereo','mako','eva','himanta','dorme'])) = public.deck_size(),
            'and one with exactly one is built');

-- The four deck builders all satisfy it, which is why the check should never
-- fire -- but "should never" is what it was before, when it was a property
-- four functions happened to share rather than a rule anything held.
select t_ok((select count(*) from (select random_deck() as d
              from generate_series(1, 200)) s where deck_royals(s.d) <> 1) = 0,
            'RANDOM_DECK NEVER BUILDS A KINGLESS BOT — two hundred out of two hundred');
select t_ok(deck_royals(default_deck()) = 1, 'and the default deck carries one');

-- ---- a live board ----------------------------------------------------------
select set_config('app.uid','12340000-0000-0000-0000-000000001234',false);
select public.set_deck(array['dereo','dione-grifo','zephyra','dorme','wuzu']);
select set_config('app.uid','56780000-0000-0000-0000-000000005678',false);
select public.set_deck(array['stelaris','lium','mako','dorme','nyxara']);
select t_match('12340000-0000-0000-0000-000000001234',
               '56780000-0000-0000-0000-000000005678') as m \gset
select set_config('app.uid','12340000-0000-0000-0000-000000001234',false);
select t_trees(:'m','[]'::jsonb);
select t_noauras(:'m');
select t_park(:'m', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);

-- ---- you may strike your own -----------------------------------------------
select t_reset(:'m');
select t_place(:'m','h2',2,2); select t_place(:'m','h4',2,3);
select t_full(:'m','h2'); select t_full(:'m','h4'); select t_dmg(:'m','h2',20);
select public.submit_attack(:'m','h2','h4');
select t_ok(t_get(:'m','h4','hp')::int = t_get(:'m','h4','maxHp')::int - 20,
            'YOU MAY STRIKE YOUR OWN');
select t_ok(t_get(:'m','h2','hp')::int = t_get(:'m','h2','maxHp')::int,
            'AND IT DOES NOT ANSWER');

-- Nor does it parry. A parry is not only a block -- it flips the swing, so
-- the parrier strikes back -- which makes "an ally that parries" the same
-- rule as "an ally that answers", read backwards.
select t_reset(:'m'); select t_full(:'m','h2'); select t_full(:'m','h4');
set cn.force_parry = 'always';
select public.submit_attack(:'m','h2','h4');
select t_ok(t_fx(:'m','parry') = 'false' and t_fx(:'m','counter')::int = 0,
            'NOR DOES IT PARRY — even with the dice forced');
select t_ok(t_get(:'m','h4','hp')::int = t_get(:'m','h4','maxHp')::int - 20,
            'so the blow lands, once');
set cn.force_parry = 'never';

-- Quick Dagger is the sharpest version of the same question: it answers
-- BEFORE the blow it is answering, so an ally carrying it would hit you
-- first for standing too close to it.
select t_reset(:'m'); select t_place(:'m','h4',5,5);
select t_place(:'m','g4',2,3);                       -- Dorme, the other side's
select t_ok((t_get(:'m','g4','parries'))::boolean, 'the enemy Dorme carries it');
select t_full(:'m','h2'); select t_full(:'m','g4');
select public.submit_attack(:'m','h2','g4');
select t_ok(t_swi(:'m',0,'why') = 'quick', 'and it lands first against an ENEMY');
-- ...and the same card on your own side does nothing at all.
select t_reset(:'m'); select t_place(:'m','g4',5,4);
select t_place(:'m','h3',2,3);
select t_set(:'m','h3','parries','true'::jsonb);
select t_full(:'m','h2'); select t_full(:'m','h3');
select public.submit_attack(:'m','h2','h3');
select t_ok(t_swi(:'m',0,'why') <> 'quick',
            'AND NOT AGAINST YOUR OWN — no dagger, no answer, one beat');
select t_set(:'m','h3','parries','false'::jsonb);

-- The passives DO still apply, which is the point of allowing it at all: a
-- cyclone is a cyclone whoever is standing in front of it.
select t_reset(:'m'); select t_clear(:'m','h4');
select t_place(:'m','h3',2,2); select t_place(:'m','h4',2,3);
select t_full(:'m','h3'); select t_full(:'m','h4');
select t_ok((t_get(:'m','h3','stuns'))::boolean, 'Zephyra is on this side');
select public.submit_attack(:'m','h3','h4');
select t_ok((t_get(:'m','h4','effects')::jsonb->>'stun')::int = 1,
            'AND IT STUNS ITS OWN SIDE — friendly fire is fire');
select t_clear(:'m','h4');

-- And a crown of yours that falls to your own blade loses you the match,
-- which is the cost that makes the rule a decision rather than a freebie.
select t_reset(:'m'); select t_park(:'m', array['h2','h3','h4','h5','g1','g2','g3','g4','g5']);
select t_place(:'m','h1',2,2); select t_place(:'m','h2',2,3);
select t_hp(:'m','h1',10); select t_full(:'m','h2'); select t_dmg(:'m','h2',40);
select public.submit_attack(:'m','h2','h1');
select t_ok((select winner from public.matches where id = :'m') = 'guest'
        and (select status from public.matches where id = :'m') = 'finished',
            'AND KILLING YOUR OWN CROWN LOSES YOU THE MATCH');

-- ---- a flier walks ---------------------------------------------------------
-- 07_abilities.sql carries the reach assertions against the live cards; what
-- is asserted here is the function itself, because cn_reach is where the
-- whole flying branch used to live and a branch is easier to delete than to
-- notice missing.
\set F '{"board":{"w":6,"h":8},"units":[{"id":"a","x":2,"y":5,"hp":75,"owner":"host","mov":3,"flies":true,"tramples":false},{"id":"b","x":2,"y":3,"hp":70,"owner":"guest","mov":3,"flies":false,"tramples":false}],"obstacles":[{"id":"t1","kind":"tree","x":2,"y":4,"hp":30,"maxHp":30}]}'
select t_ok(not ('2,3' = any(cn_reach(:'F'::jsonb, :'F'::jsonb->'units'->0))),
            'A FLIER DOES NOT CROSS A TREE any more');
select t_ok(not ('2,2' = any(cn_reach(:'F'::jsonb, :'F'::jsonb->'units'->0))),
            'nor a tree and a body together');
select t_ok('1,3' = any(cn_reach(:'F'::jsonb, :'F'::jsonb->'units'->0)),
            'it goes round instead — three steps, the long way');
-- The proof that flight now means nothing HERE: the same board, the same
-- movement, `flies` off, gives the same answer.
select t_ok(cn_reach(:'F'::jsonb, :'F'::jsonb->'units'->0)
          @> cn_reach(:'F'::jsonb, (:'F'::jsonb->'units'->0) || '{"flies": false}'::jsonb)
        and cn_reach(:'F'::jsonb, (:'F'::jsonb->'units'->0) || '{"flies": false}'::jsonb)
          @> cn_reach(:'F'::jsonb, :'F'::jsonb->'units'->0),
            'AND A FLIER AND A WALKER REACH EXACTLY THE SAME TILES');
-- Trample is still its own rule, and still works. It was never flight.
select t_ok('2,4' = any(cn_reach(:'F'::jsonb,
              (:'F'::jsonb->'units'->0) || '{"tramples": true}'::jsonb)),
            'and trampling is untouched — it was never the same thing');
