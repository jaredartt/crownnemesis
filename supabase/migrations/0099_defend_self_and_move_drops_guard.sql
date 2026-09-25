-- 0099: a unit's defended status now knows whether it is guarding ITSELF
-- or being guarded by someone else, and moving a unit that someone ELSE is
-- guarding drops that guard.
--
-- HOW TO RUN THIS: apply live via the Supabase MCP's apply_migration (name
-- "defend_self_and_move_drops_guard"), and this same file is committed to
-- supabase/migrations/ verbatim.
--
-- Jared: "I saw it's possible that this can happen: unit A defends unit B,
-- and then unit B moves (still has its defend status). Let's make it this
-- way: if unit B (which is already defended) clicks on 'Move', a pop-up
-- will show 'If you move a defended unit, it will become undefended' ...
-- and they can either choose 'Move' or 'Cancel'. If they choose move,
-- don't remove the status of defended yet, only when they select a tile to
-- move to (because maybe they cancel mid-way)." Followed by: "That is in
-- the case of defending someone, because that would mean that unit B would
-- be far away from unit A (who is the one defending unit B). Of course, if
-- unit B defends itself instead, it can move without any pop up."
--
-- `defending`/`defendedBy` (0096) already record THAT a unit is guarded and
-- WHICH SIDE raised the guard, but not WHICH UNIT did -- two units on the
-- same side can each be guarding something different, so `defendedBy`
-- alone can't say whether the guarded unit raised its own guard. This adds
-- `defendedSelf` (boolean) alongside them, set by cn_defend/cn_defend_royale
-- at the moment the guard goes up, and read by cn_move/cn_move_royale to
-- decide whether a completed move should drop the guard (ally-raised: yes,
-- the guardian is now out of position) or leave it alone (self-raised: the
-- guard travels with the unit). The client-side confirmation pop-up itself
-- is Board.tsx's own confirmMoveGuard state -- this migration is only the
-- part that has to be true no matter which client asks.
--
-- Scope note: Battle Royale's own defend UI (RoyaleMatch.tsx's onDefend)
-- never sends a target at all today -- it is self-defend only, client-side
-- -- so defendedSelf is always true there in practice and this is a no-op
-- for Royale until a retarget-defend UI exists for it too. cn_defend_royale
-- and cn_move_royale still get the same fix here so the data model is
-- correct the moment that UI shows up, rather than needing a second pass.

create or replace function public.cn_defend(p_match uuid, p_side text, p_unit text, p_target text)
returns matches
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.matches; v_st jsonb; u jsonb; e jsonb;
  v_me jsonb; v_tgt_unit jsonb; v_tgt_obj jsonb;
  v_target_id text; v_tx int; v_ty int; v_dist int;
  v_out jsonb := '[]'::jsonb; v_rocks jsonb := '[]'::jsonb;
  v_note text;
begin
  select * into m from public.matches where id = p_match for update;
  v_st := m.state;
  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then v_me := u; end if;
  end loop;
  if v_me is null then raise exception 'no such unit'; end if;
  if v_me->>'owner' <> p_side then raise exception 'that is not your unit'; end if;
  if (v_me->>'acted')::boolean then raise exception 'that unit already acted'; end if;

  v_target_id := coalesce(nullif(p_target, ''), p_unit);

  if v_target_id = p_unit then
    v_tx := (v_me->>'x')::int; v_ty := (v_me->>'y')::int;
  else
    for u in select * from jsonb_array_elements(v_st->'units') loop
      if u->>'id' = v_target_id then v_tgt_unit := u; end if;
    end loop;
    if v_tgt_unit is null then
      for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
        if e->>'id' = v_target_id then v_tgt_obj := e; end if;
      end loop;
    end if;
    if v_tgt_unit is null and v_tgt_obj is null then raise exception 'no such target'; end if;
    v_tx := coalesce((v_tgt_unit->>'x')::int, (v_tgt_obj->>'x')::int);
    v_ty := coalesce((v_tgt_unit->>'y')::int, (v_tgt_obj->>'y')::int);
  end if;

  -- RANGE 1, ALWAYS. Jared: "This applies to any unit, any movement or
  -- range they may have, it's all ignored: if you want to defend anything,
  -- it needs to be in range 1." Reads cn_cheb directly rather than the
  -- defender's own rmin/rmax the way a strike or a scripted ability would.
  v_dist := cn_cheb((v_me->>'x')::int, (v_me->>'y')::int, v_tx, v_ty);
  if v_dist > 1 then raise exception 'too far to defend'; end if;

  v_st := cn_begin_act(v_st, p_side, p_unit);

  v_out := '[]'::jsonb;
  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then
      u := jsonb_set(u, '{acted}', 'true'::jsonb);
    end if;
    -- defendedBy records WHO raised this guard (not who owns the target,
    -- which may now differ -- an enemy or a neutral structure can be
    -- defended too) -- advance_turn/advance_turn_royale read it to decide
    -- whose next turn lapses it, exactly the same window the old
    -- self-only guard always had ("still up while the opponent is
    -- swinging, lapses when the raiser's own next turn opens").
    -- defendedSelf (0099) additionally records whether the RAISING unit
    -- and the TARGET unit are one and the same -- see this migration's
    -- header for why defendedBy alone can't answer that.
    if u->>'id' = v_target_id then
      u := jsonb_set(u, '{defending}', 'true'::jsonb);
      u := jsonb_set(u, '{defendedBy}', to_jsonb(p_side));
      u := jsonb_set(u, '{defendedSelf}', to_jsonb(v_target_id = p_unit));
    end if;
    v_out := v_out || u;
  end loop;
  v_st := jsonb_set(v_st, '{units}', v_out);

  if v_tgt_obj is not null then
    v_rocks := '[]'::jsonb;
    for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
      if e->>'id' = v_target_id then
        e := jsonb_set(e, '{defending}', 'true'::jsonb);
        e := jsonb_set(e, '{defendedBy}', to_jsonb(p_side));
      end if;
      v_rocks := v_rocks || e;
    end loop;
    v_st := jsonb_set(v_st, '{obstacles}', v_rocks);
  end if;

  v_st := cn_end_act(v_st, p_unit);

  v_note := case
    when v_target_id = p_unit then (v_me->>'name') || ' raises a guard.'
    when v_tgt_unit is not null then (v_me->>'name') || ' guards ' || (v_tgt_unit->>'name') || '.'
    else (v_me->>'name') || ' guards ' || cn_obj_name(cn_obj_kind(v_tgt_obj)) || '.'
  end;
  v_st := state_log(v_st, v_note);

  update public.matches set state = v_st, updated_at = now()
   where id = m.id returning * into m;
  return m;
end
$$;

create or replace function public.cn_defend_royale(p_match uuid, p_seat integer, p_unit text, p_target text)
returns royale_matches
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.royale_matches; v_st jsonb; u jsonb; v_me jsonb; v_tgt jsonb;
  v_target_id text; v_dist int; v_out jsonb := '[]'::jsonb;
begin
  select * into m from public.royale_matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  v_st := m.state;
  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then v_me := u; end if;
  end loop;
  if v_me is null then raise exception 'no such unit'; end if;
  if (v_me->>'owner')::int <> p_seat then raise exception 'that is not your unit'; end if;
  if (v_me->>'acted')::boolean then raise exception 'that unit already acted'; end if;

  v_target_id := coalesce(nullif(p_target, ''), p_unit);
  if v_target_id <> p_unit then
    for u in select * from jsonb_array_elements(v_st->'units') loop
      if u->>'id' = v_target_id then v_tgt := u; end if;
    end loop;
    if v_tgt is null then raise exception 'no such target'; end if;
    v_dist := cn_cheb((v_me->>'x')::int, (v_me->>'y')::int, (v_tgt->>'x')::int, (v_tgt->>'y')::int);
  else
    v_dist := 0;
  end if;
  if v_dist > 1 then raise exception 'too far to defend'; end if;

  v_st := cn_begin_act_royale(v_st, p_seat, p_unit);

  v_out := '[]'::jsonb;
  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then u := jsonb_set(u, '{acted}', 'true'::jsonb); end if;
    if u->>'id' = v_target_id then
      u := jsonb_set(u, '{defending}', 'true'::jsonb);
      u := jsonb_set(u, '{defendedBy}', to_jsonb(p_seat));
      u := jsonb_set(u, '{defendedSelf}', to_jsonb(v_target_id = p_unit));
    end if;
    v_out := v_out || u;
  end loop;
  v_st := jsonb_set(v_st, '{units}', v_out);
  v_st := cn_end_act_royale(v_st, p_unit);
  v_st := state_log(v_st, (v_me->>'name') ||
    case when v_target_id = p_unit then ' raises a guard.'
         else ' guards ' || (v_tgt->>'name') || '.' end);

  update public.royale_matches set state = v_st, updated_at = now()
   where id = m.id returning * into m;
  return m;
end
$$;

create or replace function public.cn_move(p_match uuid, p_side text, p_unit text, p_x integer, p_y integer)
returns matches
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.matches; v_st jsonb; u jsonb; e jsonb; v_me jsonb;
  v_out jsonb := '[]'::jsonb; v_rocks jsonb := '[]'::jsonb;
  v_reach text[]; v_felled boolean := false;
  v_win text; v_gale jsonb; v_left int;
begin
  select * into m from public.matches where id = p_match for update;
  v_st := m.state;
  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then v_me := u; end if;
  end loop;
  if v_me is null then raise exception 'no such unit'; end if;
  if v_me->>'owner' <> p_side then raise exception 'that is not your unit'; end if;
  if (v_me->>'moved')::boolean then raise exception 'that unit already moved'; end if;

  -- Opens an activation, or continues the one this unit is already in.
  -- Moving deliberately does NOT close it: the unit may still strike, and
  -- move-then-strike is one action, not two. cn_begin_act is what charges
  -- the turn's budget, and it raises if there is nothing left to spend.
  v_st := cn_begin_act(v_st, p_side, p_unit);

  v_reach := cn_reach(v_st, v_me);
  if not ((p_x || ',' || p_y) = any(v_reach)) then
    raise exception 'that unit cannot reach that tile';
  end if;

  -- WHAT IS ON THE TILE. Anything solid was already excluded by cn_reach --
  -- you cannot walk into a tree unless you trample, and you cannot walk into
  -- a wall at all -- so what is standing here is a trap, a tornado, or a tree
  -- under a trampler. The trap is NOT handled here any more: the unit is put
  -- down first and cn_spring is asked what it landed on, because the throw
  -- needs the same answer and two copies of it would drift.
  for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
    if (e->>'x')::int = p_x and (e->>'y')::int = p_y
       and cn_obj_kind(e) = 'tree' then
      v_felled := true;                        -- trampled, and gone
    else
      if (e->>'x')::int = p_x and (e->>'y')::int = p_y
         and cn_obj_kind(e) = 'tornado'
         and e->>'owner' is not null and e->>'owner' <> p_side then
        -- Only an ENEMY tornado takes hold. Walking your own unit into your
        -- own gale to be thrown somewhere useful would make Lumea a taxi.
        v_gale := e;
      end if;
      v_rocks := v_rocks || e;                 -- a trap and a tornado both stay
    end if;
  end loop;

  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then
      u := jsonb_set(jsonb_set(u, '{x}', to_jsonb(p_x)), '{y}', to_jsonb(p_y));
      u := jsonb_set(u, '{moved}', 'true'::jsonb);
      -- 0099. Jared: "unit A defends unit B, and then unit B moves... unit
      -- B would be far away from unit A." A unit guarded by someone ELSE
      -- loses that guard the moment it actually moves -- the client warns
      -- first (see Board.tsx's confirmMoveGuard). A unit guarding ITSELF
      -- keeps its guard when it moves: the guard travels with it, there is
      -- no guardian left behind to be out of position.
      if coalesce((u->>'defending')::boolean, false)
         and not coalesce((u->>'defendedSelf')::boolean, false) then
        u := jsonb_set(u, '{defending}', 'false'::jsonb);
        u := (u - 'defendedBy') - 'defendedSelf';
      end if;
    end if;
    v_out := v_out || u;
  end loop;

  v_st := jsonb_set(v_st, '{units}', v_out);
  v_st := jsonb_set(v_st, '{obstacles}', v_rocks);
  v_st := state_log(v_st, (v_me->>'name') || ' advances.');
  if v_felled then
    v_st := state_log(v_st, (v_me->>'name') || ' walks through a tree. It comes down.');
  end if;
  -- The trap, the falling and the ending, all three through the helpers that
  -- 0036 pulled out of here -- because the throw does exactly the same three
  -- things and two copies of "who won" is how a ranked ladder quietly stops
  -- agreeing with itself.
  v_st := cn_spring(v_st, p_unit);
  if not exists (select 1 from jsonb_array_elements(v_st->'units') q
                  where q->>'id' = p_unit) then
    if coalesce((v_me->>'royal')::boolean, false) then
      v_st := state_log(v_st, 'The crown has fallen.');
    end if;
    v_win := cn_win_after_death(v_st, v_me);
    v_gale := null;          -- a unit the trap finished is not thrown anywhere
  end if;

  if v_win is not null then return cn_finish(m, v_st, v_win); end if;

  -- LUMEA'S FIFTEEN SECONDS. The gale has hold of somebody, so everything
  -- stops and the clock changes hands: what the turn had left is parked, and
  -- turn_deadline becomes the decision's deadline instead. One clock, one
  -- realtime push, one countdown -- see this file's header.
  if v_gale is not null then
    v_left := greatest(0, round(extract(epoch from
                (coalesce(m.turn_deadline, now()) - now())) * 1000))::int;
    v_st := jsonb_set(v_st, '{pending}', jsonb_build_object(
      'kind', 'throw', 'side', v_gale->>'owner', 'unit', p_unit,
      'obj', v_gale->>'id', 'resumeMs', v_left), true);
    v_st := state_log(v_st, (v_me->>'name') || ' is caught in the gale.');
    update public.matches
       set state = v_st,
           turn_deadline = now() + (cn_throw_secs() || ' seconds')::interval,
           updated_at = now()
     where id = m.id returning * into m;
    return m;
  end if;

  update public.matches set state = v_st, updated_at = now()
   where id = m.id returning * into m;
  return m;
end
$$;

create or replace function public.cn_move_royale(p_match uuid, p_seat integer, p_unit text, p_x integer, p_y integer)
returns royale_matches
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.royale_matches; v_st jsonb; u jsonb; e jsonb; v_me jsonb;
  v_out jsonb := '[]'::jsonb; v_rocks jsonb := '[]'::jsonb;
  v_reach text[]; v_felled boolean := false;
begin
  select * into m from public.royale_matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  v_st := m.state;
  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then v_me := u; end if;
  end loop;
  if v_me is null then raise exception 'no such unit'; end if;
  if (v_me->>'owner')::int <> p_seat then raise exception 'that is not your unit'; end if;
  if (v_me->>'moved')::boolean then raise exception 'that unit already moved'; end if;

  v_st := cn_begin_act_royale(v_st, p_seat, p_unit);

  v_reach := cn_reach(v_st, v_me);
  if not ((p_x || ',' || p_y) = any(v_reach)) then
    raise exception 'that unit cannot reach that tile';
  end if;

  -- Royale v1 has no summons -- see the header -- so an obstacle here is
  -- always a tree.
  for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
    if (e->>'x')::int = p_x and (e->>'y')::int = p_y and cn_obj_kind(e) = 'tree' then
      v_felled := true;
    else
      v_rocks := v_rocks || e;
    end if;
  end loop;

  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then
      u := jsonb_set(jsonb_set(u, '{x}', to_jsonb(p_x)), '{y}', to_jsonb(p_y));
      u := jsonb_set(u, '{moved}', 'true'::jsonb);
      -- 0099, same rule as cn_move above: moving drops a guard someone
      -- ELSE raised, leaves a self-guard alone.
      if coalesce((u->>'defending')::boolean, false)
         and not coalesce((u->>'defendedSelf')::boolean, false) then
        u := jsonb_set(u, '{defending}', 'false'::jsonb);
        u := (u - 'defendedBy') - 'defendedSelf';
      end if;
    end if;
    v_out := v_out || u;
  end loop;

  v_st := jsonb_set(v_st, '{units}', v_out);
  v_st := jsonb_set(v_st, '{obstacles}', v_rocks);
  v_st := state_log(v_st, (v_me->>'name') || ' advances.');
  if v_felled then
    v_st := state_log(v_st, (v_me->>'name') || ' walks through a tree. It comes down.');
  end if;

  update public.royale_matches set state = v_st, updated_at = now()
   where id = m.id returning * into m;
  return m;
end
$$;
