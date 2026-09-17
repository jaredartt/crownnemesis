-- 0060: name_color -- the RPC, the CHECK, the ladder view, and both chat
-- rails carrying it the way `username` already does.

\set ON_ERROR_STOP on
\pset pager off

delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('cc000000-0000-0000-0000-0000000000c1','c1@x.com','{"username":"colorone"}'),
  ('cc000000-0000-0000-0000-0000000000c2','c2@x.com','{"username":"colortwo"}');

-- ---- default, and the RPC ------------------------------------------------
do $$
begin
  perform t_ok((select name_color from public.profiles
                 where id = 'cc000000-0000-0000-0000-0000000000c1') = 'blue',
              'a brand-new profile defaults to blue');
end $$;

select set_config('app.uid','cc000000-0000-0000-0000-0000000000c1',false);
select t_ok(public.set_name_color('purple') = 'purple', 'set_name_color accepts purple');
select t_ok((select name_color from public.profiles
              where id = 'cc000000-0000-0000-0000-0000000000c1') = 'purple',
            'and it actually saved');
select t_raises('select public.set_name_color(''teal'')', 'not one of the nine name colors',
                'a color outside the nine is refused, by the RPC');
select t_raises('update public.profiles set name_color = ''teal''
                  where id = ''cc000000-0000-0000-0000-0000000000c1''',
                'profiles_name_color_check',
                'and by the CHECK constraint too, on a direct write');

-- ---- the ladder view ------------------------------------------------------
update public.profiles set games = 1
 where id in ('cc000000-0000-0000-0000-0000000000c1', 'cc000000-0000-0000-0000-0000000000c2');
do $$
begin
  perform t_ok((select name_color from public.leaderboard
                 where id = 'cc000000-0000-0000-0000-0000000000c1') = 'purple',
              'the leaderboard view carries name_color too');
end $$;

-- ---- chat: match_messages, inserted directly the way Chat.tsx does -------
select public.set_deck(array['dereo','dorme','lium','sinie','fey']);
select set_config('app.uid','cc000000-0000-0000-0000-0000000000c2',false);
select public.set_deck(array['dereo','ashvar','velmor','nyxara','sarrave']);
select t_match('cc000000-0000-0000-0000-0000000000c1',
               'cc000000-0000-0000-0000-0000000000c2') as m \gset
select set_config('app.uid','cc000000-0000-0000-0000-0000000000c1',false);
insert into public.match_messages (match_id, user_id, username, name_color, body)
values (:'m', 'cc000000-0000-0000-0000-0000000000c1', 'colorone', 'purple', 'hi');
do $$
begin
  perform t_ok((select name_color from public.match_messages
                 where body = 'hi') = 'purple',
              'match_messages carries whatever color the client sends');
end $$;
select t_raises(
  format('insert into public.match_messages (match_id, user_id, username, name_color, body)
          values (%L, %L, ''colorone'', ''teal'', ''bad'')', :'m', 'cc000000-0000-0000-0000-0000000000c1'),
  'match_messages_name_color_check',
  'and refuses a color outside the nine, same as profiles');

-- ---- chat: royale_messages, via send_royale_message ----------------------
select (create_royale_match()).id as rid \gset
select send_royale_message(:'rid', 'yo');
do $$
begin
  perform t_ok((select name_color from public.royale_messages
                 where body = 'yo') = 'purple',
              'send_royale_message looks up the sender''s own name_color');
end $$;
