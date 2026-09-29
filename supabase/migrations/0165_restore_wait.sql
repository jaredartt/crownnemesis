-- Jared: first asked to remove Wait entirely ("remove this option from
-- everywhere in the game, it makes no sense... no need for this option!" --
-- see 0086_remove_wait.sql), then changed his mind the same month: "I want
-- the 'Wait' button back, please."
--
-- Recreated byte-for-byte from the last live bodies before 0086 dropped
-- them (submit_wait: 0036_the_throw.sql; submit_royale_wait: 0051's own
-- bug-fix pass, which is the version 0086 actually dropped) rather than
-- rewritten from scratch, so this restores exactly the behavior that was
-- there -- including submit_wait's pending-throw guard and
-- submit_royale_wait's last_acted_turn stamp (0051: "every other
-- submit_royale_* stamps last_acted_turn already; wait was the one
-- missed"). cn_end_act / cn_end_act_royale were never dropped -- 0086 left
-- them in place for Defend -- so both bodies below call the exact same
-- helpers they always did.
create or replace function public.submit_wait(p_match uuid)
returns public.matches
language plpgsql security definer set search_path = public as $$
declare m public.matches; v_side text; v_active text; v_st jsonb;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'active' then raise exception 'match is not running'; end if;
  v_side := side_of(m, auth.uid());
  if v_side is null then raise exception 'you are spectating this match'; end if;
  if m.state->>'turn' <> v_side then raise exception 'not your turn'; end if;

  v_st := m.state;
  -- submit_wait and end_turn are the two that never reach cn_begin_act.
  if cn_pending(v_st) is not null then raise exception 'a throw is pending'; end if;
  v_active := nullif(v_st->>'active', '');
  if v_active is null then return m; end if;   -- nobody mid-go; nothing to end

  v_st := cn_end_act(v_st, v_active);
  update public.matches set state = v_st, updated_at = now()
   where id = m.id returning * into m;
  return m;
end $$;

create or replace function public.submit_royale_wait(p_match uuid)
 returns royale_matches
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare m public.royale_matches; v_seat int; v_st jsonb; v_active text;
begin
  select * into m from public.royale_matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'active' then raise exception 'match is not running'; end if;
  v_seat := royale_side_of(p_match);
  if v_seat is null then raise exception 'you are spectating this match'; end if;
  if coalesce((m.state->>'turn')::int, -1) <> v_seat then raise exception 'not your turn'; end if;

  update public.royale_players set last_acted_turn = (m.state->>'turnNumber')::int
   where match_id = p_match and seat = v_seat;

  v_st := m.state;
  v_active := nullif(v_st->>'active', '');
  if v_active is null then return m; end if;
  v_st := cn_end_act_royale(v_st, v_active);
  update public.royale_matches set state = v_st, updated_at = now()
   where id = m.id returning * into m;
  return m;
end
$function$;

grant execute on function public.submit_wait(uuid) to authenticated;
grant execute on function public.submit_royale_wait(uuid) to authenticated;

select
  to_regprocedure('public.submit_wait(uuid)') is not null as wait_is_back,
  to_regprocedure('public.submit_royale_wait(uuid)') is not null as royale_wait_is_back;
