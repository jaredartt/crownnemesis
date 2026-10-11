-- 0219: playtest extras -- undo, stat editing, saved board setups. Admin only,
-- every call goes through cn_pt_lock() (super admin + a playtest room).
--
--  * Undo: a BEFORE UPDATE trigger on playtest rooms keeps the last 25 board
--    states (without their log) in playtest_undo; pt_undo() puts the newest back,
--    keeping the live log and adding a line. pt_undo sets cn.pt_undoing so the
--    restore itself is not recorded as a new step.
--  * pt_edit(): sets one number on one unit -- hp, maxHp, mov, rmin, rmax, dmin,
--    dmax, pow, critPct, parryPct, evasionPct -- clamped, keeping pairs consistent
--    (hp <= maxHp, dmin <= dmax, rmin <= rmax). "Always crit" is critPct = 100, etc.
--  * Saved setups: pt_save() stores the units, obstacles, whose turn, turn number,
--    goes spent and the drop counter; pt_load() puts them back on the board.
create table if not exists public.playtest_undo (
  match_id uuid primary key,
  snaps jsonb not null default '[]'::jsonb
);
alter table public.playtest_undo enable row level security;

create table if not exists public.playtest_scenarios (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null default auth.uid(),
  name text not null,
  board jsonb not null,
  archived boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.playtest_scenarios enable row level security;
create policy playtest_scenarios_admin on public.playtest_scenarios for select to authenticated using (public.cn_is_super_admin());

create or replace function public.cn_pt_snapshot() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare cur jsonb; n int;
begin
  if current_setting('cn.pt_undoing', true) = '1' then return new; end if;
  select snaps into cur from public.playtest_undo where match_id = old.id;
  cur := coalesce(cur, '[]'::jsonb) || jsonb_build_array(old.state - 'log');
  n := jsonb_array_length(cur);
  if n > 25 then
    select coalesce(jsonb_agg(x order by o), '[]'::jsonb) into cur
      from jsonb_array_elements(cur) with ordinality t(x, o) where o > n - 25;
  end if;
  insert into public.playtest_undo(match_id, snaps) values (old.id, cur)
    on conflict (match_id) do update set snaps = excluded.snaps;
  return new;
end $$;

create or replace trigger cn_pt_snapshot_trg before update of state on public.matches
  for each row when (old.playtest and new.state is distinct from old.state)
  execute function public.cn_pt_snapshot();

create or replace function public.pt_undo(p_match uuid) returns public.matches
language plpgsql security definer set search_path to 'public' as $$
declare m public.matches; cur jsonb; n int; snap jsonb; st jsonb;
begin
  m := public.cn_pt_lock(p_match);
  select snaps into cur from public.playtest_undo where match_id = p_match;
  n := coalesce(jsonb_array_length(cur), 0);
  if n = 0 then raise exception 'nothing to undo'; end if;
  snap := cur -> (n - 1);
  st := snap || jsonb_build_object('log', coalesce(m.state -> 'log', '[]'::jsonb));
  st := public.state_log(st, 'Playtest: last action undone.');
  perform set_config('cn.pt_undoing', '1', true);
  update public.matches set state = st, updated_at = now() where id = m.id returning * into m;
  perform set_config('cn.pt_undoing', '0', true);
  update public.playtest_undo set snaps = cur - (n - 1) where match_id = p_match;
  return m;
end $$;

create or replace function public.pt_edit(p_match uuid, p_unit text, p_field text, p_value integer) returns public.matches
language plpgsql security definer set search_path to 'public' as $$
declare m public.matches; st jsonb; v_name text; v int; u jsonb;
begin
  m := public.cn_pt_lock(p_match);
  if p_field not in ('hp','maxHp','mov','rmin','rmax','dmin','dmax','pow','critPct','parryPct','evasionPct') then
    raise exception 'that stat cannot be edited';
  end if;
  v := case when p_field in ('critPct','parryPct','evasionPct') then greatest(0, least(100, p_value))
            when p_field in ('hp','maxHp') then greatest(1, least(999, p_value))
            else greatest(0, least(99, p_value)) end;
  st := m.state;
  select q into u from jsonb_array_elements(coalesce(st->'units','[]'::jsonb)) q where q->>'id' = p_unit;
  if u is null then raise exception 'no such unit'; end if;
  v_name := u->>'name';
  u := jsonb_set(u, array[p_field], to_jsonb(v));
  if p_field = 'maxHp' and (u->>'hp')::int > v then u := jsonb_set(u, '{hp}', to_jsonb(v)); end if;
  if p_field = 'hp' and v > (u->>'maxHp')::int then u := jsonb_set(u, '{maxHp}', to_jsonb(v)); end if;
  if p_field = 'dmin' and v > (u->>'dmax')::int then u := jsonb_set(u, '{dmax}', to_jsonb(v)); end if;
  if p_field = 'dmax' and v < (u->>'dmin')::int then u := jsonb_set(u, '{dmin}', to_jsonb(v)); end if;
  if p_field = 'rmin' and v > (u->>'rmax')::int then u := jsonb_set(u, '{rmax}', to_jsonb(v)); end if;
  if p_field = 'rmax' and v < (u->>'rmin')::int then u := jsonb_set(u, '{rmin}', to_jsonb(v)); end if;
  st := jsonb_set(st, '{units}', (select jsonb_agg(case when q->>'id' = p_unit then u else q end) from jsonb_array_elements(st->'units') q));
  st := public.state_log(st, 'Playtest: ' || v_name || ' ' || p_field || ' set to ' || v || '.');
  update public.matches set state = st, updated_at = now() where id = m.id returning * into m;
  return m;
end $$;

create or replace function public.pt_save(p_match uuid, p_name text) returns public.playtest_scenarios
language plpgsql security definer set search_path to 'public' as $$
declare m public.matches; r public.playtest_scenarios; nm text;
begin
  m := public.cn_pt_lock(p_match);
  nm := left(btrim(coalesce(p_name, '')), 60);
  if nm = '' then raise exception 'give the setup a name'; end if;
  insert into public.playtest_scenarios(owner, name, board)
    values (auth.uid(), nm, jsonb_build_object(
      'units', coalesce(m.state->'units','[]'::jsonb), 'obstacles', coalesce(m.state->'obstacles','[]'::jsonb),
      'turn', m.state->'turn', 'turnNumber', m.state->'turnNumber', 'acts', m.state->'acts', 'ptSeq', m.state->'ptSeq'))
    returning * into r;
  return r;
end $$;

create or replace function public.pt_scenarios() returns setof public.playtest_scenarios
language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.cn_is_super_admin() then raise exception 'playtest is admin only'; end if;
  return query select * from public.playtest_scenarios where not archived order by created_at desc limit 100;
end $$;

-- Setups are archived, not removed: the list hides them, the rows stay.
create or replace function public.pt_scenario_archive(p_id uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.cn_is_super_admin() then raise exception 'playtest is admin only'; end if;
  update public.playtest_scenarios set archived = true where id = p_id;
end $$;

create or replace function public.pt_load(p_match uuid, p_scenario uuid) returns public.matches
language plpgsql security definer set search_path to 'public' as $$
declare m public.matches; st jsonb; b jsonb; nm text;
begin
  m := public.cn_pt_lock(p_match);
  select board, name into b, nm from public.playtest_scenarios where id = p_scenario and not archived;
  if b is null then raise exception 'setup not found'; end if;
  st := m.state;
  st := st || jsonb_build_object('units', b->'units', 'obstacles', b->'obstacles', 'turn', b->'turn',
          'turnNumber', b->'turnNumber', 'acts', b->'acts', 'ptSeq', b->'ptSeq',
          'active', null, 'winner', null, 'phase', 'battle', 'graveyard', jsonb_build_object('host','[]'::jsonb,'guest','[]'::jsonb));
  st := st - 'undo';
  st := public.state_log(st, 'Playtest: setup "' || nm || '" loaded.');
  update public.matches set state = st, updated_at = now() where id = m.id returning * into m;
  return m;
end $$;

revoke all on function public.pt_undo(uuid), public.pt_edit(uuid,text,text,integer), public.pt_save(uuid,text), public.pt_scenarios(), public.pt_scenario_archive(uuid), public.pt_load(uuid,uuid), public.cn_pt_snapshot() from public, anon, authenticated;
grant execute on function public.pt_undo(uuid), public.pt_edit(uuid,text,text,integer), public.pt_save(uuid,text), public.pt_scenarios(), public.pt_scenario_archive(uuid), public.pt_load(uuid,uuid) to authenticated;
