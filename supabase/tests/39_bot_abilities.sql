-- 0148: the bot uses abilities strategically now. Jared: "can you make the
-- bot even smarter right now? I want it to use abilities very strategically
-- too!" -- before this, bot_step never once called cn_ability; every card
-- it commanded could only move or throw a basic attack. This proves the new
-- scoring/execution path with the sharpest case on the roster: Fey's
-- "burn it, then detonate it" combo, which only comes out right if the bot
-- actually runs the card's real ON_ABILITY script rather than a hand-coded
-- approximation of it (see cn_bot_score_ability's header).
\set ON_ERROR_STOP on

delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('bb000000-0000-0000-0000-000000000001','b1@x.com','{"username":"bone"}'),
  ('bb000000-0000-0000-0000-000000000002','b2@x.com','{"username":"btwo"}');

select set_config('app.uid','bb000000-0000-0000-0000-000000000001',false);
select public.set_deck(array['dereo','dione-grifo','eva','sinie','lumea']);
select set_config('app.uid','bb000000-0000-0000-0000-000000000002',false);
select public.set_deck(array['stelaris','fey','mako','umiro','dorme']);
select t_match('bb000000-0000-0000-0000-000000000001',
               'bb000000-0000-0000-0000-000000000002') as m \gset

select set_config('app.uid','bb000000-0000-0000-0000-000000000001',false);
select t_trees(:'m','[]'::jsonb);

-- Mark the match as a level-3 bot game on the guest seat (bot_step only
-- reads matches.bot/host_bot and the state -- it does not care whether the
-- seat is really a human or the guest_id is real, so this is a faithful way
-- to test the decision function directly without create_bot_match's own
-- deck-picking getting in the way of choosing Fey deliberately).
update public.matches set bot = 3, status = 'active',
  state = jsonb_set(state, '{turn}', '"guest"') where id = :'m';

select t_ok(t_get(:'m','g2','name') = 'Fey', 'fey is g2 in this deck order');
select t_ok(t_get(:'m','h1','name') = 'King Dereo', 'dereo is h1 in this deck order');

-- Fey (rmin 1 / rmax 3) two tiles from Dereo -- in range, no move needed --
-- and Dereo is already burning, so Fey's ability scores its 30-damage
-- detonate row (worth 300 in the bot's own currency) rather than its
-- 25-point "just apply burn" row -- comfortably ahead of a basic attack
-- (~150) even after the level-3 noise band (+/-15).
select t_place(:'m', 'g2', 2, 2);
select t_place(:'m', 'h1', 2, 1);
select t_burn(:'m', 'h1');
select t_full(:'m', 'h1');
select t_reset(:'m');

select public.bot_step(:'m');

select t_ok(t_get(:'m','g2','acted') = 'true', 'fey acted this call');
select t_ok(t_get(:'m','g2','spent') = 'true', 'and spent its whole turn on it -- an ability, not a move');
select t_ok(t_get(:'m','h1','hp')::int = 80,
            'dereo took the detonate''s 30 damage, not a basic attack''s ~15 -- the bot chose the ability');
select t_ok((t_get(:'m','h1','effects')::jsonb->>'burn')::boolean, 'and the burn itself is untouched');

\echo '--- bot abilities: all assertions passed ---'
