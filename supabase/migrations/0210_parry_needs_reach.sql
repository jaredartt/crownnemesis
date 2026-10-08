-- 0210: NO ONE parries without the reach for it.
--
-- Jared: "Make it so that NO ONE can do parries if they don't have the reach
-- for it." Until now the parry roll in the chain (forced parry, Lium's
-- parry-all, and the plain parry %) happened whatever the distance: a melee
-- unit shot from range 3 could still "parry" the arrow -- it just could not
-- answer it afterwards. Now the roll itself is gated on the parrier being
-- able to reach the striker with its own counter range (crmin..crmax), on the
-- first swing and on every swing of the chain. Out of reach, the blow simply
-- lands. Both engines: cn_attack (1v1) and cn_attack_royale.
do $patch$
declare
  v_fn text; v_def text; v_new text;
  v_anchor constant text := E'      v_parried := not v_ally\n                   and not coalesce((v_strk->>''slippery'')::boolean, false)\n';
  v_repl constant text := E'      v_parried := not v_ally\n'
    || E'                   -- 0210: a parry needs REACH -- the parrier''s own counter range\n'
    || E'                   -- must cover the striker, or there is nothing to catch with.\n'
    || E'                   and case when v_swing_is_atk\n'
    || E'                            then v_dist >= (v_tgt->>''crmin'')::int and v_dist <= (v_tgt->>''crmax'')::int\n'
    || E'                            else v_reaches_back end\n'
    || E'                   and not coalesce((v_strk->>''slippery'')::boolean, false)\n';
begin
  foreach v_fn in array array[
    'public.cn_attack(uuid,text,text,text)',
    'public.cn_attack_royale(uuid,integer,text,text)'
  ] loop
    v_def := pg_get_functiondef(v_fn::regprocedure);
    if position(v_anchor in v_def) = 0 then raise exception '0210: anchor not found in %', v_fn; end if;
    if position('0210: a parry needs REACH' in v_def) > 0 then continue; end if;
    v_new := replace(v_def, v_anchor, v_repl);
    execute v_new;
  end loop;
end
$patch$;
