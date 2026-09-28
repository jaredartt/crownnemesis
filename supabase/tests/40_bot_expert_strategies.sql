-- 0149/0150: card-specific Expert-level (level 3 / "ruthless") bot doctrine.
-- Jared: "can we actually hard code some strategies individually for each
-- card? ... Train it right now, make it as invincible as possible with all
-- these strategies that I've talked about and your strategies too."
--
-- cn_bot_strategy_bonus (0149) is a purely additive scoring bonus, keyed by
-- card slug, layered on top of bot_step's existing engine-simulated scoring;
-- 0150 wires it into bot_step's five scoring sites (move / attack / the
-- three scripted-ability sub-branches).
--
-- Most of this file calls cn_bot_strategy_bonus directly with small, hand-
-- built board states -- that tests exactly what 0149 added, in isolation
-- from bot_step's own positional/counter noise, the same way a unit test
-- isolates one function instead of driving the whole app through it. The
-- last section is a real bot_step integration smoke test: a full bot-vs-bot
-- game at level 3 with all eight named cards on the board, proving the 0150
-- wiring itself doesn't hang or raise -- the same bar 06_bot_ranked.sql
-- already holds the plain bot to.
\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------------
-- Wuzu: under 25 avg damage it should want to flee (positive move bonus,
-- strongly negative attack bonus); at/above it should want to charge the
-- king or a nearby defender (positive move-to-king and attack-on-royal
-- bonus) and shun an equally-attackable target that is nowhere near the
-- king.
-- ---------------------------------------------------------------------------
select t_ok(
  public.cn_bot_strategy_bonus('{"units":[],"board":{"h":8}}'::jsonb, 'host',
    jsonb_build_object('slug','wuzu','dmin',3,'dmax',7), 'move', 3, 3, null) > 0,
  'wuzu under 25 avg dmg: moving (fleeing) scores positive');

select t_ok(
  public.cn_bot_strategy_bonus('{"units":[],"board":{"h":8}}'::jsonb, 'host',
    jsonb_build_object('slug','wuzu','dmin',3,'dmax',7), 'attack', 3, 3, 'anything') = -260,
  'wuzu under 25 avg dmg: attacking is penalized exactly -260, whatever the target');

select t_ok(
  public.cn_bot_strategy_bonus(
    jsonb_build_object('units', jsonb_build_array(
      jsonb_build_object('id','k1','owner','guest','royal',true,'slug','stelaris','x',0,'y',0,'hp',100),
      jsonb_build_object('id','e1','owner','guest','royal',false,'slug','eva','x',5,'y',5,'hp',100))),
    'host', jsonb_build_object('slug','wuzu','dmin',30,'dmax',30), 'attack', 3, 3, 'k1') = 260,
  'charged wuzu (avg 30): attacking the king scores +260');

select t_ok(
  public.cn_bot_strategy_bonus(
    jsonb_build_object('units', jsonb_build_array(
      jsonb_build_object('id','k1','owner','guest','royal',true,'slug','stelaris','x',0,'y',0,'hp',100),
      jsonb_build_object('id','e1','owner','guest','royal',false,'slug','eva','x',5,'y',5,'hp',100))),
    'host', jsonb_build_object('slug','wuzu','dmin',30,'dmax',30), 'attack', 3, 3, 'e1') = -40,
  'charged wuzu: attacking a non-royal target far from the king scores -40, not +260');

select t_ok(
  public.cn_bot_strategy_bonus(
    jsonb_build_object('units', jsonb_build_array(
      jsonb_build_object('id','k1','owner','guest','royal',true,'slug','stelaris','x',0,'y',0,'hp',100))),
    'host', jsonb_build_object('slug','wuzu','dmin',30,'dmax',30), 'move', 1, 1, null)
  >
  public.cn_bot_strategy_bonus(
    jsonb_build_object('units', jsonb_build_array(
      jsonb_build_object('id','k1','owner','guest','royal',true,'slug','stelaris','x',0,'y',0,'hp',100))),
    'host', jsonb_build_object('slug','wuzu','dmin',30,'dmax',30), 'move', 5, 5, null),
  'charged wuzu: a move that lands closer to the enemy king scores higher than one that does not');

-- ---------------------------------------------------------------------------
-- Eva: moving nearer a damaged Fey/Sinie/Lium she can protect scores higher
-- than moving to a spot that does neither (enemies kept far off in both
-- calls, so this isolates the protect/heal-positioning term).
-- ---------------------------------------------------------------------------
select t_ok(
  public.cn_bot_strategy_bonus(
    jsonb_build_object('units', jsonb_build_array(
      jsonb_build_object('id','l1','owner','host','royal',false,'slug','lium','x',2,'y',2,'hp',50,'maxHp',100))),
    'host', jsonb_build_object('slug','eva'), 'move', 2, 3, null)
  >
  public.cn_bot_strategy_bonus(
    jsonb_build_object('units', jsonb_build_array(
      jsonb_build_object('id','l1','owner','host','royal',false,'slug','lium','x',2,'y',2,'hp',50,'maxHp',100))),
    'host', jsonb_build_object('slug','eva'), 'move', 5, 7, null),
  'eva: moving next to a wounded lium scores higher than moving away from it');

-- ---------------------------------------------------------------------------
-- Umiro: free to roam -- deeper into enemy territory scores higher than
-- staying shallow, up to the doctrine's own cap.
-- ---------------------------------------------------------------------------
select t_ok(
  public.cn_bot_strategy_bonus('{"units":[],"board":{"h":8}}'::jsonb, 'host',
    jsonb_build_object('slug','umiro'), 'move', 3, 6, null)
  >
  public.cn_bot_strategy_bonus('{"units":[],"board":{"h":8}}'::jsonb, 'host',
    jsonb_build_object('slug','umiro'), 'move', 3, 1, null),
  'umiro: pushing deeper into enemy territory (higher depth) scores higher than staying home');

-- ---------------------------------------------------------------------------
-- Mako: blocking a BOARD_CELL ability tile that sits between its own king
-- and the nearest royal/Lium/Dione&Grifo threat scores higher than one that
-- does not.
-- ---------------------------------------------------------------------------
select t_ok(
  public.cn_bot_strategy_bonus(
    jsonb_build_object('units', jsonb_build_array(
      jsonb_build_object('id','k1','owner','host','royal',true,'slug','dereo','x',3,'y',0,'hp',110),
      jsonb_build_object('id','e1','owner','guest','royal',false,'slug','lium','x',3,'y',6,'hp',80))),
    'host', jsonb_build_object('slug','mako'), 'ability', 3, 3, '@3,3')
  >
  public.cn_bot_strategy_bonus(
    jsonb_build_object('units', jsonb_build_array(
      jsonb_build_object('id','k1','owner','host','royal',true,'slug','dereo','x',3,'y',0,'hp',110),
      jsonb_build_object('id','e1','owner','guest','royal',false,'slug','lium','x',3,'y',6,'hp',80))),
    'host', jsonb_build_object('slug','mako'), 'ability', 0, 7, '@0,7'),
  'mako: a bomb tile between the king and an incoming lium scores higher than a stray corner tile');

-- ---------------------------------------------------------------------------
-- Lumea: while her tornado is still unused, she should favor the same
-- choke-point blocking as Mako; once it is spent, she should favor pressing
-- toward the nearest enemy instead.
-- ---------------------------------------------------------------------------
select t_ok(
  public.cn_bot_strategy_bonus(
    jsonb_build_object('units', jsonb_build_array(
      jsonb_build_object('id','k1','owner','host','royal',true,'slug','dereo','x',3,'y',0,'hp',110),
      jsonb_build_object('id','e1','owner','guest','royal',false,'slug','lium','x',3,'y',6,'hp',80))),
    'host', jsonb_build_object('slug','lumea','abilityUses',0), 'ability', 3, 3, '@3,3') > 0,
  'lumea with her tornado unused: blocking the choke point in front of the king scores positive');

select t_ok(
  public.cn_bot_strategy_bonus(
    jsonb_build_object('units', jsonb_build_array(
      jsonb_build_object('id','e1','owner','guest','royal',false,'slug','lium','x',5,'y',5,'hp',80))),
    'host', jsonb_build_object('slug','lumea','abilityUses',1), 'move', 4, 4, null)
  >
  public.cn_bot_strategy_bonus(
    jsonb_build_object('units', jsonb_build_array(
      jsonb_build_object('id','e1','owner','guest','royal',false,'slug','lium','x',5,'y',5,'hp',80))),
    'host', jsonb_build_object('slug','lumea','abilityUses',1), 'move', 0, 0, null),
  'lumea with her tornado already spent: pressing toward the enemy scores higher than retreating from it');

-- ---------------------------------------------------------------------------
-- Dione & Grifo: always operate solo -- pushing deep into enemy territory,
-- and using its ability at all, both score positive regardless of the rest
-- of the board.
-- ---------------------------------------------------------------------------
select t_ok(
  public.cn_bot_strategy_bonus('{"units":[],"board":{"h":8}}'::jsonb, 'host',
    jsonb_build_object('slug','dione-grifo'), 'move', 3, 6, null)
  >
  public.cn_bot_strategy_bonus('{"units":[],"board":{"h":8}}'::jsonb, 'host',
    jsonb_build_object('slug','dione-grifo'), 'move', 3, 1, null),
  'dione & grifo: infiltrating deep into enemy territory scores higher than staying home');

select t_ok(
  public.cn_bot_strategy_bonus('{"units":[],"board":{"h":8}}'::jsonb, 'host',
    jsonb_build_object('slug','dione-grifo'), 'ability', 3, 6, 'e1') > 0,
  'dione & grifo: using its ability at all is scored positive, regardless of dying early');

-- ---------------------------------------------------------------------------
-- Dorme: with more than one other ally standing, hold back toward the king
-- (attack/ability penalized, move-to-king rewarded); with at most one other
-- ally left, the doctrine flips to engage (attack/ability rewarded).
-- ---------------------------------------------------------------------------
select t_ok(
  public.cn_bot_strategy_bonus(
    jsonb_build_object('units', jsonb_build_array(
      jsonb_build_object('id','k1','owner','host','royal',true,'slug','dereo','x',0,'y',0,'hp',110),
      jsonb_build_object('id','a1','owner','host','royal',false,'slug','eva','x',1,'y',1,'hp',80),
      jsonb_build_object('id','a2','owner','host','royal',false,'slug','umiro','x',1,'y',2,'hp',75))),
    'host', jsonb_build_object('slug','dorme','id','d1'), 'attack', 4, 4, 'x') = -150,
  'dorme with 2 other allies up: attacking is penalized -150 (holding back)');

select t_ok(
  public.cn_bot_strategy_bonus(
    jsonb_build_object('units', jsonb_build_array(
      jsonb_build_object('id','k1','owner','host','royal',true,'slug','dereo','x',0,'y',0,'hp',110),
      jsonb_build_object('id','a1','owner','host','royal',false,'slug','eva','x',1,'y',1,'hp',80),
      jsonb_build_object('id','a2','owner','host','royal',false,'slug','umiro','x',1,'y',2,'hp',75))),
    'host', jsonb_build_object('slug','dorme','id','d1'), 'move', 1, 0, null) > 0,
  'dorme with 2 other allies up: moving toward the king scores positive');

select t_ok(
  public.cn_bot_strategy_bonus(
    jsonb_build_object('units', jsonb_build_array(
      jsonb_build_object('id','k1','owner','host','royal',true,'slug','dereo','x',0,'y',0,'hp',110),
      jsonb_build_object('id','a1','owner','host','royal',false,'slug','eva','x',1,'y',1,'hp',80))),
    'host', jsonb_build_object('slug','dorme','id','d1'), 'attack', 4, 4, 'x') = 80,
  'dorme down to its last stand (1 other ally): attacking is now rewarded +80');

-- ---------------------------------------------------------------------------
-- Himanta: a basic attack that lands stun on a target closer to its own
-- king scores higher than one on a target far from the king -- stunning
-- king-rushers is worth more than stunning a unit that was never a threat
-- to the king in the first place.
-- ---------------------------------------------------------------------------
select t_ok(
  public.cn_bot_strategy_bonus(
    jsonb_build_object('units', jsonb_build_array(
      jsonb_build_object('id','k1','owner','host','royal',true,'slug','dereo','x',0,'y',0,'hp',110),
      jsonb_build_object('id','t1','owner','guest','royal',false,'slug','lium','x',1,'y',0,'hp',80))),
    'host', jsonb_build_object('slug','himanta'), 'attack', 1, 0, 't1')
  >
  public.cn_bot_strategy_bonus(
    jsonb_build_object('units', jsonb_build_array(
      jsonb_build_object('id','k1','owner','host','royal',true,'slug','dereo','x',0,'y',0,'hp',110),
      jsonb_build_object('id','t1','owner','guest','royal',false,'slug','lium','x',5,'y',7,'hp',80))),
    'host', jsonb_build_object('slug','himanta'), 'attack', 5, 7, 't1'),
  'himanta: stunning an attacker near its own king scores higher than stunning one far away');

\echo '--- bot expert strategies (cn_bot_strategy_bonus, direct): all assertions passed ---'

-- ---------------------------------------------------------------------------
-- Integration smoke test: a full bot-vs-bot game, level 3 both sides, all
-- eight named cards on the board (wuzu/mako/dione-grifo/himanta for host,
-- eva/umiro/lumea/dorme for guest, one royal each). Nothing may hang and
-- nobody may cheat -- the same bar 06_bot_ranked.sql already holds the
-- plain bot to. This is what actually proves the 0150 wiring runs cleanly
-- through a real game rather than just compiling.
-- ---------------------------------------------------------------------------
delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('ee000000-0000-0000-0000-000000000003','e3@x.com','{"username":"ethree"}'),
  ('ee000000-0000-0000-0000-000000000004','e4@x.com','{"username":"efour"}');

select set_config('app.uid','ee000000-0000-0000-0000-000000000003',false);
select public.set_deck(array['dereo','wuzu','mako','dione-grifo','himanta']);
select set_config('app.uid','ee000000-0000-0000-0000-000000000004',false);
select public.set_deck(array['stelaris','eva','umiro','lumea','dorme']);
select t_match('ee000000-0000-0000-0000-000000000003',
               'ee000000-0000-0000-0000-000000000004') as m2 \gset

select set_config('app.uid','ee000000-0000-0000-0000-000000000003',false);
select t_trees(:'m2','[]'::jsonb);
update public.matches set bot = 3, host_bot = 3, status = 'active' where id = :'m2';

do $$
declare i int := 0; mid uuid := :'m2'::uuid; st text; v_turn text;
begin
  loop
    select status into st from public.matches where id = mid;
    exit when st <> 'active' or i > 500;
    select state->>'turn' into v_turn from public.matches where id = mid;
    perform public.bot_step(mid, v_turn);
    i := i + 1;
  end loop;
  if i > 500 then raise exception 'FAIL  a level-3 bot-vs-bot game with all 8 special-cased cards never finished'; end if;
  raise notice 'PASS  a full level-3 bot-vs-bot game runs to completion (% steps, %)', i, st;
end $$;

select t_ok((select status from public.matches where id=:'m2') = 'finished',
            'the game reached a real finish, not a stuck loop');

\echo '--- bot expert strategies (full game): all assertions passed ---'
