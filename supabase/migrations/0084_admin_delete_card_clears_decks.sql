-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice -- it only (re)defines admin_delete_card(), the
--  same function 0055 last touched.
-- ===========================================================================
--  0084 -- deleting a card no longer waits on who has it in a deck
--
--  Jared: "I want to be able to delete cards from the admin mode page even
--  if other players have them in their decks. If this is the case, that
--  deck will automatically be deleted (which I don't think it's a big deal,
--  honestly)."
--
--  0046/0055 had admin_delete_card() refuse outright when the card was
--  still in somebody's profiles.deck or in one of their saved kingdoms --
--  the admin had to go find every affected player first, which in practice
--  meant a card nobody actually wanted deleted anymore just sat there.
--
--  This still can't retroactively fix a match already in progress, so that
--  guard is unchanged. But a saved deck is just a preference, and the game
--  already knows how to cope with one going stale: deck_of() falls back to
--  default_deck() the moment a deck it would field comes up short a live
--  card (see 0024). So instead of refusing, this now does automatically
--  what an admin would otherwise have to ask each player to do by hand:
--
--    - any saved kingdom whose deck fields this card is deleted outright
--      (same as the owner hitting delete on it themselves -- a kingdom
--      missing one slot silently is a new bug, not a repair), reusing
--      cn_check_kingdoms' own dangling-selection repointing and keeping
--      profiles.deck in step, exactly like delete_kingdom() does
--    - a pre-kingdoms profile the backfill never reached, where the one
--      deck IS profiles.deck, has that column cleared
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
  k      jsonb;
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

  -- Everything below only means anything for a card that ever had a slug --
  -- the handful of pre-slug rows (retired long before 0005) were never
  -- referable by slug in the first place, so there is nothing to clean up.
  if v_slug is not null then
    -- Still on the board in a match that has not finished: the one case a
    -- hard delete genuinely cannot see and cannot fix up after the fact, so
    -- this alone still blocks.
    if exists (
      select 1 from public.matches m
      where m.status <> 'finished'
        and position(('"slug":"' || v_slug || '"') in m.state::text) > 0
    ) then
      raise exception '% is on the board in a match that has not finished yet -- it cannot be deleted until that match ends', v_name;
    end if;

    -- Every saved kingdom fielding this card, across every profile that has
    -- one, goes -- not just the card's slot in it. profiles.kingdoms/.kingdom
    -- are updated together so the profiles_kingdoms_are_sane trigger
    -- repoints a selection left dangling, the same as delete_kingdom() does
    -- for a player deleting their own.
    for r in
      select p.id as uid, coalesce(p.kingdoms, '[]'::jsonb) as kingdoms
        from public.profiles p
       where exists (
               select 1 from jsonb_array_elements(coalesce(p.kingdoms, '[]'::jsonb)) k
                where (k -> 'deck') ? v_slug)
    loop
      v_out := '[]'::jsonb;
      for k in select * from jsonb_array_elements(r.kingdoms) loop
        if not ((k -> 'deck') ? v_slug) then
          v_out := v_out || k;
        end if;
      end loop;
      update public.profiles set kingdoms = v_out where id = r.uid;
      -- profiles.deck follows the selected kingdom, never moves on its own.
      update public.profiles set deck = selected_deck(r.uid) where id = r.uid;
    end loop;

    -- A pre-kingdoms profile the backfill never reached: its one deck IS
    -- profiles.deck, so "that deck is deleted" means clearing this column.
    -- Anything the loop above already fixed no longer matches this (deck
    -- was just recomputed from a kingdom that, by construction, cannot
    -- still contain v_slug), so this only ever touches the legacy case.
    update public.profiles set deck = null where deck @> array[v_slug];
  end if;

  delete from public.cards where id = p_id;
end
$$;

revoke all on function public.admin_delete_card(uuid) from public;
grant execute on function public.admin_delete_card(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Did it work?
-- ---------------------------------------------------------------------------
select prosrc not ilike '%still in%''s selected deck%'
   and prosrc not ilike '%still in one of%''s saved kingdoms%' as no_longer_blocks_on_decks
  from pg_proc where proname = 'admin_delete_card';
