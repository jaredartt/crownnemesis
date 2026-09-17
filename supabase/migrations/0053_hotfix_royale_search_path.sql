-- HOTFIX: a batch of royale helper functions from 0048 were missing a fixed
-- search_path (get_advisors still flags them after 0048/0052, despite an
-- earlier agent's report claiming this was fixed). Since none of these are
-- SECURITY DEFINER, this is defense-in-depth rather than a real privilege
-- escalation, but it costs nothing to close and matches this project's own
-- convention (every function fixes its search_path). ALTER FUNCTION only sets
-- the config, it does not touch the function body -- zero behavior change.
alter function public.cn_own_royale(integer, integer, integer) set search_path = 'public';
alter function public.cn_royale_zone(integer) set search_path = 'public';
alter function public.cn_royale_gen_trees(integer, integer) set search_path = 'public';
alter function public.cn_royale_fresh_map() set search_path = 'public';
alter function public.cn_royale_army(jsonb, integer, text[]) set search_path = 'public';
alter function public.royale_side_of(uuid) set search_path = 'public';
alter function public.cn_begin_act_royale(jsonb, integer, text) set search_path = 'public';
alter function public.cn_end_act_royale(jsonb, text) set search_path = 'public';
