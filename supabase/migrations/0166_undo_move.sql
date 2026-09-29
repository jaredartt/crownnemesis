-- Jared: "make Cancel undo a move (with a smooth animation) but NOT undo
-- attack/defend/ability/anything else."
--
-- Matches are server-authoritative, so "undo" has to be a real server call,
-- not a client-side trick -- and it has to be conservative: a move can spring
-- a trap, fell a tree, catch the mover in a gale, or even kill them, and none
-- of that is safe to hand back. So cn_move now snapshots the board exactly
-- as it stood right before cn_begin_act touches anything, and -- ONLY once
-- the move is fully resolved -- compares the after picture against that
-- snapshot. If NOTHING changed except the mover's own position/moved flag
-- (and, naturally, a "someone else was guarding me" flag lapsing, which
-- moving away always does), the snapshot is kept as state.undo and Cancel
-- (Board.tsx) offers it back instead of just closing the menu. Anything
-- else about the move -- a felled tree, a sprung trap, a gale, a kill --
-- leaves state.undo cleared, same as it starts.
--
-- state.undo is intentionally short-lived: cn_attack, cn_ability, cn_defend
-- and submit_wait all clear it the instant they run, because moving on to
-- ANY other action -- by this unit or a different one -- is the player
-- committing to what came before. submit_undo_move (new) additionally
-- requires state.active to still name the same unit state.undo does, which
-- catches the one case none of those four clears cover: the gale/pending-
-- throw branch inside cn_move itself, which returns before reaching the
-- ordinary clean-move check below -- handled by clearing undo right at the
-- top of that branch instead.
--
-- The animation asked for costs nothing extra: Board.tsx's own FLIP effect
-- (the "seats" useLayoutEffect) already replays a smooth slide+tilt for ANY
-- unit whose x/y changed between renders, regardless of why -- a normal
-- move, and now an undo, look identical to it.
do $$
declare def text; v_before text;
begin
  def := pg_get_functiondef('public.cn_move(uuid,text,text,int,int)'::regprocedure);
  v_before := def;

  def := replace(def,
    '  v_win text; v_gale jsonb; v_left int; v_burn_mv int := 0;
begin',
    '  v_win text; v_gale jsonb; v_left int; v_burn_mv int := 0;
  -- 0166: what the board looked like right before this move, kept only
  -- long enough to decide whether Cancel may hand it back.
  v_pre_units jsonb; v_pre_obstacles jsonb; v_pre_active text; v_pre_acts int;
  v_mover_pre jsonb; v_mover_post jsonb; v_others_pre jsonb; v_others_post jsonb;
  v_clean boolean; v_undo jsonb;
begin');
  if def = v_before then raise exception '0166: cn_move -- declare block target not found'; end if;
  v_before := def;

  def := replace(def,
    '  if cn_stun_blocks(''move'') and cn_stunned(v_me) then raise exception ''that unit is stunned''; end if;

  v_st := cn_begin_act(v_st, p_side, p_unit);',
    '  if cn_stun_blocks(''move'') and cn_stunned(v_me) then raise exception ''that unit is stunned''; end if;

  -- 0166: snapshot everything cn_begin_act is about to touch, before it
  -- touches it.
  v_pre_units := v_st->''units'';
  v_pre_obstacles := coalesce(v_st->''obstacles'', ''[]''::jsonb);
  v_pre_active := nullif(v_st->>''active'', '''');
  v_pre_acts := coalesce((v_st->>''acts'')::int, 0);

  v_st := cn_begin_act(v_st, p_side, p_unit);');
  if def = v_before then raise exception '0166: cn_move -- snapshot target not found'; end if;
  v_before := def;

  def := replace(def,
    '  if v_gale is not null then
    v_left := greatest(0, round(extract(epoch from',
    '  if v_gale is not null then
    -- Caught in the gale is not a clean move by any definition -- whatever
    -- undo this move (or an earlier one still sitting from this turn)
    -- might have offered goes with it.
    v_st := v_st - ''undo'';
    v_left := greatest(0, round(extract(epoch from');
  if def = v_before then raise exception '0166: cn_move -- gale target not found'; end if;
  v_before := def;

  def := replace(def,
    '  update public.matches set state = v_st, updated_at = now()
   where id = m.id returning * into m;
  return m;
end
$function$',
    '  -- 0166: only offered back when NOTHING besides this move happened --
  -- re-derived from the actual before/after state rather than trusted from
  -- the call site, so any move-time side effect this migration did not
  -- anticipate fails closed (no undo offered) instead of silently becoming
  -- undoable when it should not be.
  v_clean := not v_felled;
  if v_clean then
    select (u - ''{x,y,moved,defending,defendedBy,defendedSelf}''::text[]) into v_mover_post
      from jsonb_array_elements(v_st->''units'') u where u->>''id'' = p_unit;
    v_mover_pre := v_me - ''{x,y,moved,defending,defendedBy,defendedSelf}''::text[];
    v_clean := v_mover_post = v_mover_pre;
  end if;
  if v_clean then
    select coalesce(jsonb_agg(u), ''[]''::jsonb) into v_others_post
      from jsonb_array_elements(v_st->''units'') u where u->>''id'' <> p_unit;
    select coalesce(jsonb_agg(u), ''[]''::jsonb) into v_others_pre
      from jsonb_array_elements(v_pre_units) u where u->>''id'' <> p_unit;
    v_clean := v_others_post = v_others_pre;
  end if;
  if v_clean then
    v_clean := (v_st->''obstacles'' = v_pre_obstacles);
  end if;

  if v_clean then
    v_undo := jsonb_build_object(
      ''unit'', p_unit, ''units'', v_pre_units, ''obstacles'', v_pre_obstacles,
      ''active'', to_jsonb(v_pre_active), ''acts'', v_pre_acts);
    v_st := jsonb_set(v_st, ''{undo}'', v_undo, true);
  else
    v_st := v_st - ''undo'';
  end if;

  update public.matches set state = v_st, updated_at = now()
   where id = m.id returning * into m;
  return m;
end
$function$');
  if def = v_before then raise exception '0166: cn_move -- final block target not found'; end if;
  execute def;
end $$;

-- Any other action ends the undo window -- see this migration's own header.
do $$
declare def text; v_before text;
begin
  def := pg_get_functiondef('public.cn_attack(uuid,text,text,text)'::regprocedure);
  v_before := def;
  def := replace(def,
    '  v_st := m.state;

  for u in select * from jsonb_array_elements(v_st->''units'') loop
    if u->>''id'' = p_unit   then v_atk := u; end if;',
    '  v_st := m.state;
  -- 0166: any action beyond "just moved" ends the undo window.
  v_st := v_st - ''undo'';

  for u in select * from jsonb_array_elements(v_st->''units'') loop
    if u->>''id'' = p_unit   then v_atk := u; end if;');
  if def = v_before then raise exception '0166: cn_attack -- target not found'; end if;
  execute def;
end $$;

do $$
declare def text; v_before text;
begin
  def := pg_get_functiondef('public.cn_ability(uuid,text,text,text)'::regprocedure);
  v_before := def;
  def := replace(def,
    '  v_st := m.state;
  if v_st->>''turn'' <> p_side then raise exception ''not your turn''; end if;
  v_before_units := v_st->''units'';',
    '  v_st := m.state;
  -- 0166: any action beyond "just moved" ends the undo window.
  v_st := v_st - ''undo'';
  if v_st->>''turn'' <> p_side then raise exception ''not your turn''; end if;
  v_before_units := v_st->''units'';');
  if def = v_before then raise exception '0166: cn_ability -- target not found'; end if;
  execute def;
end $$;

do $$
declare def text; v_before text;
begin
  def := pg_get_functiondef('public.cn_defend(uuid,text,text,text)'::regprocedure);
  v_before := def;
  def := replace(def,
    '  select * into m from public.matches where id = p_match for update;
  v_st := m.state;
  for u in select * from jsonb_array_elements(v_st->''units'') loop
    if u->>''id'' = p_unit then v_me := u; end if;
  end loop;',
    '  select * into m from public.matches where id = p_match for update;
  v_st := m.state;
  -- 0166: any action beyond "just moved" ends the undo window.
  v_st := v_st - ''undo'';
  for u in select * from jsonb_array_elements(v_st->''units'') loop
    if u->>''id'' = p_unit then v_me := u; end if;
  end loop;');
  if def = v_before then raise exception '0166: cn_defend -- target not found'; end if;
  execute def;
end $$;

do $$
declare def text; v_before text;
begin
  def := pg_get_functiondef('public.submit_wait(uuid)'::regprocedure);
  v_before := def;
  def := replace(def,
    '  v_st := m.state;
  -- submit_wait and end_turn are the two that never reach cn_begin_act.
  if cn_pending(v_st) is not null then raise exception ''a throw is pending''; end if;',
    '  v_st := m.state;
  -- 0166: Waiting commits to the move that came before it -- same as any
  -- other action, it ends the undo window.
  v_st := v_st - ''undo'';
  -- submit_wait and end_turn are the two that never reach cn_begin_act.
  if cn_pending(v_st) is not null then raise exception ''a throw is pending''; end if;');
  if def = v_before then raise exception '0166: submit_wait -- target not found'; end if;
  execute def;
end $$;

-- The undo itself. Mirrors submit_wait's own shape (no unit id -- it always
-- acts on whichever unit state.undo names) plus the deadline check every
-- other submit_* action already has. Restores units/obstacles/active/acts
-- verbatim from the snapshot cn_move took, then puts turn_deadline back to
-- exactly what it was before this call -- the per-go clock trigger
-- (cn_refresh_action_clock) reads the acts change as "a new go started" and
-- would otherwise hand out a free 40s, which is exactly the kind of
-- move-then-undo time-farming this must not enable.
create or replace function public.submit_undo_move(p_match uuid)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare
  m public.matches; v_side text; v_st jsonb; v_undo jsonb; v_unit text;
  v_orig_deadline timestamptz; v_name text;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'active' then raise exception 'match is not running'; end if;
  v_side := side_of(m, auth.uid());
  if v_side is null then raise exception 'you are spectating this match'; end if;
  if m.state->>'turn' <> v_side then raise exception 'not your turn'; end if;
  if now() > m.turn_deadline + interval '2 seconds' then raise exception 'your time ran out'; end if;

  v_st := m.state;
  if cn_pending(v_st) is not null then raise exception 'a throw is pending'; end if;
  v_undo := v_st->'undo';
  if v_undo is null then raise exception 'nothing to undo'; end if;
  v_unit := v_undo->>'unit';
  -- Belt to cn_move/cn_attack/cn_ability/cn_defend/submit_wait's own
  -- braces: this move's undo is only good while it is still that same
  -- unit's open go.
  if nullif(v_st->>'active', '') is distinct from v_unit then
    raise exception 'nothing to undo';
  end if;
  v_orig_deadline := m.turn_deadline;

  select u->>'name' into v_name
    from jsonb_array_elements(v_undo->'units') u where u->>'id' = v_unit;

  v_st := jsonb_set(v_st, '{units}', v_undo->'units');
  v_st := jsonb_set(v_st, '{obstacles}', v_undo->'obstacles');
  v_st := jsonb_set(v_st, '{active}', coalesce(v_undo->'active', 'null'::jsonb));
  v_st := jsonb_set(v_st, '{acts}', v_undo->'acts');
  v_st := v_st - 'undo';
  v_st := state_log(v_st, coalesce(v_name, 'The unit') || ' pulls back.');

  update public.matches set state = v_st, updated_at = now()
   where id = m.id returning * into m;

  if m.status = 'active' then
    update public.matches set turn_deadline = v_orig_deadline, state = m.state
     where id = m.id returning * into m;
  end if;
  return m;
end $$;

grant execute on function public.submit_undo_move(uuid) to authenticated;

-- Did it work?
select
  (position('v_pre_units' in pg_get_functiondef('public.cn_move(uuid,text,text,int,int)'::regprocedure)) > 0) as cn_move_patched,
  (position('undo' in pg_get_functiondef('public.cn_attack(uuid,text,text,text)'::regprocedure)) > 0) as cn_attack_clears_undo,
  (position('undo' in pg_get_functiondef('public.cn_ability(uuid,text,text,text)'::regprocedure)) > 0) as cn_ability_clears_undo,
  (position('undo' in pg_get_functiondef('public.cn_defend(uuid,text,text,text)'::regprocedure)) > 0) as cn_defend_clears_undo,
  (position('undo' in pg_get_functiondef('public.submit_wait(uuid)'::regprocedure)) > 0) as submit_wait_clears_undo,
  (to_regprocedure('public.submit_undo_move(uuid)') is not null) as submit_undo_move_exists;
