-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice. No DELETE, so no "Potential issue detected" dialog.
--  Run 0041 first. The last statement prints a row of checks; every column
--  must say true.
-- ===========================================================================
--  0042 - the menu grid, made of rows instead of a constant
--
--  TILES in Lobby.tsx has been a literal array since the menu existed -- eight
--  destinations, their colours and their pictures, written where only a
--  deploy could change them. This does not replace that array; it cannot,
--  because the colour, the picture and the focus point are presentation and
--  belong in the client same as ever. It adds one thing the array could not
--  give an admin: whether a tile is SHOWN, and in what ORDER, changeable from
--  the Menu tab and felt by every signed-in player within a websocket's worth
--  of latency, no deploy required.
--
--  The id column is the same string TILES already keys its tiles by --
--  'ranked', 'bot', 'friends', and so on -- so the client's job is simply to
--  look each tile up by id and skip or reorder the ones this table says to.
--  A row for an id the client has never heard of is harmless: nothing in
--  TILES matches it, so it is skipped, and a future tile the client does not
--  know about yet does not need a migration to be hidden by default --  a
--  missing row and a row that says visible=false come out the same way.
--
--  'admin' is deliberately not seeded here. It stopped being a lobby tile in
--  the same change that added this table -- Admin Mode now opens from the
--  bottom of Settings -- so there is no tile for this table to ever hide or
--  show.
-- ===========================================================================

create table if not exists public.menu_sections (
  id         text primary key,
  visible    boolean not null default true,
  sort       int not null default 0,
  updated_at timestamptz not null default now()
);

insert into public.menu_sections (id, sort) values
  ('ranked', 0), ('bot', 1), ('friends', 2), ('spectate', 3),
  ('ladder', 4), ('team', 5), ('tournament', 6), ('comics', 7)
on conflict (id) do nothing;

alter table public.menu_sections enable row level security;

drop policy if exists "menu sections readable by authenticated" on public.menu_sections;
create policy "menu sections readable by authenticated"
  on public.menu_sections for select to authenticated using (true);

drop policy if exists "super admin writes menu sections" on public.menu_sections;
create policy "super admin writes menu sections"
  on public.menu_sections for all to authenticated
  using (public.cn_is_super_admin())
  with check (public.cn_is_super_admin());

create or replace function public.cn_touch_menu_section()
returns trigger language plpgsql as $$
begin
  new.id := lower(btrim(coalesce(new.id, '')));
  if new.id = '' then raise exception 'a menu section needs an id'; end if;
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists menu_sections_touch on public.menu_sections;
create trigger menu_sections_touch
  before insert or update on public.menu_sections
  for each row execute function public.cn_touch_menu_section();

do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname='supabase_realtime' and schemaname='public' and tablename='menu_sections') then
    alter publication supabase_realtime add table public.menu_sections;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Did it work? All true means yes.
-- ---------------------------------------------------------------------------
select
  to_regclass('public.menu_sections') is not null                 as menu_sections_exists,
  (select count(*) from public.menu_sections) >= 8                 as every_tile_has_a_row,
  (select count(*) from public.menu_sections where id = 'admin') = 0
                                                                  as admin_is_not_a_tile,
  (select count(*) from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='menu_sections') = 1
                                                                  as menu_sections_are_realtime;
