-- =============================================================================
-- 0056 -- ABILITY SENTENCES: grouping, Active/Passive, max uses, cooldown.
--
-- The developer's ask: a "Mad Libs" sentence builder in the Admin Menu that
-- reads left to right like English, replacing the row-by-row dropdown editor
-- (AbilityEditor.tsx) 0049 shipped. Jared's own answers, from the
-- clarifying round before this was built: (1) full live gameplay, not just
-- an authoring screen; (2) the sentence UI REPLACES AbilityEditor but keeps
-- compiling to the same `card_effects` shape cn_run_effects already reads,
-- rather than a parallel schema; (3) a card may carry several independent
-- sentences, each its own Active-or-Passive; (4) Structures are a brand-new
-- content type with their own tables -- that is 0057, not this file.
--
-- WHAT THIS FILE ADDS, and why it is additive rather than a rewrite:
--
--   - `card_effects.group_id` -- ties every row of ONE AUTHORED SENTENCE
--     together (a sentence with "And" in it compiles to more than one row
--     sharing a trigger and a group_id). Existing rows get a fresh, distinct
--     group_id each via the column default, which is exactly correct: the
--     row-per-row editor already saved one independent effect per row, so
--     every existing row IS its own one-row sentence. cn_run_effects,
--     cn_resolve_targets, cn_effect_apply_action, cn_compile_card_effects --
--     every reader of this table -- are UNTOUCHED: none of them has ever
--     cared about anything but trigger/target_selector/action/value/status/
--     stat_name/conditions, and none of them needs to.
--
--   - `duration_kind`/`duration_turns`, `range_kind`/`range_min`/`range_max`
--     -- two Mad-Libs categories (Duration, Range) that the 0049 engine has
--     no columns for at all. Stored so a sentence can say "for 3 turns" or
--     "in range 1-4" and have that survive a save. Engine enforcement is
--     partial and said so plainly below, in the same spirit as 0049's own
--     ACTION_NOOPS -- ranged/timed effects a tactics game will eventually
--     want, authored now, wired where it is cheap and safe to do today:
--       * duration_kind = 'FOR_TURNS' on an APPLY_STATUS/STUN row already
--         works exactly as authored -- cn_afflict's stun already carries a
--         turn count, and cn_effect_apply_action already passes v_value
--         through to it (see that function, unchanged).
--       * duration_kind on BURNING/POISON is accepted and stored but not
--         separately counted down -- those two have always been binary
--         "afflicted until cured" flags with no turn counter anywhere in
--         the engine, and adding one is a real, separate change to
--         cn_afflict/advance_turn/cn_attack's burn-tick logic that this
--         pass deliberately leaves alone rather than splicing three more
--         order-sensitive functions for it. THIS_TURN and UNTIL_REMOVED
--         already match how burn/poison actually behave today, so only
--         FOR_TURNS on those two statuses is the honest gap.
--       * range_kind = 'FIXED_RANGE' (range_min/range_max) is accepted and
--         stored as authoring metadata; cn_resolve_targets' ENEMY_IN_RANGE
--         still reads the ACTING UNIT's own rmin/rmax, as it always has.
--         Overriding per-effect range needs a second parameter threaded
--         through cn_resolve_targets/cn_run_effects, which is a small,
--         clean follow-up once the sentence UI itself has shipped -- noted
--         here rather than guessed at.
--     Both gaps are named in AdminCards.tsx/AdminStructures.tsx's own UI
--     text too, the same "(not built yet)" honesty 0049's ACTION_NOOPS
--     already established for REVIVE/SUMMON_OBJECT/etc.
--
--   - `card_ability_meta` -- one row per AUTHORED SENTENCE that is an
--     Active ability: ability_type (kept for Passive sentences too, so the
--     editor has one place to read "what toggle is this group"), max_uses
--     (null = infinite, else 1-5), cooldown_turns (0-5). A SEPARATE table
--     from card_effects rather than more columns on it because these three
--     values describe the SENTENCE, not any one row in it -- a sentence
--     that compiles to three card_effects rows (an "and" chain) has ONE
--     cooldown, not three copies of the same number to keep in sync.
--
--     AT MOST ONE ACTIVE SENTENCE PER CARD is enforced by a partial unique
--     index, not left to the UI to promise. This matches the actual
--     gameplay contract, which has not changed: `cn_ability` dispatches ONE
--     ability per unit (`cards.ability_kind`), the board's Ability button is
--     one button, and `submit_ability` takes no group id to choose between
--     several. The sentence UI is free to let an admin build several
--     PASSIVE sentences on one card (matching today's several-PASSIVE-row
--     reality); Active stays singular because the client has exactly one
--     slot for it. Loosening that is a real, separate feature (a picker for
--     which of several abilities to activate) and is not part of this pass.
--
--   - Cooldown is tracked as "the turn number this was last used", not as a
--     counting-down field that needs a tick every turn boundary. That is a
--     deliberate simplification, not a shortcut: it means this migration
--     touches `cn_army` and `cn_ability` only -- NOT `advance_turn`, which
--     already carries the AFK-forfeit and stalemate-draw logic 0051 added
--     and is exactly the kind of order-sensitive function this project's
--     own conventions (see project_status.md section 7) say to be most
--     careful splicing. "Ready again once turnNumber - lastUsed >
--     cooldown_turns" is the same fact a countdown would track, computed
--     instead of stored, and it needs no maintenance on any turn nobody
--     used the ability.
--
--   - Uses remaining is tracked as a plain per-unit counter, incremented on
--     every successful activation and compared against the snapshot's own
--     `abilityMaxUses` (null = never refuse). Both counters live on the
--     UNIT, not the card: a card retuned mid-match must not change a match
--     already running, so `abilityMaxUses`/`abilityCooldownTurns` are
--     snapshotted onto the unit at deploy exactly like `abilityScript`
--     already is (see cn_army's own comment on that field), and
--     `abilityUses`/`abilityLastUsedTurn` are per-unit runtime state that
--     mutates over the match, exactly like `hp`/`moved`/`acted`/`effects`
--     already do.
--
-- Every splice below was fetched fresh via pg_get_functiondef from this
-- exact checkout (all of 0001-0055 applied) immediately before writing this
-- file, not reconstructed from memory -- see project_status.md section 7,
-- "Splice, never rewrite from memory."
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. card_effects grows a sentence identity, plus Duration and Range.
-- ---------------------------------------------------------------------------

alter table public.card_effects
  add column if not exists group_id uuid not null default gen_random_uuid();

comment on column public.card_effects.group_id is
  'Ties every row of one authored Mad-Libs sentence together. Several rows '
  'can share a group_id (an "And" chain of actions under one trigger); an '
  'existing pre-0056 row is its own one-row sentence via the column default.';

alter table public.card_effects
  add column if not exists duration_kind text,
  add column if not exists duration_turns int,
  add column if not exists range_kind text,
  add column if not exists range_min int,
  add column if not exists range_max int;

alter table public.card_effects drop constraint if exists card_effects_duration_kind_check;
alter table public.card_effects add constraint card_effects_duration_kind_check
  check (duration_kind is null or duration_kind in ('THIS_TURN', 'FOR_TURNS', 'UNTIL_REMOVED'));

alter table public.card_effects drop constraint if exists card_effects_duration_turns_check;
alter table public.card_effects add constraint card_effects_duration_turns_check
  check (duration_turns is null or duration_turns between 2 and 5);

alter table public.card_effects drop constraint if exists card_effects_duration_turns_needs_kind;
alter table public.card_effects add constraint card_effects_duration_turns_needs_kind
  check (duration_turns is null or duration_kind = 'FOR_TURNS');

alter table public.card_effects drop constraint if exists card_effects_range_kind_check;
alter table public.card_effects add constraint card_effects_range_kind_check
  check (range_kind is null or range_kind in
    ('CARD_RANGE', 'FIXED_RANGE', 'ANYWHERE', 'PLAYER_CHOOSES'));

alter table public.card_effects drop constraint if exists card_effects_range_bounds_check;
alter table public.card_effects add constraint card_effects_range_bounds_check
  check (range_min is null or range_max is null or range_min between 1 and range_max);

alter table public.card_effects drop constraint if exists card_effects_range_max_check;
alter table public.card_effects add constraint card_effects_range_max_check
  check (range_max is null or range_max between 1 and 4);

alter table public.card_effects drop constraint if exists card_effects_range_needs_fixed;
alter table public.card_effects add constraint card_effects_range_needs_fixed
  check ((range_min is null and range_max is null) or range_kind = 'FIXED_RANGE');

comment on column public.card_effects.duration_kind is
  'Authoring metadata for how long an applied status/modifier lasts. '
  'FOR_TURNS is enforced today only for STUN (cn_afflict already carries a '
  'turn count); on BURNING/POISON it is accepted and stored but not yet '
  'separately ticked -- see this migration''s header.';
comment on column public.card_effects.range_kind is
  'Authoring metadata for the Range Mad-Libs category. FIXED_RANGE''s '
  'range_min/range_max are not yet read by cn_resolve_targets, which still '
  'uses the acting unit''s own rmin/rmax -- see this migration''s header.';

-- ---------------------------------------------------------------------------
-- 2. card_ability_meta -- one row per authored sentence that is an Active
--    ability: what it costs to use it.
-- ---------------------------------------------------------------------------

create table if not exists public.card_ability_meta (
  card_id uuid not null references public.cards(id) on delete cascade,
  group_id uuid not null,
  ability_type text not null default 'passive' check (ability_type in ('active', 'passive')),
  -- null = infinite. 1-5 per the developer's spec.
  max_uses int check (max_uses is null or max_uses between 1 and 5),
  cooldown_turns int not null default 0 check (cooldown_turns between 0 and 5),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (card_id, group_id)
);

-- THE ONE GAMEPLAY CONTRACT THIS FILE ENFORCES RATHER THAN HOPES FOR: at
-- most one Active sentence per card, because cn_ability/submit_ability/the
-- board's Ability button all still assume exactly one ability slot -- see
-- this migration's header. A partial unique index refuses a second Active
-- row outright rather than silently letting the UI's own promise drift from
-- what the server actually does.
create unique index if not exists card_ability_meta_one_active_per_card
  on public.card_ability_meta (card_id) where (ability_type = 'active');

alter table public.card_ability_meta enable row level security;

create policy "admins write card ability meta" on public.card_ability_meta
  for all to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin))
  with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin));

create policy "card ability meta readable by authenticated" on public.card_ability_meta
  for select to authenticated
  using (true);

create or replace function public.cn_touch_card_ability_meta()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end
$$;

drop trigger if exists card_ability_meta_touch on public.card_ability_meta;
create trigger card_ability_meta_touch
  before update on public.card_ability_meta
  for each row execute function public.cn_touch_card_ability_meta();

-- ---------------------------------------------------------------------------
-- 3. THE SPLICES -- cn_army, cn_ability. Each fetched fresh via
--    pg_get_functiondef from this exact checkout (0001-0055 applied)
--    immediately before writing this file. Additive block(s) marked
--    '0056:' below.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.cn_army(p_state jsonb, p_side text, p_deck text[])
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
declare
  v_w int := (p_state->'board'->>'w')::int;
  v_h int := (p_state->'board'->>'h')::int;
  v_taken text[] := '{}'; e jsonb; c public.cards;
  v_xs int[] := '{}'::int[]; v_ys int[] := '{}'::int[];
  i int; vx int; vy int; v_idx int := 0;
  v_units jsonb := '[]'::jsonb; v_done boolean;
  -- 0049: this unit's card_effects rows, snapshotted alongside every
  -- other stat -- see 0049_card_effects_engine.sql's header.
  v_script jsonb;
  -- 0056: this unit's one Active sentence's cost, if it has one -- see this
  -- migration's header on why these three ride the snapshot like every
  -- other stat rather than being read live from card_ability_meta mid-match.
  v_meta record;
begin
  -- ONE CROWN, NO EXCEPTIONS. This is the only door every army in the game
  -- comes through, which is the whole reason the rule is here and not in the
  -- four functions that build decks. It should never fire: set_deck refuses,
  -- deck_of repairs, random_deck picks one. An invariant that never fires is
  -- an invariant doing its job.
  if deck_royals(p_deck) <> 1 then
    raise exception 'a kingdom is exactly one royal and % others, not %',
      deck_size() - 1, deck_royals(p_deck);
  end if;

  for e in select * from jsonb_array_elements(coalesce(p_state->'obstacles', '[]'::jsonb)) loop
    v_taken := v_taken || ((e->>'x') || ',' || (e->>'y'));
  end loop;

  -- columns, odd ones first, so five units on a six-wide board do not end
  -- up shoulder to shoulder along the back rank
  for i in 0 .. (v_w - 1) / 2 loop
    if 2 * i + 1 < v_w then v_xs := v_xs || (2 * i + 1); end if;
  end loop;
  for i in 0 .. (v_w - 1) / 2 loop
    if 2 * i < v_w then v_xs := v_xs || (2 * i); end if;
  end loop;

  -- rows, back rank first. The host's home row is 0, the guest's is h-1,
  -- so the two armies start facing each other down the long axis.
  if p_side = 'host'
    then for i in 0 .. (v_h / 2 - 1)            loop v_ys := v_ys || i; end loop;
    else for i in reverse (v_h - 1) .. (v_h / 2) loop v_ys := v_ys || i; end loop;
  end if;

  for i in 1 .. deck_size() loop
    select * into c from public.cards where slug = p_deck[i];
    if c.id is null then raise exception 'unknown card %', p_deck[i]; end if;

    -- 0049: THE SNAPSHOT. Copied onto the unit the moment its army is
    -- built -- the same instant every other stat is copied -- so a card
    -- retuned in the editor mid-match never changes a game already
    -- running. Runtime (cn_run_effects) reads this and never re-joins
    -- `card_effects` once a match exists.
    select coalesce(jsonb_agg(jsonb_build_object(
             'trigger', ce.trigger, 'target_selector', ce.target_selector,
             'action', ce.action, 'value', ce.value, 'status', ce.status,
             'stat_name', ce.stat_name, 'conditions', ce.conditions,
             'sort', ce.sort) order by ce.sort), '[]'::jsonb)
      into v_script
      from public.card_effects ce where ce.card_id = c.id;

    -- 0056: the one Active sentence's cost, if this card has one. Left
    -- null/false when it does not -- cn_ability's own splice treats a null
    -- abilityMaxUses/abilityCooldownTurns as "no limit", which is exactly
    -- today's unlimited-use behaviour for every card that predates this.
    select ability_type, max_uses, cooldown_turns into v_meta
      from public.card_ability_meta
     where card_id = c.id and ability_type = 'active'
     limit 1;

    v_done := false;
    foreach vy in array v_ys loop
      foreach vx in array v_xs loop
        if not ((vx || ',' || vy) = any(v_taken)) then
          v_taken := v_taken || (vx || ',' || vy);
          v_done := true;
          exit;
        end if;
      end loop;
      exit when v_done;
    end loop;
    if not v_done then raise exception 'nowhere to deploy'; end if;

    v_idx := v_idx + 1;
    -- The parenthesis matters: `||` is left-associative, so without it the
    -- second object below would be appended to the ARRAY as a unit of its
    -- own rather than merged into the one being built.
    v_units := v_units || (jsonb_build_object(
      'id', substr(p_side, 1, 1) || v_idx, 'owner', p_side,
      'cardId', c.id, 'slug', c.slug, 'name', c.name, 'role', c.role,
      'hp', c.hp, 'maxHp', c.hp, 'mov', c.mov,
      'rmin', c.rmin, 'rmax', c.rmax, 'crmin', c.crmin, 'crmax', c.crmax,
      'dmin', c.dmin, 'dmax', c.dmax, 'pow', c.power,
      'parryPct', c.parry_pct, 'critPct', c.crit_pct, 'parryAll', c.parry_all,
      'royal', c.royal,
      -- What this unit can DO, carried on the snapshot with everything else:
      -- a card retuned in the editor must not change a match in progress.
      'abilityKind', c.ability_kind, 'abilityN', c.ability_n,
      'abilityTurns', c.ability_turns, 'summonKind', c.summon_kind,
      'slippery', c.slippery, 'twicePct', c.twice_pct, 'regenPct', c.regen_pct,
      'poisonsAdj', c.poisons_adjacent, 'stuns', c.stuns,
      'vsPoisoned', c.vs_poisoned, 'lifestealPct', c.lifesteal_pct,
      -- The aura travels with the unit, like every other stat, because a
      -- card retuned mid-match must not change a match already running.
      'auraKind', c.aura_kind, 'auraClass', c.aura_class, 'auraPct', c.aura_pct,
      'burns', c.burns, 'heals', c.heals,
      -- One object for three effects, so a fourth is a key rather than a
      -- migration. `burned` is gone: nothing has applied one since 0033,
      -- which made this the last cheap moment to change the shape.
      'effects', cn_no_effects(),
      'flies', c.flies, 'sneaks', c.sneaks, 'cures', c.cures, 'tramples', c.tramples,
      'parries', c.parries, 'blooms', c.blooms,
      'accent', c.accent, 'art', c.art_url, 'ability', c.ability,
      'x', vx, 'y', vy, 'moved', false, 'acted', false)
      -- A SECOND OBJECT, and not a fiftieth pair in the first one.
      -- jsonb_build_object takes at most a hundred arguments and the unit
      -- snapshot had reached exactly a hundred, so 0037 pushed it over and
      -- every match in the suite died with 'cannot pass more than 100
      -- arguments to a function'. Concatenating is the same value, the same
      -- one statement, and it has room for the next twenty.
      || jsonb_build_object('swamps', c.swamps, 'abilityScript', v_script)
      -- 0056: the Active sentence's cost, if any -- see cn_ability's own
      -- splice for how abilityUses/abilityLastUsedTurn (the RUNTIME
      -- counters, absent here on purpose) read these two.
      || jsonb_build_object(
           'abilityMaxUses', v_meta.max_uses,
           'abilityCooldownTurns', coalesce(v_meta.cooldown_turns, 0)));
  end loop;
  return v_units;
end
$function$
;

CREATE OR REPLACE FUNCTION public.cn_ability(p_match uuid, p_side text, p_unit text, p_target text)
 RETURNS matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  m public.matches; v_st jsonb; u jsonb; e jsonb;
  v_me jsonb; v_tgt jsonb; v_kind text; v_n int;
  v_out jsonb := '[]'::jsonb; v_rocks jsonb := '[]'::jsonb;
  v_hits jsonb := '[]'::jsonb; v_swings jsonb := '[]'::jsonb;
  v_dist int; v_got int; v_hp int; v_felled boolean := false;
  v_dx int; v_dy int; v_what text; v_tile int[];
  v_note text; v_seq int;
  -- 0056: the Active sentence's cost, and how many turns since it was last
  -- used, if ever.
  v_turn_no int; v_max_uses int; v_cooldown int; v_used int; v_last_used int;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'active' then raise exception 'match is not running'; end if;
  v_st := m.state;
  if v_st->>'turn' <> p_side then raise exception 'not your turn'; end if;

  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then v_me := u; end if;
    if p_target is not null and u->>'id' = p_target then v_tgt := u; end if;
  end loop;
  if v_me is null then raise exception 'no such unit'; end if;
  if v_me->>'owner' <> p_side then raise exception 'that is not your unit'; end if;
  if (v_me->>'acted')::boolean then raise exception 'that unit already acted'; end if;
  -- An ability substitutes the attack, so a stun takes both.
  if cn_stunned(v_me) then raise exception 'that unit is stunned'; end if;

  -- Said out loud rather than left to fall through cn_awake into 'that unit
  -- has no ability'. "Not this card" and "not while you are standing there"
  -- are different news, and a player who cannot tell them apart will think
  -- the game is broken rather than that they are being beaten.
  if cn_swamped(v_st, v_me) then raise exception 'that unit is in the swamp'; end if;
  v_me := cn_awake(v_st, v_me);

  v_kind := v_me->>'abilityKind';
  if v_kind is null then raise exception 'that unit has no ability'; end if;
  v_n := coalesce((v_me->>'abilityN')::int, 0);

  -- ===== 0056: max uses / cooldown, checked before anything else spends ===
  -- this activation. A null abilityMaxUses/zero abilityCooldownTurns is
  -- "no limit" -- exactly today's behaviour for every card that predates
  -- card_ability_meta, so a card with no row there is completely unaffected.
  -- Checked (and, on success, RECORDED) here rather than inside any one
  -- kind's branch: every kind below shares the same one ability slot, so
  -- the cost is a property of activating THIS UNIT's ability at all, not of
  -- which kind it turns out to be.
  v_turn_no := coalesce((v_st->>'turnNumber')::int, 1);
  v_max_uses := nullif(v_me->>'abilityMaxUses', '')::int;
  v_cooldown := coalesce(nullif(v_me->>'abilityCooldownTurns', '')::int, 0);
  v_used := coalesce((v_me->>'abilityUses')::int, 0);
  v_last_used := nullif(v_me->>'abilityLastUsedTurn', '')::int;
  if v_max_uses is not null and v_used >= v_max_uses then
    raise exception 'that ability has no uses left this match';
  end if;
  if v_cooldown > 0 and v_last_used is not null
     and v_turn_no - v_last_used <= v_cooldown then
    raise exception 'that ability is on cooldown for % more turn(s)',
      v_cooldown - (v_turn_no - v_last_used) + 1;
  end if;
  v_me := jsonb_set(v_me, '{abilityUses}', to_jsonb(v_used + 1));
  v_me := jsonb_set(v_me, '{abilityLastUsedTurn}', to_jsonb(v_turn_no));
  -- ===== end 0056 ===========================================================

  -- Same budget as a strike, because it IS the strike: an ability substitutes
  -- the attack inside one activation.
  v_st := cn_begin_act(v_st, p_side, p_unit);
  v_seq := coalesce((v_st->'fx'->>'seq')::int, 0) + 1;

  -- ---- every tile around you ----------------------------------------------
  if v_kind = 'aoe_adjacent' then
    for u in select * from jsonb_array_elements(v_st->'units') loop
      if u->>'id' <> p_unit
         and cn_cheb((v_me->>'x')::int, (v_me->>'y')::int,
                     (u->>'x')::int, (u->>'y')::int) = 1 then
        -- Friend and foe alike. "All nearby tiles" is what the card says and
        -- what it means: standing beside your own Knight is a decision.
        v_hp := (u->>'hp')::int - v_n;
        u := jsonb_set(u, '{hp}', to_jsonb(v_hp));
        v_hits := v_hits || jsonb_build_object('id', u->>'id', 'dmg', v_n);
        v_swings := v_swings || jsonb_build_object(
          'k', 'hit', 'by', p_unit, 'at', u->>'id', 'dmg', v_n,
          'crit', false, 'counter', false, 'first', false, 'def', false,
          'why', 'ability');
      end if;
      if (u->>'hp')::int > 0 then v_out := v_out || u; end if;
    end loop;
    -- A tree beside it comes down too, which is the same sentence applied
    -- honestly rather than an exception carved out for scenery.
    for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
      if cn_cheb((v_me->>'x')::int, (v_me->>'y')::int,
                 (e->>'x')::int, (e->>'y')::int) = 1 then
        e := jsonb_set(e, '{hp}', to_jsonb((e->>'hp')::int - v_n));
        v_felled := v_felled or (e->>'hp')::int <= 0;
      end if;
      if (e->>'hp')::int > 0 then v_rocks := v_rocks || e; end if;
    end loop;
    v_st := jsonb_set(v_st, '{obstacles}', v_rocks);
    v_note := (v_me->>'name') || ' strikes every tile around them for ' || v_n || '.';

  -- ---- thirty hit points, to whoever you point at -------------------------
  elsif v_kind = 'heal_any' then
    if v_tgt is null then raise exception 'that ability needs a target'; end if;
    v_dist := cn_cheb((v_me->>'x')::int, (v_me->>'y')::int,
                      (v_tgt->>'x')::int, (v_tgt->>'y')::int);
    if v_dist > (v_me->>'rmax')::int then raise exception 'out of range'; end if;
    if not cn_los_clear(v_st, (v_me->>'x')::int, (v_me->>'y')::int,
                        (v_tgt->>'x')::int, (v_tgt->>'y')::int) then
      raise exception 'a tree is in the way';
    end if;
    for u in select * from jsonb_array_elements(v_st->'units') loop
      if u->>'id' = p_target then
        v_got := least((u->>'maxHp')::int - (u->>'hp')::int, v_n);
        u := jsonb_set(u, '{hp}', to_jsonb((u->>'hp')::int + v_got));
      end if;
      v_out := v_out || u;
    end loop;
    v_hits := jsonb_build_array(jsonb_build_object('id', p_target, 'heal', v_got));
    v_swings := jsonb_build_array(jsonb_build_object(
      'k', 'heal', 'by', p_unit, 'at', p_target, 'dmg', v_got,
      'crit', false, 'counter', false, 'first', false, 'def', false,
      'why', 'mend'));
    v_note := (v_me->>'name') || ' mends ' || (v_tgt->>'name') || ' for ' || v_got || '.';

  -- ---- two turns of cover -------------------------------------------------
  elsif v_kind = 'mist' then
    -- The parent key first. jsonb_set's create_missing only creates the LAST
    -- step of a path: ['mist','host'] on a state with no 'mist' at all does
    -- nothing at all, silently, which is the worst way for a jsonb write to
    -- fail. A match begun before this migration has no 'mist' key.
    if v_st->'mist' is null then
      v_st := jsonb_set(v_st, '{mist}', '{}'::jsonb, true);
    end if;
    v_st := jsonb_set(
      v_st, array['mist', p_side],
      jsonb_build_object('t', coalesce((v_me->>'abilityTurns')::int, 1), 'pct', v_n),
      true);
    v_out := v_st->'units';
    v_note := (v_me->>'name') || ' calls up the mist.';

  -- ---- ten, and poisoned ---------------------------------------------------
  elsif v_kind = 'poison_hit' then
    if v_tgt is null then raise exception 'that ability needs a target'; end if;
    if v_tgt->>'owner' = p_side then raise exception 'no friendly fire'; end if;
    v_dist := cn_cheb((v_me->>'x')::int, (v_me->>'y')::int,
                      (v_tgt->>'x')::int, (v_tgt->>'y')::int);
    if v_dist > (v_me->>'rmax')::int then raise exception 'out of range'; end if;
    if not cn_los_clear(v_st, (v_me->>'x')::int, (v_me->>'y')::int,
                        (v_tgt->>'x')::int, (v_tgt->>'y')::int) then
      raise exception 'a tree is in the way';
    end if;
    for u in select * from jsonb_array_elements(v_st->'units') loop
      if u->>'id' = p_target then
        u := cn_afflict(u, 'poison', 'true'::jsonb);
        u := jsonb_set(u, '{hp}', to_jsonb((u->>'hp')::int - v_n));
        v_hits := v_hits || jsonb_build_object('id', u->>'id', 'dmg', v_n);
        v_swings := v_swings || jsonb_build_object(
          'k', 'hit', 'by', p_unit, 'at', u->>'id', 'dmg', v_n,
          'crit', false, 'counter', false, 'first', false, 'def', false,
          'why', 'poison');
      end if;
      if (u->>'hp')::int > 0 then v_out := v_out || u; end if;
    end loop;
    v_note := (v_me->>'name') || ' poisons ' || (v_tgt->>'name') || '.';

  -- ---- two tiles in a line, alight ----------------------------------------
  elsif v_kind = 'line_burn' then
    if v_tgt is null then raise exception 'that ability needs a target'; end if;
    v_dist := cn_cheb((v_me->>'x')::int, (v_me->>'y')::int,
                      (v_tgt->>'x')::int, (v_tgt->>'y')::int);
    if v_dist > (v_me->>'rmax')::int then raise exception 'out of range'; end if;
    -- The line runs from the caster THROUGH the target and one tile past.
    -- Two tiles, as the card says, and which two is decided by where you
    -- aim rather than by a compass direction nobody can see.
    v_dx := sign((v_tgt->>'x')::int - (v_me->>'x')::int);
    v_dy := sign((v_tgt->>'y')::int - (v_me->>'y')::int);
    for u in select * from jsonb_array_elements(v_st->'units') loop
      if ((u->>'x')::int = (v_tgt->>'x')::int and (u->>'y')::int = (v_tgt->>'y')::int)
         or ((u->>'x')::int = (v_tgt->>'x')::int + v_dx
             and (u->>'y')::int = (v_tgt->>'y')::int + v_dy) then
        u := cn_afflict(u, 'burn', 'true'::jsonb);
        u := jsonb_set(u, '{hp}', to_jsonb((u->>'hp')::int - v_n));
        v_hits := v_hits || jsonb_build_object('id', u->>'id', 'dmg', v_n);
        v_swings := v_swings || jsonb_build_object(
          'k', 'hit', 'by', p_unit, 'at', u->>'id', 'dmg', v_n,
          'crit', false, 'counter', false, 'first', false, 'def', false,
          'why', 'fire');
      end if;
      if (u->>'hp')::int > 0 then v_out := v_out || u; end if;
    end loop;
    v_note := (v_me->>'name') || ' sets two tiles alight for ' || v_n || '.';

  -- ---- putting something on the board -------------------------------------
  -- One branch for all three summoners. What appears is the card's
  -- `summonKind`, how hard it is to remove is cn_obj_hp's business, and what
  -- it does when trodden on is cn_move's -- so Fey, Mako and Lumea differ by
  -- one column and nothing else, and F5 changes the tornado without coming
  -- back here.
  elsif v_kind = 'summon' then
    v_what := v_me->>'summonKind';
    if v_what is null then raise exception 'that unit summons nothing'; end if;

    -- ONE ALIVE AT A TIME, asked before anything else so the refusal names
    -- the real reason rather than whatever the chosen tile happens to be.
    for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
      if e->>'by' = p_unit then raise exception 'that summon is still standing'; end if;
    end loop;

    v_tile := cn_tile_target(p_target);
    if v_tile is null then raise exception 'that ability needs a tile'; end if;
    if v_tile[1] < 0 or v_tile[2] < 0
       or v_tile[1] >= (v_st->'board'->>'w')::int
       or v_tile[2] >= (v_st->'board'->>'h')::int then
      raise exception 'that tile is not on the board';
    end if;
    v_dist := cn_cheb((v_me->>'x')::int, (v_me->>'y')::int, v_tile[1], v_tile[2]);
    if v_dist < 1 or v_dist > (v_me->>'rmax')::int then
      raise exception 'out of range';
    end if;
    if not cn_los_clear(v_st, (v_me->>'x')::int, (v_me->>'y')::int,
                        v_tile[1], v_tile[2]) then
      raise exception 'a tree is in the way';
    end if;

    for u in select * from jsonb_array_elements(v_st->'units') loop
      if (u->>'x')::int = v_tile[1] and (u->>'y')::int = v_tile[2] then
        raise exception 'that tile is taken';
      end if;
      v_out := v_out || u;
    end loop;
    for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
      if (e->>'x')::int = v_tile[1] and (e->>'y')::int = v_tile[2] then
        raise exception 'that tile is taken';
      end if;
      v_rocks := v_rocks || e;
    end loop;

    -- The damage rides on the OBJECT rather than being looked up from the
    -- summoner when somebody treads on it: Mako can be long dead by then.
    v_rocks := v_rocks || jsonb_build_object(
      'id', 's' || v_seq || ':' || p_unit, 'kind', v_what,
      'x', v_tile[1], 'y', v_tile[2],
      'hp', cn_obj_hp(v_what), 'maxHp', cn_obj_hp(v_what),
      'owner', p_side, 'by', p_unit, 'dmg', v_n);
    v_st := jsonb_set(v_st, '{obstacles}', v_rocks);
    v_note := (v_me->>'name') || ' sets down ' || cn_obj_name(v_what) || '.';


  -- ---- 0049: soft-coded, through the new engine --------------------------
  elsif v_kind = 'scripted' then
    declare v_ctx jsonb := jsonb_build_object('turnNumber', coalesce((v_st->>'turnNumber')::int, 1));
    begin
      if v_tgt is not null then v_ctx := v_ctx || jsonb_build_object('target', v_tgt); end if;
      if p_target is not null and left(p_target, 1) = '@' then
        v_ctx := v_ctx || jsonb_build_object('tile', p_target);
      end if;
      v_st := cn_run_effects(v_st, 'ON_ABILITY', v_me, v_ctx);
    end;
    v_out := v_st->'units';
    v_note := (v_me->>'name') || ' uses ' ||
      coalesce(nullif(btrim(split_part(v_me->>'ability', '—', 1)), ''), 'an ability') || '.';
  else
    raise exception 'that ability is not built yet: %', v_kind;
  end if;

  -- 0056: v_out was built from v_st->'units' inside each branch above and
  -- does not carry the abilityUses/abilityLastUsedTurn bump made to v_me
  -- near the top of this function (every branch's loop reads the STATE's
  -- own copy of this unit, not the local v_me variable) -- except the
  -- 'scripted' branch, which sets v_out := v_st->'units' AFTER
  -- cn_run_effects has already run against a v_st that never had the bump
  -- either. So the bump is applied once, here, uniformly for every kind,
  -- directly against v_out -- the one place all six branches' output
  -- actually converges, right before it becomes the new state.
  v_out := (
    select coalesce(jsonb_agg(
             case when q->>'id' = p_unit
                  then jsonb_set(jsonb_set(q, '{abilityUses}', v_me->'abilityUses'),
                                 '{abilityLastUsedTurn}', v_me->'abilityLastUsedTurn')
                  else q end), '[]'::jsonb)
      from jsonb_array_elements(v_out) q);
  v_st := jsonb_set(v_st, '{units}', v_out);
  v_st := cn_end_act(v_st, p_unit);
  v_st := state_log(v_st, v_note);
  if v_felled then v_st := state_log(v_st, 'A tree comes down.'); end if;

  -- The board draws from `fx` the way it does after an exchange. `hits` is the
  -- shape an ability needs and an attack never did: one actor, any number of
  -- receivers. A client that does not know the field ignores it and draws the
  -- new board, which is the right thing for it to do.
  v_st := jsonb_set(v_st, '{fx}', jsonb_build_object(
    'seq', v_seq, 'kind', 'ability', 'atk', p_unit, 'tgt', p_target,
    'why', v_kind, 'hits', v_hits, 'swings', v_swings,
    'dmg', 0, 'heal', 0, 'counter', 0, 'burnAtk', 0, 'burnTgt', 0,
    'killedTgt', false, 'killedAtk', false, 'newBurn', false,
    'cured', false, 'parry', false, 'tree', false), true);

  update public.matches
     set state = v_st,
         turn_deadline = turn_deadline
           + (cn_cine_ms(v_swings) || ' milliseconds')::interval,
         updated_at = now()
   where id = m.id returning * into m;
  return m;
end $function$
;
