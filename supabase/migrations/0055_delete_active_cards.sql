-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice -- it only (re)defines admin_delete_card(), the
--  same function 0046 created. The last statement prints a row of checks;
--  the column must say true.
-- ===========================================================================
--  0055 -- delete permanently no longer requires retiring first
--
--  0046 made admin_delete_card() refuse a card that was still `is_active`,
--  on the reasoning that deleting a card in play is "a strictly worse
--  version of retiring it." In practice that just added a step nobody
--  wanted: the admin unticks "In the game" in the form, and the delete
--  button appears immediately because AdminCards.tsx was showing it off the
--  UNSAVED draft's is_active, not the row on the server -- so clicking
--  delete right after unticking hit this function while the database still
--  had is_active = true, and it read back as "unticking did nothing."
--
--  The developer's call: delete should just delete, guarded only by the
--  confirmation dialog the client already shows, not by a retire-then-save
--  round trip first. So this drops the is_active check entirely. The three
--  checks that are NOT a style preference -- still in someone's deck, still
--  in a saved kingdom, still on the board in a match that has not finished
--  -- are unchanged, because those are the cases a hard DELETE genuinely
--  cannot see and cannot fix up, active or not.
-- ===========================================================================

create or replace function public.admin_delete_card(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_slug   text;
  v_name   text;
  v_who    text;
begin
  if not exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin) then
    raise exception 'only an admin can delete a card';
  end if;

  select c.slug, c.name into v_slug, v_name
    from public.cards c where c.id = p_id;
  if not found then
    raise exception 'no card with that id exists';
  end if;

  -- Everything below only means anything for a card that ever had a slug --
  -- the handful of pre-slug rows (retired long before 0005) were never
  -- referable by slug in the first place, so there is nothing to check.
  if v_slug is not null then
    select p.username into v_who
      from public.profiles p
      where p.deck @> array[v_slug]
      limit 1;
    if v_who is not null then
      raise exception '% is still in %''s selected deck -- it has to come out of that deck before the card can be deleted', v_name, v_who;
    end if;

    select p.username into v_who
      from public.profiles p
      where exists (
        select 1 from jsonb_array_elements(coalesce(p.kingdoms, '[]'::jsonb)) k
        where (k -> 'deck') ? v_slug
      )
      limit 1;
    if v_who is not null then
      raise exception '% is still in one of %''s saved kingdoms -- it has to come out of that deck before the card can be deleted', v_name, v_who;
    end if;

    if exists (
      select 1 from public.matches m
      where m.status <> 'finished'
        and position(('"slug":"' || v_slug || '"') in m.state::text) > 0
    ) then
      raise exception '% is on the board in a match that has not finished yet -- it cannot be deleted until that match ends', v_name;
    end if;
  end if;

  delete from public.cards where id = p_id;
end
$$;

revoke all on function public.admin_delete_card(uuid) from public;
grant execute on function public.admin_delete_card(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Did it work?
-- ---------------------------------------------------------------------------
select prosrc not ilike '%must be retired%' as no_longer_requires_retiring
  from pg_proc where proname = 'admin_delete_card';
