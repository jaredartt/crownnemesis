-- 0211: the new card face (Jared's redesign of the full-size card).
--
--  * cards.card_no      -- the "001" on the tag under the name. Backfilled in the
--                          order the cards were created, handed out automatically
--                          to a new card (max + 1), and editable per card in the
--                          admin panel (so it is NOT unique on purpose: he may
--                          want to renumber in two steps).
--  * cards.ability_icon -- the white Tabler icon on the coloured block beside the
--                          ability. Null = the card falls back to a default glyph.
--  * app_settings.stat_icon_mov / _rng / _atk -- the white icon at the left of
--                          the blue Movement, green Range and red Attack
--                          rhomboids. One per stat for the whole game.
alter table public.cards add column if not exists card_no integer;
alter table public.cards add column if not exists ability_icon text;

update public.cards c
   set card_no = r.n
  from (select id, (row_number() over (order by created_at, sort, slug))::int n
          from public.cards) r
 where c.id = r.id and c.card_no is null;

alter table public.cards drop constraint if exists cards_card_no_range;
alter table public.cards add constraint cards_card_no_range
  check (card_no is null or (card_no >= 0 and card_no <= 9999));
alter table public.cards drop constraint if exists cards_ability_icon_shape;
alter table public.cards add constraint cards_ability_icon_shape
  check (ability_icon is null or ability_icon ~ '^[a-z0-9-]{1,48}$');

create or replace function public.cn_card_no_default() returns trigger
language plpgsql as $$
begin
  if new.card_no is null then
    select coalesce(max(card_no), 0) + 1 into new.card_no from public.cards;
  end if;
  return new;
end $$;
drop trigger if exists cards_card_no_default on public.cards;
create trigger cards_card_no_default before insert on public.cards
  for each row execute function public.cn_card_no_default();

alter table public.app_settings add column if not exists stat_icon_mov text not null default 'walk';
alter table public.app_settings add column if not exists stat_icon_rng text not null default 'target';
alter table public.app_settings add column if not exists stat_icon_atk text not null default 'sword';
alter table public.app_settings drop constraint if exists app_settings_stat_icons_shape;
alter table public.app_settings add constraint app_settings_stat_icons_shape
  check (stat_icon_mov ~ '^[a-z0-9-]{1,48}$' and stat_icon_rng ~ '^[a-z0-9-]{1,48}$'
     and stat_icon_atk ~ '^[a-z0-9-]{1,48}$');
