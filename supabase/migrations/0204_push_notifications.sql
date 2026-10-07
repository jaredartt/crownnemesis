-- 0204: phone / desktop push notifications (Web Push).
-- The in-game bell (public.notifications) is unchanged. This adds the extra
-- channel: a device subscribes, and the database tells the send-push edge
-- function when something happens that the player wants to hear about --
--   a tournament opening, a friend request, a 1v1 or Battle Royale invite,
--   a new best player in the player's country.
-- Per-type switches live on profiles.push_prefs ({"friend_request": false, ...};
-- a missing key means ON). Secrets (VAPID private key, hook secret) are written
-- LIVE into push_config and are deliberately not in this file.

create extension if not exists pg_net with schema extensions;

alter table public.profiles add column if not exists push_prefs jsonb not null default '{}'::jsonb;

create table if not exists public.push_subscriptions (
  endpoint   text primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  p256dh     text not null,
  auth       text not null,
  user_agent text,
  created_at timestamptz not null default now()
);
create index if not exists push_subscriptions_user on public.push_subscriptions(user_id);
alter table public.push_subscriptions enable row level security;   -- no policies: RPCs + service role only
revoke all on public.push_subscriptions from anon, authenticated;

create table if not exists public.push_config (
  id int primary key default 1 check (id = 1),
  vapid_public text, vapid_private text, hook_secret text, subject text
);
alter table public.push_config enable row level security;          -- no policies: service role only
revoke all on public.push_config from anon, authenticated;

create table if not exists public.country_top (
  country text primary key,
  user_id uuid not null references public.profiles(id) on delete cascade
);
alter table public.country_top enable row level security;
revoke all on public.country_top from anon, authenticated;

-- ---- what the app calls ------------------------------------------------------
create or replace function public.cn_push_subscribe(p_endpoint text, p_p256dh text, p_auth text, p_ua text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'sign in first'; end if;
  insert into public.push_subscriptions (endpoint, user_id, p256dh, auth, user_agent)
  values (p_endpoint, auth.uid(), p_p256dh, p_auth, left(p_ua, 200))
  on conflict (endpoint) do update
    set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth, user_agent = excluded.user_agent;
end $$;

create or replace function public.cn_push_unsubscribe(p_endpoint text)
returns void language sql security definer set search_path = public as $$
  delete from public.push_subscriptions where endpoint = p_endpoint and user_id = auth.uid();
$$;

create or replace function public.cn_set_push_prefs(p_prefs jsonb)
returns void language sql security definer set search_path = public as $$
  update public.profiles set push_prefs = coalesce(p_prefs, '{}'::jsonb) where id = auth.uid();
$$;

revoke all on function public.cn_push_subscribe(text, text, text, text), public.cn_push_unsubscribe(text), public.cn_set_push_prefs(jsonb) from public, anon;
grant execute on function public.cn_push_subscribe(text, text, text, text), public.cn_push_unsubscribe(text), public.cn_set_push_prefs(jsonb) to authenticated;

-- ---- the sender --------------------------------------------------------------
-- One call per language, each already filtered to people who (a) have a device
-- subscribed and (b) have not switched this type off. Never lets a failed push
-- break the game action that caused it.
create or replace function public.cn_push_send(p_users uuid[], p_type text, p_en text, p_es text, p_url text default './')
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_secret text; v_lang text; v_ids uuid[];
begin
  select hook_secret into v_secret from public.push_config where id = 1;
  if v_secret is null then return; end if;
  foreach v_lang in array array['en', 'es'] loop
    select array_agg(distinct s.user_id) into v_ids
      from public.push_subscriptions s
      join public.profiles p on p.id = s.user_id
     where s.user_id = any (p_users)
       and coalesce((p.push_prefs ->> p_type)::boolean, true)
       and (case when coalesce(p.settings ->> 'lang', 'en') = 'es' then 'es' else 'en' end) = v_lang;
    if v_ids is not null then
      perform net.http_post(
        url := 'https://dnhvfajvfhmqpbwfvyfq.supabase.co/functions/v1/send-push',
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-hook-secret', v_secret),
        body := jsonb_build_object('user_ids', v_ids, 'title', 'Crown Nemesis',
                  'body', case when v_lang = 'es' then p_es else p_en end, 'url', p_url, 'tag', p_type));
    end if;
  end loop;
exception when others then null;
end $$;
revoke all on function public.cn_push_send(uuid[], text, text, text, text) from public, anon, authenticated;

-- ---- friend requests and invites (rows the bell already gets) -----------------
create or replace function public.cn_push_on_notification()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_name text := coalesce(new.payload ->> 'from_username', new.payload ->> 'by_username', 'Someone');
        v_mode text;
begin
  if new.type = 'friend_request' then
    perform public.cn_push_send(array[new.user_id], 'friend_request',
      v_name || ' sent you a friend request!', U&'\00A1' || v_name || ' te ha enviado una solicitud de amistad!');
  elsif new.type = 'match_invite' then
    v_mode := new.payload ->> 'mode';
    if v_mode = '4p' then
      perform public.cn_push_send(array[new.user_id], 'invite_royale',
        v_name || ' invited you to a Battle Royale!', U&'\00A1' || v_name || ' te ha invitado a una Battle Royale!');
    elsif v_mode = 'tournament' then
      perform public.cn_push_send(array[new.user_id], 'tournament',
        v_name || ' invited you to the tournament!', U&'\00A1' || v_name || ' te ha invitado al torneo!');
    else
      perform public.cn_push_send(array[new.user_id], 'invite_1v1',
        v_name || ' invited you to a 1vs1!', U&'\00A1' || v_name || ' te ha invitado a un 1vs1!');
    end if;
  end if;
  return new;
end $$;
drop trigger if exists cn_push_notification on public.notifications;
create trigger cn_push_notification after insert on public.notifications
  for each row execute function public.cn_push_on_notification();

-- ---- a tournament opening -------------------------------------------------------
create or replace function public.cn_push_on_tournament()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'open' then
    perform public.cn_push_send(
      (select coalesce(array_agg(distinct user_id), '{}') from public.push_subscriptions),
      'tournament', 'There''s a tournament starting!', U&'\00A1Hay un torneo a punto de empezar!');
  end if;
  return new;
end $$;
drop trigger if exists cn_push_tournament on public.tournaments;
create trigger cn_push_tournament after insert on public.tournaments
  for each row execute function public.cn_push_on_tournament();

-- ---- a new best player in a country ----------------------------------------------
create or replace function public.cn_push_country_top()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_country text; v_top uuid; v_prev uuid; v_name text;
begin
  select p.country into v_country from public.profiles p where p.id = new.user_id and not p.is_system;
  if v_country is null then return new; end if;
  select user_id into v_prev from public.country_top where country = v_country;
  select r.user_id into v_top
    from public.player_rating r join public.profiles p on p.id = r.user_id
   where p.country = v_country and not p.is_system
   order by r.rating desc, (r.user_id = v_prev) desc, r.updated_at asc limit 1;
  if v_top is null or v_top is not distinct from v_prev then return new; end if;
  insert into public.country_top (country, user_id) values (v_country, v_top)
    on conflict (country) do update set user_id = excluded.user_id;
  if v_prev is not null then   -- the very first holder of a country is not news
    select username into v_name from public.profiles where id = v_top;
    perform public.cn_push_send(
      (select coalesce(array_agg(id), '{}') from public.profiles where country = v_country and id <> v_top and not is_system),
      'country_top',
      'There''s a new best player in your country: ' || v_name || '!',
      U&'\00A1Hay un nuevo mejor jugador en tu pa\00EDs: ' || v_name || '!');
  end if;
  return new;
end $$;
drop trigger if exists cn_push_country_top on public.player_rating;
create trigger cn_push_country_top after insert or update of rating on public.player_rating
  for each row execute function public.cn_push_country_top();

-- Today's leaders are the starting point, so nobody is told about a change that already happened.
insert into public.country_top (country, user_id)
select distinct on (p.country) p.country, r.user_id
  from public.player_rating r join public.profiles p on p.id = r.user_id
 where p.country is not null and not p.is_system
 order by p.country, r.rating desc, r.updated_at asc
on conflict (country) do nothing;
