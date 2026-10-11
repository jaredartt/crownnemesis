-- 0215: the game rules are settings. Admin Mode -> Rules edits them live.
--
-- Seven numbers that used to be literals scattered through the engine become
-- columns on the app_settings singleton, each read FRESH by a tiny function, so
-- a change applies on the next thing that needs it with no redeploy:
--
--   turn_seconds      cn_action_seconds()   the per-turn clock (was 30)
--   deploy_seconds    cn_deploy_seconds()   the deployment clock (was 90)
--   turn_cap          cn_turn_cap()         turns before the match is a draw (was 40)
--   stalemate_rounds  cn_stalemate_rounds() rounds with no damage before a draw (was 5)
--   opening_acts      cn_acts_cap()         goes on turn 1 (was 1)
--   acts_per_turn     cn_acts_cap()         goes on every later turn (was 2)
--   trees_per_half    cn_gen_trees()        trees per half of a new board (was 4)
--
-- Battle Royale: its generated functions follow the clock, the deployment time
-- and the stalemate rule (advance_turn_royale is rebuilt from advance_turn by the
-- event trigger of 0179), but keep their own single go per turn, on purpose.
--
-- Trees: the board only has room for 4 per half (a 5th silently fell back to the
-- old fixed layout), so cn_gen_trees clamps to 0..4 and the admin UI offers 0..4.

alter table public.app_settings
  add column if not exists turn_seconds     int not null default 30  constraint app_settings_turn_seconds_check     check (turn_seconds between 10 and 180),
  add column if not exists deploy_seconds   int not null default 90  constraint app_settings_deploy_seconds_check   check (deploy_seconds between 20 and 600),
  add column if not exists turn_cap         int not null default 40  constraint app_settings_turn_cap_check         check (turn_cap between 6 and 200),
  add column if not exists stalemate_rounds int not null default 5   constraint app_settings_stalemate_rounds_check check (stalemate_rounds between 2 and 30),
  add column if not exists opening_acts     int not null default 1   constraint app_settings_opening_acts_check     check (opening_acts between 1 and 5),
  add column if not exists acts_per_turn    int not null default 2   constraint app_settings_acts_per_turn_check    check (acts_per_turn between 1 and 5),
  add column if not exists trees_per_half   int not null default 4   constraint app_settings_trees_per_half_check   check (trees_per_half between 0 and 5);

create or replace function public.cn_action_seconds() returns integer
language sql stable set search_path to 'public' as
$$ select coalesce((select turn_seconds from public.app_settings where id), 30) $$;

create or replace function public.cn_deploy_seconds() returns integer
language sql stable set search_path to 'public' as
$$ select coalesce((select deploy_seconds from public.app_settings where id), 90) $$;

create or replace function public.cn_turn_cap() returns integer
language sql stable set search_path to 'public' as
$$ select coalesce((select turn_cap from public.app_settings where id), 40) $$;

create or replace function public.cn_stalemate_rounds() returns integer
language sql stable set search_path to 'public' as
$$ select coalesce((select stalemate_rounds from public.app_settings where id), 5) $$;

create or replace function public.cn_acts_cap(p_st jsonb) returns integer
language sql stable set search_path to 'public' as
$$ select case when coalesce((p_st->>'turnNumber')::int, 1) <= 1
       then coalesce((select opening_acts from public.app_settings where id), 1)
       else coalesce((select acts_per_turn from public.app_settings where id), 2) end $$;

-- cn_gen_trees: v_per trees a half instead of a fixed 4 (everything else as 0213 left it).
create or replace function public.cn_gen_trees(p_w integer, p_h integer)
returns jsonb language plpgsql as $$
declare
  v_per int := least(4, greatest(0, coalesce((select trees_per_half from public.app_settings where id), 4))); v_try int; v_band int; v_lo int; v_hi int; v_n int;
  v_cand int[]; v_pick int[] := '{}'::int[]; v_ok boolean;
  i int; j int; v_x int; v_y int; v_px int; v_py int;
  v_out jsonb := '[]'::jsonb; v_k int := 0;
begin
  for v_try in 1..80 loop
    v_pick := '{}'::int[];
    for v_band in 0..1 loop
      if v_band = 0 then v_lo := 0; v_hi := p_h / 2 - 1;
                    else v_lo := p_h / 2; v_hi := p_h - 1; end if;

      select array_agg(t) into v_cand from (
        select gy.y * p_w + gx.x as t
          from generate_series(0, p_w - 1) as gx(x),
               generate_series(v_lo, v_hi) as gy(y)
         where gy.y <> 0 and gy.y <> p_h - 1
           and not ((gx.x = 0 or gx.x = p_w - 1) and (gy.y = 0 or gy.y = p_h - 1))
         order by random()) s;

      v_n := 0;
      foreach i in array v_cand loop
        exit when v_n = v_per;
        v_x := i % p_w; v_y := i / p_w;
        v_ok := true;
        foreach j in array v_pick loop
          v_px := j % p_w; v_py := j / p_w;
          -- Literal Chebyshev, not cn_cheb -- see 0076's header.
          if greatest(abs(v_x - v_px), abs(v_y - v_py)) < 2 then v_ok := false; exit; end if;
        end loop;
        if v_ok then v_pick := v_pick || i; v_n := v_n + 1; end if;
      end loop;
      exit when v_n < v_per;
    end loop;
    exit when coalesce(array_length(v_pick, 1), 0) = 2 * v_per;
  end loop;

  if coalesce(array_length(v_pick, 1), 0) <> 2 * v_per then
    v_pick := array[ 1 * p_w + 0, 1 * p_w + 2, 1 * p_w + 4,
                     (p_h / 2 - 1) * p_w + 1,
                     (p_h - 2) * p_w + 1, (p_h - 2) * p_w + 3,
                     (p_h - 2) * p_w + 5, (p_h / 2) * p_w + 4 ];
    v_pick := v_pick[1:2 * v_per];
  end if;

  foreach i in array v_pick loop
    v_k := v_k + 1;
    v_out := v_out || jsonb_build_object(
      'id', 't' || v_k, 'kind', 'tree', 'x', i % p_w, 'y', i / p_w,
      'hp', cn_obj_hp('tree'), 'maxHp', cn_obj_hp('tree'));
  end loop;
  return v_out;
end
$$;

-- Patch the existing functions that carried the old literals. Written as
-- replace-if-present, like 0179 and 0213, so it is safe to run twice and does not
-- need the whole of each function copied here.
do $$
declare r record; d text; n text; k int := 0;
begin
  for r in select oid, proname from pg_proc where pronamespace = 'public'::regnamespace loop
    d := pg_get_functiondef(r.oid);
    n := d;
    -- deployment time: join_match, request_rematch, ranked_tick, cn_tourney_spawn, create_bot_match
    n := replace(n, 'now() + interval ''90 seconds''', 'now() + make_interval(secs => cn_deploy_seconds())');
    if r.proname like 'advance\_turn%' then
      n := replace(n, 'if v_turn > 40 and not m.playtest then', 'if v_turn > cn_turn_cap() and not m.playtest then');
      n := replace(n, '''Turn limit reached (40 turns) -- no decisive winner. The match is a draw.''',
                      '''Turn limit reached ('' || cn_turn_cap() || '' turns) -- no decisive winner. The match is a draw.''');
      n := replace(n, '''staleRounds'')::int, 0) >= 5', '''staleRounds'')::int, 0) >= cn_stalemate_rounds()');
      n := replace(n, '''Stalemate -- no damage dealt for five rounds. The match is a draw.''',
                      '''Stalemate -- no damage dealt for '' || cn_stalemate_rounds() || '' rounds. The match is a draw.''');
    end if;
    if n is distinct from d then execute n; k := k + 1; end if;
  end loop;
  raise notice '0215: patched % functions', k;
end $$;
