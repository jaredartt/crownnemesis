-- 0216: the announcement banner. One message, edited in Admin Mode -> Banner,
-- shown at the top of the menu to every signed-in player. Written in English and
-- Spanish. Every publish bumps announcement_id, which is what makes a banner that
-- somebody dismissed (remembered per id, in their browser) show again.
alter table public.app_settings
  add column if not exists announcement_enabled     boolean not null default false,
  add column if not exists announcement_text        text    not null default '' constraint app_settings_announcement_text_check    check (char_length(announcement_text) <= 280),
  add column if not exists announcement_text_es     text    not null default '' constraint app_settings_announcement_text_es_check check (char_length(announcement_text_es) <= 280),
  add column if not exists announcement_kind        text    not null default 'info' constraint app_settings_announcement_kind_check check (announcement_kind in ('info','update','warning','event')),
  add column if not exists announcement_dismissible  boolean not null default true,
  add column if not exists announcement_id          integer not null default 0;
