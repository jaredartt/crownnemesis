-- Jared: "Let's change this: Let's give 20 seconds for each unit action
-- instead of 30 for the whole turn, so it's easier for player to
-- quantify and manage their time."
--
-- The old model: turn_deadline was set ONCE, at the start of a turn (30
-- seconds), and never touched again for an ordinary move/strike/ability/
-- defend -- so on a two-activation turn, whatever was left of that one
-- shared 30-second budget after your first action was however long you
-- had for your second. That's the "hard to quantify" part: the clock you
-- watch has no fixed relationship to the decision in front of you.
--
-- The new model: every unit action gets its own fresh 20 seconds,
-- starting the moment it's taken -- move, strike, ability or defend, in
-- any order, however many you have left this turn. Letting a single
-- 20-second window lapse still ends your turn exactly like running out
-- of the old 30 did (same idle/forfeit handling in advance_turn -- see
-- 0143 for the race fix already applied to that path).
--
-- ---- Part 1: the three call sites that already set turn_deadline by
-- hand, edited via their OWN live pg_get_functiondef() output rather
-- than retyped, so this migration cannot introduce a transcription
-- mistake into any of these (cn_ability in particular is a very large
-- function) --
--   * advance_turn      -- the deadline for a turn's FIRST action.
--   * cn_set_ready       -- same, for turn 1 of a fresh match.
--   * cn_ability         -- already extends the deadline by the
--     cinematic's own playtime so a flashy ability never eats into your
--     next window (cn_cine_ms) -- that protection is kept, just measured
--     from a full fresh 20s now instead of from whatever was left.
do $$
declare def text; v_before text;
begin
  def := pg_get_functiondef('public.advance_turn(uuid,text,boolean)'::regprocedure);
  v_before := def;
  def := replace(def,
    'turn_deadline = now() + interval ''30 seconds'', updated_at = now()',
    'turn_deadline = now() + interval ''20 seconds'', updated_at = now()');
  if def = v_before then raise exception '0146: advance_turn -- target text not found'; end if;
  execute def;

  def := pg_get_functiondef('public.cn_set_ready(uuid,text,boolean)'::regprocedure);
  v_before := def;
  def := replace(def,
    'turn_deadline = now() + interval ''30 seconds'', updated_at = now()',
    'turn_deadline = now() + interval ''20 seconds'', updated_at = now()');
  if def = v_before then raise exception '0146: cn_set_ready -- target text not found'; end if;
  execute def;

  def := pg_get_functiondef('public.cn_ability(uuid,text,text,text)'::regprocedure);
  v_before := def;
  def := replace(def,
    'turn_deadline = turn_deadline',
    'turn_deadline = now() + interval ''20 seconds''');
  if def = v_before then raise exception '0146: cn_ability -- target text not found'; end if;
  execute def;
end $$;

-- ---- Part 2: everything else (cn_move, cn_attack, cn_defend, and any
-- future action that consumes a go the same way) gets its fresh 20
-- seconds from a trigger instead of a hand-edit to each one -- those
-- functions are large and this is a single, auditable rule rather than
-- N near-identical edits scattered across them. It fires only when:
--   * the match is (and stays) 'active' -- never during deploy/finished,
--   * it is still the SAME side's turn -- a real turn change is
--     advance_turn's own job and it always sets its own fresh deadline
--     explicitly, which this must never race or override,
--   * nothing has already set turn_deadline on purpose in the very same
--     update -- cn_move's tornado-throw decision window (its own
--     cn_throw_secs() timer) and cn_throw's resume-the-original-move
--     restore both do exactly that, deliberately, and must be left alone,
--   * the board state actually changed -- so there is nothing to refill
--     the clock FOR on a no-op.
create or replace function public.cn_refresh_action_clock()
 returns trigger
 language plpgsql
as $function$
begin
  if new.status = 'active'
     and old.status = 'active'
     and new.state->>'turn' is not distinct from old.state->>'turn'
     and new.turn_deadline is not distinct from old.turn_deadline
     and new.state is distinct from old.state
  then
    new.turn_deadline := now() + interval '20 seconds';
  end if;
  return new;
end
$function$;

drop trigger if exists matches_refresh_action_clock on public.matches;
create trigger matches_refresh_action_clock
  before update on public.matches
  for each row execute function public.cn_refresh_action_clock();
