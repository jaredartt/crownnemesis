-- Jared, on the Expert bot: "can we actually hard code some strategies
-- individually for each card?" -- followed by a detailed, card-by-card
-- brief (Wuzu waits to charge past 25 damage then goes for the king or its
-- defenders; Eva hangs back healing/guarding Fey, Sinie and Lium; Umiro
-- roams free; Mako and Lumea wall off dione-grifo/lium/the enemy king;
-- Lumea turns aggressive once her tornado is down; Dione & Grifo is a lone
-- infiltrator who is meant to trade itself; Dorme holds back behind the
-- king until almost nobody else is left, then finishes whoever is still
-- coming; Himanta stuns whoever is closest to threatening the king).
--
-- 0148 gave the bot a currency for "how good is this action" (HP/kill/
-- status deltas run through the real engine) but no opinion at all about
-- ROLE -- every unit, every card, was scored by the exact same yardstick.
-- This gives eleven of the thirteen live cards (every one Jared named, plus
-- himself the two royals get no special-casing at all -- letting a king
-- swing back at anyone adjacent, which 0148's plain scoring already does,
-- is exactly "let the king attack if someone gets near") an ADDITIVE bonus
-- on top of that same currency, read by slug, so a candidate that also
-- serves the card's own doctrine outscores an equally "good" candidate that
-- does not. Nothing here can make bot_step pick an action cn_bot_score_ability
-- or cn_attack's own math say is illegal or worthless -- this only tips
-- ties and near-ties toward what the card is FOR.
--
-- Scope: EXPERT (level 3, 'ruthless') only -- bot_step passes v_lvl through
-- and calls this at 0, effectively, for levels 1-2, so their existing,
-- simpler play is untouched. Battle Royale's bot is untouched too, same
-- scope note as 0148.
--
-- p_kind is 'move' (a tile the unit could step to but has not attacked or
-- used an ability from yet -- the POSITIONING question), 'attack' (a basic
-- strike, p_target_id set) or 'ability' (p_target_id a unit id, a '@x,y'
-- tile, or null for a no-target scripted row like Dione & Grifo's AOE).
-- (p_vx,p_vy) is always the tile the unit is standing on/considering for
-- this candidate, exactly like every other score in bot_step.
create or replace function public.cn_bot_strategy_bonus(
  v_st jsonb, p_side text, u jsonb, p_kind text, p_vx int, p_vy int, p_target_id text default null
) returns numeric
language plpgsql as $function$
declare
  v_slug text := u->>'slug';
  v_opp text := case when p_side = 'host' then 'guest' else 'host' end;
  v_my_king jsonb; v_opp_king jsonb;
  v_bonus numeric := 0;
  v_near_enemy int := 99;     -- distance from (p_vx,p_vy) to the nearest living enemy
  v_ally_support int := 0;    -- living allies, excluding self AND the king
  v_depth int;                -- how far into enemy territory (p_vx,p_vy) sits
  v_board_h int := coalesce((v_st->'board'->>'h')::int, 8);
  v_target jsonb;
  q jsonb; v_d int; v_avg_dmg numeric;
  -- Mako/Lumea's shared "who am I walling off" search: the nearest living
  -- enemy that is either a Royal or one of the two named breakthrough
  -- cards, whichever is closest to MY king specifically -- the whole point
  -- of a wall is standing between THAT and the crown, not just anyone.
  v_threat jsonb; v_threat_d int := 99;
begin
  if v_slug is null then return 0; end if;

  for q in select * from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) loop
    if (q->>'hp')::int <= 0 then continue; end if;
    if q->>'owner' = p_side and coalesce((q->>'royal')::boolean, false) then v_my_king := q; end if;
    if q->>'owner' = v_opp and coalesce((q->>'royal')::boolean, false) then v_opp_king := q; end if;
    if q->>'owner' = v_opp then
      v_d := cn_cheb(p_vx, p_vy, (q->>'x')::int, (q->>'y')::int);
      if v_d < v_near_enemy then v_near_enemy := v_d; end if;
    end if;
    if q->>'owner' = p_side and q->>'id' <> u->>'id' and not coalesce((q->>'royal')::boolean, false) then
      v_ally_support := v_ally_support + 1;
    end if;
  end loop;

  if v_my_king is not null then
    for q in select * from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) loop
      if q->>'owner' = v_opp and (q->>'hp')::int > 0
         and (coalesce((q->>'royal')::boolean, false) or q->>'slug' in ('dione-grifo', 'lium')) then
        v_d := cn_cheb((v_my_king->>'x')::int, (v_my_king->>'y')::int, (q->>'x')::int, (q->>'y')::int);
        if v_d < v_threat_d then v_threat_d := v_d; v_threat := q; end if;
      end if;
    end loop;
  end if;

  -- "Depth into enemy territory": 0 at your own back row, rising toward
  -- their side. Host starts at the top (y=0) and advances toward y=h-1;
  -- guest is the mirror. A cheap, slug-agnostic stand-in for "how far
  -- forward is this" that every forward-leaning card below shares.
  v_depth := case when p_side = 'host' then p_vy else v_board_h - 1 - p_vy end;

  if p_target_id is not null and left(p_target_id, 1) <> '@' then
    -- `qt`, not `q` -- `q` is already the loop variable declared above, and
    -- reusing it as this select's own FROM-clause alias makes every
    -- `qt->>'id'` reference here ambiguous to Postgres the moment this path
    -- actually runs (any real attack/ability target, e.g. Wuzu's charged
    -- king-targeting or Himanta's stun-scoring). Caught testing this file
    -- live before it ever reached git.
    select qt into v_target from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) qt
     where qt->>'id' = p_target_id;
  end if;

  -- =========================================================================
  -- WUZU -- "wait for Wuzu to have 25+ damage points, otherwise it hides or
  -- flees. When it has 25+, it goes brutal for the king or any king's
  -- defender." Its own power-growth passive (0147) is what actually moves
  -- dmin/dmax, so "25+ damage points" reads naturally as its average roll.
  -- =========================================================================
  if v_slug = 'wuzu' then
    v_avg_dmg := ((u->>'dmin')::int + (u->>'dmax')::int) / 2.0;
    if v_avg_dmg < 25 then
      if p_kind = 'move' then
        v_bonus := v_bonus + least(v_near_enemy, 6) * 18;  -- the farther from any threat, the better
      elsif p_kind = 'attack' then
        v_bonus := v_bonus - 260;  -- do not reveal an unripe Wuzu for a small hit
      end if;
    else
      if p_kind = 'move' and v_opp_king is not null then
        v_bonus := v_bonus + (10 - least(cn_cheb(p_vx, p_vy, (v_opp_king->>'x')::int, (v_opp_king->>'y')::int), 10)) * 12;
      elsif p_kind = 'attack' and v_target is not null and v_opp_king is not null then
        if coalesce((v_target->>'royal')::boolean, false)
           or cn_cheb((v_target->>'x')::int, (v_target->>'y')::int,
                      (v_opp_king->>'x')::int, (v_opp_king->>'y')::int) <= 2 then
          v_bonus := v_bonus + 260;  -- the king or one of its defenders -- go brutal
        else
          v_bonus := v_bonus - 40;  -- a real target elsewhere is still fine, just not preferred
        end if;
      end if;
    end if;

  -- =========================================================================
  -- EVA -- "always stays behind allies to heal them without getting hit,
  -- protects the ones destined to go forth and kill: Fey, Sinie, Lium."
  -- =========================================================================
  elsif v_slug = 'eva' then
    if p_kind = 'move' then
      v_bonus := v_bonus + least(v_near_enemy, 5) * 8;  -- a mild preference to stay out of the front line
      for q in select * from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) loop
        if q->>'owner' = p_side and q->>'slug' in ('fey', 'sinie', 'lium') and (q->>'hp')::int > 0 then
          v_d := cn_cheb(p_vx, p_vy, (q->>'x')::int, (q->>'y')::int);
          -- "needs it" -- hurt, or an enemy is already within striking reach of them.
          if (q->>'hp')::int < (q->>'maxHp')::int
             or exists (select 1 from jsonb_array_elements(v_st->'units') e
                         where e->>'owner' = v_opp and (e->>'hp')::int > 0
                           and cn_cheb((e->>'x')::int, (e->>'y')::int, (q->>'x')::int, (q->>'y')::int) <= 2) then
            v_bonus := v_bonus + greatest(0, 6 - v_d) * 12;
          end if;
        end if;
      end loop;
    elsif p_kind = 'ability' and v_target is not null and v_target->>'slug' in ('fey', 'sinie', 'lium') then
      v_bonus := v_bonus + 40;  -- tips a close call toward mending the carry, not a generic ally
    end if;

  -- =========================================================================
  -- UMIRO -- "can go on its own, either defending someone, or just going to
  -- the enemy territory by himself." No active ability to steer -- just a
  -- light forward lean so the general threat-aversion every other unit
  -- feels does not quietly keep him glued to the back row either.
  -- =========================================================================
  elsif v_slug = 'umiro' and p_kind = 'move' then
    v_bonus := v_bonus + least(v_depth, 4) * 5;

  -- =========================================================================
  -- MAKO -- "there to block with its bomb to Lium, Dione & Grifo, and even
  -- kings, so they don't pass." A structure earns this bonus for sitting
  -- BETWEEN that threat and my own king -- closer to my king than the
  -- threat is, and close enough to the threat to actually matter.
  -- =========================================================================
  elsif v_slug = 'mako' and p_kind = 'ability' and p_target_id is not null and left(p_target_id, 1) = '@'
        and v_threat is not null and v_my_king is not null then
    if cn_cheb(p_vx, p_vy, (v_my_king->>'x')::int, (v_my_king->>'y')::int) < v_threat_d then
      v_bonus := v_bonus + 60 + greatest(0, 8 - cn_cheb(p_vx, p_vy, (v_threat->>'x')::int, (v_threat->>'y')::int)) * 8;
    end if;

  -- =========================================================================
  -- LUMEA -- "same as Mako, but once she spawns her tornado, she goes forth
  -- to attack." Same choke-tile bonus as Mako while unused; once her
  -- abilityUses shows she has cast it, the doctrine flips to aggressive.
  -- =========================================================================
  elsif v_slug = 'lumea' then
    if coalesce((u->>'abilityUses')::int, 0) = 0 then
      if p_kind = 'ability' and p_target_id is not null and left(p_target_id, 1) = '@'
         and v_threat is not null and v_my_king is not null then
        if cn_cheb(p_vx, p_vy, (v_my_king->>'x')::int, (v_my_king->>'y')::int) < v_threat_d then
          v_bonus := v_bonus + 60 + greatest(0, 8 - cn_cheb(p_vx, p_vy, (v_threat->>'x')::int, (v_threat->>'y')::int)) * 8;
        end if;
      end if;
    else
      if p_kind = 'move' then
        v_bonus := v_bonus + (8 - least(v_near_enemy, 8)) * 10;  -- the tornado is down -- go fight
      end if;
    end if;

  -- =========================================================================
  -- DIONE & GRIFO -- "always on its own, 90% of the time infiltrate enemy
  -- territory and use its ability, regardless of dying early." The
  -- opposite instinct from everything else here: reward depth and enemy
  -- density outright, where the generic scoring elsewhere in bot_step
  -- would otherwise price that danger as a reason to hang back.
  -- =========================================================================
  elsif v_slug = 'dione-grifo' then
    if p_kind = 'move' then
      v_bonus := v_bonus + least(v_depth, 5) * 14;
      for q in select * from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) loop
        if q->>'owner' = v_opp and (q->>'hp')::int > 0 and cn_cheb(p_vx, p_vy, (q->>'x')::int, (q->>'y')::int) <= 2 then
          v_bonus := v_bonus + 20;  -- worth walking into -- her AOE wants company
        end if;
      end loop;
      -- her own safety is not the point -- undo the generic caution a low
      -- v_near_enemy would otherwise earn elsewhere in bot_step's scoring.
      v_bonus := v_bonus + greatest(0, 3 - v_near_enemy) * 15;
    elsif p_kind = 'ability' then
      v_bonus := v_bonus + 30;  -- ties go to using it, not holding it
    end if;

  -- =========================================================================
  -- DORME -- "used at the end, when no other unit can support the king (or
  -- maybe only 1 other), since it counters first. Then it's used to attack
  -- and counter first, to finish whoever still dares go for the king."
  -- =========================================================================
  elsif v_slug = 'dorme' then
    if v_ally_support > 1 then
      if p_kind = 'move' and v_my_king is not null then
        v_bonus := v_bonus + (6 - least(cn_cheb(p_vx, p_vy, (v_my_king->>'x')::int, (v_my_king->>'y')::int), 6)) * 10;
      elsif p_kind in ('attack', 'ability') then
        v_bonus := v_bonus - 150;  -- let the counter do the work -- do not go looking for a fight yet
      end if;
    else
      if p_kind = 'move' then
        v_bonus := v_bonus + (8 - least(v_near_enemy, 8)) * 14;  -- everyone else is spent -- go finish it
      elsif p_kind = 'attack' then
        v_bonus := v_bonus + 80;
      end if;
    end if;

  -- =========================================================================
  -- HIMANTA -- "stuns front attackers in the beginning, but can also stay
  -- behind to defend the king -- stunning attackers that focus on
  -- attacking the king, making them useless." Both readings share one
  -- target rule (whoever is nearest the king is the one worth stunning) and
  -- a mild pull toward the king itself, so she is naturally in position for
  -- it without ever being FORBIDDEN from just intercepting whoever is close.
  -- =========================================================================
  elsif v_slug = 'himanta' then
    if p_kind = 'attack' and v_target is not null and v_my_king is not null then
      v_bonus := v_bonus
        + greatest(0, 6 - cn_cheb((v_target->>'x')::int, (v_target->>'y')::int,
                                   (v_my_king->>'x')::int, (v_my_king->>'y')::int)) * 25;
    elsif p_kind = 'move' and v_my_king is not null then
      v_bonus := v_bonus + (6 - least(cn_cheb(p_vx, p_vy, (v_my_king->>'x')::int, (v_my_king->>'y')::int), 6)) * 8;
    end if;
  end if;

  return v_bonus;
end
$function$;
