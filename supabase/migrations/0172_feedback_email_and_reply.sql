-- Jared: "can we also link the feedback/bug report thing to emails? So
-- that whenever I receive a message like that, I receive an email... Also
-- if I respond to them through the game (inside the admin panel), my
-- responses are sent to them as emails to the email that they put in a
-- field in those messages."
--
-- Two additions to 0169's feedback table: an `email` the submitter types
-- in (the app has no email of theirs otherwise -- Supabase auth here is
-- magic-link/OAuth, and profiles carries no email column), and an
-- `admin_reply`/`replied_at` pair for the one reply Jared writes back.
-- Actually SENDING either email is not this migration's job -- see
-- send-feedback-email/index.ts (a Supabase Edge Function, deployed
-- separately) and the client calls that invoke it right after
-- submit_feedback/admin_reply_feedback succeed. This migration only makes
-- the data durable; a failed email send should never lose a bug report.

alter table public.feedback add column email text;
alter table public.feedback add column admin_reply text;
alter table public.feedback add column replied_at timestamptz;

-- submit_feedback's signature is changing (one new required argument), so
-- the old two-argument version is dropped outright rather than left as a
-- dead overload nothing calls -- every client on this build already sends
-- the third argument by the time this migration ships.
drop function if exists public.submit_feedback(text, text);

create or replace function public.submit_feedback(p_kind text, p_message text, p_email text)
returns public.feedback
language plpgsql
security definer
set search_path = public
as $$
declare v_row public.feedback;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if p_kind not in ('bug', 'feedback') then raise exception 'invalid kind'; end if;
  if length(btrim(coalesce(p_message, ''))) = 0 then raise exception 'say something first'; end if;
  if length(p_message) > 4000 then raise exception 'that is too long'; end if;
  if length(btrim(coalesce(p_email, ''))) = 0 then raise exception 'add an email so we can reply'; end if;
  -- A light sanity check, not a real validator -- Postgres has no built-in
  -- one and this is not the hill to build one on. Catches "forgot the @"
  -- and leaves the rest to Resend, which will bounce a truly bad address.
  if p_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'that email does not look right'; end if;
  if length(p_email) > 320 then raise exception 'that email is too long'; end if;

  insert into public.feedback (user_id, kind, message, email)
    values (auth.uid(), p_kind, btrim(p_message), btrim(lower(p_email)))
    returning * into v_row;
  return v_row;
end $$;

grant execute on function public.submit_feedback(text, text, text) to authenticated;

-- Return shape is changing (three new columns), so the old function is
-- dropped rather than create-or-replaced -- Postgres refuses to change a
-- function's OUT-parameter row type in place.
drop function if exists public.admin_list_feedback();

create function public.admin_list_feedback()
returns table (
  id uuid,
  user_id uuid,
  username text,
  name_color text,
  kind text,
  message text,
  email text,
  admin_reply text,
  replied_at timestamptz,
  resolved boolean,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not cn_is_super_admin() then raise exception 'admin only'; end if;
  return query
  select
    f.id, f.user_id, p.username, p.name_color, f.kind, f.message, f.email,
    f.admin_reply, f.replied_at, f.resolved, f.created_at
  from public.feedback f
  join public.profiles p on p.id = f.user_id
  order by f.resolved asc, f.created_at desc;
end $$;

grant execute on function public.admin_list_feedback() to authenticated;

-- Sets the one reply a report carries (overwrites a previous one rather
-- than threading -- Jared asked for "my responses are sent to them",
-- singular, and the admin panel has no thread UI; a second reply is still
-- possible later, it just replaces what's here, same as this row's own
-- `resolved` toggle already works). Returns the full row so the client can
-- read back email/message/kind for the email it's about to trigger,
-- without a second round trip.
create or replace function public.admin_reply_feedback(p_id uuid, p_reply text)
returns public.feedback
language plpgsql
security definer
set search_path = public
as $$
declare v_row public.feedback;
begin
  if not cn_is_super_admin() then raise exception 'admin only'; end if;
  if length(btrim(coalesce(p_reply, ''))) = 0 then raise exception 'write something first'; end if;
  if length(p_reply) > 4000 then raise exception 'that is too long'; end if;
  update public.feedback
    set admin_reply = btrim(p_reply), replied_at = now()
    where id = p_id
    returning * into v_row;
  if v_row.id is null then raise exception 'no such feedback'; end if;
  return v_row;
end $$;

grant execute on function public.admin_reply_feedback(uuid, text) to authenticated;
