-- 0061_royale_one_action.sql
--
-- Battle Royale: every seat gets exactly ONE activation per turn, always --
-- not 1v1's "1 on the opening turn, 2 after" rule. Requested directly by
-- the developer: a four-seat table with two actions each was judged to
-- drag, especially once bots are seated and each one gets its own 650ms-
-- per-step turn.
--
-- cn_acts_cap(p_st) itself is untouched and still governs 1v1 exactly as
-- it always has (0019) -- this migration does not call it from royale's
-- turn-opener at all anymore, rather than changing its return value, so
-- there is no way for a change here to leak into 1v1's own cap.
--
-- cn_begin_act_royale is fetched fresh from 0048_battle_royale.sql and
-- reproduced verbatim below except for the one line that mattered:
-- `v_cap := cn_acts_cap(p_st);` becomes `v_cap := 1;`. Every other line,
-- including the exception text and the spend-marking loop, is untouched.
--
-- Applied live via the Supabase MCP tools and verified byte-for-byte
-- against pg_proc.prosrc before this file was written.
create or replace function public.cn_begin_act_royale(p_st jsonb, p_seat int, p_unit text)
returns jsonb language plpgsql as $$
declare
  v_active text; v_acts int; v_cap int; u jsonb; v_me jsonb; v_out jsonb := '[]'::jsonb;
begin
  for u in select * from jsonb_array_elements(p_st->'units') loop
    if u->>'id' = p_unit then v_me := u; end if;
  end loop;
  if v_me is null then raise exception 'no such unit'; end if;
  if (v_me->>'owner')::int <> p_seat then raise exception 'that is not your unit'; end if;
  if coalesce((v_me->>'spent')::boolean, false) then
    raise exception 'that unit has already had its go this turn';
  end if;

  v_active := nullif(p_st->>'active', '');
  v_acts   := coalesce((p_st->>'acts')::int, 0);
  v_cap    := 1;

  if v_active is not distinct from p_unit then return p_st; end if;
  if v_acts >= v_cap then raise exception 'no actions left this turn'; end if;

  if v_active is not null then
    for u in select * from jsonb_array_elements(p_st->'units') loop
      if u->>'id' = v_active then u := jsonb_set(u, '{spent}', 'true'::jsonb); end if;
      v_out := v_out || u;
    end loop;
    p_st := jsonb_set(p_st, '{units}', v_out);
  end if;

  p_st := jsonb_set(p_st, '{acts}', to_jsonb(v_acts + 1));
  p_st := jsonb_set(p_st, '{active}', to_jsonb(p_unit));
  return p_st;
end
$$;
