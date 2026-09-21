-- 0079_structure_description.sql
--
-- Jared: "structures should have a description attribute so that when
-- players hover or long press, they could see the details of that
-- structure." Bilingual, same pairing cards already use for their own
-- ability text (cards.ability / cards.ability_es) -- see lib/i18n.ts's own
-- comment on why UI strings live in the repo but per-row admin-editable
-- text lives in the database instead (a balance/wording tweak rewrites this
-- every time, and that shouldn't need a deploy).
--
-- Applied live via the Supabase MCP connection before this file was
-- written (a plain additive column, unlike 0078's live function rewrite,
-- was not held back for approval the same way).
alter table public.structures
  add column if not exists description text,
  add column if not exists description_es text;
