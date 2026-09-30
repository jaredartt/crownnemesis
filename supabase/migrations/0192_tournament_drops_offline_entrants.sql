-- 0192: tournament sign-ups drop anyone who disconnects.
--
-- Jared: "my friend signed up for a tournament like a day ago. Remove
-- participants the moment they disconnect from the game."
--
-- Why it happened: an entry's `seen_at` is only refreshed by tournament_tick(),
-- which only runs while the player has the tournament SCREEN open -- and
-- nothing ever removed an entry whose owner went away. A sign-up from two days
-- ago still counted toward the three-player countdown.
--
-- Now:
--   * cn_tourney_drop_offline() removes every sign-up (open tournaments only --
--     a running bracket has its own forfeit rules) whose owner has gone quiet:
--       - no app heartbeat (user_presence, every 20s) and no tick for 75s, or
--       - they said goodbye (tournament_going_away, sent when the tab closes)
--         and have not been seen since, for 12s -- a reload re-beats at once.
--     It also stops the countdown if that took the count under three.
--   * a pg_cron job runs it every 15 seconds; tournament_tick() runs it too.
--   * tournament_going_away() is the tab-closing hint (a hint only: the 75s
--     rule covers a crash or a dead connection).

alter table public.tournament_entries add column if not exists away_at timestamptz;

create or replace function public.cn_tourney_drop_offline()
returns integer language plpgsql security definer set search_path to 'public' as $$
declare v_dropped integer := 0; v_gone integer;
begin
  with gone as (
    select e.tournament_id, e.user_id
      from public.tournament_entries e
      join public.tournaments t on t.id = e.tournament_id and t.status = 'open'
      left join public.user_presence p on p.user_id = e.user_id
     where e.out_at is null
       and ( greatest(coalesce(p.seen_at, '-infinity'::timestamptz), e.seen_at) < now() - interval '75 seconds'
             or ( e.away_at is not null
                  and e.away_at < now() - interval '12 seconds'
                  and coalesce(p.seen_at, '-infinity'::timestamptz) < e.away_at
                  and e.seen_at < e.away_at ) )
  )
  delete from public.tournament_entries d
   using gone g
   where d.tournament_id = g.tournament_id and d.user_id = g.user_id;
  get diagnostics v_dropped = row_count;

  -- under three players the countdown has no meaning any more
  update public.tournaments t set locks_at = null
   where t.status = 'open' and t.locks_at is not null
     and (select count(*) from public.tournament_entries e
           where e.tournament_id = t.id and e.out_at is null) < 3;
  return v_dropped;
end $$;
revoke all on function public.cn_tourney_drop_offline() from public, anon, authenticated;

create or replace function public.tournament_going_away()
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is null then return; end if;
  update public.tournament_entries set away_at = now()
   where user_id = auth.uid() and out_at is null
     and tournament_id in (select id from public.tournaments where status = 'open');
end $$;
revoke all on function public.tournament_going_away() from public, anon;
grant execute on function public.tournament_going_away() to authenticated;

-- a fresh heartbeat/tick means they are back: forget the goodbye
create or replace function public.tournament_tick()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := auth.uid(); v_t uuid; r record;
begin
  if v_uid is null then raise exception 'not signed in'; end if;

  update public.tournament_entries set seen_at = now(), away_at = null
   where user_id = v_uid and tournament_id in
     (select id from public.tournaments where status in ('open', 'running'));

  perform public.cn_tourney_drop_offline();

  for r in select id from public.tournaments
            where status = 'open' and locks_at is not null and locks_at <= now() loop
    perform cn_tourney_lock(r.id);
  end loop;
  for r in select id from public.tournaments where status = 'running' loop
    perform cn_tourney_sweep(r.id);
  end loop;

  select t.id into v_t from public.tournaments t
    join public.tournament_entries e on e.tournament_id = t.id
   where e.user_id = v_uid and t.status = 'running' limit 1;
  if v_t is null then v_t := cn_tourney_open(); end if;
  return public.tournament_state(v_t);
end $$;

select cron.schedule('cn-sweep-tournament', '15 seconds', 'select public.cn_tourney_drop_offline()');
