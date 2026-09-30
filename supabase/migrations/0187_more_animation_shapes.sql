-- 0187: ten more animation shapes (the "big" ones) + a ready-made starter row
-- for each, so they can be attached in Admin -> Cards (sentence Animation pill)
-- and tuned in Admin -> Animations immediately. Renderer: AnimationFx.tsx.

alter table public.animations drop constraint if exists animations_shape_check;
alter table public.animations add constraint animations_shape_check
  check (shape in (
    'round_burst', 'diamond_burst', 'ring_pulse', 'arc_sweep', 'beam_line', 'pulse_only',
    'shockwave', 'lightning', 'claw_slash', 'meteor', 'starburst',
    'light_pillar', 'implode', 'whirlwind', 'rising_sparks', 'ground_crack'
  ));

insert into public.animations
  (slug, name, description, shape, color, duration_ms, particle_count, spread_deg, radius_px, scale_start, scale_end, opacity_start, opacity_end, play_at, sort)
values
  ('starter_shockwave',     'Shockwave (starter)',        'Three rings race outward from a hard flash.',                   'shockwave',     '#f5a524',  800,  0, 360,  80, 0.05, 1.0, 1, 0, 'TARGET', 5),
  ('starter_lightning',     'Lightning strike (starter)', 'A jagged bolt from above, flickering, with sparks on impact.', 'lightning',     '#8fd0ff',  700, 10, 360, 110, 0.4,  1.6, 1, 0, 'TARGET', 6),
  ('starter_claw_slash',    'Claw slash (starter)',       'Three tapered slashes drawn across the tile.',                  'claw_slash',    '#ff3b3b',  600,  3, 360,  70, 0.8,  1.0, 1, 0, 'TARGET', 7),
  ('starter_meteor',        'Meteor (starter)',           'A fireball falls in, then explodes in debris and a ring.',      'meteor',        '#ff7a1a', 1000, 12, 360, 110, 0.7,  1.3, 1, 0, 'TARGET', 8),
  ('starter_starburst',     'Starburst (starter)',        'Rays flare out from the centre and twist as they fade.',        'starburst',     '#ffe066',  700, 14, 360,  60, 0.5,  1.0, 1, 0, 'CASTER', 9),
  ('starter_light_pillar',  'Light pillar (starter)',     'A column of light punches up with motes rising inside it.',     'light_pillar',  '#ffe9a8', 1100,  9, 360, 120, 0.4,  1.0, 1, 0, 'TARGET', 10),
  ('starter_implode',       'Implode (starter)',          'Sparks are sucked into the centre, then pop.',                  'implode',       '#a259ff',  900, 14, 360,  60, 0.2,  1.0, 1, 0, 'TARGET', 11),
  ('starter_whirlwind',     'Whirlwind (starter)',        'Motes spiral round inside two swirling arcs.',                  'whirlwind',     '#7fe3d0', 1000, 12, 360,  60, 0.5,  1.2, 1, 0, 'CASTER', 12),
  ('starter_rising_sparks', 'Rising sparks (starter)',    'Embers drift upward from the tile -- a gentle buff or fire.',   'rising_sparks', '#ffb347', 1100, 16, 360, 100, 0.8,  0.4, 1, 0, 'TARGET', 13),
  ('starter_ground_crack',  'Ground crack (starter)',     'Glowing fissures split the tile and rubble hops off them.',     'ground_crack',  '#ff8a1f',  900,  8, 360,  60, 0.8,  1.0, 1, 0, 'TARGET', 14)
on conflict (slug) do nothing;
