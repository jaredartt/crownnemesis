-- Jared, looking at AdminEffects.tsx's two checklists ("When burn actually
-- hurts" / "What stun actually disables"): "I need to check or uncheck
-- these things, it shouldn't be just informative, you know?"
--
-- Those two tables were pure documentation -- five/four rows of hardcoded
-- fact, traced through the SQL once and then frozen in a comment. This
-- makes every row a real switch: nine new app_settings booleans (same
-- shape as poison_pct/burn_pct -- a column on the singleton, read fresh by
-- a small helper, no redeploy needed), defaulting to exactly what the
-- checklists already said was true today, so flipping nothing changes
-- nothing:
--
--   burn_on_attack   = true   burn_on_ability = true
--   burn_on_move     = false  burn_on_defend  = false  burn_on_pass = false
--   stun_blocks_attack/ability/move/defend = true (all four)
--
-- cn_burn_applies(kind) / cn_stun_blocks(kind) are the two helpers every
-- gate below reads, 'attack'/'ability'/'move'/'defend'/'pass' for burn,
-- the same four minus 'pass' for stun.
--
-- WHAT'S NEW, NOT JUST GATED: burn_on_move/defend/pass didn't exist as
-- mechanics at all before this -- turning them on adds a real cost that
-- wasn't there. Two different shapes, on purpose:
--
--  * MOVE and DEFEND: capped so it can never kill (floored at 1 hp). cn_move
--    and cn_defend have none of cn_attack's death/burial/win-check
--    plumbing, and cn_move_royale/cn_defend_royale don't even have that
--    plumbing to borrow -- a lethal burn cost here would mean teaching two
--    more functions per mode how a unit dies, for a toggle that defaults
--    off. A capped, always-survivable tick sidesteps that honestly rather
--    than half-implementing it.
--  * PASS: mirrors poison's own per-turn tick in advance_turn exactly, cost
--    for cost, including that a tick that drops a unit to 0 just quietly
--    leaves it out of out_u -- the same thing poison's tick already does,
--    unchanged since long before this migration. Full death, same as
--    poison. 1v1 only: advance_turn_royale has no tick loop of any kind
--    (poison doesn't tick there either, today), and building one from
--    scratch -- with its own royale_players elimination bookkeeping -- is
--    a bigger change than "wire up a toggle." burn_on_pass has no effect
--    in battle royale until that exists.
--
-- STUN gets no new mechanic, only new gates on checks that already exist
-- in cn_attack/cn_attack_royale/cn_move/cn_move_royale/cn_defend/
-- cn_defend_royale/cn_ability -- every one of them already refuses with
-- 'that unit is stunned' today; this only makes the refusal conditional.
-- cn_ability_royale gets the same gate for consistency even though royale
-- abilities have no burn cost to pair it with.
--
-- ONE DELIBERATE GAP: cn_ability_royale has never charged its caster burn
-- at all (cn_ability, the 1v1 version, always has) -- burn_on_ability has
-- no effect on a royale ability cast today. Adding that cost from scratch
-- would mean replicating cn_ability's v_killed_self/cn_bury/cn_win_after_
-- death handling inside a function that currently has none of it -- out of
-- scope for a toggle that (like every "on" default here) starts equal to
-- what already happens.
--
-- BOT SAFETY: bot_step calls cn_move/cn_attack/cn_ability directly, no
-- try/catch. It used to blanket-skip any stunned unit (migration 0151);
-- that's now three separate gates -- reach tiles only extend past the
-- unit's own square when stun doesn't block move, the attack-scoring loop
-- only runs when stun doesn't block attack, the ability block's own
-- pre-existing stun check gets the same "unless the toggle says
-- otherwise" -- so the bot never scores, and therefore never attempts, an
-- action the real function would then refuse. Never calls cn_defend, so
-- stun_blocks_defend needs no bot-side wiring.
--
-- Verified live (all four throwaway, cleaned up after): burn_on_move=true
-- on a burned unit that only moves now costs it damage floored at 1 hp
-- (never destroys it); stun_blocks_attack=false lets a stunned unit attack
-- (cn_attack no longer raises); default settings (everything back to the
-- checklist's original values) reproduce the exact pre-migration behavior
-- byte for byte; bot_step run several turns with a mixed toggle set
-- (stun blocks move but not attack) never raised an uncaught exception.

alter table public.app_settings
  add column if not exists burn_on_attack   boolean not null default true,
  add column if not exists burn_on_ability  boolean not null default true,
  add column if not exists burn_on_move     boolean not null default false,
  add column if not exists burn_on_defend   boolean not null default false,
  add column if not exists burn_on_pass     boolean not null default false,
  add column if not exists stun_blocks_attack  boolean not null default true,
  add column if not exists stun_blocks_ability boolean not null default true,
  add column if not exists stun_blocks_move    boolean not null default true,
  add column if not exists stun_blocks_defend  boolean not null default true;

create or replace function public.cn_burn_applies(p_kind text)
returns boolean
language sql stable
as $$
  select case p_kind
    when 'attack'  then coalesce((select burn_on_attack  from public.app_settings where id), true)
    when 'ability' then coalesce((select burn_on_ability from public.app_settings where id), true)
    when 'move'    then coalesce((select burn_on_move    from public.app_settings where id), false)
    when 'defend'  then coalesce((select burn_on_defend  from public.app_settings where id), false)
    when 'pass'    then coalesce((select burn_on_pass    from public.app_settings where id), false)
    else true
  end
$$;

create or replace function public.cn_stun_blocks(p_kind text)
returns boolean
language sql stable
as $$
  select case p_kind
    when 'attack'  then coalesce((select stun_blocks_attack  from public.app_settings where id), true)
    when 'ability' then coalesce((select stun_blocks_ability from public.app_settings where id), true)
    when 'move'    then coalesce((select stun_blocks_move    from public.app_settings where id), true)
    when 'defend'  then coalesce((select stun_blocks_defend  from public.app_settings where id), true)
    else true
  end
$$;

do $$
declare
  v_def text;
  v_before text;
begin
  -- ===================== cn_attack =====================
  v_def := pg_get_functiondef('public.cn_attack(uuid,text,text,text)'::regprocedure);

  v_before := v_def;
  v_def := replace(v_def,
    E'  if cn_stunned(v_atk) then raise exception \'that unit is stunned\'; end if;\n',
    E'  if cn_stun_blocks(\'attack\') and cn_stunned(v_atk) then raise exception \'that unit is stunned\'; end if;\n');
  if v_def = v_before then raise exception '0157 splice (cn_attack stun) anchor not found'; end if;

  v_before := v_def;
  v_def := replace(v_def,
    E'    if cn_has(v_atk, \'burn\') then\n',
    E'    if cn_burn_applies(\'attack\') and cn_has(v_atk, \'burn\') then\n');
  if v_def = v_before then raise exception '0157 splice (cn_attack tree burn) anchor not found'; end if;

  v_before := v_def;
  v_def := replace(v_def,
    E'      if cn_has(v_tgt, \'burn\') then\n',
    E'      if cn_burn_applies(\'attack\') and cn_has(v_tgt, \'burn\') then\n');
  if v_def = v_before then raise exception '0157 splice (cn_attack quick dagger burn) anchor not found'; end if;

  v_before := v_def;
  v_def := replace(v_def,
    E'      if cn_has(v_strk, \'burn\') then\n',
    E'      if cn_burn_applies(\'attack\') and cn_has(v_strk, \'burn\') then\n');
  if v_def = v_before then raise exception '0157 splice (cn_attack chain burn) anchor not found'; end if;

  execute v_def;

  -- ===================== cn_attack_royale =====================
  v_def := pg_get_functiondef('public.cn_attack_royale(uuid,int,text,text)'::regprocedure);

  v_before := v_def;
  v_def := replace(v_def,
    E'  if cn_stunned(v_atk) then raise exception \'that unit is stunned\'; end if;\n',
    E'  if cn_stun_blocks(\'attack\') and cn_stunned(v_atk) then raise exception \'that unit is stunned\'; end if;\n');
  if v_def = v_before then raise exception '0157 splice (cn_attack_royale stun) anchor not found'; end if;

  v_before := v_def;
  v_def := replace(v_def,
    E'    if cn_has(v_atk, \'burn\') then\n',
    E'    if cn_burn_applies(\'attack\') and cn_has(v_atk, \'burn\') then\n');
  if v_def = v_before then raise exception '0157 splice (cn_attack_royale tree burn) anchor not found'; end if;

  v_before := v_def;
  v_def := replace(v_def,
    E'      if cn_has(v_tgt, \'burn\') then\n',
    E'      if cn_burn_applies(\'attack\') and cn_has(v_tgt, \'burn\') then\n');
  if v_def = v_before then raise exception '0157 splice (cn_attack_royale quick dagger burn) anchor not found'; end if;

  v_before := v_def;
  v_def := replace(v_def,
    E'      if cn_has(v_strk, \'burn\') then\n',
    E'      if cn_burn_applies(\'attack\') and cn_has(v_strk, \'burn\') then\n');
  if v_def = v_before then raise exception '0157 splice (cn_attack_royale chain burn) anchor not found'; end if;

  execute v_def;

  -- ===================== cn_move =====================
  v_def := pg_get_functiondef('public.cn_move(uuid,text,text,int,int)'::regprocedure);

  v_before := v_def;
  v_def := replace(v_def,
    E'  v_reach text[]; v_felled boolean := false;\n  v_win text; v_gale jsonb; v_left int;\n',
    E'  v_reach text[]; v_felled boolean := false;\n  v_win text; v_gale jsonb; v_left int; v_burn_mv int := 0;\n');
  if v_def = v_before then raise exception '0157 splice (cn_move declare) anchor not found'; end if;

  v_before := v_def;
  v_def := replace(v_def,
    E'  if cn_stunned(v_me) then raise exception \'that unit is stunned\'; end if;\n',
    E'  if cn_stun_blocks(\'move\') and cn_stunned(v_me) then raise exception \'that unit is stunned\'; end if;\n');
  if v_def = v_before then raise exception '0157 splice (cn_move stun) anchor not found'; end if;

  v_before := v_def;
  v_def := replace(v_def,
    E'    if u->>\'id\' = p_unit then\n      u := jsonb_set(jsonb_set(u, \'{x}\', to_jsonb(p_x)), \'{y}\', to_jsonb(p_y));\n      u := jsonb_set(u, \'{moved}\', \'true\'::jsonb);\n      if coalesce((u->>\'defending\')::boolean, false)\n         and not coalesce((u->>\'defendedSelf\')::boolean, false) then\n        u := jsonb_set(u, \'{defending}\', \'false\'::jsonb);\n        u := (u - \'defendedBy\') - \'defendedSelf\';\n      end if;\n    end if;',
    E'    if u->>\'id\' = p_unit then\n      u := jsonb_set(jsonb_set(u, \'{x}\', to_jsonb(p_x)), \'{y}\', to_jsonb(p_y));\n      u := jsonb_set(u, \'{moved}\', \'true\'::jsonb);\n      if coalesce((u->>\'defending\')::boolean, false)\n         and not coalesce((u->>\'defendedSelf\')::boolean, false) then\n        u := jsonb_set(u, \'{defending}\', \'false\'::jsonb);\n        u := (u - \'defendedBy\') - \'defendedSelf\';\n      end if;\n      if cn_burn_applies(\'move\') and cn_has(v_me, \'burn\') then\n        v_burn_mv := least(cn_effect_dmg(v_st, v_me, cn_burn_pct()), greatest(0, (v_me->>\'hp\')::int - 1));\n        if v_burn_mv > 0 then\n          u := jsonb_set(u, \'{hp}\', to_jsonb((v_me->>\'hp\')::int - v_burn_mv));\n        end if;\n      end if;\n    end if;');
  if v_def = v_before then raise exception '0157 splice (cn_move loop) anchor not found'; end if;

  v_before := v_def;
  v_def := replace(v_def,
    E'  v_st := jsonb_set(v_st, \'{obstacles}\', v_rocks);\n  v_st := state_log(v_st, (v_me->>\'name\') || \' advances.\');',
    E'  v_st := jsonb_set(v_st, \'{obstacles}\', v_rocks);\n  if v_burn_mv > 0 then\n    v_st := state_log(v_st, (v_me->>\'name\') || \' burns for \' || v_burn_mv || \' on the move.\');\n  end if;\n  v_st := state_log(v_st, (v_me->>\'name\') || \' advances.\');');
  if v_def = v_before then raise exception '0157 splice (cn_move log) anchor not found'; end if;

  execute v_def;

  -- ===================== cn_move_royale =====================
  v_def := pg_get_functiondef('public.cn_move_royale(uuid,int,text,int,int)'::regprocedure);

  v_before := v_def;
  v_def := replace(v_def,
    E'  v_reach text[]; v_felled boolean := false;\nbegin',
    E'  v_reach text[]; v_felled boolean := false; v_burn_mv int := 0;\nbegin');
  if v_def = v_before then raise exception '0157 splice (cn_move_royale declare) anchor not found'; end if;

  v_before := v_def;
  v_def := replace(v_def,
    E'  if cn_stunned(v_me) then raise exception \'that unit is stunned\'; end if;\n',
    E'  if cn_stun_blocks(\'move\') and cn_stunned(v_me) then raise exception \'that unit is stunned\'; end if;\n');
  if v_def = v_before then raise exception '0157 splice (cn_move_royale stun) anchor not found'; end if;

  v_before := v_def;
  v_def := replace(v_def,
    E'    if u->>\'id\' = p_unit then\n      u := jsonb_set(jsonb_set(u, \'{x}\', to_jsonb(p_x)), \'{y}\', to_jsonb(p_y));\n      u := jsonb_set(u, \'{moved}\', \'true\'::jsonb);\n      if coalesce((u->>\'defending\')::boolean, false)\n         and not coalesce((u->>\'defendedSelf\')::boolean, false) then\n        u := jsonb_set(u, \'{defending}\', \'false\'::jsonb);\n        u := (u - \'defendedBy\') - \'defendedSelf\';\n      end if;\n    end if;',
    E'    if u->>\'id\' = p_unit then\n      u := jsonb_set(jsonb_set(u, \'{x}\', to_jsonb(p_x)), \'{y}\', to_jsonb(p_y));\n      u := jsonb_set(u, \'{moved}\', \'true\'::jsonb);\n      if coalesce((u->>\'defending\')::boolean, false)\n         and not coalesce((u->>\'defendedSelf\')::boolean, false) then\n        u := jsonb_set(u, \'{defending}\', \'false\'::jsonb);\n        u := (u - \'defendedBy\') - \'defendedSelf\';\n      end if;\n      if cn_burn_applies(\'move\') and cn_has(v_me, \'burn\') then\n        v_burn_mv := least(cn_effect_dmg(v_st, v_me, cn_burn_pct()), greatest(0, (v_me->>\'hp\')::int - 1));\n        if v_burn_mv > 0 then\n          u := jsonb_set(u, \'{hp}\', to_jsonb((v_me->>\'hp\')::int - v_burn_mv));\n        end if;\n      end if;\n    end if;');
  if v_def = v_before then raise exception '0157 splice (cn_move_royale loop) anchor not found'; end if;

  v_before := v_def;
  v_def := replace(v_def,
    E'  v_st := jsonb_set(v_st, \'{obstacles}\', v_rocks);\n  v_st := state_log(v_st, (v_me->>\'name\') || \' advances.\');',
    E'  v_st := jsonb_set(v_st, \'{obstacles}\', v_rocks);\n  if v_burn_mv > 0 then\n    v_st := state_log(v_st, (v_me->>\'name\') || \' burns for \' || v_burn_mv || \' on the move.\');\n  end if;\n  v_st := state_log(v_st, (v_me->>\'name\') || \' advances.\');');
  if v_def = v_before then raise exception '0157 splice (cn_move_royale log) anchor not found'; end if;

  execute v_def;

  -- ===================== cn_defend (4-arg) =====================
  v_def := pg_get_functiondef('public.cn_defend(uuid,text,text,text)'::regprocedure);

  v_before := v_def;
  v_def := replace(v_def,
    E'  v_out jsonb := \'[]\'::jsonb; v_rocks jsonb := \'[]\'::jsonb;\n  v_note text;\nbegin',
    E'  v_out jsonb := \'[]\'::jsonb; v_rocks jsonb := \'[]\'::jsonb;\n  v_note text; v_burn_df int := 0;\nbegin');
  if v_def = v_before then raise exception '0157 splice (cn_defend declare) anchor not found'; end if;

  v_before := v_def;
  v_def := replace(v_def,
    E'  if cn_stunned(v_me) then raise exception \'that unit is stunned\'; end if;\n',
    E'  if cn_stun_blocks(\'defend\') and cn_stunned(v_me) then raise exception \'that unit is stunned\'; end if;\n');
  if v_def = v_before then raise exception '0157 splice (cn_defend stun) anchor not found'; end if;

  v_before := v_def;
  v_def := replace(v_def,
    E'    if u->>\'id\' = p_unit then\n      u := jsonb_set(u, \'{acted}\', \'true\'::jsonb);\n    end if;\n    if u->>\'id\' = v_target_id then',
    E'    if u->>\'id\' = p_unit then\n      u := jsonb_set(u, \'{acted}\', \'true\'::jsonb);\n      if cn_burn_applies(\'defend\') and cn_has(v_me, \'burn\') then\n        v_burn_df := least(cn_effect_dmg(v_st, v_me, cn_burn_pct()), greatest(0, (v_me->>\'hp\')::int - 1));\n        if v_burn_df > 0 then\n          u := jsonb_set(u, \'{hp}\', to_jsonb((v_me->>\'hp\')::int - v_burn_df));\n        end if;\n      end if;\n    end if;\n    if u->>\'id\' = v_target_id then');
  if v_def = v_before then raise exception '0157 splice (cn_defend loop) anchor not found'; end if;

  v_before := v_def;
  v_def := replace(v_def,
    E'  v_st := jsonb_set(v_st, \'{units}\', v_out);\n\n  if v_tgt_obj is not null then',
    E'  v_st := jsonb_set(v_st, \'{units}\', v_out);\n  if v_burn_df > 0 then\n    v_st := state_log(v_st, (v_me->>\'name\') || \' burns for \' || v_burn_df || \' while guarding.\');\n  end if;\n\n  if v_tgt_obj is not null then');
  if v_def = v_before then raise exception '0157 splice (cn_defend log) anchor not found'; end if;

  execute v_def;

  -- ===================== cn_defend_royale (4-arg) =====================
  v_def := pg_get_functiondef('public.cn_defend_royale(uuid,int,text,text)'::regprocedure);

  v_before := v_def;
  v_def := replace(v_def,
    E'  v_target_id text; v_dist int; v_out jsonb := \'[]\'::jsonb;\nbegin',
    E'  v_target_id text; v_dist int; v_out jsonb := \'[]\'::jsonb; v_burn_df int := 0;\nbegin');
  if v_def = v_before then raise exception '0157 splice (cn_defend_royale declare) anchor not found'; end if;

  v_before := v_def;
  v_def := replace(v_def,
    E'  if cn_stunned(v_me) then raise exception \'that unit is stunned\'; end if;\n',
    E'  if cn_stun_blocks(\'defend\') and cn_stunned(v_me) then raise exception \'that unit is stunned\'; end if;\n');
  if v_def = v_before then raise exception '0157 splice (cn_defend_royale stun) anchor not found'; end if;

  v_before := v_def;
  v_def := replace(v_def,
    E'    if u->>\'id\' = p_unit then u := jsonb_set(u, \'{acted}\', \'true\'::jsonb); end if;\n    if u->>\'id\' = v_target_id then',
    E'    if u->>\'id\' = p_unit then\n      u := jsonb_set(u, \'{acted}\', \'true\'::jsonb);\n      if cn_burn_applies(\'defend\') and cn_has(v_me, \'burn\') then\n        v_burn_df := least(cn_effect_dmg(v_st, v_me, cn_burn_pct()), greatest(0, (v_me->>\'hp\')::int - 1));\n        if v_burn_df > 0 then\n          u := jsonb_set(u, \'{hp}\', to_jsonb((v_me->>\'hp\')::int - v_burn_df));\n        end if;\n      end if;\n    end if;\n    if u->>\'id\' = v_target_id then');
  if v_def = v_before then raise exception '0157 splice (cn_defend_royale loop) anchor not found'; end if;

  v_before := v_def;
  v_def := replace(v_def,
    E'  v_st := jsonb_set(v_st, \'{units}\', v_out);\n  v_st := cn_end_act_royale(v_st, p_unit);',
    E'  v_st := jsonb_set(v_st, \'{units}\', v_out);\n  if v_burn_df > 0 then\n    v_st := state_log(v_st, (v_me->>\'name\') || \' burns for \' || v_burn_df || \' while guarding.\');\n  end if;\n  v_st := cn_end_act_royale(v_st, p_unit);');
  if v_def = v_before then raise exception '0157 splice (cn_defend_royale log) anchor not found'; end if;

  execute v_def;

  -- ===================== cn_ability =====================
  v_def := pg_get_functiondef('public.cn_ability(uuid,text,text,text)'::regprocedure);

  v_before := v_def;
  v_def := replace(v_def,
    E'  if cn_stunned(v_me) then raise exception \'that unit is stunned\'; end if;\n',
    E'  if cn_stun_blocks(\'ability\') and cn_stunned(v_me) then raise exception \'that unit is stunned\'; end if;\n');
  if v_def = v_before then raise exception '0157 splice (cn_ability stun) anchor not found'; end if;

  v_before := v_def;
  v_def := replace(v_def,
    E'      if cn_has(v_me, \'burn\') then\n',
    E'      if cn_burn_applies(\'ability\') and cn_has(v_me, \'burn\') then\n');
  if v_def = v_before then raise exception '0157 splice (cn_ability burn) anchor not found'; end if;

  execute v_def;

  -- ===================== cn_ability_royale =====================
  v_def := pg_get_functiondef('public.cn_ability_royale(uuid,int,text,text)'::regprocedure);

  v_before := v_def;
  v_def := replace(v_def,
    E'  if cn_stunned(v_me) then raise exception \'that unit is stunned\'; end if;\n',
    E'  if cn_stun_blocks(\'ability\') and cn_stunned(v_me) then raise exception \'that unit is stunned\'; end if;\n');
  if v_def = v_before then raise exception '0157 splice (cn_ability_royale stun) anchor not found'; end if;

  execute v_def;

  -- ===================== advance_turn (burn-on-pass tick) =====================
  v_def := pg_get_functiondef('public.advance_turn(uuid,text,boolean)'::regprocedure);

  v_before := v_def;
  v_def := replace(v_def,
    E'    if u->>\'owner\' = v_next and cn_has(u, \'poison\') and (u->>\'hp\')::int > 0 then\n      v_hurt := cn_effect_dmg(st, u, cn_poison_pct());\n      u := jsonb_set(u, \'{hp}\', to_jsonb((u->>\'hp\')::int - v_hurt));\n      st := state_log(st, (u->>\'name\') || \' takes \' || v_hurt || \' from the poison.\');\n    end if;',
    E'    if u->>\'owner\' = v_next and cn_has(u, \'poison\') and (u->>\'hp\')::int > 0 then\n      v_hurt := cn_effect_dmg(st, u, cn_poison_pct());\n      u := jsonb_set(u, \'{hp}\', to_jsonb((u->>\'hp\')::int - v_hurt));\n      st := state_log(st, (u->>\'name\') || \' takes \' || v_hurt || \' from the poison.\');\n    end if;\n\n    if cn_burn_applies(\'pass\') and u->>\'owner\' = v_next and cn_has(u, \'burn\') and (u->>\'hp\')::int > 0 then\n      v_hurt := cn_effect_dmg(st, u, cn_burn_pct());\n      u := jsonb_set(u, \'{hp}\', to_jsonb((u->>\'hp\')::int - v_hurt));\n      st := state_log(st, (u->>\'name\') || \' burns for \' || v_hurt || \'.\');\n    end if;');
  if v_def = v_before then raise exception '0157 splice (advance_turn pass tick) anchor not found'; end if;

  execute v_def;

  -- ===================== bot_step =====================
  v_def := pg_get_functiondef('public.bot_step(uuid,text)'::regprocedure);

  v_before := v_def;
  v_def := replace(v_def,
    E'    continue when (u->>\'moved\')::boolean and (u->>\'acted\')::boolean;\n    continue when cn_stunned(u);\n    continue when coalesce((u->>\'spent\')::boolean, false);',
    E'    continue when (u->>\'moved\')::boolean and (u->>\'acted\')::boolean;\n    continue when coalesce((u->>\'spent\')::boolean, false);');
  if v_def = v_before then raise exception '0157 splice (bot_step blanket stun) anchor not found'; end if;

  v_before := v_def;
  v_def := replace(v_def,
    E'    v_tiles := array[(u->>\'x\') || \',\' || (u->>\'y\')];\n    if not (u->>\'moved\')::boolean then\n      v_tiles := v_tiles || cn_reach(st, u);\n    end if;',
    E'    v_tiles := array[(u->>\'x\') || \',\' || (u->>\'y\')];\n    if not (u->>\'moved\')::boolean and (not cn_stunned(u) or not cn_stun_blocks(\'move\')) then\n      v_tiles := v_tiles || cn_reach(st, u);\n    end if;');
  if v_def = v_before then raise exception '0157 splice (bot_step tiles) anchor not found'; end if;

  v_before := v_def;
  v_def := replace(v_def,
    E'      continue when (u->>\'acted\')::boolean;\n\n      for t in select * from jsonb_array_elements(st->\'units\') loop\n        continue when t->>\'id\' = u->>\'id\';',
    E'      continue when (u->>\'acted\')::boolean;\n\n      if not cn_stunned(u) or not cn_stun_blocks(\'attack\') then\n      for t in select * from jsonb_array_elements(st->\'units\') loop\n        continue when t->>\'id\' = u->>\'id\';');
  if v_def = v_before then raise exception '0157 splice (bot_step attack open) anchor not found'; end if;

  v_before := v_def;
  v_def := replace(v_def,
    E'      end loop;\n\n      -- 0148: strategic ability use -- Jared: \"make the bot even smarter',
    E'      end loop;\n      end if;\n\n      -- 0148: strategic ability use -- Jared: \"make the bot even smarter');
  if v_def = v_before then raise exception '0157 splice (bot_step attack close) anchor not found'; end if;

  v_before := v_def;
  v_def := replace(v_def,
    E'         and not cn_stunned(u) and not cn_swamped(st, u)\n      then',
    E'         and (not cn_stunned(u) or not cn_stun_blocks(\'ability\')) and not cn_swamped(st, u)\n      then');
  if v_def = v_before then raise exception '0157 splice (bot_step ability) anchor not found'; end if;

  execute v_def;
end
$$;
