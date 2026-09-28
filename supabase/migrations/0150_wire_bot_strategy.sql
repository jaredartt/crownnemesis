-- 0150_wire_bot_strategy.sql
--
-- Wires the 0149 `cn_bot_strategy_bonus` function into `bot_step`'s actual
-- scoring, so the Expert-level (v_lvl = 3) card-specific doctrines
-- (Wuzu's 25-damage charge gate, Eva's protect-and-heal positioning,
-- Umiro's solo roam, Mako/Lumea's choke-point blocking, Dione & Grifo's
-- solo infiltration, Dorme's hold-back-then-counter, Himanta's stun
-- doctrine) actually influence bot play instead of sitting unused.
--
-- Jared: "Train it right now, make it as invincible as possible with all
-- these strategies that I've talked about and your strategies too."
--
-- Approach: same safe-splice pattern as 0148 (bot_step_abilities) --
-- fetch the exact live source via pg_get_functiondef, apply a sequence of
-- text replace() calls each guarded by a `raise exception` check that the
-- anchor text was actually found and unique, then execute the patched
-- definition. Six splices:
--   1. declare `v_strat numeric;`
--   2. move-candidate scoring: + v_strat term
--   3. attack-candidate scoring (v_best AND v_fb, both the "best of all
--      units" and "fallback if nothing else is legal" tracks): + v_strat
--   4-6. the three scripted-ability sub-branches (no-target /
--      THE_TARGET-loop / BOARD_CELL-loop): each gets its own v_strat
--      computed against that specific candidate target/tile, then added.
-- `cn_bot_strategy_bonus` is purely additive and only ever nudges ties or
-- near-ties toward each card's doctrine -- it never overrides a play the
-- underlying engine-simulated scoring (0148) already found clearly better,
-- since a strong tactical play (a lethal hit, a game-saving heal) still
-- dwarfs these bonuses in magnitude.

do $$
declare
  v_def text;
  v_before text;
begin
  v_def := pg_get_functiondef('public.bot_step(uuid,text)'::regprocedure);

  -- 1. declare v_strat
  v_before := v_def;
  v_def := replace(v_def,
    E'  v_bkind text; v_fkind text;\nbegin',
    E'  v_bkind text; v_fkind text; v_strat numeric;\nbegin');
  if v_def = v_before then
    raise exception '0150 splice 1 (declare v_strat) anchor not found';
  end if;

  -- 2. move-candidate scoring
  v_before := v_def;
  v_def := replace(v_def,
    E'        v_step_s := v_pos - v_base + v_noise\n          - v_thr * coalesce((v_w->>\'threat_mult\')::numeric, case when v_lvl >= 3 then 4.0 else 0 end);',
    E'        v_strat := case when v_lvl = 3 then cn_bot_strategy_bonus(st, p_side, u, \'move\', vx, vy, null) else 0 end;\n        v_step_s := v_pos - v_base + v_noise + v_strat\n          - v_thr * coalesce((v_w->>\'threat_mult\')::numeric, case when v_lvl >= 3 then 4.0 else 0 end);');
  if v_def = v_before then
    raise exception '0150 splice 2 (move scoring) anchor not found';
  end if;

  -- 3. attack-candidate scoring (v_best + v_fb tracks together)
  v_before := v_def;
  v_def := replace(v_def,
    E'        v_noise := random() * v_noise_scale;\n        if v_pos + v_act - v_base + v_noise > v_best then\n          v_best := v_pos + v_act - v_base + v_noise;\n          v_bu := u->>\'id\'; v_bx := vx; v_by := vy; v_bt := t->>\'id\'; v_bkind := \'attack\';\n        end if;\n        if v_pos + v_act - v_base + v_noise > v_fb then\n          v_fb := v_pos + v_act - v_base + v_noise;\n          v_fu := u->>\'id\'; v_fbx := vx; v_fby := vy; v_ft := t->>\'id\'; v_fkind := \'attack\';\n        end if;\n      end loop;',
    E'        v_noise := random() * v_noise_scale;\n        v_strat := case when v_lvl = 3 then cn_bot_strategy_bonus(st, p_side, u, \'attack\', vx, vy, t->>\'id\') else 0 end;\n        if v_pos + v_act - v_base + v_noise + v_strat > v_best then\n          v_best := v_pos + v_act - v_base + v_noise + v_strat;\n          v_bu := u->>\'id\'; v_bx := vx; v_by := vy; v_bt := t->>\'id\'; v_bkind := \'attack\';\n        end if;\n        if v_pos + v_act - v_base + v_noise + v_strat > v_fb then\n          v_fb := v_pos + v_act - v_base + v_noise + v_strat;\n          v_fu := u->>\'id\'; v_fbx := vx; v_fby := vy; v_ft := t->>\'id\'; v_fkind := \'attack\';\n        end if;\n      end loop;');
  if v_def = v_before then
    raise exception '0150 splice 3 (attack scoring) anchor not found';
  end if;

  -- 4. scripted ability, no-target branch
  v_before := v_def;
  v_def := replace(v_def,
    E'            v_ab_score := cn_bot_score_ability(st, p_side, u, null, v_w);\n            if v_ab_score is not null then\n              v_step_s := v_pos + v_ab_score - v_base + random() * v_noise_scale;',
    E'            v_ab_score := cn_bot_score_ability(st, p_side, u, null, v_w);\n            if v_ab_score is not null then\n              v_strat := case when v_lvl = 3 then cn_bot_strategy_bonus(st, p_side, u, \'ability\', vx, vy, null) else 0 end;\n              v_step_s := v_pos + v_ab_score - v_base + random() * v_noise_scale + v_strat;');
  if v_def = v_before then
    raise exception '0150 splice 4 (ability no-target) anchor not found';
  end if;

  -- 5. scripted ability, THE_TARGET loop
  v_before := v_def;
  v_def := replace(v_def,
    E'                v_ab_score := cn_bot_score_ability(st, p_side, u, t2->>\'id\', v_w);\n                if v_ab_score is not null then\n                  v_step_s := v_pos + v_ab_score - v_base + random() * v_noise_scale;',
    E'                v_ab_score := cn_bot_score_ability(st, p_side, u, t2->>\'id\', v_w);\n                if v_ab_score is not null then\n                  v_strat := case when v_lvl = 3 then cn_bot_strategy_bonus(st, p_side, u, \'ability\', vx, vy, t2->>\'id\') else 0 end;\n                  v_step_s := v_pos + v_ab_score - v_base + random() * v_noise_scale + v_strat;');
  if v_def = v_before then
    raise exception '0150 splice 5 (ability THE_TARGET) anchor not found';
  end if;

  -- 6. scripted ability, BOARD_CELL loop
  v_before := v_def;
  v_def := replace(v_def,
    E'                v_ab_score := cn_bot_score_ability(st, p_side, u, v_ab_tile, v_w);\n                if v_ab_score is not null then\n                  v_step_s := v_pos + v_ab_score - v_base + random() * v_noise_scale;',
    E'                v_ab_score := cn_bot_score_ability(st, p_side, u, v_ab_tile, v_w);\n                if v_ab_score is not null then\n                  v_strat := case when v_lvl = 3 then cn_bot_strategy_bonus(st, p_side, u, \'ability\', vx, vy, v_ab_tile) else 0 end;\n                  v_step_s := v_pos + v_ab_score - v_base + random() * v_noise_scale + v_strat;');
  if v_def = v_before then
    raise exception '0150 splice 6 (ability BOARD_CELL) anchor not found';
  end if;

  execute v_def;
end
$$;
