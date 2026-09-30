-- 0185: every unit's go gets 30 seconds (was 20 in 0182).
--
-- Jared: "Let's change the 20 second rule, we're changing everything back to 30
-- seconds ... Make sure that these 30 seconds rule work everywhere in the game."
--
-- 0182 put the clock length in ONE place, cn_action_seconds(); advance_turn,
-- cn_set_ready, cn_refresh_action_clock, cn_royale_mark_ready and the regenerated
-- advance_turn_royale all read it (and force_timeout, 0183, deals the next go's
-- clock from it), so changing the number is the whole server change. A normal 1v1
-- turn is now 30 s + 30 s; the opening turn and a Battle Royale turn (one
-- activation each) are 30 s. Deploy (90 s) and the AFK rules are unchanged.
create or replace function public.cn_action_seconds()
returns int language sql immutable as $$ select 30 $$;

-- Battle Royale's expiry check believed the clock 2 s late; 1v1's is 1 s (0183).
-- Same 1 s here so a spent go/turn is noticed when the timer reads 0 everywhere.
do $$
declare def text; v_new text;
begin
  def := pg_get_functiondef('public.force_timeout_royale(uuid)'::regprocedure);
  v_new := replace(def, 'now() <= m.turn_deadline + interval ''2 seconds''',
                        'now() <= m.turn_deadline + interval ''1 second''');
  if v_new <> def then execute v_new; end if;
end $$;
