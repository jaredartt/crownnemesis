-- Jared: "I want to be able to attach an animation to each of the sentences
-- a unit might have inside their active or passive ability. Make it a
-- dropdown button that I can choose from (kind of like how structures
-- work in that sense)... Create a new tab inside the admin panel where I
-- can define, create, modify and delete animations."
--
-- Correcting my own framing before this got built: there is no literal
-- hardcoded-per-unit animation anywhere in the client today (grepped the
-- whole thing for "umiro" -- nothing). What's actually hardcoded is
-- per-EFFECT-KIND: every heal always plays the same green diamond burst
-- (HealBurst.tsx), every burn/poison/stun always plays the same round dot
-- burst in a fixed per-status colour (StatusBurst.tsx). This table is the
-- start of replacing that -- an admin-defined catalog an ability's own
-- sentences can point at instead.
--
-- Built to the same shape as `structures` (0057) per Jared's own framing,
-- with three deliberate departures:
--
--  1. NOT reusing cn_touch_structures() -- that function has a live bug
--     (it unconditionally sets `new.accent := '#000000'` on every single
--     insert/update, visible today: `structures.bomb`/`tornado` are both
--     black because their most recent edit got clobbered, while `tree`/
--     `wall` still show their real colour from before whatever change
--     introduced the bug). cn_touch_animations() below only ever touches
--     updated_at. Flagged to Jared separately -- not fixed here, wrong
--     table for this migration.
--
--  2. `animation_slug` on card_effects gets a real FK, `on delete set
--     null` -- structure_slug's own FK (card_effects_structure_slug_fkey)
--     has no ON DELETE clause, so it's RESTRICT: you cannot delete a
--     structure a card still references. An animation reference is purely
--     cosmetic (nothing about how a match plays out depends on it), so
--     deleting an animation should just quietly stop drawing anything for
--     whatever sentences pointed at it, never block the delete.
--
--  3. Scope, Jared's own call: this migration is catalog-only -- the
--     `animations` table, its RLS, its delete RPC, four starter rows, and
--     the one new column + FK on card_effects so the picker has somewhere
--     to write. It does NOT touch Board.tsx/Duel.tsx/HealBurst.tsx/
--     StatusBurst.tsx -- an admin can define and preview an animation and
--     attach it to a sentence today, but a real match does not play it
--     yet. That's the deliberately staged fast-follow.
--
-- Presets, not freeform (Jared's call): five shapes below, all meant to
-- render with the SAME idiom the client already uses for HealBurst/
-- StatusBurst -- a DOM div positioned by CSS custom properties, animated
-- by shared @keyframes, no canvas/SVG/library -- see the frontend half of
-- this feature (AnimationFx.tsx) for exactly how each column maps onto
-- that. Column-by-column:
--
--  shape          which of the five presets: round_burst/diamond_burst
--                 (a fan of particles, particle_count/spread_deg/radius_px
--                 all apply -- literally HealBurst/StatusBurst's own
--                 shard-math, just admin-tunable instead of hardcoded),
--                 ring_pulse (one expanding ring, no particles),
--                 arc_sweep (a wedge that rotates through spread_deg
--                 degrees over duration_ms -- Jared's own example, "a
--                 sword circle swing" for Dione & Grifo), beam_line (a
--                 fan of thin bars that grow outward from the centre and
--                 fade -- no fixed direction yet, matches "where" being
--                 play_at rather than a facing).
--  color          hex, required. No secondary_color column -- considered
--                 it, cut it: nothing in the preset renderer would ever
--                 read a second colour, and a field an admin can set that
--                 visibly does nothing is worse than not having it.
--  duration_ms    50-12000. Capped at cine.ts's own CINE_CAP_MS (12000) --
--                 an animation playing during the ability cinematic can
--                 never ask for more time than the cinematic itself is
--                 hard-capped to. When live-match playback lands (the
--                 fast-follow), this will need the same server/client
--                 clock-mirroring discipline cine.ts's BEAT_MS already
--                 has with cn_cine_ms() (0021) -- flagged here, done
--                 there.
--  particle_count how many shards/dots a round_burst/diamond_burst draws.
--                 Ignored by the other three shapes.
--  spread_deg     1-360. Burst family: how wide the particles fan out
--                 (360 = full circle, matching HealBurst/StatusBurst
--                 today). arc_sweep: how far the wedge rotates -- 60-90
--                 reads as a swing, 360 as a full spin. beam_line: how wide
--                 its own small fixed fan of bars spreads. Ignored only by
--                 ring_pulse/pulse_only (a single centred effect, no fan or
--                 rotation to speak of).
--  radius_px      how far a burst particle travels / an arc's radius / a
--                 beam's length / a pulse's base size, in px at a tile's
--                 natural size (mapped to cqw at render time, same
--                 container-query scaling HealBurst/StatusBurst already
--                 use so it reads consistently at every zoom level).
--  scale_start/   the animation's own scale and opacity at its first and
--  scale_end/     last frame -- "growing," "vanishing the opacity
--  opacity_start/ smoothly," exactly as Jared described. A straight
--  opacity_end    start-to-end interpolation, deliberately simpler than
--                 HealBurst/StatusBurst's own hand-tuned three-keyframe
--                 curves (which are fixed, not admin-facing) -- an admin
--                 setting two numbers and trusting the curve between them
--                 beats an admin fighting hidden easing they can't see.
--  play_at        CASTER/TARGET/ALL_ALLIES/ALL_ENEMIES/WHOLE_BOARD -- its
--                 own small vocabulary, NOT card_effects' own 18-value
--                 target_selector. Two reasons: (1) once live playback
--                 exists, the renderer will already know exactly which
--                 unit was the caster and which units the sentence's own
--                 target_selector resolved to -- re-deriving
--                 ENEMY_IN_RANGE/RANDOM_ALLY/etc. independently client-
--                 side would be a second targeting engine solving a
--                 problem the first one already solved; CASTER/TARGET
--                 cover "the sentence's own resolved positions" from
--                 either side. (2) ALL_ALLIES/ALL_ENEMIES/WHOLE_BOARD are
--                 the genuinely different case Jared also named --
--                 flashing every ally's tile regardless of what the
--                 sentence itself mechanically targets (a passive
--                 MODIFY_STAT on SELF an admin still wants to visually
--                 read as a team-wide buff, say).
create table public.animations (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null default '',
  name_es text,
  description text,
  description_es text,

  shape text not null default 'round_burst'
    check (shape in ('round_burst', 'diamond_burst', 'ring_pulse', 'arc_sweep', 'beam_line', 'pulse_only')),
  color text not null default '#2f4bff' check (color ~ '^#[0-9a-fA-F]{6}$'),

  duration_ms integer not null default 600 check (duration_ms between 50 and 12000),
  particle_count integer not null default 9 check (particle_count between 0 and 24),
  spread_deg numeric not null default 360 check (spread_deg between 1 and 360),
  radius_px numeric not null default 42 check (radius_px > 0),

  scale_start numeric not null default 0.6 check (scale_start >= 0),
  scale_end   numeric not null default 1.4 check (scale_end >= 0),
  opacity_start numeric not null default 1 check (opacity_start between 0 and 1),
  opacity_end   numeric not null default 0 check (opacity_end between 0 and 1),

  play_at text not null default 'TARGET'
    check (play_at in ('CASTER', 'TARGET', 'ALL_ALLIES', 'ALL_ENEMIES', 'WHOLE_BOARD')),

  is_active boolean not null default true,
  sort integer not null default 99,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.cn_touch_animations()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  new.updated_at := now();
  return new;
end
$$;

create trigger animations_touch
  before insert or update on public.animations
  for each row execute function public.cn_touch_animations();

alter table public.animations enable row level security;

create policy "animations readable by authenticated" on public.animations
  for select to authenticated using (true);

create policy "admins write animations" on public.animations
  for all to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin))
  with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin));

-- Same shape as admin_delete_structure -- admin-only, existence check --
-- but no "still in use" guard: see the FK comment above, deleting an
-- animation is always safe, every card_effects row pointing at it just
-- goes back to null (no animation) automatically.
create or replace function public.admin_delete_animation(p_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if not exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin) then
    raise exception 'only an admin can delete an animation';
  end if;
  if not exists (select 1 from public.animations where id = p_id) then
    raise exception 'no animation with that id exists';
  end if;
  delete from public.animations where id = p_id;
end
$$;

-- Four starter rows so the catalog (and its sandbox preview) isn't empty
-- on first load: one of each particle-burst family, a plain pulse, and
-- one arc_sweep as a working example of Jared's own "sword circle swing"
-- idea for Dione & Grifo -- something real to open and tweak rather than
-- a blank form.
insert into public.animations
  (slug, name, shape, color, duration_ms, particle_count, spread_deg, radius_px, scale_start, scale_end, opacity_start, opacity_end, play_at, sort)
values
  ('starter_heal_burst', 'Heal burst (starter)', 'diamond_burst', '#3fae5a', 700, 14, 360, 42, 0.6, 1.4, 1, 0, 'TARGET', 1),
  ('starter_status_burst', 'Status burst (starter)', 'round_burst', '#d92d20', 450, 9, 360, 42, 0.6, 1.3, 1, 0, 'TARGET', 2),
  ('starter_pulse', 'Simple pulse (starter)', 'pulse_only', '#2f4bff', 500, 0, 360, 42, 0.8, 1.6, 0.8, 0, 'TARGET', 3),
  ('starter_sword_sweep', 'Sword circle swing (starter)', 'arc_sweep', '#c9c9c9', 500, 0, 90, 48, 0.9, 1.1, 1, 0, 'CASTER', 4);

-- 0074's own structure_slug, mirrored: which animations.slug this sentence
-- plays, on whichever action it is (unlike structure_slug, no action is
-- required to set this -- every sentence, on any action, may name one).
alter table public.card_effects
  add column animation_slug text references public.animations(slug) on delete set null;
