-- =============================================================================
-- 0075 -- ALL/ANY condition groups for the sentence builder, with nesting.
--
-- WHY: 0049/0057 built `conditions` as a flat jsonb array, every element
-- AND'd together (cn_effect_conditions_met), and 0074 added a per-element
-- "negate" flag for "and not" -- but there has never been an OR anywhere in
-- the engine (see SentenceBuilder.tsx's own header: "'Or' is accepted
-- vocabulary in the developer's spec but not built"). Jared's ask: real
-- AND/OR logic, but WITHOUT inline "X and (Y or Z)" parenthetical sentences
-- -- instead the "ALL/ANY" grouping method, so the Mad-Libs sentence stays
-- readable: "IF [ALL/ANY] of the following are true: ..." as its own
-- block, nestable (an ANY block can contain an ALL block and vice versa).
--
-- HOW, with no schema change at all: `conditions` was already "an array of
-- things that get AND'd." A GROUP is simply a new shape one array element
-- can take -- {kind:'group', mode:'ALL'|'ANY', children:[...]} -- where
-- `children` is the SAME shape recursively (a leaf {field,op,value,negate}
-- or another group). The top level was always an implicit ALL; this makes
-- that explicit and lets any element BE a labelled ALL/ANY block instead of
-- only ever a leaf. A pre-0075 row -- a flat array of plain leaves, no
-- `kind` anywhere -- is already exactly what this reads: an implicit
-- top-level ALL of leaves, byte-for-byte the same evaluation as before.
--
-- cn_effect_conditions_met's SIGNATURE, CALLERS, and the `conditions`
-- COLUMN TYPE are all completely unchanged -- cn_run_effects and
-- cn_run_structure_effects need no edits at all. The only server change is
-- what happens INSIDE conditions_met: it now delegates each array element
-- to a new small recursive function, cn_effect_node_met, which is the one
-- place that knows how to read a leaf vs. a group.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. cn_effect_node_met -- evaluate ONE node of the conditions tree: a leaf
--    (delegates to the existing cn_effect_condition_met, then applies its
--    own `negate`, exactly what cn_effect_conditions_met's loop body did
--    before this migration) or a group (recurses over `children`, combined
--    with AND for mode='ALL' or OR for mode='ANY', then itself flipped
--    should a group ever carry `negate` -- not offered by the UI today, but
--    a free, honest extension of the same flag rather than a special case
--    the leaf branch gets and the group branch does not).
--
--    Volatile, not stable: cn_effect_condition_met calls random() for
--    'roll_pct', and that has to keep re-rolling on every recursive call
--    exactly as it always has, not get folded away as a constant.
-- ---------------------------------------------------------------------------
create or replace function public.cn_effect_node_met(p_node jsonb, p_ctx jsonb)
 returns boolean
 language plpgsql
 set search_path to 'public'
as $function$
declare
  v_kind text := p_node->>'kind';
  v_mode text;
  v_child jsonb;
  v_any boolean := false;
  v_all boolean := true;
  v_has_child boolean := false;
  v_result boolean;
begin
  if p_node is null then return true; end if;

  if v_kind = 'group' then
    v_mode := coalesce(p_node->>'mode', 'ALL');
    for v_child in select * from jsonb_array_elements(coalesce(p_node->'children', '[]'::jsonb)) loop
      v_has_child := true;
      if cn_effect_node_met(v_child, p_ctx) then
        v_any := true;
      else
        v_all := false;
      end if;
    end loop;
    -- An ANY group with nothing inside it has nothing that could be true,
    -- so it reads as false rather than the vacuous "true" an empty OR would
    -- otherwise fall out of. An empty ALL group stays true (vacuously, the
    -- ordinary reading of "every one of zero things holds") -- the same
    -- answer a pre-0075 empty `conditions` array has always given.
    v_result := case when v_mode = 'ANY' then v_has_child and v_any else v_all end;
  else
    -- A leaf: exactly what the pre-0075 loop body did per element.
    v_result := cn_effect_condition_met(p_node, p_ctx);
  end if;

  if coalesce((p_node->>'negate')::boolean, false) then v_result := not v_result; end if;
  return v_result;
end
$function$;

-- ---------------------------------------------------------------------------
-- 2. cn_effect_conditions_met -- now just the top-level AND-loop, spliced
--    fresh from its 0074 body (re-fetched via pg_get_functiondef against a
--    database with 0001-0074 applied, immediately before writing this
--    file) with the loop body's own leaf-evaluation-plus-negate replaced by
--    one call to cn_effect_node_met, which now knows how to do both.
-- ---------------------------------------------------------------------------
create or replace function public.cn_effect_conditions_met(p_conditions jsonb, p_ctx jsonb)
 returns boolean
 language plpgsql
 set search_path to 'public'
as $function$
declare v_node jsonb;
begin
  if p_conditions is null or jsonb_typeof(p_conditions) <> 'array' then return true; end if;
  for v_node in select * from jsonb_array_elements(p_conditions) loop
    if not cn_effect_node_met(v_node, p_ctx) then return false; end if;
  end loop;
  return true;
end
$function$;

-- ---------------------------------------------------------------------------
-- Did it work? Every one of these runs cn_effect_node_met/conditions_met
-- directly, against hand-built jsonb, with no match/unit/table needed --
-- the same "ask the pure function" shape 33_evasion_and_conditions.sql's
-- own condition assertions already use.
-- ---------------------------------------------------------------------------
do $$
declare
  v_ctx jsonb := jsonb_build_object('self', jsonb_build_object('hp', 20, 'maxHp', 100));
  v_true jsonb := jsonb_build_object('field', 'self.hp', 'op', '<', 'value', '25');   -- 20 < 25: true
  v_false jsonb := jsonb_build_object('field', 'self.hp', 'op', '>', 'value', '25');  -- 20 > 25: false
begin
  -- A legacy flat array of leaves is untouched: still a plain AND.
  assert cn_effect_conditions_met(jsonb_build_array(v_true), v_ctx) = true,
    '0075 regression: a lone true leaf must still pass';
  assert cn_effect_conditions_met(jsonb_build_array(v_true, v_false), v_ctx) = false,
    '0075 regression: AND of true+false must fail, exactly as before';

  -- ALL group: same as AND.
  assert cn_effect_node_met(jsonb_build_object('kind', 'group', 'mode', 'ALL',
    'children', jsonb_build_array(v_true, v_true)), v_ctx) = true,
    'ALL group of two true leaves must be true';
  assert cn_effect_node_met(jsonb_build_object('kind', 'group', 'mode', 'ALL',
    'children', jsonb_build_array(v_true, v_false)), v_ctx) = false,
    'ALL group with one false leaf must be false';

  -- ANY group: real OR, which the engine has never had before this migration.
  assert cn_effect_node_met(jsonb_build_object('kind', 'group', 'mode', 'ANY',
    'children', jsonb_build_array(v_true, v_false)), v_ctx) = true,
    'ANY group with one true leaf must be true';
  assert cn_effect_node_met(jsonb_build_object('kind', 'group', 'mode', 'ANY',
    'children', jsonb_build_array(v_false, v_false)), v_ctx) = false,
    'ANY group of two false leaves must be false';

  -- Empty groups: ALL vacuously true, ANY vacuously false.
  assert cn_effect_node_met(jsonb_build_object('kind', 'group', 'mode', 'ALL',
    'children', '[]'::jsonb), v_ctx) = true, 'an empty ALL group must be true';
  assert cn_effect_node_met(jsonb_build_object('kind', 'group', 'mode', 'ANY',
    'children', '[]'::jsonb), v_ctx) = false, 'an empty ANY group must be false';

  -- Nesting: an ANY group inside an ALL group -- exactly what the spec asks
  -- to allow. true AND (false OR true) = true.
  assert cn_effect_node_met(jsonb_build_object('kind', 'group', 'mode', 'ALL', 'children',
    jsonb_build_array(v_true, jsonb_build_object('kind', 'group', 'mode', 'ANY',
      'children', jsonb_build_array(v_false, v_true)))), v_ctx) = true,
    'ALL[true, ANY[false, true]] must be true';
  -- true AND (false OR false) = false.
  assert cn_effect_node_met(jsonb_build_object('kind', 'group', 'mode', 'ALL', 'children',
    jsonb_build_array(v_true, jsonb_build_object('kind', 'group', 'mode', 'ANY',
      'children', jsonb_build_array(v_false, v_false)))), v_ctx) = false,
    'ALL[true, ANY[false, false]] must be false';

  -- A group inside the top-level array, AND'd against a sibling leaf the
  -- ordinary way -- the shape the sentence builder actually saves when a
  -- card has both a plain "if" leaf and a "+ If (group)" block.
  assert cn_effect_conditions_met(jsonb_build_array(v_true,
    jsonb_build_object('kind', 'group', 'mode', 'ANY', 'children', jsonb_build_array(v_false, v_true))),
    v_ctx) = true,
    'top-level [true-leaf, ANY[false,true]-group] must be true';
  assert cn_effect_conditions_met(jsonb_build_array(v_true,
    jsonb_build_object('kind', 'group', 'mode', 'ANY', 'children', jsonb_build_array(v_false, v_false))),
    v_ctx) = false,
    'top-level [true-leaf, ANY[false,false]-group] must be false';

  -- "and not" still works, leaf or group.
  assert cn_effect_node_met(jsonb_build_object('field', 'self.hp', 'op', '<', 'value', '25', 'negate', true), v_ctx) = false,
    'negate flips a leaf, as it always has';
  assert cn_effect_node_met(jsonb_build_object('kind', 'group', 'mode', 'ANY', 'negate', true,
    'children', jsonb_build_array(v_false, v_false)), v_ctx) = true,
    'negate also flips a whole group -- a free extension of the same flag';

  raise notice '0075 self-check: all condition-group assertions passed';
end
$$;
