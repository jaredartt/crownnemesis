-- 0190: avatar frames become flat gradient rings (no glow, no animation, no
-- per-skin thickness -- the client draws one proportional width everywhere),
-- and the ladder view carries each player's equipped frame.
--
-- New frame data: { style: solid|linear|conic|radial|duo, ring, ring2, ring3, angle }

-- 1. the five starters, re-drawn as gradients
update public.skins set data = '{"style":"linear","ring":"#e7b27a","ring2":"#8a5427","ring3":null,"angle":135}'::jsonb where slug = 'frame_bronze';
update public.skins set data = '{"style":"linear","ring":"#f4f6fa","ring2":"#9aa6b6","ring3":"#eef1f5","angle":135}'::jsonb where slug = 'frame_silver';
update public.skins set data = '{"style":"linear","ring":"#ffe58a","ring2":"#d9861f","ring3":"#ffe58a","angle":135}'::jsonb where slug = 'frame_gold';
update public.skins set data = '{"style":"linear","ring":"#ffd23f","ring2":"#ff7a1a","ring3":"#ff2f3d","angle":180}'::jsonb where slug = 'frame_flame';
update public.skins set data = '{"style":"conic","ring":"#2ec5ff","ring2":"#ff4fd8","ring3":"#ffd23f","angle":0}'::jsonb where slug = 'frame_prism';

-- 2. more kinds of gradient
insert into public.skins (slug, kind, name, name_es, unlock_level, data, is_active, sort) values
  ('frame_emerald', 'frame', 'Emerald edge',  'Borde esmeralda',   4, '{"style":"radial","ring":"#9af5c4","ring2":"#0a8f55","ring3":null,"angle":0}', true, 45),
  ('frame_ocean',   'frame', 'Ocean',         'Océano',            7, '{"style":"linear","ring":"#46d1ff","ring2":"#2f4bff","ring3":null,"angle":90}', true, 46),
  ('frame_sunset',  'frame', 'Sunset',        'Atardecer',        13, '{"style":"linear","ring":"#ffb45a","ring2":"#ff4f9a","ring3":"#8a4fff","angle":160}', true, 47),
  ('frame_royal',   'frame', 'Royal split',   'Real bicolor',     19, '{"style":"duo","ring":"#6a3df0","ring2":"#f5c542","ring3":null,"angle":90}', true, 48),
  ('frame_aurora',  'frame', 'Aurora',        'Aurora',           22, '{"style":"conic","ring":"#34e89e","ring2":"#2ec5ff","ring3":"#a259ff","angle":45}', true, 49),
  ('frame_candy',   'frame', 'Candy',         'Caramelo',         28, '{"style":"conic","ring":"#ff8ad1","ring2":"#8ad1ff","ring3":"#fff08a","angle":0}', true, 50),
  ('frame_onyx',    'frame', 'Onyx',          'Ónix',             30, '{"style":"radial","ring":"#6b7280","ring2":"#0b0b12","ring3":"#2a2a36","angle":0}', true, 51)
on conflict (slug) do update set data = excluded.data, name = excluded.name, name_es = excluded.name_es,
  unlock_level = excluded.unlock_level, sort = excluded.sort;

-- 3. the ladder shows frames
create or replace view public.leaderboard as
 select p.id,
    p.username,
    p.avatar,
    p.name_color,
    coalesce(r.rating, 1000) as rating,
    p.wins,
    p.losses,
    p.games,
    p.streak,
    p.tournaments,
    p.country,
    p.equipped_frame
   from public.profiles p
     left join public.player_rating r on r.user_id = p.id
  where not p.is_system;
