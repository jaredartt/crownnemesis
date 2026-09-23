-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice -- it only (re)defines admin_delete_card(), the
--  same function 0084 last touched.
-- ===========================================================================
--  0085 -- fix "column reference "k" is ambiguous" from 0084
--
--  0084 declared a plpgsql variable named k (`k jsonb;`) and separately used
--  k as the row alias of a nested `jsonb_array_elements(...) k` inside a SQL
--  subquery in the same function -- e.g.
--    where exists (select 1 from jsonb_array_elements(...) k
--                   where (k -> 'deck') ? v_slug)
--  Inside a plpgsql function body, a bare identifier in an embedded SQL
--  query can resolve to either a plpgsql variable or a column/alias of the
--  same name, and having both live at once is exactly what "ambiguous"
--  means -- this only showed up at CALL time (a hard delete against real
--  admin data), not at CREATE time, which is why 0084 looked fine when it
--  was applied and only broke on the first real use, from Admin -> Cards.
--
--  Fixed by not reusing the name anywhere in scope: the declared variable is
--  v_k now (also renamed in the FOR loop that used it directly), and the
--  subquery's row alias is kk. No behavior changes -- see 0084 for what this
--  function actually does.
-- ===========================================================================

create or replace function public.admin_delete_card(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_slug text;
  v_name text;
  r      record;
  v_k    jsonb;
  v_out  jsonb;
begin
  if not exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin) then
    raise exception 'only an admin can delete a card';
  end if;

  select c.slug, c.name into v_slug, v_name
    from public.cards c where c.id = p_id;
  if not found then
    raise exception 'no card with that id exists';
  end if;

  if v_slug is not null then
    if exists (
      select 1 from public.matches m
      where m.status <> 'finished'
        and position(('"slug":"' || v_slug || '"') in m.state::text) > 0
    ) then
      raise exception '% is on the board in a match that has not finished yet -- it cannot be deleted until that match ends', v_name;
    end if;

    for r in
      select p.id as uid, coalesce(p.kingdoms, '[]'::jsonb) as kingdoms
        from public.profiles p
       where exists (
               select 1 from jsonb_array_elements(coalesce(p.kingdoms, '[]'::jsonb)) kk
                where (kk -> 'deck') ? v_slug)
    loop
      v_out := '[]'::jsonb;
      for v_k in select * from jsonb_array_elements(r.kingdoms) loop
        if not ((v_k -> 'deck') ? v_slug) then
          v_out := v_out || v_k;
        end if;
      end loop;
      update public.profiles set kingdoms = v_out where id = r.uid;
      -- profiles.deck follows the selected kingdom, never moves on its own.
      update public.profiles set deck = selected_deck(r.uid) where id = r.uid;
    end loop;

    update public.profiles set deck = null where deck @> array[v_slug];
  end if;

  delete from public.cards where id = p_id;
end
$$;

revoke all on function public.admin_delete_card(uuid) from public;
grant execute on function public.admin_delete_card(uuid) to authenticated;
