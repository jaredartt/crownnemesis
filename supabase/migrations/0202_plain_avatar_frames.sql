-- Jared: "we still have the profile icons' borders, keep them so they can still
-- choose them, no gradients though, just the plain ones, with the same colors
-- available as the usernames' colors."
--
-- Avatar frames are now ONE plain solid ring per name colour, earned on the
-- level track at the same level as the matching name colour (black 1, blue 2,
-- red 5, green 8, sky 10, orange 12, purple 15, brown 17, pink 20) -- nothing is
-- sold. The twelve gradient frames (all Shop items, all only ever held by
-- 'legacy' grants -- no purchases had been made) and the redundant frame_ink are
-- DEACTIVATED, not deleted: a DELETE on public.skins hung the Supabase
-- connection when this was applied (cause not found), and keeping the rows
-- makes bringing them back a one-line update. Anyone wearing a deactivated
-- frame is unequipped. The ring hexes are the name-colour skins' own colours;
-- for the four built-in colours that come from theme variables
-- (black/blue/red/green) the light-theme value is used, since a frame is one
-- colour in both themes.

update public.skins set is_active = false
 where kind = 'frame' and (data->>'style' <> 'solid' or slug = 'frame_ink');

select set_config('cn.progress_write', '1', true);
update public.profiles set equipped_frame = null
 where equipped_frame in (select slug from public.skins where kind = 'frame' and not is_active);
select set_config('cn.progress_write', '', true);

update public.skins set name = 'Black ring', unlock_level = 1,  sort = 30, price = null, data = '{"style":"solid","ring":"#14141a","ring2":null,"ring3":null,"angle":0}' where slug = 'frame_slate';
update public.skins set name = 'Blue ring',  unlock_level = 2,  sort = 31, price = null, data = '{"style":"solid","ring":"#2f4bff","ring2":null,"ring3":null,"angle":0}' where slug = 'frame_blue';
update public.skins set name = 'Red ring',   unlock_level = 5,  sort = 32, price = null, data = '{"style":"solid","ring":"#d92d20","ring2":null,"ring3":null,"angle":0}' where slug = 'frame_red';
update public.skins set name = 'Green ring', unlock_level = 8,  sort = 33, price = null, data = '{"style":"solid","ring":"#27ae60","ring2":null,"ring3":null,"angle":0}' where slug = 'frame_green';

insert into public.skins (slug, kind, name, unlock_level, data, is_active, sort) values
  ('frame_sky',    'frame', 'Sky Blue ring', 10, '{"style":"solid","ring":"#94d1f0","ring2":null,"ring3":null,"angle":0}', true, 34),
  ('frame_orange', 'frame', 'Orange ring',   12, '{"style":"solid","ring":"#f7b373","ring2":null,"ring3":null,"angle":0}', true, 35),
  ('frame_purple', 'frame', 'Purple ring',   15, '{"style":"solid","ring":"#cc89ec","ring2":null,"ring3":null,"angle":0}', true, 36),
  ('frame_brown',  'frame', 'Brown ring',    17, '{"style":"solid","ring":"#b87d56","ring2":null,"ring3":null,"angle":0}', true, 37),
  ('frame_pink',   'frame', 'Pink ring',     20, '{"style":"solid","ring":"#ff8ad1","ring2":null,"ring3":null,"angle":0}', true, 38);
