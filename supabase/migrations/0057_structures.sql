-- =============================================================================
-- 0057 -- STRUCTURES: a brand-new content type, with its own Mad-Libs
-- sentence builder in the Admin Menu, and real board presence.
--
-- Nothing named "structure" existed anywhere in this codebase before this
-- file -- the closest relative is the SUMMON system (0035-0037: Fey's wall,
-- Mako's trap, Lumea's tornado), which is a fixed, hard-coded vocabulary of
-- three kinds living entirely inside cn_ability's 'summon' branch. Jared's
-- own answer, from the clarifying round before this was built: Structures
-- are a brand-new, admin-authorable content type with their OWN tables,
-- not a reskin of the summon system -- so this file adds `structures` (the
-- catalog: what a structure IS) and `structure_effects` (a Mad-Libs
-- sentence builder for it, mirroring `card_effects` column for column) as
-- their own thing, while making them interoperate with the EXISTING board
-- machinery wherever that machinery is already generic:
--
--   - A live structure IS an obstacle -- the same `state.obstacles` array a
--     tree, a wall, a trap or a tornado already lives in. This is not a
--     simplification made for convenience: cn_attack's `v_tree` branch,
--     cn_reach's/cn_los_clear's solidity check, and cn_move's occupancy
--     check are ALL ALREADY GENERIC over "any obstacle, whatever its
--     `kind`" -- they were written that way in 0035 for a reason 0057 gets
--     to reuse for free. A structure is ATTACKABLE, and DESTROYED at 0 hp,
--     through the exact same code path a tree already takes -- no change
--     to cn_attack's combat math at all, only one additive hook (below)
--     for what happens AFTER a structure specifically is destroyed.
--
--   - `cn_obj_kind`/`cn_obj_solid`/`cn_obj_hp`/`cn_obj_name` (0035) grow a
--     fallback to the `structures` table for any `kind` their hard-coded
--     four (tree/wall/bomb/tornado) don't recognise. Every existing call
--     with a known kind is byte-identical in behaviour; only a genuinely
--     new structure kind ever reaches the new branch.
--
--   - `card_effects` gains one new action, CREATE_STRUCTURE, and the one
--     column it needs (`structure_slug`) to say which catalog row to
--     place. This is how a CARD's own ability puts a structure on the
--     board -- the Mad-Libs "create structure [open structure sub-menu]"
--     action from the developer's spec.
--
--   - Two triggers a UNIT never has, because they are not about a unit:
--     ON_STEPPED_ON (dispatched from cn_spring, the same function that has
--     handled "something happened when I landed on this tile" since 0036)
--     and ON_DESTROYED (dispatched from cn_attack, additively, exactly
--     where 0049 already fires ON_DEATH for the same reason). Plus
--     ON_PLACE (the moment cn_create_structure puts it down) and PASSIVE,
--     for symmetry with cards -- accepted by the schema; PASSIVE compiles
--     to nothing today (there is no legacy stat system for a structure to
--     compile into, unlike a card's `slippery`/`parries`/etc) and is left
--     an honest, documented no-op rather than invented a use for.
--
--   - One target_selector a unit's own sentences never need: INVOKER --
--     whoever placed this structure (`obstacle.by`), resolved even if
--     that unit has since died or left the board (falls back to nobody,
--     silently, exactly like every other resolver in this engine when its
--     target has nothing to point at). WHOEVER_STEPPED is ON_STEPPED_ON's
--     own equivalent -- the unit that triggered THIS firing, which INVOKER
--     is not: Mako's summoner and the enemy who just stepped on his trap
--     are almost never the same unit.
--
-- Every splice below (cn_army, cn_effect_apply_action, cn_spring,
-- cn_attack) was fetched fresh via pg_get_functiondef from this exact
-- checkout (0001-0056 applied) immediately before writing this file, and
-- each insertion was verified by a Python round-trip -- removing the
-- inserted text reproduces the fetched original byte-for-byte -- before
-- being pasted in. See project_status.md section 7, "Splice, never
-- rewrite from memory."
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. structures -- the catalog. What a structure IS.
-- ---------------------------------------------------------------------------

create table if not exists public.structures (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null default '',
  hp int not null default 20 check (hp between 1 and 200),
  -- Mirrors cn_obj_solid's tree/wall (true) vs bomb/tornado (false) split:
  -- does this structure block feet and arrows, or can a unit walk onto its
  -- tile (which is what "stepped on" even means for a structure -- a wall
  -- can be attacked but never stepped on, because nothing can stand where
  -- it stands).
  blocks_movement boolean not null default false,
  accent text not null default '#2f4bff' check (accent ~ '^#[0-9a-fA-F]{6}$'),
  art_url text,
  is_active boolean not null default true,
  sort int not null default 99,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.structures enable row level security;

create policy "structures readable by authenticated"
  on public.structures for select to authenticated using (true);

create policy "admins write structures"
  on public.structures for all to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin))
  with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin));

create or replace function public.cn_touch_structures()
returns trigger language plpgsql set search_path = public as $$
begin new.updated_at := now(); return new; end
$$;

drop trigger if exists structures_touch on public.structures;
create trigger structures_touch
  before update on public.structures
  for each row execute function public.cn_touch_structures();

-- ---------------------------------------------------------------------------
-- 2. structure_effects -- the Mad-Libs sentence builder's rows, for a
--    structure. Column-for-column the same shape as card_effects, with the
--    trigger/target vocabulary a structure actually needs rather than a
--    unit's.
-- ---------------------------------------------------------------------------

create table if not exists public.structure_effects (
  id uuid primary key default gen_random_uuid(),
  structure_id uuid not null references public.structures(id) on delete cascade,
  sort int not null default 0,
  group_id uuid not null default gen_random_uuid(),

  trigger text not null check (trigger in (
    'ON_STEPPED_ON', 'ON_DESTROYED', 'ON_PLACE', 'PASSIVE'
  )),

  target_selector text not null check (target_selector in (
    'INVOKER', 'WHOEVER_STEPPED', 'ALL_ALLIES', 'ALL_ENEMIES',
    'NEARBY_ALLIES', 'ADJACENT_UNITS', 'NEAREST_ENEMY',
    'LOWEST_HP_ENEMY', 'HIGHEST_HP_ENEMY', 'LOWEST_HP_ALLY', 'HIGHEST_HP_ALLY',
    'RANDOM_ENEMY_IN_RANGE', 'RANDOM_ALLY', 'ALLIES_IN_LINE', 'ENEMIES_IN_LINE'
  )),

  action text not null check (action in (
    'DEAL_DAMAGE', 'HEAL', 'APPLY_STATUS', 'MODIFY_STAT', 'PUSH_BACK',
    'REMOVE_STATUS', 'GRANT_EXTRA_ACTIVATION'
  )),
  value int,
  status text check (status is null or status in ('NONE', 'BURNING', 'STUN', 'POISON', 'ANY', 'ALL')),
  stat_name text,
  conditions jsonb not null default '[]'::jsonb,

  duration_kind text check (duration_kind is null or duration_kind in ('THIS_TURN', 'FOR_TURNS', 'UNTIL_REMOVED')),
  duration_turns int check (duration_turns is null or duration_turns between 2 and 5),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint structure_effects_status_action_needs_status
    check (action not in ('APPLY_STATUS', 'REMOVE_STATUS') or status is not null),
  constraint structure_effects_modify_stat_needs_name
    check (action <> 'MODIFY_STAT' or stat_name is not null),
  constraint structure_effects_duration_turns_needs_kind
    check (duration_turns is null or duration_kind = 'FOR_TURNS')
);

create index if not exists structure_effects_structure_id_idx
  on public.structure_effects (structure_id, sort);

alter table public.structure_effects enable row level security;

create policy "structure effects readable by authenticated"
  on public.structure_effects for select to authenticated using (true);

create policy "admins write structure effects"
  on public.structure_effects for all to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin))
  with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin));

create or replace function public.cn_touch_structure_effects()
returns trigger language plpgsql set search_path = public as $$
begin new.updated_at := now(); return new; end
$$;

drop trigger if exists structure_effects_touch on public.structure_effects;
create trigger structure_effects_touch
  before update on public.structure_effects
  for each row execute function public.cn_touch_structure_effects();

-- ---------------------------------------------------------------------------
-- 3. card_effects grows CREATE_STRUCTURE and the column it needs.
-- ---------------------------------------------------------------------------

alter table public.card_effects add column if not exists structure_slug text
  references public.structures(slug);

alter table public.card_effects drop constraint if exists card_effects_action_check;
alter table public.card_effects add constraint card_effects_action_check
  check (action = any (array[
    'DEAL_DAMAGE', 'HEAL', 'APPLY_STATUS', 'MODIFY_STAT', 'PUSH_BACK',
    'DRAW_CARD', 'REMOVE_STATUS', 'GRANT_EXTRA_ACTIVATION', 'SUMMON_OBJECT',
    'TELEPORT_SELF', 'SWAP_POSITIONS', 'REVIVE', 'COPY_STAT_FROM_TARGET',
    'REFLECT_DAMAGE_PCT', 'CREATE_STRUCTURE'
  ]));

alter table public.card_effects drop constraint if exists card_effects_create_structure_needs_slug;
alter table public.card_effects add constraint card_effects_create_structure_needs_slug
  check (action <> 'CREATE_STRUCTURE' or structure_slug is not null);

comment on column public.card_effects.structure_slug is
  'Which `structures` catalog row a CREATE_STRUCTURE row places. Read only '
  'by cn_create_structure; every other action leaves this null.';

-- ---------------------------------------------------------------------------
-- 4. cn_obj_kind/cn_obj_solid/cn_obj_hp/cn_obj_name grow a `structures`
--    fallback. Every existing call site (0035-0055) passes one of the four
--    hard-coded kinds and is completely unaffected -- the CASE branches
--    below are checked first, exactly as before, and the fallback is only
--    ever reached for a `kind` none of the four hard-coded ones matches.
-- ---------------------------------------------------------------------------

create or replace function public.cn_obj_solid(p_kind text)
returns boolean language sql stable set search_path = public as $$
  select case
    when p_kind in ('tree', 'wall') then true
    when p_kind in ('bomb', 'tornado') then false
    else coalesce((select blocks_movement from public.structures where slug = p_kind), false)
  end
$$;

create or replace function public.cn_obj_hp(p_kind text)
returns int language sql stable set search_path = public as $$
  select case
    when p_kind = 'tree' then 30
    when p_kind = 'wall' then 20
    when p_kind = 'bomb' then 15
    when p_kind = 'tornado' then 25
    else (select hp from public.structures where slug = p_kind)
  end
$$;

create or replace function public.cn_obj_name(p_kind text)
returns text language sql stable set search_path = public as $$
  select case
    when p_kind = 'tree' then 'a tree'
    when p_kind = 'wall' then 'a cursed wall'
    when p_kind = 'bomb' then 'a trap'
    when p_kind = 'tornado' then 'a tornado'
    else coalesce((select name from public.structures where slug = p_kind), 'a structure')
  end
$$;

-- ---------------------------------------------------------------------------
-- 5. THE NEW GENERIC EXECUTOR, for a structure instead of a unit. Reuses
--    cn_effect_condition_met/cn_effect_conditions_met and
--    cn_effect_apply_action UNCHANGED (both already operate on units by
--    id, which is all a structure's effect ever targets -- nothing in
--    0049's action vocabulary writes back to the STRUCTURE itself).
--    Deliberately NOT snapshotted the way a card's abilityScript is: a
--    live structure instance is a transient obstacle, exactly like a
--    trap's damage or a wall's hp already are (cn_obj_hp is read live,
--    every time, and always has been) -- so structure_effects is read
--    live too, and an admin edit to a structure's effects takes hold on
--    every copy of it already standing on a board, the same as retuning a
--    trap's damage always has.
-- ---------------------------------------------------------------------------

create or replace function public.cn_resolve_structure_targets(
  v_st jsonb, p_selector text, p_structure jsonb, p_context jsonb
) returns jsonb
language plpgsql set search_path = public as $$
declare
  v_owner text := p_structure->>'owner';
  v_fake_unit jsonb;
begin
  if p_selector = 'INVOKER' then
    return case when exists (
             select 1 from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) u
              where u->>'id' = p_structure->>'by')
           then jsonb_build_array(p_structure->>'by') else '[]'::jsonb end;
  elsif p_selector = 'WHOEVER_STEPPED' then
    return case when p_context->'unit'->>'id' is not null
                then jsonb_build_array(p_context->'unit'->>'id') else '[]'::jsonb end;
  end if;

  -- Every other selector this table offers is one cn_resolve_targets
  -- already knows how to answer for a UNIT standing at a given x/y with a
  -- given owner -- which is exactly what a structure is, for this
  -- purpose. Building a one-field-used fake unit is less code and less
  -- risk than a second copy of eleven target-selector branches that would
  -- only ever drift from the real ones.
  v_fake_unit := jsonb_build_object(
    'id', p_structure->>'id', 'owner', coalesce(v_owner, ''),
    'x', p_structure->'x', 'y', p_structure->'y');
  return cn_resolve_targets(v_st, p_selector, v_fake_unit, p_context);
end
$$;

create or replace function public.cn_run_structure_effects(
  v_st jsonb, p_trigger text, p_structure jsonb, p_context jsonb
) returns jsonb
language plpgsql set search_path = public as $$
declare
  v_sid uuid; v_row record; v_targets jsonb; v_tid text; v_ctx jsonb;
begin
  select id into v_sid from public.structures where slug = cn_obj_kind(p_structure);
  -- No catalog row at all -- a tree, or a legacy bomb/wall/tornado summon.
  -- This is the whole reason every pre-0057 obstacle kind is unaffected by
  -- either of this function's two call sites (cn_spring, cn_attack).
  if v_sid is null then return v_st; end if;

  v_ctx := coalesce(p_context, '{}'::jsonb) || jsonb_build_object('self', p_structure);

  for v_row in
    select * from public.structure_effects
     where structure_id = v_sid and trigger = p_trigger
     order by sort
  loop
    if not cn_effect_conditions_met(coalesce(v_row.conditions, '[]'::jsonb), v_ctx) then
      continue;
    end if;
    v_targets := cn_resolve_structure_targets(v_st, v_row.target_selector, p_structure, v_ctx);
    for v_tid in select * from jsonb_array_elements_text(coalesce(v_targets, '[]'::jsonb)) loop
      v_st := cn_effect_apply_action(v_st,
        jsonb_build_object('action', v_row.action, 'value', v_row.value,
                            'status', v_row.status, 'stat_name', v_row.stat_name),
        p_structure, v_tid, v_ctx);
    end loop;
  end loop;

  return v_st;
end
$$;

-- ---------------------------------------------------------------------------
-- 6. Placing one, and noticing when a unit lands on one. Both new --
--    nothing before 0057 needed either.
-- ---------------------------------------------------------------------------

/**
 * The Range Mad-Libs category, for CREATE_STRUCTURE specifically: "in this
 * card's range" / "in range 1-4" / "anywhere" / "where player chooses" all
 * describe WHERE THE TILE MAY BE, and every one of them already reduces to
 * the same check once the player has actually picked a tile -- is it on
 * the board, is it within however far this effect's range reaches, is
 * line of sight clear. This function does not attempt to validate range
 * against range_kind/range_min/range_max (see 0056's own header on why
 * FIXED_RANGE is authored but not yet enforced) -- it validates the two
 * things that are always true regardless of range: the tile exists and is
 * empty. An out-of-range placement is a client-side concern until the
 * range plumbing above lands.
 */
create or replace function public.cn_create_structure(
  v_st jsonb, p_effect jsonb, p_unit jsonb, p_target_id text
) returns jsonb
language plpgsql set search_path = public as $$
declare
  v_slug text := p_effect->>'structure_slug';
  v_row public.structures;
  v_tile int[]; v_rocks jsonb := '[]'::jsonb; e jsonb;
begin
  if v_slug is null then return v_st; end if;
  select * into v_row from public.structures where slug = v_slug and is_active;
  if v_row.id is null then return v_st; end if;

  v_tile := cn_tile_target(p_target_id);
  if v_tile is null then return v_st; end if;
  if v_tile[1] < 0 or v_tile[2] < 0
     or v_tile[1] >= coalesce((v_st->'board'->>'w')::int, 0)
     or v_tile[2] >= coalesce((v_st->'board'->>'h')::int, 0) then
    return v_st;
  end if;
  if exists (select 1 from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) u
              where (u->>'x')::int = v_tile[1] and (u->>'y')::int = v_tile[2])
     or exists (select 1 from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) o
              where (o->>'x')::int = v_tile[1] and (o->>'y')::int = v_tile[2]) then
    return v_st;
  end if;

  for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
    v_rocks := v_rocks || e;
  end loop;
  v_rocks := v_rocks || jsonb_build_object(
    'id', gen_random_uuid()::text, 'kind', v_slug,
    'x', v_tile[1], 'y', v_tile[2],
    'hp', v_row.hp, 'maxHp', v_row.hp,
    'owner', p_unit->>'owner', 'by', p_unit->>'id');
  v_st := jsonb_set(v_st, '{obstacles}', v_rocks);
  v_st := state_log(v_st, (p_unit->>'name') || ' sets down ' || cn_obj_name(v_slug) || '.');

  -- ON_PLACE, the moment this exists -- the structure's own equivalent of
  -- ON_PLAY, fired against the row this function just appended.
  v_st := cn_run_structure_effects(v_st, 'ON_PLACE',
    v_rocks->(jsonb_array_length(v_rocks) - 1),
    jsonb_build_object('placedBy', p_unit->>'id'));
  return v_st;
end
$$;

/**
 * cn_spring's structures half -- see this migration's header for why it is
 * dispatched from there rather than from cn_move directly (cn_spring is
 * the one place "something happened when I landed here" has lived since
 * 0036, and a second copy of that idea in cn_move would be the exact
 * "two copies drift apart" mistake 0036's own header warns about).
 */
create or replace function public.cn_step_on_structure(p_st jsonb, p_unit jsonb)
returns jsonb
language plpgsql set search_path = public as $$
declare v_obj jsonb;
begin
  select e into v_obj from jsonb_array_elements(coalesce(p_st->'obstacles', '[]'::jsonb)) e
   where (e->>'x')::int = (p_unit->>'x')::int and (e->>'y')::int = (p_unit->>'y')::int
     and exists (select 1 from public.structures s where s.slug = cn_obj_kind(e))
   limit 1;
  if v_obj is null then return p_st; end if;
  return cn_run_structure_effects(p_st, 'ON_STEPPED_ON', v_obj,
    jsonb_build_object('unit', p_unit));
end
$$;

-- ---------------------------------------------------------------------------
-- 7. admin_delete_structure -- the same shape as admin_delete_card
--    (0046/0055): gated on plain is_admin (matching structures' own write
--    policy above, same reasoning 0039 gave for leaving cards on the
--    looser gate rather than cn_is_super_admin()), refused only while the
--    structure is standing on the board in a match that has not finished
--    -- there is no deck/kingdom reference to check, because nothing
--    outside a live match ever points at a structure by slug.
-- ---------------------------------------------------------------------------

create or replace function public.admin_delete_structure(p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_slug text; v_name text;
begin
  if not exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin) then
    raise exception 'only an admin can delete a structure';
  end if;
  select slug, name into v_slug, v_name from public.structures where id = p_id;
  if not found then raise exception 'no structure with that id exists'; end if;

  if exists (
    select 1 from public.matches m
     where m.status <> 'finished'
       and exists (select 1 from jsonb_array_elements(coalesce(m.state->'obstacles', '[]'::jsonb)) o
                    where o->>'kind' = v_slug)
  ) then
    raise exception '% is standing on the board in a match that has not finished', v_name;
  end if;

  delete from public.structures where id = p_id;
end
$$;

-- ---------------------------------------------------------------------------
-- 8. THE SPLICES -- cn_army, cn_effect_apply_action, cn_spring, cn_attack.
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
    -- 0057: structure_slug rides along too -- CREATE_STRUCTURE is the only
    -- action that reads it (cn_effect_apply_action), and every other action
    -- simply carries a null it never looks at.
    select coalesce(jsonb_agg(jsonb_build_object(
             'trigger', ce.trigger, 'target_selector', ce.target_selector,
             'action', ce.action, 'value', ce.value, 'status', ce.status,
             'stat_name', ce.stat_name, 'conditions', ce.conditions,
             'structure_slug', ce.structure_slug,
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

CREATE OR REPLACE FUNCTION public.cn_effect_apply_action(v_st jsonb, p_effect jsonb, p_unit jsonb, p_target_id text, p_context jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  v_action text := p_effect->>'action';
  v_value int := coalesce((p_effect->>'value')::int, 0);
  v_status text := p_effect->>'status';
  v_stat text := p_effect->>'stat_name';
  v_self_id text := p_unit->>'id';
  v_self jsonb; v_target jsonb; v_out jsonb; u jsonb;
  v_tile int[]; v_dx int; v_dy int; v_nx int; v_ny int; v_occupied boolean;
  v_field text; v_copy_val jsonb;
  v_num_field_map jsonb := '{
    "HP": "hp", "MOV": "mov", "RMIN": "rmin", "RMAX": "rmax",
    "CRMIN": "crmin", "CRMAX": "crmax", "POWER": "pow",
    "PARRY_PCT": "parryPct", "CRIT_PCT": "critPct", "TWICE_PCT": "twicePct",
    "LIFESTEAL_PCT": "lifestealPct", "REGEN_PCT": "regenPct",
    "VS_POISONED_BONUS": "vsPoisoned"
  }'::jsonb;
  v_bool_field_map jsonb := '{
    "SLIPPERY": "slippery", "PARRY_ALL": "parryAll", "STUNS_ON_HIT": "stuns",
    "POISONS_ADJACENT": "poisonsAdj", "CURES_BURN": "cures", "BLOOMS": "blooms",
    "SNEAKS": "sneaks", "FLIES": "flies", "TRAMPLES": "tramples",
    "PARRIES": "parries", "BURNS": "burns", "HEALS": "heals"
  }'::jsonb;
begin
  if p_target_id is null or p_target_id = '' then return v_st; end if;

  if left(p_target_id, 1) = '@' then
    -- 0057: CREATE_STRUCTURE reads a tile like TELEPORT_SELF always has,
    -- but does something else with it entirely -- see cn_create_structure
    -- for the tile/occupancy checks and what actually gets placed.
    if v_action = 'CREATE_STRUCTURE' then
      return cn_create_structure(v_st, p_effect, p_unit, p_target_id);
    end if;
    if v_action <> 'TELEPORT_SELF' then return v_st; end if;
    v_tile := cn_tile_target(p_target_id);
    if v_tile is null then return v_st; end if;
    v_out := '[]'::jsonb;
    for u in select * from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) loop
      if u->>'id' = v_self_id then
        u := jsonb_set(jsonb_set(u, '{x}', to_jsonb(v_tile[1])), '{y}', to_jsonb(v_tile[2]));
      end if;
      v_out := v_out || u;
    end loop;
    return jsonb_set(v_st, '{units}', v_out);
  end if;

  -- REVIVE, REFLECT_DAMAGE_PCT, SUMMON_OBJECT and DRAW_CARD are documented
  -- no-ops -- see this migration's header and the card_effects.action
  -- column comment for exactly why each one is left unbuilt rather than
  -- guessed at.
  if v_action in ('REVIVE', 'REFLECT_DAMAGE_PCT', 'SUMMON_OBJECT', 'DRAW_CARD') then
    return v_st;
  end if;

  for u in select * from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) loop
    if u->>'id' = v_self_id then v_self := u; end if;
    if u->>'id' = p_target_id then v_target := u; end if;
  end loop;
  if v_target is null then return v_st; end if;

  if v_action = 'COPY_STAT_FROM_TARGET' and v_stat is not null then
    if v_num_field_map ? v_stat then
      v_field := v_num_field_map->>v_stat;
      v_copy_val := coalesce(v_target->v_field, to_jsonb(0));
    elsif v_bool_field_map ? v_stat then
      v_field := v_bool_field_map->>v_stat;
      v_copy_val := coalesce(v_target->v_field, to_jsonb(false));
    end if;
  end if;

  v_out := '[]'::jsonb;
  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_target_id and v_action = 'DEAL_DAMAGE' then
      u := jsonb_set(u, '{hp}', to_jsonb((u->>'hp')::int - v_value));

    elsif u->>'id' = p_target_id and v_action = 'HEAL' then
      u := jsonb_set(u, '{hp}', to_jsonb(least((u->>'maxHp')::int, (u->>'hp')::int + v_value)));

    elsif u->>'id' = p_target_id and v_action = 'APPLY_STATUS' then
      if v_status = 'BURNING' then u := cn_afflict(u, 'burn', 'true'::jsonb);
      elsif v_status = 'POISON' then u := cn_afflict(u, 'poison', 'true'::jsonb);
      elsif v_status = 'STUN' then u := cn_afflict(u, 'stun', to_jsonb(greatest(1, v_value)));
      end if;

    elsif u->>'id' = p_target_id and v_action = 'REMOVE_STATUS' then
      if v_status in ('BURNING', 'ALL') then u := cn_afflict(u, 'burn', 'false'::jsonb); end if;
      if v_status in ('POISON', 'ALL') then u := cn_afflict(u, 'poison', 'false'::jsonb); end if;
      if v_status in ('STUN', 'ALL') then u := cn_afflict(u, 'stun', '0'::jsonb); end if;

    elsif u->>'id' = p_target_id and v_action = 'MODIFY_STAT' and v_stat is not null then
      if v_num_field_map ? v_stat then
        v_field := v_num_field_map->>v_stat;
        u := jsonb_set(u, array[v_field], to_jsonb(coalesce((u->>v_field)::int, 0) + v_value));
      elsif v_bool_field_map ? v_stat then
        v_field := v_bool_field_map->>v_stat;
        u := jsonb_set(u, array[v_field], to_jsonb(v_value <> 0));
      end if;

    elsif u->>'id' = p_target_id and v_action = 'COPY_STAT_FROM_TARGET' and v_field is not null then
      u := jsonb_set(u, array[v_field], v_copy_val);

    elsif u->>'id' = p_target_id and v_action = 'PUSH_BACK' then
      v_dx := sign((u->>'x')::int - (p_unit->>'x')::int);
      v_dy := sign((u->>'y')::int - (p_unit->>'y')::int);
      if v_dx = 0 and v_dy = 0 then v_dx := 1; end if;
      v_nx := (u->>'x')::int + v_dx;
      v_ny := (u->>'y')::int + v_dy;
      v_occupied := v_nx < 0 or v_ny < 0
        or v_nx >= (v_st->'board'->>'w')::int or v_ny >= (v_st->'board'->>'h')::int
        or exists (select 1 from jsonb_array_elements(v_st->'units') q
                     where (q->>'x')::int = v_nx and (q->>'y')::int = v_ny)
        or exists (select 1 from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) q
                     where (q->>'x')::int = v_nx and (q->>'y')::int = v_ny);
      if not v_occupied then
        u := jsonb_set(jsonb_set(u, '{x}', to_jsonb(v_nx)), '{y}', to_jsonb(v_ny));
      end if;

    elsif (u->>'id' = v_self_id or u->>'id' = p_target_id) and v_action = 'SWAP_POSITIONS' then
      if u->>'id' = v_self_id then
        u := jsonb_set(jsonb_set(u, '{x}', v_target->'x'), '{y}', v_target->'y');
      else
        u := jsonb_set(jsonb_set(u, '{x}', v_self->'x'), '{y}', v_self->'y');
      end if;
    end if;

    if (u->>'hp')::int > 0 then v_out := v_out || u; end if;
  end loop;
  v_st := jsonb_set(v_st, '{units}', v_out);

  if v_action = 'GRANT_EXTRA_ACTIVATION' and p_target_id = v_self_id then
    v_st := jsonb_set(v_st, '{acts}',
      to_jsonb(greatest(0, coalesce((v_st->>'acts')::int, 0) - greatest(1, v_value))));
  end if;

  return v_st;
end
$function$
;

CREATE OR REPLACE FUNCTION public.cn_spring(p_st jsonb, p_unit text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
declare
  v_me jsonb; v_trap jsonb; v_hurt int; v_dead boolean;
  u jsonb; e jsonb; v_out jsonb := '[]'::jsonb; v_rocks jsonb := '[]'::jsonb;
begin
  for u in select * from jsonb_array_elements(p_st->'units') loop
    if u->>'id' = p_unit then v_me := u; end if;
  end loop;
  if v_me is null then return p_st; end if;

  v_trap := cn_trap_at(p_st, (v_me->>'x')::int, (v_me->>'y')::int);

  -- 0057: a STRUCTURE, if the tile this unit just landed on carries an
  -- obstacle whose kind matches a row in the new `structures` catalog.
  -- Dispatched before the early return just below, since a bomb-trap and a
  -- structure are mutually exclusive (one obstacle per tile) and this
  -- function's whole shape used to be "there was nothing here, so do
  -- nothing" -- true only of a missing bomb until now. cn_step_on_structure
  -- is a no-op for every obstacle kind that predates 0057 (tree/wall/bomb/
  -- tornado all have no `structures` row), so a match that never touches
  -- the new content type is completely unaffected.
  p_st := cn_step_on_structure(p_st, v_me);

  if v_trap is null then return p_st; end if;

  v_hurt := coalesce((v_trap->>'dmg')::int, 0);
  v_dead := (v_me->>'hp')::int - v_hurt <= 0;

  for u in select * from jsonb_array_elements(p_st->'units') loop
    if u->>'id' = p_unit then
      u := jsonb_set(u, '{hp}', to_jsonb((u->>'hp')::int - v_hurt));
      if v_dead then continue; end if;
    end if;
    v_out := v_out || u;
  end loop;
  for e in select * from jsonb_array_elements(coalesce(p_st->'obstacles', '[]'::jsonb)) loop
    if e->>'id' <> v_trap->>'id' then v_rocks := v_rocks || e; end if;
  end loop;

  p_st := jsonb_set(p_st, '{units}', v_out);
  p_st := jsonb_set(p_st, '{obstacles}', v_rocks);
  p_st := state_log(p_st, (v_me->>'name') || ' steps on a trap for ' || v_hurt
    || case when v_dead then ' -- destroyed.' else '.' end);
  -- The board animates from `fx`, and a trap is one blow from nobody to
  -- somebody. `atk` is null rather than the summoner: the summoner did not
  -- act this turn and may not be alive.
  p_st := jsonb_set(p_st, '{fx}', jsonb_build_object(
    'seq', coalesce((p_st->'fx'->>'seq')::int, 0) + 1,
    'kind', 'ability', 'why', 'trap', 'atk', null, 'tgt', p_unit,
    'hits', jsonb_build_array(jsonb_build_object('id', p_unit, 'dmg', v_hurt)),
    'swings', '[]'::jsonb,
    'dmg', v_hurt, 'heal', 0, 'counter', 0, 'burnAtk', 0, 'burnTgt', 0,
    'killedTgt', v_dead, 'killedAtk', false, 'newBurn', false,
    'cured', false, 'parry', false, 'tree', false), true);
  return p_st;
end $function$
;

CREATE OR REPLACE FUNCTION public.cn_attack(p_match uuid, p_side text, p_unit text, p_target text)
 RETURNS matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  m public.matches; v_other text; v_st jsonb; u jsonb; e jsonb;
  v_atk jsonb; v_tgt jsonb; v_tree jsonb;
  v_out jsonb := '[]'::jsonb; v_rocks jsonb := '[]'::jsonb;
  v_dist int; v_dmg int := 0; v_heal int := 0;
  v_tgt_hp int; v_atk_hp int; v_counter int := 0; v_riposte int := 0;
  v_burn_atk int := 0; v_burn_tgt int := 0; v_new_burn boolean := false;
  v_cured boolean := false;
  v_answers boolean := false; v_parry boolean := false;
  v_reaches_back boolean := false; v_tgt_reaches boolean := false;
  v_hit_crit boolean := false;
  v_crit boolean := false; v_crit_counter boolean := false;
  v_chain int := 0; v_parries int := 0;
  v_swing_is_atk boolean := true; v_is_counter boolean := false;
  v_strk jsonb; v_recv jsonb; v_hit int; v_parried boolean;
  v_notes text[] := '{}';
  v_swings jsonb := '[]'::jsonb;
  v_bloom jsonb := '[]'::jsonb; v_d2 int; v_got int; v_heal_roll int := 0;
  v_killed_tgt boolean := false; v_killed_atk boolean := false;
  v_ally boolean := false; v_foes int := 0; v_mine int := 0; v_win text;
  v_crown text; v_note text;
  -- F3: a blow the mist ate, and Himanta's second swing.
  v_missed boolean := false; v_hit2 int; v_crit2 boolean;
  -- F2: what a burn costs the one swinging, and what a blow leaves behind.
  v_cost int; v_steal int;
  -- 0045: crit/parry counters, single-class team check, and bot-win credit.
  v_elem jsonb; v_by text; v_by_owner text; v_by_uid uuid;
  v_win_uid uuid; v_win_count int; v_win_roles text[];
  -- 0049: new-engine attack hooks.
  v_ce_unit jsonb; v_ce_id text;
begin
  select * into m from public.matches where id = p_match for update;
  v_other := case when p_side = 'host' then 'guest' else 'host' end;
  v_st := m.state;

  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit   then v_atk := u; end if;
    if u->>'id' = p_target then v_tgt := u; end if;
  end loop;
  for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
    if e->>'id' = p_target then v_tree := e; end if;
  end loop;

  -- THE SWAMP, applied once, here. v_strk and v_recv are assigned from these
  -- two further down, so every rule in the exchange -- the parry, the second
  -- strike, the cyclone, the lifesteal, the bonus against poison -- reads a
  -- silenced fighter without any of them being told about silence.
  v_atk := cn_awake(v_st, v_atk);
  v_tgt := cn_awake(v_st, v_tgt);

  if v_atk is null then raise exception 'no such unit'; end if;
  if v_tgt is null and v_tree is null then raise exception 'no such target'; end if;
  if v_atk->>'owner' <> p_side then raise exception 'that is not your unit'; end if;
  if (v_atk->>'acted')::boolean then raise exception 'that unit already acted'; end if;
  -- A cyclone knocks the sword out of your hand, not your feet out from
  -- under you: a stunned unit may still walk, and nothing here stops it.
  if cn_stunned(v_atk) then raise exception 'that unit is stunned'; end if;

  -- Striking spends an action whether or not this unit moved first. If it
  -- moved, it is already the active unit and this costs nothing further.
  v_st := cn_begin_act(v_st, p_side, p_unit);

  if v_tree is not null then
    v_dist := cn_cheb((v_atk->>'x')::int, (v_atk->>'y')::int,
                      (v_tree->>'x')::int, (v_tree->>'y')::int);
  else
    -- FRIENDLY FIRE IS ALLOWED. The refusal that used to be here was total
    -- in practice -- since 0033 no card carries `heals` -- so "you may only
    -- point this at an ally if you mend" meant "you may never point this at
    -- an ally". Jared's rule is that you may.
    v_ally := (v_tgt->>'owner' = p_side);
    v_dist := cn_cheb((v_atk->>'x')::int, (v_atk->>'y')::int,
                      (v_tgt->>'x')::int, (v_tgt->>'y')::int);
  end if;

  if v_dist < (v_atk->>'rmin')::int then raise exception 'too close for that unit'; end if;
  if v_dist > (v_atk->>'rmax')::int then raise exception 'out of range'; end if;
  if not cn_los_clear(v_st, (v_atk->>'x')::int, (v_atk->>'y')::int,
                      coalesce((v_tgt->>'x')::int, (v_tree->>'x')::int),
                      coalesce((v_tgt->>'y')::int, (v_tree->>'y')::int)) then
    raise exception 'a tree is in the way';
  end if;

  v_atk_hp := (v_atk->>'hp')::int;

  -- A MEND is what happens when a healer points at an ally. A healer is the
  -- only thing this branch has ever been for, and since 0033 there is not one
  -- on the roster -- so this is kept, unreachable, rather than deleted: it is
  -- the whole of how mending works and the day a card carries `heals` again it
  -- has to work the same way it always did.
  if v_ally and coalesce((v_atk->>'heals')::boolean, false) then
    -- Mending is not an exchange: no crit, no parry, no answer.
    v_heal_roll := cn_roll((v_atk->>'dmin')::int, (v_atk->>'dmax')::int);
    v_heal := v_heal_roll;
    v_tgt_hp := least((v_tgt->>'maxHp')::int, (v_tgt->>'hp')::int + v_heal);
    v_heal := v_tgt_hp - (v_tgt->>'hp')::int;
    v_cured := coalesce((v_atk->>'cures')::boolean, false)
               and cn_has(v_tgt, 'burn');
    if v_cured then v_tgt := cn_afflict(v_tgt, 'burn', 'false'::jsonb); end if;
    v_note := (v_atk->>'name') || ' mends ' || (v_tgt->>'name') || ' for ' || v_heal || '.';
    v_swings := v_swings || jsonb_build_object(
      'k', 'heal', 'by', p_unit, 'at', p_target, 'dmg', v_heal,
      'crit', false, 'counter', false, 'first', false, 'def', false,
      'why', 'mend');

    -- A flower does not choose who it grows for. One roll, spent on everyone
    -- standing in reach, so the answer to Sinie is to keep your line apart --
    -- which is the opposite of what every other unit wants of you.
    if coalesce((v_atk->>'blooms')::boolean, false) then
      for u in select * from jsonb_array_elements(v_st->'units') loop
        continue when u->>'id' = p_unit or u->>'id' = p_target;
        continue when u->>'owner' <> p_side;
        continue when (u->>'hp')::int >= (u->>'maxHp')::int;
        v_d2 := cn_cheb((v_atk->>'x')::int, (v_atk->>'y')::int,
                        (u->>'x')::int, (u->>'y')::int);
        continue when v_d2 < (v_atk->>'rmin')::int or v_d2 > (v_atk->>'rmax')::int;
        continue when not cn_los_clear(v_st, (v_atk->>'x')::int, (v_atk->>'y')::int,
                                       (u->>'x')::int, (u->>'y')::int);
        v_bloom := v_bloom || jsonb_build_array(u->>'id');
      end loop;
    end if;

  elsif v_tree is not null then
    -- A tree does not parry and does not answer, but a crit still fells it.
    v_crit := cn_chance((v_atk->>'critPct')::int, 'crit');
    v_dmg := cn_damage(cn_roll((v_atk->>'dmin')::int, (v_atk->>'dmax')::int), v_crit, false);
    v_tgt_hp := (v_tree->>'hp')::int - v_dmg;
    v_killed_tgt := v_tgt_hp <= 0;
    v_swings := v_swings || jsonb_build_object(
      'k', 'hit', 'by', p_unit, 'at', p_target, 'dmg', v_dmg,
      'crit', v_crit, 'counter', false, 'first', false, 'def', false,
      'why', 'tree');
    if v_killed_tgt then
      v_swings := v_swings || jsonb_build_object('k', 'down', 'by', p_target, 'at', p_target);
    end if;
    if cn_has(v_atk, 'burn') then
      v_burn_atk := cn_effect_dmg(v_st, v_atk, cn_burn_pct());
      v_atk_hp := v_atk_hp - v_burn_atk;
      v_swings := v_swings || jsonb_build_object(
        'k', 'burn', 'by', p_unit, 'at', p_unit, 'dmg', v_burn_atk);
    end if;
    v_killed_atk := v_atk_hp <= 0;
    -- Since 0035 the thing being struck may be a wall or a trap, and a log
    -- line that calls a summoned wall a tree is the kind of small lie that
    -- makes a player distrust the rest of the log.
    v_note := (v_atk->>'name') || ' strikes ' || cn_obj_name(cn_obj_kind(v_tree))
              || ' for ' || v_dmg
              || case when v_killed_tgt then ' -- destroyed.' else '.' end;

  else
    v_tgt_hp := (v_tgt->>'hp')::int;

    -- A thief that trades blows is not a thief -- and neither does your own
    -- soldier draw on you. A counter is what somebody does when an ENEMY
    -- attacks them; gating it here rather than at each of the three places
    -- that read v_answers is what also takes the Quick Dagger off, which
    -- would otherwise answer its own side before the blow it was answering.
    v_answers := not v_ally
                 and not coalesce((v_atk->>'sneaks')::boolean, false)
                 and v_dist >= (v_tgt->>'crmin')::int
                 and v_dist <= (v_tgt->>'crmax')::int;
    -- v_answers is the ORDINARY counter, and Quick Dagger spends it. Whether
    -- each side can physically reach the other is a separate, permanent fact,
    -- and it is the one a parry asks: a parrier answers only if the blow it
    -- caught came from somewhere it can reach.
    v_tgt_reaches  := v_answers;
    v_reaches_back := v_dist >= (v_atk->>'crmin')::int
                  and v_dist <= (v_atk->>'crmax')::int;

    -- Quick Dagger. The answer lands before the blow it is answering, and it
    -- is a passive, so nothing catches it. It spends the ordinary counter --
    -- you do not get to answer twice for one attack.
    if v_answers and coalesce((v_tgt->>'parries')::boolean, false) then
      v_crit_counter := not coalesce((v_atk->>'slippery')::boolean, false)
                        and cn_chance((v_tgt->>'critPct')::int, 'crit');
      v_counter := cn_damage(cn_roll((v_tgt->>'dmin')::int, (v_tgt->>'dmax')::int),
                             v_crit_counter, true,
                             cn_aura_bonus(v_st, v_tgt, v_atk),
                             cn_aura_resist(v_st, v_tgt, v_atk),
                             coalesce((v_atk->>'defending')::boolean, false));
      v_atk_hp := v_atk_hp - v_counter;
      if cn_has(v_tgt, 'burn') then
        v_burn_tgt := cn_effect_dmg(v_st, v_tgt, cn_burn_pct());
        v_tgt_hp := v_tgt_hp - v_burn_tgt;
      end if;
      v_killed_atk := v_atk_hp <= 0;
      v_killed_tgt := v_tgt_hp <= 0;
      v_parry   := true;          -- the clients draw this the same way
      v_answers := false;
      v_notes := v_notes || ((v_tgt->>'name') || ' answers first for ' || v_counter
                 || case when v_crit_counter then ' -- a critical hit.' else '.' end);
      -- 'first' is what tells the cinematic to play this BEFORE the lunge it
      -- is answering, which is the whole of Quick Dagger.
      v_swings := v_swings || jsonb_build_object(
        'k', 'hit', 'by', p_target, 'at', p_unit, 'dmg', v_counter,
        'crit', v_crit_counter, 'counter', true, 'first', true,
        'def', coalesce((v_atk->>'defending')::boolean, false),
        'why', 'quick');
    end if;

    -- The chain.
    while not v_killed_atk and not v_killed_tgt and v_chain < cn_parry_cap() loop
      v_chain := v_chain + 1;
      if v_swing_is_atk
        then v_strk := v_atk; v_recv := v_tgt;
        else v_strk := v_tgt; v_recv := v_atk;
      end if;

      -- Lium catches any answer-to-a-parry aimed at him. Everyone else rolls.
      -- Slippery. Nothing catches a blow of Himanta's -- not a roll, and not
      -- Lium, whose whole passive is catching answers. Checked on the
      -- SWINGER, because being hard to parry is a property of the one
      -- swinging and not of the one trying.
      -- AND YOUR OWN SIDE DOES NOT CATCH YOUR BLADE EITHER. A parry is not
      -- only a block: it flips the swing, so the parrier strikes back. An
      -- ally that parried would therefore answer, which is the rule two lines
      -- up read backwards. One `not v_ally` at the roll takes the whole chain
      -- off, and a friendly blow becomes the single beat it should be.
      v_parried := not v_ally
                   and not coalesce((v_strk->>'slippery')::boolean, false)
                   and ((v_is_counter and coalesce((v_recv->>'parryAll')::boolean, false))
                        or cn_chance((v_recv->>'parryPct')::int, 'parry'));

      if v_parried then
        v_parries := v_parries + 1;
        if v_chain = 1 then v_parry := true; end if;
        v_notes := v_notes || ((v_recv->>'name') || ' parries '
                   || (v_strk->>'name') || '.');
        -- 'why' says which rule caught it. Lium catching an answer is not the
        -- same event as a 5% roll coming up, and a caption that calls both of
        -- them "parries" is not narrating, it is labelling.
        v_swings := v_swings || jsonb_build_object(
          'k', 'parry', 'by', v_recv->>'id', 'at', v_strk->>'id',
          'why', case when v_is_counter
                       and coalesce((v_recv->>'parryAll')::boolean, false)
                      then 'all' else 'roll' end);
        -- A parry answers only if the parrier can reach what it caught.
        exit when not case when v_swing_is_atk then v_tgt_reaches
                                               else v_reaches_back end;
        v_swing_is_atk := not v_swing_is_atk;
        v_is_counter := true;
        continue;
      end if;

      -- The blow lands.
      -- ...and nothing crits ONE. Checked on the receiver, for the mirror
      -- reason: it is a property of the one being hit.
      v_hit_crit := not coalesce((v_recv->>'slippery')::boolean, false)
                    and cn_chance((v_strk->>'critPct')::int, 'crit');
      v_hit := cn_damage(cn_roll((v_strk->>'dmin')::int, (v_strk->>'dmax')::int),
                         v_hit_crit, v_is_counter,
                         cn_aura_bonus(v_st, v_strk, v_recv),
                         cn_aura_resist(v_st, v_strk, v_recv),
                         coalesce((v_recv->>'defending')::boolean, false));
      -- THE MIST. Eva's, and it is the receiver's side that has it: a Rogue
      -- standing in it has a chance to be somewhere else when the blow
      -- arrives. Rolled per blow rather than per exchange, so a chain of
      -- four swings is four chances -- which is what makes two turns of it
      -- worth an activation.
      -- THALGRIM. Flat, and added after every multiplier: "an extra 25
      -- damage" is a sentence about the number that lands, not about the
      -- roll that started it.
      if cn_has(v_recv, 'poison') then
        v_hit := v_hit + coalesce((v_strk->>'vsPoisoned')::int, 0);
      end if;
      v_missed := cn_mist_dodge(v_st, v_recv);
      if v_missed then v_hit := 0; v_hit_crit := false; end if;
      if v_swing_is_atk then
        v_tgt_hp := v_tgt_hp - v_hit;
        if v_is_counter then v_riposte := v_riposte + v_hit;
        else v_dmg := v_hit; v_crit := v_hit_crit; end if;
      else
        v_atk_hp := v_atk_hp - v_hit;
        v_counter := v_counter + v_hit;
        v_crit_counter := v_crit_counter or v_hit_crit;
      end if;
      v_swings := v_swings || jsonb_build_object(
        'k', 'hit', 'by', v_strk->>'id', 'at', v_recv->>'id', 'dmg', v_hit,
        'crit', v_hit_crit, 'counter', v_is_counter, 'first', false,
        'def', coalesce((v_recv->>'defending')::boolean, false),
        'why', case when v_missed then 'mist'
                    when v_is_counter then 'counter' else 'strike' end);

      -- STRIKE TWICE. Not only on the attack: Jared's rule is "a second hit
      -- when Himanta attacks, counters or parries", and all three are the
      -- same thing here -- a swing in the chain -- which is the whole reason
      -- the chain was made uniform in 0020. A missed blow does not double:
      -- there is nothing to do twice.
      if not v_missed and coalesce((v_strk->>'twicePct')::int, 0) > 0
         and cn_chance((v_strk->>'twicePct')::int, 'twice') then
        v_crit2 := not coalesce((v_recv->>'slippery')::boolean, false)
                   and cn_chance((v_strk->>'critPct')::int, 'crit');
        v_hit2 := cn_damage(cn_roll((v_strk->>'dmin')::int, (v_strk->>'dmax')::int),
                            v_crit2, v_is_counter,
                            cn_aura_bonus(v_st, v_strk, v_recv),
                            cn_aura_resist(v_st, v_strk, v_recv),
                            coalesce((v_recv->>'defending')::boolean, false));
        if cn_mist_dodge(v_st, v_recv) then v_hit2 := 0; v_crit2 := false; end if;
        if v_swing_is_atk then
          v_tgt_hp := v_tgt_hp - v_hit2;
          if v_is_counter then v_riposte := v_riposte + v_hit2;
          else v_dmg := v_dmg + v_hit2; end if;
        else
          v_atk_hp := v_atk_hp - v_hit2;
          v_counter := v_counter + v_hit2;
        end if;
        v_swings := v_swings || jsonb_build_object(
          'k', 'hit', 'by', v_strk->>'id', 'at', v_recv->>'id', 'dmg', v_hit2,
          'crit', v_crit2, 'counter', v_is_counter, 'first', false,
          'def', coalesce((v_recv->>'defending')::boolean, false),
          'why', 'twice');
        v_notes := v_notes || ((v_strk->>'name') || ' strikes again for ' || v_hit2 || '.');
      end if;
      if v_is_counter then
        v_notes := v_notes || ((v_strk->>'name') || ' answers for ' || v_hit
                   || case when v_hit_crit then ' -- a critical hit.' else '.' end);
      end if;

      -- ZEPHYRA. The cyclone lands with the blow, on anything it hit.
      if not v_missed and v_hit > 0
         and coalesce((v_strk->>'stuns')::boolean, false) then
        if v_swing_is_atk then v_tgt := cn_afflict(v_tgt, 'stun', '1'::jsonb);
                          else v_atk := cn_afflict(v_atk, 'stun', '1'::jsonb); end if;
        v_notes := v_notes || ((v_recv->>'name') || ' is caught in the cyclone.');
      end if;

      -- NYXARA. Heals for what it dealt, capped at its own maximum -- and
      -- for what LANDED rather than what was rolled, so a guard and a
      -- resistance take the healing down with the damage.
      v_steal := round(v_hit * coalesce((v_strk->>'lifestealPct')::int, 0) / 100.0)::int;
      if v_steal > 0 then
        if v_swing_is_atk
          then v_atk_hp := least((v_atk->>'maxHp')::int, v_atk_hp + v_steal);
          else v_tgt_hp := least((v_tgt->>'maxHp')::int, v_tgt_hp + v_steal);
        end if;
        v_swings := v_swings || jsonb_build_object(
          'k', 'heal', 'by', v_strk->>'id', 'at', v_strk->>'id', 'dmg', v_steal,
          'why', 'steal');
      end if;

      -- Swinging while alight costs you, whichever end of the exchange you
      -- are -- and since 0034 it costs 15% of your maximum rather than a
      -- flat 5, which is the spec's number and scales with the unit.
      if cn_has(v_strk, 'burn') then
        v_cost := cn_effect_dmg(v_st, v_strk, cn_burn_pct());
        if v_swing_is_atk
          then v_burn_atk := v_cost; v_atk_hp := v_atk_hp - v_cost;
          else v_burn_tgt := v_cost; v_tgt_hp := v_tgt_hp - v_cost;
        end if;
        v_swings := v_swings || jsonb_build_object(
          'k', 'burn', 'by', v_strk->>'id', 'at', v_strk->>'id', 'dmg', v_cost);
      end if;
      v_killed_atk := v_atk_hp <= 0;
      v_killed_tgt := v_tgt_hp <= 0;
      -- Recorded HERE rather than counted up at the end, because the order is
      -- the whole point of the list: a cinematic has to know whether somebody
      -- fell before or after the blow that follows.
      if v_killed_tgt then
        v_swings := v_swings || jsonb_build_object('k', 'down', 'by', p_target, 'at', p_target);
      end if;
      if v_killed_atk then
        v_swings := v_swings || jsonb_build_object('k', 'down', 'by', p_unit, 'at', p_unit);
      end if;
      exit when v_killed_atk or v_killed_tgt;

      -- A blow that lands draws the ordinary counter. A counter that lands
      -- ends it -- otherwise the two of them never stop.
      exit when v_is_counter;
      exit when not v_answers;
      v_swing_is_atk := false;
      v_is_counter := true;
    end loop;

    v_new_burn := (v_atk->>'burns')::boolean and not v_killed_tgt and v_dmg > 0;
    if v_new_burn then v_tgt := cn_afflict(v_tgt, 'burn', 'true'::jsonb); end if;

    if v_dmg = 0 then
      v_note := (v_atk->>'name') || ' lunges at ' || (v_tgt->>'name') || '.';
    else
      v_note := (v_atk->>'name') || ' hits ' || (v_tgt->>'name') || ' for ' || v_dmg
                || case when v_killed_tgt and v_burn_tgt = 0 then ' -- destroyed.' else '.' end;
    end if;
  end if;

  for u in select * from jsonb_array_elements(v_st->'units') loop
    if u->>'id' = p_unit then
      if not v_killed_atk then
        u := jsonb_set(u, '{acted}', 'true'::jsonb);
        u := jsonb_set(u, '{moved}', 'true'::jsonb);
        u := jsonb_set(u, '{spent}', 'true'::jsonb);
        u := jsonb_set(u, '{hp}', to_jsonb(v_atk_hp));
        -- The exchange afflicts the LOCAL copies -- a cyclone caught on the
        -- counter lands on v_atk, not on the row in the state -- so the whole
        -- effects object is carried back here. Setting one key at a time is
        -- how `burned` came to be written in two places and read in four.
        u := jsonb_set(u, '{effects}',
                       coalesce(v_atk->'effects', cn_no_effects()), true);
        v_out := v_out || u;
      end if;
    elsif v_tree is null and u->>'id' = p_target then
      -- ONE BRANCH, not two. There used to be an `if v_ally` here that kept
      -- the target on the board whatever its health, because the only way to
      -- point this function at an ally was to MEND it and nobody has ever
      -- been mended to death. Since 0038 an ally can be struck, and an ally
      -- struck to nothing was staying on the board at minus thirty hit
      -- points -- so the crown never fell and the match never ended.
      --
      -- The two branches were already identical apart from that: 0034 folded
      -- the cure and the new burn into v_tgt's own effects object, so there
      -- is nothing left for a mend to do differently.
      if not v_killed_tgt then
        u := jsonb_set(u, '{hp}', to_jsonb(v_tgt_hp));
        u := jsonb_set(u, '{effects}',
                       coalesce(v_tgt->'effects', cn_no_effects()), true);
        v_out := v_out || u;
      end if;
    elsif v_bloom @> jsonb_build_array(u->>'id') then
      v_got := least((u->>'maxHp')::int - (u->>'hp')::int, v_heal_roll);
      u := jsonb_set(u, '{hp}', to_jsonb((u->>'hp')::int + v_got));
      if coalesce((v_atk->>'cures')::boolean, false) then
        u := cn_afflict(u, 'burn', 'false'::jsonb);
      end if;
      v_out := v_out || u;
    else
      v_out := v_out || u;
    end if;
  end loop;

  for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
    if v_tree is not null and e->>'id' = p_target then
      if not v_killed_tgt then v_rocks := v_rocks || jsonb_set(e, '{hp}', to_jsonb(v_tgt_hp)); end if;
    else
      v_rocks := v_rocks || e;
    end if;
  end loop;

  v_st := jsonb_set(v_st, '{units}', v_out);
  v_st := jsonb_set(v_st, '{obstacles}', v_rocks);
  -- Set on the state rather than through cn_end_act: an attacker killed by
  -- the counter has already been dropped from v_out, so there is no row
  -- left to flag, and the activation still has to end.
  v_st := jsonb_set(v_st, '{active}', 'null'::jsonb);

  -- ===== 0049: new-engine attack hooks (additive) -- ON_ATTACK, ON_PARRY,
  -- ON_DEATH. Deliberately fired ONCE HERE, after v_st already carries the
  -- exchange's final hp/effects/positions (not interleaved inside the
  -- swing loop above): that loop tracks damage in the local scalars
  -- v_atk_hp/v_tgt_hp, flushed into v_st only in the two unit-rebuild
  -- loops just above, so a generic effect that touched v_st mid-loop would
  -- be silently overwritten the moment those scalars are flushed. Firing
  -- after the flush means every hook sees, and only ever touches, the one
  -- true copy of the board -- a deliberate interpretation of "additively
  -- inside the loop" rather than a literal one; see the migration report.
  -- Skipped entirely for a tree/wall/bomb/tornado strike (v_tree is not
  -- null): scenery has no abilityScript and cannot parry or die in the
  -- sense these three triggers mean. Also skipped for the (currently
  -- dead-code, since no active card carries `heals`) mend branch: a mend
  -- is not an attack, and ON_ATTACK should not fire when a healer points
  -- at an ally to bandage them.
  if v_tree is null and not (v_ally and coalesce((v_atk->>'heals')::boolean, false)) then
    if not v_killed_atk then
      v_st := cn_run_effects(v_st, 'ON_ATTACK', v_atk,
        jsonb_build_object('target', v_tgt, 'turnNumber', coalesce((v_st->>'turnNumber')::int, 1)));
    end if;
    for v_elem in select * from jsonb_array_elements(v_swings) loop
      if v_elem->>'k' = 'parry' then
        v_ce_id := v_elem->>'by';
        v_ce_unit := null;
        for u in select * from jsonb_array_elements(v_st->'units') loop
          if u->>'id' = v_ce_id then v_ce_unit := u; end if;
        end loop;
        if v_ce_unit is not null then
          v_st := cn_run_effects(v_st, 'ON_PARRY', v_ce_unit,
            jsonb_build_object(
              'target', case when v_ce_id = p_unit then v_tgt else v_atk end,
              'turnNumber', coalesce((v_st->>'turnNumber')::int, 1)));
        end if;
      end if;
    end loop;
    if v_killed_tgt then
      v_st := cn_run_effects(v_st, 'ON_DEATH', v_tgt,
        jsonb_build_object('attacker', v_atk, 'turnNumber', coalesce((v_st->>'turnNumber')::int, 1)));
    end if;
    if v_killed_atk then
      v_st := cn_run_effects(v_st, 'ON_DEATH', v_atk,
        jsonb_build_object('attacker', v_tgt, 'turnNumber', coalesce((v_st->>'turnNumber')::int, 1)));
    end if;
  end if;
  -- ===== end 0049 =============================================================
  -- ===== 0057: STRUCTURES -- ON_DESTROYED (additive) ======================
  -- Fired for exactly the same reason 0049 fires ON_ATTACK/ON_PARRY/ON_DEATH
  -- above, and at the same kind of moment: after v_st already carries the
  -- exchange's final obstacles array (the rebuild loop just above this one
  -- has already dropped the destroyed obstacle from v_rocks), never inside
  -- the tree/wall/bomb/tornado-strike branch itself. v_tree is the LOCAL
  -- copy captured before the exchange -- its hp is stale, which is fine:
  -- only kind/x/y/owner/by are read (kind to find a matching structures
  -- row at all; owner/by so INVOKER resolves to whoever placed it). A tree
  -- or a legacy summon (bomb/wall/tornado) has no row in `structures`, so
  -- cn_run_structure_effects finds nothing and this is a no-op for every
  -- strike that predates 0057 -- see that function's own header.
  if v_tree is not null and v_killed_tgt then
    v_st := cn_run_structure_effects(v_st, 'ON_DESTROYED', v_tree,
      jsonb_build_object('attacker', v_atk, 'turnNumber', coalesce((v_st->>'turnNumber')::int, 1)));
  end if;
  -- ===== end 0057 ===========================================================
  v_st := jsonb_set(v_st, '{fx}', jsonb_build_object(
    'seq', coalesce((v_st->'fx'->>'seq')::int, 0) + 1,
    'atk', p_unit, 'tgt', p_target,
    'dmg', v_dmg, 'heal', v_heal,
    'killedTgt', v_killed_tgt, 'counter', v_counter, 'killedAtk', v_killed_atk,
    'burnAtk', v_burn_atk, 'burnTgt', v_burn_tgt, 'newBurn', v_new_burn,
    'cured', v_cured, 'parry', v_parry, 'bloom', v_bloom,
    'crit', v_crit, 'critCounter', v_crit_counter,
    'parries', v_parries, 'chain', v_chain, 'riposte', v_riposte,
    'swings', v_swings,
    'tree', (v_tree is not null)));

  -- ===== 0051: STALEMATE TRACKING (additive) ================================
  -- Any real damage dealt in this exchange -- the primary blow, a counter,
  -- a riposte (a counter-to-a-counter), or burn cost paid by either side --
  -- resets advance_turn's rounds-since-damage streak. A heal, lifesteal, or
  -- a swing that misses/is parried for nothing does not count, which is
  -- what "0 total damage dealt" means. A tree/wall strike's damage lands in
  -- v_dmg the same as any other, so it is covered for free.
  if (v_dmg + v_counter + v_riposte + v_burn_atk + v_burn_tgt) > 0 then
    v_st := jsonb_set(v_st, '{roundDmg}', 'true'::jsonb);
  end if;
  -- ===== end 0051 ============================================================

  v_st := state_log(v_st, v_note);
  if jsonb_array_length(v_bloom) > 0 then
    v_st := state_log(v_st, 'The bloom spreads -- '
      || jsonb_array_length(v_bloom) || ' more mended.');
  end if;
  if v_cured then v_st := state_log(v_st, (v_tgt->>'name') || ' stops burning.'); end if;
  if v_new_burn then v_st := state_log(v_st, (v_tgt->>'name') || ' is burning.'); end if;
  foreach v_note in array v_notes loop
    v_st := state_log(v_st, v_note);
  end loop;
  if v_killed_atk and v_burn_atk = 0 and v_counter > 0 then
    v_st := state_log(v_st, (v_atk->>'name') || ' is destroyed.');
  end if;
  if v_burn_tgt > 0 then
    v_st := state_log(v_st, (v_tgt->>'name') || ' burns for ' || v_burn_tgt
      || case when v_killed_tgt then ' -- destroyed.' else '.' end);
  end if;
  if v_burn_atk > 0 then
    v_st := state_log(v_st, (v_atk->>'name') || ' burns for ' || v_burn_atk
      || case when v_killed_atk then ' -- destroyed.' else '.' end);
  end if;

  -- ---- who has won -------------------------------------------------------
  -- A crown that falls takes the kingdom with it. Checked before the count of
  -- bodies, because a king can die while four of his units are still standing
  -- and that is still over. The defender is checked first: the attack resolved,
  -- so if both crowns fell in the one exchange the one that was struck fell
  -- first.
  if v_tree is null and v_killed_tgt and coalesce((v_tgt->>'royal')::boolean, false) then
    v_crown := v_tgt->>'owner';
  elsif v_killed_atk and coalesce((v_atk->>'royal')::boolean, false) then
    v_crown := v_atk->>'owner';
  end if;

  for u in select * from jsonb_array_elements(v_out) loop
    if u->>'owner' = p_side then v_mine := v_mine + 1; else v_foes := v_foes + 1; end if;
  end loop;

  if v_crown is not null and not exists (
       select 1 from jsonb_array_elements(v_out) q
        where q->>'owner' = v_crown and (q->>'royal')::boolean) then
    v_win := case when v_crown = 'host' then 'guest' else 'host' end;
    v_st := state_log(v_st, 'The crown has fallen.');
  elsif v_foes = 0 then v_win := p_side;
  elsif v_mine = 0 then v_win := v_other;
  end if;

  -- ===== 0045: crit/parry counters, single-class team check, bot-win credit
  -- Crits and parries are counted here, once, whatever v_win turns out to be
  -- below -- a match-ending crit is still a crit. Every element of v_swings
  -- names its actor as 'by', an id that is always p_unit or p_target -- the
  -- only two units this function ever touches -- so the owner lookup is a
  -- straight comparison against the two local unit copies rather than a scan
  -- of the board.
  for v_elem in select * from jsonb_array_elements(v_swings) loop
    v_by := v_elem->>'by';
    if v_by is null then continue; end if;
    if v_by = p_unit then v_by_owner := p_side;
    elsif v_by = p_target then v_by_owner := coalesce(v_tgt->>'owner', v_other);
    else continue; end if;
    v_by_uid := case when v_by_owner = 'host' then m.host_id else m.guest_id end;
    if v_by_uid is null then continue; end if;  -- the bot has no profile row

    if coalesce((v_elem->>'crit')::boolean, false) then
      update public.profiles set crit_count = crit_count + 1 where id = v_by_uid;
      perform cn_check_achievements(v_by_uid);
    end if;
    if v_elem->>'k' = 'parry' then
      update public.profiles set parry_count = parry_count + 1 where id = v_by_uid;
      perform cn_check_achievements(v_by_uid);
    end if;
  end loop;

  if v_win is not null then
    v_win_uid := case when v_win = 'host' then m.host_id else m.guest_id end;

    -- A single-class team win: exactly four surviving non-royal units on the
    -- winning side, all one role among knight/rogue/mage/flying. Checked
    -- against v_out, the post-combat roster, and unlocked at most once ever
    -- per player -- the primary key on player_achievements is what makes
    -- that true, not a flag read beforehand.
    if v_win_uid is not null then
      select count(*), array_agg(distinct u->>'role') into v_win_count, v_win_roles
        from jsonb_array_elements(v_out) u
       where u->>'owner' = v_win and not coalesce((u->>'royal')::boolean, false);
      if v_win_count = 4 and array_length(v_win_roles, 1) = 1
         and v_win_roles[1] in ('knight', 'rogue', 'mage', 'flying') then
        insert into public.player_achievements (user_id, achievement_id)
          values (v_win_uid, 'single_class_' || v_win_roles[1])
          on conflict do nothing;
      end if;
    end if;

    -- A bot match has no rank on the line, but a win over the bot still
    -- counts toward the bot-wins tiers. The bot is always the guest
    -- (bot_step never plays anything else), so a human win here is always
    -- v_win = 'host'. Mirrors cn_finish's own copy of the same rule, for the
    -- ending that happens there instead of here.
    if m.bot is not null and v_win = 'host' and m.host_id is not null then
      update public.profiles set bot_wins = bot_wins + 1 where id = m.host_id;
    end if;

    if v_win_uid is not null then perform cn_check_achievements(v_win_uid); end if;
  end if;
  -- ===== end 0045 ===========================================================

  if v_win is not null then
    if m.ranked then perform finish_match(m.id, v_win, 'defeat'); end if;
    v_st := jsonb_set(v_st, '{winner}', to_jsonb(v_win));
    v_st := state_log(v_st,
      case when v_win = 'host' then m.host_name else m.guest_name end || ' wins.');
    update public.matches
       set state = v_st, status = 'finished', winner = v_win,
           turn_deadline = null, updated_at = now()
     where id = m.id returning * into m;
  else
    update public.matches set state = v_st, updated_at = now()
     where id = m.id returning * into m;
  end if;
  return m;
end
$function$
;


-- ---------------------------------------------------------------------------
-- 9. Verification -- every check below should read true.
-- ---------------------------------------------------------------------------

select
  (select count(*) = 1 from pg_tables where schemaname = 'public' and tablename = 'structures')
    as structures_table_exists,
  (select count(*) = 1 from pg_tables where schemaname = 'public' and tablename = 'structure_effects')
    as structure_effects_table_exists,
  (select count(*) = 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'card_effects' and column_name = 'structure_slug')
    as card_effects_has_structure_slug,
  (cn_obj_hp('tree') = 30 and cn_obj_hp('bomb') = 15) as legacy_obj_hp_unchanged,
  (cn_obj_name('tree') = 'a tree') as legacy_obj_name_unchanged,
  (cn_obj_solid('wall') and not cn_obj_solid('bomb')) as legacy_obj_solid_unchanged,
  (select count(*) = 1 from pg_proc where proname = 'cn_run_structure_effects') as run_structure_effects_exists,
  (select count(*) = 1 from pg_proc where proname = 'cn_create_structure') as create_structure_exists,
  (select count(*) = 1 from pg_proc where proname = 'cn_step_on_structure') as step_on_structure_exists,
  (select count(*) = 1 from pg_proc where proname = 'admin_delete_structure') as admin_delete_structure_exists;
