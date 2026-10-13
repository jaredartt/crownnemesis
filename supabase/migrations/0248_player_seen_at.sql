-- 0248: everybody can see everybody's last connection. user_presence's own RLS
-- still only lets you read yourself and your friends directly; this is the one
-- narrow door for a single player's seen_at (nothing else on the row).
create or replace function public.player_seen_at(p_user uuid)
returns timestamptz
language sql stable security definer set search_path = public
as $$ select seen_at from public.user_presence where user_id = p_user $$;
revoke all on function public.player_seen_at(uuid) from public, anon;
grant execute on function public.player_seen_at(uuid) to authenticated;
