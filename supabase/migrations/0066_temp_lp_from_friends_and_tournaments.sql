-- =============================================================================
-- 0066 -- TEMPORARY, admin-toggleable: let 1v1 friend-room matches and 1v1
-- tournament matches earn ladder points too, not only queued ranked
-- matches. Bots are explicitly excluded either way.
--
-- WHY: per Jared, ladder points should be obtainable "from friend matches
-- and tournaments too (not bots)" -- but only as a toggle he can flip live,
-- not a permanent change to what `ranked` means or to the matchmaking/bot/
-- rematch paths, all of which are untouched by this migration.
--
-- SHAPE: a new singleton settings row (`app_settings`, `id boolean` PK
-- `= true`, copying the existing `music_settings` singleton-row pattern)
-- carries one boolean, `friend_and_tournament_lp_enabled`, defaulting to
-- false (off until Jared turns it on). `cn_friend_tournament_lp_enabled()`
-- reads it (STABLE SQL function, mirroring the shape of this project's
-- other small read-only settings lookups). RLS: readable by anyone
-- authenticated, writable only by `cn_is_super_admin()` -- see 0070/0071
-- for the grant + realtime-publication hotfixes this row needed on top of
-- what's created here.
--
-- WHERE THE GATE GOES: everywhere a match currently calls `finish_match`
-- only `if m.ranked` -- claim_win, cn_finish, and (0067/0068, separately,
-- since both are large functions edited on their own) cn_attack and
-- advance_turn's AFK-forfeit branch -- becomes
--   `if m.ranked or (m.bot is null and cn_friend_tournament_lp_enabled())`
-- `m.bot is null` is what "not a bot match" means here (bot_step always
-- plays the guest seat in a bot match) -- so a friend-room OR tournament
-- match (neither of which sets `ranked`) earns LP exactly when the toggle
-- is on, and a bot match never does, toggle or not.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. app_settings: singleton settings row + the one flag this round needs.
-- ---------------------------------------------------------------------------
create table if not exists public.app_settings (
  id boolean primary key default true,
  season int not null default 1,
  constraint app_settings_singleton check (id)
);
insert into public.app_settings (id) values (true) on conflict (id) do nothing;

alter table public.app_settings
  add column if not exists friend_and_tournament_lp_enabled boolean not null default false;

alter table public.app_settings enable row level security;

drop policy if exists "settings readable" on public.app_settings;
create policy "settings readable" on public.app_settings
  for select to authenticated using (true);

drop policy if exists "super admin writes app settings" on public.app_settings;
create policy "super admin writes app settings" on public.app_settings
  for update to authenticated
  using (cn_is_super_admin())
  with check (cn_is_super_admin());

create or replace function public.cn_friend_tournament_lp_enabled()
 returns boolean
 language sql
 stable
 set search_path to 'public'
as $function$
  select coalesce((select friend_and_tournament_lp_enabled from public.app_settings), false)
$function$;

-- ---------------------------------------------------------------------------
-- 2. claim_win -- an idle opponent forfeits their friend-room/tournament
--    match with LP on the line too, when the toggle is on.
-- ---------------------------------------------------------------------------
create or replace function public.claim_win(p_match uuid)
 returns matches
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  m public.matches; v_side text; v_other text; v_n int;
  v_their_id uuid; v_seen timestamptz; v_busy boolean := false; u jsonb; st jsonb;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'active' then raise exception 'match is not running'; end if;
  if m.bot is not null then raise exception 'the bot does not go anywhere'; end if;

  v_side := side_of(m, auth.uid());
  if v_side is null then raise exception 'you are spectating this match'; end if;
  v_other := case when v_side = 'host' then 'guest' else 'host' end;

  v_n := coalesce((m.state->'idle'->>v_other)::int, 0);
  if v_n < 3 then raise exception 'they have not missed three turns yet'; end if;

  for u in select * from jsonb_array_elements(m.state->'units') loop
    if u->>'owner' = v_other and ((u->>'moved')::boolean or (u->>'acted')::boolean) then
      v_busy := true;
    end if;
  end loop;
  if v_busy then raise exception 'they are playing right now'; end if;

  if v_n < 6 then
    v_their_id := case when v_other = 'host' then m.host_id else m.guest_id end;
    select seen_at into v_seen from public.match_presence
     where match_id = p_match and user_id = v_their_id;
    if v_seen is not null and v_seen > now() - presence_grace() then
      raise exception 'they are still connected — you can claim this once they drop, or after six missed turns';
    end if;
  end if;

  -- 0066: was `if m.ranked then` alone -- see this migration's header.
  if m.ranked or (m.bot is null and cn_friend_tournament_lp_enabled()) then
    perform finish_match(m.id, v_side, 'abandon');
  end if;
  st := jsonb_set(m.state, '{winner}', to_jsonb(v_side));
  st := state_log(st,
        case when v_other = 'host' then m.host_name else m.guest_name end
        || ' abandoned the match. '
        || case when v_side = 'host' then m.host_name else m.guest_name end || ' wins.');

  update public.matches
     set state = st, status = 'finished', winner = v_side,
         turn_deadline = null, updated_at = now()
   where id = m.id returning * into m;
  return m;
end $function$;

-- ---------------------------------------------------------------------------
-- 3. cn_finish -- the shared normal-combat-end helper cn_attack and
--    cn_ability both call. Same gate.
-- ---------------------------------------------------------------------------
create or replace function public.cn_finish(m matches, p_st jsonb, p_win text)
 returns matches
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v public.matches; v_bot_uid uuid;
begin
  -- 0066: was `if m.ranked then` alone -- see this migration's header.
  if m.ranked or (m.bot is null and cn_friend_tournament_lp_enabled()) then
    perform finish_match(m.id, p_win, 'defeat');
  end if;

  -- 0045: a bot match has no rank on the line, but a win over the bot still
  -- counts toward the bot-wins tiers. The bot is always the guest -- bot_step
  -- never plays anything else -- so a human win here is always p_win='host',
  -- and the human is always m.host_id.
  if m.bot is not null and p_win = 'host' and m.host_id is not null then
    v_bot_uid := m.host_id;
    update public.profiles set bot_wins = bot_wins + 1 where id = v_bot_uid;
    perform cn_check_achievements(v_bot_uid);
  end if;

  p_st := jsonb_set(p_st, '{winner}', to_jsonb(p_win));
  p_st := state_log(p_st,
    case when p_win = 'host' then m.host_name else m.guest_name end || ' wins.');
  update public.matches
     set state = p_st, status = 'finished', winner = p_win,
         turn_deadline = null, updated_at = now()
   where id = m.id returning * into v;
  return v;
end $function$;

-- ---------------------------------------------------------------------------
-- 4. resign_match -- resigning a friend-room/tournament match also has LP
--    on the line when the toggle is on.
-- ---------------------------------------------------------------------------
create or replace function public.resign_match(p_match uuid)
 returns matches
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare m public.matches; v_side text; v_win text; v_st jsonb;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  v_side := side_of(m, auth.uid());
  if v_side is null then raise exception 'you are spectating this match'; end if;
  if m.status not in ('active', 'deploying') then return m; end if;

  v_win := case when v_side = 'host' then 'guest' else 'host' end;
  -- 0066: was `if m.ranked then` alone -- see this migration's header.
  if m.ranked or (m.bot is null and cn_friend_tournament_lp_enabled()) then
    perform finish_match(m.id, v_win, 'resign');
  end if;

  v_st := state_log(m.state,
        case when v_side = 'host' then m.host_name else m.guest_name end
        || ' resigned. '
        || case when v_win = 'host' then m.host_name else m.guest_name end || ' wins.');
  v_st := jsonb_set(v_st, '{winner}', to_jsonb(v_win));

  update public.matches
     set state = v_st, status = 'finished', winner = v_win,
         turn_deadline = null, updated_at = now()
   where id = m.id returning * into m;
  return m;
end $function$;

-- ---------------------------------------------------------------------------
-- Did it work?
-- ---------------------------------------------------------------------------
select
  (select friend_and_tournament_lp_enabled from public.app_settings where id = true) = false
    as toggle_defaults_off,
  cn_friend_tournament_lp_enabled() = false as reader_matches_default;
