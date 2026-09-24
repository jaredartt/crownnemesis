-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Destructive (drops two functions) but idempotent -- `if exists`
--  means running it twice is harmless.
-- ===========================================================================
--  0086 -- remove Wait, everywhere
--
--  Jared: "remove this option from everywhere in the game, it makes no
--  sense. If they don't want to do anything, they can end their turn as
--  usual, no need for this option!"
--
--  That instinct turns out to be exactly right, not just a preference: Wait
--  (submit_wait / submit_royale_wait) was never the only way to close out a
--  unit that moved and chose not to strike.
--
--    - cn_begin_act already closes out whatever unit was mid-go the moment
--      a DIFFERENT unit begins its own act ("Turning to a different unit
--      ends whatever the last one was in the middle of" -- see 0019).
--    - advance_turn / advance_turn_royale reset `active` to null and every
--      unit's `spent`/`moved`/`acted` flags outright when the turn ends,
--      regardless of what was left open.
--
--  So the only situation Wait covered on its own -- close this one unit
--  without picking another unit AND without ending the turn -- has no
--  actual consequence either way: nothing reads `active`/`spent` again
--  until one of those two things happens anyway. It was pure ceremony.
--
--  cn_end_act / cn_end_act_royale stay -- cn_defend and cn_defend_royale
--  call them directly (raising a guard ends the activation too), so they
--  are not dead, only the two RPCs that let a player invoke that half on
--  its own are.
-- ===========================================================================

drop function if exists public.submit_wait(uuid);
drop function if exists public.submit_royale_wait(uuid);

-- ---------------------------------------------------------------------------
-- Did it work?
-- ---------------------------------------------------------------------------
select
  to_regprocedure('public.submit_wait(uuid)') is null         as wait_is_gone,
  to_regprocedure('public.submit_royale_wait(uuid)') is null  as royale_wait_is_gone,
  to_regprocedure('public.cn_end_act(jsonb, text)') is not null
    as cn_end_act_still_here_for_defend;
