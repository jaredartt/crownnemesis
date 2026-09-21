-- 0076: diagonal movement and range -- a cardinal step costs 1 point, a
-- diagonal one (a corner) costs 2. Before this migration movement never had
-- a diagonal step at all (cn_reach only ever walked the four cardinal
-- directions) and range (cn_cheb, Chebyshev distance) counted a diagonal
-- neighbour the same as a cardinal one. See 0076's own header for the full
-- why. This file checks the metric itself (cn_cheb, cn_reach) and that it
-- is actually enforced at the RPC boundary a client calls (cn_move,
-- submit_attack), not only in a helper function nobody outside this suite
-- would notice drifting.
\set ON_ERROR_STOP on
\pset pager off

-- ---- cn_cheb is taxicab distance now, not Chebyshev ------------------------
select t_ok(cn_cheb(2,2,3,2) = 1, 'a cardinal neighbour is distance 1');
select t_ok(cn_cheb(2,2,2,3) = 1, 'so is the other cardinal direction');
select t_ok(cn_cheb(2,2,3,3) = 2,
            'A DIAGONAL NEIGHBOUR IS NOW DISTANCE 2, not 1 -- the whole point of this migration');
select t_ok(cn_cheb(2,2,1,1) = 2, 'and the other three corners the same');
select t_ok(cn_cheb(2,2,4,2) = 2,
            'two tiles in a straight cardinal line is also distance 2 -- the same number as one diagonal step, a coincidence of the formula, not a rule about diagonals being free');
select t_ok(cn_cheb(2,2,5,5) = 6, 'three tiles diagonally is three diagonal steps'' worth, two apiece');
select t_ok(cn_cheb(2,2,2,2) = 0, 'a tile is distance 0 from itself');

-- ---- cn_reach: movement gains diagonals, at twice the cardinal cost --------
\set OPEN '{"board":{"w":6,"h":6},"units":[],"obstacles":[]}'
select t_ok('3,2' = any(cn_reach(:'OPEN'::jsonb, '{"id":"a","x":2,"y":2,"mov":1}'::jsonb)),
            'mov 1 reaches a cardinal neighbour');
select t_ok(not ('3,3' = any(cn_reach(:'OPEN'::jsonb, '{"id":"a","x":2,"y":2,"mov":1}'::jsonb))),
            'MOV 1 DOES NOT REACH A DIAGONAL NEIGHBOUR -- that costs 2, one more than the whole budget');
select t_ok((select count(*) from unnest(cn_reach(:'OPEN'::jsonb, '{"id":"a","x":2,"y":2,"mov":1}'::jsonb)) k) = 4,
            'mov 1 in the open reaches exactly the 4 cardinal tiles -- a plus sign, not yet a diamond');

select t_ok('3,3' = any(cn_reach(:'OPEN'::jsonb, '{"id":"a","x":2,"y":2,"mov":2}'::jsonb)),
            'MOV 2 REACHES A DIAGONAL NEIGHBOUR -- a tile movement never had at all before 0076');
select t_ok('4,2' = any(cn_reach(:'OPEN'::jsonb, '{"id":"a","x":2,"y":2,"mov":2}'::jsonb)),
            'and still reaches 2 tiles away in a straight cardinal line');
select t_ok(not ('4,4' = any(cn_reach(:'OPEN'::jsonb, '{"id":"a","x":2,"y":2,"mov":2}'::jsonb))),
            'but not 2 tiles diagonally in each axis -- that is two diagonal steps, cost 4, twice the budget');

-- ---- what diagonal movement actually buys: a way through a corner ---------
-- Two trees pin BOTH cardinal neighbours of (1,1), but (1,1) itself is
-- free. No cardinal-only route can ever cross it -- both doors are shut --
-- while the diagonal step onto it only ever asks whether (1,1) itself is
-- occupied, so it is the one route through, at a real cost of 2, never a
-- shortcut.
\set BOXED '{"board":{"w":4,"h":4},"units":[],"obstacles":[{"id":"t1","kind":"tree","x":1,"y":0,"hp":30,"maxHp":30},{"id":"t2","kind":"tree","x":0,"y":1,"hp":30,"maxHp":30}]}'
select t_ok('1,1' = any(cn_reach(:'BOXED'::jsonb, '{"id":"a","x":0,"y":0,"mov":2}'::jsonb)),
            'A TILE BOXED IN BY ITS OWN TWO CARDINAL NEIGHBOURS IS STILL REACHABLE THROUGH THE CORNER, at cost 2');
select t_ok(not ('1,1' = any(cn_reach(:'BOXED'::jsonb, '{"id":"a","x":0,"y":0,"mov":1}'::jsonb))),
            'and out of reach at mov 1 -- the corner is never a shortcut, it still costs 2');

-- ---- and it is true on the board, not only in a helper function -----------
delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('ee000000-0000-0000-0000-0000000000e1','e1@x.com','{"username":"diag1"}'),
  ('ee000000-0000-0000-0000-0000000000e2','e2@x.com','{"username":"diag2"}');

select set_config('app.uid','ee000000-0000-0000-0000-0000000000e1',false);
select public.set_deck(array['dereo','dione-grifo','mako','wuzu','eva']);
select set_config('app.uid','ee000000-0000-0000-0000-0000000000e2',false);
select public.set_deck(array['dereo','lium','himanta','fey','umiro']);

select set_config('app.uid','ee000000-0000-0000-0000-0000000000e1',false);
select id, code from public.create_match() \gset
select set_config('app.uid','ee000000-0000-0000-0000-0000000000e2',false);
select public.join_match(:'code');
select set_config('app.uid','ee000000-0000-0000-0000-0000000000e1',false);
select public.set_ready(:'id');
select set_config('app.uid','ee000000-0000-0000-0000-0000000000e2',false);
select public.set_ready(:'id');
select t_trees(:'id','[]'::jsonb);

select u->>'id' as king from public.matches m, jsonb_array_elements(m.state->'units') u
 where m.id = :'id' and u->>'owner' = 'host' and u->>'slug' = 'dereo' limit 1 \gset
select u->>'id' as prey from public.matches m, jsonb_array_elements(m.state->'units') u
 where m.id = :'id' and u->>'owner' = 'guest' and u->>'slug' = 'dereo' limit 1 \gset

-- King Dereo, rmin=rmax=1 (see 21_reach.sql's own header for that number),
-- diagonally next to the guest's own Dereo: distance 2 under the new
-- metric, so it is refused exactly the way a range-1 unit used to be
-- refused from two tiles straight away, never from the tile touching its
-- own corner.
select t_place(:'id', :'king', 2, 2);
select t_place(:'id', :'prey', 3, 3);
select set_config('app.uid','ee000000-0000-0000-0000-0000000000e1',false);
select t_ok((select (u->>'hp')::int from public.matches m, jsonb_array_elements(m.state->'units') u
              where m.id = :'id' and u->>'id' = :'prey') > 0, 'the target is standing');
select t_raises(format('select public.submit_attack(%L,%L,%L)', :'id', :'king', :'prey'),
                'out of range',
                'A RANGE-1 MELEE UNIT CANNOT STRIKE A DIAGONAL NEIGHBOUR -- distance 2 now, out of range');

-- Slide the exact same target to a cardinal neighbour instead and the same
-- pair connects fine -- this was never about the units, only the geometry.
select t_place(:'id', :'prey', 2, 3);
select public.submit_attack(:'id', :'king', :'prey');
select t_ok((select (u->>'hp')::int from public.matches m, jsonb_array_elements(m.state->'units') u
              where m.id = :'id' and u->>'id' = :'prey')
            < (select (u->>'maxHp')::int from public.matches m, jsonb_array_elements(m.state->'units') u
                where m.id = :'id' and u->>'id' = :'prey'),
            'AND THE SAME RANGE-1 UNIT STRIKES FINE FROM THE CARDINAL TILE NEXT DOOR');

-- ---- movement at the RPC boundary: cn_move honours a diagonal step --------
-- Mako (mov 2, per 0031) rather than Dereo (mov 1, per the same migration):
-- a single diagonal step costs 2, so this needs a unit that can actually
-- afford one.
select u->>'id' as runner from public.matches m, jsonb_array_elements(m.state->'units') u
 where m.id = :'id' and u->>'owner' = 'host' and u->>'slug' = 'mako' limit 1 \gset
select t_reset(:'id');
select t_place(:'id', :'runner', 2, 2);
select set_config('app.uid','ee000000-0000-0000-0000-0000000000e1',false);
select public.cn_move(:'id', 'host', :'runner', 3, 3);
select t_ok((select (u->>'x')::int = 3 and (u->>'y')::int = 3 from public.matches m,
               jsonb_array_elements(m.state->'units') u
              where m.id = :'id' and u->>'id' = :'runner'),
            'CN_MOVE ITSELF ALLOWS A DIAGONAL STEP -- the real RPC a client calls, not only cn_reach in isolation');

-- And the same unit, freshly reset, may NOT cross two diagonal steps (cost
-- 4) on a movement budget of 2.
select t_reset(:'id');
select t_place(:'id', :'runner', 0, 0);
select t_raises(format('select public.cn_move(%L,''host'',%L,2,2)', :'id', :'runner'),
                'cannot reach',
                'AND STILL REFUSES A TILE THAT IS TWO DIAGONAL STEPS AWAY -- cost 4 against a budget of 2');
