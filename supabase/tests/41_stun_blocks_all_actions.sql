-- 0151: stun used to only block attacking and using an ability -- cn_move
-- and cn_defend never checked it at all, so a stunned unit could still
-- sidestep or raise a guard. Jared: "stun shouldn't allow you to defend,
-- move, or literally anything else."
\set ON_ERROR_STOP on

delete from public.match_results; delete from public.matches; delete from auth.users;
insert into auth.users (id, email, raw_user_meta_data) values
  ('ff000000-0000-0000-0000-000000000001','f1@x.com','{"username":"fone"}'),
  ('ff000000-0000-0000-0000-000000000002','f2@x.com','{"username":"ftwo"}');

select set_config('app.uid','ff000000-0000-0000-0000-000000000001',false);
select public.set_deck(array['dereo','wuzu','mako','dione-grifo','himanta']);
select set_config('app.uid','ff000000-0000-0000-0000-000000000002',false);
select public.set_deck(array['stelaris','eva','umiro','lumea','dorme']);
select t_match('ff000000-0000-0000-0000-000000000001',
               'ff000000-0000-0000-0000-000000000002') as m \gset

select set_config('app.uid','ff000000-0000-0000-0000-000000000001',false);
select t_trees(:'m','[]'::jsonb);
update public.matches set status = 'active', state = jsonb_set(state, '{turn}', '"host"') where id = :'m';
select t_reset(:'m');

select t_stun(:'m', 'h2');

select t_raises(format('select public.cn_move(%L, %L, %L, %s, %s)', :'m', 'host', 'h2', 0, 0),
                'stunned', 'a stunned unit cannot move');
select t_raises(format('select public.cn_defend(%L, %L, %L)', :'m', 'host', 'h2'),
                'stunned', 'a stunned unit cannot defend itself');
select t_raises(format('select public.cn_defend(%L, %L, %L, %L)', :'m', 'host', 'h2', 'h3'),
                'stunned', 'a stunned unit cannot defend an ally either');
select t_raises(format('select public.cn_attack(%L, %L, %L, %L)', :'m', 'host', 'h2', 'g2'),
                'stunned', 'still cannot attack (unchanged, just re-checked here)');

-- and a healthy unit is untouched by any of this
select public.cn_move(:'m', 'host', 'h3', (t_get(:'m','h3','x')::int + 1), t_get(:'m','h3','y')::int);
select t_ok(t_get(:'m','h3','moved') = 'true', 'a healthy unit still moves normally');

\echo '--- stun blocks all actions: all assertions passed ---'
