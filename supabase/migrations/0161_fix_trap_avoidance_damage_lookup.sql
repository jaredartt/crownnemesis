-- Follow-up to 0160, caught by simulating the exact match live before
-- shipping: turn 17 of a bot-vs-bot test still showed "King Stelaris steps
-- on a trap for 0" -- the bot's OWN king walked straight onto its OWN
-- Mako's bomb, the very thing 0160 was supposed to stop.
--
-- Root cause: 0160's bot_step penalty read cn_trap_at(st, vx, vy)->>'dmg',
-- exactly mirroring cn_spring's own legacy "for %s" log line -- but that
-- 'dmg' field has been dead since 0057 moved bomb into the real
-- `structures` catalog. Once a structure_id exists for a slug,
-- cn_run_structure_effects (not the legacy dmg field) is what actually
-- hurts the unit, via a structure_effects row: ON_STEPPED_ON / DEAL_DAMAGE
-- / value 30 (plus a BURNING status row). The legacy path still fires
-- afterward -- logs "for 0", consumes the obstacle -- but the number it
-- carries has been meaningless since 0057, for every player and every bot
-- level, not just this session's change. Not touching cn_trap_at/cn_spring
-- here: cn_step_on_structure already deals the real 30 through the modern
-- path, so making the legacy field return 30 too would deal it TWICE to
-- every unit that steps on a bomb -- a real-damage regression well outside
-- what Jared asked for. Bot scoring needed its OWN read of the real number.
--
-- cn_bot_trap_threat (NEW) answers "how much would stepping here actually
-- cost", straight from structure_effects, for whatever structure (bomb
-- today, anything else with a damaging ON_STEPPED_ON row tomorrow) sits at
-- that tile -- no interaction with cn_trap_at or the live damage-application
-- path at all, so this cannot change what a real step-on actually deals.
-- bot_step now calls this instead of cn_trap_at.

create or replace function public.cn_bot_trap_threat(p_st jsonb, p_x int, p_y int)
 returns int
 language sql
 stable
as $function$
  select coalesce(sum(se.value)::int, 0)
  from jsonb_array_elements(coalesce(p_st->'obstacles', '[]'::jsonb)) e
  join public.structures s on s.slug = cn_obj_kind(e)
  join public.structure_effects se
    on se.structure_id = s.id and se.trigger = 'ON_STEPPED_ON' and se.action = 'DEAL_DAMAGE'
  where (e->>'x')::int = p_x and (e->>'y')::int = p_y
$function$;

create or replace function public.bot_step(p_match uuid, p_side text DEFAULT 'guest'::text)
 returns matches
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  m public.matches; st jsonb; v_lvl int; v_noise numeric; v_w jsonb; v_brain_id uuid;
  v_noise_scale numeric; v_opp text;
  u jsonb; t jsonb;
  v_tiles text[]; v_tile text; vx int; vy int; v_first boolean;
  v_best numeric := 0; v_bu text; v_bx int; v_by int; v_bt text;
  v_fb numeric := -1e9; v_fu text; v_fbx int; v_fby int; v_ft text;
  v_pos numeric; v_base numeric; v_act numeric; v_step_s numeric;
  v_d int; v_dmg numeric; v_ctr numeric; v_near int; v_thr int; v_ally_near int;
  v_answers boolean; v_parry boolean;
  v_ab_kind text; v_ab_ready boolean; v_ab_max_uses int; v_ab_cooldown int;
  v_ab_used int; v_ab_last_used int; v_ab_turn_no int; v_ab_n int;
  v_ab_score numeric; v_ab_needs_target boolean; v_ab_needs_tile boolean;
  v_ab_tiles text[]; v_ab_tile text; v_dx int; v_dy int; t2 jsonb;
  v_bkind text; v_fkind text; v_strat numeric;
  v_trap_dmg int;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null then return m; end if;
  v_opp := case when p_side = 'host' then 'guest' else 'host' end;
  v_lvl := case when p_side = 'guest' then m.bot else m.host_bot end;
  if v_lvl is null then return m; end if;
  if m.status <> 'active' then return m; end if;
  if m.state->>'turn' <> p_side then return m; end if;

  st := m.state;

  v_brain_id := case when p_side = 'guest' then m.guest_brain_id else m.host_brain_id end;
  if v_brain_id is not null then
    select weights into v_w from public.bot_brains where id = v_brain_id;
  end if;
  if v_w is null then
    select weights into v_w from public.bot_brains where level = v_lvl and is_live limit 1;
  end if;
  v_w := coalesce(v_w, '{}'::jsonb);
  v_noise_scale := coalesce((v_w->>'noise_scale')::numeric,
    case v_lvl when 1 then 220 when 2 then 90 else 15 end);

  for u in select * from jsonb_array_elements(st->'units') loop
    continue when u->>'owner' <> p_side;
    continue when (u->>'moved')::boolean and (u->>'acted')::boolean;
    continue when coalesce((u->>'spent')::boolean, false);
    continue when coalesce((st->>'acts')::int, 0) >= cn_acts_cap(st)
              and nullif(st->>'active', '') is distinct from u->>'id';

    v_tiles := array[(u->>'x') || ',' || (u->>'y')];
    if not (u->>'moved')::boolean and (not cn_stunned(u) or not cn_stun_blocks('move')) then
      v_tiles := v_tiles || cn_reach(st, u);
    end if;
    v_first := true;

    foreach v_tile in array v_tiles loop
      vx := split_part(v_tile, ',', 1)::int;
      vy := split_part(v_tile, ',', 2)::int;

      v_near := 99; v_thr := 0;
      for t in select * from jsonb_array_elements(st->'units') loop
        continue when t->>'owner' = p_side;
        v_d := cn_cheb(vx, vy, (t->>'x')::int, (t->>'y')::int);
        v_near := least(v_near, v_d);
        if v_d <= (t->>'mov')::int + (t->>'rmax')::int then v_thr := v_thr + 1; end if;
      end loop;
      v_pos := - abs(v_near - (u->>'rmax')::int) * coalesce((v_w->>'pos_dist_mult')::numeric, 5.0)
               - v_near * coalesce((v_w->>'pos_near_mult')::numeric, 2.0);

      if v_lvl = 3 then
        v_ally_near := 99;
        for t2 in select * from jsonb_array_elements(st->'units') loop
          continue when t2->>'owner' <> p_side or t2->>'id' = u->>'id' or (t2->>'hp')::int <= 0;
          v_d := cn_cheb(vx, vy, (t2->>'x')::int, (t2->>'y')::int);
          if v_d < v_ally_near then v_ally_near := v_d; end if;
        end loop;
        v_pos := v_pos - greatest(0, coalesce((v_w->>'ally_spacing_ideal')::numeric, 2) - v_ally_near)
                          * coalesce((v_w->>'ally_spacing_mult')::numeric, 6.0);
      end if;

      -- 0160/0161: Jared: "bots shouldn't just step in their own bombs."
      -- cn_bot_trap_threat reads the REAL damage a step here would deal
      -- (straight from structure_effects -- see 0161's header), not the
      -- dead legacy field cn_trap_at/cn_spring still logs "for 0" from.
      -- Deliberately NOT gated to v_lvl = 3: not walking into a bomb you
      -- can see is baseline sense, not an Expert-only strategy call. Only
      -- fires for an actual move (vx,vy differs from the unit's own tile).
      if vx <> (u->>'x')::int or vy <> (u->>'y')::int then
        v_trap_dmg := cn_bot_trap_threat(st, vx, vy);
        if v_trap_dmg > 0 then
          v_pos := v_pos - v_trap_dmg * coalesce((v_w->>'trap_dmg_mult')::numeric, 12.0);
          if v_trap_dmg >= (u->>'hp')::int then
            v_pos := v_pos - coalesce((v_w->>'lethal_trap_penalty_flat')::numeric, 500) - (u->>'maxHp')::int;
          end if;
        end if;
      end if;

      if v_first then v_base := v_pos; v_first := false; end if;

      if vx <> (u->>'x')::int or vy <> (u->>'y')::int then
        v_noise := random() * v_noise_scale;
        v_strat := case when v_lvl = 3 then cn_bot_strategy_bonus(st, p_side, u, 'move', vx, vy, null) else 0 end;
        v_step_s := v_pos - v_base + v_noise + v_strat
          - v_thr * coalesce((v_w->>'threat_mult')::numeric, case when v_lvl >= 3 then 4.0 else 0 end);
        if v_step_s > v_best then
          v_best := v_step_s;
          v_bu := u->>'id'; v_bx := vx; v_by := vy; v_bt := null; v_bkind := null;
        end if;
        if v_step_s > v_fb then
          v_fb := v_step_s;
          v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := null; v_fkind := null;
        end if;
      end if;

      continue when (u->>'acted')::boolean;

      if not cn_stunned(u) or not cn_stun_blocks('attack') then
      for t in select * from jsonb_array_elements(st->'units') loop
        continue when t->>'id' = u->>'id';
        v_d := cn_cheb(vx, vy, (t->>'x')::int, (t->>'y')::int);
        continue when v_d < (u->>'rmin')::int or v_d > (u->>'rmax')::int;
        continue when not cn_los_clear(st, vx, vy, (t->>'x')::int, (t->>'y')::int);

        v_dmg := ((u->>'dmin')::int + (u->>'dmax')::int) / 2.0;

        if t->>'owner' = p_side then
          continue when not (u->>'heals')::boolean;
          v_act := case when (t->>'maxHp')::int - (t->>'hp')::int <= 0
                        then coalesce((v_w->>'heal_full_penalty')::numeric, -150)
                        else least(v_dmg, (t->>'maxHp')::int - (t->>'hp')::int)
                             * coalesce((v_w->>'heal_mult')::numeric, 9.0) end;
        else
          v_answers := not coalesce((u->>'sneaks')::boolean, false)
                       and v_d >= (t->>'crmin')::int and v_d <= (t->>'crmax')::int;
          v_parry := v_answers and coalesce((t->>'parries')::boolean, false);

          v_act := least(v_dmg, (t->>'hp')::int) * coalesce((v_w->>'atk_mult')::numeric, 10.0);
          if v_dmg >= (t->>'hp')::int then
            v_act := v_act + coalesce((v_w->>'kill_bonus_flat')::numeric, 400) + (t->>'maxHp')::int;
          elsif (u->>'burns')::boolean and not (t->>'burned')::boolean then
            v_act := v_act + coalesce((v_w->>'burn_bonus')::numeric, 25);
          end if;

          if v_answers and (v_parry or v_dmg < (t->>'hp')::int) then
            v_ctr := ((t->>'dmin')::int + (t->>'dmax')::int) / 2.0;
            v_act := v_act - v_ctr * coalesce((v_w->>'ctr_mult')::numeric,
                       case v_lvl when 1 then 3.0 else 8.0 end);
            if v_ctr >= (u->>'hp')::int then
              v_act := v_act - coalesce((v_w->>'lethal_ctr_penalty_flat')::numeric, 500) - (u->>'maxHp')::int
                       - case when v_parry
                              then coalesce((v_w->>'lethal_parry_extra_flat')::numeric, 400) + (t->>'maxHp')::int
                              else 0 end;
            end if;
          end if;
        end if;

        v_noise := random() * v_noise_scale;
        v_strat := case when v_lvl = 3 then cn_bot_strategy_bonus(st, p_side, u, 'attack', vx, vy, t->>'id') else 0 end;
        if v_pos + v_act - v_base + v_noise + v_strat > v_best then
          v_best := v_pos + v_act - v_base + v_noise + v_strat;
          v_bu := u->>'id'; v_bx := vx; v_by := vy; v_bt := t->>'id'; v_bkind := 'attack';
        end if;
        if v_pos + v_act - v_base + v_noise + v_strat > v_fb then
          v_fb := v_pos + v_act - v_base + v_noise + v_strat;
          v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := t->>'id'; v_fkind := 'attack';
        end if;
      end loop;
      end if;

      if vx = (u->>'x')::int and vy = (u->>'y')::int
         and not (u->>'acted')::boolean
         and u->>'abilityKind' is not null
         and (not cn_stunned(u) or not cn_stun_blocks('ability')) and not cn_swamped(st, u)
      then
        v_ab_turn_no := coalesce((st->>'turnNumber')::int, 1);
        v_ab_max_uses := nullif(u->>'abilityMaxUses', '')::int;
        v_ab_cooldown := coalesce(nullif(u->>'abilityCooldownTurns', '')::int, 0);
        v_ab_used := coalesce((u->>'abilityUses')::int, 0);
        v_ab_last_used := nullif(u->>'abilityLastUsedTurn', '')::int;
        v_ab_ready := (v_ab_max_uses is null or v_ab_used < v_ab_max_uses)
          and (v_ab_cooldown <= 0 or v_ab_last_used is null
               or v_ab_turn_no - v_ab_last_used > v_ab_cooldown);

        if v_ab_ready then
          v_ab_kind := u->>'abilityKind';
          v_ab_n := coalesce((u->>'abilityN')::int, 0);

          if v_ab_kind = 'scripted' then
            v_ab_needs_target := exists (
              select 1 from jsonb_array_elements(coalesce(u->'abilityScript', '[]'::jsonb)) r
               where r->>'trigger' = 'ON_ABILITY' and r->>'target_selector' = 'THE_TARGET');
            v_ab_needs_tile := exists (
              select 1 from jsonb_array_elements(coalesce(u->'abilityScript', '[]'::jsonb)) r
               where r->>'trigger' = 'ON_ABILITY' and r->>'target_selector' = 'BOARD_CELL');

            v_ab_score := cn_bot_score_ability(st, p_side, u, null, v_w);
            if v_ab_score is not null then
              v_strat := case when v_lvl = 3 then cn_bot_strategy_bonus(st, p_side, u, 'ability', vx, vy, null) else 0 end;
              v_step_s := v_pos + v_ab_score - v_base + random() * v_noise_scale + v_strat;
              if v_step_s > v_best then
                v_best := v_step_s;
                v_bu := u->>'id'; v_bx := vx; v_by := vy; v_bt := null; v_bkind := 'ability';
              end if;
              if v_step_s > v_fb then
                v_fb := v_step_s;
                v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := null; v_fkind := 'ability';
              end if;
            end if;

            if v_ab_needs_target then
              for t2 in select * from jsonb_array_elements(st->'units') loop
                continue when (t2->>'hp')::int <= 0;
                v_ab_score := cn_bot_score_ability(st, p_side, u, t2->>'id', v_w);
                if v_ab_score is not null then
                  v_strat := case when v_lvl = 3 then cn_bot_strategy_bonus(st, p_side, u, 'ability', vx, vy, t2->>'id') else 0 end;
                  v_step_s := v_pos + v_ab_score - v_base + random() * v_noise_scale + v_strat;
                  if v_step_s > v_best then
                    v_best := v_step_s;
                    v_bu := u->>'id'; v_bx := vx; v_by := vy; v_bt := t2->>'id'; v_bkind := 'ability';
                  end if;
                  if v_step_s > v_fb then
                    v_fb := v_step_s;
                    v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := t2->>'id'; v_fkind := 'ability';
                  end if;
                end if;
              end loop;
            end if;

            if v_ab_needs_tile then
              v_ab_tiles := cn_bot_ability_tiles(st, u);
              foreach v_ab_tile in array v_ab_tiles loop
                v_ab_score := cn_bot_score_ability(st, p_side, u, v_ab_tile, v_w);
                if v_ab_score is not null then
                  v_strat := case when v_lvl = 3 then cn_bot_strategy_bonus(st, p_side, u, 'ability', vx, vy, v_ab_tile) else 0 end;
                  v_step_s := v_pos + v_ab_score - v_base + random() * v_noise_scale + v_strat;
                  if v_step_s > v_best then
                    v_best := v_step_s;
                    v_bu := u->>'id'; v_bx := vx; v_by := vy; v_bt := v_ab_tile; v_bkind := 'ability';
                  end if;
                  if v_step_s > v_fb then
                    v_fb := v_step_s;
                    v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := v_ab_tile; v_fkind := 'ability';
                  end if;
                end if;
              end loop;
            end if;

          elsif v_ab_kind = 'aoe_adjacent' then
            v_ab_score := 0;
            for t2 in select * from jsonb_array_elements(st->'units') loop
              continue when t2->>'id' = u->>'id';
              continue when cn_cheb((u->>'x')::int, (u->>'y')::int, (t2->>'x')::int, (t2->>'y')::int) <> 1;
              if t2->>'owner' <> p_side then
                v_ab_score := v_ab_score + least(v_ab_n, (t2->>'hp')::int) * coalesce((v_w->>'atk_mult')::numeric, 10.0);
                if v_ab_n >= (t2->>'hp')::int then
                  v_ab_score := v_ab_score + coalesce((v_w->>'kill_bonus_flat')::numeric, 400) + (t2->>'maxHp')::int;
                end if;
              else
                v_ab_score := v_ab_score - least(v_ab_n, (t2->>'hp')::int) * coalesce((v_w->>'atk_mult')::numeric, 10.0);
                if v_ab_n >= (t2->>'hp')::int then
                  v_ab_score := v_ab_score - coalesce((v_w->>'kill_bonus_flat')::numeric, 400) - (t2->>'maxHp')::int;
                end if;
              end if;
            end loop;
            if v_ab_score <> 0 then
              v_step_s := v_pos + v_ab_score - v_base + random() * v_noise_scale;
              if v_step_s > v_best then
                v_best := v_step_s;
                v_bu := u->>'id'; v_bx := vx; v_by := vy; v_bt := null; v_bkind := 'ability';
              end if;
              if v_step_s > v_fb then
                v_fb := v_step_s;
                v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := null; v_fkind := 'ability';
              end if;
            end if;

          elsif v_ab_kind = 'heal_any' then
            for t2 in select * from jsonb_array_elements(st->'units') loop
              continue when t2->>'owner' <> p_side;
              continue when (t2->>'hp')::int >= (t2->>'maxHp')::int;
              v_d := cn_cheb((u->>'x')::int, (u->>'y')::int, (t2->>'x')::int, (t2->>'y')::int);
              continue when v_d > (u->>'rmax')::int;
              continue when not cn_los_clear(st, (u->>'x')::int, (u->>'y')::int, (t2->>'x')::int, (t2->>'y')::int);
              v_ab_score := least(v_ab_n, (t2->>'maxHp')::int - (t2->>'hp')::int) * coalesce((v_w->>'heal_mult')::numeric, 9.0);
              v_step_s := v_pos + v_ab_score - v_base + random() * v_noise_scale;
              if v_step_s > v_best then
                v_best := v_step_s;
                v_bu := u->>'id'; v_bx := vx; v_by := vy; v_bt := t2->>'id'; v_bkind := 'ability';
              end if;
              if v_step_s > v_fb then
                v_fb := v_step_s;
                v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := t2->>'id'; v_fkind := 'ability';
              end if;
            end loop;

          elsif v_ab_kind = 'poison_hit' then
            for t2 in select * from jsonb_array_elements(st->'units') loop
              continue when t2->>'owner' = p_side;
              v_d := cn_cheb((u->>'x')::int, (u->>'y')::int, (t2->>'x')::int, (t2->>'y')::int);
              continue when v_d > (u->>'rmax')::int;
              continue when not cn_los_clear(st, (u->>'x')::int, (u->>'y')::int, (t2->>'x')::int, (t2->>'y')::int);
              v_ab_score := least(v_ab_n, (t2->>'hp')::int) * coalesce((v_w->>'atk_mult')::numeric, 10.0);
              if v_ab_n >= (t2->>'hp')::int then
                v_ab_score := v_ab_score + coalesce((v_w->>'kill_bonus_flat')::numeric, 400) + (t2->>'maxHp')::int;
              elsif not cn_has(t2, 'poison') then
                v_ab_score := v_ab_score + coalesce((v_w->>'poison_bonus')::numeric, 25);
              end if;
              v_step_s := v_pos + v_ab_score - v_base + random() * v_noise_scale;
              if v_step_s > v_best then
                v_best := v_step_s;
                v_bu := u->>'id'; v_bx := vx; v_by := vy; v_bt := t2->>'id'; v_bkind := 'ability';
              end if;
              if v_step_s > v_fb then
                v_fb := v_step_s;
                v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := t2->>'id'; v_fkind := 'ability';
              end if;
            end loop;

          elsif v_ab_kind = 'line_burn' then
            for t2 in select * from jsonb_array_elements(st->'units') loop
              continue when t2->>'owner' = p_side;
              v_d := cn_cheb((u->>'x')::int, (u->>'y')::int, (t2->>'x')::int, (t2->>'y')::int);
              continue when v_d > (u->>'rmax')::int;
              v_dx := sign((t2->>'x')::int - (u->>'x')::int);
              v_dy := sign((t2->>'y')::int - (u->>'y')::int);
              v_ab_score := least(v_ab_n, (t2->>'hp')::int) * coalesce((v_w->>'atk_mult')::numeric, 10.0);
              if v_ab_n >= (t2->>'hp')::int then
                v_ab_score := v_ab_score + coalesce((v_w->>'kill_bonus_flat')::numeric, 400) + (t2->>'maxHp')::int;
              elsif not cn_has(t2, 'burn') then
                v_ab_score := v_ab_score + coalesce((v_w->>'burn_bonus')::numeric, 25);
              end if;
              for t in select * from jsonb_array_elements(st->'units') loop
                continue when (t->>'x')::int <> (t2->>'x')::int + v_dx or (t->>'y')::int <> (t2->>'y')::int + v_dy;
                if t->>'owner' <> p_side then
                  v_ab_score := v_ab_score + least(v_ab_n, (t->>'hp')::int) * coalesce((v_w->>'atk_mult')::numeric, 10.0);
                  if v_ab_n >= (t->>'hp')::int then
                    v_ab_score := v_ab_score + coalesce((v_w->>'kill_bonus_flat')::numeric, 400) + (t->>'maxHp')::int;
                  end if;
                else
                  v_ab_score := v_ab_score - least(v_ab_n, (t->>'hp')::int) * coalesce((v_w->>'atk_mult')::numeric, 10.0);
                end if;
              end loop;
              v_step_s := v_pos + v_ab_score - v_base + random() * v_noise_scale;
              if v_step_s > v_best then
                v_best := v_step_s;
                v_bu := u->>'id'; v_bx := vx; v_by := vy; v_bt := t2->>'id'; v_bkind := 'ability';
              end if;
              if v_step_s > v_fb then
                v_fb := v_step_s;
                v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := t2->>'id'; v_fkind := 'ability';
              end if;
            end loop;

          elsif v_ab_kind = 'mist' then
            v_ab_score := 0;
            for t2 in select * from jsonb_array_elements(st->'units') loop
              if t2->>'owner' = p_side and t2->>'role' = 'rogue' then
                v_ab_score := v_ab_score + coalesce((v_w->>'mist_bonus_per_rogue')::numeric, 15) * v_ab_n / 20.0;
              end if;
            end loop;
            if v_ab_score > 0 then
              v_step_s := v_pos + v_ab_score - v_base + random() * v_noise_scale;
              if v_step_s > v_best then
                v_best := v_step_s;
                v_bu := u->>'id'; v_bx := vx; v_by := vy; v_bt := null; v_bkind := 'ability';
              end if;
              if v_step_s > v_fb then
                v_fb := v_step_s;
                v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := null; v_fkind := 'ability';
              end if;
            end if;

          elsif v_ab_kind = 'summon' then
            if v_near <= (u->>'rmax')::int + 2 then
              v_ab_tiles := cn_bot_ability_tiles(st, u);
              foreach v_ab_tile in array v_ab_tiles loop
                v_ab_score := coalesce((v_w->>'ability_structure_flat')::numeric, 40);
                v_step_s := v_pos + v_ab_score - v_base + random() * v_noise_scale;
                if v_step_s > v_best then
                  v_best := v_step_s;
                  v_bu := u->>'id'; v_bx := vx; v_by := vy; v_bt := v_ab_tile; v_bkind := 'ability';
                end if;
                if v_step_s > v_fb then
                  v_fb := v_step_s;
                  v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := v_ab_tile; v_fkind := 'ability';
                end if;
              end loop;
            end if;
          end if;
        end if;
      end if;
    end loop;
  end loop;

  if v_bu is null and v_fu is not null then
    v_bu := v_fu; v_bx := v_fbx; v_by := v_fby; v_bt := v_ft; v_bkind := v_fkind;
  end if;
  if v_bu is null then
    m := advance_turn(p_match, null, false);
    if m.is_sim then
      update public.matches set state = jsonb_set(coalesce(m.state, '{}'::jsonb), '{lastBotAction}',
        jsonb_build_object('side', p_side, 'unit', null, 'target', null, 'kind', 'pass'))
      where id = m.id returning * into m;
    end if;
    return m;
  end if;

  for u in select * from jsonb_array_elements(st->'units') loop
    if u->>'id' = v_bu and ((u->>'x')::int <> v_bx or (u->>'y')::int <> v_by) then
      m := cn_move(p_match, p_side, v_bu, v_bx, v_by);
      if m.is_sim then
        update public.matches set state = jsonb_set(coalesce(m.state, '{}'::jsonb), '{lastBotAction}',
          jsonb_build_object('side', p_side, 'unit', v_bu, 'target', null, 'kind', 'move'))
        where id = m.id returning * into m;
      end if;
      return m;
    end if;
  end loop;

  if v_bkind = 'ability' then
    m := cn_ability(p_match, p_side, v_bu, v_bt);
    if m.is_sim then
      update public.matches set state = jsonb_set(coalesce(m.state, '{}'::jsonb), '{lastBotAction}',
        jsonb_build_object('side', p_side, 'unit', v_bu, 'target', v_bt, 'kind', 'ability'))
      where id = m.id returning * into m;
    end if;
    return m;
  end if;

  if v_bt is not null then
    m := cn_attack(p_match, p_side, v_bu, v_bt);
    if m.is_sim then
      update public.matches set state = jsonb_set(coalesce(m.state, '{}'::jsonb), '{lastBotAction}',
        jsonb_build_object('side', p_side, 'unit', v_bu, 'target', v_bt, 'kind', 'attack'))
      where id = m.id returning * into m;
    end if;
    return m;
  end if;

  m := advance_turn(p_match, null, false);
  if m.is_sim then
    update public.matches set state = jsonb_set(coalesce(m.state, '{}'::jsonb), '{lastBotAction}',
      jsonb_build_object('side', p_side, 'unit', null, 'target', null, 'kind', 'pass'))
    where id = m.id returning * into m;
  end if;
  return m;
end
$function$;
