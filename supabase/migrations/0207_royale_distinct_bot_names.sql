-- 0207: two bots in the same Battle Royale room could draw the same name from
-- bot_identity() (it is a plain random pick of 50, so a 4-seat table with 3 bots
-- collides about 6% of the time). add_royale_bot now re-draws until the name is
-- not already used by another seat in the room (up to 30 tries, then it keeps
-- the last draw rather than failing). Everything else is exactly 0181's body.
create or replace function public.add_royale_bot(p_match uuid, p_seat integer, p_level integer)
 returns royale_matches
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  m public.royale_matches; v_uid uuid := auth.uid();
  v_lvl int := 3; -- 0181: Battle Royale bots are always Expert; p_level is ignored
  v_st jsonb; v_bot record; i int := 0;
begin
  select * into m from public.royale_matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'waiting' then raise exception 'you can only add a bot before the match starts'; end if;

  if not exists (
    select 1 from public.royale_players
     where match_id = p_match and seat = 0 and user_id = v_uid) then
    raise exception 'only the host can add a bot';
  end if;

  if p_seat < 1 or p_seat > 3 then raise exception 'no such seat'; end if;

  if exists (select 1 from public.royale_players where match_id = p_match and seat = p_seat) then
    raise exception 'that seat is already taken';
  end if;

  loop
    select * into v_bot from public.bot_identity();
    i := i + 1;
    exit when i >= 30 or not exists (
      select 1 from public.royale_players
       where match_id = p_match and lower(username) = lower(v_bot.name));
  end loop;

  insert into public.royale_players (match_id, seat, user_id, username, avatar, name_color, bot)
  values (p_match, p_seat, null, v_bot.name, v_bot.avatar, v_bot.name_color, v_lvl);

  v_st := state_log(m.state, v_bot.name || ' joins the arena.');
  update public.royale_matches set state = v_st, updated_at = now()
   where id = m.id returning * into m;
  return m;
end
$function$;
