-- Jared: "now I get 20 seconds if I move a unit, then another 20 seconds if
-- I decide to hit, then another 20 seconds if I move another, and so on.
-- Please: 20 seconds for each unit (move + attack) so 40 seconds in total!"
--
-- 0146 gave every unit action a fresh clock, but "every action" was wired
-- to "any change to state at all" (cn_refresh_action_clock fired whenever
-- new.state was distinct from old.state), so a unit's move and that SAME
-- unit's own follow-up attack each reset the clock independently -- 20s to
-- move, then another fresh 20s to decide whether to strike, and so on.
-- The intent was one budget per unit's whole go (move, then optionally
-- attack/ability/defend with the SAME unit), not one budget per action.
--
-- cn_begin_act (0019) already draws exactly that line: it bumps
-- state.acts by one only when a genuinely NEW unit's go starts, and
-- returns early -- acts left untouched -- when the SAME already-active
-- unit continues (e.g. attacking right after its own move). So "acts
-- changed" IS "a new unit's go started". Key the refresh off that instead
-- of off any change to state, and give the fresh clock 40 seconds instead
-- of 20 -- one 40s budget per unit's go, not reset mid-go.
create or replace function public.cn_refresh_action_clock()
 returns trigger
 language plpgsql
as $function$
begin
  if new.status = 'active'
     and old.status = 'active'
     and new.state->>'turn' is not distinct from old.state->>'turn'
     and new.turn_deadline is not distinct from old.turn_deadline
     and new.state->>'acts' is distinct from old.state->>'acts'
  then
    new.turn_deadline := now() + interval '40 seconds';
  end if;
  return new;
end
$function$;

-- The turn's opening deadline (before anyone has acted yet) should match
-- the same 40-second-per-go budget, since the first action taken will
-- immediately overwrite it via the trigger above anyway -- keeping them in
-- sync just means a player who studies the board a while before their
-- first move isn't timed out early relative to everyone after them.
do $$
declare def text; v_before text;
begin
  def := pg_get_functiondef('public.advance_turn(uuid,text,boolean)'::regprocedure);
  v_before := def;
  def := replace(def,
    'turn_deadline = now() + interval ''20 seconds'', updated_at = now()',
    'turn_deadline = now() + interval ''40 seconds'', updated_at = now()');
  if def = v_before then raise exception '0163: advance_turn -- target text not found'; end if;
  execute def;

  def := pg_get_functiondef('public.cn_set_ready(uuid,text,boolean)'::regprocedure);
  v_before := def;
  def := replace(def,
    'turn_deadline = now() + interval ''20 seconds'', updated_at = now()',
    'turn_deadline = now() + interval ''40 seconds'', updated_at = now()');
  if def = v_before then raise exception '0163: cn_set_ready -- target text not found'; end if;
  execute def;
end $$;

-- cn_ability used to unconditionally reset the clock to a fresh 20s (plus
-- cinematic time) on EVERY use, including a use that only continues a unit's
-- already-open go -- exactly the per-action reset Jared is asking to
-- remove, and a path the trigger fix above can't reach on its own because
-- cn_ability was setting turn_deadline itself. Switch it to the same
-- two-step pattern cn_attack/submit_attack already use elsewhere in this
-- file: first write the state with turn_deadline left alone, so the
-- trigger above decides -- via whether state.acts changed -- whether this
-- was a new go needing a full 40s reset; then a second update that only
-- nudges the deadline forward by the ability's own cinematic time (never a
-- full reset), so a long ability animation doesn't visually eat into an
-- already-ticking clock.
do $$
declare def text; v_before text;
begin
  def := pg_get_functiondef('public.cn_ability(uuid,text,text,text)'::regprocedure);
  v_before := def;
  def := replace(def,
    'update public.matches
     set state = v_st,
         turn_deadline = now() + interval ''20 seconds''
           + (cn_cine_ms(v_swings) || '' milliseconds'')::interval,
         updated_at = now()
   where id = m.id returning * into m;
  return m;',
    'update public.matches
     set state = v_st, updated_at = now()
   where id = m.id returning * into m;

  -- Small nudge, not a reset: give the ability''s own cinematic time to
  -- play out without the clock looking like it ran out mid-animation.
  -- Whether this use opened a brand-new go (a fresh 40s) or continued the
  -- same unit''s already-open one (no reset at all) was already decided by
  -- cn_refresh_action_clock above, keyed on whether state.acts changed.
  if m.status = ''active'' and m.turn_deadline is not null then
    update public.matches
       set turn_deadline = turn_deadline
             + (cn_cine_ms(v_swings) || '' milliseconds'')::interval,
           state = m.state
     where id = m.id returning * into m;
  end if;
  return m;');
  if def = v_before then raise exception '0163: cn_ability -- target text not found'; end if;
  execute def;
end $$;
