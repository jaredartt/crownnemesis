-- 0213: PLAYTEST. Admin Mode -> Playtest: one account (Jared's) plays BOTH
-- sides of a real match row, drops any card or tree onto the board at any
-- time, hands any unit to either team at any time, and nobody ever wins.
--
-- The point of building it on a real `matches` row, and not as a separate
-- simulator, is that every rule is the one the 1v1 game already runs: the
-- client calls the same submit_move / submit_attack / submit_ability /
-- submit_throw / submit_defend / submit_wait / submit_undo_move / end_turn,
-- those call the same cn_* functions, and a change to any of them is a change
-- to playtest, with no second copy to keep in step. What playtest adds is only
-- the things that make the room a playground, and each is a small, named seam:
--
--   * side_of():        in a playtest room "your side" is whoever's move it is
--                       (or whoever owes the open throw decision), so one
--                       account can act for both teams.
--   * cn_playtest_guard (trigger): a playtest row is never finished, never has
--                       a winner, and has no clock. This is the net under every
--                       ending, however a future change reaches it.
--   * advance_turn():   the 40-turn cap and the 5-round stalemate are skipped
--                       in a playtest room (patched in place below).
--   * cn_finish():      a crown falling does not end a playtest room.
--   * cn_unit_from_card(): the unit-building half of cn_army, pulled out so a
--                       dropped card is built by the SAME code as a deployed
--                       one. cn_army now calls it.
--   * pt_* RPCs:        drop / remove / hand over / reset, all super-admin only.
--
-- A playtest row is also is_sim = true, which already keeps it out of the
-- Watch list, the sweeps, XP and the activity numbers.

-- (No foreign key on playtest_by: pt_new() clears the caller's old room itself,
-- and adding one meant a table lock on `profiles` that never got through.)
alter table public.matches add column if not exists playtest boolean not null default false;
alter table public.matches add column if not exists playtest_by uuid;

-- ---- whose side is the caller? -----------------------------------------------
create or replace function public.side_of(p_match public.matches, p_user uuid)
returns text language sql stable as $$
  select case
    when exists (select 1 from public.profiles pr where pr.id = p_user and pr.is_banned) then null
    -- Playtest: the one account that owns the room acts for whoever has the
    -- move -- the side that owes the open throw decision if there is one.
    when p_match.playtest then
      case when p_user = p_match.playtest_by
           then coalesce(nullif(public.cn_pending(p_match.state)->>'side', ''), p_match.state->>'turn')
           else null end
    when p_match.host_id  = p_user then 'host'
    when p_match.guest_id = p_user then 'guest'
    else null end
$$;

-- ---- a playtest row never ends, never has a clock ----------------------------
create or replace function public.cn_playtest_guard()
returns trigger language plpgsql set search_path to 'public' as $$
begin
  if new.playtest then
    new.is_sim := true;
    new.turn_deadline := null;
    new.status := 'active';
    new.winner := null;
    new.state := (new.state - 'forfeitedBy')
      || jsonb_build_object('winner', null, 'away', null, 'staleRounds', 0,
                            'idle', jsonb_build_object('host', 0, 'guest', 0));
    -- cn_attack writes "<name> wins." itself; in a playtest room nobody does.
    if jsonb_typeof(new.state->'log') = 'array' and jsonb_array_length(new.state->'log') > 0
       and coalesce(new.state->'log'->-1->>'text', '') like '% wins.' then
      new.state := jsonb_set(new.state, '{log,-1,text}',
        to_jsonb('Playtest: that would have ended the match -- the battle goes on.'::text));
    end if;
  end if;
  return new;
end $$;
revoke all on function public.cn_playtest_guard() from public, anon, authenticated;
drop trigger if exists cn_playtest_guard on public.matches;
create trigger cn_playtest_guard before insert or update on public.matches
  for each row when (new.playtest) execute function public.cn_playtest_guard();

-- ---- patch a function's source in place --------------------------------------
-- advance_turn and cn_finish are long and change often. Rather than carry a
-- second copy of them here that would silently undo the next change to the
-- originals, the playtest exceptions are spliced into whatever is live, and the
-- splice refuses (loudly) if the text it expects is not there.
create or replace function pg_temp.cn_pt_patch(p_fn regprocedure, p_old text, p_new text)
returns void language plpgsql as $$
declare v_def text := pg_get_functiondef(p_fn);
begin
  if position(p_new in v_def) > 0 then return; end if;   -- already patched
  if position(p_old in v_def) = 0 then
    raise exception 'playtest patch: % not found in %', p_old, p_fn;
  end if;
  execute replace(v_def, p_old, p_new);
end $$;

select pg_temp.cn_pt_patch('public.advance_turn(uuid,text,boolean)'::regprocedure,
  'if v_turn > 40 then', 'if v_turn > 40 and not m.playtest then');
select pg_temp.cn_pt_patch('public.advance_turn(uuid,text,boolean)'::regprocedure,
  'if coalesce((st->>''staleRounds'')::int, 0) >= 5 then',
  'if coalesce((st->>''staleRounds'')::int, 0) >= 5 and not m.playtest then');

-- A fallen crown (or an empty side) is just a log line in a playtest room.
select pg_temp.cn_pt_patch('public.cn_finish(public.matches,jsonb,text)'::regprocedure,
  E'begin\n  if m.ranked or',
  E'begin\n  if m.playtest then\n    p_st := state_log(p_st, ''Playtest: that would have ended the match -- the battle goes on.'');\n    update public.matches set state = p_st, updated_at = now()\n     where id = m.id returning * into v;\n    return v;\n  end if;\n  if m.ranked or');

-- ---- one unit, built from one card (cn_army's inner half) --------------------
create or replace function public.cn_unit_from_card(
  c public.cards, p_side text, p_id text, p_x integer, p_y integer)
returns jsonb language plpgsql set search_path to 'public' as $$
declare v_script jsonb; v_meta record;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', ce.id,
           'trigger', ce.trigger, 'target_selector', ce.target_selector,
           'action', ce.action, 'value', ce.value, 'status', ce.status,
           'stat_name', ce.stat_name, 'conditions', ce.conditions,
           'structure_slug', ce.structure_slug,
           'animation_slug', ce.animation_slug,
           'range_kind', ce.range_kind, 'range_min', ce.range_min, 'range_max', ce.range_max,
           'duration_kind', ce.duration_kind, 'duration_turns', ce.duration_turns,
           'sort', ce.sort) order by ce.sort), '[]'::jsonb)
    into v_script
    from public.card_effects ce where ce.card_id = c.id;

  select ability_type, max_uses, cooldown_turns into v_meta
    from public.card_ability_meta
   where card_id = c.id and ability_type = 'active'
   limit 1;

  return (jsonb_build_object(
    'id', p_id, 'owner', p_side,
    'cardId', c.id, 'slug', c.slug, 'name', c.name, 'role', c.role,
    'hp', c.hp, 'maxHp', c.hp, 'mov', c.mov,
    'rmin', c.rmin, 'rmax', c.rmax, 'crmin', c.crmin, 'crmax', c.crmax,
    'dmin', c.dmin, 'dmax', c.dmax, 'pow', c.power,
    'parryPct', c.parry_pct, 'critPct', c.crit_pct, 'parryAll', c.parry_all,
    'royal', c.royal,
    'abilityKind', c.ability_kind, 'abilityN', c.ability_n,
    'abilityTurns', c.ability_turns, 'summonKind', c.summon_kind,
    'slippery', c.slippery, 'twicePct', c.twice_pct, 'regenPct', c.regen_pct,
    'poisonsAdj', c.poisons_adjacent, 'stuns', c.stuns,
    'vsPoisoned', c.vs_poisoned, 'lifestealPct', c.lifesteal_pct,
    'auraKind', c.aura_kind, 'auraClass', c.aura_class, 'auraPct', c.aura_pct,
    'burns', c.burns, 'heals', c.heals,
    'effects', cn_no_effects(),
    'flies', c.flies, 'sneaks', c.sneaks, 'cures', c.cures, 'tramples', c.tramples,
    'parries', c.parries, 'blooms', c.blooms,
    'accent', c.accent, 'art', c.art_url, 'ability', c.ability,
    'x', p_x, 'y', p_y, 'moved', false, 'acted', false)
    || jsonb_build_object('swamps', c.swamps, 'abilityScript', v_script, 'evasionPct', c.evasion_pct,
                           'effectFires', '{}'::jsonb)
    || jsonb_build_object(
         'abilityMaxUses', v_meta.max_uses,
         'abilityCooldownTurns', coalesce(v_meta.cooldown_turns, 0)));
end $$;
revoke all on function public.cn_unit_from_card(public.cards, text, text, integer, integer)
  from public, anon, authenticated;

create or replace function public.cn_army(p_state jsonb, p_side text, p_deck text[])
returns jsonb language plpgsql as $$
declare
  v_w int := (p_state->'board'->>'w')::int;
  v_h int := (p_state->'board'->>'h')::int;
  v_taken text[] := '{}'; e jsonb; c public.cards;
  v_xs int[] := '{}'::int[]; v_ys int[] := '{}'::int[];
  i int; vx int; vy int; v_idx int := 0;
  v_units jsonb := '[]'::jsonb; v_done boolean;
begin
  if deck_royals(p_deck) <> 1 then
    raise exception 'a kingdom is exactly one royal and % others, not %',
      deck_size() - 1, deck_royals(p_deck);
  end if;

  for e in select * from jsonb_array_elements(coalesce(p_state->'obstacles', '[]'::jsonb)) loop
    v_taken := v_taken || ((e->>'x') || ',' || (e->>'y'));
  end loop;

  for i in 0 .. (v_w - 1) / 2 loop
    if 2 * i + 1 < v_w then v_xs := v_xs || (2 * i + 1); end if;
  end loop;
  for i in 0 .. (v_w - 1) / 2 loop
    if 2 * i < v_w then v_xs := v_xs || (2 * i); end if;
  end loop;

  if p_side = 'host'
    then for i in 0 .. (v_h / 2 - 1)            loop v_ys := v_ys || i; end loop;
    else for i in reverse (v_h - 1) .. (v_h / 2) loop v_ys := v_ys || i; end loop;
  end if;

  for i in 1 .. deck_size() loop
    select * into c from public.cards where slug = p_deck[i];
    if c.id is null then raise exception 'unknown card %', p_deck[i]; end if;

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
    v_units := v_units || cn_unit_from_card(c, p_side, substr(p_side, 1, 1) || v_idx, vx, vy);
  end loop;
  return v_units;
end $$;

-- ---- the playtest RPCs -------------------------------------------------------
create or replace function public.cn_pt_lock(p_match uuid)
returns public.matches language plpgsql security definer set search_path to 'public' as $$
declare m public.matches;
begin
  if not public.cn_is_super_admin() then raise exception 'playtest is admin only'; end if;
  select * into m from public.matches where id = p_match for update;
  if m.id is null or not m.playtest then raise exception 'not a playtest room'; end if;
  return m;
end $$;
revoke all on function public.cn_pt_lock(uuid) from public, anon, authenticated;

-- A fresh room: Blue (guest, bottom) to act, no units, a random set of trees.
-- One room per admin, reset in place: a "new board" is a fresh state in the
-- same row, so there is never a pile of old playtest rooms to clean up.
create or replace function public.pt_new()
returns public.matches language plpgsql security definer set search_path to 'public' as $$
declare v_st jsonb; m public.matches;
begin
  if not public.cn_is_super_admin() then raise exception 'playtest is admin only'; end if;
  v_st := public.cn_fresh_map();
  v_st := v_st || jsonb_build_object(
    'phase', 'battle', 'ready', jsonb_build_object('host', true, 'guest', true),
    'turn', 'guest', 'turnNumber', 1, 'acts', 0, 'active', null,
    'playtest', true, 'ptSeq', 0);
  v_st := state_log(v_st, 'Playtest: drop any card onto the board and play it like any other match.');
  select * into m from public.matches where playtest and playtest_by = auth.uid()
   order by created_at desc limit 1 for update;
  if m.id is not null then
    update public.matches set state = v_st, status = 'active', winner = null, updated_at = now()
     where id = m.id returning * into m;
  else
    insert into public.matches
      (code, host_id, host_name, guest_id, guest_name, status, state, turn_deadline,
       bot, ranked, is_sim, playtest, playtest_by)
    values
      (gen_match_code(), public.cn_sim_profile_id(), 'Red team', null, 'Blue team', 'active', v_st, null,
       null, false, true, true, auth.uid())
    returning * into m;
  end if;
  return m;
end $$;

create or replace function public.pt_drop(p_match uuid, p_slug text, p_owner text, p_x integer, p_y integer)
returns public.matches language plpgsql security definer set search_path to 'public' as $$
declare m public.matches; st jsonb; c public.cards; u jsonb; seq int; w int; h int;
begin
  m := public.cn_pt_lock(p_match);
  if p_owner not in ('host', 'guest') then raise exception 'bad team'; end if;
  st := m.state;
  w := (st->'board'->>'w')::int; h := (st->'board'->>'h')::int;
  if p_x < 0 or p_y < 0 or p_x >= w or p_y >= h then raise exception 'off the board'; end if;
  if exists (select 1 from jsonb_array_elements(coalesce(st->'units', '[]'::jsonb)) q
              where (q->>'x')::int = p_x and (q->>'y')::int = p_y)
     or exists (select 1 from jsonb_array_elements(coalesce(st->'obstacles', '[]'::jsonb)) q
              where (q->>'x')::int = p_x and (q->>'y')::int = p_y) then
    raise exception 'that tile is taken';
  end if;
  select * into c from public.cards where slug = p_slug;
  if c.id is null then raise exception 'unknown card %', p_slug; end if;

  seq := coalesce((st->>'ptSeq')::int, 0) + 1;
  u := public.cn_unit_from_card(c, p_owner, 'p' || seq, p_x, p_y);
  st := jsonb_set(st, '{ptSeq}', to_jsonb(seq), true);
  st := jsonb_set(st, '{units}', coalesce(st->'units', '[]'::jsonb) || u);
  st := state_log(st, 'Playtest: ' || c.name || ' joins the '
        || case when p_owner = 'host' then 'Red' else 'Blue' end || ' team.');
  -- Exactly what cn_set_ready does for every unit when a battle opens.
  st := cn_run_effects(st, 'ON_PLAY', u,
          jsonb_build_object('turnNumber', coalesce((st->>'turnNumber')::int, 1)));
  update public.matches set state = st, updated_at = now() where id = m.id returning * into m;
  return m;
end $$;

-- A tree, or any structure from the Structures tab (a wall, a bomb...).
create or replace function public.pt_object(p_match uuid, p_kind text, p_owner text, p_x integer, p_y integer)
returns public.matches language plpgsql security definer set search_path to 'public' as $$
declare m public.matches; st jsonb; v_hp int; w int; h int; o jsonb;
begin
  m := public.cn_pt_lock(p_match);
  st := m.state;
  v_hp := public.cn_obj_hp(p_kind);
  if v_hp is null then raise exception 'unknown object %', p_kind; end if;
  w := (st->'board'->>'w')::int; h := (st->'board'->>'h')::int;
  if p_x < 0 or p_y < 0 or p_x >= w or p_y >= h then raise exception 'off the board'; end if;
  if exists (select 1 from jsonb_array_elements(coalesce(st->'units', '[]'::jsonb)) q
              where (q->>'x')::int = p_x and (q->>'y')::int = p_y)
     or exists (select 1 from jsonb_array_elements(coalesce(st->'obstacles', '[]'::jsonb)) q
              where (q->>'x')::int = p_x and (q->>'y')::int = p_y) then
    raise exception 'that tile is taken';
  end if;
  o := jsonb_build_object('id', gen_random_uuid()::text, 'kind', p_kind, 'x', p_x, 'y', p_y,
                          'hp', v_hp, 'maxHp', v_hp);
  if p_owner in ('host', 'guest') then o := o || jsonb_build_object('owner', p_owner); end if;
  st := jsonb_set(st, '{obstacles}', coalesce(st->'obstacles', '[]'::jsonb) || o);
  st := state_log(st, 'Playtest: ' || public.cn_obj_name(p_kind) || ' placed.');
  update public.matches set state = st, updated_at = now() where id = m.id returning * into m;
  return m;
end $$;

-- Take a unit or an object off the board.
create or replace function public.pt_remove(p_match uuid, p_id text)
returns public.matches language plpgsql security definer set search_path to 'public' as $$
declare m public.matches; st jsonb; v_name text;
begin
  m := public.cn_pt_lock(p_match);
  st := m.state;
  select q->>'name' into v_name from jsonb_array_elements(coalesce(st->'units', '[]'::jsonb)) q where q->>'id' = p_id;
  st := jsonb_set(st, '{units}', coalesce((select jsonb_agg(q) from jsonb_array_elements(coalesce(st->'units', '[]'::jsonb)) q
                                            where q->>'id' <> p_id), '[]'::jsonb));
  st := jsonb_set(st, '{obstacles}', coalesce((select jsonb_agg(q) from jsonb_array_elements(coalesce(st->'obstacles', '[]'::jsonb)) q
                                                where q->>'id' <> p_id), '[]'::jsonb));
  if nullif(st->>'active', '') = p_id then st := jsonb_set(st, '{active}', 'null'::jsonb); end if;
  st := st - 'undo';
  st := state_log(st, 'Playtest: ' || coalesce(v_name, 'an object') || ' removed.');
  update public.matches set state = st, updated_at = now() where id = m.id returning * into m;
  return m;
end $$;

-- Hand a unit to a team, mid-turn or not.
create or replace function public.pt_owner(p_match uuid, p_unit text, p_owner text)
returns public.matches language plpgsql security definer set search_path to 'public' as $$
declare m public.matches; st jsonb; v_name text;
begin
  m := public.cn_pt_lock(p_match);
  if p_owner not in ('host', 'guest') then raise exception 'bad team'; end if;
  st := m.state;
  select q->>'name' into v_name from jsonb_array_elements(coalesce(st->'units', '[]'::jsonb)) q where q->>'id' = p_unit;
  if v_name is null then raise exception 'no such unit'; end if;
  st := jsonb_set(st, '{units}', (
    select jsonb_agg(case when q->>'id' = p_unit
      then ((q - 'defendedBy') - 'defendedSelf') || jsonb_build_object('owner', p_owner, 'defending', false)
      else q end) from jsonb_array_elements(st->'units') q));
  if nullif(st->>'active', '') = p_unit then st := jsonb_set(st, '{active}', 'null'::jsonb); end if;
  st := st - 'undo';
  st := state_log(st, 'Playtest: ' || v_name || ' now fights for the '
        || case when p_owner = 'host' then 'Red' else 'Blue' end || ' team.');
  update public.matches set state = st, updated_at = now() where id = m.id returning * into m;
  return m;
end $$;

-- Full health, no afflictions, a fresh go and a fresh ability.
create or replace function public.pt_reset(p_match uuid, p_unit text)
returns public.matches language plpgsql security definer set search_path to 'public' as $$
declare m public.matches; st jsonb; v_name text;
begin
  m := public.cn_pt_lock(p_match);
  st := m.state;
  select q->>'name' into v_name from jsonb_array_elements(coalesce(st->'units', '[]'::jsonb)) q where q->>'id' = p_unit;
  if v_name is null then raise exception 'no such unit'; end if;
  st := jsonb_set(st, '{units}', (
    select jsonb_agg(case when q->>'id' = p_unit
      then ((q - 'defendedBy') - 'defendedSelf') || jsonb_build_object(
             'hp', q->'maxHp', 'effects', cn_no_effects(), 'moved', false, 'acted', false,
             'spent', false, 'defending', false, 'forcedParry', false,
             'abilityUses', 0, 'abilityLastUsedTurn', null, 'effectFires', '{}'::jsonb)
      else q end) from jsonb_array_elements(st->'units') q));
  if nullif(st->>'active', '') = p_unit then st := jsonb_set(st, '{active}', 'null'::jsonb); end if;
  st := st - 'undo';
  st := state_log(st, 'Playtest: ' || v_name || ' is restored.');
  update public.matches set state = st, updated_at = now() where id = m.id returning * into m;
  return m;
end $$;

-- 'trees' re-rolls the trees (never onto a unit or another structure), 'units'
-- empties the armies, 'all' empties the whole board.
create or replace function public.pt_clear(p_match uuid, p_what text)
returns public.matches language plpgsql security definer set search_path to 'public' as $$
declare m public.matches; st jsonb; w int; h int; v_trees jsonb; v_keep jsonb;
begin
  m := public.cn_pt_lock(p_match);
  if p_what not in ('units', 'trees', 'all') then raise exception 'bad clear'; end if;
  st := m.state;
  w := (st->'board'->>'w')::int; h := (st->'board'->>'h')::int;
  if p_what in ('units', 'all') then
    st := jsonb_set(st, '{units}', '[]'::jsonb);
    st := jsonb_set(st, '{active}', 'null'::jsonb);
    st := jsonb_set(st, '{acts}', '0'::jsonb);
    st := (st - 'undo') - 'pending';
  end if;
  if p_what = 'all' then
    st := jsonb_set(st, '{obstacles}', '[]'::jsonb);
  elsif p_what = 'trees' then
    v_keep := coalesce((
      select jsonb_agg(o) from jsonb_array_elements(coalesce(st->'obstacles', '[]'::jsonb)) o
       where o->>'kind' <> 'tree'), '[]'::jsonb);
    v_trees := coalesce((
      select jsonb_agg(t) from jsonb_array_elements(public.cn_gen_trees(w, h)) t
       where not exists (select 1 from jsonb_array_elements(coalesce(st->'units', '[]'::jsonb)) q
                          where (q->>'x')::int = (t->>'x')::int and (q->>'y')::int = (t->>'y')::int)
         and not exists (select 1 from jsonb_array_elements(v_keep) o
                          where (o->>'x')::int = (t->>'x')::int and (o->>'y')::int = (t->>'y')::int)
    ), '[]'::jsonb);
    st := jsonb_set(st, '{obstacles}', v_trees || v_keep);
  end if;
  st := state_log(st, 'Playtest: ' || case p_what when 'units' then 'the armies are cleared.'
                                             when 'trees' then 'new trees.' else 'a clean board.' end);
  update public.matches set state = st, updated_at = now() where id = m.id returning * into m;
  return m;
end $$;

revoke all on function public.pt_new() from public, anon;
revoke all on function public.pt_drop(uuid, text, text, integer, integer) from public, anon;
revoke all on function public.pt_object(uuid, text, text, integer, integer) from public, anon;
revoke all on function public.pt_remove(uuid, text) from public, anon;
revoke all on function public.pt_owner(uuid, text, text) from public, anon;
revoke all on function public.pt_reset(uuid, text) from public, anon;
revoke all on function public.pt_clear(uuid, text) from public, anon;
grant execute on function public.pt_new() to authenticated;
grant execute on function public.pt_drop(uuid, text, text, integer, integer) to authenticated;
grant execute on function public.pt_object(uuid, text, text, integer, integer) to authenticated;
grant execute on function public.pt_remove(uuid, text) to authenticated;
grant execute on function public.pt_owner(uuid, text, text) to authenticated;
grant execute on function public.pt_reset(uuid, text) to authenticated;
grant execute on function public.pt_clear(uuid, text) to authenticated;
