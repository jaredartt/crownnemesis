-- 0220: Admin Mode -> Look & feel. Four dials, all percentages of today's look
-- (100 = as it was), read by every client the moment the settings row loads or
-- changes. Nothing on the server uses them; they only shape how the game feels.
--   fight_speed       how fast the fight scenes play (50-200)
--   ui_speed          menu and transition animations: tiles sliding in, the
--                     wipe between menu and match, the action menu (50-200)
--   hp_drain_speed    the HP bar's change animation and the HP number count (50-200)
--   hp_bar_thickness  how thick the HP bar on a token and in a fight scene is (60-160)
-- (The hovered card's size is in the Cards tab, 0214.)
alter table public.app_settings
  add column if not exists fight_speed       int not null default 100 constraint app_settings_fight_speed_check       check (fight_speed between 50 and 200),
  add column if not exists ui_speed          int not null default 100 constraint app_settings_ui_speed_check          check (ui_speed between 50 and 200),
  add column if not exists hp_drain_speed    int not null default 100 constraint app_settings_hp_drain_speed_check    check (hp_drain_speed between 50 and 200),
  add column if not exists hp_bar_thickness  int not null default 100 constraint app_settings_hp_bar_thickness_check  check (hp_bar_thickness between 60 and 160);
