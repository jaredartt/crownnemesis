-- 0223: card value. A card's "value" is a number worked out from its stats with the
-- price list below, shown next to the card in Admin Mode -> Cards, and tuned in
-- Admin Mode -> Card value. Nothing on the server uses it: it is a design aid, so
-- there is no function here, only the dials on the app_settings row.
--   value = hp * vp_per_hp + attack * vp_per_attack + range * vp_per_range
--         + move * vp_per_move + vp_class_<class>
-- vp_min / vp_max: the band a card is meant to land in. Outside it the number shows
-- red; within vp_warn of either edge (but inside) yellow; otherwise green.
alter table public.app_settings
  add column if not exists vp_per_hp      numeric(8,2) not null default 1   constraint app_settings_vp_per_hp_check      check (vp_per_hp      between 0 and 10000),
  add column if not exists vp_per_attack  numeric(8,2) not null default 10  constraint app_settings_vp_per_attack_check  check (vp_per_attack  between 0 and 10000),
  add column if not exists vp_per_range   numeric(8,2) not null default 30  constraint app_settings_vp_per_range_check   check (vp_per_range   between 0 and 10000),
  add column if not exists vp_per_move    numeric(8,2) not null default 20  constraint app_settings_vp_per_move_check    check (vp_per_move    between 0 and 10000),
  add column if not exists vp_class_royal  numeric(8,2) not null default 0  constraint app_settings_vp_class_royal_check  check (vp_class_royal  between -10000 and 10000),
  add column if not exists vp_class_rogue  numeric(8,2) not null default 0  constraint app_settings_vp_class_rogue_check  check (vp_class_rogue  between -10000 and 10000),
  add column if not exists vp_class_knight numeric(8,2) not null default 0  constraint app_settings_vp_class_knight_check check (vp_class_knight between -10000 and 10000),
  add column if not exists vp_class_mage   numeric(8,2) not null default 0  constraint app_settings_vp_class_mage_check   check (vp_class_mage   between -10000 and 10000),
  add column if not exists vp_class_flying numeric(8,2) not null default 0  constraint app_settings_vp_class_flying_check check (vp_class_flying between -10000 and 10000),
  add column if not exists vp_min  int not null default 250 constraint app_settings_vp_min_check  check (vp_min  between -100000 and 100000),
  add column if not exists vp_max  int not null default 500 constraint app_settings_vp_max_check  check (vp_max  between -100000 and 100000),
  add column if not exists vp_warn int not null default 25  constraint app_settings_vp_warn_check check (vp_warn between 0 and 100000);
