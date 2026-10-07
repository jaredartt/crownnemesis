-- 0206: joining a Battle Royale room by code is only possible while it is still
-- 'waiting'. start_royale_match builds every seat's army (royale_deploy rows) at
-- the moment the host presses Start, so a seat taken during 'deploying' never
-- gets one: that player cannot place units or press Ready and -- being present,
-- so never swept as AFK -- would hold the whole table in deployment forever.
-- Re-joining your OWN seat still works at any time (handled before this check).
create or replace function public.join_royale_match(p_code text)
 returns royale_matches
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid(); v_name text; v_avatar text; m public.royale_matches;
  v_seat int; v_taken int[]; v_st jsonb; i int;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select username, avatar into v_name, v_avatar from public.profiles where id = v_uid;
  if v_name is null then raise exception 'no profile'; end if;

  select * into m from public.royale_matches where code = upper(trim(p_code)) for update;
  if m.id is null then raise exception 'no room with that code'; end if;

  select seat into v_seat from public.royale_players
   where match_id = m.id and user_id = v_uid;
  if v_seat is not null then return m; end if;

  if m.status <> 'waiting' then
    raise exception 'that match has already started';
  end if;

  select array_agg(seat) into v_taken from public.royale_players where match_id = m.id;
  v_seat := null;
  for i in 0 .. 3 loop
    if not (i = any(coalesce(v_taken, '{}'::int[]))) then v_seat := i; exit; end if;
  end loop;
  if v_seat is null then raise exception 'that room is already full'; end if;

  insert into public.royale_players (match_id, seat, user_id, username, avatar)
  values (m.id, v_seat, v_uid, v_name, v_avatar);

  v_st := state_log(m.state, v_name || ' entered the arena.');
  update public.royale_matches set state = v_st, updated_at = now()
   where id = m.id returning * into m;
  return m;
end
$function$;
