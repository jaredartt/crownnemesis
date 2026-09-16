-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE of anything but a caller's own stale
--  rows, so no "Potential issue detected" dialog.
--  Run 0042 first. Run this BEFORE 0043 -- 0043's friend-request and
--  match-invite RPCs insert into this table directly, being SECURITY
--  DEFINER themselves, and that insert should not be reaching for a table
--  that is not there yet. The last statement prints a row of checks; every
--  column must say true.
-- ===========================================================================
--  0044 - one inbox for the things another player did to you
--
--  A friend request, an invite to a match, somebody accepting your request --
--  three different tables could each grow their own "has this been seen"
--  column, and a bell that has to poll three tables for one badge is a bell
--  that lags. One table, typed by a `type` column and carrying whatever that
--  type needs in `payload`, is what a single realtime subscription and a
--  single unread count can both be built on.
--
--  WHY NOT A CLIENT INSERT POLICY. Every row here is something ONE ACCOUNT is
--  telling ANOTHER about -- exactly the "mutates another user's row" case the
--  project's own convention says gets a SECURITY DEFINER RPC instead of an
--  RLS policy, because the row has to be trusted (a fabricated
--  friend_accepted notification is a lie, not a preference). 0043's RPCs are
--  already SECURITY DEFINER for their own reasons, so they insert here
--  directly rather than through a second function that would only wrap one
--  `insert`; cn_notify below exists anyway, so every call site reads the same
--  four words instead of repeating the same INSERT INTO.
--
--  EXPIRY: pg_cron is a listed extension on this project but its extension
--  row show `installed_version: null` -- it has never actually been turned on
--  here, and turning it on is a project-wide switch this migration has no
--  business flipping just to sweep one table. So the 48-hour cutoff is LAZY:
--  fetch_notifications() deletes its OWN caller's stale rows as its first
--  statement, before it selects. A notification nobody has opened in two days
--  is swept the next time -- and only the next time -- that account opens the
--  bell. Nothing sweeps a bell that never gets opened again, which is exactly
--  the account least likely to care that its own dead rows are still sitting
--  there.
-- ===========================================================================

create table if not exists public.notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  type       text not null check (type in ('friend_request', 'match_invite', 'friend_accepted')),
  payload    jsonb not null default '{}'::jsonb,
  read       boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists notifications_inbox_idx
  on public.notifications(user_id, created_at desc);

alter table public.notifications enable row level security;

drop policy if exists "notifications readable by owner" on public.notifications;
create policy "notifications readable by owner"
  on public.notifications for select to authenticated
  using (user_id = auth.uid());

-- Column-scoped on purpose: the policy alone would let a client flip its OWN
-- `type` or `payload`, which is indistinguishable from forging one. The grant
-- below is what actually narrows it to `read`; the policy just says whose row.
drop policy if exists "notifications owner marks read" on public.notifications;
create policy "notifications owner marks read"
  on public.notifications for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

grant select on public.notifications to authenticated;
grant update (read) on public.notifications to authenticated;
-- No insert policy, and no delete policy: a row here appears and disappears
-- only through the functions below.

-- ---------------------------------------------------------------------------
-- the internal helper every RPC that raises a notification calls, here and in
-- 0043. Not SECURITY DEFINER itself -- it does not need to be. Every caller
-- of it is already SECURITY DEFINER, and a plain function invoked mid-call by
-- one runs under that caller's own elevated role, not the original client's.
-- Left grantable to PUBLIC (nothing revokes it below) because RLS backstops
-- it anyway: a client that called this directly would still be inserting as
-- itself, and itself has no insert policy on this table.
-- ---------------------------------------------------------------------------
create or replace function public.cn_notify(p_user uuid, p_type text, p_payload jsonb)
returns void language plpgsql set search_path = public as $$
begin
  insert into public.notifications (user_id, type, payload)
  values (p_user, p_type, coalesce(p_payload, '{}'::jsonb));
end $$;

-- ---------------------------------------------------------------------------
-- list your own inbox, newest first, sweeping anything of yours older than
-- 48 hours on the way in. SECURITY DEFINER purely so the DELETE below has
-- something to run as -- there is no delete policy for it to lean on -- and
-- it revalidates auth.uid() itself rather than trusting a caller-supplied id.
-- ---------------------------------------------------------------------------
create or replace function public.fetch_notifications()
returns setof public.notifications
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not signed in'; end if;

  delete from public.notifications
   where user_id = v_uid and created_at < now() - interval '48 hours';

  return query
    select * from public.notifications
     where user_id = v_uid
     order by created_at desc;
end $$;

create or replace function public.mark_notification_read(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  update public.notifications set read = true
   where id = p_id and user_id = v_uid;
end $$;

create or replace function public.mark_all_notifications_read()
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  update public.notifications set read = true
   where user_id = v_uid and read = false;
end $$;

-- ---------------------------------------------------------------------------
-- realtime, so the bell lights up without a poll
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname='supabase_realtime' and schemaname='public' and tablename='notifications') then
    alter publication supabase_realtime add table public.notifications;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- who may call what
-- ---------------------------------------------------------------------------
revoke execute on function public.cn_notify(uuid, text, jsonb) from anon, authenticated;

grant execute on function public.fetch_notifications()        to authenticated;
grant execute on function public.mark_notification_read(uuid) to authenticated;
grant execute on function public.mark_all_notifications_read() to authenticated;

-- ---------------------------------------------------------------------------
-- Did it work? All true means yes.
-- ---------------------------------------------------------------------------
select
  to_regclass('public.notifications') is not null                     as notifications_exists,
  to_regprocedure('public.cn_notify(uuid,text,jsonb)') is not null     as cn_notify_exists,
  to_regprocedure('public.fetch_notifications()') is not null         as fetch_exists,
  to_regprocedure('public.mark_notification_read(uuid)') is not null  as mark_one_exists,
  to_regprocedure('public.mark_all_notifications_read()') is not null as mark_all_exists,
  (select count(*) from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='notifications') = 1
                                                                       as notifications_are_realtime;
