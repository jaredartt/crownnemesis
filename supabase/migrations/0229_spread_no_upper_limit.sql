-- 0229 -- animation Spread has no upper limit any more.
-- Jared: "I should be able to put here whatever I want, because maybe I want
-- 2 or 20 spins" (720 / 7200 on an arc_sweep). The old check capped it at 360,
-- one full turn; only the floor stays.
alter table public.animations drop constraint if exists animations_spread_deg_check;
alter table public.animations add constraint animations_spread_deg_check check (spread_deg >= 1);
