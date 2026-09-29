-- Jared: "Himanta's counters shouldn't stun."
--
-- The cyclone (Himanta's stuns-on-hit passive) fires inside cn_attack's/
-- cn_attack_royale's shared swing loop on every landed hit from a unit
-- with `stuns = true`, with no check at all for whether that particular
-- swing was the ORIGINAL blow or an answer to it (v_is_counter). That
-- made it symmetric: Himanta stunned whoever she hit whether she was the
-- one initiating, or the one countering back after being attacked --
-- exactly the asymmetry-that-shouldn't-be-symmetric Jared is pointing at
-- ("I kinda stunned someone but just in my turn, but not in his").
--
-- This adds `not v_is_counter` to the one guard, in both functions, so
-- the cyclone only ever lands on Himanta's own initiating swing (an
-- attack she starts, or the extra STRIKE TWICE beat riding that same
-- swing -- v_is_counter does not gate twicePct, only stuns) and never on
-- a counter she throws back, in either direction: not when she counters
-- someone who attacked her, and not on the "ordinary counter" half of an
-- exchange she herself started.
do $$
declare
  v_def text;
  v_before text;
begin
  v_def := pg_get_functiondef('public.cn_attack(uuid,text,text,text)'::regprocedure);
  v_before := v_def;
  v_def := replace(v_def,
    E'      if not v_missed and v_hit > 0\n         and coalesce((v_strk->>\'stuns\')::boolean, false) then',
    E'      if not v_missed and v_hit > 0 and not v_is_counter\n         and coalesce((v_strk->>\'stuns\')::boolean, false) then');
  if v_def = v_before then raise exception '0153 splice (cn_attack) anchor not found'; end if;
  execute v_def;

  v_def := pg_get_functiondef('public.cn_attack_royale(uuid,int,text,text)'::regprocedure);
  v_before := v_def;
  v_def := replace(v_def,
    E'      if not v_missed and v_hit > 0 and coalesce((v_strk->>\'stuns\')::boolean, false) then',
    E'      if not v_missed and v_hit > 0 and not v_is_counter and coalesce((v_strk->>\'stuns\')::boolean, false) then');
  if v_def = v_before then raise exception '0153 splice (cn_attack_royale) anchor not found'; end if;
  execute v_def;
end
$$;
