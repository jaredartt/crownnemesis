-- Jared: "why when the Expert bot positions its units, they're all in a
-- vertical line aligned? ... it's not 100% right I feel."
--
-- v_pos (bot_step's positioning score) rewards a candidate tile purely by
-- its distance from the NEAREST ENEMY (v_near) -- nothing in it looks at
-- where the bot's OWN other units are. When several of the bot's units
-- share the same nearest enemy (common early on, before the board opens
-- up), they independently converge on the same ideal distance from that
-- one point, and since Chebyshev distance plus the same tile-scan order
-- keeps landing them on the same column, the formation reads as "lined
-- up" rather than spread across the board.
--
-- This adds a small same-side spacing term, Expert only (v_lvl = 3, same
-- scope as cn_bot_strategy_bonus): a candidate tile that sits closer than
-- `ally_spacing_ideal` tiles (default 2) to another living friendly unit
-- loses `ally_spacing_mult` (default 6) points per tile of overlap. It's
-- folded straight into v_pos, so it's felt everywhere v_pos already is
-- (move candidates, and the v_pos-vs-v_base delta under every attack/
-- ability score) without touching anything else's math, and it's mild
-- enough that a real tactical reason to stack (a wall, a chokepoint, a
-- rescue) still wins on its own merits.
--
-- Spot-checked live against a real Expert bot match (create_bot_match(3),
-- stepped the bot through several of its own turns): units still cluster
-- somewhat when the board genuinely funnels them toward the same spot,
-- so this is a mild nudge, not a guarantee of a perfect fan-out -- if
-- Jared still sees tight lines after playing more games, ally_spacing_mult
-- is the knob to raise.
do $$
declare
  v_def text;
  v_before text;
begin
  v_def := pg_get_functiondef('public.bot_step(uuid,text)'::regprocedure);

  v_before := v_def;
  v_def := replace(v_def,
    E'  v_d int; v_dmg numeric; v_ctr numeric; v_near int; v_thr int;\n',
    E'  v_d int; v_dmg numeric; v_ctr numeric; v_near int; v_thr int; v_ally_near int;\n');
  if v_def = v_before then raise exception '0155 splice (declare) anchor not found'; end if;

  v_before := v_def;
  v_def := replace(v_def,
    E'      v_pos := - abs(v_near - (u->>\'rmax\')::int) * coalesce((v_w->>\'pos_dist_mult\')::numeric, 5.0)\n               - v_near * coalesce((v_w->>\'pos_near_mult\')::numeric, 2.0);\n\n      if v_first then v_base := v_pos; v_first := false; end if;',
    E'      v_pos := - abs(v_near - (u->>\'rmax\')::int) * coalesce((v_w->>\'pos_dist_mult\')::numeric, 5.0)\n               - v_near * coalesce((v_w->>\'pos_near_mult\')::numeric, 2.0);\n\n      if v_lvl = 3 then\n        v_ally_near := 99;\n        for t2 in select * from jsonb_array_elements(st->\'units\') loop\n          continue when t2->>\'owner\' <> p_side or t2->>\'id\' = u->>\'id\' or (t2->>\'hp\')::int <= 0;\n          v_d := cn_cheb(vx, vy, (t2->>\'x\')::int, (t2->>\'y\')::int);\n          if v_d < v_ally_near then v_ally_near := v_d; end if;\n        end loop;\n        v_pos := v_pos - greatest(0, coalesce((v_w->>\'ally_spacing_ideal\')::numeric, 2) - v_ally_near)\n                          * coalesce((v_w->>\'ally_spacing_mult\')::numeric, 6.0);\n      end if;\n\n      if v_first then v_base := v_pos; v_first := false; end if;');
  if v_def = v_before then raise exception '0155 splice (v_pos) anchor not found'; end if;

  execute v_def;
end
$$;
