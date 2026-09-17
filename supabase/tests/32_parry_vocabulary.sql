-- 0058: the parry vocabulary -- IS_PARRIED/ON_COUNTER actually dispatched
-- from cn_attack, TRIGGER_PARRY/COUNTER_ATTACK_PCT accepted as documented
-- no-op actions (same bucket as REVIVE/REFLECT_DAMAGE_PCT/etc).

\set ON_ERROR_STOP on
\pset pager off

-- ---- schema ---------------------------------------------------------------
do $$
declare v_card uuid; v_struct uuid;
begin
  select id into v_card from public.cards where slug = 'himanta';
  perform t_ok(v_card is not null, 'himanta exists to test against');

  insert into public.card_effects (card_id, sort, trigger, target_selector, action, value, status)
  values (v_card, 900, 'IS_PARRIED', 'SELF', 'HEAL', 3, null);
  perform t_ok(true, 'IS_PARRIED is accepted as a trigger');

  insert into public.card_effects (card_id, sort, trigger, target_selector, action, value, status)
  values (v_card, 901, 'ON_COUNTER', 'SELF', 'HEAL', 3, null);
  perform t_ok(true, 'ON_COUNTER (already in the enum since 0049) still saves fine');

  insert into public.card_effects (card_id, sort, trigger, target_selector, action)
  values (v_card, 902, 'ON_PARRY', 'THE_ATTACKER', 'TRIGGER_PARRY');
  perform t_ok(true, 'TRIGGER_PARRY is accepted as an action');

  insert into public.card_effects (card_id, sort, trigger, target_selector, action, value)
  values (v_card, 903, 'ON_ATTACK', 'THE_TARGET', 'COUNTER_ATTACK_PCT', 50);
  perform t_ok(true, 'COUNTER_ATTACK_PCT with a value in 1-100 saves fine');

  perform t_raises(
    format('insert into public.card_effects (card_id, sort, trigger, target_selector, action)
              values (%L, 904, ''ON_ATTACK'', ''THE_TARGET'', ''COUNTER_ATTACK_PCT'')', v_card),
    'counter_attack_pct',
    'COUNTER_ATTACK_PCT with no value at all is refused');
  perform t_raises(
    format('insert into public.card_effects (card_id, sort, trigger, target_selector, action, value)
              values (%L, 904, ''ON_ATTACK'', ''THE_TARGET'', ''COUNTER_ATTACK_PCT'', 150)', v_card),
    'counter_attack_pct',
    'COUNTER_ATTACK_PCT over 100 is refused');
  perform t_raises(
    format('insert into public.card_effects (card_id, sort, trigger, target_selector, action, value)
              values (%L, 904, ''ON_ATTACK'', ''THE_TARGET'', ''COUNTER_ATTACK_PCT'', 0)', v_card),
    'counter_attack_pct',
    'and COUNTER_ATTACK_PCT of 0 is refused too -- it is a percentage, not an optional value');

  delete from public.card_effects where card_id = v_card and sort >= 900;

  insert into public.structures (slug, name, hp, blocks_movement)
  values ('test-parry-vocab', 'Test Parry Vocab', 10, false)
  returning id into v_struct;

  insert into public.structure_effects (structure_id, sort, trigger, target_selector, action, value)
  values (v_struct, 0, 'ON_DESTROYED', 'INVOKER', 'COUNTER_ATTACK_PCT', 20);
  perform t_ok(true, 'a structure can counter-attack whoever destroys it (COUNTER_ATTACK_PCT accepted)');

  perform t_raises(
    format('insert into public.structure_effects (structure_id, sort, trigger, target_selector, action)
              values (%L, 1, ''ON_DESTROYED'', ''INVOKER'', ''TRIGGER_PARRY'')', v_struct),
    'structure_effects_action_check',
    'TRIGGER_PARRY is refused for a structure -- it never stands in a swing to parry with');

  delete from public.structure_effects where structure_id = v_struct;
  delete from public.structures where id = v_struct;
end $$;

-- ---- runtime: ON_COUNTER actually fires from an ordinary answered blow ----
-- t_sw/t_shape are 11_swings.sql's own local helpers, not shared in
-- _helpers.sql -- copied here rather than made global, the same call that
-- file's own header makes about not sharing t_duel2 with 09_combat.sql.
create or replace function t_sw(p_m uuid) returns jsonb language sql stable as $$
  select coalesce(state->'fx'->'swings', '[]'::jsonb) from public.matches where id = p_m;
$$;
create or replace function t_shape(p_m uuid) returns text language sql stable as $$
  select coalesce(string_agg((s->>'k') || ':' || (s->>'by'), ',' order by i), '')
    from jsonb_array_elements(t_sw(p_m)) with ordinality t(s, i);
$$;

set cn.force_parry = 'never'; set cn.force_crit = 'never';
set cn.force_twice = 'never'; set cn.force_mist = 'never';

delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('ff000000-0000-0000-0000-0000000000c1','c1@x.com','{"username":"cone"}'),
  ('ff000000-0000-0000-0000-0000000000c2','c2@x.com','{"username":"ctwo"}');

-- A throwaway ON_COUNTER row on Dereo (h1/g1 in this deck order) -- when it
-- lands the ordinary "in range, not parried" counter every unit already
-- throws, it also heals itself for 7. Nothing about Dereo's real card is
-- touched or restored -- card_effects rows are the only thing this test
-- writes, and they are deleted at the end, same as every other test file's
-- own throwaway sentences. Also deleted defensively BEFORE inserting: a
-- prior run that died mid-file (ON_ERROR_STOP aborting before it ever
-- reached that end-of-file cleanup) leaves a stale row behind, and a
-- second stale row silently doubles the heal this test asserts on --
-- exactly what happened once while this file was being written: two
-- leftover copies made g1 heal 14 instead of 7 and the hp assertion below
-- failed until this line was added.
-- All three throwaway rows (this one plus the ON_PARRY/IS_PARRIED pair used
-- by the second exchange below) are inserted here, BEFORE the single
-- t_match() call for this file -- cn_army snapshots each unit's
-- abilityScript from card_effects at match-creation time, once, so a row
-- inserted after t_match() would simply never be on the unit and its
-- exchange would silently do nothing rather than fail loudly. (Exactly
-- what happened once while this file was being written: the ON_PARRY/
-- IS_PARRIED inserts were originally down by their own exchange, after
-- t_match() had already run, and h2/g2/g3 played the whole thing out with
-- no ability script at all.)
delete from public.card_effects where card_id = (select id from public.cards where slug = 'dereo') and sort = 900;
select gen_random_uuid() as g1 \gset
insert into public.card_effects (card_id, sort, group_id, trigger, target_selector, action, value)
select id, 900, :'g1'::uuid, 'ON_COUNTER', 'SELF', 'HEAL', 7
  from public.cards where slug = 'dereo';

delete from public.card_effects where card_id = (select id from public.cards where slug = 'dione-grifo') and sort = 900;
delete from public.card_effects where card_id = (select id from public.cards where slug = 'eva') and sort = 900;
select gen_random_uuid() as g2 \gset
insert into public.card_effects (card_id, sort, group_id, trigger, target_selector, action, value)
select id, 900, :'g2'::uuid, 'ON_PARRY', 'SELF', 'HEAL', 3
  from public.cards where slug = 'dione-grifo';
select gen_random_uuid() as g3 \gset
insert into public.card_effects (card_id, sort, group_id, trigger, target_selector, action, value)
select id, 900, :'g3'::uuid, 'IS_PARRIED', 'SELF', 'HEAL', 4
  from public.cards where slug = 'eva';

select set_config('app.uid','ff000000-0000-0000-0000-0000000000c1',false);
select public.set_deck(array['dereo','dione-grifo','sinie','himanta','fey']);
select set_config('app.uid','ff000000-0000-0000-0000-0000000000c2',false);
select public.set_deck(array['dereo','eva','mako','wuzu','lumea']);
select t_match('ff000000-0000-0000-0000-0000000000c1',
               'ff000000-0000-0000-0000-0000000000c2') as m \gset
select set_config('app.uid','ff000000-0000-0000-0000-0000000000c1',false);
select t_trees(:'m','[]'::jsonb);
select t_park(:'m', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);
select t_ok(t_get(:'m','h1','name') = 'King Dereo' and t_get(:'m','g1','name') = 'King Dereo',
            'dereo is h1 and g1 in this deck order -- both carry the throwaway row');

-- g1 (guest Dereo) defends: adjacent to h1, in its own counter range, no
-- parry (globally forced off), fixed damage so the exchange is arithmetic
-- rather than a dice roll.
select t_place(:'m','h1',2,2); select t_place(:'m','g1',2,3);
select t_dmg(:'m','h1',10);
select t_set(:'m','g1','crmin','1'::jsonb); select t_set(:'m','g1','crmax','1'::jsonb);
select t_set(:'m','g1','parryPct','0'::jsonb); select t_set(:'m','h1','parryPct','0'::jsonb);
select t_hp(:'m','g1',60); select t_set(:'m','g1','maxHp','100'::jsonb);
select t_hp(:'m','h1',100); select t_set(:'m','h1','maxHp','100'::jsonb);
select public.submit_attack(:'m','h1','g1');
select t_ok(t_shape(:'m') = 'hit:h1,hit:g1',
            'h1''s blow, then g1''s ordinary counter -- no parry, one swing each');
select t_ok(t_get(:'m','g1','hp')::int = 60 - 10 + 7,
            'ON_COUNTER fired on g1 (the countering unit): 60 - 10 taken + 7 healed = 57');

-- ---- runtime: ON_PARRY ("parries") and IS_PARRIED ("is parried") ---------
-- Two different units, two different perspectives on the SAME swing.
-- h2 (Dione & Grifo) parries with a guaranteed roll (parryPct=100 bypasses
-- cn.force_parry entirely -- see cn_chance's own >=100 short-circuit) and
-- heals itself for the parry; g2 (Eva), whose blow it caught, heals for
-- landing on IS_PARRIED instead. h2's own counter-range is set OUT of
-- reach on purpose so the parry does not answer back into a second swing
-- (cn_attack's own v_tgt_reaches gate) -- this exchange is exactly one
-- swing, so neither heal is disturbed by anything after it. (g2's and g3's
-- card_effects rows were already inserted above, before t_match() -- see
-- that comment for why.)

select t_reset(:'m');
-- t_reset clears the per-unit move/attack flags and the turn's activation
-- budget, but not whose turn it is -- the first exchange above left that
-- 'host' (h1 acted, turn had not passed), and submit_attack checks it, so
-- this second exchange (g2, the guest's unit, attacking) has to flip it by
-- hand.
update public.matches set state = jsonb_set(state, '{turn}', '"guest"') where id = :'m';
select t_place(:'m','g2',2,2); select t_place(:'m','h2',2,3);
select t_dmg(:'m','g2',10);
select t_set(:'m','h2','parryPct','100'::jsonb);
select t_set(:'m','h2','crmin','5'::jsonb); select t_set(:'m','h2','crmax','5'::jsonb);
select t_hp(:'m','h2',50); select t_set(:'m','h2','maxHp','100'::jsonb);
select t_hp(:'m','g2',50); select t_set(:'m','g2','maxHp','100'::jsonb);
-- g2 is the guest's unit (attacker this time) -- app.uid is still c1 from
-- the h1-attacks-g1 exchange above, and submit_attack checks the caller
-- owns the attacking unit, so it must switch back to c2 first.
select set_config('app.uid','ff000000-0000-0000-0000-0000000000c2',false);
select public.submit_attack(:'m','g2','h2');
select t_ok(t_shape(:'m') = 'parry:h2',
            'the whole exchange is one swing: h2 parries g2''s blow and nothing answers back');
select t_ok(t_get(:'m','h2','hp')::int = 53,
            '"parries" (ON_PARRY, already real since 0049): h2 caught it and healed 3, untouched otherwise');
select t_ok(t_get(:'m','g2','hp')::int = 54,
            '"is parried" (IS_PARRIED, new in 0058): g2''s OWN blow got caught, and g2 healed 4 for it -- '
            'g2 took no damage at all, since the swing never got past the parry');

-- cleanup
delete from public.card_effects where card_id = (select id from public.cards where slug = 'dereo') and sort = 900;
delete from public.card_effects where card_id = (select id from public.cards where slug = 'dione-grifo') and sort = 900;
delete from public.card_effects where card_id = (select id from public.cards where slug = 'eva') and sort = 900;
