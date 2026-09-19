-- 0075: ALL/ANY condition groups, with nesting -- cn_effect_node_met (new)
-- and cn_effect_conditions_met (now a thin wrapper over it). Same shape as
-- 33_evasion_and_conditions.sql's own condition-field checks and
-- 35_not_built_yet_actions.sql's negate-chain checks: hand-built jsonb
-- against the pure functions, no match needed for most of it, because the
-- thing under test is data shape and boolean logic, not board state.

\set ON_ERROR_STOP on
\pset pager off

-- ---- schema: a card_effects row may carry a group-shaped conditions array,
--      same column, no constraint change -- ---------------------------------
do $$
declare v_card uuid; v_saved jsonb;
begin
  select id into v_card from public.cards where slug = 'himanta';
  perform t_ok(v_card is not null, 'himanta exists to test against');

  insert into public.card_effects (card_id, sort, trigger, target_selector, action, value, conditions)
  values (v_card, 900, 'ON_ABILITY', 'THE_TARGET', 'DEAL_DAMAGE', 5, jsonb_build_array(
    jsonb_build_object('kind', 'group', 'mode', 'ANY', 'children', jsonb_build_array(
      jsonb_build_object('field', 'target.hp', 'op', '<', 'value', '50'),
      jsonb_build_object('field', 'target.has_status', 'value', 'BURNING')
    ))
  ));
  select conditions into v_saved from public.card_effects where card_id = v_card and sort = 900;
  perform t_ok(v_saved is not null and jsonb_typeof(v_saved) = 'array' and jsonb_array_length(v_saved) = 1,
              'a group-shaped conditions array saves to the same jsonb column, no schema change needed');
  perform t_ok(v_saved->0->>'kind' = 'group' and v_saved->0->>'mode' = 'ANY',
              'and round-trips byte-for-byte -- kind/mode survive the insert');

  delete from public.card_effects where card_id = v_card and sort = 900;
end $$;

-- ---- cn_effect_node_met / cn_effect_conditions_met: pure boolean logic ----
do $$
declare
  v_ctx jsonb := jsonb_build_object('self', jsonb_build_object('hp', 20, 'maxHp', 100),
                                     'target', jsonb_build_object('hp', 75, 'maxHp', 100));
  v_true jsonb := '{"field":"self.hp","op":"<","value":"25"}'::jsonb;   -- 20 < 25: true
  v_false jsonb := '{"field":"self.hp","op":">","value":"25"}'::jsonb;  -- 20 > 25: false
begin
  -- A plain leaf, no `kind` at all -- exactly a pre-0075 row -- is unchanged.
  perform t_ok(cn_effect_node_met(v_true, v_ctx), 'a bare leaf with no kind still evaluates as a leaf');
  perform t_ok(cn_effect_conditions_met(jsonb_build_array(v_true), v_ctx),
              'a legacy one-leaf array still passes exactly as before 0075');
  perform t_ok(not cn_effect_conditions_met(jsonb_build_array(v_true, v_false), v_ctx),
              'a legacy two-leaf array is still a plain AND -- one false fails the chain');

  -- ALL group: real AND, spelled out as a labelled block.
  perform t_ok(cn_effect_node_met(
    jsonb_build_object('kind','group','mode','ALL','children', jsonb_build_array(v_true, v_true)), v_ctx),
    'ALL[true, true] is true');
  perform t_ok(not cn_effect_node_met(
    jsonb_build_object('kind','group','mode','ALL','children', jsonb_build_array(v_true, v_false)), v_ctx),
    'ALL[true, false] is false');

  -- ANY group: the OR this engine has never had before 0075.
  perform t_ok(cn_effect_node_met(
    jsonb_build_object('kind','group','mode','ANY','children', jsonb_build_array(v_true, v_false)), v_ctx),
    'ANY[true, false] is true -- real OR, new in 0075');
  perform t_ok(not cn_effect_node_met(
    jsonb_build_object('kind','group','mode','ANY','children', jsonb_build_array(v_false, v_false)), v_ctx),
    'ANY[false, false] is false');

  -- Defaulting: a group with no `mode` at all reads as ALL, the safer of
  -- the two (a malformed/old-shaped group can never accidentally pass
  -- something an author meant to gate with every condition).
  perform t_ok(not cn_effect_node_met(
    jsonb_build_object('kind','group','children', jsonb_build_array(v_true, v_false)), v_ctx),
    'a group with no mode defaults to ALL, not ANY');

  -- Empty groups: ALL is vacuously true (matches an empty top-level array's
  -- own long-standing behaviour); ANY has nothing that could be true.
  perform t_ok(cn_effect_node_met(jsonb_build_object('kind','group','mode','ALL','children','[]'::jsonb), v_ctx),
              'an empty ALL group is true');
  perform t_ok(not cn_effect_node_met(jsonb_build_object('kind','group','mode','ANY','children','[]'::jsonb), v_ctx),
              'an empty ANY group is false');

  -- Nesting: an ANY group inside an ALL group, and the reverse -- the exact
  -- shape "placing an ANY group inside an ALL group" asks for.
  perform t_ok(cn_effect_node_met(jsonb_build_object('kind','group','mode','ALL','children', jsonb_build_array(
      v_true, jsonb_build_object('kind','group','mode','ANY','children', jsonb_build_array(v_false, v_true))
    )), v_ctx),
    'ALL[true, ANY[false, true]] is true');
  perform t_ok(not cn_effect_node_met(jsonb_build_object('kind','group','mode','ALL','children', jsonb_build_array(
      v_true, jsonb_build_object('kind','group','mode','ANY','children', jsonb_build_array(v_false, v_false))
    )), v_ctx),
    'ALL[true, ANY[false, false]] is false');
  perform t_ok(cn_effect_node_met(jsonb_build_object('kind','group','mode','ANY','children', jsonb_build_array(
      v_false, jsonb_build_object('kind','group','mode','ALL','children', jsonb_build_array(v_true, v_true))
    )), v_ctx),
    'ANY[false, ALL[true, true]] is true -- an ALL group nested inside an ANY one');
  -- Nesting three deep, since the recursion has to keep going, not stop at one level.
  perform t_ok(cn_effect_node_met(jsonb_build_object('kind','group','mode','ALL','children', jsonb_build_array(
      jsonb_build_object('kind','group','mode','ANY','children', jsonb_build_array(v_false,
        jsonb_build_object('kind','group','mode','ALL','children', jsonb_build_array(v_true, v_true))))
    )), v_ctx),
    'three levels deep: ALL[ ANY[false, ALL[true,true]] ] is true');

  -- A top-level array mixing a plain leaf with a group -- the shape the
  -- sentence builder actually saves once a sentence has both a simple "if"
  -- leaf and a "+ If (group)" block, AND'd together as the array always has.
  perform t_ok(cn_effect_conditions_met(jsonb_build_array(v_true,
      jsonb_build_object('kind','group','mode','ANY','children', jsonb_build_array(v_false, v_true))
    ), v_ctx),
    'top-level [leaf, ANY-group] -- both hold -- is true');
  perform t_ok(not cn_effect_conditions_met(jsonb_build_array(v_true,
      jsonb_build_object('kind','group','mode','ANY','children', jsonb_build_array(v_false, v_false))
    ), v_ctx),
    'top-level [leaf, ANY-group] -- the group fails -- is false');

  -- "and not" still applies per-leaf inside a group, exactly as it does at
  -- the top level (0074).
  perform t_ok(not cn_effect_node_met(
    jsonb_build_object('kind','group','mode','ALL','children', jsonb_build_array(
      jsonb_build_object('field','self.hp','op','<','value','25','negate',true))), v_ctx),
    'a negated leaf inside an ALL group still flips -- true becomes false');

  -- negate on the GROUP itself -- a free extension of the same flag, not
  -- offered by the UI today but honest rather than silently ignored.
  perform t_ok(cn_effect_node_met(
    jsonb_build_object('kind','group','mode','ANY','negate',true,
      'children', jsonb_build_array(v_false, v_false)), v_ctx),
    'negate on a whole ANY group flips it too -- false becomes true');
end $$;
