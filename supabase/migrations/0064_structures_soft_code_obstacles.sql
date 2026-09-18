-- =============================================================================
-- 0064 -- trees, walls, traps and tornadoes become real `structures` rows,
-- not a hard-coded four-kind branch. Also ports Fey/Mako/Lumea's "summon"
-- ability off cn_ability's hard-coded branch onto the generic scripted
-- (card_effects / CREATE_STRUCTURE) path, and hardens cn_create_structure
-- with the range/LOS/one-at-a-time checks that hard-coded branch used to
-- provide for free.
--
-- WHY: the `structures` content type (0057) has been fully built -- table,
-- Mad-Libs sentence builder, admin UI, CREATE_STRUCTURE action, ON_PLACE/
-- ON_STEPPED_ON/ON_DESTROYED triggers -- but has sat completely EMPTY on
-- the live project, because the one thing that would actually exercise it
-- (a structure existing at all) never happened: even the game's own trees
-- are still a hard-coded case inside cn_obj_kind/solid/hp/name, and Fey/
-- Mako/Lumea's wall/trap/tornado still go through cn_ability's legacy
-- 'summon' branch rather than CREATE_STRUCTURE. Per Jared: "the tree that
-- is used in battle... should be a structure... add any structure that any
-- of the cards' abilities ask for... never hard coded, added from the
-- in-game admin mode."
--
-- WHAT STAYS THE SAME ON PURPOSE: the obstacle `kind` STRING placed on the
-- board is unchanged ('tree'/'wall'/'bomb'/'tornado') -- only where its hp/
-- solidity/display-name come FROM changes (a `structures` row instead of a
-- hard-coded branch). Every other piece of machinery that keys off that
-- kind string rather than off ability_kind/summon_kind -- cn_trap_at
-- (bomb damage), the tornado throw-pending decision, cn_step_on_structure's
-- dispatch, the client's tree.webp image and wall/bomb/tornado inline SVG
-- glyphs in Board.tsx, lib/objects.ts's objTramplable/objNameKey -- is
-- completely unaffected, because none of it changes. cn_gen_trees and
-- cn_royale_gen_trees already call cn_obj_hp('tree') rather than a literal
-- 30, so they pick up the catalog value with no changes of their own.
--
-- ORDER MATTERS: seed the catalog FIRST, then swap the four lookup
-- functions to read from it -- so there is never a moment where a live
-- match's tree/wall/bomb/tornado would resolve to a missing row.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Seed the catalog with the four kinds that already exist in-game, using
--    the exact values the hard-coded branches use today (byte-identical
--    behaviour once the functions below are swapped). `name` carries the
--    full display phrase ("a tree", not "tree"), matching what
--    cn_obj_name/cn_attack's log lines already say -- the generalized
--    cn_obj_name below returns this column verbatim.
-- ---------------------------------------------------------------------------
insert into public.structures (slug, name, hp, blocks_movement, accent, is_active, sort)
values
  ('tree',    'a tree',         30, true,  '#2f6b3a', true, 1),
  ('wall',    'a cursed wall',  20, true,  '#5a3b7a', true, 2),
  ('bomb',    'a trap',         15, false, '#a3312c', true, 3),
  ('tornado', 'a tornado',      25, false, '#3a6ea5', true, 4)
on conflict (slug) do nothing;

-- ---------------------------------------------------------------------------
-- 2. cn_obj_solid / cn_obj_hp / cn_obj_name -- drop the hard-coded branch
--    for all four kinds now that the catalog carries them. cn_obj_kind
--    itself (`coalesce(p_obj->>'kind', 'tree')`) needs no change -- it was
--    never kind-specific.
-- ---------------------------------------------------------------------------
create or replace function public.cn_obj_solid(p_kind text)
 returns boolean
 language sql
 stable
 set search_path to 'public'
as $function$
  select coalesce((select blocks_movement from public.structures where slug = p_kind), false)
$function$;

create or replace function public.cn_obj_hp(p_kind text)
 returns integer
 language sql
 stable
 set search_path to 'public'
as $function$
  select (select hp from public.structures where slug = p_kind)
$function$;

create or replace function public.cn_obj_name(p_kind text)
 returns text
 language sql
 stable
 set search_path to 'public'
as $function$
  select coalesce((select name from public.structures where slug = p_kind), 'a structure')
$function$;

-- ---------------------------------------------------------------------------
-- 3. cn_create_structure -- three guards the old hard-coded 'summon' branch
--    provided that the generic path never grew:
--      a) ONE LIVE STRUCTURE PER UNIT AT A TIME. The old branch raised
--         'that summon is still standing' before placing a second one.
--         CREATE_STRUCTURE's other guards (bad slug, off-board, tile
--         taken) are all silent no-ops rather than exceptions, so this
--         matches that -- see this migration's report for the one real
--         behavioural difference that follows from it (the activation is
--         still spent on a no-op attempt, same as every other scripted
--         guard failure already does).
--      b) RANGE. The old branch required 1 <= distance <= the unit's own
--         rmax. Scoped to CREATE_STRUCTURE specifically, not the sibling
--         TELEPORT_SELF branch in cn_effect_apply_action -- no live card
--         uses TELEPORT_SELF yet, so there is no established behaviour to
--         preserve there and guessing one risks encoding the wrong rule.
--      c) LINE OF SIGHT. The old branch required cn_los_clear.
--    All three are silent no-ops (return v_st unchanged), matching this
--    function's own existing style for its other guards.
-- ---------------------------------------------------------------------------
create or replace function public.cn_create_structure(v_st jsonb, p_effect jsonb, p_unit jsonb, p_target_id text)
 returns jsonb
 language plpgsql
 set search_path to 'public'
as $function$
declare
  v_slug text := p_effect->>'structure_slug';
  v_row public.structures;
  v_tile int[]; v_rocks jsonb := '[]'::jsonb; e jsonb;
  v_dist int;
begin
  if v_slug is null then return v_st; end if;
  select * into v_row from public.structures where slug = v_slug and is_active;
  if v_row.id is null then return v_st; end if;

  -- (a) one live structure per unit at a time.
  for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
    if e->>'by' = p_unit->>'id' then return v_st; end if;
  end loop;

  v_tile := cn_tile_target(p_target_id);
  if v_tile is null then return v_st; end if;
  if v_tile[1] < 0 or v_tile[2] < 0
     or v_tile[1] >= coalesce((v_st->'board'->>'w')::int, 0)
     or v_tile[2] >= coalesce((v_st->'board'->>'h')::int, 0) then
    return v_st;
  end if;

  -- (b) range: 1 <= distance <= this unit's own rmax.
  v_dist := cn_cheb((p_unit->>'x')::int, (p_unit->>'y')::int, v_tile[1], v_tile[2]);
  if v_dist < 1 or v_dist > coalesce((p_unit->>'rmax')::int, 0) then
    return v_st;
  end if;

  -- (c) line of sight.
  if not cn_los_clear(v_st, (p_unit->>'x')::int, (p_unit->>'y')::int, v_tile[1], v_tile[2]) then
    return v_st;
  end if;

  if exists (select 1 from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) u
              where (u->>'x')::int = v_tile[1] and (u->>'y')::int = v_tile[2])
     or exists (select 1 from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) o
              where (o->>'x')::int = v_tile[1] and (o->>'y')::int = v_tile[2]) then
    return v_st;
  end if;

  for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
    v_rocks := v_rocks || e;
  end loop;
  v_rocks := v_rocks || jsonb_build_object(
    'id', gen_random_uuid()::text, 'kind', v_slug,
    'x', v_tile[1], 'y', v_tile[2],
    'hp', v_row.hp, 'maxHp', v_row.hp,
    'owner', p_unit->>'owner', 'by', p_unit->>'id');
  v_st := jsonb_set(v_st, '{obstacles}', v_rocks);
  v_st := state_log(v_st, (p_unit->>'name') || ' sets down ' || cn_obj_name(v_slug) || '.');

  v_st := cn_run_structure_effects(v_st, 'ON_PLACE',
    v_rocks->(jsonb_array_length(v_rocks) - 1),
    jsonb_build_object('placedBy', p_unit->>'id'));
  return v_st;
end
$function$;

-- ---------------------------------------------------------------------------
-- 4. Port Fey, Mako and Lumea off cn_ability's hard-coded 'summon' branch
--    onto 'scripted' + a CREATE_STRUCTURE card_effects sentence.
--
--    CORRECTION vs. this migration's first draft: `summon_kind` is NOT left
--    populated. `cards_summon_needs_kind` enforces
--    `(ability_kind = 'summon') = (summon_kind IS NOT NULL)` as a two-way
--    biconditional, so a row with `ability_kind = 'scripted'` and a
--    non-null `summon_kind` is rejected outright -- confirmed live
--    (`pg_get_constraintdef`), not assumed. There is no "leave it, it's
--    harmless" option here; the two columns must be changed together in
--    the same UPDATE. This is a deliberate, narrow exception to this
--    project's usual "retire never delete" convention, forced by a check
--    constraint rather than a style choice -- rollback (if ever needed)
--    restores both `ability_kind` and `summon_kind` together from this
--    migration's own history, not by leaving one column dangling now.
--    Their rmax (Fey 3, Mako 1, Lumea 2) is unchanged, so the range guard
--    added above reproduces their old reach exactly.
--
--    Eva's mist is deliberately NOT touched here: it is a timed team-wide
--    buff-zone (`state.mist`), not an attackable/steppable object with hp,
--    and does not fit the structures model as it stands. Left on its
--    existing 'mist' branch; a real decision either way (a new zone-type
--    structure kind, or leaving it a distinct mechanic permanently) is a
--    separate, bigger design question than this migration's scope.
-- ---------------------------------------------------------------------------
update public.cards set ability_kind = 'scripted', summon_kind = null where slug in ('fey', 'mako', 'lumea');

insert into public.card_effects (card_id, sort, trigger, target_selector, action, structure_slug)
select id, 0, 'ON_ABILITY', 'BOARD_CELL', 'CREATE_STRUCTURE', 'wall'    from public.cards where slug = 'fey'
union all
select id, 0, 'ON_ABILITY', 'BOARD_CELL', 'CREATE_STRUCTURE', 'bomb'    from public.cards where slug = 'mako'
union all
select id, 0, 'ON_ABILITY', 'BOARD_CELL', 'CREATE_STRUCTURE', 'tornado' from public.cards where slug = 'lumea';

-- ---------------------------------------------------------------------------
-- Did it work?
-- ---------------------------------------------------------------------------
select
  (select count(*) from public.structures where slug in ('tree','wall','bomb','tornado')) = 4
    as all_four_seeded,
  cn_obj_hp('tree') = 30 and cn_obj_hp('wall') = 20 and cn_obj_hp('bomb') = 15 and cn_obj_hp('tornado') = 25
    as hp_matches_old_values,
  cn_obj_solid('tree') = true and cn_obj_solid('wall') = true
    and cn_obj_solid('bomb') = false and cn_obj_solid('tornado') = false
    as solidity_matches_old_values,
  cn_obj_name('tree') = 'a tree' and cn_obj_name('wall') = 'a cursed wall'
    and cn_obj_name('bomb') = 'a trap' and cn_obj_name('tornado') = 'a tornado'
    as names_match_old_values,
  (select count(*) from public.cards where slug in ('fey','mako','lumea') and ability_kind = 'scripted') = 3
    as fey_mako_lumea_scripted,
  (select count(*) from public.cards where slug in ('fey','mako','lumea') and summon_kind is null) = 3
    as fey_mako_lumea_summon_kind_cleared,
  (select count(*) from public.card_effects ce join public.cards c on c.id = ce.card_id
     where c.slug in ('fey','mako','lumea') and ce.action = 'CREATE_STRUCTURE') = 3
    as fey_mako_lumea_have_create_structure_sentence;
