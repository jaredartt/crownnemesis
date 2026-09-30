-- 0191: Crowns (in-game money) and the Shop.
--
-- Jared: "I want people to earn new skins but the normal ones, not the ones with
-- the gradients and special ones ... I want them to buy them in the shop, not
-- with real money, with in-game money they earn through levelling up and winning
-- ranked matches."
--
--  * profiles.crowns: the balance. Only server code moves it (guard trigger).
--  * crown_events: the audit trail (every payout, purchase, admin change).
--  * xp_rules.crowns: Crowns paid per (mode, result) -- ranked win = 15 to start.
--  * xp_levels.crowns: Crowns paid once for reaching each level.
--  * skins.price: null = not sold; a number = sold in the Shop for that many
--    Crowns. A skin is either on the level track (unlock_level) or in the Shop.
--  * buy_skin(slug): the one door for buying; admin_adjust_crowns(): admin tool.
--  * The plain skins stay on the level track; gradients / glows / sheens move to
--    the Shop, and anyone who had already unlocked one by level keeps it.

-- ---------------------------------------------------------------- columns
alter table public.profiles add column if not exists crowns integer not null default 0 check (crowns >= 0);
alter table public.xp_rules  add column if not exists crowns integer not null default 0 check (crowns between 0 and 1000000);
alter table public.xp_levels add column if not exists crowns integer not null default 0 check (crowns between 0 and 1000000);
alter table public.skins     add column if not exists price  integer check (price is null or price >= 0);
alter table public.xp_events add column if not exists crowns integer not null default 0;

create table if not exists public.crown_events (
  id            bigint generated always as identity primary key,
  user_id       uuid not null references public.profiles(id) on delete cascade,
  amount        integer not null,
  reason        text not null check (reason in ('match', 'level_up', 'purchase', 'admin')),
  ref           text,
  note          text,
  balance_after integer not null,
  created_at    timestamptz not null default now(),
  unique (user_id, ref)
);
create index if not exists crown_events_user_idx on public.crown_events (user_id, created_at desc);
alter table public.crown_events enable row level security;
drop policy if exists "own crown events readable" on public.crown_events;
create policy "own crown events readable" on public.crown_events for select to authenticated
  using (user_id = auth.uid() or public.cn_is_super_admin());

-- ------------------------------------------------------------------ guard
create or replace function public.cn_profiles_guard_progress()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is null or current_setting('cn.progress_write', true) = '1' or public.cn_is_super_admin() then
    return new;
  end if;
  if new.xp is distinct from old.xp then new.xp := old.xp; end if;
  if new.crowns is distinct from old.crowns then new.crowns := old.crowns; end if;
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

-- ------------------------------------------------------------ earning
-- Same award as before, now also paying Crowns: the rule's amount, plus a
-- one-time payout for every level crossed (ref 'lvl:N' -- a level is paid once
-- per player no matter how often XP moves up and down).
create or replace function public.cn_award_xp(p_user uuid, p_mode text, p_result text, p_ref text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare
  v_xp integer; v_cr integer; v_old integer; v_lb integer; v_la integer;
  v_total integer := 0; v_bal integer; l record; v_paid integer;
begin
  if p_user is null then return; end if;
  if not coalesce((select enabled from public.xp_settings where id = 1), false) then return; end if;
  select xp, crowns into v_xp, v_cr from public.xp_rules where mode = p_mode and result = p_result;
  if coalesce(v_xp, 0) <= 0 and coalesce(v_cr, 0) <= 0 then return; end if;
  v_xp := coalesce(v_xp, 0); v_cr := coalesce(v_cr, 0);
  select xp, crowns into v_old, v_bal from public.profiles where id = p_user and not coalesce(is_system, false) for update;
  if not found then return; end if;
  v_lb := public.cn_level_for_xp(v_old);
  v_la := public.cn_level_for_xp(v_old + v_xp);
  insert into public.xp_events (user_id, ref, mode, result, xp, level_before, level_after)
  values (p_user, p_ref, p_mode, p_result, v_xp, v_lb, v_la)
  on conflict (user_id, ref) do nothing;
  if not found then return; end if;

  if v_cr > 0 then
    v_bal := v_bal + v_cr; v_total := v_cr;
    insert into public.crown_events (user_id, amount, reason, ref, note, balance_after)
    values (p_user, v_cr, 'match', p_ref, p_mode || ' ' || p_result, v_bal)
    on conflict (user_id, ref) do nothing;
  end if;
  if v_la > v_lb then
    for l in select level, crowns from public.xp_levels where level > v_lb and level <= v_la and crowns > 0 order by level loop
      insert into public.crown_events (user_id, amount, reason, ref, note, balance_after)
      values (p_user, l.crowns, 'level_up', 'lvl:' || l.level, 'reached level ' || l.level, v_bal + l.crowns)
      on conflict (user_id, ref) do nothing;
      get diagnostics v_paid = row_count;
      if v_paid > 0 then v_bal := v_bal + l.crowns; v_total := v_total + l.crowns; end if;
    end loop;
  end if;

  perform set_config('cn.progress_write', '1', true);
  update public.profiles set xp = xp + v_xp, crowns = crowns + v_total where id = p_user;
  perform set_config('cn.progress_write', '', true);
  if v_total > 0 then
    update public.xp_events set crowns = v_total where user_id = p_user and ref = p_ref;
  end if;
end $$;

-- ------------------------------------------------------------ buying
create or replace function public.buy_skin(p_slug text)
returns integer language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := auth.uid(); s public.skins; v_bal integer;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into s from public.skins where slug = p_slug and is_active;
  if not found or s.price is null then raise exception 'that is not for sale'; end if;
  if public.cn_owns_skin(v_uid, s.kind, s.slug) then raise exception 'you already own that'; end if;
  select crowns into v_bal from public.profiles where id = v_uid for update;
  if v_bal < s.price then raise exception 'not enough Crowns'; end if;
  v_bal := v_bal - s.price;
  perform set_config('cn.progress_write', '1', true);
  update public.profiles set crowns = v_bal where id = v_uid;
  perform set_config('cn.progress_write', '', true);
  insert into public.user_skins (user_id, skin_id, source) values (v_uid, s.id, 'shop');
  insert into public.crown_events (user_id, amount, reason, ref, note, balance_after)
  values (v_uid, -s.price, 'purchase', 'p:' || s.id, s.slug, v_bal);
  return v_bal;
end $$;
revoke all on function public.buy_skin(text) from public;
grant execute on function public.buy_skin(text) to authenticated;

-- ------------------------------------------------------------ admin tool
create or replace function public.admin_adjust_crowns(p_user uuid, p_op text, p_value integer)
returns integer language plpgsql security definer set search_path to 'public' as $$
declare v_old integer; v_new integer;
begin
  if not public.cn_is_super_admin() then raise exception 'admins only'; end if;
  select crowns into v_old from public.profiles where id = p_user for update;
  if not found then raise exception 'no such player'; end if;
  v_new := case p_op when 'add' then v_old + p_value when 'set' then p_value else null end;
  if v_new is null then raise exception 'unknown op'; end if;
  v_new := greatest(v_new, 0);
  perform set_config('cn.progress_write', '1', true);
  update public.profiles set crowns = v_new where id = p_user;
  perform set_config('cn.progress_write', '', true);
  insert into public.crown_events (user_id, amount, reason, ref, note, balance_after)
  values (p_user, v_new - v_old, 'admin', 'a:' || gen_random_uuid(), p_op, v_new);
  return v_new;
end $$;
revoke all on function public.admin_adjust_crowns(uuid, text, integer) from public;
grant execute on function public.admin_adjust_crowns(uuid, text, integer) to authenticated;

-- ------------------------------------------------------------ starting numbers
update public.xp_rules set crowns = 15 where mode = 'ranked' and result = 'win';
update public.xp_levels set crowns = 20 + 5 * (level - 2) where level >= 2;

-- plain frames for the level track (the gradient ones are Shop items now)
insert into public.skins (slug, kind, name, name_es, unlock_level, data, is_active, sort) values
  ('frame_slate', 'frame', 'Slate ring', 'Anillo pizarra', 3,  '{"style":"solid","ring":"#8a94a6","ring2":null,"ring3":null,"angle":0}', true, 30),
  ('frame_blue',  'frame', 'Blue ring',  'Anillo azul',    6,  '{"style":"solid","ring":"#2f4bff","ring2":null,"ring3":null,"angle":0}', true, 31),
  ('frame_green', 'frame', 'Green ring', 'Anillo verde',   9,  '{"style":"solid","ring":"#27ae60","ring2":null,"ring3":null,"angle":0}', true, 32),
  ('frame_red',   'frame', 'Red ring',   'Anillo rojo',    12, '{"style":"solid","ring":"#d92d20","ring2":null,"ring3":null,"angle":0}', true, 33),
  ('frame_ink',   'frame', 'Ink ring',   'Anillo tinta',   15, '{"style":"solid","ring":"#14141a","ring2":null,"ring3":null,"angle":0}', true, 34)
on conflict (slug) do nothing;

-- grandfather: anyone who already unlocked a gradient/special skin by level keeps it
insert into public.user_skins (user_id, skin_id, source)
select p.id, s.id, 'legacy'
  from public.skins s
  join public.profiles p on public.cn_level_for_xp(p.xp) >= s.unlock_level
 where s.unlock_level is not null
   and ( (s.kind = 'frame' and s.data ->> 'style' <> 'solid')
      or (s.kind = 'name_color' and s.data ->> 'color2' is not null)
      or (s.kind = 'unit' and ((s.data ->> 'sheen') <> 'none' or s.data ->> 'glow' is not null or s.data ->> 'tint' is not null)) )
on conflict do nothing;

-- ...then move them to the Shop
with shop as (
  select id, slug, kind from public.skins
   where unlock_level is not null
     and ( (kind = 'frame' and data ->> 'style' <> 'solid')
        or (kind = 'name_color' and data ->> 'color2' is not null)
        or (kind = 'unit' and ((data ->> 'sheen') <> 'none' or data ->> 'glow' is not null or data ->> 'tint' is not null)) )
)
update public.skins k set unlock_level = null,
  price = case k.slug
    when 'frame_bronze' then 100 when 'frame_emerald' then 150 when 'frame_silver' then 150
    when 'frame_ocean' then 200 when 'frame_gold' then 300 when 'frame_sunset' then 350
    when 'frame_flame' then 400 when 'frame_royal' then 450 when 'frame_aurora' then 500
    when 'frame_candy' then 500 when 'frame_prism' then 600 when 'frame_onyx' then 600
    when 'nc_ember' then 250 when 'nc_aurora' then 400 when 'nc_gold' then 500
    when 'unit_emerald' then 200 when 'unit_crimson' then 350 when 'unit_gilded' then 450 when 'unit_holo' then 600
    else 300 end
  from shop where shop.id = k.id;

-- plain unit looks for the level track (glow / sheen ones are Shop items)
insert into public.skins (slug, kind, name, name_es, unlock_level, data, is_active, sort) values
  ('unit_azure', 'unit', 'Azure rim', 'Borde azul',  8,  '{"rim":"#2f4bff","rim_width":3,"glow":null,"glow_size":0,"sheen":"none","sheen_color":"#ffffff","tint":null,"tint_alpha":0}', true, 20),
  ('unit_jade',  'unit', 'Jade rim',  'Borde jade',  13, '{"rim":"#27ae60","rim_width":3,"glow":null,"glow_size":0,"sheen":"none","sheen_color":"#ffffff","tint":null,"tint_alpha":0}', true, 21),
  ('unit_ruby',  'unit', 'Ruby rim',  'Borde rubí',  18, '{"rim":"#d92d20","rim_width":3,"glow":null,"glow_size":0,"sheen":"none","sheen_color":"#ffffff","tint":null,"tint_alpha":0}', true, 22)
on conflict (slug) do nothing;

-- the Shop tile gets a row in the admin Menu manager (visible/sort/art crop)
insert into public.menu_sections (id, visible, sort) values ('shop', true, 8) on conflict (id) do nothing;
