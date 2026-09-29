-- Jared: a first-time tutorial (Tutorial.tsx) that "will appear once you
-- create the account, right after." It is driven entirely client-side, off
-- a new `tutorialSeen` key inside profiles.settings (see settings.ts) --
-- absent/false means "show it", true means "don't". A brand new account's
-- settings column defaults to '{}'::jsonb, so tutorialSeen is naturally
-- absent there and the lesson fires exactly once, right after signup, with
-- no schema change and no server-side trigger needed for that half.
--
-- The other half is this migration: every account that already exists also
-- has no tutorialSeen key in its settings, for the same reason -- and
-- without this backfill every one of them would see the "first-time"
-- tutorial pop up the next time they open the app, which is not what
-- "right after you create the account" means for someone who made their
-- account months ago. So this runs once, marks every CURRENT profile as
-- already past it, and never runs again -- only a signup after today
-- starts with a settings blob this UPDATE never touched, which is exactly
-- the account the tutorial is for.
update public.profiles
set settings = settings || jsonb_build_object('tutorialSeen', true)
where not (coalesce(settings, '{}'::jsonb) ? 'tutorialSeen');
