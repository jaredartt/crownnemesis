-- The bot opponent and the ranked queue.
\set ON_ERROR_STOP on
\pset pager off

delete from public.match_results;
delete from public.matches;
delete from public.ranked_queue;
delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('f0000000-0000-0000-0000-000000000001', 'f@x.com', '{"username":"fay"}'),
  ('f0000000-0000-0000-0000-000000000002', 'g@x.com', '{"username":"gus"}'),
  ('f0000000-0000-0000-0000-000000000003', 'h@x.com', '{"username":"hal"}');

-- ---- a bot match ---------------------------------------------------------
select set_config('app.uid', 'f0000000-0000-0000-0000-000000000001', false);
select id as bm from public.create_bot_match(2) \gset

select t_ok((select bot from public.matches where id=:'bm') = 2, 'the difficulty is on the match');
select t_ok((select ranked from public.matches where id=:'bm') = false, 'a bot match is never ranked');
select t_ok((select guest_id is null from public.matches where id=:'bm'),
            'the bot has no account, so the guest seat belongs to nobody');
select t_ok((select guest_name from public.matches where id=:'bm') = 'SHARP', 'it is named after its level');
select t_ok((select status from public.matches where id=:'bm') = 'deploying', 'you still get to deploy');
select t_ok((select (state->'ready'->>'guest')::boolean from public.matches where id=:'bm'),
            'and it is ready before you start');
select t_ok((select jsonb_array_length(state->'units') from public.matches where id=:'bm') = 0,
            'no army is in the readable row while you deploy');
select t_ok(t_dcount(:'bm','host') = 5 and t_dcount(:'bm','guest') = 5,
            'both armies exist privately, the bot''s included');
select t_ok((select user_id is null from public.match_deploy
              where match_id=:'bm' and side='guest'),
            'the bot''s row belongs to nobody, so it is invisible to everyone');

-- nobody can walk into the bot's seat -- but 0144: there is no reason they
-- should not be able to watch. Jared: "I cant watch my friend playing a
-- ranked match against a bot!! I want to!" -- join_match() used to throw
-- 'already full' for anyone who was not already host or guest the instant
-- the room left 'waiting', bot match or not, which was never actually a
-- working spectator path despite Lobby.tsx's own comment claiming a bot
-- room's "code still works, so a friend you hand it to can walk in and
-- watch". Now it hands back the row, untouched, instead.
select set_config('app.uid', 'f0000000-0000-0000-0000-000000000002', false);
select code as bc from public.matches where id = :'bm' \gset
select t_ok((public.join_match(:'bc')).guest_id is null,
            'walking in on a bot room does not seat you in it');
select t_ok((select status from public.matches where id=:'bm') = 'deploying',
            'joining-to-watch does not touch the room itself');
select t_raises(format('select public.submit_move(%L,''g1'',1,1)', :'bm'),
                'not running', 'an outsider still cannot play its units');

-- ---- it plays -----------------------------------------------------------
select set_config('app.uid', 'f0000000-0000-0000-0000-000000000001', false);
select public.set_ready(:'bm');
select t_ok((select status from public.matches where id=:'bm') = 'active', 'your Ready starts it alone');
select t_ok((select state->>'turn' from public.matches where id=:'bm') = 'host', 'you move first');

select public.bot_step(:'bm');
select t_ok((select state->>'turn' from public.matches where id=:'bm') = 'host',
            'the bot will not act on your turn');

select public.end_turn(:'bm');
select t_ok((select state->>'turn' from public.matches where id=:'bm') = 'guest', 'now it is the bot''s');

-- step it until the turn comes back; it must not loop forever
do $$
declare i int := 0; mid uuid := (select id from public.matches where bot is not null
                                  order by created_at desc limit 1);
begin
  while (select state->>'turn' from public.matches where id = mid) = 'guest' and i < 40 loop
    perform public.bot_step(mid);
    i := i + 1;
  end loop;
  if i >= 40 then raise exception 'FAIL  the bot never finished its turn'; end if;
  raise notice 'PASS  the bot finishes its turn in % steps', i;
end $$;

select t_ok((select count(*) > 0 from public.matches m, jsonb_array_elements(m.state->'units') u
              where m.id=:'bm' and u->>'owner'='guest'
                and ((u->>'x')::int <> 1 or (u->>'y')::int <> 0)),
            'and it actually moved something');
select t_ok((select count(*) = 0 from public.matches m,
                  jsonb_array_elements(m.state->'units') u,
                  jsonb_array_elements(m.state->'obstacles') o
              where m.id=:'bm' and u->>'x'=o->>'x' and u->>'y'=o->>'y'),
            'it cannot stand in a tree -- it moves through the same function you do');

-- play a whole game out; nothing may hang and nobody may cheat
do $$
declare i int := 0; mid uuid := (select id from public.matches where bot is not null
                                  order by created_at desc limit 1);
declare st text;
begin
  perform set_config('app.uid', 'f0000000-0000-0000-0000-000000000001', false);
  loop
    select status into st from public.matches where id = mid;
    exit when st <> 'active' or i > 400;
    if (select state->>'turn' from public.matches where id = mid) = 'guest' then
      perform public.bot_step(mid);
    else
      perform public.end_turn(mid);   -- the human does nothing at all
    end if;
    i := i + 1;
  end loop;
  raise notice 'PASS  a full bot game runs to completion (% steps, %)', i, st;
end $$;
select t_ok((select status from public.matches where id=:'bm') = 'finished',
            'a player who never acts loses to the bot');
select t_ok((select count(*) from public.match_results) = 0,
            'and none of it touched anybody''s rating');

-- ---- casual is off the record -------------------------------------------
select set_config('app.uid', 'f0000000-0000-0000-0000-000000000001', false);
select id as cm from public.create_match() \gset
select code as cc from public.matches where id = :'cm' \gset
select set_config('app.uid', 'f0000000-0000-0000-0000-000000000002', false);
select public.join_match(:'cc');
select t_ok((select ranked from public.matches where id=:'cm') = false,
            'a room you host is not ranked');
select public.resign_match(:'cm');
select t_ok((select count(*) from public.match_results) = 0, 'and resigning it costs nothing');
select t_ok((select lp from public.profiles where id='f0000000-0000-0000-0000-000000000001') = 0,
            'no LP changed hands');

-- ---- the queue -----------------------------------------------------------
select set_config('app.uid', 'f0000000-0000-0000-0000-000000000001', false);
select (public.ranked_tick()->>'match') is null as q1 \gset
select t_ok(:'q1'::boolean, 'one player alone is not paired with anybody');
select t_ok((select active from public.ranked_queue
              where user_id='f0000000-0000-0000-0000-000000000001'), 'and is waiting');

select set_config('app.uid', 'f0000000-0000-0000-0000-000000000002', false);
select public.ranked_tick()->>'match' as rm \gset
select t_ok(:'rm' is not null, 'the second player is paired at once');
select t_ok((select ranked from public.matches where id=:'rm'::uuid), 'the match is ranked');
select t_ok((select status from public.matches where id=:'rm'::uuid) = 'deploying',
            'and starts at deployment like any other');
select t_ok((select count(*) = 0 from public.ranked_queue where active),
            'both are taken out of the queue');

-- the other player finds the same match through their own tick
select set_config('app.uid', 'f0000000-0000-0000-0000-000000000001', false);
select public.ranked_tick()->>'match' as rm2 \gset
select t_ok(:'rm2' = :'rm', 'the other side finds it without an invitation');

-- ---- it pairs by strength -----------------------------------------------
update public.matches set status = 'finished' where id = :'rm'::uuid;
insert into public.player_rating (user_id, mmr) values
  ('f0000000-0000-0000-0000-000000000001', 1000),
  ('f0000000-0000-0000-0000-000000000003', 2000)
on conflict (user_id) do update set mmr = excluded.mmr;
update public.ranked_queue set active = false;

select set_config('app.uid', 'f0000000-0000-0000-0000-000000000003', false);
select public.ranked_tick();                      -- hal, 2000, waiting
select set_config('app.uid', 'f0000000-0000-0000-0000-000000000001', false);
select (public.ranked_tick()->>'match') is null as far \gset
select t_ok(:'far'::boolean, 'a thousand points apart is too far to pair immediately');

-- after a long enough wait the window swallows the gap
update public.ranked_queue set joined_at = now() - interval '60 seconds';
select public.ranked_tick()->>'match' as wide \gset
select t_ok(:'wide' is not null, 'and close enough once they have both waited a minute');

-- ---- leaving -------------------------------------------------------------
update public.matches set status = 'finished';
update public.ranked_queue set active = false;
select set_config('app.uid', 'f0000000-0000-0000-0000-000000000002', false);
select public.ranked_tick();
select public.leave_ranked();
select t_ok((select not active from public.ranked_queue
              where user_id='f0000000-0000-0000-0000-000000000002'), 'leaving takes you out');
select set_config('app.uid', 'f0000000-0000-0000-0000-000000000003', false);
select (public.ranked_tick()->>'match') is null as gone \gset
select t_ok(:'gone'::boolean, 'and nobody is paired with someone who left');

-- a stale tab is not in the queue either
select set_config('app.uid', 'f0000000-0000-0000-0000-000000000002', false);
select public.ranked_tick();
update public.ranked_queue set seen_at = now() - interval '2 minutes'
 where user_id = 'f0000000-0000-0000-0000-000000000002';
select set_config('app.uid', 'f0000000-0000-0000-0000-000000000003', false);
select (public.ranked_tick()->>'match') is null as stale \gset
select t_ok(:'stale'::boolean, 'nor with a tab that stopped calling in');

-- ---- a rematch is never ranked ------------------------------------------
select t_ok((select count(*) from public.matches where ranked and status <> 'finished') = 0,
            'no ranked match is left running');

\echo '--- bot and ranked: all assertions passed ---'

-- ---- a rematch is an invitation ------------------------------------------
select set_config('app.uid', 'f0000000-0000-0000-0000-000000000001', false);
select t_match('f0000000-0000-0000-0000-000000000001',
               'f0000000-0000-0000-0000-000000000002') as rr \gset
select public.resign_match(:'rr');

select public.request_rematch(:'rr') is null as asked1 \gset
select t_ok(:'asked1'::boolean, 'one player asking does not start anything');
select t_ok((select rematch_host from public.matches where id=:'rr'), 'the ask is on the row');

select set_config('app.uid', 'f0000000-0000-0000-0000-000000000002', false);
select public.decline_rematch(:'rr');
select t_ok((select not rematch_host and not rematch_guest and rematch_declined
               from public.matches where id=:'rr'),
            'declining clears both asks and says why');
select t_ok((select next_match_id is null from public.matches where id=:'rr'),
            'and nothing was created');

-- asking again wipes the note, and the other side accepting starts it
select set_config('app.uid', 'f0000000-0000-0000-0000-000000000002', false);
select public.request_rematch(:'rr');
select t_ok((select not rematch_declined from public.matches where id=:'rr'),
            'a fresh invitation clears the old refusal');
select set_config('app.uid', 'f0000000-0000-0000-0000-000000000001', false);
select public.request_rematch(:'rr') as rr2 \gset
select t_ok(:'rr2' is not null, 'accepting creates the new room');
select t_ok((select ranked = false and status = 'deploying'
               from public.matches where id=:'rr2'::uuid),
            'unranked, and back at deployment');
select t_ok((select count(*) = 2 from public.match_deploy where match_id = :'rr2'::uuid),
            'with both armies placed privately again');
select t_ok((select host_name from public.matches where id=:'rr2'::uuid) = 'gus',
            'and the sides swapped');

select set_config('app.uid', 'f0000000-0000-0000-0000-000000000003', false);
select t_raises(format('select public.decline_rematch(%L)', :'rr'),
                'spectating', 'a spectator cannot answer for anybody');

-- ---------------------------------------------------------------------------
-- the coin that decides who opens
-- ---------------------------------------------------------------------------
do $$
declare v_uid uuid := '77770000-0000-0000-0000-0000000000c1';
        mid uuid; n int := 0; i int; v_turn text;
begin
  -- Unpin the database default for this session only, so we measure the real
  -- thing rather than the harness.
  perform set_config('cn.first_side', '', true);
  delete from auth.users where id = v_uid;
  insert into auth.users (id, email, raw_user_meta_data)
  values (v_uid, 'coin@x.com', '{"username":"coiner"}');
  perform set_config('app.uid', v_uid::text, false);

  for i in 1..300 loop
    select id into mid from public.create_bot_match(1);
    perform public.set_ready(mid);
    select state->>'turn' into v_turn from public.matches where id = mid;
    if v_turn = 'guest' then n := n + 1; end if;
    delete from public.matches where id = mid;
  end loop;

  -- 300 flips: outside 110..190 is a one-in-a-million coincidence, so it is a
  -- rigged coin instead.
  perform t_ok(n between 110 and 190,
    format('the first move is a fair coin in practice too (%s/300 went to the bot)', n));
end $$;
