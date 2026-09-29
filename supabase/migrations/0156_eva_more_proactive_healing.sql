-- Jared: Eva's healing/protecting felt too rare -- "make her more
-- proactive." She was mechanically fine (she really did cast her heal
-- twice in your last live match), but her strategy bonus only pulled her
-- toward Fey/Sinie/Lium specifically, only from up to 6 tiles away, and
-- her ability bonus for actually casting on one of them was a flat +40 --
-- easy for a mediocre attack to outscore, and she'd never even consider
-- closing on anyone else who was hurt.
--
-- This widens both: she'll now close on ANY hurt (or threatened) ally,
-- not just her three named carries -- a smaller pull (8-tile search, 10x)
-- for anyone, a bigger one (10-tile search, 20x, both up from 6/12) for
-- Fey/Sinie/Lium specifically. Same split on the ability side: +50 for
-- healing anyone hurt, +90 (up from 40) for one of the three. Nothing
-- else in cn_bot_strategy_bonus changes.
--
-- Spot-checked directly against the pure function (no live match needed
-- -- cn_bot_strategy_bonus takes state as a plain argument): a hurt
-- non-named ally 2 tiles from a move candidate now scores +100 (was 40,
-- since the old code only ever looked at Fey/Sinie/Lium), and casting on
-- that same hurt non-named ally now scores +50 (was 0).
do $$
declare
  v_def text;
  v_before text;
begin
  v_def := pg_get_functiondef('public.cn_bot_strategy_bonus(jsonb,text,jsonb,text,int,int,text)'::regprocedure);
  v_before := v_def;
  v_def := replace(v_def,
E'  elsif v_slug = \'eva\' then
    if p_kind = \'move\' then
      v_bonus := v_bonus + least(v_near_enemy, 5) * 8;
      for q in select * from jsonb_array_elements(coalesce(v_st->\'units\', \'[]\'::jsonb)) loop
        if q->>\'owner\' = p_side and q->>\'slug\' in (\'fey\', \'sinie\', \'lium\') and (q->>\'hp\')::int > 0 then
          v_d := cn_cheb(p_vx, p_vy, (q->>\'x\')::int, (q->>\'y\')::int);
          if (q->>\'hp\')::int < (q->>\'maxHp\')::int
             or exists (select 1 from jsonb_array_elements(v_st->\'units\') e
                         where e->>\'owner\' = v_opp and (e->>\'hp\')::int > 0
                           and cn_cheb((e->>\'x\')::int, (e->>\'y\')::int, (q->>\'x\')::int, (q->>\'y\')::int) <= 2) then
            v_bonus := v_bonus + greatest(0, 6 - v_d) * 12;
          end if;
        end if;
      end loop;
    elsif p_kind = \'ability\' and v_target is not null and v_target->>\'slug\' in (\'fey\', \'sinie\', \'lium\') then
      v_bonus := v_bonus + 40;
    end if;',
E'  elsif v_slug = \'eva\' then
    if p_kind = \'move\' then
      v_bonus := v_bonus + least(v_near_enemy, 5) * 8;
      for q in select * from jsonb_array_elements(coalesce(v_st->\'units\', \'[]\'::jsonb)) loop
        if q->>\'owner\' = p_side and (q->>\'hp\')::int > 0 and q->>\'id\' <> u->>\'id\' then
          v_d := cn_cheb(p_vx, p_vy, (q->>\'x\')::int, (q->>\'y\')::int);
          if (q->>\'hp\')::int < (q->>\'maxHp\')::int
             or exists (select 1 from jsonb_array_elements(v_st->\'units\') e
                         where e->>\'owner\' = v_opp and (e->>\'hp\')::int > 0
                           and cn_cheb((e->>\'x\')::int, (e->>\'y\')::int, (q->>\'x\')::int, (q->>\'y\')::int) <= 2) then
            if q->>\'slug\' in (\'fey\', \'sinie\', \'lium\') then
              v_bonus := v_bonus + greatest(0, 10 - v_d) * 20;
            else
              v_bonus := v_bonus + greatest(0, 8 - v_d) * 10;
            end if;
          end if;
        end if;
      end loop;
    elsif p_kind = \'ability\' and v_target is not null and v_target->>\'owner\' = p_side
          and (v_target->>\'hp\')::int < (v_target->>\'maxHp\')::int then
      if v_target->>\'slug\' in (\'fey\', \'sinie\', \'lium\') then
        v_bonus := v_bonus + 90;
      else
        v_bonus := v_bonus + 50;
      end if;
    end if;');
  if v_def = v_before then raise exception '0156 splice (eva branch) anchor not found'; end if;
  execute v_def;
end
$$;
