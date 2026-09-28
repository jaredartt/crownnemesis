-- Jared: "can you make the bot even smarter right now? I want it to use
-- abilities very strategically too!"
--
-- Checked bot_step (0114, the live single-1v1-bot decision function) end to
-- end: it has never once called cn_ability. Every card the bot can command
-- either moves or throws a basic attack -- Sinie never poisons then
-- detonates, Eva never mends a low-HP ally, Fey never sets someone alight
-- and finishes them next turn, Dione & Grifo never trades their own HP for
-- a room-clearing AoE, Lumea/Mako never wall off a chokepoint. Every single
-- live card's ability is authored through the "scripted" sentence engine
-- (card_effects/abilityScript, ON_ABILITY trigger) -- none of the six
-- legacy hardcoded kinds (aoe_adjacent/heal_any/mist/poison_hit/line_burn/
-- summon) are actually in use on the shipped roster today, though the
-- engine still supports them, so this covers those too.
--
-- THE APPROACH: rather than hand-modelling what each card's authored
-- sentence does (which would mean re-deriving Fey's "burn it, then
-- detonate it" logic, Sinie's poison/finish combo, etc. by hand and
-- keeping that copy in sync with whatever gets authored in the Admin
-- sentence builder later), a candidate ability use is actually RUN through
-- the real engine -- cn_run_effects, which is already a pure function (no
-- side effects, nothing committed) -- on a scratch copy of the match state,
-- and scored from what it actually did: HP lost by enemies vs allies,
-- kills either side, new burn/poison/stun landed either side. This is
-- exactly why Fey and Sinie's two-condition sentences (apply the status if
-- it isn't there yet, otherwise cash it in for damage) come out right
-- without a single line here knowing either card exists -- the real
-- ON_ABILITY conditions decide that, same as they do for a human player.
--
-- The six legacy kinds don't run through card_effects at all (they're
-- cards.ability_kind/ability_n directly), so those get their own direct
-- formulas mirroring cn_ability's own math for each -- still real, still
-- respects range/LOS/friendly-fire exactly as cn_ability enforces it, just
-- computed rather than simulated since there's no cn_run_effects path for
-- them to run through.
--
-- Every candidate this adds folds into bot_step's EXISTING v_best/v_fb
-- scoring (the same running-best comparison move and attack candidates
-- already go through), using the SAME bot_brains-coalesced weights where
-- the concept already exists (atk_mult, heal_mult, kill_bonus_flat,
-- burn_bonus) so an ability trade is judged in the same currency as an
-- ordinary attack, plus a handful of new weights for concepts with no
-- existing analog (poison_bonus, stun_bonus, mist_bonus_per_rogue,
-- ability_structure_flat) -- all coalesced to a sensible hardcoded default,
-- so a level with no bot_brains row for it still behaves reasonably, same
-- as every other 0114 weight.
--
-- Preconditions (max uses, cooldown, stunned, swamped) are checked in
-- bot_step BEFORE a single candidate is scored, mirroring cn_ability's own
-- guards exactly -- the bot must never pick an action cn_ability would
-- reject, or the whole bot_step call blows up on an uncaught exception.
--
-- Execution is still ONE action per bot_step call, exactly like today: if
-- the winning candidate is an ability, this calls cn_ability instead of
-- cn_attack. A unit that needs to close distance first still does -- move
-- this call, ability next call -- the same way move-then-attack already
-- works, since an ability is only ever SCORED from the unit's actual
-- current tile (cn_ability itself always checks range/LOS from where the
-- unit really stands, so scoring anywhere else would just be wrong).
--
-- SCOPE: this is bot_step only -- the 1v1 ranked/friend/practice bot.
-- Battle Royale's bot (royale_bot_step/cn_ability_royale) is a separate,
-- simpler function and does not get this in this pass; a real follow-up if
-- Jared wants it there too, not silently assumed here.
--
-- A BOARD_CELL-targeted scripted ability (today: Lumea and Mako's
-- structure placement) picks its tile from cn_bot_ability_tiles below --
-- the empty, in-range, line-of-sight-clear tiles next to the caster or
-- next to the nearest enemy. That is a deliberately modest search (not a
-- full "best chokepoint" solver) -- it gets a wall or totem down somewhere
-- that actually matters near the fight, not necessarily the single best
-- tile on the board. Also good enough to cover the legacy `summon` kind,
-- which needs the exact same kind of tile pick.

-- ---------------------------------------------------------------------------
-- 1. cn_bot_score_ability -- simulate one candidate scripted ON_ABILITY use
--    on a scratch state (cn_run_effects has no side effects, nothing here
--    is ever committed) and score it from what actually happened. Returns
--    null when the candidate did nothing at all (wrong condition, no valid
--    target/tile, out of range) -- "not a real candidate", not "worth 0".
-- ---------------------------------------------------------------------------

create or replace function public.cn_bot_score_ability(
  v_st jsonb, p_side text, p_unit jsonb, p_target_id text, v_w jsonb
) returns numeric
language plpgsql as $function$
declare
  v_ctx jsonb;
  v_scratch jsonb;
  v_opp text := case when p_side = 'host' then 'guest' else 'host' end;
  v_score numeric := 0;
  v_tgt jsonb;
  u_old jsonb; u_new jsonb;
  v_old_hp int; v_new_hp int; v_max_hp int; v_owner text; v_died boolean; v_hp_delta int;
begin
  if p_target_id is not null then
    if left(p_target_id, 1) = '@' then
      v_ctx := jsonb_build_object('turnNumber', coalesce((v_st->>'turnNumber')::int, 1), 'tile', p_target_id);
    else
      select q into v_tgt from jsonb_array_elements(v_st->'units') q where q->>'id' = p_target_id;
      if v_tgt is null then return null; end if;
      v_ctx := jsonb_build_object('turnNumber', coalesce((v_st->>'turnNumber')::int, 1), 'target', v_tgt);
    end if;
  else
    v_ctx := jsonb_build_object('turnNumber', coalesce((v_st->>'turnNumber')::int, 1));
  end if;

  v_scratch := cn_run_effects(v_st, 'ON_ABILITY', p_unit, v_ctx);
  if v_scratch->'units' = v_st->'units'
     and coalesce(v_scratch->'obstacles', '[]'::jsonb) = coalesce(v_st->'obstacles', '[]'::jsonb) then
    return null;
  end if;

  for u_old in select * from jsonb_array_elements(v_st->'units') loop
    v_owner := u_old->>'owner';
    v_old_hp := (u_old->>'hp')::int;
    v_max_hp := (u_old->>'maxHp')::int;
    u_new := null;
    select q into u_new from jsonb_array_elements(v_scratch->'units') q where q->>'id' = u_old->>'id';
    v_died := u_new is null;
    v_new_hp := case when v_died then 0 else (u_new->>'hp')::int end;
    v_hp_delta := v_old_hp - v_new_hp;

    if v_owner = v_opp then
      if v_hp_delta > 0 then
        v_score := v_score + least(v_hp_delta, v_old_hp) * coalesce((v_w->>'atk_mult')::numeric, 10.0);
        if v_died then
          v_score := v_score + coalesce((v_w->>'kill_bonus_flat')::numeric, 400) + v_max_hp;
        end if;
      elsif v_hp_delta < 0 then
        -- healed the enemy?! only possible if a card is ever authored with
        -- no owner restriction on a HEAL row -- never a good idea.
        v_score := v_score - abs(v_hp_delta) * coalesce((v_w->>'heal_mult')::numeric, 9.0);
      end if;
      if not v_died then
        if not cn_has(u_old, 'burn') and cn_has(u_new, 'burn') then
          v_score := v_score + coalesce((v_w->>'burn_bonus')::numeric, 25);
        end if;
        if not cn_has(u_old, 'poison') and cn_has(u_new, 'poison') then
          v_score := v_score + coalesce((v_w->>'poison_bonus')::numeric, 25);
        end if;
        if coalesce((u_new->'effects'->>'stun')::int, 0) > coalesce((u_old->'effects'->>'stun')::int, 0) then
          v_score := v_score + coalesce((v_w->>'stun_bonus')::numeric, 60);
        end if;
      end if;
    else
      if v_hp_delta < 0 then
        v_score := v_score + least(abs(v_hp_delta), v_max_hp) * coalesce((v_w->>'heal_mult')::numeric, 9.0);
      elsif v_hp_delta > 0 then
        v_score := v_score - v_hp_delta * coalesce((v_w->>'atk_mult')::numeric, 10.0);
        if v_died then
          v_score := v_score - coalesce((v_w->>'kill_bonus_flat')::numeric, 400) - v_max_hp;
        end if;
      end if;
      if not v_died then
        if not cn_has(u_old, 'burn') and cn_has(u_new, 'burn') then
          v_score := v_score - coalesce((v_w->>'burn_bonus')::numeric, 25);
        end if;
        if not cn_has(u_old, 'poison') and cn_has(u_new, 'poison') then
          v_score := v_score - coalesce((v_w->>'poison_bonus')::numeric, 25);
        end if;
        if coalesce((u_new->'effects'->>'stun')::int, 0) > coalesce((u_old->'effects'->>'stun')::int, 0) then
          v_score := v_score - coalesce((v_w->>'stun_bonus')::numeric, 60);
        end if;
      end if;
    end if;
  end loop;

  if coalesce(jsonb_array_length(coalesce(v_scratch->'obstacles', '[]'::jsonb)), 0)
     > coalesce(jsonb_array_length(coalesce(v_st->'obstacles', '[]'::jsonb)), 0) then
    v_score := v_score + coalesce((v_w->>'ability_structure_flat')::numeric, 40);
  end if;

  return v_score;
end
$function$;

-- ---------------------------------------------------------------------------
-- 2. cn_bot_ability_tiles -- legal tile candidates for a BOARD_CELL-style
--    ability (a scripted CREATE_STRUCTURE row, or the legacy `summon`
--    kind): the empty, in-range (1..this unit's own rmax), line-of-sight
--    tiles next to the caster itself or next to the nearest enemy. Every
--    tile this returns is already valid for THIS unit -- cn_create_structure/
--    the legacy summon branch will never reject one of these for range,
--    bounds, occupancy or LOS.
-- ---------------------------------------------------------------------------

create or replace function public.cn_bot_ability_tiles(v_st jsonb, p_unit jsonb)
 returns text[]
 language plpgsql as $function$
declare
  v_out text[] := '{}';
  v_ux int := (p_unit->>'x')::int; v_uy int := (p_unit->>'y')::int;
  v_rmax int := coalesce((p_unit->>'rmax')::int, 1);
  v_w int := coalesce((v_st->'board'->>'w')::int, 0);
  v_h int := coalesce((v_st->'board'->>'h')::int, 0);
  v_seed_x int[] := array[(p_unit->>'x')::int];
  v_seed_y int[] := array[(p_unit->>'y')::int];
  v_best_id text; v_best_d int; v_best_x int; v_best_y int; v_d int;
  q jsonb; dx int; dy int; nx int; ny int; i int; v_dist int; v_tag text;
begin
  -- second seed point: the nearest enemy, if the board has one. A wall or
  -- totem next to THEM is usually the one that matters.
  for q in select * from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) loop
    continue when q->>'owner' = p_unit->>'owner';
    v_d := cn_cheb(v_ux, v_uy, (q->>'x')::int, (q->>'y')::int);
    if v_best_id is null or v_d < v_best_d then
      v_best_id := q->>'id'; v_best_d := v_d;
      v_best_x := (q->>'x')::int; v_best_y := (q->>'y')::int;
    end if;
  end loop;
  if v_best_id is not null then
    v_seed_x := v_seed_x || v_best_x;
    v_seed_y := v_seed_y || v_best_y;
  end if;

  for i in 1 .. coalesce(array_length(v_seed_x, 1), 0) loop
    for dx in -1 .. 1 loop
      for dy in -1 .. 1 loop
        continue when dx = 0 and dy = 0;
        nx := v_seed_x[i] + dx; ny := v_seed_y[i] + dy;
        continue when nx < 0 or ny < 0 or nx >= v_w or ny >= v_h;
        v_dist := cn_cheb(v_ux, v_uy, nx, ny);
        continue when v_dist < 1 or v_dist > v_rmax;
        continue when exists (select 1 from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) qu
                                where (qu->>'x')::int = nx and (qu->>'y')::int = ny);
        continue when exists (select 1 from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) qo
                                where (qo->>'x')::int = nx and (qo->>'y')::int = ny);
        continue when not cn_los_clear(v_st, v_ux, v_uy, nx, ny);
        v_tag := '@' || nx || ',' || ny;
        continue when v_tag = any(v_out);
        v_out := v_out || v_tag;
      end loop;
    end loop;
  end loop;

  return v_out;
end
$function$;

-- ---------------------------------------------------------------------------
-- 3. bot_step itself: splice in the actual scoring/execution wiring so a
--    scored ability candidate can win and get played. See this migration's
--    own header above for the full rationale; this part is purely the
--    mechanical wiring into the existing move/attack scoring loop, done via
--    pg_get_functiondef()+replace() against bot_step's own live source so
--    nothing here is retyped from memory.
-- ---------------------------------------------------------------------------

do $$
declare def text; v_before text;
begin
  def := pg_get_functiondef('public.bot_step(uuid,text)'::regprocedure);

  -- ---- 1. new locals for ability scoring ---------------------------------
  v_before := def;
  def := replace(def,
    $rep$  v_answers boolean; v_parry boolean;
begin$rep$,
    $rep$  v_answers boolean; v_parry boolean;
  -- 0148: ability scoring -- see cn_bot_score_ability/cn_bot_ability_tiles.
  v_ab_kind text; v_ab_ready boolean; v_ab_max_uses int; v_ab_cooldown int;
  v_ab_used int; v_ab_last_used int; v_ab_turn_no int; v_ab_n int;
  v_ab_score numeric; v_ab_needs_target boolean; v_ab_needs_tile boolean;
  v_ab_tiles text[]; v_ab_tile text; v_dx int; v_dy int; t2 jsonb;
  v_bkind text; v_fkind text;
begin$rep$);
  if def = v_before then raise exception '0148: bot_step -- declare target not found'; end if;

  -- ---- 2. a move candidate is never an ability -- keep v_bkind/v_fkind in
  -- step whenever a move candidate becomes the new best/fallback. --------
  v_before := def;
  def := replace(def,
    $rep$        if v_step_s > v_best then
          v_best := v_step_s;
          v_bu := u->>'id'; v_bx := vx; v_by := vy; v_bt := null;
        end if;
        if v_step_s > v_fb then
          v_fb := v_step_s;
          v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := null;
        end if;$rep$,
    $rep$        if v_step_s > v_best then
          v_best := v_step_s;
          v_bu := u->>'id'; v_bx := vx; v_by := vy; v_bt := null; v_bkind := null;
        end if;
        if v_step_s > v_fb then
          v_fb := v_step_s;
          v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := null; v_fkind := null;
        end if;$rep$);
  if def = v_before then raise exception '0148: bot_step -- move-candidate target not found'; end if;

  -- ---- 3. the big one: tag attack candidates as 'attack', and insert the
  -- whole ability-scoring section right after the attack-candidate loop
  -- (still inside the per-unit, per-tile loop, gated to the unit's actual
  -- current tile), before that loop closes. Also tags the fallback-adoption
  -- step so v_bkind carries through if nothing beat 0 outright. -----------
  v_before := def;
  def := replace(def,
    $rep$        v_noise := random() * v_noise_scale;
        if v_pos + v_act - v_base + v_noise > v_best then
          v_best := v_pos + v_act - v_base + v_noise;
          v_bu := u->>'id'; v_bx := vx; v_by := vy; v_bt := t->>'id';
        end if;
        if v_pos + v_act - v_base + v_noise > v_fb then
          v_fb := v_pos + v_act - v_base + v_noise;
          v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := t->>'id';
        end if;
      end loop;
    end loop;
  end loop;

  if v_bu is null and v_fu is not null then
    v_bu := v_fu; v_bx := v_fbx; v_by := v_fby; v_bt := v_ft;
  end if;$rep$,
    $rep$        v_noise := random() * v_noise_scale;
        if v_pos + v_act - v_base + v_noise > v_best then
          v_best := v_pos + v_act - v_base + v_noise;
          v_bu := u->>'id'; v_bx := vx; v_by := vy; v_bt := t->>'id'; v_bkind := 'attack';
        end if;
        if v_pos + v_act - v_base + v_noise > v_fb then
          v_fb := v_pos + v_act - v_base + v_noise;
          v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := t->>'id'; v_fkind := 'attack';
        end if;
      end loop;

      -- 0148: strategic ability use -- Jared: "make the bot even smarter
      -- ... I want it to use abilities very strategically too!" Scored
      -- once per unit, at its CURRENT tile only (cn_ability always checks
      -- range/LOS from where the unit actually stands, exactly like
      -- cn_attack does above) -- a unit that needs to close distance first
      -- still gets there over a later bot_step call, same as move-then-
      -- attack already works today.
      if vx = (u->>'x')::int and vy = (u->>'y')::int
         and not (u->>'acted')::boolean
         and u->>'abilityKind' is not null
         and not cn_stunned(u) and not cn_swamped(st, u)
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
            -- The general case: actually run the card's own ON_ABILITY
            -- script on a scratch copy of the state (cn_bot_score_ability
            -- calls cn_run_effects, a pure function -- nothing here is
            -- committed) and score whatever it really did, rather than
            -- hand-copying each card's authored sentence. This is what
            -- makes a two-condition ability (apply a status if it isn't
            -- there yet, otherwise cash it in for damage) come out right
            -- without a single line here knowing that card exists -- the
            -- real ON_ABILITY conditions decide that, same as they do for
            -- a human player.
            v_ab_needs_target := exists (
              select 1 from jsonb_array_elements(coalesce(u->'abilityScript', '[]'::jsonb)) r
               where r->>'trigger' = 'ON_ABILITY' and r->>'target_selector' = 'THE_TARGET');
            v_ab_needs_tile := exists (
              select 1 from jsonb_array_elements(coalesce(u->'abilityScript', '[]'::jsonb)) r
               where r->>'trigger' = 'ON_ABILITY' and r->>'target_selector' = 'BOARD_CELL');

            v_ab_score := cn_bot_score_ability(st, p_side, u, null, v_w);
            if v_ab_score is not null then
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

            if v_ab_needs_target then
              for t2 in select * from jsonb_array_elements(st->'units') loop
                continue when (t2->>'hp')::int <= 0;
                v_ab_score := cn_bot_score_ability(st, p_side, u, t2->>'id', v_w);
                if v_ab_score is not null then
                  v_step_s := v_pos + v_ab_score - v_base + random() * v_noise_scale;
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
                  v_step_s := v_pos + v_ab_score - v_base + random() * v_noise_scale;
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
  end if;$rep$);
  if def = v_before then raise exception '0148: bot_step -- attack-candidate/ability-block target not found'; end if;

  -- ---- 4. execution: an ability-kind winner calls cn_ability, not
  -- cn_attack. -------------------------------------------------------------
  v_before := def;
  def := replace(def,
    $rep$  if v_bt is not null then
    m := cn_attack(p_match, p_side, v_bu, v_bt);
    if m.is_sim then
      update public.matches set state = jsonb_set(coalesce(m.state, '{}'::jsonb), '{lastBotAction}',
        jsonb_build_object('side', p_side, 'unit', v_bu, 'target', v_bt, 'kind', 'attack'))
      where id = m.id returning * into m;
    end if;
    return m;
  end if;$rep$,
    $rep$  if v_bkind = 'ability' then
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
  end if;$rep$);
  if def = v_before then raise exception '0148: bot_step -- execution-block target not found'; end if;

  execute def;
end $$;
