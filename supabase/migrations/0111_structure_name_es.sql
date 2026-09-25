-- 0111: a Spanish name for structures, admin-editable, structures only.
--
-- Jared, after noticing the admin structures form has Description
-- (English)/Description (Spanish) but only one plain "Name" field: "Of
-- course, but only for structures for now. Do it." -- cards keep a single
-- English-only `name` (a proper noun like "King Dereo"), and stay that way
-- per this request; only `structures.name` gets a bilingual pair, the same
-- shape as its own `description`/`description_es` (0079).
--
-- Note for whoever reads this later: today's only structure KINDS a match
-- ever actually places (tree/wall/bomb/tornado -- see lib/objects.ts's
-- objNameKey) already show a player a name from the i18n dictionary
-- (obj.tree/obj.wall/obj.bomb/obj.tornado in en.json/es.json), not from
-- this column at all -- Board.tsx's fighterInfoFor() only falls back to
-- `row.name` for a hypothetical structure kind with no dictionary key,
-- which does not exist yet. So `name`/`name_es` are, today, exactly what
-- `name` alone already was: the label admin uses to tell rows apart in
-- this screen, not (yet) anything a player sees in a match. Free-text,
-- nullable, no format constraint -- same as description_es.
alter table public.structures add column if not exists name_es text;

do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_name = 'structures' and column_name = 'name_es'
  ) then
    raise exception '0111 self-test FAILED: structures.name_es does not exist after migration';
  end if;
end $$;

-- Self-test: the column round-trips an ordinary UPDATE/SELECT with no
-- trigger in the way (structures_touch only stamps updated_at -- see this
-- migration's own header on why there is nothing to normalize here,
-- unlike cards.ability_es which cn_check_card trims).
do $$
declare v_id uuid; v_got text;
begin
  select id into v_id from public.structures limit 1;
  if v_id is null then
    raise notice '0111 self-test skipped: no structures rows exist to test against.';
  else
    update public.structures set name_es = 'Prueba 0111' where id = v_id;
    select name_es into v_got from public.structures where id = v_id;
    if v_got <> 'Prueba 0111' then
      raise exception '0111 self-test FAILED: wrote %, read back %', 'Prueba 0111', v_got;
    end if;
    update public.structures set name_es = null where id = v_id;
    raise notice '0111 self-test passed: structures.name_es round-trips and was reset to null.';
  end if;
end $$;
