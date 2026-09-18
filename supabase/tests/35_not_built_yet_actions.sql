-- 0074: everything the soft-code builder used to label "(not built yet)" --
-- TRIGGER_PARRY, REFLECT_DAMAGE_PCT, SUMMON_OBJECT (aliasing CREATE_STRUCTURE),
-- REVIVE (and its graveyard), structures' COUNTER_ATTACK_PCT -- plus the
-- "and not" negate flag on conditions.

\set ON_ERROR_STOP on
\pset pager off

-- ---------------------------------------------------------------------------
-- schema
-- ---------------------------------------------------------------------------
do $$
declare v_card uuid; v_struct uuid;
begin
  select id into v_card from public.cards where slug = 'himanta';
  perform t_ok(v_card is not null, 'himanta exists to test against');

  -- A throwaway catalog row of its own -- not 'spike-trap' (the runtime
  -- section below creates that one, and reusing it here would make this
  -- block's own success depend on run order/leftovers instead of standing
  -- on its own).
  insert into public.structures (slug, name, hp, blocks_movement)
  values ('test-summon-schema', 'Test Summon Schema', 5, false)
  on conflict (slug) do nothing;

  insert into public.card_effects (card_id, sort, trigger, target_selector, action, value)
  values (v_card, 900, 'ON_DEATH', 'LAST_DEAD_ALLY', 'REVIVE', 50);
  perform t_ok(true, 'LAST_DEAD_ALLY is accepted as a target_selector, REVIVE with value 50 saves fine');

  perform t_raises(
    format('insert into public.card_effects (card_id, sort, trigger, target_selector, action)
              values (%L, 901, ''ON_DEATH'', ''LAST_DEAD_ALLY'', ''REVIVE'')', v_card),
    'revive_value',
    'REVIVE with no value at all is refused');
  perform t_raises(
    format('insert into public.card_effects (card_id, sort, trigger, target_selector, action, value)
              values (%L, 901, ''ON_DEATH'', ''LAST_DEAD_ALLY'', ''REVIVE'', 0)', v_card),
    'revive_value',
    'REVIVE with value 0 is refused -- it is a percentage, not an optional flourish');
  perform t_raises(
    format('insert into public.card_effects (card_id, sort, trigger, target_selector, action, value)
              values (%L, 901, ''ON_DEATH'', ''LAST_DEAD_ALLY'', ''REVIVE'', 101)', v_card),
    'revive_value',
    'REVIVE over 100 is refused');

  delete from public.card_effects where card_id = v_card and sort >= 900;

  -- SUMMON_OBJECT is CREATE_STRUCTURE under a second name and needs the same
  -- structure_slug -- widened constraint, not a new one.
  insert into public.card_effects (card_id, sort, trigger, target_selector, action, structure_slug)
  values (v_card, 900, 'ON_ABILITY', 'BOARD_CELL', 'SUMMON_OBJECT', 'test-summon-schema');
  perform t_ok(true, 'SUMMON_OBJECT with a structure_slug saves fine');
  perform t_raises(
    format('insert into public.card_effects (card_id, sort, trigger, target_selector, action)
              values (%L, 901, ''ON_ABILITY'', ''BOARD_CELL'', ''SUMMON_OBJECT'')', v_card),
    'create_structure_needs_slug',
    'SUMMON_OBJECT with no structure_slug is refused -- it would silently place nothing');
  delete from public.card_effects where card_id = v_card and sort >= 900;

  -- TRIGGER_PARRY / REFLECT_DAMAGE_PCT were already accepted by the schema
  -- since 0058/0049 (documented no-ops) -- this migration only changes what
  -- they DO, not whether they save. Sanity check they still save.
  insert into public.card_effects (card_id, sort, trigger, target_selector, action)
  values (v_card, 900, 'ON_ABILITY', 'THE_TARGET', 'TRIGGER_PARRY');
  insert into public.card_effects (card_id, sort, trigger, target_selector, action, value)
  values (v_card, 901, 'ON_DAMAGED', 'THE_ATTACKER', 'REFLECT_DAMAGE_PCT', 50);
  perform t_ok(true, 'TRIGGER_PARRY and REFLECT_DAMAGE_PCT still save exactly as before');
  delete from public.card_effects where card_id = v_card and sort >= 900;

  -- Structures: THE_ATTACKER now a valid selector, COUNTER_ATTACK_PCT still
  -- needs its 1-100 value (unchanged check, still enforced).
  insert into public.structures (slug, name, hp, blocks_movement)
  values ('test-nbya-struct', 'Test NBYA Struct', 10, false)
  returning id into v_struct;
  insert into public.structure_effects (structure_id, sort, trigger, target_selector, action, value)
  values (v_struct, 0, 'ON_DESTROYED', 'THE_ATTACKER', 'COUNTER_ATTACK_PCT', 40);
  perform t_ok(true, 'a structure can target THE_ATTACKER with COUNTER_ATTACK_PCT');
  delete from public.structure_effects where structure_id = v_struct;
  delete from public.structures where id = v_struct;
  delete from public.structures where slug = 'test-summon-schema';
end $$;

-- ---------------------------------------------------------------------------
-- "and not" -- cn_effect_conditions_met's negate flag
-- ---------------------------------------------------------------------------
do $$
declare v_ctx jsonb;
begin
  v_ctx := jsonb_build_object('self', jsonb_build_object('hp', 20, 'maxHp', 100));

  perform t_ok(cn_effect_conditions_met(
      jsonb_build_array(jsonb_build_object('field','self.hp','op','<','value','25')), v_ctx),
    'ordinary (non-negated) condition: self.hp < 25 is true at hp=20');
  perform t_ok(not cn_effect_conditions_met(
      jsonb_build_array(jsonb_build_object('field','self.hp','op','<','value','25','negate',true)), v_ctx),
    '"and not" flips it: self.hp < 25 negated is false at hp=20');
  perform t_ok(cn_effect_conditions_met(
      jsonb_build_array(jsonb_build_object('field','self.hp','op','<','value','15','negate',true)), v_ctx),
    'and negating a condition that would be false makes it true (self.hp < 15 is false; negated is true)');

  -- Chain of two: one plain, one negated -- both must hold (AND), and only
  -- the negated one is flipped.
  perform t_ok(cn_effect_conditions_met(
      jsonb_build_array(
        jsonb_build_object('field','self.hp','op','<','value','25'),
        jsonb_build_object('field','self.hp','op','>','value','50','negate',true)), v_ctx),
    'chain: self.hp<25 (true) AND NOT self.hp>50 (false, so negated true) -- whole chain true');
  perform t_ok(not cn_effect_conditions_met(
      jsonb_build_array(
        jsonb_build_object('field','self.hp','op','<','value','25'),
        jsonb_build_object('field','self.hp','op','<','value','50','negate',true)), v_ctx),
    'chain: self.hp<25 (true) AND NOT self.hp<50 (true, so negated false) -- whole chain false');
end $$;

-- ---------------------------------------------------------------------------
-- runtime setup: one match, several scripted exchanges played out on it
-- ---------------------------------------------------------------------------
create or replace function t_sw(p_m uuid) returns jsonb language sql stable as $$
  select coalesce(state->'fx'->'swings', '[]'::jsonb) from public.matches where id = p_m;
$$;
create or replace function t_shape(p_m uuid) returns text language sql stable as $$
  select coalesce(string_agg((s->>'k') || ':' || (s->>'by'), ',' order by i), '')
    from jsonb_array_elements(t_sw(p_m)) with ordinality t(s, i);
$$;
create or replace function t_graveyard_count(p_m uuid, p_side text) returns int
language sql stable as $$
  select coalesce(jsonb_array_length(state->'graveyard'->p_side), 0) from public.matches where id = p_m;
$$;
create or replace function t_graveyard_last(p_m uuid, p_side text, p_key text) returns text
language sql stable as $$
  select (state->'graveyard'->p_side->(jsonb_array_length(state->'graveyard'->p_side) - 1))->>p_key
    from public.matches where id = p_m;
$$;

set cn.force_parry = 'never'; set cn.force_crit = 'never';
set cn.force_twice = 'never'; set cn.force_mist = 'never';

-- royale_players and royale_messages are the only two tables referencing
-- profiles(id) with no ON DELETE CASCADE, and this is the first file that
-- ever runs after 34_name_color.sql (which leaves rows behind referencing
-- its own throwaway user -- a pre-existing gap in that file's own cleanup,
-- not something this migration touches) -- so "delete from auth.users"
-- alone fails here with a foreign-key violation unless both are cleared
-- first too.
delete from public.royale_messages;
delete from public.royale_players;
delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('dd000000-0000-0000-0000-0000000000d1','d1@x.com','{"username":"done"}'),
  ('dd000000-0000-0000-0000-0000000000d2','d2@x.com','{"username":"dtwo"}');

-- Throwaway scripted rows, inserted BEFORE t_match() -- cn_army snapshots
-- each unit's abilityScript from card_effects once, at match-creation time
-- (the project's own documented gotcha, re-learned the hard way in
-- 32_parry_vocabulary.sql and respected here).
delete from public.card_effects where card_id = (select id from public.cards where slug = 'dione-grifo') and sort >= 900;
delete from public.card_effects where card_id = (select id from public.cards where slug = 'eva') and sort >= 900;
delete from public.card_effects where card_id = (select id from public.cards where slug = 'himanta') and sort >= 900;
delete from public.card_effects where card_id = (select id from public.cards where slug = 'dereo') and sort >= 900;

-- g1 (Dereo): ON_ABILITY/LAST_DEAD_ALLY/REVIVE 60 -- the "broader" case
-- Jared asked for: a DIFFERENT unit reviving a dead ally, not a unit
-- reviving itself. Every deck here carries Dereo (both h1 and g1), but only
-- g1's activation is exercised below. ability_kind swapped from null to
-- 'scripted' the same way Himanta's and Fey's are, restored at cleanup.
update public.cards set ability_kind = 'scripted' where slug = 'dereo';
select gen_random_uuid() as gr0 \gset
insert into public.card_effects (card_id, sort, group_id, trigger, target_selector, action, value)
select id, 900, :'gr0'::uuid, 'ON_ABILITY', 'LAST_DEAD_ALLY', 'REVIVE', 60
  from public.cards where slug = 'dereo';

-- h2 (Dione & Grifo): ON_DAMAGED/THE_ATTACKER/REFLECT_DAMAGE_PCT 50 --
-- reflects half the damage it just took right back at whoever dealt it.
select gen_random_uuid() as gr1 \gset
insert into public.card_effects (card_id, sort, group_id, trigger, target_selector, action, value)
select id, 900, :'gr1'::uuid, 'ON_DAMAGED', 'THE_ATTACKER', 'REFLECT_DAMAGE_PCT', 50
  from public.cards where slug = 'dione-grifo';

-- g2 (Eva): ON_DEATH/LAST_DEAD_ALLY/REVIVE 50 -- self-revive-on-death, comes
-- back at 50% of its own max hp on an empty adjacent tile.
select gen_random_uuid() as gr2 \gset
insert into public.card_effects (card_id, sort, group_id, trigger, target_selector, action, value)
select id, 900, :'gr2'::uuid, 'ON_DEATH', 'LAST_DEAD_ALLY', 'REVIVE', 50
  from public.cards where slug = 'eva';

-- h4 (Himanta): ON_ABILITY/BOARD_CELL/SUMMON_OBJECT 'spike-trap' -- the
-- alias, exercised through the same ability plumbing 31_structures.sql
-- already proved CREATE_STRUCTURE with. ability_kind/summon_kind swapped the
-- same way that file swaps Fey's, restored at cleanup. The catalog row has
-- to exist BEFORE the card_effects row below (card_effects.structure_slug
-- is a foreign key into structures.slug) -- this file's own cleanup drops
-- 'spike-trap' again at the end, so a second run needs it recreated first,
-- not assumed still there.
insert into public.structures (slug, name, hp, blocks_movement)
values ('spike-trap', 'Spike Trap', 10, false)
on conflict (slug) do nothing;

update public.cards set ability_kind = 'scripted', summon_kind = null where slug = 'himanta';
select gen_random_uuid() as gr3 \gset
insert into public.card_effects (card_id, sort, group_id, trigger, target_selector, action, structure_slug)
select id, 900, :'gr3'::uuid, 'ON_ABILITY', 'BOARD_CELL', 'SUMMON_OBJECT', 'spike-trap'
  from public.cards where slug = 'himanta';

-- A throwaway structure for the COUNTER_ATTACK_PCT test: ON_DESTROYED /
-- THE_ATTACKER / COUNTER_ATTACK_PCT 40.
insert into public.structures (slug, name, hp, blocks_movement)
values ('test-counter-struct', 'Test Counter Struct', 8, false);
insert into public.structure_effects (structure_id, sort, trigger, target_selector, action, value)
select id, 0, 'ON_DESTROYED', 'THE_ATTACKER', 'COUNTER_ATTACK_PCT', 40
  from public.structures where slug = 'test-counter-struct';

select set_config('app.uid','dd000000-0000-0000-0000-0000000000d1',false);
select public.set_deck(array['dereo','dione-grifo','sinie','himanta','fey']);
select set_config('app.uid','dd000000-0000-0000-0000-0000000000d2',false);
select public.set_deck(array['dereo','eva','mako','wuzu','lumea']);
select t_match('dd000000-0000-0000-0000-0000000000d1',
               'dd000000-0000-0000-0000-0000000000d2') as m \gset
select set_config('app.uid','dd000000-0000-0000-0000-0000000000d1',false);
select t_trees(:'m','[]'::jsonb);
select t_park(:'m', array['h1','h2','h3','h4','h5','g1','g2','g3','g4','g5']);
-- Every deck here carries a Royal (Dereo), whose aura reaches the whole
-- board -- stripped so every exact-number assertion below measures only
-- what it says it measures, per _helpers.sql's own t_noauras header.
select t_noauras(:'m');
select t_ok(t_get(:'m','h2','name') = 'Dione & Grifo', 'h2 carries the REFLECT_DAMAGE_PCT script');
select t_ok(t_get(:'m','g2','name') = 'Eva', 'g2 carries the REVIVE-on-death script');
select t_ok(t_get(:'m','h4','name') = 'Himanta', 'h4 carries the SUMMON_OBJECT script');

-- ---------------------------------------------------------------------------
-- TRIGGER_PARRY -- a forced parry via a direct flag, consumed on the swing
-- that catches it and not carried into a second one.
-- ---------------------------------------------------------------------------
select t_place(:'m','h1',2,2); select t_place(:'m','g1',2,3);
select t_dmg(:'m','h1',10);
select t_set(:'m','g1','parryPct','0'::jsonb); select t_set(:'m','h1','parryPct','0'::jsonb);
select t_set(:'m','g1','parryAll','false'::jsonb);
select t_set(:'m','g1','crmin','0'::jsonb); select t_set(:'m','g1','crmax','0'::jsonb);
select t_set(:'m','g1','forcedParry','true'::jsonb);
select t_hp(:'m','g1',60); select t_set(:'m','g1','maxHp','100'::jsonb);
select t_hp(:'m','h1',100); select t_set(:'m','h1','maxHp','100'::jsonb);
select public.submit_attack(:'m','h1','g1');
select t_ok(t_shape(:'m') = 'parry:g1',
            'a forced parry catches the blow for certain even with parryPct=0 and no roll');
select t_ok(t_get(:'m','g1','hp')::int = 60, 'g1 took no damage -- the forced parry caught it');
select t_ok(t_get(:'m','g1','forcedParry') = 'false',
            'forcedParry is consumed the instant it catches a blow');

-- Second exchange, flag not re-set: an ordinary hit lands now.
select t_reset(:'m');
select t_hp(:'m','g1',60);
select public.submit_attack(:'m','h1','g1');
select t_ok(t_get(:'m','g1','hp')::int = 50,
            'without the flag re-set, the very next blow is an ordinary hit -- not still forced');

-- ---------------------------------------------------------------------------
-- REFLECT_DAMAGE_PCT -- h2 gives back 50% of whatever it's struck for.
-- Counter range set out of reach so this is a clean single swing (no
-- counter, no riposte) and v_dmg is exactly the fixed blow dealt.
-- ---------------------------------------------------------------------------
select t_reset(:'m');
update public.matches set state = jsonb_set(state, '{turn}', '"host"') where id = :'m';
select t_place(:'m','h3',2,2); select t_place(:'m','h2',2,3);
select t_dmg(:'m','h3',20);
select t_set(:'m','h2','crmin','0'::jsonb); select t_set(:'m','h2','crmax','0'::jsonb);
select t_set(:'m','h2','rmin','1'::jsonb); select t_set(:'m','h2','rmax','1'::jsonb);
select t_set(:'m','h2','parryPct','0'::jsonb); select t_set(:'m','h3','parryPct','0'::jsonb);
select t_hp(:'m','h2',80); select t_set(:'m','h2','maxHp','100'::jsonb);
select t_hp(:'m','h3',100); select t_set(:'m','h3','maxHp','100'::jsonb);
select public.submit_attack(:'m','h3','h2');
select t_ok(t_shape(:'m') = 'hit:h3',
            'one clean swing, no counter -- h3 hits h2 for a fixed 20, nothing answers');
select t_ok(t_get(:'m','h2','hp')::int = 60,
            'h2 took the 20 damage: 80 - 20 = 60');
select t_ok(t_get(:'m','h3','hp')::int = 90,
            'REFLECT_DAMAGE_PCT gave 50% of that 20 (=10) back to h3: 100 - 10 = 90');

-- ---------------------------------------------------------------------------
-- SUMMON_OBJECT -- dispatches identically to CREATE_STRUCTURE.
-- ---------------------------------------------------------------------------
select t_reset(:'m');
select t_place(:'m','h4',2,2);
select t_set(:'m','h4','rmax','3'::jsonb);
select public.cn_ability(:'m', 'host', 'h4', '@2,4');
select t_ok(t_nobj(:'m','spike-trap') = 1,
            'SUMMON_OBJECT placed exactly one spike-trap obstacle -- same as CREATE_STRUCTURE does');
select t_ok(t_obj_at(:'m',2,4,'owner') = 'host', 'placed by the host, same ownership rule');

-- ---------------------------------------------------------------------------
-- REVIVE, scene 1 -- cn_bury really populates the graveyard even with no
-- script to consume it: g3 (Mako, unscripted) dies and just sits there.
-- ---------------------------------------------------------------------------
select t_reset(:'m');
update public.matches set state = jsonb_set(state, '{turn}', '"host"') where id = :'m';
select t_trees(:'m','[]'::jsonb);
select t_place(:'m','h1',2,2); select t_place(:'m','g3',2,3);
select t_dmg(:'m','h1',999);
select t_hp(:'m','g3',5); select t_set(:'m','g3','maxHp','60'::jsonb);
select t_set(:'m','g3','parryPct','0'::jsonb);
select t_ok(t_alive(:'m','g3'), 'g3 (Mako) is alive going into the killing blow');
select t_ok(t_graveyard_count(:'m','guest') = 0, 'guest graveyard starts empty');
select public.submit_attack(:'m','h1','g3');
select t_ok(not t_alive(:'m','g3'), 'g3 died -- unscripted, so nothing revives it automatically');
select t_ok(t_graveyard_count(:'m','guest') = 1,
            'cn_bury alone put exactly one entry in the guest graveyard');
select t_ok(t_graveyard_last(:'m','guest','id') = 'g3', 'and it is g3, the unit that just died');

-- ---------------------------------------------------------------------------
-- REVIVE, scene 2 -- the "broader" case: g1 (Dereo), a DIFFERENT unit, uses
-- its own ON_ABILITY/LAST_DEAD_ALLY/REVIVE to bring g3 back from the
-- graveyard scene 1 just filled. Not a self-revive.
-- ---------------------------------------------------------------------------
select set_config('app.uid','dd000000-0000-0000-0000-0000000000d2',false);
update public.matches set state = jsonb_set(state, '{turn}', '"guest"') where id = :'m';
select t_reset(:'m');
select t_place(:'m','g1',4,4);
select public.cn_ability(:'m', 'guest', 'g1', null);
select t_ok(t_alive(:'m','g3'),
            'g1''s LAST_DEAD_ALLY/REVIVE ability brought g3 back -- reviving an ALLY, not itself');
select t_ok(t_get(:'m','g3','hp')::int = round(60 * 60 / 100.0)::int,
            'revived at 60% of Mako''s 60 max hp = 36 (the card''s own printed hp, untouched by this scene)');
select t_ok(cn_cheb(t_get(:'m','g3','x')::int, t_get(:'m','g3','y')::int, 4, 4) = 1,
            'revived on a tile adjacent to g1, the reviving unit -- not to where g3 died');
select t_ok(t_graveyard_count(:'m','guest') = 0, 'and the graveyard entry is consumed, not left behind');

-- ---------------------------------------------------------------------------
-- REVIVE, scene 3 -- self-revive-on-death still works as the natural
-- special case of the same mechanism: g2 (Eva) revives ITSELF via
-- ON_DEATH/LAST_DEAD_ALLY, in the same cn_attack call that killed her.
-- ---------------------------------------------------------------------------
select set_config('app.uid','dd000000-0000-0000-0000-0000000000d1',false);
update public.matches set state = jsonb_set(state, '{turn}', '"host"') where id = :'m';
select t_reset(:'m');
select t_place(:'m','h1',2,2); select t_place(:'m','g2',2,3);
select t_dmg(:'m','h1',999);
select t_hp(:'m','g2',5); select t_set(:'m','g2','maxHp','80'::jsonb);
select t_set(:'m','g2','parryPct','0'::jsonb);
select t_ok(t_alive(:'m','g2'), 'g2 (Eva) is alive going into the killing blow');
select public.submit_attack(:'m','h1','g2');
select t_ok(t_alive(:'m','g2'),
            'ON_DEATH/LAST_DEAD_ALLY/REVIVE brought Eva back in the very same call that killed her');
select t_ok(t_get(:'m','g2','hp')::int = 40, 'revived at 50% of her 80 max hp = 40');
select t_ok(cn_cheb(t_get(:'m','g2','x')::int, t_get(:'m','g2','y')::int, 2, 3) = 1,
            'revived on a tile adjacent to where she died');
select t_ok(t_graveyard_count(:'m','guest') = 0,
            'and her own graveyard entry is consumed in the same breath -- not left sitting there');

-- ---------------------------------------------------------------------------
-- Structures' COUNTER_ATTACK_PCT -- strikes back at THE_ATTACKER who
-- destroys it, for value% of the exact blow that did it.
-- ---------------------------------------------------------------------------
select t_reset(:'m');
update public.matches set state = jsonb_set(state, '{turn}', '"host"') where id = :'m';
select t_trees(:'m', jsonb_build_array(jsonb_build_object(
  'id', 'test-counter-obj-1', 'kind', 'test-counter-struct',
  'x', 2, 'y', 4, 'hp', 8, 'maxHp', 8, 'owner', 'guest', 'by', 'g3')));
select t_place(:'m','h5',2,3);
select t_dmg(:'m','h5',8);
select t_set(:'m','h5','rmin','1'::jsonb); select t_set(:'m','h5','rmax','1'::jsonb);
select t_hp(:'m','h5',100); select t_set(:'m','h5','maxHp','100'::jsonb);
select public.submit_attack(:'m','h5','test-counter-obj-1');
select t_ok(t_nobj(:'m','test-counter-struct') = 0,
            'the structure is destroyed -- its 8 hp met an 8-damage blow exactly');
select t_ok(t_get(:'m','h5','hp')::int = 100 - round(8 * 40 / 100.0)::int,
            'COUNTER_ATTACK_PCT struck back at h5 (THE_ATTACKER) for 40% of the 8 damage that destroyed it');

-- ---------------------------------------------------------------------------
-- cleanup
-- ---------------------------------------------------------------------------
delete from public.card_effects where card_id = (select id from public.cards where slug = 'dione-grifo') and sort >= 900;
delete from public.card_effects where card_id = (select id from public.cards where slug = 'eva') and sort >= 900;
delete from public.card_effects where card_id = (select id from public.cards where slug = 'himanta') and sort >= 900;
delete from public.card_effects where card_id = (select id from public.cards where slug = 'dereo') and sort >= 900;
update public.cards set ability_kind = null, summon_kind = null where slug = 'himanta';
update public.cards set ability_kind = null where slug = 'dereo';
-- Defensive: 31_structures.sql fails partway on a pre-existing, unrelated
-- gap (see project_status.md) and ON_ERROR_STOP means its own end-of-file
-- cleanup never runs when that happens -- so a leftover Fey row pointing at
-- 'spike-trap' can still be sitting in card_effects here. Cleared by slug
-- rather than by card, so this does not depend on which card left it.
delete from public.card_effects where structure_slug = 'spike-trap';
delete from public.structure_effects where structure_id = (select id from public.structures where slug = 'test-counter-struct');
delete from public.structures where slug in ('test-counter-struct', 'spike-trap');
