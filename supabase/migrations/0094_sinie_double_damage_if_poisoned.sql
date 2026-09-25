-- 0094: companion data fix for the per-block-conditions UI change in
-- SentenceBuilder.tsx/AdminCards.tsx/AdminStructures.tsx (same commit).
--
-- Until now, every block ("+Add Block") within one authored sentence
-- shared a single condition array (edited once, at the top of the
-- sentence, and force-synced onto every row in the group). That made
-- "poison the target, and if it was ALREADY poisoned deal double damage"
-- impossible to build as one Active ability: one block needs to run
-- unconditionally (apply poison, deal base damage) while a sibling block
-- needs to run only when the target was already poisoned -- two different
-- gates in the same sentence, which a single shared condition can't
-- express. Card abilities also cap at one Active ("when activated")
-- sentence per card (card_ability_meta's partial unique index), so
-- splitting into several sentences wasn't an option either.
--
-- The engine (cn_run_effects) was never actually limited this way --
-- `cn_effect_conditions_met` is evaluated per ROW (`v_row->'conditions'`),
-- not per group; group_id has only ever been an editing convenience (see
-- 0056_ability_sentences.sql's own column comment). Velmor's two ON_ABILITY
-- rows (0073) already carry independent `conditions` arrays as proof. So
-- this only needed a UI change, not a schema or engine change -- see the
-- SentenceBuilder.tsx diff in this same commit for the "if" editor moving
-- from once-per-sentence to once-per-block (onSetRowConditions replaces
-- onSetConditions), plus a real bug fix: the condition value box for
-- `*.has_status` was free text, so a typed "Poisoned" never matched the
-- engine's enum ("POISON") and silently misevaluated -- it's a Pill now,
-- like every other status picker in this editor.
--
-- Sinie's own card_effects rows were mid-repair from the user's own
-- attempts (both rows shared "target.has_status != Poisoned", which -- due
-- to the free-text bug above -- was actually always true regardless of
-- poison state, so the ability ran unconditionally with no real gating at
-- all). Rebuilt here as three blocks in Sinie's one existing ON_ABILITY
-- sentence (group_id 5f49b4ef-6ccc-49b8-a01d-224c1ac106e1):
--   sort 0 (existing row): APPLY_STATUS Poison, unconditional
--   sort 1 (existing row): DEAL_DAMAGE 40, unconditional
--   sort 2 (new row):      DEAL_DAMAGE 40, only when target.has_status = POISON
-- cn_ability freezes the target snapshot before dispatch (see its own
-- header), so sort 2's condition reads whether the target was ALREADY
-- poisoned before this cast -- never something sort 0's own APPLY_STATUS
-- just applied in the same activation. Verified live via cn_run_effects
-- before this migration ran: a fresh target takes 40 damage and becomes
-- poisoned; an already-poisoned target takes 80 (double) and stays
-- poisoned.
--
-- Applied directly via mcp__Supabase__apply_migration
-- (name sinie_double_damage_if_poisoned) before this file was written;
-- reproduced here byte-for-byte for the migration history.

update card_effects
   set conditions = '[]'::jsonb
 where id = 'ab94e28a-fda4-43d8-9082-acab48a3719a'; -- APPLY_STATUS POISON, sort 0

update card_effects
   set conditions = '[]'::jsonb
 where id = '1ae2797e-a606-4f6e-9254-4040df2d5fa1'; -- DEAL_DAMAGE 40, sort 1

insert into card_effects (card_id, sort, group_id, trigger, target_selector, action, value, range_kind, conditions)
select id, 2, '5f49b4ef-6ccc-49b8-a01d-224c1ac106e1', 'ON_ABILITY', 'THE_TARGET', 'DEAL_DAMAGE', 40, 'CARD_RANGE',
       '[{"field": "target.has_status", "op": "=", "value": "POISON"}]'::jsonb
  from cards where slug = 'sinie';
