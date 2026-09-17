-- ===========================================================================
--  HOW TO RUN THIS
--  Supabase dashboard -> SQL Editor -> New query -> paste this whole file ->
--  Run. Safe to run twice.
-- ===========================================================================
--  0054 -- Battle Royale: blind deployment (the fog of war 0048 skipped)
--
--  0048's own header named this gap plainly: "Deployment hiding: 1v1 hides
--  each side's half behind match_deploy until both are ready. Royale skips
--  that -- every seat's placement is visible in the shared match row as
--  soon as it is made... a real hidden-deploy scheme would need one
--  match_deploy-style row per seat." This is that table.
--
--  `royale_deploy` mirrors `match_deploy` (0008) exactly: one row per seat,
--  RLS restricted to `user_id = auth.uid()`, no write policy at all (every
--  write goes through a SECURITY DEFINER RPC, same as everywhere else in
--  this project). A bot seat's row has user_id = null, so -- exactly like
--  the 1v1 bot's match_deploy row -- it matches nobody's auth.uid() and is
--  invisible to every human at the table, including the one sitting next
--  to it.
--
--  `state->pendingUnits` is retired. `start_royale_match` now inserts each
--  seat's freshly-built army into `royale_deploy` instead of folding it into
--  the shared jsonb; `deploy_royale_unit` reads and writes that seat's own
--  row (locked with its own `for update`, which is also a small concurrency
--  win over the previous version's whole-match-row lock -- four seats
--  placing at once no longer serialise behind each other); and
--  `cn_royale_mark_ready`'s fold-into-battle step, the one moment every
--  seat's placement is legitimately allowed to become visible to everyone,
--  reads every seat's row out of `royale_deploy` the instant the last
--  Ready comes in. A new `my_royale_deploy(p_match)` RPC is `my_deploy`'s
--  royale sibling -- it hands back the caller's own row and nothing else.
--
--  Nothing here touches combat, elimination, AFK/stalemate tracking, or the
--  bot path beyond the one seeding change above -- `royale_bot_step` never
--  looks at pendingUnits or royale_deploy at all, and a bot seat is marked
--  ready (and its units folded in) through the exact same
--  `cn_royale_mark_ready` call a human's Ready button uses.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------

-- deploy_royale_unit's return type is changing (royale_matches -> jsonb, see
-- below) -- Postgres refuses a create-or-replace across a return-type change,
-- so the old signature has to go first. Safe to run twice: a second run finds
-- nothing to drop.
drop function if exists public.deploy_royale_unit(uuid, text, int, int);

create table if not exists public.royale_deploy (
  match_id uuid not null references public.royale_matches(id) on delete cascade,
  seat     int  not null check (seat between 0 and 3),
  user_id  uuid references public.profiles(id) on delete cascade,
  units    jsonb not null,
  primary key (match_id, seat)
);

alter table public.royale_deploy enable row level security;

drop policy if exists "see only your own royale deployment" on public.royale_deploy;
create policy "see only your own royale deployment"
  on public.royale_deploy for select to authenticated
  using (user_id = auth.uid());

revoke insert, update, delete on public.royale_deploy from anon, authenticated;

-- ---------------------------------------------------------------------------
-- start_royale_match: seed royale_deploy instead of state->pendingUnits.
-- Identical to 0052's version otherwise -- same bot-deck fallback, same
-- immediate cn_royale_mark_ready() pass for any bot seats.
-- ---------------------------------------------------------------------------
create or replace function public.start_royale_match(p_match uuid)
returns royale_matches language plpgsql security definer set search_path to 'public' as $$
declare
  m public.royale_matches; v_uid uuid := auth.uid(); v_st jsonb;
  rp record; v_deck text[]; v_army jsonb; v_count int;
begin
  select * into m from public.royale_matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'waiting' then raise exception 'this match has already started'; end if;

  if not exists (
    select 1 from public.royale_players
     where match_id = p_match and seat = 0 and user_id = v_uid) then
    raise exception 'only the host can start the match';
  end if;

  select count(*) into v_count from public.royale_players where match_id = p_match;
  if v_count < 2 then raise exception 'wait for at least one more player'; end if;

  v_st := m.state;
  for rp in select * from public.royale_players where match_id = p_match order by seat loop
    v_deck := case when rp.bot is not null then random_deck() else deck_of(rp.user_id) end;
    v_army := cn_royale_army(v_st, rp.seat, v_deck);
    insert into public.royale_deploy (match_id, seat, user_id, units)
    values (p_match, rp.seat, rp.user_id, v_army)
    on conflict (match_id, seat) do update set units = excluded.units, user_id = excluded.user_id;
  end loop;

  v_st := jsonb_set(v_st, '{phase}', '"deploy"'::jsonb, true);
  v_st := state_log(v_st, 'Place your units, then press Ready.');

  update public.royale_matches
     set state = v_st, status = 'deploying',
         turn_deadline = now() + interval '90 seconds', updated_at = now()
   where id = m.id returning * into m;

  for rp in select * from public.royale_players
             where match_id = p_match and bot is not null order by seat loop
    m := cn_royale_mark_ready(p_match, rp.seat, rp.username);
  end loop;

  return m;
end
$$;

-- ---------------------------------------------------------------------------
-- deploy_royale_unit: reposition inside YOUR OWN royale_deploy row. Same
-- swap behaviour as before (and as 1v1's deploy_unit), just reading and
-- writing the hidden table instead of the visible jsonb path. Returns your
-- own updated units, matching deploy_unit()'s own return shape -- not the
-- whole match row, since nothing about the match row changes here anymore.
-- ---------------------------------------------------------------------------
create or replace function public.deploy_royale_unit(p_match uuid, p_unit_id text, p_x int, p_y int)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  m public.royale_matches; v_seat int; v_ready boolean; v_st jsonb; v_units jsonb;
  u jsonb; e jsonb; v_me jsonb; v_swap jsonb; v_out jsonb := '[]'::jsonb; v_w int; v_h int;
begin
  select * into m from public.royale_matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'deploying' then raise exception 'deployment is over'; end if;

  select seat, ready into v_seat, v_ready from public.royale_players
   where match_id = p_match and user_id = auth.uid();
  if v_seat is null then raise exception 'you are not seated in this match'; end if;
  if v_ready then raise exception 'you are already ready'; end if;

  v_st := m.state;
  v_w := (v_st->'board'->>'w')::int;
  v_h := (v_st->'board'->>'h')::int;

  select units into v_units from public.royale_deploy
   where match_id = p_match and seat = v_seat for update;
  if v_units is null then raise exception 'nothing to deploy'; end if;

  for u in select * from jsonb_array_elements(v_units) loop
    if u->>'id' = p_unit_id then v_me := u; end if;
    if (u->>'x')::int = p_x and (u->>'y')::int = p_y then v_swap := u; end if;
  end loop;
  if v_me is null then raise exception 'that is not your unit'; end if;

  if p_x < 0 or p_y < 0 or p_x >= v_w or p_y >= v_h then raise exception 'off the board'; end if;
  if not cn_own_royale(p_x, p_y, v_seat) then raise exception 'that is not your zone'; end if;

  for e in select * from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) loop
    if (e->>'x')::int = p_x and (e->>'y')::int = p_y then
      raise exception 'there is a tree there';
    end if;
  end loop;

  for u in select * from jsonb_array_elements(v_units) loop
    if u->>'id' = p_unit_id then
      u := jsonb_set(jsonb_set(u, '{x}', to_jsonb(p_x)), '{y}', to_jsonb(p_y));
    elsif v_swap is not null and u->>'id' = v_swap->>'id' then
      u := jsonb_set(jsonb_set(u, '{x}', v_me->'x'), '{y}', v_me->'y');
    end if;
    v_out := v_out || u;
  end loop;

  update public.royale_deploy set units = v_out
   where match_id = p_match and seat = v_seat;
  return v_out;
end
$$;

-- ---------------------------------------------------------------------------
-- my_royale_deploy: my_deploy()'s royale sibling. Your own pending army, or
-- null once the match has started for real (both check(s) match my_deploy's
-- own: no seat, no row -- null either way, never an error, since the
-- caller polls this every render).
-- ---------------------------------------------------------------------------
create or replace function public.my_royale_deploy(p_match uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_seat int; v_units jsonb;
begin
  select seat into v_seat from public.royale_players
   where match_id = p_match and user_id = auth.uid();
  if v_seat is null then return null; end if;
  select units into v_units from public.royale_deploy
   where match_id = p_match and seat = v_seat;
  return v_units;
end
$$;

-- ---------------------------------------------------------------------------
-- cn_royale_mark_ready: fold every seat's royale_deploy row onto the board
-- the instant the last Ready comes in -- the one moment this is allowed to
-- become visible to everyone. Byte-for-byte the same statements as 0052's
-- version except where it reads the pending army from.
-- ---------------------------------------------------------------------------
create or replace function public.cn_royale_mark_ready(p_match uuid, p_seat int, p_name text)
returns royale_matches language plpgsql security definer set search_path to 'public' as $$
declare
  m public.royale_matches; v_st jsonb; v_all_ready boolean;
  rp record; v_seat_units jsonb; v_units jsonb; v_first int; v_first_name text;
begin
  select * into m from public.royale_matches where id = p_match for update;
  if m.id is null then raise exception 'no such match'; end if;
  if m.status <> 'deploying' then raise exception 'deployment is over'; end if;

  update public.royale_players set ready = true
   where match_id = p_match and seat = p_seat;
  v_st := state_log(m.state, p_name || ' is ready.');

  select bool_and(ready) into v_all_ready from public.royale_players where match_id = p_match;
  if not coalesce(v_all_ready, false) then
    update public.royale_matches set state = v_st, updated_at = now()
     where id = m.id returning * into m;
    return m;
  end if;

  v_units := '[]'::jsonb;
  for rp in select * from public.royale_players where match_id = p_match order by seat loop
    select units into v_seat_units from public.royale_deploy
     where match_id = p_match and seat = rp.seat;
    v_units := v_units || coalesce(v_seat_units, '[]'::jsonb);
  end loop;
  v_st := jsonb_set(v_st, '{units}', v_units);
  v_st := v_st - 'pendingUnits';
  v_st := jsonb_set(v_st, '{phase}', '"battle"'::jsonb);

  select seat into v_first from public.royale_players
   where match_id = p_match order by random() limit 1;
  select username into v_first_name from public.royale_players
   where match_id = p_match and seat = v_first;
  v_st := jsonb_set(v_st, '{turn}', to_jsonb(v_first));
  v_st := jsonb_set(v_st, '{turnNumber}', '1'::jsonb);
  v_st := state_log(v_st, 'Turn 1 -- ' || v_first_name || ' to act.');

  update public.royale_matches
     set state = v_st, status = 'active',
         turn_deadline = now() + interval '30 seconds', updated_at = now()
   where id = m.id returning * into m;
  return m;
end
$$;

-- ---------------------------------------------------------------------------
-- Verification -- every column below must read true.
-- ---------------------------------------------------------------------------
select
  (select relrowsecurity from pg_class where relname = 'royale_deploy') as deploy_rls_on,
  (select count(*) = 1 from pg_policies
    where tablename = 'royale_deploy' and policyname = 'see only your own royale deployment')
    as deploy_policy_present,
  (select count(*) = 0 from information_schema.table_privileges
    where table_name = 'royale_deploy' and privilege_type in ('INSERT','UPDATE','DELETE')
      and grantee in ('anon','authenticated')) as deploy_no_write_grants,
  (select prosecdef from pg_proc where proname = 'my_royale_deploy') as my_royale_deploy_is_definer,
  (select prosecdef from pg_proc where proname = 'deploy_royale_unit') as deploy_royale_unit_is_definer;
