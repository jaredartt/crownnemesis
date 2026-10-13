-- 0247: ANY unit that ends its move in a tornado is caught in it, including the
-- summoner's own. The summoner decides where it lands (same 15-second decision,
-- same reach). Before this the gale only caught units whose side differed from
-- the tornado's owner, so stepping on your own tornado did nothing.
--
-- Patched in place on the live cn_move (never a re-typed copy), asserting the
-- anchor exists. The royale copy follows through the cn_royale_follow_1v1 event
-- trigger; check royale_engine_log afterwards.
do $mig$
declare
  d text := pg_get_functiondef('public.cn_move(uuid,text,text,integer,integer)'::regprocedure);
  old constant text := E'and e->>''owner'' is not null and e->>''owner'' <> p_side then';
  new constant text := E'and e->>''owner'' is not null then';
begin
  if position(old in d) = 0 then
    if position(new in d) > 0 then return; end if;  -- already applied
    raise exception 'cn_move anchor not found';
  end if;
  execute replace(d, old, new);
end
$mig$;
