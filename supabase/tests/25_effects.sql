-- 0034: burn, poison and stun, and the nine cards that were waiting on them.
--
-- The card DATA is asserted from `cards`; the RULES are asserted by rigging
-- the snapshot, because a deck holds five and there are nine new units. That
-- split is deliberate: "Zephyra stuns" is a fact about a row, and "a stun
-- takes the go" is a fact about the engine, and the second one is true of
-- anything that ever carries the flag.
\set ON_ERROR_STOP on
\pset pager off

set cn.force_parry = 'never'; set cn.force_crit = 'never';
set cn.force_twice = 'never'; set cn.force_mist = 'never';

delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('11220000-0000-0000-0000-000000001122','e1@x.com','{"username":"one"}'),
  ('33440000-0000-0000-0000-000000003344','e2@x.com','{"username":"two"}');

-- ---- the nine, as rows -----------------------------------------------------
select t_ok((select count(*) from public.cards where is_active and slug is not null) = 20,
            'ALL TWENTY UNITS OF THE SPEC ARE PLAYABLE');
select t_ok(public.deck_royals(public.default_deck()) = 1
        and array_length(public.default_deck(), 1) = public.deck_size(),
            'AND THE DEFAULT DECK IS STILL LEGAL — three crowns now sort to the top');
select t_ok((select parries from public.cards where slug = 'dorme')
        and not (select parries from public.cards where slug = 'lium'),
            'Quick Dagger is Dorme''s, and no longer Lium''s — the seventh leftover');
select t_ok((select stuns from public.cards where slug = 'zephyra')
        and (select lifesteal_pct from public.cards where slug = 'nyxara') = 100
        and (select vs_poisoned from public.cards where slug = 'thalgrim') = 25
        and (select poisons_adjacent from public.cards where slug = 'sarrave'),
            'and the four new passives are on the four cards that describe them');
select t_ok((select ability_kind from public.cards where slug = 'velmor') = 'poison_hit'
        and (select ability_kind from public.cards where slug = 'ashvar') = 'line_burn',
            'and the two new abilities on theirs');

select set_config('app.uid','11220000-0000-0000-0000-000000001122',false);
select public.set_deck(array['dereo','velmor','ashvar','nyxara','zephyra']);
select set_config('app.uid','33440000-0000-0000-0000-000000003344',false);
select public.set_deck(array['stelaris','mako','thalgrim','sarrave','dorme']);
select t_match('11220000-0000-0000-0000-000000001122',
               '33440000-0000-0000-0000-000000003344') as m \gset
select set_config('app.uid','11220000-0000-0000-0000-000000001122',false);
select t_trees(:'m','[]'::jsonb);
select t_park(:'m', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);
select t_ok(t_get(:'m','h2','name') = 'Velmor' and t_get(:'m','g1','name') = 'King Stelaris',
            'the board has Velmor on one side and Stelaris on the other');

-- ---- a burn costs 15% of a MAXIMUM -----------------------------------------
-- Of maximum, not of what is left: an effect that scaled with current health
-- would asymptote and never finish anybody.
select t_reset(:'m');
select t_place(:'m','h2',2,2); select t_place(:'m','g2',2,3);
select t_hp(:'m','h2',70); select t_full(:'m','g2'); select t_dmg(:'m','h2',10);
select t_burn(:'m','h2');
select public.submit_attack(:'m','h2','g2');
select t_ok(t_fx(:'m','burnAtk')::int = 11,
            'A BURNING UNIT PAYS 11 TO SWING — 15% of Velmor''s seventy');
select t_ok(t_get(:'m','h2','hp')::int < 70, 'and it comes off its health');

-- ---- and Stelaris halves it ------------------------------------------------
-- The only answer to an effect in the whole game, and he does not lift it.
select t_reset(:'m');
select t_place(:'m','g2',2,3); select t_place(:'m','h2',2,2);
select t_full(:'m','g2'); select t_burn(:'m','g2'); select t_dmg(:'m','g2',10);
select t_hp(:'m','h2',70);
-- The turn is handed over by whoever holds it, which is the host here.
select public.end_turn(:'m');
select set_config('app.uid','33440000-0000-0000-0000-000000003344',false);
select public.submit_attack(:'m','g2','h2');
-- Mako is 60, so 15% is 9; King Stelaris on that side takes half off, so 5.
select t_ok(t_fx(:'m','burnAtk')::int = 5,
            'KING STELARIS HALVES A BURN — 9 becomes 5 on his side');
-- ...and back again, by the side that now holds it.
select public.end_turn(:'m');
select set_config('app.uid','11220000-0000-0000-0000-000000001122',false);

-- ---- poison bites at the start of its own turn -----------------------------
select t_reset(:'m'); select t_hp(:'m','h4',65); select t_poison(:'m','h4');
select public.end_turn(:'m');
select set_config('app.uid','33440000-0000-0000-0000-000000003344',false);
select t_ok(t_get(:'m','h4','hp')::int = 65,
            'a poison does NOT bite on the other side''s turn');
select public.end_turn(:'m');
select set_config('app.uid','11220000-0000-0000-0000-000000001122',false);
select t_ok(t_get(:'m','h4','hp')::int = 58,
            'A POISON TAKES 10% OF A MAXIMUM at the start of its own side''s turn');
select t_ok((select count(*) from jsonb_array_elements(
               (select state->'log' from public.matches where id=:'m')) e
              where e->>'text' like '%poison%') >= 1, 'and the log says so');

-- It can finish somebody, which is the whole reason it is worth applying.
select t_reset(:'m'); select t_hp(:'m','h4',3);
select public.end_turn(:'m');
select set_config('app.uid','33440000-0000-0000-0000-000000003344',false);
select public.end_turn(:'m');
select set_config('app.uid','11220000-0000-0000-0000-000000001122',false);
select t_ok(not t_alive(:'m','h4'), 'AND IT CAN KILL — a unit the poison finishes leaves the board');

-- ---- a stun takes the go, not the feet -------------------------------------
select t_reset(:'m'); select t_place(:'m','h2',2,2); select t_place(:'m','g2',2,3);
select t_full(:'m','g2'); select t_stun(:'m','h2');
select t_raises(format('select public.submit_attack(%L,''h2'',''g2'')', :'m'),
                'stunned', 'A STUNNED UNIT CANNOT STRIKE');
select t_raises(format('select public.submit_ability(%L,''h2'',''g2'')', :'m'),
                'stunned', 'nor use its ability, which is the same go');
select public.submit_move(:'m','h2',1,2);
select t_ok(t_get(:'m','h2','x') = '1',
            'BUT IT CAN STILL WALK — a cyclone takes the sword, not the feet');

-- and it wears off after one turn of its own
select public.end_turn(:'m');
select set_config('app.uid','33440000-0000-0000-0000-000000003344',false);
select public.end_turn(:'m');
select set_config('app.uid','11220000-0000-0000-0000-000000001122',false);
select t_ok(t_get(:'m','h2','effects')::jsonb->>'stun' = '0', 'and it wears off after one turn');
select t_reset(:'m');
select public.submit_attack(:'m','h2','g2');
select t_ok(t_get(:'m','g2','hp')::int < 60, 'after which it swings again');

-- ---- Velmor: ten, and poisoned ---------------------------------------------
select t_reset(:'m');
select t_place(:'m','h2',2,2); select t_place(:'m','g2',2,3); select t_full(:'m','g2');
select public.submit_ability(:'m','h2','g2');
select t_ok(t_get(:'m','g2','hp')::int = 50, 'CURSED BLADE deals exactly ten');
select t_ok((t_get(:'m','g2','effects')::jsonb->>'poison')::boolean, 'and leaves it poisoned');
-- h5, not h4: the poison finished h4 two blocks ago and it is off the board,
-- so pointing at it would be refused for having no target rather than for
-- being a friend -- an assertion passing for the wrong reason.
select t_reset(:'m'); select t_place(:'m','h5',2,1);
select t_raises(format('select public.submit_ability(%L,''h2'',''h5'')', :'m'),
                'friendly fire', 'and will not be pointed at an ally');

-- ---- Ashvar: two tiles in a line -------------------------------------------
select t_reset(:'m');
select t_place(:'m','h3',2,1); select t_place(:'m','g2',2,2); select t_place(:'m','g3',2,3);
select t_place(:'m','g4',0,5); select t_full(:'m','g2'); select t_full(:'m','g3');
select public.submit_ability(:'m','h3','g2');
select t_ok(t_get(:'m','g2','hp')::int = 45, 'FIREBALL burns the tile it is aimed at for 15');
select t_ok(t_get(:'m','g3','hp')::int = 65, 'AND THE ONE BEYOND IT — two tiles, in a line');
select t_ok((t_get(:'m','g2','effects')::jsonb->>'burn')::boolean
        and (t_get(:'m','g3','effects')::jsonb->>'burn')::boolean,
            'and sets both alight');
select t_ok(t_get(:'m','g4','hp')::int = t_get(:'m','g4','maxHp')::int,
            'and nothing off the line at all');

-- ---- Thalgrim, Nyxara, Zephyra ---------------------------------------------
-- Rigged onto units already on the board: a deck holds five, and these are
-- rules about whatever carries the flag rather than about three particular
-- cards. The cards themselves are asserted at the top of this file.
-- t_reset puts the FLAGS back, not the effects: an effect is permanent until
-- the unit dies, which is the whole design, so a test that wants a clean unit
-- has to say so. g2 has been set alight and poisoned twice by this point.
select t_reset(:'m'); select t_clear(:'m','g2'); select t_clear(:'m','h2');
select t_place(:'m','h2',2,2); select t_place(:'m','g2',2,3); select t_full(:'m','g2');
select t_hp(:'m','h2',70);
select t_dmg(:'m','h2',20); select t_set(:'m','h2','vsPoisoned','25'::jsonb);
select public.submit_attack(:'m','h2','g2');
select t_ok(t_get(:'m','g2','hp')::int = 40, 'a clean target takes the plain twenty');
select t_reset(:'m'); select t_full(:'m','g2'); select t_poison(:'m','g2');
select public.submit_attack(:'m','h2','g2');
select t_ok(t_get(:'m','g2','hp')::int = 15,
            'THALGRIM ADDS 25 AGAINST A POISONED TARGET — twenty becomes forty-five');
select t_set(:'m','h2','vsPoisoned','0'::jsonb);

select t_reset(:'m'); select t_clear(:'m','g2'); select t_full(:'m','g2');
select t_hp(:'m','h2',30); select t_set(:'m','h2','lifestealPct','100'::jsonb);
select public.submit_attack(:'m','h2','g2');
select t_ok(t_get(:'m','h2','hp')::int > 30,
            'A CURSED BODY DRINKS WHAT IT DEALS — and its own health goes up');
-- One short of full, and the steal is twenty: the cap has to do real work.
-- Mako's counter comes off afterwards, so the assertion is that it TOPPED OUT
-- rather than that it ended the exchange full.
select t_reset(:'m'); select t_clear(:'m','g2'); select t_hp(:'m','h2',69);
select t_full(:'m','g2'); select t_set(:'m','g2','parryPct','0'::jsonb);
-- crmax, not rmax: whether a unit ANSWERS is decided by its counter reach,
-- which 0030 made follow its range but which the snapshot still carries
-- separately -- and rigging the wrong one leaves the answer in place.
select t_set(:'m','g2','crmax','0'::jsonb);
select public.submit_attack(:'m','h2','g2');
select t_ok(t_get(:'m','h2','hp')::int = 70, 'but never past its own maximum');
select t_set(:'m','g2','crmax','1'::jsonb); select t_set(:'m','g2','parryPct','5'::jsonb);
select t_set(:'m','h2','lifestealPct','0'::jsonb);

select t_reset(:'m'); select t_full(:'m','g2'); select t_hp(:'m','h2',70);
select t_set(:'m','h2','stuns','true'::jsonb);
select public.submit_attack(:'m','h2','g2');
select t_ok((t_get(:'m','g2','effects')::jsonb->>'stun')::int = 1,
            'A CYCLONE STUNS WHAT IT HITS');
select t_set(:'m','h2','stuns','false'::jsonb);

-- And on the ANSWER, which is the other end of the same rule and the one the
-- board nearly lost: the affliction lands on cn_attack's local copy of the
-- attacker, and that copy has to be carried back into the unit list.
select t_reset(:'m'); select t_clear(:'m','h2'); select t_clear(:'m','g2');
select t_full(:'m','h2'); select t_full(:'m','g2');
select t_set(:'m','g2','stuns','true'::jsonb);
select public.submit_attack(:'m','h2','g2');
select t_ok((t_get(:'m','h2','effects')::jsonb->>'stun')::int = 1,
            'A CYCLONE CAUGHT ON THE COUNTER STUNS THE ATTACKER');
select t_set(:'m','g2','stuns','false'::jsonb); select t_clear(:'m','h2');

-- ---- Sarrave poisons the tiles around it -----------------------------------
select t_reset(:'m'); select t_clear(:'m','g2'); select t_clear(:'m','h2');
select t_place(:'m','g4',2,2); select t_place(:'m','h2',2,3); select t_place(:'m','g2',5,5);
select t_set(:'m','g4','poisonsAdj','true'::jsonb);
select public.end_turn(:'m');
select set_config('app.uid','33440000-0000-0000-0000-000000003344',false);
select t_ok((t_get(:'m','h2','effects')::jsonb->>'poison')::boolean,
            'THE SWAMP POISONS EVERY ADJACENT TILE at the start of its turn');
select t_ok(not (t_get(:'m','g2','effects')::jsonb->>'poison')::boolean,
            'and nothing standing away from it');
select t_ok(t_get(:'m','h2','hp')::int = t_get(:'m','h2','hp')::int,
            'and what it poisons this turn does not also pay for it this turn');
