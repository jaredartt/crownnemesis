-- 0077: burn also costs you for USING AN ABILITY, not only for swinging.
--
-- Jared: "make it so that burn hurts anytime you attack, use an ability
-- (not a passive), counter-attack, or deal damage with parry."
--
-- Three of those four already happened. cn_attack's own chain loop (see
-- its "Swinging while alight costs you" comment, and the dedicated check
-- in its Quick Dagger branch just above the chain) already charges
-- cn_burn_pct() of maxHp to whichever unit is CURRENTLY SWINGING, on every
-- iteration -- the opening attack, an ordinary counter, and a parry that
-- answers (which flips the swing back the parrier's way and runs through
-- that exact same loop) are all just different iterations of one chain.
-- Attacking a tree/wall has its own dedicated check right beside it, for
-- the one branch that never enters the chain at all.
--
-- Using an ability never went anywhere near cn_attack, so it never paid
-- this cost -- the one real gap, closed here.
--
-- "NOT A PASSIVE" needed no extra gate. A passive is a card_effects row
-- whose trigger fires on some OTHER event (ON_DAMAGED, START_OF_TURN,
-- PASSIVE itself, and so on) via cn_run_effects, called from wherever that
-- event actually happens -- never from this RPC. cn_ability only ever runs
-- when a player spends an action on submit_ability, which is what "using
-- an ability" means on this roster; a scripted ability's own ON_ABILITY
-- effects (ivy's poison, say) are the one case that also happens to call
-- cn_run_effects, but that call is still gated on having reached this
-- function through an active use, not on the trigger name alone. So every
-- path through cn_ability already is exactly the case to charge, and no
-- unrelated passive can ever reach this new check.
--
-- The charge itself mirrors cn_attack's precisely: cn_effect_dmg() against
-- the caster's own maxHp (aura resist included), taken after whatever the
-- ability itself did -- a scripted ability that targets 'self' (Jared's
-- own MODIFY_STAT/DEAL_DAMAGE vocabulary allows it) has already landed by
-- the time this reads the caster's row out of v_out, so the burn is on top
-- of that, not instead of it. If it kills the caster, they are buried
-- (cn_bury) the same way a burn-killed attacker already is in cn_attack --
-- not left on the board at zero or negative hp -- and cn_end_act, called
-- unconditionally right after, already no-ops safely for a unit no longer
-- in `units` (it just cannot find `p_unit` to flag `spent`), so nothing
-- downstream needs to know the caster is gone.
--
-- Deliberately NOT wired into cn_run_effects' ON_DAMAGED/ON_DEATH hooks:
-- cn_ability fires neither today for ANY of its own damage (an aoe_adjacent
-- or poison_hit kill does not fire ON_DEATH either), so a self-burn death
-- here is consistent with the level of hook support this function already
-- has, not a new gap of its own.
create or replace function public.cn_ability(p_match uuid, p_side text, p_unit text, p_target text)
returns matches
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  m public.matches; v_st jsonb; u jsonb; e jsonb;
  v_me jsonb; v_tgt jsonb; v_kind text; v_n int;
  v_out jsonb := '[]'::jsonb; v_rocks jsonb := '[]'::jsonb;
  v_hits jsonb := '[]'::jsonb; v_swings jsonb := '[]'::jsonb;
  v_dist int; v_got int; v_hp int; v_felled boolean := false;
  v_dx int; v_dy int; v_what text; v_tile int[];
  v_note text; v_seq int;
  v_turn_no int; v_max_uses int; v_cooldown int; v_used int; v_last_used int;
  -- 0077: what using this ability costs a caster who is on fire, and
  -- whether it was the thing that finished them.
  v_burn int := 0; v_killed_self boolean := false; v_final jsonb;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'active' then raise exception 'match is not running'; end if;
  v_st := m.state;
  if v_st->>'turn' <> p_side then raise exception 'not your turn'; end if;

  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then v_me := u; end if;
    if p_target is not null and u->>'id' = p_target then v_tgt := u; end if;
  end loop;
  if v_me is null then raise exception 'no such unit'; end if;
  if v_me->>'owner' <> p_side then raise exception 'that is not your unit'; end if;
  if (v_me->>'acted')::boolean then raise exception 'that unit already acted'; end if;
  if cn_stunned(v_me) then raise exception 'that unit is stunned'; end if;

  if cn_swamped(v_st, v_me) then raise exception 'that unit is in the swamp'; end if;
  v_me := cn_awake(v_st, v_me);

  v_kind := v_me->>'abilityKind';
  if v_kind is null then raise exception 'that unit has no ability'; end if;
  v_n := coalesce((v_me->>'abilityN')::int, 0);

  v_turn_no := coalesce((v_st->>'turnNumber')::int, 1);
  v_max_uses := nullif(v_me->>'abilityMaxUses', '')::int;
  v_cooldown := coalesce(nullif(v_me->>'abilityCooldownTurns', '')::int, 0);
  v_used := coalesce((v_me->>'abilityUses')::int, 0);
  v_last_used := nullif(v_me->>'abilityLastUsedTurn', '')::int;
  if v_max_uses is not null and v_used >= v_max_uses then
    raise exception 'that ability has no uses left this match';
  end if;
  if v_cooldown > 0 and v_last_used is not null
     and v_turn_no - v_last_used <= v_cooldown then
    raise exception 'that ability is on cooldown for % more turn(s)',
      v_cooldown - (v_turn_no - v_last_used) + 1;
  end if;
  v_me := jsonb_set(v_me, '{abilityUses}', to_jsonb(v_used + 1));
  v_me := jsonb_set(v_me, '{abilityLastUsedTurn}', to_jsonb(v_turn_no));

  v_st := cn_begin_act(v_st, p_side, p_unit);
  v_seq := coalesce((v_st->'fx'->>'seq')::int, 0) + 1;

  if v_kind = 'aoe_adjacent' then
    for u in select * from jsonb_array_elements(v_st->'units') loop
      if u->>'id' <> p_unit
         and cn_cheb((v_me->>'x')::int, (v_me->>'y')::int,
                     (u->>'x')::int, (u->>'y')::int) = 1 then
        v_hp := (u->>'hp')::int - v_n;
        u := jsonb_set(u, '{hp}', to_jsonb(v_hp));
        v_hits := v_hits || jsonb_build_object('id', u->>'id', 'dmg', v_n);
        v_swings := v_swings || jsonb_build_object(
          'k', 'hit', 'by', p_unit, 'at', u->>'id', 'dmg', v_n,
          'crit', false, 'counter', false, 'first', false, 'def', false,
          'why', 'ability');
      end if;
      if (u->>'hp')::int > 0 then v_out := v_out || u; end if;
    end loop;
    for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
      if cn_cheb((v_me->>'x')::int, (v_me->>'y')::int,
                 (e->>'x')::int, (e->>'y')::int) = 1 then
        e := jsonb_set(e, '{hp}', to_jsonb((e->>'hp')::int - v_n));
        v_felled := v_felled or (e->>'hp')::int <= 0;
      end if;
      if (e->>'hp')::int > 0 then v_rocks := v_rocks || e; end if;
    end loop;
    v_st := jsonb_set(v_st, '{obstacles}', v_rocks);
    v_note := (v_me->>'name') || ' strikes every tile around them for ' || v_n || '.';

  elsif v_kind = 'heal_any' then
    if v_tgt is null then raise exception 'that ability needs a target'; end if;
    v_dist := cn_cheb((v_me->>'x')::int, (v_me->>'y')::int,
                      (v_tgt->>'x')::int, (v_tgt->>'y')::int);
    if v_dist > (v_me->>'rmax')::int then raise exception 'out of range'; end if;
    if not cn_los_clear(v_st, (v_me->>'x')::int, (v_me->>'y')::int,
                        (v_tgt->>'x')::int, (v_tgt->>'y')::int) then
      raise exception 'a tree is in the way';
    end if;
    for u in select * from jsonb_array_elements(v_st->'units') loop
      if u->>'id' = p_target then
        v_got := least((u->>'maxHp')::int - (u->>'hp')::int, v_n);
        u := jsonb_set(u, '{hp}', to_jsonb((u->>'hp')::int + v_got));
      end if;
      v_out := v_out || u;
    end loop;
    v_hits := jsonb_build_array(jsonb_build_object('id', p_target, 'heal', v_got));
    v_swings := jsonb_build_array(jsonb_build_object(
      'k', 'heal', 'by', p_unit, 'at', p_target, 'dmg', v_got,
      'crit', false, 'counter', false, 'first', false, 'def', false,
      'why', 'mend'));
    v_note := (v_me->>'name') || ' mends ' || (v_tgt->>'name') || ' for ' || v_got || '.';

  elsif v_kind = 'mist' then
    if v_st->'mist' is null then
      v_st := jsonb_set(v_st, '{mist}', '{}'::jsonb, true);
    end if;
    v_st := jsonb_set(
      v_st, array['mist', p_side],
      jsonb_build_object('t', coalesce((v_me->>'abilityTurns')::int, 1), 'pct', v_n),
      true);
    v_out := v_st->'units';
    v_note := (v_me->>'name') || ' calls up the mist.';

  elsif v_kind = 'poison_hit' then
    if v_tgt is null then raise exception 'that ability needs a target'; end if;
    if v_tgt->>'owner' = p_side then raise exception 'no friendly fire'; end if;
    v_dist := cn_cheb((v_me->>'x')::int, (v_me->>'y')::int,
                      (v_tgt->>'x')::int, (v_tgt->>'y')::int);
    if v_dist > (v_me->>'rmax')::int then raise exception 'out of range'; end if;
    if not cn_los_clear(v_st, (v_me->>'x')::int, (v_me->>'y')::int,
                        (v_tgt->>'x')::int, (v_tgt->>'y')::int) then
      raise exception 'a tree is in the way';
    end if;
    for u in select * from jsonb_array_elements(v_st->'units') loop
      if u->>'id' = p_target then
        u := cn_afflict(u, 'poison', 'true'::jsonb);
        u := jsonb_set(u, '{hp}', to_jsonb((u->>'hp')::int - v_n));
        v_hits := v_hits || jsonb_build_object('id', u->>'id', 'dmg', v_n);
        v_swings := v_swings || jsonb_build_object(
          'k', 'hit', 'by', p_unit, 'at', u->>'id', 'dmg', v_n,
          'crit', false, 'counter', false, 'first', false, 'def', false,
          'why', 'poison');
      end if;
      if (u->>'hp')::int > 0 then v_out := v_out || u; end if;
    end loop;
    v_note := (v_me->>'name') || ' poisons ' || (v_tgt->>'name') || '.';

  elsif v_kind = 'line_burn' then
    if v_tgt is null then raise exception 'that ability needs a target'; end if;
    v_dist := cn_cheb((v_me->>'x')::int, (v_me->>'y')::int,
                      (v_tgt->>'x')::int, (v_tgt->>'y')::int);
    if v_dist > (v_me->>'rmax')::int then raise exception 'out of range'; end if;
    v_dx := sign((v_tgt->>'x')::int - (v_me->>'x')::int);
    v_dy := sign((v_tgt->>'y')::int - (v_me->>'y')::int);
    for u in select * from jsonb_array_elements(v_st->'units') loop
      if ((u->>'x')::int = (v_tgt->>'x')::int and (u->>'y')::int = (v_tgt->>'y')::int)
         or ((u->>'x')::int = (v_tgt->>'x')::int + v_dx
             and (u->>'y')::int = (v_tgt->>'y')::int + v_dy) then
        u := cn_afflict(u, 'burn', 'true'::jsonb);
        u := jsonb_set(u, '{hp}', to_jsonb((u->>'hp')::int - v_n));
        v_hits := v_hits || jsonb_build_object('id', u->>'id', 'dmg', v_n);
        v_swings := v_swings || jsonb_build_object(
          'k', 'hit', 'by', p_unit, 'at', u->>'id', 'dmg', v_n,
          'crit', false, 'counter', false, 'first', false, 'def', false,
          'why', 'fire');
      end if;
      if (u->>'hp')::int > 0 then v_out := v_out || u; end if;
    end loop;
    v_note := (v_me->>'name') || ' sets two tiles alight for ' || v_n || '.';

  elsif v_kind = 'summon' then
    v_what := v_me->>'summonKind';
    if v_what is null then raise exception 'that unit summons nothing'; end if;

    for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
      if e->>'by' = p_unit then raise exception 'that summon is still standing'; end if;
    end loop;

    v_tile := cn_tile_target(p_target);
    if v_tile is null then raise exception 'that ability needs a tile'; end if;
    if v_tile[1] < 0 or v_tile[2] < 0
       or v_tile[1] >= (v_st->'board'->>'w')::int
       or v_tile[2] >= (v_st->'board'->>'h')::int then
      raise exception 'that tile is not on the board';
    end if;
    v_dist := cn_cheb((v_me->>'x')::int, (v_me->>'y')::int, v_tile[1], v_tile[2]);
    if v_dist < 1 or v_dist > (v_me->>'rmax')::int then
      raise exception 'out of range';
    end if;
    if not cn_los_clear(v_st, (v_me->>'x')::int, (v_me->>'y')::int,
                        v_tile[1], v_tile[2]) then
      raise exception 'a tree is in the way';
    end if;

    for u in select * from jsonb_array_elements(v_st->'units') loop
      if (u->>'x')::int = v_tile[1] and (u->>'y')::int = v_tile[2] then
        raise exception 'that tile is taken';
      end if;
      v_out := v_out || u;
    end loop;
    for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
      if (e->>'x')::int = v_tile[1] and (e->>'y')::int = v_tile[2] then
        raise exception 'that tile is taken';
      end if;
      v_rocks := v_rocks || e;
    end loop;

    v_rocks := v_rocks || jsonb_build_object(
      'id', 's' || v_seq || ':' || p_unit, 'kind', v_what,
      'x', v_tile[1], 'y', v_tile[2],
      'hp', cn_obj_hp(v_what), 'maxHp', cn_obj_hp(v_what),
      'owner', p_side, 'by', p_unit, 'dmg', v_n);
    v_st := jsonb_set(v_st, '{obstacles}', v_rocks);
    v_note := (v_me->>'name') || ' sets down ' || cn_obj_name(v_what) || '.';

  elsif v_kind = 'scripted' then
    declare v_ctx jsonb := jsonb_build_object('turnNumber', coalesce((v_st->>'turnNumber')::int, 1));
    begin
      if v_tgt is not null then v_ctx := v_ctx || jsonb_build_object('target', v_tgt); end if;
      if p_target is not null and left(p_target, 1) = '@' then
        v_ctx := v_ctx || jsonb_build_object('tile', p_target);
      end if;
      v_st := cn_run_effects(v_st, 'ON_ABILITY', v_me, v_ctx);
    end;
    v_out := v_st->'units';
    v_note := (v_me->>'name') || ' uses ' ||
      coalesce(nullif(btrim(split_part(v_me->>'ability', '—', 1)), ''), 'an ability') || '.';
  else
    raise exception 'that ability is not built yet: %', v_kind;
  end if;

  -- 0077: one pass over v_out -- patch the caster's own abilityUses/
  -- abilityLastUsedTurn (as before 0077) and, new here, its burn cost, at
  -- the same rate cn_attack charges (cn_burn_pct() of maxHp, aura resist
  -- included) -- read off the caster's row IN v_out rather than the v_me
  -- snapshot from before the dispatch above, since 'scripted' may already
  -- have changed it via its own ON_ABILITY effects, and every branch above
  -- populates v_out with every unit (struck or not), so the caster's
  -- current row is always in there. Bury it (cn_bury), instead of leaving
  -- a zero-or-negative-hp row on the board, if that cost was lethal -- the
  -- same treatment cn_attack already gives a burn-killed attacker.
  v_final := '[]'::jsonb;
  for u in select * from jsonb_array_elements(v_out) loop
    if u->>'id' = p_unit then
      u := jsonb_set(u, '{abilityUses}', v_me->'abilityUses');
      u := jsonb_set(u, '{abilityLastUsedTurn}', v_me->'abilityLastUsedTurn');
      if cn_has(v_me, 'burn') then
        v_burn := cn_effect_dmg(v_st, u, cn_burn_pct());
        u := jsonb_set(u, '{hp}', to_jsonb((u->>'hp')::int - v_burn));
        v_killed_self := (u->>'hp')::int <= 0;
      end if;
      if v_killed_self then
        v_st := cn_bury(v_st, u);
      else
        v_final := v_final || u;
      end if;
    else
      v_final := v_final || u;
    end if;
  end loop;
  v_out := v_final;
  if v_burn > 0 then
    v_hits := v_hits || jsonb_build_object('id', p_unit, 'dmg', v_burn);
    v_swings := v_swings || jsonb_build_object(
      'k', 'burn', 'by', p_unit, 'at', p_unit, 'dmg', v_burn);
  end if;
  v_st := jsonb_set(v_st, '{units}', v_out);
  v_st := cn_end_act(v_st, p_unit);
  v_st := state_log(v_st, v_note);
  if v_felled then v_st := state_log(v_st, 'A tree comes down.'); end if;
  if v_burn > 0 then
    v_st := state_log(v_st, (v_me->>'name') || ' burns for ' || v_burn
      || case when v_killed_self then ' -- destroyed.' else '.' end);
  end if;

  v_st := jsonb_set(v_st, '{fx}', jsonb_build_object(
    'seq', v_seq, 'kind', 'ability', 'atk', p_unit, 'tgt', p_target,
    'why', v_kind, 'hits', v_hits, 'swings', v_swings,
    'dmg', 0, 'heal', 0, 'counter', 0, 'burnAtk', v_burn, 'burnTgt', 0,
    'killedTgt', false, 'killedAtk', v_killed_self, 'newBurn', false,
    'cured', false, 'parry', false, 'tree', false), true);

  update public.matches
     set state = v_st,
         turn_deadline = turn_deadline
           + (cn_cine_ms(v_swings) || ' milliseconds')::interval,
         updated_at = now()
   where id = m.id returning * into m;
  return m;
end $function$;

-- ---------------------------------------------------------------------------
-- self-check
-- ---------------------------------------------------------------------------
do $$
declare
  v_def text; v_burnt jsonb; v_dmg int;
begin
  v_def := pg_get_functiondef('public.cn_ability(uuid,text,text,text)'::regprocedure);
  if v_def !~ '0077' then
    raise exception 'cn_ability does not look like the 0077 definition';
  end if;

  -- cn_effect_dmg itself, unit-tested in isolation from any match: 15% of
  -- maxHp, at least 1, matching what cn_attack has always charged. If this
  -- ever drifts cn_ability's own charge drifts with it for free, since it
  -- calls the exact same function.
  v_burnt := jsonb_build_object('maxHp', 100, 'owner', 'host');
  v_dmg := cn_effect_dmg('{}'::jsonb, v_burnt, cn_burn_pct());
  if v_dmg <> 15 then
    raise exception 'expected cn_burn_pct of 100 maxHp to be 15, got %', v_dmg;
  end if;
end $$;
