-- 0056: sentence grouping, card_ability_meta, and cooldown/max-uses
-- enforcement in cn_ability.

-- ---- schema: group_id defaults, duration/range columns, one-Active rule --
do $$
declare
  v_card uuid; v_g1 uuid := gen_random_uuid(); v_g2 uuid := gen_random_uuid();
begin
  select id into v_card from public.cards where slug = 'himanta';
  perform t_ok(v_card is not null, 'himanta exists to test against');

  insert into public.card_effects (card_id, sort, group_id, trigger, target_selector, action, value, stat_name)
  values (v_card, 900, v_g1, 'ON_ABILITY', 'ENEMY_IN_RANGE', 'DEAL_DAMAGE', 5, null);
  perform t_ok(exists (
    select 1 from public.card_effects where card_id = v_card and group_id = v_g1
  ), 'a row can be saved with an explicit group_id');

  insert into public.card_effects (card_id, sort, trigger, target_selector, action, value, stat_name)
  values (v_card, 901, 'PASSIVE', 'SELF', 'MODIFY_STAT', 1, 'SLIPPERY');
  perform t_ok((
    select count(distinct group_id) from public.card_effects where card_id = v_card and sort in (900, 901)
  ) = 2, 'a row with no group_id given gets its own, distinct from a neighbour''s');

  insert into public.card_ability_meta (card_id, group_id, ability_type, max_uses, cooldown_turns)
  values (v_card, v_g1, 'active', 2, 1);
  perform t_ok(true, 'one active sentence saves fine');
  perform t_raises(
    format('insert into public.card_ability_meta (card_id, group_id, ability_type) values (%L, %L, %L)',
           v_card, v_g2, 'active'),
    'duplicate key',
    'a second Active sentence on the same card is refused');
  insert into public.card_ability_meta (card_id, group_id, ability_type)
  values (v_card, v_g2, 'passive');
  perform t_ok(true, 'a second PASSIVE sentence on the same card is fine -- only Active is singular');

  perform t_raises(
    format('insert into public.card_effects (card_id, sort, trigger, target_selector, action, value, status,
              duration_kind, duration_turns) values (%L, 902, ''ON_ABILITY'', ''SELF'', ''APPLY_STATUS'', 1, ''STUN'', %L, 3)',
           v_card, 'THIS_TURN'),
    'card_effects_duration_turns_needs_kind',
    'duration_turns without duration_kind = FOR_TURNS is refused');
  insert into public.card_effects (card_id, sort, trigger, target_selector, action, value, status,
                                    duration_kind, duration_turns)
  values (v_card, 902, 'ON_ABILITY', 'SELF', 'APPLY_STATUS', 1, 'STUN', 'FOR_TURNS', 3);
  perform t_ok(true, 'duration_turns with duration_kind = FOR_TURNS saves fine');

  perform t_raises(
    format('insert into public.card_effects (card_id, sort, trigger, target_selector, action, value, status,
              range_kind, range_min, range_max) values (%L, 903, ''ON_ABILITY'', ''ENEMY_IN_RANGE'', ''DEAL_DAMAGE'', 5, null, %L, 1, 4)',
           v_card, 'CARD_RANGE'),
    'card_effects_range_needs_fixed',
    'range_min/range_max set without range_kind = FIXED_RANGE is refused');
  insert into public.card_effects (card_id, sort, trigger, target_selector, action, value,
                                    range_kind, range_min, range_max)
  values (v_card, 903, 'ON_ABILITY', 'ENEMY_IN_RANGE', 'DEAL_DAMAGE', 5, 'FIXED_RANGE', 1, 4);
  perform t_ok(true, 'range_min/range_max with range_kind = FIXED_RANGE saves fine');

  delete from public.card_effects where card_id = v_card and sort >= 900;
  delete from public.card_ability_meta where card_id = v_card;
end $$;

-- ---- runtime: max uses and cooldown actually gate cn_ability -----------
\set ON_ERROR_STOP on
\pset pager off
set cn.force_parry = 'never'; set cn.force_crit = 'never';
set cn.force_twice = 'never'; set cn.force_mist = 'never';

delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('ff000000-0000-0000-0000-0000000000a1','a1@x.com','{"username":"aone"}'),
  ('ff000000-0000-0000-0000-0000000000a2','a2@x.com','{"username":"atwo"}');

-- Wuzu is passive-only in the shipped roster (Regenerative Body, no
-- abilityKind) -- give it a throwaway scripted self-heal with a tight
-- budget so this test does not depend on any one card's live tuning, and
-- clean it back up at the end.
update public.cards set ability_kind = 'scripted' where slug = 'wuzu';
select gen_random_uuid() as g1 \gset
insert into public.card_effects (card_id, sort, group_id, trigger, target_selector, action, value, stat_name)
select id, 900, :'g1'::uuid, 'ON_ABILITY', 'SELF', 'HEAL', 1, null from public.cards where slug = 'wuzu';
insert into public.card_ability_meta (card_id, group_id, ability_type, max_uses, cooldown_turns)
select id, :'g1'::uuid, 'active', 1, 2 from public.cards where slug = 'wuzu';

select set_config('app.uid','ff000000-0000-0000-0000-0000000000a1',false);
select public.set_deck(array['dereo','dione-grifo','sinie','himanta','wuzu']);
select set_config('app.uid','ff000000-0000-0000-0000-0000000000a2',false);
select public.set_deck(array['dereo','eva','mako','fey','lumea']);
select t_match('ff000000-0000-0000-0000-0000000000a1',
               'ff000000-0000-0000-0000-0000000000a2') as m \gset
select set_config('app.uid','ff000000-0000-0000-0000-0000000000a1',false);
select t_trees(:'m','[]'::jsonb);
select t_park(:'m', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);

select t_ok(t_get(:'m','h5','name') = 'Wuzu', 'wuzu is h5 in this deck order');
select t_ok((t_get(:'m','h5','abilityMaxUses'))::int = 1, 'abilityMaxUses snapshotted onto the unit at deploy');
select t_ok((t_get(:'m','h5','abilityCooldownTurns'))::int = 2, 'abilityCooldownTurns snapshotted too');

select t_hp(:'m', 'h5', 50);
select public.cn_ability(:'m', 'host', 'h5', null);
select t_ok((t_get(:'m','h5','abilityUses'))::int = 1, 'abilityUses is 1 after the first activation');
select t_ok(t_get(:'m','h5','hp')::int = 51, 'and the heal itself actually landed');

-- One full round (host's go, then guest's) so h5 may act again this turn --
-- max_uses = 1 should refuse the second activation outright.
select public.advance_turn(:'m', 'end', false);
select set_config('app.uid','ff000000-0000-0000-0000-0000000000a2',false);
select public.advance_turn(:'m', 'end', false);
select set_config('app.uid','ff000000-0000-0000-0000-0000000000a1',false);
select t_reset(:'m');
select t_raises(format('select public.cn_ability(%L,''host'',''h5'',null)', :'m'),
                'no uses left', 'a second activation is refused once max_uses is spent');

-- A fresh match for the cooldown half, so the max_uses refusal above cannot
-- be mistaken for the cooldown refusal below.
update public.card_ability_meta set max_uses = null
 where card_id = (select id from public.cards where slug = 'wuzu');
select t_match('ff000000-0000-0000-0000-0000000000a1',
               'ff000000-0000-0000-0000-0000000000a2') as m2 \gset
select set_config('app.uid','ff000000-0000-0000-0000-0000000000a1',false);
select t_trees(:'m2','[]'::jsonb);
select t_park(:'m2', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);
select t_hp(:'m2', 'h5', 50);
select public.cn_ability(:'m2', 'host', 'h5', null);
select public.advance_turn(:'m2', 'end', false);
select set_config('app.uid','ff000000-0000-0000-0000-0000000000a2',false);
select public.advance_turn(:'m2', 'end', false);
select set_config('app.uid','ff000000-0000-0000-0000-0000000000a1',false);
select t_reset(:'m2');
select t_raises(format('select public.cn_ability(%L,''host'',''h5'',null)', :'m2'),
                'cooldown', 'a same-unit re-activation one turn later is refused -- cooldown is 2 turns');

-- A card with NO card_ability_meta row at all (every card that predates
-- 0056) must be completely unaffected -- unlimited uses, no cooldown.
select t_ok(t_get(:'m2','h4','abilityMaxUses') is null,
            'a card with no card_ability_meta row snapshots a null abilityMaxUses (himanta, h4)');

-- cleanup: put wuzu back exactly as the roster ships it.
delete from public.card_ability_meta where card_id = (select id from public.cards where slug = 'wuzu');
delete from public.card_effects where card_id = (select id from public.cards where slug = 'wuzu') and sort = 900;
update public.cards set ability_kind = null where slug = 'wuzu';
