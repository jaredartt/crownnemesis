-- 0188: levels, XP and skins.
--
-- Jared: "earn XP by playing matches (I get to choose them in the admin
-- panel) and earn new skins ... make the name colors a skin they can obtain
-- with levels." Everything a rule or a reward, is DATA the admin edits:
--
--   xp_rules      XP per (mode, result). Modes: ranked, friendly, tournament,
--                 bot_calm/sharp/ruthless (unranked vs a bot), royale (vs at
--                 least one other human), royale_bots (a Royale against bots
--                 only). Results: win, loss, draw, plus second for Royale.
--   xp_settings   one row: master switch + min_turns (a match shorter than
--                 this awards nothing -- stops win-trading by instant forfeit).
--   xp_levels     the level track: level -> total XP needed.
--   skins         the catalog: kind 'unit' (how your pieces look on the board),
--                 'frame' (a ring round your avatar) or 'name_color'. `data` is
--                 the kind's template (rim/glow/sheen, ring/anim, colour/gradient)
--                 and `unlock_level` says which level earns it (null = admin
--                 grant only).
--   user_skins    skins granted outside the level track (legacy name colours,
--                 admin gifts).
--   xp_events     one row per award: audit trail, the "+XP" line on the result
--                 dialog, and the idempotency key (user_id, ref).
--
-- XP is awarded by AFTER UPDATE triggers on matches / royale_matches the moment
-- status becomes 'finished' -- every way a match can end (win, timeout, AFK,
-- forfeit, tournament) passes through that one edge, so no finish path can be
-- forgotten. profiles.xp and the equipped skins are guarded by a BEFORE UPDATE
-- trigger: a client cannot write xp, nor equip a skin it has not unlocked.

-- ---------------------------------------------------------------- profiles
alter table public.profiles
  add column if not exists xp integer not null default 0 check (xp >= 0),
  add column if not exists equipped_unit_skin text,
  add column if not exists equipped_frame text;

-- The nine fixed colours are just the first nine skins now.
alter table public.profiles       drop constraint if exists profiles_name_color_check;
alter table public.match_messages drop constraint if exists match_messages_name_color_check;
alter table public.royale_messages drop constraint if exists royale_messages_name_color_check;

-- ------------------------------------------------------------------ tables
create table public.xp_rules (
  mode   text not null,
  result text not null check (result in ('win', 'loss', 'draw', 'second')),
  xp     integer not null default 0 check (xp between 0 and 100000),
  label  text not null default '',
  sort   integer not null default 99,
  primary key (mode, result)
);

create table public.xp_settings (
  id        integer primary key default 1 check (id = 1),
  enabled   boolean not null default true,
  min_turns integer not null default 3 check (min_turns >= 0)
);
insert into public.xp_settings (id) values (1);

create table public.xp_levels (
  level    integer primary key check (level >= 1),
  xp_total integer not null check (xp_total >= 0)
);

create table public.skins (
  id           uuid primary key default gen_random_uuid(),
  slug         text not null unique check (slug ~ '^[a-z0-9_]{2,40}$'),
  kind         text not null check (kind in ('unit', 'frame', 'name_color')),
  name         text not null default '',
  name_es      text,
  description  text,
  description_es text,
  unlock_level integer check (unlock_level >= 1),
  data         jsonb not null default '{}'::jsonb check (jsonb_typeof(data) = 'object'),
  is_active    boolean not null default true,
  sort         integer not null default 99,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table public.user_skins (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  skin_id    uuid not null references public.skins(id) on delete cascade,
  source     text not null default 'admin',
  granted_at timestamptz not null default now(),
  primary key (user_id, skin_id)
);

create table public.xp_events (
  id           bigint generated always as identity primary key,
  user_id      uuid not null references public.profiles(id) on delete cascade,
  ref          text not null,
  mode         text not null,
  result       text not null,
  xp           integer not null,
  level_before integer not null,
  level_after  integer not null,
  created_at   timestamptz not null default now(),
  unique (user_id, ref)
);
create index xp_events_user_idx on public.xp_events (user_id, created_at desc);

create or replace function public.cn_touch_skins() returns trigger
language plpgsql set search_path to 'public' as $$
begin
  new.updated_at := now();
  if tg_op = 'UPDATE' and new.slug is distinct from old.slug then
    raise exception 'a skin''s slug cannot change (players have it equipped)';
  end if;
  if tg_op = 'UPDATE' and new.kind is distinct from old.kind then
    raise exception 'a skin''s kind cannot change';
  end if;
  return new;
end $$;
create trigger skins_touch before insert or update on public.skins
  for each row execute function public.cn_touch_skins();

-- ---------------------------------------------------------------------- RLS
alter table public.xp_rules    enable row level security;
alter table public.xp_settings enable row level security;
alter table public.xp_levels   enable row level security;
alter table public.skins       enable row level security;
alter table public.user_skins  enable row level security;
alter table public.xp_events   enable row level security;

create policy "xp_rules readable"    on public.xp_rules    for select to authenticated using (true);
create policy "xp_settings readable" on public.xp_settings for select to authenticated using (true);
create policy "xp_levels readable"   on public.xp_levels   for select to authenticated using (true);
create policy "skins readable"       on public.skins       for select to authenticated using (true);
create policy "own skins readable"   on public.user_skins  for select to authenticated
  using (user_id = auth.uid() or public.cn_is_super_admin());
create policy "own xp events readable" on public.xp_events for select to authenticated
  using (user_id = auth.uid() or public.cn_is_super_admin());

create policy "admin writes xp_rules"    on public.xp_rules    for all to authenticated
  using (public.cn_is_super_admin()) with check (public.cn_is_super_admin());
create policy "admin writes xp_settings" on public.xp_settings for all to authenticated
  using (public.cn_is_super_admin()) with check (public.cn_is_super_admin());
create policy "admin writes xp_levels"   on public.xp_levels   for all to authenticated
  using (public.cn_is_super_admin()) with check (public.cn_is_super_admin());
create policy "admin writes skins"       on public.skins       for all to authenticated
  using (public.cn_is_super_admin()) with check (public.cn_is_super_admin());
create policy "admin writes user_skins"  on public.user_skins  for all to authenticated
  using (public.cn_is_super_admin()) with check (public.cn_is_super_admin());

-- ----------------------------------------------------------------- functions
create or replace function public.cn_level_for_xp(p_xp integer)
returns integer language sql stable set search_path to 'public' as $$
  select coalesce(max(level), 1) from public.xp_levels where xp_total <= greatest(coalesce(p_xp, 0), 0)
$$;

create or replace function public.cn_owns_skin(p_user uuid, p_kind text, p_slug text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (
    select 1 from public.skins s
    where s.slug = p_slug and s.kind = p_kind and s.is_active
      and ( exists (select 1 from public.user_skins u where u.user_id = p_user and u.skin_id = s.id)
            or ( s.unlock_level is not null
                 and public.cn_level_for_xp((select xp from public.profiles where id = p_user)) >= s.unlock_level ) )
  )
$$;

-- Nobody but the award function / an admin moves xp, and nobody equips what
-- they have not unlocked -- whatever they send straight at the profiles table.
create or replace function public.cn_profiles_guard_progress()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is null or current_setting('cn.progress_write', true) = '1' or public.cn_is_super_admin() then
    return new;
  end if;
  if new.xp is distinct from old.xp then new.xp := old.xp; end if;
  if new.equipped_unit_skin is distinct from old.equipped_unit_skin and new.equipped_unit_skin is not null
     and not public.cn_owns_skin(new.id, 'unit', new.equipped_unit_skin) then
    raise exception 'that skin is still locked';
  end if;
  if new.equipped_frame is distinct from old.equipped_frame and new.equipped_frame is not null
     and not public.cn_owns_skin(new.id, 'frame', new.equipped_frame) then
    raise exception 'that frame is still locked';
  end if;
  if new.name_color is distinct from old.name_color and new.name_color is not null
     and not public.cn_owns_skin(new.id, 'name_color', new.name_color) then
    raise exception 'that name colour is still locked';
  end if;
  return new;
end $$;
create trigger profiles_guard_progress before update on public.profiles
  for each row execute function public.cn_profiles_guard_progress();

-- Equip (or, with a null slug, clear) one skin. The one door the client uses.
create or replace function public.equip_skin(p_kind text, p_slug text)
returns text language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if p_kind not in ('unit', 'frame', 'name_color') then raise exception 'unknown skin kind'; end if;
  if p_slug is not null and not public.cn_owns_skin(v_uid, p_kind, p_slug) then
    raise exception 'that skin is still locked';
  end if;
  if p_kind = 'unit' then
    update public.profiles set equipped_unit_skin = p_slug where id = v_uid;
  elsif p_kind = 'frame' then
    update public.profiles set equipped_frame = p_slug where id = v_uid;
  else
    update public.profiles set name_color = coalesce(p_slug, 'blue') where id = v_uid;
  end if;
  return p_slug;
end $$;

-- The old RPC keeps working (an older cached client) -- it is now just equip.
create or replace function public.set_name_color(p_color text)
returns text language plpgsql security definer set search_path to 'public' as $$
begin
  return public.equip_skin('name_color', p_color);
end $$;

-- Deleting a skin unequips it everywhere first.
create or replace function public.cn_skins_cleanup_on_delete()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  perform set_config('cn.progress_write', '1', true);
  if old.kind = 'unit' then
    update public.profiles set equipped_unit_skin = null where equipped_unit_skin = old.slug;
  elsif old.kind = 'frame' then
    update public.profiles set equipped_frame = null where equipped_frame = old.slug;
  else
    update public.profiles set name_color = 'blue' where name_color = old.slug;
  end if;
  perform set_config('cn.progress_write', '', true);
  return old;
end $$;
create trigger skins_cleanup before delete on public.skins
  for each row execute function public.cn_skins_cleanup_on_delete();

-- One award. Idempotent on (user, ref): a finish path that fires twice pays once.
create or replace function public.cn_award_xp(p_user uuid, p_mode text, p_result text, p_ref text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_xp integer; v_old integer;
begin
  if p_user is null then return; end if;
  if not coalesce((select enabled from public.xp_settings where id = 1), false) then return; end if;
  select xp into v_xp from public.xp_rules where mode = p_mode and result = p_result;
  if coalesce(v_xp, 0) <= 0 then return; end if;
  select xp into v_old from public.profiles where id = p_user and not coalesce(is_system, false) for update;
  if not found then return; end if;
  insert into public.xp_events (user_id, ref, mode, result, xp, level_before, level_after)
  values (p_user, p_ref, p_mode, p_result, v_xp, public.cn_level_for_xp(v_old), public.cn_level_for_xp(v_old + v_xp))
  on conflict (user_id, ref) do nothing;
  if not found then return; end if;
  perform set_config('cn.progress_write', '1', true);
  update public.profiles set xp = xp + v_xp where id = p_user;
  perform set_config('cn.progress_write', '', true);
end $$;

create or replace function public.cn_xp_on_match_finish()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare v_min integer; v_mode text; v_h text; v_g text;
begin
  if new.status <> 'finished' or old.status = 'finished' then return new; end if;
  if coalesce(new.is_sim, false) then return new; end if;
  select min_turns into v_min from public.xp_settings where id = 1;
  if coalesce((new.state ->> 'turnNumber')::integer, 0) < coalesce(v_min, 0) then return new; end if;
  v_h := case new.winner when 'host' then 'win' when 'guest' then 'loss' else 'draw' end;
  v_g := case new.winner when 'guest' then 'win' when 'host' then 'loss' else 'draw' end;
  if new.guest_id is null then
    if new.bot is null or new.host_bot is not null then return new; end if;
    v_mode := case when new.ranked then 'ranked'
                   else case new.bot when 1 then 'bot_calm' when 2 then 'bot_sharp' else 'bot_ruthless' end end;
    perform public.cn_award_xp(new.host_id, v_mode, v_h, 'm:' || new.id);
  else
    if new.host_id = new.guest_id then return new; end if;
    v_mode := case when new.tournament_match_id is not null then 'tournament'
                   when new.ranked then 'ranked' else 'friendly' end;
    perform public.cn_award_xp(new.host_id,  v_mode, v_h, 'm:' || new.id);
    perform public.cn_award_xp(new.guest_id, v_mode, v_g, 'm:' || new.id);
  end if;
  return new;
end $$;
create trigger matches_award_xp after update of status on public.matches
  for each row execute function public.cn_xp_on_match_finish();

create or replace function public.cn_xp_on_royale_finish()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare v_min integer; v_humans integer; v_mode text; r record; v_res text;
begin
  if new.status <> 'finished' or old.status = 'finished' then return new; end if;
  select min_turns into v_min from public.xp_settings where id = 1;
  if coalesce((new.state ->> 'turnNumber')::integer, 0) < coalesce(v_min, 0) then return new; end if;
  select count(*) into v_humans from public.royale_players
   where match_id = new.id and user_id is not null and bot is null;
  v_mode := case when v_humans > 1 then 'royale' else 'royale_bots' end;
  for r in
    select user_id, seat, bot,
           row_number() over (order by (seat = new.winner_seat) desc, eliminated asc, eliminated_at desc nulls first) as place
      from public.royale_players where match_id = new.id
  loop
    continue when r.user_id is null or r.bot is not null;
    v_res := case when coalesce(new.draw, false) then 'draw'
                  when r.seat = new.winner_seat then 'win'
                  when r.place = 2 then 'second'
                  else 'loss' end;
    perform public.cn_award_xp(r.user_id, v_mode, v_res, 'r:' || new.id);
  end loop;
  return new;
end $$;
create trigger royale_matches_award_xp after update of status on public.royale_matches
  for each row execute function public.cn_xp_on_royale_finish();

-- ---------------------------------------------------------------------- seed
insert into public.xp_rules (mode, result, xp, label, sort) values
  ('ranked',       'win',    60, 'Ranked (ladder)', 1), ('ranked',       'loss',   25, 'Ranked (ladder)', 1), ('ranked',       'draw', 30, 'Ranked (ladder)', 1),
  ('friendly',     'win',    40, 'Friendly match',  2), ('friendly',     'loss',   20, 'Friendly match',  2), ('friendly',     'draw', 25, 'Friendly match',  2),
  ('tournament',   'win',    80, 'Tournament',      3), ('tournament',   'loss',   30, 'Tournament',      3), ('tournament',   'draw', 40, 'Tournament',      3),
  ('bot_calm',     'win',    10, 'Vs bot: Calm',     4), ('bot_calm',     'loss',    5, 'Vs bot: Calm',     4), ('bot_calm',     'draw',  5, 'Vs bot: Calm',     4),
  ('bot_sharp',    'win',    25, 'Vs bot: Sharp',    5), ('bot_sharp',    'loss',   10, 'Vs bot: Sharp',    5), ('bot_sharp',    'draw', 12, 'Vs bot: Sharp',    5),
  ('bot_ruthless', 'win',    40, 'Vs bot: Ruthless', 6), ('bot_ruthless', 'loss',   15, 'Vs bot: Ruthless', 6), ('bot_ruthless', 'draw', 20, 'Vs bot: Ruthless', 6),
  ('royale',       'win',    80, 'Battle Royale',   7), ('royale',       'second', 45, 'Battle Royale',   7), ('royale',       'loss', 20, 'Battle Royale',   7), ('royale', 'draw', 40, 'Battle Royale', 7),
  ('royale_bots',  'win',    25, 'Royale vs bots only', 8), ('royale_bots', 'second', 15, 'Royale vs bots only', 8), ('royale_bots', 'loss', 8, 'Royale vs bots only', 8), ('royale_bots', 'draw', 12, 'Royale vs bots only', 8);

-- 100 XP to reach 2, then a gently steepening staircase: 250, 450, 700, ...
insert into public.xp_levels (level, xp_total)
select l, 100 * (l - 1) + 25 * (l - 1) * (l - 2) from generate_series(1, 30) l;
update public.xp_levels set xp_total = 0 where level = 1;

insert into public.skins (slug, kind, name, name_es, description, unlock_level, data, sort) values
  -- the nine original name colours, now earned
  ('blue',   'name_color', 'Blue',   'Azul',    'Where everyone starts.', 1,  '{"var":"--nc-blue"}',   1),
  ('gray',   'name_color', 'Gray',   'Gris',    null,                     1,  '{"var":"--nc-gray"}',   2),
  ('black',  'name_color', 'Black',  'Negro',   null,                     2,  '{"var":"--nc-black"}',  3),
  ('red',    'name_color', 'Red',    'Rojo',    null,                     3,  '{"var":"--nc-red"}',    4),
  ('green',  'name_color', 'Green',  'Verde',   null,                     4,  '{"var":"--nc-green"}',  5),
  ('sky',    'name_color', 'Sky',    'Cielo',   null,                     5,  '{"var":"--nc-sky"}',    6),
  ('orange', 'name_color', 'Orange', 'Naranja', null,                     6,  '{"var":"--nc-orange"}', 7),
  ('purple', 'name_color', 'Purple', 'Morado',  null,                     8,  '{"var":"--nc-purple"}', 8),
  ('brown',  'name_color', 'Brown',  'Café',    null,                     10, '{"var":"--nc-brown"}',  9),
  ('nc_ember',  'name_color', 'Ember',  'Brasa',  'A fire gradient.',            12, '{"color":"#ff3b30","color2":"#ffb020","shimmer":false}', 20),
  ('nc_aurora', 'name_color', 'Aurora', 'Aurora', 'Shifting sky and violet.',    16, '{"color":"#2ec5ff","color2":"#a259ff","shimmer":true}',  21),
  ('nc_gold',   'name_color', 'Gold',   'Oro',    'A slow golden shimmer.',      22, '{"color":"#b37a00","color2":"#f0b92e","shimmer":true}',  22),
  -- unit looks
  ('unit_steel',   'unit', 'Steel',   'Acero',   'A cool steel rim.',                3,  '{"rim":"#8a94a6","rim_width":3,"glow":null,"glow_size":0,"sheen":"none","sheen_color":"#ffffff","tint":null,"tint_alpha":0}', 30),
  ('unit_emerald', 'unit', 'Emerald', 'Esmeralda','A green rim with a soft glow.',   6,  '{"rim":"#27ae60","rim_width":3,"glow":"#27ae60","glow_size":8,"sheen":"none","sheen_color":"#ffffff","tint":null,"tint_alpha":0}', 31),
  ('unit_crimson', 'unit', 'Crimson', 'Carmesí', 'A red rim that pulses.',           9,  '{"rim":"#d92d20","rim_width":3,"glow":"#d92d20","glow_size":10,"sheen":"pulse","sheen_color":"#ff6b5e","tint":null,"tint_alpha":0}', 32),
  ('unit_gilded',  'unit', 'Gilded',  'Dorado',  'A gold rim with a passing shine.', 14, '{"rim":"#e0b34a","rim_width":4,"glow":"#f5c542","glow_size":8,"sheen":"shine","sheen_color":"#fff3c4","tint":null,"tint_alpha":0}', 33),
  ('unit_holo',    'unit', 'Holo',    'Holo',    'A rainbow foil sweeping across.',  20, '{"rim":"#9be7ff","rim_width":3,"glow":"#a259ff","glow_size":10,"sheen":"holo","sheen_color":"#ffffff","tint":null,"tint_alpha":0}', 34),
  -- avatar frames
  ('frame_bronze', 'frame', 'Bronze ring', 'Anillo de bronce', null, 2,  '{"ring":"#b0703a","ring2":null,"width":4,"glow":null,"anim":"none"}', 40),
  ('frame_silver', 'frame', 'Silver ring', 'Anillo de plata',  null, 5,  '{"ring":"#c9d1dc","ring2":null,"width":4,"glow":null,"anim":"none"}', 41),
  ('frame_gold',   'frame', 'Gold ring',   'Anillo de oro',    null, 10, '{"ring":"#f5c542","ring2":"#e0902a","width":5,"glow":"#f5c542","anim":"none"}', 42),
  ('frame_flame',  'frame', 'Flame ring',  'Anillo de fuego',  null, 16, '{"ring":"#ff3b30","ring2":"#ffb020","width":5,"glow":"#ff6a2a","anim":"pulse"}', 43),
  ('frame_prism',  'frame', 'Prism ring',  'Anillo prisma',    null, 25, '{"ring":"#2ec5ff","ring2":"#ff4fd8","width":5,"glow":"#a259ff","anim":"spin"}', 44);

-- Players who already chose a name colour keep it.
insert into public.user_skins (user_id, skin_id, source)
select p.id, s.id, 'legacy'
  from public.profiles p join public.skins s on s.kind = 'name_color' and s.slug = p.name_color
on conflict do nothing;
