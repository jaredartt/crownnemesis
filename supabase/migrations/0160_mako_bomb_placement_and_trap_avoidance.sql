-- Jared, watching an Expert bot match: "the Expert bot literally made Mako
-- spawn a bomb in the first row, and then Dorme stepped on it and literally
-- got burned herself. Such a dumb play." -- followed by a concrete brief:
-- Mako should only place his bomb strategically in the middle of the map,
-- close to the king, or in a way that blocks units that don't have a range
-- superior to one; and bots shouldn't step on their own bombs.
--
-- Two separate bugs, both pre-existing (neither touched by 0158's
-- animations work or 0159's create_bot_match fix):
--
-- (1) WHERE Mako drops the bomb -- cn_bot_ability_tiles(), the generic
-- helper every scripted BOARD_CELL ability uses to find candidate tiles,
-- only ever grows its search out from two neighborhoods: the unit's own
-- square, and the closest raw enemy. For a card whose entire doctrine
-- (0149) is walling off the path to OUR OWN king, "near our king" and "the
-- middle of the map" were never even IN the candidate set -- no amount of
-- scoring in cn_bot_strategy_bonus could pick a tile that was silently
-- dropped before scoring ever saw it. And the scoring itself only kicked in
-- once a specific named threat (an enemy royal, or Dione & Grifo/Lium) was
-- already in range of MY king -- with no such threat spotted yet (the
-- common case early in a match), Mako's tile score was flat across every
-- candidate and pure noise decided, which is exactly how a bomb ends up on
-- whatever front-row tile the noise favored.
--
-- (2) BOTS STEPPING ON BOMBS -- cn_trap_at() finds a live bomb at a tile
-- and cn_spring() hurts whoever lands there, with no owner check at all
-- (by design -- a bomb is a hazard to anyone, per the structures table's
-- own description). But bot_step(), which scores every tile a unit could
-- move to, never once called cn_trap_at -- it had no idea a bomb was even
-- there. Not an Expert-only gap either: any bot level can walk face-first
-- into a bomb today.
--
-- Fixes:
--   (a) cn_bot_ability_tiles -- for mako/lumea specifically, also seed the
--       candidate search from our own king's tile and the board's center.
--       Every tile this adds still has to pass the existing
--       cn_cheb(...) <= v_rmax check against the unit's OWN position, so
--       this can never offer a tile out of the unit's actual reach.
--   (b) cn_bot_wall_tile_bonus (NEW) -- factors the "where's a good choke
--       tile" scoring out of cn_bot_strategy_bonus so Mako and Lumea (while
--       her tornado is still unused -- same doctrine, 0149's own comment
--       says so) share it. Scores, take the best of: (i) the original
--       named-threat logic unchanged, (ii) NEW: being on the king's side of
--       ANY living enemy with rmax <= 1 -- "blocks units that don't have a
--       range superior to one" -- not just the handful of named threats,
--       (iii) NEW: flat proximity to our own king, (iv) NEW: flat proximity
--       to the board's center. (iii)/(iv) need no visible enemy at all, so
--       an early bomb no longer rides on noise alone.
--   (c) bot_step -- score a cn_trap_at() penalty (scaled by the trap's own
--       damage, plus a lethal top-up) against any candidate tile that
--       differs from the unit's current one. Deliberately NOT gated to
--       v_lvl = 3: not walking into a bomb you can see is baseline sense
--       for every bot level, not an Expert-only strategy call. A bot can
--       still be forced through one if literally every option is worse
--       (bot_step already falls back to "best of the bad options" when
--       nothing scores positively), same as any other steep penalty here.

create or replace function public.cn_bot_wall_tile_bonus(
  v_st jsonb, v_my_king jsonb, v_opp text, p_vx int, p_vy int,
  v_threat jsonb, v_threat_d int
) returns numeric
language plpgsql as $function$
declare
  v_kd int := cn_cheb(p_vx, p_vy, (v_my_king->>'x')::int, (v_my_king->>'y')::int);
  v_board_w int := coalesce((v_st->'board'->>'w')::int, 8);
  v_board_h int := coalesce((v_st->'board'->>'h')::int, 8);
  v_cd int := cn_cheb(p_vx, p_vy, v_board_w / 2, v_board_h / 2);
  v_threat_bonus numeric := 0;
  v_melee_bonus numeric := 0;
  qm jsonb; v_qd int; v_qkd int;
begin
  -- (i) Jared's original ask (0149): wall off the path between OUR king and
  -- whichever named breakthrough threat -- an enemy royal, or Dione & Grifo/
  -- Lium specifically -- is closest to it. A tile on the king's side of
  -- that threat, close enough to actually matter.
  if v_threat is not null and v_kd < v_threat_d then
    v_threat_bonus := 60 + greatest(0, 8 - cn_cheb(p_vx, p_vy, (v_threat->>'x')::int, (v_threat->>'y')::int)) * 8;
  end if;

  -- (ii) Jared: "or in a way that blocks units that don't have a range
  -- superior to one." A melee (rmax<=1) enemy has to walk up adjacent to
  -- swing at all, so sitting on the king's side of ANY living melee enemy --
  -- not only the named threats above -- is worth something, even before one
  -- of those named threats is close enough to matter.
  for qm in select * from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) loop
    if qm->>'owner' = v_opp and (qm->>'hp')::int > 0 and coalesce((qm->>'rmax')::int, 1) <= 1 then
      v_qkd := cn_cheb((qm->>'x')::int, (qm->>'y')::int, (v_my_king->>'x')::int, (v_my_king->>'y')::int);
      if v_kd < v_qkd then
        v_qd := cn_cheb(p_vx, p_vy, (qm->>'x')::int, (qm->>'y')::int);
        v_melee_bonus := greatest(v_melee_bonus, 40 + greatest(0, 6 - v_qd) * 8);
      end if;
    end if;
  end loop;

  -- (iii)/(iv) Jared: "in the middle of the map, or close to the king."
  -- Neither needs a visible enemy at all -- this is what keeps an early
  -- bomb, dropped before anything is actually bearing down, from landing on
  -- whatever tile pure noise happened to favor.
  return greatest(v_threat_bonus, v_melee_bonus,
    greatest(0, 5 - v_kd) * 10,
    greatest(0, 4 - v_cd) * 9);
end
$function$;

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
  -- kings, so they don't pass" -- and (this session) that placement itself
  -- has to be strategic: the middle of the map, close to the king, or
  -- somewhere it actually blocks a melee (rmax<=1) threat. See
  -- cn_bot_wall_tile_bonus for the full scoring; this card no longer
  -- requires a named threat to already be in range before it has an
  -- opinion about where to drop the bomb.
  -- =========================================================================
  elsif v_slug = 'mako' and p_kind = 'ability' and p_target_id is not null and left(p_target_id, 1) = '@'
        and v_my_king is not null then
    v_bonus := v_bonus + cn_bot_wall_tile_bonus(v_st, v_my_king, v_opp, p_vx, p_vy, v_threat, v_threat_d);

  -- =========================================================================
  -- LUMEA -- "same as Mako, but once she spawns her tornado, she goes forth
  -- to attack." Same choke-tile bonus as Mako while unused (now routed
  -- through the same shared cn_bot_wall_tile_bonus); once her abilityUses
  -- shows she has cast it, the doctrine flips to aggressive.
  -- =========================================================================
  elsif v_slug = 'lumea' then
    if coalesce((u->>'abilityUses')::int, 0) = 0 then
      if p_kind = 'ability' and p_target_id is not null and left(p_target_id, 1) = '@'
         and v_my_king is not null then
        v_bonus := v_bonus + cn_bot_wall_tile_bonus(v_st, v_my_king, v_opp, p_vx, p_vy, v_threat, v_threat_d);
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

create or replace function public.cn_bot_ability_tiles(v_st jsonb, p_unit jsonb)
 returns text[]
 language plpgsql
as $function$
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

  -- Jared: Mako dropped its bomb in the front row instead of somewhere that
  -- actually reads as a choke point. Root cause: this search only ever grew
  -- candidate tiles out from two neighborhoods -- the unit's own square and
  -- the closest raw enemy -- so "near our king" or "the middle of the map"
  -- were never even IN the candidate set for cn_bot_strategy_bonus to
  -- score, no matter how good a tile there might have been. Mako and Lumea
  -- (while her tornado is still unused) are the two cards whose whole
  -- doctrine is walling off the path to OUR OWN king, so give just their
  -- search two more neighborhoods: our king's own tile, and the board's
  -- center. Every tile this produces still has to clear the same
  -- cn_cheb(...) <= v_rmax check below against the unit's OWN position, so
  -- this can never hand back a tile the unit couldn't actually reach -- it
  -- only stops silently dropping the good ones before they're considered.
  if p_unit->>'slug' in ('mako', 'lumea') then
    for q in select * from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) loop
      if q->>'owner' = p_unit->>'owner' and coalesce((q->>'royal')::boolean, false) then
        v_seed_x := v_seed_x || (q->>'x')::int;
        v_seed_y := v_seed_y || (q->>'y')::int;
      end if;
    end loop;
    if v_w > 0 and v_h > 0 then
      v_seed_x := v_seed_x || (v_w / 2);
      v_seed_y := v_seed_y || (v_h / 2);
    end if;
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
  -- 0148: ability scoring -- see cn_bot_score_ability/cn_bot_ability_tiles.
  v_ab_kind text; v_ab_ready boolean; v_ab_max_uses int; v_ab_cooldown int;
  v_ab_used int; v_ab_last_used int; v_ab_turn_no int; v_ab_n int;
  v_ab_score numeric; v_ab_needs_target boolean; v_ab_needs_tile boolean;
  v_ab_tiles text[]; v_ab_tile text; v_dx int; v_dy int; t2 jsonb;
  v_bkind text; v_fkind text; v_strat numeric;
  -- 0160: bomb-avoidance -- see cn_trap_at just below.
  v_trap jsonb; v_trap_dmg int;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null then return m; end if;
  v_opp := case when p_side = 'host' then 'guest' else 'host' end;
  v_lvl := case when p_side = 'guest' then m.bot else m.host_bot end;
  if v_lvl is null then return m; end if;
  if m.status <> 'active' then return m; end if;
  if m.state->>'turn' <> p_side then return m; end if;

  st := m.state;

  -- ---- coefficients: an explicit override on the match, else whichever
  -- brain is live for this level, else the hardcoded pre-0114 numbers. ----
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

      -- 0160: Jared: "bots shouldn't just step in their own bombs."
      -- cn_trap_at doesn't care whose bomb it is -- cn_spring hurts ANY
      -- unit that lands on one -- and until now nothing in this scoring
      -- loop ever looked. Deliberately NOT gated to v_lvl = 3: not walking
      -- into a bomb you can see is baseline sense, not an Expert-only
      -- strategy call. Only fires for an actual move (vx,vy differs from
      -- the unit's own tile) -- standing where you already stand can't
      -- "step on" anything new.
      if vx <> (u->>'x')::int or vy <> (u->>'y')::int then
        v_trap := cn_trap_at(st, vx, vy);
        if v_trap is not null then
          v_trap_dmg := coalesce((v_trap->>'dmg')::int, 0);
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
