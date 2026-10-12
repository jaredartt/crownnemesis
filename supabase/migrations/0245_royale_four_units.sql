-- 0245: Battle Royale fields only the first N cards of a kingdom (N = app_settings.royale_units,
-- default 4, 2..6), the royal figure always included. Applied via execute_sql; live definitions
-- are the source of truth.
--
-- * app_settings.royale_units (check 2..6) + cn_royale_units()
-- * cn_royale_trim(text[]): keeps the royal and the first (N-1) non-royals, in kingdom order
-- * cn_derive_royale(): the army anchor now also patches cn_royale_army to
--     p_deck := cn_royale_trim(p_deck)  before the royal check, and loops 1 .. cardinality(p_deck)
--   so it follows 1v1 cn_army on every regeneration (royale_engine_log stays clean).
alter table public.app_settings add column if not exists royale_units int not null default 4;
alter table public.app_settings drop constraint if exists app_settings_royale_units_check;
alter table public.app_settings add constraint app_settings_royale_units_check check (royale_units between 2 and 6);

create or replace function public.cn_royale_units() returns int language sql stable as $$
  select coalesce((select royale_units from public.app_settings where id), 4)
$$;

create or replace function public.cn_royale_trim(p_deck text[]) returns text[] language plpgsql stable as $$
declare n int := cn_royale_units(); r text[] := '{}'; k int := 0; s text; v_royal boolean;
begin
  if p_deck is null or n >= cardinality(p_deck) or deck_royals(p_deck) <> 1 then return p_deck; end if;
  foreach s in array p_deck loop
    select royal into v_royal from public.cards where slug = s;
    if coalesce(v_royal, false) then r := r || s;
    elsif k < n - 1 then r := r || s; k := k + 1; end if;
  end loop;
  return r;
end $$;
-- (cn_derive_royale() was re-created with the two extra cn_royale_patch calls; see its live body.)
