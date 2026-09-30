-- 0195: take the public API away from internal engine functions.
--
-- Found in a security review (Jared: "ways a player could ruin supabase"):
-- Postgres gives EXECUTE to PUBLIC on every new function, and Supabase exposes
-- every public-schema function as an RPC. These four were reachable by anyone
-- holding the (public) anon key, with no sign-in:
--   cn_award_xp(user, mode, result, ref)  -> unlimited XP/Crowns for any account
--                                            (vary `ref`; idempotency is per ref)
--   cn_defend(match, side, unit, target)  -> act as either side in anyone's match
--   cn_royale_mark_ready(match, seat, ..) -> mark any seat ready, starting a
--                                            Battle Royale before others deployed
--   sim_play_one_game(...)                -> up to 300 engine turns per call,
--                                            unauthenticated (DB CPU denial of service)
-- Every caller inside the database is SECURITY DEFINER and the app never calls
-- them by name, so nothing a player does changes.
revoke execute on function public.cn_award_xp(uuid, text, text, text) from public, anon, authenticated;
revoke execute on function public.cn_defend(uuid, text, text, text) from public, anon, authenticated;
revoke execute on function public.cn_royale_mark_ready(uuid, integer, text) from public, anon, authenticated;
revoke execute on function public.sim_play_one_game(uuid, integer, text[], text[], uuid, uuid) from public, anon, authenticated;
revoke execute on function public.sim_play_one_game(uuid, integer, text[], text[], uuid, uuid, timestamp with time zone) from public, anon, authenticated;
