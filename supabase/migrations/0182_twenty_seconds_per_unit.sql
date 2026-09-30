-- 0182: every unit's go gets 20 seconds, in every mode, for players and bots alike.
--
-- Jared: "make sure that in all modes, all players and bots have 20 seconds to make
-- a move for each of the 2 units they can move in a turn."
--
-- What was wrong: 0163 gave each unit's go a 40-second budget in 1v1 (so a turn
-- could take 80 s), and Battle Royale's turn clock was 30 s while the on-screen
-- bar assumed 20 s. Now there is ONE number, cn_action_seconds() = 20, used by
--   * advance_turn / cn_set_ready      the clock a turn / the match opens with
--   * cn_refresh_action_clock          the fresh clock when the NEXT unit's go starts
--                                      (state.acts changes) -- so a normal 1v1 turn is
--                                      20 s + 20 s, the opening turn (one activation)
--                                      20 s
--   * cn_royale_mark_ready             Battle Royale's first turn
--   * cn_derive_royale()               Battle Royale's later turns (its turn is ONE
--                                      activation, 0061, so its turn is 20 s)
-- The deploy clock (90 s) and the AFK / abandonment rules are unchanged.

create or replace function public.cn_action_seconds()
returns int language sql immutable as $$ select 20 $$;

do $$
declare def text; v_new text; fn text;
begin
  -- 1. the generator first, so the regeneration triggered by step 2 uses the new clock
  def := pg_get_functiondef('public.cn_derive_royale()'::regprocedure);
  v_new := replace(def, 'turn_deadline = now() + interval ''30 seconds''',
                        'turn_deadline = now() + make_interval(secs => cn_action_seconds())');
  if v_new <> def then execute v_new; end if;

  -- 2. the 1v1 functions (advance_turn's replacement fires the royale regeneration)
  for fn in select unnest(array[
      'public.cn_refresh_action_clock()',
      'public.cn_set_ready(uuid,text,boolean)',
      'public.advance_turn(uuid,text,boolean)',
      'public.cn_royale_mark_ready(uuid,integer,text)']) loop
    def := pg_get_functiondef(fn::regprocedure);
    v_new := replace(replace(def,
      'interval ''40 seconds''', 'make_interval(secs => cn_action_seconds())'),
      'turn_deadline = now() + interval ''30 seconds''',
      'turn_deadline = now() + make_interval(secs => cn_action_seconds())');
    if v_new <> def then execute v_new; end if;
  end loop;

  perform public.cn_derive_royale();
end $$;

-- Nothing that sets a turn / activation clock may still hard-code a length.
do $$
declare bad text;
begin
  select string_agg(proname, ', ') into bad from pg_proc
   where pronamespace = 'public'::regnamespace
     and proname in ('advance_turn', 'advance_turn_royale', 'cn_set_ready',
                     'cn_refresh_action_clock', 'cn_royale_mark_ready', 'cn_derive_royale')
     and (prosrc like '%interval ''40 seconds''%' or prosrc like '%turn_deadline = now() + interval ''30 seconds''%');
  if bad is not null then raise exception '0182: still hard-coded clock in: %', bad; end if;
end $$;
