-- Jared, offered as a follow-up after the last review: "if you'd like it to
-- respect the deadline like the other actions, I can add that." He did.
--
-- submit_wait and submit_royale_wait were restored byte-for-byte from their
-- last live bodies (0165_restore_wait.sql) and neither one ever had the
-- "your time ran out" guard that submit_move/submit_attack/submit_defend
-- and their Royale equivalents all carry. Bringing Wait in line with every
-- other submit_* action, using the exact same two-second grace window.
do $$
declare def text; v_before text;
begin
  def := pg_get_functiondef('public.submit_wait(uuid)'::regprocedure);
  v_before := def;
  def := replace(def,
    'if m.state->>''turn'' <> v_side then raise exception ''not your turn''; end if;

  v_st := m.state;',
    'if m.state->>''turn'' <> v_side then raise exception ''not your turn''; end if;
  if now() > m.turn_deadline + interval ''2 seconds'' then raise exception ''your time ran out''; end if;

  v_st := m.state;');
  if def = v_before then raise exception '0167: submit_wait -- target not found'; end if;
  execute def;
end $$;

do $$
declare def text; v_before text;
begin
  def := pg_get_functiondef('public.submit_royale_wait(uuid)'::regprocedure);
  v_before := def;
  def := replace(def,
    'if coalesce((m.state->>''turn'')::int, -1) <> v_seat then raise exception ''not your turn''; end if;

  update public.royale_players',
    'if coalesce((m.state->>''turn'')::int, -1) <> v_seat then raise exception ''not your turn''; end if;
  if now() > m.turn_deadline + interval ''2 seconds'' then raise exception ''your time ran out''; end if;

  update public.royale_players');
  if def = v_before then raise exception '0167: submit_royale_wait -- target not found'; end if;
  execute def;
end $$;

select
  (position('your time ran out' in pg_get_functiondef('public.submit_wait(uuid)'::regprocedure)) > 0) as wait_fixed,
  (position('your time ran out' in pg_get_functiondef('public.submit_royale_wait(uuid)'::regprocedure)) > 0) as royale_wait_fixed;
