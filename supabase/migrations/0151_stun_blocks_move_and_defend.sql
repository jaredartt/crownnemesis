-- Jared: "stun shouldn't allow you to defend, move, or literally anything
-- else."
--
-- cn_stunned() already blocked attacking and using an ability (cn_attack /
-- cn_attack_royale / cn_ability / cn_ability_royale all check it) -- but
-- nothing ever checked it for moving or defending. cn_move, cn_move_royale,
-- cn_defend and cn_defend_royale are the only other unit-action functions
-- in the whole schema (everything else with a p_unit parameter is either an
-- internal helper, a deployment-phase function where stun cannot exist yet,
-- or a thin submit_* wrapper that just resolves the caller's side and calls
-- straight through to one of these eight) -- so a stunned unit could always
-- move away or raise a guard, and a player watching "she's stunned" up
-- close would still see her sidestep or shield herself. This closes that
-- for good: the same 'that unit is stunned' error cn_attack already
-- raises, now on all four.
--
-- bot_step also gets `continue when cn_stunned(u);` on its per-unit loop --
-- without it, a stunned unit remained a live MOVE/ATTACK candidate there
-- (only its ABILITY branch already skipped stunned units), and now that
-- cn_move/cn_attack actually enforce the rule, the bot would raise on its
-- own candidate and stall its whole turn the moment a stunned unit scored
-- highest. Excluding it up front is what keeps the bot playing around a
-- stunned unit instead of trying to act through it.

do $$
declare
  v_def text;
  v_before text;
begin
  -- ---------------------------------------------------------------------
  -- cn_move
  -- ---------------------------------------------------------------------
  v_def := pg_get_functiondef('public.cn_move(uuid,text,text,int,int)'::regprocedure);
  v_before := v_def;
  v_def := replace(v_def,
    E'  if (v_me->>\'moved\')::boolean then raise exception \'that unit already moved\'; end if;',
    E'  if (v_me->>\'moved\')::boolean then raise exception \'that unit already moved\'; end if;\n  if cn_stunned(v_me) then raise exception \'that unit is stunned\'; end if;');
  if v_def = v_before then raise exception '0151 splice (cn_move) anchor not found'; end if;
  execute v_def;

  -- ---------------------------------------------------------------------
  -- cn_move_royale
  -- ---------------------------------------------------------------------
  v_def := pg_get_functiondef('public.cn_move_royale(uuid,int,text,int,int)'::regprocedure);
  v_before := v_def;
  v_def := replace(v_def,
    E'  if (v_me->>\'moved\')::boolean then raise exception \'that unit already moved\'; end if;',
    E'  if (v_me->>\'moved\')::boolean then raise exception \'that unit already moved\'; end if;\n  if cn_stunned(v_me) then raise exception \'that unit is stunned\'; end if;');
  if v_def = v_before then raise exception '0151 splice (cn_move_royale) anchor not found'; end if;
  execute v_def;

  -- ---------------------------------------------------------------------
  -- cn_defend (the 4-arg body -- the 3-arg overload just calls through to
  -- this one, so patching this one covers "raise a guard" for self too)
  -- ---------------------------------------------------------------------
  v_def := pg_get_functiondef('public.cn_defend(uuid,text,text,text)'::regprocedure);
  v_before := v_def;
  v_def := replace(v_def,
    E'  if (v_me->>\'acted\')::boolean then raise exception \'that unit already acted\'; end if;',
    E'  if (v_me->>\'acted\')::boolean then raise exception \'that unit already acted\'; end if;\n  if cn_stunned(v_me) then raise exception \'that unit is stunned\'; end if;');
  if v_def = v_before then raise exception '0151 splice (cn_defend) anchor not found'; end if;
  execute v_def;

  -- ---------------------------------------------------------------------
  -- cn_defend_royale (4-arg body, same reasoning)
  -- ---------------------------------------------------------------------
  v_def := pg_get_functiondef('public.cn_defend_royale(uuid,int,text,text)'::regprocedure);
  v_before := v_def;
  v_def := replace(v_def,
    E'  if (v_me->>\'acted\')::boolean then raise exception \'that unit already acted\'; end if;',
    E'  if (v_me->>\'acted\')::boolean then raise exception \'that unit already acted\'; end if;\n  if cn_stunned(v_me) then raise exception \'that unit is stunned\'; end if;');
  if v_def = v_before then raise exception '0151 splice (cn_defend_royale) anchor not found'; end if;
  execute v_def;

  -- ---------------------------------------------------------------------
  -- bot_step: never let a stunned unit be a move/attack/ability candidate
  -- in the first place, now that all three would actually raise.
  -- ---------------------------------------------------------------------
  v_def := pg_get_functiondef('public.bot_step(uuid,text)'::regprocedure);
  v_before := v_def;
  v_def := replace(v_def,
    E'    continue when (u->>\'moved\')::boolean and (u->>\'acted\')::boolean;',
    E'    continue when (u->>\'moved\')::boolean and (u->>\'acted\')::boolean;\n    continue when cn_stunned(u);');
  if v_def = v_before then raise exception '0151 splice (bot_step) anchor not found'; end if;
  execute v_def;
end
$$;
