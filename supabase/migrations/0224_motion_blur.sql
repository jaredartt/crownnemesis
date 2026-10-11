-- 0224: Admin Mode -> Look & feel gets a fifth dial, "Motion blur": how much blur
-- things pick up while they move (units sliding and lunging, armies and
-- structures landing, menu tiles flying in, fight-scene entrances, the hover
-- card). A percentage of the standard amount: 0 = off, 100 = standard, 200 =
-- double. Purely cosmetic; nothing on the server reads it. Reduce motion turns
-- it off on that device whatever this says.
alter table public.app_settings
  add column if not exists motion_blur int not null default 100
    constraint app_settings_motion_blur_check check (motion_blur between 0 and 200);
