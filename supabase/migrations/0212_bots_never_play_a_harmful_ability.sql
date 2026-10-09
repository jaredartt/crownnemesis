-- 0212: bots never play an ability that nets out harmful.
--
-- Jared: "the opponent used Fey to burn her own Caela. What?"
--
-- Both bots score every ability option and keep both a BEST and a FALLBACK
-- candidate; when nothing scores above the bar they act on the fallback, which
-- is simply the least bad option -- even a negative one. Burning (or damaging,
-- or poisoning) one of their own units scores negative (cn_bot_score_ability
-- charges the burn bonus AGAINST an ally), but with nothing else worth doing it
-- was still the "least bad" pick. Now a scripted ability whose score is
-- negative is skipped outright, as a candidate and as a fallback:
--   * bot_step (1v1): the no-target and the targeted scripted branches.
--   * royale_bot_step: every option cn_rb_ability_options returns below zero.
-- Tile-aimed abilities (bombs, tornados) are untouched.
do $patch$
declare
  v_def text; v_new text;
  a1 constant text := E'            v_ab_score := cn_bot_score_ability(st, p_side, u, null, v_w);\n            if v_ab_score is not null then\n';
  b1 constant text := E'            v_ab_score := cn_bot_score_ability(st, p_side, u, null, v_w);\n            -- 0212: an ability that nets out harmful (burning or poisoning its own\n            -- unit, say) is never played, not even as the fallback when nothing\n            -- else scores.\n            if v_ab_score is not null and v_ab_score >= 0 then\n';
  a2 constant text := E'                v_ab_score := cn_bot_score_ability(st, p_side, u, t2->>''id'', v_w);\n                if v_ab_score is not null then\n';
  b2 constant text := E'                v_ab_score := cn_bot_score_ability(st, p_side, u, t2->>''id'', v_w);\n                -- 0212: same rule for a targeted ability -- Fey does not burn her own Caela.\n                if v_ab_score is not null and v_ab_score >= 0 then\n';
begin
  v_def := pg_get_functiondef('public.bot_step(uuid,text)'::regprocedure);
  if position('0212: an ability that nets out harmful' in v_def) = 0 then
    if (length(v_def) - length(replace(v_def, a1, ''))) / length(a1) <> 1 then raise exception 'a1 count'; end if;
    if (length(v_def) - length(replace(v_def, a2, ''))) / length(a2) <> 1 then raise exception 'a2 count'; end if;
    execute replace(replace(v_def, a1, b1), a2, b2);
  end if;
end
$patch$;

do $patch$
declare
  v_def text;
  a1 constant text := E'            v_tgt := v_opt->>''t'';\n';
  b1 constant text := E'            v_tgt := v_opt->>''t'';\n            -- 0212: an ability option that nets out harmful (burning its own unit,\n            -- say) is never played, not even as the fallback.\n            continue when (v_opt->>''s'')::numeric < 0;\n';
begin
  v_def := pg_get_functiondef('public.royale_bot_step(uuid,integer)'::regprocedure);
  if position('0212: an ability option that nets out harmful' in v_def) = 0 then
    if (length(v_def) - length(replace(v_def, a1, ''))) / length(a1) <> 1 then raise exception 'royale anchor count'; end if;
    execute replace(v_def, a1, b1);
  end if;
end
$patch$;
