-- =============================================================================
-- 0076 -- diagonal movement and range: a cardinal step is one point, a
-- diagonal step (a corner) is two.
--
-- Jared: "On the square grid, adjacent (cardinal) tiles cost 1 movement
-- point or range, while diagonal movements or range and corners count as 2
-- points. Ensure all pathfinding, range calculations, and movement
-- restrictions follow this 1 tile = 1 cost rule for orthogonal tiles and 2
-- cost for diagonal tiles."
--
-- WHY THIS TOUCHES TWO THINGS THAT USED TO BE DIFFERENT ON PURPOSE. 0005's
-- own header drew this distinction deliberately: "Two different rules on
-- purpose. Movement counts steps along the grid and has to walk around
-- trees, so range is a diamond and terrain actually matters. Reach counts a
-- diagonal as one, so attacks and counters cover a square." Movement was a
-- plain 4-directional walk (cn_reach) -- diagonal movement did not exist at
-- all -- and reach/range was cn_cheb, Chebyshev distance, which treats a
-- diagonal neighbour as one tile away, the same as a cardinal one. Jared's
-- rule replaces both single-purpose shapes with one metric used everywhere:
-- a cardinal tile costs 1, a diagonal tile (a corner) costs 2. Movement
-- gains diagonal steps it never had; range stops treating a diagonal
-- neighbour as "one tile away."
--
-- THE CLOSED FORM. Unobstructed, this number has one: reaching a tile
-- (dx, dy) away optimally takes min(|dx|,|dy|) diagonal steps to close the
-- smaller axis and |dx|-|dy| (absolute) cardinal steps to finish the larger
-- one -- 2*min + (max-min) = max + min = |dx| + |dy|. A diagonal step is
-- worth exactly two cardinal ones, never less, so it can never shorten a
-- trip on open ground -- two cardinal steps buy the same displacement for
-- the same two points. What a diagonal buys is a route THROUGH A CORNER
-- that cardinal steps alone cannot take at all: if a tile's two cardinal
-- neighbours are both blocked but the tile itself is not, the diagonal step
-- onto it is the only way there, at a real cost of two, not a shortcut.
-- Range never looks at what's standing in between anyway -- cn_los_clear
-- handles that separately -- so the range side of this is now exactly
-- |dx| + |dy|, plain taxicab distance, computed with no need to walk
-- anything out.
--
-- cn_cheb KEEPS ITS NAME. It is no longer Chebyshev distance -- it is
-- taxicab distance now -- but it is called by that name at roughly ninety
-- sites across every migration since 0005: every attack and counter range
-- check, every ability's adjacency and "how far away" test, structure
-- placement range, Lumea's throw distance, THE_TARGET's FIXED_RANGE/
-- CARD_RANGE gate. create or replace function changes the body in place for
-- all of them at once without touching a single call site -- renaming it
-- would mean rewriting all ninety, each its own bigger and riskier diff
-- than this formula change, for a name only this comment reads.
--
-- WHAT DELIBERATELY DOES NOT MOVE WITH IT. Two existing consumers used
-- cn_cheb for something that was never "a unit's move or range" and both
-- are decoupled below so their behaviour is unaffected byte-for-byte:
--   * cn_gen_trees / cn_royale_gen_trees's own "no two trees touch" spacing
--     check at generation time -- a terrain-layout rule, nothing to do with
--     any unit's reach. Both now carry the literal old Chebyshev formula
--     inline instead of calling cn_cheb, so destructible trees still never
--     spawn touching, diagonally included, exactly as before.
--   * cn_revive's "an adjacent free tile" search (0074) was never built on
--     cn_cheb in the first place -- it walks its own 3x3 neighbourhood
--     directly -- so a revived unit can still land on any of the 8 tiles
--     around its reviver, not only the 4 this function would now call
--     "distance 1". Revival placement is not a range rule either.
--
-- cn_reach: THE ALGORITHM CHANGE. Every edge used to cost the same single
-- point, so breadth-first search's guarantee -- the first time you see a
-- tile is the cheapest way to it -- was free. Two different edge costs (1
-- cardinal, 2 diagonal) break that: a tile can be FOUND by one route before
-- a cheaper route to it is discovered, so "seen" and "cheapest" are no
-- longer the same question, and working out the true cheapest cost takes
-- relaxing edges rather than visiting each tile once. The fix is not a full
-- Dijkstra with a priority queue -- overkill for a board this size -- but
-- the bounded relaxation Bellman-Ford uses: every edge costs at least 1, so
-- any route that stays inside p_mov crosses at most p_mov of them, which
-- means p_mov full passes over every tile reached so far -- each one
-- relaxing that tile's up-to-eight neighbours -- is guaranteed to have
-- settled everyone's true cheapest cost by the end (the same guarantee
-- Bellman-Ford gives after as many rounds as a path can have edges, just
-- bounded by the wallet instead of by the graph's size). rules.ts's
-- reachable()/pathTo() mirror this exactly, including the bound.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. cn_cheb -- taxicab distance now, not Chebyshev. See header.
-- ---------------------------------------------------------------------------
create or replace function public.cn_cheb(ax int, ay int, bx int, by int)
returns int language sql immutable as $$
  select abs(ax - bx) + abs(ay - by)
$$;

-- ---------------------------------------------------------------------------
-- 2. cn_reach -- an 8-directional weighted walk (1 cardinal, 2 diagonal),
--    bounded-relaxation, in place of the old 4-directional breadth-first
--    one. Signature, callers (cn_move, cn_move_royale, the bot AI in 0007/
--    0052), and every flying/trampling rule are all unchanged -- only how
--    "how far can this go" is worked out.
-- ---------------------------------------------------------------------------
create or replace function public.cn_reach(p_state jsonb, p_unit jsonb)
returns text[] language plpgsql immutable as $$
declare
  v_w int := (p_state->'board'->>'w')::int;
  v_h int := (p_state->'board'->>'h')::int;
  v_mov int := (p_unit->>'mov')::int;
  v_flies boolean := coalesce((p_unit->>'flies')::boolean, false);
  v_tramples boolean := coalesce((p_unit->>'tramples')::boolean, false);
  v_body boolean[]; v_tree boolean[]; v_fell boolean[];
  v_cost int[];
  e jsonb; i int; j int; k int; v_round int;
  v_x int; v_y int; nx int; ny int; v_nc int;
  v_ox int; v_oy int; v_start int;
  v_changed boolean;
  -- The four cardinal directions at a point apiece, then the four corners
  -- (the diagonals) at two.
  v_dx int[] := array[1, -1, 0, 0, 1, 1, -1, -1];
  v_dy int[] := array[0, 0, 1, -1, 1, -1, 1, -1];
  v_dw int[] := array[1, 1, 1, 1, 2, 2, 2, 2];
  v_out text[] := '{}';
begin
  v_body := array_fill(false, array[v_w * v_h]);
  v_tree := array_fill(false, array[v_w * v_h]);
  v_fell := array_fill(false, array[v_w * v_h]);
  for e in select * from jsonb_array_elements(p_state->'units') loop
    v_body[(e->>'y')::int * v_w + (e->>'x')::int + 1] := true;
  end loop;
  for e in select * from jsonb_array_elements(coalesce(p_state->'obstacles', '[]'::jsonb)) loop
    -- v_tree is "solid object" and the name is left alone on purpose --
    -- renaming a local in a spliced function is a diff nobody can read
    -- against the original. A trap and a tornado are walked onto rather
    -- than walked round, so neither belongs in here.
    if cn_obj_solid(cn_obj_kind(e)) then
      v_tree[(e->>'y')::int * v_w + (e->>'x')::int + 1] := true;
    end if;
    -- Trample is a rule about TREES, not about everything in the way.
    if cn_obj_kind(e) = 'tree' then
      v_fell[(e->>'y')::int * v_w + (e->>'x')::int + 1] := true;
    end if;
  end loop;

  -- FLIGHT IS STILL NOT A PASS -- v_flies is read out of the snapshot and
  -- deliberately unused. See 0038's own note above this function's prior
  -- body for why: a flier walks the same grid as everybody else, diagonals
  -- included now, and what the Flying class keeps is a bigger mov number.

  v_cost := array_fill(-1, array[v_w * v_h]);
  v_ox := (p_unit->>'x')::int; v_oy := (p_unit->>'y')::int;
  v_start := v_oy * v_w + v_ox + 1;
  v_cost[v_start] := 0;

  for v_round in 1..greatest(v_mov, 0) loop
    v_changed := false;
    for i in 1..(v_w * v_h) loop
      if v_cost[i] < 0 or v_cost[i] >= v_mov then continue; end if;
      v_x := (i - 1) % v_w; v_y := (i - 1) / v_w;
      for k in 1..8 loop
        nx := v_x + v_dx[k]; ny := v_y + v_dy[k];
        if nx < 0 or ny < 0 or nx >= v_w or ny >= v_h then continue; end if;
        j := ny * v_w + nx + 1;
        -- a trampler treats a tree as ground; everyone else stops at it
        if v_body[j] or (v_tree[j] and not (v_tramples and v_fell[j])) then continue; end if;
        v_nc := v_cost[i] + v_dw[k];
        if v_nc > v_mov then continue; end if;
        if v_cost[j] < 0 or v_nc < v_cost[j] then
          v_cost[j] := v_nc;
          v_changed := true;
        end if;
      end loop;
    end loop;
    exit when not v_changed;
  end loop;

  for i in 1..(v_w * v_h) loop
    if v_cost[i] >= 0 and i <> v_start then
      v_x := (i - 1) % v_w; v_y := (i - 1) / v_w;
      v_out := v_out || (v_x || ',' || v_y);
    end if;
  end loop;
  return v_out;
end $$;

-- ---------------------------------------------------------------------------
-- 3. cn_gen_trees -- decoupled from cn_cheb (see header): the "no two trees
--    touch" spacing check now carries its own literal Chebyshev formula
--    rather than calling the function that no longer computes it, so
--    generated layouts are unaffected. Everything else copied unchanged
--    from 0035's body, the latest before this one.
-- ---------------------------------------------------------------------------
create or replace function public.cn_gen_trees(p_w integer, p_h integer)
returns jsonb
language plpgsql as $$
declare
  v_try int; v_band int; v_lo int; v_hi int; v_n int;
  v_cand int[]; v_pick int[] := '{}'::int[]; v_ok boolean;
  i int; j int; v_x int; v_y int; v_px int; v_py int;
  v_out jsonb := '[]'::jsonb; v_k int := 0;
begin
  for v_try in 1..80 loop
    v_pick := '{}'::int[];
    for v_band in 0..1 loop
      if v_band = 0 then v_lo := 0; v_hi := p_h / 2 - 1;
                    else v_lo := p_h / 2; v_hi := p_h - 1; end if;

      select array_agg(t) into v_cand from (
        select gy.y * p_w + gx.x as t
          from generate_series(0, p_w - 1) as gx(x),
               generate_series(v_lo, v_hi) as gy(y)
         where gy.y <> 0 and gy.y <> p_h - 1
           and not ((gx.x = 0 or gx.x = p_w - 1) and (gy.y = 0 or gy.y = p_h - 1))
         order by random()) s;

      v_n := 0;
      foreach i in array v_cand loop
        exit when v_n = 4;
        v_x := i % p_w; v_y := i / p_w;
        v_ok := true;
        foreach j in array v_pick loop
          v_px := j % p_w; v_py := j / p_w;
          -- Literal Chebyshev, not cn_cheb -- see this migration's header.
          if greatest(abs(v_x - v_px), abs(v_y - v_py)) < 2 then v_ok := false; exit; end if;
        end loop;
        if v_ok then v_pick := v_pick || i; v_n := v_n + 1; end if;
      end loop;
      exit when v_n < 4;
    end loop;
    exit when coalesce(array_length(v_pick, 1), 0) = 8;
  end loop;

  if coalesce(array_length(v_pick, 1), 0) <> 8 then
    v_pick := array[ 1 * p_w + 0, 1 * p_w + 2, 1 * p_w + 4,
                     (p_h / 2 - 1) * p_w + 1,
                     (p_h - 2) * p_w + 1, (p_h - 2) * p_w + 3,
                     (p_h - 2) * p_w + 5, (p_h / 2) * p_w + 4 ];
  end if;

  foreach i in array v_pick loop
    v_k := v_k + 1;
    v_out := v_out || jsonb_build_object(
      'id', 't' || v_k, 'kind', 'tree', 'x', i % p_w, 'y', i / p_w,
      'hp', cn_obj_hp('tree'), 'maxHp', cn_obj_hp('tree'));
  end loop;
  return v_out;
end
$$;

-- ---------------------------------------------------------------------------
-- 4. cn_royale_gen_trees -- the same decoupling, royale's own tree
--    generator. Everything else copied unchanged from 0048's body.
-- ---------------------------------------------------------------------------
create or replace function public.cn_royale_gen_trees(p_w int, p_h int)
returns jsonb language plpgsql as $$
declare
  v_cand int[]; v_pick int[] := '{}'::int[];
  i int; j int; v_x int; v_y int; v_px int; v_py int;
  v_ok boolean; v_out jsonb := '[]'::jsonb; v_k int := 0; v_n int := 0;
begin
  select array_agg(t) into v_cand from (
    select gy.y * p_w + gx.x as t
      from generate_series(0, p_w - 1) as gx(x),
           generate_series(0, p_h - 1) as gy(y)
     where gy.y not in (3, 4)
     order by random()) s;

  foreach i in array coalesce(v_cand, '{}'::int[]) loop
    exit when v_n = 6;
    v_x := i % p_w; v_y := i / p_w;
    v_ok := true;
    foreach j in array v_pick loop
      v_px := j % p_w; v_py := j / p_w;
      -- Literal Chebyshev, not cn_cheb -- see this migration's header.
      if greatest(abs(v_x - v_px), abs(v_y - v_py)) < 2 then v_ok := false; exit; end if;
    end loop;
    if v_ok then v_pick := v_pick || i; v_n := v_n + 1; end if;
  end loop;

  foreach i in array v_pick loop
    v_k := v_k + 1;
    v_out := v_out || jsonb_build_object(
      'id', 'rt' || v_k, 'kind', 'tree', 'x', i % p_w, 'y', i / p_w,
      'hp', cn_obj_hp('tree'), 'maxHp', cn_obj_hp('tree'));
  end loop;
  return v_out;
end
$$;

-- ---------------------------------------------------------------------------
-- 5. self-check -- fails the whole migration loudly rather than shipping a
--    half-applied rule. The full suite (37_diagonal_move_and_range.sql)
--    covers this properly; this is the "if this is badly wrong, stop here"
--    net every migration since 0075 leaves for itself.
-- ---------------------------------------------------------------------------
do $$
declare v_state jsonb; v_unit jsonb; v_trees jsonb;
begin
  -- Range: a cardinal neighbour is 1 tile away, a diagonal one is 2.
  assert cn_cheb(2, 2, 3, 2) = 1, 'a cardinal neighbour must be distance 1';
  assert cn_cheb(2, 2, 3, 3) = 2, 'a diagonal neighbour must now be distance 2, not 1';
  assert cn_cheb(2, 2, 5, 2) = 3, 'three tiles in a straight cardinal line is distance 3';
  assert cn_cheb(2, 2, 2, 2) = 0, 'a tile is distance 0 from itself';

  -- Movement, open ground: mov 1 reaches only the 4 cardinal neighbours,
  -- never a diagonal one -- a diagonal step alone already costs the whole
  -- budget's worth plus one.
  v_state := '{"board":{"w":6,"h":6},"units":[],"obstacles":[]}'::jsonb;
  v_unit := '{"id":"a","x":2,"y":2,"mov":1}'::jsonb;
  assert '3,2' = any(cn_reach(v_state, v_unit)), 'mov 1 reaches the cardinal neighbour east';
  assert not ('3,3' = any(cn_reach(v_state, v_unit))),
    'mov 1 must NOT reach a diagonal neighbour -- that costs 2';
  assert array_length(cn_reach(v_state, v_unit), 1) = 4,
    'mov 1 on open ground reaches exactly the 4 cardinal tiles';

  -- Movement, open ground: mov 2 DOES reach a diagonal neighbour now, and
  -- also every cardinal tile 2 away.
  v_unit := '{"id":"a","x":2,"y":2,"mov":2}'::jsonb;
  assert '3,3' = any(cn_reach(v_state, v_unit)),
    'mov 2 reaches a diagonal neighbour -- new capability, cost 2';
  assert '4,2' = any(cn_reach(v_state, v_unit)), 'mov 2 still reaches 2 cardinal tiles away';

  -- The whole point of allowing diagonals: a tile boxed in by its own two
  -- cardinal neighbours is still reachable through the corner, because the
  -- diagonal step never asks about anything but the tile it lands on.
  -- 'tree' rather than 'wall' here on purpose: it is the one obstacle kind
  -- guaranteed solid from the game's foundation rather than data looked up
  -- in the structures table, so this assertion never depends on catalog
  -- rows this migration has no business assuming about.
  v_state := '{"board":{"w":4,"h":4},"units":[],"obstacles":[
    {"id":"o1","kind":"tree","x":1,"y":0,"hp":30,"maxHp":30},
    {"id":"o2","kind":"tree","x":0,"y":1,"hp":30,"maxHp":30}
  ]}'::jsonb;
  v_unit := '{"id":"a","x":0,"y":0,"mov":2}'::jsonb;
  assert '1,1' = any(cn_reach(v_state, v_unit)),
    'BOXED IN A CORNER: both cardinal neighbours are trees, but the ' ||
    'diagonal tile itself is free -- a diagonal step, cost 2, is the only ' ||
    'way there, and it must work';
  v_unit := '{"id":"a","x":0,"y":0,"mov":1}'::jsonb;
  assert not ('1,1' = any(cn_reach(v_state, v_unit))),
    'the same corner at mov 1 is out of budget -- a diagonal costs 2';

  -- Tree spacing is unaffected: cn_gen_trees never places two trees within
  -- Chebyshev distance 1 of each other, diagonal included, exactly as
  -- before this migration. One generated layout, checked against itself --
  -- not two independent rolls compared to one another.
  v_trees := cn_gen_trees(6, 8);
  assert (select bool_and(greatest(abs((a.a->>'x')::int - (b.b->>'x')::int),
                                    abs((a.a->>'y')::int - (b.b->>'y')::int)) >= 2)
            from jsonb_array_elements(v_trees) with ordinality a(a, i),
                 jsonb_array_elements(v_trees) with ordinality b(b, j)
           where a.i < b.j) is not false,
    'cn_gen_trees keeps its own literal spacing rule, untouched by the cn_cheb change';

  raise notice '0076 self-check: all diagonal move/range assertions passed';
end
$$;
