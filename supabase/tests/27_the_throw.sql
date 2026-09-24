-- 0036: Lumea's fifteen seconds.
--
-- The novelty is not the throw, it is the PENDING: a decision belonging to the
-- side whose turn it is not, holding the whole match still, with its own clock
-- and its own default. Every other rule in this engine asks "is it your turn";
-- this one asks "is it your decision", and most of what can go wrong is about
-- that distinction.
\set ON_ERROR_STOP on
\pset pager off

set cn.force_parry = 'never'; set cn.force_crit = 'never';
set cn.force_twice = 'never'; set cn.force_mist = 'never';

delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('99aa0000-0000-0000-0000-00000000099a','t1@x.com','{"username":"one"}'),
  ('bbcc0000-0000-0000-0000-0000000000bc','t2@x.com','{"username":"two"}');

-- ---- the vocabulary --------------------------------------------------------
select t_ok(cn_throw_secs() = 15, 'FIFTEEN SECONDS, which is what the card says');
select t_ok(cn_pending('{}'::jsonb) is null
        and cn_pending('{"pending": null}'::jsonb) is null,
            'no decision reads as none — whether the key is absent or JSON null');
select t_ok(cn_pending('{"pending":{"kind":"throw"}}'::jsonb) is not null,
            'and an open one is seen');
-- The engine is shut and only the shell is open, which is the rule every
-- cn_/submit_ pair in this schema follows.
select t_ok(has_function_privilege('authenticated',
              'public.submit_throw(uuid, text)', 'execute')
        and not has_function_privilege('authenticated',
              'public.cn_throw(uuid, text, text)', 'execute'),
            'a player may throw; a player may not call the engine');

-- ---- a live board ----------------------------------------------------------
select set_config('app.uid','99aa0000-0000-0000-0000-00000000099a',false);
select public.set_deck(array['dereo','lumea','mako','wuzu','himanta']);
select set_config('app.uid','bbcc0000-0000-0000-0000-0000000000bc',false);
select public.set_deck(array['stelaris','lium','sinie','dorme','zephyra']);
select t_match('99aa0000-0000-0000-0000-00000000099a',
               'bbcc0000-0000-0000-0000-0000000000bc') as m \gset
select set_config('app.uid','99aa0000-0000-0000-0000-00000000099a',false);
select t_trees(:'m','[]'::jsonb);
select t_park(:'m', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);
select t_ok(t_get(:'m','h2','name') = 'Lumea' and t_get(:'m','h2','summonKind') = 'tornado',
            'the board has Lumea on the host side');

-- ---- the gale takes hold ---------------------------------------------------
-- The guest walks into the host's tornado. It is the GUEST's turn throughout
-- what follows, and the decision belongs to the HOST -- that inversion is the
-- whole of this migration.
select t_reset(:'m');
select t_trees(:'m','[{"id":"z1","kind":"tornado","x":3,"y":4,"hp":25,"maxHp":25,"owner":"host","by":"h2"}]'::jsonb);
select t_place(:'m','g2',3,5);
select public.end_turn(:'m');
select set_config('app.uid','bbcc0000-0000-0000-0000-0000000000bc',false);
select public.submit_move(:'m','g2',3,4);
select t_ok(t_pending(:'m','kind') = 'throw',
            'WALKING INTO AN ENEMY TORNADO OPENS A DECISION');
select t_ok(t_pending(:'m','side') = 'host' and t_pending(:'m','unit') = 'g2',
            'and it belongs to the tornado''s owner, about the unit it caught');
select t_ok((select state->>'turn' from public.matches where id = :'m') = 'guest',
            'while the turn is still the mover''s — nobody''s turn changed');
select t_ok(t_get(:'m','g2','x')::int = 3 and t_get(:'m','g2','y')::int = 4,
            'and the move it was making finished: you are caught where you stop');
select t_ok((select turn_deadline from public.matches where id = :'m')
              between now() + interval '10 seconds' and now() + interval '16 seconds',
            'AND THE CLOCK CHANGED HANDS — fifteen seconds, on the same column');
select t_ok((t_pending(:'m','resumeMs'))::int > 0,
            'with what the turn had left parked, not lost');

-- ---- and everything stops --------------------------------------------------
-- Fifteen seconds is short enough that waiting is bearable and long enough
-- that it has to be enforced rather than hoped for.
select t_raises(format($$select public.submit_move(%L,'g3',1,5)$$, :'m'),
                'throw is pending', 'NOBODY MOVES while a decision is open');
select t_raises(format($$select public.submit_attack(%L,'g2','h1')$$, :'m'),
                'throw is pending', 'nobody strikes');
select t_raises(format($$select public.submit_defend(%L,'g3')$$, :'m'),
                'throw is pending', 'nobody guards');
select t_raises(format($$select public.end_turn(%L)$$, :'m'),
                'throw is pending', 'and nobody ends the turn');
-- The side whose decision it is may throw, and that is all it may do -- but
-- it is refused with 'not your turn', because that guard comes first and it
-- was already true. Asserted with the message it actually gives rather than
-- the one the rule above gives: a test that tidies away which guard fired is
-- a test that will not notice when the wrong one does.
select set_config('app.uid','99aa0000-0000-0000-0000-00000000099a',false);
select t_raises(format($$select public.submit_move(%L,'h3',1,1)$$, :'m'),
                'not your turn', 'and the waiting side was never able to act anyway');

-- ---- whose decision it is --------------------------------------------------
select set_config('app.uid','bbcc0000-0000-0000-0000-0000000000bc',false);
select t_raises(format($$select public.submit_throw(%L,'@3,2')$$, :'m'),
                'not your decision',
                'THE SIDE BEING THROWN DOES NOT CHOOSE WHERE');
select set_config('app.uid','99aa0000-0000-0000-0000-00000000099a',false);
select t_raises(format($$select public.submit_throw(%L,'@3,0')$$, :'m'),
                'out of range', 'and a tile further than three is refused');
select t_raises(format($$select public.submit_throw(%L,'@3,4')$$, :'m'),
                'out of range', 'and so is the tile they are already on');
select t_raises(format($$select public.submit_throw(%L,'@-1,4')$$, :'m'),
                'not on the board', 'and so is a tile off the edge');
select t_raises(format($$select public.submit_throw(%L,'g3')$$, :'m'),
                'needs a tile', 'and a unit is not a destination');

-- ---- the throw itself ------------------------------------------------------
select public.submit_throw(:'m','@5,3');
select t_ok(t_get(:'m','g2','x')::int = 5 and t_get(:'m','g2','y')::int = 3,
            'A THROW PUTS THEM WHERE THE GALE WAS AIMED');
select t_ok(t_pending(:'m','kind') is null, 'and the decision closes');
select t_ok(t_fx(:'m','why') = 'throw' and t_fx(:'m','tgt') = 'g2',
            'and the board is told what happened to whom');
select t_ok(t_nobj(:'m','tornado') = 1,
            'and the tornado is still standing — it is weather, not a trap');
select t_ok((select turn_deadline from public.matches where id = :'m') > now(),
            'AND THE TURN GETS ITS CLOCK BACK');
select t_ok((select state->>'turn' from public.matches where id = :'m') = 'guest',
            'with the turn still where it was');

-- ---- letting them go, and the clock running out ----------------------------
select t_reset(:'m');
select t_trees(:'m','[{"id":"z1","kind":"tornado","x":3,"y":4,"hp":25,"maxHp":25,"owner":"host","by":"h2"}]'::jsonb);
select t_place(:'m','g2',3,5);
select set_config('app.uid','bbcc0000-0000-0000-0000-0000000000bc',false);
select public.submit_move(:'m','g2',3,4);
select set_config('app.uid','99aa0000-0000-0000-0000-00000000099a',false);
select public.submit_throw(:'m', null);
select t_ok(t_pending(:'m','kind') is null
        and t_get(:'m','g2','x')::int = 3 and t_get(:'m','g2','y')::int = 4,
            'LETTING THEM GO CLOSES IT and leaves them standing');

-- The default. Nothing -- because a default that MOVED somebody would make
-- running the clock out a move in itself, and a decision you can lose by not
-- making is not a decision, it is a penalty.
select t_reset(:'m'); select t_place(:'m','g2',3,5);
select set_config('app.uid','bbcc0000-0000-0000-0000-0000000000bc',false);
select public.submit_move(:'m','g2',3,4);
select t_ok(t_pending(:'m','kind') = 'throw', 'the gale takes hold again');
select t_expire(:'m');
select public.force_timeout(:'m');
select t_ok(t_pending(:'m','kind') is null,
            'A DECISION NOBODY MAKES EXPIRES');
select t_ok(t_get(:'m','g2','x')::int = 3 and t_get(:'m','g2','y')::int = 4,
            'and the default is nothing at all — they stand where they stood');
select t_ok((select state->>'turn' from public.matches where id = :'m') = 'guest',
            'AND THE TURN IS NOT LOST — an expired decision is not an expired turn');

-- ---- your own gale does not take hold --------------------------------------
-- The turn has to change hands for this one, and only the side whose turn it
-- is may end it -- so the uid is switched twice rather than once. Getting
-- that wrong is how the first draft of this block failed with 'not your turn'
-- and said nothing whatever about tornadoes.
select set_config('app.uid','bbcc0000-0000-0000-0000-0000000000bc',false);
select public.end_turn(:'m');
select set_config('app.uid','99aa0000-0000-0000-0000-00000000099a',false);
select t_reset(:'m');
select t_park(:'m', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);
select t_trees(:'m','[{"id":"z1","kind":"tornado","x":3,"y":4,"hp":25,"maxHp":25,"owner":"host","by":"h2"}]'::jsonb);
select t_place(:'m','h3',3,5);
select public.submit_move(:'m','h3',3,4);
select t_ok(t_pending(:'m','kind') is null,
            'YOUR OWN TORNADO IS NOT A TAXI — walking into it opens nothing');

-- ---- thrown onto a trap ----------------------------------------------------
-- The best thing in the game, and the reason cn_spring exists rather than the
-- trap staying inlined in cn_move where 0035 left it.
select public.end_turn(:'m');
select set_config('app.uid','bbcc0000-0000-0000-0000-0000000000bc',false);
select t_reset(:'m');
select t_park(:'m', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);
select t_trees(:'m','[{"id":"z1","kind":"tornado","x":3,"y":4,"hp":25,"maxHp":25,"owner":"host","by":"h2"},
                      {"id":"b1","kind":"bomb","x":5,"y":3,"hp":15,"maxHp":15,"dmg":15,"owner":"host","by":"h3"}]'::jsonb);
select t_place(:'m','g2',3,5); select t_full(:'m','g2');
select public.submit_move(:'m','g2',3,4);
select set_config('app.uid','99aa0000-0000-0000-0000-00000000099a',false);
select public.submit_throw(:'m','@5,3');
select t_ok(t_get(:'m','g2','hp')::int = t_get(:'m','g2','maxHp')::int - 15,
            'A UNIT THROWN ONTO A TRAP SETS IT OFF');
select t_ok(t_nobj(:'m','bomb') = 0, 'and the trap is spent');
select t_raises(format($$select public.submit_throw(%L,'@4,3')$$, :'m'),
                'nothing is pending', 'and a decision already made cannot be made twice');

-- ...but a gale does not put somebody inside a wall, or on top of a unit.
select set_config('app.uid','bbcc0000-0000-0000-0000-0000000000bc',false);
select t_reset(:'m');
select t_trees(:'m','[{"id":"z1","kind":"tornado","x":3,"y":4,"hp":25,"maxHp":25,"owner":"host","by":"h2"},
                      {"id":"w1","kind":"wall","x":5,"y":3,"hp":20,"maxHp":20,"owner":"host","by":"h4"}]'::jsonb);
select t_place(:'m','g2',3,5); select t_place(:'m','g3',2,3);
select public.submit_move(:'m','g2',3,4);
select set_config('app.uid','99aa0000-0000-0000-0000-00000000099a',false);
select t_raises(format($$select public.submit_throw(%L,'@5,3')$$, :'m'),
                'tile is taken', 'A GALE DOES NOT PUT SOMEBODY INSIDE A WALL');
select t_raises(format($$select public.submit_throw(%L,'@2,3')$$, :'m'),
                'tile is taken', 'nor on top of another unit');
select public.submit_throw(:'m', null);

-- ---- a crown thrown onto a trap ends it ------------------------------------
select set_config('app.uid','bbcc0000-0000-0000-0000-0000000000bc',false);
select t_reset(:'m');
select t_park(:'m', array['h1','h2','h3','h4','h5','g2','g3','g4','g5']);
select t_trees(:'m','[{"id":"z1","kind":"tornado","x":3,"y":4,"hp":25,"maxHp":25,"owner":"host","by":"h2"},
                      {"id":"b1","kind":"bomb","x":5,"y":3,"hp":15,"maxHp":15,"dmg":15,"owner":"host","by":"h3"}]'::jsonb);
select t_place(:'m','g1',3,5); select t_hp(:'m','g1',10);
select public.submit_move(:'m','g1',3,4);
select set_config('app.uid','99aa0000-0000-0000-0000-00000000099a',false);
select public.submit_throw(:'m','@5,3');
select t_ok((select winner from public.matches where id = :'m') = 'host'
        and (select status from public.matches where id = :'m') = 'finished',
            'A CROWN THROWN ONTO A TRAP LOSES THE MATCH');
