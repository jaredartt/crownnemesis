-- 0246: Settings -> Delete account. delete_my_account(p_username) erases the signed-in account
-- from everywhere, keeps what the games produced (finished matches, results, brackets) with the
-- player's name stripped ("Deleted player"). Applied via execute_sql; the live definition is the
-- source of truth.
--   * matches.host_id is nullable now, so a finished match survives its host leaving (guest_id,
--     match_results and tournament ids were already ON DELETE SET NULL).
--   * Order: leave ranked queue / tournament / live 1v1 + Royale games (forfeits count) -> scrub the
--     username out of kept rows and match logs -> delete the rows with no FK (reports, rate limits,
--     playtest rooms) -> delete the auth user (cascades profile, kingdoms, ratings, friends, chat,
--     notifications, push subscriptions, xp, skins, achievements, presence, tournament entries...).
--   * Refuses: wrong username, system accounts, and the only remaining admin.
alter table public.matches alter column host_id drop not null;

create or replace function public.delete_my_account(p_username text)
returns void language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_uid uuid := auth.uid(); v_name text; v_admin boolean; v_sys boolean; r record;
  v_gone constant text := 'Deleted player';
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select username, is_admin, is_system into v_name, v_admin, v_sys from public.profiles where id = v_uid;
  if v_name is null then raise exception 'no such account'; end if;
  if coalesce(v_sys, false) then raise exception 'this account cannot be deleted'; end if;
  if lower(btrim(coalesce(p_username, ''))) <> lower(v_name) then
    raise exception 'type your username exactly to confirm';
  end if;
  if coalesce(v_admin, false) and not exists (
       select 1 from public.profiles where is_admin and id <> v_uid and not coalesce(is_system, false)) then
    raise exception 'you are the only admin: hand the admin role to someone else first';
  end if;

  -- 1. Whatever is still running ends first, as a forfeit.
  perform public.leave_ranked();
  begin perform public.tournament_leave(); exception when others then null; end;
  for r in select id from public.matches
            where status in ('waiting', 'deploying', 'active') and not playtest
              and (host_id = v_uid or guest_id = v_uid) loop
    begin perform public.leave_match(r.id); exception when others then null; end;
  end loop;
  for r in select distinct rp.match_id from public.royale_players rp
             join public.royale_matches rm on rm.id = rp.match_id
            where rp.user_id = v_uid and rm.status in ('waiting', 'deploying', 'active') loop
    begin perform public.leave_royale_match(r.match_id); exception when others then null; end;
  end loop;
  -- Anything the forfeit could not close: finish it for the opponent, or drop it if it was solo.
  update public.matches set status = 'finished', turn_deadline = null, updated_at = now(),
         winner = case when host_id = v_uid then 'guest' else 'host' end
   where status in ('deploying', 'active') and not playtest
     and (host_id = v_uid or guest_id = v_uid)
     and host_id is not null and guest_id is not null;
  delete from public.matches
   where status <> 'finished' and not playtest and (host_id = v_uid or guest_id = v_uid);

  -- 2. What stays (finished games and their results) loses the name.
  if char_length(v_name) >= 2 and not exists (select 1 from public.cards where lower(name) = lower(v_name)) then
    update public.matches m
       set state = jsonb_set(m.state, '{log}', (
             select coalesce(jsonb_agg(
                      case when jsonb_typeof(l) = 'object' and l ? 'text'
                           then jsonb_set(l, '{text}', to_jsonb(replace(l->>'text', v_name, v_gone))) else l end
                      order by ord), '[]'::jsonb)
               from jsonb_array_elements(m.state->'log') with ordinality as t(l, ord)))
     where (m.host_id = v_uid or m.guest_id = v_uid)
       and jsonb_typeof(m.state->'log') = 'array';
  end if;
  update public.matches set host_name = v_gone, host_id = null where host_id = v_uid;
  update public.matches set guest_name = v_gone, guest_avatar = null, guest_id = null where guest_id = v_uid;
  update public.match_results set winner_name = v_gone where winner_id = v_uid;
  update public.match_results set loser_name = v_gone where loser_id = v_uid;
  update public.tournament_matches set a_name = v_gone where a_id = v_uid;
  update public.tournament_matches set b_name = v_gone where b_id = v_uid;
  update public.tournament_matches set winner_name = v_gone where winner_id = v_uid;
  update public.tournaments set winner_name = v_gone where winner_id = v_uid;
  update public.royale_players set user_id = null, username = v_gone where user_id = v_uid;
  delete from public.royale_messages where user_id = v_uid;

  -- 3. Rows with no foreign key to the account.
  delete from public.user_reports where reporter_id = v_uid or reported_id = v_uid;
  delete from public.cn_rate where user_id = v_uid;
  delete from public.cn_throttle where key like '%' || v_uid::text || '%';
  delete from public.playtest_undo where match_id in (select id from public.matches where playtest_by = v_uid);
  delete from public.matches where playtest_by = v_uid;
  delete from public.playtest_scenarios where owner = v_uid;
  update public.ban_appeals set resolved_by = null where resolved_by = v_uid;

  -- 4. The account itself: the cascade takes the profile and everything hanging off it.
  delete from auth.users where id = v_uid;
end $fn$;

revoke all on function public.delete_my_account(text) from public, anon;
grant execute on function public.delete_my_account(text) to authenticated;
