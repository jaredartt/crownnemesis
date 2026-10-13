-- 0249: which bot a ranked player gets is now two settings, not hard-coded 900 / 1300.
--   rating <  ranked_bot_l2_from  -> level 1 (easy, very noisy)
--   rating <  ranked_bot_l3_from  -> level 2 (medium)
--   otherwise                     -> level 3 (expert: the trained brain)
-- Today (900 / 1300) everyone around the starting 1000 gets level 2. Humans beat it
-- 9 times out of 16 in ranked; level 3 beat humans 46 of 47 in casual bot games.
-- Lowering ranked_bot_l3_from is the "make ranked bots harder" dial; edit the numbers below.
alter table public.app_settings
  add column if not exists ranked_bot_l2_from int not null default 900,
  add column if not exists ranked_bot_l3_from int not null default 1000;

do $mig$
declare
  d text := pg_get_functiondef('public.ranked_tick()'::regprocedure);
  old constant text := 'v_lvl := case when v_rating < 900 then 1 when v_rating < 1300 then 2 else 3 end;';
  new constant text := 'v_lvl := case when v_rating < (select ranked_bot_l2_from from public.app_settings where id) then 1 when v_rating < (select ranked_bot_l3_from from public.app_settings where id) then 2 else 3 end;';
begin
  if position(old in d) = 0 then
    if position('ranked_bot_l3_from' in d) > 0 then return; end if;  -- already applied
    raise exception 'ranked_tick anchor not found';
  end if;
  execute replace(d, old, new);
end
$mig$;
