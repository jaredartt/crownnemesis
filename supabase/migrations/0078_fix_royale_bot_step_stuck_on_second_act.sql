-- 0078_fix_royale_bot_step_stuck_on_second_act.sql
--
-- Jared: "sometimes in 4-player mode, some bots just freeze and let their
-- seconds pass." Confirmed against real data (royale_matches rows from
-- 2026-09-19/20): a bot's turn shows exactly one logged action ("X
-- advances") and then "RUTHLESS ran out of time." with nothing in between
-- -- no follow-up attack, no clean end-of-turn. Every retry in that window
-- was hitting the SAME failure and getting nowhere, which is why it burned
-- the whole clock rather than recovering on its own the way a single
-- dropped RPC call would (royale_bot_step already retries every 2s -- see
-- RoyaleMatch.tsx's own comment on that).
--
-- Root cause: royale_bot_step's per-unit eligibility check --
--   continue when coalesce((st->>'acts')::int, 0) >= cn_acts_cap(st)
--             and nullif(st->>'active', '') is distinct from u->>'id';
-- -- still calls the generic, 1v1-shaped cn_acts_cap(st), which returns 2
-- from turn 2 onward (0019: "1 on the opening turn, 2 after"). But 0061
-- ("royale_one_action") hardcoded royale's REAL cap to 1, always, inside
-- cn_begin_act_royale -- the function that actually charges the budget --
-- and never touched this bot-decision copy, which 0052 had fetched from
-- 1v1's bot_step before 0061 existed. From turn 2 on, the two disagree:
-- the planner (this function) believes a second unit's activation is still
-- available and may pick one to move or attack with, but the enforcer
-- (cn_begin_act_royale, called inside cn_move_royale/cn_attack_royale)
-- refuses it with 'no actions left this turn' -- an exception that aborts
-- the whole call, rolls back, and leaves the row (and match.updated_at)
-- completely unchanged. Since nothing about the board changed, the exact
-- same losing decision gets made again on the next retry, and the one
-- after that, deterministically, for as long as retries keep coming --
-- which is indistinguishable from "the bot froze" to anyone watching the
-- timer, and is exactly what the log evidence shows.
--
-- Fix: match cn_begin_act_royale's own real cap here instead of asking the
-- 1v1 function for one that was never true for royale after turn 1. Once
-- the planner and the enforcer agree, a bot with nothing left to do falls
-- straight through to `if v_bu is null then return advance_turn_royale(...)`
-- the very next call instead of retrying a doomed second action for the
-- rest of the turn -- Jared's own suggested fix ("detect if they already
-- acted... continue with the next bot or player"), just enforced at the
-- source of the wrong decision rather than papered over from the client.
--
-- Reproduced verbatim from the live pg_proc.prosrc (verified byte-for-byte
-- against the production database before writing this) except for the one
-- line that mattered. NOT YET APPLIED to the live database -- Claude's own
-- auto-approval was refused for a direct production function change, on
-- purpose (this is exactly the kind of live server-logic edit that should
-- get a human's own eyes first, the same caution the CTR question already
-- got in this session). This file is ready to review and apply.
create or replace function public.royale_bot_step(p_match uuid, p_seat integer)
returns royale_matches
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  m public.royale_matches; st jsonb; v_lvl int; v_noise numeric;
  u jsonb; t jsonb;
  v_tiles text[]; v_tile text; vx int; vy int; v_first boolean;
  v_best numeric := 0; v_bu text; v_bx int; v_by int; v_bt text;
  v_fb numeric := -1e9; v_fu text; v_fbx int; v_fby int; v_ft text;
  v_pos numeric; v_base numeric; v_act numeric; v_step_s numeric;
  v_d int; v_dmg numeric; v_ctr numeric; v_near int; v_thr int;
  v_answers boolean; v_parry boolean;
begin
  select * into m from public.royale_matches where id = p_match for update;
  if m.id is null then return m; end if;
  if m.status <> 'active' then return m; end if;
  if coalesce((m.state->>'turn')::int, -1) <> p_seat then return m; end if;

  select bot into v_lvl from public.royale_players
   where match_id = p_match and seat = p_seat and not eliminated;
  if v_lvl is null then return m; end if;

  st := m.state;

  for u in select * from jsonb_array_elements(st->'units') loop
    continue when (u->>'owner')::int <> p_seat;
    continue when (u->>'moved')::boolean and (u->>'acted')::boolean;
    continue when coalesce((u->>'spent')::boolean, false);
    -- was cn_acts_cap(st) -- royale's real cap is always 1 (0061), not
    -- 1v1's "1 then 2" rule that function still implements.
    continue when coalesce((st->>'acts')::int, 0) >= 1
              and nullif(st->>'active', '') is distinct from u->>'id';

    v_tiles := array[(u->>'x') || ',' || (u->>'y')];
    if not (u->>'moved')::boolean then
      v_tiles := v_tiles || cn_reach(st, u);
    end if;
    v_first := true;

    foreach v_tile in array v_tiles loop
      vx := split_part(v_tile, ',', 1)::int;
      vy := split_part(v_tile, ',', 2)::int;

      v_near := 99; v_thr := 0;
      for t in select * from jsonb_array_elements(st->'units') loop
        continue when (t->>'owner')::int = p_seat;
        v_d := cn_cheb(vx, vy, (t->>'x')::int, (t->>'y')::int);
        v_near := least(v_near, v_d);
        if v_d <= (t->>'mov')::int + (t->>'rmax')::int then v_thr := v_thr + 1; end if;
      end loop;
      v_pos := - abs(v_near - (u->>'rmax')::int) * 5.0 - v_near * 2.0;

      if v_first then v_base := v_pos; v_first := false; end if;

      if vx <> (u->>'x')::int or vy <> (u->>'y')::int then
        v_noise := random() * (case v_lvl when 1 then 220 when 2 then 90 else 15 end);
        v_step_s := v_pos - v_base + v_noise;
        if v_lvl >= 3 then v_step_s := v_step_s - v_thr * 4.0; end if;
        if v_step_s > v_best then
          v_best := v_step_s;
          v_bu := u->>'id'; v_bx := vx; v_by := vy; v_bt := null;
        end if;
        if v_step_s > v_fb then
          v_fb := v_step_s;
          v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := null;
        end if;
      end if;

      continue when (u->>'acted')::boolean;

      for t in select * from jsonb_array_elements(st->'units') loop
        continue when t->>'id' = u->>'id';
        v_d := cn_cheb(vx, vy, (t->>'x')::int, (t->>'y')::int);
        continue when v_d < (u->>'rmin')::int or v_d > (u->>'rmax')::int;
        continue when not cn_los_clear(st, vx, vy, (t->>'x')::int, (t->>'y')::int);

        v_dmg := ((u->>'dmin')::int + (u->>'dmax')::int) / 2.0;

        if (t->>'owner')::int = p_seat then
          continue when not (u->>'heals')::boolean;
          v_act := case when (t->>'maxHp')::int - (t->>'hp')::int <= 0 then -150
                        else least(v_dmg, (t->>'maxHp')::int - (t->>'hp')::int) * 9.0 end;
        else
          v_answers := not coalesce((u->>'sneaks')::boolean, false)
                       and v_d >= (t->>'crmin')::int and v_d <= (t->>'crmax')::int;
          v_parry := v_answers and coalesce((t->>'parries')::boolean, false);

          v_act := least(v_dmg, (t->>'hp')::int) * 10.0;
          if v_dmg >= (t->>'hp')::int then
            v_act := v_act + 400 + (t->>'maxHp')::int;
          elsif (u->>'burns')::boolean and not (t->>'burned')::boolean then
            v_act := v_act + 25;
          end if;

          if v_answers and (v_parry or v_dmg < (t->>'hp')::int) then
            v_ctr := ((t->>'dmin')::int + (t->>'dmax')::int) / 2.0;
            v_act := v_act - v_ctr * (case v_lvl when 1 then 3.0 else 8.0 end);
            if v_ctr >= (u->>'hp')::int then
              v_act := v_act - 500 - (u->>'maxHp')::int
                       - case when v_parry then 400 + (t->>'maxHp')::int else 0 end;
            end if;
          end if;
        end if;

        v_noise := random() * (case v_lvl when 1 then 220 when 2 then 90 else 15 end);
        if v_pos + v_act - v_base + v_noise > v_best then
          v_best := v_pos + v_act - v_base + v_noise;
          v_bu := u->>'id'; v_bx := vx; v_by := vy; v_bt := t->>'id';
        end if;
        if v_pos + v_act - v_base + v_noise > v_fb then
          v_fb := v_pos + v_act - v_base + v_noise;
          v_fu := u->>'id'; v_fbx := vx; v_fby := vy; v_ft := t->>'id';
        end if;
      end loop;
    end loop;
  end loop;

  if v_bu is null and v_fu is not null then
    v_bu := v_fu; v_bx := v_fbx; v_by := v_fby; v_bt := v_ft;
  end if;
  if v_bu is null then return advance_turn_royale(p_match, null, false); end if;

  for u in select * from jsonb_array_elements(st->'units') loop
    if u->>'id' = v_bu and ((u->>'x')::int <> v_bx or (u->>'y')::int <> v_by) then
      return cn_move_royale(p_match, p_seat, v_bu, v_bx, v_by);
    end if;
  end loop;

  if v_bt is not null then return cn_attack_royale(p_match, p_seat, v_bu, v_bt); end if;
  return advance_turn_royale(p_match, null, false);
end
$function$;
