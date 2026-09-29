-- Jared: "apparently if I step on Lumea's tornado, she doesn't choose, the
-- player just keeps waiting until his turn is over or whatever, I don't
-- know." -- confirmed: a throw decision (0036_the_throw.sql) belongs to
-- whoever did NOT just move, so it can be open while state.turn still
-- names the OTHER side. bot_step's very first gate is
-- `if m.state->>'turn' <> p_side then return m; end if;`, which a pending
-- decision never satisfies for the bot's side -- so bot_step always
-- no-opped, botTurn on the client never had reason to poll it (see the
-- matching Match.tsx fix), and every single tornado throw against a bot
-- simply ran out its 15-second clock and defaulted to "leave them," with
-- nothing on screen for the human but a wait.
--
-- Resolve a pending throw belonging to this bot BEFORE the turn-mismatch
-- bailout, picking a landing tile the same way the rest of bot_step scores
-- things: reuse cn_bot_trap_threat (0161) to prefer flinging the caught
-- unit onto a hazard, tie-broken by landing them close to one of this
-- bot's own units for a next-turn follow-up. If nothing reachable is open
-- (boxed in), or the caught unit is already gone, it calls cn_throw with a
-- null target -- the same "leave them" cn_throw already does for a human
-- who declines, and for force_timeout when nobody answers at all.
do $$
declare def text; v_before text;
begin
  def := pg_get_functiondef('public.bot_step(uuid,text)'::regprocedure);
  v_before := def;
  def := replace(def,
    '  if m.status <> ''active'' then return m; end if;
  if m.state->>''turn'' <> p_side then return m; end if;

  st := m.state;',
    '  if m.status <> ''active'' then return m; end if;

  -- See this migration''s header. A throw decision can be open for this
  -- side while state.turn still names the other one, so it has to be
  -- handled before the turn check just below, not after it.
  declare
    v_throw_p jsonb; v_throw_u jsonb; v_cx int; v_cy int;
    v_cand_x int; v_cand_y int; v_cand_best int; v_best_ally_d int;
    v_cand_trap int; v_cand_ally_d int; v_tvx int; v_tvy int; v_td int;
  begin
    v_throw_p := cn_pending(m.state);
    if v_throw_p is not null and v_throw_p->>''kind'' = ''throw''
       and v_throw_p->>''side'' = p_side then
      v_throw_u := null;
      for u in select * from jsonb_array_elements(m.state->''units'') loop
        if u->>''id'' = v_throw_p->>''unit'' then v_throw_u := u; end if;
      end loop;

      v_cand_x := null; v_cand_y := null; v_cand_best := -1; v_best_ally_d := 99;
      if v_throw_u is not null then
        v_cx := (v_throw_u->>''x'')::int;
        v_cy := (v_throw_u->>''y'')::int;
        for v_tvx in v_cx - cn_throw_reach() .. v_cx + cn_throw_reach() loop
          for v_tvy in v_cy - cn_throw_reach() .. v_cy + cn_throw_reach() loop
            continue when v_tvx < 0 or v_tvy < 0
                      or v_tvx >= (m.state->''board''->>''w'')::int
                      or v_tvy >= (m.state->''board''->>''h'')::int;
            v_td := greatest(abs(v_tvx - v_cx), abs(v_tvy - v_cy));
            continue when v_td < 1 or v_td > cn_throw_reach();
            continue when exists (
              select 1 from jsonb_array_elements(m.state->''units'') q
              where (q->>''x'')::int = v_tvx and (q->>''y'')::int = v_tvy
            );
            continue when exists (
              select 1 from jsonb_array_elements(coalesce(m.state->''obstacles'', ''[]''::jsonb)) e
              where (e->>''x'')::int = v_tvx and (e->>''y'')::int = v_tvy
                and cn_obj_solid(cn_obj_kind(e))
            );
            v_cand_trap := cn_bot_trap_threat(m.state, v_tvx, v_tvy);
            v_cand_ally_d := 99;
            for t in select * from jsonb_array_elements(m.state->''units'') loop
              continue when t->>''owner'' <> p_side;
              v_cand_ally_d := least(v_cand_ally_d, cn_cheb(v_tvx, v_tvy, (t->>''x'')::int, (t->>''y'')::int));
            end loop;
            if v_cand_trap > v_cand_best
               or (v_cand_trap = v_cand_best and v_cand_ally_d < v_best_ally_d) then
              v_cand_best := v_cand_trap;
              v_best_ally_d := v_cand_ally_d;
              v_cand_x := v_tvx; v_cand_y := v_tvy;
            end if;
          end loop;
        end loop;
      end if;

      if v_cand_x is not null then
        return cn_throw(p_match, p_side, ''@'' || v_cand_x || '','' || v_cand_y);
      else
        return cn_throw(p_match, p_side, null);
      end if;
    end if;
  end;

  if m.state->>''turn'' <> p_side then return m; end if;

  st := m.state;');
  if def = v_before then raise exception '0164: bot_step -- target text not found'; end if;
  execute def;
end $$;
