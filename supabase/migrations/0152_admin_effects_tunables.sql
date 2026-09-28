-- Jared: "make it so that in admin panel I have access to these things:
-- how much damage units receive by poison, how much damage units receive
-- by burn... make a checklist [of what triggers burn], make a checklist
-- [of what stun disables]."
--
-- The two percentages were hardcoded literals (cn_poison_pct() = 10,
-- cn_burn_pct() = 15 -- both a share of the unit's OWN max HP, per
-- cn_effect_dmg) with no way to see or change them short of reading SQL.
-- Same shape as every other game-balance number this admin panel already
-- exposes (elo_k_placement, ranked_bot_after_seconds, ...): a column on the
-- app_settings singleton, an admin-only write, read live by the function
-- that actually matters -- no redeploy either way. The two checklists are
-- read-only and not stored anywhere: they document what the code actually
-- does (traced through cn_attack/cn_ability/cn_move/cn_defend/advance_turn
-- this session), not a switch to flip.
--
-- For the record, since AdminEffects.tsx states it as fact:
--   BURN fires only as a cost of taking an action -- attacking (either
--   side of the exchange: the striker or whoever answers) or using an
--   ability (the caster only, not whatever it hits) -- never from moving,
--   defending, or simply ending a turn.
--   POISON is the opposite: a flat tick at the start of the poisoned
--   unit's own turn, regardless of what it does or doesn't do that turn --
--   not tied to attack, ability, move or defend at all.
--   STUN (0151, same session) now blocks all four: attack, ability, move
--   and defend.

alter table public.app_settings
  add column if not exists poison_pct int not null default 10;
alter table public.app_settings
  drop constraint if exists app_settings_poison_pct_check;
alter table public.app_settings
  add constraint app_settings_poison_pct_check
  check (poison_pct >= 1 and poison_pct <= 100);

alter table public.app_settings
  add column if not exists burn_pct int not null default 15;
alter table public.app_settings
  drop constraint if exists app_settings_burn_pct_check;
alter table public.app_settings
  add constraint app_settings_burn_pct_check
  check (burn_pct >= 1 and burn_pct <= 100);

-- Both were `language sql immutable` returning a bare literal; now they
-- read the live settings row, so `stable` (still no side effects, but no
-- longer safe to constant-fold across the row potentially changing).
create or replace function public.cn_poison_pct() returns integer
language sql stable as $function$
  select coalesce((select poison_pct from public.app_settings where id), 10)
$function$;

create or replace function public.cn_burn_pct() returns integer
language sql stable as $function$
  select coalesce((select burn_pct from public.app_settings where id), 15)
$function$;
