-- 0254: an animation can be told to repeat for as long as an effect applies.
--
-- Jared: "can I control those animations from the admin panel? Maybe having a
-- button to make them repeat indefinitely. Don't hard code anything I said."
--
-- `loops` is the switch (Admin -> Animations -> "Repeat while the effect is
-- active"). When it is on, the board plays that animation continuously on every
-- unit the ability is currently affecting -- Umiro's power arrows on each ally
-- in range, Wuzu's surge while he is boosted, and so on -- and stops the moment
-- the effect stops. Which units are affected is the game rule (the client reads
-- it off the board, see src/lib/ambient.ts); WHETHER and WHAT loops is this one
-- column, so it is a toggle in Admin and not a line of code.
alter table public.animations add column if not exists loops boolean not null default false;
comment on column public.animations.loops is
  'Play this animation continuously while the effect it is attached to applies (standing abilities), instead of once when it triggers.';

-- The five that the first version of this feature looped by default.
update public.animations set loops = true
 where slug in ('umiro_power_aura', 'wuzu_power_surge', 'leos_bulwark', 'shu_leaf_guard', 'starter_rising_sparks');
