-- Assertions and board-rigging, shared by every test file. Loaded by run.sh
-- after the stub and before the tests.
create or replace function t_ok(cond boolean, label text) returns void
language plpgsql as $$
begin
  if cond then raise notice 'PASS  %', label;
  else raise exception 'FAIL  %', label; end if;
end $$;

-- Expect the next statement to raise, and to mention `frag`.
create or replace function t_raises(sql text, frag text, label text) returns void
language plpgsql as $$
begin
  begin
    execute sql;
  exception when others then
    if position(lower(frag) in lower(SQLERRM)) > 0 then
      raise notice 'PASS  % (blocked: %)', label, SQLERRM;
      return;
    else
      raise exception 'FAIL  % — wrong error: %', label, SQLERRM;
    end if;
  end;
  raise exception 'FAIL  % — was allowed but should not be', label;
end $$;

-- RLS blocks an UPDATE by making the rows invisible rather than by raising,
-- so "was refused" here means "changed nothing".
create or replace function t_norows(sql text, label text) returns void
language plpgsql as $$
declare n int;
begin
  execute sql;
  get diagnostics n = row_count;
  if n = 0 then raise notice 'PASS  % (0 rows changed)', label;
  else raise exception 'FAIL  % — % row(s) changed', label, n; end if;
end $$;

-- ---------------------------------------------------------------------------
-- Rigging. These write the board directly, which no client can do -- that is
-- the point: a test needs a known position, not a random one.
-- ---------------------------------------------------------------------------
-- The crowns, silenced. 0031 gave the Royals auras that reach across the whole
-- board -- Dereo takes 20% off every blow a Knight lands on his side -- and
-- every deck in this suite carries a Royal, because a kingdom must. So any
-- test measuring an EXACT number is measuring the aura too unless it says
-- otherwise. This is how it says otherwise. The auras have their own file.
create or replace function t_noauras(p_m uuid) returns void language sql as $$
  update public.matches set state = jsonb_set(state, '{units}', (
    select jsonb_agg(u - 'auraKind' - 'auraClass' - 'auraPct')
      from jsonb_array_elements(state->'units') u)) where id = p_m;
$$;

create or replace function t_set(p_m uuid, p_u text, p_key text, p_val jsonb)
returns void language sql as $$
  update public.matches set state = jsonb_set(state, '{units}', (
    select jsonb_agg(case when u->>'id' = p_u then jsonb_set(u, array[p_key], p_val) else u end)
      from jsonb_array_elements(state->'units') u)) where id = p_m;
$$;

create or replace function t_place(p_m uuid, p_u text, p_x int, p_y int)
returns void language sql as $$
  select t_set(p_m, p_u, 'x', to_jsonb(p_x)), t_set(p_m, p_u, 'y', to_jsonb(p_y));
$$;

-- Light a unit. `burned` was a loose boolean until 0034 and is an entry in an
-- `effects` object now; every test that used to write the flag writes through
-- here instead, so the next shape change is one function rather than twenty
-- call sites.
create or replace function t_burn(p_m uuid, p_u text) returns void language sql as $$
  select t_set(p_m, p_u, 'effects', jsonb_build_object('burn', true, 'poison', false, 'stun', 0));
$$;
create or replace function t_poison(p_m uuid, p_u text) returns void language sql as $$
  select t_set(p_m, p_u, 'effects', jsonb_build_object('burn', false, 'poison', true, 'stun', 0));
$$;
create or replace function t_stun(p_m uuid, p_u text) returns void language sql as $$
  select t_set(p_m, p_u, 'effects', jsonb_build_object('burn', false, 'poison', false, 'stun', 1));
$$;
create or replace function t_clear(p_m uuid, p_u text) returns void language sql as $$
  select t_set(p_m, p_u, 'effects', jsonb_build_object('burn', false, 'poison', false, 'stun', 0));
$$;

create or replace function t_get(p_m uuid, p_u text, p_key text)
returns text language sql stable as $$
  select u->>p_key from public.matches m, jsonb_array_elements(m.state->'units') u
   where m.id = p_m and u->>'id' = p_u;
$$;

create or replace function t_alive(p_m uuid, p_u text) returns boolean
language sql stable as $$
  select exists (select 1 from public.matches m, jsonb_array_elements(m.state->'units') u
                  where m.id = p_m and u->>'id' = p_u);
$$;

create or replace function t_fx(p_m uuid, p_key text) returns text
language sql stable as $$ select state->'fx'->>p_key from public.matches where id = p_m $$;

create or replace function t_trees(p_m uuid, p_trees jsonb) returns void
language sql as $$
  update public.matches set state = jsonb_set(state, '{obstacles}', p_trees) where id = p_m;
$$;

create or replace function t_tree_hp(p_m uuid, p_t text) returns int
language sql stable as $$
  select (o->>'hp')::int from public.matches m, jsonb_array_elements(m.state->'obstacles') o
   where m.id = p_m and o->>'id' = p_t;
$$;

-- ---------------------------------------------------------------------------
-- Board objects (0035). `obstacles` stopped meaning "trees" and started
-- meaning "objects", so t_tree_hp above reads any of them and these three
-- exist so a test never has to spell the jsonb path itself.
-- ---------------------------------------------------------------------------
create or replace function t_objs(p_m uuid) returns jsonb
language sql stable as $$
  select coalesce(state->'obstacles', '[]'::jsonb) from public.matches where id = p_m;
$$;

/** How many objects of a kind are standing. Reads a missing `kind` as 'tree',
 *  exactly as cn_obj_kind does, so a pre-0035 row counts as what it is. */
create or replace function t_nobj(p_m uuid, p_kind text) returns int
language sql stable as $$
  select count(*)::int from jsonb_array_elements(t_objs(p_m)) e
   where coalesce(e->>'kind', 'tree') = p_kind;
$$;

/** One field of whatever object is standing on a tile; null if none is. */
create or replace function t_obj_at(p_m uuid, p_x int, p_y int, p_key text)
returns text language sql stable as $$
  select e->>p_key from jsonb_array_elements(t_objs(p_m)) e
   where (e->>'x')::int = p_x and (e->>'y')::int = p_y;
$$;

-- ---------------------------------------------------------------------------
-- The pending decision (0036). One field of whatever decision is open, or
-- null when none is -- which is the shape every assertion about it wants.
-- ---------------------------------------------------------------------------
create or replace function t_pending(p_m uuid, p_key text) returns text
language sql stable as $$
  select state->'pending'->>p_key from public.matches where id = p_m;
$$;

/** Push a deadline into the past so force_timeout has something to do. The
 *  two-second slack every shell allows is included, or the expiry lands
 *  inside it and nothing happens. */
create or replace function t_expire(p_m uuid) returns void
language sql as $$
  update public.matches set turn_deadline = now() - interval '5 seconds'
   where id = p_m;
$$;

-- Give a unit a fixed profile so a test can assert an exact number instead of
-- a band. Everything else about it -- reach, counter reach, burn -- is left
-- alone, because that is usually what is under test.
create or replace function t_dmg(p_m uuid, p_u text, p_d int) returns void
language sql as $$
  select t_set(p_m, p_u, 'dmin', to_jsonb(p_d)), t_set(p_m, p_u, 'dmax', to_jsonb(p_d));
$$;

create or replace function t_hp(p_m uuid, p_u text, p_hp int) returns void
language sql as $$ select t_set(p_m, p_u, 'hp', to_jsonb(p_hp)); $$;

-- Open a room, seat both players, deploy nothing, start the match.
create or replace function t_match(p_host uuid, p_guest uuid, out mid uuid)
language plpgsql as $$
declare c text;
begin
  perform set_config('app.uid', p_host::text, false);
  select id, code into mid, c from public.create_match();
  perform set_config('app.uid', p_guest::text, false);
  perform public.join_match(c);
  perform public.set_ready(mid);
  perform set_config('app.uid', p_host::text, false);
  perform public.set_ready(mid);
end $$;

-- Clear every unit's move/attack flags without ending the turn, so one test
-- match can play out a dozen separate exchanges.
--
-- Since 0019 a turn is also a budget of two activations, and "without ending
-- the turn" has to mean that too: the flags below are per unit, but 'acts' and
-- 'active' are per turn, and a reset that left them alone would hand the next
-- assertion an 'no actions left this turn' instead of the rule it was written
-- to test. Most of this suite is testing reach, or a counter, or an ability --
-- not the budget. The budget is 10_board.sql's job, and that file never calls
-- this.
create or replace function t_reset(p_m uuid) returns void
language sql as $$
  update public.matches set state =
    jsonb_set(
      jsonb_set(
        jsonb_set(state, '{units}', (
          select jsonb_agg(jsonb_set(jsonb_set(jsonb_set(
                   u, '{moved}', 'false'), '{acted}', 'false'), '{spent}', 'false'))
            from jsonb_array_elements(state->'units') u)),
        '{acts}', '0'::jsonb),
      '{active}', 'null'::jsonb)
   where id = p_m;
$$;

-- Park an army out of the way so a test can reason about two units alone.
-- Each side goes along its own home row: since 0019 the halves are top and
-- bottom, so the two rows are seven apart on an eight-tall board -- further
-- than anything can reach, where the old back columns were five apart on a
-- six-wide one. Counting per side and not across the whole list matters -- a
-- single counter walked the guests off the far edge, where nothing could ever
-- be attacked and a test would silently assert about a unit standing outside
-- the board.
create or replace function t_park(p_m uuid, p_ids text[]) returns void
language plpgsql as $$
declare hi int := 0; gi int := 0; u text; v_h int;
begin
  select (state->'board'->>'h')::int into v_h from public.matches where id = p_m;
  foreach u in array p_ids loop
    if left(u, 1) = 'h'
      then perform t_place(p_m, u, hi, 0);         hi := hi + 1;
      else perform t_place(p_m, u, gi, v_h - 1);   gi := gi + 1;
    end if;
  end loop;
end $$;

-- Back to full health, whatever card it happens to be. A test that grinds a
-- unit down over several assertions and then asserts "it took damage" reads
-- as flaky when what actually happened is that the unit died three lines ago.
create or replace function t_full(p_m uuid, p_u text) returns void
language sql as $$
  select t_set(p_m, p_u, 'hp',
               (select u->'maxHp' from public.matches m, jsonb_array_elements(m.state->'units') u
                 where m.id = p_m and u->>'id' = p_u));
$$;

-- ---------------------------------------------------------------------------
-- During deployment the two armies are not in the match row at all -- that is
-- the point of it -- so reading and rigging them needs its own set.
-- ---------------------------------------------------------------------------
create or replace function t_dep(p_m uuid, p_side text) returns jsonb
language sql stable as $$
  select units from public.match_deploy where match_id = p_m and side = p_side;
$$;

create or replace function t_dcount(p_m uuid, p_side text) returns int
language sql stable as $$ select jsonb_array_length(t_dep(p_m, p_side)) $$;

create or replace function t_dget(p_m uuid, p_side text, p_u text, p_key text) returns text
language sql stable as $$
  select u->>p_key from public.match_deploy d, jsonb_array_elements(d.units) u
   where d.match_id = p_m and d.side = p_side and u->>'id' = p_u;
$$;

create or replace function t_dplace(p_m uuid, p_side text, p_u text, p_x int, p_y int)
returns void language sql as $$
  update public.match_deploy set units = (
    select jsonb_agg(case when u->>'id' = p_u
             then jsonb_set(jsonb_set(u, '{x}', to_jsonb(p_x)), '{y}', to_jsonb(p_y))
             else u end)
      from jsonb_array_elements(units) u)
   where match_id = p_m and side = p_side;
$$;

-- ---------------------------------------------------------------------------
-- Who acts first is a coin flip in the real game (0017). A suite that cannot
-- predict it fails one run in two, so the test database pins it. Scoped to the
-- DATABASE rather than the session on purpose: the runner opens a fresh
-- connection per test file, and a session GUC would not survive the gap.
-- Nothing outside this file ever sets it, so production keeps its coin.
-- ---------------------------------------------------------------------------
alter database t set cn.first_side = 'host';

-- Parry and crit are 5% rolls (0018). Left alone, every assertion about an
-- exchange would come apart one run in twenty, and the two rules would each
-- go untested nineteen runs in twenty. So the test database pins both OFF and
-- the files that care turn one on for a statement:
--
--   set cn.force_parry = 'always';   -- or 'never'
--   reset cn.force_parry;
--
-- Same reasoning and same shape as cn.first_side above. Production sets
-- neither, so production keeps its dice.
alter database t set cn.force_parry = 'never';
alter database t set cn.force_crit  = 'never';
