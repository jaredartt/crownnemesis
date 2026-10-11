-- 0214: how big the hovered / pinned card is on desktop, controlled from the
-- admin Cards tab ("Hover card size"). Two numbers on the app_settings
-- singleton: the card's width as a percentage of the window height, and the
-- widest it may ever get in px. Read by BigCard.tsx, live through the same
-- realtime channel as every other setting. Plain add-column statements: the
-- admin write policy ("super admin writes app settings") already covers them.
alter table public.app_settings add column if not exists hover_card_vh integer not null default 36 check (hover_card_vh between 15 and 70);
alter table public.app_settings add column if not exists hover_card_max integer not null default 390 check (hover_card_max between 150 and 800);
