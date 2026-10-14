-- 0255: how round the corners of the menu rhomboids are (Admin -> Look & feel).
-- Jared: "what if we rounded the borders of the menu options' rhomboids
-- everywhere? Make it totally and safely reversible." 0 = the sharp corners the
-- game always had; 100 = 20px. The client turns it into --rhomb-r (lib/lookFeel.ts)
-- and every rhomboid reads that variable with a 0 fallback, so setting this to 0
-- (a slider in Admin, no deploy) puts everything back exactly as it was.
alter table public.app_settings
  add column if not exists rhomb_roundness int not null default 50
    constraint app_settings_rhomb_roundness_check check (rhomb_roundness between 0 and 100);
