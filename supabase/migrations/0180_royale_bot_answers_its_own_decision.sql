-- A tornado's decision belongs to whoever raised it, on anyone's turn. A bot that
-- raised one has to be able to answer it when it is NOT its turn, so that check
-- goes before the turn check in royale_bot_step (1v1's bot gets the same
-- treatment through Match.tsx's botTurn). Idempotent.
do $b$
declare v text;
begin
  v := pg_get_functiondef('public.royale_bot_step(uuid,integer)'::regprocedure);
  if position('-- 0180' in v) = 0 then
    v := public.cn_royale_patch(v,
      E'  if coalesce((m.state->>''turn'')::int, -1) <> p_seat then return m; end if;',
      E'  -- 0180: a decision this bot owns is answered whoever''s turn it is.\n  if cn_pending(m.state) is not null and (cn_pending(m.state)->>''side'')::int = p_seat\n     and exists (select 1 from public.royale_players\n                  where match_id = p_match and seat = p_seat and bot is not null and not eliminated) then\n    perform cn_throw_royale(p_match, p_seat, null);\n    return cn_royale_commit(p_match);\n  end if;\n  if coalesce((m.state->>''turn'')::int, -1) <> p_seat then return m; end if;',
      'bot turn check');
    execute v;
  end if;
end $b$;
