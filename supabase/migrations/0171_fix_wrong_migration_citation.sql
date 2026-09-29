-- The previous migration's comment cited "0176's own header" for why both
-- `bot` and `host_bot` exist on `matches` -- that number was wrong (there is
-- no 0176 in this project; the real migration is
-- 0090_bot_identity_and_ranked_fallback.sql). Comment-only fix, no
-- behavior change.
do $$
declare def text; v_before text;
begin
  def := pg_get_functiondef('public.admin_activity_summary(integer)'::regprocedure);
  v_before := def;
  def := replace(def,
    'see 0176''s own header for why both columns exist',
    'see 0090_bot_identity_and_ranked_fallback.sql''s own header for why both columns exist');
  if def = v_before then raise exception 'admin_activity_summary -- wrong-citation comment not found'; end if;
  execute def;
end $$;
