-- Phase B, first half: the board stands up, and a turn becomes two goes.
--
-- 0019. Three rules arrive together and this file holds all three: an 8-tall
-- 6-wide board whose halves are top and bottom, a turn that is two
-- activations rather than everybody-does-everything, and Defend.
--
-- Unlike parry and crit there is no hatch to pin here -- the budget falls out
-- of turnNumber, so it is already deterministic. What this file must NOT do is
-- call t_reset. That helper clears 'acts' and 'active' on purpose, so that the
-- rest of the suite can keep testing reach and counters without fighting the
-- budget; a test OF the budget that reset it would assert nothing at all.
\set ON_ERROR_STOP on
\pset pager off

delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('eeee0000-0000-0000-0000-00000000000e','e@x.com','{"username":"edda"}'),
  ('ffff0000-0000-0000-0000-00000000000f','f@x.com','{"username":"finn"}');

-- ===========================================================================
-- 1. the shape of the board -- no match needed, these are pure functions
-- ===========================================================================
select t_ok((public.cn_fresh_map()->'board'->>'w')::int = 6
        and (public.cn_fresh_map()->'board'->>'h')::int = 8,
            'the board is six wide and eight tall');

select t_ok(public.cn_own_side('host', 0, 8) and public.cn_own_side('host', 3, 8)
        and not public.cn_own_side('host', 4, 8),
            'the host holds rows 0-3');
select t_ok(public.cn_own_side('guest', 7, 8) and public.cn_own_side('guest', 4, 8)
        and not public.cn_own_side('guest', 3, 8),
            'and the guest holds rows 4-7');

-- ---- the opening formation ----------------------------------------------
select t_ok((select bool_and((e->>'y')::int < 4) from jsonb_array_elements(
              public.cn_army(public.cn_fresh_map(),'host',public.default_deck())) e),
            'the host army forms up on its own rows');
select t_ok((select bool_and((e->>'y')::int >= 4) from jsonb_array_elements(
              public.cn_army(public.cn_fresh_map(),'guest',public.default_deck())) e),
            'and the guest army on its own');
-- Row 0 is a home row, so 0019 keeps it clear of trees -- which means all five
-- fit on it and the back rank fills before anybody steps forward.
select t_ok((select count(*) from jsonb_array_elements(
              public.cn_army(public.cn_fresh_map(),'host',public.default_deck())) e
              where (e->>'y')::int = 0) = 5,
            'and it fills its back row before stepping forward');

-- ---- the trees -----------------------------------------------------------
-- Rolled a hundred times rather than once. The placement is random, and a rule
-- that holds for one layout and not the next is exactly the bug worth having a
-- test for -- the old generator was allowed eighty shuffled goes before it fell
-- back, so a single roll proves very little.
select t_ok((select bool_and(
         jsonb_array_length(o) = 8
     and (select count(*) from jsonb_array_elements(o) e where (e->>'y')::int < 4) = 4
     and (select count(*) from jsonb_array_elements(o) e where (e->>'y')::int in (0,7)) = 0
     and (select bool_and(public.cn_cheb((a.a->>'x')::int,(a.a->>'y')::int,
                                         (b.b->>'x')::int,(b.b->>'y')::int) >= 2)
            from jsonb_array_elements(o) with ordinality a(a,i),
                 jsonb_array_elements(o) with ordinality b(b,j) where a.i < b.j))
       from (select public.cn_gen_trees(6,8) as o from generate_series(1,100)) s),
            'a hundred rolls: eight trees, four a side, none on a home row, none touching');

-- ===========================================================================
-- 2. the budget
-- ===========================================================================
select set_config('app.uid', 'eeee0000-0000-0000-0000-00000000000e', false);
select public.set_deck(array['dione-grifo','dereo','mako','wuzu','eva']);
select set_config('app.uid', 'ffff0000-0000-0000-0000-00000000000f', false);
select public.set_deck(array['dereo','eva','umiro','lumea','mako']);

select t_match('eeee0000-0000-0000-0000-00000000000e',
               'ffff0000-0000-0000-0000-00000000000f') as m \gset

-- Hand the turn to a named side and leave app.uid as that player. Counting
-- end_turns by hand across a dozen sections is how a test file quietly starts
-- asserting about the wrong player.
--
-- It always hands the turn over at LEAST once, even when it is already
-- p_side's go. A section asking for "a fresh turn as the host" wants the flags
-- and the budget reset; returning a no-op because the host happened to still
-- be mid-turn would hand it a half-spent one, and the assertion that follows
-- would be about the wrong thing.
create or replace function t_turn(p_m uuid, p_side text) returns void
language plpgsql as $$
declare i int := 0; v_who text;
begin
  loop
    select state->>'turn' into v_who from public.matches where id = p_m;
    perform set_config('app.uid',
      (case when v_who = 'host' then 'eeee0000-0000-0000-0000-00000000000e'
                                else 'ffff0000-0000-0000-0000-00000000000f' end), false);
    perform public.end_turn(p_m);
    i := i + 1;
    select state->>'turn' into v_who from public.matches where id = p_m;
    exit when v_who = p_side or i >= 4;
  end loop;
  perform set_config('app.uid',
    (case when p_side = 'host' then 'eeee0000-0000-0000-0000-00000000000e'
                               else 'ffff0000-0000-0000-0000-00000000000f' end), false);
end $$;

select set_config('app.uid', 'eeee0000-0000-0000-0000-00000000000e', false);
select t_trees(:'m', '[]'::jsonb);
select t_park(:'m', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);
select t_set(:'m','h1','mov','1'::jsonb), t_set(:'m','h1','rmin','1'::jsonb),
       t_set(:'m','h1','rmax','1'::jsonb), t_dmg(:'m','h1',0);
select t_set(:'m','h2','mov','1'::jsonb), t_set(:'m','h2','rmin','1'::jsonb),
       t_set(:'m','h2','rmax','1'::jsonb), t_dmg(:'m','h2',0);
select t_set(:'m','h3','mov','1'::jsonb);
-- g1 is a wall to hit, not a fighter: enough hit points that nothing below
-- kills it and ends the match, and no damage so its counter never muddies a
-- number this file is asserting about.
--
-- Its burn is turned off for the same reason, and it is the subtler one. g1 is
-- Dereo, who sets what he hits alight, and a burning unit loses 5 more
-- whenever it swings. The Defend arithmetic below would then be reading a
-- blow plus a burn tick and calling the total "half of 40" -- which is how a
-- test ends up green for the wrong reason, or red for one. Burn has its own
-- assertions in 04 and 09; this file is about the guard.
select t_set(:'m','g1','maxHp','400'::jsonb), t_hp(:'m','g1',400), t_dmg(:'m','g1',0),
       t_set(:'m','g1','burns','false'::jsonb),
       t_set(:'m','g1','rmin','1'::jsonb), t_set(:'m','g1','rmax','1'::jsonb);

-- ---- the opening turn is one go -----------------------------------------
select t_ok(public.cn_acts_cap((select state from public.matches where id=:'m')) = 1,
            'whoever opens the match gets one activation, not two');

select t_place(:'m','h1',2,2); select t_place(:'m','h2',0,2); select t_place(:'m','g1',2,4);
select public.submit_move(:'m','h1',2,3);
select t_ok((select (state->>'acts')::int from public.matches where id=:'m') = 1,
            'moving opens an activation');
select t_ok((select state->>'active' from public.matches where id=:'m') = 'h1',
            'and leaves that unit mid-go');
select t_raises(format('select public.submit_move(%L,''h2'',0,3)', :'m'),
                'no actions left', 'so a second unit cannot move on the opening turn');

-- The point of the whole model: the unit already mid-go strikes for free.
select public.submit_attack(:'m','h1','g1');
select t_ok((select (state->>'acts')::int from public.matches where id=:'m') = 1,
            'move-then-strike is ONE activation, not two');
select t_ok((select state->>'active' from public.matches where id=:'m') is null,
            'and striking closes it');
select t_ok(t_get(:'m','h1','spent') = 'true', 'the unit that struck has had its go');

-- ---- every turn after it is two -----------------------------------------
select t_turn(:'m','host');
select t_ok(public.cn_acts_cap((select state from public.matches where id=:'m')) = 2,
            'every turn after the first is two');
select t_ok(t_get(:'m','h1','spent') = 'false', 'and a new turn hands every unit its go back');
select t_ok((select (state->>'acts')::int from public.matches where id=:'m') = 0,
            'with the budget back to nothing spent');

select t_place(:'m','h1',2,2); select t_place(:'m','h2',0,2); select t_place(:'m','h3',4,0);
select public.submit_move(:'m','h1',2,3);
select public.submit_move(:'m','h2',0,3);
select t_ok((select (state->>'acts')::int from public.matches where id=:'m') = 2,
            'two different units is two activations');
select t_ok(t_get(:'m','h1','spent') = 'true',
            'and turning to the second ends the first one''s go -- it moved and chose not to strike');
select t_raises(format('select public.submit_move(%L,''h3'',4,1)', :'m'),
                'no actions left', 'a third unit is refused');
-- h1 moved but never struck. Its go ended when h2 was activated, so it cannot
-- wander back into the fight -- this is the "one activation per unit" half of
-- the rule, and it is enforced by 'spent' rather than by the budget.
select t_raises(format('select public.submit_attack(%L,''h1'',''g1'')', :'m'),
                'already had its go',
                'and the unit left behind mid-move cannot come back and strike');

-- ---- end turn is available whenever -------------------------------------
-- Asserted on the board rather than on the return value: end_turn hands back a
-- whole matches row, and `row is not null` in Postgres means EVERY column is
-- non-null -- which a live match, with no winner yet, never is.
select t_turn(:'m','host');
select public.end_turn(:'m');
select t_ok((select state->>'turn' from public.matches where id=:'m') = 'guest',
            'a turn can be ended without spending anything');

-- ===========================================================================
-- 3. Defend
-- ===========================================================================
-- Pinned off explicitly: a parry or a crit landing in the middle of these
-- would make the halving arithmetic below read as a failure.
set cn.force_parry = 'never'; set cn.force_crit = 'never';

select t_turn(:'m','host');
select t_place(:'m','h1',2,3); select t_place(:'m','g1',2,4);
select t_set(:'m','h1','maxHp','110'::jsonb), t_hp(:'m','h1',110), t_dmg(:'m','h1',0),
       t_set(:'m','h1','burned','false'::jsonb);
select t_dmg(:'m','g1',40);

select public.submit_defend(:'m','h1');
select t_ok(t_get(:'m','h1','defending') = 'true', 'Defend raises a guard');
select t_ok((select (state->>'acts')::int from public.matches where id=:'m') = 1,
            'and it costs one of the two');
select t_ok(t_get(:'m','h1','spent') = 'true', 'and ends that unit''s go');

-- The guard has to survive the handover, because the opponent's turn is the
-- only time it could ever matter.
select t_turn(:'m','guest');
select t_ok(t_get(:'m','h1','defending') = 'true',
            'the guard is still up while the other side is swinging');
select public.submit_attack(:'m','g1','h1');
select t_ok(t_get(:'m','h1','hp')::int = 90,
            'a guarded unit takes half -- 20 through a 40 blow, not 40');

-- ...and lapses when its owner's own next turn opens, not before.
select t_turn(:'m','host');
select t_ok(t_get(:'m','h1','defending') = 'false',
            'and it lapses when its owner''s next turn opens');

-- The other half of the measurement: the same blow, same board, no guard.
-- Without this the assertion above would also pass on a build where Defend
-- did nothing and 40 damage simply never arrived.
select t_hp(:'m','h1',110);
select t_turn(:'m','guest');
select public.submit_attack(:'m','g1','h1');
select t_ok(t_get(:'m','h1','hp')::int = 70,
            'while unguarded the same blow takes the whole 40');
reset cn.force_parry; reset cn.force_crit;

-- ===========================================================================
-- 4. the bot lives under the budget too
-- ===========================================================================
-- It always DID, in the sense that it calls the same cn_* functions and they
-- refused it -- bot_step just kept proposing a third action until the server
-- raised. Being bound by a rule and knowing about it are different things.
select set_config('app.uid', 'eeee0000-0000-0000-0000-00000000000e', false);
select id as bm from public.create_bot_match(2) \gset
-- A bot match opens in deployment like any other; your Ready is what starts it.
select public.set_ready(:'bm');
select t_ok((select status from public.matches where id=:'bm') = 'active',
            'the bot match is running');

do $$
declare mid uuid; mx int := 0; i int := 0; a int; v_who text;
begin
  select id into mid from public.matches
    where bot is not null order by created_at desc limit 1;

  -- get the turn over to the bot
  i := 0;
  loop
    select state->>'turn' into v_who from public.matches where id = mid;
    exit when v_who = 'guest' or i >= 4;
    perform public.end_turn(mid);
    i := i + 1;
  end loop;

  -- let it take one whole turn, watching the counter the whole way
  i := 0;
  while (select state->>'turn' from public.matches where id = mid) = 'guest' and i < 80 loop
    perform public.bot_step(mid);
    select coalesce((state->>'acts')::int, 0), state->>'turn'
      into a, v_who from public.matches where id = mid;
    if v_who = 'guest' then mx := greatest(mx, a); end if;
    i := i + 1;
  end loop;

  if i >= 80 then raise exception 'FAIL  the bot never finished its turn'; end if;
  if mx > 2 then raise exception 'FAIL  the bot spent % activations in one turn', mx; end if;
  raise notice 'PASS  the bot takes at most two activations and then ends its turn (spent %)', mx;
end $$;
