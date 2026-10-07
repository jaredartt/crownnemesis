-- 0208: bots (1v1 bot_step and royale_bot_step) never counted what a swing costs
-- a unit that is ALREADY BURNING: a burning unit loses 15% of its max HP every
-- time it swings (0034), whether it hits, counters or kills. The attack score
-- ignored that, so a bot would happily keep attacking with a burning unit -- even
-- one whose HP was at or below the burn cost, which kills it on its own swing.
-- This patches both functions in place (replace on their current definition, so
-- nothing else in them changes): the burn cost is charged as lost HP (same rate as
-- any damage the bot takes) and a swing that would kill the attacker is
-- penalised like a lethal counter.
do $patch$
declare
  v_def text; v_new text;
  a1 text := E'v_noise := random() * v_noise_scale;\n        v_strat := case when v_lvl = 3 then cn_bot_strategy_bonus(st, p_side, u, ''attack''';
  b1 text := E'if cn_has(u, ''burn'') then\n          v_act := v_act - cn_effect_dmg(st, u, cn_burn_pct()) * coalesce((v_w->>''atk_mult'')::numeric, 10.0);\n          if cn_effect_dmg(st, u, cn_burn_pct()) >= (u->>''hp'')::int then\n            v_act := v_act - coalesce((v_w->>''lethal_ctr_penalty_flat'')::numeric, 500) - (u->>''maxHp'')::int;\n          end if;\n        end if;\n        ';
  a2 text := E'v_noise := random() * noise_s;\n            v_strat := cn_rb_strategy_bonus(st, p_seat, u, ''attack''';
  b2 text := E'if cn_has(u, ''burn'') then\n              v_act := v_act - cn_effect_dmg(st, u, cn_burn_pct()) * atk;\n              if cn_effect_dmg(st, u, cn_burn_pct()) >= u_hp then\n                v_act := v_act - lethal_ctr - u_mhp;\n              end if;\n            end if;\n            ';
begin
  v_def := pg_get_functiondef('public.bot_step(uuid,text)'::regprocedure);
  v_new := replace(v_def, a1, b1 || a1);
  if v_new = v_def then raise exception 'bot_step anchor not found'; end if;
  execute v_new;

  v_def := pg_get_functiondef('public.royale_bot_step(uuid,integer)'::regprocedure);
  v_new := replace(v_def, a2, b2 || a2);
  if v_new = v_def then raise exception 'royale_bot_step anchor not found'; end if;
  execute v_new;
end
$patch$;
