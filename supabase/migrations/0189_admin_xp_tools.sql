-- 0189: admin tools for XP + the starting name colours.
--
-- Jared: "I should be able to track, modify, add, remove XP and levels from
-- anyone at any given point from the admin panel." admin_adjust_xp is the one
-- door: add (negative removes), set an exact XP, or jump to a level's threshold.
-- Every adjustment lands in xp_events (mode 'admin', ref 'a:<uuid>') so the
-- player's history shows who got what; the xp delta is signed.
--
-- Also: everyone now starts with black + gray (blue moves to level 2 -- anyone
-- who already wears blue keeps it, it was granted as 'legacy' in 0188) and a
-- new account's default name colour is black.

create or replace function public.admin_adjust_xp(p_user uuid, p_op text, p_value integer)
returns table (xp integer, level integer)
language plpgsql security definer set search_path to 'public' as $$
declare v_old integer; v_new integer; v_target integer;
begin
  if not public.cn_is_super_admin() then raise exception 'only the admin can change XP'; end if;
  select p.xp into v_old from public.profiles p where p.id = p_user for update;
  if not found then raise exception 'no such player'; end if;
  if p_op = 'add' then
    v_new := v_old + coalesce(p_value, 0);
  elsif p_op = 'set' then
    v_new := coalesce(p_value, 0);
  elsif p_op = 'level' then
    select l.xp_total into v_target from public.xp_levels l where l.level = p_value;
    if v_target is null then raise exception 'there is no level %', p_value; end if;
    v_new := v_target;
  else
    raise exception 'unknown operation';
  end if;
  v_new := greatest(0, v_new);
  perform set_config('cn.progress_write', '1', true);
  update public.profiles set xp = v_new where id = p_user;
  perform set_config('cn.progress_write', '', true);
  insert into public.xp_events (user_id, ref, mode, result, xp, level_before, level_after)
  values (p_user, 'a:' || gen_random_uuid(), 'admin', p_op, v_new - v_old,
          public.cn_level_for_xp(v_old), public.cn_level_for_xp(v_new));
  return query select v_new, public.cn_level_for_xp(v_new);
end $$;

alter table public.profiles alter column name_color set default 'black';
update public.skins set unlock_level = 1 where slug = 'black';
update public.skins set unlock_level = 2 where slug = 'blue';
update public.skins set description = null where slug = 'blue';
