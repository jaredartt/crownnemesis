-- Local-only: proves a room disappears exactly when no player is left in it,
-- and -- more importantly -- that it does NOT disappear while one still is.
\set ON_ERROR_STOP on

delete from public.matches;
delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('11111111-1111-1111-1111-111111111111', 'alice@x.com', '{"username":"alice"}'),
  ('22222222-2222-2222-2222-222222222222', 'bob@x.com',   '{"username":"bob"}'),
  ('33333333-3333-3333-3333-333333333333', 'carol@x.com', '{"username":"carol"}');

-- alice opens a room
select set_config('app.uid', '11111111-1111-1111-1111-111111111111', false);
select id as mid from public.create_match() \gset

select t_ok((select count(*) from public.match_presence where match_id=:'mid') = 1,
            'hosting records you as present');
select t_ok(public.sweep_matches() = 0, 'a room you are sitting in is not swept');
select t_ok((select count(*) from public.matches where id=:'mid') = 1, 'the room survived');

-- a spectator wandering in must not hold the room open
select set_config('app.uid', '33333333-3333-3333-3333-333333333333', false);
select public.touch_match(:'mid');
select t_ok((select count(*) from public.match_presence where match_id=:'mid') = 1,
            'a spectator is not counted as present');

-- ...so once alice goes quiet, the room goes, spectator or not
update public.match_presence set seen_at = now() - interval '90 seconds' where match_id = :'mid';
select t_ok(public.sweep_matches() = 1, 'a room nobody is playing in is swept');
select t_ok((select count(*) from public.matches where id=:'mid') = 0, 'and it is really gone');

-- a full match: it must survive one player leaving, and die on the second
select set_config('app.uid', '11111111-1111-1111-1111-111111111111', false);
select id as m2 from public.create_match() \gset
select code as c2 from public.matches where id = :'m2' \gset
select set_config('app.uid', '22222222-2222-2222-2222-222222222222', false);
select public.join_match(:'c2');
select t_ok((select count(*) from public.match_presence where match_id=:'m2') = 2,
            'both players are present once joined');

select public.leave_match(:'m2');            -- bob walks out
select t_ok((select count(*) from public.matches where id=:'m2') = 1,
            'the room survives while the other player is still in it');
select t_ok((select count(*) from public.match_presence where match_id=:'m2') = 1,
            'and only the leaver was removed');

select set_config('app.uid', '11111111-1111-1111-1111-111111111111', false);
select public.leave_match(:'m2');            -- alice walks out too
select t_ok((select count(*) from public.matches where id=:'m2') = 0,
            'the last player leaving removes the room immediately');

-- chat must not outlive the room it belonged to
select t_ok((select count(*) from public.match_messages where match_id=:'m2') = 0,
            'its chat went with it');

-- and a live match must never be swept
select id as m3 from public.create_match() \gset
select t_ok(public.sweep_matches() = 0, 'sweeping a fresh room is a no-op');
select t_ok((select count(*) from public.matches where id=:'m3') = 1, 'the fresh room stands');

-- 0145: Jared -- "Check again why I can't watch friends (or random real
-- players) that are having matches inside Watch section, please!" --
-- sweep_matches() used to delete ANY match (waiting, deploying, active,
-- even finished) the instant presence went stale on both sides, with no
-- regard for whether a real game was actually underway. A phone locking
-- or a backgrounded tab is enough to go quiet for 45+ seconds without a
-- match being remotely abandoned -- and the Watch page calls
-- sweep_matches() every 4 seconds just by being open, so checking Watch
-- for a friend's match could delete it out from under them. A match
-- that has actually started must survive a sweep no matter how stale
-- both players' presence gets -- that quiet is what advance_turn's own
-- idle/forfeit counter is for, and it preserves history through
-- finish_match(); sweep now only ever clears a room nobody has started
-- playing in yet.
select set_config('app.uid', '11111111-1111-1111-1111-111111111111', false);
select id as m4 from public.create_match() \gset
select code as c4 from public.matches where id = :'m4' \gset
select set_config('app.uid', '22222222-2222-2222-2222-222222222222', false);
select public.join_match(:'c4');
update public.matches set status = 'active' where id = :'m4';
update public.match_presence set seen_at = now() - interval '90 seconds' where match_id = :'m4';
select t_ok(public.sweep_matches() = 0,
            'an active match survives a sweep even with stale presence on both sides');
select t_ok((select count(*) from public.matches where id=:'m4') = 1, 'it is really still there');

\echo '--- presence assertions passed ---'
