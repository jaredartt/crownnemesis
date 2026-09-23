-- Jared: "can you tell me if attacks have a -+5? If so, change it to a -+2
-- instead." Confirmed -- cn_spread() (0018_combat_core.sql) is that number,
-- and it feeds both the one-time backfill and the cards-table trigger that
-- recomputes dmin/dmax from power on every edit (0031/0032/0040). Narrowed
-- here the same way 0018 first set it: redefine the function, then
-- backfill every existing card's band off its own power so nothing on the
-- board shifts in EXPECTATION, only how wide the roll can land.
create or replace function public.cn_spread() returns int
language sql immutable as $$ select 2 $$;

update public.cards
   set dmin = greatest(0, power - cn_spread()),
       dmax = power + cn_spread(),
       updated_at = now()
 where power is not null;
