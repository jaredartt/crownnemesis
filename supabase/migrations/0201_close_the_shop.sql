-- Jared: "Let's not have the shop for now, neither anything that players can't
-- buy, neither in-game money, so we focus on just the gameplay itself."
--
-- Switches Crowns and the Shop off WITHOUT deleting anything, so it can come
-- back later: balances (profiles.crowns), the audit tables, skins.price and the
-- buy_skin()/admin_adjust_crowns() functions all stay. What changes:
--   * nothing pays Crowns any more -- xp_rules.crowns and xp_levels.crowns are
--     zeroed (cn_award_xp reads those columns, so it pays 0 and writes no
--     crown_events). To restore: ranked win was 3, and the level payouts ran
--     5..61 over levels 2..30 (Admin -> Levels -> "Fill the Crowns column").
--   * buy_skin() refuses, so a stray client (or an old cached bundle) cannot
--     spend or earn anything either.
-- The client hides every Crowns/price control behind CROWNS_ENABLED
-- (src/lib/features.ts) and no longer has a Shop page or tile.

update public.xp_rules  set crowns = 0 where crowns <> 0;
update public.xp_levels set crowns = 0 where crowns <> 0;

create or replace function public.buy_skin(p_slug text)
 returns integer
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  raise exception 'the Shop is closed for now';
end $function$;
