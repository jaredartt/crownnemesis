-- 0057: structures -- catalog, sentence builder, and real board presence
-- (create, step on, destroy).

\set ON_ERROR_STOP on
\pset pager off
set cn.force_parry = 'never'; set cn.force_crit = 'never';
set cn.force_twice = 'never'; set cn.force_mist = 'never';

-- ---- schema + legacy compatibility --------------------------------------
do $$
declare v_s uuid;
begin
  insert into public.structures (slug, name, hp, blocks_movement)
  values ('test-spikes', 'Test Spikes', 12, false)
  returning id into v_s;
  perform t_ok(v_s is not null, 'a structure saves to the catalog');

  insert into public.structure_effects (structure_id, sort, trigger, target_selector, action, value, status)
  values (v_s, 0, 'ON_STEPPED_ON', 'WHOEVER_STEPPED', 'APPLY_STATUS', 1, 'POISON');
  perform t_ok(true, 'a structure_effects row saves');

  perform t_raises(
    'insert into public.structure_effects (structure_id, sort, trigger, target_selector, action)
       values (''00000000-0000-0000-0000-000000000000'', 0, ''ON_STEPPED_ON'', ''WHOEVER_STEPPED'', ''APPLY_STATUS'')',
    'needs_status', 'APPLY_STATUS with no status is refused, mirroring card_effects');

  -- cn_obj_* fall back to the catalog for an unknown kind, and are
  -- completely unchanged for the four legacy kinds (also checked by this
  -- migration''s own verification block, re-checked here so a future edit
  -- to either file catches a regression from either side).
  perform t_ok(cn_obj_hp('test-spikes') = 12, 'cn_obj_hp falls back to the structures catalog');
  perform t_ok(cn_obj_name('test-spikes') = 'Test Spikes', 'cn_obj_name too');
  perform t_ok(not cn_obj_solid('test-spikes'), 'blocks_movement=false reads through cn_obj_solid');
  perform t_ok(cn_obj_hp('tree') = 30 and cn_obj_name('bomb') = 'a trap',
              'and every legacy kind is still exactly what it always was');

  delete from public.structure_effects where structure_id = v_s;
  delete from public.structures where id = v_s;
end $$;

-- ---- runtime: create, step on, destroy ----------------------------------
delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('ff000000-0000-0000-0000-0000000000b1','b1@x.com','{"username":"bone"}'),
  ('ff000000-0000-0000-0000-0000000000b2','b2@x.com','{"username":"btwo"}');

-- A spike trap: 10 hp, poisons anyone who steps on it, logs a note when
-- destroyed. Placed by a scripted ON_ABILITY CREATE_STRUCTURE row on Fey
-- (chosen only because she is a Mage with real range -- her existing
-- 'summon' abilityKind is overridden for this test and restored after).
insert into public.structures (slug, name, hp, blocks_movement)
values ('spike-trap', 'Spike Trap', 10, false);
insert into public.structure_effects (structure_id, sort, trigger, target_selector, action, value, status)
select id, 0, 'ON_STEPPED_ON', 'WHOEVER_STEPPED', 'APPLY_STATUS', null, 'POISON'
  from public.structures where slug = 'spike-trap';
insert into public.structure_effects (structure_id, sort, trigger, target_selector, action, value)
select id, 1, 'ON_DESTROYED', 'INVOKER', 'HEAL', 5
  from public.structures where slug = 'spike-trap';

-- cards_summon_needs_kind requires ability_kind='summon' iff summon_kind is
-- set, so summon_kind has to come off too while this test borrows the slot
-- -- restored alongside ability_kind at cleanup.
update public.cards set ability_kind = 'scripted', summon_kind = null where slug = 'fey';
select gen_random_uuid() as g1 \gset
insert into public.card_effects (card_id, sort, group_id, trigger, target_selector, action, structure_slug)
select id, 900, :'g1'::uuid, 'ON_ABILITY', 'BOARD_CELL', 'CREATE_STRUCTURE', 'spike-trap'
  from public.cards where slug = 'fey';

select set_config('app.uid','ff000000-0000-0000-0000-0000000000b1',false);
select public.set_deck(array['dereo','dione-grifo','sinie','himanta','fey']);
select set_config('app.uid','ff000000-0000-0000-0000-0000000000b2',false);
select public.set_deck(array['dereo','eva','mako','wuzu','lumea']);
select t_match('ff000000-0000-0000-0000-0000000000b1',
               'ff000000-0000-0000-0000-0000000000b2') as m \gset
select set_config('app.uid','ff000000-0000-0000-0000-0000000000b1',false);
select t_trees(:'m','[]'::jsonb);
select t_park(:'m', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);
select t_ok(t_get(:'m','h5','name') = 'Fey', 'fey is h5 in this deck order');

-- Fey at (2,2), place the trap two tiles away at (2,4) -- within her
-- range-3 reach and clear line of sight (t_trees cleared the board).
select t_place(:'m','h5',2,2);
select public.cn_ability(:'m', 'host', 'h5', '@2,4');
select t_ok(t_nobj(:'m','spike-trap') = 1,
            'cn_ability with CREATE_STRUCTURE actually placed exactly one spike-trap obstacle');
select t_ok(t_obj_at(:'m',2,4,'hp')::int = 10, 'it carries the catalog''s hp');
select t_ok(t_obj_at(:'m',2,4,'owner') = 'host', 'and the placing side as its owner');

-- Walk an enemy unit onto it. g1 (Dereo, guest) starts on the guest home
-- row; move it step by step is unnecessary for this test -- t_place drops
-- it directly onto the trap's tile and cn_move's own cn_spring call (via a
-- real move) is what actually fires ON_STEPPED_ON, so a real move is used
-- rather than t_place, which bypasses cn_move entirely.
select set_config('app.uid','ff000000-0000-0000-0000-0000000000b2',false);
select t_place(:'m','g1',2,5);
select t_reset(:'m');
select public.cn_move(:'m', 'guest', 'g1', 2, 4);
select t_ok(t_get(:'m','g1','effects')::jsonb->>'poison' = 'true',
            'stepping on the trap poisoned the unit that stepped on it (WHOEVER_STEPPED)');
select t_ok(t_get(:'m','h1','effects') is null or (t_get(:'m','h1','effects')::jsonb->>'poison') is distinct from 'true',
            'and did NOT poison anyone else on the board');

-- Destroy it: an ordinary attack, through the ordinary v_tree branch --
-- structures need no combat-math changes at all.
select set_config('app.uid','ff000000-0000-0000-0000-0000000000b1',false);
select t_reset(:'m');
select t_hp(:'m','h5',40);
select t_place(:'m','h5',2,3);
select t_set(:'m','h5','rmin','1'::jsonb); select t_set(:'m','h5','rmax','1'::jsonb);
select public.submit_attack(:'m','h5', (select o->>'id' from jsonb_array_elements(t_objs(:'m')) o where o->>'kind' = 'spike-trap'));
select t_ok(t_nobj(:'m','spike-trap') = 0, 'the spike trap is gone once its hp reaches zero');
select t_ok(t_get(:'m','h5','hp')::int = 45,
            'ON_DESTROYED fired -- INVOKER (h5, who placed it) was healed for 5');

-- cleanup: restore fey exactly as the roster ships her, and drop the
-- throwaway catalog row.
delete from public.card_effects where card_id = (select id from public.cards where slug = 'fey') and sort = 900;
update public.cards set ability_kind = 'summon', summon_kind = 'wall' where slug = 'fey';
delete from public.structure_effects where structure_id = (select id from public.structures where slug = 'spike-trap');
delete from public.structures where slug = 'spike-trap';
