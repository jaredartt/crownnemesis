-- Jared, correcting my own framing: "he always can only parry parries,
-- right? Not that he can always parr[y] counters (replies), cause that's
-- a very different thing." He's right, and the code doesn't actually
-- match its own comment ("Lium catches any answer-to-a-parry aimed at
-- him") -- it uses one flag, v_is_counter, for two different things:
-- (1) "this swing is answering a PARRY that just landed" (what the
-- comment describes, what parryAll is supposed to be), and (2) "this
-- swing is the bog-standard ordinary counter-attack after a landed hit,
-- no parry involved at all" (the everyday riposte every reachable unit
-- gets). Because both set v_is_counter := true, parryAll's guaranteed
-- catch was firing on plain replies too, not only on answers-to-a-parry.
--
-- This splits them: a new v_after_parry flag, set true ONLY on the
-- parry-branch's flip (never on the ordinary-counter's flip at the
-- bottom of the loop), and parryAll's guarantee -- and the swing log's
-- 'why':'all' label -- now read v_after_parry instead of v_is_counter.
-- v_is_counter itself is untouched everywhere else (the "one ordinary
-- counter round only" exit rule, damage/notes labeling, etc. are a
-- separate concern and unaffected).
--
-- Verified live (throwaway matches, cleaned up after):
--  Test A -- Lium attacks, force_parry=never, no forcedParry anywhere:
--    his hit lands, the enemy's ORDINARY counter also lands on Lium
--    ('why':'counter', not a parry at all). parries=0, chain=2.
--  Test B -- enemy attacks Lium with both sides' forcedParry primed:
--    swing1 caught by Lium (why:'roll', his own forcedParry), swing2
--    caught by the enemy (why:'roll', their own forcedParry), swing3 --
--    a genuine answer-to-a-parry -- caught by Lium's parryAll (why:'all')
--    even with force_parry=never. parries=3, chain=4.
do $$
declare
  v_def text;
  v_before text;
begin
  -- ===================== cn_attack =====================
  v_def := pg_get_functiondef('public.cn_attack(uuid,text,text,text)'::regprocedure);

  v_before := v_def;
  v_def := replace(v_def,
    E'  v_swing_is_atk boolean := true; v_is_counter boolean := false;\n',
    E'  v_swing_is_atk boolean := true; v_is_counter boolean := false;\n  v_after_parry boolean := false;\n');
  if v_def = v_before then raise exception '0154 splice (cn_attack declare) anchor not found'; end if;

  v_before := v_def;
  v_def := replace(v_def,
    E'                        or (v_is_counter and coalesce((v_recv->>\'parryAll\')::boolean, false))\n',
    E'                        or (v_after_parry and coalesce((v_recv->>\'parryAll\')::boolean, false))\n');
  if v_def = v_before then raise exception '0154 splice (cn_attack v_parried) anchor not found'; end if;

  v_before := v_def;
  v_def := replace(v_def,
    E'        v_swing_is_atk := not v_swing_is_atk;\n        v_is_counter := true;\n        continue;\n      end if;',
    E'        v_swing_is_atk := not v_swing_is_atk;\n        v_is_counter := true;\n        v_after_parry := true;\n        continue;\n      end if;');
  if v_def = v_before then raise exception '0154 splice (cn_attack flip) anchor not found'; end if;

  v_before := v_def;
  v_def := replace(v_def,
    E'          \'why\', case when v_is_counter\n                       and coalesce((v_recv->>\'parryAll\')::boolean, false)\n                      then \'all\' else \'roll\' end);',
    E'          \'why\', case when v_after_parry\n                       and coalesce((v_recv->>\'parryAll\')::boolean, false)\n                      then \'all\' else \'roll\' end);');
  if v_def = v_before then raise exception '0154 splice (cn_attack why) anchor not found'; end if;

  execute v_def;

  -- ===================== cn_attack_royale =====================
  v_def := pg_get_functiondef('public.cn_attack_royale(uuid,int,text,text)'::regprocedure);

  v_before := v_def;
  v_def := replace(v_def,
    E'  v_swing_is_atk boolean := true; v_is_counter boolean := false;\n',
    E'  v_swing_is_atk boolean := true; v_is_counter boolean := false;\n  v_after_parry boolean := false;\n');
  if v_def = v_before then raise exception '0154 splice (cn_attack_royale declare) anchor not found'; end if;

  v_before := v_def;
  v_def := replace(v_def,
    E'      v_parried := not v_ally\n                   and not coalesce((v_strk->>\'slippery\')::boolean, false)\n                   and ((v_is_counter and coalesce((v_recv->>\'parryAll\')::boolean, false))\n',
    E'      v_parried := not v_ally\n                   and not coalesce((v_strk->>\'slippery\')::boolean, false)\n                   and ((v_after_parry and coalesce((v_recv->>\'parryAll\')::boolean, false))\n');
  if v_def = v_before then raise exception '0154 splice (cn_attack_royale v_parried) anchor not found'; end if;

  v_before := v_def;
  v_def := replace(v_def,
    E'        v_swing_is_atk := not v_swing_is_atk;\n        v_is_counter := true;\n        continue;\n      end if;',
    E'        v_swing_is_atk := not v_swing_is_atk;\n        v_is_counter := true;\n        v_after_parry := true;\n        continue;\n      end if;');
  if v_def = v_before then raise exception '0154 splice (cn_attack_royale flip) anchor not found'; end if;

  v_before := v_def;
  v_def := replace(v_def,
    E'          \'why\', case when v_is_counter\n                       and coalesce((v_recv->>\'parryAll\')::boolean, false)\n                      then \'all\' else \'roll\' end);',
    E'          \'why\', case when v_after_parry\n                       and coalesce((v_recv->>\'parryAll\')::boolean, false)\n                      then \'all\' else \'roll\' end);');
  if v_def = v_before then raise exception '0154 splice (cn_attack_royale why) anchor not found'; end if;

  execute v_def;
end
$$;
