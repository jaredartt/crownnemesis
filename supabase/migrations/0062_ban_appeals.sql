-- 0062_ban_appeals.sql
--
-- Two asks from the developer, both about banned accounts:
--   1. A list of banned accounts inside the admin menu, inside Users --
--      AdminUsers.tsx has always required typing a username to find one,
--      which makes "who is currently banned" a question nobody could
--      actually answer from the screen. admin_list_banned() below is that
--      list, gated by cn_is_super_admin() the same way every other admin
--      RPC on this table already is.
--   2. A way for a banned account to appeal. Banning (0039) is a client-
--      side dead end on purpose -- App.tsx's banned screen has never had
--      anything on it but a "back to menu" button that signs the account
--      out. This migration adds one door out: submit_ban_appeal() lets the
--      still-signed-in banned account (is_banned does not sign anyone out
--      by itself -- see App.tsx's own comment: the Realtime row-change is
--      what shows the banned screen, and signing out is a separate,
--      explicit click) leave one message, and admin_resolve_ban_appeal()
--      lets Jared approve (which unbans through the existing
--      admin_set_banned(), not a second copy of that logic) or deny it.
--
-- ban_appeals carries no RLS policies at all -- reachable only through the
-- three SECURITY DEFINER functions below -- the same "zero policies, RPC
-- only" shape match_presence (0003) and ranked_queue (0007) already use on
-- this project, not a new pattern.

create table if not exists public.ban_appeals (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  message     text not null,
  status      text not null default 'pending' check (status in ('pending', 'approved', 'denied')),
  admin_note  text,
  created_at  timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid references auth.users(id)
);
create index if not exists ban_appeals_user_idx on public.ban_appeals(user_id, created_at desc);
create index if not exists ban_appeals_status_idx on public.ban_appeals(status, created_at desc);

alter table public.ban_appeals enable row level security;

-- ---------------------------------------------------------------------------
-- The banned account's own two calls.
-- ---------------------------------------------------------------------------

-- One pending appeal at a time -- a second message while the first is still
-- open is an edit, not a new appeal, and letting them stack would make the
-- admin list noisy for no reason. Length-checked the same trivial way
-- send_friend_request (0043) checks a body isn't empty.
create or replace function public.submit_ban_appeal(p_message text)
returns public.ban_appeals
language plpgsql security definer set search_path = public as $$
declare v_row public.ban_appeals; v_pending int;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not exists (select 1 from public.profiles where id = auth.uid() and is_banned) then
    raise exception 'your account is not banned';
  end if;
  if length(btrim(coalesce(p_message, ''))) = 0 then raise exception 'say something first'; end if;
  if length(p_message) > 2000 then raise exception 'that is too long'; end if;

  select count(*) into v_pending from public.ban_appeals
    where user_id = auth.uid() and status = 'pending';
  if v_pending > 0 then raise exception 'you already have an appeal waiting on a reply'; end if;

  insert into public.ban_appeals (user_id, message)
    values (auth.uid(), btrim(p_message))
    returning * into v_row;
  return v_row;
end $$;
grant execute on function public.submit_ban_appeal(text) to authenticated;

create or replace function public.my_ban_appeals()
returns setof public.ban_appeals
language sql security definer set search_path = public as $$
  select * from public.ban_appeals where user_id = auth.uid() order by created_at desc;
$$;
grant execute on function public.my_ban_appeals() to authenticated;

-- ---------------------------------------------------------------------------
-- The admin's two calls -- both gated by cn_is_super_admin(), same door
-- every other function on this table (admin_set_banned, admin_update_profile)
-- already uses.
-- ---------------------------------------------------------------------------

create or replace function public.admin_list_banned()
returns setof public.profiles
language plpgsql security definer set search_path = public as $$
begin
  if not cn_is_super_admin() then raise exception 'admin only'; end if;
  return query select * from public.profiles where is_banned order by username;
end $$;
grant execute on function public.admin_list_banned() to authenticated;

create or replace function public.admin_list_ban_appeals()
returns table (
  id uuid, user_id uuid, username text, message text, status text,
  admin_note text, created_at timestamptz, resolved_at timestamptz
)
language plpgsql security definer set search_path = public as $$
begin
  if not cn_is_super_admin() then raise exception 'admin only'; end if;
  return query
    select a.id, a.user_id, p.username, a.message, a.status, a.admin_note, a.created_at, a.resolved_at
    from public.ban_appeals a
    join public.profiles p on p.id = a.user_id
    -- pending ones first, newest first within each group.
    order by (a.status = 'pending') desc, a.created_at desc;
end $$;
grant execute on function public.admin_list_ban_appeals() to authenticated;

-- Approving calls the EXISTING admin_set_banned() to lift the ban rather
-- than duplicating its update -- one place that ever flips is_banned to
-- false, same as 0039 intended.
create or replace function public.admin_resolve_ban_appeal(p_id uuid, p_approve boolean, p_note text default null)
returns public.ban_appeals
language plpgsql security definer set search_path = public as $$
declare v_row public.ban_appeals;
begin
  if not cn_is_super_admin() then raise exception 'admin only'; end if;

  update public.ban_appeals
     set status = case when p_approve then 'approved' else 'denied' end,
         admin_note = nullif(btrim(coalesce(p_note, '')), ''),
         resolved_at = now(),
         resolved_by = auth.uid()
   where id = p_id and status = 'pending'
   returning * into v_row;

  if v_row is null then raise exception 'no such pending appeal'; end if;

  if p_approve then
    perform public.admin_set_banned(v_row.user_id, false);
  end if;

  return v_row;
end $$;
grant execute on function public.admin_resolve_ban_appeal(uuid, boolean, text) to authenticated;
